FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root

# Home-local tool locations
ENV NVM_DIR=/root/.nvm
ENV RUSTUP_HOME=/root/.rustup
ENV CARGO_HOME=/root/.cargo

ENV PATH="/root/.local/bin:/root/.cargo/bin:${PATH}"

ARG NVM_VERSION=v0.40.7

# ---------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    zsh \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    openssh-client \
    build-essential \
    pkg-config \
    libssl-dev \
    iproute2 \
    iptables \
    fuse-overlayfs \
    tini \
    procps \
    less \
    vim \
    jq \
    unzip \
    xz-utils \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*


# ---------------------------------------------------------------------
# Root password
#
# Build with: --build-arg ROOT_PASSWORD=...
# (也可运行时用 -e ROOT_PASSWORD=... 覆盖，见 entrypoint，避免密码进镜像层)
# ---------------------------------------------------------------------

ARG ROOT_PASSWORD

RUN echo "root:${ROOT_PASSWORD:-changeme}" | chpasswd

# ---------------------------------------------------------------------
# SSH server setup
# ---------------------------------------------------------------------

# - /run/sshd: sshd 特权分离目录，容器内不会自动创建
# - ssh-keygen -A: 幂等地生成缺失的 host key
# - PermitRootLogin yes: Debian 默认 prohibit-password，root 密码登录会被拒
RUN mkdir -p /run/sshd /etc/ssh/sshd_config.d \
    && ssh-keygen -A \
    && printf '%s\n' \
        'PermitRootLogin yes' \
        > /etc/ssh/sshd_config.d/00-root-login.conf


# ---------------------------------------------------------------------
# Docker CE / Docker Compose / Buildx
# ---------------------------------------------------------------------

# Prevent package installation from trying to start systemd services.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    \
    && . /etc/os-release \
    && ARCH="$(dpkg --print-architecture)" \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://download.docker.com/linux/debian' \
        "Suites: ${VERSION_CODENAME}" \
        'Components: stable' \
        "Architectures: ${ARCH}" \
        'Signed-By: /etc/apt/keyrings/docker.asc' \
        > /etc/apt/sources.list.d/docker.sources \
    \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d


# ---------------------------------------------------------------------
# NVM + Node LTS
#
# Everything lives under /root/.nvm.
# /root/.local/bin contains convenience symlinks so node/npm work
# even when nvm.sh hasn't explicitly been sourced.
# ---------------------------------------------------------------------

RUN git clone \
        --depth 1 \
        --branch "${NVM_VERSION}" \
        https://github.com/nvm-sh/nvm.git \
        "${NVM_DIR}" \
    \
    && bash -c '\
        source "${NVM_DIR}/nvm.sh" && \
        nvm install --lts && \
        nvm alias default "lts/*" && \
        nvm use default && \
        mkdir -p /root/.local/bin && \
        NODE_BIN="$(dirname "$(nvm which default)")" && \
        for bin in node npm npx corepack; do \
            if [ -e "${NODE_BIN}/${bin}" ]; then \
                ln -sf "${NODE_BIN}/${bin}" "/root/.local/bin/${bin}"; \
            fi; \
        done \
    '


# ---------------------------------------------------------------------
# rustup + Rust stable
#
# /root/.rustup
# /root/.cargo
# ---------------------------------------------------------------------

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- \
        -y \
        --profile minimal \
        --default-toolchain stable \
    \
    && rustup component add rustfmt clippy


# ---------------------------------------------------------------------
# Oh My Zsh
# ---------------------------------------------------------------------

RUN git clone \
        --depth 1 \
        https://github.com/ohmyzsh/ohmyzsh.git \
        /root/.oh-my-zsh


# ---------------------------------------------------------------------
# Shell configuration
# ---------------------------------------------------------------------

RUN cat > /root/.zshrc <<'EOF'
export HOME="/root"

export NVM_DIR="$HOME/.nvm"
export RUSTUP_HOME="$HOME/.rustup"
export CARGO_HOME="$HOME/.cargo"

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# NVM
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

# Rust
[ -s "$CARGO_HOME/env" ] && source "$CARGO_HOME/env"

# Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"

plugins=(
    git
    docker
)

source "$ZSH/oh-my-zsh.sh"
EOF

# Useful when scripts use bash instead of zsh.
RUN cat > /root/.bashrc <<'EOF'
export HOME="/root"

export NVM_DIR="$HOME/.nvm"
export RUSTUP_HOME="$HOME/.rustup"
export CARGO_HOME="$HOME/.cargo"

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
[ -s "$CARGO_HOME/env" ] && source "$CARGO_HOME/env"
EOF

# ---------------------------------------------------------------------
# cloudflared latest
#
# 装在 /usr/local/bin 而非 /root/.local/bin：compose 会把宿主目录挂载
# 到 /root，/root 下的文件会被隐藏导致隧道永远不启动；
# /usr/local/bin 不受挂载影响，任何启动方式下都存在。
# ---------------------------------------------------------------------

RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
        amd64) CF_ARCH="amd64" ;; \
        arm64) CF_ARCH="arm64" ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
        -o /usr/local/bin/cloudflared \
    && chmod +x /usr/local/bin/cloudflared




