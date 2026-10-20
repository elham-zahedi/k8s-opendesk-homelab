# 02 – Kubernetes cluster with Kubespray

Scripts for [docs/02 – Kubernetes cluster with Kubespray](../../docs/02-kubernetes-cluster-kubespray.md).
The nodes are defined once in `lab.env` (`NODES`, one line per node: `name:vmid:ip:role`); every script reads them from there.

## Order

| Step | Script | Run on | What it does | Changes something? |
|---|---|---|---|---|
| 1 | `clone-nodes.sh` | Proxmox host (root) | Full clones of template 9000, static IP per node, start | Yes – refuses if a VM ID is in use |
| 2 | `check-nodes.sh [--reboot]` | kubespray VM (k8s) | Waits for SSH and cloud-init, checks hostname, IP, MTU 1450, passwordless sudo; with `--reboot` reboots nodes that need it | Only with `--reboot` |
| 3 | `install-kubespray.sh` | kubespray VM | git, venv, Kubespray v2.32.0 with its Ansible requirements | Only what is missing |
| 4 | `prepare-inventory.sh [--force]` | kubespray VM | `inventory.ini` from `NODES`, Calico MTU 1400, metrics-server, Helm, kubectl/kubeconfig to `artifacts/` | Yes – never overwrites a different inventory without `--force` |
| 5 | `prepare-nodes.sh` | kubespray VM | Runs [`prepare-nodes.yml`](prepare-nodes.yml): `/etc/hosts` block (also in the cloud-init template), chrony, time sync and swap checks | Yes – `--dry-run` = Ansible check mode |
| 6 | `install-cluster.sh` | kubespray VM, in tmux | `cluster.yml` with a log file, checks the PLAY RECAP (`failed=0`, `unreachable=0`) | Yes (25–45 min) |
| 7 | `setup-kubectl.sh [--force]` | kubespray VM | kubectl binary and `~/.kube/config` from `artifacts/` | Yes – keeps a backup |
| 8 | `verify-cluster.sh` | kubespray VM | Acceptance tests from section 8 (see below) | Only a temporary namespace |
| – | `reboot-test.sh` | kubespray VM | Reboots **all** nodes at once and checks the recovery | Yes – downtime! |

## Getting the scripts onto the kubespray VM

```bash
git clone https://github.com/elham-zahedi/k8s-opendesk-homelab.git
cd k8s-opendesk-homelab/automation
chmod +x */*.sh                 # files uploaded via the GitHub web UI are not executable
cp lab.env.example lab.env      # adjust NODES and the other values
```

The Ansible key must be in `~/.ssh/id_ed25519` on the kubespray VM (doc 02, section 3.1).

## verify-cluster.sh

Read-only checks plus functional tests in the namespace `acceptance-test`, which is deleted at the end:

- every node from `NODES` is `Ready`, all kube-system pods are `Running`
- API server `readyz`, etcd `endpoint health`, `kubectl top nodes`
- nginx deployment with one replica per worker, exposed as NodePort
- DNS (`web.acceptance-test.svc.cluster.local`), service by name
- pod-to-pod from the first worker to every nginx pod, plus a ping with 1372 bytes (MTU 1400)
- NodePort answers on every node, including the control plane

## Testing on a running cluster

All of these are safe on the existing lab:

```bash
./02-kubespray/check-nodes.sh                       # read-only
./02-kubespray/install-kubespray.sh                 # finds the existing installation
INVENTORY_NAME=autotest ./02-kubespray/prepare-inventory.sh
diff ~/kubespray/inventory/autotest/inventory.ini ~/kubespray/inventory/mycluster/inventory.ini
./02-kubespray/prepare-nodes.sh --dry-run           # check mode: expect changed=0
./02-kubespray/setup-kubectl.sh                     # expect "already up to date"
./02-kubespray/verify-cluster.sh
./02-kubespray/install-cluster.sh --dry-run
rm -rf ~/kubespray/inventory/autotest
```

A complete test run from an empty VM is possible with a single extra node that is control plane and worker at the same time:

```bash
NODES="k8s-test:299:10.240.0.29:both" ./02-kubespray/clone-nodes.sh          # on the Proxmox host
export NODES="k8s-test:299:10.240.0.29:both" INVENTORY_NAME=test1 KUBECONFIG_PATH=~/.kube/test1
./02-kubespray/check-nodes.sh --reboot && ./02-kubespray/prepare-inventory.sh \
  && ./02-kubespray/prepare-nodes.sh && ./02-kubespray/install-cluster.sh \
  && ./02-kubespray/setup-kubectl.sh && ./02-kubespray/verify-cluster.sh       # on the kubespray VM
```
