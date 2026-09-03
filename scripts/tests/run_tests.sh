#!/usr/bin/env bash
#
# Test suite for the bash collector.
#
# Modes:
#   1. Stub server (CI/GitHub Actions):
#      Provide a thunderstorm-stub-server binary. Tests start/stop it automatically.
#      ./scripts/tests/run_tests.sh [path/to/thunderstorm-stub-server]
#
#   2. External server (real Thunderstorm or already-running stub):
#      Set THUNDERSTORM_TEST_SERVER and THUNDERSTORM_TEST_PORT.
#      Skips tests that require stub-side verification (audit log, uploads dir).
#      THUNDERSTORM_TEST_SERVER=10.0.0.5 THUNDERSTORM_TEST_PORT=8081 ./scripts/tests/run_tests.sh
#
# Environment variables:
#   STUB_SERVER_BIN          Path to thunderstorm-stub-server binary
#   THUNDERSTORM_TEST_SERVER External server host (skips stub lifecycle)
#   THUNDERSTORM_TEST_PORT   External server port (default: 8080)
#   TEST_FILTER              Run only tests matching this grep pattern
#
# Stub binary lookup order (when no external server):
#   1. First CLI argument
#   2. $STUB_SERVER_BIN
#   3. ../thunderstorm-stub-server/thunderstorm-stub-server (sibling checkout)
#   4. thunderstorm-stub-server in $PATH

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
COLLECTOR="$REPO_ROOT/scripts/bash/thunderstorm-collector.sh"

# ── Locate stub server ────────────────────────────────────────────────────────

find_stub_server() {
    if [ -n "${1:-}" ] && [ -x "$1" ]; then
        echo "$1"; return 0
    fi
    if [ -n "${STUB_SERVER_BIN:-}" ] && [ -x "$STUB_SERVER_BIN" ]; then
        echo "$STUB_SERVER_BIN"; return 0
    fi
    local sibling="$REPO_ROOT/../thunderstorm-stub-server/thunderstorm-stub-server"
    if [ -x "$sibling" ]; then
        echo "$sibling"; return 0
    fi
    # The in-tree stub (Python, like verify_uploads.py), so the suite is runnable from a bare
    # checkout instead of depending on a binary that lives in another repository.
    local intree="$REPO_ROOT/scripts/tests/thunderstorm-stub-server"
    if [ -x "$intree" ] && command -v python3 >/dev/null 2>&1; then
        echo "$intree"; return 0
    fi
    if command -v thunderstorm-stub-server >/dev/null 2>&1; then
        command -v thunderstorm-stub-server; return 0
    fi
    return 1
}

# ── Mode selection ─────────────────────────────────────────────────────────────

EXTERNAL_SERVER="${THUNDERSTORM_TEST_SERVER:-}"
EXTERNAL_PORT="${THUNDERSTORM_TEST_PORT:-8080}"
USE_EXTERNAL=0
STUB_BIN=""

if [ -n "$EXTERNAL_SERVER" ]; then
    USE_EXTERNAL=1
else
    STUB_BIN="$(find_stub_server "${1:-}")" || {
        echo "ERROR: thunderstorm-stub-server binary not found." >&2
        echo "Build it: cd ../thunderstorm-stub-server && go build -o thunderstorm-stub-server ." >&2
        echo "Or set THUNDERSTORM_TEST_SERVER to use an external server." >&2
        exit 1
    }
fi

# ── Test infrastructure ──────────────────────────────────────────────────────

STUB_PORT=0
STUB_PID=""
TEST_TMP=""
UPLOADS_DIR=""
AUDIT_LOG=""
STUB_LOG=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_NAMES=""

# Colours (disabled if not a terminal)
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BOLD=''; RESET=''
fi

setup_tmp() {
    TEST_TMP="$(mktemp -d)"
    UPLOADS_DIR="$TEST_TMP/uploads"
    AUDIT_LOG="$TEST_TMP/audit.jsonl"
    STUB_LOG="$TEST_TMP/stub.log"
    mkdir -p "$UPLOADS_DIR"
}

cleanup() {
    stop_stub
    if [ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ]; then
        rm -rf "$TEST_TMP"
    fi
}
trap cleanup EXIT INT TERM

# Pick an available port
pick_port() {
    local port
    if command -v python3 >/dev/null 2>&1; then
        port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)"
        if [ -n "$port" ] && [ "$port" -ge 1 ] 2>/dev/null; then
            echo "$port"
            return 0
        fi
    fi
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 10000-60000 -n 1
    else
        echo $(( RANDOM % 50000 + 10000 ))
    fi
}

start_stub() {
    if [ "$USE_EXTERNAL" -eq 1 ]; then
        STUB_PORT="$EXTERNAL_PORT"
        return 0
    fi
    STUB_PORT="$(pick_port)"
    # Clean state for each test
    rm -rf "$UPLOADS_DIR"/* "$AUDIT_LOG" 2>/dev/null || true
    "$STUB_BIN" \
        --port "$STUB_PORT" \
        --uploads-dir "$UPLOADS_DIR" \
        --log-file "$AUDIT_LOG" \
        >"$STUB_LOG" 2>&1 &
    STUB_PID=$!
    # Wait for server readiness
    local i
    for i in $(seq 1 30); do
        if curl -fsS "http://127.0.0.1:$STUB_PORT/api/status" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    echo "ERROR: Stub server did not start on port $STUB_PORT" >&2
    cat "$STUB_LOG" >&2
    return 1
}

stop_stub() {
    if [ "$USE_EXTERNAL" -eq 1 ]; then
        return 0
    fi
    if [ -n "$STUB_PID" ]; then
        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
        STUB_PID=""
    fi
}

restart_stub() {
    stop_stub
    start_stub
}

# Whether stub-side verification (audit log, uploads dir) is available
has_stub_verification() {
    [ "$USE_EXTERNAL" -eq 0 ]
}

# verify_stub_contract -- refuse to run against a stub whose marker log shape audit_has_marker
# does not describe.
#
# The shape is an assumption about a server in ANOTHER repository (Nextron-Labs/thunderstorm-
# stub-server, pinned by STUB_SERVER_REF in .github/workflows/script-collectors.yml), and an
# unchecked cross-repo assumption is exactly how six marker tests came to assert a shape no
# server writes: they passed against an early in-tree stub that logged the request body verbatim
# and could not pass in CI. One probe at startup turns that into a single legible error instead
# of six assertions passing for the wrong reason — and if the Go stub's log shape ever moves, it
# is reported here in one line rather than as a scatter of assertion diffs.
verify_stub_contract() {
    local probe='{"type":"begin","source":"contract-probe","collector":"contract-probe"}'
    if ! curl -fsS -X POST -H 'Content-Type: application/json' -d "$probe" \
        "http://127.0.0.1:$STUB_PORT/api/collection" >/dev/null 2>&1; then
        echo "ERROR: the stub rejected the collection-marker contract probe" >&2
        return 1
    fi
    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    if audit_has_marker begin "$audit"; then
        return 0
    fi
    echo "ERROR: this stub does not record collection markers the way the Go stub does." >&2
    echo "  expected: a line with \"type\":\"collection_marker\" and \"marker\":\"begin\"" >&2
    echo "  got:      ${audit:-<nothing logged>}" >&2
    echo "  Every marker assertion would pass for the wrong reason — refusing to run." >&2
    return 1
}

# The server address used by the collector
server_host() {
    if [ "$USE_EXTERNAL" -eq 1 ]; then
        echo "$EXTERNAL_SERVER"
    else
        echo "127.0.0.1"
    fi
}

# Run collector with standard flags, additional args appended
run_collector() {
    bash "$COLLECTOR" \
        --server "$(server_host)" \
        --port "$STUB_PORT" \
        --no-log-file \
        "$@" 2>&1
}

# Get scanned_samples from stub /api/status
stub_scanned() {
    curl -fsS "http://127.0.0.1:$STUB_PORT/api/status" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['scanned_samples'])" 2>/dev/null || echo 0
}

# Count files in uploads dir
upload_count() {
    find "$UPLOADS_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
}

# Extract stat from collector output: "scanned=4 submitted=3 ..."
parse_collector_stat() {
    local output="$1" key="$2"
    # Anchor on the field separator: the summary line also carries links_seen/
    # links_collected/links_skipped, and an unanchored "skipped=" matches inside
    # "links_skipped=" — with tail -1 that returned the link count for key=skipped.
    printf '%s\n' "$output" | grep -oE "(^|[[:space:]])${key}=[0-9]+" | tail -1 | cut -d= -f2
}

# ── Test result helpers ──────────────────────────────────────────────────────

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        printf "    ${RED}FAIL${RESET}: %s — expected '%s', got '%s'\n" "$label" "$expected" "$actual"
        return 1
    fi
    return 0
}

assert_ge() {
    local label="$1" min="$2" actual="$3"
    if [ "$actual" -lt "$min" ] 2>/dev/null; then
        printf "    ${RED}FAIL${RESET}: %s — expected >= %s, got '%s'\n" "$label" "$min" "$actual"
        return 1
    fi
    return 0
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        printf "    ${RED}FAIL${RESET}: %s — output does not contain '%s'\n" "$label" "$needle"
        return 1
    fi
    return 0
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        printf "    ${RED}FAIL${RESET}: %s — output unexpectedly contains '%s'\n" "$label" "$needle"
        return 1
    fi
    return 0
}

# audit_has_marker -- the ONE definition of how a collection marker appears in the audit log.
#
# Those lines are the SERVER's record, not the collector's request body: a marker POSTed as
# {"type":"interrupted",...} is logged with "type":"collection_marker" and the marker name in a
# separate "marker" field (the stats object rides along under "stats"). Six tests each spelled
# that shape by hand as '"type":"interrupted"' — a shape no server writes — so six tests were
# wrong in six places and had to be corrected in six places. Spelled once here instead, checked
# once against the live server by verify_stub_contract, it cannot be spelled wrong by a new test
# and an upstream change to it is a one-line fix.
#
# Assertions on the request BODY (the curl/wget shims) legitimately use "type" and are unrelated.
#
# Matched per LINE, not across the whole log: an audit log normally holds several markers and
# many THOR findings, and requiring the two fields to appear on the SAME line keeps the answer
# independent of the order the server happens to serialize them in.
#   $1 = marker name, $2 = the whitespace-stripped audit text
audit_has_marker() {
    printf '%s\n' "$2" | grep -F -- "\"marker\":\"$1\"" | grep -qF -- '"type":"collection_marker"'
}

assert_marker_sent() {
    local label="$1" marker="$2" audit="$3"
    if ! audit_has_marker "$marker" "$audit"; then
        printf "    ${RED}FAIL${RESET}: %s — no '%s' collection marker in the audit log\n" "$label" "$marker"
        return 1
    fi
    return 0
}

assert_marker_absent() {
    local label="$1" marker="$2" audit="$3"
    if audit_has_marker "$marker" "$audit"; then
        printf "    ${RED}FAIL${RESET}: %s — unexpected '%s' collection marker in the audit log\n" "$label" "$marker"
        return 1
    fi
    return 0
}

run_test() {
    local name="$1"
    # Filter support
    if [ -n "${TEST_FILTER:-}" ] && ! echo "$name" | grep -q "$TEST_FILTER"; then
        return 0
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "  ${BOLD}%-55s${RESET}" "$name"
    local _rc=0
    "$name" || _rc=$?
    # 77 = skipped (the automake convention). A test whose preconditions are absent must not be
    # reported as PASS: the permission cases below cannot run as a user who cannot drop
    # privileges, and silently counting them green is how a whole class of coverage disappears
    # on the platform that needs it most.
    if [ "$_rc" -eq 77 ]; then
        printf " ${YELLOW}SKIP${RESET}\n"
        TESTS_RUN=$((TESTS_RUN - 1))
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        return 0
    fi
    if [ "$_rc" -eq 0 ]; then
        printf " ${GREEN}PASS${RESET}\n"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf " ${RED}FAIL${RESET}\n"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES  - $name\n"
    fi
}

# ── Test fixtures ────────────────────────────────────────────────────────────

create_sample_dir() {
    local dir="$TEST_TMP/samples/$1"
    mkdir -p "$dir"
    echo "$dir"
}

create_file() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$path")"
    if [ $# -gt 0 ]; then
        printf '%s' "$1" > "$path"
    else
        printf 'sample content %s\n' "$(basename "$path")" > "$path"
    fi
}

create_file_bytes() {
    local path="$1" size="$2"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/urandom of="$path" bs=1 count="$size" 2>/dev/null
}

# NOTE: the tools below are SYMLINKS to the real binaries. Writing a shim with
# `cat > "$fakebin/<tool>"` on one of these names follows the symlink and overwrites the REAL
# binary on this machine — `rm -f` the name first. (Learned the hard way: a shim written to
# "$fakebin/find" truncated /usr/bin/find and had to be reinstalled. curl and wget are not in
# the list below, which is the only reason the older shim tests were safe.)
create_fake_tool_path() {
    local dir="$TEST_TMP/fake-tools-$1"
    mkdir -p "$dir"
    local cmd path
    # Mirror the real environment: the collector needs mkdir for its private work directory
    # and readlink to resolve symlink targets. Omitting them made these fake-PATH tests abort
    # before the scan, so their assertions never exercised what they were written for.
    for cmd in bash awk cat date find grep head hostname id mkdir mktemp od readlink rm sed sleep tail tr uname wc; do
        path="$(command -v "$cmd" 2>/dev/null || true)"
        [ -n "$path" ] && ln -sf "$path" "$dir/$cmd"
    done
    echo "$dir"
}

set_file_age_days() {
    local path="$1" days="$2"
    local ts
    if date --version >/dev/null 2>&1; then
        # GNU date
        ts="$(date -d "$days days ago" +%Y%m%d%H%M.%S)"
    else
        # BSD date
        ts="$(date -v-${days}d +%Y%m%d%H%M.%S)"
    fi
    touch -t "$ts" "$path"
}

# ══════════════════════════════════════════════════════════════════════════════
# TESTS
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. Basic upload (async) ──────────────────────────────────────────────────

test_basic_async_upload() {
    restart_stub
    local d; d="$(create_sample_dir basic_async)"
    create_file "$d/a.txt"
    create_file "$d/b.bin"
    create_file "$d/c.dat"

    local out; out="$(run_collector --dir "$d" --source basic-async --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local failed; failed="$(parse_collector_stat "$out" failed)"

    assert_eq "submitted" "3" "$submitted" || return 1
    assert_eq "failed" "0" "$failed" || return 1
    # Wait briefly for async processing, then check server
    sleep 0.5
    assert_ge "stub scanned" 3 "$(stub_scanned)" || return 1
}

# ── 2. Basic upload (sync) ──────────────────────────────────────────────────

test_basic_sync_upload() {
    has_stub_verification || { echo "    (skipped: sync scan too slow on external server)"; return 77; }
    restart_stub
    local d; d="$(create_sample_dir basic_sync)"
    create_file "$d/sample.bin"

    local out; out="$(run_collector --dir "$d" --sync --source sync-test --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"

    assert_eq "submitted" "1" "$submitted" || return 1
    assert_eq "upload_count" "1" "$(upload_count)" || return 1
}

# ── 3. Dry-run: no uploads ──────────────────────────────────────────────────

test_dry_run_no_uploads() {
    restart_stub
    local d; d="$(create_sample_dir dry_run)"
    create_file "$d/a.txt"
    create_file "$d/b.txt"

    local out; out="$(run_collector --dir "$d" --dry-run --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"

    assert_eq "submitted" "2" "$submitted" || return 1
    if has_stub_verification; then
        assert_eq "upload_count" "0" "$(upload_count)" || return 1
        assert_eq "stub_scanned" "0" "$(stub_scanned)" || return 1
    fi
}

# ── 4. Max file size filter ─────────────────────────────────────────────────

test_max_file_size_filter() {
    restart_stub
    local d; d="$(create_sample_dir size_filter)"
    create_file "$d/small.bin" "small"                    # ~5 bytes
    create_file_bytes "$d/big.bin" 60000                  # ~59 KB

    # Set max size to 50 KB. F19: the limit is applied by find at discovery (like
    # --max-age), so the oversize file is never discovered — not counted as skipped.
    local out; out="$(run_collector --dir "$d" --max-size 50 --max-age 30 --debug)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local skipped; skipped="$(parse_collector_stat "$out" skipped)"

    assert_eq "submitted" "1" "$submitted" || return 1
    assert_eq "skipped (oversize filtered at discovery)" "0" "$skipped" || return 1
}

# ── 5. Max age filter ───────────────────────────────────────────────────────

test_max_age_filter() {
    restart_stub
    local d; d="$(create_sample_dir age_filter)"
    create_file "$d/recent.txt" "new"
    create_file "$d/old.txt" "old"
    set_file_age_days "$d/old.txt" 60

    # The age window is mtime OR ctime by default: set_file_age_days moves mtime with touch,
    # which leaves ctime at "now", so the backdated file is still in the window. That is the
    # point of the default -- a backdated mtime must not hide a file. Narrowing to
    # --age-timestamp mtime reproduces the old mtime-only behaviour.
    local out; out="$(run_collector --dir "$d" --max-age 30)"
    assert_eq "scanned (default any)" "2" "$(parse_collector_stat "$out" scanned)" || return 1

    out="$(run_collector --dir "$d" --max-age 30 --age-timestamp mtime)"
    assert_eq "scanned (mtime only)" "1" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_eq "submitted (mtime only)" "1" "$(parse_collector_stat "$out" submitted)" || return 1
    assert_eq "age_filtered (mtime only)" "1" "$(parse_collector_stat "$out" age_filtered)" || return 1
}

# ── 6. Multiple directories ─────────────────────────────────────────────────

test_multiple_directories() {
    restart_stub
    local d1; d1="$(create_sample_dir multi_a)"
    local d2; d2="$(create_sample_dir multi_b)"
    create_file "$d1/x.txt"
    create_file "$d2/y.txt"
    create_file "$d2/z.txt"

    local out; out="$(run_collector --dir "$d1" --dir "$d2" --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"

    assert_eq "submitted" "3" "$submitted" || return 1
}

# ── 7. Non-existent directory warning ────────────────────────────────────────

test_nonexistent_directory_fails() {
    restart_stub
    local d; d="$(create_sample_dir exists)"
    create_file "$d/a.txt"

    # F2: an explicitly named missing dir is a collection failure — the collector reports an
    # error, still scans the other (good) dir, and exits non-zero (interim: existing return 1).
    local out rc
    out="$(bash "$COLLECTOR" \
        --server "$(server_host)" --port "$STUB_PORT" --no-log-file \
        --dir /nonexistent_path_$RANDOM --dir "$d" --max-age 30 2>&1)"
    rc=$?

    assert_contains "error about missing dir" "does not exist or is not accessible" "$out" || return 1
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    assert_eq "submitted (good dir still scanned)" "1" "$submitted" || return 1
    assert_eq "exit 4 (partial failure) on bad explicit dir" "4" "$rc" || return 1
}

test_cloud_exclusion_by_proof() {
    restart_stub
    local d; d="$(create_sample_dir cloudproof)"
    # (a) PROVEN real cloud: contains markers only the Dropbox client creates -> excluded
    mkdir -p "$d/Dropbox/.dropbox.cache"
    create_file "$d/Dropbox/synced.txt"
    # (b) merely NAMED like cloud (no markers) -> must be collected (F13 headline case)
    mkdir -p "$d/cases/Dropbox"
    create_file "$d/cases/Dropbox/evidence.txt"
    create_file "$d/plain.txt"

    local out rc
    out="$(run_collector --dir "$d" --max-age 30)"; rc=$?
    assert_contains "proven cloud excluded visibly" "Excluding cloud storage folder" "$out" || return 1
    assert_contains "name-only folder scanned with note" "despite cloud-like name" "$out" || return 1
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    assert_eq "submitted (plain.txt + name-only Dropbox file)" "2" "$submitted" || return 1
    assert_eq "clean exit" "0" "$rc" || return 1
}

# ── 8. Source parameter arrives at server ────────────────────────────────────

test_source_parameter_received() {
    has_stub_verification || { echo "    (skipped: needs stub server)"; return 77; }
    restart_stub
    local d; d="$(create_sample_dir source_test)"
    create_file "$d/s.bin"

    run_collector --dir "$d" --source "my-test-source" --sync --max-age 30 >/dev/null
    sleep 0.3

    # Check the JSONL audit log for the source
    assert_contains "source in audit log" "my-test-source" "$(cat "$AUDIT_LOG" 2>/dev/null)" || return 1
}

# ── 9. File content integrity ────────────────────────────────────────────────

test_file_content_integrity() {
    has_stub_verification || { echo "    (skipped: needs stub server)"; return 77; }
    restart_stub
    local d; d="$(create_sample_dir integrity)"
    local content="THUNDERSTORM_INTEGRITY_TEST_$(date +%s)"
    create_file "$d/check.bin" "$content"
    local expected_sha; expected_sha="$(sha256sum "$d/check.bin" | awk '{print $1}')"

    run_collector --dir "$d" --sync --max-age 30 >/dev/null
    sleep 0.3

    # Verify the uploaded file has the same hash
    local uploaded_file
    uploaded_file="$(find "$UPLOADS_DIR" -type f | head -1)"
    [ -n "$uploaded_file" ] || { printf "    ${RED}FAIL${RESET}: no uploaded file found\n"; return 1; }
    local actual_sha; actual_sha="$(sha256sum "$uploaded_file" | awk '{print $1}')"
    assert_eq "sha256" "$expected_sha" "$actual_sha" || return 1
}

# ── 10. Filename with spaces ────────────────────────────────────────────────

test_filename_with_spaces() {
    restart_stub
    local d; d="$(create_sample_dir spaces)"
    create_file "$d/my important file.txt" "spaces test"

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local failed; failed="$(parse_collector_stat "$out" failed)"

    assert_eq "submitted" "1" "$submitted" || return 1
    assert_eq "failed" "0" "$failed" || return 1
}

# ── 11. Filename with special characters ────────────────────────────────────

test_filename_special_chars() {
    restart_stub
    local d; d="$(create_sample_dir special)"
    # Filenames that stress multipart encoding
    create_file "$d/file with (parens).txt" "parens"
    create_file "$d/file'with'quotes.txt" "quotes"
    create_file "$d/file&with&amps.bin" "amps"
    # Semicolons and double-quotes are sanitized by the collector
    create_file "$d/normal.txt" "baseline"

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local failed; failed="$(parse_collector_stat "$out" failed)"

    assert_eq "submitted" "4" "$submitted" || return 1
    assert_eq "failed" "0" "$failed" || return 1
}

# ── 12. Empty directory ─────────────────────────────────────────────────────

test_empty_directory() {
    restart_stub
    local d; d="$(create_sample_dir empty)"

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local scanned; scanned="$(parse_collector_stat "$out" scanned)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"

    assert_eq "scanned" "0" "$scanned" || return 1
    assert_eq "submitted" "0" "$submitted" || return 1
}

# ── 13. Nested directories ──────────────────────────────────────────────────

test_nested_directories() {
    restart_stub
    local d; d="$(create_sample_dir nested)"
    create_file "$d/top.txt"
    create_file "$d/a/mid.txt"
    create_file "$d/a/b/deep.txt"
    create_file "$d/a/b/c/deeper.txt"

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"

    assert_eq "submitted" "4" "$submitted" || return 1
}

# ── 14. Symlinks are not followed ───────────────────────────────────────────

test_symlinks_not_followed() {
    restart_stub
    local d; d="$(create_sample_dir symlinks)"
    local other; other="$(create_sample_dir symlink_target)"
    create_file "$d/real.txt"
    create_file "$other/secret.txt"
    ln -sf "$other" "$d/link_to_other" 2>/dev/null || {
        # Skip on systems that don't support symlinks in temp
        return 0
    }

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"

    # find -type f only returns regular files, not symlink targets
    # But find does follow symlinked directories by default on some systems.
    # The key thing: real.txt should always be submitted.
    assert_ge "submitted at least real.txt" 1 "$submitted" || return 1
}

# ── 15. Validation: invalid port ────────────────────────────────────────────

test_invalid_port_rejected() {
    local out; out="$(bash "$COLLECTOR" \
        --server 127.0.0.1 --port "notaport" --no-log-file \
        --dir /tmp --max-age 30 2>&1)" || true

    assert_contains "port validation" "Port must be numeric" "$out" || return 1
}

# ── 16. Validation: invalid max-age ─────────────────────────────────────────

test_invalid_max_age_rejected() {
    local out; out="$(bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file \
        --dir /tmp --max-age "abc" 2>&1)" || true

    assert_contains "max-age validation" "max-age must be numeric" "$out" || return 1
}

# ── 17. Validation: invalid max-size ─────────────────────────────────────────

test_invalid_max_size_rejected() {
    local out; out="$(bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file \
        --dir /tmp --max-size "xyz" 2>&1)" || true

    assert_contains "max-size validation" "max-size must be numeric" "$out" || return 1
}

# ── 18. Validation: missing server ───────────────────────────────────────────

test_missing_server_rejected() {
    local out; out="$(bash "$COLLECTOR" \
        --server "" --port 8080 --no-log-file \
        --dir /tmp 2>&1)" || true

    # An empty value is reported distinctly from a forgotten one (require_value)
    assert_contains "server validation" "Empty value for --server" "$out" || return 1
}

# ── 19. Unknown option rejected ──────────────────────────────────────────────

test_unknown_option_rejected() {
    local out; out="$(bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file \
        --dir /tmp --bogus-flag 2>&1)" || true

    assert_contains "unknown option" "Unknown option" "$out" || return 1
}

# ── 20. Help flag ────────────────────────────────────────────────────────────

test_help_flag() {
    local out; out="$(bash "$COLLECTOR" --help 2>&1)"

    assert_contains "help shows usage" "Usage:" "$out" || return 1
    assert_contains "help shows options" "--server" "$out" || return 1
    assert_contains "help shows examples" "Examples:" "$out" || return 1
}

# ── 21. Log file is written ─────────────────────────────────────────────────

test_log_file_written() {
    restart_stub
    local d; d="$(create_sample_dir log_file)"
    create_file "$d/a.txt"
    local log_path="$TEST_TMP/collector-test.log"

    bash "$COLLECTOR" \
        --server "$(server_host)" --port "$STUB_PORT" \
        --dir "$d" --max-age 30 --source log-test \
        --log-file "$log_path" --quiet 2>&1 >/dev/null

    [ -f "$log_path" ] || { printf "    ${RED}FAIL${RESET}: log file not created\n"; return 1; }
    assert_contains "log has collector info" "Thunderstorm Collector" "$(cat "$log_path")" || return 1
    assert_contains "log has completion" "Run completed" "$(cat "$log_path")" || return 1
}

# ── 22. Source URL-encoding ──────────────────────────────────────────────────

test_source_url_encoding() {
    has_stub_verification || { echo "    (skipped: needs stub server)"; return 77; }
    restart_stub
    local d; d="$(create_sample_dir urlenc)"
    create_file "$d/a.bin"

    run_collector --dir "$d" --source "host with spaces" --sync --max-age 30 >/dev/null
    sleep 0.3

    # The source should arrive at the server (URL-decoded)
    assert_contains "source in audit" "host with spaces" "$(cat "$AUDIT_LOG" 2>/dev/null)" || return 1
}

# ── 23. Retries on server down ───────────────────────────────────────────────

test_retries_on_connection_failure() {
    stop_stub
    local d; d="$(create_sample_dir retry_fail)"
    create_file "$d/a.txt"
    local fakebin; fakebin="$(create_fake_tool_path retry_fail)"
    cat > "$fakebin/curl" <<'EOF'
#!/bin/sh
hdr=""
outfile=""
endpoint=""
while [ $# -gt 0 ]; do
    case "$1" in
        -D) hdr="$2"; shift 2 ;;
        -o) outfile="$2"; shift 2 ;;
        -F|-H|-d|--max-time|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="$1"; shift ;;
        *) shift ;;
    esac
done

case "$endpoint" in
    */api/collection)
        [ -n "$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "$hdr"
        [ -n "$outfile" ] && : > "$outfile"
        exit 0
        ;;
    *)
        exit 7
        ;;
