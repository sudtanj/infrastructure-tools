# workflow-cron

A tiny always-on clock that starts GitHub Actions workflows **on time**.

GitHub's `schedule:` trigger is best effort: runs at the top of the hour often start
10-60 minutes late, and some are dropped. A `workflow_dispatch` event starts within
seconds. So workflow-cron keeps the cron table itself and, at the exact minute, calls
`POST /repos/{repo}/actions/workflows/{file}/dispatches`.

- Static Go binary (stdlib only) on `gcr.io/distroless/static`, non-root, read-only root,
  for `linux/amd64` and `linux/arm64` (cross-compiled, no QEMU at build or run time).
  About 5-10 MB of RAM: fits on the GCP free-tier e2-micro or an Orange Pi.
- Network errors, 5xx and rate limits are retried for about 5 minutes; a dispatch that
  still fails is logged and, if configured, sent to Telegram.
- If the clock jumps (VM paused, NTP step), minutes up to 10 minutes back are still fired;
  a minute is never fired twice.
- Before each dispatch it compares its clock with GitHub's (the `Date` header) and skips
  the run, with an alert, if they are more than 2 minutes apart: an Orange Pi has no
  battery-backed clock and runs on the time saved at shutdown until NTP syncs.
- On start it checks the token and every workflow against GitHub, and exits on a bad
  token or a missing workflow, so a broken deploy shows up right away.

## Configuration (environment)

| Variable | Default | |
|---|---|---|
| `WORKFLOW_CRON_GITHUB_TOKEN` | (required) | Token allowed to dispatch the workflows (Actions: write); the deploy runners pass `GH_TOKEN` unless this secret is set |
| `WORKFLOW_CRON_JOBS` | (required) | One job per line (or `;`-separated), `#` comments allowed |
| `WORKFLOW_CRON_TZ` | `UTC` | IANA zone the cron fields are in (`init-workflow-cron.sh` sets `Asia/Jakarta`) |
| `WORKFLOW_CRON_REPO` | `sudtanj/infrastructure-tools` | |
| `WORKFLOW_CRON_REF` | `main` | Branch the workflows run from |
| `WORKFLOW_CRON_TELEGRAM_TOKEN`, `WORKFLOW_CRON_TELEGRAM_CHAT_ID` | | Optional failure alert |

A job line is five cron fields, the workflow file name, then `workflow_dispatch` inputs
(a few of the lines in `init-workflow-cron.sh`):

```
# min hour dom mon dow  workflow file                    inputs
0    *    *   *   *     typescript-worker-run.yaml
0    7,17 *   *   *     android-emulator-session.yaml    exit_node=true autoplay=true
0    5    *   *   *     android-emulator-session.yaml    exit_node=true autoplay=true pinedrama=false
0    8,11,17,18 * * 1-5 commute-traffic.yaml        skip_off_days=true
```

Fields take `*`, `n`, `a-b`, `*/s`, `a-b/s` and comma lists (no names like `MON`). Input
values cannot contain spaces. Inputs left out get the workflow's defaults. Note a
dispatched run has `github.event_name == 'workflow_dispatch'`, not `schedule`: pass the
inputs that give the behaviour a scheduled run had.

Check a job list without a token:

```bash
docker run --rm -e WORKFLOW_CRON_TZ=Asia/Jakarta -e WORKFLOW_CRON_JOBS='0 5 * * * x.yaml' \
  sudtanj/workflow-cron -check
```

## On the GCP VM or the Orange Pi

[`bash-scripts/init-workflow-cron.sh`](../../bash-scripts/init-workflow-cron.sh) deploys it,
through **Run Bash Scripts on GCP VM** (`gcp-bash-script-runner.yaml`) or **Run Bash Scripts
on Orange Pi** (`orangepi-bash-script-runner.yaml`), script
`init-workflow-cron`. The job list (the one above) and the zone are written in that
script: to change the schedule, edit it, push, and re-run the deploy.
Telegram alerts reuse the `TELEGRAM_TOKEN` / `TELEGRAM_CHAT_ID` secrets.

1. Token: the runner reuses the existing `GH_TOKEN` secret. It must be allowed to dispatch
   this repo's workflows: a classic PAT with `repo` + `workflow`, or a fine-grained one with
   *Actions: Read and write* on this repo. To use a narrower token just for this, save it
   as `WORKFLOW_CRON_GITHUB_TOKEN`; it takes precedence.
2. Push: `builder-tools-docker-publish.yml` publishes `sudtanj/workflow-cron`.
3. Run ONE of the two runners with `init-workflow-cron`. Re-run it after editing the job
   list or rotating the token; it leaves the container alone when nothing changed.
   Never deploy it to both: every workflow would start twice. To move it, run the deploy
   on the new device, then `docker rm -f workflow-cron` on the old one. "all" in either
   runner skips this script, so it only runs when picked by name.

Logs: `docker logs workflow-cron` on the device (or Dozzle). Each dispatch prints how late it
was sent.

Every workflow in the job list (all the repo's crons except `opi-uptime-check.yaml`, which
watches the Orange Pi and so stays on GitHub's clock) no longer has a
`schedule:` of its own, so nothing runs twice. If the device goes away, put the
`schedule:` blocks back (the old crons are in a comment in each file).
