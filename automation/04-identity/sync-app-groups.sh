#!/usr/bin/env bash
# 04 – openDesk apps per AD group: for every pair GROUP:ATTRIBUTE in APP_GROUPS, sets ATTRIBUTE
#      of every user in ou=NUBUS_OU to true for the members of GROUP and to false for everyone
#      else. Members of nested groups count too (e.g. OD-Pilot inside OD-Chat).
#
# Doc:     docs/16-app-access-by-ad-group.md
# Run on:  kubespray VM as k8s – every 15 minutes from cron (--cron sets it up)
# Usage:   ./sync-app-groups.sh [--dry-run] [--force] [--quiet]
#          ./sync-app-groups.sh --cron [--dry-run]
#
# A group that is not in Nubus (yet) is skipped and its attribute is left as it is. A group
# without members is skipped too, so a mistake in AD or in the import cannot switch an app
# off for everyone (--force: apply the empty group).
# --quiet   only changes, warnings and one summary line with date and time (for cron)
# --cron    adds the cron job for this script (and PATH) to the crontab of the current user;
#           an older line that calls sync-app-groups is replaced
# Only users in ou=NUBUS_OU (imported from AD) are changed, never local accounts.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force quiet cron"
parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE NUBUS_OU NUBUS_BASE_DN
require_cmd jq curl
APP_GROUPS="${APP_GROUPS:-OD-Chat:opendeskLivecollaborationEnabled OD-Projekte:opendeskProjectmanagementEnabled OD-Projekte-Admin:opendeskProjectmanagementAdmin}"
SYNC_LOG="${SYNC_LOG:-$HOME/logs/sync-app-groups.log}"
POS="$(urlencode "ou=$NUBUS_OU,$NUBUS_BASE_DN")"
say() { [[ "$FLAG_QUIET" == 1 ]] || "$@"; }     # say CMD... – only without --quiet

# ------------------------------------------------------------------------------
if [[ "$FLAG_CRON" == 1 ]]; then
  step "Cron job: every 15 minutes, log $SYNC_LOG"
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  # bash in front: the file is not executable after a git pull (the repository stores 644)
  job="*/15 * * * * flock -n /tmp/sync-app-groups.lock bash $self --quiet >> $SYNC_LOG 2>&1"
  current="$(crontab -l 2>/dev/null || true)"
  if grep -qxF "$job" <<<"$current"; then
    ok "the crontab already has the job"
  else
    keep="$({ grep -v 'sync-app-groups' <<<"$current" || true; } | sed '/^$/d')"
    new="$( { grep -q '^PATH=' <<<"$keep" || echo 'PATH=/usr/local/bin:/usr/bin:/bin'
              [[ -z "$keep" ]] || printf '%s\n' "$keep"
              printf '%s\n' "$job"; } )"
    info "crontab (< before, > after):"
    diff <(printf '%s\n' "$current") <(printf '%s\n' "$new") | indent '    ' || true
    run mkdir -p "$(dirname "$SYNC_LOG")"
    if [[ "$DRY_RUN" != 1 ]]; then
      printf '%s\n' "$new" | crontab -
      check "crontab has the job" grep -qxF "$job" <(crontab -l)
    fi
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
use_kubectl

# resolve_members GROUP_DN – user DNs (lower case) of the group and of all nested groups
resolve_members() {
  local queue=("$1") seen=" " dn
  while ((${#queue[@]})); do
    dn="${queue[0]}"; queue=("${queue[@]:1}")
    [[ "$seen" == *" ${dn,,} "* ]] && continue
    seen+="${dn,,} "
    udm GET "groups/group/$(urlencode "$dn")"
    [[ "$UDM_STATUS" == 200 ]] || { warn "reading group $dn failed (HTTP $UDM_STATUS)"; echo "ERROR"; return; }
    jq -r '.properties.users // [] | .[] | ascii_downcase' "$UDM_BODY"
    mapfile -t -O "${#queue[@]}" queue < <(jq -r '.properties.nestedGroup // [] | .[]' "$UDM_BODY")
  done
}

udm_connect
changed=0; skipped=0
for pair in $APP_GROUPS; do
  GROUP="${pair%%:*}"; ATTR="${pair#*:}"
  say step "$GROUP -> $ATTR"
  udm GET "groups/group/?position=$POS&scope=sub&filter=$(urlencode "cn=$GROUP")&properties=nestedGroup"
  [[ "$UDM_STATUS" == 200 ]] || die "searching group $GROUP failed (HTTP $UDM_STATUS)"
  if [[ "$(jq '._embedded["udm:object"] | length' "$UDM_BODY")" -ne 1 ]]; then
    warn "group $GROUP not in ou=$NUBUS_OU yet – created in AD? the Directory Importer needs up to 5 minutes. Skipped."
    skipped=$((skipped + 1)); continue
  fi
  gdn="$(jq -r '._embedded["udm:object"][0].dn' "$UDM_BODY")"
  nested="$(jq -r '[._embedded["udm:object"][0].properties.nestedGroup // [] | .[] | split(",")[0] | sub("^cn="; "")] | join(", ")' "$UDM_BODY")"
  list="$(resolve_members "$gdn")"
  if grep -qx ERROR <<<"$list"; then
    warn "$GROUP: members could not be read completely. Skipped."
    skipped=$((skipped + 1)); continue
  fi
  members="$({ grep -v '^$' <<<"$list" || true; } | sort -u | jq -R . | jq -sc .)"
  say info "$GROUP: $(jq length <<<"$members") member(s)${nested:+, nested groups: $nested}"
  if [[ "$(jq length <<<"$members")" -eq 0 && "$FLAG_FORCE" != 1 ]]; then
    warn "$GROUP has no members – nothing changed (use --force to switch $ATTR off for everyone)"
    skipped=$((skipped + 1)); continue
  fi
  udm GET "users/user/?position=$POS&scope=sub&properties=username&properties=$ATTR"
  [[ "$UDM_STATUS" == 200 ]] || die "reading the users failed (HTTP $UDM_STATUS)"
  mapfile -t ROWS < <(jq -r --argjson m "$members" --arg a "$ATTR" '._embedded["udm:object"][]
    | [.dn, .properties.username, ((.dn | ascii_downcase) as $d | $m | index($d) != null | tostring),
       (.properties[$a] | tostring)] | @tsv' "$UDM_BODY")
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r dn name want have <<<"$row"
    if [[ "$want" == "$have" ]]; then say ok "$name: $want"; continue; fi
    info "\$ $name ($ATTR): $have -> $want"
    [[ "$DRY_RUN" == 1 ]] && continue
    udm PATCH "users/user/$(urlencode "$dn")" "{\"properties\":{\"$ATTR\":$want}}"
    [[ "$UDM_STATUS" == 204 ]] || die "$name: change failed (HTTP $UDM_STATUS)"
    ok "$name ($ATTR): $want"; changed=$((changed + 1))
  done
done
# one line per run, read by ops/daily-check.sh
note=""; [[ "$DRY_RUN" != 1 ]] || note=" (dry run)"
echo "$(date '+%F %T') sync-app-groups: $changed change(s), $skipped group(s) skipped$note"
