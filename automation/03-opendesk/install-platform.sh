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

# install_chart NAMESPACE RELEASE CHART VERSION TIMEOUT [helm args...]
install_chart() {
  local ns="$1" rel="$2" chart="$3" ver="$4" timeout="$5"; shift 5
  local current; current="$(helm_chart_version "$ns" "$rel")"
  if [[ -z "$current" ]]; then
    # --timeout is mandatory: with the default of 5 minutes helm marks slow releases as failed
    run helm install "$rel" "$chart" --namespace "$ns" --create-namespace \
      --version "$ver" --timeout "$timeout" --wait "$@"
  elif [[ "$current" == "$ver deployed" ]]; then
    ok "$rel $ver is already installed (deployed) – left unchanged"
  else
    warn "$rel is installed as '$current', expected '$ver deployed' – left unchanged (see doc 03, section 16.1)"
  fi
}

# apply_manifest FILE – creates the resources; existing ones that differ are only
# changed with --force (the difference is shown)
apply_manifest() {
  local f="$1" rc=0
  kubectl diff -f "$f" >"$TMP/diff" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "$(basename "$f"): already applied, no difference"; return 0; fi
  if [[ "$rc" -eq 1 ]] && kubectl get -f "$f" >/dev/null 2>&1; then
    indent '    ' <"$TMP/diff"
    [[ "$FLAG_FORCE" == 1 ]] || die "$(basename "$f") differs from the cluster (see above) – check lab.env, or apply it with --force"
  fi
  run kubectl apply -f "$f"
}

step "1/4 MetalLB $METALLB_VERSION and address range $LB_RANGE"
install_chart metallb-system metallb metallb/metallb "$METALLB_VERSION" 10m
if [[ "$DRY_RUN" != 1 ]]; then
  kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=5m >/dev/null
fi
render_template "$M/metallb-pool.yaml" LB_RANGE > "$TMP/metallb-pool.yaml"
apply_manifest "$TMP/metallb-pool.yaml"
warn "the range $LB_RANGE must be excluded in the DHCP server (cannot be checked from here)"

step "2/4 Longhorn $LONGHORN_VERSION"
install_chart longhorn-system longhorn longhorn/longhorn "$LONGHORN_VERSION" 15m

step "3/4 HAProxy Ingress $HAPROXY_INGRESS_VERSION on $LB_IP"
render_template "$M/haproxy-values.yaml" LB_IP > "$TMP/haproxy-values.yaml"
install_chart ingress-controller haproxy-ingress haproxy-ingress/haproxy-ingress "$HAPROXY_INGRESS_VERSION" 10m \
  -f "$TMP/haproxy-values.yaml"
if [[ -n "$(helm_chart_version ingress-controller haproxy-ingress)" ]]; then
  # compare the values of the running release with the file in the repository
  norm() { yq -P '(... comments = "") | sort_keys(..)'; }   # without comments, sorted keys
  if diff <(helm -n ingress-controller get values haproxy-ingress -o yaml | norm) \
          <(norm <"$TMP/haproxy-values.yaml") >"$TMP/vdiff"; then
    ok "values of the release match manifests/haproxy-values.yaml"
  else
    warn "values of the release differ from manifests/haproxy-values.yaml:"; indent '    ' <"$TMP/vdiff"
  fi
fi

step "4/4 cert-manager $CERT_MANAGER_VERSION and ClusterIssuer"
install_chart cert-manager cert-manager jetstack/cert-manager "$CERT_MANAGER_VERSION" 10m --set crds.enabled=true
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