# ---------------------------------------------------------------------
# Docker-in-Docker entrypoint
#
# DOCKER_MODE:
#
#   auto  - use mounted host socket if present, otherwise start DinD
#   dind  - always start dockerd
#   host  - expect /var/run/docker.sock to be mounted
#   none  - don't start/check Docker
#
# Docker data itself is also kept under /root.
# ---------------------------------------------------------------------

RUN cat > /usr/local/bin/docker-entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -e

# ---------------------------------------------------------------------
# /root 持久化恢复
#
# ./root:/root 挂载首次启动时目录为空，从镜像内快照恢复全部内容
# （cloudflared、nvm、rustup、oh-my-zsh、shell 配置等），
# 保证第一次启动即开箱即用。marker 存在则跳过 —— 绝不覆盖宿主数据。
# ---------------------------------------------------------------------

if [ -f /opt/root-initial.tar.gz ] && [ ! -e /root/.root-initialized ]; then
    echo "Initializing /root from image snapshot..."
    tar -xzf /opt/root-initial.tar.gz -C /root
    touch /root/.root-initialized
    echo "/root initialized."
fi

DOCKER_MODE="${DOCKER_MODE:-auto}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/root/.docker-data}"

start_dind() {
    mkdir -p "$DOCKER_DATA_ROOT" /var/run

    echo "Starting Docker daemon..."

    dockerd \
        --host=unix:///var/run/docker.sock \
        --data-root="$DOCKER_DATA_ROOT" \
        > /tmp/dockerd.log 2>&1 &

    # Wait for daemon.
    for i in $(seq 1 60); do
        if docker info >/dev/null 2>&1; then
            echo "Docker daemon ready."
            return 0
        fi

        if ! kill -0 "$!" >/dev/null 2>&1; then
            echo "dockerd exited unexpectedly:"
            cat /tmp/dockerd.log
            exit 1
        fi

        sleep 1
    done

    echo "Timed out waiting for dockerd."
    cat /tmp/dockerd.log
    exit 1
}

case "$DOCKER_MODE" in
    auto)
        if [ -S /var/run/docker.sock ]; then
            echo "Using existing Docker socket."
        else
            start_dind
        fi
        ;;

    dind)
        start_dind
        ;;

    host)
        if [ ! -S /var/run/docker.sock ]; then
            echo "DOCKER_MODE=host but /var/run/docker.sock is unavailable."
            exit 1
        fi
        ;;

    none)
        ;;

    *)
        echo "Unknown DOCKER_MODE: $DOCKER_MODE"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------
# SSH
#
# SSH_MODE:
#   auto|on - start sshd on 0.0.0.0:${SSH_PORT:-22}
#   none    - don't start sshd
# ---------------------------------------------------------------------

start_sshd() {
    mkdir -p /run/sshd

    # 运行时密码覆盖（优先于构建时 ARG，且不落进镜像层）
    if [ -n "${ROOT_PASSWORD:-}" ]; then
        echo "root:${ROOT_PASSWORD}" | chpasswd
    fi

    echo "Starting sshd on port ${SSH_PORT:-22}..."
    /usr/sbin/sshd -e -p "${SSH_PORT:-22}"

    if ! pgrep -x sshd >/dev/null 2>&1; then
        echo "sshd failed to start."
        exit 1
    fi
}

case "${SSH_MODE:-auto}" in
    auto|on)
        start_sshd
        ;;

    none)
        ;;

    *)
        echo "Unknown SSH_MODE: $SSH_MODE"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------
# cloudflared
#
# CLOUDFLARED_MODE:
#   auto - 配置文件存在则启动隧道（默认 /root/.cloudflared/config.yml）
#   off  - 不启动，手动运行
#
# 隧道走出站连接，config.yml 里的 ssh service 指向容器内 localhost:22，
# 因此无需 docker -p 发布 22 端口。
# ---------------------------------------------------------------------

CLOUDFLARED_CONFIG="${CLOUDFLARED_CONFIG:-/root/.cloudflared/config.yml}"

if [ "${CLOUDFLARED_MODE:-auto}" != "off" ] \
    && [ -x /usr/local/bin/cloudflared ] \
    && [ -f "$CLOUDFLARED_CONFIG" ]; then
    echo "Starting cloudflared (config: $CLOUDFLARED_CONFIG)..."
    /usr/local/bin/cloudflared \
        --no-autoupdate \
        --config "$CLOUDFLARED_CONFIG" \
        tunnel run \
        >/tmp/cloudflared.log 2>&1 &
fi

exec "$@"
EOF

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# ---------------------------------------------------------------------
# /root 初始快照
#
# ./root:/root 外部挂载首次启动时为空目录，entrypoint 会从此快照
# 恢复全部内容（cloudflared、nvm、rustup、oh-my-zsh、shell 配置）。
# 存放在 /opt（不受挂载影响）。代价：镜像体积增加约一份工具链。
# ---------------------------------------------------------------------

RUN tar -czf /opt/root-initial.tar.gz -C /root .


WORKDIR /root

ENV DOCKER_MODE=auto
ENV DOCKER_DATA_ROOT=/root/.docker-data

# 仅作文档说明：cloudflared 从容器内部访问 localhost:22，
# 隧道 SSH 不需要 -p 22:22 发布端口。
EXPOSE 22

SHELL ["/bin/zsh", "-c"]

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["zsh"]