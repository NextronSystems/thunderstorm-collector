#!/bin/bash
# utils.sh - Shared utilities for Thunderstorm collector tests

# ==============================================================================
# Paths & Configuration
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DATA_DIR="$SCRIPT_DIR/testdata"

MOCK_EXECUTABLE="${THUNDERSTORM_MOCK_EXECUTABLE:-$PROJECT_ROOT/thunderstorm-mock}"
MOCK_PORT="${MOCK_PORT:-8080}"
MOCK_SERVER_STARTUP_WAIT="${MOCK_SERVER_STARTUP_WAIT:-3}"
COLLECTOR_TIMEOUT="${COLLECTOR_TIMEOUT:-120}"

# Runtime state
MOCK_SERVER_PID=""
MOCK_LOG_FILE=""
TEMP_SCRIPT_PATH=""
GO_BINARY_PATH=""
GO_TEMPLATE_PATH=""

# ==============================================================================
# Platform Detection
# ==============================================================================

PLATFORM="linux"
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    PLATFORM="windows"
fi

# File commands
RM_CMD="rm"
MKDIR_CMD="mkdir"
CP_CMD="cp"
CHMOD_CMD="chmod"
TOUCH_CMD="touch"
MKTEMP_CMD="mktemp"
SED_CMD="sed"

# Interpreters
if [ "$PLATFORM" = "windows" ]; then
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
[ "$PLATFORM" = "windows" ] && command -v cygpath >/dev/null 2>&1 && HAS_CYGPATH=true

# ==============================================================================
# Helper Functions
# ==============================================================================

touch_with_date() {
    local file=$1
    local days_ago=$2
    $TOUCH_CMD -d "${days_ago} days ago" "$file"
}

sed_inplace() {
    local pattern=$1
    local file=$2
    $SED_CMD -i "$pattern" "$file"
}

to_native_path() {
    local path=$1
    if [ "$PLATFORM" = "windows" ] && [ "$HAS_CYGPATH" = true ]; then
        cygpath -w "$path"
    else
        echo "$path"
    fi
}

run_with_timeout() {
    local timeout=$1
    shift
    local cmd="$*"

    eval "$cmd" &
    local pid=$!

    local elapsed=0
    while kill -0 $pid 2>/dev/null; do
        if [ "$elapsed" -ge "$timeout" ]; then
            kill -TERM $pid 2>/dev/null
            sleep 1
            kill -9 $pid 2>/dev/null
            wait $pid 2>/dev/null
            return 124
        fi
        sleep 1
        ((elapsed++))
    done

    wait $pid
    return $?
}

# ==============================================================================
# Test Data
# ==============================================================================

setup_test_data() {
    echo "Setting up test data in $TEST_DATA_DIR ..."

    $RM_CMD -rf "$TEST_DATA_DIR"
    $MKDIR_CMD -p "$TEST_DATA_DIR/subdir" "$TEST_DATA_DIR/excluded"

    echo "small test file content" > "$TEST_DATA_DIR/small-file.txt"
    dd if=/dev/zero of="$TEST_DATA_DIR/medium-file.log" bs=1024 count=1024 2>/dev/null
    dd if=/dev/zero of="$TEST_DATA_DIR/large-file.dat" bs=1024 count=11264 2>/dev/null

    echo "old file content here" > "$TEST_DATA_DIR/old-file.txt"
    touch_with_date "$TEST_DATA_DIR/old-file.txt" 30

    echo 'Write-Host "Test PowerShell Script"' > "$TEST_DATA_DIR/script.ps1"
    echo '#!/bin/bash' > "$TEST_DATA_DIR/executable.sh"
    echo 'echo "test"' >> "$TEST_DATA_DIR/executable.sh"
    $CHMOD_CMD +x "$TEST_DATA_DIR/executable.sh"

    printf '%%PDF-1.4\n%%test document content\n' > "$TEST_DATA_DIR/document.pdf"
    dd if=/dev/zero bs=1 count=450 >> "$TEST_DATA_DIR/document.pdf" 2>/dev/null

    echo "nested file in subdirectory" > "$TEST_DATA_DIR/subdir/nested-file.txt"

    printf '\xff\xd8\xff\xe0\x00\x10JFIF' > "$TEST_DATA_DIR/subdir/image.jpg"
    dd if=/dev/zero bs=1 count=1000 >> "$TEST_DATA_DIR/subdir/image.jpg" 2>/dev/null

    echo "this should be skipped" > "$TEST_DATA_DIR/excluded/skip-me.tmp"

    echo "Test data setup complete"
}

cleanup_test_data() {
    if [ -d "$TEST_DATA_DIR" ]; then
        $RM_CMD -rf "$TEST_DATA_DIR"
    fi
}

# ==============================================================================
# Mock Server
# ==============================================================================

start_mock_server() {
    local port=$1
    MOCK_LOG_FILE=$($MKTEMP_CMD --suffix=.json)

    "$MOCK_EXECUTABLE" --port "$port" --output "$MOCK_LOG_FILE" >/dev/null 2>&1 &
    MOCK_SERVER_PID=$!

    sleep "$MOCK_SERVER_STARTUP_WAIT"

    if ! kill -0 "$MOCK_SERVER_PID" 2>/dev/null; then
        echo "ERROR: Failed to start mock server on port $port"
        echo "Check if port is already in use: lsof -i :$port"
        return 1
    fi
    return 0
}

stop_mock_server() {
    if [ -n "$MOCK_SERVER_PID" ]; then
        kill "$MOCK_SERVER_PID" 2>/dev/null || true
        wait "$MOCK_SERVER_PID" 2>/dev/null || true
        MOCK_SERVER_PID=""
    fi
}

# ==============================================================================
# Result Verification
# ==============================================================================

verify_result() {
    local jq_query=$1
    local expected_pattern=$2
    local log_file=$3

    if [ ! -s "$log_file" ]; then
        echo "    Verification failed: Log file is empty or does not exist"
        return 1
    fi

    local result
    result=$(jq -r -s "$jq_query" < "$log_file" 2>&1)
    local jq_exit=$?

    if [ $jq_exit -ne 0 ]; then
        echo "    Verification failed: jq parse error"
        echo "    Query: $jq_query"
        echo "    Error: $result"
        return 1
    fi

    if [[ $result =~ $expected_pattern ]]; then
        return 0
    else
        echo "    Verification failed: '$result' does not match pattern '$expected_pattern'"
        return 1
    fi
}

show_log_snippet() {
    local log_file=$1
    local lines=${2:-10}

    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        echo "    Log snippet (last $lines lines):"
        tail -n "$lines" "$log_file" | while IFS= read -r line; do
            echo "      $line"
        done
    fi
}
