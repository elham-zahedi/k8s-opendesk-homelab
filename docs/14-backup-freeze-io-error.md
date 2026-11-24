# 14 – I/O Errors after the Nightly Backup

> Troubleshooting runbook. Previous: [13 – Three control plane nodes](13-three-control-plane-nodes.md) · Next: [15 – openDesk settings per release](15-opendesk-customization.md) · Back to the [overview](../README.md)

**Summary:** In the second installation of this setup, PostgreSQL stopped on the evening of 04.11.2026 with `Input/output error` on its Longhorn volume. The cause was the nightly Proxmox backup: it froze the file systems of the Kubernetes nodes through the QEMU guest agent. Since the VMs were spread over three Proxmox hosts ([13](13-three-control-plane-nodes.md)), the hosts back up in parallel, and two nodes were frozen at the same time. Each freeze waited for the other node, both hung for about nine minutes, and Longhorn gave up on the replicas. Three more pods had broken mounts, although Longhorn showed every volume as `healthy`. The fix: the guest agent on the nodes no longer accepts the freeze command, and the VMs are set to back up without freezing.

All times are in UTC (local time = UTC + 1 hour).

| Field | Value |
|---|---|
| Date | 04.11.2026, found on 05.11.2026 in the morning |
| Affected | PostgreSQL (all apps that use it), ClamAV, OpenProject web and worker |
| Result | No data loss; PostgreSQL recovered from its WAL after a new mount; fs-freeze blocked on all nodes |

## 1. Report

In the morning the apps could not reach the database (`ECONNREFUSED`). The PostgreSQL pod failed with `Input/output error` on its data directory, while Longhorn showed the volume as `attached` and `healthy`. The last normal log line of PostgreSQL was from 19:57 UTC the evening before.

## 2. Diagnosis: from symptom to cause

**Run on:** kubespray VM as k8s, and on every Proxmox host as root

### Step 1 – What did Longhorn see?

The engine of a volume runs in the instance manager on the node where the volume is attached:

```bash
IM=$(kubectl -n longhorn-system get pod -l longhorn.io/component=instance-manager,longhorn.io/node=node4 -o name)
kubectl -n longhorn-system logs $IM --since-time=2026-11-04T19:45:00Z | grep pvc-<volume> | grep -iE 'error|timeout|fail' | head -20
```

**Result:**

```
20:01:51  R/W Timeout. No response received in 8s
20:10:45  Backend tcp://...:10126 monitoring failed, mark as ERR   error="r/w timeout"
20:10:47  Setting replica tcp://...:10593 to ERR
```

Two of three replicas stopped answering at the same moment, and nothing was wrong with the network. Something on the nodes stopped all writes.

### Step 2 – What happened on the Proxmox hosts at 20:00?

The backup job runs every evening at 21:00 local time (20:00 UTC). Each VM log in `/var/log/vzdump/` holds the last backup of that VM:

```bash
grep -H -E "Starting Backup|fs-freeze|fs-thaw|started backup task|ERROR|WARN" /var/log/vzdump/qemu-*.log
```

**Result** (on two of the three hosts, local time):

```
qemu-202.log:2026-11-04 21:01:42 INFO: issuing guest-agent 'fs-freeze' command
qemu-202.log:2026-11-04 21:10:45 ERROR: unable to freeze guest fs - failed to freeze /var/lib/kubelet/pods/.../pvc-.../mount: Input/output error
qemu-205.log:2026-11-04 21:01:42 INFO: issuing guest-agent 'fs-freeze' command
qemu-205.log:2026-11-04 21:10:54 ERROR: unable to freeze guest fs - failed to freeze /var/lib/kubelet/pods/.../pvc-.../mount: Input/output error
```

A freeze normally takes a few seconds. Here two nodes (node1 and node4, on two different hosts) started their freeze at exactly the same second, and both hung for nine minutes. Two more nodes on the third host failed the same way later in the run.

### Timeline

| Time (UTC) | Event |
|---|---|
| 20:01:42 | Backup of node1 (host 1) and node4 (host 2) starts, the guest agent freezes both |
| 20:01:51 | The PostgreSQL volume on node4 gets the first `R/W Timeout` (8 seconds) |
| 20:10:45 | The freeze of node1 fails with `Input/output error`; Longhorn sets two replicas to `ERR` |
| 20:10:54 | The freeze of node4 fails with `Input/output error` on the PostgreSQL mount |
| 20:13 – 20:15 | node5 and node6 (host 3) fail their freeze on other volumes |

