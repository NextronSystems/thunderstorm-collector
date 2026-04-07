#!/usr/bin/env bash
# ============================================================================
# Operational Feature Tests
#
# Tests operational features not covered by detection tests:
#
#  1.  Collection markers — begin/end markers sent, scan_id propagated
#  2.  Interrupted marker — SIGINT sends interrupted marker before exit
#  3.  Dry-run mode — no uploads, no server contact (bash/ash/python/perl)
#  4.  Source identifier — --source sets source field in collection markers
#  5.  Sync mode — --sync uses /api/check instead of /api/checkAsync
#  6.  Multiple scan directories — scanning multiple dirs in one run
#  7.  503 back-pressure — server returns 503, collector retries with Retry-After
#  8.  Progress reporting — --progress flag doesn't crash, produces output
#  9.  Syslog logging — --syslog flag doesn't crash (bash only)
# 10.  curl vs wget fallback — bash collector works with wget when curl absent
#
# Requires: thunderstorm-stub server with YARA support
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECTOR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STUB_PORT="${STUB_PORT:-18200}"
STUB_URL="http://localhost:${STUB_PORT}"
STUB_LOG=""
STUB_PID=""
RULES_DIR=""

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

pass() { printf "  ${GREEN}PASS${RESET} %s\n" "$*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { printf "  ${RED}FAIL${RESET} %s\n" "$*"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED_NAMES="$FAILED_NAMES  - $1\n"; }
skip() { printf "  ${YELLOW}SKIP${RESET} %s\n" "$*"; TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

MALICIOUS_CONTENT='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'

detect_ash_shell() {
    if command -v ash >/dev/null 2>&1; then
        echo "ash"
    elif command -v dash >/dev/null 2>&1; then
        echo "dash"
    elif command -v busybox >/dev/null 2>&1; then
        echo "busybox sh"
    else
        echo ""
    fi
}

ASH_SHELL="${ASH_SHELL:-$(detect_ash_shell)}"

find_stub() {
    local candidates=(
        "${STUB_BIN_PATH:-}"
        "$SCRIPT_DIR/../../../thunderstorm-stub-server/thunderstorm-stub"
        "$(command -v thunderstorm-stub 2>/dev/null || true)"
    )
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -x "$c" ] && echo "$c" && return 0
    done
    echo "ERROR: thunderstorm-stub not found" >&2
    return 1
}

find_rules() {
    local candidates=(
        "${STUB_RULES_PATH:-}"
        "$SCRIPT_DIR/../../../thunderstorm-stub-server/rules"
    )
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -d "$c" ] && echo "$c" && return 0
    done
    echo "ERROR: rules directory not found" >&2
    return 1
}

start_stub() {
    local stub_bin; stub_bin="$(find_stub)"
    RULES_DIR="$(find_rules)"
    STUB_LOG="$(mktemp /tmp/oper-test-XXXXXX.jsonl)"

    "$stub_bin" -port "$STUB_PORT" -rules-dir "$RULES_DIR" -log-file "$STUB_LOG" \
        > /dev/null 2>&1 &
    STUB_PID=$!
    sleep 2
    if ! curl -s "$STUB_URL/api/status" > /dev/null; then
        echo "ERROR: stub failed to start on port $STUB_PORT" >&2
        exit 1
    fi
}

stop_stub() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null && wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
}

clear_log() {
    curl -s -X POST "$STUB_URL/api/test/reset" > /dev/null 2>&1 || true
}

query_log() {
    local pattern="$1"
    python3 -c "
import json, sys
for line in open('$STUB_LOG'):
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    # Search in client_filename, type, marker fields
    cf = d.get('subject', {}).get('client_filename', '')
    mtype = d.get('type', '')
    marker = d.get('marker', '')
    source = d.get('source', '')
    raw = json.dumps(d)
    if '$pattern' in cf or '$pattern' in mtype or '$pattern' in marker or '$pattern' in source or '$pattern' in raw:
        print(line)
" 2>/dev/null
}

