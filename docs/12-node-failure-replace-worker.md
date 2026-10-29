# 12 – Worker Node Failure: Replacing node6

> Troubleshooting runbook / failure drill. Previous: [11 – Container keeps restarting – OOMKilled](11-oomkilled.md) · Back to the [overview](../README.md)

**Summary:** On 19.10.2026, the worker node6 was powered off hard. The failure was observed, node6 was removed from the cluster ungracefully and replaced by a new VM with the same name. A Deployment replaced its pods on its own after about 5 minutes. A StatefulSet stayed stuck until the node was removed, and then continued on node4 with the same data. openDesk was reachable during the entire drill.

All times are in UTC (local time = UTC + 2 hours).

| Field | Value |
|---|---|
| Date | 19.10.2026 (planned failure drill) |
| Affected node | node6 (VM 207, 10.240.0.27), see [06](06-add-worker-node.md) |
| Result | Deployment self-healed after ~5 min; StatefulSet down for ~26 min until the node was removed; no data loss |

## 1. Drill setup

**Run on:** kubespray VM as k8s, in `~/kubespray`

### Step 1 – What runs on node6?

```bash
kubectl get pods -n opendesk -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
kubectl get pods -A -o wide --field-selector spec.nodeName=node6 | grep -vE 'calico-node|kube-proxy|nodelocaldns|csi-smb|longhorn|engine-image|instance-manager|metallb'
```

**Result:** only short-lived CronJob pods of openDesk ran on node6; the other 55 openDesk pods were on node1 – node5.

**Conclusion:** a failure of node6 does not hit openDesk. Kubernetes does not move running pods to a new node on its own; only new pods land there.

### Step 2 – Backup

```bash
ssh k8s@10.240.0.21 "sudo etcdctl --endpoints=https://10.240.0.21:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-master.pem \
  --key=/etc/ssl/etcd/ssl/admin-master-key.pem \
  snapshot save /var/backups/etcd/vor-ausfall-node6.db"
cp inventory/mycluster/inventory.ini ~/inventory.ini.vor-ausfall-node6
```

### Step 3 – Test workloads on node6

In the namespace `uebung`, two test workloads run that **prefer** node6 (`preferredDuringScheduling`) but are not bound to it:

- **web:** Deployment with 2 replicas, no data
- **db:** StatefulSet with a Longhorn volume that writes one line to `/data/log.txt` on every start

```bash
kubectl create namespace uebung
kubectl apply -n uebung -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - {key: kubernetes.io/hostname, operator: In, values: [node6]}
      containers:
      - name: web
        image: busybox:1.36
        command: ["sh", "-c", "sleep 1d"]
        resources:
          requests: {cpu: 10m, memory: 16Mi}
          limits: {memory: 64Mi}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db
  replicas: 1
  selector:
    matchLabels: {app: db}
  template:
    metadata:
      labels: {app: db}
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - {key: kubernetes.io/hostname, operator: In, values: [node6]}
      containers:
      - name: db
        image: busybox:1.36
        command: ["sh", "-c", "echo start $(hostname) $(date +%T) >> /data/log.txt; sleep 1d"]
        resources:
          requests: {cpu: 10m, memory: 16Mi}
          limits: {memory: 64Mi}
        volumeMounts:
        - {name: data, mountPath: /data}
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn
      resources:
        requests:
          storage: 1Gi
EOF
kubectl -n uebung get pods,pvc -o wide
kubectl -n uebung exec db-0 -- cat /data/log.txt
```

**Result:** `web` (2 pods) and `db-0` run on node6, PVC `data-db-0` is `Bound`, the log contains `start db-0 11:39:42`.

## 2. The failure: powering off node6 hard

**Run on:** kubespray VM as k8s (step 1, in tmux), server1 as root (step 2)

### Step 1 – Record the timeline

```bash
while true; do
  echo "=== $(date +%T)"
  kubectl get node node6 --no-headers
  kubectl -n uebung get pods -o wide --no-headers | awk '{print $1, $2, $3, $7}'
  curl -sk -o /dev/null -w 'portal: %{http_code}\n' --resolve portal.k8s.lab:443:10.240.0.190 https://portal.k8s.lab/
  sleep 20
done | tee ~/ausfall-node6.log
```

