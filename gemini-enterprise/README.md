# Gemini Enterprise → Agent Gateway Setup

Routes Gemini Enterprise egress traffic through the `ping-authz-agent-gateway`, so every outbound tool call is authorized by PingAuthorize before reaching the MCP servers.

```
GE user query
  └─► GE engine (gemini-enterprise-17822488_1782248882888)
        └─► Agent Gateway (ping-authz-agent-gateway)
              └─► ping-authz-shim ext_proc
                    └─► PingAuthorize (allow / deny)
                          └─► MCP server (pingone-aic)
```

---

## Step 0 — Deploy the PingOne AIC MCP server

This directory contains its own copy of `pingone-aic-mcp` for the GE use case.
Deploy it first before setting up the gateway:

```bash
cd gemini-enterprise/pingone-aic-mcp
cp .env.sample .env
# Edit .env with your GCP project, AIC tenant URL, and service account UUID
cp /path/to/downloaded-key.jwk ./private_key.jwk
make deploy
```

See [`pingone-aic-mcp/README.md`](./pingone-aic-mcp/README.md) for full setup details.

---

## Steps completed by script

### Step 1 — Create custom IAM role  `setup-ge-gateway.sh`
Creates `projects/tech-partner-ping/roles/agentGatewayAccess` with the permissions the Discovery Engine service agent needs to enumerate Agent Registry resources and use the gateway:

```
agentregistry.agents.{list,search,get}
agentregistry.mcpServers.{list,search,get}
networkservices.agentGateways.{list,get,use}
```

### Step 2 — Bind role to Discovery Engine service agent  `setup-ge-gateway.sh`
Grants the role to:
```
service-175347687039@gcp-sa-discoveryengine.iam.gserviceaccount.com
```

### Step 3 — Verify Agent Gateway  `setup-ge-gateway.sh`
Confirms `ping-authz-agent-gateway` (us-central1) exists with `governedAccessPath: AGENT_TO_ANYWHERE`.  The gateway was originally deployed by `egress-registry-gw-mcp/gateway/setup-agent-registry.sh`.

### Step 4 — Bind gateway to GE engine  `setup-ge-gateway.sh`
PATCHes the engine's `agentGatewaySetting`:

```bash
curl -X PATCH \
  "https://us-discoveryengine.googleapis.com/v1/projects/175347687039/locations/us/\
collections/default_collection/engines/gemini-enterprise-17822488_1782248882888\
?updateMask=agentGatewaySetting.defaultEgressAgentGateway.name" \
  -d '{"agentGatewaySetting":{"defaultEgressAgentGateway":{
        "name":"projects/175347687039/locations/us-central1/agentGateways/ping-authz-agent-gateway"
      }}}'
```

> **Note:** The gateway `name` must use the project **number** (`175347687039`), not the project ID string. The endpoint must be `us-discoveryengine.googleapis.com` for `location=us`.

**Status: complete — engine binding is live as of 2026-06-23.**

---

## Step 5 — Import Agent Registry connectors  ⚠️ Manual (UI only)

The Agent Registry connector import has no public REST or CLI API — it must be done through the Gemini Enterprise web console.

1. Open the [GE console](https://console.cloud.google.com/gen-app-builder/engines?project=tech-partner-ping)
2. Click on engine **gemini-enterprise-1782248882888**
3. Go to **Configurations** → **Data Connectors** → **Add connector**
4. Select **Agent Registry** as the connector type
5. Import each resource by its exact Agent Registry name:

   | Display name | Registry resource name |
   |---|---|
   | PingOne AIC Provisioner MCP Server | `projects/tech-partner-ping/locations/us-central1/mcpServers/agentregistry-00000000-0000-0000-2638-c746341351e1` |

6. Click **Authorize** on the connector after import

---

## Step 6 — Verify the full chain

```bash
bash gemini-enterprise/verify-ge-gateway.sh
```

This checks:
- IAM role exists and is bound
- Gateway resource is healthy
- Authz extension and policy are attached
- Engine has `agentGatewaySetting` pointing at the gateway
- Cloud Run services are ready
- `gw-ping-authz-shim` logs (non-empty = traffic is flowing)

---

## Triggering a real tool call

"Saying hi" won't flow through the gateway — the gateway only intercepts **egress tool calls**, not plain chat messages.

Ask GE something that forces a tool invocation:
- *"List users in PingOne AIC"*
- *"Provision a test user in PingOne"*

Then confirm in authz-shim logs:
```bash
gcloud run services logs read gw-ping-authz-shim \
  --region=us-central1 --project=tech-partner-ping --limit=50
```

A request appearing there means it passed through PingAuthorize.

---

## Scripts

| Script | Purpose |
|---|---|
| `setup-ge-gateway.sh` | Steps 1–4: IAM, gateway verify, engine binding |
| `verify-ge-gateway.sh` | End-to-end health check of the full chain |

Re-running `setup-ge-gateway.sh` is idempotent — the IAM role creation skips if it already exists.
