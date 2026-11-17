#!/usr/bin/env bash
# 04 – Pre-checks before the AD integration: openDesk, DNS from a pod, ports, LDAPS.
#
# Doc:     docs/04-active-directory-sso.md (sections 1 and 2)
# Run on:  kubespray VM as k8s
# Usage:   ./check-prerequisites.sh
#
# Read-only apart from one short-lived test pod in the namespace "identity-test".

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars DOMAIN AD_DOMAIN AD_DC_HOST AD_DC_IP FS_HOST FS_IP LB_IP IDP_HOST OPENDESK_DIR OPENDESK_VERSION
identity_vars
use_kubectl
NS="identity-test"
add_exit_hook "kubectl delete namespace $NS --ignore-not-found --wait=false"

step "1/4 openDesk and tools"
check "openDesk repository at $OPENDESK_VERSION" test "$(git -C "$OPENDESK_DIR" describe --tags 2>/dev/null)" = "$OPENDESK_VERSION"
check "all nodes Ready" bash -c "! kubectl get nodes --no-headers | grep -q NotReady"
check "jq installed" command -v jq
check "openDesk CA exported to $OPENDESK_CA_FILE (03-opendesk/export-ca.sh)" test -s "$OPENDESK_CA_FILE"

step "2/4 Name resolution from a pod"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$NS" >/dev/null
kubectl -n "$NS" run dnstest --image=alpine:3.20 --restart=Never --command -- sh -c \
  "echo dc=\$(getent hosts $AD_DC_FQDN | awk '{print \$1}'); echo fs=\$(getent hosts $FS_FQDN | awk '{print \$1}');
   echo idp=\$(getent hosts $IDP_FQDN | awk '{print \$1}');
   echo srv=\$(nslookup -type=SRV _ldap._tcp.dc._msdcs.$AD_DOMAIN 2>/dev/null | grep -ci 'service =')" >/dev/null
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/dnstest --timeout=120s >/dev/null 2>&1 || true
out="$(kubectl -n "$NS" logs dnstest 2>/dev/null || true)"
get() { sed -n "s/^$1=//p" <<<"$out"; }
check "$AD_DC_FQDN -> $AD_DC_IP"                test "$(get dc)" = "$AD_DC_IP"
check "$FS_FQDN -> $FS_IP"                      test "$(get fs)" = "$FS_IP"
check "$IDP_FQDN -> $LB_IP (wildcard)"          test "$(get idp)" = "$LB_IP"
check "SRV record _ldap._tcp.dc._msdcs.$AD_DOMAIN" test "$(get srv)" -ge 1

step "3/4 Ports from the kubespray VM"
port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
check "$AD_DC_FQDN:389 (LDAP)"   port_open "$AD_DC_FQDN" 389
check "$AD_DC_FQDN:636 (LDAPS)"  port_open "$AD_DC_FQDN" 636
check "$FS_IP:445 (SMB)"         port_open "$FS_IP" 445

step "4/4 LDAPS certificate"
if [[ -s "$AD_ROOT_CA_FILE" ]]; then
  verify="$(openssl s_client -connect "$AD_DC_FQDN:636" -servername "$AD_DC_FQDN" -CAfile "$AD_ROOT_CA_FILE" </dev/null 2>/dev/null | grep 'Verify return code' || true)"
  check "LDAPS certificate trusted with $(basename "$AD_ROOT_CA_FILE") (${verify#*: })" grep -q 'return code: 0 (ok)' <<<"$verify"
else
  warn "$AD_ROOT_CA_FILE not found – run ./04-identity/fetch-ad-files.sh"
fi

check_summary
