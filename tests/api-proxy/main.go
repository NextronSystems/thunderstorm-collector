// api-proxy is a reverse proxy that translates old Thunderstorm API endpoints
// (api/) to new API endpoints (api/v1/) used by the mock server.
//
// This bridges the gap between collectors that still use the old API URL scheme
// and the mock server which implements the new OpenAPI spec under api/v1/.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

func main() {
	listenPort := flag.String("port", "8080", "Port to listen on")
	backendPort := flag.String("backend", "8081", "Backend (mock server) port")
	flag.Parse()

	backend, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%s", *backendPort))
	if err != nil {
		log.Fatalf("invalid backend URL: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(backend)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Rewrite /api/X to /api/v1/X (but not /api/v1/X which is already correct)
		if strings.HasPrefix(r.URL.Path, "/api/") && !strings.HasPrefix(r.URL.Path, "/api/v1/") {
			r.URL.Path = "/api/v1/" + strings.TrimPrefix(r.URL.Path, "/api/")
		}
		proxy.ServeHTTP(w, r)
	})

	addr := fmt.Sprintf(":%s", *listenPort)
	log.Printf("API proxy listening on %s, forwarding /api/ -> /api/v1/ on backend %s", addr, backend)
	log.Fatal(http.ListenAndServe(addr, nil))
}
