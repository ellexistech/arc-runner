#!/usr/bin/env bash
# Point an existing k3s agent at a new control-plane URL (same cluster token
# after a SQLite migrate that restored server/token).
#
# Usage (as root on the agent):
#   K3S_URL=https://192.168.1.10:6443 bash scripts/repoint-agent.sh
#   K3S_URL=https://192.168.1.10:6443 K3S_TOKEN='…' bash scripts/repoint-agent.sh
#
# Env:
#   K3S_URL     required — new https://IP:6443
#   K3S_TOKEN   optional — only if the cluster token changed
#   ENV_FILE    default: /etc/systemd/system/k3s-agent.service.env

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo)" >&2
  exit 1
fi

K3S_URL="${K3S_URL:?set K3S_URL to https://<new-control-plane>:6443}"
ENV_FILE="${ENV_FILE:-/etc/systemd/system/k3s-agent.service.env}"

if ! systemctl list-unit-files k3s-agent.service 2>/dev/null | grep -q k3s-agent.service; then
  echo "error: k3s-agent.service not installed on this host" >&2
  exit 1
fi
if systemctl is-active --quiet k3s 2>/dev/null; then
  echo "error: k3s server is active here — refuse to repoint as agent" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: env file missing: ${ENV_FILE}" >&2
  echo "  (re-join with join-agent.sh instead)" >&2
  exit 1
fi

echo "→ updating ${ENV_FILE}"
echo "   K3S_URL=${K3S_URL}"

# Preserve other lines; replace or append K3S_URL / optional K3S_TOKEN.
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

awk -v url="${K3S_URL}" -v tok="${K3S_TOKEN:-}" '
  BEGIN { u=0; t=0 }
  /^K3S_URL=/ { print "K3S_URL=" url; u=1; next }
  /^K3S_TOKEN=/ {
    if (tok != "") { print "K3S_TOKEN=" tok; t=1 }
    else { print; t=1 }
    next
  }
  { print }
  END {
    if (!u) print "K3S_URL=" url
    if (tok != "" && !t) print "K3S_TOKEN=" tok
  }
' "${ENV_FILE}" >"${tmp}"
chmod --reference="${ENV_FILE}" "${tmp}" 2>/dev/null || chmod 600 "${tmp}"
mv "${tmp}" "${ENV_FILE}"
trap - EXIT

systemctl daemon-reload
echo "→ restarting k3s-agent…"
systemctl restart k3s-agent
sleep 2
systemctl --no-pager --full status k3s-agent || true

echo
echo "done. On the control plane:"
echo "  kubectl get nodes -o wide"
echo "  journalctl -u k3s-agent -e   # on this host if NotReady"
