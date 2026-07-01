#! /bin/bash

# Exit on error
set -Ee

trap 'rc=$?; echo "ERROR: command failed at line ${LINENO}: ${BASH_COMMAND}"; echo "Network namespaces:"; ip netns ls || true; echo "Default namespace links:"; ip -brief link || true; if ip netns ls | grep -q "^physical"; then echo "Physical namespace links:"; ip -n physical -brief link || true; fi; exit "$rc"' ERR

if [[ -n "$REVISION" ]]; then
  echo "Image revision: $REVISION"
fi

echo "Current public IP is:"
curl --silent --max-time 15 -w "\n" ipecho.net/plain || echo "Public IP check failed before WireGuard setup"

if ip netns ls | grep -q "physical"
then
    # Dangling network from previous run, clean up
    echo "Clean up dangling network namespaces"
    ip -all netns delete || echo "Dangling namespace cleanup reported errors; continuing startup"
fi

# Grab information from the default interface set up in the container
GW=$(/sbin/ip route list match 0.0.0.0 | awk '{print $3}')
INT=$(/sbin/ip route list match 0.0.0.0 | awk '{print $5}')
INT_IP=$(ip -f inet addr show "$INT" | awk '/inet / {print $2}')
# Broadcast may be absent (e.g. /32). Only pass brd when `ip addr` showed one, we want to mirror the original
INT_BRD=$(ip -f inet addr show "$INT" | awk '/inet / {if ($3 == "brd") print $4}')

echo "Found default container interface, will use this in setup:"
echo "Interface: $INT"
echo "Gateway: $GW"
echo "Interface address: $INT_IP"
echo "Interface broadcast: $INT_BRD"

# Resolve WireGuard Endpoint hostnames to IPs while eth0 is still in this namespace
# (uses dig @WG_BOOTSTRAP_DNS, default 1.1.1.1 — not Docker's 127.0.0.11).
RESOLVED_CONFIG="$(mktemp)"
trap 'rm -f "$RESOLVED_CONFIG"' EXIT
python3 /opt/wireguard/resolve-wg-endpoints.py "$CONFIG_FILE" "$RESOLVED_CONFIG"

# Override DNS to Cloudflare unless ACCEPT_DNS_PRIVACY_LOSS is set to true (case insensitive).
# If set, Docker's resolver (often 127.0.0.11) may bypass the WireGuard tunnel for DNS.
if [ -z "${ACCEPT_DNS_PRIVACY_LOSS}" ] || ! [[ "${ACCEPT_DNS_PRIVACY_LOSS,,}" == "true" ]]; then
  echo "Overriding DNS to Cloudflare"
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
else
  echo "ACCEPT_DNS_PRIVACY_LOSS=true: not overriding /etc/resolv.conf; DNS queries may not use the WireGuard tunnel."
fi

echo "DNS config:"
cat /etc/resolv.conf

# Create a "physical" network namespace and move our eth0 there
ip netns ls
ip netns add physical
ip link set "$INT" netns physical

# Create wireguard interface in physical namespace and move it to the default namespace
ip -n physical link add wg0 type wireguard
ip -n physical link set wg0 netns 1

# Restore IP and route configuration for the default interface, start it
if [ -n "$INT_BRD" ]; then
  ip -n physical addr add "$INT_IP" dev "$INT" brd "$INT_BRD"
else
  ip -n physical addr add "$INT_IP" dev "$INT"
fi
ip -n physical link set "$INT" up
#ip -n physical link set lo up
if ! ip -n physical route add default via "$GW" dev "$INT"; then
  echo "Default route via $GW was not accepted as on-link, retrying with onlink"
  ip -n physical route add default via "$GW" dev "$INT" onlink
fi

#
# Setting up Wireguard
# We need to make the wg0 interface separately to do the namespace linking
# and we can't use wg-quick after that. So the rest is done "manually".
#

# Get the Address from the config file. For now: Only keep the first address (typically the IPv4 address)
address=$(python3 /opt/wireguard/get-config-value.py Address "$RESOLVED_CONFIG" | cut -d, -f1 | xargs)
#dns=$(python3 /opt/wireguard/get-config-value.py DNS "$RESOLVED_CONFIG")

ip addr add "$address" dev wg0

stripped_config_file=$(mktemp)
python3 /opt/wireguard/strip-wg-config.py "$RESOLVED_CONFIG" > "$stripped_config_file"

echo "Will use wg config from $stripped_config_file"
wg setconf wg0 "$stripped_config_file"
ip link set wg0 up
#ip link set lo up
ip route add default dev wg0

#
# Wireguard interface is now set up and should be connected
#
echo "Wireguard is up - new IP:"
curl --silent --max-time 15 -w "\n" ipecho.net/plain || echo "Public IP check failed after WireGuard setup; continuing startup"
wg show || true

# Create a veth link pair, one interface in each namespace
echo "Creating veth pair for physical namespace proxying"
ip link add veth1 type veth peer name veth2
echo "Moving veth2 into physical namespace"
ip link set veth2 netns physical

