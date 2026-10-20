# 06 – Adding a Worker Node (node6)

> Part 6 of the build series. Previous: [05 – OX App Suite](05-ox-app-suite.md) · Next: [07 – Webmail "Connection error"](07-webmail-connection-error.md)

**Summary:** On 19.10.2026, the additional worker node6 (VM 207, 10.240.0.27) was added to the cluster. The VM was cloned from template 9000, prepared like the other nodes and joined with `scale.yml --limit=node6`. The running cluster and openDesk were not affected. Result: 7 nodes `Ready`, node6 schedulable in Longhorn, functional test with a volume and DNS successful.

## 1. Starting point

| Node | IP | Role |
|---|---|---|
| master | 10.240.0.21 | Control plane, etcd |
| node1 – node5 | 10.240.0.22 – .26 | Workers |
| node6 (new) | 10.240.0.27 | Worker, VM 207 |

The cluster runs Kubernetes v1.36.4 with containerd 2.3.5. It was installed with Kubespray v2.32.0 from the kubespray VM (10.240.0.200, user `k8s`, `~/kubespray`), see [02](02-kubernetes-cluster-kubespray.md).

> **Important:** The Proxmox host server1 is shared with other users, so only change your own VMs. VMs of other users are never stopped, deleted or modified.

## 2. Preparation: capacity and backup

**Run on:** server1 as root (step 1), kubespray VM as k8s (step 2)

### Step 1 – Is there room for another node?

```bash
ping -c 2 -W 1 10.240.0.27
nproc; free -g
pvesm status
qm list
```

**Result:** 10.240.0.27 does not answer, so the address is free. The host has 24 threads; with node6, the assigned vCPUs rise from 76 to 84. 112 GB RAM are available, netapp-hdd7tb-01 has 1.7 TiB free. `qm list` also shows a VM of another user; it is in a different network and does not conflict with node6.

**Conclusion:** RAM and storage are sufficient. The CPU is overcommitted, which is common for workers; keep an eye on the load with `kubectl top nodes`.

### Step 2 – Backup before the change

```bash
ssh k8s@10.240.0.21 "sudo etcdctl --endpoints=https://10.240.0.21:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-master.pem \
  --key=/etc/ssl/etcd/ssl/admin-master-key.pem \
  snapshot save /var/backups/etcd/vor-node6.db"
ssh k8s@10.240.0.21 "sudo etcdutl --write-out=table snapshot status /var/backups/etcd/vor-node6.db"
cp ~/kubespray/inventory/mycluster/inventory.ini ~/inventory.ini.vor-node6
```

**Result:** snapshot with hash df687900, revision 4639961, 2027 keys and 92 MB; copy of the inventory at `~/inventory.ini.vor-node6`.

**Conclusion:** if something goes wrong, the cluster state and the inventory can be reset to the state before node6.

## 3. Create the VM node6 from the template

**Run on:** server1 as root (step 1), kubespray VM as k8s (step 2)

### Step 1 – Clone, set the IP, start

```bash
qm clone 9000 207 --name node6 --full --storage netapp-hdd7tb-01
qm set 207 --ipconfig0 ip=10.240.0.27/24,gw=10.240.0.1
qm start 207
qm config 207 | grep -E '^(name|cores|memory|ipconfig0|net0)'
```

**Result:** VM 207 node6 is running with `ipconfig0: ip=10.240.0.27/24,gw=10.240.0.1`.

**Conclusion:** the template ([01](01-proxmox-cloud-init-template.md)) brings Ubuntu 24.04 and the cloud-init user `k8s` with SSH key. `--full` creates a standalone copy that does not depend on the template.

### Step 2 – Wait for cloud-init

```bash
until ssh -o ConnectTimeout=5 k8s@10.240.0.27 true 2>/dev/null; do sleep 10; done
ssh k8s@10.240.0.27 "cloud-init status --wait"
ssh k8s@10.240.0.27 "[ -f /var/run/reboot-required ] && echo 'reboot required' || echo 'no reboot required'"
ssh k8s@10.240.0.27 "sudo reboot"     # only if "reboot required", then repeat the loop
```

