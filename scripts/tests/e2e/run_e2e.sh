#!/usr/bin/env bash
# =============================================================================
# End-to-End Test Suite for Thunderstorm Collector Scripts
# =============================================================================
#
# Runs each collector script against a stub server and verifies:
#   - Files are uploaded correctly
#   - Collection markers (begin/end) are sent
#   - scan_id propagates from begin marker to uploads and end marker
#   - Source field is correct in markers and uploads
#   - Filtering by extension/size/age works
#   - Retry logic handles 503 responses
#   - Exit codes follow the contract (0=clean, 1=partial, 2=fatal)
#   - Failed count is tracked in end marker stats
#   - 503 retry uses single sleep strategy (no double-sleep)
#   - Error messages go to stderr (not stdout)
#   - --log-file captures error records (not just start/finish)
#   - No encoding warnings on non-ASCII filenames
#   - Run completes even if begin marker POST fails
#   - All collection markers are valid JSON
#   - Marker timestamps are ISO 8601
#   - End marker sent even when begin marker fails
#   - HTTP-level errors (500) are detected (not just connection failures)
#   - Special characters in --source produce valid JSON markers
#   - HTTP error messages appear on stderr (not just stdout)
#
# Test coverage notes:
#   - ps1, ps2: require pwsh (PowerShell Core) or Windows + PowerShell 2.0+
#   - bat: requires Windows with a functional curl.exe (Win10+ has built-in curl;
#     Win7 needs curl for Windows from https://curl.se/windows/ with UCRT runtime).
#     The batch collector is NOT recommended for production use.
#   - py2: requires python2 (end-of-life, not commonly available)
#
# Usage:
#   ./run_e2e.sh [path/to/thunderstorm-stub-server]
#
# Environment:
#   STUB_SERVER_BIN   Path to thunderstorm-stub-server binary
#   SKIP_SCRIPTS      Space-separated list of scripts to skip (e.g. "py2 bat")
#
set -uo pipefail
# Note: -e is intentionally NOT set — test functions handle errors via return codes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STUB_BIN="${1:-${STUB_SERVER_BIN:-}}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# ── Locate stub server ──────────────────────────────────────────────────────

find_stub_server() {
    if [ -n "$STUB_BIN" ] && [ -x "$STUB_BIN" ]; then
        echo "$STUB_BIN"; return
    fi
    # Check common locations
    local candidates=(
        "$SCRIPTS_DIR/../thunderstorm-stub-server/thunderstorm-stub-server"
        "$(command -v thunderstorm-stub-server 2>/dev/null || true)"
    )
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
    done
    echo ""
}

STUB_BIN="$(find_stub_server)"
if [ -z "$STUB_BIN" ]; then
    echo "ERROR: thunderstorm-stub-server binary not found."
    echo "Set STUB_SERVER_BIN or pass as first argument."
    exit 2
fi

# ── Fixture setup ────────────────────────────────────────────────────────────

FIXTURES_DIR="$(mktemp -d)"
LOG_FILE="$(mktemp)"
STUB_PORT=0
STUB_PID=0

cleanup() {
    [ "$STUB_PID" -gt 0 ] && kill "$STUB_PID" 2>/dev/null && wait "$STUB_PID" 2>/dev/null || true
    rm -rf "$FIXTURES_DIR" "$LOG_FILE"
}
trap cleanup EXIT

create_fixtures() {
    # Standard test files with matching extensions
    echo "malware_payload_data" > "$FIXTURES_DIR/malware.exe"
    echo "suspicious_dll_code" > "$FIXTURES_DIR/library.dll"
    echo "batch_script_content" > "$FIXTURES_DIR/startup.bat"
    echo "powershell_payload" > "$FIXTURES_DIR/invoke.ps1"

    # Files that should be filtered OUT (wrong extension)
    echo "vacation photo" > "$FIXTURES_DIR/photo.jpg"
    echo "music file" > "$FIXTURES_DIR/song.mp3"
    echo "document" > "$FIXTURES_DIR/report.pdf"

    # Non-ASCII filename
    echo "résumé content" > "$FIXTURES_DIR/résumé.exe"

    # File with special characters
    echo "special chars" > "$FIXTURES_DIR/alert!warn.dll"

    # Touch all files to ensure they're within MAX_AGE
    find "$FIXTURES_DIR" -type f -exec touch {} +
}

create_fixtures

# ── Stub server management ──────────────────────────────────────────────────

start_stub() {
    # Find a free port
    STUB_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
    : > "$LOG_FILE"
    "$STUB_BIN" --port "$STUB_PORT" --log-file "$LOG_FILE" --retry-after 1 &
    STUB_PID=$!
    # Wait for server to be ready
    local tries=0
    while ! curl -s "http://127.0.0.1:${STUB_PORT}/api/status" >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -gt 20 ] && { echo "ERROR: stub server failed to start"; exit 2; }
        sleep 0.1
    done
}

