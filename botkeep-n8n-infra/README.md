# botkeep-n8n-infra

Minimal [n8n](https://n8n.io) deployment on [botkeep.cloud](https://botkeep.cloud), auto-deployed from GitHub.

## Layout

| File | Purpose |
| --- | --- |
| `package.json` | Pins n8n; `npm start` runs `n8n start` |
| `.env.example` | Environment variables to set on the workload |
| `scripts/set-env.sh` | Pushes an env file to the workload via the Botkeep API |
| `../.github/workflows/botkeep-n8n-deploy.yaml` | Zips this folder, uploads and extracts it on the server, restarts it |

## Setup

Botkeep runs on Pterodactyl (`https://panel.botkeep.cloud`), so deployment uses the community
[`pterodactyl-upload-action`](https://github.com/rexlManu/pterodactyl-upload-action).

1. **Create the server** once in the Botkeep dashboard: Node.js 22, at least 1 GB RAM and **3-4 GB storage** (n8n from npm is over 1 GB installed, so 1 GB overflows). SQLite is used, so no database is needed. Startup command (keeps the npm cache out of server storage and skips dev/optional packages):
   ```bash
   npm install --omit=dev --omit=optional --no-audit --no-fund --cache /tmp/.npm && npm start
   ```
2. **Create a Pterodactyl client API key**: panel → Account → API Credentials. It starts with `ptlc_`. This is not the Botkeep developer API key.
3. **GitHub** (Settings → Secrets and variables → Actions):
   - Secret `PTERODACTYL_API_KEY`: the panel client API key from step 2 (takes precedence over `BOTKEEP_API_KEY`).
   - Optional variables `PTERO_PANEL_HOST` (default `https://panel.botkeep.cloud`) and `PTERO_SERVER_ID` (default `dc848c77`, the first 8 characters of the server UUID).
4. **Environment variables**: set the values from `.env.example` in the server's Startup tab in the dashboard (or use `scripts/set-env.sh` with a Botkeep developer API key). Keep `N8N_ENCRYPTION_KEY` backed up: losing it makes stored credentials unreadable.
5. **Deploy**: push a change under `botkeep-n8n-infra/` to `main`, or run *Deploy n8n to Botkeep* manually.
   The workflow zips only this folder, uploads the zip, extracts it on the server (the zip is deleted afterwards) and restarts the server.

## Notes

- Workload files persist on Botkeep storage, so the SQLite DB and `.n8n/` survive redeploys. Use Botkeep backups for the workload.
- Bump n8n by editing the version in `package.json` and pushing.
- Open the n8n URL once after the first start to create the owner account.
- **Storage over the limit?** Delete the leftovers from the earlier whole-repo sync (everything except `package.json`, `scripts/`, `README.md`, `.env.example`, `.n8n/` and `node_modules/`), remove `~/.npm` if present, then raise the storage limit in the dashboard (or use the startup command above). n8n's `node_modules` alone can exceed 1 GB.