**Result:** first `status: running`, then briefly `Connection refused`, finally `status: done`. After the reboot caused by the package upgrade, the check reports `no reboot required`.

**Conclusion:** `Connection refused` right after the first boot is normal. Cloud-init installs updates and restarts sshd while doing so – do not intervene, just wait.

## 4. Prepare node6

**Run on:** kubespray VM as k8s, in `~/kubespray`

### Step 1 – Add node6 to the inventory

```bash
sed -i '/^node5 /a node6 ansible_host=10.240.0.27 ip=10.240.0.27' inventory/mycluster/inventory.ini
grep -A7 '^\[kube_node\]' inventory/mycluster/inventory.ini
ansible -i inventory/mycluster/inventory.ini node6 -m ping
```

**Result:** node6 is listed under `[kube_node]` right after node5, answer `pong`.

**Conclusion:** `ansible_host` is the address for SSH, `ip` the address the Kubernetes components listen on.

### Step 2 – /etc/hosts on all nodes

Since v2.29, Kubespray no longer adds the nodes to `/etc/hosts`. In addition, cloud-init rewrites `/etc/hosts` on every boot. That is why node6 is added to the block on all 7 nodes and also to the cloud-init template.

```bash
HOSTS='10.240.0.21 master
10.240.0.22 node1
10.240.0.23 node2
10.240.0.24 node3
10.240.0.25 node4
10.240.0.26 node5
10.240.0.27 node6'
for f in /etc/hosts /etc/cloud/templates/hosts.debian.tmpl; do
  ansible -i inventory/mycluster/inventory.ini all -b -m blockinfile \
    -a "path=$f block='$HOSTS' marker='# {mark} k8s nodes'"
done
ansible -i inventory/mycluster/inventory.ini all -b -m command -a "getent hosts node6" -o
```

**Result:** all 7 nodes resolve node6 to 10.240.0.27.

### Step 3 – chrony and the prerequisites for Longhorn

```bash
INV=inventory/mycluster/inventory.ini
ansible -i $INV node6 -b -m apt -a "name=chrony state=present update_cache=yes" -o
ansible -i $INV node6 -b -m apt -a "name=open-iscsi,nfs-common,cryptsetup,dmsetup state=present" -o
ansible -i $INV node6 -b -m shell -a "systemctl enable --now iscsid; modprobe iscsi_tcp; echo iscsi_tcp > /etc/modules-load.d/iscsi_tcp.conf; systemctl disable --now multipathd.service multipathd.socket 2>/dev/null; true"
ansible -i $INV node6 -b -m shell -a "printf 'fs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 524288\n' > /etc/sysctl.d/98-inotify.conf && sysctl --system >/dev/null"
ansible -i $INV node6 -m shell -a "echo iscsid=\$(systemctl is-active iscsid) multipathd=\$(systemctl is-active multipathd) iscsi_tcp=\$(lsmod | grep -c '^iscsi_tcp'); timedatectl | grep synchronized"
```

**Result:** `iscsid=active multipathd=inactive iscsi_tcp=1`, `System clock synchronized: yes`.

**Conclusion:** Longhorn attaches volumes via iSCSI; multipathd would otherwise claim the Longhorn devices.

### Step 4 – Kernel module nls_utf8 for SMB

```bash
ansible -i $INV node6 -b -m shell -a "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-modules-extra-\$(uname -r) >/dev/null && modprobe nls_utf8 && echo nls_utf8 > /etc/modules-load.d/nls_utf8.conf && echo \$(uname -r) nls_utf8=\$(lsmod | grep -c '^nls_utf8')" -o
```

**Result:** `6.8.0-147-generic nls_utf8=1`.

**Conclusion:** node6 runs a newer kernel than the other nodes (6.8.0-146), because cloud-init installed updates on the first boot. The package `linux-modules-extra` must match the running kernel; `$(uname -r)` takes care of that. Without `nls_utf8`, the SMB mounts of Nextcloud fail ([04](04-active-directory-sso.md), error F7).

