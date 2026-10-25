# proxyrack

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The [ProxyRack Peer Program](https://peer.proxyrack.com) client on
`gcr.io/distroless/static-debian13:nonroot`. Earns by sharing bandwidth:
$0.50/GB from a home IP, $0.05/GB from a datacenter IP (ProxyRack's rates in
2026). **`linux/amd64` only**: ProxyRack builds its client for x86-64 Linux
only, so it does not run on the Orange Pi.

## What this fixes over the official image

| Official `proxyrack/pop` | This image |
|---|---|
| Ubuntu with Node.js, curl, netcat; runs as root | Distroless, no shell, uid 65532 |
| `run.sh` downloads a JavaScript launcher at every start, which downloads and runs the real client, without any checksum | The client (a static Go binary) is fetched once at build time and pinned by SHA-256; it never updates itself |
| Sends your dashboard API key from the container | No API key in the container; the deploy workflow adds the device to the dashboard from GitHub Actions |

## Quick start

```bash
# Device ID: generate once and keep it; the dashboard counts one device per ID.
UUID=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
docker run -d -i --name proxyrack --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --memory 128m --memory-swap 128m -e GOMEMLIMIT=96MiB -e GOMAXPROCS=1 \
  sudtanj/proxyrack:latest --id "$UUID"
```

Then add the device ID in the dashboard (Devices -> Add device).

`-i` is required: the client exits as soon as its stdin closes.

## Deployment used here

Not this image: the private repo runs the same pinned client from
[`proxyrack-bundle`](../proxyrack-bundle) on the Instabox self-hosted runner,
whose job containers have no Docker or TUN device. That bundle sends all of
the client's traffic through the Tailscale exit node, with a filter that
keeps it away from private networks and the tailnet.

## Notes

- **Updating.** Fetch `https://app-updates.sock.sh/peerclient/go/version.txt`
  and the `client` file next to it, check the binary, then bump
  `PROXYRACK_SHA256` and `--version` in the Dockerfile (and the same two in
  `../proxyrack-bundle`). Until then the build
  keeps the pinned version, and fails if upstream replaces the file at the
  same URL.
- **Arguments** are the ones the official launcher passes (`--homeIp`,
  `--homePort`, `--clientKey`, `--clientType PoP`, `--version`, `--osType`,
  `--osArch`); only `--id` is added at run time.
- **Earnings are irregular.** ProxyRack pauses buying bandwidth when demand
  drops; a datacenter IP earns a tenth of a home IP.
