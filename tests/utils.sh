#!/bin/bash
# utils.sh - Shared utilities for Thunderstorm collector tests
#
# Sourced by test-collectors.sh and test-single.sh. Variables defined here are
# used by collector scripts in test-collectors.d/.

# ==============================================================================
# Paths & Configuration
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DATA_DIR="${SCRIPT_DIR}/testdata"

MOCK_EXECUTABLE="${THUNDERSTORM_MOCK_EXECUTABLE:-${PROJECT_ROOT}/thunderstorm-mock}"
MOCK_PORT="${MOCK_PORT:-8080}"
MOCK_SERVER_STARTUP_WAIT="${MOCK_SERVER_STARTUP_WAIT:-3}"
COLLECTOR_TIMEOUT="${COLLECTOR_TIMEOUT:-120}"

# Runtime state
MOCK_SERVER_PID=""
MOCK_LOG_FILE=""

# Shared collector state (used by test-collectors.d/ scripts)
# shellcheck disable=SC2034
TEMP_SCRIPT_PATH=""
# shellcheck disable=SC2034
GO_BINARY_PATH=""
# shellcheck disable=SC2034
GO_TEMPLATE_PATH=""

# ==============================================================================
# Platform Detection
# ==============================================================================

PLATFORM="linux"
if [[ "${OSTYPE}" == "msys" || "${OSTYPE}" == "win32" || "${OSTYPE}" == "cygwin" ]]; then
    PLATFORM="windows"
fi

# File commands
RM_CMD="rm"
MKDIR_CMD="mkdir"
# shellcheck disable=SC2034
CP_CMD="cp"
# shellcheck disable=SC2034
CHMOD_CMD="chmod"
TOUCH_CMD="touch"
MKTEMP_CMD="mktemp"
SED_CMD="sed"

# Interpreters (used by test-collectors.d/ scripts)
# shellcheck disable=SC2034
if [[ "${PLATFORM}" = "windows" ]]; then
    PYTHON_CMD="python"
    PERL_CMD="perl"
    BASH_CMD="bash"
    PWSH_CMD="powershell.exe"
    CMD_CMD="cmd.exe"
else
    PYTHON_CMD="python3"
    PERL_CMD="perl"
    BASH_CMD="bash"
    PWSH_CMD="pwsh"
fi

# Path conversion (Windows only)
HAS_CYGPATH=false
[[ "${PLATFORM}" = "windows" ]] && command -v cygpath >/dev/null 2>&1 && HAS_CYGPATH=true

# ==============================================================================
# Helper Functions
# ==============================================================================

touch_with_date() {
    local file="$1"
    local days_ago="$2"
    "${TOUCH_CMD}" -d "${days_ago} days ago" "${file}"
}

sed_inplace() {
    local pattern="$1"
    local file="$2"
    "${SED_CMD}" -i "${pattern}" "${file}"
}

to_native_path() {
    local path="$1"
    if [[ "${PLATFORM}" = "windows" ]] && [[ "${HAS_CYGPATH}" = true ]]; then
        cygpath -w "${path}"
    else
        echo "${path}"
    fi
}

run_with_timeout() {
    local timeout="$1"
    shift
    local cmd="$*"

    eval "${cmd}" &
    local pid=$!

    local elapsed=0
    while kill -0 "${pid}" 2>/dev/null; do
        if [[ "${elapsed}" -ge "${timeout}" ]]; then
            kill -TERM "${pid}" 2>/dev/null
            sleep 1
            kill -9 "${pid}" 2>/dev/null
            wait "${pid}" 2>/dev/null
            return 124
        fi
        sleep 1
        ((elapsed++))
    done

    wait "${pid}"
}

# ==============================================================================
# Test Data
# ==============================================================================

