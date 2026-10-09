# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_setup() {
    TEMP_SCRIPT_PATH=$("${MKTEMP_CMD}" --suffix=.bat) || return 1
    "${CP_CMD}" "${PROJECT_ROOT}/scripts/batch/thunderstorm-collector.bat" "${TEMP_SCRIPT_PATH}" || return 1

    # The standalone cmd/WSH collector takes configuration from its environment;
    # never edit its source or interpolate selected paths into cmd expressions.
    export THUNDERSTORM_SERVER=127.0.0.1 THUNDERSTORM_PORT="${MOCK_PORT}"
    local curl_executable
    curl_executable=$(command -v curl.exe) || return 1
    COLLECT_DIRS=$(to_native_path "${TEST_DATA_DIR}") || return 1
    CURL_PATH=$(to_native_path "$curl_executable") || return 1
    export COLLECT_DIRS CURL_PATH
    export MAX_AGE=365 COLLECT_MAX_SIZE=3000000 UPLOAD_ATTEMPTS=1
    export RELEVANT_EXTENSIONS='.txt;.log;.ps1;.tmp'
    export URL_SCHEME=http SOURCE=legacy-batch-test DRY_RUN=0 SYNC=0
}
