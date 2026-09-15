# shellcheck shell=bash
# Shared test harness for the collector suites that assert WHERE evidence goes.
#
# Extracted verbatim from run_port_tests.sh, which was the only suite in this repo able to prove
# which peer received bytes -- its python listener writes one "REQ <method> <path>" line per
# request, and that is the mechanism a --server suite needs too. Copying 250 lines of listener into
# a second file would have guaranteed the two drifted; the acceptance gate for this extraction is
# that run_port_tests.sh still reports its full count with 0 failures.
#
# Sourced, never executed. The sourcing suite must set, BEFORE sourcing:
#   TESTS_DIR REPO_ROOT COLLECTOR   (paths)
#   HARNESS_NAME                    (scratch-directory prefix, e.g. ts-server-tests)
# and it owns everything after: its own expectations, its tests and its main().
#
# Provides: LIVE_* config, colours, TESTS_* counters, cleanup+trap, WORK, assert_eq/contains/
# not_contains/le, run_test, section, make_fixtures, run_collector, co_stat, co_endpoint,
# pick_port, write_listener_src, start_listener, wget_only_path, posix_grep_path, refused_port.

HARNESS_NAME="${HARNESS_NAME:-ts-tests}"

# ── Live-tier configuration ───────────────────────────────────────────────────

# THUNDERSTORM_LIVE_* is the shared spelling; the port suite's original
# THUNDERSTORM_PORT_LIVE_* names still work, so anyone's existing invocation keeps running.
LIVE_HOST="${THUNDERSTORM_LIVE_HOST:-${THUNDERSTORM_PORT_LIVE_HOST:-}}"
LIVE_PORT="${THUNDERSTORM_LIVE_PORT:-${THUNDERSTORM_PORT_LIVE_PORT:-443}}"
LIVE_TLS="${THUNDERSTORM_LIVE_TLS:-${THUNDERSTORM_PORT_LIVE_TLS:-1}}"
LIVE_INSECURE="${THUNDERSTORM_LIVE_INSECURE:-${THUNDERSTORM_PORT_LIVE_INSECURE:-1}}"
# shellcheck disable=SC2034  # read by the sourcing suite, not by this file
LIVE_OPEN_WRONG="${THUNDERSTORM_LIVE_OPEN_WRONG:-${THUNDERSTORM_PORT_LIVE_OPEN_WRONG:-80}}"
# shellcheck disable=SC2034  # read by the sourcing suite
LIVE_REFUSED="${THUNDERSTORM_LIVE_REFUSED:-${THUNDERSTORM_PORT_LIVE_REFUSED:-8080}}"
# shellcheck disable=SC2034  # read by the sourcing suite
LIVE_FILTERED="${THUNDERSTORM_LIVE_FILTERED:-${THUNDERSTORM_PORT_LIVE_FILTERED:-8443}}"
LIVE_READY=0

# TLS flags as an array: an argument list is never a string (CLAUDE.md §2).
declare -a LIVE_TLS_OPTS=()
[ "$LIVE_TLS" = "1" ] && LIVE_TLS_OPTS+=("--ssl")
[ "$LIVE_INSECURE" = "1" ] && LIVE_TLS_OPTS+=("--insecure")

# ── Output ────────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BOLD=""; DIM=""; RESET=""
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_NAMES=""

# ── Scratch state ─────────────────────────────────────────────────────────────

WORK=""
FIXTURES=""
ONEFILE=""
declare -a LISTENER_PIDS=()
# shellcheck disable=SC2034  # read by the sourcing suite
LISTENER_PORT_OUT=""   # set by start_listener; never read it through $( )
LISTENER_LOG_OUT=""    # that listener's stderr: "ready", then one "REQ <method> <path>" per request

cleanup() {
    local _rc=$?
    local _pid
    for _pid in ${LISTENER_PIDS[@]+"${LISTENER_PIDS[@]}"}; do
        kill "$_pid" 2>/dev/null || :
        wait "$_pid" 2>/dev/null || :
    done
    if [ -n "$WORK" ]; then
        rm -rf -- "$WORK" 2>/dev/null || :
    fi
    exit "$_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK="$(mktemp -d "${TMPDIR:-/tmp}/${HARNESS_NAME}.XXXXXX")" || {
    echo "ERROR: cannot create a work directory" >&2; exit 1; }

# ── Assertions ────────────────────────────────────────────────────────────────

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        printf "    ${RED}FAIL${RESET}: %s — expected '%s', got '%s'\n" "$label" "$expected" "$actual"
        return 1
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) return 0 ;;
    esac
    printf "    ${RED}FAIL${RESET}: %s — output does not contain '%s'\n" "$label" "$needle"
    printf "    ${DIM}got: %s${RESET}\n" "$(printf '%s' "$haystack" | head -3 | tr '\n' '|')"
    return 1
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            printf "    ${RED}FAIL${RESET}: %s — output unexpectedly contains '%s'\n" "$label" "$needle"
            return 1
            ;;
    esac
}

# assert_le -- numeric upper bound, for the wall-clock budgets. A wrong port that
# starts hanging must fail the suite, not merely make it slow.
assert_ge() {
    local label="$1" min="$2" actual="$3"
    case "$actual" in ''|*[!0-9]*)
        printf "    ${RED}FAIL${RESET}: %s — expected a number, got '%s'\n" "$label" "$actual"; return 1 ;;
    esac
    if [ "$actual" -lt "$min" ]; then
        printf "    ${RED}FAIL${RESET}: %s — expected >= %s, got %s\n" "$label" "$min" "$actual"
        return 1
    fi
}

assert_le() {
    local label="$1" max="$2" actual="$3"
    case "$actual" in ''|*[!0-9]*)
        printf "    ${RED}FAIL${RESET}: %s — expected a number, got '%s'\n" "$label" "$actual"; return 1 ;;
    esac
    if [ "$actual" -gt "$max" ]; then
        printf "    ${RED}FAIL${RESET}: %s — expected <= %s, got %s\n" "$label" "$max" "$actual"
        return 1
    fi
}

# ── Test dispatch ─────────────────────────────────────────────────────────────

# require_test_exists -- a dispatch line naming a function that is not defined is a suite BUG, not
# a result. Round 5 hit this: a patch that failed halfway added the dispatch lines without the
# function bodies, and every one of them ran as "command not found" -- exit 127, which run_test_red
# happily reported as "RED, as documented". A missing test looked exactly like a confirmed defect.
require_test_exists() {
    if ! declare -f "$1" >/dev/null 2>&1; then
        printf "  ${BOLD}%-58s${RESET} ${RED}MISSING${RESET}\n" "$1"
        printf "    no function named '%s' is defined; the dispatch list and the test bodies disagree\n" "$1"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES  - $1 (dispatched but not defined)
"
        return 1
    fi
}

run_test() {
    local name="$1"
    if [ -n "${TEST_FILTER:-}" ] && ! printf '%s\n' "$name" | grep -q "$TEST_FILTER"; then
        return 0
    fi
    require_test_exists "$name" || return 0
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "  ${BOLD}%-58s${RESET}" "$name"
    local _rc=0
    "$name" || _rc=$?
    # 77 = skipped. A test whose preconditions are absent must never report PASS:
    # the live tier is unavailable on most machines, and a suite that turns that
    # into a green tick is worse than one that does not run at all.
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
        FAILED_NAMES="$FAILED_NAMES  - $name
"
    fi
}

section() {
    printf "\n${BOLD}%s${RESET}\n" "$1"
}

# ── Fixtures ──────────────────────────────────────────────────────────────────

# make_fixtures -- the tree every upload case scans. Deliberately tiny: the
# subject under test is the port, so the walk must not dominate the wall-clock
# budgets. Every file is benign and generated here; nothing is committed.
make_fixtures() {
    FIXTURES="$WORK/fixtures"
    mkdir -p "$FIXTURES/nested/deep" || return 1
    printf 'benign port-audit fixture 0123456789 abcdefghijklmnopqrstuvwxyz\n' > "$FIXTURES/plain.txt" || return 1
    printf 'fixture with spaces in the name\n' > "$FIXTURES/name with spaces.txt" || return 1
    printf 'fixture with a non-ascii name\n' > "$FIXTURES/unicode-\xc3\xbc\xc3\xaf.txt" || return 1
    printf 'nested fixture, proves the walk actually ran\n' > "$FIXTURES/nested/deep/file.txt" || return 1
    # A byte-exact binary part, so the happy path proves multipart is binary-safe
    # on the wire and not merely that the exit code was 0.
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256)))' > "$FIXTURES/binary.bin"
    else
        head -c 256 /dev/urandom > "$FIXTURES/binary.bin" 2>/dev/null || printf 'binary\n' > "$FIXTURES/binary.bin"
    fi

    # Single-file tree for the timing cases: wall-clock must measure the port
    # behaviour, never the walk.
    ONEFILE="$WORK/onefile"
    mkdir -p "$ONEFILE" || return 1
    printf 'single fixture for the timing cases\n' > "$ONEFILE/only.txt" || return 1

    # Round 4: FIXTURE_COUNT was a hand-maintained 5 checked against a tree whose five writes
    # were themselves unchecked -- a filesystem that cannot store the non-ASCII name yielded a
    # four-file tree and a suite that then asserted submitted=5 against it. Count what is
    # actually there, and fail here rather than in an unrelated assertion.
    FIXTURE_COUNT="$(find "$FIXTURES" -type f | wc -l | tr -d ' ')"
    [ "$FIXTURE_COUNT" -ge 4 ] || return 1
}

