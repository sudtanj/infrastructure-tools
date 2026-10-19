# tailscale

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`tailscale/tailscale`](https://hub.docker.com/r/tailscale/tailscale)
`tailscaled` and `tailscale` binaries, repackaged on
`gcr.io/distroless/static-debian13`. The Alpine base, iptables/iproute2,
`containerboot` and the shell are dropped. Built for `linux/amd64` and
`linux/arm64`, sized for an Orange Pi Zero 3 running from an SD card.

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # TS_AUTHKEY, TS_HOSTNAME, TS_EXIT_NODE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
docker exec tailscale tailscale status
```

| Variable | Required | Notes |
|---|---|---|
| `TS_AUTHKEY` | first start only | Auth key. Leave empty to log in by hand: `docker exec tailscale tailscale up`, then open the printed URL. |
| `TS_HOSTNAME` | no (default `opi-zero3`) | Name in the admin console and MagicDNS. |
| `TS_EXIT_NODE` | no (default `true`) | `true` or `false`. Advertises the board as an exit node. |
| `TS_PORT` | no (default `41641`) | WireGuard UDP port. Forward it on the router for direct connections. |
| `TS_TAILSCALED_EXTRA_ARGS` | no | Extra `tailscaled` flags, split on spaces and added last so they win, e.g. `--port 8806`. Same name as in the official image. |

Settings go into tailscaled's own config file (`--config`), which Compose
writes from `.env`. Recreate with `docker compose up -d` after you change
`.env`. This needs Docker Compose 2.23.1 or newer.

## Host preparation (once)

```bash
# TUN device (built into most Orange Pi / Armbian kernels)
ls -l /dev/net/tun || sudo modprobe tun

# Exit node only: Docker can't set net.* sysctls for a host-network
# container, so the host has to turn on forwarding.
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' |
  sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

# Exit node only, when Docker runs on iptables-legacy ("iptables -V" says
# legacy): tailscaled here only writes nftables rules, and those can't override
# Docker's legacy FORWARD DROP policy, so the exit node forwards nothing.
sudo iptables-legacy -I FORWARD 1 -i tailscale0 -j ACCEPT
sudo iptables-legacy -I FORWARD 1 -o tailscale0 -j ACCEPT
```

Then approve the exit node in the admin console (Machines → Edit route
settings → Use as exit node).

### Moving from a host-installed Tailscale

The container and a host `tailscaled` can't both own `tailscale0`. Stop the
host one first. **Do this from the LAN, not over Tailscale**, because the
connection drops in between. To keep the same node (IP, name, ACL tags),
copy the host state into the volume before the first start:

```bash
sudo systemctl disable --now tailscaled
docker volume create tailscale_tailscale-state
sudo cp /var/lib/tailscale/tailscaled.state \
  "$(docker volume inspect -f '{{.Mountpoint}}' tailscale_tailscale-state)/"
docker compose -f docker-compose.hub.yml up -d
```

## Why it suits a small board on an SD card

- **Size**: two static binaries on a base of about 2 MB. Unlike the official
  image, it has no Alpine, iptables/iproute2 or `containerboot`.
- **SD card writes**: log upload is off (`TS_NO_LOGS_NO_SUPPORT=true`),
  which also removes the on-disk log buffer, the main source of steady writes.
  The root filesystem is read-only, cache and socket are on tmpfs, and the
  state volume is only written on logins, key renewals and setting changes.
  Container logs are capped at 2 × 5 MB.
- **Memory**: tailscaled usually uses 30–50 MB. The container is capped at
  128 MB with `GOMEMLIMIT=96MiB`. Even the 1 GB Zero 3 has plenty of room.
- **Throughput**: kernel networking (real TUN device, host network), not
  userspace netstack. That matters on the Cortex-A53 for exit node traffic.

## Notes

- **Firewall**: tailscaled programs nftables directly over netlink
  (`TS_DEBUG_FIREWALL_MODE=nftables`), so the kernel needs `nf_tables`.
  Docker on current Debian/Armbian already uses it. On a legacy-iptables-only
  kernel, use the official image instead.
- **No shell**: `docker exec tailscale tailscale <cmd>` works, because the
  CLI binary is in the image. Interactive shells don't.
- **No Tailscale support logs**: with log upload off, Tailscale support
  can't see this node's logs. Set `TS_NO_LOGS_NO_SUPPORT: "false"` under
  `environment:` to turn uploads back on.
- **Accept routes / DNS** are off, so routes from other subnet routers and
  tailnet DNS never take over the board's own LAN and resolver.
- **Updating Tailscale**: Dependabot bumps the `tailscale/tailscale` tag in
  the `Dockerfile` weekly. You can also bump it by hand. The build runs
  `tailscaled --version` and `tailscale version` as a smoke test, so a
  release that isn't statically linked fails the build rather than the
  container.

## Deploying with the init script

[`bash-scripts/opi-init-tailscale-docker.sh`](../../bash-scripts/opi-init-tailscale-docker.sh)
runs this image without Compose and adds:
- Taking over a host-installed Tailscale, keeping the same node identity.
- Disconnect-safe deploys: the work runs as its own systemd unit, so it finishes
  when the SSH session over Tailscale drops, and a container that does not come
  up is swapped back for the previous one. `OPI_TS_ATTACH=1` follows a running
  deployment; the Orange Pi workflow reconnects and does this on its own.
- IP forwarding on the host, loose `rp_filter` where it was strict, and, when
  Docker or ufw use iptables-legacy with a `FORWARD` DROP policy, rules that let
  `tailscale0` through it (kept across reboots by `tailscale-docker-forward.service`).
  Without them the exit node can be selected but reaches nothing.
- Subnet routes (`OPI_TS_ROUTES`).
- Extra `tailscaled` flags (`OPI_TS_TAILSCALED_EXTRA_ARGS`, e.g. `--port 8806`
  for a fixed, port-forwarded WireGuard port and direct connections).
- One credential, the repo's existing `TAILSCALE_OAUTH_CLIENT_SECRET` OAuth
  client, used to:
  - log a new node in with a one-off auth key tagged `OPI_TS_TAGS`, and keep
    the tags in sync on later runs
  - approve the routes and exit node
  - pin the tailnet IP (`OPI_TS_IP`)

Run it from the Orange Pi workflow (pick `opi-init-tailscale-docker`) or directly
on the device:

```bash
sudo TAILSCALE_OAUTH_CLIENT_SECRET=tskey-client-xxxx OPI_TS_TAGS=tag:opi \
  OPI_TS_ROUTES=192.168.1.0/24 OPI_TS_IP=100.100.10.10 \
  bash opi-init-tailscale-docker.sh
```

Use either the script or Compose on a host, not both: both name the
container `tailscale`.
