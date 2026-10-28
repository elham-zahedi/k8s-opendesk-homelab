#!/usr/bin/env bash
# 04 – Check "Login with AD account" end to end (everything except the browser).
#
# Doc:     docs/04-active-directory-sso.md (sections 17, 19, 21 and 24.2)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-sso.sh
#
# Read-only apart from one short-lived curl pod in the namespace "identity-test".
# The browser test (one login per test account) stays manual – doc 04, section 20.

# shellcheck disable=SC2016  # $variables inside single quotes are jq variables
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars DOMAIN IDP_HOST IDP_REALM IDP_CLIENT IDP_KEY OPENDESK_NAMESPACE OPENDESK_DIR OPENDESK_ENV
identity_vars
require_cmd jq curl yq openssl
use_kubectl
NS="identity-test"
add_exit_hook "kubectl delete namespace $NS --ignore-not-found --wait=false"
sha() { sha256sum | cut -d' ' -f1; }

step "1/4 Keycloak $IDP_URL"
check "keycloak-postgres-0 ready"   kubectl -n idp wait --for=condition=Ready pod/keycloak-postgres-0 --timeout=60s
check "keycloak-keycloakx-0 ready"  kubectl -n idp wait --for=condition=Ready pod/keycloak-keycloakx-0 --timeout=60s
issuer="$(curl -s --cacert "$OPENDESK_CA_FILE" "$IDP_URL/realms/$IDP_REALM/.well-known/openid-configuration" | jq -r '.issuer // empty' || true)"
check "issuer of realm $IDP_REALM (trusted with the openDesk CA)" test "$issuer" = "$IDP_URL/realms/$IDP_REALM"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$NS" >/dev/null
kubectl -n "$NS" run nettest --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "$IDP_URL/realms/$IDP_REALM/.well-known/openid-configuration" >/dev/null
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/nettest --timeout=120s >/dev/null 2>&1 || true
code="$(kubectl -n "$NS" logs nettest 2>/dev/null || true)"
check "reachable from a pod (HTTP ${code:-none})" test "$code" = 200

step "2/4 Certificates"
end="$(kubectl -n idp get secret idp-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate | cut -d= -f2)"
days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
check "certificate $IDP_FQDN valid for $days more days (renewed by cert-manager)" test "$days" -gt 0
check "copy of the openDesk CA in idp is up to date (doc 04, section 24.1)" test \
  "$(kubectl -n idp get secret opendesk-ca-copy -o jsonpath='{.data.tls\.crt}')" = \
  "$(kubectl -n "$OPENDESK_NAMESPACE" get secret opendesk-certificates-ca-tls -o jsonpath='{.data.tls\.crt}')"

step "3/4 Realm $IDP_REALM"
kc_connect
kc GET "/$IDP_REALM/users/count"; users="$(cat "$KC_BODY")"
if [[ -n "${AD_EXPECTED_USERS:-}" ]]; then check "$users users from AD (expected $AD_EXPECTED_USERS)" test "$users" = "$AD_EXPECTED_USERS"
else check "$users users from AD" test "$users" -gt 0; fi
kc GET "/$IDP_REALM/clients?clientId=$IDP_CLIENT"
check "client $IDP_CLIENT with redirect URI $IDP_REDIRECT_URI" \
  jq -e --arg u "$IDP_REDIRECT_URI" '.[0].redirectUris | index($u) != null' "$KC_BODY"
check "client $IDP_CLIENT with post-logout URI …/logout_response (doc 05, error F5)" \
  jq -e --arg u "$IDP_REDIRECT_URI/logout_response" '.[0].attributes["post.logout.redirect.uris"] // "" | split("##") | index($u) != null' "$KC_BODY"
