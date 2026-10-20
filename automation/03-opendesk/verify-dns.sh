#!/usr/bin/env bash
# 03 – Check name resolution in the cluster: split DNS in CoreDNS and nodelocaldns,
#      and resolution from a pod on every worker.
#
# Doc:     docs/03-opendesk-deployment.md (sections 2.5 and 18.2)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-dns.sh
#
# Read-only apart from short-lived test pods in the namespace "dns-test".
# Run it again after every Kubespray run (scale.yml, upgrade-cluster.yml).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars DOMAIN AD_DOMAIN AD_DC_IP LB_IP KUBECONFIG_PATH
use_kubectl
NS="dns-test"
trap 'kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

step "1/3 Corefiles"
for cm in coredns nodelocaldns; do
  corefile="$(kubectl -n kube-system get cm "$cm" -o jsonpath='{.data.Corefile}')"
  # the server block that starts with the zone names, up to its matching closing brace
  # (it contains nested blocks such as "errors { }", so the braces are counted)
  block="$(awk -v d="$DOMAIN" '!f && index($0, d) && /\{/ {f=1}
    f {print; n += gsub(/\{/, "{"); n -= gsub(/\}/, "}"); if (n <= 0) exit}' <<<"$corefile")"
  check "$cm: block for $DOMAIN $AD_DOMAIN" grep -q "$AD_DOMAIN" <<<"$block"
  check "$cm: forwards to $AD_DC_IP"     grep -qE "forward \. $AD_DC_IP" <<<"$block"
done
strict="$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '$1 == "strictARP:" {print $2}')"
check "kube-proxy strictARP: true" test "$strict" = true

step "2/3 Resolution from a pod on every worker"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$NS" >/dev/null
workers="$(kubectl get nodes --no-headers | grep -v control-plane | awk '{print $1}')"
for n in $workers; do
  kubectl -n "$NS" run "dns-$n" --image=alpine:3.20 --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$n\"}}" --command -- sh -c \
    "echo search=\$(grep ^search /etc/resolv.conf); echo portal=\$(getent hosts portal.$DOMAIN | awk '{print \$1}'); echo ad=\$(getent hosts $AD_DOMAIN | awk '{print \$1}' | xargs); echo ext=\$(getent hosts github.com | awk '{print \$1}')" >/dev/null
done
for n in $workers; do
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/dns-$n" --timeout=120s >/dev/null 2>&1 || true
done

step "3/3 Results"
for n in $workers; do
  out="$(kubectl -n "$NS" logs "dns-$n" 2>/dev/null || true)"
  get() { sed -n "s/^$1=//p" <<<"$out"; }
  check "$n: portal.$DOMAIN -> $LB_IP"         test "$(get portal)" = "$LB_IP"
  check "$n: $AD_DOMAIN -> $AD_DC_IP"          grep -qw "$AD_DC_IP" <<<"$(get ad)"
  check "$n: external names (github.com)"      test -n "$(get ext)"
  check "$n: $DOMAIN not in the search line"   bash -c "! grep -qw '$DOMAIN' <<<\"\$1\"" _ "$(get search)"
done

check_summary
