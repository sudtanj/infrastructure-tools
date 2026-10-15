# Orange Pi scripts

Scripts for a home device on the tailnet, run by **Run Bash Scripts on Orange Pi**
(`.github/workflows/orangepi-bash-script-runner.yaml`). They live here, not in `bash-scripts/`,
so the GCP runner's `all` never picks them up. The Orange Pi runner also accepts shared scripts
from `bash-scripts/` by name (for example `init-dozzle`).

- **`init-honeygain.sh`**: runs [`sudtanj/honeygain`](../../builder-tools/honeygain/) with the
  account from `HONEYGAIN_EMAIL` / `HONEYGAIN_PASSWORD` and the device name from
  `HONEYGAIN_DEVICE` (default: the device's hostname). Read-only root, capped at 0.5 CPU /
  128 MiB, state in the `honeygain-data` volume. DNS goes through AdGuard Family Protection by
  default (`HONEYGAIN_DNS` to override, `system` for the host resolver). Skips the restart when the image and settings
  are unchanged.

## How the workflow connects

1. The runner joins the tailnet as an ephemeral node (Tailscale OAuth client, or an auth key).
2. It SSHes to the device's Tailscale address with a password (`sshpass`).
3. The script runs with `bash -s`. `sudo` gets the same password through a temporary askpass
   helper, so scripts keep calling plain `sudo`.

Every line from the device is sanitized (IPs, emails, hostnames, secret values) before it reaches
the public log.

## Secrets to add

| Secret | Purpose |
|---|---|
| `OPI_TAILSCALE_IP` | Device's Tailscale IP or MagicDNS name |
| `OPI_SSH_USER` | SSH user |
| `OPI_SSH_PASSWORD` | SSH password (also used for sudo) |
| `OPI_SSH_PORT` | Optional, default 22 |
| `TS_OAUTH_CLIENT_ID` + `TS_OAUTH_SECRET` | Tailscale OAuth client (`auth_keys` scope); runner nodes get `tag:ci` (override with `TS_TAGS`) |
| `TS_RUNNER_AUTH_KEY` | Alternative to OAuth: an ephemeral, pre-approved auth key |
| `HONEYGAIN_EMAIL`, `HONEYGAIN_PASSWORD` | Honeygain account |
| `HONEYGAIN_DEVICE` | Optional dashboard device name |

The tailnet ACL must let the runner's tag reach the device on port 22, and `tag:ci` must be listed
in `tagOwners` when using OAuth.
