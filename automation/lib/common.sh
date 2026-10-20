#!/usr/bin/env bash
# Shared helpers for all automation scripts. This file is sourced, not executed.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

set -euo pipefail

AUTOMATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_BOLD=''; C_OFF=''
fi

step() { echo; echo "${C_BOLD}==> $*${C_OFF}"; }
info() { echo "  $*"; }
ok()   { echo "${C_GREEN}  ✔ $*${C_OFF}"; }
warn() { echo "${C_YELLOW}  ! $*${C_OFF}" >&2; }
indent() { sed "s/^/${1:-  }/"; }   # indent stdin (for command output)
die()  { echo "${C_RED}  ✘ $*${C_OFF}" >&2; exit 1; }

# run CMD...  – prints the command, then runs it (only prints it with --dry-run)
run() {
  echo "  \$ $*"
  [[ "$DRY_RUN" == 1 ]] && return 0
  "$@"
}

# run_masked "TEXT" CMD...  – like run, but prints TEXT instead of the command
# (for commands that contain a password)
run_masked() {
  local text="$1"; shift
  echo "  \$ $text"
  [[ "$DRY_RUN" == 1 ]] && return 0
  "$@"
}

# load_env – reads automation/lab.env (or the file given in $LAB_ENV)
load_env() {
  local f="${LAB_ENV:-$AUTOMATION_DIR/lab.env}"
  [[ -f "$f" ]] || die "$f not found – run: cp lab.env.example lab.env, then adjust lab.env"
  # shellcheck source=/dev/null
  source "$f"
}

require_root() {
  [[ "$DRY_RUN" == 1 || "$EUID" -eq 0 ]] || die "run this script as root"
}

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "command not found: $c"; done
}

require_vars() {
  local v
  for v in "$@"; do [[ -n "${!v:-}" ]] || die "variable $v is empty – set it in lab.env"; done
}

# ask_secret VAR "Prompt" – takes VAR from the environment, otherwise asks for it (hidden input).
# Secrets are never written to lab.env or to the repository.
ask_secret() {
  local var="$1" prompt="$2" value=""
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "$DRY_RUN" == 1 ]]; then printf -v "$var" '%s' '<secret>'; return 0; fi
  read -rsp "  $prompt: " value; echo
  [[ -n "$value" ]] || die "$var must not be empty"
  printf -v "$var" '%s' "$value"
}

# confirm "Question?" – returns 0 on y/Y; always yes with --yes or --dry-run
confirm() {
  [[ "$ASSUME_YES" == 1 || "$DRY_RUN" == 1 ]] && return 0
  local answer=""
  read -rp "  $* [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]]
}

# usage – prints the comment block at the top of the running script
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# parse_common_args "$@" – handles --dry-run, --yes and --help.
# Scripts can allow extra flags before calling it: ALLOWED_FLAGS="force reboot"
# turns --force into FLAG_FORCE=1 and --reboot into FLAG_REBOOT=1.
ALLOWED_FLAGS="${ALLOWED_FLAGS:-}"
parse_common_args() {
  local a f name
  for f in $ALLOWED_FLAGS; do printf -v "FLAG_${f^^}" '%s' 0; done
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      --*)
        name="${a#--}"
        if [[ " $ALLOWED_FLAGS " == *" $name "* ]]; then printf -v "FLAG_${name^^}" '%s' 1
        else die "unknown option: $a (see --help)"; fi ;;
      *) die "unknown option: $a (see --help)" ;;
    esac
  done
  if [[ "$DRY_RUN" == 1 ]]; then warn "DRY RUN – commands are only printed, nothing is changed"; fi
}

# Simple pass/fail counter for verify scripts
CHECKS_OK=0
CHECKS_FAILED=0
check() {  # check "description" CONDITION-COMMAND...
  local text="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$text"; CHECKS_OK=$((CHECKS_OK + 1))
  else
    echo "${C_RED}  ✘ $text${C_OFF}"; CHECKS_FAILED=$((CHECKS_FAILED + 1))
  fi
}
check_summary() {
  echo
  if [[ "$CHECKS_FAILED" -eq 0 ]]; then
    ok "All $CHECKS_OK checks passed"
  else
    die "$CHECKS_FAILED of $((CHECKS_OK + CHECKS_FAILED)) checks failed"
  fi
}

# append_line FILE "LINE" – appends LINE to FILE (prints it with --dry-run)
append_line() {
  echo "  \$ echo '$2' >> $1"
  [[ "$DRY_RUN" == 1 ]] && return 0
  printf '%s\n' "$2" >> "$1"
}

# parse_nodes – splits $NODES (entries "name:vmid:ip:role") into the arrays
# NODE_NAMES, NODE_IDS, NODE_IPS and NODE_ROLES (role = control | worker | both)
parse_nodes() {
  NODE_NAMES=(); NODE_IDS=(); NODE_IPS=(); NODE_ROLES=()
  local entry name id ip role
  for entry in $NODES; do
    IFS=: read -r name id ip role <<<"$entry"
    [[ -n "$name" && "$id" =~ ^[0-9]+$ && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "invalid NODES entry '$entry' – expected name:vmid:ip:role"
    case "$role" in control|worker|both) ;; *) die "invalid role '$role' in NODES entry '$entry'" ;; esac
    NODE_NAMES+=("$name"); NODE_IDS+=("$id"); NODE_IPS+=("$ip"); NODE_ROLES+=("$role")
  done
  [[ "${#NODE_NAMES[@]}" -gt 0 ]] || die "NODES is empty – set it in lab.env"
}

# use_kubespray – runs Ansible from the Kubespray directory with the Kubespray venv
use_kubespray() {
  [[ -d "$KUBESPRAY_DIR" ]] || die "$KUBESPRAY_DIR not found – run 02-kubespray/install-kubespray.sh first"
  [[ -x "$KUBESPRAY_VENV/bin/ansible-playbook" ]] || die "Ansible not found in $KUBESPRAY_VENV – run install-kubespray.sh first"
  PATH="$KUBESPRAY_VENV/bin:$PATH"
  INV_DIR="$KUBESPRAY_DIR/inventory/$INVENTORY_NAME"
  INV="$INV_DIR/inventory.ini"
  cd "$KUBESPRAY_DIR"   # ansible.cfg of Kubespray is only used from here
}
