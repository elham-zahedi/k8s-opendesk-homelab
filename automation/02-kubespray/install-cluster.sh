#!/usr/bin/env bash
# 02 – Install the Kubernetes cluster with Kubespray (cluster.yml).
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (section 6)
# Run on:  kubespray VM as k8s, preferably inside tmux (takes 25–45 minutes)
# Usage:   tmux new -s kubespray
#          ./install-cluster.sh [--dry-run] [--yes]
#
# Writes a log to ~/cluster-install-<date>.log and checks the PLAY RECAP:
# every node must have unreachable=0 and failed=0.
# cluster.yml is idempotent: after fixing an error it can simply be run again.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars INVENTORY_NAME
use_kubespray
[[ -f "$INV" ]] || die "$INV not found – run prepare-inventory.sh first"

LOG="${LOG:-$HOME/cluster-install-$(date +%Y%m%d-%H%M).log}"
hosts="$(ansible -i "$INV" all --list-hosts 2>/dev/null | tail -n +2 | xargs)"

step "Installation of the cluster"
info "inventory: $INV"
info "nodes:     $hosts"
info "log:       $LOG"
if [[ -z "${TMUX:-}" && "$DRY_RUN" != 1 ]]; then
  warn "not running inside tmux – if the SSH connection drops, the installation stops"
  confirm "Continue without tmux?" || die "aborted – start tmux with: tmux new -s kubespray"
fi
confirm "Run cluster.yml now (25–45 minutes)?" || die "aborted"

echo "  \$ ansible-playbook -i $INV -b cluster.yml 2>&1 | tee $LOG"
if [[ "$DRY_RUN" == 1 ]]; then exit 0; fi
set +e
ansible-playbook -i "$INV" -b cluster.yml 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e

step "Result (PLAY RECAP)"
recap="$(sed -n '/PLAY RECAP/,/^$/p' "$LOG" | grep -E 'ok=[0-9]+')" || die "no PLAY RECAP in $LOG – see the end of the log"
indent <<<"$recap"
if [[ "$rc" -eq 0 ]] && ! grep -qE 'unreachable=[1-9]|failed=[1-9]' <<<"$recap"; then
  ok "Installation successful: unreachable=0 and failed=0 on all nodes"
  info "Next: ./02-kubespray/setup-kubectl.sh"
else
  warn "Errors (lines with 'fatal:' that do NOT end with '...ignoring'):"
  grep -n -A 3 'fatal:' "$LOG" | tail -n 40 | sed 's/^/  /' || true
  die "installation failed (exit code $rc) – fix the cause and run the script again"
fi
