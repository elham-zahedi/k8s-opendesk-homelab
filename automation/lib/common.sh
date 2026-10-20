#!/usr/bin/env bash
# Shared helpers for all automation scripts. This file is sourced, not executed.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

set -euo pipefail

AUTOMATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_BOLD=''; C_OFF=''
fi

step() { echo; echo "${C_BOLD}==> $*${C_OFF}"; }
info() { echo "  $*"; }
ok()   { echo "${C_GREEN}  ✔ $*${C_OFF}"; }
warn() { echo "${C_YELLOW}  ! $*${C_OFF}" >&2; }
indent() { sed "s/^/${1:-  }/"; }   # indent stdin (for command output)
die()  { echo "${C_RED}  ✘ $*${C_OFF}" >&2; exit 1; }

# run CMD...  – prints the command, then runs it (only prints it with --dry-run)
run() {
  echo "  \$ $*"
  [[ "$DRY_RUN" == 1 ]] && return 0
  "$@"
}

# run_masked "TEXT" CMD...  – like run, but prints TEXT instead of the command
# (for commands that contain a password)
run_masked() {
  local text="$1"; shift
  echo "  \$ $text"
  [[ "$DRY_RUN" == 1 ]] && return 0
  "$@"
}

# load_env – reads automation/lab.env (or the file given in $LAB_ENV)
load_env() {
  local f="${LAB_ENV:-$AUTOMATION_DIR/lab.env}"
  [[ -f "$f" ]] || die "$f not found – run: cp lab.env.example lab.env, then adjust lab.env"
  # shellcheck source=/dev/null
  source "$f"
}

require_root() {
  [[ "$DRY_RUN" == 1 || "$EUID" -eq 0 ]] || die "run this script as root"
}

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "command not found: $c"; done
}

require_vars() {
  local v
  for v in "$@"; do [[ -n "${!v:-}" ]] || die "variable $v is empty – set it in lab.env"; done
}

# ask_secret VAR "Prompt" – takes VAR from the environment, otherwise asks for it (hidden input).
# Secrets are never written to lab.env or to the repository.
ask_secret() {
  local var="$1" prompt="$2" value=""
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "$DRY_RUN" == 1 ]]; then printf -v "$var" '%s' '<secret>'; return 0; fi
  read -rsp "  $prompt: " value; echo
  [[ -n "$value" ]] || die "$var must not be empty"
  printf -v "$var" '%s' "$value"
}

# confirm "Question?" – returns 0 on y/Y; always yes with --yes or --dry-run
confirm() {
  [[ "$ASSUME_YES" == 1 || "$DRY_RUN" == 1 ]] && return 0
  local answer=""
  read -rp "  $* [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]]
}

# usage – prints the comment block at the top of the running script
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# parse_common_args "$@" – handles --dry-run, --yes and --help.
# Scripts can allow extra flags before calling it: ALLOWED_FLAGS="force reboot"
# turns --force into FLAG_FORCE=1 and --reboot into FLAG_REBOOT=1.
ALLOWED_FLAGS="${ALLOWED_FLAGS:-}"
parse_common_args() {
  local a f name
  for f in $ALLOWED_FLAGS; do printf -v "FLAG_${f^^}" '%s' 0; done
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      --*)
        name="${a#--}"
        if [[ " $ALLOWED_FLAGS " == *" $name "* ]]; then printf -v "FLAG_${name^^}" '%s' 1
        else die "unknown option: $a (see --help)"; fi ;;
      *) die "unknown option: $a (see --help)" ;;
    esac
  done
  if [[ "$DRY_RUN" == 1 ]]; then warn "DRY RUN – commands are only printed, nothing is changed"; fi
}

