# 08 – openDesk settings per release

Script for [docs/15 – openDesk settings per release](../../docs/15-opendesk-customization.md).
The values files go to `CUSTOM_DIR` (default `~/opendesk-custom`), outside the repository, because the OX file holds a secret. The settings are in section "08" of `lab.env`.

**Run on:** kubespray VM as k8s

## Order

| Step | Script | What it does | Changes something? |
|---|---|---|---|
| 1 | `configure-customization.sh --dry-run` | Shows which files would be written and listed | No |
| 2 | `configure-customization.sh` | Writes the missing files to `CUSTOM_DIR` and lists them in `customization.release.<release>` (backup of the configuration first). Existing files with a different content are not overwritten | Only what is missing |
| 3 | `../03-opendesk/deploy-opendesk.sh` with `HELMFILE_SELECTOR=name=<release>` | Rollout of each release that got a new entry – the script prints the commands | Yes |
| 4 | `../ops/post-rollout.sh` | The usual checks after every rollout | Only what is missing |

| File | Release | When |
|---|---|---|
| [`manifests/openproject-ssrf.yaml`](manifests/openproject-ssrf.yaml) | `openproject` | OpenProject switched on and `OPENPROJECT_SSRF_ALLOW=yes`; `@LB_IP@` is replaced |
| [`manifests/element-e2ee.yaml`](manifests/element-e2ee.yaml) | `opendesk-well-known` | Element switched on and `ELEMENT_E2EE_OFF=yes` |
| `openxchange-passcrypt.yaml` (written from the running secret, chmod 600) | `open-xchange` | OX switched on, `OX_PIN_PASSCRYPT=yes` and openDesk before v1.20.0 |

## Not automated

- Removing an entry from `customization.release`, e.g. to switch the chat encryption on again or after the upgrade to openDesk v1.20.0 – a deliberate step by hand (doc 15, sections 3 and 4).
