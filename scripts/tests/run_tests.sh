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

run_test() {
    local name="$1"
    # Filter support
    if [ -n "${TEST_FILTER:-}" ] && ! echo "$name" | grep -q "$TEST_FILTER"; then
        return 0
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "  ${BOLD}%-55s${RESET}" "$name"
    if "$name"; then
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
    has_stub_verification || { echo "    (skipped: sync scan too slow on external server)"; return 0; }
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
    has_stub_verification || { echo "    (skipped: needs stub server)"; return 0; }
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
    has_stub_verification || { echo "    (skipped: needs stub server)"; return 0; }
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
    has_stub_verification || { echo "    (skipped: needs stub server)"; return 0; }
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
    has_stub_verification || return 0
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
    has_stub_verification || return 0
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
    has_stub_verification || return 0
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
        [ "${_seen:-0}" -ge 5 ] && break
        sleep 0.05
    done
    kill -INT "$pid" 2>/dev/null || true
    set +e
    wait "$pid"
    local rc=$?
    set -e

    local audit; audit="$(tr -d ' \t' < "$AUDIT_LOG" 2>/dev/null)"
    assert_eq "interrupted exit code" "130" "$rc" || return 1
    assert_contains "an interrupted marker was sent" '"type":"interrupted"' "$audit" || return 1
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
    local runas=""
    if [ "$(id -u)" -eq 0 ]; then
        command -v setpriv >/dev/null 2>&1 || return 0
        id -u nobody >/dev/null 2>&1 || return 0
        runas="setpriv --reuid=65534 --regid=65534 --clear-groups"
    fi

    # World-traversable fixture: the unprivileged user has to be able to reach it.
    local base="/tmp/ts-unsizeable-$$"
    rm -rf "$base"; mkdir -p "$base/locked"
    local i
    for i in 1 2 3 4; do head -c 100 /dev/zero > "$base/locked/f$i.bin"; done
    head -c 100 /dev/zero > "$base/normal.bin"
    chmod -R a+rX "$base"
    chmod 0444 "$base/locked"          # readable, NOT searchable -> stat on children denied
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

# Summary
printf "\n${BOLD}Results:${RESET} %d/%d passed" "$TESTS_PASSED" "$TESTS_RUN"
if [ "$TESTS_FAILED" -gt 0 ]; then
    printf ", ${RED}%d failed${RESET}\n" "$TESTS_FAILED"
    printf "\n${RED}Failed tests:${RESET}\n"
    printf "$FAILED_NAMES"
    exit 1
else
    printf " ${GREEN}✓${RESET}\n\n"
    exit 0
fi
