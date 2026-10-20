# 03 – Platform services and openDesk

Scripts for [docs/03 – openDesk deployment](../../docs/03-opendesk-deployment.md).
All values (domain, domain controller, MetalLB range, chart versions) are in section "03" of `lab.env`; the manifests in [`manifests/`](manifests/) contain `@PLACEHOLDERS@` that the scripts fill from there.

**Run on:** kubespray VM as k8s (Windows steps: [`../windows/`](../windows/))

## Order

| Step | Script | What it does | Changes something? |
|---|---|---|---|
| 1 | `install-tools.sh` | helm, helm-diff, helmfile, yq; Helm chart repositories | Only what is missing |
| 2 | `configure-cluster-dns.sh` | Kubespray settings: `kube_proxy_strict_arp`, `coredns_external_zones`, `nodelocaldns_external_zones` ([`manifests/cluster-dns.yaml`](manifests/cluster-dns.yaml)) | Yes – keeps a backup, never overwrites a different value |
| 3 | `../02-kubespray/install-cluster.sh` | Rolls the DNS settings out (about 20 minutes) | Yes |
| 4 | `fix-strictarp.sh` | Patches strictARP into the running kube-proxy (error F2) and checks `arp_ignore`/`arp_announce` | Only if strictARP is false |
| 5 | `verify-dns.sh` | Both Corefiles forward the zones; from a pod on every worker: portal → MetalLB address, AD domain → DC, external names, search line | No (test pods) |
| 6 | `prepare-nodes-storage.sh` | Runs [`prepare-nodes-storage.yml`](prepare-nodes-storage.yml): open-iscsi, `iscsi_tcp`, multipathd off, inotify limits | Yes – `--dry-run` = Ansible check mode |
| 7 | `install-platform.sh` | MetalLB + address pool, Longhorn, HAProxy Ingress, cert-manager + ClusterIssuer, followed by checks | Only what is missing |
| 8 | `split-dns.sh` | systemd-resolved on the kubespray VM sends only the two zones to the DC (error F4) | Only if different |
| 9 | `smoke-test.sh` | Longhorn volume in a pod, certificate, ingress without a class, full chain DNS → MetalLB → HAProxy → pod | No (temporary namespace) |
| 10 | `../ops/etcd-backup.sh basis` | etcd snapshot with a copy on the kubespray VM | Creates a backup |
| 11 | `prepare-opendesk.sh` | openDesk repository v1.17.2, `values.yaml.gotmpl` from [`manifests/`](manifests/opendesk-values.yaml.gotmpl), master password | Never overwrites an existing configuration or password |
| 12 | `deploy-opendesk.sh --render` | Renders all manifests and shows volumes and host names | No |
| 13 | `deploy-opendesk.sh` | etcd backup, then `helmfile apply -n opendesk` (about one hour, in tmux) | Yes |
| 14 | `verify-opendesk.sh` | Releases, pods, certificates, ingress classes, HTTPS from outside and from a pod | No (one test pod) |
| 15 | `export-ca.sh` + [`../windows/import-ca.ps1`](../windows/import-ca.ps1) | Root CA for the workstations, imported only after the thumbprint matches | Only on the workstation |

`deploy-opendesk.sh --diff` shows what a new `helmfile apply` would change in a running openDesk. It prints only the names of the changed resources; the full diff is written to a log file with permissions 600.

## The two values that must never get lost

- **Master password** (`MASTER_PASSWORD_FILE`, default `~/opendesk-master-password.txt`): openDesk derives every database and service password from it. `prepare-opendesk.sh` creates it once and never replaces it; `deploy-opendesk.sh` reads it from the file and never prints it. Keep a copy in a password manager.
- **etcd snapshots** contain every secret of the cluster: `etcd-backup.sh` stores them with permissions 600.

## Testing on a running lab

```bash
./03-opendesk/install-tools.sh                    # finds the installed versions
./03-opendesk/configure-cluster-dns.sh --dry-run  # expect "already set" three times
./03-opendesk/fix-strictarp.sh                    # strictARP already true: checks only
./03-opendesk/verify-dns.sh
./03-opendesk/prepare-nodes-storage.sh --dry-run  # check mode: expect changed=0
./03-opendesk/install-platform.sh --dry-run       # expect "already installed" and "no difference"
./03-opendesk/split-dns.sh --dry-run              # expect "already configured"
./03-opendesk/smoke-test.sh
./ops/etcd-backup.sh automation-test
./03-opendesk/prepare-opendesk.sh                 # compares only; differences for OX App Suite (05) are expected
./03-opendesk/verify-opendesk.sh
./03-opendesk/export-ca.sh
./03-opendesk/deploy-opendesk.sh --diff           # optional, 10–20 minutes
```