# shellcheck disable=SC2034  # set by make_fixtures, read by the sourcing suite
FIXTURE_COUNT=0

# ── Collector runner ──────────────────────────────────────────────────────────

# Results of the last run_collector, as globals rather than a parsed string: the
# output is multi-line and command substitution would strip trailing newlines.
CO_OUT=""
CO_RC=0
# shellcheck disable=SC2034  # read by the sourcing suite
CO_SECS=0
# shellcheck disable=SC2034  # read by the sourcing suite
CO_MS=0

# now_ms -- milliseconds since the epoch. GNU date has %N; BSD/macOS date does not and prints the
# literal 'N', so fall back to whole seconds rather than producing a nonsense number.
now_ms() {
    local _n
    _n="$(date +%s%N 2>/dev/null)" || _n=""
    case "$_n" in
        ''|*[!0-9]*) printf '%s\n' "$(( $(date +%s) * 1000 ))" ;;
        *)           printf '%s\n' "$(( _n / 1000000 ))" ;;
    esac
}

# run_collector -- run the collector from a private CWD (so a run that writes
# ./thunderstorm.log cannot litter the repo) and record output, status and
# elapsed seconds.
run_collector() {
    local _t0 _t1
    _t0="$(now_ms)"
    # shellcheck disable=SC2034  # CO_RC is read by the sourcing suite's assertions
    CO_OUT="$( cd "$WORK/cwd" && bash "$COLLECTOR" "$@" 2>&1 )" && CO_RC=0 || CO_RC=$?
    _t1="$(now_ms)"
    # shellcheck disable=SC2034  # read by the sourcing suite's timing assertions
    CO_MS=$(( _t1 - _t0 ))
    # shellcheck disable=SC2034  # read by the sourcing suite
    CO_SECS=$(( CO_MS / 1000 ))
}

# run_collector_env -- run_collector with environment assignments, which six call sites in the
# server suite each hand-rolled as a 4-line `CO_OUT="$( cd … && env … )"` -- losing CO_RC's
# meaning and the timing globals every time. Usage: run_collector_env A=1 B=2 -- --server x …
run_collector_env() {
    local -a _env=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --) shift; break ;;
            *=*) _env+=("$1"); shift ;;
            *) break ;;
        esac
    done
    local _t0 _t1
    _t0="$(now_ms)"
    # shellcheck disable=SC2034  # CO_RC is read by the sourcing suite's assertions
    CO_OUT="$( cd "$WORK/cwd" && env "${_env[@]+"${_env[@]}"}" bash "$COLLECTOR" "$@" 2>&1 )" && CO_RC=0 || CO_RC=$?
    _t1="$(now_ms)"
    CO_MS=$(( _t1 - _t0 ))
    # shellcheck disable=SC2034  # read by the sourcing suite
    CO_SECS=$(( CO_MS / 1000 ))
}

# co_stat -- read one key=value counter off the run summary. Anchored on a word
# boundary: an unanchored 'skipped=' also matches inside 'links_skipped='.
co_stat() {
    printf '%s\n' "$CO_OUT" | grep -oE "(^|[[:space:]])$1=[0-9]+" | tail -1 | cut -d= -f2
}

# co_endpoint -- the API endpoint the run actually built.
co_endpoint() {
    printf '%s\n' "$CO_OUT" | grep -m1 'API endpoint:' | sed 's/.*API endpoint: //'
}

# ── Local listeners ───────────────────────────────────────────────────────────

# pick_port -- a free TCP port. Same approach as run_tests.sh:114-128.
pick_port() {
    local port
    if command -v python3 >/dev/null 2>&1; then
        port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)"
        if [ -n "$port" ] && [ "$port" -ge 1 ] 2>/dev/null; then
            printf '%s\n' "$port"
            return 0
        fi
    fi
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 10000-60000 -n 1
    else
        printf '%s\n' "$(( RANDOM % 50000 + 10000 ))"
    fi
}

have_python3() { command -v python3 >/dev/null 2>&1; }

LISTENER_SRC=""

