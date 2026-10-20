# 06 – Adding a worker node

Scripts for [docs/06 – Adding a worker node](../../docs/06-add-worker-node.md).
A new worker is one more line in `NODES` (section "02" of `lab.env`), e.g. `node7:208:10.240.0.28:worker`. Everything else – template, network, Kubespray version – comes from the settings of the installation.

**Run on:** kubespray VM as k8s – `create-worker-vm.sh` on the Proxmox host as root.

## Order

| Step | Script | Run on | What it does | Changes something? |
|---|---|---|---|---|
| 1 | `precheck-worker.sh NAME` | kubespray | Entry in `NODES`, address free (no ping answer), not yet in the cluster or the inventory, all nodes `Ready`, no failed pods, same Kubespray version | No |
| 2 | `create-worker-vm.sh NAME` | Proxmox host | Template, free VM ID, enough RAM and storage for one more VM of the template's size, vCPUs of the running VMs; then clones and starts **only this VM** with `02-kubespray/clone-nodes.sh` | Yes – one new VM |
| 3 | `add-worker.sh NAME` (in tmux) | kubespray | SSH and cloud-init, reboot after the first boot; etcd snapshot and copy of the inventory; inventory line under `[kube_node]`; `/etc/hosts` block on all nodes and in the cloud-init template, chrony, Longhorn prerequisites and `nls_utf8` on the new node; `facts.yml` for **all** nodes; `scale.yml --limit=NAME` | Yes |
| 4 | `verify-worker.sh NAME` | kubespray | Node `Ready` with the same kubelet version, every DaemonSet of another worker also runs here, Longhorn `READY` and `SCHEDULABLE`, on the node: `nls_utf8`, MTU and ping with DF bit, nginx-proxy, kubelet → `localhost:6443`, iSCSI, multipathd off, time, names; test pod with a Longhorn volume pinned to the node, DNS for the cluster, openDesk and AD | No (test namespace `worker-test`, deleted at the end) |

```bash
# kubespray VM
./06-add-worker/precheck-worker.sh node7
# Proxmox host (root)
./06-add-worker/create-worker-vm.sh node7 --dry-run
./06-add-worker/create-worker-vm.sh node7
# kubespray VM, in tmux
tmux new -s scale
./06-add-worker/add-worker.sh node7 --dry-run       # node preparation in Ansible check mode
./06-add-worker/add-worker.sh node7
./06-add-worker/verify-worker.sh node7
```

## Why these steps

- **`facts.yml` without a limit.** With `--limit`, Ansible does not connect to the control plane; its data (e.g. the address for nginx-proxy) then only comes from the fact cache, which is valid for 24 hours. An incomplete cache made the first `scale.yml` fail with `has no attribute 'main_access_ip'` (doc 06, section 5). `add-worker.sh` checks the cache before it starts `scale.yml`.
- **`/etc/hosts` on all nodes.** Kubespray no longer writes the nodes to `/etc/hosts`, and cloud-init rewrites the file on every boot, so the block also goes into the cloud-init template.
- **Same Kubespray version and group_vars** as at the installation – otherwise the new node gets different settings. `add-worker.sh` stops if the version differs.
- **`nls_utf8` for the running kernel.** The new node installs updates on the first boot and usually runs a newer kernel than the others.
- **Only workers.** Control plane and etcd nodes are added with `cluster.yml` without a limit (doc 06, section 8).

## Testing on a running lab

`add-worker.sh` on a node that is already in the cluster only previews with `--dry-run` and otherwise stops with "nothing to do".

```bash
./06-add-worker/precheck-worker.sh node7:208:10.240.0.28:worker   # node that does not exist (no change to lab.env)
./06-add-worker/add-worker.sh node6 --dry-run                     # existing worker: preview, check mode
./06-add-worker/verify-worker.sh node6                            # any existing worker
```

## Not automated

- A `Host NAME` entry in `~/.ssh/config` on the jump host, if you want to log in to the node by name.