For access from Z01, a `Host node6` entry is added to `~/.ssh/config` (HostName 10.240.0.27, User k8s, IdentityFile `~/.ssh/k8s_ansible`). Check: `ssh node6 hostname`.

## 5. Join node6 to the cluster

**Run on:** kubespray VM as k8s, in `~/kubespray`; run playbooks in tmux (`tmux new -s scale`)

### Step 1 – Check the starting state

```bash
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed'
```

**Result:** 6 nodes `Ready`, no failed pods.

**Conclusion:** the cluster is healthy; errors after the join can clearly be attributed to node6.

### Step 2 – Refresh the facts of all nodes

```bash
ansible-playbook -i inventory/mycluster/inventory.ini -b playbooks/facts.yml 2>&1 | tee ~/facts.log
grep -A9 "PLAY RECAP" ~/facts.log
ansible -i inventory/mycluster/inventory.ini master -m debug -a var=main_access_ip
```

**Result:** all 7 hosts `unreachable=0 failed=0`; master reports `"main_access_ip": "10.240.0.21"`.

**Conclusion:** with `--limit=node6`, Ansible does not connect to the master in the next step. Its data, such as the IP for nginx-proxy, then only comes from the fact cache (`/tmp/s1_<host>` on the kubespray VM). That is why `facts.yml` must run completely, without a limit.

### Step 3 – scale.yml for node6 only

```bash
ansible-playbook -i inventory/mycluster/inventory.ini -b scale.yml --limit=node6 2>&1 | tee ~/scale-node6-2.log
grep -A3 "PLAY RECAP" ~/scale-node6-2.log
```

**Result:** `node6 : ok=403 changed=32 unreachable=0 failed=0`, runtime about 4 minutes.

**Conclusion:** `--limit=node6` restricts all changes to node6; master and node1 – node5 are not touched.

### Error during the first run

The first run of `scale.yml` aborted with `failed=1`, and node6 was missing from `kubectl get nodes`:

```
object of type 'HostVarsVars' has no attribute 'main_access_ip'
Origin: roles/kubernetes/node/templates/loadbalancer/nginx.conf.j2
```

Diagnosis:

```bash
grep -n -B3 -A20 "fatal: \[node6\]" ~/scale-node6.log | tail -n 60
ansible-config dump --only-changed | grep -iE 'CACHE|GATHERING'
ls -l /tmp/s1_*
ansible -i inventory/mycluster/inventory.ini master,node6 -m debug -a var=main_access_ip
```

**Result:** fact cache `jsonfile` in `/tmp`; the files of master and node1 – node5 were only about 5 KB. The master reported `'main_access_ip' is undefined`, node6 on the other hand `10.240.0.27`.

**Conclusion:** the previous `facts.yml` run had been incomplete; only the first play (bootstrap) had written data. So the cause of the error was the missing cache entry of the master, not node6.

**Solution:** repeat step 2 completely, then step 3. `scale.yml` is idempotent and simply continues. When it aborted, node6 was not yet part of the cluster (kubelet inactive), so nothing had to be reset.

## 6. Checks after the join

**Run on:** kubespray VM as k8s