# write_listener_src -- one python3 helper serving every shape the real server
# cannot provide. Written once, into the work directory.
write_listener_src() {
    LISTENER_SRC="$WORK/listener.py"
    cat > "$LISTENER_SRC" <<'PY'
"""Test listeners for the collector's destination suites. One mode per network shape."""
import os
import socket
import sys
import threading
import time

MODE = sys.argv[1]
PORT = int(sys.argv[2])
ARG = sys.argv[3] if len(sys.argv) > 3 else ""
# Bind address. Additive and defaulted, so every existing 3-argument call is unaffected.
# A --server suite needs it twice over: a SECOND loopback address, so "which peer received the
# bytes" is a question the harness can answer at all, and an AF_INET6 socket, because an AF_INET
# listener cannot accept a connection to [::1] -- a passing IPv6 run then looks like a regression.
BIND = sys.argv[4] if len(sys.argv) > 4 else "127.0.0.1"
STATE = {"uploads": 0, "status": 0}
LOCK = threading.Lock()

# Modes that are meant to be REACHABLE: they answer the collector's /api/status preflight with a
# Thunderstorm-shaped body so the test can exercise the upload path behind it. http404 is
# deliberately absent -- it is the "open port, wrong application" case and failing the gate is the
# point. Named rather than repeated inline, because round 4 added seven modes and a mode that
# forgets to join this tuple fails its preflight for a reason no assertion explains.
REACHABLE = (
    "upload404", "redirect", "hdrforge", "nostatus", "ackstr", "ackempty",
    "dieupload", "forgepeer", "ackthenhtml", "radate", "ackpretty", "up500",
    "hostecho", "vhost", "rstupload", "scanid", "up413", "marker500", "tlsack",
    "dieafterbegin", "statusfold", "statusforge", "acknested", "ackbig", "echocred5xx",
)

# The collection markers carry the host's source name and the run statistics. A suite that only
# counts requests cannot tell an "end" marker from an "interrupted" one, so capture the body of
# every POST /api/collection. Bounded, and only for that path: an upload body is a file.
def log_marker_body(first, req):
    if "/api/collection" not in first:
        return
    body = req.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in req else b""
    sys.stderr.write("REQ BODY " + body[:400].decode("latin-1", "replace").replace("\n", " ") + "\n")
    sys.stderr.flush()


def send(conn, status, body=b"", extra=b""):
    conn.sendall(b"HTTP/1.1 " + status + b"\r\nContent-Type: application/json\r\n" + extra
                 + b"Content-Length: %d\r\n\r\n" % len(body) + body)

HTTP_404 = (b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
            b"Content-Length: 19\r\n\r\n404 page not found\n")


def handle(conn):
    try:
        if MODE == "silent":
            # Accept and never answer: bounded by --max-time, not --connect-timeout.
            while conn.recv(65536):
                pass
            return
        if MODE == "nonhttp":
            # An SSH banner, then hold. Does the HTTP status parser misread it?
            conn.sendall(b"SSH-2.0-OpenSSH_9.2p1\r\n")
            conn.recv(65536)
            return
        if MODE in ("bigchunked", "trickle", "prettylate"):
            # Three shapes of a 2xx /api/status body that the round-5 preflight read without any
            # bound. They are handled before the generic recv() below because each has to control
            # the response framing itself.
            #
            # bigchunked: ~8 MB with Transfer-Encoding: chunked and NO Content-Length. Measured on
            #   curl 7.88.1: --max-filesize CANNOT stop this (it needs a declared length), so the
            #   only bound is on our side of the pipe.
            # trickle: headers, then one byte every 200 ms forever. wget's --read-timeout is a
            #   per-read timer that every byte resets, so wget alone has no total bound here.
            # prettylate: a VALID, pretty-printed Thunderstorm status document whose recognised
            #   field sits past the first 4 KB. It must still be recognised -- a read bound set
            #   too tight turns a healthy server into "not a Thunderstorm".
            _req = conn.recv(65536)
            sys.stderr.write("REQ " + _req.split(b"\r\n")[0].decode("latin-1", "replace") + "\n")
            sys.stderr.flush()
            if MODE == "prettylate":
                pad = b"".join(b'  "filler_%06d": "%s",\n' % (i, b"v" * 24) for i in range(900))
                body = b"{\n" + pad + b'  "scanned_samples": 3\n}\n'
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             b"Content-Length: %d\r\n\r\n" % len(body) + body)
                return
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                         b"Transfer-Encoding: chunked\r\n\r\n")
            if MODE == "trickle":
                try:
                    while True:
                        conn.sendall(b"1\r\nx\r\n")
                        time.sleep(0.2)
                except Exception:
                    return
            # NEWLINES matter: the round-5 read was `while read -r line; acc="$acc$line"`, which is
            # only quadratic across MANY lines. An 8 MB single line reads in milliseconds and would
            # have made this test pass against the very code it is meant to pin.
            #
            # And it must be well-formed JSON of FOREIGN keys, not 'x' filler. The identity loop
            # runs json_top_level_out once per key over the retained body, which is O(keys x bytes);
            # filler exits that parser at its first arm (`case "$_r" in \{*)`), so the parse cost it
            # is supposed to bound was never reached and the test passed on the read bound alone.
            # JSON tolerates the newlines between tokens, so both defences stay exercised.
            chunk = b"".join(b'"k%06d":"%s",\n' % (i, b"v" * 46) for i in range(1024))
            try:
                conn.sendall(b"1\r\n{\r\n")
                for _i in range(128):
                    conn.sendall(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                conn.sendall(b"0\r\n\r\n")
            except Exception:
                pass
            return
        req = conn.recv(65536)
        first = req.split(b"\r\n")[0].decode("latin-1", "replace")
        sys.stderr.write("REQ " + first + "\n")
        sys.stderr.flush()
        log_marker_body(first, req)
        if MODE == "hostecho":
            # Which name did the transport put in the Host header? For an IPv6 literal that is
            # the bracketed form, and for a proxied request the request line is absolute -- both
            # are claims this suite makes and neither was observable before.
            #
            # Round 5 also logs EVERY request header, lower-cased, as "HDR <name>: <value>", so a
            # test can assert what the collector sent rather than only what it received. Header
            # names are case-insensitive on the wire, so the assertion must not depend on the
            # transport's choice of capitalisation.
            for line in req.split(b"\r\n")[1:]:
                if not line:
                    break
                if b":" not in line:
                    continue
                name, _, value = line.partition(b":")
                sys.stderr.write("HDR " + name.strip().lower().decode("latin-1", "replace")
                                 + ": " + value.strip().decode("latin-1", "replace") + "\n")
                if name.strip().lower() == b"host":
                    sys.stderr.write("REQ HOST " + value.strip().decode("latin-1", "replace") + "\n")
            sys.stderr.flush()
        if MODE == "proxy":
            # A forward proxy sees the ABSOLUTE form: "POST http://host:port/path HTTP/1.1".
            # Logging it separately is what makes "the bytes went to the proxy, not the origin"
            # an assertion rather than an inference from a log line the collector printed itself.
            sys.stderr.write("REQ PROXY " + first + "\n")
            sys.stderr.flush()
        # Modes that are meant to be REACHABLE answer the collector's /api/status preflight, so
        # the test can still exercise the upload path behind it. http404 deliberately does not:
        # it is the "open port, wrong application" case, and failing the preflight is the point.
        if MODE in REACHABLE and b"/api/status" in req.split(b"\r\n")[0]:
            body = b'{"scanned_samples":0,"queued_async_requests":0}'
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                         b"Content-Length: %d\r\n\r\n" % len(body) + body)
            return
        if MODE in ("http404", "upload404"):
            conn.sendall(HTTP_404)
        elif MODE == "yes200":
            body = b"{}"
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                         b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "hdrforge":
            # A healthy Thunderstorm-shaped answer whose HEADER VALUE contains a status line.
            # An unanchored status parser read this as a 500.
            if b"/api/collection" in req.split(b"\r\n")[0]:
                conn.sendall(HTTP_404)
            else:
                body = b'{"id":7}'
                conn.sendall(b"HTTP/1.1 200 OK\r\nX-Upstream: HTTP/1.1 500 Internal Server Error\r\n"
                             b"Content-Type: application/json\r\n"
                             b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "forgepeer":
            # A healthy Thunderstorm answer carrying a header value shaped exactly like wget's own
            # "Connecting to <host>|<addr>|:<port>... connected." progress line. The collector reads
            # the peer address out of the same file wget writes those headers into, so this is an
            # attempt by the peer to write a different address into the evidence log.
            body = b'{"id":7}'
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                         b"X-Evil: Connecting to evil.example (evil.example)|203.0.113.99|:443... connected.\r\n"
                         b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "dieupload":
            # Acknowledge exactly ONE upload, then take this address out of service. Used to make a
            # mid-run address change deterministic: with two listeners on the same port at two
            # addresses of one name, whichever one the transport picks first stops answering after
            # its first sample, so every later upload must reach the other -- whichever order
            # getaddrinfo happened to return.
            if b"/api/collection" in req.split(b"\r\n")[0]:
                conn.sendall(HTTP_404)
            else:
                body = b'{"id":9001}'
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             b"Content-Length: %d\r\n\r\n" % len(body) + body)
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                conn.close()
                sys.stderr.write("REQ DIEUPLOAD\n")
                sys.stderr.flush()
                import os as _os
                _os._exit(0)
        elif MODE == "ackstr":
            # The reference Go stub's spelling: {"id":"<uuid>"}. Requiring digits here rejected
            # every upload against CI while passing against production.
            if b"/api/collection" in req.split(b"\r\n")[0]:
                conn.sendall(HTTP_404)
            else:
                body = b'{"status":"ok","id":"3f2a9c1e"}'
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "ackempty":
            # Present but empty: not an acknowledgement.
            if b"/api/collection" in req.split(b"\r\n")[0]:
                conn.sendall(HTTP_404)
            else:
                body = b'{"id":""}'
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "nostatus":
            # Reachable (status answers 200, the marker 404s), but a sample upload gets bytes
            # with no status line at all: the collector must fail closed, never count it sent.
            if b"/api/collection" in req.split(b"\r\n")[0]:
                conn.sendall(HTTP_404)
            else:
                conn.sendall(b'{"id":1}\n')
        elif MODE == "connect200":
            # A forward proxy that accepts CONNECT and then drops the tunnel. curl -D keeps this
            # status line in the same file as the origin's; the origin never speaks.
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        elif MODE == "status407":
            send(conn, b"407 Proxy Authentication Required", b"", b"Proxy-Authenticate: Basic realm=\"corp\"\r\n")
        elif MODE == "redirectstatus":
            send(conn, b"302 Found", b"", b"Location: https://127.0.0.1:443/api/status\r\n")
        elif MODE == "ackpretty":
            if b"/api/collection" in first.encode():
                conn.sendall(HTTP_404)
            else:
                send(conn, b"200 OK", b'\n{\n  "id": 5\n}\n')
        elif MODE == "up500":
            if b"/api/collection" in first.encode():
                conn.sendall(HTTP_404)
            else:
                send(conn, b"500 Internal Server Error", b"boom")
        elif MODE == "radate":
            # 503 with an HTTP-date Retry-After: allowed by RFC 9110, not a number.
            if b"/api/collection" in first.encode():
                conn.sendall(HTTP_404)
            else:
                send(conn, b"503 Service Unavailable", b"", b"Retry-After: Fri, 04 Sep 2026 10:00:00 GMT\r\n")
        elif MODE == "ackthenhtml":
            # Acknowledges every upload except the THIRD, which gets a 200 HTML error page.
            if b"/api/collection" in first.encode():
                conn.sendall(HTTP_404)
            else:
                with LOCK:
                    STATE["uploads"] += 1
                    k = STATE["uploads"]
                if k == 3:
                    send(conn, b"200 OK", b"<html>Service temporarily unavailable</html>")
                else:
                    send(conn, b"200 OK", b'{"id":%d}' % k)
        elif MODE == "status503once":
            # The first /api/status is a 503 with Retry-After: 1; everything after is healthy.
            if b"/api/status" in first.encode():
                with LOCK:
                    STATE["status"] += 1
                    n = STATE["status"]
                if n == 1:
                    send(conn, b"503 Service Unavailable", b"", b"Retry-After: 1\r\n")
                else:
                    # A real status document once healthy. It used to answer '{}', which was a
                    # modelling error: no Thunderstorm answers /api/status that way, and once the
                    # collector began requiring the real shape this mode stopped representing a
                    # server that had come back up.
                    send(conn, b"200 OK", b'{"scanned_samples":0,"queued_async_requests":0}')
            elif b"/api/collection" in first.encode():
                conn.sendall(HTTP_404)
            else:
                send(conn, b"200 OK", b'{"id":1}')
        elif MODE in ("hostecho", "tlsack"):
            # Healthy, and identical to ackstr on the wire: these modes differ only in what the
            # harness records (Host header) or how the socket is wrapped (TLS).
            if b"/api/collection" in first.encode():
                conn.sendall(HTTP_404)
            else:
                send(conn, b"200 OK", b'{"status":"ok","id":"3f2a9c1e"}')
        elif MODE == "vhost":
            # 421 unless the Host header names ARG. A local model of a name-based virtual host,
            # which is what makes an IP-literal --server behave differently from the name.
            got = b""
            for line in req.split(b"\r\n")[1:]:
                if line[:5].lower() == b"host:":
                    got = line[5:].strip()
                    break
            want = ARG.encode()
            # Compare the host only: strip a :port and the IPv6 brackets.
            h = got
            if h.startswith(b"["):
                h = h[1:h.index(b"]")] if b"]" in h else h[1:]
            elif b":" in h:
                h = h.rsplit(b":", 1)[0]
            if h.lower() != want.lower():
                send(conn, b"421 Misdirected Request", b'{"error":"wrong host"}')
            elif b"/api/collection" in first.encode():
                conn.sendall(HTTP_404)
            else:
                send(conn, b"200 OK", b'{"id":11}')
        elif MODE == "proxy":
            # Answers whatever the absolute-form URI asks for, so a run through this listener
            # completes normally and the ORIGIN listener can be asserted to have received nothing.
            if "/api/status" in first:
                send(conn, b"200 OK", b'{"scanned_samples":0,"queued_async_requests":0}')
            elif "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                send(conn, b"200 OK", b'{"id":4242}')
        elif MODE == "dieafterbegin":
            # Answer the status gate, answer the begin marker (404 = "not implemented", which the
            # collector warns about and continues past), then leave. Every upload that follows
            # finds a CLOSED port, so the transport never connects and no peer address exists to
            # report. That is the state the literal-fallback guard is for, and the only way to
            # reach it: a listener that dies before the begin marker makes the marker itself fatal,
            # which aborts the run before an upload is ever attempted.
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                conn.close()
                sys.stderr.write("REQ DIEAFTERBEGIN\n")
                sys.stderr.flush()
                os._exit(0)
            else:
                send(conn, b"200 OK", b'{"id":1}')
        elif MODE == "rstupload":
            # The status gate passes; every upload connection is RESET before a byte of response.
            # SO_LINGER 0 makes close() send RST rather than FIN, so the transport reports a
            # connection error rather than an empty 200 -- which is the state in which the
            # collector must claim NO upload peer. (The previous test for that pointed the whole
            # run at a refused port, so it never reached an upload at all and would have passed
            # with the peer machinery deleted.)
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                __import__("struct").pack("ii", 1, 0))
                conn.close()
                return
        elif MODE == "scanid":
            # The begin marker's answer is the SERVER's input into every later request URL.
            # ARG is echoed back as the scan_id, so a hostile or over-long id can be tested.
            if "/api/collection" in first:
                body = b'{"scan_id":"' + ARG.encode() + b'"}'
                send(conn, b"200 OK", body)
            else:
                send(conn, b"200 OK", b'{"id":77}')
        elif MODE == "up413":
            # What production's --file-size-limit is expected to look like on the wire.
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                send(conn, b"413 Payload Too Large", b'{"error":"file too large"}')
        elif MODE == "statushtml":
            # /api/status answers 200 with an HTML page that merely MENTIONS a counter name. The
            # substring gate this replaced accepted it, so a captive portal or a WAF page counted as
            # a Thunderstorm and the collection proceeded against it.
            body = b"<html>unknown metric scanned_samples</html>"
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                         b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "echocred":
            # A peer that echoes the request URL back in its body -- a gateway log line, a captive
            # portal, a proxy error page. When http_proxy carries a credential, that credential is in
            # the bytes the collector is about to quote. NOT in REACHABLE: this body is not a status
            # document, so the preflight must refuse it, and refusing it is what quotes the body.
            body = b"gateway log: http://puser:s3cr3tPW@127.0.0.1:9/ refused"
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                         b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "echocred5xx":
            # The same echo, but on the UPLOAD: /api/status is a healthy status document so the run
            # gets past the gate, then every upload is a 500 whose body carries the credential.
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                body = b"gateway log: http://puser:s3cr3tPW@127.0.0.1:9/ refused"
                conn.sendall(b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\n"
                             b"Content-Length: %d\r\n\r\n" % len(body) + body)
        elif MODE == "acknested":
            # The reverse-proxy shape the audit named: /api/status is passed through to Thunderstorm
            # but /api/checkAsync reaches a different backend, whose ordinary create-response carries
            # the id at depth 2. A substring search for '"id"' accepted this and booked the file.
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                send(conn, b"200 OK", b'{"data":{"id":91}}')
        elif MODE == "ackbig":
            # A VALID acknowledgement placed past the 64 KiB the collector reads. It is not evidence
            # about the peer, so it must be retried, not treated as an impostor -- and it must not
            # latch the withholding gate for the rest of the run.
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                send(conn, b"200 OK", b'{"note":"' + b'x' * 70000 + b'","id":27844}')
        elif MODE == "statusfold":
            # A REFUSED upload (real 503) plus an RFC 9112 obs-fold continuation line -- a header
            # line beginning with SP -- that spells a 200. Raw bytes, not send(), because the whole
            # point is the exact framing. curl -D writes this verbatim, so a parser that strips
            # leading blanks reads the FOLD as the status and books a refused file as submitted.
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                             b"X-Note: harmless\r\n"
                             b" HTTP/1.1 200 OK\r\n"
                             b"Content-Type: application/json\r\n"
                             b"Content-Length: 11\r\n\r\n"
                             b'{"id":4242}')
        elif MODE == "statusforge":
            # The same refusal, but the fake status line is NOT folded: it is an ordinary header
            # line at column 0. wget -S echoes it INDENTED like any other header, so the
            # last-match rule reads 200 -- the wget-path forgery that is still open. curl takes
            # its status from %{http_code} and is unaffected.
            if "/api/collection" in first:
                conn.sendall(HTTP_404)
            else:
                conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                             b"X-Note: harmless\r\n"
                             b"HTTP/1.1 200 OK: forged\r\n"
                             b"Content-Type: application/json\r\n"
                             b"Content-Length: 11\r\n\r\n"
                             b'{"id":4242}')
        elif MODE == "marker500":
            # /api/collection answers 500. The begin marker is FATAL after its one retry, so this
            # is the shape that aborts a whole collection before a file is read.
            if "/api/collection" in first:
                send(conn, b"500 Internal Server Error", b"boom")
            else:
                send(conn, b"200 OK", b'{"id":5}')
        elif MODE == "redirect":
            body = b"moved\n"
            conn.sendall(
                b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:" + ARG.encode()
                + b"/api/checkAsync\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    except OSError:
        pass
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()


srv = socket.socket(socket.AF_INET6 if ":" in BIND else socket.AF_INET)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((BIND, PORT))
srv.listen(16)

# TLS is opt-in through the environment rather than a mode suffix, so every mode above can be
# served over TLS without a second copy of it. TS_TLS_CERT/TS_TLS_KEY come from
# make_selfsigned_cert; without them the socket stays plaintext.
CTX = None
if os.environ.get("TS_TLS_CERT") and os.environ.get("TS_TLS_KEY"):
    import ssl
    CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    CTX.load_cert_chain(os.environ["TS_TLS_CERT"], os.environ["TS_TLS_KEY"])

sys.stderr.write("ready\n")
sys.stderr.flush()


def accept_and_handle(c):
    if CTX is not None:
        try:
            c = CTX.wrap_socket(c, server_side=True)
        except OSError:
            # A failed handshake is the POINT of the no---insecure case: record it so the test can
            # tell "the client refused the certificate" from "nothing ever connected".
            sys.stderr.write("REQ TLSFAIL\n")
            sys.stderr.flush()
            try:
                c.close()
            except OSError:
                pass
            return
    handle(c)


while True:
    try:
        c, _ = srv.accept()
    except OSError:
        break
    threading.Thread(target=accept_and_handle, args=(c,), daemon=True).start()
PY
}

