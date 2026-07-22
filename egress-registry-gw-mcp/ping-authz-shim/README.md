# gw-ping-authz-shim

Envoy `ext_proc` gRPC service for the identity provisioning Agent Gateway
(`ping-authz-agent-gateway`). On every MCP `tools/call`, the Agent Gateway
calls this shim synchronously; the shim extracts policy attributes from the
request body and consults PingAuthorize before allowing or denying the call.

Deployed as Cloud Run service `gw-ping-authz-shim` (internal ingress, HTTP/2).

## Differences from `ingress-public-lb-mcp/ping-authz-shim`

| | Ingress shim | This shim |
|---|---|---|
| Accepted paths | `/mcp` only | `/mcp`, `/mcp/*` |
| Policy attributes | Stripe purchase fields | Identity provisioning fields |

The `:path` attribute (e.g. `/mcp/pingone`) tells PingAuthorize which
identity system is targeted without needing to inspect the tool arguments.

## Policy Attributes

Sent to PingAuthorize on every `tools/call`:

```json
{
  "attributes": {
    "access_token": "<delegated bearer token>",
    ":path": "/mcp/pingone",
    ":method": "POST",
    "mcp_method": "tools/call",
    "mcp_tool_name": "provision_user",
    "mcp_email": "alice@example.com",
    "mcp_username": "alice.smith"
  }
}
```

## Environment Variables

```
SHIM_SERVER_PORT=8080
PING_AUTHORIZE_URL=               # PingAuthorize governance engine endpoint
MCP_SERVER_URL=                   # Agent Gateway URL (used in WWW-Authenticate)
PING_AUTHORIZE_SKIP_TLS_VERIFY=false
MCP_REQUIRED_SCOPES=pingone:provisioning
```

## Local Development

```bash
cp .env.sample .env
export $(cat .env | xargs)
go run .
```

## Deploy

```bash
gcloud builds submit \
  --config egress-registry-gw-mcp/ping-authz-shim/cloudbuild.yaml .
```
