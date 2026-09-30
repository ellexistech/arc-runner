#!/usr/bin/env bash
# Backup the k3s single-server SQLite datastore + cluster token for a
# control-plane migrate (see MIGRATE-CONTROL-PLANE.md).
#
# Usage (as root on the CURRENT control plane):
#   bash scripts/backup-control-plane.sh
#   OUT_DIR=/root/k3s-cp-backup bash scripts/backup-control-plane.sh
#
# Env:
#   OUT_DIR        default: /root/k3s-cp-backup-<UTC timestamp>
#   KEEP_STOPPED   set to 1 to leave k3s stopped after backup (cutover)

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo)" >&2
  exit 1
fi

SERVER_DIR="/var/lib/rancher/k3s/server"
DB_DIR="${SERVER_DIR}/db"
TOKEN_FILE="${SERVER_DIR}/token"

if [[ ! -d "${DB_DIR}" ]]; then
  echo "error: ${DB_DIR} missing — is this a k3s server?" >&2
  exit 1
fi
if [[ ! -f "${TOKEN_FILE}" ]]; then
  echo "error: ${TOKEN_FILE} missing — refuse to backup incomplete state" >&2
  exit 1
fi
if systemctl is-active --quiet k3s-agent 2>/dev/null && \
   ! systemctl is-active --quiet k3s 2>/dev/null; then
  echo "error: this host looks like an agent only; run on the control plane" >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUT_DIR:-/root/k3s-cp-backup-${TS}}"
mkdir -p "${OUT_DIR}"

echo "→ stopping k3s briefly for a consistent SQLite copy…"
WAS_ACTIVE=0
if systemctl is-active --quiet k3s 2>/dev/null; then
  WAS_ACTIVE=1
  systemctl stop k3s
fi

cp -a "${DB_DIR}" "${OUT_DIR}/db"
cp -a "${TOKEN_FILE}" "${OUT_DIR}/token"
printf '%s\n' "$(hostname -s)" >"${OUT_DIR}/source-hostname.txt"
printf '%s\n' "$(date -u --iso-8601=seconds)" >"${OUT_DIR}/backed-up-at.txt"
ip -4 -br addr >"${OUT_DIR}/source-addrs.txt" || true

ARCHIVE="/root/k3s-cp-backup-${TS}.tar.gz"
tar -C "${OUT_DIR}" -czf "${ARCHIVE}" .
chmod 600 "${ARCHIVE}" "${OUT_DIR}/token" 2>/dev/null || true

KEEP_STOPPED="${KEEP_STOPPED:-0}"
if [[ "${WAS_ACTIVE}" -eq 1 && "${KEEP_STOPPED}" != "1" ]]; then
  echo "→ restarting k3s (set KEEP_STOPPED=1 to leave it down for cutover)…"
  systemctl start k3s
elif [[ "${KEEP_STOPPED}" == "1" ]]; then
  echo "→ KEEP_STOPPED=1 — k3s left stopped (do not start until new CP is healthy, or roll back here)"
fi

echo
echo "done."
echo "  dir:     ${OUT_DIR}"
echo "  archive: ${ARCHIVE}"
echo
echo "Copy the archive off this host before cutover, e.g.:"
echo "  scp root@$(hostname -s):${ARCHIVE} ."
echo "Also copy ~/arc-runners-values.yaml and /etc/github-arc/ as belt-and-suspenders."
