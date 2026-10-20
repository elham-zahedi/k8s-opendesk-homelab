#!/usr/bin/env bash
# 03 – Kubespray settings for openDesk: strictARP for MetalLB and DNS forwarding
#      of the openDesk and AD zones to the domain controller.
#
# Doc:     docs/03-opendesk-deployment.md (section 2)
# Run on:  kubespray VM as k8s
# Usage:   ./configure-cluster-dns.sh [--dry-run]
#
# Changes inventory/<INVENTORY_NAME>/group_vars/k8s_cluster/k8s-cluster.yml
# (a backup is kept). Values that are already set are left unchanged; a value that
# differs is reported and NOT overwritten.
# Afterwards: 02-kubespray/install-cluster.sh, then fix-strictarp.sh and verify-dns.sh.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

parse_common_args "$@"
load_env
require_vars DOMAIN AD_DOMAIN AD_DC_IP INVENTORY_NAME
require_cmd yq
HERE="$AUTOMATION_DIR/03-opendesk"
use_kubespray
G="$INV_DIR/group_vars/k8s_cluster/k8s-cluster.yml"
[[ -f "$G" ]] || die "$G not found – run 02-kubespray/prepare-inventory.sh first"

wanted="$(render_template "$HERE/manifests/cluster-dns.yaml" DOMAIN AD_DOMAIN AD_DC_IP)"
changed=0
backup_once() {
  if [[ "$changed" == 0 ]]; then run cp -p "$G" "$G.bak-$(date +%Y%m%d-%H%M%S)"; changed=1; fi
}

step "1/2 kube_proxy_strict_arp: true (required by MetalLB)"
if grep -qx 'kube_proxy_strict_arp: true' "$G"; then
  ok "already set"
else
  backup_once
  set_yaml_var "$G" kube_proxy_strict_arp true
fi

step "2/2 DNS forwarding of $DOMAIN and $AD_DOMAIN to $AD_DC_IP"
for key in coredns_external_zones nodelocaldns_external_zones; do
  current="$(yq -o=json -I=0 ".$key" "$G")"
  desired="$(yq -o=json -I=0 ".$key" <<<"$wanted")"
  if [[ "$current" == "$desired" ]]; then
    ok "$key already set"
  elif [[ "$current" == null ]]; then
    backup_once
    info "\$ append $key to $G"
    if [[ "$DRY_RUN" == 1 ]]; then
      yq "{\"$key\": .$key}" <<<"$wanted" | indent '    '
    else
      { echo "# openDesk: forward $DOMAIN and $AD_DOMAIN to the domain controller"; yq "{\"$key\": .$key}" <<<"$wanted"; } >> "$G"
    fi
  else
    warn "$key is set to a different value – not changed:"
    yq ".$key" "$G" | indent '    '
    die "not changed – check DOMAIN, AD_DOMAIN and AD_DC_IP in lab.env (or $G)"
  fi
done

if [[ "$DRY_RUN" != 1 ]]; then
  yq '.' "$G" >/dev/null || die "$G is no longer valid YAML – restore the backup"
  ok "YAML OK"
fi
echo
if [[ "$changed" == 1 ]]; then
  info "Next: ./02-kubespray/install-cluster.sh (about 20 minutes), then ./03-opendesk/fix-strictarp.sh"
else
  info "Nothing changed. Next: ./03-opendesk/fix-strictarp.sh and ./03-opendesk/verify-dns.sh"
fi
