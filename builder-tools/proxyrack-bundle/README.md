# proxyrack-bundle

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

Not a runnable container (`FROM scratch`): a set of prebuilt files for running
the [ProxyRack](../proxyrack) client inside an ephemeral GitHub Actions job on
a self-hosted runner that has no Docker, no TUN device and no `NET_ADMIN`.
The job downloads the image's layers from Docker Hub with `curl` and runs
`run.sh`; nothing is compiled or installed during the job. **`linux/amd64`
only**, like the client.

| File | What |
|---|---|
| `proxyrack` | the client, the same pinned binary as `builder-tools/proxyrack` |
| `graftcp` | [graftcp](https://github.com/hmgle/graftcp) v0.8.3, static: redirects a process's connections to a SOCKS5 proxy by tracing its syscalls, so it works on static Go binaries that ignore proxy settings |
| `proxyrack-guard` | SOCKS5 filter (`guard/main.go`, standard library only) |
| `tailscale`, `tailscaled` | from `tailscale/tailscale:v1.104.1`, run in userspace mode |
| `run.sh` | joins the tailnet, sets the exit node, checks the path, runs the client |

## Traffic path

```
proxyrack --graftcp--> proxyrack-guard --> tailscaled SOCKS5 --> exit node --> internet
```

- Every TCP connection of the client, loopback included, goes to the guard,
  which passes only public IPv4 addresses on. Private ranges (so the exit
  node's LAN and the runner's network), the tailnet, IPv6 and the mail and DoT
  ports are refused.
- DNS becomes DNS-over-TCP on the same path, always to AdGuard Family.
- Other UDP (the client has a UDP proxy) is dropped, never sent directly.
- Fails closed: if graftcp dies the kernel kills the client with it; if the
  guard, Tailscale or the exit node is down, connections fail.
- Before starting the client, `run.sh` checks that traffic on this path leaves
  from a different IP than the runner's, and that a loopback connection cannot
  skip the guard.

## Requirements on the runner

`ptrace` must be allowed for a process tracing its own child (Docker's
default seccomp profile allows it), plus `curl` and `jq`. See the header of
`run.sh` for its environment variables.

## Updating

- Client: bump `PROXYRACK_SHA256` in the Dockerfile and `--version` in
  `run.sh`, together with `builder-tools/proxyrack`.
- graftcp: bump `GRAFTCP_REF` and `GRAFTCP_COMMIT` (the build checks the
  commit).
- Tailscale and Go base images: Dependabot.
