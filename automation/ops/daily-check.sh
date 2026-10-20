#!/usr/bin/env bash
# ops – Daily check of the whole lab: everything that the runbooks 07 – 12 and the
#       documents 03 – 06 found to break silently.
#
# Doc:     docs/07 – 12 (prevention), docs/04 (section 24), docs/05 (section 14)
# Run on:  kubespray VM as k8s
# Usage:   ./daily-check.sh
#
# Read-only. Takes about one minute. Every problem names the runbook that explains
# it. Exit code 0 = all checks passed (warnings do not count), so it can run from cron:
#   0 7 * * * $HOME/automation/ops/daily-check.sh > $HOME/daily-check.log 2>&1
#
#  1 Nodes            NotReady, cordoned after an aborted drain (10), memory usage
#  2 On the nodes     nls_utf8 and linux-modules-extra for the newest kernel (04 F7),
#                     disk, time, pending reboots
#  3 Pods, rollouts   ImagePullBackOff (08), Pending (09), OOMKilled/CrashLoop (11),
#                     stuck Terminating (12), unfinished rollouts, deployments at 0
#                     replicas and services without endpoints (07)
#  4 Access           portal, files, idp; webmail, its API and dav (07)
#  5 Storage          PVCs, Longhorn volumes and nodes (10, 12)
#  6 Certificates     Ready, renewal not overdue, CA expiry (04 section 24.1)
#  7 Integrations     files_external and groupware group (05 F2/F3), importer,
#                     split DNS and strictARP (03)
#  8 etcd             health, size, age of the newest backup
#
# Known exceptions (deployments at 0 replicas, services without endpoints):
#   DAILY_IGNORE="opendesk/some-service|other-ns/.*" in lab.env (regex on namespace/name)

# shellcheck disable=SC2016  # $variables inside single quotes are jq variables
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars NODES ANSIBLE_USER OPENDESK_NAMESPACE OPENDESK_DIR OPENDESK_ENV DOMAIN ETCD_BACKUP_DIR INVENTORY_NAME
require_cmd jq curl yq
identity_vars
control_plane_node
use_kubectl
IGNORE="${DAILY_IGNORE:-^$}"
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
OX_ENABLED="$(yq '.apps.oxAppSuite.enabled // false' "$VALUES" 2>/dev/null || echo false)"
WARNINGS=0
note() { warn "$*"; WARNINGS=$((WARNINGS + 1)); }
list() { [[ -z "$1" ]] || indent '      ' <<<"$1"; }        # list LINES – indented details
CURL=(curl -s -o /dev/null -m 10 -w '%{http_code}')
if [[ -s "$OPENDESK_CA_FILE" ]]; then CURL+=(--cacert "$OPENDESK_CA_FILE"); else CURL+=(-k); fi
info "$(date '+%d.%m.%Y %H:%M') – cluster $(kubectl config current-context 2>/dev/null || echo '?')"

