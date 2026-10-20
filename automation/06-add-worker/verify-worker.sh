#!/usr/bin/env bash
# 06 – Check a worker after the join: node, DaemonSets, Longhorn, settings on the
#      node, and a functional test with a Longhorn volume and DNS on this node.
#
# Doc:     docs/06-add-worker-node.md (sections 6 and 7)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-worker.sh NAME
#
# Works for every worker, also for the ones from the installation. Read-only apart
# from the temporary namespace "worker-test" (PVC of 1 GiB and one pod pinned to
# NAME), which is deleted at the end together with its volume.

# shellcheck disable=SC2016  # $variables inside single quotes are jq variables
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

node=""; flags=()
for a in "$@"; do if [[ "$a" == -* ]]; then flags+=("$a"); else node="$a"; fi; done
parse_common_args "${flags[@]}"
load_env
require_vars NODES ANSIBLE_USER NODE_MTU DOMAIN AD_DOMAIN AD_DC_IP LB_IP INVENTORY_NAME KUBESPRAY_DIR KUBESPRAY_VENV
require_cmd jq ssh
find_node "$node"
control_plane_node
use_kubectl
NS="worker-test"
IMAGE="${BUSYBOX_IMAGE:-busybox:1.36}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ANSIBLE_USER@$W_IP")

# ------------------------------------------------------------------------------
step "1/5 Node $W_NAME in Kubernetes"
nj="$(kubectl get node "$W_NAME" -o json 2>/dev/null)" || die "$W_NAME is not a node of the cluster"
cpj="$(kubectl get node "$CP_NAME" -o json)"
f() { jq -r "$1" <<<"$nj"; }
check "Ready" test "$(f '.status.conditions[] | select(.type == "Ready") | .status')" = True
check "schedulable (not cordoned)" test "$(f '.spec.unschedulable // false')" = false
check "InternalIP $W_IP" test "$(f '.status.addresses[] | select(.type == "InternalIP") | .address')" = "$W_IP"
kv="$(f .status.nodeInfo.kubeletVersion)"; cpkv="$(jq -r .status.nodeInfo.kubeletVersion <<<"$cpj")"
check "kubelet $kv – same as $CP_NAME ($cpkv)" test "$kv" = "$cpkv"
info "kernel $(f .status.nodeInfo.kernelVersion), $(f .status.nodeInfo.containerRuntimeVersion)"

# ------------------------------------------------------------------------------
step "2/5 Pods on $W_NAME"
pods="$(kubectl get pods -A -o json)"
ref="$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o json \
  | jq -r --arg n "$W_NAME" '[.items[] | select(.metadata.name != $n)
      | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | .metadata.name] | first // empty')"
ds() {  # DaemonSets with a running pod on node $1
  jq -r --arg n "$1" '.items[] | select(.spec.nodeName == $n and .status.phase == "Running")
    | .metadata.namespace + "/" + (.metadata.ownerReferences[]? | select(.kind == "DaemonSet") | .name)' <<<"$pods" | sort -u
}
mine="$(ds "$W_NAME")"
info "$(grep -c . <<<"$mine" || true) DaemonSet pods running: $(awk -F/ '{print $2}' <<<"$mine" | xargs)"
if [[ -n "$ref" ]]; then
  missing="$(comm -23 <(ds "$ref") <(echo "$mine") | xargs)"
  check "every DaemonSet of the worker $ref also runs here${missing:+ (missing: $missing)}" test -z "$missing"
else
  info "no other Ready worker to compare the DaemonSets with"
fi
bad="$(jq -r --arg n "$W_NAME" '.items[] | select(.spec.nodeName == $n and (.status.phase | IN("Running", "Succeeded") | not))
  | .metadata.namespace + "/" + .metadata.name + " " + .status.phase' <<<"$pods")"
check "no pod on $W_NAME outside Running/Completed${bad:+ – $(xargs <<<"$bad")}" test -z "$bad"

