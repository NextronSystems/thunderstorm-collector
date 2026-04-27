#!/bin/bash
# thunderstorm-mock-wrapper.sh - Wraps thunderstorm-mock with an API proxy
#
# Drop-in replacement for the thunderstorm-mock executable. Accepts the same
# CLI flags but interposes a reverse proxy that rewrites /api/ -> /api/v1/.
#
# This is a temporary shim: remove this step once the real Thunderstorm server
# has migrated to the new /api/v1/ endpoint scheme and collectors are updated.
#
# Required environment:
#   THUNDERSTORM_MOCK_REAL  - path to the real thunderstorm-mock binary
#   API_PROXY_BINARY        - path to the compiled api-proxy binary

set -euo pipefail

: "${THUNDERSTORM_MOCK_REAL:?THUNDERSTORM_MOCK_REAL must be set}"
: "${API_PROXY_BINARY:?API_PROXY_BINARY must be set}"

# Parse the --port flag from arguments (default 8080) so we can intercept it.
# All other flags are passed through to the real mock unchanged.
LISTEN_PORT="8080"
BACKEND_PORT=""
MOCK_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            LISTEN_PORT="$2"
            shift 2
            ;;
        *)
            MOCK_ARGS+=("$1")
            shift
            ;;
    esac
done

# Pick a backend port: listener port + 1000
BACKEND_PORT=$((LISTEN_PORT + 1000))

cleanup() {
    # Kill child processes on exit
    kill "$MOCK_PID" 2>/dev/null || true
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Start real mock on backend port
"$THUNDERSTORM_MOCK_REAL" --port "$BACKEND_PORT" "${MOCK_ARGS[@]}" &
MOCK_PID=$!

# Brief pause to let mock bind
sleep 0.5

# Start API proxy on the original listen port
"$API_PROXY_BINARY" --port "$LISTEN_PORT" --backend "$BACKEND_PORT" &
PROXY_PID=$!

# Wait for either process to exit
wait -n "$MOCK_PID" "$PROXY_PID" 2>/dev/null || true