# ------------------------------------------------------------------------------
step "1/8 Nodes (runbooks 10 and 12)"
nodes="$(kubectl get nodes -o json)"
total="$(jq '.items | length' <<<"$nodes")"
expected="$(wc -w <<<"$NODES")"
check "$total nodes in the cluster, $expected in NODES" test "$total" -eq "$expected"
notready="$(jq -r '.items[] | select(any(.status.conditions[]; .type == "Ready" and .status != "True")) | .metadata.name' <<<"$nodes")"
check "all nodes Ready${notready:+ – NotReady: $(xargs <<<"$notready") (runbook 12)}" test -z "$notready"
cordoned="$(kubectl get nodes --show-managed-fields -o json | jq -r '.items[] | select(.spec.unschedulable == true)
  | .metadata.name + "  cordoned since " + ([.metadata.managedFields[] | select(.fieldsV1["f:spec"]["f:unschedulable"]?) | .time] | last // "?")')"
check "no node SchedulingDisabled" test -z "$cordoned"
[[ -z "$cordoned" ]] || { list "$cordoned"; info "      after the maintenance: kubectl uncordon NODE (runbook 10)"; }
while read -r n _ _ _ mem; do
  [[ "${mem%\%}" =~ ^[0-9]+$ ]] || continue
  if [[ "${mem%\%}" -ge 85 ]]; then note "$n uses $mem of its memory"; fi
done < <(kubectl top nodes --no-headers 2>/dev/null || true)

# ------------------------------------------------------------------------------
step "2/8 On the nodes (doc 04 error F7, doc 06)"
REMOTE='exec 2>/dev/null
newest=$(dpkg-query -W -f="\${db:Status-Abbrev}\${Package}\n" "linux-image-[0-9]*" 2>/dev/null | awk "/^ii/ {sub(/^ii */, \"\"); sub(/^linux-image-/, \"\"); print}" | sort -V | tail -1)
extra=$(dpkg-query -W -f="\${db:Status-Abbrev}" "linux-modules-extra-$newest" 2>/dev/null | grep -c "^ii")
echo "kernel=$(uname -r) newest=$newest extra=$extra nls=$(lsmod | grep -c "^nls_utf8") disk=$(df --output=pcent /var/lib | tail -1 | tr -dc 0-9) ntp=$(timedatectl show -p NTPSynchronized --value) reboot=$([ -f /var/run/reboot-required ] && echo yes || echo no)"'
facts="$(use_kubespray; ansible -i "$INV" all -m shell -a "$REMOTE" -o 2>/dev/null || true)"
v() { grep -oE "(^| )$1=[^ ]*" <<<"$2" | cut -d= -f2; }
bad_nls=""; bad_extra=""; bad_disk=""; bad_ntp=""; reboot=""; seen=0
while read -r line; do
  host="${line%% *}"
  if [[ "$line" != *"rc=0"* ]]; then bad_nls+=" $host(unreachable)"; continue; fi
  seen=$((seen + 1))
  [[ "$(v nls "$line")" -ge 1 ]]    || bad_nls+=" $host"
  [[ "$(v extra "$line")" -ge 1 ]]  || bad_extra+=" $host($(v newest "$line"))"
  d="$(v disk "$line")"
  if [[ "${d:-0}" -ge 85 ]]; then bad_disk+=" $host(${d}%)"; elif [[ "${d:-0}" -ge 75 ]]; then note "$host: /var/lib ${d}% full"; fi
  [[ "$(v ntp "$line")" == yes ]]   || bad_ntp+=" $host"
  [[ "$(v reboot "$line")" == no ]] || reboot+=" $host"
done < <(grep -E '^[^ ]+ \| ' <<<"$facts")
check "$seen of $expected nodes answer to Ansible" test "$seen" -eq "$expected"
check "nls_utf8 loaded (SMB mounts of Nextcloud)${bad_nls:+ – not:$bad_nls}" test -z "$bad_nls"
check "linux-modules-extra for the newest kernel${bad_extra:+ – missing:$bad_extra}" test -z "$bad_extra"
[[ -z "$bad_extra" ]] || info "      before the next reboot: ./04-identity/setup-smb-storage.sh (otherwise Nextcloud loses the mounts)"
check "disk /var/lib below 85 %${bad_disk:+ –$bad_disk}" test -z "$bad_disk"
check "clock synchronised${bad_ntp:+ – not:$bad_ntp}" test -z "$bad_ntp"
[[ -z "$reboot" ]] || note "reboot pending on:$reboot – one node at a time with drain/uncordon (runbook 10, section 4)"

# ------------------------------------------------------------------------------
step "3/8 Pods and rollouts (runbooks 07, 08, 09, 11, 12)"
pods="$(kubectl get pods -A -o json)"
okjobs="$(kubectl get jobs -A -o json | jq -c '[.items[] | select((.status.succeeded // 0) >= 1) | .metadata.namespace + "/" + .metadata.name]')"
eval_pods='
  def age: now - (. | fromdateiso8601);
  def job: [.metadata.ownerReferences[]? | select(.kind == "Job") | .name][0];
  def reason: ([(.status.initContainerStatuses // [])[], (.status.containerStatuses // [])[]
                | .state.waiting.reason // empty][0])
              // (if any(.status.conditions[]?; .type == "PodScheduled" and .status == "False") then "Unschedulable" else null end)
              // (if .status.phase == "Running" then "NotReady" else null end)
              // .status.phase // "Unknown";
  def hint: if test("ImagePull|ErrImage") then "runbook 08" elif test("Unschedulable|Pending") then "runbook 09"
            elif test("CrashLoop|OOM|Error") then "runbook 11" else "" end;
  .items[] | (.metadata.namespace + "/" + .metadata.name) as $id
  | (.metadata.namespace + "/" + (job // "")) as $job
  | if .metadata.deletionTimestamp then
      (if (.metadata.deletionTimestamp | age) > 600 then "stuck\t\($id)\tTerminating since \(.metadata.deletionTimestamp)\t\(.spec.nodeName // "-")\trunbook 12" else empty end)
    elif .status.phase == "Succeeded" then empty
    elif .status.phase == "Running" and all((.status.containerStatuses // [])[]; .ready) then empty
    elif .status.phase == "Failed" and ($okjobs | index($job)) then "old\t\($id)"
    elif (.status.phase == "Running" or .status.phase == "Pending") and (.metadata.creationTimestamp | age) < 600 then empty
    else reason as $r | "bad\t\($id)\t\($r)\t\(.spec.nodeName // "-")\t\($r | hint)" end'
pod_eval="$(jq -r --argjson okjobs "$okjobs" "$eval_pods" <<<"$pods")"
bad="$(awk -F'\t' '$1 == "bad" {printf "%-60s %-26s %-8s %s\n", $2, $3, $4, $5}' <<<"$pod_eval")"
stuck="$(awk -F'\t' '$1 == "stuck" {printf "%-60s %s on %s  %s\n", $2, $3, $4, $5}' <<<"$pod_eval")"
old="$(grep -c '^old' <<<"$pod_eval" || true)"
npods="$(jq '.items | length' <<<"$pods")"; nbad=0; [[ -z "$bad" ]] || nbad="$(grep -c . <<<"$bad")"
check "pods without a problem: $((npods - nbad)) of $npods" test -z "$bad"
list "$bad"
check "no pod stuck in Terminating (node failure?)" test -z "$stuck"
list "$stuck"
[[ "$old" -eq 0 ]] || note "$old failed pod(s) of jobs that succeeded later (old attempts) – kubectl delete pod -A --field-selector status.phase=Failed"
oom="$(jq -r '.items[] | (.metadata.namespace + "/" + .metadata.name) as $p | .status.containerStatuses[]?
  | select(.lastState.terminated.reason == "OOMKilled") | "\($p) \(.name) restarts=\(.restartCount) \(.lastState.terminated.finishedAt)"' <<<"$pods")"
oom_new="$(while read -r p c r t; do [[ -n "$t" ]] || continue
  [[ $(( $(date +%s) - $(date -d "$t" +%s) )) -lt 86400 ]] && echo "$p $c $r $t"; done <<<"$oom" || true)"
check "no container OOMKilled in the last 24 hours (runbook 11)" test -z "$oom_new"
list "$oom_new"
[[ -z "$oom" || -n "$oom_new" ]] || info "older OOMKilled (last termination): $(grep -c . <<<"$oom")"

# large lists go through files: a single command-line argument is limited to 128 KB
TMPD="$(mktemp -d)"; add_exit_hook "rm -rf $TMPD"
printf '%s' "$pods" >"$TMPD/pods.json"
kubectl get deploy -A --show-managed-fields -o json >"$TMPD/deploy.json"
kubectl get sts -A --show-managed-fields -o json >"$TMPD/sts.json"
stuckdep="$(jq -r '.items[] | select(.spec.replicas > 0) | (.metadata.namespace + "/" + .metadata.name) as $id
  | select((.status.observedGeneration // 0) < .metadata.generation or (.status.unavailableReplicas // 0) > 0
      or (.status.replicas // 0) > .spec.replicas or (.status.updatedReplicas // 0) < .spec.replicas
      or any(.status.conditions[]?; .reason == "ProgressDeadlineExceeded"))
  | "\($id)  ready \(.status.readyReplicas // 0)/\(.spec.replicas), updated \(.status.updatedReplicas // 0), pods \(.status.replicas // 0)"' "$TMPD/deploy.json")"
check "all rollouts finished (no second pod of a deployment waiting – runbooks 08, 09)" test -z "$stuckdep"
list "$stuckdep"

# Workloads at 0 replicas: set by Helm = configuration (e.g. optional LDAP replicas
# of Nubus); set by hand with kubectl scale = runbook 07. The managedFields record
# who set spec.replicas last.
zero_jq='def rman: [.metadata.managedFields[]? | select(.fieldsV1["f:spec"]["f:replicas"]?)] | sort_by(.time) | last | .manager // "?";
  .items[] | select(.spec.replicas == 0)
  | [(.metadata.namespace + "/" + .metadata.name), rman, (.metadata.labels["app.kubernetes.io/managed-by"] // "-")] | @tsv'
zero="$( { jq -r "$zero_jq" "$TMPD/deploy.json" | sed 's/^/deploy\t/'; jq -r "$zero_jq" "$TMPD/sts.json" | sed 's/^/sts\t/'; } \
  | grep -vE "$IGNORE" || true)"
by_hand="$(awk -F'\t' '$3 ~ /^kubectl/ || ($4 == "Helm" && $3 != "helm") {print $1 " " $2 "  (replicas set by " $3 ")"}' <<<"$zero")"
by_conf="$(awk -F'\t' 'NF && !($3 ~ /^kubectl/ || ($4 == "Helm" && $3 != "helm")) {print $2}' <<<"$zero" | xargs)"
check "no workload scaled to 0 by hand (runbook 07)" test -z "$by_hand"
[[ -z "$by_hand" ]] || { list "$by_hand"; info "      back: kubectl -n NAMESPACE scale deploy NAME --replicas=1"; }
[[ -z "$by_conf" ]] || info "at 0 replicas by configuration (Helm): $by_conf"
sts="$(jq -r '.items[] | select((.status.readyReplicas // 0) < .spec.replicas)
  | .metadata.namespace + "/" + .metadata.name + "  ready \(.status.readyReplicas // 0)/\(.spec.replicas)"' "$TMPD/sts.json")"
check "all StatefulSets ready" test -z "$sts"
list "$sts"

# Services without a ready endpoint: a problem if pods exist but none is ready, or
# if an ingress routes users to the service and the route fails (runbook 07).
# Without pods and without a failing route it is an unused optional component.
kubectl get svc -A -o json >"$TMPD/svc.json"
kubectl get endpointslices -A -o json >"$TMPD/eps.json"
kubectl get ingress -A -o json >"$TMPD/ing.json"
noep="$(jq -rn --slurpfile s "$TMPD/svc.json" --slurpfile e "$TMPD/eps.json" --slurpfile i "$TMPD/ing.json" --slurpfile p "$TMPD/pods.json" '
  ([$e[0].items[] | {k: (.metadata.namespace + "/" + (.metadata.labels["kubernetes.io/service-name"] // "")),
                     n: ([.endpoints[]? | select(.conditions.ready == true)] | length)}]
   | group_by(.k) | map({key: .[0].k, value: (map(.n) | add)}) | from_entries) as $ready
  | ([$i[0].items[] | .metadata.namespace as $ns | .spec.rules[]? | .host as $h | .http.paths[]? | (.path // "/") as $path
      | {k: ($ns + "/" + (.backend.service.name // "")),
         url: ("https://" + $h + (if ($path | test("[\\[\\]()*?+^$|]")) then "/" else $path end))}]
     | group_by(.k) | map({key: .[0].k, value: .[0].url}) | from_entries) as $ing
  | $s[0].items[] | select((.spec.selector // {}) != {} and .spec.type != "ExternalName")
  | (.metadata.namespace + "/" + .metadata.name) as $id | select(($ready[$id] // 0) == 0)
  | .metadata.namespace as $ns | .spec.selector as $sel
  | ([$p[0].items[] | select(.metadata.namespace == $ns) | (.metadata.labels // {}) as $l
      | select(all($sel | to_entries[]; $l[.key] == .value))] | length) as $np
  | [$id, $np, ($ing[$id] // "-")] | @tsv' | grep -vE "$IGNORE" || true)"
svc_bad=""; svc_unused=""
while IFS=$'\t' read -r id np url; do
  [[ -n "$id" ]] || continue
  if [[ "$np" -gt 0 ]]; then
    svc_bad+="$id  $np pod(s), none ready"$'\n'
  elif [[ "$url" != - ]]; then
    code="$("${CURL[@]}" "$url" || true)"
    if [[ "$code" =~ ^(5|000) ]]; then svc_bad+="$id  no pods, ingress route $url answers $code"$'\n'
    else svc_unused+=" ${id#*/}"; fi
  else
    svc_unused+=" ${id#*/}"
  fi
done <<<"$noep"
svc_bad="${svc_bad%$'\n'}"
check "services: no failing endpoint (runbook 07)" test -z "$svc_bad"
list "$svc_bad"
[[ -z "$svc_unused" ]] || info "services without pods (optional components, no failing route):$svc_unused"

# ------------------------------------------------------------------------------
step "4/8 Access over HTTPS"
for t in "portal:/:301" "files:/:302" "$IDP_HOST:/auth/realms/$IDP_REALM/.well-known/openid-configuration:200"; do
  IFS=: read -r h path want <<<"$t"
  got="$("${CURL[@]}" "https://$h.$DOMAIN$path" || true)"
  check "https://$h.$DOMAIN${path%/} -> $want (got $got)" test "$got" = "$want"
done
if [[ "$OX_ENABLED" == true ]]; then
  for t in "webmail:/:302" "dav:/:401"; do
    IFS=: read -r h path want <<<"$t"
    got="$("${CURL[@]}" "https://$h.$DOMAIN$path" || true)"
    check "https://$h.$DOMAIN -> $want (got $got)" test "$got" = "$want"
  done
  # the start page answers even when the middleware is gone – only the API shows it
  got="$("${CURL[@]}" "https://webmail.$DOMAIN/appsuite/api/" || true)"
  check "webmail API /appsuite/api/ answers (got $got, 404 is normal, 503 = runbook 07)" test "${got:0:1}" = 4
fi

# ------------------------------------------------------------------------------
step "5/8 Storage (runbooks 10 and 12)"
pvc="$(kubectl get pvc -A -o json | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.namespace + "/" + .metadata.name + "  " + .status.phase')"
check "$(kubectl get pvc -A --no-headers 2>/dev/null | grep -c .) PVCs, all Bound" test -z "$pvc"
list "$pvc"
vols="$(kubectl -n longhorn-system get volumes.longhorn.io -o json)"
vbad="$(jq -r '.items[] | select((.status.state == "attached" and .status.robustness != "healthy") or .status.robustness == "faulted")
  | .metadata.name + "  " + .status.state + ", " + .status.robustness + "  (" + (.status.kubernetesStatus.namespace // "") + "/" + (.status.kubernetesStatus.pvcName // "") + ")"' <<<"$vols")"
check "$(jq '[.items[] | select(.status.state == "attached")] | length' <<<"$vols") attached Longhorn volumes, all healthy" test -z "$vbad"
list "$vbad"
lnodes="$(kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n
  | (.status.conditions // [] | (if type == "array" then . else [.[]] end)) as $c
  | select(([$c[] | select(.type == "Ready" or .type == "Schedulable") | .status] | unique) != ["True"] or .spec.allowScheduling != true)
  | $n')"
check "Longhorn: all nodes READY and SCHEDULABLE${lnodes:+ – not: $(xargs <<<"$lnodes")}" test -z "$lnodes"

# ------------------------------------------------------------------------------
step "6/8 Certificates (doc 04 section 24.1, doc 05 section 14.3)"
certs="$(kubectl get certificates.cert-manager.io -A -o json)"
cbad="$(jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not) | .metadata.namespace + "/" + .metadata.name' <<<"$certs")"
check "$(jq '.items | length' <<<"$certs") certificates, all Ready" test -z "$cbad"
list "$cbad"
overdue="$(jq -r '.items[] | select(.status.renewalTime and ((.status.renewalTime | fromdateiso8601) + 86400 < now))
  | .metadata.namespace + "/" + .metadata.name + "  renewal due since " + .status.renewalTime' <<<"$certs")"
check "no renewal overdue (cert-manager renews automatically)" test -z "$overdue"
list "$overdue"
while IFS=$'\t' read -r id days ca; do
  [[ -n "$id" ]] || continue
  if [[ "$ca" == true && "$days" -lt 45 ]]; then
    note "CA $id expires in $days days – after the renewal: 04-identity/setup-keycloak-idp.sh, 03-opendesk/export-ca.sh, windows/import-ca.ps1"
  fi
done < <(jq -r '.items[] | select(.status.notAfter) | [.metadata.namespace + "/" + .metadata.name,
  (((.status.notAfter | fromdateiso8601) - now) / 86400 | floor), (.spec.isCA // false)] | @tsv' <<<"$certs")
info "next expiries: $(jq -r '[.items[] | select(.status.notAfter) | {n: .metadata.name, d: (((.status.notAfter | fromdateiso8601) - now) / 86400 | floor)}]
  | sort_by(.d) | .[:3] | map("\(.n) \(.d) d") | join(", ")' <<<"$certs")"

# ------------------------------------------------------------------------------
step "7/8 Integrations (doc 03, 04, 05)"
NCPOD="$(kubectl -n "$OPENDESK_NAMESPACE" get pod -l app.kubernetes.io/name=aio \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$NCPOD" ]]; then
  check "Nextcloud pod running" false
elif occ app:list --output=json 2>/dev/null | jq -e '.enabled | has("files_external")' >/dev/null; then
  ok "files_external enabled"
else
  check "files_external enabled – switched off by a rollout: ./ops/post-rollout.sh (doc 05, F3)" false
fi
if [[ "$OX_ENABLED" == true ]]; then
  udm_connect
  groupware_state
  check "groupware group: $GW_MEMBERS members, $GW_MISSING of $OX_USERS users missing (doc 05, F2)" test "$GW_MISSING" -eq 0 -a -n "$GW_DN"
  [[ "$GW_MISSING" -eq 0 ]] || info "      fix: ./ops/post-rollout.sh"
fi
if kubectl get namespace directory-importer >/dev/null 2>&1; then
  logs="$(kubectl -n directory-importer logs deployment/directory-importer --since=15m 2>/dev/null || true)"
  cycles="$(grep -c 'Sleeping' <<<"$logs" || true)"; errors="$(grep -cE ' ERROR |Traceback' <<<"$logs" || true)"
  check "Directory Importer: $cycles cycle(s) in 15 minutes, $errors error lines" test "$cycles" -ge 1 -a "$errors" -eq 0
fi
corefile="$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')"
block="$(awk -v d="$DOMAIN" '!f && index($0, d) && /\{/ {f=1}
  f {print; n += gsub(/\{/, "{"); n -= gsub(/\}/, "}"); if (n <= 0) exit}' <<<"$corefile")"
check "CoreDNS: $DOMAIN and $AD_DOMAIN forwarded to $AD_DC_IP (doc 03)" grep -qE "forward \. $AD_DC_IP" <<<"$block"
strict="$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '$1 == "strictARP:" {print $2}')"
check "kube-proxy strictARP: true (MetalLB, doc 03)" test "$strict" = true

# ------------------------------------------------------------------------------
step "8/8 etcd and backups"
ETCDCTL="sudo etcdctl --endpoints=https://$CP_IP:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-$CP_NAME.pem --key=/etc/ssl/etcd/ssl/admin-$CP_NAME-key.pem"
etcd="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ANSIBLE_USER@$CP_IP" "$ETCDCTL endpoint health 2>&1; $ETCDCTL endpoint status -w json" 2>/dev/null || true)"
check "etcd on $CP_NAME healthy" grep -q 'is healthy' <<<"$etcd"
size="$(grep '^\[' <<<"$etcd" | jq -r '.[0].Status.dbSize // empty' 2>/dev/null || true)"
if [[ -n "$size" ]]; then
  info "etcd database: $((size / 1000000)) MB (limit 2 GB; space is only freed by a defragmentation)"
  [[ "$size" -lt 1000000000 ]] || note "etcd database above 1 GB – plan a defragmentation"
fi
newest="$(find "$ETCD_BACKUP_DIR" -maxdepth 1 -name '*.db' -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -1)"
if [[ -z "$newest" ]]; then
  note "no etcd backup in $ETCD_BACKUP_DIR – ./ops/etcd-backup.sh NAME"
else
  age=$(( ($(date +%s) - ${newest%%.*}) / 86400 ))
  info "newest etcd backup: ${newest#* } ($age days old)"
  [[ "$age" -le 7 ]] || note "the newest etcd backup is $age days old – ./ops/etcd-backup.sh NAME"
fi

echo
[[ "$WARNINGS" -eq 0 ]] || warn "$WARNINGS warning(s) – not counted as failures"
check_summary
