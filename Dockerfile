# syntax=docker/dockerfile:1.7

# Helper image to install Transmission UIs
FROM alpine:latest AS transmissionui

SHELL ["/bin/ash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3018
RUN apk --no-cache add curl jq \
    && mkdir -p /opt/transmission-ui \
    && echo "Install Shift" \
    && wget -qO- https://github.com/killemov/Shift/archive/master.tar.gz | tar xz -C /opt/transmission-ui \
    && mv /opt/transmission-ui/Shift-master /opt/transmission-ui/shift \
    && echo "Install Flood for Transmission" \
    && wget -qO- https://github.com/johman10/flood-for-transmission/releases/latest/download/flood-for-transmission.tar.gz | tar xz -C /opt/transmission-ui \
    && echo "Install Combustion" \
    && wget -qO- https://github.com/Secretmapper/combustion/archive/release.tar.gz | tar xz -C /opt/transmission-ui \
    && echo "Install kettu" \
    && wget -qO- https://github.com/endor/kettu/archive/master.tar.gz | tar xz -C /opt/transmission-ui \
    && mv /opt/transmission-ui/kettu-master /opt/transmission-ui/kettu \
    && echo "Install Transmissionic" \
    && wget -qO- https://github.com/6c65726f79/Transmissionic/releases/download/v1.8.0/Transmissionic-webui-v1.8.0.zip | unzip -q - \
    && mv web /opt/transmission-ui/transmissionic \
    && echo "Install Transmission Web Control" \
    && wget -qO- https://github.com/ronggang/transmission-web-control/archive/v1.6.1-update1.tar.gz | tar xz -C /opt/transmission-ui \
    && mv /opt/transmission-ui/transmission-web-control-1.6.1-update1/src /opt/transmission-ui/transmission-web-control \
    && rm -rf /opt/transmission-ui/transmission-web-control-1.6.1-update1

# Main image — Ubuntu + Transmission from the shared base
# https://github.com/haugene/transmission-base
FROM haugene/transmission-base:4.1.3-ubuntu26.04

VOLUME /data
VOLUME /config

COPY --from=transmissionui /opt/transmission-ui /opt/transmission-ui

ARG DEBIAN_FRONTEND=noninteractive
ARG PIAWGC_REPOSITORY=disaac/piawgc
ARG PIAWGC_ASSET_NAME=piawgc-aarch64-unknown-linux-gnu
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    dumb-init python3 dnsmasq-base \
    tzdata dnsutils iputils-ping ufw iproute2 iptables \
    openssh-client git jq curl wget unrar unzip bc ca-certificates \
    # New for this image
    wireguard nginx libnginx-mod-stream privoxy gettext-base \
    # End new for this image
    && rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/* \
    && useradd -u 911 -U -d /config -s /bin/false abc \
    && usermod -G users abc

RUN --mount=type=secret,id=GH_TOKEN,required=true \
    set -eu; \
    gh_token="$(cat /run/secrets/GH_TOKEN)"; \
    release_json="$(mktemp)"; \
    curl -fsSL \
      -H "Authorization: Bearer ${gh_token}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${PIAWGC_REPOSITORY}/releases/latest" \
      -o "${release_json}"; \
    asset_id="$(jq -er --arg name "${PIAWGC_ASSET_NAME}" '.assets[] | select(.name == $name) | .id' "${release_json}")"; \
    asset_tag="$(jq -er '.tag_name' "${release_json}")"; \
    echo "Installing piawgc ${asset_tag} asset ${PIAWGC_ASSET_NAME}"; \
    curl -fsSL \
      -H "Authorization: Bearer ${gh_token}" \
      -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/${PIAWGC_REPOSITORY}/releases/assets/${asset_id}" \
      -o /usr/local/bin/piawgc; \
    chmod 0755 /usr/local/bin/piawgc; \
    rm -f "${release_json}"


COPY start.sh /opt/wireguard/start.sh
COPY get-config-value.py /opt/wireguard/get-config-value.py
COPY strip-wg-config.py /opt/wireguard/strip-wg-config.py
COPY pia-port-forwarding.sh /opt/wireguard/pia-port-forwarding.sh
COPY healthcheck.sh /opt/wireguard/healthcheck.sh
COPY nginx_server.conf /opt/nginx/server.conf
COPY nginx_templates /opt/nginx/templates
RUN mkdir -p /opt/nginx/main.d /opt/nginx/stream.d
COPY transmission-default-settings.json /opt/transmission/default-settings.json
COPY updateSettings.py /opt/transmission/
COPY userSetup.sh /opt/transmission/
RUN chmod 0755 /opt/wireguard/start.sh /opt/wireguard/pia-port-forwarding.sh /opt/wireguard/healthcheck.sh

# Set some environment variables needed in various scripts
ENV TRANSMISSION_HOME=/config/transmission-home \
    TRANSMISSION_DOWNLOAD_DIR=/data/completed \
    TRANSMISSION_INCOMPLETE_DIR=/data/incomplete \
    TRANSMISSION_WATCH_DIR=/data/watch \
    GLOBAL_APPLY_PERMISSIONS=true \
    TRANSMISSION_UMASK=2 \
    WEBPROXY_ENABLED=false \
    WEBPROXY_PORT=8118 \
    WEBPROXY_BIND_ADDRESS=

# Get base_revision passed as a build argument and set it as env var
ARG REVISION
ENV REVISION=${REVISION:-""}

# Transmission RPC
EXPOSE 9091
# Privoxy web proxy
EXPOSE 8118

HEALTHCHECK --interval=1m --timeout=10s --start-period=2m --retries=3 CMD ["/opt/wireguard/healthcheck.sh"]

CMD ["dumb-init", "/opt/wireguard/start.sh"]