esac
EOF
    chmod +x "$fakebin/curl"

    local out rc
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress \
        --dir "$d" --max-age 30 --retries 2 2>&1)"
    rc=$?
    set -e

    local failed; failed="$(parse_collector_stat "$out" failed)"
    # Exit-code taxonomy: the run completed but a file could not be collected => 4 (partial
    # failure). 1 is reserved for "could not run at all".
    assert_eq "exit code" "4" "$rc" || return 1
    assert_eq "failed" "1" "$failed" || return 1
    assert_contains "retry message" "attempt" "$out" || return 1
}

# ── 24. Full path as multipart filename ──────────────────────────────────────

test_full_path_sent_as_filename() {
    restart_stub
    local d; d="$(create_sample_dir fullpath)"
    create_file "$d/sample.bin" "path test"

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local failed; failed="$(parse_collector_stat "$out" failed)"

    assert_eq "submitted" "1" "$submitted" || return 1
    assert_eq "failed" "0" "$failed" || return 1
}

# ── 25. Zero-byte file ──────────────────────────────────────────────────────

test_zero_byte_file() {
    restart_stub
    local d; d="$(create_sample_dir zerobyte)"
    : > "$d/empty.bin"

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local failed; failed="$(parse_collector_stat "$out" failed)"

    # Zero-byte file: size 0 KB, should pass size filter (it's under any limit)
    # and be submitted (the server may or may not accept it — that's server-side)
    assert_ge "submitted or failed" 1 "$((submitted + failed))" || return 1
}

# ── 26. Max-age 0 includes all files ────────────────────────────────────────

test_max_age_zero_includes_all() {
    restart_stub
    local d; d="$(create_sample_dir age_zero)"
    create_file "$d/recent.txt" "new"
    create_file "$d/old.txt" "old"
    set_file_age_days "$d/old.txt" 365

    # --max-age 0 means NO age filter -- not find's "-mtime 0" sense of "within the last 24h":
    # build_age_tests leaves AGE_TESTS empty, so no age predicate is emitted at all.
    local out; out="$(run_collector --dir "$d" --max-age 0)"
    assert_eq "scanned (both files)" "2" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_eq "age_filtered" "0" "$(parse_collector_stat "$out" age_filtered)" || return 1
    assert_contains "the policy line says the filter is off" "Age filter: disabled" "$out" || return 1
}

test_max_age_cli_override_applied() {
    restart_stub
    local d; d="$(create_sample_dir age_override)"
    create_file "$d/recent.txt" "new"
    create_file "$d/medium.txt" "medium age"
    set_file_age_days "$d/medium.txt" 20

    # Default MAX_AGE is 14 days: the CLI value must reach build_age_tests, so the 20-day-old
    # file is included under --max-age 30 where the default would exclude it.
    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local scanned; scanned="$(parse_collector_stat "$out" scanned)"

    assert_eq "scanned" "2" "$scanned" || return 1
}

# ── 29. Age-window boundary, leading zeros, and unmeasured counters ──────────
# These pin what documentation alone cannot defend: a boundary flipped to inclusive, or "010"
# read as octal, produced identical results on every other fixture in this file.

test_max_age_boundary_is_exclusive() {
    restart_stub
    local d; d="$(create_sample_dir age_boundary)"
    local now; now="$(date +%s)"
    create_file "$d/inside.txt"
    create_file "$d/exact.txt"
    create_file "$d/outside.txt"
    # mtime only: touch leaves ctime at now, and the default policy is mtime OR ctime.
    touch -d "@$(( now - 2 * 86400 + 60 ))" "$d/inside.txt"
    touch -d "@$(( now - 2 * 86400 ))"      "$d/exact.txt"
    touch -d "@$(( now - 2 * 86400 - 60 ))" "$d/outside.txt"

    local out; out="$(run_collector --dry-run --dir "$d" --max-age 2 --age-timestamp mtime)"
    # strictly younger than Nx24h: only inside.txt survives
    assert_eq "scanned" "1" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_eq "age_filtered" "2" "$(parse_collector_stat "$out" age_filtered)" || return 1
    assert_contains "collected the file just inside the window" "inside.txt" "$out" || return 1
}

test_max_age_leading_zero_is_decimal() {
    restart_stub
    local d; d="$(create_sample_dir age_octal)"
    local now; now="$(date +%s)"
    create_file "$d/d07.txt"; touch -d "@$(( now - 7 * 86400 ))" "$d/d07.txt"
    create_file "$d/d09.txt"; touch -d "@$(( now - 9 * 86400 ))" "$d/d09.txt"
    create_file "$d/d11.txt"; touch -d "@$(( now - 11 * 86400 ))" "$d/d11.txt"

    # Bash reads a leading zero as octal: 010 once meant 8 days and 08 aborted the run.
    local plain; plain="$(run_collector --dry-run --dir "$d" --max-age 10 --age-timestamp mtime)"
    local zeroed; zeroed="$(run_collector --dry-run --dir "$d" --max-age 010 --age-timestamp mtime)"
    assert_eq "010 scans the same as 10" \
        "$(parse_collector_stat "$plain" scanned)" "$(parse_collector_stat "$zeroed" scanned)" || return 1
    local eight; eight="$(run_collector --dry-run --dir "$d" --max-age 08 --age-timestamp mtime)"
    if echo "$eight" | grep -q 'value too great for base'; then
        printf "    ${RED}FAIL${RESET}: --max-age 08 leaked a raw shell arithmetic error\n"
        return 1
    fi
    assert_eq "08 means eight days" "1" "$(parse_collector_stat "$eight" scanned)" || return 1
}

