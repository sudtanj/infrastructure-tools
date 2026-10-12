# syntax=docker/dockerfile:1

# Wraps https://github.com/mohankumarpaluru/oracle-freetier-instance-creation
# (main.py - polls the OCI API until it can create an Always Free compute
# instance, since free-tier capacity is often exhausted) to run unattended
# in a container, configured entirely through env vars (see .env.example)
# instead of the upstream project's interactive setup_env.sh / mounted
# oci_config + oci_api_private_key.pem files.

# --- builder stage -----------------------------------------------------------
# Alpine ships no manylinux wheels (musl, not glibc), so paramiko's
# cryptography dependency has to compile its Rust extension from source -
# needs gcc/musl-dev/libffi-dev/openssl-dev/cargo. All isolated to this
# stage so none of that toolchain ends up in the final image.
FROM python:3.14-alpine AS builder

RUN apk add --no-cache git build-base libffi-dev openssl-dev cargo rust

# Pin a commit/tag instead of "main" for a reproducible build if you want -
# rebuild with --build-arg OCI_FREETIER_REF=<sha> to bump it.
ARG OCI_FREETIER_REF=main
RUN git clone --depth 1 --branch "$OCI_FREETIER_REF" \
    https://github.com/mohankumarpaluru/oracle-freetier-instance-creation.git /src

WORKDIR /src
RUN python -m venv /venv \
    && /venv/bin/pip install --no-cache-dir --upgrade pip wheel setuptools \
    && /venv/bin/pip install --no-cache-dir -r requirements.txt

# --- final stage ---------------------------------------------------------
FROM python:3.14-alpine

# libffi/openssl: runtime shared libs cryptography's compiled extension
# needs (not the -dev/build-base/rust used only to build it above).
# su-exec: alpine's minimal gosu equivalent, for the root -> oci privilege
# drop below.
RUN apk add --no-cache libffi openssl su-exec \
    && addgroup -g 1000 oci && adduser -D -u 1000 -G oci oci

COPY --from=builder /venv /venv
# Only what main.py actually needs at runtime - not requirements.txt,
# setup_init.sh/setup_env.sh (upstream's own bash-driven flow, unused here
# since the entrypoint below replaces it), sample configs, or docs.
COPY --from=builder /src/main.py /src/email_content.html /app/
RUN chown -R oci:oci /app

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app
ENV PATH="/venv/bin:$PATH"

# Stays root - the entrypoint self-heals /app's ownership (in case the
# mounted volume is stale/root-owned - the same class of bug hit by every
# other image in this repo) and generates oci_config + the private key file
# from env vars, both of which need to happen before dropping to `oci` via
# su-exec.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
