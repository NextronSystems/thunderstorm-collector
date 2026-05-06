# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_check_requirements() {
    if ! command -v go >/dev/null 2>&1; then
        echo "ERROR: Go toolchain not found"
        echo "Install from: https://go.dev/dl/"
        return 1
    fi
    if ! command -v make >/dev/null 2>&1; then
        echo "ERROR: make not found (required to build Go collector)"
        return 1
    fi
}
