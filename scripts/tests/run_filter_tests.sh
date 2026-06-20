#!/usr/bin/env bash
#
# Filter / Selector Tests for All Script Collectors
# Tests: --max-age, --max-size, and extension filtering
#
# Requires: stub server running on $STUB_PORT, test fixtures in $FIXTURES_DIR
#
set -euo pipefail

STUB_HOST="${STUB_HOST:-127.0.0.1}"
STUB_PORT="${STUB_PORT:-19990}"
STUB_LOG="${STUB_LOG:-/tmp/stub-filter-test.jsonl}"
FIXTURES_DIR="${FIXTURES_DIR:-/tmp/filter-test-fixtures}"
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
COLLECTOR_FILTER_RAW="${THUNDERSTORM_TEST_COLLECTORS:-}"
COLLECTOR_REQUIRE_MATCH="${THUNDERSTORM_TEST_REQUIRE_MATCH:-0}"
COLLECTOR_REQUIRE_ALL="${THUNDERSTORM_TEST_REQUIRE_ALL:-0}"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
skip() { SKIP=$((SKIP+1)); printf "  \033[33mSKIP\033[0m %s\n" "$1"; }

normalize_collector() {
    case "$1" in
        bash|ash|perl|python2|python3|ps3|ps2) printf '%s\n' "$1" ;;
        python) printf 'python3\n' ;;
        powershell|powershell3|pwsh|ps) printf 'ps3\n' ;;
        powershell2|psv2) printf 'ps2\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

collector_enabled() {
    local current wanted
    current="$(normalize_collector "$1")"
    [ -z "$COLLECTOR_FILTER_RAW" ] && return 0

    for wanted in ${COLLECTOR_FILTER_RAW//,/ }; do
        if [ "$(normalize_collector "$wanted")" = "$current" ]; then
            return 0
        fi
    done
    return 1
}

is_truthy() {
    case "${1:-0}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

list_contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

detect_ash_shell() {
    if command -v dash >/dev/null 2>&1; then
        command -v dash
        return 0
    fi
    if command -v busybox >/dev/null 2>&1; then
        printf '%s sh\n' "$(command -v busybox)"
        return 0
    fi
    return 1
}

ASH_SHELL="${ASH_SHELL:-$(detect_ash_shell 2>/dev/null || true)}"

collector_script_path() {
    case "$(normalize_collector "$1")" in
        bash) printf '%s/thunderstorm-collector.sh\n' "$SCRIPTS_DIR" ;;
        ash) printf '%s/thunderstorm-collector-ash.sh\n' "$SCRIPTS_DIR" ;;
        python3) printf '%s/thunderstorm-collector.py\n' "$SCRIPTS_DIR" ;;
        python2) printf '%s/thunderstorm-collector-py2.py\n' "$SCRIPTS_DIR" ;;
        perl) printf '%s/thunderstorm-collector.pl\n' "$SCRIPTS_DIR" ;;
        ps3) printf '%s/thunderstorm-collector.ps1\n' "$SCRIPTS_DIR" ;;
        ps2) printf '%s/thunderstorm-collector-ps2.ps1\n' "$SCRIPTS_DIR" ;;
        *) return 1 ;;
    esac
}

collector_has_flags() {
    local script_path="$1" flag
    shift
    for flag in "$@"; do
        grep -q -- "$flag" "$script_path" || return 1
    done
}

collector_supports_shared_harness() {
    local current script_path
    current="$(normalize_collector "$1")"
    script_path="$(collector_script_path "$current")" || return 1

    case "$current" in
        bash|ash)
            collector_has_flags "$script_path" --server --port --dir --max-age --source --dry-run
            ;;
        python3|python2)
            collector_has_flags "$script_path" --server --port --dirs --max-age --source --dry-run
            ;;
        perl)
            collector_has_flags "$script_path" --server --port --dir --max-age --source --dry-run
            ;;
        ps3|ps2)
            collector_has_flags "$script_path" ThunderstormServer ThunderstormPort Folder Source MaxAge MaxSize AllExtensions
            ;;
        *) return 1 ;;
    esac
}

collector_runnable() {
    local current script_path
    current="$(normalize_collector "$1")"
    script_path="$(collector_script_path "$current")" || return 1
    [ -f "$script_path" ] || return 1
    collector_supports_shared_harness "$current" || return 1

    case "$current" in
        bash) command -v bash >/dev/null 2>&1 ;;
        ash) [ -n "$ASH_SHELL" ] ;;
        python3) command -v python3 >/dev/null 2>&1 ;;
        python2) command -v python2 >/dev/null 2>&1 ;;
        perl) command -v perl >/dev/null 2>&1 && perl -MLWP::UserAgent -e1 2>/dev/null ;;
        ps3|ps2) command -v pwsh >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