# start_listener_at -- launch one listener on a CALLER-CHOSEN port and wait until it answers.
# $1 bind address, $2 port, $3 mode, $4 extra (the mode's ARG).
#
# Round 4 extracted this from start_listener because two tests already hand-rolled the launch to
# get a fixed port ("two addresses, one port" and "port 80"), each with its own readiness budget
# (15 x 0.2 s vs 25 x 0.2 s) and each overwriting LISTENER_LOG_OUT behind the harness's back.
# One spelling, one budget, one place that registers the pid for teardown.
#
# Sets LISTENER_PORT_OUT, LISTENER_LOG_OUT and LISTENER_PID_OUT. Never call it inside $( ): the
# pid would land in a subshell's copy of LISTENER_PIDS and nothing would ever be killed.
LISTENER_PID_OUT=""
start_listener_at() {
    local bind="$1" port="$2" mode="$3" extra="${4:-}"
    local pid waited
    LISTENER_PORT_OUT=""
    LISTENER_PID_OUT=""
    # A fresh log per listener: the same mode may run several times in one suite, and the
    # readiness grep must not read an earlier instance's "ready". The log also records every
    # request line, so a test can assert how many requests actually reached the peer.
    LISTENER_LOG_OUT="$WORK/listener.$mode.$bind.$port.log"
    : > "$LISTENER_LOG_OUT"
    python3 "$LISTENER_SRC" "$mode" "$port" "$extra" "$bind" >/dev/null 2>"$LISTENER_LOG_OUT" &
    pid=$!
    LISTENER_PIDS+=("$pid")
    waited=0
    while [ "$waited" -lt 25 ]; do
        if grep -q ready "$LISTENER_LOG_OUT" 2>/dev/null; then
            # shellcheck disable=SC2034  # read by the sourcing suite
            LISTENER_PORT_OUT="$port"
            LISTENER_PID_OUT="$pid"
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.2
        waited=$(( waited + 1 ))
    done
    return 1
}

