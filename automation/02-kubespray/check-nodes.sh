#!/usr/bin/env bash
# 02 – Check SSH access, hostname, IP, MTU and sudo on every node.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (sections 1.3 and 3.1)
# Run on:  kubespray VM as k8s (needs the Ansible key as ~/.ssh/id_ed25519)
# Usage:   ./check-nodes.sh [--reboot]
#
#   --reboot   reboot NEW nodes that report "reboot required" (after the first
#              boot of a clone) and wait until they are back. Nodes that are
#              already part of the cluster are never rebooted by this script.
#
# Without --reboot the script only reads and changes nothing.
# Waits up to WAIT_TIMEOUT seconds (default 600) for each node to answer on SSH.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="reboot"
parse_common_args "$@"
load_env
require_vars NODES ANSIBLE_USER NODE_MTU NET_PREFIX
require_cmd ssh
parse_nodes
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

wait_for_ssh() {  # wait_for_ssh IP
  local ip="$1" waited=0
  until ssh "${SSH_OPTS[@]}" "$ANSIBLE_USER@$ip" true 2>/dev/null; do
    [[ "$waited" -ge "$WAIT_TIMEOUT" ]] && return 1
    sleep 10; waited=$((waited + 10))
  done
}

reboot_list=()
for i in "${!NODE_NAMES[@]}"; do
  name="${NODE_NAMES[$i]}"; ip="${NODE_IPS[$i]}"
  step "$name ($ip)"
  if ! wait_for_ssh "$ip"; then
    check "SSH with key as $ANSIBLE_USER" false
    continue
  fi
  # cloud-init must be finished before the node is used (first boot installs updates)
  ssh "${SSH_OPTS[@]}" "$ANSIBLE_USER@$ip" "cloud-init status --wait >/dev/null 2>&1 || true"
  facts="$(ssh "${SSH_OPTS[@]}" "$ANSIBLE_USER@$ip" \
    'echo "host=$(hostname)"
     echo "addr=$(ip -o -4 addr show eth0 | awk "{print \$4}")"
     echo "mtu=$(cat /sys/class/net/eth0/mtu)"
     echo "sudo=$(sudo -n whoami 2>/dev/null)"
     echo "reboot=$([ -f /var/run/reboot-required ] && echo yes || echo no)"
     echo "member=$([ -f /etc/kubernetes/kubelet.conf ] && echo yes || echo no)"')"
  get() { sed -n "s/^$1=//p" <<<"$facts"; }

  check "SSH with key as $ANSIBLE_USER"   true
  check "hostname is $name"              test "$(get host)" = "$name"
  check "IP is $ip/$NET_PREFIX"          test "$(get addr)" = "$ip/$NET_PREFIX"
  check "MTU is $NODE_MTU"               test "$(get mtu)" = "$NODE_MTU"
  check "passwordless sudo"              test "$(get sudo)" = "root"
  if [[ "$(get reboot)" == yes && "$(get member)" == yes ]]; then
    # never reboot a running cluster node blindly – drain it first (doc 10)
    warn "reboot required (pending updates) – node is already in the cluster: reboot it during maintenance with drain/uncordon, not with --reboot"
  elif [[ "$(get reboot)" == yes ]]; then
    warn "reboot required (updates from the first boot)"
    reboot_list+=("$i")
  else
    ok "no reboot required"
  fi
done

if [[ "${#reboot_list[@]}" -gt 0 ]]; then
  if [[ "$FLAG_REBOOT" == 1 ]]; then
    step "Reboot ${#reboot_list[@]} node(s)"
    for i in "${reboot_list[@]}"; do
      run ssh "${SSH_OPTS[@]}" "$ANSIBLE_USER@${NODE_IPS[$i]}" "sudo systemctl reboot" || true
    done
    sleep 30
    for i in "${reboot_list[@]}"; do
      check "${NODE_NAMES[$i]} is back after the reboot" wait_for_ssh "${NODE_IPS[$i]}"
    done
  else
    warn "${#reboot_list[@]} node(s) need a reboot – run again with --reboot"
  fi
fi

check_summary
