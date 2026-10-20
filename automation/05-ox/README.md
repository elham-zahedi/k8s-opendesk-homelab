# 05 – OX App Suite (mail, calendar, contacts)

Scripts for [docs/05 – OX App Suite](../../docs/05-ox-app-suite.md).
The mail domain and the name of the groupware group are in section "05" of `lab.env`. `MAIL_DOMAIN` defaults to `AD_DOMAIN`: the openDesk addresses must be the same as the AD addresses, because "Login with AD account" links the accounts by email address (doc 05, section 4.1).

**Run on:** kubespray VM as k8s

## Order

| Step | Script | What it does | Changes something? |
|---|---|---|---|
| 1 | `enable-ox.sh` | Pre-check in Nubus (every user with `isOxUser` and an address `@MAIL_DOMAIN`, mail domain exists), then sets `global.mailDomain` and `apps.oxAppSuite.enabled: true`; keeps a copy of the old configuration (chmod 600) | Only if not enabled yet; `--force` for a different mail domain |
| 2 | `../03-opendesk/deploy-opendesk.sh --diff` | Shows what the rollout changes: 12 new `open-xchange-*` deployments, ox-connector, mail with the new domain | No |
| 3 | `../03-opendesk/deploy-opendesk.sh` (in tmux) | etcd backup, configuration and release list saved, `helmfile apply` (about 25 minutes), release list compared afterwards | Yes |
| 4 | `../ops/post-rollout.sh` | Enables `files_external` again (error F3) and adds the missing users to `managed-by-attribute-Groupware` (error F2), then runs the checks | Only what is missing |
| 5 | `../04-identity/configure-keycloak-realm.sh` | Sets the post-logout URI of the client – without it the logout ends with "Invalid redirect uri" (error F5) | Only if missing |
| 6 | `verify-ox.sh` | Configuration, releases `open-xchange`, `ox-connector`, `opendesk-open-xchange-bootstrap`, pods, certificate with `webmail` and `dav`, HTTP codes, OX Connector log, groupware group | No |

Then the acceptance in the browser stays manual (doc 05, section 9): two accounts in two **different** browsers, mail in both directions, a calendar invitation and the address book.

## After every rollout

The job `opendesk-nextcloud-management` switches `files_external` off on every `helmfile apply`, and Nubus fills the groupware group only when a user object changes. That is why [`../ops/post-rollout.sh`](../ops/post-rollout.sh) is mandatory after every rollout, not only after this part. `deploy-opendesk.sh` reminds you of it at the end.

## Testing on a running lab

```bash
./05-ox/enable-ox.sh --dry-run                    # expect: already enabled
./ops/post-rollout.sh --dry-run                   # expect: enabled, no member missing
./04-identity/configure-keycloak-realm.sh --dry-run
./05-ox/verify-ox.sh
./04-identity/verify-sso.sh                       # now also checks the post-logout URI
```

## Not automated

- Public mail (MX, smarthost, DKIM, spam filter), IMAP/SMTP and CalDAV/CardDAV clients – not set up in the lab (doc 05, section 14.4).
- Backup of mailboxes and the OX database: the Longhorn volumes have no backup target yet.