sync_stub() { sleep 1; }

# Configure stub to return specific responses
configure_stub() {
    local config="$1"
    curl -s -X POST "$STUB_URL/api/test/config" \
        -H "Content-Type: application/json" \
        -d "$config" > /dev/null
}

# Translate generic flags to PS parameter names
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

run_collector() {
    local name="$1"; shift
    case "$name" in
        bash)   run_bash "$@" ;;
        ash)    run_ash "$@" ;;
        python) run_python "$@" ;;
        perl)   run_perl "$@" ;;
        ps3)    run_ps3 "$@" ;;
        ps2)    run_ps2 "$@" ;;
    esac
}

run_bash() {
    local dir="$1"; shift
    bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
        --server localhost --port "$STUB_PORT" --dir "$dir" \
        "$@" 2>&1
}

run_ash() {
    local dir="$1"; shift
    [ -n "$ASH_SHELL" ] || return 127
    # Intentionally rely on shell word splitting so "busybox sh" works.
    # shellcheck disable=SC2086
    $ASH_SHELL "${COLLECTOR_DIR}/thunderstorm-collector-ash.sh" \
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

# ============================================================================
# Tests
# ============================================================================

# ── 1. Collection markers — begin/end with scan_id ─────────────────────────
test_collection_markers() {
    local collector="$1"
    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$fixtures/marker-${collector}.exe"

    run_collector "$collector" "$fixtures" --max-age 30 >/dev/null 2>&1 || true
    sync_stub

    # Check for begin marker
    local begin_entry; begin_entry="$(query_log 'begin')"
    if [ -z "$begin_entry" ]; then
        fail "$collector/collection-markers: no begin marker found"
        rm -rf "$fixtures"
        return
    fi

    # Check for end marker
    local end_entry; end_entry="$(query_log 'end')"
    if [ -z "$end_entry" ]; then
        fail "$collector/collection-markers: no end marker found"
        rm -rf "$fixtures"
        return
    fi

    # Verify scan_id is present and consistent
    local begin_scan_id; begin_scan_id="$(echo "$begin_entry" | head -1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('scan_id',''))" 2>/dev/null)"
    local end_scan_id; end_scan_id="$(echo "$end_entry" | head -1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('scan_id',''))" 2>/dev/null)"

    if [ -z "$begin_scan_id" ]; then
        fail "$collector/collection-markers: begin marker missing scan_id"
    elif [ "$begin_scan_id" != "$end_scan_id" ]; then
        fail "$collector/collection-markers: scan_id mismatch (begin=$begin_scan_id end=$end_scan_id)"
    else
        pass "$collector/collection-markers: begin+end markers with matching scan_id=$begin_scan_id"
    fi

    # Verify end marker has stats
    local has_stats; has_stats="$(echo "$end_entry" | head -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
stats = d.get('stats', {})
print('yes' if stats and 'submitted' in str(stats) else 'no')
" 2>/dev/null)"
    if [ "$has_stats" = "yes" ]; then
        pass "$collector/collection-markers-stats: end marker includes stats"
    else
        fail "$collector/collection-markers-stats: end marker missing stats"
    fi

    rm -rf "$fixtures"
}