test_no_count_filtered_reports_unmeasured() {
    restart_stub
    local d; d="$(create_sample_dir age_uncounted)"
    local now; now="$(date +%s)"
    create_file "$d/recent.txt"
    create_file "$d/old.txt"; touch -d "@$(( now - 400 * 86400 ))" "$d/old.txt"

    local out; out="$(run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp mtime --no-count-filtered)"
    # The counters read 0 because nothing was measured; saying so is the whole point --
    # a bare age_filtered=0 is indistinguishable from "nothing was excluded".
    assert_eq "age_filtered reads 0" "0" "$(parse_collector_stat "$out" age_filtered)" || return 1
    assert_contains "the run says the counts were not measured" "Not measured this run" "$out" || return 1
    assert_eq "the old file is still excluded" "1" "$(parse_collector_stat "$out" scanned)" || return 1
}

test_future_timestamp_collected_and_counted() {
    restart_stub
    local d; d="$(create_sample_dir age_future)"
    create_file "$d/tomorrow.txt"
    touch -d '2099-01-01' "$d/tomorrow.txt"

    local out; out="$(run_collector --dry-run --dir "$d" --max-age 14)"
    assert_eq "future-dated file is collected, never hidden" "1" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_eq "and counted" "1" "$(parse_collector_stat "$out" future)" || return 1
    assert_contains "and warned about" "ahead of this host's clock" "$out" || return 1
}

# ── 30. Age accounting: ctime arm, attribution, roots, counting mechanism ────
# Dropping the size test from the age walk, AGE_TESTS from the symlink policy, or the ctime
# arm's wiring would previously have passed the whole tracked suite.

test_age_ctime_only_reported() {
    restart_stub
    local d; d="$(create_sample_dir age_ctime_only)"
    create_file "$d/plain.txt"
    create_file "$d/stomped_a.txt"; set_file_age_days "$d/stomped_a.txt" 400
    create_file "$d/stomped_b.txt"; set_file_age_days "$d/stomped_b.txt" 400

    # touch moves mtime and leaves ctime at now, so both backdated files are in the window by
    # ctime alone -- the anti-timestomping default, and the number that makes it auditable.
    local out; out="$(run_collector --dry-run --dir "$d" --max-age 14)"
    assert_eq "scanned" "3" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_eq "age_ctime_only" "2" "$(parse_collector_stat "$out" age_ctime_only)" || return 1
    assert_contains "the ctime contribution is named" "matched at discovery by ctime only" "$out" || return 1

    out="$(run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp mtime)"
    assert_eq "age_ctime_only (mtime arm)" "0" "$(parse_collector_stat "$out" age_ctime_only)" || return 1
    assert_eq "age_filtered (mtime arm)" "2" "$(parse_collector_stat "$out" age_filtered)" || return 1
}

test_age_timestamp_ctime_arm() {
    restart_stub
    local d; d="$(create_sample_dir age_ctime_arm)"
    create_file "$d/a.txt"; set_file_age_days "$d/a.txt" 400

    # The third documented value, passed in the = form so the option-splitting allowlist entry is
    # pinned too. Under the default "any" a broken ctime arm is masked by mtime.
    local out; out="$(run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp=ctime)"
    assert_eq "ctime arm collects the backdated file" "1" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_contains "the policy line names the arm" "Age filter: ctime within 14 day(s)" "$out" || return 1

    out="$(run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp bogus 2>&1)"
    assert_contains "an invalid arm is rejected" "--age-timestamp must be 'mtime', 'ctime' or 'any'" "$out" || return 1
}

test_age_and_size_attribution_disjoint() {
    restart_stub
    local d; d="$(create_sample_dir age_attrib)"
    create_file_bytes "$d/bigold.bin" 4000
    set_file_age_days "$d/bigold.bin" 400
    create_file "$d/ok.txt"

    # A file that is BOTH oversize and too old must be counted once, as size. The age walk is
    # qualified by the size test to guarantee it.
    local out; out="$(run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp mtime --max-size 1)"
    assert_eq "size_filtered" "1" "$(parse_collector_stat "$out" size_filtered)" || return 1
    assert_eq "age_filtered" "0" "$(parse_collector_stat "$out" age_filtered)" || return 1
    assert_eq "scanned" "1" "$(parse_collector_stat "$out" scanned)" || return 1
}

test_age_counters_sum_across_roots() {
    restart_stub
    local d1; d1="$(create_sample_dir age_root_a)"
    local d2; d2="$(create_sample_dir age_root_b)"
    create_file "$d1/old.txt"; set_file_age_days "$d1/old.txt" 400
    create_file "$d2/old.txt"; set_file_age_days "$d2/old.txt" 400

    local out; out="$(run_collector --dry-run --dir "$d1" --dir "$d2" --max-age 14 --age-timestamp mtime)"
    assert_eq "age_filtered summed over both roots" "2" "$(parse_collector_stat "$out" age_filtered)" || return 1
}

test_age_policy_applies_to_symlink_targets() {
    restart_stub
    local d; d="$(create_sample_dir age_links)"
    mkdir -p "$d/real" "$d/scan"
    create_file "$d/real/in.txt"
    create_file "$d/real/out.txt"; set_file_age_days "$d/real/out.txt" 400
    ln -sf "$d/real/in.txt" "$d/scan/in_link"
    ln -sf "$d/real/out.txt" "$d/scan/out_link"

    # link_stat_test embeds AGE_TESTS: a link target outside the window must be refused, or
    # --follow-symlinks becomes a way around the age policy. Nothing tracked covered this.
    local out; out="$(run_collector --dry-run --dir "$d/scan" --follow-symlinks --max-age 14 --age-timestamp mtime)"
    assert_eq "one target collected" "1" "$(parse_collector_stat "$out" links_collected)" || return 1
    assert_eq "one target refused" "1" "$(parse_collector_stat "$out" links_skipped)" || return 1
    assert_contains "the in-window target is the one collected" "in.txt" "$out" || return 1
    if echo "$out" | grep -q "out.txt'"; then
        printf "    ${RED}FAIL${RESET}: an out-of-window symlink target was collected\n"
        return 1
    fi
}

test_age_counting_paths_agree() {
    restart_stub
    local d; d="$(create_sample_dir age_count_paths)"
    create_file "$d/fresh.txt"
    create_file "$d/old.txt"; set_file_age_days "$d/old.txt" 400
    create_file_bytes "$d/big.bin" 40000
    # a newline in a filename: the fast path counts NUL separators precisely so this cannot
    # inflate the count
    create_file "$d/two
lines.txt"

    local fast; fast="$(run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp mtime --max-size 20)"
    # strip wc from PATH so count_matching falls back to its read loop; both must agree exactly
    local nowc; nowc="$TEST_TMP/nowc-bin"; mkdir -p "$nowc"
    local cmd path
    for cmd in bash awk cat curl date find grep head hostname id mkdir mktemp od readlink rm sed sleep tail touch tr uname wget; do
        path="$(type -P "$cmd" 2>/dev/null || true)"
        [ -n "$path" ] && ln -sf "$path" "$nowc/$cmd"
    done
    local slow; slow="$(PATH="$nowc" run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp mtime --max-size 20)"

    local k
    for k in scanned age_filtered size_filtered future; do
        assert_eq "$k identical with and without wc" \
            "$(parse_collector_stat "$fast" "$k")" "$(parse_collector_stat "$slow" "$k")" || return 1
    done
    assert_eq "age_filtered" "1" "$(parse_collector_stat "$fast" age_filtered)" || return 1
    assert_eq "size_filtered" "1" "$(parse_collector_stat "$fast" size_filtered)" || return 1
}

test_age_counting_failure_is_not_called_churn() {
    restart_stub
    local d; d="$(create_sample_dir age_count_fail)"
    create_file "$d/a.txt"
    create_file "$d/b.txt"
    # a find that fails ONLY on the predicate-free reconciliation walk: every count reads 0 and
    # COUNT_MATCHING_PARTIAL is set. That must be reported as an incomplete count, never as
    # "the tree changed" -- blaming the host for our own scratch-list failure.
    local shim; shim="$TEST_TMP/failfind-bin"; mkdir -p "$shim"
    local cmd path
    for cmd in bash awk cat curl date grep head hostname id mkdir mktemp od readlink rm sed sleep tail touch tr uname wc wget; do
        path="$(type -P "$cmd" 2>/dev/null || true)"
        [ -n "$path" ] && ln -sf "$path" "$shim/$cmd"
    done
    {
        printf '#!/usr/bin/env bash\n'
        printf 'case " $* " in *" -type f -print0 "*) exit 1 ;; esac\n'
        printf 'exec %s "$@"\n' "$(type -P find)"
    } > "$shim/find"
    chmod +x "$shim/find"

    local out; out="$(PATH="$shim" run_collector --dry-run --dir "$d" --max-age 14)"
    assert_contains "an incomplete count says so" "lower bound" "$out" || return 1
    if echo "$out" | grep -q 'the tree changed'; then
        printf "    ${RED}FAIL${RESET}: a failed counting walk was reported as host churn\n"
        return 1
    fi
    return 0
}

test_age_static_tree_is_not_a_snapshot() {
    restart_stub
    local d; d="$(create_sample_dir age_static)"
    local i=0
    while [ "$i" -lt 40 ]; do create_file "$d/f$i.txt"; i=$((i + 1)); done
    create_file "$d/old.txt"; set_file_age_days "$d/old.txt" 400

    # The churn detector must not label a clean run. It has an allowance for files whose age
    # crosses the window mid-walk, so a quiet tree has to come out silent.
    local out; out="$(run_collector --dry-run --dir "$d" --max-age 14 --age-timestamp mtime)"
    if echo "$out" | grep -qE 'snapshot|lower bound'; then
        printf "    ${RED}FAIL${RESET}: a static tree was labelled inexact\n"
        return 1
    fi
    assert_eq "age_filtered" "1" "$(parse_collector_stat "$out" age_filtered)" || return 1
}

test_max_age_value_validation() {
    restart_stub
    local d; d="$(create_sample_dir age_values)"
    create_file "$d/a.txt"
    local bad rc out
    # over-range must be caught by the string-length check BEFORE any arithmetic sees it
    for bad in 36501 99999999999999999999 -1 abc "" " "; do
        out="$(run_collector --dry-run --dir "$d" --max-age "$bad" 2>&1)"; rc=$?
        if [ "$rc" -ne 2 ]; then
            printf "    ${RED}FAIL${RESET}: --max-age '%s' exited %s, expected 2\n" "$bad" "$rc"
            return 1
        fi
        if echo "$out" | grep -qE 'integer expression|value too great for base|operand expected'; then
            printf "    ${RED}FAIL${RESET}: --max-age '%s' leaked a raw shell diagnostic\n" "$bad"
            return 1
        fi
    done
    # a missing value must not silently eat the next flag
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" --no-log-file --dir "$d" --max-age 2>&1)"; rc=$?
    assert_eq "missing value rejected" "2" "$rc" || return 1
    # and a usage error must never exit without reaching a sink, even with every sink disabled
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" --no-log-file --quiet --dir "$d" --max-age abc 2>&1)"; rc=$?
    assert_eq "silenced usage error still exits 2" "2" "$rc" || return 1
    if [ -z "$out" ]; then
        printf "    ${RED}FAIL${RESET}: --quiet --no-log-file --max-age abc exited 2 with no output at all\n"
        return 1
    fi
    return 0
}

# ── 28. Positional directory args ────────────────────────────────────────────

test_positional_directory_args() {
    restart_stub
    local d1; d1="$(create_sample_dir pos_a)"
    local d2; d2="$(create_sample_dir pos_b)"
    create_file "$d1/x.txt"
    create_file "$d2/y.txt"

    # Pass directories as positional args (not --dir)
    local out; out="$(bash "$COLLECTOR" \
        --server "$(server_host)" --port "$STUB_PORT" --no-log-file \
        --max-age 30 "$d1" "$d2" 2>&1)"

    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    assert_eq "submitted" "2" "$submitted" || return 1
}

# ── 29. Begin-marker failures stay fatal even with no candidate files ───────

test_begin_marker_failure_is_fatal() {
    stop_stub
    local d; d="$(create_sample_dir begin_marker_failure)"
    local fakebin; fakebin="$(create_fake_tool_path begin_marker_failure)"
    cat > "$fakebin/curl" <<'EOF'
#!/bin/sh
exit 7
EOF
    chmod +x "$fakebin/curl"

    local out rc
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 65534 --no-log-file --no-progress \
        --dir "$d" 2>&1)"
    rc=$?
    set -e

    # Server unreachable is a RUNTIME error => 1; 2 is reserved for usage/config errors.
    assert_eq "exit code" "1" "$rc" || return 1
    assert_contains "begin marker failure message" "begin marker failed after retry" "$out" || return 1
}

# ── 30. Wget 404 on /api/collection stays non-fatal ─────────────────────────

test_wget_collection_marker_404_nonfatal() {
    stop_stub
    local d; d="$(create_sample_dir wget_marker_404)"
    local fakebin; fakebin="$(create_fake_tool_path wget_marker_404)"
    cat > "$fakebin/wget" <<'EOF'
#!/bin/sh
printf '  HTTP/1.1 404 Not Found\n' >&2
exit 8
EOF
    chmod +x "$fakebin/wget"

    local out rc
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress \
        --dir "$d" 2>&1)"
    rc=$?
    set -e

    assert_eq "exit code" "0" "$rc" || return 1
    assert_contains "optional marker warning" "not supported (HTTP 404)" "$out" || return 1
    assert_not_contains "marker not fatal" "begin marker failed after retry" "$out" || return 1
}

# ── 31. Redirect upload responses are rejected ───────────────────────────────

test_redirect_upload_rejected() {
    stop_stub
    local d; d="$(create_sample_dir redirect_upload)"
    create_file "$d/sample.bin" "redirect-test"
    local fakebin; fakebin="$(create_fake_tool_path redirect_upload)"
    cat > "$fakebin/curl" <<'EOF'
#!/bin/sh
hdr=""
outfile=""
endpoint=""
while [ $# -gt 0 ]; do
    case "$1" in
        -D) hdr="$2"; shift 2 ;;
        -o) outfile="$2"; shift 2 ;;
        -F|-H|-d|--max-time|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="$1"; shift ;;
        *) shift ;;
    esac
done

case "$endpoint" in
    */api/collection)
        [ -n "$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "$hdr"
        [ -n "$outfile" ] && : > "$outfile"
        ;;
    *)
        [ -n "$hdr" ] && printf 'HTTP/1.1 302 Found\r\nLocation: https://example.invalid/other\r\n\r\n' > "$hdr"
        if [ -n "$outfile" ]; then
            printf 'redirect' > "$outfile"
        else
            printf 'redirect'
        fi
        ;;
esac
exit 0
EOF
    chmod +x "$fakebin/curl"

    local out rc
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress \
        --dir "$d" --retries 1 2>&1)"
    rc=$?
    set -e

    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local failed; failed="$(parse_collector_stat "$out" failed)"

    # Partial failure (the run happened, one file could not be collected) => exit 4
    assert_eq "exit code" "4" "$rc" || return 1
    assert_eq "submitted" "0" "$submitted" || return 1
    assert_eq "failed" "1" "$failed" || return 1
    assert_contains "redirect status logged" "HTTP 302" "$out" || return 1
}


# ══════════════════════════════════════════════════════════════════════════════
# --max-size
#
# These pin what documentation alone cannot defend. The size gate had no boundary test at all
# (only verify_portable.sh:89, which pins find's -size semantics, not the bound the collector
# derives from them), no test that the filter can be turned off, and no test that the policy
# reaches the operator's log or the server's record of the run.
# ══════════════════════════════════════════════════════════════════════════════

# The bound is INCLUSIVE: --max-size N collects a file of exactly N*1024 bytes and drops
# N*1024+1. That matches every sibling collector (Go's "MaxFileSize < info.Size()" skip test,
# and the Python/Perl/PowerShell/Batch ">" tests), so a file collected by one must not be
# dropped by another. KB means KiB (1024), as in Go — not 1000.
test_max_size_boundary_is_inclusive() {
    restart_stub
    local d; d="$(create_sample_dir size_boundary)"
    create_file_bytes "$d/under.bin"  2047
    create_file_bytes "$d/exact.bin"  2048
    create_file_bytes "$d/over.bin"   2049

    local out; out="$(run_collector --dry-run --dir "$d" --max-size 2 --max-age 0)"
    assert_eq "scanned" "2" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_eq "size_filtered" "1" "$(parse_collector_stat "$out" size_filtered)" || return 1
    assert_contains "one byte under the bound is collected" "under.bin" "$out" || return 1
    assert_contains "exactly at the bound is collected" "exact.bin" "$out" || return 1
    assert_not_contains "one byte over the bound is dropped" "over.bin" "$out" || return 1
}

# A zero-byte file is always inside any bound; it must never be silently dropped.
test_max_size_zero_byte_file_always_collected() {
    restart_stub
    local d; d="$(create_sample_dir size_zero_byte)"
    : > "$d/empty.bin"
    local out; out="$(run_collector --dry-run --dir "$d" --max-size 1 --max-age 0)"
    assert_eq "scanned" "1" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_eq "size_filtered" "0" "$(parse_collector_stat "$out" size_filtered)" || return 1
}

