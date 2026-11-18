# 19 – Upgrading openDesk from 1.17.2 to 1.20.2

> Part 19 of the series. Previous: [18 – Directory Importer after the upgrade to openDesk 1.18](18-directory-importer-opendesk-1-18.md) · Next: [20 – IMAP access for a mail archive](20-imap-archive-master-user.md) · Back to the [overview](../README.md)

**Summary:** The second installation of this setup went from openDesk v1.17.2 to v1.20.2 in three steps on 17 and 18.11.2026: 1.18.3, 1.19.5 and 1.20.2. openDesk does not allow skipping 1.18 and 1.19, because both run migrations that the next release expects. Version 1.19 is the hard one: the chat moves to the new Matrix stack with the Matrix Authentication Service (MAS), and that step cannot be undone. Every step started with a full backup, a dry run where openDesk offers one, and a render of the new release; every step ended with `post-rollout.sh`, the daily check and a browser test. All three steps worked. This document lists what had to change and what went wrong on the way.

| Field | Value |
|---|---|
| Path | v1.17.2 → v1.18.3 (17.11.) → v1.19.5 (18.11., ~1 h) → v1.20.2 (18.11., ~1 h) |
| Source | `docs/migrations-manual.md` of the openDesk repository in the tags v1.19.5 and v1.20.2 |
| Downtime | Short restarts per app during each rollout; chat unavailable during the MAS migration |
| Result | All apps working, `post-rollout.sh` and the daily check without errors after each step |

## 1. Before every step

### 1.1 Backup

The backup takes about 15 minutes. The ConfigMap `migrations-status` is mandatory: it records which migrations have run, and a restore without it does not match the data.

**Run on:** kubespray VM as k8s

```bash
source ~/k8s-opendesk-homelab/automation/lab.env
V=$(git -C "$OPENDESK_DIR" describe --tags)
B=~/backups/upgrade-$V-$(date +%Y%m%d-%H%M); mkdir -p $B; chmod 700 $B

# 1) Longhorn: the nightly backup job, now
kubectl -n longhorn-system create job --from=cronjob/backup-daily backup-before-$(date +%H%M)
kubectl -n longhorn-system get backups.longhorn.io -o custom-columns=STATE:.status.state --no-headers | sort | uniq -c

# 2) etcd
( cd ~/k8s-opendesk-homelab/automation && ./ops/etcd-backup.sh before-$V )

# 3) state of the namespace and configuration
kubectl -n opendesk get cm migrations-status -o yaml > $B/migrations-status.yaml
kubectl -n opendesk get secrets -o yaml > $B/opendesk-secrets.yaml
kubectl -n opendesk get configmaps -o yaml > $B/opendesk-configmaps.yaml
helm -n opendesk list -o yaml > $B/helm-releases.yaml
cp "$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl" ~/opendesk-custom/*.yaml $B/
git -C "$OPENDESK_DIR" diff > $B/opendesk-local-changes.patch

# 4) database dumps, in addition to Longhorn
kubectl -n opendesk exec postgresql-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -h 127.0.0.1 -U "$POSTGRES_USER"' | gzip > $B/postgresql.sql.gz
kubectl -n opendesk exec mariadb-0 -- sh -c 'D=$(command -v mariadb-dump || command -v mysqldump); $D --all-databases --single-transaction -uroot -p"$MARIADB_ROOT_PASSWORD"' | gzip > $B/mariadb.sql.gz
zcat $B/postgresql.sql.gz | grep -c 'cluster dump complete'   # 1
zcat $B/mariadb.sql.gz | tail -1                                # -- Dump completed on …

chmod 600 $B/*; ls -lh $B
```

✔ **Expected:** all Longhorn backups `Completed`, the etcd backup with ✔, no dump smaller than about 1 KB. The folder holds secrets: it stays on the kubespray VM.

### 1.2 Render the new release first

There was no separate test environment. Instead, each new tag was checked out into a second folder with `git worktree` and rendered with the planned values, without touching the cluster:

```bash
git -C ~/opendesk worktree add ~/opendesk-1.19.5 v1.19.5
# copy the environment folder, change the values there, apply the Nextcloud patch, then:
cd ~/opendesk-1.19.5 && MASTER_PASSWORD="$(cat "$MASTER_PASSWORD_FILE")" helmfile -e "$OPENDESK_ENV" template > /tmp/render.yaml
```

For 1.19 the render found the broken Nextcloud patch (section 3.2) and confirmed the new settings (sections 3.1 and 3.4) before the real rollout. Delete the render afterwards, it contains secrets; remove the worktree after the upgrade with `git -C ~/opendesk worktree remove --force ~/opendesk-1.19.5`.

### 1.3 Rollout

The same for every step, only the tag changes:

