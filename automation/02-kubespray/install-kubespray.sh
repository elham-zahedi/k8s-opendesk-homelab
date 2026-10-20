#!/usr/bin/env bash
# 02 – Install Kubespray and Ansible on the kubespray VM.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (section 3.2)
# Run on:  kubespray VM as k8s
# Usage:   ./install-kubespray.sh [--dry-run]
#
# Safe to run again: an existing Kubespray checkout is never changed; packages,
# the Python venv and requirements are only added where they are missing.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars KUBESPRAY_VERSION KUBESPRAY_DIR KUBESPRAY_VENV
[[ "$EUID" -ne 0 ]] || die "run this script as the normal user (k8s), not as root"

step "1/4 System packages (git, python3-venv, python3-pip, tmux)"
missing=()
for p in git python3-venv python3-pip tmux; do
  dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [[ "${#missing[@]}" -eq 0 ]]; then
  ok "all packages are installed"
else
  run sudo apt-get update
  run sudo apt-get install -y "${missing[@]}"
fi

step "2/4 Kubespray $KUBESPRAY_VERSION in $KUBESPRAY_DIR"
if [[ -d "$KUBESPRAY_DIR/.git" ]]; then
  current="$(git -C "$KUBESPRAY_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
  if [[ "$current" == "$KUBESPRAY_VERSION" ]]; then
    ok "already checked out ($current) – left unchanged"
  else
    die "$KUBESPRAY_DIR is at version $current, expected $KUBESPRAY_VERSION – upgrades are a manual step (doc 02, section 13.4)"
  fi
else
  run git -c advice.detachedHead=false clone --branch "$KUBESPRAY_VERSION" --depth 1 https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_DIR"
fi

step "3/4 Python venv $KUBESPRAY_VENV with the Kubespray requirements"
if [[ -x "$KUBESPRAY_VENV/bin/python" ]]; then
  ok "venv exists"
else
  run python3 -m venv "$KUBESPRAY_VENV"
  run "$KUBESPRAY_VENV/bin/pip" install -q -U pip
fi
# installs only what is missing; an existing venv with all requirements stays unchanged
run "$KUBESPRAY_VENV/bin/pip" install -q -r "$KUBESPRAY_DIR/requirements.txt"

line="source $KUBESPRAY_VENV/bin/activate"
# also accepts an existing line written as "source ~/kubespray-venv/bin/activate"
if grep -qE "^\s*(source|\.)\s+\S*$(basename "$KUBESPRAY_VENV")/bin/activate\s*$" "$HOME/.bashrc" 2>/dev/null; then
  ok "venv is activated automatically at login"
else
  append_line "$HOME/.bashrc" "$line"
fi

step "4/4 Check Ansible"
if [[ "$DRY_RUN" != 1 ]]; then
  out="$(cd "$KUBESPRAY_DIR" && "$KUBESPRAY_VENV/bin/ansible" --version)"
  echo "$out" | sed -n '1p;/config file/p;/python version/p' | sed 's/^/  /'
  grep -q "config file = $KUBESPRAY_DIR/ansible.cfg" <<<"$out" || die "Ansible does not use $KUBESPRAY_DIR/ansible.cfg"
  ok "Ansible is ready"
fi
info "Next: ./02-kubespray/prepare-inventory.sh"
