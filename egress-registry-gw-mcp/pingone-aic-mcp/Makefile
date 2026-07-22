include .env
export

.PHONY: deploy test

deploy:
	@echo "→ Pushing secrets to Secret Manager..."
	@gcloud secrets describe aic-admin-client-id --project=$(GCP_PROJECT) &>/dev/null || \
	  gcloud secrets create aic-admin-client-id --project=$(GCP_PROJECT) --replication-policy=automatic
	@printf '%s' "$(AIC_ADMIN_CLIENT_ID)" \
	  | gcloud secrets versions add aic-admin-client-id --project=$(GCP_PROJECT) --data-file=-
	@gcloud secrets describe aic-admin-private-key-jwk --project=$(GCP_PROJECT) &>/dev/null || \
	  gcloud secrets create aic-admin-private-key-jwk --project=$(GCP_PROJECT) --replication-policy=automatic
	@python3 -c "import json; print(json.dumps(json.load(open('$(AIC_ADMIN_PRIVATE_KEY_JWK_FILE)')), separators=(',',':')))" \
	  | gcloud secrets versions add aic-admin-private-key-jwk --project=$(GCP_PROJECT) --data-file=-
	@echo "→ Deploying via Cloud Build..."
	@gcloud builds submit \
	  --project=$(GCP_PROJECT) \
	  --config=cloudbuild.yaml \
	  --region=$(GCP_REGION) \
	  --substitutions=_GCP_PROJECT_ID=$(GCP_PROJECT),_GCP_REGION=$(GCP_REGION),_PINGONE_AIC_MCP_REPO=$(ARTIFACT_REPO),_SERVICE_NAME=$(SERVICE_NAME) \
	  .
	@echo "✓ Service URL:"
	@gcloud run services describe $(SERVICE_NAME) --region=$(GCP_REGION) --project=$(GCP_PROJECT) --format='value(status.url)'

test:
	$(eval URL=$(shell gcloud run services describe $(SERVICE_NAME) --region=$(GCP_REGION) --project=$(GCP_PROJECT) --format='value(status.url)'))
	$(eval SID=$(shell curl -si -X POST $(URL)/mcp \
	  -H 'Content-Type: application/json' \
	  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
	  | grep -i mcp-session-id | awk '{print $$2}' | tr -d '\r'))
	@curl -s -X POST $(URL)/mcp \
	  -H 'Content-Type: application/json' \
	  -H "mcp-session-id: $(SID)" \
	  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_users","arguments":{}}}' \
	  | python3 -m json.tool
