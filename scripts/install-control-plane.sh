#!/usr/bin/env bash
# Install a fresh k3s *server* (control plane) for the ARC builder cluster.
# Use with restore-control-plane.sh when migrating SQLite state from another host.
#
# Usage (as root on the NEW control plane):
#   TLS_SAN=192.168.1.10 bash scripts/install-control-plane.sh
#   TLS_SAN=192.168.1.10,akk.elx NODE_NAME=elx-akk bash scripts/install-control-plane.sh
#
# Env:
#   TLS_SAN              required — comma-separated IPs/DNS for API cert SANs
#   NODE_NAME            default: $(hostname -s)
#   CACHE_ROOT           default: /cache/columbus
#   INSTALL_K3S_VERSION  optional — pin k3s version (e.g. v1.36.4+k3s1)
#   KUBECONFIG_USER      default: SUDO_USER or the invoking non-root owner

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo)" >&2
  exit 1
fi

TLS_SAN="${TLS_SAN:?set TLS_SAN to the new control-plane LAN IP (and optional DNS names)}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
CACHE_ROOT="${CACHE_ROOT:-/cache/columbus}"

if systemctl is-active --quiet k3s-agent 2>/dev/null; then
  echo "error: k3s-agent is running — uninstall the agent first:" >&2
  echo "  /usr/local/bin/k3s-agent-uninstall.sh" >&2
  exit 1
fi
if systemctl is-active --quiet k3s 2>/dev/null || [[ -d /var/lib/rancher/k3s/server/db ]]; then
  echo "error: k3s server already present on this host; refuse to reinstall" >&2
  echo "  (for migrate: uninstall agent, then install on a clean host; or wipe server dir carefully)" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates

mkdir -p \
  "${CACHE_ROOT}/pnpm-store" \
  "${CACHE_ROOT}/turbo" \
  "${CACHE_ROOT}/bin"
chmod -R 777 "${CACHE_ROOT}"

# Build --tls-san flags (repeatable).
SAN_ARGS=()
IFS=',' read -r -a SANS <<<"${TLS_SAN}"
for san in "${SANS[@]}"; do
  san="$(echo "${san}" | tr -d '[:space:]')"
  [[ -z "${san}" ]] && continue
  SAN_ARGS+=("--tls-san=${san}")
done
if [[ "${#SAN_ARGS[@]}" -eq 0 ]]; then
  echo "error: TLS_SAN produced no SANs" >&2
  exit 1
fi

INSTALL_K3S_EXEC="server --node-name=${NODE_NAME} ${SAN_ARGS[*]}"

echo "→ installing k3s server as ${NODE_NAME}"
echo "   TLS_SAN=${TLS_SAN}"
echo "   INSTALL_K3S_EXEC=${INSTALL_K3S_EXEC}"

INSTALL_ENV=(
  "INSTALL_K3S_EXEC=${INSTALL_K3S_EXEC}"
)
if [[ -n "${INSTALL_K3S_VERSION:-}" ]]; then
  INSTALL_ENV+=("INSTALL_K3S_VERSION=${INSTALL_K3S_VERSION}")
  echo "   INSTALL_K3S_VERSION=${INSTALL_K3S_VERSION}"
fi

curl -sfL https://get.k3s.io | env "${INSTALL_ENV[@]}" sh -

systemctl enable --now k3s
systemctl --no-pager --full status k3s || true

# Kubeconfig for the sudo-invoking user (or KUBECONFIG_USER).
CFG_USER="${KUBECONFIG_USER:-${SUDO_USER:-}}"
if [[ -n "${CFG_USER}" && "${CFG_USER}" != "root" ]]; then
  CFG_HOME="$(getent passwd "${CFG_USER}" | cut -d: -f6)"
  if [[ -n "${CFG_HOME}" && -d "${CFG_HOME}" ]]; then
    mkdir -p "${CFG_HOME}/.kube"
    cp /etc/rancher/k3s/k3s.yaml "${CFG_HOME}/.kube/config"
    chown -R "${CFG_USER}:${CFG_USER}" "${CFG_HOME}/.kube"
    chmod 600 "${CFG_HOME}/.kube/config"
    # Prefer LAN IP in kubeconfig when first SAN looks like an IP.
    FIRST_SAN="$(echo "${SANS[0]}" | tr -d '[:space:]')"
    if [[ "${FIRST_SAN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      sed -i "s#https://127.0.0.1:6443#https://${FIRST_SAN}:6443#g" \
        "${CFG_HOME}/.kube/config"
    fi
    echo "→ wrote ${CFG_HOME}/.kube/config for ${CFG_USER}"
  fi
fi

echo
echo "done. Next for migrate: restore-control-plane.sh with BACKUP_ARCHIVE=…"
echo "  kubectl get nodes -o wide"
echo "  sudo cat /var/lib/rancher/k3s/server/node-token"