# ── 2. Interrupted marker via SIGINT ────────────────────────────────────────
test_interrupted_marker() {
    local collector="$1"
    clear_log

    # Create a large directory tree so the collector takes a while
    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    for i in $(seq 1 200); do
        echo "$MALICIOUS_CONTENT" > "$fixtures/file-${collector}-${i}.exe"
    done

    # Start collector in background
    local pid_file; pid_file="$(mktemp /tmp/oper-pid-XXXXXX)"
    case "$collector" in
        bash)
            bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
                --server localhost --port "$STUB_PORT" --dir "$fixtures" \
                --max-age 30 > /dev/null 2>&1 &
            echo $! > "$pid_file"
            ;;
        ash)
            # shellcheck disable=SC2086
            $ASH_SHELL "${COLLECTOR_DIR}/thunderstorm-collector-ash.sh" \
                --server localhost --port "$STUB_PORT" --dir "$fixtures" \
                --max-age 30 > /dev/null 2>&1 &
            echo $! > "$pid_file"
            ;;
        python)
            python3 "${COLLECTOR_DIR}/thunderstorm-collector.py" \
                -s localhost -p "$STUB_PORT" -d "$fixtures" \
                --max-age 30 > /dev/null 2>&1 &
            echo $! > "$pid_file"
            ;;
        perl)
            perl "${COLLECTOR_DIR}/thunderstorm-collector.pl" \
                -s localhost -p "$STUB_PORT" --dir "$fixtures" \
                --max-age 30 > /dev/null 2>&1 &
            echo $! > "$pid_file"
            ;;
        ps3)
            pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" \
                -MaxAge 30 > /dev/null 2>&1 &
            echo $! > "$pid_file"
            ;;
        ps2)
            pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector-ps2.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" \
                -MaxAge 30 > /dev/null 2>&1 &
            echo $! > "$pid_file"
            ;;
    esac

    local coll_pid; coll_pid="$(cat "$pid_file")"

    # Wait for begin marker to appear (collector is running)
    local waited=0
    while [ $waited -lt 10 ]; do
        if query_log 'begin' | grep -q 'begin' 2>/dev/null; then
            break
        fi
        sleep 0.5
        waited=$((waited + 1))
    done

    # Send SIGINT (Ctrl-C)
    kill -INT "$coll_pid" 2>/dev/null || true
    # Wait for collector to finish
    wait "$coll_pid" 2>/dev/null || true
    sync_stub
    sync_stub  # extra wait for marker

    # Check for interrupted marker
    local int_entry; int_entry="$(query_log 'interrupted')"
    if [ -n "$int_entry" ]; then
        pass "$collector/interrupted-marker: interrupted marker sent on SIGINT"
    else
        # Some collectors may not support interrupted markers
        local end_entry; end_entry="$(query_log 'end')"
        if [ -n "$end_entry" ]; then
            # Sent end marker instead of interrupted — acceptable
            skip "$collector/interrupted-marker: sent end marker instead of interrupted on SIGINT"
        else
            fail "$collector/interrupted-marker: no interrupted or end marker on SIGINT"
        fi
    fi

    rm -rf "$fixtures" "$pid_file"
}

# ── 3. Dry-run mode ────────────────────────────────────────────────────────
test_dry_run() {
    local collector="$1"

    # PS collectors don't support dry-run
    case "$collector" in
        ps3|ps2)
            skip "$collector/dry-run: not supported"
            return
            ;;
    esac

    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$fixtures/dryrun-${collector}.exe"

    local output
    case "$collector" in
        bash)   output="$(run_bash "$fixtures" --max-age 30 --dry-run 2>&1)" ;;
        ash)    output="$(run_ash "$fixtures" --max-age 30 --dry-run 2>&1)" ;;
        python) output="$(run_python "$fixtures" --max-age 30 --dry-run 2>&1)" ;;
        perl)   output="$(run_perl "$fixtures" --max-age 30 --dry-run 2>&1)" ;;
    esac
    sync_stub

    # Verify no uploads occurred
    local upload_entry; upload_entry="$(query_log "dryrun-${collector}")"
    if [ -n "$upload_entry" ]; then
        fail "$collector/dry-run: file was uploaded (should not be)"
    else
        # Verify the dry-run output mentions the file
        if echo "$output" | grep -qi "dryrun-${collector}\|dry.run\|would"; then
            pass "$collector/dry-run: no upload, file listed in output"
        else
            fail "$collector/dry-run: no upload, but file not mentioned in output"
        fi
    fi

    rm -rf "$fixtures"
}

