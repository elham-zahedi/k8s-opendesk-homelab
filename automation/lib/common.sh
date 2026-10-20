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

# parse_common_args "$@" – handles --dry-run, --yes and --help
parse_common_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
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