# Simple pass/fail counter for verify scripts
CHECKS_OK=0
CHECKS_FAILED=0
check() {  # check "description" CONDITION-COMMAND...
  local text="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$text"; CHECKS_OK=$((CHECKS_OK + 1))
  else
    echo "${C_RED}  ✘ $text${C_OFF}"; CHECKS_FAILED=$((CHECKS_FAILED + 1))
  fi
}
check_summary() {
  echo
  if [[ "$CHECKS_FAILED" -eq 0 ]]; then
    ok "All $CHECKS_OK checks passed"
  else
    die "$CHECKS_FAILED of $((CHECKS_OK + CHECKS_FAILED)) checks failed"
  fi
}

# append_line FILE "LINE" – appends LINE to FILE (prints it with --dry-run)
append_line() {
  echo "  \$ echo '$2' >> $1"
  [[ "$DRY_RUN" == 1 ]] && return 0
  printf '%s\n' "$2" >> "$1"
}

# parse_nodes – splits $NODES (entries "name:vmid:ip:role") into the arrays
# NODE_NAMES, NODE_IDS, NODE_IPS and NODE_ROLES (role = control | worker | both)
parse_nodes() {
  NODE_NAMES=(); NODE_IDS=(); NODE_IPS=(); NODE_ROLES=()
  local entry name id ip role
  for entry in $NODES; do
    IFS=: read -r name id ip role <<<"$entry"
    [[ -n "$name" && "$id" =~ ^[0-9]+$ && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "invalid NODES entry '$entry' – expected name:vmid:ip:role"
    case "$role" in control|worker|both) ;; *) die "invalid role '$role' in NODES entry '$entry'" ;; esac
    NODE_NAMES+=("$name"); NODE_IDS+=("$id"); NODE_IPS+=("$ip"); NODE_ROLES+=("$role")
  done
  [[ "${#NODE_NAMES[@]}" -gt 0 ]] || die "NODES is empty – set it in lab.env"
}

# use_kubespray – runs Ansible from the Kubespray directory with the Kubespray venv
use_kubespray() {
  [[ -d "$KUBESPRAY_DIR" ]] || die "$KUBESPRAY_DIR not found – run 02-kubespray/install-kubespray.sh first"
  [[ -x "$KUBESPRAY_VENV/bin/ansible-playbook" ]] || die "Ansible not found in $KUBESPRAY_VENV – run install-kubespray.sh first"
  PATH="$KUBESPRAY_VENV/bin:$PATH"
  INV_DIR="$KUBESPRAY_DIR/inventory/$INVENTORY_NAME"
  INV="$INV_DIR/inventory.ini"
  cd "$KUBESPRAY_DIR"   # ansible.cfg of Kubespray is only used from here
}

# render_template FILE VAR... – prints FILE with every @VAR@ replaced by the value of $VAR
render_template() {
  local file="$1" content v; shift
  content="$(cat "$file")"
  for v in "$@"; do content="${content//@${v}@/${!v}}"; done
  grep -q '@[A-Z_]*@' <<<"$content" && die "unresolved placeholder in $file: $(grep -o '@[A-Z_]*@' <<<"$content" | head -1)"
  printf '%s\n' "$content"
}

# use_kubectl – kubectl against KUBECONFIG_PATH
use_kubectl() {
  require_cmd kubectl
  export KUBECONFIG="$KUBECONFIG_PATH"
  kubectl get --raw=/readyz >/dev/null 2>&1 || die "Kubernetes API not reachable with $KUBECONFIG_PATH"
}

# helm_chart_version NAMESPACE RELEASE – prints the installed chart version (empty if not installed)
helm_chart_version() {
  helm -n "$1" list -a -f "^$2\$" -o json 2>/dev/null \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["chart"].rsplit("-",1)[1] + " " + r[0]["status"] if r else "")'
}

