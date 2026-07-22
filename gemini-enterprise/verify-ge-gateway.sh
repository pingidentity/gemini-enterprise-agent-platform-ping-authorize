#!/usr/bin/env bash
# verify-ge-gateway.sh
#
# Verifies that the Agent Gateway → PingAuthorize chain is wired correctly for
# a Gemini Enterprise engine.  Run this after completing the connector import
# in the GE UI (see README.md Step 5).
#
# Usage:
#   bash verify-ge-gateway.sh
#   LOG_LIMIT=100 bash verify-ge-gateway.sh   # tail more authz-shim log lines

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tech-partner-ping}"
PROJECT_NUMBER="${PROJECT_NUMBER:-175347687039}"
GE_LOCATION="${GE_LOCATION:-us}"
REGION="${REGION:-us-central1}"
AGENT_GATEWAY_NAME="${AGENT_GATEWAY_NAME:-ping-authz-agent-gateway}"
ENGINE_ID="${ENGINE_ID:-gemini-enterprise-17822488_1782248882888}"
LOG_LIMIT="${LOG_LIMIT:-30}"

DE_ENDPOINT="us-discoveryengine.googleapis.com"
TOKEN=$(gcloud auth print-access-token)

ok()   { echo "  [OK]  $*"; }
warn() { echo "  [WARN] $*"; }
fail() { echo "  [FAIL] $*"; }

echo "========================================================"
echo "  Agent Gateway ↔ GE Verification"
echo "  Project : ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "  Engine  : ${ENGINE_ID}"
echo "  Region  : ${REGION}"
echo "========================================================"
echo ""

# ── 1. IAM role exists ────────────────────────────────────────────────────────
echo "── 1. Custom IAM role"
if gcloud alpha iam roles describe agentGatewayAccess \
     --project="${PROJECT_ID}" &>/dev/null; then
  ok "projects/${PROJECT_ID}/roles/agentGatewayAccess exists"
else
  fail "Role not found — run setup-ge-gateway.sh"
fi

# ── 2. Discovery Engine SA has the role ───────────────────────────────────────
echo "── 2. Discovery Engine service agent IAM binding"
SA="service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
BINDING=$(gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --format="value(bindings.role)" \
  --filter="bindings.members:serviceAccount:${SA}" 2>/dev/null \
  | grep "agentGatewayAccess" || true)
if [[ -n "${BINDING}" ]]; then
  ok "${SA} → agentGatewayAccess"
else
  fail "${SA} missing agentGatewayAccess — run setup-ge-gateway.sh Step 2"
fi

# ── 3. Agent Gateway exists and is AGENT_TO_ANYWHERE ─────────────────────────
echo "── 3. Agent Gateway resource"
GW_RESP=$(curl -sf -X GET \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://networkservices.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGENT_GATEWAY_NAME}" 2>/dev/null || echo "ERROR")
if echo "${GW_RESP}" | grep -q "AGENT_TO_ANYWHERE"; then
  ok "Gateway '${AGENT_GATEWAY_NAME}' exists, governedAccessPath=AGENT_TO_ANYWHERE"
else
  fail "Gateway not found or misconfigured — run egress-registry-gw-mcp/gateway/setup-agent-registry.sh"
fi

# ── 4. Authz extension exists ─────────────────────────────────────────────────
echo "── 4. Authz extension (ping-authz-ext)"
EXT=$(gcloud beta service-extensions authz-extensions describe ping-authz-ext \
  --location="${REGION}" --project="${PROJECT_ID}" \
  --format="value(name)" 2>/dev/null || echo "")
if [[ -n "${EXT}" ]]; then
  ok "ping-authz-ext exists"
else
  warn "ping-authz-ext not found — may affect authorization enforcement"
fi

# ── 5. Authz policy is attached ───────────────────────────────────────────────
echo "── 5. Authz policy (ping-authz-policy)"
POLICY=$(gcloud beta network-security authz-policies describe ping-authz-policy \
  --location="${REGION}" --project="${PROJECT_ID}" \
  --format="value(name)" 2>/dev/null || echo "")
if [[ -n "${POLICY}" ]]; then
  ok "ping-authz-policy exists"
else
  warn "ping-authz-policy not found — run egress-registry-gw-mcp/gateway/setup-agent-registry.sh"
fi

# ── 6. GE engine has agentGatewaySetting bound ────────────────────────────────
echo "── 6. GE engine agentGatewaySetting"
ENGINE_RESP=$(curl -sf -X GET \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  "https://${DE_ENDPOINT}/v1/projects/${PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/engines/${ENGINE_ID}" 2>/dev/null || echo "ERROR")
if echo "${ENGINE_RESP}" | python3 -m json.tool 2>/dev/null | grep -q "agentGatewaySetting"; then
  GW_BINDING=$(echo "${ENGINE_RESP}" | python3 -c "
import json,sys
e=json.load(sys.stdin)
print(e.get('agentGatewaySetting',{}).get('defaultEgressAgentGateway',{}).get('name','NOT SET'))
" 2>/dev/null || echo "parse error")
  ok "agentGatewaySetting.defaultEgressAgentGateway = ${GW_BINDING}"
else
  fail "Engine has no agentGatewaySetting — run setup-ge-gateway.sh"
fi

# ── 7. Agent Registry MCP servers registered ──────────────────────────────────
echo "── 7. Agent Registry MCP servers"
MCP_COUNT=$(gcloud alpha agent-registry mcp-servers list \
  --project="${PROJECT_ID}" --location="${REGION}" \
  --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${MCP_COUNT}" -ge 1 ]]; then
  ok "${MCP_COUNT} MCP server(s) in registry"
  gcloud alpha agent-registry mcp-servers list \
    --project="${PROJECT_ID}" --location="${REGION}" \
    --format="value(displayName,name)" 2>/dev/null \
    | while IFS= read -r line; do echo "        ${line}"; done
else
  warn "No MCP servers in registry (found ${MCP_COUNT})"
fi

# ── 8. Cloud Run services are up ──────────────────────────────────────────────
echo "── 8. Cloud Run services (ready state)"
for SVC in gw-ping-authz-shim gw-pingone-aic-mcp gw-ping-provisioner-agent; do
  READY=$(gcloud run services describe "${SVC}" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(status.conditions[0].status)" 2>/dev/null || echo "NOT_FOUND")
  if [[ "${READY}" == "True" ]]; then
    ok "${SVC} is ready"
  else
    warn "${SVC} — status: ${READY}"
  fi
done

# ── 9. Recent authz-shim logs (traffic indicator) ─────────────────────────────
echo "── 9. Recent gw-ping-authz-shim logs (last ${LOG_LIMIT} lines)"
echo "       (non-empty = traffic has flowed through PingAuthorize)"
gcloud run services logs read gw-ping-authz-shim \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --limit="${LOG_LIMIT}" 2>/dev/null \
  | grep -v "^$" \
  | tail -20 \
  || warn "No logs or service not found"

echo ""
echo "========================================================"
echo "  Summary"
echo ""
echo "  If all checks passed and authz-shim logs show requests,"
echo "  the full chain is working:"
echo ""
echo "    GE query → Agent Gateway → ping-authz-shim"
echo "             → PingAuthorize (allow/deny)"
echo "             → MCP server (pingone-aic)"
echo ""
echo "  Trigger a real tool call in GE to generate traffic:"
echo "    'List users in PingOne AIC'"
echo "    'Provision a test user in PingOne'"
echo "========================================================"
