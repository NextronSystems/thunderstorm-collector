# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_build_command() {
    local args="$1"
    if [[ -n "${args}" ]]; then
        echo "ERROR: Batch collector uses environment settings, not CLI arguments" >&2
        return 1
    fi
    local bat_path
    bat_path=$(to_native_path "${TEMP_SCRIPT_PATH}")
    printf 'MSYS_NO_PATHCONV=1 %q /d /v:off /s /c %q\n' "${CMD_CMD}" "\"${bat_path}\""
}
