#!/usr/bin/env bash
# 04 – Create the Nextcloud external storage mounts (files_external, backend "local")
#      from a CSV file.
#
# Doc:     docs/04-active-directory-sso.md (section 14)
# Run on:  kubespray VM as k8s
# Usage:   ./nc-mounts.sh [CSV]            plan only (default), changes nothing
#          ./nc-mounts.sh [CSV] --apply    create the missing mounts
#
# CSV (default NC_MOUNTS_CSV in lab.env): mountpoint;datadir;type;target;mode;sharing
# Existing mount points are skipped, so the script can be run any number of times.
# A mount without an assigned group/user would be visible to EVERYONE – it is
# deleted again if the assignment fails, and the final check lists such mounts.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="apply"
CSV=""; args=()
for a in "$@"; do if [[ "$a" == -* ]]; then args+=("$a"); else CSV="$a"; fi; done
parse_common_args "${args[@]}"
load_env
CSV="${CSV:-${NC_MOUNTS_CSV:-$AUTOMATION_DIR/04-identity/manifests/nc-mounts.csv}}"   # argument > lab.env > example list
require_vars OPENDESK_NAMESPACE
require_cmd jq
use_kubectl
[[ -f "$CSV" ]] || die "$CSV not found"
nextcloud_pod

GROUPS_JSON="$(occ group:list --output=json)"
USERS_JSON="$(occ user:list --output=json)"
MOUNTS_JSON="$(occ files_external:list --output=json)"
errors=0

step "Mounts from $(basename "$CSV")$([[ "$FLAG_APPLY" == 1 ]] || echo ' – plan only, add --apply to create them')"
while IFS=';' read -r mp dir type target mode sharing; do
  if jq -e --arg mp "$mp" '.[] | select(.mount_point == $mp)' <<<"$MOUNTS_JSON" >/dev/null; then
    echo "  SKIP    $mp (already exists)"; continue
  fi
  # resolve and check the target BEFORE the mount is created
  case "$type" in
    group)
      if ! jq -e --arg g "$target" 'has($g)' <<<"$GROUPS_JSON" >/dev/null; then
        echo "  ERROR   $mp: group '$target' not found in Nextcloud"; errors=$((errors + 1)); continue
      fi
      arg=(--add-group "$target") ;;
    user)
      uid="$(jq -r --arg u "($target@" 'to_entries[] | select(.value | contains($u)) | .key' <<<"$USERS_JSON")"
      if [[ "$(wc -w <<<"$uid")" -ne 1 ]]; then
        echo "  ERROR   $mp: user '$target' not found or not unique"; errors=$((errors + 1)); continue
      fi
      arg=(--add-user "$uid") ;;
    *) echo "  ERROR   $mp: unknown type '$type'"; errors=$((errors + 1)); continue ;;
  esac
  if [[ "$FLAG_APPLY" != 1 ]]; then
    echo "  PLAN    $mp -> $dir  [$mode, sharing=$sharing]  ${arg[*]}"; continue
  fi
  id="$(occ files_external:create "$mp" local null::null -c datadir="$dir" | grep -oE '[0-9]+$' || true)"
  if [[ -z "$id" ]]; then echo "  ERROR   $mp: create failed"; errors=$((errors + 1)); continue; fi
  if ! occ files_external:applicable "$id" "${arg[@]}" >/dev/null; then
    occ files_external:delete --yes "$id" >/dev/null
    echo "  ERROR   $mp: applicable failed, mount deleted"; errors=$((errors + 1)); continue
  fi
  occ files_external:option "$id" filesystem_check_changes 1
  occ files_external:option "$id" enable_sharing "$sharing"
  if [[ "$mode" == ro ]]; then occ files_external:option "$id" readonly true; fi
  if occ files_external:verify "$id" | grep -q 'status: ok'; then echo "  OK      $mp = $id"
  else echo "  WARNING $mp = $id: verify not ok"; fi
done < <(csv_rows "$CSV")

step "Mounts without an assigned group or user (would be visible to everyone)"
unassigned="$(occ files_external:list --output=json \
  | jq -r '.[] | select((.applicable_users | length) == 0 and (.applicable_groups | length) == 0) | "\(.mount_id)  \(.mount_point)"')"
check "no mount without assignment" test -z "$unassigned"
[[ -z "$unassigned" ]] || indent '    ' <<<"$unassigned"
check "no errors in the mount list" test "$errors" -eq 0
check_summary
