#!/usr/bin/env bash
# 05 – Enable OX App Suite (mail, calendar, contacts) in the openDesk configuration.
#
# Doc:     docs/05-ox-app-suite.md (sections 2 – 4)
# Run on:  kubespray VM as k8s
# Usage:   ./enable-ox.sh [--dry-run] [--force]
#
#   --force   change the configuration even if the pre-check fails or a different
#             global.mailDomain is set
#
# Pre-check in Nubus: every imported user has the groupware permission (isOxUser)
# and an address @MAIL_DOMAIN, and the mail domain exists. MAIL_DOMAIN must be the
# domain of the AD mail addresses – "Login with AD account" links the accounts by
# email address (doc 05, section 4.1).
# Then sets global.mailDomain and apps.oxAppSuite.enabled = true. A copy of the old
# configuration is kept (chmod 600 – it contains the client secret). Afterwards:
#   ./03-opendesk/deploy-opendesk.sh --diff     review the changes
#   ./03-opendesk/deploy-opendesk.sh            rollout, about 25 minutes (in tmux)
#   ./ops/post-rollout.sh                       mandatory after every rollout
#   ./05-ox/verify-ox.sh

# shellcheck disable=SC2016  # $variables inside single quotes are jq variables
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars OPENDESK_DIR OPENDESK_ENV MAIL_DOMAIN NUBUS_OU NUBUS_BASE_DN OPENDESK_NAMESPACE
identity_vars
require_cmd yq jq curl
use_kubectl
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
[[ -f "$VALUES" ]] || die "$VALUES not found"

step "1/2 Pre-check: users in Nubus (ou=$NUBUS_OU)"
udm_connect
udm GET "users/user/?position=$(urlencode "ou=$NUBUS_OU,$NUBUS_BASE_DN")&scope=sub&properties=isOxUser&properties=mailPrimaryAddress"
[[ "$UDM_STATUS" == 200 ]] || die "reading the users failed (HTTP $UDM_STATUS)"
read -r total ox mail <<<"$(jq -r --arg d "@$MAIL_DOMAIN" '._embedded["udm:object"] | [length,
  ([.[] | select(.properties.isOxUser == true)] | length),
  ([.[] | select(.properties.mailPrimaryAddress | tostring | ascii_downcase | endswith($d | ascii_downcase))] | length)] | @tsv' "$UDM_BODY")"
info "users: $total, isOxUser = true: $ox, address @$MAIL_DOMAIN: $mail"
check "users imported"                                    test "$total" -gt 0
check "every user has the groupware permission (isOxUser)" test "$ox" -eq "$total"
check "every user has an address @$MAIL_DOMAIN"           test "$mail" -eq "$total"
check "mail domain $MAIL_DOMAIN exists in Nubus" test "$(udm_count "mail/domain/?filter=$(urlencode "cn=$MAIL_DOMAIN")")" -ge 1
PRE_FAILED="$CHECKS_FAILED"

step "2/2 Configuration $(basename "$VALUES")"
cur_md="$(yq '.global.mailDomain // ""' "$VALUES")"
cur_ox="$(yq '.apps.oxAppSuite.enabled // false' "$VALUES")"
info "now: global.mailDomain = '${cur_md}', apps.oxAppSuite.enabled = $cur_ox"
if [[ "$cur_md" == "$MAIL_DOMAIN" && "$cur_ox" == true ]]; then
  ok "OX App Suite is already enabled with mail domain $MAIL_DOMAIN – nothing to change"
  [[ "$PRE_FAILED" -eq 0 ]] || warn "$PRE_FAILED pre-check(s) failed – see above"
  exit 0
fi
[[ "$PRE_FAILED" -eq 0 || "$FLAG_FORCE" == 1 ]] \
  || die "pre-check failed (see above) – fix it first (doc 05, section 2), or use --force"
[[ -z "$cur_md" || "$cur_md" == "$MAIL_DOMAIN" || "$FLAG_FORCE" == 1 ]] \
  || die "global.mailDomain is '$cur_md' – a different mail domain changes every address; use --force if that is intended"
backup="$HOME/values-$OPENDESK_ENV.yaml.gotmpl.before-ox-$(date +%Y%m%d-%H%M)"
info "\$ yq -i '.global.mailDomain = \"$MAIL_DOMAIN\" | .apps.oxAppSuite.enabled = true' $VALUES"
info "  (copy of the old file: $backup)"
[[ "$DRY_RUN" == 1 ]] && exit 0
( umask 077; cp "$VALUES" "$backup" )
MD="$MAIL_DOMAIN" yq -i '.global.mailDomain = strenv(MD) | .apps.oxAppSuite.enabled = true' "$VALUES"
chmod 600 "$VALUES"
diff "$backup" "$VALUES" | grep -vi secret | indent '    ' || true
ok "configuration changed"
info "Next: ./03-opendesk/deploy-opendesk.sh --diff, then the rollout (see --help)"
