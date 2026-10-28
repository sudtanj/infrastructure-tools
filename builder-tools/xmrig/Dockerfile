FROM ubuntu:25.10 AS build

# "latest" resolves the newest xmrig release at build time, so the weekly
# no-cache rebuild always picks up new upstream versions. Pin with
# --build-arg VERSION=v6.x.y (leading "v" optional).
ARG VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential cmake automake libtool autoconf curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    if [ "$VERSION" = "latest" ]; then \
        TAG="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/xmrig/xmrig/releases/latest)"; \
        TAG="${TAG##*/}"; \
    else \
        case "$VERSION" in v*) TAG="$VERSION" ;; *) TAG="v$VERSION" ;; esac; \
    fi; \
    echo "Building xmrig ${TAG}"; \
    curl -fsSL -o /tmp/xmrig.tar.gz "https://github.com/xmrig/xmrig/archive/refs/tags/${TAG}.tar.gz"; \
    tar xf /tmp/xmrig.tar.gz -C /tmp; \
    SRC="/tmp/xmrig-${TAG#v}"; \
    (cd "$SRC/scripts" && ./build_deps.sh); \
    mkdir -p "$SRC/build"; \
    cd "$SRC/build"; \
    cmake .. -DXMRIG_DEPS=scripts/deps; \
    make -j "$(nproc)"; \
    cp xmrig /usr/local/bin/xmrig

FROM ubuntu:25.10 AS main

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends uuid-runtime && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/xmrig /usr/local/bin/xmrig

ENV POOL_USER="" \
    POOL_URL="" \
    POOL_PASS="" \
    DONATE_LEVEL=1 \
    PRIORITY=1 \
    THREADS=0 \
    ACCESS_TOKEN="" \
    ALGO="" \
    COIN=""

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /tmp
EXPOSE 3000

LABEL org.opencontainers.image.source=https://github.com/sudtanj/infrastructure-tools
LABEL org.opencontainers.image.description="An up-to-date XMRig image for x86/ARM Docker hosts."
LABEL org.opencontainers.image.licenses=MIT

CMD ["/entrypoint.sh"]
