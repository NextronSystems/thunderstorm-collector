#!/bin/bash
#
# test-collectors.sh - Test Thunderstorm collector scripts
#
# DESCRIPTION:
#   Tests Thunderstorm collector scripts against the thunderstorm-mock server.
#   Validates that collectors properly submit files and handle various configurations.
#
#   The collectors use /api/v1/checkAsync which matches the mock server's API.
#
# REQUIREMENTS:
#   Core utilities:
#     - bash 4.0+
#     - jq (JSON processor) - REQUIRED
#     - Standard tools: mktemp, rm, mkdir, cp, chmod, touch, sed, grep, dd
#
#   Collector-specific (depending on which collectors you test):
#     - perl 5.x with LWP::UserAgent module
#     - python3 (Linux) or python (Windows)
#     - curl (for shell script collector)
#     - powershell.exe (Windows) or pwsh (PowerShell Core on Linux)
#     - cmd.exe (Windows only, for batch scripts)
#     - go 1.15+ toolchain with make (for Go collector)
#
# PLATFORM SUPPORT:
#   - Linux: Native bash environment
#   - Windows: Git Bash (Git for Windows)
#
# WINDOWS SETUP:
#
#   For GitHub Actions (add to workflow):
#     - uses: actions/checkout@v4
#     - name: Install jq
#       run: choco install jq -y
#     - name: Install Perl (if testing Perl collector)
#       run: choco install strawberryperl -y
#
#   For local Windows development:
#     # Install Git for Windows (provides Git Bash + coreutils)
#     winget install Git.Git
#
#     # Install jq
#     choco install jq
#
#     # Install Perl (if needed)
#     choco install strawberryperl
#
#     # Python usually pre-installed, verify with:
#     python --version
#
# USAGE:
#   ./tests/test-collectors.sh <collector-keyword>
#
#   Collector keywords:
#     perl, pl        - Test Perl collector
#     python, py      - Test Python collector
#     sh, bash        - Test Shell collector
#     ps1, powershell - Test PowerShell collector
#     bat, batch      - Test Batch collector (Windows only)
#     go              - Test Go collector
#     all             - Test all applicable collectors
#
#   Options:
#     -h, --help           - Show help message
#     -p, --port NUM       - Use custom port for mock server (default: 8080)
#     -t, --timeout NUM    - Collector timeout in seconds (default: 120)
#
#   Environment variables:
#     THUNDERSTORM_MOCK_EXECUTABLE - Path to mock executable (default: ./thunderstorm-mock)
#     MOCK_PORT                    - Mock server port (default: 8080)
#     COLLECTOR_TIMEOUT            - Timeout in seconds (default: 120)
#
# EXAMPLES:
#   # Test Perl collector
#   ./tests/test-collectors.sh perl
#
#   # Test all collectors
#   ./tests/test-collectors.sh all
#
#   # Use custom mock location
#   THUNDERSTORM_MOCK_EXECUTABLE=/usr/local/bin/thunderstorm-mock ./tests/test-collectors.sh python
#
#   # Use custom port and timeout
#   ./tests/test-collectors.sh --port 9090 --timeout 60 perl
#
# AUTHOR:
#   Claude Opus 4.5

set -o pipefail

# ==============================================================================
# Configuration & Global Variables
# ==============================================================================

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test data location
TEST_DATA_DIR="$SCRIPT_DIR/testdata"

# Mock server configuration
MOCK_EXECUTABLE="${THUNDERSTORM_MOCK_EXECUTABLE:-$PROJECT_ROOT/thunderstorm-mock}"
MOCK_PORT="${MOCK_PORT:-8080}"
MOCK_SERVER_STARTUP_WAIT="${MOCK_SERVER_STARTUP_WAIT:-3}"

# Timeout configuration
COLLECTOR_TIMEOUT="${COLLECTOR_TIMEOUT:-120}"

