# syntax=docker/dockerfile:1

# Isolated, full-featured Ubuntu dev environment bundling:
#   - Claude Code       (@anthropic-ai/claude-code)
#   - Codex CLI         (@openai/codex) - BYOK: point it at any
#                        OpenAI-Responses-API-compatible endpoint via
#                        CODEX_BASE_URL / CODEX_API_KEY, see
#                        configure-codex-provider.sh
#   - Happy CLI         (https://github.com/slopus/happy)
# plus common compilers/interpreters so Claude Code can actually build and
# run the code it writes (C/C++, Python, Go, Node, Deno), not just edit it.
FROM ubuntu:26.04

ARG USERNAME=agent
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=22
ARG GO_VERSION=1.23.4
ARG DENO_VERSION=v2.1.4

# glibc's built-in C.UTF-8 gives UTF-8 locale support without installing the
# (surprisingly not-tiny) `locales` package + running locale-gen.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Base OS tooling + full build/dev toolchain:
#   - build-essential, cmake, pkg-config, gdb    -> compile & debug C/C++
#   - python3/pip/venv                           -> run & build Python
#   - git, curl, wget, unzip, jq, ripgrep, ...    -> everyday CLI/dev tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-transport-https \
        autoconf \
        automake \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        gdb \
        git \
        gnupg \
        htop \
        jq \
        less \
        libssl-dev \
        libtool \
        lsof \
        make \
        openssh-client \
        pkg-config \
        procps \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        sqlite3 \
        sudo \
        tmux \
        unzip \
        vim \
        wget \
        zip \
        zsh \
    && rm -rf /var/lib/apt/lists/*

# Node.js (required to run/install the npm-based CLIs below) from NodeSource.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Go toolchain.
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# Deno runtime, installed system-wide from the official release archive.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) DENO_ARCH=x86_64-unknown-linux-gnu ;; \
        arm64) DENO_ARCH=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported architecture for deno" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/denoland/deno/releases/download/${DENO_VERSION}/deno-${DENO_ARCH}.zip" -o /tmp/deno.zip \
    && unzip -q /tmp/deno.zip -d /usr/local/bin \
    && rm /tmp/deno.zip \
    && chmod +x /usr/local/bin/deno

# Non-root user the CLIs and any compiled programs run as, with passwordless
# sudo so build tooling (package installs, etc.) can still be used ad hoc.
#
# Ubuntu's official 24.04 base image ships its own "ubuntu" user/group at
# uid/gid 1000, which collides with USER_UID/USER_GID's default of 1000
# (useradd/groupadd fail with "UID/GID not unique", exit code 4). Remove it
# first - `|| true` so this still works on a base image that doesn't have it.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"${USERNAME}" \
    && chmod 0440 /etc/sudoers.d/"${USERNAME}"

# Global npm packages:
#   claude-code -> `claude`
#   codex       -> `codex`  (OpenAI's coding agent; `happy codex` finds it
#                  via PATH automatically, same package Happy's own error
#                  message recommends installing)
#   happy       -> `happy`  (mobile/web client wrapper: `happy claude` /
#                  `happy codex`)
#
# `happy` bundles prebuilt ripgrep + difftastic archives for EVERY platform
# it supports (darwin/linux/win32 x x64/arm64 = 12 files, ~106MB) directly
# in its package tree (tools/archives/), not as npm optionalDependencies -
# so npm installs all of them regardless of host platform. A Linux
# container can only ever use the linux build for its own architecture;
# delete the other 10 in the SAME layer as the install (deleting in a later
# layer would not shrink the image - the files would still exist in this
# layer's diff).
RUN npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
        happy \
    && npm cache clean --force \
    && case "$(dpkg --print-architecture)" in \
        amd64) HAPPY_ARCH=x64 ;; \
        arm64) HAPPY_ARCH=arm64 ;; \
        *) echo "unsupported architecture for happy" >&2; exit 1 ;; \
    esac \
    && HAPPY_ARCHIVES="$(npm root -g)/happy/tools/archives" \
    && find "${HAPPY_ARCHIVES}" -type f \( -name 'ripgrep-*.tar.gz' -o -name 'difftastic-*.tar.gz' \) \
        ! -name "ripgrep-${HAPPY_ARCH}-linux.tar.gz" \
        ! -name "difftastic-${HAPPY_ARCH}-linux.tar.gz" \
        -delete

# Workspace the CLIs operate on. Owned by the non-root user so `claude`,
# `codex`, and `happy` can all write their local state/config dirs, and so
# compiled artifacts land with sane ownership.
ENV WORKDIR=/workspace
RUN mkdir -p "${WORKDIR}" \
    && chown -R "${USERNAME}:${USERNAME}" "${WORKDIR}" /home/"${USERNAME}"

COPY --chown=${USERNAME}:${USERNAME} entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=${USERNAME}:${USERNAME} configure-codex-provider.sh /usr/local/bin/configure-codex-provider
COPY --chown=${USERNAME}:${USERNAME} configure-happy-credentials.sh /usr/local/bin/configure-happy-credentials
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/configure-codex-provider \
        /usr/local/bin/configure-happy-credentials

USER ${USERNAME}
WORKDIR ${WORKDIR}

# Provide a placeholder key so Claude Code's login dialog doesn't block when
# routing through another provider; override with a real ANTHROPIC_API_KEY
# for direct Anthropic use.
ENV ANTHROPIC_API_KEY=sk-ant-api03-placeholder

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
