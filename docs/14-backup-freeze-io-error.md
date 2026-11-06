# 14 – I/O Errors after the Nightly Backup

> Troubleshooting runbook. Previous: [13 – Three control plane nodes](13-three-control-plane-nodes.md) · Back to the [overview](../README.md)

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

---

Previous: [13 – Three control plane nodes](13-three-control-plane-nodes.md) · Back to the [overview](../README.md)
