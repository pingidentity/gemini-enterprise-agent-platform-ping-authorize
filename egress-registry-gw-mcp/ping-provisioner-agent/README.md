# ping-provisioner-agent

ADK Python agent that provisions user accounts in PingOne AIC. Deployed to the
**Gemini Enterprise Agent Platform** via `deploy_agent.py`.

> **Note:** This folder also contains a Cloud Run-compatible `main.py` for local
> development. The production deployment uses `deploy_agent.py`, which enables
> Workload Identity Federation, RFC 8693 token exchange, and AGENT_IDENTITY
> egress through the Agent Gateway.

## Endpoints (Cloud Run / local)

| Method | Path | Description |
|---|---|---|
| `POST` | `/provision` | Run a provisioning instruction |
| `GET` | `/health` | Liveness probe |

```json
// POST /provision
{ "instruction": "Provision alice@example.com in PingOne AIC" }

// Response
{ "result": "Provisioned alice@example.com: AIC user_id=abc123" }
```

## Environment Variables

```
GOOGLE_CLOUD_PROJECT=       # GCP project for Vertex AI / Gemini API
GOOGLE_CLOUD_LOCATION=us-central1
AGENT_PORT=3000
GEMINI_MODEL=gemini-2.5-flash
PINGONE_AIC_MCP_URL=        # https://gw-pingone-aic-mcp-*.run.app/mcp
```

## Local Development

```bash
pip install -r requirements.txt
cp .env.sample .env
python main.py
```

## Deploy via Cloud Build

```bash
gcloud builds submit \
  --config egress-registry-gw-mcp/ping-provisioner-agent/cloudbuild.yaml .
```

For Agent Platform deployment (production), see `deploy_agent.py` in this folder.