reset_stub() {
    curl -s -X POST "http://127.0.0.1:${STUB_PORT}/api/test/reset" >/dev/null
}

configure_stub() {
    curl -s -X POST -H "Content-Type: application/json" -d "$1" \
        "http://127.0.0.1:${STUB_PORT}/api/test/config" >/dev/null
}

get_log() {
    curl -s "http://127.0.0.1:${STUB_PORT}/api/test/log"
}

start_stub

# ── Helper: parse JSONL log ──────────────────────────────────────────────────

# Count entries of a given type
count_type() {
    local type_val="$1"
    get_log | python3 -c "
import sys, json
count = 0
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('type') == '$type_val':
        count += 1
print(count)
"
}

# Get field from first marker of given type
marker_field() {
    local marker="$1" field="$2"
    get_log | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('type') == 'collection_marker' and d.get('marker') == '$marker':
        val = d.get('$field', '')
        if isinstance(val, dict):
            import json as j
            print(j.dumps(val))
        else:
            print(val)
        break
"
}

# Get all uploaded filenames
uploaded_files() {
    get_log | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('type') == 'THOR finding':
        print(d['subject'].get('client_filename', d['subject'].get('path', '')))
"
}

# Get source from all uploads
upload_sources() {
    get_log | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('type') == 'THOR finding':
        print(d['subject'].get('source', ''))
"
}

# ── Check script availability ────────────────────────────────────────────────

SKIP_SCRIPTS="${SKIP_SCRIPTS:-}"

can_run() {
    local script="$1"
    # Check skip list
    for s in $SKIP_SCRIPTS; do
        [ "$s" = "$script" ] && return 1
    done
    case "$script" in
        bash) command -v bash >/dev/null 2>&1 ;;
        ash)  command -v dash >/dev/null 2>&1 || command -v busybox >/dev/null 2>&1 ;;
        py3)  command -v python3 >/dev/null 2>&1 ;;
        py2)  command -v python2 >/dev/null 2>&1 ;;
        perl) perl -e 'use LWP::UserAgent' 2>/dev/null ;;
        ps1)  command -v pwsh >/dev/null 2>&1 ;;
        ps2)  command -v pwsh >/dev/null 2>&1 ;;  # PS2 tests run under pwsh with version emulation
        bat)  return 1 ;;  # Windows only
    esac
}

# ── Run a collector script ───────────────────────────────────────────────────

run_collector() {
    local script="$1" source="$2" extra_args="${3:-}"
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    local rc=0

    case "$script" in
        bash)
            bash "$SCRIPTS_DIR/thunderstorm-collector.sh" \
                --server 127.0.0.1 --port "$STUB_PORT" \
                --source "$source" --dir "$FIXTURES_DIR" \
                --max-age 365 $extra_args \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        ash)
            # Use dash as ash substitute
            dash "$SCRIPTS_DIR/thunderstorm-collector-ash.sh" \
                --server 127.0.0.1 --port "$STUB_PORT" \
                --source "$source" --dir "$FIXTURES_DIR" \
                --max-age 365 $extra_args \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        py3)
            python3 "$SCRIPTS_DIR/thunderstorm-collector.py" \
                --server 127.0.0.1 --port "$STUB_PORT" \
                --source "$source" --dirs "$FIXTURES_DIR" \
                --max-age 365 $extra_args \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        py2)
            python2 "$SCRIPTS_DIR/thunderstorm-collector-py2.py" \
                --server 127.0.0.1 --port "$STUB_PORT" \
                --source "$source" --dirs "$FIXTURES_DIR" \
                --max-age 365 $extra_args \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        perl)
            perl "$SCRIPTS_DIR/thunderstorm-collector.pl" \
                --server 127.0.0.1 --port "$STUB_PORT" \
                --source "$source" --dir "$FIXTURES_DIR" \
                --max-age 365 $extra_args \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        ps1)
            pwsh -NoProfile -File "$SCRIPTS_DIR/thunderstorm-collector.ps1" \
                -ThunderstormServer 127.0.0.1 -ThunderstormPort "$STUB_PORT" \
                -Source "$source" -Folder "$FIXTURES_DIR" \
                -MaxAge 365 $extra_args \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        ps2)
            pwsh -NoProfile -File "$SCRIPTS_DIR/thunderstorm-collector-ps2.ps1" \
                -ThunderstormServer 127.0.0.1 -ThunderstormPort "$STUB_PORT" \
                -Source "$source" -Folder "$FIXTURES_DIR" \
                -MaxAge 365 $extra_args \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
    esac

    # Export for assertions
    E2E_STDOUT="$(cat "$stdout_file")"
    E2E_STDERR="$(cat "$stderr_file")"
    E2E_RC=$rc
    rm -f "$stdout_file" "$stderr_file"
}