# Runtime state
MOCK_SERVER_PID=""
MOCK_LOG_FILE=""
TEMP_SCRIPT_PATH=""
GO_BINARY_PATH=""
GO_TEMPLATE_PATH=""
COLLECTOR_KEYWORD=""

# Test results
TOTAL_PASSED=0
TOTAL_FAILED=0
declare -A COLLECTOR_RESULTS

# ==============================================================================
# Platform Detection & Command Variables
# ==============================================================================

PLATFORM="linux"

detect_platform() {
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
        PLATFORM="windows"
    else
        PLATFORM="linux"
    fi
}

# Initialize platform detection
detect_platform

# File operations (same on both platforms via Git Bash)
RM_CMD="rm"
MKDIR_CMD="mkdir"
CP_CMD="cp"
CHMOD_CMD="chmod"
TOUCH_CMD="touch"

# Utilities
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

# Touch file with date in the past (GNU coreutils on Linux and Git Bash)
touch_with_date() {
    local file=$1
    local days_ago=$2
    $TOUCH_CMD -d "${days_ago} days ago" "$file"
}

# Sed in-place (GNU sed on Linux and Git Bash)
sed_inplace() {
    local pattern=$1
    local file=$2
    $SED_CMD -i "$pattern" "$file"
}

# Convert path to Windows native format when needed
to_native_path() {
    local path=$1
    if [ "$PLATFORM" = "windows" ] && [ "$HAS_CYGPATH" = true ]; then
        cygpath -w "$path"
    else
        echo "$path"
    fi
}

# Run command with timeout
# Returns 124 on timeout (standard timeout exit code)
run_with_timeout() {
    local timeout=$1
    shift
    local cmd="$*"

    # Start command in background
    eval "$cmd" &
    local pid=$!

    # Wait with timeout
    local elapsed=0
    while kill -0 $pid 2>/dev/null; do
        if [ "$elapsed" -ge "$timeout" ]; then
            # Timeout reached - kill the process
            kill -TERM $pid 2>/dev/null
            sleep 1
            # Force kill if still running
            kill -9 $pid 2>/dev/null
            wait $pid 2>/dev/null
            return 124
        fi
        sleep 1
        ((elapsed++))
    done

    # Get exit status
    wait $pid
    return $?
}

# Setup test data directory with various test files
setup_test_data() {
    echo "Setting up test data in $TEST_DATA_DIR ..."

    # Clean existing test data
    $RM_CMD -rf "$TEST_DATA_DIR"
    $MKDIR_CMD -p "$TEST_DATA_DIR/subdir" "$TEST_DATA_DIR/excluded"

    # Create small text file (25 bytes)
    echo "small test file content" > "$TEST_DATA_DIR/small-file.txt"

    # Create medium file (1 MB)
    dd if=/dev/zero of="$TEST_DATA_DIR/medium-file.log" bs=1024 count=1024 2>/dev/null

    # Create large file (11 MB - may be skipped by size filters)
    dd if=/dev/zero of="$TEST_DATA_DIR/large-file.dat" bs=1024 count=11264 2>/dev/null

    # Create old file (30 days old)
    echo "old file content here" > "$TEST_DATA_DIR/old-file.txt"
    touch_with_date "$TEST_DATA_DIR/old-file.txt" 30

    # Create script files
    echo 'Write-Host "Test PowerShell Script"' > "$TEST_DATA_DIR/script.ps1"
    echo '#!/bin/bash' > "$TEST_DATA_DIR/executable.sh"
    echo 'echo "test"' >> "$TEST_DATA_DIR/executable.sh"
    $CHMOD_CMD +x "$TEST_DATA_DIR/executable.sh"

    # Create fake PDF (with PDF header)
    printf '%%PDF-1.4\n%%test document content\n' > "$TEST_DATA_DIR/document.pdf"
    dd if=/dev/zero bs=1 count=450 >> "$TEST_DATA_DIR/document.pdf" 2>/dev/null

    # Create nested files
    echo "nested file in subdirectory" > "$TEST_DATA_DIR/subdir/nested-file.txt"

    # Create fake JPEG (with JPEG header: FF D8 FF)
    printf '\xff\xd8\xff\xe0\x00\x10JFIF' > "$TEST_DATA_DIR/subdir/image.jpg"
    dd if=/dev/zero bs=1 count=1000 >> "$TEST_DATA_DIR/subdir/image.jpg" 2>/dev/null

    # Create file in excluded directory
    echo "this should be skipped" > "$TEST_DATA_DIR/excluded/skip-me.tmp"

    echo "Test data setup complete"
}

