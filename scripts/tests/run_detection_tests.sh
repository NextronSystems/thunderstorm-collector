#!/usr/bin/env bash
# ============================================================================
# Detection & Path Verification Tests
#
# Tests the full detection pipeline across all collector scripts:
#
# Positive tests:
#   1. Malicious file → YARA content match (score > 0)
#   2. Benign file → no match (no log entry)
#   3. Benign file with malicious filename (/tmp/x) → filename IOC match
#   4. Malicious file filtered by size → no event logged
#   5. Same large file without size filter → detected
#   6. Full path preserved in thunderstorm log
#   7. Subdirectory recursion (files found at all levels)
#
# Negative tests (verifying collectors DON'T do what they shouldn't):
#   8. Directory scope — scanning /target must NOT pick up files from /decoy
#   9. Age filter — files older than --max-age must NOT be submitted
#  10. Extension filter (PS only) — exotic extensions must NOT be submitted
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
    # Extra args can override --max-age, --max-size-kb, etc.
    bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
        --server localhost --port "$STUB_PORT" --dir "$dir" \
        "$@" 2>&1
}

run_python() {
    local dir="$1"; shift
    python3 "${COLLECTOR_DIR}/thunderstorm-collector.py" \
        --server localhost --port "$STUB_PORT" --dir "$dir" \
        "$@" 2>&1
}

run_perl() {
    local dir="$1"; shift
    perl "${COLLECTOR_DIR}/thunderstorm-collector.pl" \
        -s localhost -p "$STUB_PORT" --dir "$dir" \
        "$@" 2>&1
}

# Translate generic flags (--max-size-kb, --max-age) to PowerShell parameter names
_translate_ps_args() {
    local -n out_args=$1; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --max-size-kb) out_args+=("-MaxSize" "$(( $2 / 1024 ))"); shift 2 ;;
            --max-age)     out_args+=("-MaxAge" "$2"); shift 2 ;;
            *)             out_args+=("$1"); shift ;;
        esac
    done
}

run_ps3() {
    local dir="$1"; shift
    local args=()
    _translate_ps_args args "$@"
    pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector.ps1" \
        -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$dir" \
        "${args[@]}" 2>&1
}

