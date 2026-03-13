#!/usr/bin/env bash
#
# End-to-End Compliance Tests for Thunderstorm Collector Scripts
#
# Verifies that each collector sends correctly formatted multipart uploads
# with proper metadata fields that a Thunderstorm server can parse.
#
# Tests run against a stub server with JSONL audit log for field verification.
# Checks: source, filename, file integrity (MD5), collection markers,
#         zero-byte files, binary files, filenames with spaces/special chars.
#
# Usage:
#   ./run_e2e_compliance.sh [stub-server-binary]
#
# Environment:
#   STUB_SERVER_BIN      Path to stub server binary
#   THUNDERSTORM_HOST    Real Thunderstorm host (optional, for live smoke tests)
#   THUNDERSTORM_PORT    Real Thunderstorm port (default: 8081)
#

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

STUB_PORT=19993
STUB_LOG="/tmp/e2e-compliance.jsonl"
STUB_PID=""

TS_HOST="${THUNDERSTORM_HOST:-}"
TS_PORT="${THUNDERSTORM_PORT:-8081}"

FIXTURES="/tmp/e2e-compliance-fixtures"
PASS=0
FAIL=0
SKIP=0

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()    { PASS=$((PASS+1)); printf "  ${GREEN}PASS${RESET} %s\n" "$1"; }
fail()    { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${RESET} %s\n" "$1"; }
skip()    { SKIP=$((SKIP+1)); printf "  ${YELLOW}SKIP${RESET} %s\n" "$1"; }
section() { printf "\n${BOLD}${CYAN}── %s ──${RESET}\n" "$1"; }

# ── Stub Server ───────────────────────────────────────────────────────────────

find_stub() {
    if [ -n "${1:-}" ] && [ -x "$1" ]; then echo "$1"; return 0; fi
    if [ -n "${STUB_SERVER_BIN:-}" ] && [ -x "$STUB_SERVER_BIN" ]; then echo "$STUB_SERVER_BIN"; return 0; fi
    local sibling="$SCRIPTS_DIR/../../thunderstorm-stub-server/thunderstorm-stub-server"
    if [ -x "$sibling" ]; then echo "$sibling"; return 0; fi
    for p in \
        "$HOME/.openclaw/workspace/projects/thunderstorm-stub-server/thunderstorm-stub-server" \
        "$HOME/thunderstorm-stub-server/thunderstorm-stub-server"; do
        if [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    command -v thunderstorm-stub-server 2>/dev/null && return 0
    return 1
}

start_stub() {
    pkill -f "stub-server.*$STUB_PORT" 2>/dev/null || true
    sleep 1
    rm -f "$STUB_LOG"
    "$1" -port "$STUB_PORT" -log-file "$STUB_LOG" &
    STUB_PID=$!
    sleep 2
    if ! curl -sf "http://127.0.0.1:$STUB_PORT/api/status" >/dev/null 2>&1; then
        echo "ERROR: Stub server failed to start on port $STUB_PORT"; exit 1
    fi
}

stop_stub() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null && wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""; }

cleanup() { stop_stub; rm -rf "$FIXTURES"; }
trap cleanup EXIT

# ── Fixtures ──────────────────────────────────────────────────────────────────

create_fixtures() {
    rm -rf "$FIXTURES"
    mkdir -p "$FIXTURES/subdir with spaces" "$FIXTURES/nested/deep"
    echo "hello world" > "$FIXTURES/normal.txt"
    echo "spaced" > "$FIXTURES/file with spaces.txt"
    echo "special" > "$FIXTURES/special-chars_v2.0(1).txt"
    printf '\x00\x01\x02\x03DEADBEEF\x00\xff\xfe' > "$FIXTURES/binary.bin"
    echo "nested space" > "$FIXTURES/subdir with spaces/inner.txt"
    echo "deep" > "$FIXTURES/nested/deep/deep.txt"
    touch "$FIXTURES/empty.txt"
    echo "report" > "$FIXTURES/report-2024.txt"
}

# ── JSONL Helpers ─────────────────────────────────────────────────────────────

jsonl_count() { wc -l < "$STUB_LOG" 2>/dev/null | tr -d ' '; }

# Get upload entries (type="THOR finding") since line N
jsonl_uploads_since() {
    tail -n +"$1" "$STUB_LOG" 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        if d.get('type') == 'THOR finding': print(line)
    except: pass
"
}

# Get all entries since line N
jsonl_since() { tail -n +"$1" "$STUB_LOG" 2>/dev/null; }

# Extract a dotted field path from a JSON line
jf() {
    echo "$1" | python3 -c "
import sys, json
data = json.load(sys.stdin)
keys = '${2}'.split('.')
val = data
for k in keys:
    val = val.get(k) if isinstance(val, dict) else None
    if val is None: break
if val is not None: print(val)
" 2>/dev/null
}

# Find first upload entry matching a client_filename substring
find_upload() {
    echo "$1" | python3 -c "
import sys, json
target = '${2}'
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    cf = d.get('subject',{}).get('client_filename','')
    if target in cf: print(line); break
" 2>/dev/null
}

# Find marker entry by type
find_marker() {
    echo "$1" | python3 -c "
import sys, json
target = '${2}'
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('type') == 'collection_marker' and d.get('marker') == target: print(line); break
" 2>/dev/null
}

# ── Assertions ────────────────────────────────────────────────────────────────

assert_eq()       { [ "$(jf "$1" "$2")" = "$3" ] && pass "$4" || fail "$4: expected='$3' got='$(jf "$1" "$2")'"; }
assert_nonempty() { [ -n "$(jf "$1" "$2")" ] && pass "$3: $(jf "$1" "$2")" || fail "$3: empty"; }
assert_md5()      { local exp; exp=$(md5sum "$2" | awk '{print $1}'); local got; got=$(jf "$1" "subject.hashes.md5"); [ "$exp" = "$got" ] && pass "$3: MD5 $exp" || fail "$3: MD5 expected=$exp got=$got"; }

# ── Test Runner ───────────────────────────────────────────────────────────────

run_tests() {
    local name="$1"; shift
    local source_val="E2E Test (v2.0)"
    local start_line uploads all_entries entry

    section "$name"

    start_line=$(($(jsonl_count) + 1))
    "$@" --source "$source_val" > /dev/null 2>&1 || true
    sleep 2

    uploads=$(jsonl_uploads_since "$start_line")
    all_entries=$(jsonl_since "$start_line")

    if [ -z "$uploads" ]; then
        fail "$name: no uploads recorded (collector may have crashed)"
        return
    fi

    # Source parameter arrives correctly
    entry=$(echo "$uploads" | head -1)
    assert_eq "$entry" "subject.source" "$source_val" "$name/source"

    # Collection markers
    local begin_m; begin_m=$(find_marker "$all_entries" "begin")
    local end_m; end_m=$(find_marker "$all_entries" "end")
    if [ -n "$begin_m" ]; then
        pass "$name/marker-begin"
        assert_nonempty "$begin_m" "collector" "$name/marker-collector"
        assert_eq "$begin_m" "source" "$source_val" "$name/marker-source"
    else
        fail "$name/marker-begin: not found"
    fi
    [ -n "$end_m" ] && pass "$name/marker-end" || fail "$name/marker-end: not found"

    # File content integrity — text
    entry=$(find_upload "$uploads" "normal.txt")
    if [ -n "$entry" ]; then
        assert_md5 "$entry" "$FIXTURES/normal.txt" "$name/integrity-text"
    else
        fail "$name/integrity-text: not found"
    fi

    # File content integrity — binary with NUL bytes
    entry=$(find_upload "$uploads" "binary.bin")
    if [ -n "$entry" ]; then
        assert_md5 "$entry" "$FIXTURES/binary.bin" "$name/integrity-binary"
    else
        fail "$name/integrity-binary: not found"
    fi

    # Filename with spaces
    entry=$(find_upload "$uploads" "file with spaces")
    if [ -n "$entry" ]; then
        assert_md5 "$entry" "$FIXTURES/file with spaces.txt" "$name/spaces-in-name"
    else
        fail "$name/spaces-in-name: not found"
    fi

    # Special characters in filename
    entry=$(find_upload "$uploads" "special-chars")
    if [ -n "$entry" ]; then
        assert_md5 "$entry" "$FIXTURES/special-chars_v2.0(1).txt" "$name/special-chars"
    else
        fail "$name/special-chars: not found"
    fi

    # Zero-byte file
    entry=$(find_upload "$uploads" "empty.txt")
    if [ -n "$entry" ]; then
        local sz; sz=$(jf "$entry" "subject.size")
        [ "$sz" = "0" ] && pass "$name/zero-byte" || fail "$name/zero-byte: size=$sz"
    else
        fail "$name/zero-byte: not found"
    fi

    # Nested directory
    entry=$(find_upload "$uploads" "deep.txt")
    [ -n "$entry" ] && pass "$name/nested-dir" || fail "$name/nested-dir: not found"

    # Subdirectory with spaces
    entry=$(find_upload "$uploads" "inner.txt")
    [ -n "$entry" ] && pass "$name/subdir-spaces" || fail "$name/subdir-spaces: not found"

    # Total count
    local n; n=$(echo "$uploads" | wc -l | tr -d ' ')
    [ "$n" -ge 8 ] && pass "$name/count: $n files" || fail "$name/count: $n files (expected ≥8)"
}

# PowerShell wrapper (uses -Source instead of --source)
run_tests_ps() {
    local name="$1" script="$2"
    local source_val="E2E Test (v2.0)"
    local start_line uploads entry

    section "$name"

    start_line=$(($(jsonl_count) + 1))
    pwsh -NoProfile -ep bypass -c "& '$script' \
        -ThunderstormServer '127.0.0.1' -ThunderstormPort $STUB_PORT \
        -Folder '$FIXTURES' -MaxAge 365 -AllExtensions \
        -Source '$source_val'" > /dev/null 2>&1 || true
    sleep 2

    uploads=$(jsonl_uploads_since "$start_line")
    if [ -z "$uploads" ]; then
        fail "$name: no uploads recorded (collector may have crashed)"
        return
    fi

    entry=$(echo "$uploads" | head -1)
    assert_eq "$entry" "subject.source" "$source_val" "$name/source"

    entry=$(find_upload "$uploads" "normal.txt")
    [ -n "$entry" ] && assert_md5 "$entry" "$FIXTURES/normal.txt" "$name/integrity-text" || fail "$name/integrity-text"

    entry=$(find_upload "$uploads" "binary.bin")
    [ -n "$entry" ] && assert_md5 "$entry" "$FIXTURES/binary.bin" "$name/integrity-binary" || fail "$name/integrity-binary"

    entry=$(find_upload "$uploads" "file with spaces")
    [ -n "$entry" ] && assert_md5 "$entry" "$FIXTURES/file with spaces.txt" "$name/spaces-in-name" || fail "$name/spaces-in-name"

    entry=$(find_upload "$uploads" "empty.txt")
    if [ -n "$entry" ]; then
        local sz; sz=$(jf "$entry" "subject.size")
        [ "$sz" = "0" ] && pass "$name/zero-byte" || fail "$name/zero-byte: size=$sz"
    else fail "$name/zero-byte"; fi

    local n; n=$(echo "$uploads" | wc -l | tr -d ' ')
    [ "$n" -ge 5 ] && pass "$name/count: $n files" || fail "$name/count: $n files (expected ≥5)"
}

run_dry_run_test() {
    local name="$1"; shift
    local start_line n
    start_line=$(($(jsonl_count) + 1))
    "$@" --dry-run > /dev/null 2>&1 || true
    sleep 1
    n=$(jsonl_uploads_since "$start_line" | wc -l | tr -d ' ')
    [ "$n" -eq 0 ] && pass "$name/dry-run" || fail "$name/dry-run: $n uploads (should be 0)"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo " E2E Compliance Tests"
echo " Stub: 127.0.0.1:$STUB_PORT"
[ -n "$TS_HOST" ] && echo " Thunderstorm: $TS_HOST:$TS_PORT"
echo "============================================"

STUB_BIN=$(find_stub "${1:-}" || true)
if [ -z "$STUB_BIN" ]; then
    echo "ERROR: Cannot find stub server binary"; exit 1
fi
echo "Stub: $STUB_BIN"
start_stub "$STUB_BIN"
create_fixtures

# Bash
run_tests "bash" bash "$SCRIPTS_DIR/thunderstorm-collector.sh" \
    --server 127.0.0.1 --port "$STUB_PORT" --dir "$FIXTURES" --max-age 365 --quiet
run_dry_run_test "bash" bash "$SCRIPTS_DIR/thunderstorm-collector.sh" \
    --server 127.0.0.1 --port "$STUB_PORT" --dir "$FIXTURES" --max-age 365 --quiet

# Ash / POSIX sh
if command -v dash >/dev/null 2>&1; then
    run_tests "ash (dash)" dash "$SCRIPTS_DIR/thunderstorm-collector-ash.sh" \
        --server 127.0.0.1 --port "$STUB_PORT" --dir "$FIXTURES" --max-age 365 --quiet
    run_dry_run_test "ash (dash)" dash "$SCRIPTS_DIR/thunderstorm-collector-ash.sh" \
        --server 127.0.0.1 --port "$STUB_PORT" --dir "$FIXTURES" --max-age 365 --quiet
else
    section "ash"; skip "no dash or busybox available"
fi

# Python 3
if command -v python3 >/dev/null 2>&1; then
    run_tests "python3" python3 "$SCRIPTS_DIR/thunderstorm-collector.py" \
        -s 127.0.0.1 -p "$STUB_PORT" -d "$FIXTURES" --max-age 365
    run_dry_run_test "python3" python3 "$SCRIPTS_DIR/thunderstorm-collector.py" \
        -s 127.0.0.1 -p "$STUB_PORT" -d "$FIXTURES" --max-age 365
else
    section "python3"; skip "not available"
fi

# Python 2
if command -v python2 >/dev/null 2>&1; then
    run_tests "python2" python2 "$SCRIPTS_DIR/thunderstorm-collector-py2.py" \
        -s 127.0.0.1 -p "$STUB_PORT" -d "$FIXTURES" --max-age 365
    run_dry_run_test "python2" python2 "$SCRIPTS_DIR/thunderstorm-collector-py2.py" \
        -s 127.0.0.1 -p "$STUB_PORT" -d "$FIXTURES" --max-age 365
else
    section "python2"; skip "not available"
fi

# Perl
if command -v perl >/dev/null 2>&1 && perl -MLWP::UserAgent -e1 2>/dev/null; then
    run_tests "perl" perl "$SCRIPTS_DIR/thunderstorm-collector.pl" \
        -s 127.0.0.1 --port "$STUB_PORT" --dir "$FIXTURES" --max-age 365
    run_dry_run_test "perl" perl "$SCRIPTS_DIR/thunderstorm-collector.pl" \
        -s 127.0.0.1 --port "$STUB_PORT" --dir "$FIXTURES" --max-age 365
else
    section "perl"; skip "not available or missing LWP::UserAgent"
fi

# PowerShell 3+
if command -v pwsh >/dev/null 2>&1; then
    run_tests_ps "powershell3+" "$SCRIPTS_DIR/thunderstorm-collector.ps1"
else
    section "powershell3+"; skip "pwsh not available"
fi

# PowerShell 2+
if command -v pwsh >/dev/null 2>&1; then
    run_tests_ps "powershell2+" "$SCRIPTS_DIR/thunderstorm-collector-ps2.ps1"
else
    section "powershell2+"; skip "pwsh not available"
fi

# Real Thunderstorm smoke tests
if [ -n "$TS_HOST" ]; then
    section "Real Thunderstorm ($TS_HOST:$TS_PORT)"
    if curl -sf "http://$TS_HOST:$TS_PORT/api/status" >/dev/null 2>&1; then
        pass "connectivity: server reachable"
        TS_FIX="/tmp/e2e-ts-smoke"
        rm -rf "$TS_FIX"; mkdir -p "$TS_FIX"
        echo "live test" > "$TS_FIX/live.txt"
        printf '\x00BINARY\x00' > "$TS_FIX/live.bin"

        for info in \
            "bash:bash $SCRIPTS_DIR/thunderstorm-collector.sh --server $TS_HOST --port $TS_PORT --dir $TS_FIX --max-age 365 --quiet" \
            "python3:python3 $SCRIPTS_DIR/thunderstorm-collector.py -s $TS_HOST -p $TS_PORT -d $TS_FIX --max-age 365" \
            "perl:perl $SCRIPTS_DIR/thunderstorm-collector.pl -s $TS_HOST --port $TS_PORT --dir $TS_FIX --max-age 365" \
            "ps3:pwsh -NoProfile -ep bypass -c \"& '$SCRIPTS_DIR/thunderstorm-collector.ps1' -ThunderstormServer $TS_HOST -ThunderstormPort $TS_PORT -Folder '$TS_FIX' -MaxAge 365 -AllExtensions\""; do
            n="${info%%:*}"; c="${info#*:}"
            if eval "$c" >/dev/null 2>&1; then
                pass "live/$n: upload succeeded"
            else
                fail "live/$n: upload failed"
            fi
        done
        rm -rf "$TS_FIX"
    else
        fail "connectivity: unreachable at $TS_HOST:$TS_PORT"
    fi
fi

echo ""
echo "============================================"
printf " Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d skipped${RESET}\n" "$PASS" "$FAIL" "$SKIP"
echo "============================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
