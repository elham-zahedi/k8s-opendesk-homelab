#!/usr/bin/env bash
# 02 – Create the Kubespray inventory and the cluster settings.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (sections 4.1 and 5)
# Run on:  kubespray VM as k8s
# Usage:   ./prepare-inventory.sh [--dry-run] [--force]
#
#   --force   replace an existing inventory.ini that differs (a backup is kept)
#
# Writes inventory/<INVENTORY_NAME>/inventory.ini from NODES (lab.env) and sets
# calico_veth_mtu, metrics-server, Helm, kubeconfig_localhost and kubectl_localhost.
# Safe to run again: values that are already set are left unchanged.
#
# Test next to the real inventory:
#   INVENTORY_NAME=autotest ./prepare-inventory.sh
#   diff ~/kubespray/inventory/autotest/inventory.ini ~/kubespray/inventory/mycluster/inventory.ini

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars NODES ANSIBLE_USER CALICO_MTU INVENTORY_NAME
parse_nodes
use_kubespray

# ------------------------------------------------------------------------------
step "1/3 Inventory directory $INV_DIR"
FRESH=0
if [[ -d "$INV_DIR" ]]; then
  ok "exists"
else
  run cp -rfp inventory/sample "$INV_DIR"
  FRESH=1   # the copied sample inventory.ini is replaced below
fi

# ------------------------------------------------------------------------------
step "2/3 inventory.ini from NODES"
new_inv="$(
  echo "[kube_control_plane]"
  for i in "${!NODE_NAMES[@]}"; do
    [[ "${NODE_ROLES[$i]}" == worker ]] && continue
    echo "${NODE_NAMES[$i]} ansible_host=${NODE_IPS[$i]} ip=${NODE_IPS[$i]}"
  done
  echo
  echo "[etcd:children]"
  echo "kube_control_plane"
  echo
  echo "[kube_node]"
  for i in "${!NODE_NAMES[@]}"; do
    case "${NODE_ROLES[$i]}" in
      worker) echo "${NODE_NAMES[$i]} ansible_host=${NODE_IPS[$i]} ip=${NODE_IPS[$i]}" ;;
      both)   echo "${NODE_NAMES[$i]}" ;;   # variables are already set above
    esac
  done
  echo
  echo "[all:vars]"
  echo "ansible_user=$ANSIBLE_USER"
  echo "ansible_python_interpreter=/usr/bin/python3"
)"
grep -q . <<<"$(sed -n '/^\[kube_control_plane\]/,/^$/p' <<<"$new_inv" | sed 1d)" \
  || die "NODES contains no control plane node (role control or both)"

if [[ -f "$INV" ]] && diff -q <(echo "$new_inv") "$INV" >/dev/null; then
  ok "$INV is already up to date"
elif [[ -f "$INV" && "$FLAG_FORCE" != 1 && "$FRESH" != 1 ]]; then
  diff -u "$INV" <(echo "$new_inv") | sed 's/^/  /' || true
  die "$INV differs from NODES (see above) – check it, then run again with --force"
else
  if [[ -f "$INV" && "$FRESH" != 1 ]]; then run cp -p "$INV" "$INV.bak-$(date +%Y%m%d-%H%M%S)"; fi
  info "\$ write $INV"
  if [[ "$DRY_RUN" == 1 ]]; then indent '    ' <<<"$new_inv"; else echo "$new_inv" > "$INV"; fi
  ok "inventory written: ${#NODE_NAMES[@]} node(s)"
fi

# ------------------------------------------------------------------------------
step "3/3 Cluster settings in group_vars"
G="$INV_DIR/group_vars/k8s_cluster"

# set_var FILE KEY VALUE – sets "KEY: VALUE"; replaces an existing or commented-out line
set_var() {
  local file="$1" key="$2" value="$3"
  [[ -f "$file" || "$DRY_RUN" == 1 ]] || die "$file not found"
  if grep -qxE "${key}: ${value}" "$file" 2>/dev/null; then
    ok "$key: $value (already set)"
  elif grep -qE "^${key}:" "$file" 2>/dev/null; then
    run sed -i -E "s|^${key}:.*|${key}: ${value}|" "$file"
  elif grep -qE "^# *${key}:" "$file" 2>/dev/null; then
    run sed -i -E "0,/^# *${key}:.*/s||${key}: ${value}|" "$file"
  else
    append_line "$file" "${key}: ${value}"
  fi
}

set_var "$G/k8s-net-calico.yml" calico_veth_mtu        "$CALICO_MTU"   # pod MTU = node MTU - 50
set_var "$G/addons.yml"         metrics_server_enabled true            # kubectl top
set_var "$G/addons.yml"         helm_enabled           true
set_var "$G/k8s-cluster.yml"    kubeconfig_localhost   true            # admin.conf to artifacts/
set_var "$G/k8s-cluster.yml"    kubectl_localhost      true            # kubectl binary to artifacts/

if [[ "$DRY_RUN" != 1 ]]; then
  echo
  grep -hE '^(calico_veth_mtu|metrics_server_enabled|helm_enabled|kubeconfig_localhost|kubectl_localhost|kube_network_plugin|kube_service_addresses|kube_pods_subnet):' \
    "$G"/k8s-net-calico.yml "$G"/addons.yml "$G"/k8s-cluster.yml | sed 's/^/  /'
fi
echo
info "Next: ./02-kubespray/prepare-nodes.sh"
