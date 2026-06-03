#!/bin/bash
# test-single.sh - Run all tests for a single collector type
#
# Usage: test-single.sh <collector-type>
#
# Sources scripts from test-collectors.d/<collector-type>/ and executes the
# test specifications defined there. Expects test data to already be set up.
#
# Each collector directory must provide:
#   define_tests.sh             - sets COLLECTOR_NAME
#   check_requirements.sh       - defines collector_check_requirements()
#   setup_test.sh               - defines collector_setup()
#   build_command.sh            - defines collector_build_command()
#   cleanup_test.sh             - defines collector_cleanup()
#   request-tests.d/*.sh        - request tests (ARGS, JQ_QUERY, PATTERN)
#   transmission-tests.d/*.sh   - transmission tests (ARGS, EXPECTED_FILES, UNEXPECTED_FILES)
#
# Output:
#   Human-readable test output, plus a machine-readable final line:
#     RESULT:<passed>:<failed>:<skipped>

# shellcheck disable=SC2154  # Variables sourced from utils.sh and test-collectors.d/
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh disable=SC1091
source "${SCRIPT_DIR}/utils.sh"

COLLECTOR_TYPE="$1"
if [[ -z "${COLLECTOR_TYPE}" ]]; then
    echo "Usage: test-single.sh <collector-type>"
    exit 2
fi

COLLECTOR_DIR="${SCRIPT_DIR}/test-collectors.d/${COLLECTOR_TYPE}"
if [[ ! -d "${COLLECTOR_DIR}" ]]; then
    echo "ERROR: Unknown collector type: ${COLLECTOR_TYPE}"
    available=$(ls "${SCRIPT_DIR}/test-collectors.d/")
    echo "Available: ${available}"
    exit 2
fi

# Source collector-specific scripts
# shellcheck source=/dev/null
source "${COLLECTOR_DIR}/define_tests.sh"
# shellcheck source=/dev/null
source "${COLLECTOR_DIR}/check_requirements.sh"
# shellcheck source=/dev/null
source "${COLLECTOR_DIR}/setup_test.sh"
# shellcheck source=/dev/null
source "${COLLECTOR_DIR}/build_command.sh"
# shellcheck source=/dev/null
source "${COLLECTOR_DIR}/cleanup_test.sh"

# ==============================================================================
# Header
# ==============================================================================

echo ""
echo "========================================"
echo "Testing ${COLLECTOR_NAME} Collector"
echo "========================================"

# ==============================================================================
# Test Data (set up if not present, e.g. standalone invocation)
# ==============================================================================

STANDALONE_TEST_DATA=false
if [[ ! -d "${TEST_DATA_DIR}" ]]; then
    STANDALONE_TEST_DATA=true
    setup_test_data
fi

# ==============================================================================
# Requirements Check
# ==============================================================================

if ! collector_check_requirements; then
    echo ""
    echo "Skipping ${COLLECTOR_NAME} collector tests due to missing requirements"
    echo "RESULT:0:0:1"
    exit 0
fi

# ==============================================================================
# Shared test helpers
# ==============================================================================

# Run collector and leave mock server running. Sets collector_exit.
# Args: $1 = args string
# Expects: MOCK_PORT, COLLECTOR_TIMEOUT set; collector_setup already called
run_collector() {
    local args="$1"

    # Start mock server
    if ! start_mock_server "${MOCK_PORT}"; then
        collector_cleanup
        return 1
    fi

    # Build and execute collector command
    local collector_cmd
    collector_cmd=$(collector_build_command "${args}")
    local collector_log_file
    collector_log_file=$("${MKTEMP_CMD}" --suffix=.log)
    run_with_timeout "${COLLECTOR_TIMEOUT}" "${collector_cmd}" >"${collector_log_file}" 2>&1
    collector_exit=$?
    if [[ "${VERBOSE}" = "true" ]]; then
        echo "    Collector output (exit code ${collector_exit}):"
        while IFS= read -r line; do
            echo "      ${line}"
        done < "${collector_log_file}"
    fi
    "${RM_CMD}" -f "${collector_log_file}"
    if [[ "${collector_exit}" -ne 0 ]]; then
        if [[ "${collector_exit}" -eq 124 ]]; then
            echo "    ERROR: Collector timed out after ${COLLECTOR_TIMEOUT}s"
        else
            echo "    ERROR: Collector exited with code ${collector_exit}"
        fi
    fi

    # Give mock server a moment to finish writing logs
    sleep 1
    return 0
}

# Print verbose log and clean up after a test
finish_test() {
    if [[ "${VERBOSE}" = "true" ]] && [[ -f "${MOCK_LOG_FILE}" ]]; then
        echo "    Mock server log:"
        while IFS= read -r log_line; do
            echo "      ${log_line}"
        done < "${MOCK_LOG_FILE}"
    fi
    collector_cleanup
    "${RM_CMD}" -f "${MOCK_LOG_FILE}"
}

