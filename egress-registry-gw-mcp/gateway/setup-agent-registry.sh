#!/usr/bin/env bash
# setup-agent-registry.sh
#
# Registers the gw-ping-provisioner-agent and gw-pingone-aic-mcp-server in
# GCP Agent Registry, then creates the Agent Gateway
# (egress) and attaches the PingAuthorize authz extension.
#
# Prerequisites:
#   gcloud components install alpha
#   gcloud services enable agentregistry.googleapis.com --project=$PROJECT_ID
#   gcloud services enable networkservices.googleapis.com --project=$PROJECT_ID
#   gcloud services enable networksecurity.googleapis.com --project=$PROJECT_ID
#
# Required IAM roles on the service account running this script:
#   roles/agentregistry.editor
#   roles/networkservices.serviceExtensionsAdmin (or equivalent)
#   roles/networksecurity.securityPolicyAdmin
#
# Usage:
#   PROJECT_ID=tech-partner-ping REGION=us-central1 bash setup-agent-registry.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tech-partner-ping}"
REGION="${REGION:-us-central1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "==> Enabling required APIs"
gcloud services enable \
  agentregistry.googleapis.com \
  networkservices.googleapis.com \
  networksecurity.googleapis.com \
  --project="${PROJECT_ID}"

# ── Resolve Cloud Run service URLs ──────────────────────────────────────────
echo "==> Resolving Cloud Run service URLs"

PROVISIONER_URL=$(gcloud run services describe gw-ping-provisioner-agent \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)')

PINGONE_MCP_URL=$(gcloud run services describe gw-pingone-aic-mcp \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)')

AUTHZ_SHIM_URL=$(gcloud run services describe gw-ping-authz-shim \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)')

# Strip https:// to get the bare FQDN for the authz extension
AUTHZ_SHIM_FQDN="${AUTHZ_SHIM_URL#https://}"

echo "  gw-ping-provisioner-agent : ${PROVISIONER_URL}"
echo "  gw-pingone-aic-mcp        : ${PINGONE_MCP_URL}"
echo "  ping-authz-shim           : ${AUTHZ_SHIM_URL} (FQDN: ${AUTHZ_SHIM_FQDN})"

# ── Register gw-ping-provisioner-agent ─────────────────────────────────────────
echo "==> Registering gw-ping-provisioner-agent in Agent Registry"
gcloud alpha agent-registry services create gw-ping-provisioner-agent \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --display-name="Ping Provisioner Agent" \
  --agent-spec-type=no-spec \
  --interfaces="url=${PROVISIONER_URL},protocolBinding=HTTP_JSON" \
  || gcloud alpha agent-registry services update gw-ping-provisioner-agent \
       --project="${PROJECT_ID}" \
       --location="${REGION}" \
       --interfaces="url=${PROVISIONER_URL},protocolBinding=HTTP_JSON"

# ── Register gw-pingone-aic-mcp-server ─────────────────────────────────────────
echo "==> Registering gw-pingone-aic-mcp-server in Agent Registry"
gcloud alpha agent-registry services create gw-pingone-aic-mcp-server \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --display-name="PingOne AIC Provisioner MCP Server" \
  --mcp-server-spec-type=tool-spec \
  --mcp-server-spec-content="${REPO_DIR}/egress-registry-gw-mcp/pingone-aic-mcp/toolspec.json" \
  --interfaces="url=${PINGONE_MCP_URL},protocolBinding=JSONRPC" \
  || gcloud alpha agent-registry services update gw-pingone-aic-mcp-server \
       --project="${PROJECT_ID}" \
       --location="${REGION}" \
       --mcp-server-spec-content="${REPO_DIR}/egress-registry-gw-mcp/pingone-aic-mcp/toolspec.json" \
       --interfaces="url=${PINGONE_MCP_URL},protocolBinding=JSONRPC"

# ── Verify Agent Registry entries ───────────────────────────────────────────
echo "==> Registered agents:"
gcloud alpha agent-registry agents list \
  --project="${PROJECT_ID}" --location="${REGION}"