### Step 2 – Simulate a power outage

```bash
qm config 207 | grep ^name    # must show name: node6
date +%T; qm stop 207
```

`qm stop` turns the VM off immediately, like pulling the power plug. kubelet has no chance to inform the cluster.

### Step 3 – Evaluation

```bash
awk '/^===/{t=$2} /^node6 /{print t, $2}' ~/ausfall-node6.log | uniq -f1
awk '/^===/{t=$2} /Terminating/ && !a++ {print "first Terminating:", t} /^web.* node[1-5]$/ && !b++ {print "first replacement pod:", t}' ~/ausfall-node6.log
kubectl get node node6 -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}'
kubectl -n longhorn-system get volumes.longhorn.io pvc-7fb90e0d-e807-4ed5-8f03-15a2a74fb012
```

| Time (UTC) | Observation |
|---|---|
| Until 11:48:22 | node6 `Ready`; shortly after that `qm stop 207` |
| 11:49:43 | node6 `NotReady`, taints `node.kubernetes.io/unreachable:NoSchedule` and `:NoExecute` |
| 11:54:47 | Pods on node6 `Terminating`; two new `web` pods `Running` on node1 and node4 |
| Afterwards | `db-0` stays `Terminating` on node6, no new `db-0`; volume `attaching`, robustness `unknown` |
| The whole time | `portal: 301`, openDesk reachable |

**Conclusion:**

- Without a heartbeat, Kubernetes marks a node as `NotReady` after about 40 – 50 seconds.
- By default, every pod tolerates the `unreachable` taint for 300 seconds. Only then are its pods removed – hence exactly 5 minutes until `Terminating`.
- The Deployment replaces its pods on other nodes right away.
- The pods on node6 stay behind as "ghosts" in `Terminating`, because kubelet cannot confirm the deletion. Their displayed status (`1/1`) is the last known state and no longer reliable.

> **Important:** Both `web` replicas were on the same node. That is why `web` was completely gone for about 6 minutes. In real applications, spread replicas across nodes with `topologySpreadConstraints` or `podAntiAffinity`.

## 3. Why db-0 gets stuck

A StatefulSet guarantees that each of its pods exists **at most once**. Kubernetes cannot tell whether node6 is switched off or only cut off from the network. If it started a second `db-0` while the first one was still running, two processes would write to the same data. So it waits until an administrator decides. In a real failure, the database is down until then.

**Fencing first:** before releasing anything, it must be certain that the failed node is really off and will not come back. Here: `qm status 207` shows `status: stopped`.

| Option | When | Effect |
|---|---|---|
| Remove the node (`remove-node.yml` or `kubectl delete node`) | The node will be replaced | The node's pods are deleted, `db-0` starts elsewhere |
| Taint `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` | The node is definitely off and will be repaired later | Pods are deleted and volumes released immediately |
| `kubectl delete pod db-0 --force --grace-period=0` | Only if the node is provably off | Riskiest option, bypasses all safety mechanisms |

In this drill, the first option was chosen because node6 is being replaced.

## 4. Removing node6 ungracefully

**Run on:** server1 as root (step 1), kubespray VM as k8s in tmux (steps 2 and 3)

### Step 1 – Check the fencing

```bash
qm status 207
```

**Result:** `status: stopped`.

### Step 2 – remove-node.yml

```bash
ansible-playbook -i inventory/mycluster/inventory.ini -b remove-node.yml -e node=node6 -e '{"reset_nodes": false, "allow_ungraceful_removal": true}'
```

Confirm the prompt `Type 'yes' to delete nodes` with `yes`. Start it without `| tee`, so that the prompt is visible right away.

- `reset_nodes: false`: Kubespray does not try to connect to node6 and reset it.
- `allow_ungraceful_removal: true`: a failed drain does not abort the run.

**Result:** the task `Drain node except daemonsets resource` waited from 12:01:05 until its timeout of 360 seconds. After that, Kubespray ran `kubectl delete node node6`. The run finished at 12:07:22 after 6:44 minutes with `node6 : ok=8 changed=3 failed=0`.