# start_listener -- start_listener_at on a port this function picks. Unchanged contract.
start_listener() {
    local mode="$1" extra="${2:-}" bind="${3:-127.0.0.1}"
    start_listener_at "$bind" "$(pick_port)" "$mode" "$extra"
}

# stop_listener -- end one listener now. Round 4: there was no teardown at all, so LISTENER_PIDS
# only grew and cleanup ran once, at suite exit. With ~13 listener tests that left ~15 idle
# python3 processes and ~15 held ports by the end of a run -- and the port-80 case held a
# PRIVILEGED port for the whole remainder of the suite. A test that binds a fixed or privileged
# port must release it in the same test.
stop_listener() {
    local pid="${1:-$LISTENER_PID_OUT}" i=0
    local -a keep=()
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
    for i in ${LISTENER_PIDS[@]+"${LISTENER_PIDS[@]}"}; do
        [ "$i" = "$pid" ] || keep+=("$i")
    done
    LISTENER_PIDS=(${keep[@]+"${keep[@]}"})
}

# wget_only_path -- build a PATH containing the collector's tools but no curl, so
# the wget transport can be exercised. Uses `type -P` (a real binary) rather than
# `command -v`, which also resolves functions, aliases and builtins.
WGET_ONLY_DIR=""
wget_only_path() {
    local b t
    if [ -n "$WGET_ONLY_DIR" ]; then printf '%s\n' "$WGET_ONLY_DIR"; return 0; fi
    type -P wget >/dev/null 2>&1 || return 1
    WGET_ONLY_DIR="$WORK/nocurl"
    mkdir -p "$WGET_ONLY_DIR" || return 1
    # 'od' is not optional: urlencode (build_query_source -> urlencode) shells out to
    # 'od -An -tx1' for every character outside the unreserved set, and without it the
    # character is silently DROPPED from the query string -- so a shim missing od would
    # test a collector whose --source is quietly mangled.
    for b in wget find mkdir tr wc date grep sed awk cat rm mv cp id hostname sleep \
             head tail cut sort uniq stat uname readlink dirname basename mktemp ls \
             sh bash env touch chmod du seq expr logger od openssl timeout; do
        t="$(type -P "$b" 2>/dev/null || true)"
        [ -n "$t" ] && [ -x "$t" ] && ln -sf "$t" "$WGET_ONLY_DIR/$b"
    done
    [ -x "$WGET_ONLY_DIR/wget" ] && [ -x "$WGET_ONLY_DIR/find" ] || return 1
    printf '%s\n' "$WGET_ONLY_DIR"
}

# posix_grep_path -- a PATH whose `grep` rejects -o, as a non-GNU grep would. The
# collector's status parser WAS `grep -oE` at three call sites, and `grep` was never
# detected; it is now pure parameter expansion (http_status_from_headers). This shim pins
# that a POSIX grep without -o can no longer turn a wrong port into a green run.
POSIX_GREP_DIR=""
posix_grep_path() {
    local b t
    if [ -n "$POSIX_GREP_DIR" ]; then printf '%s\n' "$POSIX_GREP_DIR"; return 0; fi
    POSIX_GREP_DIR="$WORK/nogrepo"
    mkdir -p "$POSIX_GREP_DIR" || return 1
    for b in bash find mkdir tr wc date sed awk cat rm mv cp id hostname sleep head tail \
             cut sort uniq stat uname readlink dirname basename mktemp ls sh env touch \
             chmod du seq expr od curl wget; do
        t="$(type -P "$b" 2>/dev/null || true)"
        [ -n "$t" ] && [ -x "$t" ] && ln -sf "$t" "$POSIX_GREP_DIR/$b"
    done
    t="$(type -P grep)" || return 1
    { printf '#!/bin/sh\n'
      printf '# A POSIX grep: -o is a GNU extension and is refused here.\n'
      printf 'for a in "$@"; do case "$a" in -*o*) exit 2 ;; esac; done\n'
      printf 'exec %s "$@"\n' "$t"
    } > "$POSIX_GREP_DIR/grep.tmp" || return 1
    # rm before mv: every other entry here is a symlink to a REAL binary, and writing through
    # one would truncate the system tool (that accident is on record for /usr/bin/find).
    rm -f "$POSIX_GREP_DIR/grep"
    mv "$POSIX_GREP_DIR/grep.tmp" "$POSIX_GREP_DIR/grep" || return 1
    chmod +x "$POSIX_GREP_DIR/grep" || return 1
    printf '%s\n' "$POSIX_GREP_DIR"
}

require_python3() { have_python3 || return 77; }
require_live() { [ "$LIVE_READY" -eq 1 ] || return 77; }
# probe_live -- is the live tier usable? Asks the server's own status endpoint, so
# an unset host, a firewall, or a server that is down all land on SKIP rather than
# on a wall of red.
#
# Three outcomes, not two, because they need three different messages:
#   0  a Thunderstorm answered            -> run the live tier
#   2  something answered, but not that   -> say so; running the tier would be a wall of red
#      about a service that was never the subject
#   1  nothing to ask, or nothing answered
# Round 4: this used to be `curl -sS -o /dev/null` with no -f, so a 404 or a captive portal's
# 200 flipped LIVE_READY on and turned every live SKIP into a failure attributed to the collector.
PROBE_LIVE_BODY=""
probe_live() {
    PROBE_LIVE_BODY=""
    [ -n "$LIVE_HOST" ] || return 1
    local scheme="http"
    [ "$LIVE_TLS" = "1" ] && scheme="https"
    local -a opts=(-sS -f --connect-timeout 8 --max-time 20)
    [ "$LIVE_INSECURE" = "1" ] && opts+=(-k)
    command -v curl >/dev/null 2>&1 || return 1
    PROBE_LIVE_BODY="$(curl "${opts[@]}" "$scheme://$LIVE_HOST:$LIVE_PORT/api/status" 2>/dev/null)" || return 1
    # /api/status is the one endpoint whose shape both production and the reference stub agree on.
    case "$PROBE_LIVE_BODY" in
        *scanned_samples*|*queued_async_requests*) return 0 ;;
    esac
    return 2
}

# start_listener_on -- start_listener with the bind address FIRST, because a test about where
# evidence goes should read the address before the mode. $1 address, $2 mode, $3 extra.
start_listener_on() {
    start_listener "$2" "${3:-}" "$1"
}

# refused_port -- a port nothing listens on. Round 4: this used to be a bare `pick_port`, whose
# python3 branch does bind-then-close but whose fallback (`shuf`) is an unverified guess that may
# well be listening -- and the docstring claimed the bind either way. Bind it here, in this
# function, so the promise is kept on every branch and on a host without python3.
refused_port() {
    local p
    if have_python3; then
        p="$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)"
        if [ -n "$p" ]; then printf '%s\n' "$p"; return 0; fi
    fi
    # No python3: probe candidates until one refuses a connection. bash's /dev/tcp is a builtin,
    # so this costs no process.
    local i=0
    while [ "$i" -lt 40 ]; do
        p="$(pick_port)"
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then printf '%s\n' "$p"; return 0; fi
        i=$(( i + 1 ))
    done
    return 1
}


