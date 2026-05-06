# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_setup() {
    TEMP_SCRIPT_PATH=$("${MKTEMP_CMD}" --suffix=.py)
    "${CP_CMD}" "${PROJECT_ROOT}/scripts/thunderstorm-collector.py" "${TEMP_SCRIPT_PATH}"
}