**Conclusion:** the waiting time is normal. The drain waits for pods that will never disappear from a powered-off node. Do not cancel.

### Step 3 – Watch db-0 restart

```bash
kubectl get nodes
kubectl -n uebung get pods -o wide
kubectl -n uebung describe pod db-0 | tail -6
kubectl get volumeattachments | grep pvc-7fb90e0d
```

**Result:** node6 `NotFound`, 6 nodes `Ready`; the ghost pods are gone. `db-0` was scheduled on node4 around 12:08, but stays in `ContainerCreating`. Event: `FailedAttachVolume … Volume is already exclusively attached to one node, waiting on detach before it can be attached to another node`. The VolumeAttachment still shows `node6, true`.

**Conclusion:** an RWO volume may only be attached to one node. Kubernetes cannot ask node6 whether the volume has been released, so it waits up to 6 minutes (`maxWaitForUnmountDuration`). After that, it detaches the volume forcibly.

```bash
kubectl -n uebung exec db-0 -- cat /data/log.txt
kubectl -n longhorn-system get volumes.longhorn.io pvc-7fb90e0d-e807-4ed5-8f03-15a2a74fb012
```

**Result:** at 12:14:13, `db-0` starts on node4. The volume is attached to node4 with robustness `degraded`, and the VolumeAttachment now shows node4. The log contains two lines: `start db-0 11:39:42` (on node6) and `start db-0 12:14:13` (on node4).

**Conclusion:** the data survived the failure. `degraded` means that the replica on node6 is missing; the remaining replicas carry the volume.

## 5. Cleaning up in Longhorn

**Run on:** kubespray VM as k8s

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,VOLUME:.spec.volumeName,STATE:.status.currentState --no-headers | grep node6
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=ROBUST:.status.robustness --no-headers | sort | uniq -c
kubectl delete namespace uebung
kubectl -n longhorn-system patch nodes.longhorn.io node6 --type merge -p '{"spec":{"allowScheduling":false}}'
kubectl -n longhorn-system delete nodes.longhorn.io node6
kubectl -n longhorn-system get nodes.longhorn.io
```

**Result:**

- Only one replica was on node6: the one of the test volume (`stopped`).
- 16 volumes `healthy`, 1 `degraded` (the test volume). No openDesk volume had a replica on node6.
- The first delete attempt without the patch was rejected: `could not delete node node6 with node ready condition is False, reason is KubernetesNodeGone, node schedulable true, and 0 replica, 0 engine running on it`.
- After the patch, node6 disappeared from Longhorn immediately; the following delete only reported `NotFound`.
- Afterwards: node1 – node5 in Longhorn, 16 volumes `healthy`.

**Conclusion:** Longhorn only deletes a node once it is gone, carries no replicas and engines anymore, and scheduling is switched off. So the order is: first `allowScheduling: false`, then delete. The old Longhorn entry must be gone before a new node with the same name joins; otherwise Longhorn mixes it up with the old disk data.

## 6. Building the replacement node

node6 gets a new VM with the same name and the same IP. So the inventory and `/etc/hosts` of the other nodes stay unchanged; `remove-node.yml` does not change the inventory.

### Step 1 – Delete the old VM, clone a new one (server1 as root)

```bash
qm status 207; qm config 207 | grep ^name    # status: stopped, name: node6
qm destroy 207 --purge
qm clone 9000 207 --name node6 --full --storage vm-storage
qm set 207 --ipconfig0 ip=10.240.0.27/24,gw=10.240.0.1
qm start 207
```

`--purge` also removes the VM from backup jobs and from the Proxmox HA configuration. A failed node is not repaired, but replaced by a fresh VM.

### Step 2 – SSH host key and cloud-init (kubespray VM)

```bash
ssh-keygen -R 10.240.0.27; ssh-keygen -R node6
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new k8s@10.240.0.27 true 2>/dev/null; do sleep 10; done
ssh k8s@10.240.0.27 "cloud-init status --wait"
ssh k8s@10.240.0.27 "[ -f /var/run/reboot-required ] && echo 'reboot required' || echo 'no reboot required'"
ssh k8s@10.240.0.27 "sudo reboot"; sleep 30
until ssh -o ConnectTimeout=5 k8s@10.240.0.27 true 2>/dev/null; do sleep 10; done
ssh k8s@10.240.0.27 "uname -r"
grep '^node6 ' ~/kubespray/inventory/mycluster/inventory.ini
```

**Result:** `reboot required`; after the reboot, kernel 6.8.0-147 is running. node6 is still in the inventory.

**Conclusion:** the new VM has a new SSH host key. Without `ssh-keygen -R`, SSH warns with `REMOTE HOST IDENTIFICATION HAS CHANGED`, just like during an attack. Do the same on jumphost. `accept-new` accepts new keys without asking, but rejects changed ones.

### Step 3 – Preparation and join

As in [06 – Adding a worker node](06-add-worker-node.md), sections 4 to 6:

1. Distribute the `/etc/hosts` block to all nodes via `blockinfile`. Only node6 reports `changed`.
2. chrony, open-iscsi, iscsid, iscsi_tcp, multipathd off, inotify.
3. Install `nls_utf8` only after the reboot, because `linux-modules-extra-$(uname -r)` applies to the running kernel.
4. `playbooks/facts.yml` without a limit; check the PLAY RECAP and the master's `main_access_ip`.
5. `scale.yml --limit=node6` in tmux.

### Step 4 – Verification

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide --field-selector spec.nodeName=node6
kubectl -n longhorn-system get nodes.longhorn.io
```

