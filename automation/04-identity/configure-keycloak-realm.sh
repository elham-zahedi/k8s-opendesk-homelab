#!/usr/bin/env bash
# 04 – Realm, LDAP federation to Active Directory and OIDC client for openDesk in the
#      dedicated Keycloak – via the admin REST API instead of clicking in the console.
#
# Doc:     docs/04-active-directory-sso.md (sections 18, 19.2 and 19.4)
# Run on:  kubespray VM as k8s
# Usage:   ./configure-keycloak-realm.sh [--dry-run] [--force] [--sync]
#
#   --force   correct an existing LDAP provider or client that differs
#   --sync    start a full user synchronisation from AD
#
# Creates what is missing: realm IDP_REALM, LDAP provider (read-only, LDAPS, subtree),
# username mapper, client IDP_CLIENT with the redirect URI of openDesk. Existing
# objects are compared and only changed with --force. Asks for the password of the AD
# service account (or takes $AD_KEYCLOAK_PASSWORD) only when the provider is created.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force sync"
parse_common_args "$@"
load_env
require_vars DOMAIN AD_DOMAIN AD_DC_HOST AD_USER_OU SVC_KEYCLOAK IDP_HOST IDP_REALM IDP_CLIENT IDP_KEY
identity_vars
require_cmd jq curl
use_kubectl
kc_connect
R="$IDP_REALM"

# Wanted LDAP settings (doc 04, section 18). searchScope 2 = subtree: the users are in
# department OUs below the user OU – one level finds nobody (error F12).
WANTED_LDAP="$(jq -n --arg url "ldaps://$AD_DC_FQDN:636" --arg bind "$SVC_KEYCLOAK@$AD_DOMAIN" --arg dn "$AD_USER_BASE" '{
  vendor: "ad", connectionUrl: $url, useTruststoreSpi: "always", authType: "simple", bindDn: $bind,
  editMode: "READ_ONLY", usersDn: $dn, usernameLDAPAttribute: "sAMAccountName", rdnLDAPAttribute: "cn",
  uuidLDAPAttribute: "objectGUID", userObjectClasses: "person, organizationalPerson, user", searchScope: "2",
  importEnabled: "true", syncRegistrations: "false", changedSyncPeriod: "900", trustEmail: "true"}')"
# the settings that decide whether the login works; the others are reported only
KEY_SETTINGS="vendor connectionUrl bindDn editMode usersDn usernameLDAPAttribute uuidLDAPAttribute searchScope importEnabled"

# ------------------------------------------------------------------------------
step "1/4 Realm $R"
kc GET "/$R"
if [[ "$KC_STATUS" == 200 ]]; then ok "realm $R exists"
elif [[ "$KC_STATUS" == 404 ]]; then
  info "\$ create realm $R"
  if [[ "$DRY_RUN" != 1 ]]; then
    kc POST "" "{\"realm\":\"$R\",\"enabled\":true}"; [[ "$KC_STATUS" == 201 ]] || die "creating the realm failed (HTTP $KC_STATUS)"
    kc GET "/$R"
  fi
else die "reading the realm failed (HTTP $KC_STATUS)"; fi
REALM_ID="$(jq -r '.id // empty' "$KC_BODY" 2>/dev/null || true)"

# ------------------------------------------------------------------------------
step "2/4 LDAP provider (Active Directory $AD_DC_FQDN)"
LDAP_ID=""; CREATED=0
if [[ -n "$REALM_ID" ]]; then
  kc GET "/$R/components?type=org.keycloak.storage.UserStorageProvider"
  LDAP_ID="$(jq -r '[.[] | select(.providerId == "ldap")][0].id // empty' "$KC_BODY")"
