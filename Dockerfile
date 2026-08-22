# PI WEB on Railway — web UI for persistent Pi Coding Agent sessions.
#
# Upstream ships NO authentication of any kind and says so plainly in its README:
# "It is not a sandbox, permission system, or multi-tenant platform. Do not expose it
# directly to the public internet without a trusted network, firewall, VPN, SSH tunnel,
# or authenticated reverse proxy."
#
# A Railway service gets a public URL, and PI WEB's surface includes interactive
# terminals and read/write filesystem access. So this image ships the authenticated
# reverse proxy upstream asks for: Caddy terminates the public port and enforces HTTP
# basic auth before anything reaches PI WEB, and the entrypoint refuses to boot when
# no password is configured.
FROM node:22-bookworm-slim

ARG PI_WEB_VERSION=1.202608.1
ARG CADDY_VERSION=2.10.2

ENV DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    SHELL=/bin/bash \
    TERM=xterm-256color

# Dev tools the agent is expected to have in its workspace. git is not optional:
# PI WEB's project/workspace model is built around real repositories.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client \
        build-essential python3 python3-venv pkg-config \
        ripgrep jq less procps unzip tini; \
    rm -rf /var/lib/apt/lists/*

# Caddy, pinned. Used only as the auth-enforcing reverse proxy in front of PI WEB.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) caddy_arch=amd64 ;; \
      arm64) caddy_arch=arm64 ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/caddy.tar.gz \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz"; \
    tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy; \
    rm -f /tmp/caddy.tar.gz; \
    chmod 0755 /usr/local/bin/caddy; \
    caddy version

# PI WEB plus its Pi Coding Agent peer (>=0.84.0). --include=peer is what puts the
# `pi` binary in the image; a PI WEB with no agent installed is a half-product.
RUN set -eux; \
    npm install -g --omit=dev --include=peer --no-audit --no-fund \
        "@jmfederico/pi-web@${PI_WEB_VERSION}" --allow-scripts=node-pty; \
    global_root="$(npm root -g)"; \
    global_prefix="$(npm prefix -g)"; \
    peer_pi_bin="${global_root}/@jmfederico/pi-web/node_modules/.bin/pi"; \
    if [ -x "${peer_pi_bin}" ]; then ln -sf "${peer_pi_bin}" "${global_prefix}/bin/pi"; fi; \
    test -x "${global_prefix}/bin/pi" || { echo "pi binary missing" >&2; exit 1; }; \
    npm cache clean --force

# Every writable path lives under /data, which is the volume mount point. Without
# this the workspaces, the repos cloned into them, the Pi login and the whole
# session history are ephemeral and die on the next redeploy.
ENV HOME=/data/home \
    XDG_CONFIG_HOME=/data/config \
    PI_WEB_DATA_DIR=/data/pi-web \
    PI_WEB_SESSIOND_SOCKET=/data/pi-web/sessiond.sock \
    PI_CODING_AGENT_DIR=/data/pi-agent \
    PI_WEB_HOST=127.0.0.1 \
    PI_WEB_PORT=8504 \
    PI_WEB_ALLOWED_HOSTS=all \
    PI_WEB_USERNAME=admin \
    HOSTEXEC_MODE=disabled \
    PI_WEB_WORKSPACE=/data/workspace

COPY Caddyfile /etc/caddy/Caddyfile
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/railway-entrypoint.sh

WORKDIR /data/workspace
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/railway-entrypoint.sh"]
