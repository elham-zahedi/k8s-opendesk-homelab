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
| 03 | [`03-opendesk`](03-opendesk/) | kubespray VM (k8s) | `install-tools.sh`, `configure-cluster-dns.sh`, `fix-strictarp.sh`, `verify-dns.sh`, `prepare-nodes-storage.sh`, `install-platform.sh`, `split-dns.sh`, `smoke-test.sh`, `prepare-opendesk.sh`, `deploy-opendesk.sh`, `verify-opendesk.sh`, `export-ca.sh` | [03 – openDesk deployment](../docs/03-opendesk-deployment.md) | ✔ Tested 20.10.2026 on the running lab² |
| 04 | [`04-identity`](04-identity/) | kubespray VM (k8s), DC and FS (PowerShell) | `check-prerequisites.sh`, `fetch-ad-files.sh`, `setup-directory-importer.sh`, `verify-directory-importer.sh`, `setup-smb-storage.sh`, `patch-nextcloud-volumes.sh`, `enable-fileshare-groups.sh`, `nc-mounts.sh`, `verify-nextcloud-files.sh`, `setup-keycloak-idp.sh`, `configure-keycloak-realm.sh`, `configure-sso.sh`, `verify-sso.sh` | [04 – Active Directory and SSO](../docs/04-active-directory-sso.md) | ✔ Tested 20.10.2026 on the running lab³ |
| 05 | [`05-ox`](05-ox/) | kubespray VM (k8s) | `enable-ox.sh`, `verify-ox.sh` | [05 – OX App Suite](../docs/05-ox-app-suite.md) | ✔ Tested 20.10.2026 on the running lab⁴ |
| 06 | [`06-add-worker`](06-add-worker/) | kubespray VM (k8s), Proxmox host (root) | `precheck-worker.sh`, `create-worker-vm.sh`, `add-worker.sh`, `verify-worker.sh` | [06 – Adding a worker node](../docs/06-add-worker-node.md) | ✔ Tested 20.10.2026 on the running lab⁵ |
| – | [`ops`](ops/) | kubespray VM (k8s) | `daily-check.sh`, `etcd-backup.sh`, `post-rollout.sh` | 03 – 12 | ✔ Tested 20.10.2026⁴ ⁶ |
| – | [`windows`](windows/) | DC, file server, workstation | `ad-inventory.ps1`, `test-service-accounts.ps1`, `set-test-passwords.ps1`, `fs-inventory.ps1`, `import-ca.ps1` | [03](../docs/03-opendesk-deployment.md), [04](../docs/04-active-directory-sso.md) | Not tested yet |

¹ `check-nodes`, `install-kubespray`, `prepare-inventory`, `prepare-nodes` (check mode: `changed=0` on all 7 nodes), `setup-kubectl` and `verify-cluster` (34/34 checks) were run against the live cluster. `clone-nodes`, `install-cluster` and `reboot-test` change or interrupt a running lab and were only run with `--dry-run` there.

² Run against the live lab: `install-tools`, `fix-strictarp`, `verify-dns`, `smoke-test` (7/7), `prepare-opendesk` (compares only), `verify-opendesk` (8/8) and `export-ca`; `configure-cluster-dns`, `prepare-nodes-storage` (check mode: `changed=0`), `install-platform` and `split-dns` with `--dry-run` – no change was needed. `verify-dns` showed one false failure (nested braces in the CoreDNS block); the script was fixed and checked against the live Corefile. `deploy-opendesk` was not run on the live lab, because it would roll out openDesk again.

³ Run against the live lab: `check-prerequisites` (12/12), `fetch-ad-files` (4/4), `verify-directory-importer`, `nc-mounts` (plan: 27 × SKIP), `verify-nextcloud-files` (9/9, 19 directories writable, 27 mounts as in the list) and `verify-sso`; `setup-smb-storage` found that the pending kernel 6.8.0-147 on six nodes had no `linux-modules-extra` and installed it (the second run showed `changed=0`). `setup-directory-importer`, `patch-nextcloud-volumes`, `enable-fileshare-groups`, `setup-keycloak-idp`, `configure-keycloak-realm` and `configure-sso` with `--dry-run` – everything already matched. Two script errors found in the test were fixed (a jq expression and a fixed user count).

⁴ Run against the live lab, where OX App Suite was already active: `enable-ox --dry-run` (pre-check 4/4, "already enabled"), `post-rollout --dry-run` (files_external enabled, no user missing in the groupware group), `configure-keycloak-realm --dry-run` (post-logout URI present), `verify-ox` (20/20) and `verify-sso` (11/11, now including the post-logout URI). The rollout itself and the repair steps of `post-rollout` were not run, because nothing needed to be changed.

⁵ Run against the live lab: `precheck-worker` for a node that does not exist yet (8/8), `add-worker --dry-run` for the existing worker node6 (node preparation in Ansible check mode: `changed=0` on all 7 nodes, fact cache checked, `scale.yml` only printed) and `verify-worker` for node6 (26/26, including a Longhorn volume and DNS in a pod on node6). `create-worker-vm` was only tested against a simulated `qm`, and `add-worker` without `--dry-run` against a simulated cluster, because a real run would create a new VM and join it to the cluster.

⁶ `daily-check` was run against the live lab: 31/31 checks. The first run reported two Nubus LDAP components that are at 0 replicas by configuration and two services without pods as failures. The script now reads from the managedFields who set the replicas (Helm = configuration, kubectl = runbook 07) and only reports a service without endpoints if its pods exist but are not ready, or if an ingress route to it fails.

## Daily operation

```bash
./ops/daily-check.sh     # every morning, read-only; every problem names its runbook
./ops/post-rollout.sh    # after every helmfile apply
./ops/etcd-backup.sh NAME   # before every bigger change
```

The runbooks 07 – 12 have no scripts of their own: their prevention checks are part of `daily-check.sh`, while the fixes (`kubectl scale`, `rollout undo`, `uncordon`, `remove-node.yml`) stay deliberate manual decisions, described step by step in the runbooks.

## Conventions

- **One settings file.** All names, addresses and versions live in `lab.env` (created from [`lab.env.example`](lab.env.example), ignored by git). Any value can be overridden for a single run: `TEMPLATE_ID=9001 ./01-proxmox/create-template.sh`.
- **No secrets in the repository.** Passwords are asked for at runtime (hidden input) or read from an environment variable, e.g. `CI_PASSWORD`.
- **Preview first.** Every script supports `--dry-run` (print the commands only) and `--help`.
- **Fail early, never overwrite.** Scripts stop at the first error (`set -euo pipefail`) and refuse to replace existing resources.
- **Verify afterwards.** `verify-*.sh` scripts are read-only and compare the result with the expected state from the documentation.
- Shared helpers are in [`lib/common.sh`](lib/common.sh). All Bash scripts pass [ShellCheck](https://www.shellcheck.net/), the PowerShell scripts pass PSScriptAnalyzer.