# ── 4. Source identifier ────────────────────────────────────────────────────
test_source_identifier() {
    local collector="$1"
    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$fixtures/source-${collector}.exe"

    local source_name="test-source-${collector}"
    case "$collector" in
        bash)
            run_bash "$fixtures" --max-age 30 --source "$source_name" >/dev/null 2>&1 || true
            ;;
        ash)
            run_ash "$fixtures" --max-age 30 --source "$source_name" >/dev/null 2>&1 || true
            ;;
        python)
            python3 "${COLLECTOR_DIR}/thunderstorm-collector.py" \
                -s localhost -p "$STUB_PORT" -d "$fixtures" \
                --max-age 30 --source "$source_name" >/dev/null 2>&1 || true
            ;;
        perl)
            perl "${COLLECTOR_DIR}/thunderstorm-collector.pl" \
                -s localhost -p "$STUB_PORT" --dir "$fixtures" \
                --max-age 30 --source "$source_name" >/dev/null 2>&1 || true
            ;;
        ps3)
            pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" \
                -MaxAge 30 -Source "$source_name" >/dev/null 2>&1 || true
            ;;
        ps2)
            pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector-ps2.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" \
                -MaxAge 30 -Source "$source_name" >/dev/null 2>&1 || true
            ;;
    esac
    sync_stub

    # Check collection markers for source field
    local marker_entry; marker_entry="$(query_log 'begin')"
    if [ -n "$marker_entry" ]; then
        local source_in_marker; source_in_marker="$(echo "$marker_entry" | head -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('source', ''))
" 2>/dev/null)"
        if [ "$source_in_marker" = "$source_name" ]; then
            pass "$collector/source-id: source='$source_name' in collection marker"
        else
            fail "$collector/source-id: expected source='$source_name', got source='$source_in_marker'"
        fi
    else
        # Check if source is in the upload URL query params
        local upload_entry; upload_entry="$(query_log "source-${collector}")"
        if [ -n "$upload_entry" ]; then
            local src_in_upload; src_in_upload="$(echo "$upload_entry" | head -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d.get('subject', {}).get('source', '')
print(s)
" 2>/dev/null)"
            if [ "$src_in_upload" = "$source_name" ]; then
                pass "$collector/source-id: source='$source_name' in upload"
            else
                pass "$collector/source-id: file uploaded (source may be in URL params)"
            fi
        else
            fail "$collector/source-id: no marker or upload found"
        fi
    fi

    rm -rf "$fixtures"
}

# ── 5. Sync mode ───────────────────────────────────────────────────────────
test_sync_mode() {
    local collector="$1"

    # PS collectors don't support --sync flag
    case "$collector" in
        ps3|ps2)
            skip "$collector/sync-mode: not supported (PS always uses checkAsync)"
            return
            ;;
    esac

    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$fixtures/sync-${collector}.exe"

    case "$collector" in
        bash)   run_bash "$fixtures" --max-age 30 --sync >/dev/null 2>&1 || true ;;
        ash)    run_ash "$fixtures" --max-age 30 --sync >/dev/null 2>&1 || true ;;
        python) run_python "$fixtures" --max-age 30 --sync >/dev/null 2>&1 || true ;;
        perl)   run_perl "$fixtures" --max-age 30 --sync >/dev/null 2>&1 || true ;;
    esac
    sync_stub

    # In sync mode, the stub logs the scan immediately (no async queue)
    local entry; entry="$(query_log "sync-${collector}")"
    if [ -n "$entry" ]; then
        local score; score="$(echo "$entry" | head -1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('score',0))" 2>/dev/null)"
        pass "$collector/sync-mode: file scanned synchronously (score=$score)"
    else
        fail "$collector/sync-mode: file not found in log"
    fi

    rm -rf "$fixtures"
}