# set_yaml_var FILE KEY VALUE – sets "KEY: VALUE"; replaces an existing or commented-out line
set_yaml_var() {
  local file="$1" key="$2" value="$3"
  [[ -f "$file" || "$DRY_RUN" == 1 ]] || die "$file not found"
  if grep -qxE "${key}: ${value}" "$file" 2>/dev/null; then
    ok "$key: $value (already set)"
  elif grep -qE "^${key}:" "$file" 2>/dev/null; then
    run sed -i -E "s|^${key}:.*|${key}: ${value}|" "$file"
  elif grep -qE "^# *${key}:" "$file" 2>/dev/null; then
    run sed -i -E "0,/^# *${key}:.*/s||${key}: ${value}|" "$file"
  else
    append_line "$file" "${key}: ${value}"
  fi
}

# identity_vars – names derived from lab.env for section 04
identity_vars() {
  AD_BASE_DN="DC=${AD_DOMAIN//./,DC=}"            # lab.local -> DC=lab,DC=local
  AD_DC_FQDN="$AD_DC_HOST.$AD_DOMAIN"
  FS_FQDN="$FS_HOST.$AD_DOMAIN"
  AD_USER_BASE="$AD_USER_OU,$AD_BASE_DN"
  AD_GROUP_BASE="$AD_GROUP_OU,$AD_BASE_DN"
  IDP_FQDN="$IDP_HOST.$DOMAIN"
  IDP_URL="https://$IDP_FQDN/auth"
  OPENDESK_ID_FQDN="id.$DOMAIN"                    # Keycloak of openDesk
  IDP_ALIAS="sso-federation-idp-$IDP_KEY"
  IDP_REDIRECT_URI="https://$OPENDESK_ID_FQDN/realms/opendesk/broker/$IDP_ALIAS/endpoint"
  UDM_URL_IN_CLUSTER="http://ums-udm-rest-api.$OPENDESK_NAMESPACE.svc.cluster.local:9979/univention/udm/"
}

# secret_exists NAMESPACE NAME
secret_exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }

# add_exit_hook "COMMAND" – runs COMMAND when the script ends (several hooks possible)
EXIT_HOOKS=()
run_exit_hooks() { local h; for h in "${EXIT_HOOKS[@]}"; do eval "$h" >/dev/null 2>&1 || true; done; }
add_exit_hook() { EXIT_HOOKS+=("$1"); trap run_exit_hooks EXIT; }

