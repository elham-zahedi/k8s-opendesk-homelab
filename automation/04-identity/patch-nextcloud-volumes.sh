#!/usr/bin/env bash
# 04 – Mount the SMB volumes into the Nextcloud pod (the only change to a versioned
#      file of the openDesk repository).
#
# Doc:     docs/04-active-directory-sso.md (section 12)
# Run on:  kubespray VM as k8s
# Usage:   ./patch-nextcloud-volumes.sh [--dry-run]
#
# Changes helmfile/apps/nextcloud/values-nextcloud.yaml.gotmpl: the CA volume stays
# conditional, one volume and mount per share in SMB_SHARES is added. The block is
# found by its content (patch-nextcloud-volumes.py), not by line numbers. A file that
# already contains the volumes is left unchanged. The local change is saved as a patch
# (PATCH_FILE) so it can be re-applied after an openDesk update with "git apply".
# Afterwards roll out Nextcloud:
#   HELMFILE_SELECTOR=name=opendesk-nextcloud ./03-opendesk/deploy-opendesk.sh

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars OPENDESK_DIR SMB_SHARES
require_cmd git python3
F="$OPENDESK_DIR/helmfile/apps/nextcloud/values-nextcloud.yaml.gotmpl"
PATCH_FILE="${PATCH_FILE:-$HOME/opendesk-local-changes.patch}"
[[ -f "$F" ]] || die "$F not found – run 03-opendesk/prepare-opendesk.sh first"
TMP="$(mktemp)"; add_exit_hook "rm -f $TMP"

names=()
for s in $SMB_SHARES; do names+=("$(tr '[:upper:]' '[:lower:]' <<<"$s")"); done

step "1/2 $F"
missing=0
for n in "${names[@]}"; do grep -q "claimName: \"pvc-fs-$n\"" "$F" || missing=$((missing + 1)); done
if [[ "$missing" -eq 0 ]]; then
  ok "already contains the volumes of all ${#names[@]} shares – left unchanged"
else
  {
    cat <<'EOF'
  extraVolumes:
    {{- if .Values.certificate.selfSigned }}
    - name: "trusted-cert-secret-volume"
      secret:
        secretName: "opendesk-certificates-ca-tls"
        items:
          - key: "ca.crt"
            path: "ca-certificates.crt"
    {{- end }}
EOF
    for n in "${names[@]}"; do
      printf '    - name: "fs-%s"\n      persistentVolumeClaim:\n        claimName: "pvc-fs-%s"\n' "$n" "$n"
    done
    cat <<'EOF'
  extraVolumeMounts:
    {{- if .Values.certificate.selfSigned }}
    - name: "trusted-cert-secret-volume"
      mountPath: "/etc/ssl/certs/ca-certificates.crt"
      subPath: "ca-certificates.crt"
    {{- end }}
EOF
    for n in "${names[@]}"; do
      printf '    - name: "fs-%s"\n      mountPath: "/mnt/fs-%s"\n' "$n" "$n"
    done
  } >"$TMP"
  if [[ "$DRY_RUN" == 1 ]]; then
    cp "$F" "$TMP.preview"; add_exit_hook "rm -f $TMP.preview"
    python3 "$AUTOMATION_DIR/04-identity/patch-nextcloud-volumes.py" "$TMP.preview" "$TMP" | indent
    diff -u "$F" "$TMP.preview" | indent '    ' || true
  else
    run cp -p "$F" "$HOME/values-nextcloud.yaml.gotmpl.orig"
    python3 "$AUTOMATION_DIR/04-identity/patch-nextcloud-volumes.py" "$F" "$TMP" | indent
  fi
fi

step "2/2 Local changes in the openDesk repository"
git -C "$OPENDESK_DIR" --no-pager diff --stat | indent
if [[ "$DRY_RUN" != 1 ]]; then
  git -C "$OPENDESK_DIR" --no-pager diff >"$PATCH_FILE.new"
  if [[ -f "$PATCH_FILE" ]] && cmp -s "$PATCH_FILE" "$PATCH_FILE.new"; then
    rm -f "$PATCH_FILE.new"; ok "patch $PATCH_FILE is up to date"
  else
    mv "$PATCH_FILE.new" "$PATCH_FILE"; ok "patch saved: $PATCH_FILE ($(wc -c <"$PATCH_FILE") bytes)"
  fi
fi
[[ "$missing" -eq 0 ]] || info "Next: HELMFILE_SELECTOR=name=opendesk-nextcloud ./03-opendesk/deploy-opendesk.sh"