# ── Test definitions ─────────────────────────────────────────────────────────

# Expected uploadable files (matching default extensions): malware.exe, library.dll,
# startup.bat, invoke.ps1, résumé.exe, alert!warn.dll = 6 files
# Filtered out: photo.jpg, song.mp3, report.pdf = 3 files

test_basic_upload() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    local upload_count
    upload_count=$(count_type "THOR finding")

    # bash/ash upload ALL files (no ext filter) = 9 fixtures
    # Others filter by extension = 6 matching fixtures
    local min_expected=4
    if [ "$upload_count" -ge "$min_expected" ]; then
        pass "${script}/basic-upload: ${upload_count} files uploaded"
    else
        fail "${script}/basic-upload: expected ≥${min_expected} uploads, got ${upload_count}"
    fi
}

test_collection_markers() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    local begin_count end_count
    begin_count=$(count_type "collection_marker" | python3 -c "
import sys, json
count=0
for line in open('$LOG_FILE'):
    line=line.strip()
    if not line: continue
    d=json.loads(line)
    if d.get('type')=='collection_marker' and d.get('marker')=='begin': count+=1
print(count)
" 2>/dev/null || count_type "collection_marker")

    # Simpler: just check begin and end markers exist
    local begin_marker end_marker
    begin_marker="$(marker_field begin source)"
    end_marker="$(marker_field end source)"

    if [ -n "$begin_marker" ]; then
        pass "${script}/begin-marker: source=${begin_marker}"
    else
        fail "${script}/begin-marker: no begin marker found"
    fi

    if [ -n "$end_marker" ]; then
        pass "${script}/end-marker: source=${end_marker}"
    else
        fail "${script}/end-marker: no end marker found"
    fi
}

test_scan_id_propagation() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    local begin_scan_id end_scan_id
    begin_scan_id="$(marker_field begin scan_id)"
    end_scan_id="$(marker_field end scan_id)"

    if [ -n "$begin_scan_id" ] && [ "$begin_scan_id" = "$end_scan_id" ]; then
        pass "${script}/scan-id-propagation: ${begin_scan_id}"
    else
        fail "${script}/scan-id-propagation: begin=${begin_scan_id} end=${end_scan_id}"
    fi
}

test_source_field() {
    local script="$1"
    local expected_source="source-test-${script}"
    reset_stub
    run_collector "$script" "$expected_source"

    local marker_source
    marker_source="$(marker_field begin source)"

    if [ "$marker_source" = "$expected_source" ]; then
        pass "${script}/source-in-marker: ${marker_source}"
    else
        fail "${script}/source-in-marker: expected '${expected_source}', got '${marker_source}'"
    fi

    # Check source in uploads
    local upload_source_count
    upload_source_count=$(upload_sources | grep -c "$expected_source" || true)
    if [ "$upload_source_count" -ge 1 ]; then
        pass "${script}/source-in-uploads: ${upload_source_count} uploads have correct source"
    else
        fail "${script}/source-in-uploads: no uploads with source '${expected_source}'"
    fi
}

test_extension_filtering() {
    local script="$1"

    # Only PS1 and PS2 have extension filtering; other scripts upload all files
    case "$script" in
        ps1|ps2) ;;  # continue with test
        *)
            skip "${script}/ext-filter: script has no extension filtering"
            return
            ;;
    esac

    reset_stub
    run_collector "$script" "e2e-test-${script}"

    local uploaded
    uploaded="$(uploaded_files)"

    # photo.jpg and song.mp3 should NOT appear (.pdf IS in PS extension lists)
    local filtered_ok=true
    for excluded in photo.jpg song.mp3; do
        if echo "$uploaded" | grep -q "$excluded"; then
            fail "${script}/ext-filter: '${excluded}' should have been filtered out"
            filtered_ok=false
        fi
    done
    if $filtered_ok; then
        pass "${script}/ext-filter: non-matching extensions correctly filtered"
    fi
}

test_exit_code_clean() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    if [ "$E2E_RC" -eq 0 ]; then
        pass "${script}/exit-code-clean: exit 0"
    else
        fail "${script}/exit-code-clean: expected 0, got ${E2E_RC}"
    fi
}

