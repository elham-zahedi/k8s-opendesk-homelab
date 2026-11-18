#!/usr/bin/env bash
# ops – Daily copy of the openDesk ConfigMap migrations-status on the kubespray VM.
#
# Doc:     docs/19-opendesk-upgrade-1-20.md (section 1.1)
# Run on:  kubespray VM as k8s, from cron
# Usage:   ./migrations-status-backup.sh [--dry-run]
#
# Since openDesk 1.17 the ConfigMap migrations-status records which migrations have run.
# A restore of volumes or databases only fits if migrations-status comes from the same
# day. The nightly Longhorn backup does not contain it, so this script saves it shortly
# before (cron: 55 0 * * *) to STATE_BACKUP_DIR/migrations-status-<date>.yaml, without the
# fields that only the cluster sets (uid, resourceVersion, …), and deletes copies older
# than STATE_BACKUP_KEEP_DAYS.
#
# Restore (only together with the data of the same day, doc 19 section 5):
#   kubectl apply -f STATE_BACKUP_DIR/migrations-status-<date>.yaml

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_NAMESPACE
require_cmd yq
use_kubectl
DIR="${STATE_BACKUP_DIR:-$HOME/backups/opendesk-state}"
KEEP="${STATE_BACKUP_KEEP_DAYS:-30}"
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || die "STATE_BACKUP_KEEP_DAYS must be a number of days, at least 1"
file="$DIR/migrations-status-$(date +%F).yaml"

step "1/2 Save migrations-status to $file"
cmyaml="$(kubectl -n "$OPENDESK_NAMESPACE" get cm migrations-status -o yaml 2>/dev/null)" \
  || die "ConfigMap migrations-status not found in namespace $OPENDESK_NAMESPACE"
cmyaml="$(yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields,
  .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")' <<<"$cmyaml")"
entries="$(yq '(.data // {}) | length' <<<"$cmyaml")"
[[ "$entries" -gt 0 ]] || die "migrations-status has no entries – not saved"
run mkdir -p -m 700 "$DIR"
if [[ "$DRY_RUN" != 1 ]]; then
  ( umask 077; printf '%s\n' "$cmyaml" > "$file.tmp" ) && mv "$file.tmp" "$file"
  ok "$file ($entries entries)"
fi

step "2/2 Delete copies older than $KEEP days"
old="$(find "$DIR" -maxdepth 1 -name 'migrations-status-*.yaml' -mtime +"$KEEP" 2>/dev/null || true)"
if [[ -z "$old" ]]; then
  ok "nothing to delete ($(find "$DIR" -maxdepth 1 -name 'migrations-status-*.yaml' 2>/dev/null | wc -l) copies kept)"
else
  while read -r f; do run rm -f "$f"; done <<<"$old"
fi
