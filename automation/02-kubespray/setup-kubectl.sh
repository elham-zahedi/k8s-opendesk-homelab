#!/usr/bin/env bash
# 02 – Install kubectl and the admin kubeconfig on the kubespray VM.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (section 7)
# Run on:  kubespray VM as k8s, after install-cluster.sh
# Usage:   ./setup-kubectl.sh [--dry-run] [--force]
#
#   --force   replace an existing, different kubeconfig (a backup is kept)
#
# Copies kubectl and admin.conf from inventory/<INVENTORY_NAME>/artifacts/.
# The kubeconfig goes to KUBECONFIG_PATH (default ~/.kube/config); for a test
# cluster use e.g. KUBECONFIG_PATH=~/.kube/test so the real config stays untouched.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars INVENTORY_NAME KUBECONFIG_PATH
use_kubespray
ART="$INV_DIR/artifacts"
[[ -f "$ART/admin.conf" && -f "$ART/kubectl" ]] || [[ "$DRY_RUN" == 1 ]] \
  || die "$ART/admin.conf or kubectl missing – did install-cluster.sh finish? (kubeconfig_localhost / kubectl_localhost)"

step "1/3 kubectl binary"
if [[ -x /usr/local/bin/kubectl ]] && cmp -s "$ART/kubectl" /usr/local/bin/kubectl; then
  ok "/usr/local/bin/kubectl is up to date"
else
  run sudo install -m 755 "$ART/kubectl" /usr/local/bin/kubectl
fi

step "2/3 kubeconfig $KUBECONFIG_PATH"
if [[ -f "$KUBECONFIG_PATH" ]] && cmp -s "$ART/admin.conf" "$KUBECONFIG_PATH"; then
  ok "already up to date"
else
  if [[ -f "$KUBECONFIG_PATH" ]]; then
    [[ "$FLAG_FORCE" == 1 ]] || die "$KUBECONFIG_PATH exists and differs – use --force to replace it (a backup is kept)"
    run cp -p "$KUBECONFIG_PATH" "$KUBECONFIG_PATH.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  run mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  run install -m 600 "$ART/admin.conf" "$KUBECONFIG_PATH"
fi

step "3/3 First check"
if [[ "$DRY_RUN" != 1 ]]; then
  info "$(grep -m1 'server:' "$KUBECONFIG_PATH" | xargs)"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide | sed 's/^/  /'
fi
info "Next: ./02-kubespray/verify-cluster.sh"
