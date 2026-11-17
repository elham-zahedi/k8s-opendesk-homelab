# 18 – Directory Importer After the Upgrade to openDesk 1.18

> Troubleshooting runbook. Previous: [17 – Empty app menu](17-empty-app-menu.md) · Back to the [overview](../README.md)

**Summary:** After the upgrade from openDesk 1.17.2 to 1.18.3 in the second installation, the Directory Importer ([04](04-active-directory-sso.md), part B) no longer found the users and groups it had imported. openDesk 1.18 sets `univentionObjectIdentifier` of every object to its `entryUUID` and reserves a new property, `reservedLegacyExternalIamIdentifier`, for the ID of an external IAM. The importer still looked up its objects by `univentionObjectIdentifier`. It deleted the imported groups and created them again without members, and it failed to create the users a second time. The AD IDs were restored from the log of the migration job, the recreated groups were deleted, and the importer now uses `reservedLegacyExternalIamIdentifier`. No user was deleted or disabled.

| Field | Value |
|---|---|
| Date | 17.11.2026, right after the upgrade to openDesk 1.18.3 |
| Affected | Directory Importer; members of the imported groups (5 users, 4 groups in the second installation) |
| Not affected | Login, apps, app access per AD group ([16](16-app-access-by-ad-group.md) skips groups without members) |
| Result | IDs restored, groups recreated with their members by the importer, importer without errors, daily check 39/39 |

## 1. Report

After the upgrade, `ops/post-rollout.sh` and the daily check reported errors of the importer:

```
KeyError('<AD ID of a user>')
'POST' 'users/user' status=422
```

The groups imported from AD had no members any more.

## 2. Diagnosis

**Run on:** kubespray VM as k8s

### Step 1 – Stop the importer

```bash
kubectl -n directory-importer scale deployment/directory-importer --replicas=0
```

As long as it runs, it keeps changing the target OU every 5 minutes.

### Step 2 – The migration log

The upgrade runs the migration `ldap_entryuuid_to_object_identifier` in the job `opendesk-migrations-pre`. It logs every object it changes, with the old and the new value:

```
INFO : ldap_entryuuid_to_object_identifier: Aligning …
INFO :     uid=<user>,ou=intern-ad,dc=swp-ldap,dc=internal: <AD ID> -> <entryUUID>
INFO :     …
INFO : … now carry their entryUUID
```

This log is the only place where the old AD IDs are still stored. Save it before the job or its pod is deleted:

```bash
kubectl -n opendesk get pods | grep migrations-pre
kubectl -n opendesk logs <pod of opendesk-migrations-pre> > ~/backups/<upgrade folder>/opendesk-migrations-pre.log
chmod 600 ~/backups/<upgrade folder>/opendesk-migrations-pre.log
```

### Step 3 – What the importer did

A dry run of the restore script (section 3.1) compares every object in the log with its state now. For the users, `univentionObjectIdentifier` still held the value of the log (`entryUUID`): they were unchanged, because creating them again failed with 422. The four groups had another `entryUUID` than in the log, carried the old AD ID in `univentionObjectIdentifier` and had no user members: the importer had deleted and created them again, and could not add the users, because it did not find them.

### Root cause

Up to openDesk 1.17, the importer stored the AD `objectGUID` in `univentionObjectIdentifier` and used it as the primary key. openDesk 1.18 makes `univentionObjectIdentifier` the identifier of Nubus itself (`entryUUID`) and adds `reservedLegacyExternalIamIdentifier` (LDAP attribute `univentionFreeAttribute2`, syntax UUID, can only be set once) for an external ID. The migration overwrote the AD IDs. The importer, still configured with `univentionObjectIdentifier`, found no AD ID in Nubus any more and treated every object as new.

## 3. Fix

### 3.1 Restore the AD IDs of the users

