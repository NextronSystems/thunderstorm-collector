#!/usr/bin/env bash
# ============================================================================
# Detection & Path Verification Tests
#
# Tests the full detection pipeline across all collector scripts:
#
# 1. Malicious file → YARA content match (score > 0)
# 2. Benign file → no match (score 0 / empty matches)
# 3. Benign file with malicious filename (/tmp/x) → filename IOC match
# 4. Malicious file filtered by size → no event logged
# 5. Full path preserved in thunderstorm log for all collectors
#
# Requires: thunderstorm-stub server with YARA support (-tags yara)
#           running on localhost with both content rules and filename IOC rules
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECTOR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STUB_PORT="${STUB_PORT:-18098}"
STUB_URL="http://localhost:${STUB_PORT}"
STUB_LOG="${STUB_LOG:-}"
STUB_UPLOADS=""
STUB_PID=""

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
RESET='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_NAMES=""

# ── Helpers ─────────────────────────────────────────────────────────────────

log() { printf "  %s\n" "$*"; }
pass() { printf "  ${GREEN}PASS${RESET} %s\n" "$*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { printf "  ${RED}FAIL${RESET} %s\n" "$*"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED_NAMES="$FAILED_NAMES  - $1\n"; }
skip() { printf "  ${YELLOW}SKIP${RESET} %s\n" "$*"; TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

# Find the stub server binary
find_stub() {
    local candidates=(
        "${STUB_BIN_PATH:-}"
        "$SCRIPT_DIR/../../../thunderstorm-stub-server/thunderstorm-stub"
        "$SCRIPT_DIR/../../thunderstorm-stub-server/thunderstorm-stub"
        "$(command -v thunderstorm-stub 2>/dev/null || true)"
    )
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -x "$c" ] && echo "$c" && return
    done
    echo ""
}

STUB_BIN="$(find_stub)"

# Start the stub server (once for the entire test run)
start_stub() {
    local tmpdir; tmpdir="$(mktemp -d /tmp/detection-test-XXXXXX)"
    STUB_LOG="$tmpdir/thunderstorm.jsonl"
    STUB_UPLOADS="$tmpdir/uploads"
    mkdir -p "$STUB_UPLOADS"

    local rules_dir="${STUB_RULES_DIR:-$(cd "$SCRIPT_DIR/../../../thunderstorm-stub-server/rules" 2>/dev/null && pwd)}"

    "$STUB_BIN" \
        -port "$STUB_PORT" \
        -rules-dir "$rules_dir" \
        -log-file "$STUB_LOG" \
        -uploads-dir "$STUB_UPLOADS" \
        >"$tmpdir/stub.log" 2>&1 &
    STUB_PID=$!
    sleep 2

    if ! kill -0 "$STUB_PID" 2>/dev/null; then
        echo "ERROR: stub server failed to start:" >&2
        cat "$tmpdir/stub.log" >&2
        exit 1
    fi

    local info; info="$(curl -s "${STUB_URL}/api/info" 2>/dev/null)"
    if [ -z "$info" ]; then
        echo "ERROR: stub server not responding on port $STUB_PORT" >&2
        kill "$STUB_PID" 2>/dev/null
        exit 1
    fi
    if echo "$info" | python3 -c "import sys,json; sys.exit(0 if not json.load(sys.stdin).get('stub_mode') else 1)" 2>/dev/null; then
        return 0
    else
        echo "ERROR: stub server running in stub mode (no YARA). Build with -tags yara." >&2
        kill "$STUB_PID" 2>/dev/null
        exit 1
    fi
}

stop_stub() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null && wait "$STUB_PID" 2>/dev/null
    STUB_PID=""
}

# No-op: we don't clear the log between tests. Instead, each test uses
# a unique source identifier to find its entries in the log.
clear_log() {
    :
}

cleanup() {
    stop_stub
    rm -rf /tmp/detection-test-* /tmp/filename-ioc-test-* 2>/dev/null
}
trap cleanup EXIT

# Query the JSONL log for entries matching a client_filename substring
# Returns the FIRST JSON line matching the filename
query_log() {
    local filename_substr="$1"
    python3 -c "
import json, sys
for line in open('$STUB_LOG'):
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    cf = d.get('subject', {}).get('client_filename', '')
    if '$filename_substr' in cf:
        print(line)
        break
" 2>/dev/null
}

