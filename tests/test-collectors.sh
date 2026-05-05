#!/bin/bash
#
# test-collectors.sh - Test Thunderstorm collector scripts
#
# DESCRIPTION:
#   Entrypoint for testing Thunderstorm collector scripts against the
#   thunderstorm-mock server. Delegates to test-single.sh for each collector.
#
#   The collectors use /api/checkAsync (old API scheme). An API proxy in front of
#   the mock server translates /api/ to /api/v1/ (new OpenAPI scheme).
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
#   ./tests/test-collectors.sh perl
#   ./tests/test-collectors.sh all
#   ./tests/test-collectors.sh --port 9090 --timeout 60 perl

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

COLLECTOR_KEYWORD=""

# ==============================================================================
# Argument Parsing
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
  ./tests/test-collectors.sh perl
  ./tests/test-collectors.sh --timeout 60 python
  ./tests/test-collectors.sh --port 9090 perl
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

# ==============================================================================
# Collector Resolution
# ==============================================================================

# Map keyword to collector directory name(s)
resolve_collectors() {
    local keyword=$1
    case $keyword in
        perl|pl)        echo "perl" ;;
        python|py)      echo "python" ;;
        sh|bash)        echo "sh" ;;
        ps1|powershell) echo "ps1" ;;
        bat|batch)      echo "bat" ;;
        go)             echo "go" ;;
        all)
            local collectors="perl python sh ps1 go"
            [ "$PLATFORM" = "windows" ] && collectors="$collectors bat"
            echo "$collectors"
            ;;
        *)
            echo "ERROR: Unknown collector: $keyword" >&2
            return 1
            ;;
    esac
}

# ==============================================================================
# Validation & Cleanup
# ==============================================================================

validate_requirements() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required but not found"
        echo "Install with: apt-get install jq (Linux) or choco install jq (Windows)"
        exit 1
    fi
    if [ ! -x "$MOCK_EXECUTABLE" ]; then
        echo "ERROR: Mock executable not found or not executable: $MOCK_EXECUTABLE"
        echo "Set THUNDERSTORM_MOCK_EXECUTABLE environment variable to specify location"
        exit 1
    fi
}

cleanup_all() {
    echo ""
    echo "Cleaning up..."
    stop_mock_server
    cleanup_test_data
    $RM_CMD -f /tmp/mock-*.json 2>/dev/null || true
    $RM_CMD -f /tmp/tmp.*.json 2>/dev/null || true
    echo "Cleanup complete"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    parse_arguments "$@"

    if [ -z "$COLLECTOR_KEYWORD" ]; then
        echo "ERROR: No collector specified"
        echo ""
        usage
        exit 1
    fi

    validate_requirements

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

    setup_test_data

    local collectors
    collectors=$(resolve_collectors "$COLLECTOR_KEYWORD") || exit 1

    # Export variables for test-single.sh subprocesses
    export THUNDERSTORM_MOCK_EXECUTABLE="$MOCK_EXECUTABLE"
    export MOCK_PORT COLLECTOR_TIMEOUT

    local overall_success=0
    local total_passed=0
    local total_failed=0
    declare -A collector_results

    for collector in $collectors; do
        # Run test-single.sh and capture output
        local output result_line
        output=$("$SCRIPT_DIR/test-single.sh" "$collector" 2>&1)
        local exit_code=$?

        # Display output (minus the machine-readable RESULT line)
        echo "$output" | grep -v "^RESULT:"

        # Parse machine-readable result
        result_line=$(echo "$output" | grep "^RESULT:" | tail -1)
        local p f s
        IFS=':' read -r _ p f s <<< "$result_line"
        p=${p:-0}; f=${f:-0}; s=${s:-0}

        # Extract collector display name from output
        local name
        name=$(echo "$output" | sed -n 's/^Testing \(.*\) Collector$/\1/p' | head -1)
        name="${name:-$collector}"

        if [ "$s" -gt 0 ]; then
            collector_results["$name"]="SKIPPED"
        else
            total_passed=$((total_passed + p))
            total_failed=$((total_failed + f))
            collector_results["$name"]="$p/$((p + f))"
            [ $exit_code -ne 0 ] && overall_success=1
        fi
    done

    # Handle non-Windows bat skip
    if [ "$COLLECTOR_KEYWORD" = "all" ] && [ "$PLATFORM" != "windows" ]; then
        echo ""
        echo "Skipping Batch collector tests (Windows only)"
        collector_results["Batch"]="SKIPPED (Windows only)"
    fi

    # Print summary
    echo ""
    echo "========================================"
    echo "Overall Results"
    echo "========================================"

    for name in "${!collector_results[@]}"; do
        printf "%-20s %s\n" "$name Collector:" "${collector_results[$name]}"
    done

    echo ""
    echo "Total: $total_passed passed, $total_failed failed"

    [ $total_failed -gt 0 ] && overall_success=1
    exit $overall_success
}

main "$@"
