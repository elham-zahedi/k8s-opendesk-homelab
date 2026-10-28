#!/usr/bin/env bash
# 01 – Check that the cloud-init template has all settings from doc 01.
# Read-only: changes nothing, safe to run at any time.
#
# Doc:     docs/01-proxmox-cloud-init-template.md (sections 3.3, 4 and 6.2)
# Run on:  Proxmox host as root
# Usage:   ./verify-template.sh            (checks TEMPLATE_ID from lab.env)
#          TEMPLATE_ID=9001 ./verify-template.sh

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars TEMPLATE_ID PVE_BRIDGE VM_CORES VM_MEMORY VM_DISK_SIZE CI_USER DNS_SERVER SSH_PUBKEYS
require_cmd qm

ID="$TEMPLATE_ID"
CONF="$(qm config "$ID" 2>/dev/null)" || die "VM $ID not found"
USERDATA="$(qm cloudinit dump "$ID" user 2>/dev/null || true)"

has()  { grep -qE "$1" <<<"$CONF"; }
lacks() { ! grep -qE "$1" <<<"$CONF"; }

step "Template $ID – hardware"
check "${VM_CORES} cores"                 has "^cores: ${VM_CORES}$"
check "CPU type host"                     has "^cpu: host$"
check "memory ${VM_MEMORY} MB"            has "^memory: ${VM_MEMORY}$"
check "no ballooning (balloon: 0)"        has "^balloon: 0$"
check "machine q35"                       has "^machine: q35"
check "VirtIO SCSI single"                has "^scsihw: virtio-scsi-single$"
check "disk scsi0 with discard and iothread" has "^scsi0: .*discard=on.*iothread=1"
check "disk size ${VM_DISK_SIZE}"         has "^scsi0: .*size=${VM_DISK_SIZE}"
BRIDGE_MTU="$(cat "/sys/class/net/${PVE_BRIDGE}/mtu" 2>/dev/null || echo unknown)"
check "network on ${PVE_BRIDGE} with mtu=1 (inherits ${BRIDGE_MTU} from the bridge)" has "^net0: virtio=.*bridge=${PVE_BRIDGE}.*mtu=1"
check "cloud-init drive on ide2"          has "^ide2: .*cloudinit"
check "boot from scsi0"                   has "^boot: order=scsi0$"
check "serial console"                    has "^serial0: socket$"
check "display serial0"                   has "^vga: serial0$"
check "QEMU guest agent enabled"          has "^agent: (1|enabled=1)"

step "Template $ID – cloud-init"
check "user ${CI_USER}"                   has "^ciuser: ${CI_USER}$"
check "console password is set"           has "^cipassword: "
check "DNS server ${DNS_SERVER}"          has "^nameserver: ${DNS_SERVER}$"
check "package upgrade on first boot not disabled" lacks "^ciupgrade: 0$"
check "IP via DHCP in the template (static per clone)" has "^ipconfig0: ip=dhcp$"
check "exactly one sshkeys line"          test "$(grep -c '^sshkeys:' <<<"$CONF")" -eq 1

# shellcheck disable=SC2086  # SSH_PUBKEYS is a space-separated list
for key in $SSH_PUBKEYS; do
  [[ -s "$key" ]] || { warn "public key $key not found on this host – skipped"; continue; }
  comment="$(awk '{print $3}' "$key")"
  check "SSH key ${comment:-$key} in the cloud-init dump" grep -qF "$(awk '{print $2}' "$key")" <<<"$USERDATA"
done

step "Template $ID – state"
check "converted to a template (template: 1)" has "^template: 1$"

check_summary