# --max-size 0 turns the size filter OFF, the way --max-age 0 turns the age filter off.
test_max_size_zero_disables_filter() {
    restart_stub
    local d; d="$(create_sample_dir size_zero_off)"
    create_file_bytes "$d/small.bin" 100
    create_file_bytes "$d/big.bin"   300000

    local out; out="$(run_collector --dry-run --dir "$d" --max-size 0 --max-age 0)"
    assert_eq "scanned (both, no size bound)" "2" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_contains "the run says the filter is off" "Size filter: disabled" "$out" || return 1
    assert_contains "the oversize file is collected" "big.bin" "$out" || return 1
}

# Regression guard for a silent-inflation trap. The size counting walk is spelled
# "-type f ! ${SIZE_TEST[@]}"; with SIZE_TEST empty that is not an absent test, it is
# "-type f ! -print0", which find matches for EVERY regular file. Measured before the guard:
# 3 of 3 files reported as size_filtered instead of 0. size_filtered must read 0 here, and it
# must mean "nothing was excluded", not "the counter was corrupted".
test_max_size_zero_does_not_inflate_size_filtered() {
    restart_stub
    local d; d="$(create_sample_dir size_zero_counter)"
    create_file_bytes "$d/a.bin" 10
    create_file_bytes "$d/b.bin" 20
    create_file_bytes "$d/c.bin" 90000

    local out; out="$(run_collector --dry-run --dir "$d" --max-size 0 --max-age 0)"
    assert_eq "size_filtered (nothing excluded)" "0" "$(parse_collector_stat "$out" size_filtered)" || return 1
    assert_eq "discovered" "3" "$(parse_collector_stat "$out" discovered)" || return 1
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}

# Bash reads a leading zero as octal: without 10# normalisation '--max-size 010' would mean
# 8 KiB, and '--max-size 08' would be a raw arithmetic error. Sibling of
# test_max_age_leading_zero_is_decimal.
test_max_size_leading_zero_is_decimal() {
    restart_stub
    local d; d="$(create_sample_dir size_octal)"
    create_file_bytes "$d/in.bin"  10240   # exactly 10 KiB -> inside a decimal 10
    create_file_bytes "$d/out.bin" 10241   # one over

    local out; out="$(run_collector --dry-run --dir "$d" --max-size 010 --max-age 0)"
    assert_eq "010 means 10 KiB, not 8" "1" "$(parse_collector_stat "$out" scanned)" || return 1
    assert_contains "the 10 KiB file is collected" "in.bin" "$out" || return 1
    assert_not_contains "the 10 KiB + 1 file is not" "out.bin" "$out" || return 1
}

test_max_size_value_validation() {
    restart_stub
    local d; d="$(create_sample_dir size_validation)"
    create_file "$d/a.txt" "x"
    local out rc

    # A negative value is a value the user meant, named as such — not "missing".
    set +e
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --dir "$d" --max-size -5 2>&1)"; rc=$?
    set -e
    assert_eq "negative rejected (exit 2)" "2" "$rc" || return 1
    assert_contains "negative named as such" "does not take a negative value" "$out" || return 1

    # A forgotten value must not silently eat the next flag.
    set +e
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --max-size --dir "$d" 2>&1)"; rc=$?
    set -e
    assert_eq "option-like value rejected (exit 2)" "2" "$rc" || return 1
    assert_contains "missing value named" "Missing value for --max-size" "$out" || return 1

    # Upper bound: 1 TiB in KiB is accepted, one more is not (the digit-count guard in
    # in_range keeps an oversized value out of Bash arithmetic entirely).
    set +e
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --dir "$d" --max-size 1073741825 2>&1)"; rc=$?
    set -e
    assert_eq "above 1 TiB rejected (exit 2)" "2" "$rc" || return 1
    assert_contains "bound named" "max-size must be <= 1073741824 KiB" "$out" || return 1

    # The --option=value form.
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --dir "$d" --max-size=1 --max-age 0 2>&1)"
    assert_contains "equals form accepted" "Size filter: regular files up to 1 KiB" "$out" || return 1
}

# The size policy must be stated in terms an operator can reconcile against the filesystem
# afterwards, as the age policy is. A bare "Max size (KB): 2000" said neither that KB means
# KiB nor which side of the boundary is kept.
test_max_size_policy_line_states_boundary() {
    restart_stub
    local d; d="$(create_sample_dir size_policy_line)"
    create_file "$d/a.txt" "x"
    local out; out="$(run_collector --dry-run --dir "$d" --max-size 2000 --max-age 0)"
    assert_contains "KiB and the byte bound" "up to 2000 KiB (2048000 bytes)" "$out" || return 1
    assert_contains "which side of the boundary is kept" "exactly 2048000 bytes is kept, one of 2048001 is not" "$out" || return 1
}

# The size gate applies to a symlink's resolved TARGET, not to the link. Sibling of
# test_age_policy_applies_to_symlink_targets.
test_max_size_policy_applies_to_symlink_targets() {
    restart_stub
    local d; d="$(create_sample_dir size_symlink)"
    local t; t="$(create_sample_dir size_symlink_targets)"
    create_file_bytes "$t/big.bin"   9000
    create_file_bytes "$t/small.bin" 100
    ln -s "$t/big.bin"   "$d/link-big"
    ln -s "$t/small.bin" "$d/link-small"

    local out; out="$(run_collector --dry-run --dir "$d" --follow-symlinks --max-size 1 --max-age 0)"
    assert_eq "links seen" "2" "$(parse_collector_stat "$out" links_seen)" || return 1
    assert_eq "the oversize target is skipped" "1" "$(parse_collector_stat "$out" links_skipped)" || return 1
    assert_contains "attributed to the SIZE gate, not merged" "filtered_size=1" "$out" || return 1
    assert_contains "and not to the age gate" "filtered_age=0" "$out" || return 1
    # README.md's claim: the counting walks cover regular files under the roots, so a link
    # target outside them is never attributed to size_filtered=. Asserted, not just documented.
    assert_eq "link targets are not counted in size_filtered" "0" "$(parse_collector_stat "$out" size_filtered)" || return 1
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}

# The split must name the gate that actually removed each link target, in every configuration:
# both gates on (one extra find decides), and either gate off (decided by elimination, no extra
# find spelled at all). The reconciliation identity must close in all three.
test_symlink_filtered_attribution_splits_size_from_age() {
    restart_stub
    local root; root="$(create_sample_dir link_split_root)"
    local tgt;  tgt="$(create_sample_dir link_split_targets)"
    create_file_bytes "$tgt/big.bin"  9000        # over a 1 KiB bound
    create_file_bytes "$tgt/old.bin"  100         # inside the bound, but ancient
    create_file_bytes "$tgt/good.bin" 100
    set_file_age_days "$tgt/old.bin" 400
    ln -s "$tgt/big.bin"  "$root/link-big"
    ln -s "$tgt/old.bin"  "$root/link-old"
    ln -s "$tgt/good.bin" "$root/link-good"

    local out
    # Both gates on: one target per reason, one collected.
    out="$(run_collector --dry-run --dir "$root" --follow-symlinks --max-size 1 --max-age 30 --age-timestamp mtime)"
    assert_contains "size reason named" "filtered_size=1" "$out" || return 1
    assert_contains "age reason named" "filtered_age=1" "$out" || return 1
    assert_eq "the in-policy target is still collected" "1" "$(parse_collector_stat "$out" links_collected)" || return 1
    assert_not_contains "reconciliation closes (both gates)" "Reconciliation failed" "$out" || return 1

    # Size gate off: whatever is filtered can only be age.
    out="$(run_collector --dry-run --dir "$root" --follow-symlinks --max-size 0 --max-age 30 --age-timestamp mtime)"
    assert_contains "no size attribution when the size gate is off" "filtered_size=0" "$out" || return 1
    assert_contains "age still attributed" "filtered_age=1" "$out" || return 1
    assert_not_contains "reconciliation closes (size off)" "Reconciliation failed" "$out" || return 1

    # Age gate off: whatever is filtered can only be size.
    out="$(run_collector --dry-run --dir "$root" --follow-symlinks --max-size 1 --max-age 0)"
    assert_contains "size attributed" "filtered_size=1" "$out" || return 1
    assert_contains "no age attribution when the age gate is off" "filtered_age=0" "$out" || return 1
    assert_not_contains "reconciliation closes (age off)" "Reconciliation failed" "$out" || return 1
}

# size_filtered= must ACCUMULATE across scan roots. With a single-root fixture, replacing the
# accumulation with a bare assignment passes every other test in this suite.
test_size_counters_sum_across_roots() {
    restart_stub
    local a; a="$(create_sample_dir size_roots_a)"
    local b; b="$(create_sample_dir size_roots_b)"
    create_file_bytes "$a/big1.bin" 9000
    create_file_bytes "$a/big2.bin" 9000
    create_file_bytes "$b/big3.bin" 9000
    create_file_bytes "$b/ok.bin"   100

    local out; out="$(run_collector --dry-run --dir "$a" --dir "$b" --max-size 1 --max-age 0)"
    assert_eq "size_filtered sums both roots" "3" "$(parse_collector_stat "$out" size_filtered)" || return 1
    assert_eq "scanned" "1" "$(parse_collector_stat "$out" scanned)" || return 1
}

# --no-count-filtered must say the size counter is UNMEASURED, and must not claim that when
# both gates are disabled (nothing could have been excluded, so the zeros are the truth).
test_no_count_filtered_with_size_gate() {
    restart_stub
    local d; d="$(create_sample_dir size_nocount)"
    create_file_bytes "$d/big.bin" 9000
    create_file_bytes "$d/ok.bin"  100

    local out; out="$(run_collector --dry-run --dir "$d" --max-size 1 --max-age 0 --no-count-filtered)"
    assert_eq "size_filtered reads 0 because it was not measured" "0" "$(parse_collector_stat "$out" size_filtered)" || return 1
    assert_contains "and the run says so" "not because nothing was excluded" "$out" || return 1
    assert_eq "the gate still applied at discovery" "1" "$(parse_collector_stat "$out" scanned)" || return 1

    # Both gates off: the zeros are true, so the run must NOT claim they are unmeasured.
    out="$(run_collector --dry-run --dir "$d" --max-size 0 --max-age 0 --no-count-filtered)"
    assert_contains "both-gates-off wording" "both discovery gates are disabled" "$out" || return 1
    assert_not_contains "does not claim the zeros hide exclusions" "not because nothing was excluded" "$out" || return 1
}

# The diagnostic must name the flag the operator actually typed.
test_max_size_errors_name_the_spelling_used() {
    restart_stub
    local d; d="$(create_sample_dir size_flagname)"
    create_file "$d/a.txt" "x"
    local out rc

    set +e
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --dir "$d" --max-size-kb abc 2>&1)"; rc=$?
    set -e
    assert_eq "legacy spelling rejected (exit 2)" "2" "$rc" || return 1
    assert_contains "error names the legacy flag" "max-size-kb must be numeric" "$out" || return 1

    set +e
    out="$(bash "$COLLECTOR" --dry-run --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --dir "$d" --max-size abc 2>&1)"; rc=$?
    set -e
    assert_contains "error names the canonical flag" "max-size must be numeric" "$out" || return 1
    assert_not_contains "and not the legacy one" "max-size-kb must be numeric" "$out" || return 1
}

# The size bound must be self-describing on the wire: max_size_kb alone repeats the KB/KiB
# ambiguity the log line was rewritten to remove, and a disabled gate had to be inferred.
test_size_bound_bytes_in_marker_stats() {
    has_stub_verification || return 77
    restart_stub
    local d; d="$(create_sample_dir size_bound_wire)"
    create_file "$d/a.txt" "x"
    run_collector --dir "$d" --max-size 77 --max-age 0 >/dev/null 2>&1 || true
    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_contains "the byte bound reaches the server" '"size_bound_bytes":78848' "$audit" || return 1
    assert_contains "beside the KiB value" '"max_size_kb":77' "$audit" || return 1

    # Gate off: the bound is stated as 0, not left to be inferred.
    restart_stub
    run_collector --dir "$d" --max-size 0 --max-age 0 >/dev/null 2>&1 || true
    audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_contains "disabled gate states a zero bound" '"size_bound_bytes":0' "$audit" || return 1
}

# --help must carry the flag and its alias; the alias's behaviour is tested but its
# discoverability was not.
test_help_documents_max_size_and_alias() {
    local out; out="$(bash "$COLLECTOR" --help 2>&1)"
    assert_contains "help lists --max-size" "--max-size <kb>" "$out" || return 1
    assert_contains "help states the KiB base" "1 KiB = 1024 bytes" "$out" || return 1
    assert_contains "help names the retained alias" "--max-size-kb is the former name" "$out" || return 1
}

# The cut-off-mid-transfer warning is the README's headline measured failure mode (a proxy with
# a shorter per-request window than the client), and it names --max-size. Untested until now.
test_cutoff_midtransfer_points_at_max_size() {
    local d; d="$(create_sample_dir size_cutoff)"
    create_file "$d/a.txt" "payload"
    local fakebin; fakebin="$(create_fake_tool_path size_cutoff)"
    rm -f "$fakebin/curl"
    cat > "$fakebin/curl" <<EOF
#!/bin/sh
hdr=""; outfile=""; endpoint=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -D) hdr="\$2"; shift 2 ;;
        -o) outfile="\$2"; shift 2 ;;
        -F|-H|-d|--max-time|--connect-timeout|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$endpoint" in
    */api/collection)
        [ -n "\$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        exit 0
        ;;
    *)
        # A proxy that answers, then cuts the request off mid-body: curl exit 18.
        [ -n "\$hdr" ] && printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        exit 18
        ;;
esac
EOF
    chmod +x "$fakebin/curl"

    local out
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress \
        --dir "$d" --max-age 0 --max-size 2000 --retries 1 2>&1)"
    set -e
    assert_contains "the server status is named, not discarded" "HTTP 502" "$out" || return 1
    assert_contains "the operator is pointed at the flag" "lower --max-size" "$out" || return 1
}



# The server records size_filtered=; without max_size_kb beside it that number cannot be
# interpreted. max_age has always been sent — max_size_kb was not.
test_max_size_reported_in_marker_stats() {
    has_stub_verification || return 77
    restart_stub
    local d; d="$(create_sample_dir size_marker)"
    create_file "$d/a.txt" "x"
    run_collector --dir "$d" --max-size 77 --max-age 0 >/dev/null 2>&1 || true
    # Whitespace-normalised: the assertion is about the field reaching the server, not about
    # how a particular stub chooses to re-serialise the JSON it received.
    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_contains "max_size_kb reaches the server" '"max_size_kb":77' "$audit" || return 1
    assert_contains "beside the age policy it has always carried" '"max_age":0' "$audit" || return 1
}

# CLAUDE.md §2: retry only what the protocol calls transient. A 413 is the server saying this
# body is too large; retrying re-uploads the whole file for a guaranteed second refusal.
test_oversize_rejection_is_not_retried() {
    local d; d="$(create_sample_dir size_413)"
    create_file "$d/a.txt" "payload"
    local fakebin; fakebin="$(create_fake_tool_path size_413)"
    local hits="$TEST_TMP/413-hits"
    : > "$hits"
    rm -f "$fakebin/curl"
    cat > "$fakebin/curl" <<EOF
#!/bin/sh
hdr=""; outfile=""; endpoint=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -D) hdr="\$2"; shift 2 ;;
        -o) outfile="\$2"; shift 2 ;;
        -F|-H|-d|--max-time|--connect-timeout|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$endpoint" in
    */api/collection)
        [ -n "\$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        ;;
    *)
        printf 'x' >> "$hits"
        [ -n "\$hdr" ] && printf 'HTTP/1.1 413 Payload Too Large\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && printf 'too large' > "\$outfile"
        ;;
esac
exit 0
EOF
    chmod +x "$fakebin/curl"

    local out rc
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress \
        --dir "$d" --max-age 0 --retries 3 2>&1)"
    rc=$?
    set -e

    local attempts; attempts="$(wc -c < "$hits" | tr -d ' ')"
    assert_eq "413 uploaded once, not --retries times" "1" "$attempts" || return 1
    assert_eq "exit code (partial failure)" "4" "$rc" || return 1
    assert_eq "failed" "1" "$(parse_collector_stat "$out" failed)" || return 1
    assert_contains "the status is named" "HTTP 413" "$out" || return 1
    assert_contains "and the decision explained" "not retrying" "$out" || return 1
}

# A 5xx IS transient and must still consume the retry budget — the classifier must not
# over-reach and turn every failure terminal.
test_server_error_is_still_retried() {
    local d; d="$(create_sample_dir size_502)"
    create_file "$d/a.txt" "payload"
    local fakebin; fakebin="$(create_fake_tool_path size_502)"
    local hits="$TEST_TMP/502-hits"
    : > "$hits"
    rm -f "$fakebin/curl"
    cat > "$fakebin/curl" <<EOF
#!/bin/sh
hdr=""; outfile=""; endpoint=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -D) hdr="\$2"; shift 2 ;;
        -o) outfile="\$2"; shift 2 ;;
        -F|-H|-d|--max-time|--connect-timeout|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$endpoint" in
    */api/collection)
        [ -n "\$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        ;;
    *)
        printf 'x' >> "$hits"
        [ -n "\$hdr" ] && printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && printf 'bad gateway' > "\$outfile"
        ;;
