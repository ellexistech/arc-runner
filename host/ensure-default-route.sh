#!/usr/bin/env bash
# Restore default route + DNS when Wi‑Fi comes back without a gateway
# (common after lid-close / AP roam: networkd logs
#  "Could not set route: Nexthop has invalid gateway").
#
# Env:
#   IFACE   default: first UP wlan*, else wlp0s20f3
#   GATEWAY default: 192.168.1.1
#   DNS     default: 1.1.1.1 8.8.8.8

set -euo pipefail

GATEWAY="${GATEWAY:-192.168.1.1}"
DNS_SERVERS="${DNS:-1.1.1.1 8.8.8.8}"

detect_iface() {
  local i
  for i in /sys/class/net/*; do
    local name type
    name="$(basename "$i")"
    [[ -d "$i/wireless" ]] || continue
    type="$(cat "$i/operstate" 2>/dev/null || true)"
    if [[ "$type" == "up" ]]; then
      echo "$name"
      return 0
    fi
  done
  echo "wlp0s20f3"
}

IFACE="${IFACE:-$(detect_iface)}"

if [[ ! -d "/sys/class/net/${IFACE}" ]]; then
  echo "ensure-default-route: iface ${IFACE} missing" >&2
  exit 0
fi

oper="$(cat "/sys/class/net/${IFACE}/operstate" 2>/dev/null || echo down)"
if [[ "$oper" != "up" ]]; then
  echo "ensure-default-route: ${IFACE} is ${oper}; skip"
  exit 0
fi

# Prefer an address on this iface before adding a route.
if ! ip -4 -o addr show dev "$IFACE" | grep -q 'inet '; then
  echo "ensure-default-route: ${IFACE} has no IPv4; skip"
  exit 0
fi

if ! ip route show default | grep -q .; then
  echo "ensure-default-route: adding default via ${GATEWAY} dev ${IFACE} onlink"
  ip route replace default via "$GATEWAY" dev "$IFACE" onlink
else
  # If default exists but points nowhere useful, leave it (multi-homed).
  echo "ensure-default-route: default route present: $(ip route show default | tr '\n' ' ')"
fi

# Fix empty uplink DNS (resolvectl shows no servers on wifi after failed configure).
if command -v resolvectl >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  resolvectl dns "$IFACE" $DNS_SERVERS >/dev/null 2>&1 || true
  resolvectl domain "$IFACE" '~.' >/dev/null 2>&1 || true
fi

exit 0
