#!/usr/bin/env bash
# 04 – Dedicated Keycloak for "Login with AD account": PostgreSQL, certificate from the
#      openDesk CA, truststore with the AD root CA, Helm release codecentric/keycloakx.
#
# Doc:     docs/04-active-directory-sso.md (sections 16, 17, 19.5 and 24.1)
# Run on:  kubespray VM as k8s (needs fetch-ad-files.sh and 03-opendesk/export-ca.sh)
# Usage:   ./setup-keycloak-idp.sh [--dry-run] [--force]
#
#   --force   apply manifests, release values or a login design that differ from the
#             cluster – e.g. after an openDesk update changed its login design
#
# The database and admin passwords are generated once into KEYCLOAK_DB_PASSWORD_FILE
# and KEYCLOAK_ADMIN_PASSWORD_FILE (chmod 600) and never replaced. When cert-manager
# has renewed the openDesk CA, the copy in the namespace idp is updated and the
# certificate of the Keycloak is issued again (doc 04, section 24.1).
# With IDP_LOGIN_THEME set, the login page gets the design of the openDesk login page:
# its theme is copied from the Keycloak of openDesk into the ConfigMap idp-login-theme
# (doc 04, section 19.5). The realm uses it once configure-keycloak-realm.sh has run.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars DOMAIN IDP_HOST KEYCLOAKX_VERSION KEYCLOAK_DB_SIZE KEYCLOAK_DB_PASSWORD_FILE \
             KEYCLOAK_ADMIN_PASSWORD_FILE AD_ROOT_CA_FILE OPENDESK_NAMESPACE OPENDESK_CA_FILE
identity_vars
require_cmd helm jq yq curl openssl
use_kubectl
NS="idp"
M="$AUTOMATION_DIR/04-identity/manifests"
TMPD="$(mktemp -d)"; add_exit_hook "rm -rf $TMPD"
sha() { sha256sum | cut -d' ' -f1; }

# cm_keys – one line "key checksum" per entry of a ConfigMap (JSON on stdin)
cm_keys() {
  jq -r '.data // {} | to_entries[] | "\(.key)\t\(.value | @base64)"' \
    | while IFS=$'\t' read -r k v; do printf '%s %s\n' "$k" "$(printf '%s' "$v" | sha | cut -c1-12)"; done
}