esac
exit 0
EOF
    chmod +x "$fakebin/curl"

    set +e
    env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress \
        --dir "$d" --max-age 0 --retries 2 >/dev/null 2>&1
    set -e

    local attempts; attempts="$(wc -c < "$hits" | tr -d ' ')"
    assert_eq "502 consumes the retry budget" "2" "$attempts" || return 1
}


# The interrupted marker carries the same policy fields as the end marker. It had no test at
# all, and max_size_kb was originally added to the end marker's copy of the stats object only —
# the two payloads were written out verbatim twice. Both are now built by build_stats_json;
# this pins that they stay in step.
test_interrupted_marker_carries_policy() {
    has_stub_verification || return 77
    restart_stub
    local d; d="$(create_sample_dir interrupt_marker)"
    local i
    for i in $(seq 1 600); do create_file_bytes "$d/f$i.bin" 512; done

    # The collector is started DIRECTLY, not through run_collector: that is a shell function,
    # so backgrounding it would give us the PID of its subshell and the SIGINT would never
    # reach the collector (the run then exited 0 and the test passed for the wrong reason).
    # Job control ON for the launch. A non-interactive shell starts background jobs with
    # SIGINT set to SIG_IGN, and bash cannot trap a signal that was ignored on entry — so the
    # collector's INT trap never fired and it ran to completion, uploading all 600 files while
    # the test believed it had interrupted it. With 'set -m' the child gets its own process
    # group and the default INT disposition, which is what a real Ctrl-C delivers.
    set -m
    bash "$COLLECTOR" --server "$(server_host)" --port "$STUB_PORT" --no-log-file --no-progress \
        --dir "$d" --max-size 77 --max-age 0 >/dev/null 2>&1 &
    local pid=$!
    set +m
    # Wait for a CONDITION, not a duration: a fixed sleep raced the run (400 small files
    # against a local stub can finish inside it), and the collector then exited 0 with the
    # test asserting on a run that was never interrupted.
    local i _seen
    for i in $(seq 1 200); do
        # NB: 'grep -c' prints 0 AND exits 1 when there is no match, so a '|| echo 0' fallback
        # captures "0\n0" and every numeric test after it is a shell error.
        _seen="$(grep -c 'THOR finding' "$AUDIT_LOG" 2>/dev/null)" || _seen=0
        # 1, not 5: each poll costs a fork, and under battery load waiting for five
        # uploads could consume the run's remaining work, so the signal landed after the
        # collector had already exited and the test failed for a reason that was not a
        # regression. One upload proves the upload pass has started, which is all this needs.
        [ "${_seen:-0}" -ge 1 ] && break
        sleep 0.05
    done
    kill -INT "$pid" 2>/dev/null || true
    set +e
    wait "$pid"
    local rc=$?
    set -e

    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    # A 0 here means the run finished before the signal landed (fixture too small or the box
    # too fast), not that the signal path is broken — say so rather than leaving a bare mismatch.
    [ "$rc" -ne 0 ] || { printf 'FAIL: the run completed before the signal was delivered (test setup, not a product failure)\n' >&2; return 1; }
    assert_eq "interrupted exit code" "130" "$rc" || return 1
    assert_marker_sent "an interrupted marker was sent" interrupted "$audit" || return 1
    assert_contains "carrying the size policy" '"max_size_kb":77' "$audit" || return 1
    assert_contains "and the age policy beside it" '"max_age":0' "$audit" || return 1
}

# The summary must not name a gate that is switched off. With --max-size 0 the run's own
# policy line says "Size filter: disabled", so a summary claiming "0 file(s) over the size
# limit" asserts a limit that does not exist.
test_summary_names_only_active_gates() {
    restart_stub
    local d; d="$(create_sample_dir active_gates)"
    create_file "$d/fresh.txt" "new"
    create_file "$d/old.txt" "old"
    set_file_age_days "$d/old.txt" 400

    # size filter OFF, age filter ON -> age clause only
    local out; out="$(run_collector --dry-run --dir "$d" --max-size 0 --max-age 7 --age-timestamp mtime)"
    assert_contains "the age gate is named" "outside the age window" "$out" || return 1
    assert_not_contains "the disabled size gate is not" "over the size limit" "$out" || return 1

    # both ON -> both clauses
    out="$(run_collector --dry-run --dir "$d" --max-size 1 --max-age 7 --age-timestamp mtime)"
    assert_contains "both gates named when both are on" "over the size limit" "$out" || return 1
}


# Regression guard for a defect introduced with the retry classifier and caught only by
# adversarial review. curl sends "Expect: 100-continue"; when a peer answers 100 and then drops
# the connection, the ONLY status line in curl's -D file is "HTTP/1.1 100 Continue", so the
# collector's parser yields 100. A classifier written as "retryable unless in a known-good set"
# called that non-retryable and abandoned the file after ONE attempt — turning an ordinary
# transient network failure into a permanent loss. The classifier's default must be RETRY.
test_transient_status_still_retried() {
    local d; d="$(create_sample_dir transient_100)"
    create_file "$d/a.txt" "payload"
    local fakebin; fakebin="$(create_fake_tool_path transient_100)"
    local hits="$TEST_TMP/100-hits"
    : > "$hits"
    rm -f "$fakebin/curl"
    cat > "$fakebin/curl" <<EOF
#!/bin/sh
hdr=""; outfile=""; endpoint=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -D) hdr="\$2"; shift 2 ;;
        -o) outfile="\$2"; shift 2 ;;
        -F|-H|-d|--max-time|--connect-timeout|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$endpoint" in
    */api/collection)
        [ -n "\$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        exit 0
        ;;
    *)
        printf 'x' >> "$hits"
        # 100 Continue and nothing else, then a transport failure (curl exit 55, send error).
        [ -n "\$hdr" ] && printf 'HTTP/1.1 100 Continue\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        exit 55
        ;;
esac
EOF
    chmod +x "$fakebin/curl"

    set +e
    env PATH="$fakebin" bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress \
        --dir "$d" --max-age 0 --retries 3 >/dev/null 2>&1
    set -e

    local attempts; attempts="$(wc -c < "$hits" | tr -d ' ')"
    assert_eq "a 1xx status is transient: all --retries attempts used" "3" "$attempts" || return 1
}


# A vanished file must never be reported as collected. On the wget path the multipart body is
# assembled in a brace group; a brace group reports its LAST command's status, so a failed
# `cat` was masked by the trailing printf, the body went out with an EMPTY file part, the
# server answered 200, and the run reported submitted=1 for bytes it never sent.
test_wget_vanished_file_is_not_reported_collected() {
    restart_stub
    local d; d="$(create_sample_dir wget_vanish)"
    create_file "$d/gone.txt" "content that will disappear"

    # A wget shim that deletes the file before wget would read the body, then reports success —
    # standing in for the file vanishing between the pre-open check and the body build.
    local fakebin; fakebin="$(create_fake_tool_path wget_vanish)"
    rm -f "$fakebin/curl"                       # force the wget path
    rm -f "$fakebin/wget"
    cat > "$fakebin/wget" <<EOF
#!/bin/sh
exec $(command -v wget) "\$@"
EOF
    chmod +x "$fakebin/wget"

    # Remove the file, then run: submit_file's [ -f ] guard should catch it (94 -> vanished),
    # and in no case may it be counted as submitted.
    rm -f "$d/gone.txt"
    create_file "$d/present.txt" "still here"

    local out; out="$(env PATH="$fakebin" bash "$COLLECTOR" \
        --server "$(server_host)" --port "$STUB_PORT" --no-log-file --no-progress \
        --dir "$d" --max-age 0 --max-size 2000 2>&1)"

    # Whatever is submitted must have been really sent: submitted must equal the uploads the
    # stub actually recorded, and no zero-byte body may be recorded for a named file.
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local recorded; recorded="$(grep -c 'THOR finding' "$AUDIT_LOG" 2>/dev/null)" || recorded=0
    assert_eq "submitted equals what the server actually received" "$recorded" "$submitted" || return 1
    assert_not_contains "no empty body recorded for a named file" '"size":0,"hashes"' "$(tr -d ' ' < "$AUDIT_LOG")" || return 1
}

# The wget multipart boundary-collision guard must actually read the file. The boundary starts
# with '----', so `grep -qF "$boundary" file` is parsed as an option bundle: grep exits 2
# without reading a byte, 2>/dev/null hides it, and the leading '!' reads that error as
# "no collision". This pins the '-e' that makes the guard real.
test_wget_boundary_guard_reads_the_file() {
    local b="----ThunderstormBoundary12345"
    local f="$TEST_TMP/boundary-probe.txt"
    printf 'x %s y\n' "$b" > "$f"
    local rc
    set +e
    LC_ALL=C grep -qF -e "$b" "$f" 2>/dev/null; rc=$?
    set -e
    assert_eq "grep -qF -e finds a boundary present in the file" "0" "$rc" || return 1
    # And the bare form really is broken, so the '-e' above is load-bearing and not decoration.
    set +e
    LC_ALL=C grep -qF "$b" "$f" 2>/dev/null; rc=$?
    set -e
    assert_eq "without -e grep errors out instead of matching" "2" "$rc" || return 1
    # The collector must use the -e form (the collision is not reproducible on demand — the
    # boundary is randomised — so the fix is pinned at the source level).
    local hits; hits="$(grep -c -- '-qF -e "\$boundary"' "$COLLECTOR")" || hits=0
    assert_eq "collector guards with -e" "1" "$hits" || return 1
}


# The flag is --max-size (--max-age does not carry "days" in its name either). The former
# spelling --max-size-kb is still accepted so deployed runbooks and CI keep working; both
# spellings, in both the separated and the =value form, must mean exactly the same thing.
test_max_size_legacy_flag_name_still_works() {
    restart_stub
    local d; d="$(create_sample_dir size_legacy_name)"
    create_file_bytes "$d/under.bin" 2048
    create_file_bytes "$d/over.bin"  2049

    local spelling out
    for spelling in "--max-size 2" "--max-size=2" "--max-size-kb 2" "--max-size-kb=2"; do
        # shellcheck disable=SC2086
        out="$(run_collector --dry-run --dir "$d" $spelling --max-age 0)"
        assert_eq "scanned ($spelling)" "1" "$(parse_collector_stat "$out" scanned)" || return 1
        assert_eq "size_filtered ($spelling)" "1" "$(parse_collector_stat "$out" size_filtered)" || return 1
        assert_contains "same policy line ($spelling)" "up to 2 KiB (2048 bytes)" "$out" || return 1
    done

    # 0 disables the filter through the legacy spelling too.
    out="$(run_collector --dry-run --dir "$d" --max-size-kb 0 --max-age 0)"
    assert_contains "legacy spelling can disable the filter" "Size filter: disabled" "$out" || return 1
    assert_eq "both files collected" "2" "$(parse_collector_stat "$out" scanned)" || return 1
}


# size_filtered= must count files MEASURED to be too big, never files whose size could not be
# read. find answers -type f from the directory entry without a stat, so under a directory that
# is readable but not searchable (0444 — an ordinary non-root situation) `! -size -Nc` is true
# for every file in it and the summary claimed they were all over the limit. The counting walk
# uses the positive `-size +Mc` instead, which is false when the stat fails.
#
# Root bypasses DAC entirely, so this can only be observed as an unprivileged user; the test
# skips rather than passing vacuously when it cannot drop privileges.
test_size_filtered_excludes_unsizeable_files() {
    # drop_privs_prefix, not an inline copy: this reimplemented it with a hardcoded 65534 instead
    # of looking `nobody` up, and — the part that mattered — returned 0 when it could not drop
    # privileges at all. A test that cannot establish its own premise was reporting PASS having
    # asserted nothing; 77/SKIP is the convention run_test understands.
    local runas; runas="$(drop_privs_prefix)" || return 77

    # World-traversable fixture: the unprivileged user has to be able to reach it.
    local base="/tmp/ts-unsizeable-$$"
    rm -rf "$base"; mkdir -p "$base/locked"
    local i
    for i in 1 2 3 4; do head -c 100 /dev/zero > "$base/locked/f$i.bin"; done
    head -c 100 /dev/zero > "$base/normal.bin"
    chmod -R a+rX "$base"
    chmod 0444 "$base/locked"          # readable, NOT searchable -> stat on children denied
    assert_fixture_denies "$base/locked" x "$runas" || return 1
    local tmp="$base/tmp"; mkdir -p "$tmp"; chmod 0777 "$tmp"

    local out
    out="$($runas env TMPDIR="$tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 2 --max-age 0 2>&1)"

    # Every file is 100 bytes: nothing is over a 2 KiB bound, whatever can or cannot be stat'ed.
    assert_eq "unsizeable files are not called oversize" "0" "$(parse_collector_stat "$out" size_filtered)" || return 1
    assert_not_contains "and the summary does not claim they were" "file(s) over the size limit" "$out" || return 1

    chmod 0755 "$base/locked" 2>/dev/null || true
    rm -rf "$base"
}


# ══════════════════════════════════════════════════════════════════════════════
# Signals, walk-error attribution, and inaccessible-vs-vanished
#
# All of the permission cases below are invisible to root, which bypasses DAC entirely — which
# is why they survived four audit rounds. They drop privileges, and SKIP rather than pass
# vacuously when they cannot.
# ══════════════════════════════════════════════════════════════════════════════

# assert_fixture_denies -- a denial fixture must deny through its MODE BITS ALONE, never by
# relying on the reader being someone other than the owner.
#
# drop_privs_prefix returns a setpriv prefix when the suite is root and an EMPTY string when it
# is not, so the identity that reads a fixture differs by box: `nobody` reading a root-owned tree
# here, the tree's own owner on a non-root runner. chmod 0700 denied the former and granted the
# latter rwx, so the "unlistable" directory was fully readable in CI: unreadable_dirs= counted 1
# instead of 2 and its files were collected, while the same fixture read correctly under
# root+setpriv. Green here, red in GitHub Actions.
#
# The mode-bit check below is what closes that, and it is deliberately NOT a live read: probing
# the fixture as the reader would have passed here too, because under root+setpriv 0700 genuinely
# denied `nobody`. A property that never asks who is reading fails identically on every box.
# Root itself bypasses r/x bits entirely (which is why the suite drops privileges at all), so
# this divergence cannot be removed — only made impossible to get wrong.
#   $1 = directory  $2 = the bit that must be clear for u, g AND o: r (unlistable) / x (unsearchable)
#   $3 = the privilege-drop prefix the collector will use ("" when the suite is not root)
assert_fixture_denies() {
    local dir="$1" want="$2" pre="$3" mode bit n
    case "$want" in
        r) bit=4 ;;
        x) bit=1 ;;
        *) printf 'FIXTURE: assert_fixture_denies got bit %s, expected r or x\n' "$want" >&2; return 1 ;;
    esac
    mode="$(stat -c '%a' "$dir" 2>/dev/null)" || mode=""
    [ -n "$mode" ] || mode="$(stat -f '%Lp' "$dir" 2>/dev/null)" || mode=""
    if [ -n "$mode" ]; then
        # 10# so a leading zero is not read as octal by the shell's own arithmetic.
        n=$(( 10#$mode ))
        if [ $(( n / 100 % 10 & bit )) -ne 0 ] || [ $(( n / 10 % 10 & bit )) -ne 0 ] \
            || [ $(( n % 10 & bit )) -ne 0 ]; then
            printf 'FIXTURE: %s is mode %s — a %s bit is still set, so it denies only non-owners\n' \
                "$dir" "$mode" "$want" >&2
            return 1
        fi
    fi
    # Then confirm it live as the identity that will actually read it. Costs one process and
    # catches what mode bits cannot: an ACL, an unexpected umask, a `nobody` that happens to
    # share the fixture's group. No r -> cannot list; no x -> cannot cd into it.
    #
    # Only when that identity is NOT root, though. Root bypasses r/x bits, so the probe would
    # report every correct fixture as readable and fail it — the mode-bit check above is the
    # whole invariant in that case. An empty prefix means "read as whoever runs the suite", so
    # root + no prefix is exactly the case to skip.
    if [ -z "$pre" ] && [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    case "$want" in
        r) if $pre sh -c "ls '$dir' >/dev/null 2>&1"; then
               printf 'FIXTURE: %s is listable by the reader\n' "$dir" >&2; return 1
           fi ;;
        x) if $pre sh -c "cd '$dir' >/dev/null 2>&1"; then
               printf 'FIXTURE: %s is searchable by the reader\n' "$dir" >&2; return 1
           fi ;;
    esac
    return 0
}