### Step 1 – Node, pods and Longhorn

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide --field-selector spec.nodeName=node6
kubectl -n longhorn-system get nodes.longhorn.io
```

**Result:** node6 is `Ready` with v1.36.4, 10.240.0.27, kernel 6.8.0-147 and containerd 2.3.5. The 9 DaemonSet pods run on node6: calico-node, kube-proxy, nodelocaldns, csi-smb-node, longhorn-manager, longhorn-csi-plugin, engine-image, metallb-speaker and metallb-frr-k8s – plus the Longhorn instance-manager. In Longhorn, node6 is `READY True` and `SCHEDULABLE True`.

**Conclusion:** DaemonSets distribute their pods to new nodes automatically; no further step is needed for that. One restart each for csi-smb-node and longhorn-csi-plugin in the first minute is normal. The first openDesk CronJob pods ran on node6 right away, so the scheduler is using the node.

### Step 2 – nginx-proxy, MTU and nls_utf8 on node6

```bash
ssh k8s@10.240.0.27 'uname -r; lsmod | grep -c "^nls_utf8"; ip -o link | awk "{print \$2, \$5}" | grep -E "^(eth|ens|vxlan|tunl)"; ping -M do -s 1422 -c 2 -q 10.240.0.21 | tail -2; sudo crictl ps --name nginx-proxy 2>/dev/null | cut -c1-100; sudo grep -h "server:" /etc/kubernetes/kubelet.conf'
```

**Result:** `nls_utf8` loaded; eth0 with MTU 1450 and vxlan.calico with MTU 1400; a ping with 1422 bytes and the DF bit set arrives twice. The nginx-proxy container is running, and kubelet talks to `https://localhost:6443`.

**Conclusion:** every worker reaches the API server through its local nginx-proxy (localhost:6443 → master:6443). 1422 bytes of data plus 28 bytes of IP and ICMP headers add up to exactly 1450, so the full MTU fits without fragmentation.

### Step 3 – Explaining two oddities

```bash
ssh k8s@10.240.0.27 'sudo journalctl -u kubelet --no-pager | grep -i "mirror pod" | tail -2 | cut -c1-300'
kubectl -n opendesk get events --field-selector involvedObject.name=opendesk-nextcloud-aio-cron-29873400-6nmkw --sort-by=.lastTimestamp | tail -6
```

**Result 1:** nginx-proxy is missing from `kubectl get pods` on all nodes. The kubelet log shows `Failed creating a mirror pod … the integer value of priority (2000001000) must not be provided in pod spec`.

**Conclusion:** the Kubespray v2.32.0 template sets only `priority` without `priorityClassName` for this static pod. The API server therefore rejects the mirror pod, but the container runs anyway. nginx-proxy is checked on the node with `crictl`, not with kubectl.

**Result 2:** the first Nextcloud CronJob pod on node6 reported `FailedMount … failed to create newCsiDriverClient` twice, then `Pulled`, `Created` and `Started`.

**Conclusion:** the pod was scheduled before csi-smb-node had registered the SMB driver on node6. kubelet retries on its own; the SMB mounts work afterwards. Only check csi-smb-node if the message persists.

## 7. Functional test: volume and DNS on node6

**Run on:** kubespray VM as k8s

### Step 1 – Test pod with a Longhorn volume, pinned to node6

```bash
kubectl create namespace uebung
kubectl apply -n uebung -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-node6
spec:
  nodeSelector:
    kubernetes.io/hostname: node6
  containers:
  - name: test
    image: busybox:1.36
    command: ["sh", "-c", "echo ok-$(date +%T) > /data/test.txt && sleep 3600"]
    resources:
      requests: {cpu: 10m, memory: 16Mi}
      limits: {memory: 64Mi}
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
EOF
kubectl -n uebung wait --for=condition=Ready pod/test-node6 --timeout=180s
kubectl -n uebung get pod,pvc -o wide
```

**Result:** `condition met`; pod `Running` on node6 with 10.233.75.72; PVC `Bound` with StorageClass longhorn and 1Gi.

**Conclusion:** Longhorn can attach a volume via iSCSI on node6.

### Step 2 – Volume and DNS from inside the pod

```bash
kubectl -n uebung exec test-node6 -- sh -c 'cat /data/test.txt; for n in kubernetes.default.svc.cluster.local portal.k8s.lab lab.local; do echo "== $n"; nslookup $n | grep -A2 "^Name"; done'
```

| Check | Result | Meaning |
|---|---|---|
| `/data/test.txt` | ok-10:08:26 | Writing and reading on the Longhorn volume |
| kubernetes.default.svc.cluster.local | 10.233.0.1 | Cluster DNS via nodelocaldns |
| portal.k8s.lab | 10.240.0.190 | openDesk via MetalLB |
| lab.local | 10.240.0.234 | AD domain via AD-DC |

