# Wireguard and Transmission with WebUI

This project creates a Docker image that bundles Wireguard and Transmission.
It sets up networking in a way that ensures Transmission traffic is always routed through the VPN.

## Work in progress

This image is under construction. Breaking changes might occur without warning!

If you're already running an instance of `haugene/transmission-openvpn`, _I would not recommend_
swapping your installation for this image just yet. Please test it and report any issues.

## Quick start

The new image differs a bit from the old, and I'll hopefully get to document that better soon.
But from the "getting it to run" perspective, the first things that come to mind are:

* You need to mount a config file
* It requires running in privileged mode

This might change, but this is how it's running now.

I've also changed the Transmission settings handling a bit. The container will still accept
environment variables, but defaults are read from a file. This is to de-clutter the Dockerfile a bit.
There are still a handful of default settings being set as ENV variables in the Dockerfile to
get the PUID/PGID working like it used to. I'll try to clean up that as well.

If you're already running the old image, I'd recommend setting the ports option to: `- 9092:9091`.
That way you'll map it to port 9092 locally and you can have them both running at the same time.


### Example Docker Compose file:
```yaml
services:
  transmission-wireguard:
    # No versioned tags yet, pulling latest build from the main branch.
    image: haugene/transmission-wireguard:main
    container_name: wg-main
    privileged: true
    ports:
      - 9091:9091
    volumes:
      - /your/storage/path/:/data # where transmission will store downloads
      - /your/config/path/:/config # where transmission-home (state) is stored
      - /your/wireguard-configs/:/wg-config/ # example mount for wireguard configs
    environment:
      - PUID=1000
      - PGID=1000
      - WEBPROXY_ENABLED=true # only if you need the bundled proxy
      - CONFIG_FILE=/wg-config/my_wg.conf  # A config file within your wireguard config mount
    logging:
      driver: json-file
      options:
        max-size: 10m
```

## PIA port forwarding

PIA port forwarding can be enabled when the mounted WireGuard config connects to a
PIA region that supports forwarded ports.

Set:

```yaml
environment:
  - PIA_PORT_FORWARDING=true
  - PIA_USERNAME=your-pia-username
  - PIA_PASSWORD=your-pia-password
```

Alternatively, set `PIA_TOKEN` directly or mount credentials as
`/config/pia-credentials.txt` with the username on line 1 and password on line 2.

The helper infers the PIA port-forwarding gateway from `CONFIG_FILE`'s `Endpoint`.
If needed, override it with `PIA_PF_GATEWAY`. The helper reserves a forwarded PIA
port, updates Transmission's peer port through RPC, and refreshes the PIA binding
every 15 minutes.

## Local network access

By default the container's default route is forced through `wg0`. Set
`LOCAL_NETWORK` only for private/local networks that must be reachable outside the
VPN tunnel, for example a Docker bridge service or a LAN service:

```yaml
environment:
  - LOCAL_NETWORK=172.22.0.8/32
```

Multiple networks can be comma-separated:

```yaml
environment:
  - LOCAL_NETWORK=172.22.0.8/32,192.168.7.0/24
```

The route is added through the container's `physical` namespace veth gateway, while
the default route remains on `wg0`. `LOCAL_NETWORK` accepts IPv4 private, loopback,
or link-local CIDRs and rejects default routes and public networks.

The internal veth pair defaults to `10.10.13.36/31` and `10.10.13.37/31`.
Override `VETH_DEFAULT_NS_IP`, `VETH_PHYSICAL_NS_IP`, or `VETH_CIDR` only if
that internal range conflicts with your environment.

To narrow the non-VPN route to specific TCP ports, set `LOCAL_NETWORK_PORTS`:

```yaml
environment:
  - LOCAL_NETWORK=172.22.0.8/32
  - LOCAL_NETWORK_PORTS=8000
```

When `LOCAL_NETWORK_PORTS` is set, traffic to the configured local network over the
non-VPN veth path is accepted only for those TCP destination ports and rejected for
other ports.

## Docker service name resolution

The container normally writes VPN-routed public DNS servers to `/etc/resolv.conf`.
That protects general DNS lookups from using Docker or host DNS, but it also means
Docker network aliases such as `apprise` will not resolve.

Set `DOCKER_DNS_NAMES` for Docker-local names that should resolve through Docker's
embedded DNS while all other DNS continues to use VPN-routed DNS servers:

```yaml
environment:
  - DOCKER_DNS_NAMES=apprise
```

Multiple names can be comma-separated:

```yaml
environment:
  - DOCKER_DNS_NAMES=apprise,traefik
```

This starts a local split-DNS `dnsmasq` instance in the WireGuard namespace:

- configured Docker names resolve via Docker DNS at `127.0.0.11`
- all other DNS resolves through `VPN_DNS_SERVERS`, defaulting to `1.1.1.1,1.0.0.1`
- `/etc/resolv.conf` points to the WireGuard namespace split-DNS listener

Services that share this container's network namespace cannot set Docker `dns:`
options. For those services, bind-mount a resolver file that points at the
WireGuard namespace split-DNS listener:

```yaml
services:
  transmission-wireguard:
    environment:
      - DOCKER_DNS_NAMES=apprise

  sidecar:
    network_mode: service:transmission-wireguard
    volumes:
      - ./transmission-resolv.conf:/etc/resolv.conf:ro
```

`transmission-resolv.conf` should match the split-DNS listener address. With the
default veth settings:

```text
nameserver 10.10.13.36
options ndots:0
```

The image starts one dnsmasq instance in the WireGuard namespace and one Docker DNS
forwarder in the physical Docker namespace. The physical forwarder has no generic
upstream and forwards only names listed in `DOCKER_DNS_NAMES`; normal lookups stay
on the VPN default route. This lets sidecars use names like `http://apprise:8000`
without hard-coded container IPs.

If Docker's embedded DNS at `127.0.0.11` is not reachable from the physical
namespace in your environment, run a dedicated DNS forwarder on the Docker network
instead and point split DNS at it:

```yaml
services:
  docker-dns:
    build:
      context: ./coredns-docker
    image: local-coredns:latest
    command: ["-conf", "/Corefile"]
    networks:
      trafik:
        ipv4_address: 172.22.0.53

  transmission-wireguard:
    environment:
      - DOCKER_DNS_NAMES=apprise
      - DOCKER_DNS_FORWARDER_IP=172.22.0.53
      - DOCKER_DNS_FORWARDER_PORT=53
```

Use a small Dockerfile for the DNS forwarder image so the Corefile is readable by
CoreDNS' non-root runtime user without relying on bind/config mount permissions:

```dockerfile
FROM coredns/coredns:latest

COPY --chown=nonroot:nonroot --chmod=0444 Corefile /Corefile
```

When `DOCKER_DNS_FORWARDER_IP` is set, the image treats it as an external upstream
and does not start the internal physical-namespace Docker DNS forwarder unless
`START_DOCKER_DNS_FORWARDER=true` is also set.
