#!/usr/bin/env bash
# ops – Mandatory repairs and checks after every rollout (helmfile apply).
#
# Doc:     docs/05-ox-app-suite.md (sections 7, 8 and 14.1), docs/04 (section 24.4)
# Run on:  kubespray VM as k8s
# Usage:   ./post-rollout.sh [--dry-run]
#
# 1. files_external: the job opendesk-nextcloud-management switches the app off on
#    every rollout, and users lose their file server folders (doc 05, error F3).
#    It is enabled again; the mounts and their options are kept in the database.
# 2. Groupware group: Nubus only adds a user to the group when the user object
#    changes (doc 05, error F2). Users with isOxUser = true that are missing are
#    added. No member is removed.
# 3. Runs the checks for Nextcloud files (mount list NC_MOUNTS_CSV), SSO and – if
#    enabled – OX App Suite.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE OPENDESK_DIR OPENDESK_ENV NUBUS_OU NUBUS_BASE_DN GROUPWARE_GROUP
identity_vars
require_cmd jq curl yq
use_kubectl
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
OX_ENABLED="$(yq '.apps.oxAppSuite.enabled // false' "$VALUES")"

step "1/3 files_external in Nextcloud"
nextcloud_pod
if occ app:list --output=json | jq -e '.enabled | has("files_external")' >/dev/null; then
  ok "files_external is enabled"
else
  warn "files_external is switched off (by the last rollout)"
  run occ app:enable files_external
  [[ "$DRY_RUN" == 1 ]] || info "mounts: $(occ files_external:list --output=json | jq length)"
fi

step "2/3 Members of $GROUPWARE_GROUP"
if [[ "$OX_ENABLED" != true ]]; then
  info "OX App Suite is not enabled – skipped"
else
  udm_connect
  groupware_state
  info "users with isOxUser = true in ou=$NUBUS_OU: $OX_USERS, members: $GW_MEMBERS"
  if [[ -z "$GW_DN" ]]; then
    warn "group $GROUPWARE_GROUP does not exist – it is created by the OX rollout"
  elif [[ "$GW_MISSING" -eq 0 ]]; then
    ok "every user with isOxUser = true is a member"
  else
    # A PATCH on "users" replaces the whole member list (doc 05, section 8.1),
    # so the current members plus the missing users are sent.
    info "\$ PATCH $GW_DN: add $GW_MISSING user(s), keep the $GW_MEMBERS current members"
    if [[ "$DRY_RUN" != 1 ]]; then
      body="$(jq -nc --argjson cur "$GW_ALL_MEMBERS" --argjson add "$GW_MISSING_DNS" '{properties: {users: ($cur + $add | unique)}}')"
      udm PATCH "groups/group/$(urlencode "$GW_DN")" "$body"
      [[ "$UDM_STATUS" == 204 ]] || die "PATCH failed (HTTP $UDM_STATUS): $(head -c 600 "$UDM_BODY")"
      groupware_state
      ok "group updated – $GW_MEMBERS members, $GW_MISSING missing"
    fi
  fi
fi

step "3/3 Checks"
[[ "$DRY_RUN" == 1 ]] && { info "skipped with --dry-run"; exit 0; }
scripts=(04-identity/verify-nextcloud-files.sh 04-identity/verify-sso.sh)
[[ "$OX_ENABLED" == true ]] && scripts+=(05-ox/verify-ox.sh)
results=()
for s in "${scripts[@]}"; do
  echo; info "────── $s"
  if "$AUTOMATION_DIR/$s"; then results+=("ok $s"); else results+=("failed $s"); fi
done
step "Summary"
for r in "${results[@]}"; do check "${r#* }" test "${r%% *}" = ok; done
check_summary