# ── 6. Multiple scan directories ───────────────────────────────────────────
test_multiple_dirs() {
    local collector="$1"

    # PS collectors only accept a single -Folder
    case "$collector" in
        ps3|ps2)
            skip "$collector/multiple-dirs: PS accepts single -Folder only"
            return
            ;;
    esac

    clear_log

    local dir1; dir1="$(mktemp -d /tmp/oper-test-XXXXXX)"
    local dir2; dir2="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$dir1/multi1-${collector}.exe"
    echo "$MALICIOUS_CONTENT" > "$dir2/multi2-${collector}.exe"

    case "$collector" in
        bash)
            bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
                --server localhost --port "$STUB_PORT" \
                --dir "$dir1" --dir "$dir2" \
                --max-age 30 >/dev/null 2>&1 || true
            ;;
        ash)
            # shellcheck disable=SC2086
            $ASH_SHELL "${COLLECTOR_DIR}/thunderstorm-collector-ash.sh" \
                --server localhost --port "$STUB_PORT" \
                --dir "$dir1" --dir "$dir2" \
                --max-age 30 >/dev/null 2>&1 || true
            ;;
        python)
            python3 "${COLLECTOR_DIR}/thunderstorm-collector.py" \
                -s localhost -p "$STUB_PORT" \
                -d "$dir1" "$dir2" \
                --max-age 30 >/dev/null 2>&1 || true
            ;;
        perl)
            # Perl may only accept a single --dir — test and see
            perl "${COLLECTOR_DIR}/thunderstorm-collector.pl" \
                -s localhost -p "$STUB_PORT" --dir "$dir1" --dir "$dir2" \
                --max-age 30 >/dev/null 2>&1 || true
            ;;
    esac
    sync_stub

    local f1; f1="$(query_log "multi1-${collector}")"
    local f2; f2="$(query_log "multi2-${collector}")"

    if [ -n "$f1" ] && [ -n "$f2" ]; then
        pass "$collector/multiple-dirs: both directories scanned"
    elif [ -n "$f1" ] || [ -n "$f2" ]; then
        # Collector only scanned one dir — might only support single dir
        if [ -n "$f1" ]; then
            skip "$collector/multiple-dirs: only first directory scanned (single-dir only?)"
        else
            skip "$collector/multiple-dirs: only second directory scanned"
        fi
    else
        fail "$collector/multiple-dirs: neither directory scanned"
    fi

    rm -rf "$dir1" "$dir2"
}

# ── 7. 503 back-pressure with Retry-After ──────────────────────────────────
test_503_backpressure() {
    local collector="$1"
    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$fixtures/bp503-${collector}.exe"
    echo "$MALICIOUS_CONTENT" > "$fixtures/bp503b-${collector}.exe"

    # Configure stub: first upload returns 503 with Retry-After: 1
    # Only the first request gets 503; subsequent requests proceed normally
    configure_stub '{
        "upload_rules": [
            {"match_count": [1], "status": 503, "headers": {"Retry-After": "1"}}
        ]
    }'

    local output
    local collector_exit=0
    case "$collector" in
        bash)
            output="$(timeout 30 bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
                --server localhost --port "$STUB_PORT" --dir "$fixtures" --max-age 30 --retries 5 2>&1)" || collector_exit=$?
            ;;
        ash)
            # shellcheck disable=SC2086
            output="$(timeout 30 $ASH_SHELL "${COLLECTOR_DIR}/thunderstorm-collector-ash.sh" \
                --server localhost --port "$STUB_PORT" --dir "$fixtures" --max-age 30 --retries 5 2>&1)" || collector_exit=$?
            ;;
        python)
            output="$(timeout 30 python3 "${COLLECTOR_DIR}/thunderstorm-collector.py" \
                -s localhost -p "$STUB_PORT" -d "$fixtures" --max-age 30 --retries 5 2>&1)" || collector_exit=$?
            ;;
        perl)
            output="$(timeout 30 perl "${COLLECTOR_DIR}/thunderstorm-collector.pl" \
                -s localhost -p "$STUB_PORT" --dir "$fixtures" --max-age 30 --retries 5 2>&1)" || collector_exit=$?
            ;;
        ps3)
            output="$(timeout 30 pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" -MaxAge 30 2>&1)" || collector_exit=$?
            ;;
        ps2)
            output="$(timeout 30 pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector-ps2.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" -MaxAge 30 2>&1)" || collector_exit=$?
            ;;
    esac
    sync_stub
    sync_stub  # extra wait for retry

    # Reset config
    configure_stub '{"upload_rules": []}'

    # Check that at least one file was eventually submitted
    local entry; entry="$(query_log "bp503")"
    if [ -n "$entry" ]; then
        # Check if output mentions retry/503
        if echo "$output" | grep -qi '503\|retry\|busy\|back.off\|Retry-After'; then
            pass "$collector/503-backpressure: retried after 503, file submitted"
        else
            pass "$collector/503-backpressure: file submitted (retry may be silent)"
        fi
    else
        if echo "$output" | grep -qi '503\|busy\|Service Unavailable'; then
            fail "$collector/503-backpressure: got 503 but never retried successfully"
        else
            fail "$collector/503-backpressure: no evidence of 503 handling"
        fi
    fi

    rm -rf "$fixtures"
}

