
FROM node:22-bookworm-slim

# Install common development tools.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       ca-certificates \
       curl \
       python3 \
       make \
       g++ \
       jq \
       iptables \
       ipset \
       iproute2 \
       aggregate \
       dnsutils \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code inside the image, plus the JS/TS language server
# used by the typescript-lsp plugin.
RUN npm install -g @anthropic-ai/claude-code typescript-language-server typescript


# Bake in tamper-proof security policy: managed settings take precedence
# over every other settings level and live outside any writable mount,
# so the sandboxed agent can never edit or disable its own guardrail
# (the container filesystem is read_only: true except for declared
# writable mounts/tmpfs - see compose.yaml).
COPY claude-config/managed-settings.json /etc/claude-code/managed-settings.json
COPY claude-config/hooks/security-validator.sh /etc/claude-code/hooks/security-validator.sh
RUN chmod 644 /etc/claude-code/managed-settings.json \
    && chmod 755 /etc/claude-code/hooks/security-validator.sh

# Egress firewall: baked-in, root-only. Not reachable by the sandboxed
# agent at runtime - it never runs as root, see docker-entrypoint.sh.
COPY claude-config/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY claude-config/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 750 /usr/local/bin/init-firewall.sh \
    && chmod 750 /usr/local/bin/docker-entrypoint.sh

ENV HOME=/home/node
ENV npm_config_cache=/tmp/npm-cache

WORKDIR /workspace

# Stays root by default at runtime (no USER directive here) so the
# entrypoint can set up the firewall as root, then drops to the
# unprivileged node user itself before execing claude - see
# docker-entrypoint.sh.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]