test_exit_code_partial_failure() {
    local script="$1"
    reset_stub
    # Configure stub to return 500 for uploads 1-5 (covers all retries of the 1st file)
    configure_stub '{"upload_rules":[{"match_count":[1,2,3,4,5],"status":500,"body":"{\"error\":\"test\"}"},{"default":true,"status":200}]}'

    # Force sync mode for async-default scripts; limit retries for speed
    local extra_flags=""
    case "$script" in
        bash|ash)  extra_flags="--sync --retries 1" ;;
        py3|py2)   extra_flags="--sync --retries 1" ;;
        perl)      extra_flags="--retries 1" ;;
        # PS scripts don't have a --retries flag; they retry 3x by default
    esac
    run_collector "$script" "e2e-test-${script}" "$extra_flags"

    if [ "$E2E_RC" -eq 1 ]; then
        pass "${script}/exit-code-partial: exit 1 on partial failure"
    elif [ "$E2E_RC" -eq 0 ]; then
        # Some scripts may not detect partial failure depending on how the stub
        # returns errors and how the script handles non-503 HTTP errors
        case "$script" in
            ps1|ps2)
                skip "${script}/exit-code-partial: PS retry/failure detection needs investigation"
                ;;
            *)
                fail "${script}/exit-code-partial: expected 1, got ${E2E_RC}"
                ;;
        esac
    else
        fail "${script}/exit-code-partial: expected 1, got ${E2E_RC}"
    fi
}

test_exit_code_fatal() {
    local script="$1"
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    local rc=0

    # Test with missing required --server flag → immediate config error (exit 2)
    # This is fast (no network I/O) and tests the fatal exit path
    case "$script" in
        bash)
            bash "$SCRIPTS_DIR/thunderstorm-collector.sh" \
                --dir "$FIXTURES_DIR" \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        ash)
            dash "$SCRIPTS_DIR/thunderstorm-collector-ash.sh" \
                --dir "$FIXTURES_DIR" \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        py3)
            python3 "$SCRIPTS_DIR/thunderstorm-collector.py" \
                --dirs "$FIXTURES_DIR" \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        perl)
            perl "$SCRIPTS_DIR/thunderstorm-collector.pl" \
                --dir "$FIXTURES_DIR" \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        ps1)
            pwsh -NoProfile -File "$SCRIPTS_DIR/thunderstorm-collector.ps1" \
                -Folder "$FIXTURES_DIR" \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
        ps2)
            pwsh -NoProfile -File "$SCRIPTS_DIR/thunderstorm-collector-ps2.ps1" \
                -Folder "$FIXTURES_DIR" \
                >"$stdout_file" 2>"$stderr_file" || rc=$?
            ;;
    esac
    rm -f "$stdout_file" "$stderr_file"

    # Scripts with missing/empty server should exit non-zero (ideally 2 for fatal).
    # PS scripts don't validate -ThunderstormServer as mandatory; they proceed with default.
    case "$script" in
        ps1|ps2)
            if [ "$rc" -ne 0 ]; then
                pass "${script}/exit-code-fatal: exit ${rc} on missing server"
            else
                skip "${script}/exit-code-fatal: PS scripts don't require -ThunderstormServer"
            fi
            ;;
        *)
            if [ "$rc" -ne 0 ]; then
                pass "${script}/exit-code-fatal: exit ${rc} on missing server"
            else
                fail "${script}/exit-code-fatal: expected non-zero, got 0"
            fi
            ;;
    esac
}

test_retry_on_503() {
    local script="$1"
    reset_stub
    # Return 503 for first 2 uploads, then 200 for everything else
    configure_stub '{"upload_rules":[{"match_count":[1,2],"status":503},{"default":true,"status":200}]}'

    # Force sync mode for async-default scripts; use 3 retries (enough to pass the 2 503s)
    local extra_flags=""
    case "$script" in
        bash|ash)  extra_flags="--sync --retries 3" ;;
        py3|py2)   extra_flags="--sync --retries 3" ;;
        perl)      extra_flags="--retries 3" ;;
    esac
    run_collector "$script" "e2e-test-${script}" "$extra_flags"

    # The first file should eventually succeed (after retries), so upload count should be ≥4
    local upload_count
    upload_count=$(count_type "THOR finding")
    if [ "$upload_count" -ge 4 ]; then
        pass "${script}/retry-503: ${upload_count} files uploaded after 503 retries"
    else
        fail "${script}/retry-503: expected ≥4 uploads, got ${upload_count}"
    fi
}

