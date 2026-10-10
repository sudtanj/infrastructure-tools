# botkeep-n8n-infra

Minimal [n8n](https://n8n.io) deployment on [botkeep.cloud](https://botkeep.cloud), auto-deployed from GitHub.

## Layout

| File | Purpose |
| --- | --- |
| `package.json` | Pins n8n; `npm start` runs `n8n start` |
| `.env.example` | Environment variables to set on the workload |
| `scripts/set-env.sh` | Pushes an env file to the workload via the Botkeep API |
| `../.github/workflows/botkeep-n8n-deploy.yaml` | Uploads this folder over SFTP, then restarts the server |

## Setup

Botkeep servers run on Pterodactyl (`https://panel.botkeep.cloud`). Deployment uploads this folder over SFTP using your panel login.

1. **Create the server** once in the Botkeep dashboard: Node.js 22, at least 1 GB RAM and **3-4 GB storage** (n8n from npm is over 1 GB installed, so 1 GB overflows). SQLite is used, so no database is needed. Startup command (keeps the npm cache out of server storage and skips dev/optional packages):
   ```bash
   npm install --omit=dev --omit=optional --no-audit --no-fund --cache /tmp/.npm && npm start
   ```
2. **Get the SFTP details**: panel → your server → Settings → SFTP Details. You get the host, port (usually 2022) and username (`<panel-username>.<server-id>`). The password is your panel account password.
3. **GitHub** (Settings → Secrets and variables → Actions), secrets:
   - `SFTP_HOST`, `SFTP_USERNAME`, `SFTP_PASSWORD`, optional `SFTP_PORT` (default `2022`)
   - `BOTKEEP_API_KEY` (optional): used only to restart the server via the Botkeep developer API (scope `power:write`). Without it, files upload but you restart from the dashboard.
   - Optional variable `BOTKEEP_WORKLOAD_ID` (default: this server's workload ID).
4. **Environment variables**: set the values from `.env.example` in the server's Startup tab in the dashboard (or use `scripts/set-env.sh` with a Botkeep developer API key). Keep `N8N_ENCRYPTION_KEY` backed up: losing it makes stored credentials unreadable.
5. **Deploy**: push a change under `botkeep-n8n-infra/` to `main`, or run *Deploy n8n to Botkeep* manually.
   The workflow uploads only the contents of this folder over SFTP (nothing is deleted on the server) and then restarts the server.

## Notes

- Workload files persist on Botkeep storage, so the SQLite DB and `.n8n/` survive redeploys. Use Botkeep backups for the workload.
- Bump n8n by editing the version in `package.json` and pushing.
- Open the n8n URL once after the first start to create the owner account.
- **Storage over the limit?** Delete the leftovers from the earlier whole-repo sync (everything except `package.json`, `scripts/`, `README.md`, `.env.example`, `.n8n/` and `node_modules/`), remove `~/.npm` if present, then raise the storage limit in the dashboard (or use the startup command above). n8n's `node_modules` alone can exceed 1 GB.
