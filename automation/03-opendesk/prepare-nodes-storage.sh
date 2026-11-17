#!/usr/bin/env bash
# 03 – Prepare all nodes for Longhorn: open-iscsi, iscsi_tcp, multipathd off, inotify.
#
# Doc:     docs/03-opendesk-deployment.md (section 3)
# Run on:  kubespray VM as k8s
# Usage:   ./prepare-nodes-storage.sh [--dry-run]
#
#   --dry-run   Ansible check mode: shows what WOULD change, changes nothing
#
# Safe to run again: on prepared nodes the recap shows changed=0.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CHECK_ARGS=()
args=()
for a in "$@"; do
  if [[ "$a" == --dry-run ]]; then CHECK_ARGS=(--check --diff); else args+=("$a"); fi
done
parse_common_args "${args[@]}"
load_env
require_vars INVENTORY_NAME
use_kubespray
[[ -f "$INV" ]] || die "$INV not found"

step "Prepare the nodes for Longhorn${CHECK_ARGS:+ (check mode – nothing is changed)}"
run ansible-playbook -i "$INV" "$AUTOMATION_DIR/03-opendesk/prepare-nodes-storage.yml" "${CHECK_ARGS[@]}"
ok "done – the recap above shows changed=… per node"