# ── Round 4: wire assertions ──────────────────────────────────────────────────
#
# Eleven call sites across the two suites spelled this as an inline
# `assert_eq "…" 0 "$(grep -c '^REQ ' "$log")"`. Three of them differed in whether they trimmed
# whitespace, and `grep -c` on a missing file prints nothing at all, which assert_eq then reports
# as "expected 0, got ''" -- a failure whose message does not say the log was never created.

# req_match -- does one recorded line match ANY of the given globs? No globs means "any line".
#
# Round 4 wrote these helpers taking a single pattern and then called them with 'GET *|POST *',
# on the assumption that a case pattern alternates. It does not: alternation in `case` is
# syntactic and is parsed BEFORE the variable is expanded, so that string matched a line
# containing a literal '|' -- i.e. nothing. One test then compared two zeros and passed.
# Hence: several patterns, as several arguments, matched here.
req_match() {
    local line="$1" pat
    shift
    [ $# -gt 0 ] || return 0
    for pat in "$@"; do
        # shellcheck disable=SC2254  # the pattern is the caller's, deliberately a glob
        case "$line" in $pat) return 0 ;; esac
    done
    return 1
}

# count_req -- how many requests reached one listener. Any further arguments are globs the
# request line must match ('POST /api/checkAsync*', 'HOST *', 'PROXY *', 'BODY *').
count_req() {
    local log="$1" n=0 line
    shift
    [ -f "$log" ] || { printf '0\n'; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        # "REQ <request line>" and "HDR <name>: <value>" are both recorded facts about what
        # arrived; a caller asking for 'HDR cache-control: *' means the header, not the request.
        case "$line" in
            "REQ "*) line="${line#REQ }" ;;
            "HDR "*) ;;
            *)       continue ;;
        esac
        req_match "$line" "$@" || continue
        n=$(( n + 1 ))
    done < "$log"
    printf '%s\n' "$n"
}

# assert_no_req -- NOT ONE request reached any of the named listeners. The load-bearing assertion
# of the whole suite: a refused --server must not put a packet on the wire, and "the run exited 2"
# is not that fact.
assert_no_req() {
    local label="$1" log n
    shift
    for log in "$@"; do
        n="$(count_req "$log")"
        if [ "$n" != "0" ]; then
            printf "    ${RED}FAIL${RESET}: %s — %s request(s) reached %s\n" "$label" "$n" "${log##*/}"
            printf "    ${DIM}%s${RESET}\n" "$(grep '^REQ ' "$log" 2>/dev/null | head -3 | tr '\n' '|')"
            return 1
        fi
    done
}

# req_lines -- the request lines of one listener, in order, pipe-joined. Lets a test assert the
# exact conversation rather than a count: an accidental extra request (a retry, a version probe,
# a followed redirect) is invisible to a count that only has a lower bound.
req_lines() {
    local log="$1" line out=""
    shift
    [ -f "$log" ] || { printf '\n'; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "REQ "*) ;; *) continue ;; esac
        line="${line#REQ }"
        req_match "$line" "$@" || continue
        out="${out:+$out|}$line"
    done < "$log"
    printf '%s\n' "$out"
}

# endpoint_host -- the HOST component of the API endpoint the run built, bracket-aware. A grammar
# test that asserts on a substring of the whole URL passes for a value that merely appears in it;
# this asserts the host itself.
endpoint_host() {
    local url
    url="$(co_endpoint)"
    url="${url#*://}"
    case "$url" in
        \[*) printf '%s\n' "[${url#\[}" | sed 's/\].*/]/' ;;
        *)   printf '%s\n' "${url%%:*}" ;;
    esac
}

# ── Round 4: TLS listeners ────────────────────────────────────────────────────

CERT_OUT=""
KEY_OUT=""
# make_selfsigned_cert -- a certificate for $1 (CN and SAN). Returns 77 when openssl is absent,
# because a missing tool must SKIP, never fail. The cert is deliberately self-signed and untrusted:
# that is what makes "--ssl without --insecure must refuse" testable at all.
make_selfsigned_cert() {
    local cn="${1:-127.0.0.1}"
    [ -n "$CERT_OUT" ] && [ -f "$CERT_OUT" ] && return 0
    command -v openssl >/dev/null 2>&1 || return 77
    CERT_OUT="$WORK/tls-cert.pem"
    KEY_OUT="$WORK/tls-key.pem"
    local san="IP:127.0.0.1,IP:::1,DNS:localhost"
    case "$cn" in *[!0-9.:]*) san="DNS:$cn,$san" ;; esac
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj "/CN=$cn" -addext "subjectAltName=$san" \
        -keyout "$KEY_OUT" -out "$CERT_OUT" >/dev/null 2>&1 || return 77
    [ -s "$CERT_OUT" ] && [ -s "$KEY_OUT" ]
}

# start_listener_tls -- a TLS listener. Same argv as start_listener_at; the cert reaches the
# python process through the environment, so every plaintext mode is available over TLS without a
# second copy of it.
start_listener_tls() {
    local bind="$1" port="$2" mode="$3" extra="${4:-}"
    make_selfsigned_cert "$bind" || return 77
    TS_TLS_CERT="$CERT_OUT" TS_TLS_KEY="$KEY_OUT" start_listener_at "$bind" "$port" "$mode" "$extra"
}

# ── Round 4: signals ──────────────────────────────────────────────────────────
#
# Ported from run_tests.sh:2241-2272. Every signal case needs both: the collector's handler blanks
# its own traps (thunderstorm-collector.sh:570), so a defect there is a HANG, not a failure -- and
# without a slow transport the run finishes before the signal is delivered, which is a test bug
# that looks like a product pass.

# shellcheck disable=SC2034  # read by the sourcing suite
CO_BG_PID=""
# shellcheck disable=SC2034  # read by the sourcing suite
CO_BG_OUT_FILE=""
# run_collector_bg_env -- start a collector run in the background from the private cwd, with
# optional VAR=VAL assignments before a '--'. 'set -m' gives it its own process group and the
# DEFAULT signal disposition: a non-interactive shell starts background jobs with INT ignored, and
# bash cannot trap a signal that was ignored on entry -- which is why every signal test in
# run_tests.sh does the same thing.
#
# CO_BG_OUT_FILE is a FILE, not a variable: the run is still going when the caller wants to look.
run_collector_bg_env() {
    local -a _env=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --) shift; break ;;
            *=*) _env+=("$1"); shift ;;
            *) break ;;
        esac
    done
    CO_BG_OUT_FILE="$WORK/bg.$$.$RANDOM.out"
    : > "$CO_BG_OUT_FILE"
    # NOT `( cd … && env … ) &`. That backgrounds a SUBSHELL, so $! is the subshell's pid and a
    # kill reaches the wrapper, not the collector: the wrapper dies on the default disposition,
    # `wait` reports 143, and the collector keeps running as an orphan. Every assertion about the
    # signal handler then passes because nothing was signalled -- measured, three of them did.
    # `env` execs bash in place, so backgrounding it directly makes $! the collector's own pid.
    local _old="$PWD"
    cd "$WORK/cwd" || return 1
    set -m
    env "${_env[@]+"${_env[@]}"}" bash "$COLLECTOR" "$@" >"$CO_BG_OUT_FILE" 2>&1 &
    # shellcheck disable=SC2034  # read by the sourcing suite
    CO_BG_PID=$!
    set +m
    cd "$_old" || return 1
}

# run_collector_bg -- the no-environment spelling.
run_collector_bg() { run_collector_bg_env -- "$@"; }

# co_bg_out -- what the background run has printed so far.
co_bg_out() { cat "$CO_BG_OUT_FILE" 2>/dev/null; }

# shellcheck disable=SC2034  # read by the sourcing suite
BOUNDED_WAIT_RC=0
# bounded_wait -- wait for $1, at most $2 deciseconds, then SIGKILL and report failure.
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
    # shellcheck disable=SC2034  # read by the sourcing suite
    BOUNDED_WAIT_RC=$?
    return 0
}

