#!/usr/bin/env bash
# 04 – Check the file server integration of Nextcloud against the mount list.
#
# Doc:     docs/04-active-directory-sso.md (sections 11, 12, 15 and 24.2)
# Run on:  kubespray VM as k8s
# Usage:   ./verify-nextcloud-files.sh [CSV]      (default NC_MOUNTS_CSV in lab.env)
#
# - nls_utf8 loaded on all nodes (otherwise the SMB mounts fail after a kernel update)
# - every data directory of the mount list is writable from the Nextcloud pod
#   (a test file is created and deleted again)
# - every mount exists with the right directory, group, read-only flag and sharing
# - no mount without an assigned group or user
# Read-only apart from the test files.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CSV=""; args=()
for a in "$@"; do if [[ "$a" == -* ]]; then args+=("$a"); else CSV="$a"; fi; done
parse_common_args "${args[@]}"
load_env
CSV="${CSV:-${NC_MOUNTS_CSV:-$AUTOMATION_DIR/04-identity/manifests/nc-mounts.csv}}"   # argument > lab.env > example list
require_vars OPENDESK_NAMESPACE INVENTORY_NAME SMB_SHARES
require_cmd jq
use_kubectl
[[ -f "$CSV" ]] || die "$CSV not found"

step "1/4 nls_utf8 on all nodes"
out="$(use_kubespray; ansible -i "$INV" all -m shell -a "echo \$(uname -r) \$(lsmod | grep -c '^nls_utf8')" -o 2>/dev/null || true)"
nodes="$(grep -c 'rc=0' <<<"$out" || true)"
loaded="$(grep -cE 'rc=0 .*\(stdout\) \S+ 1$' <<<"$out" || true)"
check "nls_utf8 loaded on $loaded of $nodes nodes" test "$loaded" -eq "$nodes" -a "$nodes" -gt 0
[[ "$loaded" -eq "$nodes" ]] || info "fix: ./04-identity/setup-smb-storage.sh (installs linux-modules-extra for the running kernel)"

step "2/4 Shares in the Nextcloud pod"
nextcloud_pod
for s in $SMB_SHARES; do
  n="$(tr '[:upper:]' '[:lower:]' <<<"$s")"
  check "PVC pvc-fs-$n Bound" bash -c "kubectl -n $OPENDESK_NAMESPACE get pvc pvc-fs-$n -o jsonpath='{.status.phase}' | grep -qx Bound"
done
mapfile -t DIRS < <(csv_rows "$CSV" | cut -d';' -f2 | sort -u)
# shellcheck disable=SC2016  # the loop runs in the pod, the directories are passed as arguments
result="$(kubectl -n "$OPENDESK_NAMESPACE" exec "$NCPOD" -- sh -c '
  for d in "$@"; do
    if touch "$d/.nc-check" 2>/dev/null && rm "$d/.nc-check"; then echo "OK $d"; else echo "FAILED $d"; fi
  done' sh "${DIRS[@]}" </dev/null)"
good="$(grep -c '^OK ' <<<"$result" || true)"
check "$good of ${#DIRS[@]} data directories writable" test "$good" -eq "${#DIRS[@]}"
grep '^FAILED' <<<"$result" | indent '    ' || true

step "3/4 Mounts compared with $(basename "$CSV")"
check "app files_external enabled" bash -c "kubectl -n $OPENDESK_NAMESPACE exec $NCPOD -- php /var/www/html/occ app:list --output=json </dev/null | jq -e '.enabled | has(\"files_external\")'"
ML="$(occ files_external:list --output=json)"
rows=0; wrong=0
while IFS=';' read -r mp dir type target mode sharing; do
  rows=$((rows + 1))
  m="$(jq -c --arg mp "$mp" '.[] | select(.mount_point == $mp)' <<<"$ML")"
  if [[ -z "$m" ]]; then echo "  MISSING  $mp"; wrong=$((wrong + 1)); continue; fi
  got_dir="$(jq -r '.configuration.datadir' <<<"$m")"
  got_ro="$(jq -r '(.options.readonly // false) | tostring' <<<"$m")"
  got_sh="$(jq -r '(.options.enable_sharing // false) | tostring' <<<"$m")"
  if [[ "$type" == group ]]; then has_target="$(jq -r --arg t "$target" '.applicable_groups | index($t) != null' <<<"$m")"
  else has_target="$(jq -r --arg t "$target" '[.applicable_users[] | select(contains($t))] | length > 0' <<<"$m")"; fi
  want_ro=false; [[ "$mode" == ro ]] && want_ro=true
  problems=""
  [[ "$got_dir" == "$dir" ]]     || problems+=" datadir=$got_dir"
  [[ "$has_target" == true ]]    || problems+=" $type $target not assigned"
  [[ "$got_ro" == "$want_ro" ]]  || problems+=" readonly=$got_ro"
  [[ "$got_sh" == "$sharing" ]]  || problems+=" sharing=$got_sh"
  if [[ -n "$problems" ]]; then echo "  WRONG    $mp:$problems"; wrong=$((wrong + 1)); fi
done < <(csv_rows "$CSV")
check "$rows mounts as in the list" test "$wrong" -eq 0
extra="$(jq -r --argjson want "$(csv_rows "$CSV" | cut -d';' -f1 | jq -R . | jq -s .)" \
  '.[] | select(.mount_point as $m | $want | index($m) | not) | .mount_point' <<<"$ML")"
[[ -z "$extra" ]] || warn "mounts that are not in the list: $(tr '\n' ' ' <<<"$extra")"

step "4/4 Mounts without an assigned group or user"
unassigned="$(jq -r '.[] | select((.applicable_users | length) == 0 and (.applicable_groups | length) == 0) | .mount_point' <<<"$ML")"
check "none (they would be visible to everyone)" test -z "$unassigned"

check_summary
