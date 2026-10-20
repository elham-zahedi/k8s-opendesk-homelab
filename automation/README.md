# Automation

Scripts that rebuild the homelab step by step. Each folder belongs to one document in [`docs/`](../docs/): the document explains **why** something is done, the scripts **do** it – without copying commands by hand.

## Quick start

```bash
git clone https://github.com/elham-zahedi/k8s-opendesk-homelab.git
cd k8s-opendesk-homelab/automation
chmod +x */*.sh                   # files uploaded via the GitHub web UI are not executable
cp lab.env.example lab.env        # adjust names, IP addresses and versions

./01-proxmox/create-template.sh --dry-run   # preview: prints every command, changes nothing
./01-proxmox/create-template.sh
./01-proxmox/verify-template.sh
```

## Order

| # | Folder | Run on | Scripts | Document | Status |
|---|---|---|---|---|---|
| 01 | [`01-proxmox`](01-proxmox/) | Proxmox host (root) | `create-template.sh`, `verify-template.sh` | [01 – Proxmox cloud-init template](../docs/01-proxmox-cloud-init-template.md) | ✔ Tested 20.10.2026 |
| 02 | [`02-kubespray`](02-kubespray/) | Proxmox host, then kubespray VM (k8s) | `clone-nodes.sh`, `check-nodes.sh`, `install-kubespray.sh`, `prepare-inventory.sh`, `prepare-nodes.sh`, `install-cluster.sh`, `setup-kubectl.sh`, `verify-cluster.sh`, `reboot-test.sh` | [02 – Kubernetes cluster with Kubespray](../docs/02-kubernetes-cluster-kubespray.md) | ✔ Tested 20.10.2026 on the running cluster¹ |

¹ `check-nodes`, `install-kubespray`, `prepare-inventory`, `prepare-nodes` (check mode: `changed=0` on all 7 nodes), `setup-kubectl` and `verify-cluster` (34/34 checks) were run against the live cluster. `clone-nodes`, `install-cluster` and `reboot-test` change or interrupt a running lab and were only run with `--dry-run` there.

The remaining sections (openDesk, identity, OX App Suite, adding a worker, daily checks) are being added one by one.

## Conventions

- **One settings file.** All names, addresses and versions live in `lab.env` (created from [`lab.env.example`](lab.env.example), ignored by git). Any value can be overridden for a single run: `TEMPLATE_ID=9001 ./01-proxmox/create-template.sh`.
- **No secrets in the repository.** Passwords are asked for at runtime (hidden input) or read from an environment variable, e.g. `CI_PASSWORD`.
- **Preview first.** Every script supports `--dry-run` (print the commands only) and `--help`.
- **Fail early, never overwrite.** Scripts stop at the first error (`set -euo pipefail`) and refuse to replace existing resources.
- **Verify afterwards.** `verify-*.sh` scripts are read-only and compare the result with the expected state from the documentation.
- Shared helpers are in [`lib/common.sh`](lib/common.sh). All scripts pass [ShellCheck](https://www.shellcheck.net/).
