#!/usr/bin/env bash
# 03 – Set strictARP in the running kube-proxy configuration.
#
# Doc:     docs/03-opendesk-deployment.md (section 2.4, error F2)
# Run on:  kubespray VM as k8s, after cluster.yml
# Usage:   ./fix-strictarp.sh [--dry-run]
#
# Kubespray only writes the kube-proxy ConfigMap at install and upgrade time, so
# kube_proxy_strict_arp in group_vars does not reach an existing cluster. This
# script patches the ConfigMap and restarts kube-proxy – only if needed.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars KUBECONFIG_PATH INVENTORY_NAME
use_kubectl

strict="$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '$1 == "strictARP:" {print $2}')"
mode="$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '$1 == "mode:" {print $2}' | tr -d '"')"
info "kube-proxy mode: ${mode:-?}, strictARP: ${strict:-?}"

step "1/2 strictARP in the kube-proxy ConfigMap"
if [[ "$strict" == true ]]; then
  ok "strictARP is already true – nothing to do"
else
  echo "  \$ kubectl -n kube-system get cm kube-proxy -o yaml | sed 's/strictARP: false/strictARP: true/' | kubectl apply -f -"
  if [[ "$DRY_RUN" != 1 ]]; then
    kubectl -n kube-system get cm kube-proxy -o yaml | sed 's/strictARP: false/strictARP: true/' | kubectl -n kube-system apply -f -
  fi
  run kubectl -n kube-system rollout restart ds kube-proxy
  run kubectl -n kube-system rollout status ds kube-proxy --timeout=5m
fi

step "2/2 ARP settings on all nodes (arp_ignore = 1, arp_announce = 2)"
if [[ "$DRY_RUN" != 1 ]]; then
  use_kubespray
  out="$(ansible -i "$INV" all -m command -a 'sysctl -n net.ipv4.conf.all.arp_ignore net.ipv4.conf.all.arp_announce' -o)"
  total="$(grep -c 'rc=0' <<<"$out" || true)"
  good="$(grep -cE 'rc=0 .*\(stdout\) 1\\n2' <<<"$out" || true)"
  check "arp_ignore=1 and arp_announce=2 on $good of $total nodes" test "$good" -eq "$total" -a "$total" -gt 0
  check_summary
fi