### Root cause

`fs-freeze` stops every write on every file system of the VM. On a Kubernetes node this includes:

- the file systems of the Longhorn volumes that pods have mounted (they are mounted on the node), and
- `/var/lib/longhorn`, where the node keeps its replicas of other volumes.

A Longhorn volume writes to replicas on other nodes. When node A freezes its pod mounts, they have to write their dirty data first, and that data goes to a replica on node B. If node B is frozen at the same time, the write never finishes, so node A cannot finish its freeze either, and the other way round. After 8 seconds without an answer, Longhorn marks the replica as broken. After about nine minutes, the guest agent gives up, and the file systems in the pods are left with I/O errors.

As long as all nodes were on one Proxmox host, the VMs were backed up one after the other and this could not happen. With three hosts, every host runs its own part of the backup job at 21:00, so nodes of different hosts freeze at the same time.

## 3. Recovery

### Step 1 – Snapshot first

Before touching a broken volume, take a Longhorn snapshot (Longhorn UI → Volume → Take Snapshot). Then nothing can get worse by the next steps.

### Step 2 – Give the pod a fresh mount

The volume itself was fine after Longhorn rebuilt the replicas. Only the mount in the running pod was broken. Deleting the pod is enough; the StatefulSet creates it again with a new mount:

```bash
kubectl -n opendesk delete pod postgresql-0
kubectl -n opendesk logs postgresql-0 -f | grep -iE 'redo|ready to accept'
```

PostgreSQL replays its WAL and starts. Afterwards the daily check passed all checks.

### Step 3 – Find every other broken mount

The backup error only names the first mount that failed on each node. Other pods can be broken too, while Longhorn still shows `healthy`. `longhorn-mount-check.sh` writes and deletes a small file in every Longhorn mount of every running pod:

```bash
./ops/longhorn-mount-check.sh
```

**Result:** three more pods: ClamAV (`Read-only file system`), OpenProject worker and web (`Input/output error` on `/app/tmp`). Deleting these pods fixed them; the second run printed `All OK`.

## 4. Fix

### 4.1 Broken mounts

Delete the pod; it gets a fresh mount (section 3, step 2). The daily check now runs `longhorn-mount-check.sh` and names such pods.

Not every read-only mount is broken. Since openDesk 1.20 the `leader-elector` container of `ums-ldap-server-primary-0` mounts `/var/lib/univention-ldap` read-only on purpose; the `main` container of the same pod mounts it writable. Check the pod spec before you delete a pod:

```bash
kubectl -n opendesk get pod ums-ldap-server-primary-0 -o jsonpath='{range .spec.containers[*]}{.name}{": "}{range .volumeMounts[*]}{.mountPath}{" (readOnly="}{.readOnly}{") "}{end}{"\n"}{end}'
```

`readOnly=true` there means: by design, nothing to fix. `longhorn-mount-check.sh` skips such mounts and prints them as `Skipped`.

### 4.2 Block fs-freeze in the QEMU guest agent (works at once)

`prepare-nodes.yml` writes `/etc/qemu/qemu-ga.conf` on every node:

```ini
[general]
block-rpcs=guest-fsfreeze-freeze,guest-fsfreeze-freeze-list
```

and restarts the guest agent. The agent keeps working (shutdown, IP address in Proxmox), it only refuses the freeze. The backup then logs one line per VM and goes on without freezing:

```
ERROR: unable to freeze guest fs - Command guest-fsfreeze-freeze has been disabled
INFO: Finished Backup of VM 205 (00:02:48)
```

To run it on the existing nodes:

```bash
cd ~/kubespray
ansible-playbook -i inventory/mycluster/inventory.ini ~/k8s-opendesk-homelab/automation/02-kubespray/prepare-nodes.yml --check --diff
ansible-playbook -i inventory/mycluster/inventory.ini ~/k8s-opendesk-homelab/automation/02-kubespray/prepare-nodes.yml
```

Check from each Proxmox host that the command is really blocked (`"enabled":false`):