# make_slow_curl_path -- a PATH whose curl sleeps before running, so the upload phase lasts long
# enough for a signal to land inside it.
SLOW_CURL_DIRS=""
# make_delayed_curl_path SECONDS TAG -- a curl that sleeps SECONDS before exec'ing the real one.
# make_slow_curl_path is fixed at 0.15 s, which is right for "let the walk start" but far too short
# to land a signal inside a named window of prepare_run. The delay applies to EVERY curl the run
# makes, which is what makes the window wide and predictable.
# path_without TOOL... -- a PATH directory holding a symlink to every tool the collector uses
# EXCEPT the named ones, so "what happens when X is missing" becomes an assertion instead of an
# argument. Symlinks, never shims: writing a shim over a real binary once destroyed /usr/bin/find.
path_without() {
    local skip=" $* " dir b t
    dir="$WORK/without-$(printf '%s' "$*" | tr -c 'a-zA-Z0-9' '_')"
    mkdir -p "$dir" || return 1
    for b in curl wget find mkdir tr wc date grep sed awk cat rm mv cp id hostname sleep \
             head tail cut sort uniq stat uname readlink dirname basename mktemp ls \
             sh bash env touch chmod du seq expr logger od openssl timeout; do
        case "$skip" in *" $b "*) continue ;; esac
        t="$(type -P "$b" 2>/dev/null || true)"
        [ -n "$t" ] && [ -x "$t" ] && ln -sf "$t" "$dir/$b"
    done
    [ -x "$dir/find" ] || return 1
    printf '%s\n' "$dir"
}

make_delayed_curl_path() {
    local secs="$1" dir="$WORK/delayedcurl-$2" real
    real="$(type -P curl)" || return 1
    mkdir -p "$dir" || return 1
    rm -f "$dir/curl"
    { printf '#!/usr/bin/env bash\n'
      printf 'sleep %s\n' "$secs"
      printf 'exec %s "$@"\n' "$real"
    } > "$dir/curl" || return 1
    chmod +x "$dir/curl" || return 1
    SLOW_CURL_DIRS="$SLOW_CURL_DIRS $dir"
    printf '%s\n' "$dir"
}

make_slow_curl_path() {
    local dir="$WORK/slowcurl-$1" real
    real="$(type -P curl)" || return 1
    mkdir -p "$dir" || return 1
    rm -f "$dir/curl"
    { printf '#!/usr/bin/env bash\n'
      printf 'sleep 0.15\n'
      printf 'exec %s "$@"\n' "$real"
    } > "$dir/curl" || return 1
    chmod +x "$dir/curl" || return 1
    SLOW_CURL_DIRS="$SLOW_CURL_DIRS $dir"
    printf '%s\n' "$dir"
}

# ── Round 4: measurement ──────────────────────────────────────────────────────
#
# These produce NUMBERS, and numbers are reported, not asserted -- except against deliberately
# generous ceilings. A frozen fork count is a test that fails on every refactor; an unbounded one
# is how a per-file `$( )` gets added without anyone noticing.

EXEC_LOG_OUT=""
EXEC_COUNTER_DIR=""
# exec_counter_path -- a PATH of counting wrappers. Each appends its own name to EXEC_LOG_OUT and
# then execs the real binary, so the collector under measurement behaves identically. Only tools
# it actually calls are wrapped; anything not listed resolves through the real PATH appended below.
exec_counter_path() {
    local label="${1:-m}" b t
    EXEC_COUNTER_DIR="$WORK/execcount-$label"
    EXEC_LOG_OUT="$WORK/execcount-$label.log"
    mkdir -p "$EXEC_COUNTER_DIR" || return 1
    : > "$EXEC_LOG_OUT"
    for b in curl wget date mktemp od tr wc awk sed grep cat find hostname uname \
             logger openssl timeout id readlink stat du cut sort head tail seq expr; do
        t="$(type -P "$b" 2>/dev/null || true)"
        [ -n "$t" ] && [ -x "$t" ] || continue
        { printf '#!/bin/sh\n'
          printf 'printf %%s\\\\n %s >> %s\n' "$b" "$EXEC_LOG_OUT"
          printf 'exec %s "$@"\n' "$t"
        } > "$EXEC_COUNTER_DIR/$b" || return 1
        chmod +x "$EXEC_COUNTER_DIR/$b" || return 1
    done
    printf '%s\n' "$EXEC_COUNTER_DIR"
}

# exec_count -- total execs recorded, or those of one tool.
exec_count() {
    local n
    [ -f "$EXEC_LOG_OUT" ] || { printf '0\n'; return 0; }
    if [ -n "${1:-}" ]; then
        # `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so `grep -c … || printf 0` emits
        # "0\n0" -- which then reaches `[ … -ge … ]` as a two-line word and produces a raw shell
        # diagnostic. Capture first, default after.
        n="$(grep -c "^$1\$" "$EXEC_LOG_OUT" 2>/dev/null)" || n="${n:-0}"
        printf '%s\n' "${n:-0}"
    else
        wc -l < "$EXEC_LOG_OUT" | tr -d ' '
    fi
}

# exec_breakdown -- "tool:n tool:n …", for the report.
exec_breakdown() {
    [ -f "$EXEC_LOG_OUT" ] || return 0
    sort "$EXEC_LOG_OUT" | uniq -c | sort -rn | awk '{printf "%s:%s ", $2, $1}'
}

# pid_churn -- total process creation, including subshells that never exec (which the counter
# above cannot see). Linux only; the value is only meaningful on an idle host, so callers take a
# minimum of several runs and report rather than assert.
PID_CHURN_START=0
pid_churn_start() {
    [ -r /proc/sys/kernel/ns_last_pid ] || return 77
    PID_CHURN_START="$(cat /proc/sys/kernel/ns_last_pid)"
}
pid_churn_delta() {
    [ -r /proc/sys/kernel/ns_last_pid ] || { printf '0\n'; return 0; }
    local now; now="$(cat /proc/sys/kernel/ns_last_pid)"
    if [ "$now" -ge "$PID_CHURN_START" ]; then printf '%s\n' "$(( now - PID_CHURN_START ))"
    else printf '%s\n' "-1"; fi   # the pid space wrapped: unusable, say so rather than lie
}

# peak_rss_kb -- high-water RSS of a running pid, sampled. Linux only (VmHWM).
peak_rss_kb() {
    local pid="$1" hw=0 v
    [ -r "/proc/$pid/status" ] || { printf '0\n'; return 0; }
    while kill -0 "$pid" 2>/dev/null; do
        v="$(awk '/^VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null)" || v=""
        [ -n "$v" ] && [ "$v" -gt "$hw" ] 2>/dev/null && hw="$v"
        sleep 0.1
    done
    printf '%s\n' "$hw"
}

# ── Round 4: syslog sink ──────────────────────────────────────────────────────

LOGGER_LOG_OUT=""
LOGGER_DIR=""
# logger_capture_path -- a PATH whose `logger` records its full argv instead of writing to syslog.
# --syslog is a documented sink for the destination and for the redaction guarantee, and nothing
# has ever read what it emits.
logger_capture_path() {
    local b t
    [ -n "$LOGGER_DIR" ] && { printf '%s\n' "$LOGGER_DIR"; return 0; }
    LOGGER_DIR="$WORK/loggercap"
    LOGGER_LOG_OUT="$WORK/logger.log"
    mkdir -p "$LOGGER_DIR" || return 1
    : > "$LOGGER_LOG_OUT"
    for b in curl wget find mkdir tr wc date grep sed awk cat rm mv cp id hostname sleep \
             head tail cut sort uniq stat uname readlink dirname basename mktemp ls sh bash \
             env touch chmod du seq expr od openssl timeout; do
        t="$(type -P "$b" 2>/dev/null || true)"
        [ -n "$t" ] && [ -x "$t" ] && ln -sf "$t" "$LOGGER_DIR/$b"
    done
    { printf '#!/bin/sh\n'
      printf '# Capture, do not syslog: the suite must be able to read what the sink was handed.\n'
      printf 'printf %%s\\\\n "$*" >> %s\n' "$LOGGER_LOG_OUT"
      printf 'exit 0\n'
    } > "$LOGGER_DIR/logger.tmp" || return 1
    rm -f "$LOGGER_DIR/logger"
    mv "$LOGGER_DIR/logger.tmp" "$LOGGER_DIR/logger" || return 1
    chmod +x "$LOGGER_DIR/logger" || return 1
    printf '%s\n' "$LOGGER_DIR"
}

# ── Round 4: the suite must not be green by absence ───────────────────────────

# assert_tests_floor -- fail the SUITE when fewer than $1 tests actually executed. run_test
# correctly refuses to count a skip as a pass, but nothing enforced a minimum, so a runner without
# python3 skipped 15 of 35 tests and the suite still exited 0. A destination suite that did not
# run is not a destination suite that passed.
assert_tests_floor() {
    local min="$1"
    # A deliberate TEST_FILTER run is meant to execute a handful of tests; the floor is about a
    # FULL run that quietly executed almost nothing.
    [ -n "${TEST_FILTER:-}" ] && return 0
    if [ "$TESTS_RUN" -lt "$min" ]; then
        printf "${RED}Only %d tests executed; this suite requires at least %d${RESET}\n" "$TESTS_RUN" "$min"
        printf "${DIM}(%d skipped — missing python3, openssl, IPv6 loopback or the live host)${RESET}\n" "$TESTS_SKIPPED"
        return 1
    fi
}

