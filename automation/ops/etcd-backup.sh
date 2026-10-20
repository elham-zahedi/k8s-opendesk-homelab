#!/usr/bin/env bash
# ops – etcd snapshot on the control plane, with a copy on the kubespray VM.
#
# Doc:     docs/03-opendesk-deployment.md (section 8.2), docs/06 and docs/12
# Run on:  kubespray VM as k8s
# Usage:   ./etcd-backup.sh NAME          e.g. ./etcd-backup.sh vor-opendesk
#
# Snapshot: /var/backups/etcd/NAME.db on the first control plane node from NODES,
# copy: ETCD_BACKUP_DIR/NAME-<date>.db (chmod 600 – the snapshot contains all secrets).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

name=""; flags=()
for a in "$@"; do
  if [[ "$a" == -* ]]; then flags+=("$a"); elif [[ -z "$name" ]]; then name="$a"; else die "only one NAME allowed"; fi
done
parse_common_args "${flags[@]}"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "usage: ./etcd-backup.sh NAME [--dry-run]   (NAME: letters, digits, . _ -)"
load_env
require_vars NODES ANSIBLE_USER ETCD_BACKUP_DIR
parse_nodes
cp_name=""; cp_ip=""
for i in "${!NODE_NAMES[@]}"; do
  if [[ "${NODE_ROLES[$i]}" != worker ]]; then cp_name="${NODE_NAMES[$i]}"; cp_ip="${NODE_IPS[$i]}"; break; fi
done
[[ -n "$cp_name" ]] || die "no control plane node in NODES"
SSH=(ssh -o BatchMode=yes "$ANSIBLE_USER@$cp_ip")
ETCDCTL="sudo etcdctl --endpoints=https://$cp_ip:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-$cp_name.pem --key=/etc/ssl/etcd/ssl/admin-$cp_name-key.pem"

step "1/3 Snapshot on $cp_name: /var/backups/etcd/$name.db"
run "${SSH[@]}" "sudo mkdir -p /var/backups/etcd && $ETCDCTL snapshot save /var/backups/etcd/$name.db >/dev/null"

step "2/3 Snapshot status"
run "${SSH[@]}" "sudo etcdutl --write-out=table snapshot status /var/backups/etcd/$name.db"

step "3/3 Copy to $ETCD_BACKUP_DIR (outside the cluster)"
copy="$ETCD_BACKUP_DIR/$name-$(date +%F-%H%M).db"
run mkdir -p "$ETCD_BACKUP_DIR"
echo "  \$ ${SSH[*]} \"sudo cat /var/backups/etcd/$name.db\" > $copy"
if [[ "$DRY_RUN" != 1 ]]; then
  ( umask 077; "${SSH[@]}" "sudo cat /var/backups/etcd/$name.db" > "$copy" )
  chmod 600 "$copy"
  [[ -s "$copy" ]] || die "copy is empty"
  ok "$copy ($(du -h "$copy" | cut -f1))"
fi