The openDesk helper for this migration copies the current `univentionObjectIdentifier` into the new property – after the upgrade that is the `entryUUID`, not the AD ID. [`restore-external-iam-identifier.py`](../automation/04-identity/restore-external-iam-identifier.py) is based on it, but reads the old values from the migration log. Before it writes, it checks for every object that `univentionObjectIdentifier` still holds the new value of the log and that the new property is empty. Every other object is reported as a conflict and left untouched; the report says why (for example "object RECREATED after the migration") without printing IDs.

```bash
kubectl -n opendesk port-forward service/ums-udm-rest-api 9979:9979 >/dev/null 2>&1 &
export UDM_PASSWORD="$(kubectl -n opendesk get secret ums-ldap-server-admin -o jsonpath='{.data.password}' | base64 -d)"
LOG=~/backups/<upgrade folder>/opendesk-migrations-pre.log
S=~/k8s-opendesk-homelab/automation/04-identity/restore-external-iam-identifier.py
python3 $S --log $LOG --dry-run > ~/restore-dryrun.txt 2>&1; grep -E "LOG:|CONFLICT|SUMMARY" ~/restore-dryrun.txt
python3 $S --log $LOG --limit 1    # one object first
python3 $S --log $LOG              # the rest
```

The output of `--dry-run` and of the writing runs contains AD IDs and user names – keep it on the kubespray VM. In the second installation:

```
SUMMARY: 9 in the log below the scope, 5 to write, 0 written, 0 already restored, 4 conflict(s), 0 missing, 0 skipped.
SUMMARY: 9 in the log below the scope, 4 planned, 4 written, 1 already restored, 4 conflict(s), 0 missing, 0 skipped.
```

The 4 conflicts are the recreated groups (section 3.2). The script exits with 1 as long as there are conflicts.

### 3.2 Delete the recreated groups

A recreated group carries the AD ID in `univentionObjectIdentifier`, which should be the identifier of Nubus. It is simpler to delete it and let the importer create it again with the new configuration (section 3.3) than to correct it. Only delete groups that the dry run reports as `object RECREATED` and that have no user members – the importer adds the members again from AD. Group-in-group memberships between these groups are fine; they come back too. Save each group first:

```bash
B=~/backups/<upgrade folder>
for g in <group> <group>; do
  url="http://localhost:9979/univention/udm/groups/group/$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "cn=$g,ou=intern-ad,dc=swp-ldap,dc=internal")"
  curl -sf -u "cn=admin:$UDM_PASSWORD" -H 'Accept: application/json' "$url" > "$B/udm-group-$g.json" && chmod 600 "$B/udm-group-$g.json" \
    && curl -s -o /dev/null -w "$g: HTTP %{http_code}\n" -u "cn=admin:$UDM_PASSWORD" -X DELETE "$url"
done
```

✔ **Expected:** a 2xx status per group and a JSON copy per group in `$B`.

### 3.3 Switch the importer to the new property

[`directory-importer-values.yaml`](../automation/04-identity/manifests/directory-importer-values.yaml) (and section 7 of [04](04-active-directory-sso.md)):

- `user_primary_key_property` and `group_primary_key_property`: `reservedLegacyExternalIamIdentifier`
- `rename_attrs` for users and groups: `reservedLegacyExternalIamIdentifier: "objectGUID"`
- `user_properties` and `group_properties` written out: the default lists of the importer, with `univentionObjectIdentifier` replaced by `reservedLegacyExternalIamIdentifier`

The last point is needed for two reasons found in the code of the importer (1.7.2). It reads the existing users with exactly the properties of `user_properties` and does not add the primary key on its own – without the new property in the list it stops with `KeyError: 'reservedLegacyExternalIamIdentifier'`. And when it compares an object, it sets every listed property that the source does not deliver to its empty default – with `univentionObjectIdentifier` still in the default list, it would empty the identifier of every imported user and group.

```bash
cd ~/k8s-opendesk-homelab/automation
./04-identity/setup-directory-importer.sh --dry-run    # diff: the changed lines only
./04-identity/setup-directory-importer.sh --force
```

`--force` asks for the password of the AD service account again (it replaces the AD secrets too). Paste this command alone – a command pasted after it becomes the password.

