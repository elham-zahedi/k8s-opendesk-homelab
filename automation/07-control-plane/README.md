# 07 – Three control plane nodes

Steps and check for [docs/13 – Three control plane nodes](../../docs/13-three-control-plane-nodes.md).

Adding control plane nodes changes etcd, the database of the whole cluster. There is deliberately **no script that runs the playbooks**: every step is started by hand, and `verify-control-plane.sh` shows after each step what is still missing.

**Run on:** Proxmox host as root (steps 1–2), everything else on the kubespray VM as k8s, the playbooks inside tmux.

## Order

| Step | Run on | What | Changes something? |
|---|---|---|---|
| 1 | Proxmox | Spread the existing VMs over the Proxmox hosts, one at a time: `qm migrate VMID HOST --online`. Two workers per host, the first control plane node stays | Yes – no interruption (23 ms pause per VM) |
| 2 | Proxmox | Clone the new control plane VMs with `NODES_ONLY="…" ./02-kubespray/clone-nodes.sh`, then move each to its own host | Yes – new VMs, not in the cluster yet |
| 3 | kubespray | `NODES_ONLY="…" ./02-kubespray/check-nodes.sh --reboot` – SSH, hostname, IP, MTU, sudo, reboot after the first boot | Only the new VMs |
| 4 | kubespray | New lines in `NODES` of `lab.env` directly below the first control plane node; `./02-kubespray/prepare-inventory.sh` (preview), then `--force` | Inventory (a backup is kept) |
| 5 | kubespray | `./02-kubespray/prepare-nodes.sh --dry-run`, then without; Longhorn and SMB preparation `--limit` the new nodes | `/etc/hosts` on all nodes, packages on the new ones |
| 6 | kubespray | `./ops/etcd-backup.sh`, `facts.yml` for all nodes, `cluster.yml --limit=etcd,kube_control_plane` | **Yes – etcd gets the new members** |
| 7 | kubespray | `upgrade-cluster.yml --limit=etcd,kube_control_plane` | Yes – every API server learns all etcd members |
| 8 | kubespray | `cluster.yml --limit=kube_node`, then restart nginx-proxy on every worker | Yes – the workers learn the new API servers |
| 9 | both | Reboot the new nodes one at a time if needed; failover test: shut down the first control plane node | Yes |
| 10 | kubespray | `./07-control-plane/verify-control-plane.sh`, `./ops/daily-check.sh` | No |

```bash
# kubespray VM, the values of doc 13
NEW="master2:211:10.240.0.31:control master3:212:10.240.0.32:control"
NODES_ONLY="$NEW" ./02-kubespray/check-nodes.sh --reboot

tmux new -s master
cd ~/kubespray
ansible-playbook -i inventory/mycluster/inventory.ini -b playbooks/facts.yml
ansible-playbook -i inventory/mycluster/inventory.ini -b cluster.yml \
  --limit=etcd,kube_control_plane -e '{"ignore_assert_errors": true}' -e etcd_retries=10
ansible-playbook -i inventory/mycluster/inventory.ini -b upgrade-cluster.yml \
  --limit=etcd,kube_control_plane -e '{"ignore_assert_errors": true}'
ansible-playbook -i inventory/mycluster/inventory.ini -b cluster.yml --limit=kube_node
cd ~/k8s-opendesk-homelab/automation
./07-control-plane/verify-control-plane.sh
```

## verify-control-plane.sh

Read-only, about 20 seconds:

1. Every control plane node from `NODES` is `Ready`, has the role `control-plane` and is not cordoned. An even number is reported: with two, one failure already stops etcd.
2. etcd: every member healthy, as many members as control plane nodes, a leader. It asks through the first node that answers, so it also works while one is down.
3. `--etcd-servers` of every `kube-apiserver` lists all members – after step 6 it only lists the first one; step 7 fixes that.
4. `kube-apiserver`, `kube-controller-manager` and `kube-scheduler` ready on every control plane node.
5. The nginx-proxy of every worker lists all control plane nodes and was restarted after its configuration changed.

`kubectl` on the kubespray VM talks to the API server in its kubeconfig. While that node is down:

```bash
KUBECTL_SERVER=https://10.240.0.31:6443 ./07-control-plane/verify-control-plane.sh
kubectl --server=https://10.240.0.31:6443 get nodes
```

`daily-check.sh` checks the etcd members and the nginx-proxy of the workers every morning.

## Why these steps

- **Spread first.** Three control plane nodes on one Proxmox host only protect against a broken VM, not against a broken host.
- **`--limit=etcd,kube_control_plane`** follows "Adding an etcd node" in the Kubespray guide (`docs/operations/nodes.md`, v2.32.0). The workers are not touched in step 6 and 7.
- **`upgrade-cluster.yml`** writes the kubeadm configuration again. The new nodes joined with the configuration of the first one, which knew only one etcd member; without this step every API server still depends on the first node.
- **nginx-proxy restart** – Kubespray writes the new configuration, but nginx only reads it at the start.
- **Never two control plane nodes down at the same time.** With three, etcd needs two.
