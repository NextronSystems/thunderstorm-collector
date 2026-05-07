#!/bin/bash
# test-single.sh - Run all tests for a single collector type
#
# Usage: test-single.sh <collector-type>
#
# Sources scripts from test-collectors.d/<collector-type>/ and executes the
# test specifications defined there. Expects test data to already be set up.
#
# Each collector directory must provide:
#   define_tests.sh       - sets COLLECTOR_NAME
#   check_requirements.sh - defines collector_check_requirements()
#   setup_test.sh         - defines collector_setup()
#   build_command.sh      - defines collector_build_command()
#   cleanup_test.sh       - defines collector_cleanup()
#   tests.d/*.sh          - individual test files setting ARGS, JQ_QUERY, PATTERN
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
# Run Tests
# ==============================================================================

passed=0
failed=0

for test_file in "${COLLECTOR_DIR}/tests.d/"*.sh; do
    [[ -f "${test_file}" ]] || continue
    test_name=$(basename "${test_file}" .sh)
    ARGS="" JQ_QUERY="" PATTERN=""
    # shellcheck source=/dev/null
    source "${test_file}"
    echo "  Running test: ${test_name}"

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

    # Start mock server
    if ! start_mock_server "${MOCK_PORT}"; then
        collector_cleanup
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Build and execute collector command
    collector_cmd=$(collector_build_command "${args}")
    run_with_timeout "${COLLECTOR_TIMEOUT}" "${collector_cmd}" >/dev/null 2>&1
    collector_exit=$?
    if [[ "${collector_exit}" -ne 0 ]]; then
        if [[ "${collector_exit}" -eq 124 ]]; then
            echo "    ERROR: Collector timed out after ${COLLECTOR_TIMEOUT}s"
        else
            echo "    ERROR: Collector exited with code ${collector_exit}"
        fi
    fi

    # Give mock server a moment to finish writing logs
    sleep 1
    stop_mock_server

    # Handle collector failure
    if [[ "${collector_exit}" -ne 0 ]]; then
        show_log_snippet "${MOCK_LOG_FILE}"
        collector_cleanup
        "${RM_CMD}" -f "${MOCK_LOG_FILE}"
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Verify results
    if ! verify_result "${JQ_QUERY}" "${PATTERN}" "${MOCK_LOG_FILE}"; then
        show_log_snippet "${MOCK_LOG_FILE}"
        collector_cleanup
        "${RM_CMD}" -f "${MOCK_LOG_FILE}"
        echo "  FAIL"
        ((failed++))
        continue
    fi

    # Success
    if [[ "${VERBOSE}" = "true" ]] && [[ -f "${MOCK_LOG_FILE}" ]]; then
        echo "    Mock server log:"
        while IFS= read -r log_line; do
            echo "      ${log_line}"
        done < "${MOCK_LOG_FILE}"
    fi
    collector_cleanup
    "${RM_CMD}" -f "${MOCK_LOG_FILE}"
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