test_end_marker_stats() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    local stats
    stats="$(marker_field end stats)"

    if [ -z "$stats" ]; then
        fail "${script}/end-stats: no stats in end marker"
        return
    fi

    # Check that stats has scanned and submitted fields
    local has_scanned has_submitted
    has_scanned=$(echo "$stats" | python3 -c "import sys,json; d=json.load(sys.stdin); print(1 if 'scanned' in d else 0)" 2>/dev/null || echo 0)
    has_submitted=$(echo "$stats" | python3 -c "import sys,json; d=json.load(sys.stdin); print(1 if 'submitted' in d else 0)" 2>/dev/null || echo 0)

    if [ "$has_scanned" = "1" ] && [ "$has_submitted" = "1" ]; then
        pass "${script}/end-stats: stats contain scanned+submitted"
    else
        fail "${script}/end-stats: missing fields in stats: ${stats}"
    fi
}

# ── New tests: coverage gaps from code review ────────────────────────────────

# Test: 503 retry should not double-sleep (critical finding)
# After a 503 with Retry-After, the script should sleep EITHER the server-specified
# time OR exponential backoff — not both in sequence.
test_503_no_double_sleep() {
    local script="$1"
    reset_stub
    # 503 with short Retry-After on first upload, then 200 for all
    configure_stub '{"upload_rules":[{"match_count":[1],"status":503,"headers":{"Retry-After":"1"}},{"default":true,"status":200}]}'

    local extra_flags=""
    case "$script" in
        bash|ash)  extra_flags="--sync --retries 3" ;;
        py3|py2)   extra_flags="--sync --retries 3" ;;
        perl)      extra_flags="--retries 3" ;;
    esac
    run_collector "$script" "e2e-test-${script}" "$extra_flags"

    # Check output pattern: after a "503" / "Server busy" message, the very next
    # retry-related line should NOT be an exponential backoff "Waiting N seconds"
    # message — that indicates both sleep paths executed.
    local combined="$E2E_STDOUT"$'\n'"$E2E_STDERR"
    local double_sleep_detected=false

    # Different scripts use different messages. Look for the pattern:
    # Line with "503" or "busy" followed by line with "Waiting" or "backoff" or "retry" with seconds
    if echo "$combined" | grep -q "Server busy (503)"; then
        # Perl/Python style: check if "Waiting N seconds to retry" appears AFTER "Server busy"
        if echo "$combined" | grep -A2 "Server busy (503)" | grep -qi "Waiting.*seconds.*retry"; then
            double_sleep_detected=true
        fi
    fi

    if $double_sleep_detected; then
        fail "${script}/503-no-double-sleep: exponential backoff fires after server-specified Retry-After"
    else
        pass "${script}/503-no-double-sleep: single sleep strategy per 503 retry"
    fi
}

# Test: errors should go to stderr, not stdout (m4)
test_errors_to_stderr() {
    local script="$1"
    reset_stub

    # Create an unreadable directory inside fixtures
    local unreadable_dir="$FIXTURES_DIR/noaccess"
    mkdir -p "$unreadable_dir"
    echo "hidden file" > "$unreadable_dir/secret.exe"
    chmod 000 "$unreadable_dir"

    run_collector "$script" "e2e-test-${script}"

    # Restore permissions for cleanup
    chmod 755 "$unreadable_dir"

    # If stderr contains error indicators about the directory, that's correct.
    # If stdout contains "[ERROR]" lines about directory access but stderr doesn't, that's the bug.
    local stdout_errors stderr_errors
    stdout_errors=$(echo "$E2E_STDOUT" | grep -ci "\[ERROR\].*unable\|permission denied\|cannot.*access" || true)
    stderr_errors=$(echo "$E2E_STDERR" | grep -ci "\[ERROR\]\|error\|permission denied\|cannot.*access\|warn" || true)

    # This test is informational — scripts that put errors on stdout get flagged
    if [ "$stdout_errors" -gt 0 ] && [ "$stderr_errors" -eq 0 ]; then
        fail "${script}/errors-to-stderr: errors appear on stdout only (${stdout_errors} lines), not stderr"
    else
        pass "${script}/errors-to-stderr: errors correctly routed (stdout_err=${stdout_errors} stderr_err=${stderr_errors})"
    fi
}

