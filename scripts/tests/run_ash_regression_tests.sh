#!/bin/sh
#
# Ash / POSIX sh regression tests
#
# Focused tests for startup and transport-selection regressions that are hard to
# exercise via the stub-backed suites:
#   1. Default scan roots remain split into individual directories
#   2. Optional /api/collection markers do not abort when wget gets 404/501
#   3. nc-only environments continue without collection markers
#   4. HTTPS refuses nc-only upload setups up front

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
COLLECTOR="$REPO_ROOT/scripts/thunderstorm-collector-ash.sh"

PASS=0
FAIL=0
SKIP=0

if [ -t 1 ]; then
    GREEN=$(printf '\033[0;32m')
    RED=$(printf '\033[0;31m')
    YELLOW=$(printf '\033[1;33m')
    BOLD=$(printf '\033[1m')
    RESET=$(printf '\033[0m')
else
    GREEN=''
    RED=''
    YELLOW=''
    BOLD=''
    RESET=''
fi

pass() {
    PASS=$((PASS + 1))
    printf "  %sPASS%s %s\n" "$GREEN" "$RESET" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "  %sFAIL%s %s\n" "$RED" "$RESET" "$1"
}

skip() {
    SKIP=$((SKIP + 1))
    printf "  %sSKIP%s %s\n" "$YELLOW" "$RESET" "$1"
}

