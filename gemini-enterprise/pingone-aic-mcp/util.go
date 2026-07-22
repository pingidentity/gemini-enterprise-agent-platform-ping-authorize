package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
)

var mcpRequiredScopes string

func requireEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		log.Fatalf("required environment variable %s is not set", key)
	}
	return val
}

func getEnvOrDefault(key, defaultValue string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultValue
}

func scopesToJSON(scopes string) string {
	parts := strings.Fields(scopes)
	quoted := make([]string, len(parts))
	for i, s := range parts {
		quoted[i] = fmt.Sprintf("%q", s)
	}
	return "[" + strings.Join(quoted, ",") + "]"
}

func aicIssuerURL() string {
	return fmt.Sprintf("%s/am/oauth2/%s", aicBaseURL, aicRealm)
}

func handleProtectedResourceMetadata(w http.ResponseWriter) {
	issuer := aicIssuerURL()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"authorization_servers":["%s"],"scopes_supported":%s}`, issuer, mcpRequiredScopes)
}

func handleOAuthDiscovery(w http.ResponseWriter) {
	issuer := aicIssuerURL()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{
		"issuer": "%s",
		"authorization_endpoint": "%s/authorize",
		"token_endpoint": "%s/access_token",
		"introspection_endpoint": "%s/introspect",
		"scopes_supported": ["openid","profile",%s],
		"response_types_supported": ["code"],
		"grant_types_supported": ["authorization_code","client_credentials","refresh_token"],
		"code_challenge_methods_supported": ["S256"],
		"token_endpoint_auth_methods_supported": ["client_secret_basic","client_secret_post"]
	}`, issuer, issuer, issuer, issuer, mcpRequiredScopes[1:len(mcpRequiredScopes)-1])
}
