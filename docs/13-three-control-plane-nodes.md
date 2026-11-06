# 13 – Three Control Plane Nodes

> Part 13 of the series. Previous: [12 – Worker node failure and replacement](12-node-failure-replace-worker.md) · Next: [14 – I/O errors after the nightly backup](14-backup-freeze-io-error.md) · Back to the [overview](../README.md)

**Summary:** A second installation of this setup ran with one control plane node, and all its VMs were on one Proxmox host. On 30.10.2026 the workers were spread over three Proxmox hosts with live migration; on 02.11.2026 two more control plane and etcd nodes were added to the running cluster with Kubespray. A failover test followed: the first control plane node was shut down, etcd chose a new leader, all workers stayed `Ready` and openDesk kept running. The whole work happened during working hours without an interruption for the users.

The values below are the neutral names and addresses of this documentation. Scripts and a short version: [`automation/07-control-plane`](../automation/07-control-plane/).

## 1. Why three, and why not two

etcd, the database of the cluster, only works while **more than half** of its members are reachable:

| Control plane nodes | May fail | What happens when one fails |
|---|---|---|
| 1 | 0 | The cluster cannot be managed: no rollouts, no rescheduling, no `kubectl`. Running pods keep running |
| 2 | 0 | 1 of 2 is not more than half – etcd stops. Worse than one node |
| 3 | 1 | 2 of 3 – everything keeps working |

Three control plane nodes only help if they are on **three different Proxmox hosts**. The first step therefore was to spread the VMs.

## 2. Starting point and spreading the VMs

**Run on:** server1 as root

```bash
pvesh get /cluster/resources --type vm --output-format json | perl -MJSON -e 'for (sort { $a->{vmid} <=> $b->{vmid} } grep { $_->{name} =~ /^(kubespray|master\d*|node\d+)$/ && !$_->{template} } @{decode_json(join "", <STDIN>)}) { printf "%-5s %-10s %-8s %s\n", $_->{vmid}, $_->{name}, $_->{node}, $_->{status} }'
pvesh get /cluster/resources --type node --output-format json | perl -MJSON -e 'for (@{decode_json(join "", <STDIN>)}) { printf "%-8s %2d CPU  RAM %3d of %3d GB\n", $_->{node}, $_->{maxcpu}, $_->{mem}/1024**3, $_->{maxmem}/1024**3 }'
```

Result: all eight VMs (kubespray, master, node1–node6) ran on server1, the host with the fewest CPU cores; server2 and server3 were nearly empty. A failure of server1 would have stopped the whole cluster, with one or with three control plane nodes.

**Before a live migration,** four things were checked:

| Check | Command | Expected |
|---|---|---|
| VM disks on shared storage | `grep -A6 '^lvm: vm-storage' /etc/pve/storage.cfg` | `shared 1` – only the RAM is copied |
| CPU type of every VM | `grep -E '^(cpu\|ide2\|scsi0\|hostpci\|usb)' /etc/pve/nodes/*/qemu-server/204.conf` | `cpu: x86-64-v3` ([01](01-proxmox-cloud-init-template.md), section 4.7); disks and cloud-init drive on `vm-storage`; no `hostpci`, no `usb` |
| No HA rule that pulls the VMs back | `ha-manager status`, `cat /etc/pve/ha/resources.cfg` | no resources |
| Capacity on the target hosts | see above | enough RAM and CPU |

Then one VM at a time, with a check after each:

```bash
qm migrate 204 server2 --online          # node3
# on the kubespray VM: all nodes Ready, all Longhorn volumes healthy
kubectl get nodes
kubectl -n longhorn-system get volumes.longhorn.io
```

```
2026-10-30 12:55:27 average migration speed: 111.5 MiB/s - downtime 23 ms
2026-10-30 12:55:30 migration finished successfully (duration 00:02:34)
```

| Proxmox host | Before | After |
|---|---|---|
| server1 | kubespray, master, node1 – node6 | kubespray, master, node1, node2 |
| server2 | – | node3, node4 (later master2) |
| server3 | – | node5, node6 (later master3) |

With two workers per host, the three replicas of every Longhorn volume are always on at least two hosts.

> **Important:** Proxmox does not keep this placement by itself. After maintenance of a host, move the VMs back – the first command of this section shows the host of every VM. Two control plane nodes must never be on the same host.

## 3. Creating the new VMs

| VM | Name | IP | Proxmox host |
|---|---|---|---|
| 211 | master2 | 10.240.0.31 | server2 |
| 212 | master3 | 10.240.0.32 | server3 |