```bash
for ID in $(qm list | awk 'NR>1 {print $1}'); do
  echo "$ID: $(qm guest cmd $ID info 2>/dev/null | tr -d ' \n' | grep -o '{[^{}]*"guest-fsfreeze-freeze"[^{}]*}')"
done
```

### 4.3 Turn off the freeze in the VM options (works after the next VM restart)

```bash
qm set <vmid> --agent enabled=1,freeze-fs-on-backup=0
qm pending <vmid>
```

On a running VM the change stays pending (`new agent: …`) until the VM is stopped and started again. After that, the backup log shows `skipping guest-agent 'fs-freeze', disabled in VM options`. The template from [01](01-proxmox-cloud-init-template.md) has this option now, so new nodes get it from the start. 4.2 and 4.3 together mean that no node freezes, even if one of the two settings gets lost.

Without the freeze the backup is crash-consistent, like a power cut. For Kubernetes nodes this is fine: the data of the apps is in Longhorn with three replicas, and etcd and PostgreSQL recover from their logs.

### 4.4 Verify after the next backup

```bash
grep -H -E "fs-freeze|freeze guest|Finished Backup|failed" /var/log/vzdump/qemu-*.log   # on every host
./ops/longhorn-mount-check.sh                                                          # kubespray VM
```

Every Kubernetes VM shows the freeze error from 4.2 (or the `skipping` line from 4.3) and then `Finished Backup` within a few minutes; the mount check prints `All OK`.

## 5. Why Longhorn still showed `healthy`

Longhorn reports the state of the volume: its engine and its replicas. After the freeze ended, the replicas were rebuilt and the volume was healthy again. The ext4 file system inside the pod had already seen I/O errors and stayed broken (read-only, or `Input/output error` on every access) until it was mounted again. Longhorn does not look inside the file system, so only a write from the pod shows the problem.

## 6. Takeaways

- A backup that freezes the guest is not safe for VMs that run distributed storage. Block the freeze in the guest agent and turn it off in the VM options.
- Moving VMs to more Proxmox hosts also changes how the backup runs. Check the backup job after such a change.
- `healthy` in Longhorn does not prove that the pods can write. The daily check now writes a test file in every mount.
- The backup error names only the first broken mount of a node. Check all pods, not only the one that failed.

## 7. Follow-up on 20.11.2026: the control plane went down during every backup

Two weeks later the same backup still hurt the cluster, without a single error in the morning: the three `kube-apiserver` pods had more than 100 restarts each in 17 days. Every night, during the backup, etcd lost its leader for a few minutes. The pods of the users kept running, but everything that needs the API failed in that time. The daily check now reports restarts of the control plane.

### 7.1 Diagnosis

**Run on:** kubespray VM as k8s

```bash
# 1. Which containers restarted in the last 24 hours, and when (UTC)?
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p
  | .status.containerStatuses[]? | select(.lastState.terminated.finishedAt != null
  and (.lastState.terminated.finishedAt > (now - 86400 | todate)))
  | "\(.lastState.terminated.finishedAt)  \($ns)/\($p) [\(.name)] exit=\(.lastState.terminated.exitCode)"' | sort

# 2. When did the kubelet kill the API server, per hour, on every control plane node?
for h in 10.240.0.21 10.240.0.31 10.240.0.32; do   # the control plane nodes (doc 13)
  ssh "$ANSIBLE_USER@$h" "sudo journalctl -u kubelet --since '-4 days' --no-pager | grep -E 'Killing container.*kube-apiserver' | awk '{print \$1, \$2, substr(\$3,1,2)\":00\"}' | uniq -c"
done

# 3. Was etcd slow? (etcd runs as a systemd service on the control plane nodes)
ssh "$ANSIBLE_USER@10.240.0.21" "sudo journalctl -u etcd --since '-1 day' --no-pager | grep -c -E 'slow fdatasync|took too long'"
```

What it showed:

- Between 20:00 and 20:09 the three `kube-apiserver` were killed (`exit=137`, failed liveness probe), then `kube-controller-manager`, `kube-scheduler`, the Longhorn CSI sidecars, cert-manager, MetalLB, calico and the `leader-elector` of the LDAP server restarted (`exit=1`, API not reachable).
- The kubelet killed the API servers only between 20:00 and 22:00, every night.
- etcd logged about 2000 warnings per node in that hour: `slow fdatasync` up to 4 seconds (expected: below 1 second), then `lost leader` and `no leader`. All three members were slow at the same time, so etcd had no quorum.

