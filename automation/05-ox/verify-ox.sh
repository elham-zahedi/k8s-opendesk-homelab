#!/usr/bin/env bash
# 05 – Check OX App Suite: configuration, releases, pods, certificate, web and DAV
#      access, OX Connector and the groupware group in Nubus.
#
# Doc:     docs/05-ox-app-suite.md (sections 5, 6, 8 and 14.2)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-ox.sh
#
# Read-only. The mail and calendar test with two accounts in two different browsers
# stays manual (doc 05, section 9).

# shellcheck disable=SC2016  # $variables inside single quotes are jq variables
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE OPENDESK_DIR OPENDESK_ENV DOMAIN MAIL_DOMAIN GROUPWARE_GROUP NUBUS_OU NUBUS_BASE_DN OPENDESK_CA_FILE
identity_vars
require_cmd helm jq curl openssl yq
use_kubectl
NS="$OPENDESK_NAMESPACE"
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"

step "1/5 Configuration and releases"
check "apps.oxAppSuite.enabled: true"    test "$(yq '.apps.oxAppSuite.enabled' "$VALUES")" = true
check "global.mailDomain: $MAIL_DOMAIN"  test "$(yq '.global.mailDomain' "$VALUES")" = "$MAIL_DOMAIN"
rel="$(helm -n "$NS" list -a -o json)"
for r in open-xchange ox-connector opendesk-open-xchange-bootstrap; do
  check "release $r deployed" jq -e --arg r "$r" 'any(.[]; .name == $r and .status == "deployed")' <<<"$rel"
done
notdeployed="$(jq -r '[.[] | select(.status != "deployed") | .name] | join(" ")' <<<"$rel")"
check "all $(jq length <<<"$rel") releases deployed ${notdeployed:+(not: $notdeployed)}" test -z "$notdeployed"

step "2/5 Pods"
pods="$(kubectl -n "$NS" get pods --no-headers | grep -E '^(open-xchange|ox-connector|dovecot|postfix)' || true)"
bad="$(awk '$3 != "Running" && $3 != "Completed" {print $1 " " $3}' <<<"$pods")"
info "$(grep -c '^open-xchange' <<<"$pods" || true) open-xchange pods, plus ox-connector, dovecot, postfix, postfix-ox"
check "all of them Running ${bad:+– not: $(tr '\n' ' ' <<<"$bad")}" test -z "$bad" -a -n "$pods"
for w in statefulset/ox-connector deployment/dovecot deployment/postfix deployment/postfix-ox; do
  r="$(kubectl -n "$NS" get "$w" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)"
  check "$w ready (${r:-not found})" test -n "${r#*/}" -a "${r%/*}" = "${r#*/}"
done
errors="$(kubectl -n "$NS" logs ox-connector-0 -c main --since=24h 2>/dev/null | grep -ciE 'error|traceback' || true)"
check "ox-connector: no error lines in 24 hours ($errors)" test "$errors" -eq 0

step "3/5 Certificate and access"
san="$(kubectl -n "$NS" get secret opendesk-certificates-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName)"
for h in webmail dav; do check "certificate contains $h.$DOMAIN" grep -q "DNS:$h.$DOMAIN" <<<"$san"; done
for pair in webmail:302 dav:401 portal:301 files:302; do
  h="${pair%:*}"; want="${pair#*:}"
  got="$(curl -s -o /dev/null -m 10 -w '%{http_code}' --cacert "$OPENDESK_CA_FILE" "https://$h.$DOMAIN" || true)"
  check "https://$h.$DOMAIN -> $want (got $got)" test "$got" = "$want"
done

step "4/5 Groupware group in Nubus"
udm_connect
groupware_state
info "users with isOxUser = true in ou=$NUBUS_OU: $OX_USERS, members of $GROUPWARE_GROUP: $GW_MEMBERS"
check "group $GROUPWARE_GROUP exists" test -n "$GW_DN"
check "every user with isOxUser = true is a member ($GW_MISSING missing)" test "$GW_MISSING" -eq 0
[[ "$GW_MISSING" -eq 0 ]] || info "fix: ./ops/post-rollout.sh (doc 05, section 8 – error F2)"

step "5/5 Mail in the last 24 hours (information only)"
for d in postfix-ox postfix; do
  log="$(kubectl -n "$NS" logs "deploy/$d" --since=24h 2>/dev/null || true)"
  info "$d: $(grep -c 'status=sent' <<<"$log" || true) sent, $(grep -c 'status=deferred' <<<"$log" || true) deferred, $(grep -c 'status=bounced' <<<"$log" || true) bounced"
done
info "Manual test: two accounts in two different browsers, mail and invitation (doc 05, section 9)"

check_summary
