#!/usr/bin/env bash
# 04 – Directory Importer: imports the AD users and groups into Nubus every 5 minutes.
#
# Doc:     docs/04-active-directory-sso.md (sections 6 and 7, 24.3)
# Run on:  kubespray VM as k8s (needs fetch-ad-files.sh for the root CA)
# Usage:   ./setup-directory-importer.sh [--dry-run] [--force]
#
#   --force   replace the AD secrets, the values file or release values that differ
#
# Creates namespace, secrets, the target OU and the mail domain in Nubus, the values
# file ~/directory-importer/custom-values.yaml and the Helm release. Everything that
# already exists is only compared. Asks for the password of the AD service account
# (or takes it from $AD_IMPORT_PASSWORD) only if its secret does not exist yet.
# The secret udm-credentials always follows the current Nubus Administrator password:
# after a change in the portal, run the script again – it asks for the new password
# (or takes it from $NUBUS_ADMIN_PASSWORD / NUBUS_ADMIN_PASSWORD_FILE).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars AD_DOMAIN AD_DC_HOST SVC_IMPORT AD_USER_OU AD_GROUP_OU AD_GROUP_PREFIX AD_ROOT_CA_FILE \
             NUBUS_OU NUBUS_BASE_DN DIRECTORY_IMPORTER_VERSION OPENDESK_NAMESPACE
identity_vars
require_cmd helm yq jq curl
use_kubectl
NS="directory-importer"
SVC_IMPORT_UPN="$SVC_IMPORT@$AD_DOMAIN"
VALUES="${DI_VALUES:-$HOME/directory-importer/custom-values.yaml}"
CHART="oci://artifacts.software-univention.de/nubus-dev/charts/directory-importer"
sha() { sha256sum | cut -d' ' -f1; }

# ------------------------------------------------------------------------------
step "1/5 Namespace and secrets"
if kubectl get namespace "$NS" >/dev/null 2>&1; then ok "namespace $NS exists"; else run kubectl create namespace "$NS"; fi

[[ -s "$AD_ROOT_CA_FILE" ]] || die "$AD_ROOT_CA_FILE not found – run ./04-identity/fetch-ad-files.sh first"
if ! secret_exists "$NS" ad-root-ca; then
  put_secret "$NS" ad-root-ca ca-certificates-ad.crt <"$AD_ROOT_CA_FILE"
elif [[ "$(secret_value "$NS" ad-root-ca ca-certificates-ad.crt | sha)" == "$(sha <"$AD_ROOT_CA_FILE")" ]]; then
  ok "secret ad-root-ca matches $(basename "$AD_ROOT_CA_FILE")"
elif [[ "$FLAG_FORCE" == 1 ]]; then
  put_secret "$NS" ad-root-ca ca-certificates-ad.crt <"$AD_ROOT_CA_FILE"
else
  die "secret ad-root-ca differs from $AD_ROOT_CA_FILE – check it, or replace it with --force"
fi

if secret_exists "$NS" ad-bind-credentials && [[ "$FLAG_FORCE" != 1 ]]; then
  ok "secret ad-bind-credentials exists"
else
  ask_secret AD_IMPORT_PASSWORD "Password of $SVC_IMPORT_UPN"
  printf '%s' "$AD_IMPORT_PASSWORD" | put_secret "$NS" ad-bind-credentials password
fi

# The importer logs in to Nubus as Administrator with the password that udm_connect has
# just checked – also after it was changed in the portal (then it is asked for).
udm_connect
if ! secret_exists "$NS" udm-credentials; then
  printf '%s' "$UDM_PW" | put_secret "$NS" udm-credentials password
elif [[ "$(secret_value "$NS" udm-credentials password | sha)" == "$(printf '%s' "$UDM_PW" | sha)" ]]; then
  ok "secret udm-credentials matches the current Nubus administrator password"
else
  warn "secret udm-credentials differs from the current Nubus administrator password – replaced"
  printf '%s' "$UDM_PW" | put_secret "$NS" udm-credentials password
  if kubectl -n "$NS" get deployment directory-importer >/dev/null 2>&1; then
    run kubectl -n "$NS" rollout restart deployment/directory-importer
  fi