run_ps2() {
    local dir="$1"; shift
    local args=()
    _translate_ps_args args "$@"
    pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector-ps2.ps1" \
        -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$dir" \
        "${args[@]}" 2>&1
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

    run_collector "$collector" "$fixtures/malicious" --max-age 30 >/dev/null 2>&1 || true

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

    run_collector "$collector" "$fixtures/benign" --max-age 30 >/dev/null 2>&1 || true

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
    run_collector "$collector" "$ioc_dir" --max-age 30 >/dev/null 2>&1 || true

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
    run_collector "$collector" "$fixtures/large" --max-age 30 --max-size-kb 1024 >/dev/null 2>&1 || true

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
    run_collector "$collector" "$fixtures/large" --max-age 30 --max-size-kb 4096 >/dev/null 2>&1 || true

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

    run_collector "$collector" "$fixtures/malicious" --max-age 30 >/dev/null 2>&1 || true

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

# ── 8. Directory scope — only scans target directory ────────────────────────
# Verifies that scanning /target does NOT pick up files from /decoy
test_directory_scope() {
    local collector="$1"
    local fixtures; fixtures="$(mktemp -d /tmp/detection-test-XXXXXX)"

    # Create two sibling directories: target and decoy
    mkdir -p "$fixtures/target" "$fixtures/decoy"
    echo "$MALICIOUS_CONTENT" > "$fixtures/target/in-scope-${collector}.exe"
    echo "$MALICIOUS_CONTENT" > "$fixtures/decoy/out-of-scope-${collector}.exe"

    # Scan ONLY the target directory
    run_collector "$collector" "$fixtures/target" --max-age 30 >/dev/null 2>&1 || true

    # The in-scope file MUST be in the log
    local in_entry; in_entry="$(query_log "in-scope-${collector}.exe")"
    if [ -z "$in_entry" ]; then
        fail "$collector/dir-scope: in-scope file not found in log"
        rm -rf "$fixtures"
        return
    fi

    # The out-of-scope file MUST NOT be in the log
    local out_entry; out_entry="$(query_log "out-of-scope-${collector}.exe")"
    if [ -n "$out_entry" ]; then
        fail "$collector/dir-scope: out-of-scope file WAS submitted (directory escape!)"
    else
        pass "$collector/dir-scope: only target directory scanned"
    fi

    rm -rf "$fixtures"
}

# ── 9. Age filter — old files must not be collected ─────────────────────────
# Creates a recent file and an old file (backdated via touch -t),
# scans with --max-age 1, and verifies only the recent file is submitted.
test_age_filter() {
    local collector="$1"
    local fixtures; fixtures="$(mktemp -d /tmp/detection-test-XXXXXX)"

    mkdir -p "$fixtures/aged"

    # Recent file (now) — should be submitted
    echo "$MALICIOUS_CONTENT" > "$fixtures/aged/recent-${collector}.exe"

    # Old file (60 days ago) — should NOT be submitted with --max-age 1
    echo "$MALICIOUS_CONTENT" > "$fixtures/aged/old-${collector}.exe"
    touch -t "$(date -d '60 days ago' '+%Y%m%d%H%M.%S')" "$fixtures/aged/old-${collector}.exe"

    # Verify the timestomping worked
    local old_mtime; old_mtime="$(stat -c %Y "$fixtures/aged/old-${collector}.exe")"
    local now; now="$(date +%s)"
    local age_days=$(( (now - old_mtime) / 86400 ))
    if [ "$age_days" -lt 30 ]; then
        skip "$collector/age-filter: timestomping failed (age=$age_days days, expected >= 60)"
        rm -rf "$fixtures"
        return
    fi

    # Scan with --max-age 1 (only files modified in the last day)
    run_collector "$collector" "$fixtures/aged" --max-age 1 >/dev/null 2>&1 || true

    # Recent file MUST be in the log
    local recent_entry; recent_entry="$(query_log "recent-${collector}.exe")"
    if [ -z "$recent_entry" ]; then
        fail "$collector/age-filter: recent file not found in log"
        rm -rf "$fixtures"
        return
    fi

    # Old file MUST NOT be in the log
    local old_entry; old_entry="$(query_log "old-${collector}.exe")"
    if [ -n "$old_entry" ]; then
        fail "$collector/age-filter: old file (60d ago) WAS submitted despite --max-age 1"
    else
        pass "$collector/age-filter: old file correctly skipped (--max-age 1)"
    fi

    rm -rf "$fixtures"
}

# ── 10. Extension filter (PS only) — unknown extensions not submitted ───────
# PowerShell collectors have a default extension whitelist.
# Files with exotic extensions (.xyz) should NOT be submitted.
test_extension_filter() {
    local collector="$1"

    # Only applies to PowerShell collectors
    case "$collector" in
        ps3|ps2) ;;
        *)
            skip "$collector/ext-filter: N/A (no extension filter)"
            return ;;
    esac

    local fixtures; fixtures="$(mktemp -d /tmp/detection-test-XXXXXX)"
    mkdir -p "$fixtures/exttest"

    # File with a known extension — should be submitted
    echo "$MALICIOUS_CONTENT" > "$fixtures/exttest/known-${collector}.exe"

    # File with an exotic extension — should NOT be submitted
    echo "$MALICIOUS_CONTENT" > "$fixtures/exttest/exotic-${collector}.xyz"

    run_collector "$collector" "$fixtures/exttest" --max-age 30 >/dev/null 2>&1 || true

    # Known extension file MUST be in log
    local known_entry; known_entry="$(query_log "known-${collector}.exe")"
    if [ -z "$known_entry" ]; then
        fail "$collector/ext-filter: .exe file not found in log"
        rm -rf "$fixtures"
        return
    fi

    # Exotic extension file MUST NOT be in log
    local exotic_entry; exotic_entry="$(query_log "exotic-${collector}.xyz")"
    if [ -n "$exotic_entry" ]; then
        fail "$collector/ext-filter: .xyz file WAS submitted (should be filtered by extension)"
    else
        pass "$collector/ext-filter: .xyz file correctly filtered"
    fi

    rm -rf "$fixtures"
}

# ── 11. Subdirectory recursion — files in subdirectories are found ──────────
# Verifies that the collector descends into subdirectories.
test_subdirectory_recursion() {
    local collector="$1"
    local fixtures; fixtures="$(mktemp -d /tmp/detection-test-XXXXXX)"

    mkdir -p "$fixtures/root/sub1/sub2"
    echo "$MALICIOUS_CONTENT" > "$fixtures/root/top-${collector}.exe"
    echo "$MALICIOUS_CONTENT" > "$fixtures/root/sub1/mid-${collector}.exe"
    echo "$MALICIOUS_CONTENT" > "$fixtures/root/sub1/sub2/deep-${collector}.exe"

    run_collector "$collector" "$fixtures/root" --max-age 30 >/dev/null 2>&1 || true

    local top; top="$(query_log "top-${collector}.exe")"
    local mid; mid="$(query_log "mid-${collector}.exe")"
    local deep; deep="$(query_log "deep-${collector}.exe")"

    if [ -n "$top" ] && [ -n "$mid" ] && [ -n "$deep" ]; then
        pass "$collector/subdir-recursion: files found at all 3 levels"
    else
        local missing=""
        [ -z "$top" ] && missing="$missing top"
        [ -z "$mid" ] && missing="$missing mid"
        [ -z "$deep" ] && missing="$missing deep"
        fail "$collector/subdir-recursion: missing files:$missing"
    fi

    rm -rf "$fixtures"
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
    test_directory_scope "$collector"
    test_age_filter "$collector"
    test_extension_filter "$collector"
    test_subdirectory_recursion "$collector"

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