The addresses must be free and outside every DHCP range. A ping only finds devices that are switched on, so the DHCP server was checked as well (`Get-DhcpServerv4Scope` on the DC): the server network has no DHCP range.

**Run on:** server1 as root (the template is there). This run used the `qm` commands of `clone-nodes.sh` by hand:

```bash
qm clone 9000 211 --name master2 --full --storage vm-storage
qm set 211 --ipconfig0 ip=10.240.0.31/24,gw=10.240.0.1 --onboot 1 --startup order=1,up=60
qm migrate 211 server2                       # stopped: takes one second
pvesh create /nodes/server2/qemu/211/status/start
```

The same for master3 on server3. A full clone of the 120 GB disk took about 25 minutes. With the script, both at once: `NODES_ONLY="master2:211:10.240.0.31:control master3:212:10.240.0.32:control" ./02-kubespray/clone-nodes.sh`, then `qm migrate … --online`.

## 4. Preparing the new nodes

**Run on:** kubespray VM as k8s

```bash
cd ~/k8s-opendesk-homelab/automation
NODES_ONLY="master2:211:10.240.0.31:control master3:212:10.240.0.32:control" ./02-kubespray/check-nodes.sh --reboot
```

✔ **Expected:** for both nodes SSH, hostname, IP, MTU, sudo – `All 10 checks passed` (or 12 with the reboot after the first boot).

Then the two nodes go into `NODES` of `lab.env`, **directly below the first control plane node** – Kubespray only supports new control plane nodes at the end of `[kube_control_plane]`:

```
master:201:10.240.0.21:control
master2:211:10.240.0.31:control
master3:212:10.240.0.32:control
node1:202:10.240.0.22:worker
…
```

```bash
./02-kubespray/prepare-inventory.sh            # preview: stops with "differs" and shows the diff
./02-kubespray/prepare-inventory.sh --force    # writes it, keeps a backup
./02-kubespray/prepare-nodes.sh --dry-run      # /etc/hosts block on all nodes
./02-kubespray/prepare-nodes.sh
bash -c 'source lib/common.sh; load_env; use_kubespray; for pb in 03-opendesk/prepare-nodes-storage.yml 04-identity/prepare-nodes-smb.yml; do ansible-playbook -i "$INV" "$AUTOMATION_DIR/$pb" --limit master2,master3 || exit 1; done'
```

✔ **Expected:** the diff only adds `master2 …` and `master3 …` under `[kube_control_plane]`; in every PLAY RECAP `unreachable=0 failed=0`. The new nodes get the same packages as the first control plane node, so the daily check stays the same on all nine.

Until section 6 the daily check reports "7 nodes in the cluster, 9 in NODES" – expected.

## 5. Backups before the change

```bash
./ops/etcd-backup.sh vor-c1-$(date +%H%M)                     # kubespray VM
vzdump 201 104 --storage pbs-backup --mode snapshot          # server1: first control plane node and kubespray VM
```

The Proxmox backup was incremental: 95 % of the data was reused from the night before.

## 6. etcd and control plane on the new nodes

**Run on:** kubespray VM as k8s, in tmux (`tmux new -s master`; after a lost connection `tmux attach -t master`)

The Kubespray guide (`docs/operations/nodes.md`, v2.32.0, "Adding an etcd node" and "Adding/replacing a control plane node") was read in the installed version first:

```bash
sed -n '28,52p;126,147p' ~/kubespray/docs/operations/nodes.md
```

```bash
cd ~/kubespray
ansible-playbook -i inventory/mycluster/inventory.ini -b playbooks/facts.yml 2>&1 | grep -A10 'PLAY RECAP'
ansible-playbook -i inventory/mycluster/inventory.ini -b cluster.yml --limit=etcd,kube_control_plane \
  -e '{"ignore_assert_errors": true}' -e etcd_retries=10 2>&1 | tee ~/c1-cluster-$(date +%Y%m%d-%H%M).log
```

- `facts.yml` without a limit: Kubespray needs the data of all nine nodes, also of those it does not touch ([06](06-add-worker-node.md), section 5).
- `--limit=etcd,kube_control_plane`: only the three control plane nodes change. The workers and the openDesk pods are not touched.
- `etcd_retries=10`: more waiting between the joins of two etcd members, as the guide recommends for several at once.

Result after 15 minutes: `failed=0` on all three, `master2` and `master3` `Ready` with the role `control-plane`. etcd:

