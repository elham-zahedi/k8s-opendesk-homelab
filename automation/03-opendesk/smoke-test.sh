#!/usr/bin/env bash
# 03 – Acceptance test of the base services before openDesk is rolled out:
#      Longhorn volume in a pod (iSCSI), certificate, ingress without a class,
#      and the full chain DNS -> MetalLB -> HAProxy -> service -> pod.
#
# Doc:     docs/03-opendesk-deployment.md (section 8.1)
# Run on:  kubespray VM as k8s (needs split-dns.sh for the last check)
# Usage:   ./smoke-test.sh
#
# Everything runs in the temporary namespace "smoke-test", which is deleted at
# the end (including the 1 GiB Longhorn volume).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars DOMAIN KUBECONFIG_PATH
require_cmd curl
use_kubectl
NS="smoke-test"
trap 'kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

step "1/2 Create the test resources in namespace $NS"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$NS" >/dev/null
render_template "$AUTOMATION_DIR/03-opendesk/manifests/smoke-test.yaml" DOMAIN | kubectl -n "$NS" apply -f - | indent

step "2/2 Checks (volumes can take a minute to attach)"
k() { kubectl -n "$NS" "$@"; }
check "PVC Bound (StorageClass longhorn)"   k wait --for=jsonpath='{.status.phase}'=Bound pvc/smoke-pvc --timeout=180s
check "pod with the volume Running"         k wait --for=condition=Ready pod/smoke-vol --timeout=300s
check "volume writable (log: longhorn-ok)"  bash -c "kubectl -n $NS logs smoke-vol | grep -qx longhorn-ok"
check "certificate Ready"                   k wait --for=condition=Ready certificate/smoke-cert --timeout=120s
check "ingress got the default class haproxy" bash -c "kubectl -n $NS get ingress smoke-ingress -o jsonpath='{.spec.ingressClassName}' | grep -qx haproxy"
check "nginx Running"                       k rollout status deploy/smoke-nginx --timeout=180s
code="000"
for _ in $(seq 12); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://smoke.$DOMAIN" || true)"
  [[ "$code" == 200 ]] && break
  sleep 5
done
check "http://smoke.$DOMAIN -> 200 (got $code)" test "$code" = 200
info "volume on node: $(k get pod smoke-vol -o jsonpath='{.spec.nodeName}')"

check_summary
