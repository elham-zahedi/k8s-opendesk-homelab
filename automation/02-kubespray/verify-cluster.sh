#!/usr/bin/env bash
# 02 – Acceptance tests for the Kubernetes cluster.
#
# Doc:     docs/02-kubernetes-cluster-kubespray.md (sections 7 and 8)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-cluster.sh
#
# Checks nodes, system pods, API server, etcd and metrics-server, then runs the
# functional tests in a temporary namespace "acceptance-test": nginx deployment,
# DNS, service by name, pod-to-pod across nodes with an MTU test, and NodePort on
# every node. The namespace is deleted at the end – safe on a running cluster.
# For a test cluster: KUBECONFIG_PATH=~/.kube/test ./verify-cluster.sh

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars NODES KUBECONFIG_PATH CALICO_MTU ANSIBLE_USER
require_cmd kubectl ssh curl
parse_nodes
export KUBECONFIG="$KUBECONFIG_PATH"
NS="acceptance-test"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:stable}"
BUSYBOX_IMAGE="${BUSYBOX_IMAGE:-busybox:1.36}"
k() { kubectl "$@"; }

cleanup() { k delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# run_pod NAME NODE COMMAND – runs a busybox pod (optionally on NODE), prints its log
run_pod() {
  local name="$1" node="$2" cmd="$3" phase="" waited=0
  local overrides=()
  [[ -n "$node" ]] && overrides=(--overrides "{\"spec\":{\"nodeName\":\"$node\"}}")
  k -n "$NS" run "$name" --image="$BUSYBOX_IMAGE" --restart=Never "${overrides[@]}" -- sh -c "$cmd" >/dev/null
  while [[ "$waited" -lt 120 ]]; do
    phase="$(k -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 2; waited=$((waited + 2))
  done
  k -n "$NS" logs "$name" 2>/dev/null || true
  k -n "$NS" delete pod "$name" --wait=false >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
step "1/4 Nodes and system pods"
nodes_out="$(k get nodes --no-headers)"
for name in "${NODE_NAMES[@]}"; do
  check "node $name is Ready" grep -qE "^$name +Ready " <<<"$nodes_out"
done
check "no node is NotReady"                 bash -c "! grep -q NotReady <<<\"\$1\"" _ "$nodes_out"
check "all kube-system pods Running"        test -z "$(k -n kube-system get pods --no-headers | grep -vE ' Running | Completed ')"

step "2/4 API server, etcd, metrics-server"
check "API server: readyz"                  test "$(k get --raw=/readyz)" = ok
cp_name=""; cp_ip=""
for i in "${!NODE_NAMES[@]}"; do
  if [[ "${NODE_ROLES[$i]}" != worker ]]; then cp_name="${NODE_NAMES[$i]}"; cp_ip="${NODE_IPS[$i]}"; break; fi
done
etcd_out="$(ssh -o BatchMode=yes "$ANSIBLE_USER@$cp_ip" "sudo etcdctl --endpoints=https://$cp_ip:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-$cp_name.pem \
  --key=/etc/ssl/etcd/ssl/admin-$cp_name-key.pem endpoint health" 2>&1 || true)"
check "etcd on $cp_name is healthy"         grep -q 'is healthy' <<<"$etcd_out"
check "metrics-server: kubectl top nodes"   k top nodes

# ------------------------------------------------------------------------------
step "3/4 Test deployment in namespace $NS"
k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
k create namespace "$NS" >/dev/null
workers="$(k get nodes --no-headers | grep -vc 'control-plane' || true)"
[[ "$workers" -gt 0 ]] || workers=1
k -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: $workers
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      topologySpreadConstraints:          # one pod per node where possible
        - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway, labelSelector: {matchLabels: {app: web}}}
      containers:
        - {name: nginx, image: "$NGINX_IMAGE", ports: [{containerPort: 80}]}
EOF
k -n "$NS" expose deployment web --port=80 --type=NodePort >/dev/null
check "deployment web: $workers replicas ready" k -n "$NS" rollout status deployment/web --timeout=180s
k -n "$NS" get pods -l app=web -o wide --no-headers | awk '{printf "  %-24s %-10s %-16s %s\n", $1, $3, $6, $7}'
POD_IPS="$(k -n "$NS" get pods -l app=web -o jsonpath='{.items[*].status.podIP}')"
NODE_PORT="$(k -n "$NS" get svc web -o jsonpath='{.spec.ports[0].nodePort}')"
spread="$(k -n "$NS" get pods -l app=web -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)"
info "pods are spread across $spread node(s), NodePort $NODE_PORT"

step "4/4 Network tests"
dns_out="$(run_pod dnstest "" "nslookup web.$NS.svc.cluster.local")"
check "DNS: web.$NS.svc.cluster.local resolves" grep -q "Name:.*web\.$NS\.svc\.cluster\.local" <<<"$dns_out"
grep -E '^(Server|Address)' <<<"$dns_out" | head -3 | sed 's/^/    /' || true

svc_out="$(run_pod curltest "" "wget -qO- -T 5 http://web.$NS.svc.cluster.local")"
check "service by name returns the nginx page" grep -q 'Welcome to nginx' <<<"$svc_out"

first_worker="$(k get nodes --no-headers | grep -v 'control-plane' | awk 'NR==1{print $1}')"
[[ -n "$first_worker" ]] || first_worker="$(k get nodes --no-headers | awk 'NR==1{print $1}')"
payload=$((CALICO_MTU - 28))   # ICMP + IP header = 28 bytes
p2p_out="$(run_pod podtest "$first_worker" "for ip in $POD_IPS; do
  echo \"\$ip http=\$(wget -qO- -T 5 http://\$ip | grep -c 'Welcome to nginx') mtu=\$(ping -c 1 -W 2 -s $payload \$ip >/dev/null && echo ok || echo failed)\"; done")"
for ip in $POD_IPS; do
  check "pod-to-pod from $first_worker to $ip (HTTP)" grep -qE "^$ip http=[1-9]" <<<"$p2p_out"
  check "MTU $CALICO_MTU from $first_worker to $ip"   grep -q "^$ip .*mtu=ok" <<<"$p2p_out"
done

for ip in $(k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  check "NodePort $NODE_PORT on $ip" bash -c "curl -s -m 5 http://$ip:$NODE_PORT | grep -q 'Welcome to nginx'"
done

check_summary
