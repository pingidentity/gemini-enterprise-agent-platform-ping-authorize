#!/usr/bin/env bash
# setup-ge-gateway.sh
#
# Wires the existing Agent Gateway (ping-authz-agent-gateway) into a
# Gemini Enterprise engine so that GE egress traffic flows through the
# gateway and through PingAuthorize policy enforcement.
#
# Based on:
#   https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/agent-gateway-ge-deploy
#
# Prerequisites:
#   - Agent Gateway already deployed (egress-registry-gw-mcp/gateway/setup-agent-registry.sh)
#   - gcloud components install alpha
#   - A Gemini Enterprise engine exists in this project
#
# Required IAM: roles/iam.roleAdmin (or equivalent) + roles/resourcemanager.projectIamAdmin
#
# Usage:
#   ENGINE_ID=your-engine-id bash setup-ge-gateway.sh
#   # Or set all vars explicitly:
#   PROJECT_ID=tech-partner-ping GE_LOCATION=us ENGINE_ID=your-engine-id bash setup-ge-gateway.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tech-partner-ping}"
PROJECT_NUMBER="${PROJECT_NUMBER:-175347687039}"
GE_LOCATION="${GE_LOCATION:-us}"
REGION="${REGION:-us-central1}"        # us → us-central1 per GE location mapping
AGENT_GATEWAY_NAME="${AGENT_GATEWAY_NAME:-ping-authz-agent-gateway}"
AGENT_GATEWAY_ROLE_NAME="${AGENT_GATEWAY_ROLE_NAME:-agentGatewayAccess}"
ENGINE_ID="${ENGINE_ID:-gemini-enterprise-17822488_1782248882888}"

echo "==> Configuration"
echo "    PROJECT_ID          : ${PROJECT_ID}"
echo "    PROJECT_NUMBER      : ${PROJECT_NUMBER}"
echo "    GE_LOCATION         : ${GE_LOCATION}"
echo "    AGENT_GATEWAY_REGION: ${REGION}"
echo "    AGENT_GATEWAY_NAME  : ${AGENT_GATEWAY_NAME}"
echo "    ENGINE_ID           : ${ENGINE_ID}"
echo ""

# ── Step 1: Create custom IAM role ──────────────────────────────────────────
echo "==> Step 1: Creating custom IAM role '${AGENT_GATEWAY_ROLE_NAME}'"
gcloud alpha iam roles create "${AGENT_GATEWAY_ROLE_NAME}" \
  --project="${PROJECT_ID}" \
  --title="Custom Agent Gateway and Agent Registry access role" \
  --description="Grants Discovery Engine service agent access to Agent Gateway and Agent Registry" \
  --permissions="agentregistry.agents.list,agentregistry.agents.search,agentregistry.agents.get,agentregistry.mcpServers.list,agentregistry.mcpServers.search,agentregistry.mcpServers.get,networkservices.agentGateways.list,networkservices.agentGateways.get,networkservices.agentGateways.use" \
  || echo "  Role already exists, skipping creation."

# ── Step 2: Bind role to Discovery Engine service agent ─────────────────────
echo "==> Step 2: Binding role to Discovery Engine service agent"
gcloud alpha projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="projects/${PROJECT_ID}/roles/${AGENT_GATEWAY_ROLE_NAME}"

# ── Step 3: Verify Agent Gateway exists ─────────────────────────────────────
echo "==> Step 3: Verifying Agent Gateway '${AGENT_GATEWAY_NAME}' in ${REGION}"
curl -sf -X GET \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://networkservices.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGENT_GATEWAY_NAME}" \
  | python3 -m json.tool --no-ensure-ascii 2>/dev/null \
  || echo "  WARNING: Could not verify gateway. Ensure it was deployed first."

# Regional endpoint: global → discoveryengine, us/eu → <region>-discoveryengine
if [[ "${GE_LOCATION}" == "global" ]]; then
  DE_ENDPOINT="discoveryengine.googleapis.com"
else
  DE_ENDPOINT="${GE_LOCATION}-discoveryengine.googleapis.com"
fi

# ── Step 4: Bind Agent Gateway to Gemini Enterprise engine ──────────────────
echo "==> Step 4: Binding Agent Gateway to engine '${ENGINE_ID}' (location: ${GE_LOCATION})"
curl -sf -X PATCH \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -d "{
    \"agentGatewaySetting\": {
      \"defaultEgressAgentGateway\": {
        \"name\": \"projects/${PROJECT_NUMBER}/locations/${REGION}/agentGateways/${AGENT_GATEWAY_NAME}\"
      }
    }
  }" \
  "https://${DE_ENDPOINT}/v1/projects/${PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/engines/${ENGINE_ID}?updateMask=agentGatewaySetting.defaultEgressAgentGateway.name" \
  | python3 -m json.tool --no-ensure-ascii

# ── Step 5: Verify engine now has gateway binding ────────────────────────────
echo "==> Step 5: Verifying engine gateway binding"
curl -sf -X GET \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -H "Content-Type: application/json" \
  "https://${DE_ENDPOINT}/v1/projects/${PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/engines/${ENGINE_ID}" \
  | python3 -m json.tool --no-ensure-ascii \
  | grep -A5 "agentGatewaySetting" || echo "  agentGatewaySetting not present — binding may still be propagating."

echo ""
echo "==> Setup complete."
echo ""
echo "    Next steps:"
echo "    1. Import agents/MCP servers from the Agent Registry into your GE engine"
echo "       (Gemini Enterprise UI → Data Connectors → Agent Registry)"
echo "    2. Authorize data connectors via the GE UI"
echo "    3. Test: submit a query in GE that triggers an external tool"
echo "       and confirm it routes through ping-authz-agent-gateway"
echo ""
echo "    Agent Registry console:"
echo "      https://console.cloud.google.com/agent-registry?project=${PROJECT_ID}"
echo "    Gemini Enterprise console:"
echo "      https://console.cloud.google.com/gen-app-builder/engines?project=${PROJECT_ID}"
echo ""
