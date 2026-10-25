# earnapp

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [EarnApp](https://earnapp.com) (Bright Data) Linux client,
pinned by checksum and repackaged on `gcr.io/distroless/cc-debian13:nonroot`.
Built for `linux/amd64` and `linux/arm64` (Orange Pi Zero 3 included).
Upstream publishes no Docker image.

## What this fixes over the official install

| Official `install.sh` | This image |
|---|---|
| Downloads whatever the CDN serves, runs it as root, installs systemd services and an auto-upgrader that replaces the binary in place | One version pinned by sha256, no upgrader, runs as `nonroot` (uid 65532) with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| Sends DNS straight to Google (`8.8.8.8`, hard-coded) | `init-earnapp.sh` redirects all DNS from the container to AdGuard Family Protection and drops DoT |
| Can reach your LAN like any program on the device | `init-earnapp.sh` drops all traffic from the container to private, Tailscale, link-local and multicast ranges |
| Node.js heap sized from the host's RAM | `--max-old-space-size=96` under a 160 MB cap with no swap, 0.25 CPU, 64 pids, small rotated logs |

## Quick start

```bash
echo "sdk-node-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"   # once: your device ID
cp .env.example .env
$EDITOR .env                       # EARNAPP_UUID=<that ID>
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

Then open `https://earnapp.com/r/<that ID>` once while logged in to EarnApp:
that links the device to your account. Until then it earns nothing.

| Variable | Required | Notes |
|---|---|---|
| `EARNAPP_UUID` | yes | `sdk-node-` + 32 lowercase hex digits. Keep it: a new ID is a new device that has to be linked again |

## Notes

- **One device per IP**: EarnApp pays for one device per public IP. Run it
  once per network.
- **State**: `/etc/earnapp` is a 16 MB tmpfs. The entrypoint writes the ID
  and status into it on every start; the client's own logs there are
  encrypted by upstream and rotate at 3 MB.
- **Old Node.js**: the client is built on Node.js 16, which is out of
  support. That is upstream's choice; the non-root, no-capability, no-LAN
  setup is what limits it.
- **Crash and usage reports** go to `perr.brightdata.com`. They are left on:
  the app's start-up and device checks report there.
- **No shell**: `docker exec` won't work. Use `docker logs`.
- **Redistribution**: this image republishes Bright Data's binary. Consider
  making `sudtanj/earnapp` private on Docker Hub.

## Updating

Read `VERSION=` from `https://brightdata.com/static/earnapp/install.sh`,
download `earnapp-x64-<version>` and `earnapp-aarch64-<version>` from
`https://cdn-earnapp.b-cdn.net/static/`, and bump `EARNAPP_VERSION` and both
`EARNAPP_SHA256_*` in the Dockerfile.