# Cleanup test data directory
cleanup_test_data() {
    if [ -d "$TEST_DATA_DIR" ]; then
        $RM_CMD -rf "$TEST_DATA_DIR"
    fi
}

# Start mock server
start_mock_server() {
    local port=$1

    # Create temporary log file
    MOCK_LOG_FILE=$($MKTEMP_CMD --suffix=.json)

    # Start mock server in background (suppress startup messages)
    "$MOCK_EXECUTABLE" --port "$port" --output "$MOCK_LOG_FILE" >/dev/null 2>&1 &
    MOCK_SERVER_PID=$!

    # Wait for server to start
    sleep "$MOCK_SERVER_STARTUP_WAIT"

    # Verify server is running
    if ! kill -0 "$MOCK_SERVER_PID" 2>/dev/null; then
        echo "ERROR: Failed to start mock server on port $port"
        echo "Check if port is already in use: lsof -i :$port"
        return 1
    fi

    return 0
}

# Stop mock server
stop_mock_server() {
    if [ -n "$MOCK_SERVER_PID" ]; then
        kill "$MOCK_SERVER_PID" 2>/dev/null || true
        wait "$MOCK_SERVER_PID" 2>/dev/null || true
        MOCK_SERVER_PID=""
    fi
}

# Verify test result using jq
# Arguments: jq_query, expected_pattern, log_file
# Returns: 0 on success, 1 on failure
verify_result() {
    local jq_query=$1
    local expected_pattern=$2
    local log_file=$3

    # Check if log file exists and is not empty
    if [ ! -s "$log_file" ]; then
        echo "    Verification failed: Log file is empty or does not exist"
        return 1
    fi

    # Wrap log entries in array for jq processing
    # Each line is a separate JSON object
    local result
    result=$(jq -r -s "$jq_query" < "$log_file" 2>&1)
    local jq_exit=$?

    if [ $jq_exit -ne 0 ]; then
        echo "    Verification failed: jq parse error"
        echo "    Query: $jq_query"
        echo "    Error: $result"
        return 1
    fi

    # Check if result matches expected pattern (bash extended regex via =~)
    if [[ $result =~ $expected_pattern ]]; then
        return 0
    else
        echo "    Verification failed: '$result' does not match pattern '$expected_pattern'"
        return 1
    fi
}

# Show snippet of log file on failure
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

# Setup Perl script copy
setup_perl_script() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.pl)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.pl" "$TEMP_SCRIPT_PATH"

    $CHMOD_CMD +x "$TEMP_SCRIPT_PATH"
}

# Setup Python script copy
setup_python_script() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.py)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.py" "$TEMP_SCRIPT_PATH"
}

# Setup shell script copy with modified variables
setup_sh_script() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.sh)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.sh" "$TEMP_SCRIPT_PATH"

    # Modify variables for testing
    sed_inplace "s/THUNDERSTORM_SERVER=.*/THUNDERSTORM_SERVER=\"localhost\"/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/THUNDERSTORM_PORT=.*/THUNDERSTORM_PORT=$MOCK_PORT/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s|declare -a SCAN_FOLDERS=.*|declare -a SCAN_FOLDERS=('$TEST_DATA_DIR')|" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/DEBUG=.*/DEBUG=0/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/MAX_AGE=.*/MAX_AGE=365/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/MAX_FILE_SIZE=.*/MAX_FILE_SIZE=20000/" "$TEMP_SCRIPT_PATH"

    $CHMOD_CMD +x "$TEMP_SCRIPT_PATH"
}

