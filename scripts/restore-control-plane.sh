#!/usr/bin/env bash
# Restore a SQLite control-plane backup onto this k3s server and regenerate TLS
# so agents can join via the new host IP (see MIGRATE-CONTROL-PLANE.md).
#
# Prerequisites: k3s server already installed (install-control-plane.sh).
#
# Usage (as root on the NEW control plane):
#   BACKUP_ARCHIVE=/root/k3s-cp-backup-….tar.gz bash scripts/restore-control-plane.sh
#   BACKUP_DIR=/root/k3s-cp-backup-… bash scripts/restore-control-plane.sh
#
# Env:
#   BACKUP_ARCHIVE   path to tar.gz from backup-control-plane.sh (or BACKUP_DIR)
#   BACKUP_DIR       extracted dir containing db/ and token
#   WAIT_SECONDS     default 120 — wait for API Ready

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo)" >&2
  exit 1
fi

SERVER_DIR="/var/lib/rancher/k3s/server"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

if [[ ! -d "${SERVER_DIR}" ]]; then
  echo "error: ${SERVER_DIR} missing — run install-control-plane.sh first" >&2
  exit 1
fi
if systemctl is-active --quiet k3s-agent 2>/dev/null && \
   ! systemctl list-unit-files k3s.service 2>/dev/null | grep -q k3s.service; then
  echo "error: this host looks like an agent; restore only on a server" >&2
  exit 1
fi

TMP=""
cleanup() {
  if [[ -n "${TMP}" && -d "${TMP}" ]]; then
    rm -rf "${TMP}"
  fi
}
trap cleanup EXIT

if [[ -n "${BACKUP_ARCHIVE:-}" ]]; then
  if [[ ! -f "${BACKUP_ARCHIVE}" ]]; then
    echo "error: BACKUP_ARCHIVE not found: ${BACKUP_ARCHIVE}" >&2
    exit 1
  fi
  TMP="$(mktemp -d)"
  tar -xzf "${BACKUP_ARCHIVE}" -C "${TMP}"
  BACKUP_DIR="${TMP}"
elif [[ -n "${BACKUP_DIR:-}" ]]; then
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "error: BACKUP_DIR not found: ${BACKUP_DIR}" >&2
    exit 1
  fi
else
  echo "error: set BACKUP_ARCHIVE=… or BACKUP_DIR=…" >&2
  exit 1
fi

if [[ ! -d "${BACKUP_DIR}/db" || ! -f "${BACKUP_DIR}/token" ]]; then
  echo "error: backup must contain db/ and token" >&2
  ls -la "${BACKUP_DIR}" >&2 || true
  exit 1
fi

echo "→ stopping k3s…"
systemctl stop k3s

echo "→ restoring db + token…"
rm -rf "${SERVER_DIR}/db"
cp -a "${BACKUP_DIR}/db" "${SERVER_DIR}/db"
cp -a "${BACKUP_DIR}/token" "${SERVER_DIR}/token"
chmod 600 "${SERVER_DIR}/token" || true

echo "→ wiping TLS + creds so certs regenerate for this host / --tls-san…"
rm -rf "${SERVER_DIR}/tls"
rm -rf "${SERVER_DIR}/cred"
rm -f /etc/rancher/k3s/k3s.yaml

echo "→ starting k3s…"
systemctl start k3s

echo "→ waiting up to ${WAIT_SECONDS}s for node Ready…"
deadline=$((SECONDS + WAIT_SECONDS))
ok=0
while (( SECONDS < deadline )); do
  if kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes >/dev/null 2>&1; then
    if kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes \
      --no-headers 2>/dev/null | grep -q Ready; then
      ok=1
      break
    fi
  fi
  sleep 3
done

if [[ "${ok}" -ne 1 ]]; then
  echo "error: API did not become Ready in time; check: journalctl -u k3s -e" >&2
  systemctl --no-pager --full status k3s || true
  exit 1
fi

# Refresh user kubeconfig if present from install.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  CFG_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  if [[ -n "${CFG_HOME}" && -d "${CFG_HOME}" ]]; then
    mkdir -p "${CFG_HOME}/.kube"
    cp /etc/rancher/k3s/k3s.yaml "${CFG_HOME}/.kube/config"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${CFG_HOME}/.kube"
    chmod 600 "${CFG_HOME}/.kube/config"
    # Prefer advertised LAN IP when kubeconfig still points at loopback.
    if grep -q 'https://127.0.0.1:6443' "${CFG_HOME}/.kube/config"; then
      # Best-effort: first non-loopback IPv4 on the host.
      LAN_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
      if [[ -n "${LAN_IP}" ]]; then
        sed -i "s#https://127.0.0.1:6443#https://${LAN_IP}:6443#g" \
          "${CFG_HOME}/.kube/config"
      fi
    fi
  fi
fi

echo
echo "=== nodes ==="
kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes -o wide || true
echo
echo "done. Next:"
echo "  kubectl delete node <OLD_CP_NAME>   # and stale agent identity for this host if needed"
echo "  on each agent: repoint-agent.sh with K3S_URL=https://<NEW_IP>:6443"
echo "  sudo cat /var/lib/rancher/k3s/server/node-token"
