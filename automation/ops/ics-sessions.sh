#!/usr/bin/env bash
# ops – Sessions of the Intercom Service (ICS) in Redis: list them, or delete the stale ones.
#       A stale session leaves the 9-dot menu of the apps empty for its user (doc 17).
#
# Doc:     docs/17-empty-app-menu.md
# Run on:  kubespray VM as k8s – ops/post-rollout.sh runs it with --clean after every rollout
# Usage:   ./ics-sessions.sh                   list the sessions (read-only)
#          ./ics-sessions.sh --clean [--dry-run]
#                                              delete sessions whose tokens expired more than
#                                              10 minutes ago
#          ./ics-sessions.sh --clean --all     delete every session
#
# The scripts in ics/ run with node inside the pod intercom-service, which already has the
# Redis connection in its environment. They print user names and times, never a token.
# A user whose session was deleted gets a new one with the next page load; as long as the
# Keycloak login is still valid, this happens without a login form.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="clean all"
parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE
use_kubectl
NS="$OPENDESK_NAMESPACE"
DIR="$AUTOMATION_DIR/ops/ics"
[[ "$FLAG_ALL" != 1 || "$FLAG_CLEAN" == 1 ]] || die "--all only together with --clean"
kubectl -n "$NS" get deploy intercom-service >/dev/null 2>&1 \
  || die "deployment intercom-service not found in namespace $NS"

if [[ "$FLAG_CLEAN" == 1 ]]; then
  args=()
  [[ "$DRY_RUN" == 1 ]] && args+=(--dry-run)
  [[ "$FLAG_ALL" == 1 ]] && args+=(--all)
  step "ICS sessions: delete $([[ "$FLAG_ALL" == 1 ]] && echo "all sessions" || echo "stale sessions (tokens expired more than 10 minutes ago)")"
  # --dry-run is passed on to the script, which then only lists
  kubectl -n "$NS" exec -i deploy/intercom-service -- node - "${args[@]}" <"$DIR/ics-clear-stale.js"
else
  step "ICS sessions in Redis (read-only)"
  kubectl -n "$NS" exec -i deploy/intercom-service -- node - <"$DIR/ics-sessions.js"
fi