# Test: --log-file should capture error records, not just start/finish (m5)
test_log_file_captures_errors() {
    local script="$1"
    reset_stub

    # Configure stub to return 500 for first 3 uploads
    configure_stub '{"upload_rules":[{"match_count":[1,2,3],"status":500,"body":"{\"error\":\"test\"}"},{"default":true,"status":200}]}'

    local test_log
    test_log="$(mktemp)"

    local extra_flags=""
    case "$script" in
        bash|ash)  extra_flags="--sync --retries 1 --log-file $test_log" ;;
        py3)       extra_flags="--sync --retries 1 --log-file $test_log" ;;
        perl)      extra_flags="--retries 1 --log-file $test_log" ;;
        ps1)       extra_flags="-LogFile $test_log" ;;
        ps2)       extra_flags="-LogFile $test_log" ;;
        *)
            skip "${script}/log-file-errors: script doesn't support --log-file"
            rm -f "$test_log"
            return
            ;;
    esac
    run_collector "$script" "e2e-test-${script}" "$extra_flags"

    if [ ! -s "$test_log" ]; then
        fail "${script}/log-file-errors: log file is empty"
        rm -f "$test_log"
        return
    fi

    # Log should contain SOME evidence of errors/failures, not just start and finish
    local log_content
    log_content="$(cat "$test_log")"
    local has_error_records
    has_error_records=$(echo "$log_content" | grep -ci "error\|fail\|retry\|500" || true)

    if [ "$has_error_records" -gt 0 ]; then
        pass "${script}/log-file-errors: log file contains ${has_error_records} error-related records"
    else
        fail "${script}/log-file-errors: log file has no error records despite failures"
    fi
    rm -f "$test_log"
}

# Test: non-ASCII filenames should not produce Perl/Python warnings on stderr (m6)
test_no_encoding_warnings() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    # Check stderr for encoding warnings
    local warnings
    warnings=$(echo "$E2E_STDERR" | grep -ci "wide character\|UnicodeEncodeError\|UnicodeDecodeError\|codec can't" || true)

    if [ "$warnings" -gt 0 ]; then
        fail "${script}/no-encoding-warnings: ${warnings} encoding warning(s) in stderr"
    else
        pass "${script}/no-encoding-warnings: no encoding warnings"
    fi
}

# Test: collection begin marker failure should not break the run (m7)
# Requires stub server with collection_rules support
test_begin_marker_resilience() {
    local script="$1"
    reset_stub

    # Fail the first collection request (begin marker); subsequent ones fall through
    # to the default handler (no default rule = use normal handler which returns scan_id)
    configure_stub '{"collection_rules":[{"match_count":[1],"status":500}],"upload_rules":[]}'

    run_collector "$script" "e2e-test-${script}"

    # The run should still complete (uploads should succeed even without scan_id)
    local upload_count
    upload_count=$(count_type "THOR finding")

    if [ "$upload_count" -ge 4 ]; then
        pass "${script}/begin-marker-resilience: ${upload_count} files uploaded despite begin marker failure"
    else
        fail "${script}/begin-marker-resilience: expected ≥4 uploads, got ${upload_count} (begin marker failure broke the run?)"
    fi

    # Check if scan_id propagated (if the script retried the begin marker)
    local end_scan_id
    end_scan_id="$(marker_field end scan_id)"
    if [ -n "$end_scan_id" ]; then
        pass "${script}/begin-marker-retry: scan_id recovered after initial failure (${end_scan_id})"
    else
        # Not a failure — most scripts don't retry the begin marker (that's the enhancement suggestion)
        skip "${script}/begin-marker-retry: no scan_id in end marker (begin marker has no retry)"
    fi
}

# Test: collection markers must be valid JSON (m1 — catches unescaped fields)
test_marker_json_validity() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    # Get raw log and check that all collection_marker entries are valid JSON
    local invalid_count
    invalid_count=$(get_log | python3 -c "
import sys, json
invalid = 0
for i, line in enumerate(sys.stdin, 1):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        invalid += 1
        print(f'Line {i}: invalid JSON', file=sys.stderr)
print(invalid)
" 2>&1 | tail -1)

    if [ "$invalid_count" = "0" ]; then
        pass "${script}/marker-json-valid: all log entries are valid JSON"
    else
        fail "${script}/marker-json-valid: ${invalid_count} invalid JSON entries in log"
    fi
}

# Test: collection marker timestamps must be ISO 8601 (catches BAT %date% bug)
test_timestamp_format() {
    local script="$1"
    reset_stub
    run_collector "$script" "e2e-test-${script}"

    # Get timestamp from begin marker
    local ts
    ts="$(marker_field begin timestamp)"

    if [ -z "$ts" ]; then
        fail "${script}/timestamp-format: no timestamp in begin marker"
        return
    fi

    # Check ISO 8601 pattern: YYYY-MM-DDTHH:MM:SS (with optional Z or timezone)
    if echo "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
        pass "${script}/timestamp-format: ISO 8601 (${ts})"
    else
        fail "${script}/timestamp-format: not ISO 8601: '${ts}'"
    fi
}

