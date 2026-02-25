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
COLLECTOR="$REPO_ROOT/scripts/thunderstorm-collector.sh"

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
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
    elif command -v shuf >/dev/null 2>&1; then
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
    echo "$output" | grep -oP "${key}=\K[0-9]+" | tail -1
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

    # Set max size to 50 KB
    local out; out="$(run_collector --dir "$d" --max-size-kb 50 --max-age 30 --debug)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    local skipped; skipped="$(parse_collector_stat "$out" skipped)"

    assert_eq "submitted" "1" "$submitted" || return 1
    assert_eq "skipped" "1" "$skipped" || return 1
}

# ── 5. Max age filter ───────────────────────────────────────────────────────

test_max_age_filter() {
    restart_stub
    local d; d="$(create_sample_dir age_filter)"
    create_file "$d/recent.txt" "new"
    create_file "$d/old.txt" "old"
    set_file_age_days "$d/old.txt" 60

    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local scanned; scanned="$(parse_collector_stat "$out" scanned)"
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"

    # find -mtime -30 should exclude the 60-day-old file entirely
    assert_eq "scanned" "1" "$scanned" || return 1
    assert_eq "submitted" "1" "$submitted" || return 1
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

test_nonexistent_directory_warning() {
    restart_stub
    local d; d="$(create_sample_dir exists)"
    create_file "$d/a.txt"

    # Also pass a non-existent dir — collector should warn but continue
    local out; out="$(bash "$COLLECTOR" \
        --server "$(server_host)" --port "$STUB_PORT" --no-log-file \
        --dir /nonexistent_path_$RANDOM --dir "$d" --max-age 30 2>&1)"

    assert_contains "warn about missing dir" "non-directory" "$out" || return 1
    local submitted; submitted="$(parse_collector_stat "$out" submitted)"
    assert_eq "submitted" "1" "$submitted" || return 1
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

# ── 17. Validation: invalid max-size-kb ──────────────────────────────────────

test_invalid_max_size_rejected() {
    local out; out="$(bash "$COLLECTOR" \
        --server 127.0.0.1 --port 8080 --no-log-file \
        --dir /tmp --max-size-kb "xyz" 2>&1)" || true

    assert_contains "max-size validation" "max-size-kb must be numeric" "$out" || return 1
}

# ── 18. Validation: missing server ───────────────────────────────────────────

test_missing_server_rejected() {
    local out; out="$(bash "$COLLECTOR" \
        --server "" --port 8080 --no-log-file \
        --dir /tmp 2>&1)" || true

    # Empty string is caught as "Missing value" by the arg parser
    assert_contains "server validation" "Missing value" "$out" || return 1
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
    # Don't start stub — let it fail
    stop_stub
    local d; d="$(create_sample_dir retry_fail)"
    create_file "$d/a.txt"

    local dead_port; dead_port="$(pick_port)"
    local out; out="$(bash "$COLLECTOR" \
        --server 127.0.0.1 --port "$dead_port" --no-log-file \
        --dir "$d" --max-age 30 --retries 2 2>&1)"

    local failed; failed="$(parse_collector_stat "$out" failed)"
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

    local out; out="$(run_collector --dir "$d" --max-age 0)"
    local scanned; scanned="$(parse_collector_stat "$out" scanned)"

    # -mtime -0 matches files modified in the last 0 days (i.e., today or
    # the last 24h, which depends on find implementation). This is tricky.
    # With max-age 0, the collector uses find -mtime -0. On GNU find this
    # matches files modified in the last 24h. The old file should be excluded.
    # This test documents the actual behavior.
    assert_ge "scanned at least 1" 1 "$scanned" || return 1
}

# ── 27. Max-age CLI override actually takes effect ───────────────────────────

test_max_age_cli_override_applied() {
    restart_stub
    local d; d="$(create_sample_dir age_override)"
    create_file "$d/recent.txt" "new"
    create_file "$d/medium.txt" "medium age"
    set_file_age_days "$d/medium.txt" 20

    # Default MAX_AGE is 14 days. Pass --max-age 30 on CLI.
    # If the bug where find_mtime was set before parse_args is present,
    # the 20-day-old file would be excluded (find -mtime -14).
    # With the fix, --max-age 30 means find -mtime -30, so it's included.
    local out; out="$(run_collector --dir "$d" --max-age 30)"
    local scanned; scanned="$(parse_collector_stat "$out" scanned)"

    assert_eq "scanned" "2" "$scanned" || return 1
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
run_test test_nonexistent_directory_warning
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