**Result:** node6 `Ready` (age 2m39s, v1.36.4, kernel 6.8.0-147). The 9 DaemonSet pods and the instance-manager are running; one restart of longhorn-csi-plugin at startup is normal. In Longhorn, node6 is `READY True`, `SCHEDULABLE True` again.

## 7. Findings and checklist

| Time value | Duration in the drill | Where it comes from |
|---|---|---|
| Until `NotReady` | About 40 – 50 s | Missing heartbeat from kubelet |
| Until pods `Terminating` | 5 min after `NotReady` | Toleration `unreachable` 300 s |
| Drain in `remove-node.yml` | 6 min | `drain_timeout` 360 s |
| Until the volume is on the new node | About 6 min after deleting the node | `maxWaitForUnmountDuration` |
| Total outage of `db-0` | About 26 min (11:48 to 12:14) | Unlimited without intervention |

- Stateless Deployments heal themselves; StatefulSets need a decision by an administrator when a node fails.
- Fencing before any release: make sure the node is off and stays off.
- Spread replicas across several nodes, otherwise a Deployment fails completely together with one node.
- Do not trust the status of pods on a `NotReady` node; it is outdated.
- In Longhorn, switch off scheduling first, then delete the node.
- A new VM means a new SSH host key and usually a newer kernel; install `nls_utf8` after the reboot.
- The kubespray VM reported `System restart required`; reboot it outside of running playbooks.

**Checklist: replacing a broken worker**

1. Confirm the failure: node `NotReady`, identify the affected pods.
2. Fencing: the VM is off (`qm status`).
3. etcd snapshot and a copy of the inventory.
4. `remove-node.yml -e node=<node> -e '{"reset_nodes": false, "allow_ungraceful_removal": true}'`, confirm with `yes`, wait out the drain timeout.
5. Check stranded StatefulSet pods and volumes; plan for up to 6 minutes of waiting while volumes are re-attached.
6. Longhorn: `allowScheduling: false`, delete the node, volumes `healthy`.
7. Delete the old VM, clone a new one from template 9000, remove the old SSH host key, wait for cloud-init and the reboot.
8. Preparation, `facts.yml`, `scale.yml --limit=<node>` as in [06](06-add-worker-node.md).
9. Verification: node `Ready`, DaemonSet pods `Running`, Longhorn `SCHEDULABLE True`.

**Source:** Kubespray guide "Adding/replacing a node" (`docs/operations/nodes.md`, v2.32.0).

---

Previous: [11 – Container keeps restarting – OOMKilled](11-oomkilled.md) · Back to the [overview](../README.md)
