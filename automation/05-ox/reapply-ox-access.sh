#!/usr/bin/env bash
# 05 – Send the OX users to OX again, so the OX Connector applies their access profile
#      once more (error F6: Calendar and Tasks open the mail, Contacts works).
#
# Doc:     docs/05-ox-app-suite.md (section 12.3)
# Run on:  kubespray VM as k8s
# Usage:   ./reapply-ox-access.sh [--dry-run] [USERNAME ...]
#
# The OX Connector applies an access profile (oxAccess) only while it processes a user,
# not when the profile itself changes. A user it processed while the profile was still
# unknown keeps only mail and contacts in OX. For every user with isOxUser = true (or
# only the names given) the script sets oxAccess to "none" and back to the user's own
# profile. The connector does not know "none" and leaves the rights untouched, so there
# is no interruption; the second change applies the full profile. Users see calendar
# and tasks after logging out and in again.
# OX_REAPPLY_PAUSE in lab.env: seconds between the two changes of one user (default 5).
# A user left on "none" by an aborted run is skipped; give it back its profile with
#   OX_REAPPLY_PROFILE=opendesk_standard ./reapply-ox-access.sh USERNAME

# shellcheck disable=SC2016  # $variables inside single quotes are jq variables
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NAMES=(); args=()
for a in "$@"; do if [[ "$a" == -* ]]; then args+=("$a"); else NAMES+=("$a"); fi; done
parse_common_args "${args[@]}"
load_env
require_vars OPENDESK_NAMESPACE NUBUS_OU NUBUS_BASE_DN
require_cmd jq curl
use_kubectl
NS="$OPENDESK_NAMESPACE"
PAUSE="${OX_REAPPLY_PAUSE:-5}"

# ------------------------------------------------------------------------------
step "1/3 Users and access profiles"
udm_connect
ox_access_state
info "profiles in use: ${OX_PROFILES_USED:-none}; known to the OX Connector: ${OX_PROFILES_KNOWN:-none}"
[[ -z "$OX_PROFILES_MISSING" ]] \
  || die "the OX Connector does not know: $OX_PROFILES_MISSING – sending the users again would not help; check the release opendesk-open-xchange-bootstrap"
[[ " $OX_PROFILES_KNOWN " != *" none "* ]] \
  || warn "the OX Connector knows the profile \"none\": every user loses OX access for about $PAUSE seconds"
udm GET "users/user/?position=$(urlencode "ou=$NUBUS_OU,$NUBUS_BASE_DN")&scope=sub&properties=username&properties=isOxUser&properties=oxAccess"
[[ "$UDM_STATUS" == 200 ]] || die "reading the users failed (HTTP $UDM_STATUS)"
names_json="$(printf '%s\n' "${NAMES[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
mapfile -t ROWS < <(jq -r --argjson names "$names_json" '._embedded["udm:object"][]
  | select(.properties.isOxUser == true)
  | select(($names | length) == 0 or (.properties.username | IN($names[])))
  | [.dn, .properties.username, (.properties.oxAccess // "")] | @tsv' "$UDM_BODY")
for n in "${NAMES[@]}"; do
  printf '%s\n' "${ROWS[@]}" | cut -f2 | grep -qFx "$n" || die "$n: no user with isOxUser = true in ou=$NUBUS_OU"
done
if [[ -n "${OX_REAPPLY_PROFILE:-}" ]]; then
  [[ "${#NAMES[@]}" -gt 0 ]] || die "OX_REAPPLY_PROFILE only works together with user names"
  [[ " $OX_PROFILES_KNOWN " == *" $OX_REAPPLY_PROFILE "* ]] || die "OX_REAPPLY_PROFILE=$OX_REAPPLY_PROFILE is not known to the OX Connector"
fi
[[ "${#ROWS[@]}" -gt 0 ]] || die "no user with isOxUser = true in ou=$NUBUS_OU"
info "${#ROWS[@]} user(s), OX warnings before this run: $OX_PROFILE_WARNINGS (last: $OX_PROFILE_WARNING_LAST)"

# ------------------------------------------------------------------------------
step "2/3 oxAccess \"none\" and back, user by user (about $(( ${#ROWS[@]} * (PAUSE + 1) )) seconds)"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r dn name profile <<<"$row"
  if [[ -z "$profile" || "$profile" == none ]]; then
    if [[ -z "${OX_REAPPLY_PROFILE:-}" || "${#NAMES[@]}" -eq 0 ]]; then info "$name: oxAccess ${profile:-empty} – skipped"; continue; fi
    profile="$OX_REAPPLY_PROFILE"   # only for users named on the command line
  fi
  if [[ "$DRY_RUN" == 1 ]]; then info "\$ $name: oxAccess none, $PAUSE s, then $profile"; continue; fi
  udm PATCH "users/user/$(urlencode "$dn")" '{"properties":{"oxAccess":"none"}}'
  [[ "$UDM_STATUS" == 204 ]] || die "$name: oxAccess=none failed (HTTP $UDM_STATUS) – nothing changed for $name"
  sleep "$PAUSE"
  for try in 1 2 3; do
    udm PATCH "users/user/$(urlencode "$dn")" "$(jq -nc --arg p "$profile" '{properties: {oxAccess: $p}}')"
    [[ "$UDM_STATUS" == 204 ]] && break
    warn "$name: oxAccess=$profile failed (HTTP $UDM_STATUS), try $try of 3"; sleep 5
  done
  [[ "$UDM_STATUS" == 204 ]] \
    || die "$name is on oxAccess \"none\" now – set it back: OX_REAPPLY_PROFILE=$profile $0 $name"
  ok "$name: $profile"
done
[[ "$DRY_RUN" != 1 ]] || exit 0

# ------------------------------------------------------------------------------
step "3/3 OX Connector log since $since"
info "waiting 30 s for the OX Connector"
sleep 30
log="$(kubectl -n "$NS" logs ox-connector-0 -c main --since-time="$since" 2>/dev/null || true)"
errors="$(grep -ciE 'error|traceback' <<<"$log" || true)"
other="$(grep 'Cannot find access profile' <<<"$log" | grep -vc "profile 'none'" || true)"
check "ox-connector: no error lines ($errors)" test "$errors" -eq 0
check "ox-connector: every profile found (warnings for other profiles than \"none\": $other)" test "$other" -eq 0
info "users see calendar and tasks after logging out and in again"
check_summary
