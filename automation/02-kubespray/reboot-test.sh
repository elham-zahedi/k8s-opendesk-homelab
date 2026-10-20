#!/usr/bin/env bash
# 02 – Reboot test: reboot ALL nodes at once and check that the cluster recovers.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (section 9)
# Run on:  kubespray VM as k8s
# Usage:   ./reboot-test.sh [--dry-run]
#
# WARNING: all applications are down for a few minutes. Only run it in a
# maintenance window. Afterwards: nodes Ready, containerd/kubelet active,
# /etc/hosts entries still present (cloud-init template), no stuck pods.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars INVENTORY_NAME KUBECONFIG_PATH NODES
parse_nodes
use_kubespray
export KUBECONFIG="$KUBECONFIG_PATH"

warn "This reboots ALL ${#NODE_NAMES[@]} nodes at the same time – every application will be down for a few minutes."
confirm "Really reboot all nodes now?" || die "aborted"

step "1/3 Reboot all nodes (Ansible waits until they are back)"
run ansible -i "$INV" all -b -m reboot -o
[[ "$DRY_RUN" == 1 ]] && exit 0

step "2/3 Wait until all nodes are Ready (up to 10 minutes)"
for _ in $(seq 60); do
  out="$(kubectl get nodes --no-headers 2>/dev/null || true)"
  if [[ -n "$out" ]] && ! grep -qE 'NotReady|Unknown' <<<"$out" \
     && [[ "$(wc -l <<<"$out")" -ge "${#NODE_NAMES[@]}" ]]; then break; fi
  sleep 10
done
sleep 60   # give the pods a moment to restart

step "3/3 Checks"
nodes_out="$(kubectl get nodes --no-headers)"
for name in "${NODE_NAMES[@]}"; do
  check "node $name is Ready" grep -qE "^$name +Ready " <<<"$nodes_out"
done
check "containerd and kubelet active on all nodes" \
  bash -c "! ansible -i '$INV' all -b -m command -a 'systemctl is-active containerd kubelet' -o | grep -qv 'rc=0'"
check "/etc/hosts block survived the reboot" \
  bash -c "ansible -i '$INV' all -m command -a 'getent hosts ${NODE_NAMES[0]}' -o | grep -c 'rc=0' | grep -qx '${#NODE_NAMES[@]}'"
stuck="$(kubectl get pods -A --no-headers | grep -vE ' Running | Completed ' || true)"
check "no pods outside Running/Completed" test -z "$stuck"
[[ -z "$stuck" ]] || indent '    ' <<<"$stuck"

check_summary
