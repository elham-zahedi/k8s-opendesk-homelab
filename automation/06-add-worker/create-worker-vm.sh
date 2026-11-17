#!/usr/bin/env bash
# 06 – Check the capacity of the Proxmox host, then clone and start the VM of a new
#      worker from the cloud-init template.
#
# Doc:     docs/06-add-worker-node.md (sections 2 and 3)
# Run on:  Proxmox host as root
# Usage:   ./create-worker-vm.sh NAME [--dry-run] [--yes]
#          ./create-worker-vm.sh name:vmid:ip:worker --dry-run   (test without lab.env)
#
# The capacity checks only read (also with --dry-run): template, free VM ID, free
# RAM and storage for one more VM of the template's size; the vCPUs of all running
# VMs are only shown (overcommit is common for workers). Then 02-kubespray/
# clone-nodes.sh clones only this one VM. Other VMs on the host are never touched.
# Check beforehand on the kubespray VM: ./06-add-worker/precheck-worker.sh NAME

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

node=""; flags=()
for a in "$@"; do if [[ "$a" == -* ]]; then flags+=("$a"); else node="$a"; fi; done
parse_common_args "${flags[@]}"
load_env
require_vars NODES TEMPLATE_ID PVE_STORAGE
require_root
require_cmd qm pvesm nproc free
find_node "$node"

to_mb() {  # 120G / 3584M / 1T -> MB
  local v="${1^^}"
  case "$v" in
    *T) echo $(( ${v%T} * 1024 * 1024 )) ;;
    *G) echo $(( ${v%G} * 1024 )) ;;
    *M) echo "${v%M}" ;;
    *)  echo 0 ;;
  esac
}

step "1/2 Capacity of the host for $W_NAME (VM $W_ID, $W_IP)"
tpl="$(qm config "$TEMPLATE_ID" 2>/dev/null || true)"
check "VM $TEMPLATE_ID is a template" grep -q '^template: 1$' <<<"$tpl"
check "VM ID $W_ID is free" bash -c "! qm status $W_ID >/dev/null 2>&1"
cores="$(awk '/^cores:/ {print $2}' <<<"$tpl")"; cores="${cores:-1}"
mem="$(awk '/^memory:/ {print $2}' <<<"$tpl")"; mem="${mem:-0}"
disk="$(grep -oE '^scsi0: .*size=[0-9]+[MGT]' <<<"$tpl" | grep -oE '[0-9]+[MGT]$' || true)"
disk_mb="$(to_mb "${disk:-0M}")"
info "one more VM of the template: $cores vCPUs, $mem MB RAM, disk ${disk:-?}"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
check "RAM: $((avail_mb / 1024)) GB available, $((mem / 1024)) GB needed" test "$avail_mb" -gt "$mem"
stor_kb="$(pvesm status --storage "$PVE_STORAGE" 2>/dev/null | awk 'NR == 2 {print $6}')"
check "storage $PVE_STORAGE: $(( ${stor_kb:-0} / 1024 / 1024 )) GB free, $((disk_mb / 1024)) GB needed" \
  test "${stor_kb:-0}" -gt $((disk_mb * 1024))

threads="$(nproc)"; vcpus=0; running=0
for id in $(qm list 2>/dev/null | awk 'NR > 1 && $3 == "running" {print $1}'); do
  c="$(qm config "$id" 2>/dev/null | awk '/^cores:/ {c=$2} /^sockets:/ {s=$2} END {print (c ? c : 1) * (s ? s : 1)}')"
  vcpus=$((vcpus + c)); running=$((running + 1))
done
info "CPU: $threads threads; $running running VMs with $vcpus vCPUs, with $W_NAME $((vcpus + cores))"
[[ $((vcpus + cores)) -le $((threads * 4)) ]] || warn "more than 4 vCPUs per thread – watch the load with kubectl top nodes"
info "The host cannot ping into the VM network: precheck-worker.sh on the kubespray VM checks that $W_IP is free."
[[ "$CHECKS_FAILED" -eq 0 ]] || check_summary

step "2/2 Clone $W_NAME (only this VM)"
NODES="$W_ENTRY" CLONE_NEXT="./06-add-worker/add-worker.sh $W_NAME (in tmux)" \
  "$AUTOMATION_DIR/02-kubespray/clone-nodes.sh" "${flags[@]}"
