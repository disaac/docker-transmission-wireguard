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

DOCKER_DNS_SERVER="${DOCKER_DNS_SERVER:-$(awk '/^nameserver[[:space:]]+127\.0\.0\.11$/ { print $2; exit }' /etc/resolv.conf)}"
DOCKER_DNS_SERVER="${DOCKER_DNS_SERVER:-127.0.0.11}"

# Override DNS to Cloudflare unless SKIP_DNS_OVERRIDE is set to true (case insensitive)
if [ -z "${SKIP_DNS_OVERRIDE}" ] || ! [[ "${SKIP_DNS_OVERRIDE,,}" == "true" ]]; then
  echo "Overriding DNS to Cloudflare"
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
else
  echo "Skipping DNS override due to SKIP_DNS_OVERRIDE=${SKIP_DNS_OVERRIDE}"
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
address=$(python3 /opt/wireguard/get-config-value.py Address "$CONFIG_FILE" | cut -d, -f1 | xargs)
#dns=$(python3 /opt/wireguard/get-config-value.py DNS "$CONFIG_FILE")

ip addr add "$address" dev wg0

stripped_config_file=$(mktemp)
python3 /opt/wireguard/strip-wg-config.py "$CONFIG_FILE" > "$stripped_config_file"

echo "Will use wg config from $stripped_config_file"
wg setconf wg0 "$stripped_config_file"
ip link set wg0 up
#ip link set lo up
ip route add default dev wg0

