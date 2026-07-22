package main

import (
	"fmt"
	"log"
	"net/http"
	"strings"

	"github.com/mark3labs/mcp-go/server"
)

func newRouter(mcpServer *server.StreamableHTTPServer) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/.well-known/oauth-protected-resource"):
			handleProtectedResourceMetadata(w)
		case strings.HasPrefix(r.URL.Path, "/.well-known/oauth-authorization-server"):
			handleOAuthDiscovery(w)
		case r.URL.Path == "/" || strings.HasPrefix(r.URL.Path, "/mcp"):
			log.Printf("mcp %s %s bearer=...%s", r.Method, r.URL.Path, truncateToken(r.Header.Get("Authorization")))
			r2 := r.Clone(r.Context())
			r2.URL.Path = "/mcp"
			mcpServer.ServeHTTP(w, r2)
		default:
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprintf(w, `{"error":"not_found"}`)
		}
	})
}

func truncateToken(authHeader string) string {
	const prefix = "Bearer "
	if !strings.HasPrefix(authHeader, prefix) {
		return "<none>"
	}
	token := authHeader[len(prefix):]
	if len(token) <= 8 {
		return "****"
	}
	return token[len(token)-8:]
}
