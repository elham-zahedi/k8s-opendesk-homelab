#!/usr/bin/env bash
# 03 – Roll out openDesk with helmfile.
#
# Doc:     docs/03-opendesk-deployment.md (sections 11, 12 and 18.4)
# Run on:  kubespray VM as k8s, inside tmux (the rollout takes about an hour)
# Usage:   ./deploy-opendesk.sh --render     render all manifests, check them (read-only)
#          ./deploy-opendesk.sh --diff       show what an apply would change (read-only)
#          ./deploy-opendesk.sh [--yes]      etcd backup, then helmfile apply
#
# Only one release (e.g. after a change in section 04 or 05):
#          HELMFILE_SELECTOR=name=opendesk-nextcloud ./deploy-opendesk.sh
#
# The master password is read from MASTER_PASSWORD_FILE and never printed.
# The first helmfile call downloads all charts and prints nothing for 5–15 minutes.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ALLOWED_FLAGS="render diff"
parse_common_args "$@"
load_env
require_vars OPENDESK_DIR OPENDESK_ENV OPENDESK_NAMESPACE MASTER_PASSWORD_FILE DOMAIN KUBECONFIG_PATH
require_cmd helmfile helm jq
use_kubectl
VALUES="$OPENDESK_DIR/helmfile/environments/$OPENDESK_ENV/values.yaml.gotmpl"
[[ -f "$VALUES" ]] || die "$VALUES not found – run prepare-opendesk.sh first"
[[ -s "$MASTER_PASSWORD_FILE" ]] || die "$MASTER_PASSWORD_FILE not found – run prepare-opendesk.sh first"
helm plugin list | awk '$1 == "diff"' | grep -q . || die "helm-diff plugin missing – run install-tools.sh"
MASTER_PASSWORD="$(cat "$MASTER_PASSWORD_FILE")"
export MASTER_PASSWORD
cd "$OPENDESK_DIR"
SEL=(); [[ -n "${HELMFILE_SELECTOR:-}" ]] && SEL=(-l "$HELMFILE_SELECTOR")
info "openDesk $(git describe --tags 2>/dev/null || echo '?'), environment $OPENDESK_ENV, namespace $OPENDESK_NAMESPACE"
info "master password: read from $MASTER_PASSWORD_FILE (not shown)"
[[ ${#SEL[@]} -eq 0 ]] || info "only releases matching: $HELMFILE_SELECTOR"

if [[ "$FLAG_RENDER" == 1 ]]; then
  step "Render all manifests (read-only)"
  out="$(mktemp /tmp/opendesk-render.XXXXXX.yaml)"
  echo "  \$ helmfile -e $OPENDESK_ENV ${SEL[*]} template > $out"
  [[ "$DRY_RUN" == 1 ]] && exit 0
  info "the first call downloads all charts and prints nothing for 5–15 minutes – do not cancel"
  helmfile -e "$OPENDESK_ENV" "${SEL[@]}" template >"$out" 2>"$out.log" || { tail -20 "$out.log"; die "helmfile template failed"; }
  chmod 600 "$out"   # the rendered manifests contain the derived passwords
  info "rendered: $(du -h "$out" | cut -f1) in $out (delete it when done)"
  info "volumes with StorageClass longhorn: $(grep -cE 'storageClassName: "?longhorn' "$out" || true)"
  info "host names in $DOMAIN:"
  grep -ohE "[a-z0-9.-]+\.${DOMAIN//./\\.}" "$out" | sort -u | indent '    '
  exit 0
fi

if [[ "$FLAG_DIFF" == 1 ]]; then
  step "Difference between the configuration and the running openDesk (read-only)"
  log="$HOME/opendesk-diff-$(date +%Y%m%d-%H%M).log"
  echo "  \$ helmfile -e $OPENDESK_ENV ${SEL[*]} diff -n $OPENDESK_NAMESPACE --suppress-secrets --detailed-exitcode > $log"
  [[ "$DRY_RUN" == 1 ]] && exit 0
  info "this evaluates every release and can take 10–20 minutes"
  set +e
  ( umask 077; helmfile -e "$OPENDESK_ENV" "${SEL[@]}" diff -n "$OPENDESK_NAMESPACE" --suppress-secrets \
      --detailed-exitcode --context 2 >"$log" 2>&1 )
  rc=$?
  set -e
  # only the summary lines are printed; the full diff stays in the log file (chmod 600)
  changes="$(grep -E ' has (changed|been added|been removed):' "$log" || true)"
  case "$rc" in
    0) ok "no differences – the running openDesk matches the configuration" ;;
    2) warn "$(grep -c . <<<"$changes") resource(s) would change:"; indent '    ' <<<"$changes"
       info "details (may contain configuration values – do not share): $log" ;;
    *) tail -n 20 "$log" | indent '    '; die "helmfile diff failed (exit code $rc) – see $log" ;;
  esac
  exit 0