fi
if [[ -n "$LDAP_ID" ]]; then
  current="$(jq -c '[.[] | select(.id == "'"$LDAP_ID"'")][0]' "$KC_BODY")"
  ok "provider '$(jq -r .name <<<"$current")' exists"
  diffs=0
  for k in $(jq -r 'keys[]' <<<"$WANTED_LDAP"); do
    want="$(jq -r --arg k "$k" '.[$k]' <<<"$WANTED_LDAP")"
    got="$(jq -r --arg k "$k" '.config[$k][0] // ""' <<<"$current")"
    if [[ "$want" != "$got" ]]; then
      if [[ " $KEY_SETTINGS " == *" $k "* ]]; then warn "$k: '$got' (expected '$want')"; diffs=$((diffs + 1))
      else info "note: $k is '$got' (template: '$want')"; fi
    fi
  done
  if [[ "$diffs" -eq 0 ]]; then ok "all important settings as expected"
  elif [[ "$FLAG_FORCE" == 1 ]]; then
    info "\$ update the provider settings"
    if [[ "$DRY_RUN" != 1 ]]; then
      jq --argjson w "$WANTED_LDAP" '.config += ($w | with_entries(.value = [.value]))' <<<"$current" >"$KC_BODY.put"
      kc PUT "/$R/components/$LDAP_ID" "@$KC_BODY.put"; rm -f "$KC_BODY.put"
      check "provider updated (HTTP $KC_STATUS)" test "$KC_STATUS" = 204
    fi
  else
    warn "$diffs important setting(s) differ – not changed; use --force to correct them"
  fi
else
  info "\$ create LDAP provider 'ldap' (bind $SVC_KEYCLOAK@$AD_DOMAIN, users $AD_USER_BASE)"
  if [[ "$DRY_RUN" != 1 ]]; then
    ask_secret AD_KEYCLOAK_PASSWORD "Password of $SVC_KEYCLOAK@$AD_DOMAIN"
    # the request body contains the bind password, so it goes to curl on stdin
    jq -n --argjson w "$WANTED_LDAP" --arg parent "$REALM_ID" --arg pw "$AD_KEYCLOAK_PASSWORD" '{
        name: "ldap", providerId: "ldap", providerType: "org.keycloak.storage.UserStorageProvider", parentId: $parent,
        config: (($w + {enabled: "true", priority: "0", connectionPooling: "true", pagination: "true",
                       fullSyncPeriod: "-1", batchSizeForSync: "1000", cachePolicy: "DEFAULT", bindCredential: $pw})
                 | with_entries(.value = [.value]))}' | kc POST "/$R/components" @-
    [[ "$KC_STATUS" == 201 ]] || die "creating the LDAP provider failed (HTTP $KC_STATUS)"
    kc GET "/$R/components?type=org.keycloak.storage.UserStorageProvider"
    LDAP_ID="$(jq -r '[.[] | select(.providerId == "ldap")][0].id' "$KC_BODY")"
    ok "provider created"
    CREATED=1; FLAG_SYNC=1
  fi
fi