setup_test_data() {
    # Creates the following test file structure in TEST_DATA_DIR:
    #
    #   testdata/
    #   ├── small-file.txt          23 B    text, "small test file content\n"
    #   ├── medium-file.log          1 MB   zero bytes
    #   ├── large-file.dat          11 MB   zero bytes
    #   ├── old-file.txt            21 B    text, mtime set to 30 days ago
    #   ├── script.ps1              36 B    PowerShell script
    #   ├── executable.sh           25 B    shell script, +x
    #   ├── document.pdf           ~480 B   PDF header + zero padding
    #   ├── subdir/
    #   │   ├── nested-file.txt     27 B    text
    #   │   └── image.jpg         ~1010 B   JFIF header + zero padding
    #   └── excluded/
    #       └── skip-me.tmp         23 B    text
    #
    # Collectors apply their own filters (extension, size, age, regex)
    # to this fixed set. Transmission tests define which files each
    # collector is expected to upload or skip.
    echo "Setting up test data in ${TEST_DATA_DIR} ..."

    "${RM_CMD}" -rf "${TEST_DATA_DIR}"
    "${MKDIR_CMD}" -p "${TEST_DATA_DIR}/subdir" "${TEST_DATA_DIR}/excluded"

    echo "small test file content" > "${TEST_DATA_DIR}/small-file.txt"
    dd if=/dev/zero of="${TEST_DATA_DIR}/medium-file.log" bs=1024 count=1024 2>/dev/null
    dd if=/dev/zero of="${TEST_DATA_DIR}/large-file.dat" bs=1024 count=11264 2>/dev/null

    echo "old file content here" > "${TEST_DATA_DIR}/old-file.txt"
    touch_with_date "${TEST_DATA_DIR}/old-file.txt" 30

    echo 'Write-Host "Test PowerShell Script"' > "${TEST_DATA_DIR}/script.ps1"
    echo '#!/bin/bash' > "${TEST_DATA_DIR}/executable.sh"
    echo 'echo "test"' >> "${TEST_DATA_DIR}/executable.sh"
    "${CHMOD_CMD}" +x "${TEST_DATA_DIR}/executable.sh"

    printf '%%PDF-1.4\n%%test document content\n' > "${TEST_DATA_DIR}/document.pdf"
    dd if=/dev/zero bs=1 count=450 >> "${TEST_DATA_DIR}/document.pdf" 2>/dev/null

    echo "nested file in subdirectory" > "${TEST_DATA_DIR}/subdir/nested-file.txt"

    printf '\xff\xd8\xff\xe0\x00\x10JFIF' > "${TEST_DATA_DIR}/subdir/image.jpg"
    dd if=/dev/zero bs=1 count=1000 >> "${TEST_DATA_DIR}/subdir/image.jpg" 2>/dev/null

    echo "this should be skipped" > "${TEST_DATA_DIR}/excluded/skip-me.tmp"

    echo "Test data setup complete"
}

cleanup_test_data() {
    if [[ -d "${TEST_DATA_DIR}" ]]; then
        "${RM_CMD}" -rf "${TEST_DATA_DIR}"
    fi
}

# ==============================================================================
# Mock Server
# ==============================================================================

start_mock_server() {
    local port="$1"
    MOCK_LOG_FILE=$("${MKTEMP_CMD}" --suffix=.json)

    "${MOCK_EXECUTABLE}" --port "${port}" --output "${MOCK_LOG_FILE}" >/dev/null 2>&1 &
    MOCK_SERVER_PID=$!

    sleep "${MOCK_SERVER_STARTUP_WAIT}"

    if ! kill -0 "${MOCK_SERVER_PID}" 2>/dev/null; then
        echo "ERROR: Failed to start mock server on port ${port}"
        echo "Check if port is already in use: lsof -i :${port}"
        return 1
    fi
    return 0
}

stop_mock_server() {
    if [[ -n "${MOCK_SERVER_PID}" ]]; then
        kill "${MOCK_SERVER_PID}" 2>/dev/null || true
        wait "${MOCK_SERVER_PID}" 2>/dev/null || true
        MOCK_SERVER_PID=""
    fi
}

# ==============================================================================
# Result Verification
# ==============================================================================

verify_result() {
    local jq_query="$1"
    local expected_pattern="$2"
    local log_file="$3"

    if [[ ! -s "${log_file}" ]]; then
        echo "    Verification failed: Log file is empty or does not exist"
        return 1
    fi

    local result
    result=$(jq -r -s "${jq_query}" < "${log_file}" 2>&1)
    local jq_exit=$?

    if [[ "${jq_exit}" -ne 0 ]]; then
        echo "    Verification failed: jq parse error"
        echo "    Query: ${jq_query}"
        echo "    Error: ${result}"
        return 1
    fi

    if [[ ${result} =~ ${expected_pattern} ]]; then
        return 0
    else
        echo "    Verification failed: '${result}' does not match pattern '${expected_pattern}'"
        return 1
    fi
}

# ==============================================================================
# Transmission Verification
# ==============================================================================
#
# For async submissions, the mock server returns an ID immediately. The actual
# file hash becomes available via /api/getAsyncResults?id=<id> after a delay
# (the mock simulates processing: "Waiting" -> "Scanning" -> "Complete").
# For sync submissions, the hash is returned directly in the response.

