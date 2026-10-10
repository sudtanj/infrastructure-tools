# botkeep-n8n-infra

Minimal [n8n](https://n8n.io) deployment on [botkeep.cloud](https://botkeep.cloud), auto-deployed from GitHub.

## Layout

| File | Purpose |
| --- | --- |
| `package.json` | Pins n8n; `npm start` runs `n8n start` |
| `.env.example` | Environment variables to set on the workload |
| `scripts/set-env.sh` | Pushes an env file to the workload via the Botkeep API |
| `../.github/workflows/botkeep-n8n-deploy.yaml` | Deploys this folder on push (uses the reusable `botkeep-deploy.yml`) |

## Setup

1. **Create the workload** in the Botkeep panel: platform `general`, runtime Node.js 20+ (or 22), source `blank` or this repo.
   Start command: `npm install --no-audit --no-fund && npm start`.
   Resources: at least 512 MB RAM (1 GB recommended), 50% CPU, 1 GB storage. SQLite is used, so no database is needed.
2. **Set environment variables**:
   ```bash
   cp botkeep-n8n-infra/.env.example .env   # fill in WEBHOOK_URL and N8N_ENCRYPTION_KEY
   BOTKEEP_API_KEY=... WORKLOAD_ID=... botkeep-n8n-infra/scripts/set-env.sh .env
   ```
   Keep `N8N_ENCRYPTION_KEY` backed up: losing it makes stored credentials unreadable.
3. **Configure GitHub** (Settings → Secrets and variables → Actions):
   - Secret `BOTKEEP_API_KEY` (scopes `deploy:write`, `workloads:read`, `settings:read`, `environment:write`)
   - Variables `BOTKEEP_N8N_WORKLOAD_ID` and `BOTKEEP_N8N_WORKLOAD_NAME`
4. **Deploy**: push a change under `botkeep-n8n-infra/` to `main`, or run *Deploy n8n to Botkeep* manually.
   The workflow syncs only this folder (`mode: folder`) and restarts the workload.

## Notes

- Workload files persist on Botkeep storage, so the SQLite DB and `.n8n/` survive redeploys. Use Botkeep backups for the workload.
- Bump n8n by editing the version in `package.json` and pushing.
- Open the n8n URL once after the first start to create the owner account.
