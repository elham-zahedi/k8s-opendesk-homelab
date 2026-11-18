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
# Mounts that the pod spec declares readOnly are read-only by design and are skipped.
# Example: since openDesk 1.20 the leader-elector container of ums-ldap-server-primary
# mounts /var/lib/univention-ldap read-only. The same volume is still tested in the
# container that mounts it writable (there: main).
#
# Output: "Tested: N mounts", "Skipped: N mounts ..." (only if there are any), then
# the failing mounts (exit code 1) or "All OK".
# Fix for a failing mount: delete the pod, it gets a fresh mount (runbook 14).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_cmd jq
use_kubectl

# In the pod, $1 = the container's readOnly mount paths from the pod spec, comma-separated
SKIPPED='skipped, readOnly in the pod spec'
# shellcheck disable=SC2016  # $variables inside single quotes are expanded in the pod
SKIP='case ",$1," in *",$mp,"*) echo "$mp: '"$SKIPPED"'"; continue ;; esac; '
# shellcheck disable=SC2016
if [[ "$DRY_RUN" == 1 ]]; then
  TEST='grep longhorn /proc/mounts | while read -r dev mp rest; do '"$SKIP"'echo "$mp: not tested"; done'
else
  TEST='grep longhorn /proc/mounts | while read -r dev mp rest; do '"$SKIP"'echo "$mp: $(touch "$mp/.iotest" 2>&1 && rm -f "$mp/.iotest" && echo OK)"; done'
fi

out="$(mktemp)"; add_exit_hook "rm -f $out"
kubectl get pods -A --field-selector=status.phase=Running -o json |
  jq -r '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim or .ephemeral))
         | .metadata.namespace as $ns | .metadata.name as $pod | .spec.containers[]
         | "\($ns) \($pod) \(.name) \([.volumeMounts[]? | select(.readOnly == true) | .mountPath] | join(",") | if . == "" then "-" else . end)"' |
  while read -r ns pod c ro; do
    # a container without a shell or a pod that is just being deleted is skipped
    kubectl -n "$ns" exec "$pod" -c "$c" -- sh -c "$TEST" sh "$ro" </dev/null 2>/dev/null | sed "s|^|$ns/$pod [$c] |" || true
  done >"$out"

skipped="$(grep -c ": $SKIPPED\$" "$out" || true)"
echo "Tested: $(grep -v ": $SKIPPED\$" "$out" | grep -c . || true) mounts"
[[ "$skipped" == 0 ]] || echo "Skipped: $skipped mounts (readOnly in the pod spec, read-only by design)"
if [[ "$DRY_RUN" == 1 ]]; then cat "$out"; exit 0; fi
bad="$(grep -v -e ': OK$' -e ": $SKIPPED\$" "$out" || true)"
if [[ -z "$bad" ]]; then echo "All OK"; else echo "$bad"; exit 1; fi
