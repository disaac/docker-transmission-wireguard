#!/bin/bash

set -Eeuo pipefail

log() {
  echo "[pia-port-forwarding] $*"
}

run_port_forwarding_cycle() {
  get_pia_token || return 1
  get_signature || return 1
  bind_port || return 1
  update_transmission_port || return 1
}

setting_value() {
  local setting="$1"
  jq -r --arg setting "$setting" '.[$setting] // empty' "$transmission_settings_file"
}

credential_value() {
  local env_value="$1"
  local line_number="$2"

  if [[ -n "$env_value" ]]; then
    echo "$env_value"
    return
  fi

  if [[ -n "${PIA_CREDENTIALS_FILE:-}" && -f "$PIA_CREDENTIALS_FILE" ]]; then
    sed -n "${line_number}p" "$PIA_CREDENTIALS_FILE"
    return
  fi

  if [[ -f /config/pia-credentials.txt ]]; then
    sed -n "${line_number}p" /config/pia-credentials.txt
    return
  fi

  if [[ -f /config/openvpn-credentials.txt ]]; then
    sed -n "${line_number}p" /config/openvpn-credentials.txt
    return
  fi
}

endpoint_host_from_config() {
  local endpoint
  endpoint="$(python3 /opt/wireguard/get-config-value.py Endpoint "$CONFIG_FILE")"
  endpoint="${endpoint%%,*}"

  if [[ "$endpoint" =~ ^\[([^]]+)\]:(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  echo "${endpoint%:*}"
}

get_pia_token() {
  if [[ -n "${PIA_TOKEN:-}" ]]; then
    pia_token="$PIA_TOKEN"
    return
  fi

  local username password response
  username="$(credential_value "${PIA_USERNAME:-${PIA_USER:-${OPENVPN_USERNAME:-}}}" 1)"
  password="$(credential_value "${PIA_PASSWORD:-${PIA_PASS:-${OPENVPN_PASSWORD:-}}}" 2)"

  if [[ -z "$username" || -z "$password" ]]; then
    log "PIA credentials are required. Set PIA_TOKEN, PIA_USERNAME/PIA_PASSWORD, or mount /config/pia-credentials.txt."
    return 1
  fi

  log "Requesting PIA auth token"
  response="$(curl --silent --show-error --fail \
    --request POST \
    --max-time "$curl_max_time" \
    --user "$username:$password" \
    "https://www.privateinternetaccess.com/gtoken/generateToken")" || return 1

  pia_token="$(echo "$response" | jq -er '.token')" || return 1
}

get_signature() {
  local response decoded_payload

  if [[ -z "${pia_token:-}" ]]; then
    log "PIA token is not available yet"
    return 1
  fi

  log "Requesting forwarded port signature from ${pf_gateway}"
  response="$(curl --insecure --get --silent --show-error --fail \
    --retry "$curl_retry" \
    --retry-delay "$curl_retry_delay" \
    --max-time "$curl_max_time" \
    --data-urlencode "token=${pia_token}" \
    "https://${pf_gateway}:19999/getSignature")" || return 1

  if [[ "$(echo "$response" | jq -r '.status')" != "OK" ]]; then
    log "PIA getSignature returned an error: $response"
    return 1
  fi

  pf_payload="$(echo "$response" | jq -er '.payload')" || return 1
  pf_signature="$(echo "$response" | jq -er '.signature')" || return 1
  decoded_payload="$(echo "$pf_payload" | base64 -d)" || return 1
  pf_port="$(echo "$decoded_payload" | jq -er '.port')" || return 1
  pf_expires_at="$(echo "$decoded_payload" | jq -er '.expires_at')" || return 1

  if ! pf_expires_epoch="$(date -d "$pf_expires_at" +%s 2>/dev/null)"; then
    log "Could not parse PIA port expiration date: ${pf_expires_at}"
    pf_expires_epoch=0
  fi
}

bind_port() {
  local response

  if [[ -z "${pf_payload:-}" || -z "${pf_signature:-}" ]]; then
    log "PIA port forwarding payload/signature is not available yet"
    return 1
  fi

  response="$(curl --insecure --get --silent --show-error --fail \
    --retry "$curl_retry" \
    --retry-delay "$curl_retry_delay" \
    --max-time "$curl_max_time" \
    --data-urlencode "payload=${pf_payload}" \
    --data-urlencode "signature=${pf_signature}" \
    "https://${pf_gateway}:19999/bindPort")" || return 1

  if [[ "$(echo "$response" | jq -r '.status')" != "OK" ]]; then
    log "PIA bindPort returned an error: $response"
    return 1
  fi

  log "Bound forwarded port ${pf_port}; expires at ${pf_expires_at}"
}

transmission_auth_args() {
  local auth_required username password
  auth_required="$(setting_value "rpc-authentication-required")"

  if [[ "$auth_required" == "true" ]]; then
    username="${TRANSMISSION_RPC_USERNAME:-$(setting_value "rpc-username")}"
    password="${TRANSMISSION_RPC_PASSWORD:-$(setting_value "rpc-password")}"

    if [[ "$password" == \{* ]]; then
      log "Transmission RPC password in settings.json is hashed; set TRANSMISSION_RPC_PASSWORD for port forwarding."
      exit 1
    fi

    transmission_remote_auth_args=(--auth "${username}:${password}")
  else
    transmission_remote_auth_args=()
  fi
}

wait_for_transmission() {
  local rpc_port rpc_url
  rpc_port="${TRANSMISSION_RPC_PORT:-$(setting_value "rpc-port")}"
  rpc_url="${TRANSMISSION_RPC_URL:-$(setting_value "rpc-url")}"
  rpc_url="${rpc_url%/}"
  transmission_rpc_host="http://localhost:${rpc_port}${rpc_url}"

  transmission_auth_args

  log "Waiting for Transmission RPC at ${transmission_rpc_host}"
  until transmission-remote "$transmission_rpc_host" "${transmission_remote_auth_args[@]}" -l >/dev/null 2>&1; do
    sleep 10
  done
}

update_transmission_port() {
  local current_port

  if [[ -z "${pf_port:-}" ]]; then
    log "PIA forwarded port is not available yet"
    return 1
  fi

  wait_for_transmission

  current_port="$(transmission-remote "$transmission_rpc_host" "${transmission_remote_auth_args[@]}" -si \
    | awk -F: '/Listenport/ {gsub(/ /, "", $2); print $2; exit}')"

  if [[ "$current_port" == "$pf_port" ]]; then
    log "Transmission already uses peer port ${pf_port}"
    return
  fi

  log "Setting Transmission peer port to ${pf_port}"
  transmission-remote "$transmission_rpc_host" "${transmission_remote_auth_args[@]}" -p "$pf_port" >/dev/null
  transmission-remote "$transmission_rpc_host" "${transmission_remote_auth_args[@]}" -pt || true
}

curl_max_time="${PIA_PF_CURL_MAX_TIME:-15}"
curl_retry="${PIA_PF_CURL_RETRY:-5}"
curl_retry_delay="${PIA_PF_CURL_RETRY_DELAY:-15}"
refresh_seconds="${PIA_PF_REFRESH_SECONDS:-900}"
renew_before_seconds="${PIA_PF_RENEW_BEFORE_SECONDS:-604800}"
transmission_settings_file="${TRANSMISSION_HOME}/settings.json"
transmission_remote_auth_args=()

pf_gateway="${PIA_PF_GATEWAY:-${PF_GATEWAY:-}}"
if [[ -z "$pf_gateway" ]]; then
  pf_gateway="$(endpoint_host_from_config)"
fi

if [[ -z "$pf_gateway" ]]; then
  log "Could not determine PIA port forwarding gateway. Set PIA_PF_GATEWAY or ensure CONFIG_FILE has Endpoint."
  exit 0
fi

if [[ ! -f "$transmission_settings_file" ]]; then
  log "Transmission settings file does not exist: ${transmission_settings_file}"
  exit 0
fi

until run_port_forwarding_cycle; do
  log "PIA port forwarding setup failed; retrying in ${refresh_seconds}s"
  sleep "$refresh_seconds"
done

while true; do
  sleep "$refresh_seconds"

  now="$(date +%s)"
  remaining_seconds=$((pf_expires_epoch - now))

  if [[ "$pf_expires_epoch" -eq 0 || "$remaining_seconds" -lt "$renew_before_seconds" ]]; then
    log "Forwarded port reservation is nearing expiration; requesting a new reservation"
    run_port_forwarding_cycle || log "PIA port forwarding renewal failed; will retry on next refresh"
    continue
  fi

  bind_port || log "PIA port forwarding bind refresh failed; will retry on next refresh"
done