# Shared fixture: a world-traversable tree with one directory that can be listed but not
# searched (0444) and one that cannot be listed at all (0300), plus its own TMPDIR.
# Echoes the base path, and refuses to hand one back that does not actually deny.
# $1 = fixture name, $2 = the privilege-drop prefix the collector will run under.
make_denied_fixture() {
    local base="/tmp/ts-denied-$$-$1"
    rm -rf "$base"
    mkdir -p "$base/unsearchable" "$base/unlistable" "$base/tmp"
    local i
    for i in 1 2 3 4; do head -c 100 /dev/zero > "$base/unsearchable/f$i.bin"; done
    for i in 1 2; do head -c 100 /dev/zero > "$base/unlistable/g$i.bin"; done
    head -c 100 /dev/zero > "$base/ok.bin"
    chmod -R a+rX "$base"
    chmod 0777 "$base/tmp"
    # 0444 has no x bit for anyone (listable, not searchable); 0300 has no r bit for anyone (not
    # listable). Both classes then hold for the owner and for a privilege-dropped reader alike —
    # see assert_fixture_denies, which refuses to hand back a fixture that does not.
    chmod 0444 "$base/unsearchable"
    chmod 0300 "$base/unlistable"
    assert_fixture_denies "$base/unsearchable" x "$2" || return 1
    assert_fixture_denies "$base/unlistable"   r "$2" || return 1
    echo "$base"
}

drop_privs_prefix() {
    if [ "$(id -u)" -eq 0 ]; then
        command -v setpriv >/dev/null 2>&1 || return 1
        local _uid _gid
        _uid="$(id -u nobody 2>/dev/null)" || return 1
        _gid="$(id -g nobody 2>/dev/null)" || return 1
        # The one path a priv-dropped test cannot relocate is the collector itself: under a 0700
        # checkout every such test would FAIL on an unreadable script rather than SKIP.
        setpriv --reuid="$_uid" --regid="$_gid" --clear-groups \
            env COLLECTOR_PATH="$COLLECTOR" sh -c 'test -r "$COLLECTOR_PATH"' 2>/dev/null || return 1
        echo "setpriv --reuid=$_uid --regid=$_gid --clear-groups"
        return 0
    fi
    echo ""
}

# A curl that sleeps briefly, then delegates to the real curl: gives a signal test a
# deterministic window in which the run is still in its upload pass, without faking the wire.
# Its own directory, never create_fake_tool_path's (whose entries are symlinks to REAL binaries).
make_slow_curl_path() {
    local dir="$TEST_TMP/slowcurl-$1" real
    real="$(type -P curl)" || return 1
    mkdir -p "$dir"
    rm -f "$dir/curl"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'sleep 0.15\n'
        printf 'exec %s "$@"\n' "$real"
    } > "$dir/curl"
    chmod +x "$dir/curl"
    printf '%s\n' "$dir"
}

# Reap $1 with a bound: a hung signal handler must FAIL the test, not hang the suite (the
# handler blanks its own traps, so a defect there is precisely a hang).
BOUNDED_WAIT_RC=0
bounded_wait() {
    local pid="$1" max="${2:-200}" i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt "$max" ]; then
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            BOUNDED_WAIT_RC=137
            return 1
        fi
        sleep 0.05
    done
    wait "$pid" 2>/dev/null
    BOUNDED_WAIT_RC=$?
    return 0
}

# Whether the find on PATH lists entries it cannot stat. GNU answers -type from the directory
# entry and so lists them; busybox stats unconditionally and cannot see them at all. That
# difference is a documented platform limitation, not a defect, so the tests below assert the
# GNU counts where they are obtainable and the documented fallback where they are not.
# $1 = an unsearchable directory, $2 = the privilege-dropping prefix (may be empty).
find_lists_unstatable_entries() {
    local n
    # The SAME expression the collector's probe uses, '! -type l' included — a probe with a
    # different shape than the one it predicts is how every one of these tests once took the
    # busybox branch on GNU. NUL-terminated and counted by separator, so a newline-bearing
    # path cannot inflate the answer.
    n="$($2 find "$1" ! -size -1c ! -size +0c ! -type l -print0 2>/dev/null | tr -d -c '\000' | wc -c | tr -d ' ')"
    [ "${n:-0}" -gt 0 ]
}

cleanup_denied_fixture() {
    chmod 0755 "$1/unsearchable" "$1/unlistable" 2>/dev/null || true
    rm -rf "$1"
}

# Each signal must end the run deliberately: interrupted marker naming the signal, work directory
# removed, exit 128+signum. Before the fix HUP and QUIT were at their default disposition — the
# process died with no marker at all, so the server held a begin marker and nothing else.
test_signals_end_the_run_cleanly() {
    has_stub_verification || return 77
    local sig rc expect
    for sig in HUP QUIT INT TERM; do
        case "$sig" in
            HUP) expect=129 ;; INT) expect=130 ;; QUIT) expect=131 ;; TERM) expect=143 ;;
        esac
        # A signal the HARNESS itself inherited as SIG_IGN (a suite run under nohup ignores HUP)
        # is untrappable in every child by design — that leg is the ignore-on-entry test's job,
        # not a failure of this one. Probe deliverability with a child that signals itself.
        bash -c "trap 'exit 42' $sig; kill -$sig \$\$; sleep 0.1; exit 0" >/dev/null 2>&1
        if [ "$?" -ne 42 ]; then
            echo "    (SIG$sig arrives ignored in this harness — e.g. a nohup run — skipping that leg)"
            continue
        fi
        restart_stub
        local d; d="$(create_sample_dir "sig_$sig")"
        local i
        for i in $(seq 1 80); do create_file_bytes "$d/f$i.bin" 512; done
        local wt="$TEST_TMP/work_$sig"; rm -rf "$wt"; mkdir -p "$wt"
        # The slow-curl shim makes the window deterministic: 80 uploads at >=0.15 s each is
        # ~12 s of runway, where the bare 600-file run finished before the kill under load.
        local slow; slow="$(make_slow_curl_path "sig_$sig")" || return 77

        # 'set -m' so the child gets its own process group and the default disposition: a
        # non-interactive shell starts background jobs with INT ignored, and bash cannot trap a
        # signal ignored on entry.
        set -m
        env PATH="$slow:$PATH" TMPDIR="$wt" bash "$COLLECTOR" --server "$(server_host)" --port "$STUB_PORT" \
            --no-log-file --no-progress --dir "$d" --max-size 2000 --max-age 0 >/dev/null 2>&1 &
        local pid=$!
        set +m
        local seen
        for i in $(seq 1 200); do
            seen="$(grep -c 'THOR finding' "$AUDIT_LOG" 2>/dev/null)" || seen=0
            # One upload proves the upload pass started, and leaves the most runway.
            [ "${seen:-0}" -ge 1 ] && break
            sleep 0.05
        done
        kill -"$sig" "$pid" 2>/dev/null || true
        set +e
        # The handler blanks its own traps, so a defect in it is a HANG: bound the reap.
        bounded_wait "$pid" 400 \
            || { printf 'FAIL: SIG%s — the signal handler hung (killed after 20 s)\n' "$sig" >&2; return 1; }
        rc=$BOUNDED_WAIT_RC
        set -e

        local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
        [ "$rc" -ne 0 ] || { printf 'FAIL: SIG%s — the run completed before the signal was delivered (test setup, not a product failure)\n' "$sig" >&2; return 1; }
        assert_eq "SIG$sig exit code" "$expect" "$rc" || return 1
        assert_marker_sent "SIG$sig sent an interrupted marker" interrupted "$audit" || return 1
        assert_contains "SIG$sig named itself on the wire" "\"interrupted_by\":\"$sig\"" "$audit" || return 1
        assert_eq "SIG$sig removed its work directory" "0" "$(find "$wt" -maxdepth 1 -name 'thunderstorm.work.*' 2>/dev/null | wc -l | tr -d ' ')" || return 1
    done
}

test_help_documents_the_interrupt_exit_codes() {
    local out; out="$(bash "$COLLECTOR" --help 2>&1)"
    assert_contains "help lists the interrupt codes" "129/130/131/143" "$out" || return 1
}

# unreadable_dirs= must count DIRECTORIES. find writes one diagnostic per failed stat, so one
# unsearchable directory holding four files produced four lines and the counter read 4 — for one
# directory — while claiming "their files are unknown".
test_unreadable_dirs_counts_directories_not_diagnostics() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base; base="$(make_denied_fixture dirs "$pre")" || return 1
    local out
    out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 2 --max-age 0 2>&1)"
    cleanup_denied_fixture "$base"

    # Two directories: one unlistable, one unsearchable. Not four diagnostics.
    assert_eq "unreadable_dirs counts directories" "2" "$(parse_collector_stat "$out" unreadable_dirs)" || return 1
    # The message template always contains both phrases, so grepping them proves nothing —
    # assert the COUNTS: one directory of each class, not four diagnostics.
    assert_contains "one directory could not be listed" ": 1 could not be listed" "$out" || return 1
    assert_contains "and one could not be searched" "; 1 could be listed but not searched" "$out" || return 1
}

# The entries an unsearchable directory hides are known to exist and are silently never
# collected. Nothing counted them before.
test_unstatable_entries_are_counted_and_named() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base; base="$(make_denied_fixture entries "$pre")" || return 1
    local _sees=0
    find_lists_unstatable_entries "$base/unsearchable" "$pre" && _sees=1
    local out
    out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 2 --max-age 0 2>&1)"
    local rc
    set +e
    $pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 2 --max-age 0 >/dev/null 2>&1
    rc=$?
    set -e
    cleanup_denied_fixture "$base"

    if [ "$_sees" -eq 1 ]; then
        assert_eq "the four hidden entries are counted" "4" "$(parse_collector_stat "$out" unstatable)" || return 1
        assert_contains "and a REAL path is named, not a constant phrase" "$base/unsearchable/f" "$out" || return 1
    else
        # This find cannot see an entry it cannot stat. The zero must be declared unmeasured,
        # never printed as a statement that nothing was hidden.
        assert_eq "unstatable reads zero here" "0" "$(parse_collector_stat "$out" unstatable)" || return 1
        assert_contains "and says so instead of claiming none were hidden" "unmeasured rather than a statement" "$out" || return 1
    fi
    # Either way the directory is counted and the run is partial.
    assert_contains "the directory is still counted" "could be listed but not searched" "$out" || return 1
    assert_eq "the run is partial" "4" "$rc" || return 1
}

# D4: with both gates off the walk needs no stat, so find SUCCEEDS, writes nothing to stderr and
# unreadable_dirs= never fires — yet every hidden file is discovered and then fails [ -f ].
# Booking those as vanished made the run exit 5 and call a permission failure "ordinary churn on
# a live host and nothing the collector or the operator did wrong". This is the case with no
# other signal at all.
test_inaccessible_files_are_unreadable_not_vanished() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base; base="$(make_denied_fixture d4 "$pre")" || return 1
    chmod 0755 "$base/unlistable"        # isolate the unsearchable class
    local _sees=0
    find_lists_unstatable_entries "$base/unsearchable" "$pre" && _sees=1
    local out rc
    out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 0 --max-age 0 2>&1)"
    set +e
    $pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 0 --max-age 0 >/dev/null 2>&1
    rc=$?
    set -e
    cleanup_denied_fixture "$base"

    if [ "$_sees" -eq 1 ]; then
        # The entries are discovered, then cannot be examined: unreadable, never churn.
        assert_eq "failed" "4" "$(parse_collector_stat "$out" failed)" || return 1
        assert_contains "counted as unreadable" "unreadable=4" "$out" || return 1
        assert_contains "and not as churn" "vanished=0" "$out" || return 1
    else
        # They are never enumerated here, so the loss shows as the unreadable directory instead.
        assert_eq "nothing is miscounted as churn" "0" "$(parse_collector_stat "$out" failed)" || return 1
        assert_contains "the directory carries the loss" "could be listed but not searched" "$out" || return 1
    fi
    assert_eq "exit 4 (partial failure), not 5 (churn)" "4" "$rc" || return 1
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}

# A symlink under an unsearchable directory cannot be lstat'ed, so its type is genuinely
# unknowable to the upload pass. It must be reported as a named FAILURE — the entry exists and
# was not collected — and never as churn ("vanished", exit 5, "nothing anyone did wrong"), which
# is what it used to be. Discovery deliberately does not guess a type it cannot read.
test_symlink_under_unsearchable_dir_is_a_named_failure() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base; base="$(make_denied_fixture linkfail "$pre")" || return 1
    chmod 0755 "$base/unsearchable"
    ln -s "$base/ok.bin" "$base/unsearchable/alink"
    chmod 0444 "$base/unsearchable"
    chmod 0755 "$base/unlistable"
    assert_fixture_denies "$base/unsearchable" x "$pre" || return 1

    local _sees=0
    find_lists_unstatable_entries "$base/unsearchable" "$pre" && _sees=1
    local out rc
    out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 0 --max-age 0 2>&1)"
    set +e
    $pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --dir "$base" --max-size 0 --max-age 0 >/dev/null 2>&1
    rc=$?
    set -e
    cleanup_denied_fixture "$base"

    if [ "$_sees" -eq 1 ]; then
        assert_contains "the link is named as unreadable" "alink' could not be examined" "$out" || return 1
        assert_contains "and not booked as churn" "vanished=0" "$out" || return 1
    else
        # This find cannot enumerate an entry it cannot stat, so the link never reaches the
        # upload pass at all; the unreadable directory carries the loss instead.
        assert_contains "the directory carries the loss" "could be listed but not searched" "$out" || return 1
    fi
    assert_eq "the run is partial, not churn-only" "4" "$rc" || return 1
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}

# A symlink inside a proven cloud-storage folder must not be enumerated: the prune applies to the
# whole discovery expression, symlink arm included.
test_symlink_respects_cloud_prunes() {
    restart_stub
    local d; d="$(create_sample_dir link_prune)"
    mkdir -p "$d/Dropbox"
    : > "$d/Dropbox/.dropbox.cache"
    create_file "$d/Dropbox/inside.txt" "secret"
    ln -s "$d/outside.txt" "$d/Dropbox/alink"
    create_file "$d/outside.txt" "fine"

    local out; out="$(run_collector --dry-run --dir "$d" --max-size 0 --max-age 0)"
    assert_contains "the cloud folder is pruned" "Excluding cloud storage folder" "$out" || return 1
    assert_eq "the pruned symlink is not enumerated" "0" "$(parse_collector_stat "$out" links_seen)" || return 1
    assert_not_contains "nor its contents" "inside.txt" "$out" || return 1
}

# The attribution probes must not run on a clean root — the zero-cost claim.
test_clean_run_runs_no_attribution_probe() {
    restart_stub
    local d; d="$(create_sample_dir clean_probe)"
    create_file "$d/a.txt" "x"
    local out; out="$(run_collector --dry-run --dir "$d" --max-size 0 --max-age 0 --debug)"
    assert_eq "nothing unreadable" "0" "$(parse_collector_stat "$out" unreadable_dirs)" || return 1
    assert_eq "nothing unstatable" "0" "$(parse_collector_stat "$out" unstatable)" || return 1
    # The counters would read zero whether or not the probe ran, so assert on the probe's own
    # debug line: without it a collector that probed every root would still pass this test.
    assert_not_contains "the attribution probe did not run" "Attributing walk errors" "$out" || return 1
}

# walk_excludes is built per root and includes the prunes for overlapping child roots. A symlink
# inside a pruned child must not be enumerated by the parent's walk. (This and its sibling below
# were written when discovery was split into two walks; discovery is one walk again, so they no
# longer guard against a prune set diverging BETWEEN walks — they still pin that the single
# walk's prune set covers symlinks, which is what they actually test.)
test_symlink_respects_child_prunes() {
    restart_stub
    local parent; parent="$(create_sample_dir link_child_prune)"
    mkdir -p "$parent/child"
    create_file "$parent/child/target.txt" "x"
    ln -s "$parent/child/target.txt" "$parent/child/alink"

    # Naming both parent and child means the child is pruned from the parent's walk.
    local out; out="$(run_collector --dry-run --dir "$parent" --dir "$parent/child" --follow-symlinks --max-size 0 --max-age 0)"
    assert_eq "the symlink is enumerated exactly once" "1" "$(parse_collector_stat "$out" links_seen)" || return 1
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}