echo "==> Registered MCP servers:"
gcloud alpha agent-registry mcp-servers list \
  --project="${PROJECT_ID}" --location="${REGION}"

# ── Create Agent Gateway (egress) ───────────────────────────────────────────
echo "==> Creating Agent Gateway (egress)"
# Patch the registry reference into the YAML using the actual project ID.
GATEWAY_YAML=$(mktemp)
sed "s|tech-partner-ping|${PROJECT_ID}|g; s|us-central1|${REGION}|g" \
  "${SCRIPT_DIR}/agent-gateway-egress.yaml" > "${GATEWAY_YAML}"

gcloud alpha network-services agent-gateways import ping-authz-agent-gateway \
  --source="${GATEWAY_YAML}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
rm -f "${GATEWAY_YAML}"

# ── Create authorization extension (ping-authz-shim) ────────────────────────
echo "==> Creating authz extension for ping-authz-shim"
AUTHZ_EXT_YAML=$(mktemp)
sed "s|PING_AUTHZ_SHIM_FQDN|${AUTHZ_SHIM_FQDN}|g" \
  "${SCRIPT_DIR}/authz-extension.yaml" > "${AUTHZ_EXT_YAML}"

gcloud beta service-extensions authz-extensions import ping-authz-ext \
  --source="${AUTHZ_EXT_YAML}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
rm -f "${AUTHZ_EXT_YAML}"

# ── Create authorization policy ─────────────────────────────────────────────
echo "==> Creating authz policy (attaching shim to gateway)"
AUTHZ_POLICY_YAML=$(mktemp)
sed "s|tech-partner-ping|${PROJECT_ID}|g; s|us-central1|${REGION}|g" \
  "${SCRIPT_DIR}/authz-policy.yaml" > "${AUTHZ_POLICY_YAML}"

gcloud beta network-security authz-policies import ping-authz-policy \
  --source="${AUTHZ_POLICY_YAML}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
rm -f "${AUTHZ_POLICY_YAML}"

# ── Resolve Agent Gateway URL and update the provisioner agent ───────────────
echo "==> Resolving Agent Gateway URL"
GATEWAY_URL=$(gcloud alpha network-services agent-gateways describe ping-authz-agent-gateway \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format='value(addresses[0].value)' 2>/dev/null || true)

if [[ -n "${GATEWAY_URL}" ]]; then
  echo "  Agent Gateway URL: ${GATEWAY_URL}"
  echo "==> Updating gw-ping-provisioner-agent with AGENT_GATEWAY_URL"
  gcloud run services update gw-ping-provisioner-agent \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --update-env-vars="AGENT_GATEWAY_URL=${GATEWAY_URL}"
  echo "  gw-ping-provisioner-agent updated: AGENT_GATEWAY_URL=${GATEWAY_URL}"
else
  echo "  WARNING: Could not auto-resolve Agent Gateway URL."
  echo "  Run the following after the gateway becomes active:"
  echo ""
  echo "    GATEWAY_URL=\$(gcloud alpha network-services agent-gateways describe ping-authz-agent-gateway \\"
  echo "      --location=${REGION} --project=${PROJECT_ID} --format='value(addresses[0].value)')"
  echo "    gcloud run services update gw-ping-provisioner-agent \\"
  echo "      --region=${REGION} --project=${PROJECT_ID} \\"
  echo "      --update-env-vars=\"AGENT_GATEWAY_URL=\${GATEWAY_URL}\""
fi

echo ""
echo "==> Setup complete."
echo ""
echo "    Agent Registry:  https://console.cloud.google.com/agent-registry?project=${PROJECT_ID}"
echo "    Verify agent:    gcloud alpha agent-registry agents list --project=${PROJECT_ID} --location=${REGION}"
echo "    Verify MCPs:     gcloud alpha agent-registry mcp-servers list --project=${PROJECT_ID} --location=${REGION}"
echo ""
