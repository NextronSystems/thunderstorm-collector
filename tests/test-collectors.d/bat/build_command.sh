# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_build_command() {
    local args="$1"
    local bat_path
    bat_path=$(to_native_path "${TEMP_SCRIPT_PATH}")
    echo "${CMD_CMD} /c \"${bat_path}\" ${args}"
}
