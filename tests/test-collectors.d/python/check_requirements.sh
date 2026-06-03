# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_check_requirements() {
    if ! command -v "${PYTHON_CMD}" >/dev/null 2>&1; then
        echo "ERROR: Python interpreter not found (${PYTHON_CMD})"
        echo "Install with: choco install python (Windows) or apt-get install python3 (Linux)"
        return 1
    fi
}
