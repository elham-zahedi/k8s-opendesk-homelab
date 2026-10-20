#!/usr/bin/env bash
# 04 – Add "Login with AD account" to the openDesk configuration.
#
# Doc:     docs/04-active-directory-sso.md (section 19.3)
# Run on:  kubespray VM as k8s, after configure-keycloak-realm.sh
# Usage:   ./configure-sso.sh [--dry-run] [--force]
#
#   --force   replace a different ssoFederation block or client secret
#
# Merges manifests/sso-federation.yaml into helmfile/environments/<env>/values.yaml.gotmpl.
# The client secret is read from the Keycloak admin API and written straight into
# the file – it is never printed and never stored in the repository. The file is
# outside Git (.gitignore of openDesk) and gets permissions 600.
# Afterwards: HELMFILE_SELECTOR=name=opendesk-keycloak-bootstrap ./03-opendesk/deploy-opendesk.sh

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars OPENDESK_DIR OPENDESK_ENV DOMAIN IDP_HOST IDP_REALM IDP_CLIENT IDP_KEY IDP_DISPLAY_NAME
identity_vars
require_cmd yq jq curl
use_kubectl
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
[[ -f "$VALUES" ]] || die "$VALUES not found – run 03-opendesk/prepare-opendesk.sh first"
TMP="$(mktemp)"; add_exit_hook "rm -f $TMP"
render_template "$AUTOMATION_DIR/04-identity/manifests/sso-federation.yaml" \
  IDP_KEY IDP_DISPLAY_NAME IDP_URL IDP_REALM IDP_CLIENT >"$TMP"
SECRET_PATH=".functional.authentication.ssoFederation.idps[\"$IDP_KEY\"].idpDetails.config.clientSecret"
sha() { sha256sum | cut -d' ' -f1; }

step "1/3 Client secret of $IDP_CLIENT (realm $IDP_REALM)"
kc_connect
kc GET "/$IDP_REALM/clients?clientId=$IDP_CLIENT"
CID="$(jq -r '.[0].id // empty' "$KC_BODY" 2>/dev/null || true)"
[[ -n "$CID" ]] || die "client $IDP_CLIENT not found in realm $IDP_REALM – run configure-keycloak-realm.sh first"
kc GET "/$IDP_REALM/clients/$CID/client-secret"
CS="$(jq -r '.value // empty' "$KC_BODY")"; : >"$KC_BODY"
[[ -n "$CS" ]] || die "could not read the client secret"
ok "read from Keycloak (${#CS} characters, not shown)"

step "2/3 ssoFederation in $(basename "$VALUES")"
norm='del(.functional.authentication.ssoFederation.idps[].idpDetails.config.clientSecret) | .functional.authentication.ssoFederation | sort_keys(..)'
if [[ "$(yq '.functional.authentication.ssoFederation' "$VALUES")" == null ]]; then
  action=add
elif diff -q <(yq -o=json "$norm" "$VALUES") <(yq -o=json "$norm" "$TMP") >/dev/null; then
  ok "settings match manifests/sso-federation.yaml"; action=none
else
  diff <(yq -P "$norm" "$VALUES") <(yq -P "$norm" "$TMP") | indent '    ' || true
  [[ "$FLAG_FORCE" == 1 ]] || die "the ssoFederation block differs (see above) – check lab.env, or replace it with --force"
  action=replace
fi
if [[ "$action" != none ]]; then
  info "\$ $action the ssoFederation block (backup: $(basename "$VALUES").bak-…)"
  if [[ "$DRY_RUN" != 1 ]]; then
    cp -p "$VALUES" "$VALUES.bak-$(date +%Y%m%d-%H%M%S)"
    [[ "$action" == replace ]] && yq -i 'del(.functional.authentication.ssoFederation)' "$VALUES"
    yq -i ". *= load(\"$TMP\")" "$VALUES"
  fi
fi

current_sha="$(yq "$SECRET_PATH // \"\"" "$VALUES" | tr -d '\n' | sha)"
if [[ "$current_sha" == "$(printf '%s' "$CS" | sha)" ]]; then
  ok "client secret in the configuration matches Keycloak"
elif [[ "$action" != none || "$FLAG_FORCE" == 1 ]]; then
  info "\$ write the client secret into the configuration (not shown)"
  [[ "$DRY_RUN" == 1 ]] || CS="$CS" yq -i "$SECRET_PATH = strenv(CS)" "$VALUES"
else
  die "the client secret in the configuration differs from Keycloak – replace it with --force"
fi
unset CS
[[ "$DRY_RUN" == 1 ]] || chmod 600 "$VALUES"

step "3/3 Checks"
if [[ "$DRY_RUN" != 1 ]]; then
  check "values file is valid YAML"                    yq '.' "$VALUES"
  check "issuer $IDP_URL/realms/$IDP_REALM"            test "$(yq ".functional.authentication.ssoFederation.idps[\"$IDP_KEY\"].idpDetails.config.issuer" "$VALUES")" = "$IDP_URL/realms/$IDP_REALM"
  check "file permissions 600 (contains the client secret)" test "$(stat -c %a "$VALUES")" = 600
  check "values file is ignored by git"                git -C "$OPENDESK_DIR" check-ignore -q "$VALUES"
fi
if [[ "$action" != none ]]; then
  info "Next: HELMFILE_SELECTOR=name=opendesk-keycloak-bootstrap ./03-opendesk/deploy-opendesk.sh"
fi
if [[ "$CHECKS_FAILED" -gt 0 ]]; then check_summary; fi
