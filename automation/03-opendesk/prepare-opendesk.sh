#!/usr/bin/env bash
# 03 – Get the openDesk repository, write the configuration and create the master password.
#
# Doc:     docs/03-opendesk-deployment.md (sections 9 and 10)
# Run on:  kubespray VM as k8s
# Usage:   ./prepare-opendesk.sh [--dry-run] [--force]
#
#   --force   replace an existing values file (a backup is kept)
#
# An existing configuration is never overwritten without --force: the script only
# compares it with manifests/opendesk-values.yaml.gotmpl and reports the differences
# (sections 04 and 05 extend the file, so some differences are expected later).
# An existing master password file is NEVER replaced – a new master password would
# no longer match the databases.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars OPENDESK_VERSION OPENDESK_REPO OPENDESK_DIR OPENDESK_ENV DOMAIN MASTER_PASSWORD_FILE
require_cmd git yq openssl
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
TEMPLATE="$AUTOMATION_DIR/03-opendesk/manifests/opendesk-values.yaml.gotmpl"

step "1/3 openDesk repository $OPENDESK_VERSION in $OPENDESK_DIR"
if [[ -d "$OPENDESK_DIR/.git" ]]; then
  current="$(git -C "$OPENDESK_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
  if [[ "$current" == "$OPENDESK_VERSION" ]]; then
    ok "already checked out ($current) – left unchanged"
  else
    warn "$OPENDESK_DIR is at '$current', expected $OPENDESK_VERSION – left unchanged (updates are a manual step)"
  fi
else
  run git clone -q "$OPENDESK_REPO" "$OPENDESK_DIR"
  run git -C "$OPENDESK_DIR" -c advice.detachedHead=false checkout -q "$OPENDESK_VERSION"
fi

step "2/3 Configuration $VALUES"
wanted="$(render_template "$TEMPLATE" DOMAIN)"
if [[ ! -f "$VALUES" || "$FLAG_FORCE" == 1 ]]; then
  if [[ -f "$VALUES" ]]; then run cp -p "$VALUES" "$VALUES.bak-$(date +%Y%m%d-%H%M%S)"; fi
  run mkdir -p "$(dirname "$VALUES")"
  info "\$ write $VALUES"
  if [[ "$DRY_RUN" == 1 ]]; then indent '    ' <<<"$wanted"; else printf '%s\n' "$wanted" > "$VALUES"; fi
else
  ok "exists – left unchanged. Comparison with the repository template:"
  same=0; diffs=0
  while IFS= read -r p; do
    a="$(yq ".$p" "$VALUES" 2>/dev/null || echo '<unreadable>')"
    b="$(yq ".$p" <<<"$wanted")"
    if [[ "$a" == "$b" ]]; then same=$((same + 1)); else diffs=$((diffs + 1)); warn "$p: file '$a', template '$b'"; fi
  done < <(yq '.. | select(tag != "!!map" and tag != "!!seq") | path | join(".")' <<<"$wanted")
  info "$same setting(s) identical, $diffs different"
fi
if [[ "$DRY_RUN" != 1 ]]; then
  check "values file is valid YAML" yq '.' "$VALUES"
  check "values file is ignored by git (never committed)" git -C "$OPENDESK_DIR" check-ignore -q "$VALUES"
fi

step "3/3 Master password $MASTER_PASSWORD_FILE"
if [[ -s "$MASTER_PASSWORD_FILE" ]]; then
  ok "exists ($(wc -c <"$MASTER_PASSWORD_FILE") characters) – never replaced"
  check "file permissions 600" test "$(stat -c %a "$MASTER_PASSWORD_FILE")" = 600
else
  info "\$ openssl rand -base64 32 | tr -d '\\n' > $MASTER_PASSWORD_FILE"
  if [[ "$DRY_RUN" != 1 ]]; then
    ( umask 077; openssl rand -base64 32 | tr -d '\n' > "$MASTER_PASSWORD_FILE" )
    chmod 600 "$MASTER_PASSWORD_FILE"
    ok "created ($(wc -c <"$MASTER_PASSWORD_FILE") characters)"
  fi
  warn "store the content in a password manager and in the backup – never in Git"
fi

if [[ "$DRY_RUN" != 1 && "$CHECKS_FAILED" -gt 0 ]]; then check_summary; fi
echo
info "Next (in tmux): ./03-opendesk/deploy-opendesk.sh --render, then ./03-opendesk/deploy-opendesk.sh"