validate_available_collectors() {
    local available=("$@")
    local wanted normalized missing=()

    if is_truthy "$COLLECTOR_REQUIRE_MATCH" && [ "${#available[@]}" -eq 0 ]; then
        echo "ERROR: no runnable collectors matched THUNDERSTORM_TEST_COLLECTORS='${COLLECTOR_FILTER_RAW}'" >&2
        exit 1
    fi

    if is_truthy "$COLLECTOR_REQUIRE_ALL" && [ -n "$COLLECTOR_FILTER_RAW" ]; then
        for wanted in ${COLLECTOR_FILTER_RAW//,/ }; do
            normalized="$(normalize_collector "$wanted")"
            if ! list_contains "$normalized" "${available[@]}"; then
                missing+=("$normalized")
            fi
        done
        if [ "${#missing[@]}" -gt 0 ]; then
            echo "ERROR: requested collectors are not runnable: ${missing[*]}" >&2
            exit 1
        fi
    fi
}

# Get uploaded filenames from stub server JSONL log since a given line
# Extracts basename from client_filename field
get_uploaded_files() {
    local start_line="$1"
    tail -n +"$start_line" "$STUB_LOG" 2>/dev/null \
        | grep -o '"client_filename":"[^"]*"' \
        | sed 's/"client_filename":"//;s/"//' \
        | xargs -I{} basename {} \
        | sort
}

log_lines() {
    wc -l < "$STUB_LOG" 2>/dev/null | tr -d ' '
}

assert_uploaded() {
    local start="$1" filename="$2" label="$3"
    if get_uploaded_files "$start" | grep -qF "$filename"; then
        pass "$label: '$filename' uploaded"
    else
        fail "$label: '$filename' NOT uploaded (expected)"
    fi
}

assert_not_uploaded() {
    local start="$1" filename="$2" label="$3"
    if get_uploaded_files "$start" | grep -qF "$filename"; then
        fail "$label: '$filename' uploaded (should be filtered)"
    else
        pass "$label: '$filename' filtered out"
    fi
}

kb_to_mb_ceil() {
    local kb="$1"
    echo $(((kb + 1023) / 1024))
}

# Create patched copies of Python/Perl collectors with specific max_age/max_size
patch_python() {
    local max_age="$1" max_size_kb="$2" out="$TMP_DIR/thunderstorm-collector-patched.py"
    local src="$SCRIPTS_DIR/thunderstorm-collector.py" max_size="$max_size_kb"
    if ! grep -q -- "--max-size-kb" "$src"; then
        max_size="$(kb_to_mb_ceil "$max_size_kb")"
    fi
    sed -e "s/^max_age = .*/max_age = $max_age/" \
        -e "s/^max_size = .*/max_size = $max_size/" \
        -e "s/\"--max-size-kb\", type=int, default=[0-9]*/\"--max-size-kb\", type=int, default=$max_size_kb/" \
        -e "s/\"--max-age\", type=int, default=[0-9]*/\"--max-age\", type=int, default=$max_age/" \
        "$src" > "$out"
    echo "$out"
}

patch_python2() {
    local max_age="$1" max_size_kb="$2" out="$TMP_DIR/thunderstorm-collector-py2-patched.py"
    local src="$SCRIPTS_DIR/thunderstorm-collector-py2.py" max_size="$max_size_kb"
    if ! grep -q -- "--max-size-kb" "$src"; then
        max_size="$(kb_to_mb_ceil "$max_size_kb")"
    fi
    sed -e "s/^max_age = .*/max_age = $max_age/" \
        -e "s/^max_size = .*/max_size = $max_size/" \
        -e "s/\"--max-size-kb\", type=int, default=[0-9]*/\"--max-size-kb\", type=int, default=$max_size_kb/" \
        -e "s/\"--max-age\", type=int, default=[0-9]*/\"--max-age\", type=int, default=$max_age/" \
        "$src" > "$out"
    echo "$out"
}

patch_perl() {
    local max_age="$1" max_size_kb="$2" out="$TMP_DIR/thunderstorm-collector-patched.pl"
    local src="$SCRIPTS_DIR/thunderstorm-collector.pl" max_size="$max_size_kb"
    if ! grep -q 'our \$max_size_kb' "$src"; then
        max_size="$(kb_to_mb_ceil "$max_size_kb")"
    fi
    sed -e "s/^our \\\$max_age = .*/our \$max_age = $max_age;/" \
        -e "s/^our \\\$max_size_kb = .*/our \$max_size_kb = $max_size_kb;/" \
        -e "s/^our \\\$max_size = .*/our \$max_size = $max_size;/" \
        "$src" > "$out"
    echo "$out"
}

available_collectors=()
collector_enabled bash && collector_runnable bash && available_collectors+=("bash")
collector_enabled ash && collector_runnable ash && available_collectors+=("ash")
collector_enabled python3 && collector_runnable python3 && available_collectors+=("python3")
collector_enabled python2 && collector_runnable python2 && available_collectors+=("python2")
collector_enabled perl && collector_runnable perl && available_collectors+=("perl")
collector_enabled ps3 && collector_runnable ps3 && available_collectors+=("ps3")
collector_enabled ps2 && collector_runnable ps2 && available_collectors+=("ps2")

if [ "${#available_collectors[@]}" -gt 0 ]; then
    validate_available_collectors "${available_collectors[@]}"
else
    validate_available_collectors
fi

if [ "${#available_collectors[@]}" -eq 0 ]; then
    echo "Available collectors: none"
    echo "No runnable collectors selected; nothing to do."
    exit 0
fi

collector_available() {
    local current
    current="$(normalize_collector "$1")"
    list_contains "$current" "${available_collectors[@]}"
}

# Ensure stub server is running
if ! curl -s "http://${STUB_HOST}:${STUB_PORT}/api/status" >/dev/null 2>&1; then
    echo "ERROR: Stub server not running on ${STUB_HOST}:${STUB_PORT}"
    exit 1
fi

if [ ! -d "$FIXTURES_DIR" ]; then
    echo "ERROR: Fixtures directory not found: $FIXTURES_DIR"
    exit 1
fi

echo "============================================"
echo " Filter / Selector Tests"
echo " Server: ${STUB_HOST}:${STUB_PORT}"
echo " Fixtures: ${FIXTURES_DIR}"
echo " Available collectors: ${available_collectors[*]}"
echo "============================================"
echo ""

# ══════════════════════════════════════════════
# BASH COLLECTOR
# ══════════════════════════════════════════════
if collector_available bash; then
    echo "── Bash Collector ──────────────────────────"

    # max-size: 1000KB limit → small(100B), fresh(6B), old(4B), ancient(8B),
    #   medium(500KB) pass; large(3MB), huge(25MB) filtered
    # Also passes: sample.exe(12B), sample.dll(12B), photo.jpg(12B), settings.conf(13B), noext(13B), nested.txt(7B)
    start=$(log_lines)
    bash "$SCRIPTS_DIR/thunderstorm-collector.sh" \
        --server "$STUB_HOST" --port "$STUB_PORT" \
        --dir "$FIXTURES_DIR" --max-size-kb 1000 --max-age 365 --quiet 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "bash/max-size-1000KB"
    assert_uploaded     "$start" "medium.bin"   "bash/max-size-1000KB"
    assert_not_uploaded "$start" "large.bin"    "bash/max-size-1000KB"
    assert_not_uploaded "$start" "huge.bin"     "bash/max-size-1000KB"

    # max-age: 7 days → only files created today pass (fresh, small, medium, large, huge, extensions, nested, noext)
    # old(30d) and ancient(90d) filtered
    start=$(log_lines)
    bash "$SCRIPTS_DIR/thunderstorm-collector.sh" \
        --server "$STUB_HOST" --port "$STUB_PORT" \
        --dir "$FIXTURES_DIR" --max-age 7 --max-size-kb 50000 --quiet 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "bash/max-age-7d"
    assert_uploaded     "$start" "small.txt"    "bash/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "bash/max-age-7d"
    assert_not_uploaded "$start" "ancient.txt"  "bash/max-age-7d"

    # combined: 7 days + 200KB → only small fresh files
    start=$(log_lines)
    bash "$SCRIPTS_DIR/thunderstorm-collector.sh" \
        --server "$STUB_HOST" --port "$STUB_PORT" \
        --dir "$FIXTURES_DIR" --max-age 7 --max-size-kb 200 --quiet 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "bash/combined"
    assert_not_uploaded "$start" "medium.bin"   "bash/combined"
    assert_not_uploaded "$start" "old.txt"      "bash/combined"
    assert_not_uploaded "$start" "large.bin"    "bash/combined"

    echo ""
fi

# ══════════════════════════════════════════════
# ASH / POSIX SH COLLECTOR
# ══════════════════════════════════════════════
if collector_available ash; then
    echo "── POSIX sh Collector (via $ASH_SHELL) ──────"

    start=$(log_lines)
    # Intentionally rely on word splitting so "busybox sh" works.
    # shellcheck disable=SC2086
    $ASH_SHELL "$SCRIPTS_DIR/thunderstorm-collector-ash.sh" \
        --server "$STUB_HOST" --port "$STUB_PORT" \
        --dir "$FIXTURES_DIR" --max-size-kb 1000 --max-age 365 --quiet 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "ash/max-size-1000KB"
    assert_uploaded     "$start" "medium.bin"   "ash/max-size-1000KB"
    assert_not_uploaded "$start" "large.bin"    "ash/max-size-1000KB"
    assert_not_uploaded "$start" "huge.bin"     "ash/max-size-1000KB"

    start=$(log_lines)
    $ASH_SHELL "$SCRIPTS_DIR/thunderstorm-collector-ash.sh" \
        --server "$STUB_HOST" --port "$STUB_PORT" \
        --dir "$FIXTURES_DIR" --max-age 7 --max-size-kb 50000 --quiet 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "ash/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "ash/max-age-7d"
    assert_not_uploaded "$start" "ancient.txt"  "ash/max-age-7d"

    echo ""
elif collector_enabled ash; then
    echo "── POSIX sh Collector ────────────────────────"
    skip "neither dash nor busybox available"
    echo ""
fi

# ══════════════════════════════════════════════
# PYTHON 3 COLLECTOR
# ══════════════════════════════════════════════
if collector_available python3; then
    echo "── Python 3 Collector ────────────────────────"

    # max-size test: 1024KB (~1MB), 365 days max_age
    py_script="$(patch_python 365 1024)"
    start=$(log_lines)
    python3 "$py_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "python3/max-size-1MB"
    assert_uploaded     "$start" "medium.bin"   "python3/max-size-1MB"
    assert_not_uploaded "$start" "large.bin"    "python3/max-size-1MB"
    assert_not_uploaded "$start" "huge.bin"     "python3/max-size-1MB"

    # max-age test: patch to 7 days max_age, 100MB max_size
    py_script="$(patch_python 7 50000)"
    start=$(log_lines)
    python3 "$py_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "python3/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "python3/max-age-7d"
    assert_not_uploaded "$start" "ancient.txt"  "python3/max-age-7d"

    # combined: 7 days + 200KB (only tiny fresh files; medium.bin is 500KB → filtered)
    py_script="$(patch_python 7 200)"
    start=$(log_lines)
    python3 "$py_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "python3/combined"
    assert_not_uploaded "$start" "medium.bin"   "python3/combined"
    assert_not_uploaded "$start" "old.txt"      "python3/combined"

    echo ""
fi

# ══════════════════════════════════════════════
# PYTHON 2 COLLECTOR
# ══════════════════════════════════════════════
if collector_available python2; then
    echo "── Python 2 Collector ────────────────────────"

    py2_script="$(patch_python2 365 1024)"
    start=$(log_lines)
    python2 "$py2_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "python2/max-size-1MB"
    assert_not_uploaded "$start" "large.bin"    "python2/max-size-1MB"

    py2_script="$(patch_python2 7 50000)"
    start=$(log_lines)
    python2 "$py2_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "python2/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "python2/max-age-7d"

    echo ""
elif collector_enabled python2; then
    echo "── Python 2 Collector ────────────────────────"
    skip "python2 not available"
    echo ""
fi

# ══════════════════════════════════════════════
# PERL COLLECTOR
# ══════════════════════════════════════════════
if collector_available perl; then
    echo "── Perl Collector ────────────────────────────"

    # max-size test: 1024KB (~1MB), 365 days
    pl_script="$(patch_perl 365 1024)"
    start=$(log_lines)
    perl "$pl_script" -s "$STUB_HOST" --port "$STUB_PORT" --dir "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "perl/max-size-1MB"
    assert_not_uploaded "$start" "large.bin"    "perl/max-size-1MB"
    assert_not_uploaded "$start" "huge.bin"     "perl/max-size-1MB"

    # max-age test: 7 days, 50000KB (~50MB, effectively no size limit)
    pl_script="$(patch_perl 7 50000)"
    start=$(log_lines)
    perl "$pl_script" -s "$STUB_HOST" --port "$STUB_PORT" --dir "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "perl/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "perl/max-age-7d"
    assert_not_uploaded "$start" "ancient.txt"  "perl/max-age-7d"

    echo ""
fi

# ══════════════════════════════════════════════
# POWERSHELL COLLECTORS
# ══════════════════════════════════════════════
if collector_available ps3; then
    echo "── PowerShell 3+ Collector ─────────────────"

    # max-size: 1MB — use wildcard extension '*' to match all files
    start=$(log_lines)
    pwsh -NoProfile -ep bypass -c "& '$SCRIPTS_DIR/thunderstorm-collector.ps1' \
        -ThunderstormServer '$STUB_HOST' -ThunderstormPort $STUB_PORT \
        -Folder '$FIXTURES_DIR' -MaxSize 1 -MaxAge 365 \
        -Extensions @('.txt','.bin','.exe','.dll','.jpg','.conf')" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "ps3/max-size-1MB"
    assert_uploaded     "$start" "medium.bin"   "ps3/max-size-1MB"
    assert_not_uploaded "$start" "large.bin"    "ps3/max-size-1MB"
    assert_not_uploaded "$start" "huge.bin"     "ps3/max-size-1MB"

    # max-age: 7 days
    start=$(log_lines)
    pwsh -NoProfile -ep bypass -c "& '$SCRIPTS_DIR/thunderstorm-collector.ps1' \
        -ThunderstormServer '$STUB_HOST' -ThunderstormPort $STUB_PORT \
        -Folder '$FIXTURES_DIR' -MaxAge 7 -MaxSize 100 \
        -Extensions @('.txt','.bin','.exe','.dll','.jpg','.conf')" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "ps3/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "ps3/max-age-7d"
    assert_not_uploaded "$start" "ancient.txt"  "ps3/max-age-7d"

    # extension filtering: only .exe and .dll
    start=$(log_lines)
    pwsh -NoProfile -ep bypass -c "& '$SCRIPTS_DIR/thunderstorm-collector.ps1' \
        -ThunderstormServer '$STUB_HOST' -ThunderstormPort $STUB_PORT \
        -Folder '$FIXTURES_DIR' -MaxAge 365 -MaxSize 100 \
        -Extensions @('.exe', '.dll')" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "sample.exe"   "ps3/ext-filter"
    assert_uploaded     "$start" "sample.dll"   "ps3/ext-filter"
    assert_not_uploaded "$start" "photo.jpg"    "ps3/ext-filter"
    assert_not_uploaded "$start" "fresh.txt"    "ps3/ext-filter"
    assert_not_uploaded "$start" "noext"        "ps3/ext-filter"

    echo ""
fi

if collector_available ps2; then
    echo "── PowerShell 2+ Collector ─────────────────"

    start=$(log_lines)
    pwsh -NoProfile -ep bypass -c "& '$SCRIPTS_DIR/thunderstorm-collector-ps2.ps1' \
        -ThunderstormServer '$STUB_HOST' -ThunderstormPort $STUB_PORT \
        -Folder '$FIXTURES_DIR' -MaxSize 1 -MaxAge 365 \
        -Extensions @('.txt','.bin','.exe','.dll','.jpg','.conf')" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "ps2/max-size-1MB"
    assert_not_uploaded "$start" "large.bin"    "ps2/max-size-1MB"

    start=$(log_lines)
    pwsh -NoProfile -ep bypass -c "& '$SCRIPTS_DIR/thunderstorm-collector-ps2.ps1' \
        -ThunderstormServer '$STUB_HOST' -ThunderstormPort $STUB_PORT \
        -Folder '$FIXTURES_DIR' -MaxAge 7 -MaxSize 100 \
        -Extensions @('.txt','.bin','.exe','.dll','.jpg','.conf')" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "ps2/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "ps2/max-age-7d"

    # PS2 extension filtering
    start=$(log_lines)
    pwsh -NoProfile -ep bypass -c "& '$SCRIPTS_DIR/thunderstorm-collector-ps2.ps1' \
        -ThunderstormServer '$STUB_HOST' -ThunderstormPort $STUB_PORT \
        -Folder '$FIXTURES_DIR' -MaxAge 365 -MaxSize 100 \
        -Extensions @('.exe', '.dll')" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "sample.exe"   "ps2/ext-filter"
    assert_uploaded     "$start" "sample.dll"   "ps2/ext-filter"
    assert_not_uploaded "$start" "photo.jpg"    "ps2/ext-filter"

    echo ""
elif { collector_enabled ps3 || collector_enabled ps2; } && ! command -v pwsh >/dev/null 2>&1; then
    echo "── PowerShell Collectors ─────────────────────"
    skip "pwsh not available"
    echo ""
fi

# ══════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════
echo "============================================"
echo " Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
