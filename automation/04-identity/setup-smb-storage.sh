#!/usr/bin/env bash
# 04 – File server shares for Nextcloud: SMB CSI driver, nls_utf8 on all nodes,
#      SMB credentials and one PersistentVolume + PVC per share.
#
# Doc:     docs/04-active-directory-sso.md (sections 9 – 11)
# Run on:  kubespray VM as k8s
# Usage:   ./setup-smb-storage.sh [--dry-run] [--force]
#
#   --dry-run   prints the changes; the node preparation runs in Ansible check mode
#   --force     replace a different SMB secret or PV/PVC definition
#
# Asks for the password of the SMB service account (or takes $SMB_PASSWORD) only
# if the secret smb-fs-creds does not exist yet. The write test is part of
# verify-nextcloud-files.sh.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="force"
parse_common_args "$@"
load_env
require_vars FS_IP SMB_SHARES SMB_CSI_VERSION NC_UID SVC_SMB AD_NETBIOS OPENDESK_NAMESPACE INVENTORY_NAME
identity_vars
require_cmd helm
use_kubectl
NSO="$OPENDESK_NAMESPACE"
TMPD="$(mktemp -d)"; add_exit_hook "rm -rf $TMPD"

step "1/4 SMB CSI driver $SMB_CSI_VERSION"
if ! helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx csi-driver-smb; then
  run helm repo add csi-driver-smb https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
  run helm repo update csi-driver-smb
fi
helm_install_once kube-system csi-driver-smb csi-driver-smb/csi-driver-smb "$SMB_CSI_VERSION" 10m

step "2/4 Kernel module nls_utf8 on all nodes (error F7)"
( use_kubespray
  check_args=(); [[ "$DRY_RUN" == 1 ]] && check_args=(--check --diff)
  echo "  \$ ansible-playbook -i $INV prepare-nodes-smb.yml ${check_args[*]}"
  ansible-playbook -i "$INV" "$AUTOMATION_DIR/04-identity/prepare-nodes-smb.yml" "${check_args[@]}" \
    | grep -E 'msg|changed=|failed=|FAILED|fatal' | indent )

step "3/4 Secret smb-fs-creds (user $SVC_SMB, domain $AD_NETBIOS)"
if secret_exists "$NSO" smb-fs-creds; then
  user="$(secret_value "$NSO" smb-fs-creds username)"; dom="$(secret_value "$NSO" smb-fs-creds domain)"
  if [[ "$user" == "$SVC_SMB" && "$dom" == "$AD_NETBIOS" && "$FLAG_FORCE" != 1 ]]; then
    ok "exists (user $user, domain $dom)"
  elif [[ "$FLAG_FORCE" != 1 ]]; then
    die "smb-fs-creds has user '$user' / domain '$dom' – expected $SVC_SMB / $AD_NETBIOS; use --force to replace it"
  fi
fi
if ! secret_exists "$NSO" smb-fs-creds || [[ "$FLAG_FORCE" == 1 ]]; then
  ask_secret SMB_PASSWORD "Password of $SVC_SMB"
  printf '%s' "$SMB_PASSWORD" | put_secret "$NSO" smb-fs-creds password \
    --from-literal=username="$SVC_SMB" --from-literal=domain="$AD_NETBIOS"
fi

step "4/4 PersistentVolumes and PVCs for the shares: $SMB_SHARES"
for SHARE in $SMB_SHARES; do
  NAME="$(tr '[:upper:]' '[:lower:]' <<<"$SHARE")"
  OPENDESK_NAMESPACE="$NSO" render_template "$AUTOMATION_DIR/04-identity/manifests/smb-volume.yaml" \
    NAME SHARE FS_IP NC_UID OPENDESK_NAMESPACE >"$TMPD/smb-$NAME.yaml"
  apply_manifest "$TMPD/smb-$NAME.yaml"
done

[[ "$DRY_RUN" == 1 ]] && exit 0
echo
for SHARE in $SMB_SHARES; do
  NAME="$(tr '[:upper:]' '[:lower:]' <<<"$SHARE")"
  check "pvc-fs-$NAME Bound" bash -c "kubectl -n $NSO get pvc pvc-fs-$NAME -o jsonpath='{.status.phase}' | grep -qx Bound"
done
check "csidriver smb.csi.k8s.io registered" kubectl get csidriver smb.csi.k8s.io
check_summary
