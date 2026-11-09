#!/usr/bin/env bash
# 08 – Values files for single openDesk releases (customization.release.<release>):
#      OpenProject  – the SSRF protection allows the ingress address LB_IP
#      Element      – end-to-end encryption off (only with ELEMENT_E2EE_OFF=yes)
#      OX App Suite – CREDSTORAGE_PASSCRYPT stays the same over upgrades (before v1.20.0)
#
# Doc:     docs/15-opendesk-customization.md
# Run on:  kubespray VM as k8s
# Usage:   ./configure-customization.sh [--dry-run]
#
# 1. Writes the values files to CUSTOM_DIR – outside the repository, because the OX file
#    holds a secret (chmod 600). An existing file with a different content is never
#    overwritten: the difference is shown (for the OX file only a fingerprint).
# 2. Lists them in customization.release.<release> of the openDesk configuration
#    (backup: values.yaml.gotmpl.bak-…).
# 3. Rolls nothing out: every file takes effect with the next rollout of its release; the
#    script prints the commands.
# Apps that are switched off in the configuration (apps.<app>.enabled: false) are skipped.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_DIR OPENDESK_ENV OPENDESK_NAMESPACE OPENDESK_VERSION LB_IP
require_cmd yq
CUSTOM_DIR="${CUSTOM_DIR:-$HOME/opendesk-custom}"
OPENPROJECT_SSRF_ALLOW="${OPENPROJECT_SSRF_ALLOW:-yes}"
ELEMENT_E2EE_OFF="${ELEMENT_E2EE_OFF:-no}"
OX_PIN_PASSCRYPT="${OX_PIN_PASSCRYPT:-yes}"
MANIFESTS="$AUTOMATION_DIR/08-customization/manifests"
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
[[ -f "$VALUES" ]] || die "$VALUES not found – run 03-opendesk/prepare-opendesk.sh first"
NS="$OPENDESK_NAMESPACE"
# key in customization.release -> name of the helmfile release
declare -A RELEASE=([openproject]=openproject [opendeskWellKnown]=opendesk-well-known [openxchange]=open-xchange)
ROLLOUT=()
BACKUP=""

# app_enabled APP – false only if the configuration switches the app off
app_enabled() { [[ "$(yq ".apps.$1.enabled" "$VALUES")" != false ]]; }
# listed KEY FILE – true if customization.release.KEY lists FILE
listed() { R="$1" F="$2" yq -e '(.customization.release[strenv(R)] // []) | any_c(. == strenv(F))' "$VALUES" >/dev/null 2>&1; }
fingerprint() { printf '%s' "$1" | sha256sum | cut -c1-12; }
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

DIR_SHOWN=0
ensure_dir() {
  [[ -d "$CUSTOM_DIR" || "$DIR_SHOWN" == 1 ]] && return 0
  DIR_SHOWN=1
  run mkdir -p -m 700 "$CUSTOM_DIR"
}

# put_file NAME – writes stdin to CUSTOM_DIR/NAME, unless that file exists with a different content
put_file() {
  local dst="$CUSTOM_DIR/$1" tmp; tmp="$(mktemp)"
  cat >"$tmp"
  if [[ ! -f "$dst" ]]; then
    ensure_dir
    info "\$ write $dst"
    [[ "$DRY_RUN" == 1 ]] || install -m 644 "$tmp" "$dst"
  elif yaml_same "$dst" "$tmp"; then
    ok "$dst: same content as the manifest"
  else
    warn "$dst differs from the manifest – left unchanged (< manifest, > file):"
    diff <(yq -P 'sort_keys(..)' "$tmp") <(yq -P 'sort_keys(..)' "$dst") | indent '    ' >&2 || true
  fi
  rm -f "$tmp"
}

# add_to_release KEY FILE – lists FILE in customization.release.KEY
add_to_release() {
  local key="$1" file="$2"
  if listed "$key" "$file"; then ok "customization.release.$key lists $file"; return 0; fi
  info "\$ add $file to customization.release.$key"
  if [[ "$DRY_RUN" != 1 ]]; then
    if [[ -z "$BACKUP" ]]; then
      BACKUP="$VALUES.bak-$(date +%Y%m%d-%H%M%S)"
      cp -p "$VALUES" "$BACKUP"
      info "backup: $BACKUP"
    fi
    R="$key" F="$file" yq -i '.customization.release[strenv(R)] = ((.customization.release[strenv(R)] // []) + [strenv(F)])' "$VALUES"
    chmod 600 "$VALUES"
  fi
  ROLLOUT+=("$key")
}