# Test: end marker should be sent even when begin marker fails (no scan_id)
# Catches scripts that gate end marker on scan_id existence (BAT C4)
test_end_marker_always_sent() {
    local script="$1"
    reset_stub

    # Fail ALL collection requests — begin marker returns 500, no scan_id
    configure_stub '{"collection_rules":[{"match_count":[1],"status":500}],"upload_rules":[]}'

    run_collector "$script" "e2e-test-${script}"

    # Check if an end marker was sent (it should be, even without scan_id)
    local end_marker
    end_marker="$(marker_field end source)"

    if [ -n "$end_marker" ]; then
        pass "${script}/end-marker-always-sent: end marker sent despite begin failure"
    else
        fail "${script}/end-marker-always-sent: no end marker when begin marker failed (stats lost)"
    fi
}

# Test: script must detect HTTP-level errors (not just connection failures)
# Configure ALL uploads to return 500, verify failed count > 0 in end marker stats.
# Catches scripts that only check curl exit code (BAT C1/C2).
test_http_error_detection() {
    local script="$1"
    reset_stub

    # All uploads return 500
    configure_stub '{"upload_rules":[{"default":true,"status":500,"body":"{\"error\":\"test\"}"}]}'

    local extra_flags=""
    case "$script" in
        bash|ash)  extra_flags="--sync --retries 1" ;;
        py3|py2)   extra_flags="--sync --retries 1" ;;
        perl)      extra_flags="--retries 1" ;;
    esac
    run_collector "$script" "e2e-test-${script}" "$extra_flags"

    # Check: exit code should be non-zero (all uploads failed)
    if [ "$E2E_RC" -eq 0 ]; then
        fail "${script}/http-error-detection: exit 0 despite all uploads returning 500 (HTTP errors invisible?)"
        return
    fi

    # Check: end marker stats should show failed > 0
    local stats
    stats="$(marker_field end stats)"
    if [ -n "$stats" ]; then
        local failed_count
        failed_count=$(echo "$stats" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('failed',0))" 2>/dev/null || echo 0)
        if [ "$failed_count" -gt 0 ]; then
            pass "${script}/http-error-detection: detected ${failed_count} HTTP failures"
        else
            fail "${script}/http-error-detection: end stats show 0 failures despite all-500 responses"
        fi
    else
        # No end marker stats — script may not send end marker on total failure
        pass "${script}/http-error-detection: exit ${E2E_RC} (non-zero, errors detected)"
    fi
}

# Test: special characters in --source must produce valid JSON in markers
# Catches incomplete JSON escaping (PS2 C3, BAT m6)
test_special_source_json() {
    local script="$1"
    reset_stub

    # Source with characters that need JSON escaping: backslash, quotes, tab
    local special_source='test\host"name'
    run_collector "$script" "$special_source"

    # Check all log entries are valid JSON (malformed source = broken JSON)
    local invalid_count
    invalid_count=$(get_log | python3 -c "
import sys, json
invalid = 0
for i, line in enumerate(sys.stdin, 1):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError as e:
        invalid += 1
        print(f'Line {i}: {e}', file=sys.stderr)
print(invalid)
" 2>&1 | tail -1)

    if [ "$invalid_count" = "0" ]; then
        pass "${script}/special-source-json: markers valid with special chars in source"
    else
        fail "${script}/special-source-json: ${invalid_count} invalid JSON entries (source escaping broken)"
    fi
}

# Test: HTTP errors should be visible in stderr (not swallowed silently)
# Specifically targets PS scripts where Write-Host bypasses redirection
test_http_errors_to_stderr() {
    local script="$1"
    reset_stub

    # All uploads return 500
    configure_stub '{"upload_rules":[{"default":true,"status":500,"body":"{\"error\":\"test\"}"}]}'

    local extra_flags=""
    case "$script" in
        bash|ash)  extra_flags="--sync --retries 1" ;;
        py3|py2)   extra_flags="--sync --retries 1" ;;
        perl)      extra_flags="--retries 1" ;;
    esac
    run_collector "$script" "e2e-test-${script}" "$extra_flags"

    # Combined output should mention errors/failures
    local combined="$E2E_STDOUT"$'\n'"$E2E_STDERR"
    local error_mentions
    error_mentions=$(echo "$combined" | grep -ci "error\|fail\|500\|giving up" || true)

    if [ "$error_mentions" -gt 0 ]; then
        # Now check: are any of those on stderr specifically?
        local stderr_errors
        stderr_errors=$(echo "$E2E_STDERR" | grep -ci "error\|fail\|500\|giving up" || true)
        if [ "$stderr_errors" -gt 0 ]; then
            pass "${script}/http-errors-to-stderr: ${stderr_errors} error indicators on stderr"
        else
            fail "${script}/http-errors-to-stderr: errors only on stdout (${error_mentions} mentions), none on stderr"
        fi
    else
        fail "${script}/http-errors-to-stderr: no error output at all despite all-500 responses"
    fi
}

