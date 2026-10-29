#!/usr/bin/env bash
# 01 – Create the Proxmox cloud-init template for all Kubernetes nodes.
#
# Doc:     docs/01-proxmox-cloud-init-template.md (sections 2 and 3)
# Run on:  Proxmox host as root
# Usage:   ./create-template.sh [--dry-run] [--yes]
#
#   --dry-run   only print the commands, change nothing
#   --yes       do not ask before converting the VM into a template
#
# Test without touching the real template 9000:
#   TEMPLATE_ID=9001 TEMPLATE_NAME=k8s-tpl-test ./create-template.sh
#   ./verify-template.sh   (with the same variables), then: qm destroy 9001
#
# The console password for the user is asked for (or taken from $CI_PASSWORD).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars PVE_STORAGE PVE_BRIDGE TEMPLATE_ID TEMPLATE_NAME IMAGE_URL IMAGE_FILE \
             VM_CORES VM_MEMORY VM_DISK_SIZE CI_USER DNS_SERVER SSH_PUBKEYS
require_root

ID="$TEMPLATE_ID"

# ------------------------------------------------------------------------------
step "Checks before starting"
if [[ "$DRY_RUN" == 1 ]]; then
  info "(dry run) VM ID, storage and bridge checks are skipped"
else
  require_cmd qm pvesm wget
  if qm status "$ID" >/dev/null 2>&1; then
    die "VM $ID already exists – choose another TEMPLATE_ID or remove it first (qm destroy $ID)"
  fi
  pvesm status --storage "$PVE_STORAGE" >/dev/null 2>&1 || die "storage $PVE_STORAGE not found (pvesm status)"
  ip link show "$PVE_BRIDGE" >/dev/null 2>&1 || warn "bridge $PVE_BRIDGE not visible on this host – check the SDN configuration"
fi
[[ "$CI_USER" != "kube" ]] || die "CI_USER must not be 'kube' – Kubespray overwrites that user"

KEYS_FILE="$(mktemp /tmp/k8s-keys.XXXXXX)"
trap 'rm -f "$KEYS_FILE"' EXIT
# shellcheck disable=SC2086  # SSH_PUBKEYS is a space-separated list
for key in $SSH_PUBKEYS; do
  if [[ "$DRY_RUN" == 1 && ! -f "$key" ]]; then info "(dry run) would use $key"; continue; fi
  [[ -s "$key" ]] || die "SSH public key $key is missing or empty (see doc 01, problem 4)"
  cat "$key" >> "$KEYS_FILE"
done
if [[ "$DRY_RUN" != 1 ]]; then
  ok "VM ID $ID is free, storage $PVE_STORAGE exists, $(wc -l < "$KEYS_FILE") SSH key(s) found"
fi

ask_secret CI_PASSWORD "Console password for user $CI_USER"

# ------------------------------------------------------------------------------
step "1/6 Download the Ubuntu cloud image"
if [[ -f "$IMAGE_FILE" ]]; then
  ok "$IMAGE_FILE already exists – download skipped"
else
  run wget -O "$IMAGE_FILE" "$IMAGE_URL"
fi

# ------------------------------------------------------------------------------
step "2/6 Bake packages into the image ($BAKE_PACKAGES)"
if [[ -z "$BAKE_PACKAGES" ]]; then
  info "BAKE_PACKAGES is empty – skipped"
else
  if ! command -v virt-customize >/dev/null 2>&1; then
    run apt-get update
    run apt-get install -y libguestfs-tools
  fi
  # --truncate /etc/machine-id: otherwise all clones share one machine ID (and one DHCP lease)
  run virt-customize -a "$IMAGE_FILE" --install "$BAKE_PACKAGES" --truncate /etc/machine-id
fi

# ------------------------------------------------------------------------------
step "3/6 Create VM $ID ($TEMPLATE_NAME)"
run qm create "$ID" --name "$TEMPLATE_NAME" \
  --cores "$VM_CORES" --sockets 1 --cpu "${VM_CPU_TYPE:-x86-64-v3}" \
  --memory "$VM_MEMORY" --balloon 0 \
  --net0 "virtio,bridge=$PVE_BRIDGE,mtu=1" \
  --scsihw virtio-scsi-single --machine q35 \
  --ostype l26 --agent enabled=1

# ------------------------------------------------------------------------------
step "4/6 Import the disk, resize it to $VM_DISK_SIZE, add cloud-init drive and console"
run qm set "$ID" --scsi0 "$PVE_STORAGE:0,import-from=$IMAGE_FILE,discard=on,iothread=1"
run qm disk resize "$ID" scsi0 "$VM_DISK_SIZE"
run qm set "$ID" --ide2 "$PVE_STORAGE:cloudinit"
run qm set "$ID" --boot order=scsi0
run qm set "$ID" --serial0 socket --vga serial0

# ------------------------------------------------------------------------------
step "5/6 Cloud-init: user, password, DNS, updates, SSH keys"
run qm set "$ID" --ciuser "$CI_USER"
run_masked "qm set $ID --cipassword '********'" qm set "$ID" --cipassword "$CI_PASSWORD"
run qm set "$ID" --nameserver "$DNS_SERVER"
run qm set "$ID" --ciupgrade 1
run qm set "$ID" --ipconfig0 ip=dhcp          # overridden per clone
run qm set "$ID" --sshkeys "$KEYS_FILE"

if [[ "$DRY_RUN" != 1 ]]; then
  keys_in_dump=$(qm cloudinit dump "$ID" user | grep -cE '^\s*- (ssh-|ecdsa-)' || true)
  keys_expected=$(grep -cE '^(ssh-|ecdsa-)' "$KEYS_FILE")
  [[ "$keys_in_dump" -eq "$keys_expected" ]] \
    || die "cloud-init dump shows $keys_in_dump SSH key(s), expected $keys_expected – check: qm cloudinit dump $ID user"
  ok "$keys_in_dump SSH key(s) in the cloud-init configuration"
fi

# ------------------------------------------------------------------------------
step "6/6 Convert VM $ID into a template"
info "VM $ID has never been started – that is required for a clean template."
if confirm "Convert VM $ID into a template now?"; then
  run qm template "$ID"
else
  warn "Not converted. Do it later with: qm template $ID  (do NOT start the VM before that)"
  exit 0
fi

echo
ok "Template $ID ($TEMPLATE_NAME) is ready."
info "Next: ./verify-template.sh   then continue with 02-kubespray/"
