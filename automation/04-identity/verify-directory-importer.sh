#!/usr/bin/env bash
# 04 – Check the Directory Importer and the imported users and groups in Nubus.
#
# Doc:     docs/04-active-directory-sso.md (sections 8 and 24.2)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-directory-importer.sh
#
# Read-only. Log lines are only counted, never printed: some of them contain
# generated placeholder passwords (doc 04, error F6).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars NUBUS_OU NUBUS_BASE_DN OPENDESK_NAMESPACE DIRECTORY_IMPORTER_VERSION AD_GROUP_PREFIX
identity_vars
require_cmd helm jq curl
use_kubectl
NS="directory-importer"

step "1/3 Release and pod"
check "release directory-importer $DIRECTORY_IMPORTER_VERSION deployed" \
  test "$(helm_chart_version "$NS" directory-importer)" = "$DIRECTORY_IMPORTER_VERSION deployed"
check "deployment ready" kubectl -n "$NS" rollout status deployment/directory-importer --timeout=60s

step "2/3 Sync cycles (last 15 minutes)"
logs="$(kubectl -n "$NS" logs deployment/directory-importer --since=15m 2>/dev/null || true)"
cycles="$(grep -c 'Sleeping' <<<"$logs" || true)"
errors="$(grep -cE ' ERROR |Traceback' <<<"$logs" || true)"
check "at least one finished cycle ($cycles × 'Sleeping')" test "$cycles" -ge 1
check "no errors in the last cycles ($errors)"             test "$errors" -eq 0
[[ "$errors" -eq 0 ]] || info "look at them with: kubectl -n $NS logs deployment/directory-importer --since=15m | grep ERROR  (do not share – may contain passwords)"

step "3/3 Objects in ou=$NUBUS_OU"
udm_connect
pos="$(urlencode "ou=$NUBUS_OU,$NUBUS_BASE_DN")"
users="$(udm_count "users/user/?position=$pos&scope=sub&properties=username")"
groups="$(udm_count "groups/group/?position=$pos&scope=sub&filter=$(urlencode "cn=$AD_GROUP_PREFIX*")&properties=name")"
info "users: $users, groups: $groups (removed AD accounts stay in Nubus for 7 days – deletion_grace_period_days)"
if [[ -n "${AD_EXPECTED_USERS:-}" ]]; then check "$AD_EXPECTED_USERS users imported"  test "$users" -eq "$AD_EXPECTED_USERS"
else check "users imported" test "$users" -gt 0; fi
if [[ -n "${AD_EXPECTED_GROUPS:-}" ]]; then check "$AD_EXPECTED_GROUPS groups imported" test "$groups" -eq "$AD_EXPECTED_GROUPS"
else check "groups imported" test "$groups" -gt 0; fi

check_summary