fi

step "Rollout"
if [[ -z "${TMUX:-}" && "$DRY_RUN" != 1 ]]; then
  warn "not running inside tmux – if the SSH connection drops, the rollout stops"
  confirm "Continue without tmux?" || die "aborted – start tmux with: tmux new -s opendesk"
fi
confirm "Create an etcd backup and run helmfile apply ${HELMFILE_SELECTOR:+($HELMFILE_SELECTOR) }in namespace $OPENDESK_NAMESPACE now?" || die "aborted"

STAMP="$(date +%Y%m%d-%H%M)"
run "$AUTOMATION_DIR/ops/etcd-backup.sh" "before-opendesk-$STAMP"
# state before the rollout: configuration (contains secrets -> 600) and release list
REL_BEFORE="$HOME/helm-releases-before-$STAMP.txt"
releases() { helm -n "$OPENDESK_NAMESPACE" list -a -o json 2>/dev/null | jq -r '.[] | "\(.name)\t\(.revision)\t\(.chart)\t\(.status)"' | sort; }
echo "  \$ save $VALUES and the release list ($REL_BEFORE)"
if [[ "$DRY_RUN" != 1 ]]; then
  ( umask 077; cp "$VALUES" "$HOME/values-$OPENDESK_ENV.yaml.gotmpl.before-$STAMP" )
  releases >"$REL_BEFORE"
fi
if ! kubectl get namespace "$OPENDESK_NAMESPACE" >/dev/null 2>&1; then
  run kubectl create namespace "$OPENDESK_NAMESPACE"
fi
LOG="$HOME/opendesk-apply-$(date +%Y%m%d-%H%M).log"
# -n is mandatory: without it ~60 releases end up in the default namespace
echo "  \$ helmfile -e $OPENDESK_ENV ${SEL[*]} apply -n $OPENDESK_NAMESPACE --suppress-secrets 2>&1 | tee $LOG"
[[ "$DRY_RUN" == 1 ]] && exit 0
info "watch the progress in a second session: kubectl -n $OPENDESK_NAMESPACE get pods | grep -vE 'Running|Completed'"
set +e
helmfile -e "$OPENDESK_ENV" "${SEL[@]}" apply -n "$OPENDESK_NAMESPACE" --suppress-secrets 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e
[[ "$rc" -eq 0 ]] || die "helmfile apply failed (exit code $rc) – see $LOG and doc 03, section 16"
ok "helmfile apply finished – log: $LOG"
REL_AFTER="$HOME/helm-releases-after-$STAMP.txt"
releases >"$REL_AFTER"
info "releases before / after: $(wc -l <"$REL_BEFORE") / $(wc -l <"$REL_AFTER")"
new_rel="$(join -v2 <(cut -f1 "$REL_BEFORE") <(cut -f1 "$REL_AFTER") | xargs)"
[[ -z "$new_rel" ]] || info "new releases: $new_rel"
bad_rel="$(awk -F'\t' '$4 != "deployed" {print $1 " (" $4 ")"}' "$REL_AFTER" | xargs)"
[[ -z "$bad_rel" ]] || warn "not deployed: $bad_rel"
info "Next, once doc 04 (file server, SSO) is set up – then mandatory after every rollout: ./ops/post-rollout.sh (doc 05, F3)"
