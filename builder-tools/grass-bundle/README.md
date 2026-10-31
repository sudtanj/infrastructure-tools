# grass-bundle

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

Not a runnable container (`FROM scratch`): prebuilt files for running stock
Google Chrome with the official [Grass](https://grass.io) "Lite Node"
extension in a GitHub Actions job on the self-hosted Instabox runner (no
Docker, no TUN, no X server), with all traffic leaving through a Tailscale exit
node. Built like [wipter-bundle](../wipter-bundle) in its open-network mode;
the job downloads the layers from Docker Hub with `curl` and runs `run.sh`.
**`linux/amd64` only.**

| File | What |
|---|---|
| `rt/chrome/` | `google-chrome-stable` from Google's `.deb`, with its libraries, Xvfb, x11vnc and fonts, relocated (as in wipter-bundle) to run from `/tmp/grass-rt` |
| `graftcp` | same build as wipter-bundle's: sends whatever Chrome connects to past its proxy setting to tailscaled's SOCKS5 port |
| `tailscale`, `tailscaled` | `tailscale/tailscale:v1.104.1`, userspace mode |
| `run.sh` | joins the tailnet as `grass-instabox`, sets the exit node, checks the path, runs Chrome; its header lists the environment variables |

Chrome gets `--proxy-server=socks5://127.0.0.1:1058` (tailscaled) and
`--force-webrtc-ip-handling-policy=disable_non_proxied_udp`, and runs under
graftcp too. Before it starts, the IP seen through both paths must differ from
the machine's own; it is stopped if the exit node is unset or offline for 10
minutes. Ports (1058, 5901, display `:97`) don't clash with wipter-bundle's.

**Sandbox**: `--no-sandbox` by default, like wipter-bundle (no setuid helper in
a download, Chrome refuses root, and the job container is the boundary).
`GRASS_SANDBOX=1` tries Chrome's user-namespace sandbox when the runner allows
it (untested under graftcp).

## One-time setup (over VNC)

Branded Chrome ignores `--load-extension`, so the extension is installed by
hand once; it and the Grass sign-in then live in the profile the workflow
saves (`$RUN_DIR/home`).

1. Allow your devices to reach the runner's tag on port 5900 in the tailnet ACL.
2. Run the workflow with `vnc_listen` and connect a VNC viewer to
   `grass-instabox:5900` (password: the VNC secret).
3. In Chrome, open
   `https://chromewebstore.google.com/detail/ilehaonighjijnmpnagapkhpcdbhclfg`,
   add the extension, then sign in to Grass at `https://app.grass.io/` and in
   the extension.
4. Wait for a state save (every 15 min, and at the end of the run).

## Environment

`TS_AUTHKEY`, `TS_TAGS`, `TS_EXIT_NODE`, `RUN_SECONDS`, `RUN_DIR`,
`VNC_LISTEN` + `GRASS_VNC_PASSWORD`, `TS_API_TOKEN` + `TS_FIXED_IP`,
`GRASS_CDP=1` (DevTools on tailnet port 9222, connect by the 100.x IP), `GRASS_URL`, `GRASS_TZ` (default `Asia/Jakarta`, match the exit node), `GRASS_CACHE_DIR` (Chrome's 64 MB HTTP cache; the workflow puts it on disk), `GRASS_DEBUG=1` (Chrome's output, masked), `GRASS_SANDBOX=1`.
Details in `run.sh`.

## One client per connection

Grass pays per internet connection (IP): a second client on the same home
connection earns nothing extra. Run this only where no other Grass client
shares the exit node's connection.

## Updating

Chrome: every rebuild takes Google's current stable (the weekly no-cache build
too). graftcp: with wipter-bundle and proxyrack-bundle. Tailscale: Dependabot.