```
| ID               | STATUS  | NAME  | PEER ADDRS               |
| 8e9e05c52164694d | started | etcd1 | https://10.240.0.21:2380 |
| 91bc3c398fb3c146 | started | etcd2 | https://10.240.0.31:2380 |
| fd422379fda50e48 | started | etcd3 | https://10.240.0.32:2380 |
```

All three `HEALTH true`, the same `RAFT INDEX` on all three. But the API servers (today step 3/5 of `./07-control-plane/verify-control-plane.sh`):

```bash
for ip in 10.240.0.21 10.240.0.31 10.240.0.32; do echo "== $ip"; ssh k8s@$ip "sudo grep -o -- '--etcd-servers=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml"; done
```

```
== 10.240.0.21
--etcd-servers=https://10.240.0.21:2379
== 10.240.0.31
--etcd-servers=https://10.240.0.21:2379
== 10.240.0.32
--etcd-servers=https://10.240.0.21:2379
```

Every API server still only knew the first etcd member (error F3). Without a fix, a failure of the first node would have stopped all three API servers. The second playbook of the guide writes the configuration again:

```bash
ansible-playbook -i inventory/mycluster/inventory.ini -b upgrade-cluster.yml --limit=etcd,kube_control_plane \
  -e '{"ignore_assert_errors": true}' 2>&1 | tee ~/c1-upgrade-$(date +%Y%m%d-%H%M).log
```

The versions stay the same. The control plane nodes are drained one by one (only DaemonSets run there, so nothing moves) and come back. Result after 20 minutes: `failed=0`, every API server has `--etcd-servers` with all three members, no node `SchedulingDisabled`.

## 7. The workers learn the new API servers

Every worker reaches the API through a local proxy (`nginx-proxy`, `localhost:6443`). Its configuration still listed only the first node:

```bash
ssh k8s@10.240.0.22 "sudo grep -A4 'upstream kube_apiserver' /etc/nginx/nginx.conf"
```

```
  upstream kube_apiserver {
    least_conn;
    server 10.240.0.21:6443;
    }
```

```bash
cd ~/kubespray
ansible-playbook -i inventory/mycluster/inventory.ini -b playbooks/facts.yml 2>&1 | grep -A10 'PLAY RECAP'
ansible-playbook -i inventory/mycluster/inventory.ini -b cluster.yml --limit=kube_node 2>&1 | tee ~/c2-cluster-$(date +%Y%m%d-%H%M).log
```

Result: `failed=0` on all six workers, each lists `10.240.0.21`, `.31` and `.32`. nginx only reads the file at the start, so the proxy is restarted on one worker after the other – the kubelet starts it again within seconds, the pods are not affected:

```bash
for ip in 10.240.0.22 10.240.0.23 10.240.0.24 10.240.0.25 10.240.0.26 10.240.0.27; do
  echo "== $ip"
  ssh k8s@$ip "sudo crictl ps --name nginx-proxy -q | xargs -r sudo crictl stop" >/dev/null
  sleep 20
  ssh k8s@$ip "sudo crictl ps --name nginx-proxy | tail -1"
done
kubectl get nodes
```

## 8. Reboots of the new nodes

The daily check reported `reboot pending on: master2 master3` (updates from the first boot). One at a time:

```bash
kubectl drain master2 --ignore-daemonsets --delete-emptydir-data --dry-run=server --timeout=60s   # only DaemonSets
kubectl drain master2 --ignore-daemonsets --delete-emptydir-data --timeout=5m
ssh k8s@10.240.0.31 'sudo systemctl reboot'
kubectl wait --for=condition=Ready node/master2 --timeout=10m
kubectl uncordon master2
```

While master2 was down, etcd showed `10.240.0.31 false` and the two others `true`, `kubectl` and all workers kept working. `etcdctl` ends such a table with `Error: unhealthy cluster` – that only means "not every member is healthy"; with two of three, etcd works normally.

## 9. Failover test: the first control plane node switched off

```bash
kubectl drain master --ignore-daemonsets --delete-emptydir-data --timeout=5m   # kubespray VM
qm shutdown 201                                                                 # server1
```

After one minute, through another API server:

```bash
kubectl --server=https://10.240.0.31:6443 get nodes
```

```
NAME      STATUS                        ROLES           AGE
master    NotReady,SchedulingDisabled   control-plane   10d
master2   Ready                         control-plane   68m
master3   Ready                         control-plane   68m
node1     Ready                         worker          10d
…
node6     Ready                         worker          10d
```

etcd chose a new leader (master2, `RAFT TERM` 11 → 12), both remaining members had the same `RAFT INDEX`. openDesk answered with the usual codes (portal 301, files 302, webmail 302) and worked in the browser without an interruption.