```bash
source ~/k8s-opendesk-homelab/automation/lab.env
T=v1.19.5
cd "$OPENDESK_DIR"
git checkout -- helmfile/apps/nextcloud/values-nextcloud.yaml.gotmpl   # local patch, it is in the backup
git checkout $T && git describe --tags
( cd ~/k8s-opendesk-homelab/automation && ./04-identity/patch-nextcloud-volumes.sh )
MASTER_PASSWORD="$(cat "$MASTER_PASSWORD_FILE")" helmfile -e "$OPENDESK_ENV" apply -n "$OPENDESK_NAMESPACE" \
  2>&1 | tee ~/logs/upgrade-$T-$(date +%Y%m%d-%H%M).log
```

After the rollout: save the logs of the migration jobs into `$B` (for 1.18 they were the only copy of the old AD IDs, [18](18-directory-importer-opendesk-1-18.md)), then `./ops/post-rollout.sh`, `./ops/daily-check.sh` and a browser test: login, mail, calendar, files including the SMB shares, chat, projects and the app menu.

## 2. Step 1: openDesk 1.18.3

OX functional accounts become shared accounts and OX gets new user IDs – all automatic. Two things needed work:

**The migration job did not trust the internal CA.** `opendesk-migrations-pre` connects to the internal S3 and stopped with an SSL error, because it did not know the CA of the installation. Fix: `migrations.objectStore.caBundle: "/etc/opendesk-ca/ca.crt"` in the values, plus a values file for the releases `migrationsPre` and `migrationsPost` (`customization.release`, [15](15-opendesk-customization.md)) that mounts the secret `opendesk-certificates-ca-tls` at `/etc/opendesk-ca`. It is still needed with 1.19 and 1.20.

**The Directory Importer lost its users and groups.** See [18](18-directory-importer-opendesk-1-18.md): stop the importer before the upgrade and switch it to `reservedLegacyExternalIamIdentifier` before starting it again.

## 3. Step 2: openDesk 1.19.5

### 3.1 Changed values

```bash
V="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
cp -p "$V" "$V.bak-$(date +%Y%m%d-%H%M)"
yq -i '
  .certificate.create = false |
  .certificate.selfSigned = false |
  del(.certificate.issuerRef) |
  .trust.secret.mount = true |
  .cluster.networking.ingressGatewayIP = "10.240.0.190" |
  .technical.matrix.migration.enabled = true |
  .persistence.storages.synapse.existingClaim = "media-opendesk-synapse-0" |
  .functional.dataProtection.matrixAccountErasure.enabled = true |
  del(.customization.release.opendeskWellKnown) |
  .customization.release.opendeskElement = ["/home/k8s/opendesk-custom/element-e2ee-1.19.yaml"]
' "$V"
```

| Setting | Why |
|---|---|
| `certificate.create/selfSigned: false`, `trust.secret.mount: true` | The certificate comes from the own PKI ([03](03-opendesk-deployment.md)). 1.19 replaces `selfSigned` by a trust mount: the existing secret `opendesk-certificates-ca-tls` (`ca.crt`, `truststore.jks`) is mounted into all containers, and cert-manager creates nothing |
| `cluster.networking.ingressGatewayIP` | The video call service (SFU) of the new chat announces this address; without it, it announces the public address of the internet line |
| `technical.matrix.migration.enabled` | Runs the one-way migration of Synapse to MAS |
| `persistence.storages.synapse.existingClaim` | The new Matrix chart keeps the old media volume |
| `matrixAccountErasure.enabled` | Default `true`: name, avatar and profile of deleted users are erased, which cannot be undone. Kept, there was no real chat data yet |
| `opendeskWellKnown` → `opendeskElement` | The release `opendesk-well-known` is gone in 1.19; the switch for end-to-end encryption moves to the Matrix stack (section 3.4) |

### 3.2 Nextcloud patch

1.19 changed the condition of the CA block in `values-nextcloud.yaml.gotmpl` from `certificate.selfSigned` to `trust.secret.mount`. `patch-nextcloud-volumes.sh` failed on it in the render. It now keeps whatever condition and CA lines the file has and only adds the SMB shares, for 1.18 and 1.19+ alike ([04](04-active-directory-sso.md)).

### 3.3 Postfix without root

From 1.19, Postfix no longer runs as root. Its spool directories on the existing volume belonged to root, so the new pods could not write. Fix, still on 1.18 and right before the rollout:

```bash
kubectl -n opendesk exec deploy/postfix -c postfix -- chown -R 100:101 /var/spool/postfix /var/lib/postfix
kubectl -n opendesk exec deploy/postfix-ox -c postfix -- chown -R 100:101 /var/spool/postfix /var/lib/postfix
```

The image has no `find -uid`; check the owners with `ls -ln`.

### 3.4 Chat without end-to-end encryption

The old file for `opendeskWellKnown` ([15](15-opendesk-customization.md), section 3) has no effect any more. The new file for `customization.release.opendeskElement`:

```yaml
# Chat: end-to-end encryption off (decision of the operator), from 1.19 via the Matrix stack chart
wellKnownDelegation:
  additional:
    client: '{"io.element.e2ee": {"force_disable": true}}'
```

The render showed it in the ConfigMap `element-well-known-haproxy`. Check after the rollout:

