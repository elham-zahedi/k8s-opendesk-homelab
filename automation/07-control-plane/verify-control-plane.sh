#!/usr/bin/env bash
# 07 – Check the control plane: every node with the role control in NODES is a Ready
#      node of the cluster and a healthy etcd member, every API server knows every etcd
#      member, the control plane pods run on each of them, and the API proxy
#      (nginx-proxy) of every worker lists all of them and was restarted after its
#      configuration changed.
#
# Doc:     docs/13-three-control-plane-nodes.md (sections 6 to 9)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-control-plane.sh
#
# Read-only. Also works with one control plane node; three is the goal (doc 13).
# kubectl on this VM talks to one API server. While that node is down, use another one:
#   KUBECTL_SERVER=https://10.240.0.31:6443 ./verify-control-plane.sh

# shellcheck disable=SC2016  # $variables inside single quotes are jq or remote variables
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars NODES ANSIBLE_USER
require_cmd jq ssh
control_plane_nodes
if [[ -n "${KUBECTL_SERVER:-}" ]]; then
  kubectl() { command kubectl --server="$KUBECTL_SERVER" "$@"; }
fi
use_kubectl
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5)
n="${#CP_NAMES[@]}"
WORKER_NAMES=(); WORKER_IPS=()
for entry in $NODES; do
  IFS=: read -r name _ ip role <<<"$entry"
  if [[ "$role" == worker ]]; then WORKER_NAMES+=("$name"); WORKER_IPS+=("$ip"); fi
done

# ------------------------------------------------------------------------------
step "1/5 Control plane nodes in NODES: ${CP_NAMES[*]}"
if (( n % 2 == 0 )); then
  warn "$n control plane nodes – etcd needs an odd number: with 2, one failure already stops the cluster"
fi
[[ "$n" -ge 3 ]] || info "$n control plane node(s) – the cluster cannot lose one of them (doc 13)"
nodes="$(kubectl get nodes -o json)"
for name in "${CP_NAMES[@]}"; do
  state="$(jq -r --arg n "$name" '.items[] | select(.metadata.name == $n)
    | [(any(.status.conditions[]; .type == "Ready" and .status == "True") | if . then "Ready" else "NotReady" end),
       (if .metadata.labels | has("node-role.kubernetes.io/control-plane") then "control-plane" else "no-role" end),
       (if .spec.unschedulable == true then "cordoned" else "schedulable" end)] | join(" ")' <<<"$nodes")"
  check "$name: ${state:-not a node of the cluster}" test "$state" = "Ready control-plane schedulable"
done

# ------------------------------------------------------------------------------
step "2/5 etcd"
etcd_state
if [[ -z "$ETCD_VIA" ]]; then
  check "etcd answers on one of ${CP_NAMES[*]} (SSH as $ANSIBLE_USER, etcdctl)" false
else
  info "asked through $ETCD_VIA"
  check "$ETCD_HEALTHY of $n member(s) healthy${ETCD_UNHEALTHY:+ – not: $ETCD_UNHEALTHY}" test "$ETCD_HEALTHY" -eq "$n"
  check "etcd knows $ETCD_MEMBERS member(s), NODES has $n control plane node(s)" test "$ETCD_MEMBERS" -eq "$n"
  check "leader: ${ETCD_LEADER:-none}" test -n "$ETCD_LEADER"
  [[ "$ETCD_MEMBERS" -eq "$n" ]] \
    || info "fix: cluster.yml --limit=etcd,kube_control_plane (doc 13, section 6)"
fi

# ------------------------------------------------------------------------------
step "3/5 Every API server knows every etcd member"
want="$(for ip in "${CP_IPS[@]}"; do echo "https://$ip:2379"; done | sort | paste -sd,)"
missing=""
for i in "${!CP_NAMES[@]}"; do
  got="$("${SSH[@]}" "$ANSIBLE_USER@${CP_IPS[$i]}" \
    "sudo grep -o -- '--etcd-servers=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml" 2>/dev/null \
    | cut -d= -f2- | tr , '\n' | sort | paste -sd, || true)"
  check "${CP_NAMES[$i]}: --etcd-servers=${got:-?}" test "$got" = "$want"
  [[ "$got" == "$want" ]] || missing+=" ${CP_NAMES[$i]}"
done
[[ -z "$missing" ]] || info "fix: upgrade-cluster.yml --limit=etcd,kube_control_plane (doc 13, section 6)"

# ------------------------------------------------------------------------------
step "4/5 Control plane pods"
pods="$(kubectl -n kube-system get pods -o json)"
for comp in kube-apiserver kube-controller-manager kube-scheduler; do
  not=""
  for name in "${CP_NAMES[@]}"; do
    jq -e --arg p "$comp-$name" 'any(.items[]; .metadata.name == $p and .status.phase == "Running"
      and all(.status.containerStatuses[]?; .ready == true))' <<<"$pods" >/dev/null || not+=" $name"
  done
  check "$comp ready on all $n${not:+ – not on:$not}" test -z "$not"
done

# ------------------------------------------------------------------------------
step "5/5 API proxy (nginx-proxy) of the workers"
REMOTE='echo "api=$(sed -n "/upstream kube_apiserver/,/}/p" /etc/nginx/nginx.conf 2>/dev/null | grep -oE "[0-9.]+:6443" | sort -u | paste -sd,)"
echo "conf=$(stat -c %Y /etc/nginx/nginx.conf 2>/dev/null || echo 0)"
sudo crictl ps --name nginx-proxy -o json 2>/dev/null'
want="$(for ip in "${CP_IPS[@]}"; do echo "$ip:6443"; done | sort | paste -sd,)"
stale=""; incomplete=""
for i in "${!WORKER_NAMES[@]}"; do
  w="${WORKER_NAMES[$i]}"
  out="$("${SSH[@]}" "$ANSIBLE_USER@${WORKER_IPS[$i]}" "$REMOTE" 2>/dev/null || true)"
  api="$(sed -n 's/^api=//p' <<<"$out")"
  conf="$(sed -n 's/^conf=//p' <<<"$out")"
  started="$(sed -n '/^{/,$p' <<<"$out" | jq -r '[.containers[]? | .createdAt | tonumber] | max // 0 | . / 1000000000 | floor' 2>/dev/null || echo 0)"
  if [[ "$api" != "$want" ]]; then incomplete+=" $w(${api:-?})"
  elif [[ "${started:-0}" -lt "${conf:-0}" ]]; then stale+=" $w"; fi
done
check "every worker lists $want${incomplete:+ – not:$incomplete}" test -z "$incomplete"
[[ -z "$incomplete" ]] || info "fix: cluster.yml --limit=kube_node (doc 13, section 7)"
check "nginx-proxy restarted after its configuration changed${stale:+ – not on:$stale}" test -z "$stale"
[[ -z "$stale" ]] || info "fix on each of them: ssh $ANSIBLE_USER@IP \"sudo crictl ps --name nginx-proxy -q | xargs -r sudo crictl stop\" (doc 13, section 7)"

echo
info "kubectl on this VM talks to $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '?');"
info "while that node is down: kubectl --server=https://<other control plane node>:6443 … (doc 13, section 9)"
check_summary