# ── Round 4: environment preconditions ────────────────────────────────────────
#
# An absent environment feature must SKIP. Round 4 found the same precondition treated as a skip
# in one test and a hard failure in another (`start_listener_on '::1' … || return 1` vs
# `|| return 77`), so a runner without IPv6 loopback produced red attributed to the collector.
# These name the precondition explicitly, so the skip message is about the runner, not the subject.

require_ipv6_loopback() {
    have_python3 || return 77
    python3 -c 'import socket,sys
try:
    s=socket.socket(socket.AF_INET6); s.bind(("::1",0)); s.close()
except OSError:
    sys.exit(1)' 2>/dev/null || return 77
}

require_second_loopback() {
    have_python3 || return 77
    python3 -c 'import socket,sys
try:
    s=socket.socket(); s.bind(("127.0.0.2",0)); s.close()
except OSError:
    sys.exit(1)' 2>/dev/null || return 77
}

require_privileged_port() {
    have_python3 || return 77
    python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try:
    s.bind(("127.0.0.1",80))
except OSError:
    sys.exit(1)
s.close()' 2>/dev/null || return 77
}

require_both_families_for_localhost() {
    have_python3 || return 77
    # Ask what the TRANSPORT asks. `getent hosts` returns only the first match, which skipped a
    # test on a host that does have both families; getaddrinfo() is what curl and wget call.
    python3 -c 'import socket,sys
fams={ai[0] for ai in socket.getaddrinfo("localhost", 80, proto=socket.IPPROTO_TCP)}
sys.exit(0 if {socket.AF_INET, socket.AF_INET6} <= fams else 1)' 2>/dev/null || return 77
}

# count_files -- how many files under $1 match $2, one level deep. Not `find | wc -l`: BSD/macOS
# `wc` pads its output with leading spaces and command substitution strips only trailing newlines,
# so `assert_eq 0 "       0"` fails there for a reason that has nothing to do with the collector.
count_files() {
    local dir="$1" pat="${2:-*}" n=0 f
    [ -d "$dir" ] || { printf '0\n'; return 0; }
    for f in "$dir"/$pat; do
        [ -e "$f" ] && n=$(( n + 1 ))
    done
    printf '%s\n' "$n"
}

# ── Round 4: red-first dispatch ───────────────────────────────────────────────
#
# This round assesses; it does not fix. A test that pins a CONFIRMED defect therefore fails
# against the current collector, and there are only three honest things to do with it: delete it
# (losing the evidence), invert it to assert the defective behaviour (which then has to be
# rewritten when the defect is fixed, and reads as if the behaviour were intended), or dispatch it
# as expected-red. This is the third.
#
# The important half is the ELSE branch: a red-first test that starts PASSING fails the suite. That
# is what stops "expected to fail" from decaying into "nobody looks at it" -- either the defect was
# fixed, in which case the finding must be re-classified and the test moved to run_test, or the
# test stopped exercising what it was written for.
TESTS_RED=0
RED_NAMES=""
run_test_red() {
    local name="$1" finding="$2"
    if [ -n "${TEST_FILTER:-}" ] && ! printf '%s\n' "$name" | grep -q "$TEST_FILTER"; then
        return 0
    fi
    require_test_exists "$name" || return 0
    printf "  ${BOLD}%-58s${RESET}" "$name"
    local _rc=0
    # The assertion diagnostics of an expected-red test are noise, not news: the finding text is
    # the news. Capture them so the summary line stays readable, and show them only under
    # TEST_VERBOSE=1.
    local _diag
    _diag="$("$name" 2>&1)" || _rc=$?
    if [ "$_rc" -eq 77 ]; then
        printf " ${YELLOW}SKIP${RESET}\n"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        return 0
    fi
    if [ "$_rc" -ne 0 ]; then
        printf " ${YELLOW}RED${RESET} (%s, as documented)\n" "$finding"
        [ "${TEST_VERBOSE:-0}" = "1" ] && printf '%s\n' "$_diag"
        TESTS_RED=$((TESTS_RED + 1))
        RED_NAMES="$RED_NAMES  - $name ($finding)
"
        return 0
    fi
    printf " ${RED}UNEXPECTED PASS${RESET}\n"
    printf "    %s no longer reproduces: either it was fixed (re-classify the finding and move this\n" "$finding"
    printf "    test to run_test) or the test stopped exercising it.\n"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES  - $name (expected-red test passed unexpectedly)
"
}

# make_slow_hostname_path -- a PATH whose `hostname` sleeps before answering.
#
# The window between "the signal traps are installed" (file scope) and "a destination has been
# validated" (validate_config) is normally microseconds wide, which is why the gate on it is tested
# by sourcing the collector as a library. An executable-process test needs the window to be real:
# detect_source_name runs immediately BEFORE validate_config and forks `hostname`, so slowing that
# one tool opens the window legitimately -- without relying on a defect to do it.
#
# (Round 4's first version of that test used the quadratic validator as its window. Fixing the
# quadratic behaviour closed the window and the test went SKIP -- an instrument built out of the
# defect it was meant to outlive.)
SLOW_HOSTNAME_DIR=""
make_slow_hostname_path() {
    local real
    [ -n "$SLOW_HOSTNAME_DIR" ] && { printf '%s\n' "$SLOW_HOSTNAME_DIR"; return 0; }
    real="$(type -P hostname)" || return 1
    SLOW_HOSTNAME_DIR="$WORK/slowhostname"
    mkdir -p "$SLOW_HOSTNAME_DIR" || return 1
    rm -f "$SLOW_HOSTNAME_DIR/hostname"
    { printf '#!/usr/bin/env bash\n'
      printf 'sleep 3\n'
      printf 'exec %s "$@"\n' "$real"
    } > "$SLOW_HOSTNAME_DIR/hostname" || return 1
    chmod +x "$SLOW_HOSTNAME_DIR/hostname" || return 1
    printf '%s\n' "$SLOW_HOSTNAME_DIR"
}

# ── Round 5: what did the transport actually receive? ─────────────────────────
#
# exec_counter_path records WHICH tools ran; this records the ARGV they ran with. Round 5 needed it
# because two curl options (--suppress-connect-headers, --resolve) sat behind a
# `[ "$UPLOAD_TOOL" = "curl" ]` guard that was evaluated before the tool was detected, so they were
# never passed at all -- and no test could see it, because both are invisible in the run's output.
# An option that decides where evidence goes must be assertable at the point it is handed over.
# NEVER call this in $( ): it sets CURL_ARGV_LOG_OUT, and a command substitution would set it in a
# subshell, leaving the caller with an empty path -- the assertions then silently pass or silently
# fail against a file that does not exist. Round 5 made that mistake three times (here, in
# exec_counter_path and in start_listener). Call it directly and read CURL_ARGV_DIR.
CURL_ARGV_LOG_OUT=""
CURL_ARGV_DIR=""
curl_argv_capture_path() {
    local real
    [ -n "$CURL_ARGV_DIR" ] && { printf '%s\n' "$CURL_ARGV_DIR"; return 0; }
    real="$(type -P curl)" || return 1
    CURL_ARGV_DIR="$WORK/curlargv"
    CURL_ARGV_LOG_OUT="$WORK/curlargv.log"
    mkdir -p "$CURL_ARGV_DIR" || return 1
    : > "$CURL_ARGV_LOG_OUT"
    rm -f "$CURL_ARGV_DIR/curl"
    { printf '#!/usr/bin/env bash\n'
      printf '# Record the argv, one invocation per line, then behave exactly like curl.\n'
      printf 'printf "%%s\\\\n" "$*" >> %s\n' "$CURL_ARGV_LOG_OUT"
      printf 'exec %s "$@"\n' "$real"
    } > "$CURL_ARGV_DIR/curl" || return 1
    chmod +x "$CURL_ARGV_DIR/curl" || return 1
    printf '%s\n' "$CURL_ARGV_DIR"
}

# curl_argv_has -- did any recorded curl invocation carry $1 (a glob)?
curl_argv_has() {
    local line
    [ -f "$CURL_ARGV_LOG_OUT" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        # shellcheck disable=SC2254  # caller's glob
        case "$line" in $1) return 0 ;; esac
    done < "$CURL_ARGV_LOG_OUT"
    return 1
}