```bash
curl -s https://k8s.lab/.well-known/matrix/client | jq '."io.element.e2ee"'
```

✔ **Expected:** `"force_disable": true`.

### 3.5 Orphaned chat accounts: a dry run is a run

1.19 can deactivate chat accounts whose user no longer exists in the IAM (`migrations.actionOptions.synapseDeactivateOrphanedUsers`). openDesk recommends a dry run first: deploy only the secrets and the pre-migrations of the new tag and read the log:

```bash
MASTER_PASSWORD="$(cat "$MASTER_PASSWORD_FILE")" helmfile -e "$OPENDESK_ENV" -n "$OPENDESK_NAMESPACE" \
  -l name=opendesk-secrets -l name=opendesk-migrations-pre apply
kubectl -n opendesk logs job/<opendesk-migrations-pre job> | grep 'DRY RUN - would deactivate'
```

It found three guest accounts and no real user. Then `dryRun: false` (with `maxOrphanPercent: 50`) was set for the real rollout – but the action did not run again: the log said that it had already run with this footprint. The dry run had been recorded as done. The three guest accounts stayed active and did no harm. If the action matters, run it with `dryRun: false` directly, or read how to reset the state of a migration first.

### 3.6 Checking the MAS migration

The job `element-syn2mas` runs twice. The second run logs that the migration has already happened and skips; that is not an error. Proof that it ran:

```bash
kubectl -n opendesk get cm element-markers -o jsonpath='{.data.MATRIX_STACK_MSC3861}{"\n"}'   # syn2mas_migrated
kubectl -n opendesk exec postgresql-0 -- sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d matrix_authentication -tAc "select count(*) from users"'
```

✔ **Expected:** `syn2mas_migrated`, and as many MAS users as there were chat accounts (13 in the second installation; `upstream_oauth_links` holds one link per user who has logged in through Keycloak).

The new host names `mas.`, `mrtc.` and `element-admin.` were already covered by the wildcard certificate and the wildcard DNS record.

## 4. Step 3: openDesk 1.20.2

**Audience mappers.** With 1.20 (Keycloak 26.8), audience mappers must reference a client that exists. The migration manual of v1.20.2 has a dry run for this ("Audience mappers must reference an existing client"). It was run before the rollout with the new image in a copy of the `keycloak-bootstrap` pod (`kubectl debug --copy-to`), so nothing changed in Keycloak. Compare the clients it lists with the ones you know before rolling out.

**`CREDSTORAGE_PASSCRYPT`.** Fixed upstream in 1.20.0 ([15](15-opendesk-customization.md), section 4). The pinned value was kept: it still wins over the new default and works.

**During the rollout:** one pod of the job `ums-stack-data-ums` failed once with a connection error to the UDM REST API, which was still starting; the job completed with the next pod. The failed pod only needed to be deleted. `verify-sso.sh` failed once right after the rollout and passed a few minutes later.

**Daily check: a read-only mount by design.** The new Nubus chart mounts `/var/lib/univention-ldap` read-only into the `leader-elector` container of `ums-ldap-server-primary-0`. The write test reported `Read-only file system`, although the `main` container of the same pod mounts the volume writable. Not a fault: see [14](14-backup-freeze-io-error.md), section 4.1; `longhorn-mount-check.sh` now skips mounts that the pod spec declares read-only.

**Clean up the Helm history of `ums`.** Releases of `ums` before 1.20 stored `MASTER_PASSWORD` unencrypted in their Helm secrets. Once everything works, delete all revisions except the newest – only if the newest is `deployed`:

```bash
last=$(kubectl -n opendesk get secret -l owner=helm,name=ums --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.labels.status}')
echo "newest: $last"
[ "$last" = deployed ] && kubectl -n opendesk get secret -l owner=helm,name=ums --sort-by=.metadata.creationTimestamp -o name | head -n -1 | xargs -r kubectl -n opendesk delete
helm -n opendesk history ums
```

✔ **Expected:** one line, `deployed`. A Helm rollback of `ums` is no longer possible after this; the backup of section 1.1 is the way back.

## 5. Rollback

openDesk does not support a downgrade: the migrations change the databases. Going back means restoring the data from before the step (Longhorn volumes or the dumps, plus `migrations-status.yaml`) and deploying the previous tag – about 1 to 3 hours. After 1.19, going back to 1.18 also needs the Synapse database, the media volume and the signing key from the backup. Fix forward when only one app is affected.

## 6. Takeaways

- **Read the migration manual of every release on the way, not only of the target.** Each of the three steps had at least one change that needed preparation.
- **Render before you roll out.** Without a test environment, a render of the new tag with the planned values found the broken Nextcloud patch before it could stop the rollout.
- **A dry run can consume a one-time action.** The dry run of the orphaned chat accounts was recorded as done.
- **Charts tighten their defaults.** Postfix without root and a read-only mount in a sidecar were both correct changes upstream; the first needed a migration of file owners, the second a smarter check.
- **Old Helm revisions can hold secrets.** Clean them up when the upstream notes say so.