# port_forward NAMESPACE SERVICE LOCAL:REMOTE – starts kubectl port-forward in the
# background and waits until it answers; stopped automatically when the script ends
port_forward() {
  local ns="$1" svc="$2" ports="$3" local_port="${3%%:*}" i
  kubectl -n "$ns" port-forward "svc/$svc" "$ports" >/dev/null 2>&1 &
  add_exit_hook "kill $!"
  for i in $(seq 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null && return 0
    sleep 0.5
  done
  die "port-forward to $ns/$svc did not start"
}

# helm_install_once NAMESPACE RELEASE CHART VERSION TIMEOUT [helm args...]
# Installs a release that does not exist yet. An existing release is left unchanged
# (upgrades are a manual decision) and only reported if its version differs.
helm_install_once() {
  local ns="$1" rel="$2" chart="$3" ver="$4" timeout="$5"; shift 5
  local current; current="$(helm_chart_version "$ns" "$rel")"
  if [[ -z "$current" ]]; then
    # --timeout is mandatory: with the default of 5 minutes helm marks slow releases as failed
    run helm upgrade --install "$rel" "$chart" --namespace "$ns" --create-namespace \
      --version "$ver" --timeout "$timeout" --wait "$@"
  elif [[ "$current" == "$ver deployed" ]]; then
    ok "$rel $ver is already installed (deployed) – left unchanged"
  else
    warn "$rel is installed as '$current', expected '$ver deployed' – left unchanged"
  fi
}

# yaml_same A B – true if two YAML files have the same content (comments, order and quoting ignored)
yaml_same() { diff -q <(yq -o=json 'sort_keys(..)' "$1") <(yq -o=json 'sort_keys(..)' "$2") >/dev/null 2>&1; }

# helm_values_match NAMESPACE RELEASE FILE – compares the values of a release with FILE
helm_values_match() {
  local tmp; tmp="$(mktemp)"
  helm -n "$1" get values "$2" -o yaml >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  if yaml_same "$tmp" "$3"; then rm -f "$tmp"; return 0; fi
  diff <(yq -P 'sort_keys(..)' "$tmp") <(yq -P '(... comments = "") | sort_keys(..)' "$3") | indent '    ' || true
  rm -f "$tmp"; return 1
}

# apply_manifest FILE – creates the resources in FILE. Existing resources that differ
# are only changed with --force (the difference is shown first).
apply_manifest() {
  local f="$1" rc=0 tmp; tmp="$(mktemp)"
  kubectl diff -f "$f" >"$tmp" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "$(basename "$f"): already applied, no difference"; rm -f "$tmp"; return 0; fi
  if [[ "$rc" -eq 1 ]] && kubectl get -f "$f" >/dev/null 2>&1; then
    indent '    ' <"$tmp"; rm -f "$tmp"
    [[ "${FLAG_FORCE:-0}" == 1 ]] || die "$(basename "$f") differs from the cluster (see above) – check lab.env, or apply it with --force"
  fi
  rm -f "$tmp"
  run kubectl apply -f "$f"
}

# urlencode STRING
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# secret_value NAMESPACE NAME KEY – prints one value of a secret (never echo it to the terminal)
secret_value() { kubectl -n "$1" get secret "$2" -o json | jq -r --arg k "$3" '.data[$k] // empty' | base64 -d; }

# put_secret NAMESPACE NAME KEY [more --from-literal args] – creates or replaces a secret;
# the value of KEY is read from stdin, so it never shows up in the process list
put_secret() {
  local ns="$1" name="$2" key="$3"; shift 3
  echo "  \$ kubectl -n $ns create secret generic $name --from-file=$key=<hidden> $*"
  if [[ "$DRY_RUN" == 1 ]]; then cat >/dev/null; return 0; fi
  kubectl -n "$ns" create secret generic "$name" --from-file="$key=/dev/stdin" "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# ---- Nubus UDM REST API (through kubectl port-forward, password via curl config on a pipe)
UDM_BODY=""; UDM_STATUS=""
udm_connect() {
  UDM_BODY="$(mktemp)"
  UDM_PW="$(secret_value "$OPENDESK_NAMESPACE" ums-nubus-credentials administrator_password)"
  [[ -n "$UDM_PW" ]] || die "Nubus administrator password not found (secret ums-nubus-credentials)"
  port_forward "$OPENDESK_NAMESPACE" ums-udm-rest-api 19979:9979
  add_exit_hook "rm -f $UDM_BODY"
}
# udm METHOD PATH [JSON] – body in $UDM_BODY, HTTP status in $UDM_STATUS
udm() {
  local method="$1" path="$2" data=() pw="${UDM_PW//\\/\\\\}"
  pw="${pw//\"/\\\"}"
  [[ -n "${3:-}" ]] && data=(--data "$3")
  UDM_STATUS="$(curl -sS -o "$UDM_BODY" -w '%{http_code}' -X "$method" \
    -K <(printf 'user = "Administrator:%s"\n' "$pw") \
    -H 'Accept: application/json' -H 'Content-Type: application/json' "${data[@]}" \
    "http://127.0.0.1:19979/univention/udm/$path")" || UDM_STATUS=000
}
# udm_count PATH – number of objects in a search result
udm_count() { udm GET "$1"; jq '._embedded["udm:object"] | length' "$UDM_BODY" 2>/dev/null || echo 0; }

# ---- Nextcloud
# nextcloud_pod – sets NCPOD to the running Nextcloud (aio) pod
nextcloud_pod() {
  NCPOD="$(kubectl -n "$OPENDESK_NAMESPACE" get pod -l app.kubernetes.io/name=aio \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$NCPOD" ]] || die "no running Nextcloud pod (label app.kubernetes.io/name=aio) in $OPENDESK_NAMESPACE"
}
# occ ARGS... – Nextcloud command line in the pod
occ() { kubectl -n "$OPENDESK_NAMESPACE" exec "$NCPOD" -- php /var/www/html/occ "$@" </dev/null; }
# csv_rows FILE – the data lines of a ;-separated file, without header and CR
csv_rows() { tail -n +2 "$1" | tr -d '\r' | grep -v '^\s*$'; }

