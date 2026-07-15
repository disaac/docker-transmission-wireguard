#!/bin/bash

set -Ee

truthy() {
  case "${1,,}" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

fail() {
  echo "$*" >&2
  exit 1
}

require_positive_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1 ]]; then
    fail "${name} must be a positive integer; got '${value}'"
  fi
}

print_monitor_summary() {
  local status_file="$1"

  jq -r '
    "wireguard_monitor: enabled=\(.wireguard_monitor.enabled) permanently_unhealthy=\(.wireguard_monitor.permanently_unhealthy) consecutive_failed_health_checks=\(.wireguard_monitor.consecutive_failed_health_checks) recovery_attempts_before_unhealthy=\(.wireguard_monitor.recovery_attempts_before_unhealthy) last_error=\(.wireguard_monitor.last_error // "none")"
  ' "${status_file}" >&2
}

check_piawgc_health() {
  local pid_file="${PIAWGC_PID_FILE:-/tmp/piawgc.pid}"
  local status_file="${PIAWGC_PIA_STATUS_FILE:-/tmp/piawgc-status.json}"
  local wait_seconds="${PIAWGC_STATUS_WAIT_SECONDS:-10}"
  local pid
  local waited=0

  command -v jq >/dev/null 2>&1 || fail "jq is required for piawgc health checks"
  require_positive_integer PIAWGC_STATUS_WAIT_SECONDS "${wait_seconds}"

  [[ -s "${pid_file}" ]] || fail "piawgc PID file is missing or empty: ${pid_file}"
  pid="$(<"${pid_file}")"
  pid="${pid//[[:space:]]/}"
  [[ "${pid}" =~ ^[0-9]+$ ]] || fail "piawgc PID file does not contain a numeric PID: ${pid_file}"

  kill -0 "${pid}" 2>/dev/null || fail "piawgc process ${pid} is not running"

  rm -f "${status_file}"
  kill -USR1 "${pid}" 2>/dev/null || fail "could not request piawgc health JSON from process ${pid}"

  while [[ "${waited}" -lt "${wait_seconds}" ]]; do
    if [[ -s "${status_file}" ]]; then
      break
    fi

    sleep 1
    waited=$((waited + 1))
  done

  [[ -s "${status_file}" ]] || fail "timed out waiting ${wait_seconds}s for piawgc health JSON at ${status_file}"

  jq -e . "${status_file}" >/dev/null 2>&1 || fail "piawgc health JSON is invalid: ${status_file}"
  jq -e '.wireguard_monitor.enabled == true' "${status_file}" >/dev/null 2>&1 || {
    print_monitor_summary "${status_file}"
    fail "piawgc WireGuard monitor is not enabled"
  }

  if jq -e '.wireguard_monitor.permanently_unhealthy == true' "${status_file}" >/dev/null 2>&1; then
    print_monitor_summary "${status_file}"
    fail "piawgc WireGuard monitor reports permanently unhealthy"
  fi
}

if truthy "${PIA_USE_PIAWGC:-}"; then
  check_piawgc_health
fi

exit 0
