#!/usr/bin/env bash
# 04 – Dedicated Keycloak for "Login with AD account": PostgreSQL, certificate from the
#      openDesk CA, truststore with the AD root CA, Helm release codecentric/keycloakx.
#
# Doc:     docs/04-active-directory-sso.md (sections 16, 17 and 24.1)
# Run on:  kubespray VM as k8s (needs fetch-ad-files.sh and 03-opendesk/export-ca.sh)
# Usage:   ./setup-keycloak-idp.sh [--dry-run] [--force]
#
#   --force   apply manifests or release values that differ from the cluster
#
# The database and admin passwords are generated once into KEYCLOAK_DB_PASSWORD_FILE
# and KEYCLOAK_ADMIN_PASSWORD_FILE (chmod 600) and never replaced. When cert-manager
# has renewed the openDesk CA, the copy in the namespace idp is updated and the
# certificate of the Keycloak is issued again (doc 04, section 24.1).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars DOMAIN IDP_HOST KEYCLOAKX_VERSION KEYCLOAK_DB_SIZE KEYCLOAK_DB_PASSWORD_FILE \
             KEYCLOAK_ADMIN_PASSWORD_FILE AD_ROOT_CA_FILE OPENDESK_NAMESPACE OPENDESK_CA_FILE
identity_vars
require_cmd helm jq curl openssl
use_kubectl
NS="idp"
M="$AUTOMATION_DIR/04-identity/manifests"
TMPD="$(mktemp -d)"; add_exit_hook "rm -rf $TMPD"
sha() { sha256sum | cut -d' ' -f1; }

step "1/5 Namespace, passwords and secrets"
if kubectl get namespace "$NS" >/dev/null 2>&1; then ok "namespace $NS exists"; else run kubectl create namespace "$NS"; fi
for spec in "$KEYCLOAK_DB_PASSWORD_FILE:32" "$KEYCLOAK_ADMIN_PASSWORD_FILE:24"; do
  f="${spec%:*}"
  if [[ -s "$f" ]]; then ok "$(basename "$f") exists – never replaced"
  else
    info "\$ generate $f (${spec##*:} characters, chmod 600)"
    [[ "$DRY_RUN" == 1 ]] || ( umask 077; random_password "${spec##*:}" > "$f" )
  fi
done
if secret_exists "$NS" keycloak-db; then ok "secret keycloak-db exists"
else tr -d '\n' <"$KEYCLOAK_DB_PASSWORD_FILE" 2>/dev/null | put_secret "$NS" keycloak-db password; fi
if secret_exists "$NS" keycloak-admin; then ok "secret keycloak-admin exists"
else tr -d '\n' <"$KEYCLOAK_ADMIN_PASSWORD_FILE" 2>/dev/null | put_secret "$NS" keycloak-admin password --from-literal=username=admin; fi
[[ -s "$AD_ROOT_CA_FILE" ]] || die "$AD_ROOT_CA_FILE not found – run ./04-identity/fetch-ad-files.sh"
CA_KEY="$(basename "$AD_ROOT_CA_FILE")"   # file name = key in the truststore secret
if ! secret_exists "$NS" ad-root-ca; then
  put_secret "$NS" ad-root-ca "$CA_KEY" <"$AD_ROOT_CA_FILE"
elif [[ "$(secret_value "$NS" ad-root-ca "$CA_KEY" | sha)" == "$(sha <"$AD_ROOT_CA_FILE")" ]]; then
  ok "secret ad-root-ca (truststore) matches $CA_KEY"
else
  warn "secret ad-root-ca differs from $AD_ROOT_CA_FILE – not changed"
fi

step "2/5 PostgreSQL ($KEYCLOAK_DB_SIZE on Longhorn)"
render_template "$M/keycloak-postgres.yaml" KEYCLOAK_DB_SIZE >"$TMPD/keycloak-postgres.yaml"
apply_manifest "$TMPD/keycloak-postgres.yaml"
[[ "$DRY_RUN" == 1 ]] || kubectl -n "$NS" rollout status statefulset keycloak-postgres --timeout=5m | indent

