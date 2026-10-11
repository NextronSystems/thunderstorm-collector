# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_build_command() {
    local args="$1"
    printf '%q ' "${BASH_CMD}" "${TEMP_SCRIPT_PATH}" \
        --server localhost --port "${MOCK_PORT}" --dir "${TEST_DATA_DIR}" \
        --max-age 365 --max-size-kb 20000 --no-log-file --no-progress
    printf '%s\n' "${args}"
}