CID="$(jq -r '.[0].id // empty' "$KC_BODY")"
kc GET "/$IDP_REALM/clients/$CID/client-secret"; ks="$(jq -r '.value // ""' "$KC_BODY" | tr -d '\n' | sha)"; : >"$KC_BODY"
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
vs="$(yq ".functional.authentication.ssoFederation.idps[\"$IDP_KEY\"].idpDetails.config.clientSecret // \"\"" "$VALUES" | tr -d '\n' | sha)"
check "client secret in the openDesk configuration matches Keycloak" test "$ks" = "$vs"
kc GET "/$IDP_REALM"
if [[ -n "$IDP_LOGIN_THEME" ]]; then
  check "realm $IDP_REALM uses the login design $IDP_LOGIN_THEME (doc 04, section 19.5)" \
    jq -e --arg t "$IDP_LOGIN_THEME" '.loginTheme == $t' "$KC_BODY"
  page="$(curl -s --cacert "$OPENDESK_CA_FILE" "$IDP_URL/realms/$IDP_REALM/protocol/openid-connect/auth?client_id=$(urlencode "$IDP_CLIENT")&redirect_uri=$(urlencode "$IDP_REDIRECT_URI")&response_type=code&scope=openid" || true)"
  check "login page is served with the design $IDP_LOGIN_THEME" grep -q "/login/$IDP_LOGIN_THEME/" <<<"$page"
fi
if [[ -n "$IDP_LOCALE" ]]; then
  check "login page in language $IDP_LOCALE" jq -e --arg l "$IDP_LOCALE" '.internationalizationEnabled and .defaultLocale == $l' "$KC_BODY"
fi

step "4/4 Identity provider in the openDesk Keycloak"
pw="$(secret_value "$OPENDESK_NAMESPACE" opendesk-keycloak-bootstrap-admin-creds admin.yaml | grep -i password | awk '{print $2}' | tr -d '"')"
[[ -n "$pw" ]] || die "password of kcadmin not found (secret opendesk-keycloak-bootstrap-admin-creds)"
port_forward "$OPENDESK_NAMESPACE" ums-keycloak 18080:8080
token="$(printf '%s' "$pw" | curl -s -d client_id=admin-cli -d username=kcadmin --data-urlencode "password@-" \
  -d grant_type=password http://127.0.0.1:18080/realms/master/protocol/openid-connect/token | jq -r '.access_token // empty')"
unset pw
idps="$(curl -s -H @<(printf 'Authorization: Bearer %s\n' "$token") \
  http://127.0.0.1:18080/admin/realms/opendesk/identity-provider/instances)"
unset token
check "$IDP_ALIAS exists and is enabled" jq -e --arg a "$IDP_ALIAS" '[.[] | select(.alias == $a and .enabled)] | length == 1' <<<"$idps"
info "display name: $(jq -r --arg a "$IDP_ALIAS" '.[] | select(.alias == $a) | .displayName' <<<"$idps" 2>/dev/null)"
VALUES_ENFORCE="$(yq '.functional.authentication.ssoFederation.enforceFederatedLogin // ""' "$VALUES")"
check "enforceFederatedLogin: '$IDP_ENFORCE_KEY' (IDP_ENFORCE=$IDP_ENFORCE)" test "$VALUES_ENFORCE" = "$IDP_ENFORCE_KEY"
# A login of the portal, as the browser starts it: with IDP_ENFORCE=yes the openDesk
# Keycloak answers with a redirect to the broker instead of its own login form. The
# portal client requires PKCE; the challenge is a fixed example value, no login happens.
portal="https://portal.$DOMAIN/univention/oidc/"
start="https://$OPENDESK_ID_FQDN/realms/opendesk/protocol/openid-connect/auth?client_id=$(urlencode "$portal")&redirect_uri=$(urlencode "$portal")&response_type=code&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
target="$(curl -s --cacert "$OPENDESK_CA_FILE" -o /dev/null -w '%{redirect_url}' "$start" || true)"
if [[ "$IDP_ENFORCE" == yes ]]; then
  check "login of the portal goes straight to $IDP_ALIAS (no openDesk login form)" grep -q "/broker/$IDP_ALIAS/login" <<<"$target"
  info "Browser test: https://portal.$DOMAIN shows the login page of $IDP_FQDN directly (doc 04, section 20)"
else
  info "Browser test: https://portal.$DOMAIN -> Log in -> \"$IDP_DISPLAY_NAME\" (doc 04, section 20)"
fi

check_summary
