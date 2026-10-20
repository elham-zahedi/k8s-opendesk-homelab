# ops – Operations

Scripts for recurring tasks on the running lab.

**Run on:** kubespray VM as k8s

| Script | What it does | Doc |
|---|---|---|
| `etcd-backup.sh NAME` | etcd snapshot `/var/backups/etcd/NAME.db` on the control plane, status table, copy to `~/backups/etcd/NAME-<date>.db` with permissions 600 | [03](../../docs/03-opendesk-deployment.md) section 8.2, [06](../../docs/06-add-worker-node.md), [12](../../docs/12-node-failure-replace-worker.md) |

```bash
./ops/etcd-backup.sh before-update       # before every bigger change
```

An etcd snapshot contains every secret of the cluster: copy it only to trusted systems.