configure_split_dns() {
  local docker_dns_names="${DOCKER_DNS_NAMES:-}"
  local vpn_dns_servers="${VPN_DNS_SERVERS:-1.1.1.1,1.0.0.1}"
  local split_dns_listen_ip="${SPLIT_DNS_LISTEN_IP:-${VETH_DEFAULT_NS_IP:-127.0.0.1}}"
  local configured_docker_dns_forwarder_ip="${DOCKER_DNS_FORWARDER_IP:-}"
  local docker_dns_forwarder_ip="${configured_docker_dns_forwarder_ip:-${VETH_PHYSICAL_NS_IP:-}}"
  local docker_dns_forwarder_port="${DOCKER_DNS_FORWARDER_PORT:-5353}"
  local start_docker_dns_forwarder="${START_DOCKER_DNS_FORWARDER:-}"
  local split_dns_config="/tmp/dnsmasq-split-dns.conf"
  local docker_dns_config="/tmp/dnsmasq-docker-dns.conf"
  local docker_dns_name
  local vpn_dns_server

  if [[ -z "${docker_dns_names}" ]]; then
    return 0
  fi

  command -v dnsmasq >/dev/null 2>&1 || {
    echo "ERROR: DOCKER_DNS_NAMES requires dnsmasq"
    exit 1
  }

  if [[ -z "${docker_dns_forwarder_ip}" ]]; then
    echo "ERROR: DOCKER_DNS_NAMES requires VETH_PHYSICAL_NS_IP or DOCKER_DNS_FORWARDER_IP"
    exit 1
  fi

  if ! [[ "${docker_dns_forwarder_port}" =~ ^[0-9]+$ ]] || [[ "${docker_dns_forwarder_port}" -lt 1 || "${docker_dns_forwarder_port}" -gt 65535 ]]; then
    echo "ERROR: Invalid DOCKER_DNS_FORWARDER_PORT value: ${docker_dns_forwarder_port}"
    exit 1
  fi

  if [[ -z "${start_docker_dns_forwarder}" ]]; then
    if [[ -n "${configured_docker_dns_forwarder_ip}" ]]; then
      start_docker_dns_forwarder="false"
    else
      start_docker_dns_forwarder="true"
    fi
  fi

  if [[ "${start_docker_dns_forwarder,,}" == "true" ]]; then
    {
      echo "no-resolv"
      echo "bind-interfaces"
      echo "listen-address=${docker_dns_forwarder_ip}"
      echo "port=${docker_dns_forwarder_port}"
      echo "cache-size=0"
      echo "pid-file=/tmp/dnsmasq-docker-dns.pid"
      for docker_dns_name in ${docker_dns_names//,/ }; do
        docker_dns_name="$(echo "${docker_dns_name}" | xargs)"
        if [[ -n "${docker_dns_name}" ]]; then
          echo "server=/${docker_dns_name}/${DOCKER_DNS_SERVER}"
        fi
      done
    } > "${docker_dns_config}"

    echo "Starting Docker DNS forwarder on ${docker_dns_forwarder_ip}:${docker_dns_forwarder_port} for [${docker_dns_names}] via ${DOCKER_DNS_SERVER}"
    ip netns exec physical dnsmasq --conf-file="${docker_dns_config}"
  else
    echo "Using external Docker DNS forwarder at ${docker_dns_forwarder_ip}:${docker_dns_forwarder_port} for [${docker_dns_names}]"
  fi

  {
    echo "no-resolv"
    echo "bind-interfaces"
    echo "listen-address=127.0.0.1"
    echo "listen-address=${split_dns_listen_ip}"
    echo "port=53"
    echo "cache-size=0"
    echo "pid-file=/tmp/dnsmasq-split-dns.pid"
    for vpn_dns_server in ${vpn_dns_servers//,/ }; do
      vpn_dns_server="$(echo "${vpn_dns_server}" | xargs)"
      if [[ -n "${vpn_dns_server}" ]]; then
        echo "server=${vpn_dns_server}"
      fi
    done
    for docker_dns_name in ${docker_dns_names//,/ }; do
      docker_dns_name="$(echo "${docker_dns_name}" | xargs)"
      if [[ -n "${docker_dns_name}" ]]; then
        echo "server=/${docker_dns_name}/${docker_dns_forwarder_ip}#${docker_dns_forwarder_port}"
      fi
    done
  } > "${split_dns_config}"

  echo "Starting split DNS on ${split_dns_listen_ip}. Docker names [${docker_dns_names}] resolve via ${docker_dns_forwarder_ip}:${docker_dns_forwarder_port}; other DNS uses [${vpn_dns_servers}]"
  dnsmasq --conf-file="${split_dns_config}"
  {
    echo "nameserver ${split_dns_listen_ip}"
    echo "options ndots:0"
  } > /etc/resolv.conf
}

configure_docker_name_proxies() {
  local proxy_targets="${DOCKER_NAME_PROXY_TARGETS:-}"
  local proxy_resolver="${DOCKER_NAME_PROXY_RESOLVER:-127.0.0.1}"
  local proxy_config="/tmp/nginx-docker-name-proxy.conf"
  local proxy_target
  local proxy_name
  local target_port
  local listen_port

  if [[ -z "${proxy_targets}" ]]; then
    return 0
  fi

  command -v nginx >/dev/null 2>&1 || {
    echo "ERROR: DOCKER_NAME_PROXY_TARGETS requires nginx"
    exit 1
  }

  {
    echo "pid /tmp/nginx-docker-name-proxy.pid;"
    echo "events { worker_connections 256; }"
    echo "http {"
    echo "  resolver ${proxy_resolver} valid=10s ipv6=off;"
    for proxy_target in ${proxy_targets//,/ }; do
      proxy_target="$(echo "${proxy_target}" | xargs)"
      if [[ -z "${proxy_target}" ]]; then
        continue
      fi

      IFS=':' read -r proxy_name target_port listen_port <<< "${proxy_target}"
      if [[ -z "${proxy_name}" || -z "${target_port}" || -z "${listen_port}" ]]; then
        echo "ERROR: Invalid DOCKER_NAME_PROXY_TARGETS value '${proxy_target}'. Expected name:target_port:listen_port"
        exit 1
      fi

      if ! [[ "${target_port}" =~ ^[0-9]+$ ]] || [[ "${target_port}" -lt 1 || "${target_port}" -gt 65535 ]]; then
        echo "ERROR: Invalid target port in DOCKER_NAME_PROXY_TARGETS value: ${proxy_target}"
        exit 1
      fi

      if ! [[ "${listen_port}" =~ ^[0-9]+$ ]] || [[ "${listen_port}" -lt 1 || "${listen_port}" -gt 65535 ]]; then
        echo "ERROR: Invalid listen port in DOCKER_NAME_PROXY_TARGETS value: ${proxy_target}"
        exit 1
      fi

      echo "  server {"
      echo "    listen 127.0.0.1:${listen_port};"
      echo "    set \$docker_name_upstream ${proxy_name}:${target_port};"
      echo "    location / {"
      echo "      proxy_pass http://\$docker_name_upstream;"
      echo "      proxy_set_header Host ${proxy_name};"
      echo "      proxy_set_header X-Real-IP \$remote_addr;"
      echo "      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
      echo "      proxy_set_header X-Forwarded-Proto \$scheme;"
      echo "      proxy_http_version 1.1;"
      echo "      proxy_set_header Connection \"\";"
      echo "    }"
      echo "  }"
    done
    echo "}"
  } > "${proxy_config}"

  echo "Starting Docker-name proxy for [${proxy_targets}] using resolver ${proxy_resolver}"
  nginx -c "${proxy_config}"
}

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
ip -n physical link set lo up

configure_split_dns
configure_docker_name_proxies

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
