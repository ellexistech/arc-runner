#!/usr/bin/env bash
# Join a host as a k3s agent (worker) for the ARC builder cluster.
#
# Designed for a small node (e.g. 4GB RAM) that should only fit ~1 DinD
# runner at a time: reserves kube/system memory so allocatable ≈ 2Gi.
#
# Usage (on the new host, with sudo):
#   K3S_URL=https://192.168.1.9:6443 \
#   K3S_TOKEN='…' \
#   bash scripts/join-agent.sh
#
# Or from a workstation:
#   ssh zee.elx 'sudo bash -s' < scripts/join-agent.sh
#   (export K3S_URL / K3S_TOKEN in the remote env first)
#
# Env:
#   K3S_URL              required — control-plane URL (https://SERVER:6443)
#   K3S_TOKEN            required — contents of /var/lib/rancher/k3s/server/node-token
#   NODE_NAME            default: $(hostname -s)
#   CACHE_ROOT           default: /cache/columbus
#   KUBE_RESERVED_MEM    default: 1Gi
#   SYSTEM_RESERVED_MEM  default: 512Mi

set -euo pipefail

K3S_URL="${K3S_URL:?set K3S_URL to https://<control-plane>:6443}"
K3S_TOKEN="${K3S_TOKEN:?set K3S_TOKEN from the control-plane node-token}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
CACHE_ROOT="${CACHE_ROOT:-/cache/columbus}"
KUBE_RESERVED_MEM="${KUBE_RESERVED_MEM:-1Gi}"
SYSTEM_RESERVED_MEM="${SYSTEM_RESERVED_MEM:-512Mi}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo)" >&2
  exit 1
fi

if systemctl is-active --quiet k3s 2>/dev/null; then
  echo "error: k3s server is already running on this host; refuse to install agent" >&2
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

# Reserve enough RAM that only one ~1Gi-request runner (+ DinD) fits on a 4GB box.
INSTALL_K3S_EXEC="agent \
  --node-name=${NODE_NAME} \
  --kubelet-arg=kube-reserved=memory=${KUBE_RESERVED_MEM} \
  --kubelet-arg=system-reserved=memory=${SYSTEM_RESERVED_MEM} \
  --kubelet-arg=eviction-hard=memory.available<100Mi"

echo "→ installing k3s agent as ${NODE_NAME}"
echo "   K3S_URL=${K3S_URL}"
echo "   kube-reserved=${KUBE_RESERVED_MEM} system-reserved=${SYSTEM_RESERVED_MEM}"

curl -sfL https://get.k3s.io | \
  K3S_URL="${K3S_URL}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC}" \
  sh -

systemctl enable --now k3s-agent
systemctl --no-pager --full status k3s-agent || true

echo
echo "done. On the control plane:"
echo "  kubectl get nodes -o wide"
echo "  kubectl label node ${NODE_NAME} arc.ellexis.io/capacity=small --overwrite"
echo "  kubectl describe node ${NODE_NAME} | grep -A6 Allocatable"
