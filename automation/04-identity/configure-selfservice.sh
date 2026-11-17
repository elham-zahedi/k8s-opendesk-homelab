#!/usr/bin/env bash
# 04 – Self-service of the portal for accounts from AD: the password lives in AD, so
#      changing or resetting the (unused) openDesk password is switched off and the
#      profile only offers the photo.
#
# Doc:     docs/04-active-directory-sso.md (section 19.6)
# Run on:  kubespray VM as k8s – ops/post-rollout.sh runs it after every rollout
# Usage:   ./configure-selfservice.sh [--dry-run]
#
# 1. customization.release.ums in the openDesk configuration lists SELFSERVICE_VALUES
#    (default manifests/ums-selfservice.yaml); it takes effect with the next rollout of
#    the release "ums".
# 2. The menu entries "Mein Passwort ändern" and "Meine Passwort-Reset Optionen" are
#    deactivated. A rollout of "ums" activates them again.
# 3. The profile fields of the running umc-server match the values file. Nubus keeps its
#    own default for self-service/udm_attributes in the same ConfigMap; if it wins, the
#    line is corrected and umc-server restarted (the portal self-service and admin
#    pages are away for about a minute – login, files and mail are not affected).
# SELFSERVICE_VALUES empty in lab.env = self-service stays as openDesk ships it.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_DIR OPENDESK_ENV OPENDESK_NAMESPACE
require_cmd jq yq curl
SELFSERVICE_VALUES="${SELFSERVICE_VALUES-$AUTOMATION_DIR/04-identity/manifests/ums-selfservice.yaml}"
if [[ -z "$SELFSERVICE_VALUES" ]]; then
  info "SELFSERVICE_VALUES is empty – the self-service stays as openDesk ships it"; exit 0
fi
[[ -f "$SELFSERVICE_VALUES" ]] || die "$SELFSERVICE_VALUES not found"
use_kubectl
NS="$OPENDESK_NAMESPACE"
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
[[ -f "$VALUES" ]] || die "$VALUES not found – run 03-opendesk/prepare-opendesk.sh first"
WANT="$(yq '.global.configUcr."self-service/udm_attributes" // .global.configUcr."self-service".udm_attributes // ""' "$SELFSERVICE_VALUES")"
[[ -n "$WANT" ]] || die "no self-service/udm_attributes in $SELFSERVICE_VALUES"
HIDE=(swp.selfservice.change_password swp.selfservice.protect_account)
UMC_POD="ums-umc-server-0"
KEY="self-service/udm_attributes"

# ------------------------------------------------------------------------------
step "1/3 $(basename "$SELFSERVICE_VALUES") in the openDesk configuration"
if SV="$SELFSERVICE_VALUES" yq -e '(.customization.release.ums // []) | any_c(. == strenv(SV))' "$VALUES" >/dev/null 2>&1; then
  ok "customization.release.ums lists $SELFSERVICE_VALUES"
else
  info "\$ add $SELFSERVICE_VALUES to customization.release.ums (backup: $(basename "$VALUES").bak-…)"
  if [[ "$DRY_RUN" != 1 ]]; then
    cp -p "$VALUES" "$VALUES.bak-$(date +%Y%m%d-%H%M%S)"
    SV="$SELFSERVICE_VALUES" yq -i '.customization.release.ums = ((.customization.release.ums // []) + [strenv(SV)] | unique)' "$VALUES"
    chmod 600 "$VALUES"
  fi
  warn "takes effect with the next rollout: HELMFILE_SELECTOR=name=ums ./03-opendesk/deploy-opendesk.sh, then ./ops/post-rollout.sh"
fi

# ------------------------------------------------------------------------------
step "2/3 Menu entries for the openDesk password"
udm_connect
for e in "${HIDE[@]}"; do
  udm GET "portals/entry/?filter=$(urlencode "cn=$e")&properties=activated"
  dn="$(jq -r '._embedded["udm:object"][0].dn // empty' "$UDM_BODY")"
  if [[ -z "$dn" ]]; then info "$e does not exist in this openDesk version – nothing to hide"; continue; fi
  if [[ "$(jq -r '._embedded["udm:object"][0].properties.activated' "$UDM_BODY")" == false ]]; then
    ok "$e hidden"; continue
  fi
  info "\$ PATCH $e activated=false"
  [[ "$DRY_RUN" == 1 ]] && continue
  udm PATCH "portals/entry/$(urlencode "$dn")" '{"properties":{"activated":false}}'
  check "$e hidden (HTTP $UDM_STATUS)" test "$UDM_STATUS" = 204
done

# ------------------------------------------------------------------------------
step "3/3 Profile fields in the portal: $WANT"
ucr_lines() { kubectl -n "$NS" get configmap ums-stack-data-ums-ucr -o json | jq -r '.data["base.conf"] // ""' | grep "^$KEY: " || true; }
running() { kubectl -n "$NS" exec "$UMC_POD" -c main -- ucr get "$KEY" 2>/dev/null || true; }
lines="$(ucr_lines)"
if ! grep -qx "$KEY: $WANT" <<<"$lines"; then
  info "the values file is not rolled out yet – after the next rollout of ums this step corrects the rest"
else
  restart=0
  # several lines with the same key: the last one wins
  if [[ "$(tail -1 <<<"$lines")" != "$KEY: $WANT" || "$(sort -u <<<"$lines" | wc -l)" -gt 1 ]]; then
    warn "the Nubus default is also in ums-stack-data-ums-ucr – every $KEY line is set to $WANT"
    info "\$ kubectl replace configmap ums-stack-data-ums-ucr (base.conf)"
    if [[ "$DRY_RUN" != 1 ]]; then
      kubectl -n "$NS" get configmap ums-stack-data-ums-ucr -o json \
        | jq --arg k "$KEY: " --arg w "$WANT" '.data["base.conf"] |= (split("\n")
            | map(if startswith($k) then $k + $w else . end) | join("\n"))' \
        | kubectl replace -f - >/dev/null
    fi
    restart=1
  fi
  got="$(running)"
  if [[ "$got" != "$WANT" ]]; then info "umc-server still shows: $got"; restart=1; fi
  if [[ "$restart" == 1 ]]; then
    run kubectl -n "$NS" delete pod "$UMC_POD"
    if [[ "$DRY_RUN" != 1 ]]; then
      sleep 5
      kubectl -n "$NS" wait --for=condition=Ready "pod/$UMC_POD" --timeout=5m >/dev/null
    fi
  fi
  [[ "$DRY_RUN" == 1 ]] || check "umc-server shows only: $WANT (got: $(running))" test "$(running)" = "$WANT"
fi

if [[ "$CHECKS_FAILED" -gt 0 ]]; then check_summary; fi