# Setup batch script copy with modified variables
setup_bat_script() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.bat)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.bat" "$TEMP_SCRIPT_PATH"

    # Convert path for Windows batch script
    local win_testdir
    win_testdir=$(to_native_path "$TEST_DATA_DIR")

    # Escape backslashes for sed
    local escaped_path="${win_testdir//\\/\\\\}"

    sed_inplace "s/SET THUNDERSTORM_SERVER=.*/SET THUNDERSTORM_SERVER=localhost/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/SET THUNDERSTORM_PORT=.*/SET THUNDERSTORM_PORT=$MOCK_PORT/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/SET COLLECT_DIRS=.*/SET COLLECT_DIRS=$escaped_path/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/SET DEBUG=.*/SET DEBUG=0/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s|SET /A MAX_AGE=.*|SET /A MAX_AGE=365|" "$TEMP_SCRIPT_PATH"
}

# Setup PowerShell script copy
setup_ps1_script() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.ps1)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.ps1" "$TEMP_SCRIPT_PATH"
}

# Setup Go collector binary (build via make)
setup_go_binary() {
    # Build the Go collector
    if ! make -C "$PROJECT_ROOT/go" build >/dev/null 2>&1; then
        echo "    ERROR: Failed to build Go collector"
        return 1
    fi

    # Determine the binary name for the current platform
    local arch os_name suffix=""
    arch=$(go env GOARCH)
    os_name=$(go env GOOS)
    [ "$os_name" = "windows" ] && suffix=".exe"
    GO_BINARY_PATH="$PROJECT_ROOT/go/bin/${arch}-${os_name}-thunderstorm-collector${suffix}"

    if [ ! -x "$GO_BINARY_PATH" ]; then
        echo "    ERROR: Go binary not found at $GO_BINARY_PATH"
        return 1
    fi

    # Create an empty YAML template to prevent the binary from reading the
    # default config.yml (which restricts extensions and file sizes)
    GO_TEMPLATE_PATH=$($MKTEMP_CMD --suffix=.yml)
    echo "---" > "$GO_TEMPLATE_PATH"
    echo "max-filesize: 100" >> "$GO_TEMPLATE_PATH"
}

# Cleanup temporary scripts
cleanup_temp_scripts() {
    if [ -n "$TEMP_SCRIPT_PATH" ] && [ -f "$TEMP_SCRIPT_PATH" ]; then
        $RM_CMD -f "$TEMP_SCRIPT_PATH"
        TEMP_SCRIPT_PATH=""
    fi
    if [ -n "$GO_TEMPLATE_PATH" ] && [ -f "$GO_TEMPLATE_PATH" ]; then
        $RM_CMD -f "$GO_TEMPLATE_PATH"
        GO_TEMPLATE_PATH=""
    fi
}

# ==============================================================================
# Test Definitions
# ==============================================================================

# Test format: "name;args;jq_query;pattern"
# Note: Using semicolon (;) as delimiter because jq queries use pipe (|)
#
# Placeholders in args:
#   PORT    - Replaced with MOCK_PORT
#   TESTDIR - Replaced with TEST_DATA_DIR
#
# pattern notes:
#   - Matched against the jq result using bash's =~ operator
#   - Use POSIX Extended Regular Expression (ERE) syntax
#
# jq_query notes:
#   - Log file is wrapped in array with jq -s
#   - Each entry has: timestamp, method, path, request, response, status
#   - response field contains JSON string that needs fromjson

# Perl collector tests
declare -a PERL_TESTS=(
    "basic_submission;--server localhost:PORT --dir TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
    "source_param;--server localhost:PORT --source test-client --dir TESTDIR;.[0].uri | capture(\"source=(?<src>[^&]*)\") | .src;^test-client$"
    "file_count;--server localhost:PORT --dir TESTDIR;length;^[1-9][0-9]*$"
    "port_param;--server localhost --port PORT --dir TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
)

