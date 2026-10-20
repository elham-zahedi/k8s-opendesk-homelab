#!/usr/bin/env bash
# 02 – Clone the Kubernetes nodes from the cloud-init template and start them.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (section 1)
# Run on:  Proxmox host as root
# Usage:   ./clone-nodes.sh [--dry-run] [--yes]
#
# Clones every node listed in NODES (lab.env) as a full clone, sets its static IP
# and starts it. Stops before cloning anything if one of the VM IDs is in use.
#
# Test with a single extra VM (nothing else is touched):
#   NODES="k8s-test:299:10.240.0.29:both" ./clone-nodes.sh

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars TEMPLATE_ID PVE_STORAGE GATEWAY NET_PREFIX NODES
require_root
parse_nodes

step "Checks before starting"
if [[ "$DRY_RUN" == 1 ]]; then
  info "(dry run) template and VM ID checks are skipped"
else
  require_cmd qm
  qm config "$TEMPLATE_ID" 2>/dev/null | grep -q '^template: 1$' \
    || die "VM $TEMPLATE_ID is not a template – run 01-proxmox/create-template.sh first"
  for i in "${!NODE_NAMES[@]}"; do
    if qm status "${NODE_IDS[$i]}" >/dev/null 2>&1; then
      die "VM ID ${NODE_IDS[$i]} (${NODE_NAMES[$i]}) is already in use – nothing was cloned"
    fi
  done
  ok "template $TEMPLATE_ID found, all ${#NODE_NAMES[@]} VM IDs are free"
fi
warn "Make sure the IP addresses are not in use (the Proxmox host cannot ping into the VM network):"
for i in "${!NODE_NAMES[@]}"; do info "  ${NODE_NAMES[$i]}  VM ${NODE_IDS[$i]}  ${NODE_IPS[$i]}/${NET_PREFIX}  (${NODE_ROLES[$i]})"; done
confirm "Clone and start these ${#NODE_NAMES[@]} VM(s)?" || die "aborted"

for i in "${!NODE_NAMES[@]}"; do
  name="${NODE_NAMES[$i]}"; id="${NODE_IDS[$i]}"; ip="${NODE_IPS[$i]}"
  step "Clone $name (VM $id, $ip)"
  run qm clone "$TEMPLATE_ID" "$id" --name "$name" --full --storage "$PVE_STORAGE"
  run qm set "$id" --ipconfig0 "ip=$ip/$NET_PREFIX,gw=$GATEWAY"
  run qm start "$id"
done

echo
if [[ "$DRY_RUN" == 1 ]]; then info "(dry run) nothing was cloned"; exit 0; fi
ok "${#NODE_NAMES[@]} VM(s) cloned and started."
info "The first boot installs updates. Next, on the kubespray VM: ${CLONE_NEXT:-./02-kubespray/check-nodes.sh --reboot}"
