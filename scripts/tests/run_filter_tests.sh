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

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
skip() { SKIP=$((SKIP+1)); printf "  \033[33mSKIP\033[0m %s\n" "$1"; }

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

# Create patched copies of Python/Perl collectors with specific max_age/max_size
patch_python() {
    local max_age="$1" max_size="$2" out="$TMP_DIR/thunderstorm-collector-patched.py"
    sed -e "s/^max_age = .*/max_age = $max_age/" \
        -e "s/^max_size = .*/max_size = $max_size/" \
        "$SCRIPTS_DIR/thunderstorm-collector.py" > "$out"
    echo "$out"
}

patch_python2() {
    local max_age="$1" max_size="$2" out="$TMP_DIR/thunderstorm-collector-py2-patched.py"
    sed -e "s/^max_age = .*/max_age = $max_age/" \
        -e "s/^max_size = .*/max_size = $max_size/" \
        "$SCRIPTS_DIR/thunderstorm-collector-py2.py" > "$out"
    echo "$out"
}

patch_perl() {
    local max_age="$1" max_size="$2" out="$TMP_DIR/thunderstorm-collector-patched.pl"
    sed -e "s/^our \\\$max_age = .*/our \$max_age = $max_age;/" \
        -e "s/^our \\\$max_size = .*/our \$max_size = $max_size;/" \
        "$SCRIPTS_DIR/thunderstorm-collector.pl" > "$out"
    echo "$out"
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
echo "============================================"
echo ""

# ══════════════════════════════════════════════
# BASH COLLECTOR
# ══════════════════════════════════════════════
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

# ══════════════════════════════════════════════
# ASH / POSIX SH COLLECTOR
# ══════════════════════════════════════════════
if command -v dash >/dev/null 2>&1; then
    ASH_SHELL="dash"
elif command -v busybox >/dev/null 2>&1; then
    ASH_SHELL="busybox sh"
else
    ASH_SHELL=""
fi

if [ -n "$ASH_SHELL" ]; then
    echo "── POSIX sh Collector (via $ASH_SHELL) ──────"

    start=$(log_lines)
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
else
    echo "── POSIX sh Collector ────────────────────────"
    skip "neither dash nor busybox available"
    echo ""
fi

# ══════════════════════════════════════════════
# PYTHON 3 COLLECTOR
# ══════════════════════════════════════════════
echo "── Python 3 Collector ────────────────────────"

# max-size test: patch to 1MB max_size, 365 days max_age
py_script="$(patch_python 365 1)"
start=$(log_lines)
python3 "$py_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
sleep 1
assert_uploaded     "$start" "small.txt"    "python3/max-size-1MB"
assert_uploaded     "$start" "medium.bin"   "python3/max-size-1MB"
assert_not_uploaded "$start" "large.bin"    "python3/max-size-1MB"
assert_not_uploaded "$start" "huge.bin"     "python3/max-size-1MB"

# max-age test: patch to 7 days max_age, 100MB max_size
py_script="$(patch_python 7 100)"
start=$(log_lines)
python3 "$py_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
sleep 1
assert_uploaded     "$start" "fresh.txt"    "python3/max-age-7d"
assert_not_uploaded "$start" "old.txt"      "python3/max-age-7d"
assert_not_uploaded "$start" "ancient.txt"  "python3/max-age-7d"

# combined: 7 days + 0.4MB (only tiny fresh files)
py_script="$(patch_python 7 0.4)"
start=$(log_lines)
python3 "$py_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
sleep 1
assert_uploaded     "$start" "fresh.txt"    "python3/combined"
assert_not_uploaded "$start" "medium.bin"   "python3/combined"
assert_not_uploaded "$start" "old.txt"      "python3/combined"

echo ""

# ══════════════════════════════════════════════
# PYTHON 2 COLLECTOR
# ══════════════════════════════════════════════
if command -v python2 >/dev/null 2>&1; then
    echo "── Python 2 Collector ────────────────────────"

    py2_script="$(patch_python2 365 1)"
    start=$(log_lines)
    python2 "$py2_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "small.txt"    "python2/max-size-1MB"
    assert_not_uploaded "$start" "large.bin"    "python2/max-size-1MB"

    py2_script="$(patch_python2 7 100)"
    start=$(log_lines)
    python2 "$py2_script" -s "$STUB_HOST" -p "$STUB_PORT" -d "$FIXTURES_DIR" 2>/dev/null || true
    sleep 1
    assert_uploaded     "$start" "fresh.txt"    "python2/max-age-7d"
    assert_not_uploaded "$start" "old.txt"      "python2/max-age-7d"

    echo ""
else
    echo "── Python 2 Collector ────────────────────────"
    skip "python2 not available"
    echo ""
fi

# ══════════════════════════════════════════════
# PERL COLLECTOR
# ══════════════════════════════════════════════
echo "── Perl Collector ────────────────────────────"

# max-size test: 1MB, 365 days
pl_script="$(patch_perl 365 1)"
start=$(log_lines)
perl "$pl_script" -- -s "$STUB_HOST" --port "$STUB_PORT" --dir "$FIXTURES_DIR" 2>/dev/null || true
sleep 1
assert_uploaded     "$start" "small.txt"    "perl/max-size-1MB"
assert_not_uploaded "$start" "large.bin"    "perl/max-size-1MB"
assert_not_uploaded "$start" "huge.bin"     "perl/max-size-1MB"

# max-age test: 7 days, 100MB
pl_script="$(patch_perl 7 100)"
start=$(log_lines)
perl "$pl_script" -- -s "$STUB_HOST" --port "$STUB_PORT" --dir "$FIXTURES_DIR" 2>/dev/null || true
sleep 1
assert_uploaded     "$start" "fresh.txt"    "perl/max-age-7d"
assert_not_uploaded "$start" "old.txt"      "perl/max-age-7d"
assert_not_uploaded "$start" "ancient.txt"  "perl/max-age-7d"

echo ""

# ══════════════════════════════════════════════
# POWERSHELL COLLECTORS
# ══════════════════════════════════════════════
if command -v pwsh >/dev/null 2>&1; then
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
else
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