# The discriminator must not OVER-reach: a file genuinely deleted between discovery and upload is
# still churn (vanished, exit 5), not a permission failure. Without this guard the fix for the
# inaccessible case could quietly reclassify every churn event as a real loss, inverting the
# rsync 23-vs-24 distinction the exit taxonomy is built on.
test_genuine_churn_is_still_vanished() {
    local d; d="$(create_sample_dir churn_guard)"
    create_file_bytes "$d/aaa.bin" 100
    create_file_bytes "$d/zzz.bin" 100
    local fakebin; fakebin="$(create_fake_tool_path churn_guard)"
    # A curl shim that deletes the not-yet-uploaded sibling on its first sample POST: a real
    # churn event, at exactly the moment the collector is walking its own discovery list.
    rm -f "$fakebin/curl"
    cat > "$fakebin/curl" <<EOF
#!/bin/sh
hdr=""; outfile=""; endpoint=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -D) hdr="\$2"; shift 2 ;;
        -o) outfile="\$2"; shift 2 ;;
        -F|-H|-d|--max-time|--connect-timeout|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$endpoint" in
    */api/collection)
        [ -n "\$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        ;;
    *)
        # First sample POST only, and BOTH candidates go: whichever file is mid-upload is
        # already streaming, so exactly one not-yet-uploaded file vanishes — in either readdir
        # order. Deleting only zzz.bin made the test depend on aaa.bin uploading first.
        if [ ! -e "$fakebin/.hit" ]; then
            : > "$fakebin/.hit"
            rm -f "$d/aaa.bin" "$d/zzz.bin"
        fi
        [ -n "\$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && printf '{"id":1}' > "\$outfile"
        ;;
esac
exit 0
EOF
    chmod +x "$fakebin/curl"

    local out rc
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" --server 127.0.0.1 --port 8080 \
        --no-log-file --no-progress --dir "$d" --max-size 0 --max-age 0 2>&1)"
    rc=$?
    set -e

    assert_contains "the lost file is churn, not a permission failure" "vanished=1" "$out" || return 1
    assert_contains "and not counted as unreadable" "unreadable=0" "$out" || return 1
    assert_eq "churn-only run exits 5, not 4" "5" "$rc" || return 1
}

# Under nohup the signal arrives already ignored and cannot be trapped. That must be benign: the
# run completes and sends a normal END marker, never an interrupted one.
test_untrappable_hup_lets_the_run_finish() {
    has_stub_verification || return 77
    restart_stub
    local d; d="$(create_sample_dir hup_ignored)"
    local i
    for i in $(seq 1 30); do create_file_bytes "$d/f$i.bin" 64; done
    local slow; slow="$(make_slow_curl_path hup_ignored)" || return 77

    # 'exec' so the backgrounded PID IS the collector, with HUP already SIG_IGN through the
    # exec. The first spelling of this test killed the ignoring SUBSHELL after a fixed sleep:
    # the collector never received any signal (verified), the run was usually over anyway, and
    # '|| true' ate the evidence — a test that could not fail.
    local rc
    set +e
    ( trap '' HUP
      exec env PATH="$slow:$PATH" bash "$COLLECTOR" --server "$(server_host)" --port "$STUB_PORT" \
          --no-log-file --no-progress --dir "$d" --max-size 0 --max-age 0 >/dev/null 2>&1 ) &
    local pid=$!
    local seen
    for i in $(seq 1 200); do
        seen="$(grep -c 'THOR finding' "$AUDIT_LOG" 2>/dev/null)" || seen=0
        [ "${seen:-0}" -ge 1 ] && break
        sleep 0.05
    done
    kill -HUP "$pid" 2>/dev/null
    local delivered=$?
    bounded_wait "$pid" 600 || { echo "FAIL: the run hung after an ignored HUP" >&2; return 1; }
    rc=$BOUNDED_WAIT_RC
    set -e

    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_eq "HUP was delivered to the live collector" "0" "$delivered" || return 1
    assert_eq "the run finished normally" "0" "$rc" || return 1
    assert_marker_sent "an end marker was sent" end "$audit" || return 1
    assert_marker_absent "and no interrupted marker" interrupted "$audit" || return 1
}


# The discriminator must not treat every failed stat as a permission problem. '[ -r ]'/'[ -x ]'
# answer false for a parent that no longer EXISTS exactly as for one that cannot be searched, so
# three ordinary churn events were reported as permission failures — with a sentence claiming the
# directory "is not searchable" when it was gone, replaced by a file, or a dangling symlink.
test_discriminator_calls_churn_churn() {
    local probe="$TEST_TMP/disc-probe.sh"
    local base="$TEST_TMP/disc"
    rm -rf "$base"; mkdir -p "$base"
    printf 'x' > "$base/notdir"
    ln -sfn "$base/missing" "$base/danglink"
    mkdir -p "$base/gone"; : > "$base/gone/f.bin"; rm -rf "$base/gone"

    cat > "$probe" <<EOF
eval "\$(sed '/^main "\\\$@"/,\$d' "$COLLECTOR")"
entry_stat_denied "$base/gone/f.bin"     && echo gone_PERM     || echo gone_churn
entry_stat_denied "$base/notdir/f.bin"   && echo notdir_PERM   || echo notdir_churn
entry_stat_denied "$base/danglink/f.bin" && echo dangling_PERM || echo dangling_churn
entry_stat_denied "$base/never-existed"  && echo missing_PERM  || echo missing_churn
EOF
    local out; out="$(bash "$probe" 2>&1)"
    assert_contains "a removed parent directory is churn" "gone_churn" "$out" || return 1
    assert_contains "a parent replaced by a file is churn" "notdir_churn" "$out" || return 1
    assert_contains "a dangling symlink parent is churn" "dangling_churn" "$out" || return 1
    assert_contains "a plainly deleted file is churn" "missing_churn" "$out" || return 1
}

# A path is attacker-controlled content. Any line echoing one must come BEFORE the summary, or a
# directory named "... unreadable_dirs=0" makes a scraper taking the last match read the planted
# number and believe the host was fully covered.
test_paths_cannot_forge_summary_counters() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base="/tmp/ts-inject-$$"
    rm -rf "$base"; mkdir -p "$base/evil unreadable_dirs=0" "$base/tmp"
    head -c 100 /dev/zero > "$base/evil unreadable_dirs=0/f.bin"
    head -c 100 /dev/zero > "$base/ok.bin"
    chmod -R a+rX "$base"; chmod 0777 "$base/tmp"; chmod 0444 "$base/evil unreadable_dirs=0"
    assert_fixture_denies "$base/evil unreadable_dirs=0" x "$pre" || return 1

    local out; out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file \
        --no-progress --dir "$base" --max-size 2 --max-age 0 2>&1)"
    chmod 0755 "$base/evil unreadable_dirs=0" 2>/dev/null || true
    rm -rf "$base"

    # The property has two halves: the forged path IS printed (else the test proves nothing)
    # and the scraper's last match is still the real counter, because every path-bearing line
    # is emitted before the summary.
    assert_contains "the forged path itself is printed" "evil unreadable_dirs=0" "$out" || return 1
    # parse_collector_stat is exactly what a scraper does: last match wins.
    assert_eq "the real count survives a forged one in a path" "1" "$(parse_collector_stat "$out" unreadable_dirs)" || return 1
}


# Bash can LOSE a signal whose trap action it fails to parse while expanding a command
# substitution (measured: 1 lost SIGHUP in 60 on 5.2.15). on_signal then never runs. The EXIT
# trap still runs, so the run must still tell the server it stopped. Driven here with SIGUSR1,
# which the collector deliberately does not trap — the same end state as a swallowed signal,
# reached deterministically.
test_lost_signal_still_reports_to_the_server() {
    has_stub_verification || return 77
    restart_stub
    local d; d="$(create_sample_dir lost_signal)"
    local i
    for i in $(seq 1 400); do create_file_bytes "$d/f$i.bin" 512; done
    local wt="$TEST_TMP/work_lost"; rm -rf "$wt"; mkdir -p "$wt"

    set -m
    env TMPDIR="$wt" bash "$COLLECTOR" --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --no-progress --dir "$d" --max-size 2000 --max-age 0 >/dev/null 2>&1 &
    local pid=$!
    set +m
    local seen
    for i in $(seq 1 200); do
        seen="$(grep -c 'THOR finding' "$AUDIT_LOG" 2>/dev/null)" || seen=0
        [ "${seen:-0}" -ge 1 ] && break
        sleep 0.05
    done
    kill -USR1 "$pid" 2>/dev/null || true
    set +e
    wait "$pid"
    local rc=$?
    set -e
    [ "$rc" -ne 0 ] || { printf 'FAIL: the run completed before the signal landed (test setup)\n' >&2; return 1; }

    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_marker_sent "the exit trap still sent an interrupted marker" interrupted "$audit" || return 1
    assert_contains "and admits the signal is unknown" '"interrupted_by":"unknown"' "$audit" || return 1
    assert_eq "the work directory was still removed" "0" "$(find "$wt" -maxdepth 1 -name 'thunderstorm.work.*' 2>/dev/null | wc -l | tr -d ' ')" || return 1
}

# Denial one level ABOVE the entry must still be a permission failure, not churn. The earlier
# '[ -d parent ]' guard answered false here and booked files that are still on disk as vanished
# (exit 5, "nothing anyone did wrong").
test_denial_above_the_parent_is_not_churn() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base="/tmp/ts-h3-$$"
    # The probe lives in the fixture, not in TEST_TMP: mktemp -d is 0700 and owned by the
    # invoking user, so the unprivileged user cannot even read a script placed there.
    local probe="$base/h3probe.sh"
    rm -rf "$base"; mkdir -p "$base/denied/sub"
    : > "$base/denied/sub/f.bin"
    mkdir -p "$base/gone"; : > "$base/gone/f.bin"; rm -rf "$base/gone"
    cat > "$probe" <<EOF
eval "\$(sed '/^main "\\\$@"/,\$d' "$COLLECTOR")"
entry_stat_denied "$base/denied/sub/f.bin" && echo grandparent_DENIED || echo grandparent_churn
entry_stat_denied "$base/denied/f.bin"     && echo parent_DENIED      || echo parent_churn
entry_stat_denied "$base/gone/f.bin"       && echo removed_DENIED     || echo removed_churn
EOF
    chmod -R a+rX "$base"; chmod 0444 "$base/denied"
    assert_fixture_denies "$base/denied" x "$pre" || return 1
    local out; out="$($pre bash "$probe" 2>&1)"
    chmod 0755 "$base/denied" 2>/dev/null || true; rm -rf "$base"

    assert_contains "denial at the grandparent is a permission failure" "grandparent_DENIED" "$out" || return 1
    assert_contains "denial at the parent likewise" "parent_DENIED" "$out" || return 1
    assert_contains "but a removed subtree is still churn" "removed_churn" "$out" || return 1
}

# A symlink under an unsearchable directory is NOT in links_seen — that counter comes from
# '[ -h ]', which is exactly the lstat the directory refuses — so it is carried as a regular
# entry and booked once, in failed=/unreadable=. Counting it in unstatable= as well would book
# one object under two counters that mean different things.
test_unstatable_does_not_double_count_symlinks() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base="/tmp/ts-h2-$$"
    rm -rf "$base"; mkdir -p "$base/unsearchable" "$base/tmp"
    local i
    for i in 1 2 3; do head -c 100 /dev/zero > "$base/unsearchable/f$i.bin"; done
    head -c 100 /dev/zero > "$base/target.bin"
    ln -s "$base/target.bin" "$base/unsearchable/alink"
    chmod -R a+rX "$base"; chmod 0777 "$base/tmp"; chmod 0444 "$base/unsearchable"
    assert_fixture_denies "$base/unsearchable" x "$pre" || return 1

    local _sees=0
    find_lists_unstatable_entries "$base/unsearchable" "$pre" && _sees=1
    local out; out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file \
        --no-progress --dir "$base" --max-size 2 --max-age 0 2>&1)"
    chmod 0755 "$base/unsearchable" 2>/dev/null || true; rm -rf "$base"

    if [ "$_sees" -eq 1 ]; then
        # Three regular files are hidden and counted. The symlink is NOT among them: it is
        # enumerated by the walk and accounted in the upload pass as an unreadable entry, so
        # counting it here too would book one object under two counters that mean different
        # things.
        assert_eq "only the hidden regular files are counted" "3" "$(parse_collector_stat "$out" unstatable)" || return 1
        assert_contains "the symlink is accounted once, as a failure" "alink' could not be examined" "$out" || return 1
    fi
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}

# Ordinary churn must never be reported as a loss. A previous revision verified the two
# discovery walks against a third count of the same tree; because the three counts were taken at
# three different instants, files merely CREATED during the scan were reported as "entries lost
# to a type change" and forced exit 4 (measured: 14 false losses on a tree gaining 400 files).
# Discovery is a single walk again, so creation and deletion during it are invisible to the
# inventory, which is the honest outcome — a snapshot is a snapshot.
test_churn_during_discovery_is_not_reported_as_loss() {
    restart_stub
    local d; d="$(create_sample_dir churn_discovery)"
    local i
    for i in $(seq 1 400); do create_file_bytes "$d/f$i.bin" 64; done

    # Create files continuously while the scan runs.
    ( for i in $(seq 1 200); do : > "$d/new$i.bin"; sleep 0.005; done ) &
    local churn=$!
    local out rc
    set +e
    out="$(run_collector --dry-run --dir "$d" --max-size 0 --max-age 0)"
    rc=$?
    set -e
    wait "$churn" 2>/dev/null || true

    # Real output only: the first spelling asserted the absence of strings that exist nowhere
    # in the collector ("changed type" lives in comments; the other needle nowhere) — two
    # assertions that could never fail.
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
    assert_not_contains "no unattributed walk error" "could not be attributed" "$out" || return 1
    assert_eq "nothing counted as failed" "0" "$(parse_collector_stat "$out" failed)" || return 1
    assert_eq "a run that only gained files is clean" "0" "$rc" || return 1
}


# A run that COMPLETES — even as a partial failure — must announce its end and nothing else.
# RUN_FINISHED is what stands the exit-trap backstop down; get that ordering wrong and every
# non-root partial collection reports itself to the server as an interrupted scan.
test_completed_partial_run_sends_end_not_interrupted() {
    has_stub_verification || return 77
    restart_stub
    local d; d="$(create_sample_dir partial_end)"
    create_file "$d/ok.txt" "content"

    local rc
    set +e
    run_collector --dir "$d" --dir "$TEST_TMP/absent-dir-$$" --max-size 0 --max-age 0 >/dev/null 2>&1
    rc=$?
    set -e

    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_eq "a named missing target is a partial run" "4" "$rc" || return 1
    assert_marker_sent "the run announced its end" end "$audit" || return 1
    assert_marker_absent "and never called itself interrupted" interrupted "$audit" || return 1
    assert_not_contains "interrupted_by stays off a normal end marker" '"interrupted_by"' "$audit" || return 1
}

# The end marker must carry the attribution counters — build_stats_json exists because a field
# was once added to one marker copy and not the other, and these are the newest fields.
test_end_marker_carries_attribution_counters() {
    has_stub_verification || return 77
    local pre; pre="$(drop_privs_prefix)" || return 77
    restart_stub
    local base; base="$(make_denied_fixture marker "$pre")" || return 1
    find_lists_unstatable_entries "$base/unsearchable" "$pre" || { cleanup_denied_fixture "$base"; return 77; }

    $pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --server "$(server_host)" --port "$STUB_PORT" \
        --no-log-file --no-progress --dir "$base" --max-size 2 --max-age 0 >/dev/null 2>&1 || true
    cleanup_denied_fixture "$base"

    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_contains "unreadable_dirs on the wire" '"unreadable_dirs":2' "$audit" || return 1
    assert_contains "unstatable on the wire" '"unstatable":4' "$audit" || return 1
    assert_contains "walk_errors_unexplained on the wire" '"walk_errors_unexplained":0' "$audit" || return 1
}

# A walk error nothing in the tree can explain must be reported as exactly that — not converted
# into an invented "1 directory could not be read". Driven with a find that fails the discovery
# walk on a healthy tree, which is what a path vanishing mid-walk looks like afterwards.
test_unexplained_walk_error_is_reported_not_invented() {
    local d; d="$(create_sample_dir unexplained)"
    create_file "$d/a.txt" "x"
    local shim="$TEST_TMP/failwalk-bin" real
    real="$(type -P find)" || return 77
    mkdir -p "$shim"
    rm -f "$shim/find"
    {
        printf '#!/usr/bin/env bash\n'
        # Only the discovery walk carries the '-o -type l' arm; every other walk runs untouched.
        printf 'case " $* " in *" -type l "*) %s "$@"; exit 1 ;; esac\n' "$real"
        printf 'exec %s "$@"\n' "$real"
    } > "$shim/find"
    chmod +x "$shim/find"

    local out rc
    set +e
    out="$(env PATH="$shim:$PATH" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --server 127.0.0.1 --port 8080 --dir "$d" --max-size 2000 --max-age 0 2>&1)"
    rc=$?
    set -e

    assert_contains "the error is named unattributable" "could not be attributed" "$out" || return 1
    assert_eq "no directory count is invented" "0" "$(parse_collector_stat "$out" unreadable_dirs)" || return 1
    assert_eq "no entry count is invented" "0" "$(parse_collector_stat "$out" unstatable)" || return 1
    assert_eq "the run is still partial" "4" "$rc" || return 1
}