fi

# ------------------------------------------------------------------------------
step "2/5 Target OU ou=$NUBUS_OU and mail domain $AD_DOMAIN in Nubus"
if [[ "$(udm_count "container/ou/?filter=$(urlencode "ou=$NUBUS_OU")")" -ge 1 ]]; then
  ok "OU $NUBUS_OU exists"
else
  info "\$ POST container/ou/ name=$NUBUS_OU position=$NUBUS_BASE_DN"
  if [[ "$DRY_RUN" != 1 ]]; then
    udm POST "container/ou/" "{\"properties\":{\"name\":\"$NUBUS_OU\"},\"position\":\"$NUBUS_BASE_DN\"}"
    [[ "$UDM_STATUS" == 201 ]] || die "creating the OU failed (HTTP $UDM_STATUS)"
    ok "OU created"
  fi
fi
# The importer owns this OU: objects created there by hand are deleted again.
if [[ "$(udm_count "mail/domain/?filter=$(urlencode "cn=$AD_DOMAIN")")" -ge 1 ]]; then
  ok "mail domain $AD_DOMAIN exists"
else
  info "\$ POST mail/domain/ name=$AD_DOMAIN   (without it Nubus rejects every @$AD_DOMAIN address)"
  if [[ "$DRY_RUN" != 1 ]]; then
    udm POST "mail/domain/" "{\"properties\":{\"name\":\"$AD_DOMAIN\"}}"
    [[ "$UDM_STATUS" == 201 ]] || die "creating the mail domain failed (HTTP $UDM_STATUS)"
    ok "mail domain created"
  fi
fi

# ------------------------------------------------------------------------------
step "3/5 Values file $VALUES"
TMP="$(mktemp)"; add_exit_hook "rm -f $TMP"
render_template "$AUTOMATION_DIR/04-identity/manifests/directory-importer-values.yaml" \
  UDM_URL_IN_CLUSTER NUBUS_OU AD_DC_FQDN SVC_IMPORT_UPN AD_USER_BASE AD_DOMAIN AD_GROUP_BASE AD_GROUP_PREFIX >"$TMP"
yq '.' "$TMP" >/dev/null || die "rendered values are not valid YAML"
if [[ -f "$VALUES" ]] && yaml_same "$VALUES" "$TMP"; then
  ok "matches manifests/directory-importer-values.yaml"
elif [[ -f "$VALUES" && "$FLAG_FORCE" != 1 ]]; then
  diff <(yq -P 'sort_keys(..)' "$VALUES") <(yq -P '(... comments = "") | sort_keys(..)' "$TMP") | indent '    ' || true
  die "$VALUES differs (see above) – check lab.env, or replace it with --force"
else
  if [[ -f "$VALUES" ]]; then run cp -p "$VALUES" "$VALUES.bak-$(date +%Y%m%d-%H%M%S)"; fi
  run mkdir -p "$(dirname "$VALUES")"
  run cp "$TMP" "$VALUES"
fi

# ------------------------------------------------------------------------------
step "4/5 Helm release directory-importer $DIRECTORY_IMPORTER_VERSION"
current="$(helm_chart_version "$NS" directory-importer)"
if [[ -z "$current" ]]; then
  helm_install_once "$NS" directory-importer "$CHART" "$DIRECTORY_IMPORTER_VERSION" 10m --values "$TMP"
elif helm_values_match "$NS" directory-importer "$TMP"; then
  ok "release $current – values match"
elif [[ "$FLAG_FORCE" == 1 ]]; then
  run helm upgrade directory-importer "$CHART" -n "$NS" --version "$DIRECTORY_IMPORTER_VERSION" \
    --values "$TMP" --timeout 10m --wait
else
  warn "values of the release differ (see above) – not changed; use --force to upgrade"
fi

[[ "$DRY_RUN" == 1 ]] && exit 0
step "5/5 Checks"
check "deployment directory-importer ready" kubectl -n "$NS" rollout status deployment/directory-importer --timeout=120s
info "The first import of 500 accounts takes about 13 minutes. Then: ./04-identity/verify-directory-importer.sh"
check_summary
