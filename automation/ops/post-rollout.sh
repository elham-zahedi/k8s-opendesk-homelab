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
# 3. Self-service of the portal: 04-identity/configure-selfservice.sh hides the menu
#    entries for the openDesk password again and checks the profile fields (doc 04,
#    section 19.6) – a rollout of "ums" resets both.
# 4. Direct login: a rollout of "ums" also resets the redirect to the dedicated Keycloak
#    (IDP_ENFORCE=yes). If the openDesk login form is back, the release
#    opendesk-keycloak-bootstrap is rolled out again with helmfile sync (doc 04, 19.5).
# 5. Runs the checks for Nextcloud files (mount list NC_MOUNTS_CSV), SSO and – if
#    enabled – OX App Suite.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE OPENDESK_DIR OPENDESK_ENV NUBUS_OU NUBUS_BASE_DN GROUPWARE_GROUP \
             DOMAIN IDP_KEY MASTER_PASSWORD_FILE OPENDESK_CA_FILE
identity_vars
require_cmd jq curl yq
use_kubectl
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
OX_ENABLED="$(yq '.apps.oxAppSuite.enabled // false' "$VALUES")"

step "1/5 files_external in Nextcloud"
nextcloud_pod
if occ app:list --output=json | jq -e '.enabled | has("files_external")' >/dev/null; then
  ok "files_external is enabled"
else
  warn "files_external is switched off (by the last rollout)"
  run occ app:enable files_external
  [[ "$DRY_RUN" == 1 ]] || info "mounts: $(occ files_external:list --output=json | jq length)"
fi

step "2/5 Members of $GROUPWARE_GROUP"
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

step "3/5 Self-service of the portal"
results=()
dry=(); [[ "$DRY_RUN" == 1 ]] && dry=(--dry-run)
if "$AUTOMATION_DIR/04-identity/configure-selfservice.sh" "${dry[@]}"; then results+=("ok 04-identity/configure-selfservice.sh")
else results+=("failed 04-identity/configure-selfservice.sh"); fi

step "4/5 Direct login to $IDP_ALIAS (IDP_ENFORCE=$IDP_ENFORCE)"
straight() { grep -q "/broker/$IDP_ALIAS/login" <<<"$(portal_login_redirect)"; }
if [[ "$IDP_ENFORCE" != yes ]]; then
  info "IDP_ENFORCE is not yes – the openDesk login form stays"
elif straight; then
  ok "the login of the portal goes straight to $IDP_ALIAS"
else
  warn "the openDesk login form is back (a rollout of ums resets it) – rolling out opendesk-keycloak-bootstrap again"
  info "\$ helmfile -e $OPENDESK_ENV -l name=opendesk-keycloak-bootstrap sync -n $OPENDESK_NAMESPACE"
  if [[ "$DRY_RUN" != 1 ]]; then
    require_cmd helmfile
    log="$(mktemp)"; add_exit_hook "rm -f $log"
    # helmfile sync also runs a release whose values did not change (apply would skip it)
    if ! ( cd "$OPENDESK_DIR" && MASTER_PASSWORD="$(cat "$MASTER_PASSWORD_FILE")" \
           helmfile -e "$OPENDESK_ENV" -l name=opendesk-keycloak-bootstrap sync -n "$OPENDESK_NAMESPACE" ) >"$log" 2>&1; then
      tail -n 20 "$log" | indent '    '; die "helmfile sync of opendesk-keycloak-bootstrap failed"
    fi
    info "waiting for the bootstrap job (about 3 minutes, at most 10)"
    for _ in $(seq 60); do straight && break; sleep 10; done
    check "the login of the portal goes straight to $IDP_ALIAS again" straight
  fi
fi

step "5/5 Checks"
[[ "$DRY_RUN" == 1 ]] && { info "skipped with --dry-run"; exit 0; }
scripts=(04-identity/verify-nextcloud-files.sh 04-identity/verify-sso.sh)
[[ "$OX_ENABLED" == true ]] && scripts+=(05-ox/verify-ox.sh)
for s in "${scripts[@]}"; do
  echo; info "────── $s"
  if "$AUTOMATION_DIR/$s"; then results+=("ok $s"); else results+=("failed $s"); fi
done
step "Summary"
for r in "${results[@]}"; do check "${r#* }" test "${r%% *}" = ok; done
check_summary
