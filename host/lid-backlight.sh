#!/usr/bin/env bash
# Blank or restore the laptop panel backlight based on ACPI lid state.
# Does NOT suspend — pair with HandleLidSwitch=ignore + masked sleep targets.
#
# Env:
#   BACKLIGHT_SYS   optional — e.g. /sys/class/backlight/intel_backlight
#   LID_STATE_FILE  optional — e.g. /proc/acpi/button/lid/LID0/state
#   BRIGHTNESS_ON   optional — restore value when open (default: max_brightness)

set -euo pipefail

find_lid_state() {
  if [[ -n "${LID_STATE_FILE:-}" && -r "${LID_STATE_FILE}" ]]; then
    printf '%s\n' "${LID_STATE_FILE}"
    return 0
  fi
  local f
  for f in /proc/acpi/button/lid/*/state; do
    if [[ -r "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

find_backlight() {
  if [[ -n "${BACKLIGHT_SYS:-}" && -d "${BACKLIGHT_SYS}" ]]; then
    printf '%s\n' "${BACKLIGHT_SYS}"
    return 0
  fi
  local d
  # Prefer intel/amd; skip acpi_video* when a native device exists.
  for d in /sys/class/backlight/*; do
    [[ -d "$d" ]] || continue
    case "$(basename "$d")" in
      acpi_video*) continue ;;
    esac
    if [[ -w "$d/brightness" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  for d in /sys/class/backlight/*; do
    [[ -d "$d" && -w "$d/brightness" ]] || continue
    printf '%s\n' "$d"
    return 0
  done
  return 1
}

LID_FILE="$(find_lid_state)" || {
  echo "lid-backlight: no lid state file; nothing to do" >&2
  exit 0
}
BL="$(find_backlight)" || {
  echo "lid-backlight: no writable backlight; nothing to do" >&2
  exit 0
}

STATE="$(awk '{print $2; exit}' "${LID_FILE}")"
MAX="$(cat "${BL}/max_brightness")"
ON="${BRIGHTNESS_ON:-${MAX}}"

case "${STATE}" in
  closed)
    echo 0 >"${BL}/brightness"
    echo "lid-backlight: lid closed → brightness 0 (${BL})"
    ;;
  open)
    echo "${ON}" >"${BL}/brightness"
    echo "lid-backlight: lid open → brightness ${ON} (${BL})"
    ;;
  *)
    echo "lid-backlight: unknown lid state '${STATE}' in ${LID_FILE}" >&2
    exit 0
    ;;
esac
