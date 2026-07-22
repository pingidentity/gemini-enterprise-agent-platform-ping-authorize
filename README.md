# Gemini Enterprise Agent Platform + PingAuthorize

AI agents can invoke tools with real-world consequences — charging a payment card, provisioning an account, modifying a record. These reference implementations show how to put [**PingAuthorize**](https://www.pingidentity.com/en/product/pingauthorize.html) in the call path so every [**MCP**](https://modelcontextprotocol.io/docs/getting-started/intro) `tools/call` is authorized by policy before it reaches a backend, regardless of which agent issued it.

Both patterns run on **Google Cloud** — agents on the **Gemini Enterprise Agent Platform**, MCP servers and authorization shims on Cloud Run — with [**PingOne AIC**](https://www.pingidentity.com/en/platform/pingone-advanced-identity-cloud.html) handling identity and **PingAuthorize** enforcing policy. Two enforcement patterns are covered: **public client → GCP-hosted MCP server** (via Regional Load Balancer), and **GCP-hosted agent → GCP-hosted MCP backends** (via Agent Gateway).

---

## Use Case 1 — Ingress: AI Shopping Agent

**Directory:** [`ingress-public-lb-mcp/`](./ingress-public-lb-mcp/)

A consumer-facing storefront where an authenticated user converses with an AI
shopping assistant. The agent acts on behalf of the user via RFC 8693 token
exchange; every Stripe tool call is authorized by PingAuthorize before
execution.

![](./_docs/ingress_lb_diagram.png)

**How it works:**
1. User logs in via PingOne AIC (PKCE). The access token contains a `may_act` claim granting the agent permission to act on their behalf.
2. UI sends the user token to `ping-store-agent`, which validates it and performs RFC 8693 token exchange — producing a delegated token that carries both user and agent identity.
3. The Strands AI agent calls MCP tools through the GCP Regional Load Balancer.
4. The load balancer's Traffic Extension calls `lb-ping-authz-shim` via gRPC. The shim extracts the token, tool name, and payment arguments, then calls PingAuthorize for a PERMIT/DENY decision.
5. Permitted requests reach `lb-stripe-mcp`; denied requests receive a 403 — `stripe-mcp` never sees them.

**Key characteristics:**
- `lb-stripe-mcp` and `lb-ping-authz-shim` are internal-only — unreachable without passing through the load balancer
- PingAuthorize receives the delegated token plus tool arguments (product ID, quantity, total price) on every call, enabling attribute-based payment authorization

---

## Use Case 2 — Egress: Identity Provisioning Agent

**Directory:** [`egress-registry-gw-mcp/`](./egress-registry-gw-mcp/)

A React chat UI lets administrators provision user accounts in **PingOne AIC**
by conversing with a Gemini AI agent. The agent runs on the
**Gemini Enterprise Agent Platform**; every MCP tool call routes through the
**GCP Agent Gateway** and is authorized by PingAuthorize before reaching a backend.

![](./_docs/egress_gw_diagram.png)

**How it works:**
1. User logs in via PingOne AIC (PKCE). The UI exchanges the AIC OIDC token for a Google federated credential via **Workload Identity Federation** (Google STS).
2. The browser uses the Google token to call the Gemini Enterprise Agent Platform directly — no Cloud Run proxy.
3. The raw AIC token is passed into the session state. The agent's `header_provider` performs **RFC 8693 token exchange** before each MCP call, producing a delegated token (sub=user, act.sub=agent).
4. MCP calls route through the **GCP Agent Gateway** (AGENT_TO_ANYWHERE mode), which calls `gw-ping-authz-shim` via ext_proc.
5. The shim sends the delegated token, tool name, and provisioning arguments to PingAuthorize. Permitted calls reach the MCP backend; denied calls are rejected.

**Key characteristics:**
- Browser authenticates to the Gemini Enterprise Agent Platform directly via WIF — no intermediate service
- Agent and MCP servers are registered in GCP Agent Registry (visible in the Gemini Enterprise Agent Platform console)
- PingAuthorize receives the full delegated identity (user + agent) on every call, enabling policies like "deny `deprovision_user` unless agent is in approved-deprovisioners"

---

## Common Pattern

Both use cases share the same enforcement mechanism — a `ping-authz-shim`
gRPC service attached to the network control plane:

| | UC1 — Ingress | UC2 — Egress |
|---|---|---|
| **Control plane** | GCP Regional Load Balancer | GCP Agent Gateway |
| **Shim attachment** | Traffic Extension (ext_proc on URL map) | CONTENT_AUTHZ authz extension + policy |
| **Token flow** | RFC 8693 in agent backend | RFC 8693 inside Agent Platform |
| **Identity federation** | PingOne AIC only | PingOne AIC → WIF → Google STS |

In both cases, `ping-authz-shim` parses the MCP JSON-RPC body, extracts the
bearer token and tool arguments, and calls PingAuthorize for a `PERMIT` or
`DENY` decision on every `tools/call`.
