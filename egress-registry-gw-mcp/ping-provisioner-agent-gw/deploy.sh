#!/usr/bin/env bash
set -euo pipefail

PROJECT="${GCP_PROJECT:-tech-partner-ping}"
REGION="${GCP_REGION:-us-central1}"
AGENT_RESOURCE="${AGENT_RESOURCE_NAME:-projects/175347687039/locations/us-central1/reasoningEngines/7733215472602054656}"
SERVICE_NAME="ping-provisioner-agent-gw"
REPO="agent-platform"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/${SERVICE_NAME}:latest"

cd "$(dirname "$0")"

echo "==> Building and pushing image to Artifact Registry..."
gcloud builds submit \
  --tag "${IMAGE}" \
  --project "${PROJECT}" \
  .

echo "==> Deploying to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --project "${PROJECT}" \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --set-env-vars "GCP_PROJECT=${PROJECT},GCP_REGION=${REGION},AGENT_RESOURCE_NAME=${AGENT_RESOURCE}"

echo "==> Done! Service URL:"
gcloud run services describe "${SERVICE_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT}" \
  --format "value(status.url)"
