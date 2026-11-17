#!/usr/bin/env bash
# 04 – Copy the AD root CA and the list of test accounts from the domain controller.
#
# Doc:     docs/04-active-directory-sso.md (section 5)
# Run on:  kubespray VM as k8s
# Usage:   ./fetch-ad-files.sh [--force]
#
#   --force   copy the files again even if they exist
#
# On the DC first run windows/ad-inventory.ps1 -ExportCA (creates the PEM file).
# scp asks for the password of the domain administrator. Afterwards the files are
# converted (UTF-16/CRLF -> UTF-8/LF) and the LDAPS certificate of the DC is verified.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars AD_DOMAIN AD_DC_HOST AD_ADMIN_USER AD_ROOT_CA_FILE TEST_ACCOUNTS_FILE
identity_vars
require_cmd scp openssl file iconv
REMOTE_CA="${REMOTE_CA:-C:/intern-root-ca.pem}"
REMOTE_TESTS="${REMOTE_TESTS:-C:/testkonten.txt}"
REMOTE_USER="${AD_DOMAIN}\\${AD_ADMIN_USER}"

fetch() {  # fetch REMOTE LOCAL
  if [[ -s "$2" && "$FLAG_FORCE" != 1 ]]; then ok "$2 exists – not copied again (--force to refresh)"; return 0; fi
  run scp "$REMOTE_USER@$AD_DC_FQDN:$1" "$2"
}
to_unix() {  # to_unix FILE – UTF-16 -> UTF-8, CRLF -> LF
  [[ "$DRY_RUN" == 1 || ! -f "$1" ]] && return 0
  if file -b "$1" | grep -qi 'UTF-16'; then
    iconv -f UTF-16 -t UTF-8 "$1" > "$1.tmp" && mv "$1.tmp" "$1"; info "$(basename "$1"): converted from UTF-16"
  fi
  if grep -q $'\r' "$1"; then sed -i 's/\r$//' "$1"; info "$(basename "$1"): CRLF -> LF"; fi
}

step "1/3 Root CA $AD_ROOT_CA_FILE"
fetch "$REMOTE_CA" "$AD_ROOT_CA_FILE"
to_unix "$AD_ROOT_CA_FILE"

step "2/3 Test accounts $TEST_ACCOUNTS_FILE"
fetch "$REMOTE_TESTS" "$TEST_ACCOUNTS_FILE"
to_unix "$TEST_ACCOUNTS_FILE"

[[ "$DRY_RUN" == 1 ]] && exit 0
step "3/3 Checks"
check "root CA is a valid certificate"   openssl x509 -in "$AD_ROOT_CA_FILE" -noout
info "$(openssl x509 -in "$AD_ROOT_CA_FILE" -noout -subject -enddate | tr '\n' ' ')"
check "no Windows line endings left"     bash -c "! grep -q $'\r' '$AD_ROOT_CA_FILE' '$TEST_ACCOUNTS_FILE'"
verify="$(openssl s_client -connect "$AD_DC_FQDN:636" -servername "$AD_DC_FQDN" -CAfile "$AD_ROOT_CA_FILE" </dev/null 2>/dev/null | grep 'Verify return code' || true)"
check "LDAPS of $AD_DC_FQDN trusted (${verify#*: })" grep -q 'return code: 0 (ok)' <<<"$verify"
accounts="$(grep -cE '^[^;]+;[^;]+;[^;]+$' "$TEST_ACCOUNTS_FILE" || true)"
check "$accounts test accounts in the format role;login;groups" test "$accounts" -gt 0
check_summary
