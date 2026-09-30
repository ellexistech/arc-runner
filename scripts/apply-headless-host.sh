#!/usr/bin/env bash
# Apply headless-laptop host units so lid-close does not sleep, the panel
# backlight blanks when the lid is closed, and Wi‑Fi stays awake. Also ensures
# k3s (server or agent) is enabled on boot.
#
# Usage (as root on the host):
#   bash scripts/apply-headless-host.sh
#   WIFI_IFACE=wlp0s12f0 bash scripts/apply-headless-host.sh
#
# Auto-detects the first managed Wi‑Fi iface via `iw` when WIFI_IFACE unset.
# Lid backlight: skips cleanly if no ACPI lid or writable backlight exists.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(cd "${SCRIPT_DIR}/../host" && pwd)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y iw

detect_wifi() {
  iw dev 2>/dev/null | awk '/Interface/{print $2; exit}'
}

detect_lid_state() {
  local f
  for f in /proc/acpi/button/lid/*/state; do
    if [[ -r "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

WIFI_IFACE="${WIFI_IFACE:-$(detect_wifi)}"
if [[ -z "${WIFI_IFACE}" ]]; then
  echo "error: no Wi‑Fi iface found (set WIFI_IFACE=…)" >&2
  exit 1
fi
echo "→ Wi‑Fi iface: ${WIFI_IFACE}"

mkdir -p /etc/systemd/logind.conf.d
install -m 644 "${HOST_DIR}/99-headless-ci.conf" \
  /etc/systemd/logind.conf.d/99-headless-ci.conf

# Render wifi unit with this host's iface (template uses wlp0s20f3).
tmp="$(mktemp)"
sed "s/wlp0s20f3/${WIFI_IFACE}/g" \
  "${HOST_DIR}/wifi-no-powersave.service" >"${tmp}"
install -m 644 "${tmp}" /etc/systemd/system/wifi-no-powersave.service
rm -f "${tmp}"

# Lid → blank backlight (no sleep). Path unit watches the real ACPI lid file.
install -m 755 "${HOST_DIR}/lid-backlight.sh" /usr/local/bin/lid-backlight.sh
install -m 644 "${HOST_DIR}/lid-backlight.service" /etc/systemd/system/lid-backlight.service
install -m 644 "${HOST_DIR}/lid-backlight.timer" /etc/systemd/system/lid-backlight.timer
LID_STATE="$(detect_lid_state || true)"
if [[ -n "${LID_STATE}" ]]; then
  echo "→ lid state: ${LID_STATE}"
  sed "s|/proc/acpi/button/lid/LID0/state|${LID_STATE}|g" \
    "${HOST_DIR}/lid-backlight.path" \
    >/etc/systemd/system/lid-backlight.path
  ENABLE_LID=1
else
  echo "→ no ACPI lid state file; skipping lid-backlight.path (timer still installed)"
  install -m 644 "${HOST_DIR}/lid-backlight.path" /etc/systemd/system/lid-backlight.path
  ENABLE_LID=0
fi

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl daemon-reload
systemctl restart systemd-logind
systemctl enable --now wifi-no-powersave.service
systemctl enable --now lid-backlight.timer
if [[ "${ENABLE_LID}" -eq 1 ]]; then
  systemctl enable --now lid-backlight.path
fi
systemctl start lid-backlight.service || true

# Prefer agent, else server — whichever this node runs.
if systemctl list-unit-files k3s-agent.service &>/dev/null && \
   systemctl cat k3s-agent.service &>/dev/null; then
  systemctl enable --now k3s-agent.service
  echo "→ k3s-agent enabled"
elif systemctl list-unit-files k3s.service &>/dev/null; then
  systemctl enable --now k3s.service
  echo "→ k3s (server) enabled"
fi

iw dev "${WIFI_IFACE}" set power_save off || true
echo "→ power_save: $(iw dev "${WIFI_IFACE}" get power_save 2>/dev/null || echo unknown)"

echo
echo "=== status ==="
systemctl is-enabled sleep.target suspend.target hibernate.target hybrid-sleep.target || true
systemctl is-enabled wifi-no-powersave.service
systemctl is-enabled lid-backlight.timer
systemctl is-enabled lid-backlight.path 2>/dev/null || echo "lid-backlight.path: not enabled"
systemctl is-enabled k3s-agent.service 2>/dev/null || systemctl is-enabled k3s.service
systemctl --no-pager --full status wifi-no-powersave.service || true
systemctl --no-pager --full status lid-backlight.timer lid-backlight.service || true

echo
echo "done. Lid close keeps the machine awake and blanks the panel backlight; k3s starts on boot."