# ---- Admin REST API of the dedicated Keycloak (doc 04, section 19.4)
# The password is passed to curl on stdin and the token in a header file, so neither
# shows up in the process list. A new token is fetched for every call (lifetime 60 s).
KC_BODY=""; KC_STATUS=""
kc_connect() {
  [[ -s "$KEYCLOAK_ADMIN_PASSWORD_FILE" ]] || die "$KEYCLOAK_ADMIN_PASSWORD_FILE not found"
  [[ -s "$OPENDESK_CA_FILE" ]] || die "$OPENDESK_CA_FILE not found – run 03-opendesk/export-ca.sh"
  KC_BODY="$(mktemp)"; add_exit_hook "rm -f $KC_BODY"
}
kc_token() {
  printf '%s' "$(<"$KEYCLOAK_ADMIN_PASSWORD_FILE")" | curl -sS --cacert "$OPENDESK_CA_FILE" \
    -d client_id=admin-cli -d "username=${KEYCLOAK_ADMIN_USER:-admin}" --data-urlencode "password@-" \
    -d grant_type=password "$IDP_URL/realms/master/protocol/openid-connect/token" | jq -r '.access_token // empty'
}
# kc METHOD PATH [JSON | @-] – PATH below /admin/realms; body in $KC_BODY, status in $KC_STATUS
kc() {
  local method="$1" path="$2" data=() token
  token="$(kc_token)"
  [[ -n "$token" ]] || die "no admin token from $IDP_URL (user ${KEYCLOAK_ADMIN_USER:-admin}, password file $KEYCLOAK_ADMIN_PASSWORD_FILE)"
  [[ -n "${3:-}" ]] && data=(--data-binary "$3")
  KC_STATUS="$(curl -sS --cacert "$OPENDESK_CA_FILE" -o "$KC_BODY" -w '%{http_code}' -X "$method" \
    -H @<(printf 'Authorization: Bearer %s\n' "$token") -H 'Content-Type: application/json' \
    "${data[@]}" "$IDP_URL/admin/realms$path")" || KC_STATUS=000
}

# random_password LENGTH – letters and digits only
random_password() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-"$1"; }

# ---- Groupware permission (doc 05, section 8)
# groupware_state – compares the users with isOxUser = true in ou=NUBUS_OU with the
# members of the group GROUPWARE_GROUP (needs udm_connect). DNs are compared without
# case, the original spelling is kept. Sets GW_DN (empty if the group does not exist),
# OX_USERS, GW_MEMBERS, GW_MISSING (counts), GW_ALL_MEMBERS and GW_MISSING_DNS (JSON arrays).
groupware_state() {
  local users
  udm GET "users/user/?position=$(urlencode "ou=$NUBUS_OU,$NUBUS_BASE_DN")&scope=sub&properties=isOxUser"
  [[ "$UDM_STATUS" == 200 ]] || die "reading the users failed (HTTP $UDM_STATUS)"
  users="$(jq -c '[._embedded["udm:object"][] | select(.properties.isOxUser == true) | .dn]' "$UDM_BODY")"
  udm GET "groups/group/?filter=$(urlencode "cn=$GROUPWARE_GROUP")&properties=users"
  [[ "$UDM_STATUS" == 200 ]] || die "reading the group $GROUPWARE_GROUP failed (HTTP $UDM_STATUS)"
  GW_DN="$(jq -r '._embedded["udm:object"][0].dn // empty' "$UDM_BODY")"
  GW_ALL_MEMBERS="$(jq -c '._embedded["udm:object"][0].properties.users // []' "$UDM_BODY")"
  GW_MISSING_DNS="$(jq -nc --argjson u "$users" --argjson m "$GW_ALL_MEMBERS" \
    '($m | map(ascii_downcase)) as $have | $u | map(select(ascii_downcase | IN($have[]) | not))')"
  OX_USERS="$(jq length <<<"$users")"
  GW_MEMBERS="$(jq length <<<"$GW_ALL_MEMBERS")"
  GW_MISSING="$(jq length <<<"$GW_MISSING_DNS")"
}