# ==============================================================================
# Request Tests
# ==============================================================================
#
# Each file in request-tests.d/ defines a single request-level test by setting
# three variables:
#
#   ARGS        Collector CLI arguments. Two placeholders are replaced at
#               runtime: PORT → mock server port, TESTDIR → test data path.
#               Example: "--server localhost:PORT --dir TESTDIR --source myclient"
#
#   JQ_QUERY    A jq expression evaluated against the mock server log. The log
#               is a JSONL file (one JSON object per request) slurped into an
#               array with `jq -s`. Each entry has fields like .uri, .handler,
#               .response, .method, etc. The query is run as:
#                   jq -r -s '<JQ_QUERY>' < logfile
#               Examples:
#                   '.[0].response | fromjson | .id'      # extract response id
#                   'length'                               # count requests
#                   '.[0].uri | capture("source=(?<s>[^&]*)") | .s'
#
#   PATTERN     An extended regex matched against JQ_QUERY output using bash's
#               =~ operator. Test passes when the jq result matches this regex.
#               Examples:
#                   '^[0-9]+$'       # numeric id
#                   '^test-client$'  # exact string
#                   '^[1-9][0-9]*$'  # at least 1
#

passed=0
failed=0

for test_file in "${COLLECTOR_DIR}/request-tests.d/"*.sh; do
    [[ -f "${test_file}" ]] || continue
    test_name=$(basename "${test_file}" .sh)
    ARGS="" JQ_QUERY="" PATTERN=""
    # shellcheck source=/dev/null
    source "${test_file}"
    echo "  Running request test: ${test_name}"

    # Setup collector
    if ! collector_setup; then
        echo "    ERROR: Setup function failed"
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Replace placeholders in args
    args="${ARGS//PORT/${MOCK_PORT}}"
    args="${args//TESTDIR/${TEST_DATA_DIR}}"

    # Run collector, stop mock after
    if ! run_collector "${args}"; then
        echo "  FAIL"
        ((failed++))
        continue
    fi
    stop_mock_server

    # Handle collector failure
    if [[ "${collector_exit}" -ne 0 ]]; then
        show_log_snippet "${MOCK_LOG_FILE}"
        finish_test
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Verify results
    if ! verify_result "${JQ_QUERY}" "${PATTERN}" "${MOCK_LOG_FILE}"; then
        show_log_snippet "${MOCK_LOG_FILE}"
        finish_test
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Success
    finish_test
    echo "  PASS"
    ((passed++))
done

# ==============================================================================
# Transmission Tests
# ==============================================================================
#
# Each file in transmission-tests.d/ defines a single transmission test by
# setting three variables:
#
#   ARGS              Collector CLI arguments (same PORT/TESTDIR placeholders
#                     as request tests).
#                     Example: "-s localhost --port PORT -p TESTDIR -e .txt"
#
#   EXPECTED_FILES    Bash array of paths (relative to TEST_DATA_DIR) whose
#                     SHA256 hashes MUST appear in the mock server's received
#                     file set. Verification computes sha256sum of each local
#                     file and checks it was transmitted.
#                     Example: ("small-file.txt" "subdir/nested-file.txt")
#
#   UNEXPECTED_FILES  Bash array of paths (relative to TEST_DATA_DIR) whose
#                     hashes must NOT appear. Used to verify filters (extension,
#                     size, exclude patterns) correctly prevented transmission.
#                     Example: ("large-file.dat" "excluded/skip-me.tmp")
#
# Available test data files are created by setup_test_data() in utils.sh:
#
#   small-file.txt, medium-file.log (1 MB), large-file.dat (11 MB),
#   old-file.txt (mtime 30 days ago), script.ps1, executable.sh,
#   document.pdf, subdir/nested-file.txt, subdir/image.jpg,
#   excluded/skip-me.tmp
#
# Hashes are collected from mock server responses — sync (Check handler) or
# async (CheckAsync + getAsyncResults polling), determined automatically.
#

for test_file in "${COLLECTOR_DIR}/transmission-tests.d/"*.sh; do
    [[ -f "${test_file}" ]] || continue
    test_name=$(basename "${test_file}" .sh)
    ARGS=""
    # shellcheck disable=SC2034  # used by verify_transmission via nameref
    EXPECTED_FILES=()
    # shellcheck disable=SC2034
    UNEXPECTED_FILES=()
    # shellcheck source=/dev/null
    source "${test_file}"
    echo "  Running transmission test: ${test_name}"

    # Setup collector
    if ! collector_setup; then
        echo "    ERROR: Setup function failed"
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Replace placeholders in args
    args="${ARGS//PORT/${MOCK_PORT}}"
    args="${args//TESTDIR/${TEST_DATA_DIR}}"

    # Run collector (mock stays running for getAsyncResults polling)
    if ! run_collector "${args}"; then
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Handle collector failure
    if [[ "${collector_exit}" -ne 0 ]]; then
        stop_mock_server
        show_log_snippet "${MOCK_LOG_FILE}"
        finish_test
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Verify file transmission via hash comparison
    if ! verify_transmission "${MOCK_PORT}" "${MOCK_LOG_FILE}" EXPECTED_FILES UNEXPECTED_FILES; then
        stop_mock_server
        show_log_snippet "${MOCK_LOG_FILE}"
        finish_test
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Success
    stop_mock_server
    finish_test
    echo "  PASS"
    ((passed++))
done

# Cleanup test data if we created it
if [[ "${STANDALONE_TEST_DATA}" = true ]]; then
    cleanup_test_data
fi

echo ""
echo "Results: ${passed} passed, ${failed} failed"
echo "RESULT:${passed}:${failed}:0"

[[ "${failed}" -eq 0 ]]
