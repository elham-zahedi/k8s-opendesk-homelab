# ops – Operations

Scripts for recurring tasks on the running lab.

**Run on:** kubespray VM as k8s

| Script | What it does | Doc |
|---|---|---|
| `daily-check.sh` | Read-only check of the whole lab in about one minute: nodes (NotReady, cordoned), on the nodes (`nls_utf8`, `linux-modules-extra` for the newest kernel, disk, time, pending reboots), pods (ImagePullBackOff, Pending, OOMKilled, CrashLoop, stuck Terminating), unfinished rollouts, deployments at 0 replicas, services without endpoints, HTTPS access including the webmail API, PVCs and Longhorn, certificates and their renewal, files_external, groupware group, Directory Importer, split DNS, strictARP, etcd and the age of the newest backup. Every problem names the runbook that explains it | [07](../../docs/07-webmail-connection-error.md) – [12](../../docs/12-node-failure-replace-worker.md), [04](../../docs/04-active-directory-sso.md) section 24, [05](../../docs/05-ox-app-suite.md) section 14 |
| `post-rollout.sh` | Mandatory after every `helmfile apply`: enables `files_external` again (the Nextcloud management job switches it off), adds users with `isOxUser = true` that are missing in `managed-by-attribute-Groupware` (no member is removed), runs `configure-selfservice.sh` and – if a rollout of `ums` reset it – rolls out `opendesk-keycloak-bootstrap` again for the direct login, then runs `verify-nextcloud-files.sh` (mount list `NC_MOUNTS_CSV` from `lab.env`), `verify-sso.sh` and – with OX – `verify-ox.sh` | [05](../../docs/05-ox-app-suite.md) sections 7, 8 and 14.1 |
| `etcd-backup.sh NAME` | etcd snapshot `/var/backups/etcd/NAME.db` on the control plane, status table, copy to `~/backups/etcd/NAME-<date>.db` with permissions 600 | [03](../../docs/03-opendesk-deployment.md) section 8.2, [06](../../docs/06-add-worker-node.md), [12](../../docs/12-node-failure-replace-worker.md) |

```bash
./ops/daily-check.sh                     # every morning; exit code 0 = all checks passed
./ops/etcd-backup.sh before-update       # before every bigger change
./ops/post-rollout.sh --dry-run          # shows what would be repaired
./ops/post-rollout.sh                    # after every rollout
```

An etcd snapshot contains every secret of the cluster: copy it only to trusted systems.

## Daily check from cron

```bash
crontab -e
# every day at 07:00 – the result is in ~/daily-check.log
0 7 * * * $HOME/automation/ops/daily-check.sh > $HOME/daily-check.log 2>&1
```

Warnings (e.g. a pending reboot, a CA that expires within 45 days, an old etcd backup) are shown but do not fail the check. Deployments that are at 0 replicas on purpose, or services without endpoints on purpose, go into `DAILY_IGNORE` in `lab.env`.

| Problem in the output | Runbook |
|---|---|
| Deployment at 0 replicas, service without endpoints, webmail API 503 | [07 – Webmail "Connection error"](../../docs/07-webmail-connection-error.md) |
| `ImagePullBackOff`, `ErrImagePull`, rollout not finished | [08 – ImagePullBackOff](../../docs/08-imagepullbackoff.md) |
| `Unschedulable`, Pending, rollout not finished | [09 – Pending: insufficient memory](../../docs/09-pending-insufficient-memory.md) |
| Node `SchedulingDisabled`, pending reboot | [10 – Node SchedulingDisabled](../../docs/10-node-schedulingdisabled.md) |
| `CrashLoopBackOff`, `OOMKilled` | [11 – OOMKilled](../../docs/11-oomkilled.md) |
| Node `NotReady`, pod stuck in `Terminating`, Longhorn volume degraded | [12 – Node failure](../../docs/12-node-failure-replace-worker.md) |
| files_external off, groupware group incomplete | `./ops/post-rollout.sh` ([05](../../docs/05-ox-app-suite.md) F2, F3) |
| `linux-modules-extra` missing for the newest kernel | `./04-identity/setup-smb-storage.sh` before the next reboot |

