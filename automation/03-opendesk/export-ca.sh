#!/usr/bin/env bash
# 03 – Export the openDesk root CA for the workstations.
#
# Doc:     docs/03-opendesk-deployment.md (sections 14.2 and 18.1)
# Run on:  kubespray VM as k8s
# Usage:   ./export-ca.sh            writes ~/opendesk-ca.crt
#
# Prints the SHA1 fingerprint and the Windows thumbprint. Then copy the file to the
# workstation (e.g. via jumphost) and run windows/import-ca.ps1 with that thumbprint.
# The CA is public – it contains no secret.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE KUBECONFIG_PATH
require_cmd openssl base64
use_kubectl
OUT="${CA_FILE:-$HOME/opendesk-ca.crt}"

step "Export secret opendesk-certificates-ca-tls to $OUT"
run_masked "kubectl -n $OPENDESK_NAMESPACE get secret opendesk-certificates-ca-tls -o jsonpath='{.data.ca\\.crt}' | base64 -d > $OUT" true
[[ "$DRY_RUN" == 1 ]] && exit 0
kubectl -n "$OPENDESK_NAMESPACE" get secret opendesk-certificates-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OUT"
openssl x509 -in "$OUT" -noout >/dev/null 2>&1 || die "$OUT is not a valid certificate"

sha1="$(openssl x509 -in "$OUT" -noout -fingerprint -sha1 | cut -d= -f2)"
end="$(openssl x509 -in "$OUT" -noout -enddate | cut -d= -f2)"
days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
info "subject:     $(openssl x509 -in "$OUT" -noout -subject | sed 's/^subject=//')"
info "valid until: $end ($days days)"
info "SHA1:        $sha1"
info "thumbprint:  ${sha1//:/}   (compare with Windows)"
[[ "$days" -gt 30 ]] || warn "the CA expires in $days days – cert-manager renews it; import the new one on every workstation"
echo
info "On the workstation (PowerShell as administrator):"
info "  .\\import-ca.ps1 -CertFile C:\\Temp\\opendesk-ca.crt -ExpectedThumbprint ${sha1//:/}"
