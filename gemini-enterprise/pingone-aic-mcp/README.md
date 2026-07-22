# PingOne AIC MCP Server

MCP server that wraps the PingOne AIC (ForgeRock Identity Cloud) managed user API, deployed to Google Cloud Run.

## Tools

| Tool | Description |
|---|---|
| `list_users` | List / filter users in the AIC alpha realm |
| `provision_user` | Create a new user |
| `deprovision_user` | Delete a user by email |
| `update_user_status` | Enable or disable a user |

## Setup

### 1. GCP prerequisites

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Enable required APIs
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com

# Create Artifact Registry repo (only needed once)
gcloud artifacts repositories create pingone-aic-mcp-repo \
  --repository-format=docker \
  --location=us-central1

# Grant Cloud Build permission to deploy to Cloud Run and access secrets
PROJECT_NUMBER=$(gcloud projects describe YOUR_PROJECT_ID --format='value(projectNumber)')
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/run.admin"
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
gcloud iam service-accounts add-iam-policy-binding \
  ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

### 2. AIC prerequisites

In the AIC admin console, create a service account and download its private key JWK file.

### 3. Configure and deploy

```bash
cp .env.sample .env
# Edit .env with your GCP project, AIC tenant URL, and service account UUID

cp /path/to/downloaded-key.jwk ./private_key.jwk

make deploy
```

## Test

```bash
make test
```

Calls `list_users` against the live service and prints the result.

## Environment variables (`.env`)

| Variable | Description |
|---|---|
| `GCP_PROJECT` | GCP project ID |
| `GCP_REGION` | GCP region (e.g. `us-central1`) |
| `ARTIFACT_REPO` | Artifact Registry repo name |
| `SERVICE_NAME` | Cloud Run service name |
| `AIC_BASE_URL` | AIC tenant URL, e.g. `https://openam-tenant.forgeblocks.com` |
| `AIC_ADMIN_CLIENT_ID` | Service account UUID from AIC |
| `AIC_ADMIN_PRIVATE_KEY_JWK_FILE` | Path to the downloaded private key JWK file |
| `AIC_REALM` | Realm (default: `alpha`) |
| `MCP_REQUIRED_SCOPES` | Scopes advertised in OAuth discovery metadata |
