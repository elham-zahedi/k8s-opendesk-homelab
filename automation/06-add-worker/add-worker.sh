#!/usr/bin/env bash
# 06 – Add a worker to the running cluster: backup, inventory, node preparation,
#      facts of all nodes, then scale.yml only for the new node.
#
# Doc:     docs/06-add-worker-node.md (sections 2.2, 3.2, 4 and 5)
# Run on:  kubespray VM as k8s, inside tmux (tmux new -s scale)
# Usage:   ./add-worker.sh NAME [--dry-run] [--yes] [--force]
#
#   --dry-run   preview: the node preparation runs in Ansible check mode, the
#               backup, facts.yml and scale.yml are only printed
#   --force     run scale.yml although NAME is already a node of the cluster
#               (it is idempotent), or although the Kubespray version differs
#
# NAME must be listed in NODES (lab.env) with the role "worker", and its VM must be
# running (create-worker-vm.sh) – also for --dry-run. The other nodes only get the new line in their
# /etc/hosts block; scale.yml --limit=NAME does not touch them.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

node=""; flags=()
for a in "$@"; do if [[ "$a" == -* ]]; then flags+=("$a"); else node="$a"; fi; done
ALLOWED_FLAGS="force"
parse_common_args "${flags[@]}"
load_env
require_vars NODES ANSIBLE_USER KUBESPRAY_VERSION INVENTORY_NAME
find_node "$node"
[[ "$W_IN_NODES" == 1 ]] || die "$W_NAME is not listed in NODES – add $W_ENTRY to lab.env first"
use_kubectl
use_kubespray
[[ -f "$INV" ]] || die "$INV not found"
STAMP="$(date +%Y%m%d-%H%M)"
pass=(); LOGTAG="$STAMP"     # logs of the check mode runs are kept as well: ~/add-NAME-*-check-*.log
if [[ "$DRY_RUN" == 1 ]]; then pass=(--dry-run); LOGTAG="check-$STAMP"; fi

# ------------------------------------------------------------------------------
step "1/7 Starting point"
if kubectl get node "$W_NAME" >/dev/null 2>&1; then
  if [[ "$FLAG_FORCE" != 1 && "$DRY_RUN" != 1 ]]; then
    ok "$W_NAME is already a node of the cluster – nothing to do"
    info "check it with: ./06-add-worker/verify-worker.sh $W_NAME   (run scale.yml again with --force)"
    exit 0
  fi
  if [[ "$FLAG_FORCE" == 1 ]]; then warn "$W_NAME is already a node of the cluster – scale.yml runs again (--force)"
  else warn "$W_NAME is already a node of the cluster – preview only"; fi
fi
ver="$(git -C "$KUBESPRAY_DIR" describe --tags 2>/dev/null || echo unknown)"
if [[ "$ver" == "$KUBESPRAY_VERSION" ]]; then
  ok "Kubespray $ver – same as at the installation"
elif [[ "$FLAG_FORCE" == 1 ]]; then
  warn "Kubespray is $ver, lab.env says $KUBESPRAY_VERSION – continuing (--force)"
else
  die "Kubespray is $ver, lab.env says $KUBESPRAY_VERSION – a different version would give the new node different settings (doc 06, section 8)"
fi
notready="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}' | xargs)"
if [[ -z "$notready" ]]; then ok "all nodes Ready"
else warn "not Ready: $notready – errors after the join could not be told apart from them"; fi

# ------------------------------------------------------------------------------
step "2/7 SSH, cloud-init and reboot after the first boot"
# check-nodes.sh never reboots a node that is already in the cluster
if [[ "$DRY_RUN" == 1 ]]; then
  WAIT_TIMEOUT=30 NODES="$W_ENTRY" "$AUTOMATION_DIR/02-kubespray/check-nodes.sh"
else
  NODES="$W_ENTRY" "$AUTOMATION_DIR/02-kubespray/check-nodes.sh" --reboot
fi

# ------------------------------------------------------------------------------
step "3/7 Backup: etcd snapshot and inventory"
"$AUTOMATION_DIR/ops/etcd-backup.sh" "before-$W_NAME-$STAMP" "${pass[@]}"
run cp -p "$INV" "$HOME/inventory.ini.before-$W_NAME-$STAMP"

# ------------------------------------------------------------------------------
step "4/7 Inventory: $W_NAME under [kube_node]"
INV_RUN="$INV"
if grep -qE "^$W_NAME([[:space:]]|$)" "$INV"; then
  ok "$W_NAME is already in $INV"