# Collect SHA256 hashes from sync (Check) responses in the log.
# Prints one hash per line to stdout.
# Args: $1 = log file
collect_sync_hashes() {
    local log_file="$1"
    jq -r -s '[.[] | select(.handler == "Check")] | .[].response | fromjson | .[0].hash' < "${log_file}" 2>/dev/null
}

# Collect SHA256 hashes of all async submissions by polling getAsyncResults.
# Prints one hash per line to stdout.
# Args: $1 = mock server port, $2 = log file
# Returns: 0 on success, 1 if any ID failed to resolve within timeout
collect_async_hashes() {
    local port="$1"
    local log_file="$2"
    local poll_timeout="${3:-60}"

    # Extract sample IDs from checkAsync responses in the log
    local ids
    ids=$(jq -r -s '[.[] | select(.handler == "CheckAsync")] | .[].response | fromjson | .id' < "${log_file}" 2>/dev/null)
    if [[ -z "${ids}" ]]; then
        echo "    No async submissions found in log" >&2
        return 1
    fi

    local all_hashes=""
    local base_url="http://localhost:${port}/api/getAsyncResults"

    for sample_id in ${ids}; do
        local elapsed=0
        local hash=""
        while [[ "${elapsed}" -lt "${poll_timeout}" ]]; do
            local resp
            resp=$(curl -s "${base_url}?id=${sample_id}" 2>/dev/null)
            local status
            status=$(echo "${resp}" | jq -r '.status // empty' 2>/dev/null)

            if [[ "${status}" == "Sample analysis complete" ]]; then
                hash=$(echo "${resp}" | jq -r '.result[0].hash // empty' 2>/dev/null)
                break
            fi
            sleep 1
            ((elapsed++))
        done

        if [[ -z "${hash}" ]]; then
            echo "    Timeout waiting for async result of sample ${sample_id}" >&2
            return 1
        fi
        all_hashes="${all_hashes}${hash}"$'\n'
    done

    # Print hashes (strip trailing newline)
    printf '%s' "${all_hashes}" | head -c -1
}

# Verify that the expected files were transmitted and unexpected files were not.
# Uses SHA256 hashes to identify files.
# Args: $1 = port, $2 = log file, $3 = EXPECTED_FILES array (name ref),
#        $4 = UNEXPECTED_FILES array (name ref)
# Returns: 0 if all checks pass, 1 on any mismatch
verify_transmission() {
    local port="$1"
    local log_file="$2"
    local -n _expected_files=$3
    local -n _unexpected_files=$4

    # Collect hashes: use sync responses if present, otherwise poll async results
    local received_hashes
    local has_sync
    has_sync=$(jq -s '[.[] | select(.handler == "Check")] | length' < "${log_file}" 2>/dev/null)
    if [[ "${has_sync}" -gt 0 ]]; then
        received_hashes=$(collect_sync_hashes "${log_file}")
    else
        if ! received_hashes=$(collect_async_hashes "${port}" "${log_file}"); then
            return 1
        fi
    fi

    local ok=true

    # Check expected files: their hashes must appear in received set
    for file in "${_expected_files[@]}"; do
        local filepath="${TEST_DATA_DIR}/${file}"
        if [[ ! -f "${filepath}" ]]; then
            echo "    Expected file does not exist: ${file}" >&2
            ok=false
            continue
        fi
        local expected_hash
        expected_hash=$(sha256sum "${filepath}" | cut -d' ' -f1) || true
        if ! echo "${received_hashes}" | grep -qF "${expected_hash}"; then
            echo "    MISSING: ${file} (hash ${expected_hash})" >&2
            ok=false
        fi
    done

    # Check unexpected files: their hashes must NOT appear in received set
    for file in "${_unexpected_files[@]}"; do
        local filepath="${TEST_DATA_DIR}/${file}"
        if [[ ! -f "${filepath}" ]]; then
            continue
        fi
        local unexpected_hash
        unexpected_hash=$(sha256sum "${filepath}" | cut -d' ' -f1) || true
        if echo "${received_hashes}" | grep -qF "${unexpected_hash}"; then
            echo "    UNEXPECTED: ${file} was transmitted (hash ${unexpected_hash})" >&2
            ok=false
        fi
    done

    [[ "${ok}" = true ]]
}

show_log_snippet() {
    local log_file="$1"
    local lines="${2:-10}"

    if [[ -f "${log_file}" ]] && [[ -s "${log_file}" ]]; then
        echo "    Log snippet (last ${lines} lines):"
        local snippet
        snippet=$(tail -n "${lines}" "${log_file}")
        while IFS= read -r line; do
            echo "      ${line}"
        done <<< "${snippet}"
    fi
}
