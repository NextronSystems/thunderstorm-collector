# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_setup() {
    TEMP_SCRIPT_PATH=$("${MKTEMP_CMD}" --suffix=.sh)
    "${CP_CMD}" "${PROJECT_ROOT}/scripts/bash/thunderstorm-collector.sh" "${TEMP_SCRIPT_PATH}"

    "${CHMOD_CMD}" +x "${TEMP_SCRIPT_PATH}"
}