else
  grep -qx '\[kube_node\]' "$INV" || die "no [kube_node] section in $INV"
  line="$W_NAME ansible_host=$W_IP ip=$W_IP"
  new="$(awk -v line="$line" '
    /^\[/ { if (sec && !done) { print line; done = 1 } sec = ($0 == "[kube_node]") }
    sec && /^[[:space:]]*$/ && !done { print line; done = 1 }
    { print }
    END { if (sec && !done) print line }' "$INV")"
  diff <(cat "$INV") <(echo "$new") | indent '    ' || true
  if [[ "$DRY_RUN" == 1 ]]; then
    # the preview works on a copy next to the real inventory (same group_vars)
    INV_RUN="$INV_DIR/inventory.dry-run.ini"; add_exit_hook "rm -f $INV_RUN"
    echo "$new" >"$INV_RUN"
    info "(dry run) the following steps use a temporary copy with $W_NAME"
  else
    echo "$new" >"$INV"
    ok "$W_NAME added"
  fi
fi
check "ansible ping $W_NAME" ansible -i "$INV_RUN" "$W_NAME" -m ping
[[ "$CHECKS_FAILED" -eq 0 || "$DRY_RUN" == 1 ]] || die "$W_NAME does not answer to Ansible"

# ------------------------------------------------------------------------------
step "5/7 Node preparation${pass:+ (check mode – nothing is changed)}"
chk=(); [[ "$DRY_RUN" == 1 ]] && chk=(--check --diff)
info "/etc/hosts block on all nodes, chrony, time, swap (02-kubespray/prepare-nodes.yml)"
run_playbook "$HOME/add-$W_NAME-prepare-$LOGTAG.log"  "$AUTOMATION_DIR/02-kubespray/prepare-nodes.yml" "${chk[@]}"
info "Longhorn: open-iscsi, iscsi_tcp, multipathd off, inotify – only $W_NAME"
run_playbook "$HOME/add-$W_NAME-storage-$LOGTAG.log" "$AUTOMATION_DIR/03-opendesk/prepare-nodes-storage.yml" --limit "$W_NAME" "${chk[@]}"
info "nls_utf8 for the SMB mounts – only $W_NAME"
run_playbook "$HOME/add-$W_NAME-smb-$LOGTAG.log"     "$AUTOMATION_DIR/04-identity/prepare-nodes-smb.yml" --limit "$W_NAME" "${chk[@]}"

# ------------------------------------------------------------------------------
step "6/7 Facts of ALL nodes (playbooks/facts.yml, no limit)"
# With --limit, Ansible does not connect to the control plane: its data (e.g. the
# address for nginx-proxy) then only comes from the fact cache (doc 06, section 5, "Error during the first run").
if [[ "$DRY_RUN" == 1 ]]; then
  info "\$ ansible-playbook -i $INV_RUN -b playbooks/facts.yml   (log: ~/facts-$STAMP.log)"
else
  run_playbook "$HOME/facts-$STAMP.log" playbooks/facts.yml -b
  hosts="$(ansible -i "$INV_RUN" all --list-hosts 2>/dev/null | tail -n +2 | grep -c . || true)"
  recap="$(sed -n '/PLAY RECAP/,/^$/p' "$HOME/facts-$STAMP.log" | grep -c 'ok=' || true)"
  check "PLAY RECAP lists all $hosts hosts ($recap)" test "$recap" -eq "$hosts"
fi
cps="$(ansible -i "$INV_RUN" kube_control_plane --list-hosts 2>/dev/null | tail -n +2 | xargs)"
[[ -n "$cps" ]] || die "no host in [kube_control_plane] of $INV_RUN"
mai="$(ansible -i "$INV_RUN" kube_control_plane -m debug -a var=main_access_ip -o 2>/dev/null || true)"
cp_bad=""
for h in $cps; do grep -qE "^$h \| SUCCESS => .*\"main_access_ip\": *\"[0-9.]+\"" <<<"$mai" || cp_bad+="${cp_bad:+ }$h"; done
if [[ -z "$cp_bad" ]]; then ok "fact cache: main_access_ip known for $cps"
elif [[ "$DRY_RUN" == 1 ]]; then info "fact cache: main_access_ip not known for $cp_bad – facts.yml refreshes it"
else die "main_access_ip still unknown for $cp_bad – scale.yml would fail (doc 06, section 5, error during the first run)"; fi

# ------------------------------------------------------------------------------
step "7/7 scale.yml --limit=$W_NAME"
LOG="$HOME/scale-$W_NAME-$STAMP.log"
if [[ "$DRY_RUN" == 1 ]]; then
  info "\$ ansible-playbook -i $INV -b scale.yml --limit=$W_NAME   (about 4 minutes, log: $LOG)"
  exit 0
fi
if [[ -z "${TMUX:-}" ]]; then
  warn "not running inside tmux – if the SSH connection drops, the playbook stops"
  confirm "Continue without tmux?" || die "aborted – start tmux with: tmux new -s scale"
fi
confirm "Join $W_NAME to the cluster now (scale.yml, about 4 minutes)?" || die "aborted"
run_playbook "$LOG" scale.yml -b --limit="$W_NAME"
check "$W_NAME Ready" kubectl wait --for=condition=Ready "node/$W_NAME" --timeout=300s
check_summary
info "Next: ./06-add-worker/verify-worker.sh $W_NAME"
info "Optional on Z01: a 'Host $W_NAME' entry in ~/.ssh/config (HostName $W_IP, User $ANSIBLE_USER)"
