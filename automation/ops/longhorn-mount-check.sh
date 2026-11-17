#!/usr/bin/env bash
# ops – Write test on every Longhorn volume that a running pod has mounted.
#
# Doc:     docs/14-backup-freeze-io-error.md
# Run on:  kubespray VM as k8s
# Usage:   ./longhorn-mount-check.sh [--dry-run]
#
# A Longhorn volume can be "healthy" in Longhorn while the file system in the pod is
# already broken (Input/output error, or read-only after an I/O error). Only a write
# shows it. For every Longhorn mount in every running pod, the script creates and
# deletes the file .iotest and prints only the mounts that fail. Containers without
# a shell are skipped. --dry-run only lists the mounts and writes nothing.
#
# Output: "Tested: N mounts", then the failing mounts (exit code 1) or "All OK".
# Fix for a failing mount: delete the pod, it gets a fresh mount (runbook 14).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_cmd jq
use_kubectl

# shellcheck disable=SC2016  # $variables inside single quotes are expanded in the pod
if [[ "$DRY_RUN" == 1 ]]; then
  TEST='grep longhorn /proc/mounts | while read -r dev mp rest; do echo "$mp: not tested"; done'
else
  TEST='grep longhorn /proc/mounts | while read -r dev mp rest; do echo "$mp: $(touch "$mp/.iotest" 2>&1 && rm -f "$mp/.iotest" && echo OK)"; done'
fi

out="$(mktemp)"; add_exit_hook "rm -f $out"
kubectl get pods -A --field-selector=status.phase=Running -o json |
  jq -r '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim or .ephemeral))
         | "\(.metadata.namespace) \(.metadata.name) \([.spec.containers[].name] | join(","))"' |
  while read -r ns pod cs; do
    for c in ${cs//,/ }; do
      # a container without a shell or a pod that is just being deleted is skipped
      kubectl -n "$ns" exec "$pod" -c "$c" -- sh -c "$TEST" </dev/null 2>/dev/null | sed "s|^|$ns/$pod [$c] |" || true
    done
  done >"$out"

echo "Tested: $(grep -c . "$out" || true) mounts"
if [[ "$DRY_RUN" == 1 ]]; then cat "$out"; exit 0; fi
bad="$(grep -v ': OK$' "$out" || true)"
if [[ -z "$bad" ]]; then echo "All OK"; else echo "$bad"; exit 1; fi