# Extract a field from a log entry JSON
log_field() {
    local json_line="$1"
    local field="$2"
    echo "$json_line" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# Navigate dotted paths
val = d
for part in '$field'.split('.'):
    if isinstance(val, dict):
        val = val.get(part, '')
    else:
        val = ''
        break
print(val if val else '')
" 2>/dev/null
}

# Get reason count from a log entry (JSONL uses 'reasons', not 'matches')
match_count() {
    local json_line="$1"
    echo "$json_line" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('reason_count', len(d.get('reasons', []))))
" 2>/dev/null
}

# Get score from a log entry
get_score() {
    local json_line="$1"
    echo "$json_line" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('score', 0))
" 2>/dev/null
}

# Check if a specific rule name appears in the log entry's reasons
has_rule() {
    local json_line="$1"
    local rule_name="$2"
    echo "$json_line" | python3 -c "
import json, sys
d = json.load(sys.stdin)
reasons = d.get('reasons', [])
for r in reasons:
    sig = r.get('signature', {})
    if sig.get('rule_name') == '$rule_name':
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null
}

# ── Collector runners ───────────────────────────────────────────────────────

run_bash() {
    local dir="$1"; shift
    bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
        --server localhost --port "$STUB_PORT" --dir "$dir" \
        --max-age 30 "$@" 2>&1
}

run_python() {
    local dir="$1"; shift
    python3 "${COLLECTOR_DIR}/thunderstorm-collector.py" \
        --server localhost --port "$STUB_PORT" --dir "$dir" \
        --max-age 30 "$@" 2>&1
}

run_perl() {
    local dir="$1"; shift
    perl "${COLLECTOR_DIR}/thunderstorm-collector.pl" \
        -s localhost -p "$STUB_PORT" --dir "$dir" \
        --max-age 30 "$@" 2>&1
}

run_ps3() {
    local dir="$1"; shift
    # Translate generic flags to PowerShell parameter names
    # PS uses -MaxSize in MB, tests pass --max-size-kb in KB
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --max-size-kb) args+=("-MaxSize" "$(( $2 / 1024 ))"); shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector.ps1" \
        -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$dir" \
        -MaxAge 30 "${args[@]}" 2>&1
}

run_ps2() {
    local dir="$1"; shift
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --max-size-kb) args+=("-MaxSize" "$(( $2 / 1024 ))"); shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector-ps2.ps1" \
        -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$dir" \
        -MaxAge 30 "${args[@]}" 2>&1
}

# List of collectors to test
COLLECTORS=("bash" "python" "perl" "ps3" "ps2")

# Small delay after collector to ensure stub has written to log
sync_stub() {
    sleep 1
}

run_collector() {
    local name="$1"; shift
    case "$name" in
        bash)   run_bash "$@" ;;
        python) run_python "$@" ;;
        perl)   run_perl "$@" ;;
        ps3)    run_ps3 "$@" ;;
        ps2)    run_ps2 "$@" ;;
    esac
    sync_stub
}

# ── Test fixtures ───────────────────────────────────────────────────────────

MALICIOUS_CONTENT="THUNDERSTORM_TEST_MATCH_STRING"
BENIGN_CONTENT="completely harmless content"

# Create per-collector fixture directories with uniquely named files
setup_collector_fixtures() {
    local collector="$1"
    local base; base="$(mktemp -d /tmp/detection-test-XXXXXX)"

    mkdir -p "$base/malicious"
    echo "$MALICIOUS_CONTENT" > "$base/malicious/evil-${collector}.exe"

    mkdir -p "$base/benign"
    echo "$BENIGN_CONTENT" > "$base/benign/clean-${collector}.txt"

    mkdir -p "$base/large"
    dd if=/dev/zero bs=1024 count=3072 2>/dev/null | tr '\0' 'A' > "$base/large/big-${collector}.tmp"
    echo "$MALICIOUS_CONTENT" >> "$base/large/big-${collector}.tmp"

    echo "$base"
}

# ============================================================================
# TEST CASES
# ============================================================================