# Python collector tests
declare -a PYTHON_TESTS=(
    "basic_submission;-s localhost -p PORT --dirs TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
    "source_param;-s localhost -p PORT -S test-host --dirs TESTDIR;.[0].uri | capture(\"source=(?<src>[^&]*)\") | .src;^test-host$"
    "file_count;-s localhost -p PORT --dirs TESTDIR;length;^[1-9][0-9]*$"
)

# Shell script tests (require script modification)
declare -a SH_TESTS=(
    "basic_submission;;.[0].response | fromjson | .id;^[0-9]+$"
    "file_count;;length;^[1-9][0-9]*$"
)

# PowerShell tests
declare -a PS1_TESTS=(
    "basic_submission;-ThunderstormServer localhost -ThunderstormPort PORT -Folder TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
    "file_count;-ThunderstormServer localhost -ThunderstormPort PORT -Folder TESTDIR;length;^[1-9][0-9]*$"
)

# Batch script tests (Windows only, require script modification)
declare -a BAT_TESTS=(
    "basic_submission;;.[0].response | fromjson | .id;^[0-9]+$"
)

# Go collector tests
# Note: The Go collector issues a GET /api/v1/status health check before uploading,
# so jq queries must filter for checkAsync entries to skip the status request.
declare -a GO_TESTS=(
    "basic_submission;-s localhost --port PORT -p TESTDIR;[.[] | select(.handler == \"CheckAsync\")] | .[0].response | fromjson | .id;^[0-9]+$"
    "source_param;-s localhost --port PORT -o test-device -p TESTDIR;[.[] | select(.handler == \"CheckAsync\")] | .[0].uri | capture(\"source=(?<src>[^&]*)\") | .src;^test-device$"
    "file_count;-s localhost --port PORT -p TESTDIR;[.[] | select(.handler == \"CheckAsync\")] | length;^[1-9][0-9]*$"
)

# ==============================================================================
# Test Execution Functions
# ==============================================================================

# Check if required interpreter is available
check_collector_requirements() {
    local collector=$1

    case $collector in
        perl)
            if ! command -v $PERL_CMD >/dev/null 2>&1; then
                echo "ERROR: Perl interpreter not found ($PERL_CMD)"
                echo "Install with: choco install strawberryperl (Windows) or apt-get install perl (Linux)"
                return 1
            fi
            # Check for LWP::UserAgent module
            if ! $PERL_CMD -MLWP::UserAgent -e 1 2>/dev/null; then
                echo "ERROR: Perl LWP::UserAgent module not found"
                echo "Install with: apt-get install libwww-perl (Linux) or cpan LWP::UserAgent"
                return 1
            fi
            ;;
        python)
            if ! command -v $PYTHON_CMD >/dev/null 2>&1; then
                echo "ERROR: Python interpreter not found ($PYTHON_CMD)"
                echo "Install with: choco install python (Windows) or apt-get install python3 (Linux)"
                return 1
            fi
            ;;
        sh)
            if ! command -v $BASH_CMD >/dev/null 2>&1; then
                echo "ERROR: Bash interpreter not found ($BASH_CMD)"
                return 1
            fi
            if ! command -v curl >/dev/null 2>&1; then
                echo "ERROR: curl not found (required by shell collector)"
                echo "Install with: apt-get install curl (Linux) or choco install curl (Windows)"
                return 1
            fi
            ;;
        ps1)
            if ! command -v $PWSH_CMD >/dev/null 2>&1; then
                echo "ERROR: PowerShell interpreter not found ($PWSH_CMD)"
                if [ "$PLATFORM" = "linux" ]; then
                    echo "Install PowerShell Core: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
                fi
                return 1
            fi
            ;;
        bat)
            if [ "$PLATFORM" != "windows" ]; then
                echo "ERROR: Batch scripts can only be tested on Windows"
                return 1
            fi
            if ! command -v $CMD_CMD >/dev/null 2>&1; then
                echo "ERROR: cmd.exe not found"
                return 1
            fi
            ;;
        go)
            if ! command -v go >/dev/null 2>&1; then
                echo "ERROR: Go toolchain not found"
                echo "Install from: https://go.dev/dl/"
                return 1
            fi
            if ! command -v make >/dev/null 2>&1; then
                echo "ERROR: make not found (required to build Go collector)"
                return 1
            fi
            ;;
        *)
            echo "ERROR: Unknown collector: $collector"
            return 1
            ;;
    esac

    return 0
}

