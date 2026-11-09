# 16 – openDesk Apps per AD Group

> Part 16 of the series. Previous: [15 – openDesk settings per release](15-opendesk-customization.md) · Back to the [overview](../README.md)

**Summary:** openDesk shows an app such as the chat or the projects only to users whose Nubus account has the matching attribute, e.g. `opendeskLivecollaborationEnabled` for the chat. The Directory Importer of [04](04-active-directory-sso.md) brings users and groups from AD, but it does not set these attributes from a group membership. In the second installation of this setup the access to the apps is therefore managed with AD groups: [`sync-app-groups.sh`](../automation/04-identity/sync-app-groups.sh) sets the attribute to `true` for every member of a group – also through nested groups – and to `false` for everyone else. It runs every 15 minutes from cron.

| AD group | Attribute in Nubus | App |
|---|---|---|
| `OD-Chat` | `opendeskLivecollaborationEnabled` | Chat (Element) |
| `OD-Projekte` | `opendeskProjectmanagementEnabled` | Projects (OpenProject) |
| `OD-Projekte-Admin` | `opendeskProjectmanagementAdmin` | Administration in OpenProject |

The pairs are in `APP_GROUPS` in `lab.env`. Groups can be nested: the pilot users are in a group `OD-Pilot`, which is a member of `OD-Chat` and `OD-Projekte`.

## 1. Rules

- **Only imported users.** The script only reads and changes users in `ou=NUBUS_OU` – the users from AD. Local accounts such as the Nubus Administrator are never changed.
- **Nested groups count.** Members of a group inside the group get the app too. A group that contains itself (directly or through other groups) is read only once.
- **A missing group changes nothing.** A group that is not in Nubus (yet) is skipped, and its attribute stays as it is. A new AD group needs up to 5 minutes until the Directory Importer has brought it to Nubus.
- **An empty group changes nothing.** A group without members is skipped too, so a mistake in AD or in the import cannot switch an app off for everyone. `--force` applies an empty group on purpose.
- **Only differences are written.** A user whose attribute is already right is not touched, so a run without changes does not write anything to Nubus.

The groups must be imported by the Directory Importer. In the lab of [04](04-active-directory-sso.md) only groups that start with `AD_GROUP_PREFIX` (`G-`) are imported: either name the app groups with this prefix or extend the filter of the importer. In the second installation the filter of the importer is `OD-`.

## 2. Timing

A change in AD takes effect in two steps: the Directory Importer copies the membership to Nubus (every 5 minutes), then `sync-app-groups.sh` sets the attribute (every 15 minutes). So a new member gets the app after at most about 20 minutes. Users may have to log out of the portal and in again before they see the change.

## 3. Run

**Run on:** kubespray VM as k8s

```bash
cd ~/k8s-opendesk-homelab/automation
./04-identity/sync-app-groups.sh --dry-run      # shows every user and what would change
./04-identity/sync-app-groups.sh                # changes only the differences
./04-identity/sync-app-groups.sh --cron --dry-run
./04-identity/sync-app-groups.sh --cron         # cron job every 15 minutes
```

`--cron` adds the job and a `PATH` line to the crontab of the user. An older line that calls `sync-app-groups` – for example a first copy of the script in the home directory – is replaced; the difference is shown first:

```
PATH=/usr/local/bin:/usr/bin:/bin
*/15 * * * * flock -n /tmp/sync-app-groups.lock bash /home/k8s/k8s-opendesk-homelab/automation/04-identity/sync-app-groups.sh --quiet >> /home/k8s/logs/sync-app-groups.log 2>&1
```

- `flock` makes sure that two runs never overlap.
- `bash` in front of the path: a `git pull` writes the script without the executable bit (the repository stores the files as 644), and the job keeps working.
- `--quiet` writes only changes, warnings and one summary line per run, so the log grows by about 100 short lines a day:

```
2026-11-09 12:15:02 sync-app-groups: 0 change(s), 0 group(s) skipped
```

✔ **Expected:** the dry run lists every imported user with ✔ and the right value; the summary line shows `0 change(s), 0 group(s) skipped` once AD and Nubus agree.

## 4. Daily check

A cron job fails silently. [`ops/daily-check.sh`](../automation/ops/daily-check.sh) therefore reads the last summary line of the log (step 7/8): the last run must be at most 30 minutes old, and a skipped group is reported as a warning.

```
  ✔ app groups: last sync 4 minute(s) ago – 0 change(s), 0 group(s) skipped (doc 16)
```

If the check fails, the end of the log names the reason, e.g. a Nubus login that does not work any more (`NUBUS_ADMIN_PASSWORD_FILE`, [03](03-opendesk-deployment.md)):

```bash
tail -20 ~/logs/sync-app-groups.log
```

## 5. Renaming the groups

All group names are in `APP_GROUPS`. To move to other names, e.g. `DL_OD_Chat` instead of `OD-Chat`:

1. Create the new groups in AD with the same members.
2. Extend the group filter of the Directory Importer to the new names, and wait until the groups are in Nubus.
3. Change `APP_GROUPS` in `lab.env` and run `./04-identity/sync-app-groups.sh --dry-run`: expected `0 change(s)`, because the members are the same.
4. Only then delete the old groups in AD.

The order matters: as long as the new groups are not in Nubus, the script skips them and changes nothing.

## 6. Takeaways

- Access to the apps follows the AD groups, so it is managed in one place – the same place as the other permissions.
- A missing or empty group switches nothing off. A failing import must not take the chat away from everyone.
- A cron job needs a sign of life: one summary line per run and a check in the daily check.

---

Previous: [15 – openDesk settings per release](15-opendesk-customization.md) · Back to the [overview](../README.md)