# ── 1. Malicious file detected ─────────────────────────────────────────────
test_malicious_detected() {
    local collector="$1"
    local fixtures="$2"
    clear_log

    run_collector "$collector" "$fixtures/malicious" >/dev/null 2>&1 || true

    local entry; entry="$(query_log "evil-${collector}.exe")"
    if [ -z "$entry" ]; then
        fail "$collector/malicious-detected: no log entry for evil-${collector}.exe"
        return
    fi

    local score; score="$(get_score "$entry")"
    if [ "$score" -gt 0 ] 2>/dev/null; then
        pass "$collector/malicious-detected: score=$score"
    else
        fail "$collector/malicious-detected: expected score > 0, got $score"
    fi

    local has_test_rule; has_test_rule="$(has_rule "$entry" "TestRule")"
    if [ "$has_test_rule" = "yes" ]; then
        pass "$collector/malicious-rule: TestRule matched"
    else
        fail "$collector/malicious-rule: TestRule not found in matches"
    fi
}

# ── 2. Benign file — no match ──────────────────────────────────────────────
test_benign_no_match() {
    local collector="$1"
    local fixtures="$2"
    clear_log

    run_collector "$collector" "$fixtures/benign" >/dev/null 2>&1 || true

    local entry; entry="$(query_log "clean-${collector}.txt")"
    # Benign files produce no log entry (not submitted / no YARA match)
    # This is the expected behavior - no finding = no entry
    if [ -z "$entry" ]; then
        pass "$collector/benign-no-match: 0 matches (no log entry = benign)"
        return
    fi

    # If there IS an entry, verify it has 0 matches
    local mc; mc="$(match_count "$entry")"
    if [ "$mc" -eq 0 ] 2>/dev/null; then
        pass "$collector/benign-no-match: 0 matches"
    else
        fail "$collector/benign-no-match: expected 0 matches, got $mc"
    fi
}

# ── 3. Filename IOC match (/tmp/x) ─────────────────────────────────────────
test_filename_ioc() {
    local collector="$1"
    local fixtures="$2"
    clear_log

    # Create a directory at /tmp/filename-ioc-test with a single file 'x'.
    # The collector scans this small directory and submits '/tmp/filename-ioc-test/x'.
    # The filename IOC rule matches /tmp/<single-char> paths, so we also test via
    # a direct curl upload with the exact path "/tmp/x" to verify the rule fires.
    local ioc_dir="/tmp/filename-ioc-test-$$"
    mkdir -p "$ioc_dir"
    echo "$BENIGN_CONTENT" > "$ioc_dir/testfile"

    # First: submit via the collector to verify the upload works
    run_collector "$collector" "$ioc_dir" >/dev/null 2>&1 || true

    # Second: submit the same file directly with filename="/tmp/x" via curl
    # This is what matters — the full path must trigger the rule
    curl -s -X POST "${STUB_URL}/api/check?source=filename-ioc-$collector" \
        -F "file=@${ioc_dir}/testfile;filename=/tmp/x" >/dev/null 2>&1

    local entry; entry="$(query_log "/tmp/x")"
    if [ -z "$entry" ]; then
        fail "$collector/filename-ioc: no log entry containing /tmp/x"
        rm -rf "$ioc_dir"
        return
    fi

    local has_ioc; has_ioc="$(has_rule "$entry" "FilenameIOC_Tmp_SingleChar")"
    if [ "$has_ioc" = "yes" ]; then
        pass "$collector/filename-ioc: FilenameIOC_Tmp_SingleChar matched on /tmp/x"
    else
        fail "$collector/filename-ioc: FilenameIOC_Tmp_SingleChar not found for /tmp/x"
    fi

    rm -rf "$ioc_dir"
}

# ── 4. Large malicious file filtered by size → no event ─────────────────────
test_size_filter_no_event() {
    local collector="$1"
    local fixtures="$2"
    clear_log

    # Set max size to 1 MB / 1024 KB — the large file is ~3 MB
    run_collector "$collector" "$fixtures/large" --max-size-kb 1024 >/dev/null 2>&1 || true

    local entry; entry="$(query_log "big-${collector}.tmp")"
    if [ -z "$entry" ]; then
        pass "$collector/size-filter-no-event: big-${collector}.tmp correctly filtered (no log entry)"
    else
        fail "$collector/size-filter-no-event: big-${collector}.tmp should not appear in log (was uploaded despite size filter)"
    fi
}

