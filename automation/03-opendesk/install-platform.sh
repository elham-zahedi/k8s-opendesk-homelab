#!/usr/bin/env bash
# 03 – Install the platform services: MetalLB, Longhorn, HAProxy Ingress, cert-manager.
#
# Doc:     docs/03-opendesk-deployment.md (sections 4.2, 5, 6.1 and 7)
# Run on:  kubespray VM as k8s
# Usage:   ./install-platform.sh [--dry-run] [--force]
#
#   --force   apply the MetalLB pool / ClusterIssuer even if they differ in the cluster
#
# A Helm release that already exists in the expected version is left unchanged
# (upgrades are a manual decision). The MetalLB pool and the ClusterIssuer are
# applied with kubectl and show "unchanged" if they are already correct. For an
# existing HAProxy release, its values are compared with manifests/haproxy-values.yaml.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars LB_IP LB_RANGE METALLB_VERSION LONGHORN_VERSION HAPROXY_INGRESS_VERSION CERT_MANAGER_VERSION KUBECONFIG_PATH
require_cmd helm yq curl
use_kubectl
M="$AUTOMATION_DIR/03-opendesk/manifests"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

step "1/4 MetalLB $METALLB_VERSION and address range $LB_RANGE"
helm_install_once metallb-system metallb metallb/metallb "$METALLB_VERSION" 10m
if [[ "$DRY_RUN" != 1 ]]; then
  kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=5m >/dev/null
fi
render_template "$M/metallb-pool.yaml" LB_RANGE > "$TMP/metallb-pool.yaml"
apply_manifest "$TMP/metallb-pool.yaml"
warn "the range $LB_RANGE must be excluded in the DHCP server (cannot be checked from here)"

step "2/4 Longhorn $LONGHORN_VERSION"
helm_install_once longhorn-system longhorn longhorn/longhorn "$LONGHORN_VERSION" 15m

step "3/4 HAProxy Ingress $HAPROXY_INGRESS_VERSION on $LB_IP"
render_template "$M/haproxy-values.yaml" LB_IP > "$TMP/haproxy-values.yaml"
helm_install_once ingress-controller haproxy-ingress haproxy-ingress/haproxy-ingress "$HAPROXY_INGRESS_VERSION" 10m \
  -f "$TMP/haproxy-values.yaml"
if [[ -n "$(helm_chart_version ingress-controller haproxy-ingress)" ]]; then
  # compare the values of the running release with the file in the repository
  if helm_values_match ingress-controller haproxy-ingress "$TMP/haproxy-values.yaml"; then
    ok "values of the release match manifests/haproxy-values.yaml"
  else
    warn "values of the release differ from manifests/haproxy-values.yaml (see above)"
  fi
fi

step "4/4 cert-manager $CERT_MANAGER_VERSION and ClusterIssuer"
helm_install_once cert-manager cert-manager jetstack/cert-manager "$CERT_MANAGER_VERSION" 10m --set crds.enabled=true
if [[ "$DRY_RUN" != 1 ]]; then
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m >/dev/null
fi
apply_manifest "$M/cluster-issuer.yaml"

[[ "$DRY_RUN" == 1 ]] && exit 0

step "Checks"
check "MetalLB controller running"            kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=60s
check "IPAddressPool cluster-pool exists"     kubectl -n metallb-system get ipaddresspool cluster-pool
check "StorageClass longhorn is the default"  bash -c "kubectl get storageclass longhorn -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -qx true"
check "IngressClass haproxy is the default"   bash -c "kubectl get ingressclass haproxy -o jsonpath='{.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}' | grep -qx true"
check "HAProxy service has address $LB_IP"    bash -c "kubectl -n ingress-controller get svc haproxy-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -qx '$LB_IP'"
check "http://$LB_IP answers (404 from HAProxy)" bash -c "curl -s -o /dev/null -m 5 -w '%{http_code}' http://$LB_IP | grep -qx 404"
check "ClusterIssuer selfsigned-issuer Ready" bash -c "kubectl get clusterissuer selfsigned-issuer -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
for ns in metallb-system longhorn-system ingress-controller cert-manager; do
  check "all pods in $ns Running" test -z "$(kubectl -n "$ns" get pods --no-headers | grep -vE ' Running | Completed ' || true)"
done
check_summary
