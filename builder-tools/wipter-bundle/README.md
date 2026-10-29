# wipter-bundle

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

Not a runnable container (`FROM scratch`): a set of prebuilt files for running
the [Wipter](../wipter) app inside an ephemeral GitHub Actions job on a
self-hosted runner that has no Docker, no TUN device, no `NET_ADMIN` and no X
server (it brings its own Xvfb), with all of its traffic leaving through a Tailscale exit node, the
same way as [proxyrack-bundle](../proxyrack-bundle). The job downloads the
image's layers from Docker Hub with `curl` and runs `run.sh`; nothing is
compiled or installed during the job. **`linux/amd64` only.**

| File | What |
|---|---|
| `rt/` | the app, its shim and launcher from [`sudtanj/wipter`](../wipter), plus every library it needs, relocated to run from `/tmp/wipter-rt` |
| `graftcp` | [graftcp](https://github.com/hmgle/graftcp) v0.8.3, the same build as proxyrack-bundle's: redirects the connections of the app and all its child processes to a SOCKS5 proxy by tracing their syscalls |
| `wipter-guard` | SOCKS5 filter (`guard/main.go`): proxyrack-bundle's guard plus one loopback address let through |
| `tailscale`, `tailscaled` | from `tailscale/tailscale:v1.104.1`, run in userspace mode |
| `rt/bin/x11vnc` | optional VNC view of the app's screen, relocated like the rest |
| `run.sh` | joins the tailnet, sets the exit node, checks the path, runs the app |

## Running the app without its image

- **Libraries**: the app is a Debian trixie build, the runner is Ubuntu. Every
  executable gets the bundle's own glibc loader at a fixed path,
  `/tmp/wipter-rt/ld-linux-x86-64.so.2`, and every library a forced `DT_RPATH`
  into `/tmp/wipter-rt/lib`, the way NixOS packages Electron. `run.sh` links
  `/tmp/wipter-rt` to the unpacked bundle. No `LD_LIBRARY_PATH`, so the host
  programs the app starts (`sh`, `cat`, ...) keep the host's libraries. The
  build checks this on Alpine, which has no glibc at all: every library
  resolves inside the bundle and the app starts and shows its sign-in form.
- **Display**: the bundle's own Xvfb, from the same Debian release, relocated
  the same way (Chromium's headless backend hangs Electron). It runs
  `xkbcomp` from a compiled-in dir, so its `/usr/bin` string is patched to
  `/tmp/wxb` (same length), which `run.sh` links to `rt/bin`; the keyboard
  data is passed with `-xkbdir`. GTK's settings schemas are in `rt/share`.
- **Fonts**: the bundle's, through `rt/fonts.conf`.
- **Device ID**: the app fingerprints the device with `/etc/machine-id`, or
  `hostname` without one; `run.sh` puts a `hostname` that prints
  `WIPTER_MACHINE_ID` first in the app's `PATH`, so a runner without a
  machine-id file is the same device every run.

## Traffic path

```
wipter app --graftcp--> wipter-guard --> tailscaled SOCKS5 --> exit node --> internet
```

As in proxyrack-bundle: only public IPv4 is passed on, DNS goes to AdGuard
Family over TCP, other UDP is dropped, and it fails closed. One addition:
the app runs a SOCKS5 server on `127.0.0.1:2000` that its `wipter-tunnel`
process connects to, so the guard dials exactly that address directly
(`-local`). `run.sh` checks the port is free first, so the app gets it. Any
other loopback connection, tailscaled's port included, is refused. The ports
differ from proxyrack-bundle's, since the jobs share the host network.

## Watching the app over VNC (optional)

With `VNC_VIEWER=<tailnet device>[:port]` (default port 5500) and
`WIPTER_VNC_PASSWORD`, x11vnc connects **out** to a VNC viewer listening on
that tailnet device (for example TigerVNC `vncviewer -listen 5500`, or
RealVNC/Remmina in listening mode), every 30 s until one takes the session,
and again after it ends. The viewer asks for the password. The screen is
1024x800, enough for the whole window, with no window manager.

It is a reverse connection on purpose: nothing listens for the tailnet, so
`--shields-up` stays on. Userspace tailscaled forwards every inbound tailnet
connection to `127.0.0.1` on the same port, which here would include the
app's SOCKS5 server and tailscaled's own, leaving only the tailnet ACL in
the way. x11vnc reaches the viewer through tailscaled's SOCKS5 port under
graftcp (tailnet addresses only) and listens on no port. The tailnet ACL must
let the runner's tag reach the viewer's device on that port.

## Requirements on the runner

`ptrace` allowed for a process tracing its own children (Docker's default
seccomp profile allows it), a writable `/tmp`, `curl`, `jq` and `timeout`.
About 350 MB of disk (tmpfs) for the unpacked bundle and ~300 MB of RAM for
the app. See the header of `run.sh` for its environment variables.

## Updating

- App: bump the `sudtanj/wipter` tag in the Dockerfile after `builder-tools/wipter`
  is published.
- graftcp: together with proxyrack-bundle (`GRAFTCP_REF`, `GRAFTCP_COMMIT`).
- Guard: changes to proxyrack-bundle's guard belong here too.
- Tailscale and Go base images: Dependabot.