cleanup() {
    [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

detect_ash_shell() {
    if command -v ash >/dev/null 2>&1; then
        command -v ash
        return 0
    fi
    if command -v dash >/dev/null 2>&1; then
        command -v dash
        return 0
    fi
    if command -v busybox >/dev/null 2>&1; then
        printf '%s sh\n' "$(command -v busybox)"
        return 0
    fi
    if command -v sh >/dev/null 2>&1; then
        command -v sh
        return 0
    fi
    return 1
}

ASH_CMD="${ASH_SHELL:-$(detect_ash_shell 2>/dev/null || true)}"
if [ -z "$ASH_CMD" ]; then
    skip "no ash/dash/busybox sh available"
    exit 0
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ash-regression-tests.XXXXXX")

run_ash() {
    # Intentionally rely on word splitting so "<busybox-path> sh" works.
    # shellcheck disable=SC2086
    set -- $ASH_CMD "$COLLECTOR" "$@"
    "$@"
}

link_tool() {
    _dest_dir=$1
    _tool=$2
    _tool_path=$(command -v "$_tool" 2>/dev/null || true)
    [ -n "$_tool_path" ] && ln -s "$_tool_path" "$_dest_dir/$_tool"
}

make_minimal_path() {
    _name=$1
    _dir="$TMP_ROOT/$_name"
    mkdir -p "$_dir"
    for _tool in cat date grep head hostname id mktemp od rm sed tail tr uname wc sleep; do
        link_tool "$_dir" "$_tool"
    done
    printf '%s\n' "$_dir"
}

write_fake_find() {
    _dir=$1
    cat > "$_dir/find" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$_dir/find"
}

write_fake_nc() {
    _dir=$1
    cat > "$_dir/nc" <<'EOF'
#!/bin/sh
cat >/dev/null
printf 'HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n'
EOF
    chmod +x "$_dir/nc"
}

write_fake_wget_404() {
    _dir=$1
    cat > "$_dir/wget" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
    printf 'GNU Wget 1.21\n'
    exit 0
fi
printf '  HTTP/1.1 404 Not Found\n' >&2
exit 8
EOF
    chmod +x "$_dir/wget"
}

contains() {
    _needle=$1
    _haystack=$2
    printf '%s' "$_haystack" | grep -F -- "$_needle" >/dev/null 2>&1
}

test_default_dirs_are_split() {
    _fakebin=$(make_minimal_path default-dirs)
    write_fake_find "$_fakebin"

    _out=$(PATH="$_fakebin:$PATH" run_ash \
        --server 127.0.0.1 --dry-run --no-log-file --no-progress --debug 2>&1)
    _rc=$?

    if [ "$_rc" -ne 0 ]; then
        fail "ash/default-dirs: collector exited with $_rc"
        return
    fi
    if contains "Skipping non-directory path '/root /tmp /home /var /usr'" "$_out"; then
        fail "ash/default-dirs: default roots collapsed into one invalid path"
        return
    fi
    if ! contains "Scanning '/tmp'" "$_out"; then
        fail "ash/default-dirs: expected /tmp to be processed as its own scan root"
        return
    fi
    if ! contains "Run completed:" "$_out"; then
        fail "ash/default-dirs: collector did not complete normally"
        return
    fi
    pass "ash/default-dirs: default roots processed individually"
}

test_wget_404_marker_is_optional() {
    _fakebin=$(make_minimal_path wget-404)
    write_fake_find "$_fakebin"
    write_fake_wget_404 "$_fakebin"

    _out=$(PATH="$_fakebin" run_ash \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress --debug 2>&1)
    _rc=$?

    if [ "$_rc" -ne 0 ]; then
        fail "ash/wget-404-marker: collector exited with $_rc"
        return
    fi
    if ! contains "Collection marker 'begin' not supported (HTTP 404)" "$_out"; then
        fail "ash/wget-404-marker: missing optional-marker warning for HTTP 404"
        return
    fi
    if contains "Cannot connect to Thunderstorm server" "$_out"; then
        fail "ash/wget-404-marker: begin marker was still treated as fatal"
        return
    fi
    if ! contains "Run completed:" "$_out"; then
        fail "ash/wget-404-marker: collector did not continue after optional marker failure"
        return
    fi
    pass "ash/wget-404-marker: unsupported /api/collection stays non-fatal"
}

test_nc_only_marker_is_optional() {
    _fakebin=$(make_minimal_path nc-only)
    write_fake_find "$_fakebin"
    write_fake_nc "$_fakebin"

    _out=$(PATH="$_fakebin" run_ash \
        --server 127.0.0.1 --port 8080 --no-log-file --no-progress --debug 2>&1)
    _rc=$?

    if [ "$_rc" -ne 0 ]; then
        fail "ash/nc-marker: collector exited with $_rc"
        return
    fi
    if ! contains "Skipping collection marker 'begin': curl or wget is required for /api/collection" "$_out"; then
        fail "ash/nc-marker: missing nc-only collection-marker warning"
        return
    fi
    if ! contains "Run completed:" "$_out"; then
        fail "ash/nc-marker: collector did not continue in nc-only mode"
        return
    fi
    pass "ash/nc-marker: nc-only systems continue without collection markers"
}

test_https_rejects_nc_only() {
    _fakebin=$(make_minimal_path https-nc-only)
    write_fake_find "$_fakebin"
    write_fake_nc "$_fakebin"

    _out=$(PATH="$_fakebin" run_ash \
        --server 127.0.0.1 --port 8080 --ssl --no-log-file --no-progress --debug 2>&1 || true)

    if ! contains "HTTPS uploads require 'curl' or 'wget'; 'nc' does not support TLS" "$_out"; then
        fail "ash/https-nc-only: missing fail-fast TLS uploader error"
        return
    fi
    pass "ash/https-nc-only: HTTPS refuses nc-only upload setups"
}

printf "\n%sAsh Regression Tests%s\n" "$BOLD" "$RESET"
printf "============================================\n"
printf " Shell: %s\n" "$ASH_CMD"
printf "============================================\n\n"

test_default_dirs_are_split
test_wget_404_marker_is_optional
test_nc_only_marker_is_optional
test_https_rejects_nc_only

printf "\n============================================\n"
printf " Results: %s%d passed%s, %s%d failed%s, %s%d skipped%s\n" \
    "$GREEN" "$PASS" "$RESET" \
    "$RED" "$FAIL" "$RESET" \
    "$YELLOW" "$SKIP" "$RESET"
printf "============================================\n"

[ "$FAIL" -eq 0 ]
