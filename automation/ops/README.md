# ops – Operations

Scripts for recurring tasks on the running lab.

**Run on:** kubespray VM as k8s

| Script | What it does | Doc |
|---|---|---|
| `post-rollout.sh` | Mandatory after every `helmfile apply`: enables `files_external` again (the Nextcloud management job switches it off), adds users with `isOxUser = true` that are missing in `managed-by-attribute-Groupware` (no member is removed), then runs `verify-nextcloud-files.sh`, `verify-sso.sh` and – with OX – `verify-ox.sh` | [05](../../docs/05-ox-app-suite.md) sections 7, 8 and 14.1 |
| `etcd-backup.sh NAME` | etcd snapshot `/var/backups/etcd/NAME.db` on the control plane, status table, copy to `~/backups/etcd/NAME-<date>.db` with permissions 600 | [03](../../docs/03-opendesk-deployment.md) section 8.2, [06](../../docs/06-add-worker-node.md), [12](../../docs/12-node-failure-replace-worker.md) |

```bash
./ops/etcd-backup.sh before-update       # before every bigger change
./ops/post-rollout.sh --dry-run          # shows what would be repaired
./ops/post-rollout.sh                    # after every rollout
```

An etcd snapshot contains every secret of the cluster: copy it only to trusted systems.
