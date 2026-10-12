# syntax=docker/dockerfile:1
ARG TERRAFORM_VERSION=1.6.0
FROM alpine:3.24 AS terraform-download
ARG TERRAFORM_VERSION
ARG TARGETARCH
RUN apk add --no-cache ca-certificates curl unzip \
    && case "${TARGETARCH:-$(apk --print-arch)}" in \
        amd64|x86_64) terraform_arch=amd64 ;; \
        arm64|aarch64) terraform_arch=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && asset="terraform_${TERRAFORM_VERSION}_linux_${terraform_arch}.zip" \
    && base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}" \
    && curl -fsSLO "$base/$asset" \
    && curl -fsSLO "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
    && grep " $asset$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c - \
    && unzip -q "$asset" -d /out
FROM alpine:3.24
RUN apk add --no-cache ca-certificates tini su-exec \
    && addgroup -g 1000 terraform \
    && adduser -D -u 1000 -G terraform terraform
COPY --from=terraform-download /out/terraform /usr/local/bin/terraform
COPY terraform/ /workspace
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh
WORKDIR /workspace
ENV TF_IN_AUTOMATION=1 \
    TF_PLUGIN_CACHE_DIR=/workspace/.terraform.d/plugin-cache \
    TF_LOG_PATH=/workspace/terraform.log
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
