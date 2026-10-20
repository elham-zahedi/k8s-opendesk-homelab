# 04 – Active Directory, file server and single sign-on

Scripts for [docs/04 – Active Directory and SSO](../../docs/04-active-directory-sso.md).
All names (domain, DC, OUs, service accounts, shares, realm) are in section "04" of `lab.env`; derived names such as `DC=lab,DC=local` or `https://idp.k8s.lab/auth` are calculated from them.

**Run on:** kubespray VM as k8s – the PowerShell scripts in [`../windows/`](../windows/) on the domain controller and the file server.

## Order

| Step | Script | What it does | Changes something? |
|---|---|---|---|
| 1 | `check-prerequisites.sh` | openDesk version, DNS names from a pod (DC, FS, idp, SRV record), ports 389/636/445, LDAPS certificate | No |
| 2 | `../windows/ad-inventory.ps1 -ExportCA` (DC) | Users, groups, AD CS, service accounts, service group; exports the root CA as PEM | Writes the CA file on the DC |
| 3 | `fetch-ad-files.sh` | Copies root CA and test accounts from the DC, converts UTF-16/CRLF, verifies LDAPS | Only missing files |
| 4 | `setup-directory-importer.sh` | Namespace, secrets, OU and mail domain in Nubus, values file, Helm release | Only what is missing; `--force` after a changed Nubus password |
| 5 | `verify-directory-importer.sh` | Release, sync cycles, number of users and groups in Nubus | No |
| 6 | `setup-smb-storage.sh` | SMB CSI driver, `nls_utf8` via [`prepare-nodes-smb.yml`](prepare-nodes-smb.yml), SMB secret, PV + PVC per share | Only what is missing |
| 7 | `patch-nextcloud-volumes.sh` | Adds the SMB volumes to `values-nextcloud.yaml.gotmpl` (found by content, not line numbers) and saves the change as a patch | Only if not patched yet |
| 8 | `HELMFILE_SELECTOR=name=opendesk-nextcloud ../03-opendesk/deploy-opendesk.sh` | Rolls out Nextcloud with the volumes | Yes |
| 9 | `enable-fileshare-groups.sh` | Enables `files_external`, releases the groups of the mount list in Nubus | Only groups not released yet |
| 10 | `nc-mounts.sh [--apply]` | Creates the 27 mounts of [`manifests/nc-mounts.csv`](manifests/nc-mounts.csv); plan only without `--apply` | With `--apply` |
| 11 | `verify-nextcloud-files.sh` | `nls_utf8` on all nodes, write test in every data directory, every mount compared with the list | No (test files) |
| 12 | `setup-keycloak-idp.sh` | Passwords, PostgreSQL, CA copy, certificate, Keycloak release; renews the CA copy when the openDesk CA was renewed | Only what is missing |
| 13 | `configure-keycloak-realm.sh` | Realm, LDAP provider to AD, username mapper, OIDC client – via the admin REST API | Only what is missing; `--force` corrects |
| 14 | `configure-sso.sh` | Adds the `ssoFederation` block with the client secret to the openDesk configuration | Only if missing |
| 15 | `HELMFILE_SELECTOR=name=opendesk-keycloak-bootstrap ../03-opendesk/deploy-opendesk.sh` | Creates the identity provider in openDesk | Yes |
| 16 | `verify-sso.sh` | Keycloak, issuer from outside and from a pod, certificates, users in the realm, client, secret, identity provider in openDesk | No (test pod) |
| 17 | `../windows/set-test-passwords.ps1` (DC) | Test password for the browser test; `-RequireChangeAtLogon` afterwards | Yes |

The browser test with one login per test account stays manual (doc 04, section 20).

## Secrets

Passwords of the AD service accounts are asked for (hidden input) only when the secret that needs them does not exist yet – or read from `AD_IMPORT_PASSWORD`, `SMB_PASSWORD` and `AD_KEYCLOAK_PASSWORD`. All values go to `kubectl` and `curl` on stdin, never as command-line arguments. The Keycloak passwords are generated once (chmod 600) and never replaced. The client secret is copied from Keycloak into the openDesk configuration without being printed. Log lines of the importer are only counted, because some of them contain generated placeholder passwords.

## After changes

| Event | Run |
|---|---|
| Kernel update (before rebooting the nodes) | `setup-smb-storage.sh` – installs `linux-modules-extra` also for the newest installed kernel |
| Nubus administrator password changed | `setup-directory-importer.sh --force` |
| openDesk CA renewed by cert-manager | `setup-keycloak-idp.sh`, then `../03-opendesk/export-ca.sh` and `../windows/import-ca.ps1` |
| openDesk update | `patch-nextcloud-volumes.sh`, `nc-mounts.sh` (only `SKIP`), `verify-nextcloud-files.sh`, `verify-sso.sh` |

## Testing on a running lab

```bash
./04-identity/check-prerequisites.sh
./04-identity/fetch-ad-files.sh                   # files exist: verify only
./04-identity/setup-directory-importer.sh --dry-run
./04-identity/verify-directory-importer.sh
./04-identity/setup-smb-storage.sh --dry-run      # node preparation in check mode
./04-identity/patch-nextcloud-volumes.sh --dry-run
./04-identity/enable-fileshare-groups.sh --dry-run
./04-identity/nc-mounts.sh                        # plan only: expect 27 × SKIP
./04-identity/verify-nextcloud-files.sh
./04-identity/setup-keycloak-idp.sh --dry-run
./04-identity/configure-keycloak-realm.sh --dry-run
./04-identity/configure-sso.sh --dry-run
./04-identity/verify-sso.sh
```