### 3.4 Start and check

```bash
kubectl -n directory-importer scale deployment/directory-importer --replicas=1
sleep 120
kubectl -n directory-importer logs deployment/directory-importer --since=5m | grep -cE "KeyError|422|Traceback|ERROR"
kubectl -n directory-importer logs deployment/directory-importer --since=5m | grep "request count"
./04-identity/sync-app-groups.sh --dry-run
./ops/daily-check.sh
```

The first cycle in the second installation:

```
INFO 'POST' 'groups/group' status=201 count=4
INFO 'PUT' 'groups/group' status=204 count=2
```

The four groups were created with their members, two of them got their nested group back, and no user was modified (no `PUT users/user`). Every user and group had `reservedLegacyExternalIamIdentifier` set; the users kept `univentionObjectIdentifier` = `entryUUID`, the new groups got an identifier from Nubus (not the AD ID). `sync-app-groups.sh` found 0 changes, the daily check 39 of 39.

## 4. Prevention

For an upgrade from openDesk 1.17 or older to 1.18 or later with the Directory Importer:

1. **Before the upgrade:** scale the importer to 0, then follow the openDesk notes for 1.18 on external IAM identifiers (migration manual of the release) and their helper `docs/migrations-helper/1.18.0-external-iam-identifier.py`, while `univentionObjectIdentifier` still holds the AD IDs.
2. **After the upgrade, before starting the importer:** switch its configuration (section 3.3).
3. **Always:** save the logs of the migration jobs into the backup folder of the upgrade before deleting the jobs.

## 5. Takeaways

- **An upgrade can change the data a connector relies on.** The importer kept running and acted on what it saw: objects without a known ID. Stopping it before the upgrade would have prevented the recreated groups.
- **Migration logs are backups.** The log of `opendesk-migrations-pre` was the only copy of the old AD IDs.
- **Default lists are part of the configuration.** The importer empties properties that are listed but not delivered by the source; changing the primary key without the property lists would have emptied the identifiers of all imported objects.
- **Check before writing.** Each step ran as a dry run first, then for one object, then for all – the dry run found the recreated groups before anything was written.

## 6. Deletion grace period

With `deletion_grace_period_days` above 0 (3650 in [04](04-active-directory-sso.md), section 7), the importer does not delete an account that is gone from AD right away. In the next cycle it disables the account and writes the time into the UDM property `directoryImporterDeprovisionedAt`; once the grace period has passed, it deletes the account. If the account comes back in AD first, the property is emptied and the account is enabled again. Groups have no grace period, they are deleted at once.

The property is an extended attribute that the README of the importer creates with a helper script of its test setup; the script is not part of the image. In the second installation it was missing (found on 17.11.2026): the importer could not have marked a removed account, so the account would have stayed enabled in openDesk – login was still blocked, because it goes through AD.

[`setup-directory-importer.sh`](../automation/04-identity/setup-directory-importer.sh) now creates it (step 2) when the grace period is above 0, and restarts the UDM REST API, which reads the extended attributes when it starts:

| Setting | Value | Why |
|---|---|---|
| Position | `cn=custom attributes,cn=univention,<base>` | Outside `cn=opendesk`, so openDesk updates do not touch it |
| Module | `users/user` | The grace period only applies to users |
| Syntax | `string` | The importer writes `2026-11-17T12:00:00Z` (UTC) |
| LDAP attribute | `univentionFreeAttribute20` (`DI_DEPROVISION_LDAP_ATTR`) | openDesk 1.18 uses 1, 2 and 14 |
| `deleteObjectClass` | `false` | `reservedLegacyExternalIamIdentifier` uses the same object class `univentionFreeAttributes` – emptying the timestamp must not remove it |
| `disableUDMWeb` | `true` | Like the property of openDesk: only the importer works with it |

`verify-directory-importer.sh` checks that it exists. In the second installation it was created on 17.11.2026; afterwards a user showed the property (empty) and `disabled: False`.
