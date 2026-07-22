package main

import (
	"log"
	"net/http"
	"os"

	"github.com/mark3labs/mcp-go/server"
)

func main() {
	log.SetFlags(0)

	aicBaseURL = requireEnv("AIC_BASE_URL")
	aicAdminClientID = requireEnv("AIC_ADMIN_CLIENT_ID")
	aicRealm = getEnvOrDefault("AIC_REALM", "alpha")
	mcpRequiredScopes = scopesToJSON(requireEnv("MCP_REQUIRED_SCOPES"))

	jwk := os.Getenv("AIC_ADMIN_PRIVATE_KEY_JWK")
	if jwk == "" {
		path := requireEnv("AIC_ADMIN_PRIVATE_KEY_JWK_FILE")
		b, err := os.ReadFile(path)
		if err != nil {
			log.Fatalf("read JWK file: %v", err)
		}
		jwk = string(b)
	}
	key, err := loadRSAPrivateKeyFromJWK(jwk)
	if err != nil {
		log.Fatalf("load private key: %v", err)
	}
	aicAdminPrivateKey = key

	mcpSrv := server.NewMCPServer("pingone-aic-mcp", "1.0.0", server.WithToolCapabilities(false))
	registerAicMcpTools(mcpSrv)
	if err := http.ListenAndServe(":"+requireEnv("MCP_SERVER_PORT"), newRouter(server.NewStreamableHTTPServer(mcpSrv))); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
