#!/usr/bin/env bash
# Install ensure-default-route watchdog (timer + optional path unit).
#
# Usage (as root):
#   IFACE=wlp0s20f0 bash scripts/apply-default-route-guard.sh
#   GATEWAY=192.168.1.1 IFACE=wlp0s12f0 bash scripts/apply-default-route-guard.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(cd "${SCRIPT_DIR}/../host" && pwd)"

IFACE="${IFACE:-}"
GATEWAY="${GATEWAY:-192.168.1.1}"

if [[ -z "$IFACE" ]]; then
  for i in /sys/class/net/*; do
    [[ -d "$i/wireless" ]] || continue
    IFACE="$(basename "$i")"
    break
  done
fi
IFACE="${IFACE:-wlp0s20f3}"

install -m 755 "${HOST_DIR}/ensure-default-route.sh" /usr/local/bin/ensure-default-route.sh
install -m 644 "${HOST_DIR}/ensure-default-route.service" /etc/systemd/system/ensure-default-route.service
install -m 644 "${HOST_DIR}/ensure-default-route.timer" /etc/systemd/system/ensure-default-route.timer

# Path unit is iface-specific — render from template.
sed "s/wlp0s20f3/${IFACE}/g" \
  "${HOST_DIR}/ensure-default-route.path" \
  >/etc/systemd/system/ensure-default-route.path

# Drop-in so the oneshot always uses this iface/gateway.
mkdir -p /etc/systemd/system/ensure-default-route.service.d
cat >/etc/systemd/system/ensure-default-route.service.d/override.conf <<EOF
[Service]
Environment=IFACE=${IFACE}
Environment=GATEWAY=${GATEWAY}
EOF

systemctl daemon-reload
systemctl enable --now ensure-default-route.timer
systemctl enable --now ensure-default-route.path
systemctl start ensure-default-route.service

echo "=== routes ==="
ip route show
echo
echo "=== dns test ==="
getent hosts api.github.com || true
curl -sS -o /dev/null -w "api.github.com → %{http_code}\n" --connect-timeout 8 https://api.github.com/ || true
echo
echo "=== units ==="
systemctl is-enabled ensure-default-route.timer ensure-default-route.path
systemctl --no-pager --full status ensure-default-route.timer ensure-default-route.service | sed -n '1,40p'

echo
echo "done. Watchdog installed for ${IFACE} via ${GATEWAY}."