# copy_login_theme – copies the login theme of the openDesk Keycloak into
# $TMPD/idp-login-theme.yaml and adds it to $TMPD/keycloak-values.yaml (doc 04, section 19.5)
copy_login_theme() {
  local src="/opt/keycloak/themes/UCS/login" pod f key css logo logo_abs last env_yaml="" items="" args=()
  pod="$(kubectl -n "$OPENDESK_NAMESPACE" get pods -o name | grep -E '/ums-keycloak-[0-9]+$' | head -1 || true)"
  [[ -n "$pod" ]] || die "Keycloak pod of openDesk (ums-keycloak-N) not found"
  # ls -pR marks directories with "/"; the image has no find or tar
  mapfile -t files < <(kubectl -n "$OPENDESK_NAMESPACE" exec "$pod" -- ls -pR "$src" 2>/dev/null \
    | awk -v root="$src" '/:$/ {d = substr($0, 1, length($0) - 1); d = substr(d, length(root) + 2); next}
                          NF && !/\/$/ {print (d == "" ? "" : d "/") $0}')
  [[ ${#files[@]} -gt 0 ]] || die "no theme in $pod:$src – did openDesk change its login design? IDP_LOGIN_THEME= in lab.env uses the Keycloak default page"
  for f in "${files[@]}"; do
    mkdir -p "$TMPD/theme/$(dirname "$f")"
    kubectl -n "$OPENDESK_NAMESPACE" exec "$pod" -- cat "$src/$f" >"$TMPD/theme/$f" 2>/dev/null || die "copying $f from $pod failed"
  done
  [[ -f "$TMPD/theme/theme.properties" ]] || die "theme.properties missing in $pod:$src"
  ok "${#files[@]} files of the openDesk login design copied from ${pod#pod/}"

  # The design loads colours, logo and favicon from the portal; theme.properties reads the
  # addresses from these environment variables of the openDesk Keycloak.
  while IFS='=' read -r k v; do
    env_yaml+="- name: $k"$'\n'"  value: $(jq -Rn --arg v "$v" '$v')"$'\n'
  done < <(kubectl -n "$OPENDESK_NAMESPACE" exec "$pod" -- env 2>/dev/null | grep -E '^UNIVENTION_[A-Z_]+=' | sort)
  [[ -n "$env_yaml" ]] || warn "no UNIVENTION_* variables in $pod – the page may show without colours"

  # custom.css sets the logo with a path relative to id.DOMAIN (--login-logo: url("/…")).
  # On IDP_FQDN that path does not exist, so the copy points to id.DOMAIN.
  css="$(kubectl -n "$OPENDESK_NAMESPACE" exec "$pod" -- env 2>/dev/null | sed -n 's/^UNIVENTION_CUSTOM_THEME=//p' || true)"
  logo="$( { [[ "$css" == https://* ]] && curl -s --cacert "$OPENDESK_CA_FILE" "$css"; } | grep -oE -- '--login-logo:[^;}]+' | head -1 || true)"
  last="$(sed -n 's/^styles=//p' "$TMPD/theme/theme.properties" | awk '{print $NF}')"
  if [[ "$logo" =~ url\(\"?\'?/ && -n "$last" && -f "$TMPD/theme/resources/$last" ]]; then
    logo_abs="$(sed -E 's#url\((["'\'']?)/#url(\1https://'"$OPENDESK_ID_FQDN"'/#' <<<"$logo")"
    printf '\n/* setup-keycloak-idp.sh: the logo path of custom.css only exists on %s */\n* { %s !important; }\n' \
      "$OPENDESK_ID_FQDN" "$logo_abs" >>"$TMPD/theme/resources/$last"
    info "logo: $(grep -oE 'https://[^"'\'')]+' <<<"$logo_abs")"
  else
    warn "no relative --login-logo in ${css:-custom.css} – the page keeps the logo setting of openDesk"
  fi

  # ConfigMap keys cannot contain "/": resources/css/login.css -> resources__css__login.css
  for f in "${files[@]}"; do
    key="${f//\//__}"
    args+=("--from-file=$key=$TMPD/theme/$f")
    items+="      - {key: $key, path: login/$f}"$'\n'
  done
  kubectl -n "$NS" create configmap idp-login-theme "${args[@]}" --dry-run=client -o yaml \
    | NS="$NS" yq '.metadata.namespace = strenv(NS) | del(.metadata.creationTimestamp)' >"$TMPD/idp-login-theme.yaml"
  ADD_ENV="$env_yaml" \
  ADD_VOL="- name: login-theme"$'\n'"  configMap:"$'\n'"    name: idp-login-theme"$'\n'"    items:"$'\n'"$items" \
  ADD_MNT="- name: login-theme"$'\n'"  mountPath: /opt/keycloak/themes/$IDP_LOGIN_THEME"$'\n'"  readOnly: true"$'\n' \
    yq -i '.extraEnv += strenv(ADD_ENV) | .extraVolumes += strenv(ADD_VOL) | .extraVolumeMounts += strenv(ADD_MNT)' \
      "$TMPD/keycloak-values.yaml"
}

step "1/6 Namespace, passwords and secrets"
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

step "2/6 PostgreSQL ($KEYCLOAK_DB_SIZE on Longhorn)"
render_template "$M/keycloak-postgres.yaml" KEYCLOAK_DB_SIZE >"$TMPD/keycloak-postgres.yaml"
apply_manifest "$TMPD/keycloak-postgres.yaml"
[[ "$DRY_RUN" == 1 ]] || kubectl -n "$NS" rollout status statefulset keycloak-postgres --timeout=5m | indent

step "3/6 Copy of the openDesk CA and certificate for $IDP_FQDN"
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

step "4/6 Login page in the openDesk design"
render_template "$M/keycloak-values.yaml" IDP_URL IDP_FQDN >"$TMPD/keycloak-values.yaml"
CM_STATE="off"   # off | new | same | differs
if [[ -z "$IDP_LOGIN_THEME" ]]; then
  info "IDP_LOGIN_THEME is empty – Keycloak shows its default login page"
else
  copy_login_theme
  if ! kubectl -n "$NS" get configmap idp-login-theme >/dev/null 2>&1; then
    CM_STATE="new"; info "ConfigMap idp-login-theme does not exist yet – it is created in the next step"
  elif kubectl diff -f "$TMPD/idp-login-theme.yaml" >/dev/null 2>&1; then CM_STATE="same"; ok "ConfigMap idp-login-theme is up to date"
  else
    CM_STATE="differs"
    warn "the login design of openDesk differs from the ConfigMap idp-login-theme (openDesk updated?):"
    diff <(kubectl -n "$NS" get configmap idp-login-theme -o json | cm_keys) <(yq -o=json "$TMPD/idp-login-theme.yaml" | cm_keys) | indent '    ' || true
  fi
fi

step "5/6 Keycloak (codecentric/keycloakx $KEYCLOAKX_VERSION)"
if ! helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx codecentric; then
  run helm repo add codecentric https://codecentric.github.io/helm-charts
  run helm repo update codecentric
fi
# A missing ConfigMap is created right away (no pod uses it before the release does). An
# existing one is only replaced together with the restart that loads it: a running pod
# whose ConfigMap lost a file would not start again after its next restart.
[[ "$CM_STATE" == new ]] && run kubectl apply -f "$TMPD/idp-login-theme.yaml"
apply_theme() { if [[ "$CM_STATE" == differs ]]; then run kubectl apply -f "$TMPD/idp-login-theme.yaml"; fi; }
if [[ -z "$(helm_chart_version "$NS" keycloak)" ]]; then
  helm_install_once "$NS" keycloak codecentric/keycloakx "$KEYCLOAKX_VERSION" 10m --values "$TMPD/keycloak-values.yaml"
elif helm_values_match "$NS" keycloak "$TMPD/keycloak-values.yaml"; then
  ok "release keycloak $(helm_chart_version "$NS" keycloak) – values match"
  if [[ "$CM_STATE" != differs ]]; then :
  elif [[ "$FLAG_FORCE" == 1 ]]; then
    apply_theme
    run kubectl -n "$NS" rollout restart statefulset keycloak-keycloakx
    run kubectl -n "$NS" rollout status statefulset keycloak-keycloakx --timeout=5m
  else
    warn "login design not changed – use --force to copy it again (Keycloak restarts, about 1 minute)"
  fi
elif [[ "$FLAG_FORCE" == 1 ]]; then
  apply_theme
  run helm upgrade keycloak codecentric/keycloakx -n "$NS" --version "$KEYCLOAKX_VERSION" \
    --values "$TMPD/keycloak-values.yaml" --timeout 10m --wait
else
  warn "values of the release keycloak differ (see above) – not changed; use --force to upgrade"
fi

[[ "$DRY_RUN" == 1 ]] && exit 0
step "6/6 Checks"
check "pod keycloak-keycloakx-0 ready" kubectl -n "$NS" wait --for=condition=Ready pod/keycloak-keycloakx-0 --timeout=5m
issuer="$(curl -s --cacert "$OPENDESK_CA_FILE" "$IDP_URL/realms/master/.well-known/openid-configuration" | jq -r '.issuer // empty' || true)"
check "issuer $IDP_URL/realms/master (trusted with the openDesk CA)" test "$issuer" = "$IDP_URL/realms/master"
days=$(( ( $(date -d "$(kubectl -n "$NS" get secret idp-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
check "certificate $IDP_FQDN valid for $days more days" test "$days" -gt 0
if [[ -n "$IDP_LOGIN_THEME" ]]; then
  check "login design mounted (/opt/keycloak/themes/$IDP_LOGIN_THEME)" \
    kubectl -n "$NS" exec keycloak-keycloakx-0 -c keycloak -- test -f "/opt/keycloak/themes/$IDP_LOGIN_THEME/login/theme.properties"
fi
info "Next: ./04-identity/configure-keycloak-realm.sh"
check_summary
