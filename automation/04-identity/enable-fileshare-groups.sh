#!/usr/bin/env bash
# 04 – Enable files_external in Nextcloud and release the groups of the mount list.
#
# Doc:     docs/04-active-directory-sso.md (section 13)
# Run on:  kubespray VM as k8s
# Usage:   ./enable-fileshare-groups.sh [--dry-run] [CSV]
#
# Nextcloud only reads groups with opendeskFileshareEnabled=TRUE. The groups are
# taken from the mount list (default manifests/nc-mounts.csv, column "target" of
# the type "group"), so no group is released that has no mount. Groups that are
# already released are left unchanged.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CSV="$AUTOMATION_DIR/04-identity/manifests/nc-mounts.csv"; args=()
for a in "$@"; do if [[ "$a" == -* ]]; then args+=("$a"); else CSV="$a"; fi; done
parse_common_args "${args[@]}"
load_env
require_vars NUBUS_OU NUBUS_BASE_DN OPENDESK_NAMESPACE
identity_vars
require_cmd jq curl
use_kubectl
[[ -f "$CSV" ]] || die "$CSV not found"
mapfile -t GROUPS_LIST < <(csv_rows "$CSV" | awk -F';' '$3 == "group" {print $4}' | sort -u)

step "1/2 Nextcloud app files_external"
nextcloud_pod
if occ app:list --output=json | jq -e '.enabled | has("files_external")' >/dev/null; then
  ok "files_external is enabled"
else
  run occ app:enable files_external
fi

step "2/2 opendeskFileshareEnabled for ${#GROUPS_LIST[@]} groups from $(basename "$CSV")"
udm_connect
changed=0
for g in "${GROUPS_LIST[@]}"; do
  path="groups/group/$(urlencode "cn=$g,ou=$NUBUS_OU,$NUBUS_BASE_DN")"
  udm GET "$path"
  if [[ "$UDM_STATUS" != 200 ]]; then
    check "$g exists in Nubus (HTTP $UDM_STATUS – imported by the Directory Importer?)" false; continue
  fi
  if [[ "$(jq -r '.properties.opendeskFileshareEnabled' "$UDM_BODY")" == true ]]; then
    ok "$g already released"; continue
  fi
  info "\$ PATCH $g opendeskFileshareEnabled=true"
  changed=$((changed + 1))
  [[ "$DRY_RUN" == 1 ]] && continue
  udm PATCH "$path" '{"properties":{"opendeskFileshareEnabled":true}}'
  check "$g released (HTTP $UDM_STATUS)" test "$UDM_STATUS" = 204
done
info "$changed group(s) changed"
if [[ "$CHECKS_FAILED" -gt 0 ]]; then check_summary; fi