### 7.2 Root cause

The disks of all Kubernetes VMs, the control plane nodes included, are on one shared NFS storage with hard disks. One backup job with node "all" started at 20:00 on all three Proxmox hosts at once, and a second job for other VMs started at the same time. Four backups read from the same storage, and every VM on it waited for its writes. etcd was slow already at 20:00:08, while its own node was not yet being backed up: the shared storage was the bottleneck, not the backup of a single VM.

The night after the kernel update of all nodes ([10](10-node-schedulingdisabled.md)) was the worst: a restart of a VM clears the dirty bitmap of the incremental backup, so the next backup reads the whole disk (120 GB per VM) and runs for hours.

### 7.3 Fix

In Proxmox, Datacenter → Backup:

| Job | VMs | Start (UTC) |
|---|---|---|
| Kubernetes-1 | VMs on the first host, with the first control plane node | 20:00 |
| Kubernetes-2 | VMs on the second host, with the second control plane node | 20:20 |
| Kubernetes-3 | VMs on the third host, with the third control plane node | 20:40 |
| Other VMs | everything else on the same storage | 21:00 |

- Only one backup reads from the storage at a time, and only one etcd member is under load: the other two keep the quorum.
- Bandwidth limit 40 MiB/s per job (Advanced). An incremental backup still takes only a few minutes per host.
- Create the new jobs first, then remove their VMs from the old job, so that no VM is without a backup. Set the same retention as before: a new job shows `Fallback from storage config`, which may prune differently.

**Verify the next morning:** step 1 of 7.1 lists no restart of the control plane, and etcd logs (almost) no `slow fdatasync`. After a restart of the VMs the first backup reads the whole disks again and the jobs can overlap: watch that night.

### 7.4 Follow-up on 23.11.2026: one job still without a limit

After 7.3 the API servers stayed up. But the restart counters of `kube-controller-manager` and `kube-scheduler` still grew every night (exit 1), and the `leader-elector` of the LDAP server restarted too. Step 1 of 7.1 showed the last restarts at 21:02 – 21:05 UTC, one hour after the Kubernetes jobs.

The etcd warnings per hour on every control plane node:

```bash
for h in 10.240.0.21 10.240.0.31 10.240.0.32; do   # the control plane nodes (doc 13)
  echo "== $h"
  ssh "$ANSIBLE_USER@$h" "sudo journalctl -u etcd --since '-3 days' --no-pager | grep -E 'slow fdatasync|took too long|lost leader|no leader' | awk '{print \$1, \$2, substr(\$3,1,2)\":00\"}' | uniq -c"
done
```

The first two nodes only logged warnings at 20:00 UTC (27 – 122 per hour, during the Kubernetes jobs, without restarts). The third node logged 1138, 1840 and 1331 warnings at 21:00 UTC in three nights: the hour of the job for the other VMs.

**Cause.** The job for the other VMs runs on the third host and had no bandwidth limit. It read as fast as the host could, and every VM on that host waited for its disks, the third control plane node too. One slow member does not cost etcd its quorum, so the API servers stayed up. But the controller manager and the scheduler must renew their leader lease every few seconds. When that takes too long, they stop on purpose (exit 1) and the kubelet starts them again.

**Fix.** The same limit for that job: Datacenter → Backup → the job → Advanced → Bandwidth limit 40 MiB/s. Check all jobs on one Proxmox host (the file is the same on every host of the cluster):

```bash
grep -E '^vzdump:|^\s+(comment|schedule|bwlimit)' /etc/pve/jobs.cfg
```

✔ **Expected:** every job that backs up VMs on the same storage has `bwlimit 40960` (KiB/s).

**Result the next night:** no restart of the control plane or of the LDAP `leader-elector`. The third node logged 117 etcd warnings at 21:00 UTC instead of more than 1100, and the daily check passed.

**Lesson:** the bandwidth limit belongs on every backup job that reads from the same storage, not only on the jobs of the cluster.

Longer term, etcd and Longhorn need fast disks (SSD). Shared hard disks are enough for a lab, not for a few hundred users.

---

Previous: [13 – Three control plane nodes](13-three-control-plane-nodes.md) · Next: [15 – openDesk settings per release](15-opendesk-customization.md) · Back to the [overview](../README.md)