# Set their IPs, CIDR with only two addresses to limit ip route ranges
echo "Assigning veth addresses"
VETH_DEFAULT_NS_IP="${VETH_DEFAULT_NS_IP:-10.10.13.36}"
VETH_PHYSICAL_NS_IP="${VETH_PHYSICAL_NS_IP:-10.10.13.37}"
VETH_CIDR="${VETH_CIDR:-31}"
export VETH_DEFAULT_NS_IP VETH_PHYSICAL_NS_IP VETH_CIDR
ip addr add "${VETH_DEFAULT_NS_IP}/${VETH_CIDR}" dev veth1
ip -n physical addr add "${VETH_PHYSICAL_NS_IP}/${VETH_CIDR}" dev veth2

# Start the veth interfaces
echo "Starting veth interfaces"
ip link set veth1 up
ip -n physical link set veth2 up

configure_local_network_access() {
  local local_networks="${LOCAL_NETWORK:-}"
  local local_ports="${LOCAL_NETWORK_PORTS:-}"
  local veth_dev="${LOCAL_NETWORK_DEV:-veth1}"
  local veth_gateway="${LOCAL_NETWORK_GATEWAY:-${VETH_PHYSICAL_NS_IP}}"
  local veth_source="${LOCAL_NETWORK_SOURCE:-${VETH_DEFAULT_NS_IP}}"
  local physical_namespace="${LOCAL_NETWORK_NAMESPACE:-physical}"
  local local_net
  local local_port
  local local_network_ports=()
  local local_network_chain="LOCAL_NETWORK_OUT"
  local allow_all_ports=true

  if [[ -z "${local_networks}" ]]; then
    return 0
  fi

  if [[ -n "${local_ports}" ]]; then
    allow_all_ports=false
    for local_port in ${local_ports//,/ }; do
      local_port="$(echo "${local_port}" | xargs)"
      if [[ -z "${local_port}" ]]; then
        continue
      fi

      if ! [[ "${local_port}" =~ ^[0-9]+$ ]] || [[ "${local_port}" -lt 1 || "${local_port}" -gt 65535 ]]; then
        echo "ERROR: Invalid LOCAL_NETWORK_PORTS value: ${local_port}"
        exit 1
      fi

      local_network_ports+=("${local_port}")
    done

    if [[ "${#local_network_ports[@]}" -eq 0 ]]; then
      echo "ERROR: LOCAL_NETWORK_PORTS was set but no valid ports were provided"
      exit 1
    fi

    iptables -N "${local_network_chain}" 2>/dev/null || true
    iptables -F "${local_network_chain}"
    for local_port in "${local_network_ports[@]}"; do
      iptables -A "${local_network_chain}" -p tcp --dport "${local_port}" -j ACCEPT
    done
    iptables -A "${local_network_chain}" -j REJECT
  fi

  ip netns exec "${physical_namespace}" sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

  for local_net in ${local_networks//,/ }; do
    local_net="$(echo "${local_net}" | xargs)"
    if [[ -z "${local_net}" ]]; then
      continue
    fi

    if ! python3 - "${local_net}" <<'PY'; then
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError as exc:
    print(f"ERROR: Invalid LOCAL_NETWORK value '{sys.argv[1]}': {exc}", file=sys.stderr)
    sys.exit(1)

if network.prefixlen == 0:
    print("ERROR: LOCAL_NETWORK must not be a default route", file=sys.stderr)
    sys.exit(1)

if network.version != 4:
    print("ERROR: LOCAL_NETWORK currently supports IPv4 networks only", file=sys.stderr)
    sys.exit(1)

if not (network.is_private or network.is_loopback or network.is_link_local):
    print(f"ERROR: LOCAL_NETWORK must be private, loopback, or link-local; got '{network}'", file=sys.stderr)
    sys.exit(1)
PY
      exit 1
    fi

    echo "Adding route to local network ${local_net} via ${veth_gateway} dev ${veth_dev}"
    ip route replace "${local_net}" via "${veth_gateway}" dev "${veth_dev}"

    if [[ "${allow_all_ports}" == "true" ]]; then
      iptables -C OUTPUT -o "${veth_dev}" -d "${local_net}" -j ACCEPT 2>/dev/null \
        || iptables -I OUTPUT 1 -o "${veth_dev}" -d "${local_net}" -j ACCEPT

      ip netns exec "${physical_namespace}" iptables -t nat -C POSTROUTING \
        -s "${veth_source}/32" \
        -d "${local_net}" \
        -j MASQUERADE 2>/dev/null \
        || ip netns exec "${physical_namespace}" iptables -t nat -A POSTROUTING \
          -s "${veth_source}/32" \
          -d "${local_net}" \
          -j MASQUERADE
    else
      iptables -C OUTPUT -o "${veth_dev}" -d "${local_net}" -j "${local_network_chain}" 2>/dev/null \
        || iptables -I OUTPUT 1 -o "${veth_dev}" -d "${local_net}" -j "${local_network_chain}"

      for local_port in "${local_network_ports[@]}"; do
        ip netns exec "${physical_namespace}" iptables -t nat -C POSTROUTING \
          -s "${veth_source}/32" \
          -d "${local_net}" \
          -p tcp \
          --dport "${local_port}" \
          -j MASQUERADE 2>/dev/null \
          || ip netns exec "${physical_namespace}" iptables -t nat -A POSTROUTING \
            -s "${veth_source}/32" \
            -d "${local_net}" \
            -p tcp \
            --dport "${local_port}" \
            -j MASQUERADE
      done
    fi
  done
}

configure_local_network_access

if [[ "${WEBPROXY_ENABLED,,}" == "true" ]]; then
  WEBPROXY_PORT="${WEBPROXY_PORT:-8118}"
  WEBPROXY_BIND_ADDRESS="${WEBPROXY_BIND_ADDRESS:-0.0.0.0}"

  echo "Starting web proxy (Privoxy) on ${WEBPROXY_BIND_ADDRESS}:${WEBPROXY_PORT}"

  # Remove all listen-address lines and add exactly one with the correct address/port
  sed -i '/^listen-address /d' /etc/privoxy/config
  echo "listen-address ${WEBPROXY_BIND_ADDRESS}:${WEBPROXY_PORT}" >> /etc/privoxy/config

  # Start Privoxy in the current (wg0) namespace so traffic routes through WireGuard
  privoxy /etc/privoxy/config
fi

stream_proxy_ports=()
if [[ "${WEBPROXY_ENABLED,,}" == "true" ]]; then
  stream_proxy_ports+=("${WEBPROXY_PORT}")
fi

if [[ -n "${HOST_FORWARD_PORTS}" ]]; then
  IFS=',' read -ra configured_ports <<< "${HOST_FORWARD_PORTS}"
  for configured_port in "${configured_ports[@]}"; do
    configured_port="$(echo "${configured_port}" | xargs)"
    if [[ -n "${configured_port}" ]]; then
      stream_proxy_ports+=("${configured_port}")
    fi
  done
fi

if [[ "${#stream_proxy_ports[@]}" -gt 0 ]]; then
  # Activate the stream module and proxy configured TCP ports via nginx.
  cp /opt/nginx/templates/stream_module.conf /opt/nginx/main.d/stream_module.conf
  {
    echo "stream {"
    for stream_proxy_port in $(printf '%s\n' "${stream_proxy_ports[@]}" | awk '!seen[$0]++'); do
      if ! [[ "${stream_proxy_port}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid HOST_FORWARD_PORTS value: ${stream_proxy_port}"
        exit 1
      fi

      echo "  server {"
      echo "    listen ${stream_proxy_port};"
      echo "    proxy_pass ${VETH_DEFAULT_NS_IP}:${stream_proxy_port};"
      echo "  }"
    done
    echo "}"
  } > /opt/nginx/stream.d/stream.conf
fi

# Start a reverse proxy in the physical namespace
envsubst '${VETH_DEFAULT_NS_IP}' < /opt/nginx/server.conf > /opt/nginx/server.generated.conf
ip netns exec physical nginx -c /opt/nginx/server.generated.conf

# Set TRANSMISSION_WEB_HOME if user has selected an alternative web UI
if [[ -n "$TRANSMISSION_WEB_UI" ]]; then
  case "$TRANSMISSION_WEB_UI" in
    combustion)        ui_dir="combustion-release" ;;
    kettu)             ui_dir="kettu" ;;
    flood-for-transmission) ui_dir="flood-for-transmission" ;;
    shift)             ui_dir="shift" ;;
    transmissionic)    ui_dir="transmissionic" ;;
    transmission-web-control) ui_dir="transmission-web-control" ;;
    *)
      echo "ERROR: Unknown TRANSMISSION_WEB_UI value: $TRANSMISSION_WEB_UI"
      echo "Valid options: combustion, kettu, flood-for-transmission, shift, transmissionic, transmission-web-control"
      exit 1
      ;;
  esac

  export TRANSMISSION_WEB_HOME="/opt/transmission-ui/${ui_dir}"
  echo "Using alternative Transmission UI: $TRANSMISSION_WEB_UI (from $TRANSMISSION_WEB_HOME)"
fi

# Make sure TRANSMISSION_HOME exists and create/update settings.json
mkdir -p "$TRANSMISSION_HOME"
python3 /opt/transmission/updateSettings.py /opt/transmission/default-settings.json ${TRANSMISSION_HOME}/settings.json || exit 1

# Support running Transmission as non-root (and set permissions on folders)
. /opt/transmission/userSetup.sh

if [[ "${PIA_PORT_FORWARDING,,}" == "true" || "${PIA_PF,,}" == "true" ]]; then
  echo "Starting PIA port forwarding helper"
  bash /opt/wireguard/pia-port-forwarding.sh &
fi

exec su --preserve-environment ${RUN_AS} -s /bin/bash -c "/usr/bin/transmission-daemon --foreground -g ${TRANSMISSION_HOME}"