# ------------------------------------------------------------------------------
step "1/3 OpenProject: the SSRF protection allows $LB_IP"
if ! app_enabled openproject; then
  info "OpenProject is switched off in the configuration – skipped"
elif [[ "$OPENPROJECT_SSRF_ALLOW" != yes ]]; then
  info "OPENPROJECT_SSRF_ALLOW=$OPENPROJECT_SSRF_ALLOW – skipped"
else
  ssrf="$(render_template "$MANIFESTS/openproject-ssrf.yaml" LB_IP)"
  put_file openproject-ssrf.yaml <<<"$ssrf"
  add_to_release openproject "$CUSTOM_DIR/openproject-ssrf.yaml"
fi

# ------------------------------------------------------------------------------
step "2/3 Element: end-to-end encryption"
e2ee_file="$CUSTOM_DIR/element-e2ee.yaml"
if ! app_enabled element; then
  info "Element is switched off in the configuration – skipped"
elif [[ "$ELEMENT_E2EE_OFF" != yes ]]; then
  info "ELEMENT_E2EE_OFF=$ELEMENT_E2EE_OFF – Element keeps the encryption as openDesk ships it"
  if listed opendeskWellKnown "$e2ee_file"; then
    warn "customization.release.opendeskWellKnown still lists $e2ee_file – remove it by hand to switch the encryption on again (doc 15, section 3)"
  fi
else
  put_file element-e2ee.yaml <"$MANIFESTS/element-e2ee.yaml"
  add_to_release opendeskWellKnown "$e2ee_file"
fi

# ------------------------------------------------------------------------------
step "3/3 OX App Suite: CREDSTORAGE_PASSCRYPT stays the same over upgrades"
ox_file="$CUSTOM_DIR/openxchange-passcrypt.yaml"
if ! app_enabled oxAppSuite; then
  info "OX App Suite is switched off in the configuration – skipped"
elif [[ "$OX_PIN_PASSCRYPT" != yes ]]; then
  info "OX_PIN_PASSCRYPT=$OX_PIN_PASSCRYPT – skipped"
elif version_ge "${OPENDESK_VERSION#v}" 1.20.0; then
  info "openDesk $OPENDESK_VERSION keeps the value itself (upstream issue #499) – nothing to pin"
  if listed openxchange "$ox_file"; then
    info "$ox_file is still listed: the pinned value wins, which works too; it can be removed (doc 15, section 4)"
  fi
else
  require_cmd jq
  use_kubectl
  live="$(secret_value "$NS" open-xchange-core-mw-secret-envvars CREDSTORAGE_PASSCRYPT 2>/dev/null || true)"
  if [[ -z "$live" ]]; then
    warn "the secret open-xchange-core-mw-secret-envvars has no CREDSTORAGE_PASSCRYPT yet – run this script again after the first rollout of OX"
  else
    info "running value: sha256 $(fingerprint "$live")… (the value itself is never printed)"
    if [[ -f "$ox_file" ]]; then
      pinned="$(yq '.appsuite."core-mw".credstoragePasscrypt // ""' "$ox_file")"
      if [[ "$pinned" == "$live" ]]; then
        ok "$ox_file pins the running value"
      else
        warn "$ox_file pins sha256 $(fingerprint "$pinned")… – left unchanged; the next rollout of open-xchange sets the secret to the pinned value"
      fi
      [[ "$(stat -c %a "$ox_file")" == 600 ]] || run chmod 600 "$ox_file"
    else
      ensure_dir
      info "\$ write $ox_file (chmod 600) with the running value"
      if [[ "$DRY_RUN" != 1 ]]; then
        ( umask 077
          V="$live" yq -n '.appsuite."core-mw".credstoragePasscrypt = strenv(V)
            | .appsuite."core-mw".credstoragePasscrypt style = "double"
            | . head_comment = "OX CREDSTORAGE_PASSCRYPT, pinned by configure-customization.sh (doc 15, section 4).\nSECRET: chmod 600, never commit."' >"$ox_file" )
      fi
    fi
    add_to_release openxchange "$ox_file"
  fi
  unset live pinned
fi

# ------------------------------------------------------------------------------
step "Next"
if [[ ${#ROLLOUT[@]} -eq 0 ]]; then
  ok "nothing changed in the openDesk configuration – no rollout needed"
else
  info "the files take effect with the next rollout of their release:"
  for key in $(printf '%s\n' "${ROLLOUT[@]}" | sort -u); do
    info "  HELMFILE_SELECTOR=name=${RELEASE[$key]} ./03-opendesk/deploy-opendesk.sh --diff    # then without --diff"
  done
  info "  ./ops/post-rollout.sh"
fi