# Run a single test
# Arguments: collector_type, test_spec
run_test() {
    local collector=$1
    local test_spec=$2

    # Parse test specification (semicolon-delimited to avoid conflict with jq pipe)
    IFS=';' read -r test_name args jq_query pattern <<< "$test_spec"

    echo "  Running test: $test_name"

    # Call setup function based on collector type
    local setup_ok=true
    case $collector in
        perl)   setup_perl_script   || setup_ok=false ;;
        python) setup_python_script || setup_ok=false ;;
        sh)     setup_sh_script     || setup_ok=false ;;
        bat)    setup_bat_script    || setup_ok=false ;;
        ps1)    setup_ps1_script    || setup_ok=false ;;
        go)     setup_go_binary     || setup_ok=false ;;
    esac
    if [ "$setup_ok" = false ]; then
        echo "    ERROR: Setup function failed"
        echo "  FAIL"
        return 1
    fi

    # Replace placeholders in args
    args="${args//PORT/$MOCK_PORT}"
    args="${args//TESTDIR/$TEST_DATA_DIR}"

    # Start mock server
    if ! start_mock_server "$MOCK_PORT"; then
        cleanup_temp_scripts
        echo "  FAIL"
        return 1
    fi

    # Build collector command
    # Use TEMP_SCRIPT_PATH if set (for modified script copies), otherwise use original
    local collector_cmd=""
    local collector_exit=0
    local script_path=""

    case $collector in
        perl)
            script_path="${TEMP_SCRIPT_PATH:-$PROJECT_ROOT/scripts/thunderstorm-collector.pl}"
            collector_cmd="$PERL_CMD \"$script_path\" -- $args"
            ;;
        python)
            script_path="${TEMP_SCRIPT_PATH:-$PROJECT_ROOT/scripts/thunderstorm-collector.py}"
            collector_cmd="$PYTHON_CMD \"$script_path\" $args"
            ;;
        sh)
            collector_cmd="$BASH_CMD \"$TEMP_SCRIPT_PATH\" $args"
            ;;
        ps1)
            script_path="${TEMP_SCRIPT_PATH:-$PROJECT_ROOT/scripts/thunderstorm-collector.ps1}"
            local ps1_path
            ps1_path=$(to_native_path "$script_path")
            collector_cmd="$PWSH_CMD -ExecutionPolicy Bypass -File \"$ps1_path\" $args"
            ;;
        bat)
            local bat_path
            bat_path=$(to_native_path "$TEMP_SCRIPT_PATH")
            collector_cmd="$CMD_CMD /c \"$bat_path\" $args"
            ;;
        go)
            collector_cmd="\"$GO_BINARY_PATH\" --template \"$GO_TEMPLATE_PATH\" $args"
            ;;
    esac

    # Execute collector with timeout
    if ! run_with_timeout "$COLLECTOR_TIMEOUT" "$collector_cmd" >/dev/null 2>&1; then
        collector_exit=$?
        if [ $collector_exit -eq 124 ]; then
            echo "    ERROR: Collector timed out after ${COLLECTOR_TIMEOUT}s"
        else
            echo "    ERROR: Collector exited with code $collector_exit"
        fi
    fi

    # Give mock server a moment to finish writing logs
    sleep 1

    # Stop mock server
    stop_mock_server

    # If collector failed/timed out, show log and fail
    if [ $collector_exit -ne 0 ]; then
        show_log_snippet "$MOCK_LOG_FILE"
        cleanup_temp_scripts
        $RM_CMD -f "$MOCK_LOG_FILE"
        echo "  FAIL"
        return 1
    fi

    # Verify results
    if ! verify_result "$jq_query" "$pattern" "$MOCK_LOG_FILE"; then
        show_log_snippet "$MOCK_LOG_FILE"
        cleanup_temp_scripts
        $RM_CMD -f "$MOCK_LOG_FILE"
        echo "  FAIL"
        return 1
    fi

    # Success - cleanup
    cleanup_temp_scripts
    $RM_CMD -f "$MOCK_LOG_FILE"
    echo "  PASS"
    return 0
}