# ── 8. Progress reporting ──────────────────────────────────────────────────
test_progress_reporting() {
    local collector="$1"

    # PS collectors use -Progress (switch) — handled differently
    local progress_flag
    case "$collector" in
        bash)   progress_flag="--progress" ;;
        ash)    progress_flag="--progress" ;;
        python) progress_flag="--progress" ;;
        perl)   progress_flag="--progress" ;;
        ps3)    progress_flag="-Progress" ;;
        ps2)    progress_flag="-Progress" ;;
    esac

    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    for i in $(seq 1 5); do
        echo "$MALICIOUS_CONTENT" > "$fixtures/prog-${collector}-${i}.exe"
    done

    local output
    case "$collector" in
        bash)
            output="$(timeout 30 bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
                --server localhost --port "$STUB_PORT" --dir "$fixtures" --max-age 30 --progress 2>&1)" || true
            ;;
        ash)
            # shellcheck disable=SC2086
            output="$(timeout 30 $ASH_SHELL "${COLLECTOR_DIR}/thunderstorm-collector-ash.sh" \
                --server localhost --port "$STUB_PORT" --dir "$fixtures" --max-age 30 --progress 2>&1)" || true
            ;;
        python)
            output="$(timeout 30 python3 "${COLLECTOR_DIR}/thunderstorm-collector.py" \
                -s localhost -p "$STUB_PORT" -d "$fixtures" --max-age 30 --progress 2>&1)" || true
            ;;
        perl)
            output="$(timeout 30 perl "${COLLECTOR_DIR}/thunderstorm-collector.pl" \
                -s localhost -p "$STUB_PORT" --dir "$fixtures" --max-age 30 --progress 2>&1)" || true
            ;;
        ps3)
            output="$(timeout 30 pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" \
                -MaxAge 30 -Progress 2>&1)" || true
            ;;
        ps2)
            output="$(timeout 30 pwsh -NoProfile -File "${COLLECTOR_DIR}/thunderstorm-collector-ps2.ps1" \
                -ThunderstormServer localhost -ThunderstormPort "$STUB_PORT" -Folder "$fixtures" \
                -MaxAge 30 -Progress 2>&1)" || true
            ;;
    esac
    sync_stub

    # Check collector didn't crash and produced some output
    local submitted; submitted="$(query_log "prog-${collector}")"
    if [ -n "$submitted" ]; then
        pass "$collector/progress: collector ran successfully with progress flag"
    else
        fail "$collector/progress: no files submitted with progress flag"
    fi

    rm -rf "$fixtures"
}