### Step 3 – Remove the test resources

```bash
kubectl delete namespace uebung
kubectl get pv | grep -c pvc-c4416518 || true
kubectl -n longhorn-system get volumes.longhorn.io | grep -c pvc-c4416518 || true
```

**Result:** `0` twice. Deleting the namespace also deletes the PVC, the PV and the Longhorn volume (reclaim policy `Delete`). Deleting takes about 30 seconds, because `sleep` in the test pod does not react to SIGTERM.

## 8. Pitfalls

| Observation | Cause | Solution |
|---|---|---|
| scale.yml: `has no attribute 'main_access_ip'` | facts.yml did not run completely; the fact cache had no entry for the master | Run facts.yml completely without a limit, check the PLAY RECAP, then run scale.yml again (section 5) |
| facts.yml seems to hang | `\| tail` only shows output at the end | Run it with `\| tee file.log` and do not cancel |
| `Connection refused` shortly after the first boot | Cloud-init restarts sshd during the package upgrade | Wait, `cloud-init status --wait` |
| nginx-proxy missing in kubectl, on all nodes | Mirror pod rejected because of `priority` without `priorityClassName` | Nothing to do; check with `crictl ps --name nginx-proxy` |
| `FailedMount … newCsiDriverClient` in the first minutes | Pod scheduled before csi-smb-node had registered the driver | Resolves itself; if it persists, check csi-smb-node |
| node6 with kernel 6.8.0-147, the others with 146 | Cloud-init installs updates on the first boot | Always install `linux-modules-extra` for `$(uname -r)`; check `nls_utf8` after every kernel update ([04](04-active-directory-sso.md), section 10) |

> **Important:**
> - Start playbooks in tmux. If the SSH connection drops, the run continues.
> - Take an etcd snapshot and back up the inventory before every change to the cluster.
> - On the shared Proxmox host, only touch your own VMs.

**Scope:** the procedure follows the official Kubespray guide "Adding/replacing a worker node" (`docs/operations/nodes.md`, v2.32.0).

- Workers only. Control plane and etcd nodes are added with `cluster.yml` without a limit; afterwards nginx-proxy is restarted on all nodes.
- Do not change the Kubespray version or the group_vars between installation and extension, otherwise the new node gets different settings.
- The fact cache is valid for 24 hours (`fact_caching_timeout = 86400`). That is why `facts.yml` should be run again before every `scale.yml`.
- The preparation from section 4 must be finished before `scale.yml`. As soon as the node is `Ready`, Kubernetes schedules pods on it.

## 9. Result and checklist

**Result on 19.10.2026:** the cluster has 7 nodes `Ready`, 6 of them workers. node6 runs all DaemonSets, is schedulable in Longhorn, resolves cluster, openDesk and AD names, and mounts SMB and Longhorn volumes. openDesk ran without interruption during the entire work.

**Checklist for the next worker:**

1. Check the capacity on server1, confirm a free IP, do not touch other users' VMs.
2. Take an etcd snapshot and a copy of the inventory.
3. Clone the VM from template 9000, set the IP, start it, wait for cloud-init, reboot if needed.
4. Add the node to the inventory and distribute the `/etc/hosts` block to all nodes and to the cloud-init template.
5. Set up chrony, iSCSI, multipathd off, inotify and `nls_utf8` on the new node.
6. Run `playbooks/facts.yml` without a limit, check the PLAY RECAP.
7. Run `scale.yml --limit=<node>` in tmux, check the PLAY RECAP.
8. Node `Ready`, DaemonSet pods `Running`, Longhorn `SCHEDULABLE True`.
9. Functional test with a PVC and DNS, then delete the test resources.

---

Previous: [05 – OX App Suite](05-ox-app-suite.md) · Next: [07 – Webmail "Connection error"](07-webmail-connection-error.md)