`kubectl` without `--server` does not answer during this time: the kubeconfig on the kubespray VM points to the first control plane node.

```bash
qm start 201                                                                    # server1
kubectl --server=https://10.240.0.31:6443 wait --for=condition=Ready node/master --timeout=10m
kubectl uncordon master
```

Right after the start, the daily check reported `calico-node … NotReady master` once; one minute later all nine `calico-node` pods were `1/1 Running`. Calico needs a short time after a boot to build its connections to the other nodes.

## 10. Afterwards

- **Role label of the workers.** Kubernetes only labels the control plane; the workers showed `<none>` under ROLES. Set once with `kubectl label nodes -l '!node-role.kubernetes.io/control-plane' node-role.kubernetes.io/worker=`. `setup-kubectl.sh` and `add-worker.sh` set it since then.
- **Proxmox backup job.** The two new VMs were added to the nightly job. The old job had `--node server1`: VMs that had been moved to another host were silently left out (the newest backup of three workers was almost two weeks old, one worker had never had one). The job now runs on all hosts.
- **Daily check and update guide.** `daily-check.sh` checks every etcd member and the nginx-proxy of every worker. Control plane nodes are restarted one at a time, never two together.
- **kubectl** keeps talking to the first control plane node. While it is down: `kubectl --server=https://10.240.0.31:6443 …`.

## 11. Errors and pitfalls

| # | Problem / message | Cause | Solution |
|---|---|---|---|
| F1 | `NODES="…" ./02-kubespray/check-nodes.sh` checked the seven old nodes instead of the two new ones | `lab.env` of this installation sets `NODES="…"` directly, not as `${NODES:-…}`, so it overwrites the value from the command line | `NODES_ONLY="…"` (since this change) or a temporary env file: `LAB_ENV=file`, which sources `lab.env` and then sets `NODES` |
| F2 | master2: `No route to host`, `Destination Host Unreachable` | `ipconfig0: ip=dhcp` – the `qm set … --ipconfig0` line had not been run; there is no DHCP in the server network | `pvesh set /nodes/server2/qemu/211/config --ipconfig0 "ip=10.240.0.31/24,gw=10.240.0.1"`, then stop and start the VM (a reboot inside the VM does not rebuild the cloud-init drive) |
| F3 | After `cluster.yml`, `--etcd-servers` of all three API servers only lists the first etcd member | The new nodes join with the kubeadm configuration of the first one, which knew one member | `upgrade-cluster.yml --limit=etcd,kube_control_plane` (section 6) |
| F4 | The nginx-proxy of the workers only lists the first node | `cluster.yml` with the control plane limit does not touch the workers | `cluster.yml --limit=kube_node`, then restart nginx-proxy on every worker (section 7) |
| F5 | Proxmox backups of the moved workers missing | Backup job with `--node server1` | Backup job for all hosts (section 10) |

**Not errors:**

| Observation | Meaning |
|---|---|
| `Error: unhealthy cluster` while one member is down | Not every member answers; etcd works with two of three |
| `kube-controller-manager-master` and `kube-scheduler-master` with new restarts | Their API server restarted during `upgrade-cluster.yml` |
| `calico-node` on a node that just started `NotReady` for about a minute | Calico builds its connections |
| etcd leader stays on master2 after the first node is back | Normal – any member can be the leader |

## 12. Checklist

1. All VMs of the cluster on at least three Proxmox hosts, two control plane nodes never on the same host; shared storage, CPU type `x86-64-v3`.
2. Free addresses outside every DHCP range; new VMs from the template, each on its own host, `check-nodes.sh` green.
3. New lines in `NODES` below the first control plane node; inventory preview, then `--force`; node preparation.
4. etcd snapshot and Proxmox backup of the first control plane node.
5. In tmux: `facts.yml`, `cluster.yml --limit=etcd,kube_control_plane`, check etcd.
6. `upgrade-cluster.yml --limit=etcd,kube_control_plane`, check `--etcd-servers` on every node.
7. `cluster.yml --limit=kube_node`, restart nginx-proxy on every worker.
8. Reboots one at a time, failover test with the first control plane node.
9. `./07-control-plane/verify-control-plane.sh` and `./ops/daily-check.sh` green; new VMs in the backup job.

---

Previous: [12 – Worker node failure and replacement](12-node-failure-replace-worker.md) · Next: [14 – I/O errors after the nightly backup](14-backup-freeze-io-error.md) · Back to the [overview](../README.md)
