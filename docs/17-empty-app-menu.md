# 17 – Empty App Menu (9 Dots) in the Apps

> Troubleshooting runbook. Previous: [16 – openDesk apps per AD group](16-app-access-by-ad-group.md) · Back to the [overview](../README.md)

**Summary:** In the second installation of this setup, the 9-dot menu in the top bar of the apps (Files, Mail and the others) opened empty for some users, while login, files and mail kept working. The menu comes from the Intercom Service (ICS). ICS keeps one session per user in Redis, with the tokens from Keycloak. When these tokens expire and cannot be renewed, the session stays in Redis and the menu stays empty until the session is deleted. [`ops/ics-sessions.sh --clean`](../automation/ops/ics-sessions.sh) deletes such stale sessions, and `ops/post-rollout.sh` now does it after every rollout.

| Field | Value |
|---|---|
| Date | Investigated on 02.11.2026; stale sessions deleted on 03.11. and 05.11.2026 |
| Affected | The 9-dot menu of the apps, for users with a stale ICS session |
| Not affected | Login, portal, files, mail |
| Result | The menu is back after the session is deleted and the page is reloaded |

## 1. Report

The 9-dot menu in the top bar of the apps opened without any entries. Login, the portal, files and mail worked as usual.

## 2. Diagnosis

**Run on:** kubespray VM as k8s

### Step 1 – Where the menu comes from

The apps load the menu from ICS (`ics.<domain>`, path `/navigation.json`). ICS asks the portal for the entries of the logged-in user. It knows who the user is from the tokens in its own session, which it stores in Redis (`sess:*`). Without valid tokens, the portal gets no user and returns no entries.

### Step 2 – List the ICS sessions

```bash
cd ~/k8s-opendesk-homelab/automation
./ops/ics-sessions.sh
```

The script runs [`ops/ics/ics-sessions.js`](../automation/ops/ics/ics-sessions.js) with node inside the pod `intercom-service`, which already has the Redis connection in its environment. It prints for each session the user, when the session was created and last used, when its tokens expire and whether they are still valid – never a token. All times are in seconds relative to now, so a negative value lies in the past.

A stale session has an `expires_at` far in the past, and its tokens fail the check with `ERR_JWT_EXPIRED`.

### Step 3 – Dry run of the cleanup

```bash
./ops/ics-sessions.sh --clean --dry-run
```

It lists every session whose tokens expired more than 10 minutes ago (`would delete: session of …`) and changes nothing.

### Root cause

ICS renews the tokens of a session when they expire. If the renewal fails – for example while Keycloak or its database is not available, as during the outage of [14](14-backup-freeze-io-error.md) – ICS keeps the session with the expired tokens. It can then no longer tell the portal who the user is. The session is not replaced on its own: it stays in Redis until it ends or is deleted, and reloading the page does not help.

## 3. Fix

```bash
./ops/ics-sessions.sh --clean          # sessions whose tokens expired more than 10 minutes ago
./ops/ics-sessions.sh --clean --all    # every session, e.g. after a bigger outage
```

[`ops/ics/ics-clear-stale.js`](../automation/ops/ics/ics-clear-stale.js) deletes the sessions in Redis. The user gets a new session with the next page load. As long as the Keycloak login is still valid, this happens without a login form, and the menu is back.

**Result** in the second installation (user names replaced):

| Date | Situation | Deleted |
|---|---|---|
| 03.11.2026 | After a rollout | 2 sessions, tokens expired 1 and 2.6 hours before |
| 05.11.2026 | Morning after the PostgreSQL outage of [14](14-backup-freeze-io-error.md) | 4 sessions, tokens expired 19 to 21 hours before |

```
  deleted: session of user-a (tokens expired 3791s ago)
  deleted: session of user-b (tokens expired 9338s ago)
  2 stale, 0 kept
```

## 4. Prevention

- [`ops/post-rollout.sh`](../automation/ops/post-rollout.sh) runs `ics-sessions.sh --clean` after every rollout (step 5/6).
- After an outage of Keycloak or its database, run `./ops/ics-sessions.sh --clean` once Keycloak works again.

## 5. Takeaways

- An empty menu does not mean missing permissions. Check the ICS session first: a stale session looks the same for every app.
- A session store can keep a broken state after the cause is gone. After an outage, clean the sessions too, not only the services.
- The user cannot fix it by reloading the page. The stale session has to be deleted on the server.

---

Previous: [16 – openDesk apps per AD group](16-app-access-by-ad-group.md) · Back to the [overview](../README.md)
