#!/usr/bin/env bash
# 02 – Prepare all nodes: /etc/hosts block, chrony, time sync and swap check.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (sections 4.2 and 4.3)
# Run on:  kubespray VM as k8s
# Usage:   ./prepare-nodes.sh [--dry-run]
#
#   --dry-run   runs the playbook in Ansible check mode: shows what WOULD change
#               ("changed=…" in the recap), changes nothing
#
# Runs prepare-nodes.yml against inventory/<INVENTORY_NAME>/inventory.ini.
# Safe to run again: on prepared nodes the recap shows changed=0.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# --dry-run is handled here: the playbook then runs in Ansible check mode (read-only)
DRY_RUN_REQUESTED=0
args=()
for a in "$@"; do
  if [[ "$a" == --dry-run ]]; then DRY_RUN_REQUESTED=1; else args+=("$a"); fi
done
parse_common_args "${args[@]}"
load_env
require_vars INVENTORY_NAME
use_kubespray
[[ -f "$INV" ]] || die "$INV not found – run prepare-inventory.sh first"

PLAYBOOK="$AUTOMATION_DIR/02-kubespray/prepare-nodes.yml"
CHECK_ARGS=()
[[ "$DRY_RUN_REQUESTED" == 1 ]] && CHECK_ARGS=(--check --diff)

step "1/2 Connection test (ansible ping)"
run ansible -i "$INV" all -m ping -o

step "2/2 Prepare the nodes${CHECK_ARGS:+ (check mode – nothing is changed)}"
run ansible-playbook -i "$INV" "$PLAYBOOK" "${CHECK_ARGS[@]}"

echo
if [[ "$DRY_RUN_REQUESTED" == 1 ]]; then
  ok "Check mode finished – the recap shows how many tasks would change something."
else
  ok "All nodes are prepared."
  info "Next (in tmux): ./02-kubespray/install-cluster.sh"
fi
