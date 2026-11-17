#!/usr/bin/env bash
# 03 – Install helm, the helm-diff plugin, helmfile and yq on the kubespray VM,
#      and add the Helm chart repositories.
#
# Doc:     docs/03-opendesk-deployment.md (sections 4.1 and 9)
# Run on:  kubespray VM as k8s
# Usage:   ./install-tools.sh [--dry-run]
#
# Safe to run again: tools that already have the expected version are skipped.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars HELM_VERSION HELM_DIFF_VERSION HELMFILE_VERSION YQ_VERSION
require_cmd curl tar sudo
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# has_version "OUTPUT" 1.7.3 – true if OUTPUT contains the version, with or without a leading "v"
has_version() { local v="${2#v}"; grep -qE "(^|[^0-9.])v?${v//./\\.}([^0-9]|$)" <<<"$1"; }

step "1/5 helm $HELM_VERSION"
if helm version --short 2>/dev/null | grep -q "^${HELM_VERSION}+"; then
  ok "$(helm version --short) already installed"
else
  run curl -fsSL -o "$TMP/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  run tar xzf "$TMP/helm.tgz" -C "$TMP"
  run sudo install -m 755 "$TMP/linux-amd64/helm" /usr/local/bin/helm
fi

step "2/5 helm-diff plugin $HELM_DIFF_VERSION (required by helmfile apply)"
current="$(helm plugin list 2>/dev/null | awk '$1 == "diff" {print $2}')"
if [[ "$current" == "${HELM_DIFF_VERSION#v}" ]]; then
  ok "helm-diff $current already installed"
elif [[ -n "$current" ]]; then
  warn "helm-diff $current is installed (expected ${HELM_DIFF_VERSION#v}) – left unchanged"
else
  run helm plugin install https://github.com/databus23/helm-diff --version "$HELM_DIFF_VERSION"
fi

step "3/5 helmfile $HELMFILE_VERSION"
if has_version "$(helmfile --version 2>/dev/null)" "$HELMFILE_VERSION"; then
  ok "helmfile $HELMFILE_VERSION already installed"
else
  run curl -fsSL -o "$TMP/helmfile.tgz" \
    "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz"
  run tar xzf "$TMP/helmfile.tgz" -C "$TMP" helmfile
  run sudo install -m 755 "$TMP/helmfile" /usr/local/bin/helmfile
fi

step "4/5 yq $YQ_VERSION"
if has_version "$(yq --version 2>/dev/null)" "$YQ_VERSION"; then
  ok "yq $YQ_VERSION already installed"
else
  run curl -fsSL -o "$TMP/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
  run sudo install -m 755 "$TMP/yq" /usr/local/bin/yq
fi

step "5/5 Helm chart repositories"
repos="$(helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' || true)"   # helm exits 1 when no repository exists yet
for entry in metallb=https://metallb.github.io/metallb \
             longhorn=https://charts.longhorn.io \
             haproxy-ingress=https://haproxy-ingress.github.io/charts \
             jetstack=https://charts.jetstack.io; do
  name="${entry%%=*}"; url="${entry#*=}"
  if grep -qx "$name" <<<"$repos"; then ok "repo $name exists"; else run helm repo add "$name" "$url"; fi
done
run helm repo update

if [[ "$DRY_RUN" != 1 ]]; then
  echo
  info "helm     $(helm version --short)"
  info "diff     $(helm plugin list | awk '$1 == "diff" {print $2}')"
  info "helmfile $(helmfile --version 2>/dev/null | awk '{print $NF}')"
  info "yq       $(yq --version | awk '{print $NF}')"
fi
