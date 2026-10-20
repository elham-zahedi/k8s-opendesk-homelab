#!/usr/bin/env bash
# 06 – Read-only check before a new worker is created: free address, healthy cluster,
#      same Kubespray version as at the installation.
#
# Doc:     docs/06-add-worker-node.md (sections 2 and 5.1)
# Run on:  kubespray VM as k8s
# Usage:   ./precheck-worker.sh NAME
#          ./precheck-worker.sh name:vmid:ip:worker     (test without changing lab.env)
#
# NAME must be listed in NODES (lab.env) with the role "worker", e.g.
#   node7:208:10.240.0.28:worker
# Nothing is changed. The capacity of the Proxmox host is checked by
# create-worker-vm.sh on the host itself.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

node=""; flags=()
for a in "$@"; do if [[ "$a" == -* ]]; then flags+=("$a"); else node="$a"; fi; done
parse_common_args "${flags[@]}"
load_env
require_vars NODES KUBESPRAY_DIR KUBESPRAY_VERSION INVENTORY_NAME
require_cmd ping git
find_node "$node"
use_kubectl

step "1/3 Definition of $W_NAME (VM $W_ID, $W_IP)"
if [[ "$W_IN_NODES" == 1 ]]; then ok "listed in NODES with the role worker"
else warn "not listed in NODES – add $W_ENTRY to NODES in lab.env before add-worker.sh"; fi
dups=""
for e in $NODES; do
  IFS=: read -r n i p _ <<<"$e"
  if [[ "$n" != "$W_NAME" && ( "$i" == "$W_ID" || "$p" == "$W_IP" ) ]]; then dups+="${dups:+ }$n"; fi
done
check "VM ID and IP not used by another entry in NODES${dups:+ (used by: $dups)}" test -z "$dups"

step "2/3 Address and cluster membership"
check "$W_IP does not answer (address free)" bash -c "! ping -c 2 -W 1 $W_IP >/dev/null 2>&1"
check "$W_NAME is not a node of the cluster yet" bash -c "! kubectl get node $W_NAME >/dev/null 2>&1"
INV="$KUBESPRAY_DIR/inventory/$INVENTORY_NAME/inventory.ini"
check "inventory $INV exists" test -f "$INV"
check "$W_NAME is not in the inventory yet" bash -c "! grep -qE '^$W_NAME([[:space:]]|$)' '$INV'"

step "3/3 State of the cluster"
nodes="$(kubectl get nodes --no-headers)"
notready="$(awk '$2 != "Ready" {print $1}' <<<"$nodes" | xargs)"
check "all $(grep -c . <<<"$nodes") nodes Ready${notready:+ (not: $notready)}" test -z "$notready"
bad="$(kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed" {print $1 "/" $2 " " $4}')"
check "no pod outside Running/Completed ($(grep -c . <<<"$bad" || true))" test -z "$bad"
[[ -z "$bad" ]] || head -5 <<<"$bad" | indent '    '
ver="$(git -C "$KUBESPRAY_DIR" describe --tags 2>/dev/null || echo unknown)"
check "Kubespray $ver – same as at the installation ($KUBESPRAY_VERSION)" test "$ver" = "$KUBESPRAY_VERSION"
info "load of the nodes (requests decide the scheduling, not this):"
kubectl top nodes 2>/dev/null | indent '    ' || true

check_summary
info "Next, on the Proxmox host as root: ./06-add-worker/create-worker-vm.sh $W_NAME"
