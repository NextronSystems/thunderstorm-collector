# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_build_command() {
    local args="$1"
    echo "${BASH_CMD} \"${TEMP_SCRIPT_PATH}\" ${args}"
}
