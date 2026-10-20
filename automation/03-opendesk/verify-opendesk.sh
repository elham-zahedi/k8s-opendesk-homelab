#!/usr/bin/env bash
# 03 – Acceptance test of openDesk: releases, pods, certificates, ingresses, HTTPS.
#
# Doc:     docs/03-opendesk-deployment.md (sections 12, 13 and 18.2)
# Run on:  kubespray VM as k8s (needs split-dns.sh)
# Usage:   ./verify-opendesk.sh
#
# Read-only apart from one short-lived curl pod. Failed pods of a Job whose
# latest run succeeded are only reported (old attempts, doc 03 section 17).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE DOMAIN KUBECONFIG_PATH
require_cmd helm curl python3
use_kubectl
NS="$OPENDESK_NAMESPACE"
TESTNS="opendesk-test"
trap 'kubectl delete namespace "$TESTNS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

step "1/4 Helm releases"
releases="$(helm -n "$NS" list -a -o json)"
read -r total bad <<<"$(python3 -c 'import json,sys; r=json.load(sys.stdin); print(len(r), " ".join(x["name"]+"="+x["status"] for x in r if x["status"]!="deployed") or "-")' <<<"$releases")"
check "$total releases, all deployed" test "$bad" = "-"
[[ "$bad" == "-" ]] || info "not deployed: $bad"

step "2/4 Pods"
summary="$(kubectl -n "$NS" get pods,jobs -o json | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
jobs = {i["metadata"]["name"]: i for i in items if i["kind"] == "Job"}
ok = old = 0; bad = []
for p in (i for i in items if i["kind"] == "Pod"):
    phase = p["status"].get("phase")
    ready = all(c.get("ready") for c in p["status"].get("containerStatuses", []))
    owner = next((o["name"] for o in p["metadata"].get("ownerReferences", []) if o["kind"] == "Job"), None)
    if phase == "Succeeded" or (phase == "Running" and ready):
        ok += 1
    elif owner and jobs.get(owner, {}).get("status", {}).get("succeeded", 0) >= 1:
        old += 1
    else:
        bad.append(p["metadata"]["name"] + "(" + str(phase) + ")")
print(ok, old, " ".join(bad) or "-")
')"
read -r pods_ok pods_old pods_bad <<<"$summary"
check "$pods_ok pods Running/Completed, no pod with a problem" test "$pods_bad" = "-"
[[ "$pods_bad" == "-" ]] || info "problems: $pods_bad"
[[ "$pods_old" -eq 0 ]] || warn "$pods_old failed pod(s) of jobs that later succeeded (old attempts) – remove with: kubectl -n $NS delete pod --field-selector status.phase=Failed"

step "3/4 Certificates and ingresses"
certs="$(kubectl -n "$NS" get certificate -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')"
check "$(wc -l <<<"$certs") certificates, all Ready" bash -c "! grep -qv '=True$' <<<\"\$1\"" _ "$certs"
classes="$(kubectl -n "$NS" get ingress -o jsonpath='{range .items[*]}{.spec.ingressClassName}{"\n"}{end}')"
check "$(wc -l <<<"$classes") ingresses, all with class haproxy" bash -c "! grep -qvx haproxy <<<\"\$1\"" _ "$classes"

step "4/4 HTTPS (self-signed CA, so -k)"
code() { curl -k -s -o /dev/null -m 10 -w '%{http_code}' "$@" || true; }
c="$(code "https://portal.$DOMAIN")";        check "portal.$DOMAIN -> 301 (got $c)"  test "$c" = 301
c="$(code "https://files.$DOMAIN")";         check "files.$DOMAIN -> 302 (got $c)"   test "$c" = 302
c="$(code -I "https://objectstorage.$DOMAIN")"; check "objectstorage.$DOMAIN answers (got $c)" test "$c" != 000
kubectl delete namespace "$TESTNS" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$TESTNS" >/dev/null
kubectl -n "$TESTNS" run nettest --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "https://objectstorage.$DOMAIN" >/dev/null
kubectl -n "$TESTNS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/nettest --timeout=120s >/dev/null 2>&1 || true
c="$(kubectl -n "$TESTNS" logs nettest 2>/dev/null || true)"
check "objectstorage.$DOMAIN from a pod answers (got ${c:-none})" bash -c "[[ -n '$c' && '$c' != 000 ]]"

check_summary
