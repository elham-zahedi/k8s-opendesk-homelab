# 15 – openDesk Settings per Release: OpenProject, Element and OX

> Troubleshooting runbook. Previous: [14 – I/O errors after the nightly backup](14-backup-freeze-io-error.md) · Next: [16 – openDesk apps per AD group](16-app-access-by-ad-group.md) · Back to the [overview](../README.md)

**Summary:** The second installation of this setup also runs OpenProject, Element (chat) and OX App Suite. Three things needed a setting that openDesk v1.17.2 does not offer in its own configuration: the SSRF protection of OpenProject blocked the internal ingress address, the chat should run without end-to-end encryption, and OX got a new `CREDSTORAGE_PASSCRYPT` on every upgrade. openDesk can pass extra values files to a single release with `customization.release.<release>`. [`configure-customization.sh`](../automation/08-customization/configure-customization.sh) writes the three files and lists them there.

| Field | Value |
|---|---|
| Version | openDesk v1.17.2 (OpenProject 17.6, chart appsuite-public-sector 2.31.56) |
| Affected | Releases `openproject`, `opendesk-well-known`, `open-xchange` |
| Upstream | [#495](https://gitlab.opencode.de/bmi/opendesk/deployment/opendesk/-/work_items/495) (Element), [#499](https://gitlab.opencode.de/bmi/opendesk/deployment/opendesk/-/work_items/499) (OX, fixed in v1.20.0) |
| Not in the lab | The lab of [03](03-opendesk-deployment.md) switches OpenProject and Element off; the script skips apps that are switched off |

## 1. Extra values for one release

openDesk reads a list of extra values files for each release from `customization.release.<key>` in the environment configuration (`helmfile/environments/<env>/values.yaml.gotmpl`). The files are added after the values that openDesk sets for this release, so their values win. They live outside the openDesk repository, so a new openDesk version keeps them, and they take effect with the next rollout of their release.

```yaml
customization:
  release:
    openproject:
      - /home/k8s/opendesk-custom/openproject-ssrf.yaml
    opendeskWellKnown:
      - /home/k8s/opendesk-custom/element-e2ee.yaml
    openxchange:
      - /home/k8s/opendesk-custom/openxchange-passcrypt.yaml
```

The key is not always the name of the helmfile release:

| Key in `customization.release` | Helmfile release | Values file |
|---|---|---|
| `openproject` | `openproject` | `openproject-ssrf.yaml` (section 2) |
| `opendeskWellKnown` | `opendesk-well-known` | `element-e2ee.yaml` (section 3) |
| `openxchange` | `open-xchange` | `openxchange-passcrypt.yaml` (section 4) |

The files are in `CUSTOM_DIR` (default `~/opendesk-custom`), not in this repository, because the OX file holds a secret. The repository only has the templates in [`automation/08-customization/manifests/`](../automation/08-customization/manifests/).

## 2. OpenProject: the SSRF protection blocks the ingress address

**Symptom:** the seeder job of OpenProject failed. Besides the seeder, the login via Keycloak and the Nextcloud file storage also need outgoing requests from OpenProject to other openDesk hosts.

**Cause:** OpenProject 17.6 blocks outgoing requests to private IP addresses (SSRF protection, against requests that an attacker sends through the server to internal systems). In this setup every openDesk host name resolves to the MetalLB address of the ingress (`LB_IP`, [03](03-opendesk-deployment.md)), which is a private address.

**Fix:** [`openproject-ssrf.yaml`](../automation/08-customization/manifests/openproject-ssrf.yaml) allows exactly this one address, not the whole private range:

```yaml
environment:
  OPENPROJECT_SSRF_PROTECTION_IP_ALLOWLIST: "10.240.0.190"
  OPENPROJECT_SSRF__PROTECTION__IP__ALLOWLIST: "10.240.0.190"
  OPENPROJECT_SEED_DESIGN_LOGO: ""
  # … the other OPENPROJECT_SEED_DESIGN_* logo variables, also empty
```

The variable is set in both spellings that OpenProject uses for settings. The seeder downloads the openDesk logos with CarrierWave, whose SSRF check ignores the allowlist, so the whole seed failed. The logo variables are therefore empty: OpenProject keeps its own logos, the openDesk colours are still set.

**Check** after the rollout of `openproject`:

```bash
helm -n opendesk get values openproject | grep SSRF
```

✔ **Expected:** both variables with `LB_IP`.

## 3. Element: end-to-end encryption off

This is a decision, not a fix: in this lab the chat runs without end-to-end encryption. It is only written with `ELEMENT_E2EE_OFF=yes` in `lab.env`. Decide again before the chat is used for confidential messages.

[`element-e2ee.yaml`](../automation/08-customization/manifests/element-e2ee.yaml) sets `configuration.e2ee.forceDisable: true` for the release `opendesk-well-known`. Element reads `io.element.e2ee.force_disable` from `/.well-known/matrix/client`:

```bash
curl -s https://k8s.lab/.well-known/matrix/client | jq '."io.element.e2ee"'
```

✔ **Expected:** `"force_disable": true`.

> **Known issue:** Element still shows the toast "Verify this session" although the encryption is switched off. Reported upstream as [#495](https://gitlab.opencode.de/bmi/opendesk/deployment/opendesk/-/work_items/495).

To switch the encryption on again: set `ELEMENT_E2EE_OFF=no`, remove `element-e2ee.yaml` from `customization.release.opendeskWellKnown` by hand and roll out `opendesk-well-known`. The script does not remove entries; it only warns while the file is still listed.

## 4. OX App Suite: `CREDSTORAGE_PASSCRYPT` changes on every upgrade

**Symptom:** `helmfile diff` always showed a change for `open-xchange`, so every rollout upgraded the release and restarted the core-mw pods, even when nothing else had changed. The value differs after every upgrade:

```bash
kubectl -n opendesk get secret open-xchange-core-mw-secret-envvars \
  -o jsonpath='{.data.CREDSTORAGE_PASSCRYPT}' | base64 -d | sha256sum | cut -c1-12
```

All six revisions of the release had a different value (compared with `helm get manifest --revision N`).

**Cause:** openDesk v1.17.2 does not set `appsuite.core-mw.credstoragePasscrypt`, so the chart creates a new random value on each rollout. The credential storage is switched off in openDesk, so no stored credentials were lost; the cost were the needless diffs and restarts.

**Fix:** pin the running value. The script reads it from the secret and writes it to `openxchange-passcrypt.yaml` (chmod 600). It never prints the value, only the first 12 characters of its SHA-256 hash:

```yaml
appsuite:
  core-mw:
    credstoragePasscrypt: "<running value>"
```

After that, `helmfile diff` shows no change for `open-xchange` any more. The file is a secret: it stays in `CUSTOM_DIR`, and `.gitignore` excludes `*passcrypt*.yaml` in case a copy ends up in the repository.

**Upstream:** reported as [#499](https://gitlab.opencode.de/bmi/opendesk/deployment/opendesk/-/work_items/499) and fixed in openDesk v1.20.0, which sets the value from `secrets.oxAppSuite.sessiondEncryptionKey`. There is no backport to 1.17, 1.18 or 1.19. With the upgrade to v1.20.0 or later the value changes one last time and then stays the same; the file can be removed then. If it stays, the pinned value wins, which works too. The script skips this step when `OPENDESK_VERSION` is v1.20.0 or later.

## 5. Run

**Run on:** kubespray VM as k8s

```bash
cd ~/k8s-opendesk-homelab/automation
./08-customization/configure-customization.sh --dry-run
./08-customization/configure-customization.sh
```

The script never rolls anything out. For every release that got a new entry it prints the rollout command, e.g.:

```bash
HELMFILE_SELECTOR=name=open-xchange ./03-opendesk/deploy-opendesk.sh --diff
HELMFILE_SELECTOR=name=open-xchange ./03-opendesk/deploy-opendesk.sh
./ops/post-rollout.sh
```

✔ **Expected** on a second run: every line with ✔ and "nothing changed in the openDesk configuration – no rollout needed".

| `lab.env` | Default | Meaning |
|---|---|---|
| `CUSTOM_DIR` | `$HOME/opendesk-custom` | Folder for the values files, outside the repository |
| `OPENPROJECT_SSRF_ALLOW` | `yes` | Write `openproject-ssrf.yaml` when OpenProject is switched on |
| `ELEMENT_E2EE_OFF` | `no` | `yes` = chat without end-to-end encryption |
| `OX_PIN_PASSCRYPT` | `yes` | Pin `CREDSTORAGE_PASSCRYPT` (only before v1.20.0) |

## 6. Takeaways

- Settings that openDesk does not offer belong in `customization.release`, not in the openDesk repository: they survive a new openDesk version.
- A `helmfile diff` that never goes away is worth a look. Here it was a secret that the chart generated again on every rollout.
- Values files with secrets stay outside the repository (chmod 600, `.gitignore`).
- Problems found in openDesk itself are worth reporting: #499 was fixed in the next release.

---

Previous: [14 – I/O errors after the nightly backup](14-backup-freeze-io-error.md) · Next: [16 – openDesk apps per AD group](16-app-access-by-ad-group.md) · Back to the [overview](../README.md)
