# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_check_requirements() {
    if ! command -v "${BASH_CMD}" >/dev/null 2>&1; then
        echo "ERROR: Bash interpreter not found (${BASH_CMD})"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl not found (required by shell collector)"
        echo "Install with: apt-get install curl (Linux) or choco install curl (Windows)"
        return 1
    fi
}