if [[ -n "$LDAP_ID" ]]; then
  # username mapper: the value must always come from AD (error F11)
  kc GET "/$R/components?parent=$LDAP_ID&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper"
  mapper="$(jq -c '[.[] | select(.name == "username")][0] // empty' "$KC_BODY")"
  if [[ -z "$mapper" ]]; then
    check "mapper 'username' exists" false
  else
    bad="$(jq -r '.config as $c | [["ldap.attribute", "sAMAccountName"], ["always.read.value.from.ldap", "true"],
            ["is.mandatory.in.ldap", "true"], ["read.only", "true"]] | map(select(($c[.[0]][0] // "") != .[1]) | .[0]) | join(" ")' <<<"$mapper")"
    if [[ -z "$bad" ]]; then ok "mapper 'username' (sAMAccountName, always read from LDAP)"
    elif [[ "$FLAG_FORCE" == 1 || "$CREATED" == 1 ]]; then
      info "\$ correct mapper 'username': $bad"
      if [[ "$DRY_RUN" != 1 ]]; then
        jq '.config += {"ldap.attribute": ["sAMAccountName"], "always.read.value.from.ldap": ["true"],
                        "is.mandatory.in.ldap": ["true"], "read.only": ["true"]}' <<<"$mapper" >"$KC_BODY.put"
        kc PUT "/$R/components/$(jq -r .id <<<"$mapper")" "@$KC_BODY.put"; rm -f "$KC_BODY.put"
        check "mapper corrected (HTTP $KC_STATUS)" test "$KC_STATUS" = 204
      fi
    else
      warn "mapper 'username' differs in: $bad – use --force to correct it"
    fi
  fi
  if [[ "$FLAG_SYNC" == 1 ]]; then
    info "\$ full synchronisation from AD"
    if [[ "$DRY_RUN" != 1 ]]; then
      kc POST "/$R/user-storage/$LDAP_ID/sync?action=triggerFullSync"
      info "$(jq -r '.status // "?"' "$KC_BODY" 2>/dev/null)"
    fi
  fi
  [[ "$DRY_RUN" == 1 ]] || { kc GET "/$R/users/count"; info "users in realm $R: $(cat "$KC_BODY")"; }
fi

# ------------------------------------------------------------------------------
step "3/4 Client $IDP_CLIENT (redirect URIs of openDesk)"
# post-logout URI: without it the logout ends with "Invalid redirect uri" (doc 05, error F5)
POST_LOGOUT_URI="$IDP_REDIRECT_URI/logout_response"
WANTED_CLIENT="$(jq -n --arg id "$IDP_CLIENT" --arg uri "$IDP_REDIRECT_URI" --arg origin "https://$OPENDESK_ID_FQDN" '{
  clientId: $id, protocol: "openid-connect", publicClient: false, standardFlowEnabled: true,
  directAccessGrantsEnabled: false, implicitFlowEnabled: false, serviceAccountsEnabled: false,
  redirectUris: [$uri], webOrigins: [$origin]}')"
CID=""
if [[ -n "$REALM_ID" ]]; then
  kc GET "/$R/clients?clientId=$IDP_CLIENT"
  CID="$(jq -r '.[0].id // empty' "$KC_BODY")"
fi
if [[ -n "$CID" ]]; then
  current="$(jq -c '.[0]' "$KC_BODY")"
  bad="$(jq -r --argjson w "$WANTED_CLIENT" '. as $c | $w | keys | map(select($c[.] != $w[.])) | join(" ")' <<<"$current")"
  got_pl="$(jq -r '.attributes["post.logout.redirect.uris"] // ""' <<<"$current")"
  [[ "$got_pl" == "$POST_LOGOUT_URI" ]] || bad+="${bad:+ }post.logout.redirect.uris"
  if [[ -z "$bad" ]]; then ok "client $IDP_CLIENT exists, redirect URI $IDP_REDIRECT_URI and post-logout URI"
  else
    for k in $bad; do
      if [[ "$k" == post.logout.redirect.uris ]]; then warn "$k: '${got_pl}' (expected '$POST_LOGOUT_URI')"
      else warn "$k: $(jq -c --arg k "$k" '.[$k]' <<<"$current") (expected $(jq -c --arg k "$k" '.[$k]' <<<"$WANTED_CLIENT"))"; fi
    done
    if [[ "$FLAG_FORCE" == 1 ]]; then
      info "\$ correct client $IDP_CLIENT (doc 04 error F15, doc 05 error F5)"
      if [[ "$DRY_RUN" != 1 ]]; then
        jq --argjson w "$WANTED_CLIENT" --arg pl "$POST_LOGOUT_URI" '. + $w | .attributes["post.logout.redirect.uris"] = $pl' \
          <<<"$current" >"$KC_BODY.put"
        kc PUT "/$R/clients/$CID" "@$KC_BODY.put"; rm -f "$KC_BODY.put"
        check "client corrected (HTTP $KC_STATUS)" test "$KC_STATUS" = 204
      fi
    else warn "not changed – use --force to correct the client"; fi
  fi
else
  info "\$ create client $IDP_CLIENT"
  if [[ "$DRY_RUN" != 1 ]]; then
    kc POST "/$R/clients" "$(jq --arg pl "$POST_LOGOUT_URI" '. + {attributes: {"post.logout.redirect.uris": $pl}}' <<<"$WANTED_CLIENT")"
    [[ "$KC_STATUS" == 201 ]] || die "creating the client failed (HTTP $KC_STATUS)"
    ok "client created – the secret is written into the openDesk configuration by configure-sso.sh"
  fi
fi

step "4/4 Summary"
info "Next: ./04-identity/configure-sso.sh"
if [[ "$CHECKS_FAILED" -gt 0 ]]; then check_summary; fi