# ------------------------------------------------------------------------------
step "3/5 Longhorn"
ln="$(kubectl -n longhorn-system get nodes.longhorn.io "$W_NAME" -o json 2>/dev/null || echo '{}')"
cond() { jq -r --arg t "$1" '.status.conditions // [] | (if type == "array" then . else [.[]] end)
  | map(select(.type == $t)) | first | .status // "missing"' <<<"$ln"; }
check "Longhorn node READY ($(cond Ready))"            test "$(cond Ready)" = True
check "Longhorn node SCHEDULABLE ($(cond Schedulable))" test "$(cond Schedulable)" = True
check "scheduling allowed" test "$(jq -r '.spec.allowScheduling // false' <<<"$ln")" = true

# ------------------------------------------------------------------------------
step "4/5 Settings on $W_NAME (SSH)"
payload=$((NODE_MTU - 28))   # IP and ICMP header = 28 bytes
facts="$("${SSH[@]}" "CP_IP=$CP_IP PAYLOAD=$payload NODES='$(xargs <<<"$NODES")' bash -s" <<'REMOTE' 2>/dev/null || true
echo "nls=$(lsmod | grep -c '^nls_utf8')"
echo "mtu=$(cat /sys/class/net/eth0/mtu)"
echo "ping=$(ping -M do -s "$PAYLOAD" -c 2 -W 2 -q "$CP_IP" >/dev/null 2>&1 && echo ok || echo failed)"
echo "nginx=$(sudo crictl ps --name nginx-proxy -q 2>/dev/null | grep -c .)"
echo "server=$(sudo awk '/server:/ {print $2; exit}' /etc/kubernetes/kubelet.conf 2>/dev/null)"
echo "iscsid=$(systemctl is-active iscsid)"
echo "multipathd=$(systemctl is-active multipathd)"
echo "ntp=$(timedatectl show -p NTPSynchronized --value)"
n=0; for e in $NODES; do getent hosts "${e%%:*}" >/dev/null && n=$((n + 1)); done; echo "resolved=$n"
REMOTE
)"
[[ -n "$facts" ]] || die "no SSH connection to $ANSIBLE_USER@$W_IP"
get() { sed -n "s/^$1=//p" <<<"$facts"; }
total="$(wc -w <<<"$NODES")"
check "nls_utf8 loaded (SMB mounts of Nextcloud)"                test "$(get nls)" -ge 1
check "MTU of eth0 is $NODE_MTU"                                 test "$(get mtu)" = "$NODE_MTU"
check "ping with $payload bytes and DF bit to $CP_NAME"          test "$(get ping)" = ok
check "nginx-proxy running (crictl – there is no mirror pod, doc 06 section 6)" test "$(get nginx)" -ge 1
check "kubelet talks to https://localhost:6443 ($(get server))"  test "$(get server)" = "https://localhost:6443"
check "iscsid active"                                            test "$(get iscsid)" = active
check "multipathd not active ($(get multipathd))"                test "$(get multipathd)" != active
check "clock synchronised"                                       test "$(get ntp)" = yes
check "resolves all $total nodes from NODES ($(get resolved))"   test "$(get resolved)" = "$total"
others="$(cd "$KUBESPRAY_DIR" && "$KUBESPRAY_VENV/bin/ansible" -i "inventory/$INVENTORY_NAME/inventory.ini" all \
  -m command -a "getent hosts $W_NAME" -o 2>/dev/null | grep -c "rc=0.*$W_IP" || true)"
check "all $total nodes resolve $W_NAME to $W_IP ($others)" test "$others" = "$total"

# ------------------------------------------------------------------------------
step "5/5 Functional test in namespace $NS: Longhorn volume and DNS on $W_NAME"
add_exit_hook "kubectl delete namespace $NS --ignore-not-found --wait=false"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$NS" >/dev/null
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: test-pvc}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: test-$W_NAME}
spec:
  nodeSelector: {kubernetes.io/hostname: $W_NAME}
  terminationGracePeriodSeconds: 5
  containers:
    - name: test
      image: $IMAGE
      command: ["sh", "-c", "echo volume-ok > /data/test.txt; trap 'exit 0' TERM; sleep 3600 & wait"]
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 64Mi}}
      volumeMounts: [{name: data, mountPath: /data}]
  volumes:
    - {name: data, persistentVolumeClaim: {claimName: test-pvc}}
EOF
k() { kubectl -n "$NS" "$@"; }
check "pod with the Longhorn volume Running on $W_NAME" k wait --for=condition=Ready "pod/test-$W_NAME" --timeout=300s
pv="$(k get pvc test-pvc -o jsonpath='{.spec.volumeName}')"
check "PVC Bound ($pv)" test "$(k get pvc test-pvc -o jsonpath='{.status.phase}')" = Bound
check "volume writable and readable" bash -c "kubectl -n $NS exec test-$W_NAME -- cat /data/test.txt | grep -qx volume-ok"
lookup() { k exec "test-$W_NAME" -- nslookup "$1" 2>/dev/null | sed -n '/^Name:/,$p' || true; }
svc_ip="$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')"
check "DNS: kubernetes.default.svc.cluster.local -> $svc_ip" grep -qF "$svc_ip" <<<"$(lookup kubernetes.default.svc.cluster.local)"
check "DNS: portal.$DOMAIN -> $LB_IP (MetalLB)"            grep -qF "$LB_IP" <<<"$(lookup "portal.$DOMAIN")"
check "DNS: $AD_DOMAIN -> $AD_DC_IP (domain controller)"   grep -qF "$AD_DC_IP" <<<"$(lookup "$AD_DOMAIN")"

info "removing namespace $NS (PVC, PV and Longhorn volume)"
kubectl delete namespace "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
gone=1
for _ in $(seq 30); do
  if [[ -z "$pv" ]] || { ! kubectl get pv "$pv" >/dev/null 2>&1 && ! kubectl -n longhorn-system get volumes.longhorn.io "$pv" >/dev/null 2>&1; }; then
    gone=0; break
  fi
  sleep 3
done
check "test volume deleted again (PV and Longhorn volume)" test "$gone" -eq 0

check_summary