# --follow-symlinks onto a target inside an unsearchable directory: lost evidence, so a named
# unreadable failure and exit 4 — not the old debug-level "dangling" skip with exit 0.
test_denied_symlink_target_is_a_named_failure() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base="/tmp/ts-denied-target-$$"
    rm -rf "$base"; mkdir -p "$base/real" "$base/scan" "$base/tmp"
    head -c 64 /dev/zero > "$base/real/target.bin"
    ln -s "$base/real/target.bin" "$base/scan/alink"
    chmod -R a+rX "$base"; chmod 0777 "$base/tmp"; chmod 0444 "$base/real"
    assert_fixture_denies "$base/real" x "$pre" || return 1

    local out rc
    set +e
    out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --follow-symlinks --dir "$base/scan" --max-size 0 --max-age 0 2>&1)"
    rc=$?
    set -e
    chmod 0755 "$base/real" 2>/dev/null || true
    rm -rf "$base"

    assert_contains "the refusal is named" "could not be examined" "$out" || return 1
    assert_eq "booked as unreadable" "1" "$(parse_collector_stat "$out" failed)" || return 1
    assert_eq "not as vanished churn" "0" "$(parse_collector_stat "$out" vanished)" || return 1
    assert_not_contains "and never called dangling" "dangling or special target" "$out" || return 1
    assert_eq "lost evidence is a partial run" "4" "$rc" || return 1
}

# dir_searchable tests search permission ONLY. A mode-0111 directory (searchable, not listable —
# anything a user can chmod their own directory to) whose file genuinely vanished must be churn:
# requiring -r as well booked that loss as a permission failure.
test_vanish_under_searchable_unlistable_dir_is_churn() {
    local d; d="$(create_sample_dir churn0111)"
    mkdir -p "$d/sub"
    create_file_bytes "$d/sub/aaa.bin" 64
    create_file_bytes "$d/sub/zzz.bin" 64
    local fakebin; fakebin="$(create_fake_tool_path churn0111)"
    rm -f "$fakebin/curl"
    cat > "$fakebin/curl" <<EOF
#!/bin/sh
hdr=""; outfile=""; endpoint=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -D) hdr="\$2"; shift 2 ;;
        -o) outfile="\$2"; shift 2 ;;
        -F|-H|-d|--max-time|--connect-timeout|--cacert) shift 2 ;;
        -sS|--show-error|-X|-k) shift ;;
        http://*|https://*) endpoint="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$endpoint" in
    */api/collection)
        [ -n "\$hdr" ] && printf 'HTTP/1.1 204 No Content\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && : > "\$outfile"
        ;;
    *)
        if [ ! -e "$fakebin/.hit" ]; then
            : > "$fakebin/.hit"
            rm -f "$d/sub/aaa.bin" "$d/sub/zzz.bin"
            # 0111: no r bit for anyone, so it is unlistable for the owner too and needs no
            # assert_fixture_denies. It could not have one anyway — this fires inside the shim,
            # mid-collection, and the mutation IS the thing under test.
            chmod 0111 "$d/sub"
        fi
        [ -n "\$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$hdr"
        [ -n "\$outfile" ] && printf '{"id":1}' > "\$outfile"
        ;;
esac
exit 0
EOF
    chmod +x "$fakebin/curl"

    local out rc
    set +e
    out="$(env PATH="$fakebin" bash "$COLLECTOR" --server 127.0.0.1 --port 8080 \
        --no-log-file --no-progress --dir "$d" --max-size 0 --max-age 0 2>&1)"
    rc=$?
    set -e
    chmod 0755 "$d/sub" 2>/dev/null || true

    assert_contains "the loss under 0111 is churn" "vanished=1" "$out" || return 1
    assert_contains "not a permission failure" "unreadable=0" "$out" || return 1
    assert_eq "churn-only run exits 5" "5" "$rc" || return 1
}

# The busybox arm of the attribution engine, driven by the real busybox find: it stats
# unconditionally, cannot list what it cannot stat, and the run must say "unmeasured" instead of
# printing a bare zero — while still counting the directories and staying a partial run.
test_busybox_find_reports_unstatable_as_unmeasured() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    command -v busybox >/dev/null 2>&1 || return 77
    busybox find /dev/null >/dev/null 2>&1 || return 77
    # In /tmp so the priv-dropped collector can traverse to it; a shim script of its own, never
    # a create_fake_tool_path entry (those are symlinks to the real binaries).
    local bb="/tmp/ts-bbbin-$$" real
    real="$(command -v busybox)"
    rm -rf "$bb"; mkdir -p "$bb"
    {
        printf '#!/bin/sh\n'
        printf 'exec %s find "$@"\n' "$real"
    } > "$bb/find"
    chmod 0755 "$bb" "$bb/find"

    local base; base="$(make_denied_fixture bbarm "$pre")" || return 1
    local out rc
    set +e
    out="$($pre env PATH="$bb:$PATH" TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file \
        --no-progress --dir "$base" --max-size 2 --max-age 0 2>&1)"
    rc=$?
    set -e
    cleanup_denied_fixture "$base"
    rm -rf "$bb"

    assert_contains "the zero is declared unmeasured" "unmeasured rather than a statement" "$out" || return 1
    assert_eq "unstatable stays an honest zero" "0" "$(parse_collector_stat "$out" unstatable)" || return 1
    assert_eq "the directories are still counted" "2" "$(parse_collector_stat "$out" unreadable_dirs)" || return 1
    assert_eq "and the run is still partial" "4" "$rc" || return 1
}

# With both gates off the walk needs no stat, so the hidden files are enumerated and booked
# individually as unreadable — but a SUBDIRECTORY in that position reaches no counter, so
# unstatable=0 must say WHY it is not a measured zero. Reachable only when the walk fails for
# another reason (an unlistable directory) while the gates are off.
test_gates_off_declares_unstatable_unmeasured() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base="/tmp/ts-gatesoff-$$"
    rm -rf "$base"; mkdir -p "$base/tmp" "$base/r/unlist" "$base/r/unsearch"
    head -c 50 /dev/zero > "$base/r/unlist/a.bin"
    head -c 50 /dev/zero > "$base/r/unsearch/b.bin"
    head -c 50 /dev/zero > "$base/r/ok.bin"
    chmod 0777 "$base/tmp"; chmod -R a+rX "$base/r"
    # 0300 not 0700: the denial has to apply to the owner too — see make_denied_fixture. This
    # test needs the walk to FAIL for a second reason (an unlistable directory) while both gates
    # are off, and a 0700 directory its own owner can read denies nothing, so on a non-root
    # runner the walk succeeded and the message under test was never reached.
    chmod 0300 "$base/r/unlist"; chmod 0444 "$base/r/unsearch"
    assert_fixture_denies "$base/r/unlist"   r "$pre" || return 1
    assert_fixture_denies "$base/r/unsearch" x "$pre" || return 1

    local out rc
    set +e
    out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file --no-progress \
        --server 127.0.0.1 --port 8080 --dir "$base/r" --max-size 0 --max-age 0 2>&1)"
    rc=$?
    set -e
    chmod 0755 "$base/r/unlist" "$base/r/unsearch" 2>/dev/null || true
    rm -rf "$base"

    assert_contains "the zero names the configuration as its reason" "both discovery gates are off" "$out" || return 1
    assert_eq "and stays an unmeasured zero" "0" "$(parse_collector_stat "$out" unstatable)" || return 1
    assert_eq "both directories still counted" "2" "$(parse_collector_stat "$out" unreadable_dirs)" || return 1
    assert_eq "the hidden file is booked as a failure" "1" "$(parse_collector_stat "$out" failed)" || return 1
    assert_eq "lost evidence is a partial run" "4" "$rc" || return 1
}

# Per-root evidence must belong to the root that reports it. ATTR_FIRST_ENTRY_OUT is reset with
# the rest of the per-root ATTR_* set; when it was omitted from that reset it stayed sticky, so
# every failing root after the first named an EARLIER root's file as its own example — which is
# exactly the defect the per-root value was introduced to fix.
test_per_root_evidence_names_its_own_root() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base="/tmp/ts-tworoot-$$"
    rm -rf "$base"; mkdir -p "$base/tmp" "$base/A/denied" "$base/B/denied"
    local i
    for i in 1 2; do head -c 100 /dev/zero > "$base/A/denied/aaa$i.bin"; done
    for i in 1 2; do head -c 100 /dev/zero > "$base/B/denied/bbb$i.bin"; done
    head -c 100 /dev/zero > "$base/A/ok.bin"; head -c 100 /dev/zero > "$base/B/ok.bin"
    chmod -R a+rX "$base"; chmod 0777 "$base/tmp"
    chmod 0444 "$base/A/denied" "$base/B/denied"
    assert_fixture_denies "$base/A/denied" x "$pre" || return 1
    assert_fixture_denies "$base/B/denied" x "$pre" || return 1

    local _sees=0
    find_lists_unstatable_entries "$base/A/denied" "$pre" && _sees=1
    local out; out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file \
        --no-progress --dir "$base/A" --dir "$base/B" --max-size 2 --max-age 0 2>&1)"
    chmod 0755 "$base/A/denied" "$base/B/denied" 2>/dev/null || true; rm -rf "$base"

    if [ "$_sees" -eq 1 ]; then
        # The B root's own line must name a bbb* path, never one of A's aaa* files.
        local bline; bline="$(printf '%s\n' "$out" | grep "entry(ies) inside them" | tail -1)"
        assert_contains "the second root names its own evidence" "bbb" "$bline" || return 1
        assert_not_contains "and not the first root's" "aaa" "$bline" || return 1
    fi
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}

# A category matched by NEGATION counts entries whose stat was REFUSED, not just entries outside
# the category. With --max-size 0 the age arm was '-type f ! <age test>', so every file hidden by
# an unsearchable directory satisfied it and was reported as "outside the age window" — a false
# statement about files whose age was never read. The arm now requires the size to be readable
# first, which is the same guard the size category gets by matching positively.
test_age_filter_does_not_count_unreadable_files() {
    local pre; pre="$(drop_privs_prefix)" || return 77
    local base="/tmp/ts-agedenied-$$"
    rm -rf "$base"; mkdir -p "$base/tmp" "$base/denied"
    local i
    for i in 1 2 3 4; do head -c 100 /dev/zero > "$base/denied/f$i.bin"; done
    head -c 100 /dev/zero > "$base/fresh.bin"
    chmod -R a+rX "$base"; chmod 0777 "$base/tmp"; chmod 0444 "$base/denied"
    assert_fixture_denies "$base/denied" x "$pre" || return 1

    local _sees=0
    find_lists_unstatable_entries "$base/denied" "$pre" && _sees=1
    # Size gate OFF so the age arm is the only qualifier; age gate ON so it actually runs.
    local out; out="$($pre env TMPDIR="$base/tmp" bash "$COLLECTOR" --dry-run --no-log-file \
        --no-progress --dir "$base" --max-size 0 --max-age 3650 2>&1)"
    chmod 0755 "$base/denied" 2>/dev/null || true; rm -rf "$base"

    if [ "$_sees" -eq 1 ]; then
        assert_eq "files whose age could not be read are not 'outside the age window'" "0" \
            "$(parse_collector_stat "$out" age_filtered)" || return 1
    fi
    assert_not_contains "no reconciliation failure" "Reconciliation failed" "$out" || return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# RUN
# ══════════════════════════════════════════════════════════════════════════════

printf "\n${BOLD}Thunderstorm Bash Collector — Test Suite${RESET}\n"
printf "  Collector: %s\n" "$COLLECTOR"
if [ "$USE_EXTERNAL" -eq 1 ]; then
    printf "  Server:    %s:%s (external)\n" "$EXTERNAL_SERVER" "$EXTERNAL_PORT"
    printf "  Note:      stub-verification tests will be skipped\n\n"
else
    printf "  Stub:      %s\n\n" "$STUB_BIN"
fi

setup_tmp

# Before any assertion runs: confirm this stub records markers the way audit_has_marker says it
# does. A stub that logs the collector's request body verbatim makes every marker test pass for
# the wrong reason, which is how the suite came to be green here and red in CI.
if [ "$USE_EXTERNAL" -eq 0 ]; then
    restart_stub && verify_stub_contract || exit 1
    stop_stub
fi

# Validation tests (no server needed)
run_test test_help_flag
run_test test_invalid_port_rejected
run_test test_invalid_max_age_rejected
run_test test_invalid_max_size_rejected
run_test test_missing_server_rejected
run_test test_unknown_option_rejected

# Functional tests (need stub server)
run_test test_basic_async_upload
run_test test_basic_sync_upload
run_test test_dry_run_no_uploads
run_test test_max_file_size_filter
run_test test_max_age_filter
run_test test_multiple_directories
run_test test_nonexistent_directory_fails
run_test test_cloud_exclusion_by_proof
run_test test_source_parameter_received
run_test test_file_content_integrity
run_test test_filename_with_spaces
run_test test_filename_special_chars
run_test test_empty_directory
run_test test_nested_directories
run_test test_symlinks_not_followed
run_test test_log_file_written
run_test test_source_url_encoding
run_test test_retries_on_connection_failure
run_test test_full_path_sent_as_filename
run_test test_zero_byte_file
run_test test_max_age_zero_includes_all
run_test test_max_age_cli_override_applied
run_test test_positional_directory_args
run_test test_max_age_boundary_is_exclusive
run_test test_max_age_leading_zero_is_decimal
run_test test_no_count_filtered_reports_unmeasured
run_test test_future_timestamp_collected_and_counted
run_test test_age_ctime_only_reported
run_test test_age_timestamp_ctime_arm
run_test test_age_and_size_attribution_disjoint
run_test test_age_counters_sum_across_roots
run_test test_age_policy_applies_to_symlink_targets
run_test test_age_counting_paths_agree
run_test test_age_counting_failure_is_not_called_churn
run_test test_age_static_tree_is_not_a_snapshot
run_test test_max_age_value_validation
run_test test_begin_marker_failure_is_fatal
run_test test_wget_collection_marker_404_nonfatal
run_test test_redirect_upload_rejected

# --max-size
run_test test_max_size_boundary_is_inclusive
run_test test_max_size_legacy_flag_name_still_works
run_test test_max_size_zero_byte_file_always_collected
run_test test_max_size_zero_disables_filter
run_test test_max_size_zero_does_not_inflate_size_filtered
run_test test_max_size_leading_zero_is_decimal
run_test test_max_size_value_validation
run_test test_max_size_policy_line_states_boundary
run_test test_max_size_policy_applies_to_symlink_targets
run_test test_max_size_reported_in_marker_stats
run_test test_symlink_filtered_attribution_splits_size_from_age
run_test test_size_counters_sum_across_roots
run_test test_size_filtered_excludes_unsizeable_files
run_test test_no_count_filtered_with_size_gate
run_test test_max_size_errors_name_the_spelling_used
run_test test_size_bound_bytes_in_marker_stats
run_test test_help_documents_max_size_and_alias
run_test test_cutoff_midtransfer_points_at_max_size
run_test test_oversize_rejection_is_not_retried
run_test test_server_error_is_still_retried
run_test test_interrupted_marker_carries_policy
run_test test_summary_names_only_active_gates
run_test test_transient_status_still_retried
run_test test_wget_vanished_file_is_not_reported_collected
run_test test_wget_boundary_guard_reads_the_file

# Signals, walk-error attribution, inaccessible-vs-vanished
run_test test_signals_end_the_run_cleanly
run_test test_help_documents_the_interrupt_exit_codes
run_test test_unreadable_dirs_counts_directories_not_diagnostics
run_test test_unstatable_entries_are_counted_and_named
run_test test_inaccessible_files_are_unreadable_not_vanished
run_test test_symlink_under_unsearchable_dir_is_a_named_failure
run_test test_symlink_respects_cloud_prunes
run_test test_symlink_respects_child_prunes
run_test test_clean_run_runs_no_attribution_probe
run_test test_genuine_churn_is_still_vanished
run_test test_discriminator_calls_churn_churn
run_test test_paths_cannot_forge_summary_counters
run_test test_untrappable_hup_lets_the_run_finish
run_test test_completed_partial_run_sends_end_not_interrupted
run_test test_end_marker_carries_attribution_counters
run_test test_unexplained_walk_error_is_reported_not_invented
run_test test_denied_symlink_target_is_a_named_failure
run_test test_vanish_under_searchable_unlistable_dir_is_churn
run_test test_busybox_find_reports_unstatable_as_unmeasured
run_test test_gates_off_declares_unstatable_unmeasured
run_test test_lost_signal_still_reports_to_the_server
run_test test_denial_above_the_parent_is_not_churn
run_test test_per_root_evidence_names_its_own_root
run_test test_age_filter_does_not_count_unreadable_files
run_test test_unstatable_does_not_double_count_symlinks
run_test test_churn_during_discovery_is_not_reported_as_loss

# Summary
printf "\n${BOLD}Results:${RESET} %d/%d passed" "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_SKIPPED" -gt 0 ] && printf ", ${YELLOW}%d skipped${RESET}" "$TESTS_SKIPPED"
if [ "$TESTS_FAILED" -gt 0 ]; then
    printf ", ${RED}%d failed${RESET}\n" "$TESTS_FAILED"
    printf "\n${RED}Failed tests:${RESET}\n"
    printf "$FAILED_NAMES"
    exit 1
else
    printf " ${GREEN}✓${RESET}\n\n"
    exit 0
fi