step "3/5 Copy of the openDesk CA and certificate for $IDP_FQDN"
src="$(kubectl -n "$OPENDESK_NAMESPACE" get secret opendesk-certificates-ca-tls -o jsonpath='{.data.tls\.crt}')"
cur="$(kubectl -n "$NS" get secret opendesk-ca-copy -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
if [[ -n "$cur" && "$cur" == "$src" ]]; then
  ok "opendesk-ca-copy is up to date"
else
  [[ -n "$cur" ]] && warn "the openDesk CA was renewed – updating the copy and issuing $IDP_FQDN again"
  echo "  \$ copy secret $OPENDESK_NAMESPACE/opendesk-certificates-ca-tls -> $NS/opendesk-ca-copy (tls.crt, tls.key)"
  if [[ "$DRY_RUN" != 1 ]]; then
    kubectl -n "$OPENDESK_NAMESPACE" get secret opendesk-certificates-ca-tls -o json \
      | jq --arg ns "$NS" '{apiVersion, kind, type, data: {"tls.crt": .data["tls.crt"], "tls.key": .data["tls.key"]},
                           metadata: {name: "opendesk-ca-copy", namespace: $ns}}' \
      | kubectl apply -f - >/dev/null
    if [[ -n "$cur" ]]; then kubectl -n "$NS" delete secret idp-tls --ignore-not-found >/dev/null; fi
  fi
fi
render_template "$M/idp-cert.yaml" IDP_FQDN >"$TMPD/idp-cert.yaml"
apply_manifest "$TMPD/idp-cert.yaml"
[[ "$DRY_RUN" == 1 ]] || kubectl -n "$NS" wait --for=condition=Ready certificate/idp-tls --timeout=2m >/dev/null

step "4/5 Keycloak (codecentric/keycloakx $KEYCLOAKX_VERSION)"
if ! helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx codecentric; then
  run helm repo add codecentric https://codecentric.github.io/helm-charts
  run helm repo update codecentric
fi
render_template "$M/keycloak-values.yaml" IDP_URL IDP_FQDN >"$TMPD/keycloak-values.yaml"
if [[ -z "$(helm_chart_version "$NS" keycloak)" ]]; then
  helm_install_once "$NS" keycloak codecentric/keycloakx "$KEYCLOAKX_VERSION" 10m --values "$TMPD/keycloak-values.yaml"
elif helm_values_match "$NS" keycloak "$TMPD/keycloak-values.yaml"; then
  ok "release keycloak $(helm_chart_version "$NS" keycloak) – values match"
elif [[ "$FLAG_FORCE" == 1 ]]; then
  run helm upgrade keycloak codecentric/keycloakx -n "$NS" --version "$KEYCLOAKX_VERSION" \
    --values "$TMPD/keycloak-values.yaml" --timeout 10m --wait
else
  warn "values of the release keycloak differ (see above) – not changed; use --force to upgrade"
fi

[[ "$DRY_RUN" == 1 ]] && exit 0
step "5/5 Checks"
check "pod keycloak-keycloakx-0 ready" kubectl -n "$NS" wait --for=condition=Ready pod/keycloak-keycloakx-0 --timeout=5m
issuer="$(curl -s --cacert "$OPENDESK_CA_FILE" "$IDP_URL/realms/master/.well-known/openid-configuration" | jq -r '.issuer // empty' || true)"
check "issuer $IDP_URL/realms/master (trusted with the openDesk CA)" test "$issuer" = "$IDP_URL/realms/master"
days=$(( ( $(date -d "$(kubectl -n "$NS" get secret idp-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
check "certificate $IDP_FQDN valid for $days more days" test "$days" -gt 0
info "Next: ./04-identity/configure-keycloak-realm.sh"
check_summary
