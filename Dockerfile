# syntax=docker/dockerfile:1.7
FROM cgr.dev/chainguard/node:latest-dev@sha256:337a0e2860e69cb2ae25e2e5e942e18d08cf72f3470cb9081325e852dff7e237

# openssh-client: ssh binary for git-over-SSH (PI_SSH_AGENT=1) and ssh-add.
USER root
ENV HOME=/home/piuser
RUN mkdir /home/piuser

RUN apk add --no-cache \
        curl \
        ca-certificates \
        git \
        openssh-client \
        tmux

# Install mise (GPG-verified via mise-release.asc).
COPY mise-release.asc /tmp/mise-release.asc
RUN apk add --no-cache gpg gpg-agent \
    && gpg --import /tmp/mise-release.asc \
    && curl -fsSL https://mise.jdx.dev/install.sh.sig -o /tmp/mise-install.sh.sig \
    && gpg --decrypt /tmp/mise-install.sh.sig > /tmp/mise-install.sh \
    && MISE_VERSION=2026.5.2 MISE_INSTALL_PATH=/usr/local/bin/mise sh /tmp/mise-install.sh \
    && rm /tmp/mise-release.asc /tmp/mise-install.sh.sig /tmp/mise-install.sh \
    && apk del gpg gpg-agent

# ARG (not ENV): available during build, not baked in. At runtime mise defaults
# to ~/.local/share/mise, which the container user can write to.
ARG MISE_DATA_DIR=/usr/local/share/mise

# Install uv via mise and expose uv and uvx on PATH.
RUN mise install uv@0.11.11 \
    && ln -s "$(mise exec uv@0.11.11 -- which uv)" /usr/local/bin/uv \
    && ln -s "$(mise exec uv@0.11.11 -- which uvx)" /usr/local/bin/uvx

ENV UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python

# Install Python via uv and expose it on PATH
RUN uv python install 3.14.4 \
    && ln -s "$(uv python find 3.14.4)" /usr/local/bin/python3

# Install Bun and oh-my-pi globally.
ARG OMP_PACKAGE
ARG OMP_VERSION
ARG OMP_LOCAL_PACKAGE
ENV BUN_INSTALL=/usr/local/share/bun
ENV PATH="${BUN_INSTALL}/bin:${PATH}"
# TODO harden bun install too
RUN curl --proto '=https' --tlsv1.2 -fsSL https://bun.sh/install -o /tmp/bun-install.sh \
    && bash /tmp/bun-install.sh \
    && rm /tmp/bun-install.sh

# TODO separate named build stage for local package build, since npm package doesn't need rust install
# install rust for the native calls
RUN curl --proto '=https' --tlsv1.2 -fsS https://sh.rustup.rs -o /tmp/rust-install.sh \
    && bash /tmp/rust-install.sh -y \
    && rm /tmp/rust-install.sh

ENV PATH="${HOME}/.cargo/bin:${PATH}"

# Copy the optional local package context so native build steps can write.
# hadolint ignore=DL3022
COPY --from=omp-local . /tmp/omp-local
RUN bash <<'EOF'
set -euo pipefail

if [[ -n "${OMP_LOCAL_PACKAGE}" ]]; then
    cd /tmp/omp-local
    bun run build:native
    bun run install:dev
else
    bun install -g "${OMP_PACKAGE}@${OMP_VERSION}"
fi

ln -sf "${BUN_INSTALL}/bin/omp" /usr/local/bin/omp
EOF

# Prepend extension binaries (host-mounted via /home/piuser/.omp/agent). Security: binaries
# here can shadow any command; no privilege escalation (--cap-drop=ALL,
# --no-new-privileges), but review ~/.omp/agent/npm-global/bin/ after installs.
ENV PATH="/home/piuser/.omp/agent/npm-global/bin:${PATH}"

# /home/piuser: world-writable (1777) so any runtime UID can write here.
# /home/piuser/.ssh: root-owned 755; SSH accepts it and the runtime user can
#   read mounts inside it (700 would block a non-matching UID).
# /etc/passwd: world-writable so the entrypoint can add the runtime UID.
#   SSH calls getpwuid(3) and hard-fails without a passwd entry. Safe here
#   because --cap-drop=ALL and --no-new-privileges block privilege escalation.
# .npmrc sets prefix=~/.omp/agent/npm-global so npm-based extensions persist across restarts.
# Written as a literal file because ENV HOME is not yet set to /home/piuser.
RUN mkdir -p /home/piuser /home/piuser/.ssh \
    && chmod 1777 /home/piuser \
    && chmod 755 /home/piuser/.ssh \
    && chmod a+w /etc/passwd \
    && touch /home/piuser/.ssh/known_hosts \
    && chmod 666 /home/piuser/.ssh/known_hosts \
    && echo "prefix=/home/piuser/.omp/agent/npm-global" > /home/piuser/.npmrc

# Register the runtime UID in /etc/passwd before starting omp.
# SSH calls getpwuid(3) and hard-fails without an entry; nss_wrapper is
# unavailable in Wolfi so we append directly.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
