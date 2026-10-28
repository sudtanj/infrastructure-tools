# wipter

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [Wipter](https://wipter.com) desktop app, pinned by checksum and
run on a bare virtual display (Xvfb): no window manager, VNC or keyring, and
none of the GPU drivers.
Built for `linux/amd64` and `linux/arm64` (Orange Pi Zero 3 included).
Upstream publishes no Docker image.

## What this fixes over the usual setup

Wipter ships only a desktop app (Electron). The community images run it under
Xvfb, a window manager, VNC/noVNC and gnome-keyring, and type the login into
the window with fake key presses.

| Community image | This image |
|---|---|
| Xvfb + Openbox + x11vnc + noVNC + gnome-keyring + dbus, plus git, Python, xterm and fonts | A bare Xvfb (Chromium's headless backend deadlocks in Electron); only the libraries the Electron binary links against, minus Mesa, LLVM, SwiftShader and Vulkan (software drawing, no GPU process, one page process) |
| Types the email and password into the window with `xte` and fixed sleeps | A small shim loaded before the app (`shim/shim.js`, in `resources/app/`) fills in the sign-in form from inside the app. No DevTools port: the app relays third-party traffic, so a port on localhost would be reachable through it |
| Randomises the hostname, vendor, model and firmware it reports on every start | Reports the real system; one stable machine ID kept on the host |
| Downloads whatever `latest` is, runs as root | One version pinned by sha256, runs as `nonroot` (uid 65532) with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| Can reach your LAN like any program on the device | `init-wipter.sh` drops all traffic from the container to private, Tailscale, link-local and multicast ranges, and sends all DNS to AdGuard Family Protection |

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # WIPTER_EMAIL, WIPTER_PASSWORD
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
docker logs -f wipter              # "wipter-entry: signed in", then "status: Online"
```

| Variable | Required | Notes |
|---|---|---|
| `WIPTER_EMAIL` | yes | Your Wipter account (sign up in the app or on wipter.com first) |
| `WIPTER_PASSWORD` | yes | Only used when there is no saved session; never passed on to the app |
| `WIPTER_DEBUG` | no | `1` shows the app's own (noisy) output, which includes the account email |

## Notes

- **What the shim does**: the app's own code runs unchanged; the shim signs in when the sign-in form
  shows (at most 3 tries, then it waits 30 minutes and exits so Docker
  restarts it), clicks *agree* on Wipter's bandwidth-sharing consent prompt
  (the app shares nothing until it is accepted: running this image is that
  choice), switches sharing on if it stays *Offline*, and logs status
  changes.
- **Session**: kept in the `wipter-config` volume
  (`/home/nonroot/.config/wipter-app`), together with the app's own logs.
  Delete the volume to sign in from scratch.
- **Machine ID**: the app uses `/etc/machine-id` as its device fingerprint.
  `init-wipter.sh` makes one once in `/var/lib/wipter/machine-id` and mounts
  it read-only. Without it the app falls back to the hostname.
- **Containers are visible**: the app checks for `/.dockerenv`, container
  cgroups and hypervisors, and reports what it finds. Nothing here hides it.
- **Residential IPs only**: Wipter flags non-residential IPs and too many
  devices per IP. Run it once per network, at home.
- **Resources**: Electron is far heavier than the other clients here: 512 MB
  cap, 0.5 CPU, 256 pids (Chromium counts threads). The log shows the app's
  memory 5 minutes after sign-in (about 300 MB on amd64 at the sign-in form:
  app 128, page 108, network 48, Xvfb 8); lower `WIPTER_MEMORY_LIMIT` to
  fit. `WIPTER_CHROMIUM_FLAGS` adds Chromium switches (space-separated);
  `--js-flags=--lite-mode` saves ~30 MB more at some CPU cost.
- **Updates**: the app's updater can't install anything (no root, read-only
  rootfs). A new version is a new image.
- **Redistribution**: this image republishes Wipter's binary. Consider
  making `sudtanj/wipter` private on Docker Hub.

## Updating

Read `version` and the path of the build from
`https://provider-assets.wipter.com/latest/linux/x64/latest-linux.yml` (the
arm64 feed is `.../linux/arm64/latest-linux-arm64.yml`; the build folder is
the `path:` in the app's `resources/app-update.yml`, e.g.
`20261005140844_1_25_1012`). Download
`https://provider-assets.wipter.com/desktop_app/<build>/linux/<x64|arm64>/wipter-app-<amd64|arm64>.deb`,
and bump `WIPTER_VERSION`, `WIPTER_BUILD` and both sha256 values in the
Dockerfile. The build checks the version inside the .deb, and on amd64 that
the app starts and shows its sign-in form; if the form's test IDs
(`email-input`, `password-input`, `sign-in-button`) changed, update
`shim/shim.js`.
