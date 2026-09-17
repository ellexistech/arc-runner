#!/usr/bin/env bash
# Set ARC maxRunners on the builder and helm-upgrade immediately.
#
# Usage:
#   bash ./set-runner-max.sh 8
#   bash ./set-runner-max.sh 8 1          # max 8, min 1
#   MAX_RUNNERS_HOST=builder.example bash ./set-runner-max.sh 3
#
# On the builder (hostname == BUILDER_HOSTNAME):
#   bash ./set-runner-max.sh 8
#
# Env overrides:
#   MAX_RUNNERS_HOST   SSH target when not on the builder (default: kvy.elx)
#   BUILDER_HOSTNAME   short hostname that means "run locally" (default: elx-kvy)
#   HELM_RELEASE       default ellexis-runners
#   HELM_NAMESPACE     default arc-runners
#   HELM_CHART         default gha-runner-scale-set OCI chart
#   VALUES_FILE        default ~/arc-runners-values.yaml

set -euo pipefail

HOST="${MAX_RUNNERS_HOST:-kvy.elx}"
BUILDER_HOSTNAME="${BUILDER_HOSTNAME:-elx-kvy}"
RELEASE="${HELM_RELEASE:-ellexis-runners}"
NAMESPACE="${HELM_NAMESPACE:-arc-runners}"
CHART="${HELM_CHART:-oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set}"

usage() {
  echo "Usage: $0 <maxRunners> [minRunners]" >&2
  echo "  maxRunners  positive integer (required)" >&2
  echo "  minRunners  non-negative integer (optional; keeps current if omitted)" >&2
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

MAX="$1"
MIN="${2:-}"

if ! [[ "$MAX" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: maxRunners must be a positive integer, got: $MAX" >&2
  exit 1
fi

if [[ -n "$MIN" ]]; then
  if ! [[ "$MIN" =~ ^[0-9]+$ ]]; then
    echo "error: minRunners must be a non-negative integer, got: $MIN" >&2
    exit 1
  fi
  if (( MIN > MAX )); then
    echo "error: minRunners ($MIN) cannot exceed maxRunners ($MAX)" >&2
    exit 1
  fi
fi

# Re-exec on the builder when invoked from a workstation.
if [[ "$(hostname -s 2>/dev/null || hostname)" != "$BUILDER_HOSTNAME" ]]; then
  if ! command -v ssh >/dev/null 2>&1; then
    echo "error: run this on ${BUILDER_HOSTNAME}, or install ssh and set MAX_RUNNERS_HOST" >&2
    exit 1
  fi
  echo "→ running on ${HOST}…"
  remote_env=(
    "HELM_RELEASE=$(printf %q "$RELEASE")"
    "HELM_NAMESPACE=$(printf %q "$NAMESPACE")"
    "HELM_CHART=$(printf %q "$CHART")"
    "BUILDER_HOSTNAME=$(printf %q "$BUILDER_HOSTNAME")"
  )
  if [[ -n "${VALUES_FILE:-}" ]]; then
    remote_env+=("VALUES_FILE=$(printf %q "$VALUES_FILE")")
  fi
  # shellcheck disable=SC2029
  exec ssh "$HOST" "env ${remote_env[*]} bash -s -- $(printf %q "$MAX") ${MIN:+$(printf %q "$MIN")}" <"$0"
fi

VALUES="${VALUES_FILE:-$HOME/arc-runners-values.yaml}"

if [[ ! -f "$VALUES" ]]; then
  echo "error: values file not found: $VALUES" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "error: helm not found on PATH" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl not found on PATH" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$VALUES" "$tmp"

set_key() {
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}:" "$file"; then
    sed -E "s|^${key}:.*|${key}: ${val}|" "$file" >"${file}.new"
    mv "${file}.new" "$file"
  else
    printf '%s: %s\n' "$key" "$val" >>"$file"
  fi
}

set_key maxRunners "$MAX" "$tmp"
if [[ -n "$MIN" ]]; then
  set_key minRunners "$MIN" "$tmp"
fi

echo "=== values (diff) ==="
diff -u "$VALUES" "$tmp" || true
echo

cp "$tmp" "$VALUES"
echo "→ helm upgrade ${RELEASE} (maxRunners=${MAX}${MIN:+ minRunners=${MIN}})…"
helm upgrade "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  -f "$VALUES"

echo
echo "=== AutoscalingRunnerSet ==="
kubectl get autoscalingrunnerset "$RELEASE" -n "$NAMESPACE"
echo
echo "done."