# Run all tests for a collector
# Arguments: collector_name, collector_type, test_specs...
run_collector_tests() {
    local name=$1
    local collector_type=$2
    shift 2

    echo ""
    echo "========================================"
    echo "Testing $name Collector"
    echo "========================================"

    # Check requirements
    if ! check_collector_requirements "$collector_type"; then
        echo ""
        echo "Skipping $name collector tests due to missing requirements"
        COLLECTOR_RESULTS["$name"]="SKIPPED"
        return 1
    fi

    local passed=0
    local failed=0

    for test_spec in "$@"; do
        if run_test "$collector_type" "$test_spec"; then
            ((passed++))
            ((TOTAL_PASSED++))
        else
            ((failed++))
            ((TOTAL_FAILED++))
        fi
    done

    echo ""
    echo "Results: $passed passed, $failed failed"

    COLLECTOR_RESULTS["$name"]="$passed/$((passed + failed))"

    if [ $failed -gt 0 ]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# Main Program
# ==============================================================================

usage() {
    cat <<EOF
Usage: test-collectors.sh [OPTIONS] <collector>

Test Thunderstorm collector scripts against a mock server.

COLLECTORS:
  perl, pl        Test Perl collector (thunderstorm-collector.pl)
  python, py      Test Python collector (thunderstorm-collector.py)
  sh, bash        Test Shell collector (thunderstorm-collector.sh)
  ps1, powershell Test PowerShell collector (thunderstorm-collector.ps1)
  bat, batch      Test Batch collector (thunderstorm-collector.bat) [Windows]
  go              Test Go collector (go/)
  all             Test all applicable collectors

OPTIONS:
  -h, --help           Show this help message
  -p, --port NUM       Mock server port (default: 8080)
  -t, --timeout NUM    Collector timeout in seconds (default: 120)

ENVIRONMENT VARIABLES:
  THUNDERSTORM_MOCK_EXECUTABLE  Path to thunderstorm-mock executable
                                (default: ./thunderstorm-mock)
  MOCK_PORT                     Mock server port (default: 8080)
  COLLECTOR_TIMEOUT             Timeout in seconds (default: 120)

EXAMPLES:
  # Test Perl collector
  ./tests/test-collectors.sh perl

  # Test with custom timeout (60 seconds)
  ./tests/test-collectors.sh --timeout 60 python

  # Test on custom port
  ./tests/test-collectors.sh --port 9090 perl

  # Test all collectors with custom mock location
  THUNDERSTORM_MOCK_EXECUTABLE=/path/to/mock ./tests/test-collectors.sh all
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -p|--port)
                MOCK_PORT="$2"
                shift 2
                ;;
            -t|--timeout)
                COLLECTOR_TIMEOUT="$2"
                shift 2
                ;;
            -*)
                echo "ERROR: Unknown option: $1"
                echo ""
                usage
                exit 1
                ;;
            *)
                COLLECTOR_KEYWORD="$1"
                shift
                ;;
        esac
    done
}

validate_requirements() {
    # Check for jq
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required but not found"
        echo "Install with: apt-get install jq (Linux) or choco install jq (Windows)"
        exit 1
    fi

    # Check for mock executable
    if [ ! -x "$MOCK_EXECUTABLE" ]; then
        echo "ERROR: Mock executable not found or not executable: $MOCK_EXECUTABLE"
        echo "Set THUNDERSTORM_MOCK_EXECUTABLE environment variable to specify location"
        exit 1
    fi
}