# ---- Adding a worker (doc 06)
# find_node NAME | name:vmid:ip:role – sets W_NAME, W_ID, W_IP, W_ROLE, W_ENTRY and
# W_IN_NODES (1 if NAME is listed in NODES). A full entry is only needed for a test
# with a node that is not in lab.env yet.
find_node() {
  local arg="${1:-}" entry
  [[ -n "$arg" ]] || die "node missing – usage: $(basename "$0") NAME   (see --help)"
  W_IN_NODES=0; W_ENTRY=""
  for entry in $NODES; do
    if [[ "${entry%%:*}" == "${arg%%:*}" ]]; then
      W_IN_NODES=1
      [[ "$arg" == *:* && "$arg" != "$entry" ]] && die "$arg differs from the entry $entry in NODES"
      W_ENTRY="$entry"
    fi
  done
  [[ "$arg" == *:* ]] && W_ENTRY="$arg"
  [[ -n "$W_ENTRY" ]] || die "$arg is not listed in NODES (lab.env) – add a line like $arg:208:10.240.0.28:worker"
  IFS=: read -r W_NAME W_ID W_IP W_ROLE <<<"$W_ENTRY"
  [[ "$W_NAME" =~ ^[a-z0-9-]+$ && "$W_ID" =~ ^[0-9]+$ && "$W_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "invalid node entry '$W_ENTRY' – expected name:vmid:ip:role"
  [[ "$W_ROLE" == worker ]] || die "$W_NAME has the role '$W_ROLE' – these scripts only add workers; control plane and etcd nodes need cluster.yml (doc 06, section 8)"
}

# control_plane_node – sets CP_NAME and CP_IP to the first control plane node in NODES
control_plane_node() {
  local entry name id ip role
  CP_NAME=""; CP_IP=""
  for entry in $NODES; do
    IFS=: read -r name id ip role <<<"$entry"
    if [[ "$role" != worker ]]; then CP_NAME="$name"; CP_IP="$ip"; return 0; fi
  done
  die "no control plane node in NODES"
}

# run_playbook LOG PLAYBOOK [ansible-playbook args...] – runs a playbook from the
# Kubespray directory (use_kubespray first), writes the full output to LOG, prints
# the result lines and the PLAY RECAP, and stops if a host failed.
run_playbook() {
  local log="$1" pb="$2" rc; shift 2
  echo "  \$ ansible-playbook -i $INV_RUN $(basename "$pb") $*   (log: $log)"
  set +e
  ansible-playbook -i "$INV_RUN" "$pb" "$@" >"$log" 2>&1
  rc=$?
  set -e
  grep -E '"msg"|ok=[0-9]+ +changed=' "$log" | indent '    ' || true
  if [[ "$rc" -ne 0 ]] || grep -qE 'unreachable=[1-9]|failed=[1-9]' "$log"; then
    grep -n -A3 'fatal:' "$log" | grep -v '\.\.\.ignoring' | tail -n 20 | indent '    ' || true
    die "$(basename "$pb") failed (exit code $rc) – see $log"
  fi
}