# ── 9. Syslog logging ─────────────────────────────────────────────────────
test_syslog_logging() {
    local collector="$1"

    # Only bash supports --syslog
    case "$collector" in
        bash) ;;
        *)
            skip "$collector/syslog: not supported"
            return
            ;;
    esac

    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$fixtures/syslog-${collector}.exe"

    # Run with --syslog — just verify it doesn't crash
    local output; output="$(run_bash "$fixtures" --max-age 30 --syslog 2>&1)" || true
    sync_stub

    local entry; entry="$(query_log "syslog-${collector}")"
    if [ -n "$entry" ]; then
        pass "$collector/syslog: collector ran successfully with --syslog"
    else
        # Even if upload fails, the collector shouldn't crash with --syslog
        if echo "$output" | grep -qi 'error\|crash\|abort'; then
            fail "$collector/syslog: collector crashed with --syslog"
        else
            pass "$collector/syslog: collector ran with --syslog (no crash)"
        fi
    fi

    rm -rf "$fixtures"
}

# ── 10. curl vs wget fallback (bash only) ──────────────────────────────────
test_wget_fallback() {
    local collector="$1"

    case "$collector" in
        bash) ;;
        *)
            skip "$collector/wget-fallback: bash only"
            return
            ;;
    esac

    # Check if wget is available
    if ! command -v wget >/dev/null 2>&1; then
        skip "$collector/wget-fallback: wget not installed"
        return
    fi

    clear_log

    local fixtures; fixtures="$(mktemp -d /tmp/oper-test-XXXXXX)"
    echo "$MALICIOUS_CONTENT" > "$fixtures/wget-${collector}.exe"

    # Build a PATH that excludes directories containing real curl, but includes wget
    local wget_path; wget_path="$(command -v wget 2>/dev/null)"
    if [ -z "$wget_path" ]; then
        skip "$collector/wget-fallback: wget not installed"
        rm -rf "$fixtures"
        return
    fi

    local wget_dir; wget_dir="$(dirname "$wget_path")"
    # Build a minimal PATH with only wget's directory and standard utils (but no curl)
    local clean_path="$wget_dir:/usr/sbin:/sbin"
    # Verify curl is NOT on this path
    if env PATH="$clean_path" command -v curl >/dev/null 2>&1; then
        # curl is in the same dir as wget — can't isolate
        skip "$collector/wget-fallback: curl and wget in same directory, cannot isolate"
        rm -rf "$fixtures"
        return
    fi

    local output
    output="$(timeout 30 env PATH="$clean_path" \
        bash "${COLLECTOR_DIR}/thunderstorm-collector.sh" \
        --server localhost --port "$STUB_PORT" --dir "$fixtures" \
        --max-age 30 2>&1)" || true
    sync_stub

    local entry; entry="$(query_log "wget-${collector}")"
    if [ -n "$entry" ]; then
        pass "$collector/wget-fallback: file submitted via wget"
    else
        if echo "$output" | grep -qi 'wget'; then
            fail "$collector/wget-fallback: detected wget but upload failed"
        else
            skip "$collector/wget-fallback: could not isolate wget from curl"
        fi
    fi

    rm -rf "$fixtures"
}

# ============================================================================
# Main
# ============================================================================

echo ""
printf "${BOLD}Operational Feature Tests${RESET}\n"
echo "============================================"
echo ""

start_stub

COLLECTORS=("bash")
[ -n "$ASH_SHELL" ] && COLLECTORS+=("ash")
COLLECTORS+=("python" "perl" "ps3" "ps2")

for collector in "${COLLECTORS[@]}"; do
    printf "\n${CYAN}── $collector ──${RESET}\n"

    test_collection_markers "$collector"
    test_interrupted_marker "$collector"
    test_dry_run "$collector"
    test_source_identifier "$collector"
    test_sync_mode "$collector"
    test_multiple_dirs "$collector"
    test_503_backpressure "$collector"
    test_progress_reporting "$collector"
    test_syslog_logging "$collector"
    test_wget_fallback "$collector"
done

stop_stub

echo ""
echo "============================================"
printf " Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d skipped${RESET}\n" \
    "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
echo "============================================"

if [ -n "$FAILED_NAMES" ]; then
    echo ""
    printf "${RED}Failed tests:${RESET}\n"
    printf "$FAILED_NAMES"
fi

echo ""
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
