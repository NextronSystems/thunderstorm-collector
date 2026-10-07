# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_cleanup() {
    if [[ -n "${TEMP_SCRIPT_PATH}" ]] && [[ -f "${TEMP_SCRIPT_PATH}" ]]; then
        "${RM_CMD}" -f "${TEMP_SCRIPT_PATH}"
        TEMP_SCRIPT_PATH=""
    fi
}
