collector_setup() {
    # Build the Go collector
    if ! make -C "$PROJECT_ROOT/go" build >/dev/null 2>&1; then
        echo "    ERROR: Failed to build Go collector"
        return 1
    fi

    # Determine the binary name for the current platform
    local arch os_name suffix=""
    arch=$(go env GOARCH)
    os_name=$(go env GOOS)
    [ "$os_name" = "windows" ] && suffix=".exe"
    GO_BINARY_PATH="$PROJECT_ROOT/go/bin/${arch}-${os_name}-thunderstorm-collector${suffix}"

    if [ ! -x "$GO_BINARY_PATH" ]; then
        echo "    ERROR: Go binary not found at $GO_BINARY_PATH"
        return 1
    fi

    # Create an empty YAML template to prevent the binary from reading the
    # default config.yml (which restricts extensions and file sizes)
    GO_TEMPLATE_PATH=$($MKTEMP_CMD --suffix=.yml)
    echo "---" > "$GO_TEMPLATE_PATH"
    echo "max-filesize: 100" >> "$GO_TEMPLATE_PATH"
}
