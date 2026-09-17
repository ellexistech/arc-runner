#!/usr/bin/env bash
# Force-delete EphemeralRunners that block the scale set after jobs finish.
#
# ARC 0.14 can leave CRs in phase=Running with finalizers while the pod is
# Succeeded/Failed (or missing). Those slots count toward maxRunners and
# leave GitHub jobs queued forever.
#
# Safe rule: only touch ERs whose pod is gone / Succeeded / Failed and older
# than GRACE_SECONDS (gives the controller time to clean up normally).
#
# Usage:
#   bash scripts/cleanup-stuck-ephemeralrunners.sh
#   DRY_RUN=1 GRACE_SECONDS=60 bash scripts/cleanup-stuck-ephemeralrunners.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-arc-runners}"
GRACE_SECONDS="${GRACE_SECONDS:-120}"
DRY_RUN="${DRY_RUN:-0}"

now_epoch=$(date -u +%s)

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

to_epoch() {
  # Accept 2026-09-17T09:56:18Z or …18.123456789Z.
  # BusyBox (alpine/k8s): date -u -D FMT -d TIME; GNU: date -u -d TIME.
  local ts out
  ts=$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')
  if out=$(date -u -D '%Y-%m-%dT%H:%M:%SZ' -d "$ts" +%s 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(date -u -d "$ts" +%s 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  printf '0\n'
  return 1
}

force_delete_er() {
  local name="$1"
  local reason="$2"
  log "FORCE-DELETE ephemeralrunner/${name} (${reason})"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  kubectl patch "ephemeralrunner/${name}" -n "$NAMESPACE" --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  kubectl delete "ephemeralrunner/${name}" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
}

log "scanning EphemeralRunners in ${NAMESPACE} (grace=${GRACE_SECONDS}s)"

mapfile -t ers < <(kubectl get ephemeralrunner -n "$NAMESPACE" -o name 2>/dev/null || true)
if [[ ${#ers[@]} -eq 0 || -z "${ers[0]:-}" ]]; then
  log "no EphemeralRunners"
fi

for er in "${ers[@]}"; do
  [[ -z "$er" ]] && continue
  name=${er#ephemeralrunner.actions.github.com/}
  name=${name#ephemeralrunner/}
  phase=$(kubectl get ephemeralrunner "$name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  created=$(kubectl get ephemeralrunner "$name" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}')
  created_epoch=$(to_epoch "$created" || true)
  if [[ "$created_epoch" -eq 0 ]]; then
    log "skip ${name}: cannot parse creationTimestamp=${created}"
    continue
  fi
  age=$((now_epoch - created_epoch))

  if ! kubectl get "pod/${name}" -n "$NAMESPACE" >/dev/null 2>&1; then
    if (( age >= GRACE_SECONDS )); then
      force_delete_er "$name" "no pod, age=${age}s, phase=${phase:-none}"
    else
      log "skip ${name}: no pod yet (age=${age}s < grace)"
    fi
    continue
  fi

  pod_phase=$(kubectl get "pod/${name}" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
  finished=$(kubectl get "pod/${name}" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.finishedAt}')
  if [[ -z "$finished" ]]; then
    finished=$(kubectl get "pod/${name}" -n "$NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}')
  fi
  if [[ -z "$finished" ]]; then
    finished=$(kubectl get "pod/${name}" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}')
  fi
  finished_epoch=$(to_epoch "$finished" || true)
  # If finishedAt cannot be parsed, fall back to ER age (never treat as epoch 0).
  if [[ "$finished_epoch" -eq 0 ]]; then
    finished_age=$age
    log "warn ${name}: bad finishedAt=${finished}; using ER age=${age}s"
  else
    finished_age=$((now_epoch - finished_epoch))
  fi

  case "$pod_phase" in
    Succeeded|Failed)
      if (( finished_age >= GRACE_SECONDS )); then
        force_delete_er "$name" "pod=${pod_phase}, finished_age=${finished_age}s, er_phase=${phase:-none}"
      else
        log "skip ${name}: pod ${pod_phase} (finished_age=${finished_age}s < grace)"
      fi
      ;;
    *)
      log "ok ${name}: pod=${pod_phase} er_phase=${phase:-none}"
      ;;
  esac
done

while read -r p; do
  [[ -z "$p" ]] && continue
  pod=${p#pod/}
  if ! kubectl get "ephemeralrunner/${pod}" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "delete orphan pod/${pod} (no ER)"
    if [[ "$DRY_RUN" != "1" ]]; then
      kubectl delete "pod/${pod}" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
    fi
  fi
done < <(
  { kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Succeeded -o name 2>/dev/null || true
    kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Failed -o name 2>/dev/null || true
  }
)

log "done"
