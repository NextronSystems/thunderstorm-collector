# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_setup() {
    TEMP_SCRIPT_PATH=$("${MKTEMP_CMD}" --suffix=.bat)
    "${CP_CMD}" "${PROJECT_ROOT}/scripts/thunderstorm-collector.bat" "${TEMP_SCRIPT_PATH}"

    # Convert path for Windows batch script
    local win_testdir
    win_testdir=$(to_native_path "${TEST_DATA_DIR}")
    local escaped_path="${win_testdir//\\/\\\\}"

    sed_inplace "s/SET THUNDERSTORM_SERVER=.*/SET THUNDERSTORM_SERVER=localhost/" "${TEMP_SCRIPT_PATH}"
    sed_inplace "s/SET THUNDERSTORM_PORT=.*/SET THUNDERSTORM_PORT=${MOCK_PORT}/" "${TEMP_SCRIPT_PATH}"
    sed_inplace "s/SET COLLECT_DIRS=.*/SET COLLECT_DIRS=${escaped_path}/" "${TEMP_SCRIPT_PATH}"
    sed_inplace "s/SET DEBUG=.*/SET DEBUG=0/" "${TEMP_SCRIPT_PATH}"
    sed_inplace "s|SET /A MAX_AGE=.*|SET /A MAX_AGE=365|" "${TEMP_SCRIPT_PATH}"
}