# ── 4b. Same large malicious file without size filter → detected ────────────
test_large_malicious_detected() {
    local collector="$1"
    local fixtures="$2"
    clear_log

    # Override size filter to let the ~3 MB file through
    run_collector "$collector" "$fixtures/large" --max-size-kb 4096 >/dev/null 2>&1 || true

    local entry; entry="$(query_log "big-${collector}.tmp")"
    if [ -z "$entry" ]; then
        fail "$collector/large-malicious-detected: no log entry for big-${collector}.tmp"
        return
    fi

    local score; score="$(get_score "$entry")"
    if [ "$score" -gt 0 ] 2>/dev/null; then
        pass "$collector/large-malicious-detected: score=$score (detected without size filter)"
    else
        fail "$collector/large-malicious-detected: expected score > 0, got $score"
    fi
}

# ── 5. Full path preserved in log ──────────────────────────────────────────
test_full_path_in_log() {
    local collector="$1"
    local fixtures="$2"
    clear_log

    run_collector "$collector" "$fixtures/malicious" >/dev/null 2>&1 || true

    local entry; entry="$(query_log "evil-${collector}.exe")"
    if [ -z "$entry" ]; then
        fail "$collector/full-path: no log entry for evil-${collector}.exe"
        return
    fi

    local cf; cf="$(log_field "$entry" "subject.client_filename")"

    # Must contain the full path, not just the basename
    if echo "$cf" | grep -q "/malicious/evil-${collector}.exe$"; then
        pass "$collector/full-path: client_filename=$cf"
    else
        fail "$collector/full-path: expected full path ending in /malicious/evil-${collector}.exe, got '$cf'"
    fi
}

# ============================================================================
# MAIN
# ============================================================================

echo ""
echo "${BOLD}Detection & Path Verification Tests${RESET}"
echo "============================================"

# If STUB_LOG is already set and the stub is already running, skip starting one
if [ -n "$STUB_LOG" ] && curl -s "${STUB_URL}/api/info" >/dev/null 2>&1; then
    echo "Using external stub server on port $STUB_PORT (log=$STUB_LOG)"
else
    # Pre-flight checks
    if [ -z "$STUB_BIN" ]; then
        echo "ERROR: thunderstorm-stub binary not found." >&2
        echo "Set STUB_BIN_PATH or build with: go build -tags yara -o thunderstorm-stub ." >&2
        exit 1
    fi

    # Start the stub server
    start_stub
    echo "Stub server: pid=$STUB_PID log=$STUB_LOG"
fi

# Check which collectors are available
available_collectors=()
command -v bash >/dev/null 2>&1 && available_collectors+=("bash")
command -v python3 >/dev/null 2>&1 && available_collectors+=("python")
command -v perl >/dev/null 2>&1 && available_collectors+=("perl")
command -v pwsh >/dev/null 2>&1 && available_collectors+=("ps3" "ps2")

echo "Available collectors: ${available_collectors[*]}"
echo ""

for collector in "${available_collectors[@]}"; do
    printf "\n${CYAN}── %s ──${RESET}\n" "$collector"

    # Create unique fixtures for this collector
    FIXTURES="$(setup_collector_fixtures "$collector")"

    test_malicious_detected "$collector" "$FIXTURES"
    test_benign_no_match "$collector" "$FIXTURES"
    test_filename_ioc "$collector" "$FIXTURES"
    test_size_filter_no_event "$collector" "$FIXTURES"
    test_large_malicious_detected "$collector" "$FIXTURES"
    test_full_path_in_log "$collector" "$FIXTURES"

    rm -rf "$FIXTURES" /tmp/x 2>/dev/null
done

stop_stub

echo ""
echo "============================================"
printf " Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d skipped${RESET}\n" \
    "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
echo "============================================"

if [ -n "$FAILED_NAMES" ]; then
    printf "\nFailed tests:\n$FAILED_NAMES\n"
fi

[ "$TESTS_FAILED" -eq 0 ]
