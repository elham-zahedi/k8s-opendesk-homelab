#!/usr/bin/env bash
# 03 – Split DNS on the kubespray VM: only the openDesk and AD zones go to the
#      domain controller, everything else keeps using the gateway.
#
# Doc:     docs/03-opendesk-deployment.md (section 6.2, error F4)
# Run on:  kubespray VM as k8s
# Usage:   ./split-dns.sh [--dry-run]
#
#   --force   replace an existing file with different settings
#
# Writes /etc/systemd/resolved.conf.d/opendesk.conf if it is missing. An existing
# file with different settings is only replaced with --force.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars DOMAIN AD_DOMAIN AD_DC_IP LB_IP
CONF=/etc/systemd/resolved.conf.d/opendesk.conf
wanted="$(render_template "$AUTOMATION_DIR/03-opendesk/manifests/resolved-split-dns.conf" DOMAIN AD_DOMAIN AD_DC_IP)"
settings() { grep -vE '^\s*(#|$)' | sed 's/\s*$//'; }   # compare without comments and blank lines

step "1/2 $CONF"
if [[ -f "$CONF" ]] && diff -q <(settings <"$CONF") <(settings <<<"$wanted") >/dev/null; then
  ok "already configured"
else
  if [[ -f "$CONF" ]]; then
    warn "current content differs:"; indent '    ' <"$CONF"
    [[ "$FLAG_FORCE" == 1 ]] || die "not changed – check DOMAIN and AD_DOMAIN in lab.env, or replace the file with --force"
  fi
  run sudo mkdir -p "$(dirname "$CONF")"
  info "\$ write $CONF"
  if [[ "$DRY_RUN" == 1 ]]; then indent '    ' <<<"$wanted"; else sudo tee "$CONF" >/dev/null <<<"$wanted"; fi
  run sudo systemctl restart systemd-resolved
fi

[[ "$DRY_RUN" == 1 ]] && exit 0
step "2/2 Checks"
check "portal.$DOMAIN -> $LB_IP"       bash -c "getent hosts portal.$DOMAIN | grep -qw '$LB_IP'"
check "$AD_DOMAIN -> $AD_DC_IP"        bash -c "getent hosts $AD_DOMAIN | grep -qw '$AD_DC_IP'"
check "external names (github.com)"    getent hosts github.com
check "http://portal.$DOMAIN answers"  bash -c "curl -s -o /dev/null -m 5 -w '%{http_code}' http://portal.$DOMAIN | grep -qvx 000"
check_summary
