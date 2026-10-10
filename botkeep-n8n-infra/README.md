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

1. **GitHub**: add the secret `BOTKEEP_API_KEY` (scopes `workloads:read`, `workloads:create`, `deploy:write`, `settings:read`, `environment:write`) in Settings → Secrets and variables → Actions.
2. **Deploy**: push a change under `botkeep-n8n-infra/` to `main`, or run *Deploy n8n to Botkeep* manually.
   The workload is identified by the folder name (`botkeep-n8n-infra`). If it doesn't exist it is created
   (Node 22, 1 GB RAM, 50% CPU, 1 GB storage, start command `npm install --no-audit --no-fund && npm start`),
   then only the files in this folder are uploaded (`method: upload`) and the workload restarts. Edit the `with:` block in the workflow to change the sizing.
3. **Set environment variables** (after the workload exists; use the workload ID from the panel):
   ```bash
   cp botkeep-n8n-infra/.env.example .env   # fill in WEBHOOK_URL and N8N_ENCRYPTION_KEY
   BOTKEEP_API_KEY=... WORKLOAD_ID=... botkeep-n8n-infra/scripts/set-env.sh .env
   ```
   Keep `N8N_ENCRYPTION_KEY` backed up: losing it makes stored credentials unreadable. Restart the workload after changing variables.

## Notes

- Workload files persist on Botkeep storage, so the SQLite DB and `.n8n/` survive redeploys. Use Botkeep backups for the workload.
- Bump n8n by editing the version in `package.json` and pushing.
- Open the n8n URL once after the first start to create the owner account.
