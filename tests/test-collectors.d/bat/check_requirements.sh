# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_check_requirements() {
    if [[ "${PLATFORM}" != "windows" ]]; then
        echo "ERROR: Batch scripts can only be tested on Windows"
        return 1
    fi
    if ! command -v "${CMD_CMD}" >/dev/null 2>&1; then
        echo "ERROR: cmd.exe not found"
        return 1
    fi
}