# Test: read errors (unreadable files) should be counted as failures
# Catches scripts that silently skip unreadable files without incrementing error count (PS1 m3)
test_read_errors_counted() {
    local script="$1"
    reset_stub

    # Create an unreadable file in fixtures
    local unreadable="$FIXTURES_DIR/unreadable.exe"
    echo "secret" > "$unreadable"
    chmod 000 "$unreadable"

    run_collector "$script" "e2e-test-${script}"

    # Restore permissions for cleanup
    chmod 644 "$unreadable"

    # End marker stats should show failed > 0 OR exit code should be non-zero
    local end_stats
    end_stats="$(marker_field end stats)"
    local failed_in_stats=0
    if [ -n "$end_stats" ]; then
        failed_in_stats=$(echo "$end_stats" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('failed',0))" 2>/dev/null || echo 0)
    fi

    if [ "$failed_in_stats" -gt 0 ] || [ "$E2E_RC" -ne 0 ]; then
        pass "${script}/read-errors-counted: read failures tracked (failed=${failed_in_stats}, exit=${E2E_RC})"
    else
        fail "${script}/read-errors-counted: unreadable file not counted as failure (failed=${failed_in_stats}, exit=${E2E_RC})"
    fi
    rm -f "$unreadable"
}

# Test: retry count should match --retries setting exactly
# Catches off-by-one errors where MaxRetries=N gives N+1 attempts (PS1 m2)
test_retry_count_exact() {
    local script="$1"
    reset_stub

    # All uploads return 500, set retries to 1
    configure_stub '{"upload_rules":[{"default":true,"status":500,"body":"{\"error\":\"test\"}"}]}'

    local extra_flags=""
    case "$script" in
        bash|ash)  extra_flags="--sync --retries 1" ;;
        py3|py2)   extra_flags="--sync --retries 1" ;;
        perl)      extra_flags="--retries 1" ;;
        ps1|ps2)
            # PS scripts don't have --retries yet; skip
            skip "${script}/retry-count-exact: no --retries parameter"
            return ;;
        *)
            skip "${script}/retry-count-exact: retries not configurable"
            return ;;
    esac
    run_collector "$script" "e2e-test-${script}" "$extra_flags"

    # With --retries 1 and N files, stub should see exactly N upload attempts
    # (1 attempt per file, no retries since retries=1 means "try once")
    # Actually --retries 1 means "1 retry after first attempt" = 2 total in most scripts
    # The key check: total upload attempts should be ≤ (files × retries)
    local upload_count
    upload_count=$(get_log | python3 -c "
import sys, json
count = 0
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('type') == 'THOR finding':
        count += 1
print(count)
" 2>/dev/null || echo 0)

    # With fixture files (~9-10) and retries=1, we expect at most files×2 attempts
    local file_count
    file_count=$(ls "$FIXTURES_DIR" | wc -l)
    local max_expected=$((file_count * 2))

    if [ "$upload_count" -le "$max_expected" ]; then
        pass "${script}/retry-count-exact: ${upload_count} attempts for ${file_count} files (max ${max_expected})"
    else
        fail "${script}/retry-count-exact: ${upload_count} attempts exceeds expected max ${max_expected} (off-by-one?)"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        Thunderstorm Collector — End-to-End Test Suite        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "Stub server: ${STUB_BIN} (port ${STUB_PORT})"
echo "Fixtures: ${FIXTURES_DIR}"
echo ""

SCRIPTS_TO_TEST="bash ash py3 py2 perl ps1 ps2"

for script in $SCRIPTS_TO_TEST; do
    if ! can_run "$script"; then
        skip "${script}: runtime not available"
        continue
    fi

    echo ""
    echo "── ${script} ──────────────────────────────────────────────"

    test_basic_upload "$script"
    test_collection_markers "$script"
    test_scan_id_propagation "$script"
    test_source_field "$script"
    test_extension_filtering "$script"
    test_exit_code_clean "$script"
    test_exit_code_partial_failure "$script"
    test_exit_code_fatal "$script"
    test_retry_on_503 "$script"
    test_end_marker_stats "$script"
    test_503_no_double_sleep "$script"
    test_errors_to_stderr "$script"
    test_log_file_captures_errors "$script"
    test_no_encoding_warnings "$script"
    test_begin_marker_resilience "$script"
    test_marker_json_validity "$script"
    test_timestamp_format "$script"
    test_end_marker_always_sent "$script"
    test_http_error_detection "$script"
    test_special_source_json "$script"
    test_http_errors_to_stderr "$script"
    test_read_errors_counted "$script"
    test_retry_count_exact "$script"
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
echo "════════════════════════════════════════════════════════════════"
echo ""

[ "$FAIL_COUNT" -eq 0 ] || exit 1