cleanup_all() {
    echo ""
    echo "Cleaning up..."

    # Stop mock server if still running
    stop_mock_server

    # Remove temporary scripts
    cleanup_temp_scripts

    # Remove test data
    cleanup_test_data

    # Remove any leftover mock logs
    $RM_CMD -f /tmp/mock-*.json 2>/dev/null || true
    $RM_CMD -f /tmp/tmp.*.json 2>/dev/null || true

    echo "Cleanup complete"
}

print_summary() {
    echo ""
    echo "========================================"
    echo "Overall Results"
    echo "========================================"

    for collector in "${!COLLECTOR_RESULTS[@]}"; do
        printf "%-20s %s\n" "$collector Collector:" "${COLLECTOR_RESULTS[$collector]}"
    done

    echo ""
    echo "Total: $TOTAL_PASSED passed, $TOTAL_FAILED failed"

    if [ $TOTAL_FAILED -gt 0 ]; then
        return 1
    fi
    return 0
}

main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Validate collector keyword
    if [ -z "$COLLECTOR_KEYWORD" ]; then
        echo "ERROR: No collector specified"
        echo ""
        usage
        exit 1
    fi

    # Validate requirements
    validate_requirements

    # Set up trap for cleanup
    trap cleanup_all EXIT INT TERM

    # Display configuration
    echo "========================================"
    echo "Thunderstorm Collector Test Suite"
    echo "========================================"
    echo "Platform:      $PLATFORM"
    echo "Mock Server:   $MOCK_EXECUTABLE"
    echo "Mock Port:     $MOCK_PORT"
    echo "Timeout:       ${COLLECTOR_TIMEOUT}s"
    echo "Test Data:     $TEST_DATA_DIR"

    # Setup test data
    setup_test_data

    # Track overall success
    local overall_success=0

    # Run tests for specified collector(s)
    case $COLLECTOR_KEYWORD in
        perl|pl)
            run_collector_tests "Perl" "perl" "${PERL_TESTS[@]}" || overall_success=1
            ;;
        python|py)
            run_collector_tests "Python" "python" "${PYTHON_TESTS[@]}" || overall_success=1
            ;;
        sh|bash)
            run_collector_tests "Shell" "sh" "${SH_TESTS[@]}" || overall_success=1
            ;;
        ps1|powershell)
            run_collector_tests "PowerShell" "ps1" "${PS1_TESTS[@]}" || overall_success=1
            ;;
        bat|batch)
            run_collector_tests "Batch" "bat" "${BAT_TESTS[@]}" || overall_success=1
            ;;
        go)
            run_collector_tests "Go" "go" "${GO_TESTS[@]}" || overall_success=1
            ;;
        all)
            # Run all applicable collectors
            run_collector_tests "Perl" "perl" "${PERL_TESTS[@]}" || overall_success=1
            run_collector_tests "Python" "python" "${PYTHON_TESTS[@]}" || overall_success=1
            run_collector_tests "Shell" "sh" "${SH_TESTS[@]}" || overall_success=1

            # PowerShell - try on all platforms (pwsh on Linux, powershell.exe on Windows)
            run_collector_tests "PowerShell" "ps1" "${PS1_TESTS[@]}" || overall_success=1

            # Go collector
            run_collector_tests "Go" "go" "${GO_TESTS[@]}" || overall_success=1

            # Batch - Windows only
            if [ "$PLATFORM" = "windows" ]; then
                run_collector_tests "Batch" "bat" "${BAT_TESTS[@]}" || overall_success=1
            else
                echo ""
                echo "Skipping Batch collector tests (Windows only)"
                COLLECTOR_RESULTS["Batch"]="SKIPPED (Windows only)"
            fi
            ;;
        *)
            echo "ERROR: Unknown collector: $COLLECTOR_KEYWORD"
            echo ""
            usage
            exit 1
            ;;
    esac

    # Print summary
    print_summary || overall_success=1

    exit $overall_success
}

# ==============================================================================
# Entry Point
# ==============================================================================

main "$@"
