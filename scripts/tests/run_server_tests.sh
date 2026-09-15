#!/usr/bin/env bash
#
# --server suite for the Bash Thunderstorm collector.
#
# --server is the only input that decides WHERE a collection is uploaded, and until this round it
# was the least defended flag in the file: one non-empty check that the compiled-in default
# ("ygdrasil.nextron", a Nextron-internal name that RESOLVES) made unreachable, and a raw
# interpolation into "<scheme>://<server>:<port>". Six value shapes therefore delivered the
# evidence to a host the operator never named while the run printed "submitted=1 failed=0" and
# exited 0 -- satisfying the whole defensive stack the --port round added, because the wrong peer
# answered all of it. Reproduced before the fix, each against a recording listener:
#
#   --server 'name@127.0.0.1'  -> evidence to 127.0.0.1, and 'name' transmitted to it as the HTTP
#                                 Basic username; under --quiet --no-log-file the entire output was
#                                 407 bytes of ASCII banner, so nothing recorded the destination
#   --server '127.0.0.1/'      -> "[info] Port: 41791" printed as fact while a listener on port 80
#                                 received the evidence (the port became a path segment)
#   --server '127.0.0.1#x'     -> peer log for a whole run was "GET /, POST /, POST /": /api/status,
#                                 /api/collection and /api/checkAsync were never requested
#   --server '0177.0.0.1'      -> "Server: 0177.0.0.1" logged, 127.0.0.1 contacted; getaddrinfo(3)
#                                 still honours inet_aton's legacy forms, so '010.0.0.9' reaches
#                                 8.0.0.9 and '2130706433' reaches 127.0.0.1
#   --server '127.0.0.[1-2]'   -> ONE curl invocation transferred to both hosts
#   --server '::1'             -> built "http://::1:8080" and reported an unreachable server, for a
#                                 value the Go client connects with
#
# What this suite pins, by axis:
#   A  --server is REQUIRED (exit 2), exempt only under --dry-run, and there is no default at all
#   B  the accepted grammar, positively and negatively, offline: a host name, an IPv4 dotted quad
#      or an IPv6 literal, and nothing that could mean two things
#   C  the WIRE: a refused value must not produce a single request, at any listener
#   D  an IPv6 --server actually delivers, over a real AF_INET6 peer
#   E  the run records the address that answered, identically on both transports
#   F  observability, and that a usage error still leaves nothing on disk
#
# Usage:
#   scripts/tests/run_server_tests.sh                 # offline + local-listener tiers
#   THUNDERSTORM_LIVE_HOST=thunderstorm.example \
#     scripts/tests/run_server_tests.sh               # adds the live tier
#
# Exit: 0 all passed, 1 any failed. A test body returning 77 is SKIP (automake convention, as in
# run_tests.sh and run_port_tests.sh) and is never counted as a pass.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
# COLLECTOR_OVERRIDE exists to answer the one question a green test cannot: CAN it fail? Point it at
# a copy of the collector that still carries the defect and the test must go red. Every test added
# in round 9 was checked that way, and the check caught four assertions written against a helper
# (assert_ne) this harness does not have -- which would have made three of them pass for the wrong
# reason and turned a documented-red into a fake red.
COLLECTOR="${COLLECTOR_OVERRIDE:-$REPO_ROOT/scripts/bash/thunderstorm-collector.sh}"

[ -r "$COLLECTOR" ] || { echo "ERROR: collector not readable at $COLLECTOR" >&2; exit 1; }

# ── Shared harness ────────────────────────────────────────────────────────────
# Listeners, assertions, dispatch and fixtures are shared with run_port_tests.sh so the two
# suites cannot drift apart. See scripts/tests/lib/harness.sh.
# shellcheck disable=SC2034  # read by lib/harness.sh when it is sourced below
HARNESS_NAME="ts-server-tests"
# shellcheck source=lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"

# ── Shared expectations ───────────────────────────────────────────────────────

# offline_server -- a dry run against the one-file tree with a FIXED, valid port, for parsing,
# validation and URL composition. A REFUSED value never reaches the network. An ACCEPTED one does:
# a dry run still checks the destination, and the failure to reach it is reported, not fatal.
#
# Note it is deliberately --dry-run: --server validation is NOT conditional on a run reaching the
# network. A destination that could mean two things is a usage error whether or not anything is
# about to be sent, so the same message and the same exit code appear in both modes.
offline_server() {
    run_collector --port 8080 --no-log-file --dry-run --no-progress --dir "$ONEFILE" "$@"
}

# expect_server_reject -- the value must be refused as a usage error (exit 2) with the named
# message. The message is asserted, not just the status: "rejected" is not the same fact as
# "rejected for the right reason", and for this flag the reason is what teaches the operator what
# to type instead.
expect_server_reject() {
    local label="$1" value="$2" msg="$3"
    offline_server --server "$value"
    assert_eq "$label: exit code" 2 "$CO_RC" || return 1
    assert_contains "$label: message" "$msg" "$CO_OUT" || return 1
    # A refused value must never reach URL composition.
    assert_not_contains "$label: no endpoint announced" "API endpoint: http" "$CO_OUT" || return 1
    # A raw shell diagnostic must never reach the operator.
    assert_not_contains "$label: no raw shell error" "integer expression expected" "$CO_OUT" || return 1
    assert_not_contains "$label: no raw shell error" "unary operator expected" "$CO_OUT" || return 1
    assert_not_contains "$label: no raw shell error" "bad substitution" "$CO_OUT" || return 1
}

# expect_server_accept -- the value must be accepted, and the host must reach the URL in the
# spelling $3. That second half is the point: for an IPv6 literal the URL form is bracketed, and
# for everything else it must be byte-identical to what the operator typed. A collector that
# rewrites a host it was given is as wrong as one that accepts a URL.
expect_server_accept() {
    local label="$1" value="$2" urlhost="$3"
    offline_server --server "$value"
    assert_eq "$label: exit code" 0 "$CO_RC" || return 1
    assert_contains "$label: logged server" "Server: $value" "$CO_OUT" || return 1
    assert_contains "$label: url host" "API endpoint: http://${urlhost}:8080/api/" "$CO_OUT" || return 1
}

# old_curl_path -- a PATH whose `curl` does not understand '-w', as every curl before 7.29 does
# not: it echoes the format string back on stdout and runs the transfer normally. The collector
# reads its peer address through '-w %{remote_ip}', so without a guard this is what would make it
# print "Server answered from %{remote_ip}" as though that were a peer.
OLD_CURL_DIR=""
old_curl_path() {
    local b t real
    if [ -n "$OLD_CURL_DIR" ]; then printf '%s\n' "$OLD_CURL_DIR"; return 0; fi
    real="$(type -P curl 2>/dev/null || true)"
    [ -n "$real" ] || return 1
    OLD_CURL_DIR="$WORK/oldcurl"
    mkdir -p "$OLD_CURL_DIR" || return 1
    for b in find mkdir tr wc date grep sed awk cat rm mv cp id hostname sleep head tail cut \
             sort uniq stat uname readlink dirname basename mktemp ls sh bash env touch chmod \
             du seq expr logger od timeout wget; do
        t="$(type -P "$b" 2>/dev/null || true)"
        [ -n "$t" ] && [ -x "$t" ] && ln -sf "$t" "$OLD_CURL_DIR/$b"
    done
    { printf '#!/bin/sh\n'
      printf '# A curl older than 7.29: -w is unknown, so the format is echoed back verbatim.\n'
      printf 'count=$#\n'
      printf 'while [ "$count" -gt 0 ]; do\n'
      printf '    a="$1"; shift\n'
      printf '    if [ "$a" = "-w" ]; then shift; count=$(( count - 2 )); printf %s; continue; fi\n' "'%%{remote_ip}\\n'"
      printf '    set -- "$@" "$a"; count=$(( count - 1 ))\n'
      printf 'done\n'
      printf 'exec %s "$@"\n' "$real"
    } > "$OLD_CURL_DIR/curl.tmp" || return 1
    # rm before mv: every other entry here is a symlink to a real binary, and writing through one
    # would truncate the system tool.
    rm -f "$OLD_CURL_DIR/curl"
    mv "$OLD_CURL_DIR/curl.tmp" "$OLD_CURL_DIR/curl" || return 1
    chmod +x "$OLD_CURL_DIR/curl" || return 1
    printf '%s\n' "$OLD_CURL_DIR"
}

# ── Axis A — --server is required, and there is no default ────────────────────

test_a_missing_server_refused() { # THE finding this round exists for. A run with no --server used
                                # to adopt a compiled-in Nextron-internal host that resolves, so a
                                # forgotten flag was not a usage error: the collector dialled vendor
                                # infrastructure from a customer host on its own initiative.
                                run_collector --port 8080 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a missing --server is a usage error" 2 "$CO_RC" || return 1
                                assert_contains "and names the flag" "pass -s/--server <host>" "$CO_OUT" || return 1
                                assert_contains "and says when it is optional" "required unless --dry-run" "$CO_OUT" || return 1
                                # Nothing may be announced as a destination, and the removed
                                # internal host name must not reappear in any message.
                                assert_not_contains "no endpoint" "API endpoint: http" "$CO_OUT" || return 1
                                assert_not_contains "no vendor host in the message" "nextron" "$CO_OUT" || return 1
                                assert_not_contains "the run does not start" "Run completed" "$CO_OUT"; }

test_a_dry_run_is_exempt()      { # Mirrors go/main.go:134, "required unless using --dry-run": a
                                # dry run reads files and sends nothing, so it needs no destination.
                                run_collector --dry-run --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a dry run needs no server" 0 "$CO_RC" || return 1
                                assert_contains "and says so plainly" "Server: none given (--dry-run)" "$CO_OUT" || return 1
                                # "http://:8080/api/..." is a URL that names no host. Printing it
                                # would be a false statement about the destination, harmless run or
                                # not, so the endpoint line must say there is none.
                                assert_contains "no endpoint is invented" "API endpoint: none" "$CO_OUT" || return 1
                                assert_not_contains "no hostless URL" "http://:" "$CO_OUT" || return 1
                                assert_contains "and it still ran, unmistakably as a dry run" "Dry-run completed" "$CO_OUT"; }

test_a_empty_value_is_distinct() { # An empty value and a forgotten flag are different mistakes and
                                # must not share one message: require_value catches the first at
                                # parse time, validate_config the second.
                                offline_server --server ""
                                assert_eq "exit code" 2 "$CO_RC" || return 1
                                assert_contains "empty value names itself" "Empty value for --server" "$CO_OUT" || return 1
                                assert_not_contains "and is not the forgotten-flag message" "pass -s/--server" "$CO_OUT"; }

test_a_no_compiled_in_default() { # A guard against reintroduction, asserted on the SOURCE because
                                # that is where the defect lived: a default here is a default
                                # DESTINATION FOR EVIDENCE. The whole repo carried this literal in
                                # three files; this pins the one that is a CLI contract.
                                local src; src="$(cat "$COLLECTOR")"
                                assert_contains "the variable is still assigned (sourced as a library)" 'THUNDERSTORM_SERVER=""' "$src" || return 1
                                assert_not_contains "and carries no vendor-internal default" "ygdrasil" "$src"; }

test_a_env_is_ignored_and_named() { # An exported THUNDERSTORM_SERVER is deliberately NOT honoured --
                                # the environment must not be able to redirect evidence -- but it is
                                # announced rather than dropped in silence. With no --server the
                                # sentence used to end in an empty interpolation ("the server is ").
                                CO_OUT=""; CO_RC=0
                                CO_OUT="$( cd "$WORK/cwd" && env THUNDERSTORM_SERVER=evil.example \
                                    bash "$COLLECTOR" --dry-run --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && CO_RC=0 || CO_RC=$?
                                assert_contains "named and ignored" "THUNDERSTORM_SERVER='evil.example' is set in the environment and was IGNORED" "$CO_OUT" || return 1
                                assert_contains "and the sentence completes" "the server is none given (--dry-run" "$CO_OUT" || return 1
                                assert_not_contains "the environment never becomes the destination" "Server: evil.example" "$CO_OUT" || return 1
                                # The OTHER branch of that same parameter expansion: with --server
                                # given, the sentence must name the FLAG's value as the destination.
                                # Only the default branch was covered, so the branch an operator
                                # actually hits in the field was never exercised.
                                CO_OUT=""; CO_RC=0
                                CO_OUT="$( cd "$WORK/cwd" && env THUNDERSTORM_SERVER=evil.example \
                                    bash "$COLLECTOR" --server ts.example --port 8080 --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && CO_RC=0 || CO_RC=$?
                                assert_contains "still named and ignored" "was IGNORED" "$CO_OUT" || return 1
                                assert_contains "and the flag's value is the destination" "the server is ts.example (use --server)" "$CO_OUT" || return 1
                                assert_not_contains "the environment is never the destination" "Server: evil.example" "$CO_OUT" || return 1
                                # A credential exported by mistake must not reach the log or syslog.
                                CO_OUT="$( cd "$WORK/cwd" && env THUNDERSTORM_SERVER='svc:S3cr3t@evil.example' \
                                    bash "$COLLECTOR" --server ts.example --port 8080 --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" || :
                                assert_not_contains "an exported credential is redacted" "S3cr3t" "$CO_OUT" || return 1
                                assert_contains "and the rest of the value is still named" "<redacted>@evil.example" "$CO_OUT"; }

# ── Axis B — the grammar, offline ─────────────────────────────────────────────

test_b_url_shapes_refused()     { # Every character that can END a URL authority moves the
                                # destination. Each of these was a green run before the fix.
                                expect_server_reject "userinfo"        'ts.example@127.0.0.1'   "contains '@'" || return 1
                                expect_server_reject "scheme"          'https://ts.example'     "is a URL, not a host" || return 1
                                expect_server_reject "scheme+port"     'http://ts.example:8080'  "is a URL, not a host" || return 1
                                expect_server_reject "trailing slash"  'ts.example/'            "contains '/'" || return 1
                                expect_server_reject "path"            'ts.example/api'         "contains '/'" || return 1
                                expect_server_reject "query"           'ts.example?a=b'         "contains '?'" || return 1
                                expect_server_reject "fragment"        'ts.example#f'           "contains '#'" || return 1
                                expect_server_reject "host:port"       'ts.example:8080'        "contains ':'" || return 1
                                expect_server_reject "bracket + port"  '[::1]:8080'             "is bracketed" || return 1
                                # The suggested correction must be usable. It was built by cutting at
                                # the first ':' -- which is INSIDE the brackets -- and printed
                                # "write --server '['".
                                assert_contains "bracket + port: the suggestion is usable" "write --server ::1 --port 8080" "$CO_OUT" || return 1
                                expect_server_reject "percent"         'ts.example%2f'          "contains '%'" || return 1
                                expect_server_reject "zone id"         'fe80::1%eth0'           "contains '%'" || return 1
                                # curl expands these into SEVERAL transfers from ONE invocation.
                                # '[' now lands on the bracket arm (one spelling per host), so the value that
                                # exercises the GLOB arm is a brace list -- which is all that arm still owns.
                                expect_server_reject "glob range"      '127.0.0.[1-2]'          "does not name one host" || return 1
                                expect_server_reject "glob list"       '{a,b}.example'          "curl's URL list syntax" || return 1
                                expect_server_reject "unclosed bracket" '[::1'                  "is bracketed" || return 1
                                # curl resolves an international name through libidn2 and wget does
                                # not, so this same command line names DIFFERENT hosts per transport.
                                expect_server_reject "non-ascii"       'täst.example'           "punycode" || return 1
                                expect_server_reject "trailing space"  'ts.example '            "contains whitespace" || return 1
                                expect_server_reject "inner space"     'ts. example'            "contains whitespace"; }

test_b_bad_names_refused()      { # RFC 1123 shape. Not pedantry: each of these resolves to nothing,
                                # so without the gate the operator's diagnosis is a transport error
                                # instead of the typo they actually made.
                                expect_server_reject "empty label"     'a..b'                   "empty label" || return 1
                                expect_server_reject "leading dot"     '.ts.example'            "empty label" || return 1
                                expect_server_reject "lone dot"        '.'                      "is only a dot" || return 1
                                # A leading-dash VALUE is caught earlier, by require_value, and that
                                # is correct: '--server -x' is ambiguous with a flag. The '=' form is
                                # the documented escape hatch, and it reaches the validator.
                                offline_server --server=-ts.example
                                assert_eq "leading hyphen: exit code" 2 "$CO_RC" || return 1
                                assert_contains "leading hyphen: message" "starts or ends with '-'" "$CO_OUT" || return 1
                                offline_server --server '-ts.example'
                                assert_eq "and the bare dash form is a parse error" 2 "$CO_RC" || return 1
                                assert_contains "named as such" "option-like token" "$CO_OUT" || return 1
                                expect_server_reject "trailing hyphen" 'ts-.example'            "starts or ends with '-'" || return 1
                                expect_server_reject "long label"      "$(printf 'a%.0s' $(seq 64)).example" "longer than 63" || return 1
                                expect_server_reject "long name"       "$(printf 'aaaaaaaaa.%.0s' $(seq 26))a" "longer than 253 characters"; }

test_b_numeric_shapes_refused() { # getaddrinfo(3) still honours inet_aton's legacy forms, so a value
                                # that LOOKS like an address reaches a different one: measured on
                                # this host, '010.0.0.9' -> 8.0.0.9, '127.1' -> 127.0.0.1,
                                # '2130706433' -> 127.0.0.1, '0x7f000001' -> 127.0.0.1. A
                                # leading-zero octet copied out of a ticket is the realistic way in,
                                # and the log printed the typed value as if it were the peer.
                                expect_server_reject "octal octet"     '010.0.0.9'              "not four decimal octets" || return 1
                                expect_server_reject "zero-padded"     '127.000.000.001'        "not four decimal octets" || return 1
                                expect_server_reject "short form"      '127.1'                  "not four decimal octets" || return 1
                                expect_server_reject "decimal address" '2130706433'             "not four decimal octets" || return 1
                                expect_server_reject "octet range"     '1.2.3.999'              "not four decimal octets" || return 1
                                expect_server_reject "five octets"     '1.2.3.4.5'              "not four decimal octets" || return 1
                                expect_server_reject "truncated quad"  '10.0.0.'                "not four decimal octets" || return 1
                                expect_server_reject "hex address"     '0x7f000001'             "hexadecimal address" || return 1
                                # The message must explain the CONSEQUENCE, not just the rule:
                                # "invalid" would leave the operator believing their value was fine.
                                offline_server --server '010.0.0.9'
                                assert_contains "and says what would have happened" "as typed it reaches a different address" "$CO_OUT"; }

test_b_valid_shapes_accepted()  { # The gate must not cost a single legitimate destination. A
                                # trailing root dot is valid; a DOTLESS name is not, since the
                                # collected host's search list would complete it (see
                                # test_r9_single_label_refused).
                                expect_server_accept "fqdn"          'thunderstorm.example'  'thunderstorm.example' || return 1
                                expect_server_accept "two labels"    'a.b'                   'a.b' || return 1
                                expect_server_accept "root dot"      'ts.example.'           'ts.example.' || return 1
                                expect_server_accept "mixed case"    'TS.Example.COM'        'TS.Example.COM' || return 1
                                expect_server_accept "underscore"    'ts_stage.example'      'ts_stage.example' || return 1
                                expect_server_accept "ipv4"          '10.0.0.5'              '10.0.0.5' || return 1
                                # Round 5 moved '0.0.0.0' and '255.255.255.255' OUT of the accept
                                # set: measured, the unspecified address connects to loopback and
                                # the broadcast address connects to nothing, so neither names a
                                # destination. test_r5_unspecified_address_refused owns them now.
                                # Their neighbours stay here, so the rule is about those two
                                # addresses and not about zeros or 255s.
                                expect_server_accept "ipv4 near-zero" '0.0.0.1'              '0.0.0.1' || return 1
                                expect_server_accept "ipv4 near-max"  '255.255.255.254'      '255.255.255.254' || return 1
                                # The ONE mechanical step: an IPv6 literal is bracketed, because
                                # that is the only spelling RFC 3986 allows. It cannot change which
                                # host is named -- --port is the sole source of the port -- and it is
                                # the split osquery's URI class makes on purpose (host() keeps the
                                # brackets for URLs, hostname() strips them for getaddrinfo).
                                expect_server_accept "ipv6 bare"     '::1'                   '[::1]' || return 1
                                expect_server_accept "ipv6 full"     '2001:db8::5'           '[2001:db8::5]' || return 1
                                expect_server_accept "ipv6 mapped"   '::ffff:127.0.0.1'      '[::ffff:127.0.0.1]' || return 1
                                # ONE spelling per host: the bracketed form is refused now, and
                                # round 8 pins that in test_r8_brackets_are_refused. What matters
                                # here is that the PLAIN form still produces the bracketed URL --
                                # the brackets are the collector's job, not the operator's.
                                # (The bracketed spelling used to be accepted here as a second way
                                # to write the same host; it is refused since round 8. That the PLAIN
                                # form is bracketed for the URL is asserted by the "ipv6 bare" case
                                # above -- expect_server_accept checks exactly that.)
                                return 0; }

test_b_second_server_is_a_usage_error() { # --server names ONE destination. A second occurrence
                                # used to be an ordered candidate list; it is now a usage error, so
                                # two destinations can never be named for one collection.
                                run_collector -s ts.example -s ts2.example --port 8080 --source S \
                                    --no-log-file --no-progress --dry-run --dir "$ONEFILE"
                                assert_eq "a second --server is refused" 2 "$CO_RC" || return 1
                                assert_contains "and says why" "names one destination" "$CO_OUT" || return 1
                                assert_not_contains "no endpoint is built" "API endpoint: http" "$CO_OUT" || return 1
                                # The rejected value must not be echoed: this message reaches the
                                # terminal, the log file and syslog at once.
                                run_collector -s ts.example -s 'user:pw@evil.example' --port 8080 \
                                    --source S --no-log-file --no-progress --dry-run --dir "$ONEFILE"
                                assert_eq "still a usage error" 2 "$CO_RC" || return 1
                                # The whole value, not a 2-character fragment: 'pw' could match by
                                # accident and would pass for the wrong reason.
                                assert_not_contains "and leaks no credential" "user:pw@evil.example" "$CO_OUT" || return 1
                                assert_not_contains "nor the host it named" "evil.example" "$CO_OUT"; }

test_b_bad_ipv6_refused()       { expect_server_reject "triple colon"  ':::1'        "not an IPv6 literal" || return 1
                                expect_server_reject "two ::"          '1::2::3'     "not an IPv6 literal" || return 1
                                expect_server_reject "non-hex"         'gg::1'       "not an IPv6 literal" || return 1
                                expect_server_reject "bad in brackets" '[gg::1]'     "not a valid IPv6 address inside the brackets"; }

test_b_credential_is_redacted() { # The refusal message is the ONE place the rejected value is
                                # echoed to the terminal, the log file and syslog at once. For the
                                # '@' shape everything before the '@' is a password.
                                offline_server --server 'operator:s3cr3t-do-not-log@127.0.0.1'
                                assert_eq "exit code" 2 "$CO_RC" || return 1
                                assert_not_contains "the password is not logged" "s3cr3t-do-not-log" "$CO_OUT" || return 1
                                assert_contains "it is redacted" "<redacted>@127.0.0.1" "$CO_OUT" || return 1
                                # ...and the message still names the host that WOULD have received
                                # the collection, because that is what makes an operator recognise
                                # their own mistake.
                                assert_contains "and names the real destination" "would go to '127.0.0.1'" "$CO_OUT"; }

test_b_equals_and_short_forms() { offline_server --server=ts.example
                                assert_eq "--server=value" 0 "$CO_RC" || return 1
                                assert_contains "value taken" "Server: ts.example" "$CO_OUT" || return 1
                                offline_server -s ts.example
                                assert_eq "-s value" 0 "$CO_RC" || return 1
                                assert_contains "value taken" "Server: ts.example" "$CO_OUT" || return 1
                                offline_server --server=bad..name
                                assert_eq "and the = form is validated too" 2 "$CO_RC"; }

# ── Axis C — the wire: a refused value sends NOTHING ──────────────────────────

test_c_refused_sends_no_packet() { # Exit 2 is not the interesting half. The interesting half is
                                # that the bytes never leave: before the fix each of these
                                # DELIVERED, to a peer the operator never named, and reported
                                # success. The listener records one "REQ" line per request.
                                require_python3 || return 77
                                local p log v
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                # Every value here resolves to, or expands to include, this very
                                # listener's address -- so a zero-request assertion is meaningful
                                # rather than vacuously true.
                                for v in '127.0.0.1@127.0.0.1' '127.0.0.1/' '127.0.0.1#x' '127.0.0.1?a=b' \
                                         '127.0.0.[1-1]' '{127.0.0.1,127.0.0.1}' '0177.0.0.1' '2130706433' '127.1'; do
                                    run_collector --server "$v" --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                    assert_eq "'$v' is refused" 2 "$CO_RC" || return 1
                                    assert_not_contains "'$v' collects nothing" "Run completed" "$CO_OUT" || return 1
                                done
                                assert_eq "and NOT ONE request reached the peer" 0 "$(count_req "$log")"; }

test_c_at_form_does_not_retarget() { # The sharpest case, on two loopback addresses: the value NAMES
                                # 127.0.0.2 and would have SENT to 127.0.0.1. Measured before the
                                # fix: 'REQ POST /api/checkAsync ... evidence=True' at 127.0.0.1,
                                # exit 0, submitted=1, and 127.0.0.2's name transmitted to
                                # 127.0.0.1 as the HTTP Basic username.
                                require_python3 || return 77
                                local p1 l1 p2 l2
                                # 127.0.0.2 is not bindable everywhere (macOS needs an explicit lo0
                                # alias). Round 4: an absent environment feature must SKIP -- this
                                # used to turn "no second loopback address" into red attributed to
                                # the collector.
                                require_second_loopback || return 77
                                start_listener_on 127.0.0.1 ackstr || return 1; p1="$LISTENER_PORT_OUT"; l1="$LISTENER_LOG_OUT"
                                start_listener_on 127.0.0.2 ackstr || return 1; p2="$LISTENER_PORT_OUT"; l2="$LISTENER_LOG_OUT"
                                run_collector --server "127.0.0.2@127.0.0.1" --port "$p1" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "refused" 2 "$CO_RC" || return 1
                                assert_eq "the host after the '@' received nothing" 0 "$(count_req "$l1")" || return 1
                                assert_eq "and the host it appeared to name received nothing" 0 "$(count_req "$l2")" || return 1
                                # Control: 127.0.0.2 is genuinely reachable, so the zero above is
                                # the validator's doing and not a broken fixture.
                                run_collector --server 127.0.0.2 --port "$p2" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the control run succeeds" 0 "$CO_RC" || return 1
                                assert_ge "and the control peer was reached" 1 "$(count_req "$l2" 'POST /api/checkAsync*')"; }

test_c_slash_cannot_reach_port_80() { # The trailing slash put --port in the URL PATH, so the request
                                # went to the SCHEME'S DEFAULT PORT while the log printed the port
                                # the operator asked for as fact. This binds 80 to prove it, and
                                # skips where that is not permitted.
                                require_python3 || return 77
                                local l80 p
                                python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try: s.bind(("127.0.0.1",80))
except OSError: sys.exit(1)
s.close()' 2>/dev/null || return 77
                                start_listener yes200 "" 127.0.0.1 || return 1
                                p="$LISTENER_PORT_OUT"
                                # Now a real listener on 80, the port the old bug fell back to.
                                # Round 4: this was hand-rolled with its own readiness loop and no
                                # teardown, so it held a PRIVILEGED port for the whole remainder of
                                # the suite. start_listener_at is the one spelling; stop_listener
                                # gives it back in the same test.
                                local pid80
                                start_listener_at 127.0.0.1 80 ackstr || return 77
                                l80="$LISTENER_LOG_OUT"; pid80="$LISTENER_PID_OUT"
                                run_collector --server "127.0.0.1/" --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                local rc=0
                                assert_eq "refused" 2 "$CO_RC" || rc=1
                                [ "$rc" -eq 0 ] && { assert_no_req "port 80 received NOTHING" "$l80" || rc=1; }
                                stop_listener "$pid80"
                                return "$rc"; }

test_c_dry_run_still_validates() { # A destination that could mean two things is a usage error even
                                # when nothing is about to be sent -- otherwise the operator learns
                                # their value is fine from a dry run and discovers otherwise in
                                # production, with the evidence already gone.
                                require_python3 || return 77
                                local p log
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server '127.0.0.1/' --port "$p" --dry-run --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a dry run refuses it too" 2 "$CO_RC" || return 1
                                assert_contains "with the same reason" "contains '/'" "$CO_OUT" || return 1
                                assert_eq "and a dry run still sends nothing" 0 "$(count_req "$log")"; }

# ── Axis D — an IPv6 --server actually delivers ───────────────────────────────

test_d_ipv6_delivers()          { # Before the fix '::1' built "http://::1:8080", curl exited 3 and
                                # the run reported "Cannot reach a Thunderstorm server" -- for a
                                # value the Go client connects with. Both spellings must now work
                                # against a REAL AF_INET6 peer: an AF_INET listener cannot accept a
                                # connection to [::1], and mistaking that for a collector bug has
                                # cost this round time before.
                                require_python3 || return 77
                                local p log v
                                require_ipv6_loopback || return 77
                                start_listener_on '::1' ackstr || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                # '[::1]' is refused since round 8 (one spelling per host), so the
                                # loop carries the accepted spelling only; the refusal is pinned by
                                # test_r8_brackets_are_refused.
                                for v in '::1'; do
                                    : > "$log"
                                    run_collector --server "$v" --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                    assert_eq "'$v' delivers" 0 "$CO_RC" || return 1
                                    assert_contains "'$v' is bracketed in the URL" "API endpoint: http://[::1]:$p/api/" "$CO_OUT" || return 1
                                    assert_eq "'$v' submitted the file" 1 "$(co_stat submitted)" || return 1
                                    assert_ge "'$v' reached the IPv6 peer" 1 "$(grep -c '^REQ POST /api/checkAsync' "$log")" || return 1
                                    assert_not_contains "'$v' is never called malformed" "URL was malformed" "$CO_OUT" || return 1
                                done
                                return 0; }

# ── Axis E — the run records the address that answered ───────────────────────

# SC1090: the library path is built at run time, so ShellCheck cannot follow it. SC2034: every
# variable set below is read by the SOURCED collector's own functions, which ShellCheck also cannot
# see. Both are inherent to testing a shell script by sourcing it.
# shellcheck disable=SC1090,SC2034
test_a_interrupted_marker_needs_validation() { # The signal traps are installed at file scope, so
                                # they fire DURING parse_args -- before validate_config has judged
                                # --server. The interrupted marker used to build its URL from the
                                # raw value, so '--server name@evil.example' plus a signal in that
                                # window would have handed evil.example this host's source name and
                                # run statistics: the same retarget the validator closes everywhere
                                # else, and the same payload that makes withholding the end marker
                                # from an unacknowledged peer worth doing.
                                #
                                # Asserted by sourcing the collector as a library (the
                                # verify_portable.sh pattern), because the real window is
                                # microseconds wide and cannot be hit reliably from outside.
                                local lib out
                                lib="$WORK/collector-lib.sh"
                                sed '$d' "$COLLECTOR" | sed '$d' > "$lib" || return 1
                                # Round 4: the source was run as `. "$lib" >/dev/null 2>&1`, which
                                # swallows a sourcing failure -- if the strip had taken the wrong
                                # two lines, or the function had been renamed, $out became a
                                # "command not found" string and the two assert_not_contains that
                                # the test is NAMED for both passed. Prove the library loaded and
                                # the function exists before asserting anything about it.
                                ( . "$lib" >/dev/null 2>&1
                                  command -v send_interrupted_marker >/dev/null 2>&1 \
                                  && command -v build_base_url >/dev/null 2>&1 \
                                  && command -v classify_server >/dev/null 2>&1 ) || {
                                    printf "    ${RED}FAIL${RESET}: the collector could not be sourced as a library (the trailing-line strip no longer matches)\n"
                                    return 1; }
                                out="$( . "$lib" >/dev/null 2>&1
                                        THUNDERSTORM_SERVER='ts.example@evil.example'
                                        SERVER_URLHOST_OUT=''
                                        DRY_RUN=0; START_TS=0
                                        send_interrupted_marker 2>&1
                                        printf 'MARKER_RC=%s' "$?" )"
                                assert_not_contains "an unvalidated destination gets no marker" "evil.example" "$out" || return 1
                                # ...and the URL builder no longer has a raw-value fallback at all.
                                out="$( . "$lib" >/dev/null 2>&1
                                        THUNDERSTORM_SERVER='ts.example@evil.example'
                                        SERVER_URLHOST_OUT=''
                                        THUNDERSTORM_PORT=8080; USE_SSL=0
                                        build_base_url; printf '%s' "$BASE_URL_OUT" )"
                                assert_not_contains "build_base_url never uses the raw value" "evil.example" "$out" || return 1
                                # The legitimate path still works.
                                out="$( . "$lib" >/dev/null 2>&1
                                        classify_server 'ts.example' >/dev/null 2>&1
                                        THUNDERSTORM_PORT=8080; USE_SSL=0
                                        build_base_url; printf '%s' "$BASE_URL_OUT" )"
                                assert_eq "a validated server still builds its URL" "http://ts.example:8080" "$out"; }

# ── Axis F — observability, and no side effects on a usage error ─────────────

test_f_help_documents_server()  { CO_OUT="$(bash "$COLLECTOR" --help 2>&1)"; CO_RC=$?
                                assert_eq "--help exits 0" 0 "$CO_RC" || return 1
                                assert_contains "says it is required" "required unless --dry-run" "$CO_OUT" || return 1
                                # The entry names all three accepted shapes and shows one command.
                                # The rules and the reasoning live in the README; what --help owes
                                # the operator is the shapes, the requirement and an example.
                                # Needles must not span the wrap: each fact sits on one line.
                                assert_contains "names all three shapes" "a fully qualified name, an IPv4, or an IPv6" "$CO_OUT" || return 1
                                assert_contains "and states the dot rule" "A name needs a dot" "$CO_OUT" || return 1
                                assert_contains "and that IPv6 is unbracketed" "plainly (::1, not [::1])" "$CO_OUT" || return 1
                                assert_contains "and shows a runnable example" "Example: --server thunderstorm.local" "$CO_OUT" || return 1
                                # The port belongs to --port, and --ssl does not move it: that rule
                                # is next door, in the --port entry, and must stay somewhere.
                                assert_contains "and --port still states the ssl/port rule" "does NOT change it to 443" "$CO_OUT" || return 1
                                # --help must not advertise a destination.
                                assert_not_contains "and names no vendor host" "ygdrasil" "$CO_OUT"; }

test_f_usage_error_writes_none() { # A usage error must not leave a log file in whatever directory
                                # the operator happened to run from: validate_config runs BEFORE the
                                # file sink is armed, and the --server check has to stay there.
                                local d="$WORK/cwd-srv"
                                rm -rf "$d"; mkdir -p "$d" || return 1
                                ( cd "$d" && bash "$COLLECTOR" --server 'ts.example/' --port 8080 --dir "$ONEFILE" --no-progress >/dev/null 2>&1 )
                                assert_eq "an invalid --server writes no log file" 0 "$(count_files "$d" '*.log')" || return 1
                                ( cd "$d" && bash "$COLLECTOR" --port 8080 --dir "$ONEFILE" --no-progress >/dev/null 2>&1 )
                                assert_eq "a missing --server writes no log file" 0 "$(count_files "$d" '*.log')"; }

test_f_quiet_nolog_still_reports() { # The documented cron form. A destination error that reaches no
                                # sink at all is how a misdirected run stayed invisible: measured
                                # before the fix, the whole output of a retargeted run was 407 bytes
                                # of ASCII banner.
                                CO_OUT=""; CO_RC=0
                                CO_OUT="$( cd "$WORK/cwd" && bash "$COLLECTOR" --server 'ts.example/' --port 8080 \
                                    --dir "$ONEFILE" --quiet --no-log-file --no-progress 2>&1 )" && CO_RC=0 || CO_RC=$?
                                assert_eq "exit code" 2 "$CO_RC" || return 1
                                assert_contains "the reason still reaches a sink" "contains '/'" "$CO_OUT"; }

# ── Live tier ────────────────────────────────────────────────────────────────

live_collector() {
    run_collector --no-log-file --no-progress --source "server-audit-$$" "$@"
}

test_live_delivers()            { require_live || return 77
                                live_collector --server "$LIVE_HOST" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "the live server accepts the collection" 0 "$CO_RC" || return 1
                                assert_eq "and acknowledged the file" 1 "$(co_stat submitted)"; }

test_live_transports_agree()    { require_live || return 77
                                # Peer-address reporting was removed with the proxy verdict, so this
                                # no longer compares addresses. What must still hold is that the two
                                # transports behave identically against a real server.
                                local shim
                                shim="$(wget_only_path)" || return 77
                                live_collector --server "$LIVE_HOST" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "curl delivers" 0 "$CO_RC" || return 1
                                assert_eq "curl acknowledged the file" 1 "$(co_stat submitted)" || return 1
                                CO_OUT=""; CO_RC=0
                                CO_OUT="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server "$LIVE_HOST" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} \
                                    --no-log-file --no-progress --source "server-audit-wget-$$" --dir "$ONEFILE" 2>&1 )" && CO_RC=0 || CO_RC=$?
                                assert_eq "wget delivers" 0 "$CO_RC" || return 1
                                assert_eq "wget acknowledged the file too" 1 "$(co_stat submitted)"; }

test_live_slash_refused()       { require_live || return 77
                                # Before the fix this DELIVERED, to port 80 of the same host, and
                                # reported success. Now it must not open a socket at all.
                                live_collector --server "${LIVE_HOST}/" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "refused" 2 "$CO_RC" || return 1
                                assert_contains "with the reason" "contains '/'" "$CO_OUT" || return 1
                                assert_not_contains "and nothing was collected" "Run completed" "$CO_OUT"; }

test_live_userinfo_refused()    { require_live || return 77
                                live_collector --server "${LIVE_HOST}@127.0.0.1" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "refused" 2 "$CO_RC" || return 1
                                assert_contains "and names the real destination" "would go to '127.0.0.1'" "$CO_OUT"; }

# ══════════════════════════════════════════════════════════════════════════════
# ROUND 4 — an independent re-assessment, before the first three rounds are committed.
#
# Every test below Axis R is dispatched with run_test_red: it pins a defect that is CONFIRMED
# against the current collector and therefore fails today. The finding id in the dispatch call is
# the entry in the round-4 register. When a fix lands, run_test_red turns the test's newfound PASS
# into a suite failure, which is the signal to move it to run_test.
# ══════════════════════════════════════════════════════════════════════════════

# ── Axis B4 — grammar boundaries the first three rounds never reached ─────────

test_r4_ipv6_group_counting()   { # server_ipv6_ok is documented as "a real check, not a shape
                                # test": it counts groups, allows an IPv4 tail worth two, and
                                # bounds each group at four hex digits. Every boundary named in
                                # that comment, and none of them had a test.
                                local v
                                # '::' is a WELL-FORMED literal and server_ipv6_ok still accepts
                                # it -- that is what this test is about. It is refused one step
                                # later, as a destination that names no host (round 5, S1), so it
                                # belongs in test_r5_unspecified_address_refused rather than here.
                                for v in '1:2:3:4:5:6:7:8' '1::' '::1' '1::8' \
                                         '::ffff:127.0.0.1' '64:ff9b::192.0.2.33' '1:2:3:4:5:6:1.2.3.4' \
                                         '0000:0000:0000:0000:0000:0000:255.255.255.255' '::FFFF:127.0.0.1'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' is a valid literal" 0 "$CO_RC" || return 1
                                    assert_eq "and is bracketed exactly once" "[$v]" "$(endpoint_host)" || return 1
                                done
                                # The other side. '1:2:3:4:5:6:7:1.2.3.4' is nine groups because the
                                # tail counts as two -- the arithmetic the comment claims.
                                for v in '1:2:3:4:5:6:7:8:9' '1:2:3:4:5:6:7:1.2.3.4' '12345::1' \
                                         '1::2::3' ':::1' '1.2.3.4::1' ':1' '1:' '::1:'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' is refused" 2 "$CO_RC" || return 1
                                done
                                # 46 characters: one digit past the longest literal that exists.
                                offline_server --server '00000:0000:0000:0000:0000:0000:255.255.255.255'
                                assert_eq "one character past the maximum is refused" 2 "$CO_RC"; }

test_r4_ipv6_zone_and_bracket_spellings() { # A zone id is the one IPv6 spelling the two transports
                                # genuinely disagree about -- measured: curl connects to fe80::1
                                # and wget refuses the URL outright -- so it must be refused before
                                # either sees it, in BOTH the bare and the RFC 6874 '%25' form.
                                expect_server_reject "zone id" '::1%eth0' "contains '%'" || return 1
                                expect_server_reject "escaped zone id" '[fe80::1%25eth0]' "contains '%'" || return 1
                                # '[::]' parses as an IPv6 literal and is then refused as a
                                # destination (round 5, S1) -- both halves matter, so assert the
                                # reason is the destination rule and not a grammar complaint.
                                # '[::]' is refused for the BRACKETS now, one arm before the
                                # literal is parsed, so the reason is the spelling and not the
                                # destination. '::' itself is still refused as naming no host --
                                # asserted just below and in test_r5_unspecified_address_refused.
                                offline_server --server '[::]'
                                assert_eq "bracketed unspecified is refused" 2 "$CO_RC" || return 1
                                assert_contains "for the brackets, before the literal is parsed" "is bracketed" "$CO_OUT" || return 1
                                # The bracket arm has two branches and "is bracketed" is in both.
                                # '[::]' takes the names-no-host branch, which must NOT prescribe a
                                # paste-back: "write --server ::" would be refused on the next run.
                                assert_contains "and says the address itself names nothing" "names no destination even written plainly" "$CO_OUT" || return 1
                                assert_not_contains "so it prescribes no value the collector refuses" "write --server" "$CO_OUT" || return 1
                                offline_server --server '::'
                                assert_eq "and the plain form is refused too" 2 "$CO_RC" || return 1
                                assert_contains "as a destination that names no host" "names no destination" "$CO_OUT" || return 1
                                # '[]' matches the bracketed-literal arm, so the diagnosis is about
                                # what is inside the brackets -- which is the more useful sentence
                                # of the two, and is asserted here so a future reorder cannot
                                # silently downgrade it to the generic globbing message.
                                expect_server_reject "empty brackets" '[]' "does not name one host" || return 1
                                # The bracketed leading-zero tail is refused for the same reason a
                                # bare 010.0.0.9 is: the tail goes through server_ipv4_ok.
                                expect_server_reject "leading zero in the v4 tail" '[::ffff:010.0.0.1]' "not a valid IPv6 address inside the brackets"; }

test_r4_name_boundaries()       { # The 63- and 253-character bounds, exactly, from both sides --
                                # the existing tests only ever tried values well past them, which
                                # cannot tell a correct bound from an off-by-one.
                                local l63 l64 n253 n254 base
                                l63="$(printf 'a%.0s' $(seq 1 63))"
                                l64="${l63}a"
                                # Dotted, because a dotless name is refused whatever its length:
                                # what is under test here is the 63-byte LABEL bound.
                                expect_server_accept "63-character label" "$l63.example" "$l63.example" || return 1
                                offline_server --server "$l64.example"
                                assert_eq "64-character label refused" 2 "$CO_RC" || return 1
                                assert_contains "for the stated reason" "longer than 63 characters" "$CO_OUT" || return 1
                                base="$(printf 'a%.0s' $(seq 1 49))"
                                n253="${base}.${base}.${base}.${base}.${base}.abc"
                                n254="${n253}a"
                                assert_eq "253 fixture" 253 "${#n253}" || return 1
                                expect_server_accept "253-character name" "$n253" "$n253" || return 1
                                offline_server --server "$n254"
                                assert_eq "254 characters refused" 2 "$CO_RC" || return 1
                                assert_contains "for the stated reason" "longer than 253 characters" "$CO_OUT"; }

test_r4_punycode_is_accepted()  { # The non-ASCII message tells the operator to "pass the punycode
                                # (xn--) form". That remedy has never been tested, and a validator
                                # that refused it would be prescribing something it does not accept
                                # -- 'xn--' contains the '--' that the label rules are fussy about.
                                expect_server_accept "punycode label" 'xn--tst-qla.example' 'xn--tst-qla.example' || return 1
                                expect_server_accept "double hyphen inside" 'a--b.example' 'a--b.example' || return 1
                                # And the value it is prescribed FOR is still refused.
                                offline_server --server 'täst.example'
                                assert_eq "non-ASCII refused" 2 "$CO_RC" || return 1
                                assert_contains "and prescribes punycode" "punycode" "$CO_OUT"; }

test_r4_name_frontier_with_numbers() { # Where "all labels are numeric" stops and "a host name"
                                # begins. This is the rule that makes the numeric message's claim
                                # true or false, so it needs to be pinned in its own right.
                                expect_server_accept "numeric TLD is still a name" 'ts.example.123' 'ts.example.123' || return 1
                                expect_server_accept "numeric first label" '123.example' '123.example' || return 1
                                expect_server_accept "underscore, as internal zones use" 'ts_stage.example' 'ts_stage.example' || return 1
                                expect_server_accept "case is preserved byte for byte" 'TS.Example.COM' 'TS.Example.COM' || return 1
                                expect_server_accept "single character label" 'x.example' 'x.example' || return 1
                                offline_server --server '123.456'
                                assert_eq "two numeric labels are an address, not a name" 2 "$CO_RC"; }

test_r4_no_value_reaches_a_shell() { # The cheapest possible assurance that a --server value cannot
                                # be executed. Each of these is refused by the label rule; the point
                                # is that the refusal is a message, not a shell diagnostic, and that
                                # nothing ran.
                                local v
                                for v in 'a$(id).example' 'a`id`.example' 'a;id.example' 'a|id.example' \
                                         "a'b.example" 'a"b.example' 'a<b.example' 'a*b.example' 'a\b.example'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' refused" 2 "$CO_RC" || return 1
                                    assert_contains "'$v' by the label rule" "is not a letter, digit" "$CO_OUT" || return 1
                                    assert_not_contains "'$v' executed nothing" "uid=" "$CO_OUT" || return 1
                                done; }

test_r4_control_characters()    { # A destination value reaches the terminal, the log file and
                                # syslog. An embedded newline that survived into a sink would let
                                # the value forge a log line of its own.
                                local v
                                offline_server --server "$(printf 'ts.example\nfoo')"
                                assert_eq "embedded newline refused" 2 "$CO_RC" || return 1
                                assert_contains "as whitespace" "contains whitespace" "$CO_OUT" || return 1
                                assert_not_contains "and forges no log line" "] foo" "$CO_OUT" || return 1
                                for v in "$(printf 'a\tb')" "$(printf 'a\013b')" "$(printf 'a\014b')" "$(printf 'a\rb')" ' ts.example' 'ts.example '; do
                                    offline_server --server "$v"
                                    assert_eq "control/space value refused" 2 "$CO_RC" || return 1
                                done; }

test_r4_locale_cannot_open_the_gate() { # The non-ASCII arm is a bracket range ('*[!\ -~]*') and the
                                # whitespace arm a character class -- both collation-dependent in a
                                # non-C locale. The gate must refuse the same values under every
                                # locale the collector might inherit, because the operator does not
                                # choose the locale of the host being collected.
                                local loc v
                                for loc in C C.UTF-8 en_US.UTF-8 ""; do
                                    for v in 'täst.example' "$(printf 'ts\xc2\xa0example')" "$(printf 'ts\xe3\x80\x80example')"; do
                                        if [ -n "$loc" ]; then
                                            run_collector_env LC_ALL="$loc" -- --port 8080 --no-log-file --dry-run \
                                                --no-progress --dir "$ONEFILE" --server "$v"
                                        else
                                            run_collector_env LANG=en_US.UTF-8 -- --port 8080 --no-log-file --dry-run \
                                                --no-progress --dir "$ONEFILE" --server "$v"
                                        fi
                                        assert_eq "refused under LC_ALL='$loc'" 2 "$CO_RC" || return 1
                                        assert_not_contains "and never composed a URL" "API endpoint: http" "$CO_OUT" || return 1
                                    done
                                done; }

# ── Axis C4 — the exact conversation ──────────────────────────────────────────

test_r4_exact_request_sequence() { # Every other wire test asserts a LOWER bound ("at least one
                                # POST reached it") or zero. Neither can see an EXTRA request: a
                                # retry that should not have happened, a followed redirect, a
                                # version probe. This pins the whole conversation, in order, as the
                                # baseline every other case is stated against.
                                require_python3 || return 77
                                local p log
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                # An explicit --source, so the expectation does not depend on this
                                # host's name.
                                run_collector --server 127.0.0.1 --port "$p" --source r4seq --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                assert_eq "and the conversation is exactly this" \
"GET /api/status HTTP/1.1|POST /api/collection HTTP/1.1|POST /api/checkAsync?source=r4seq HTTP/1.1|POST /api/collection HTTP/1.1" \
                                    "$(req_lines "$log" 'GET *' 'POST *')"; }

test_r4_debug_adds_no_request() { # --debug reports the transport's version, which it obtains by
                                # running the tool locally. The comment says so; nothing checked
                                # that it does not also ask the SERVER something.
                                require_python3 || return 77
                                local p log a b
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                a="$(count_req "$log" 'GET *' 'POST *')"
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --debug --dir "$ONEFILE"
                                b="$(count_req "$log" 'GET *' 'POST *')"
                                assert_contains "--debug reports a transport version" "Transport version:" "$CO_OUT" || return 1
                                # Both counts must be the BASELINE, not merely equal: the first
                                # draft of this test compared two zeros and passed.
                                assert_eq "the plain run made the four baseline requests" 4 "$a" || return 1
                                assert_eq "and --debug asks the server nothing extra" "$a" "$b"; }

# ── Axis D — IPv6 delivery, on the transport the existing test does not use ────

test_r4_ipv6_delivers_under_wget() { # The existing IPv6 case is curl-only. wget's handling of a
                                # bracketed authority, its --max-redirect=0 on such a URL, and --
                                # most of all -- its peer-address parse for a LITERAL target
                                # (thunderstorm-collector.sh:3883-3894, the branch with no '|addr|'
                                # pair to read) have no coverage at all.
                                require_python3 || return 77
                                require_ipv6_loopback || return 77
                                local p log shim v
                                shim="$(wget_only_path)" || return 77
                                # '[::1]' is refused since round 8 (one spelling per host), so the
                                # loop carries the accepted spelling only; the refusal is pinned by
                                # test_r8_brackets_are_refused.
                                for v in '::1'; do
                                    start_listener_on '::1' ackstr || return 1
                                    p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                    run_collector_env PATH="$shim" -- --server "$v" --port "$p" \
                                        --no-log-file --no-progress --dir "$ONEFILE"
                                    assert_eq "'$v' delivers under wget" 0 "$CO_RC" || return 1
                                    assert_contains "'$v' used wget" "Transport: wget" "$CO_OUT" || return 1
                                    assert_eq "'$v' built the bracketed authority" '[::1]' "$(endpoint_host)" || return 1
                                    assert_eq "'$v' submitted the file" 1 "$(co_stat submitted)" || return 1
                                    assert_ge "'$v' reached the AF_INET6 peer" 1 "$(count_req "$log" 'POST /api/checkAsync*')" || return 1
                                    # The recorded address is the ADDRESS, never the URL spelling.
                                    assert_not_contains "'$v' never records the bracketed form as a peer" "answered from [::1]" "$CO_OUT" || return 1
                                done; }

# ── Axis J — the server's own input into the request URL ──────────────────────

test_r4_hostile_scan_id_cannot_rewrite_the_url() { # --server is the operator's value and is
                                # validated. The scan_id is the SERVER's, comes back from the begin
                                # marker, and is appended to every later upload URL -- the one
                                # input path into the URL that no round has examined.
                                require_python3 || return 77
                                local p log
                                start_listener scanid 'a b&c=d#e/f' || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                # The request PATH must still be the endpoint: a raw '#' would have
                                # truncated it, a raw '/' would have moved it.
                                assert_ge "the endpoint is unchanged" 1 "$(count_req "$log" 'POST /api/checkAsync?*')" || return 1
                                assert_eq "and nothing was requested outside /api" 0 "$(count_req "$log" 'POST /api/checkAsync?*e/f*')" || return 1
                                assert_contains "the id is percent-encoded" "scan_id=a%20b%26c%3Dd%23e%2Ff" "$(req_lines "$log" 'POST /api/checkAsync?*')"; }

test_r4_overlong_scan_id_is_dropped() { # The collector caps the id and drops an unusable one. The
                                # drop is silent, so the server can no longer tie the uploads to the
                                # collection it opened and nothing says why. Recorded as behaviour.
                                require_python3 || return 77
                                local p log id
                                id="$(printf 'a%.0s' $(seq 1 300))"
                                start_listener scanid "$id" || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run still succeeds" 0 "$CO_RC" || return 1
                                assert_eq "and no scan_id is appended" 0 "$(count_req "$log" 'POST /api/checkAsync?*scan_id*')"; }

test_r4_marker_500_aborts_before_any_file() { # The begin marker is FATAL after its one retry. This
                                # is the shape that turns a server-side change on /api/collection
                                # into "no collection happens at all", and it is the risk the live
                                # tier's G2 case is checking production against.
                                require_python3 || return 77
                                local p log
                                start_listener marker500 || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run is a runtime failure" 1 "$CO_RC" || return 1
                                assert_contains "and says which endpoint failed" "begin marker to /api/collection failed after retry" "$CO_OUT" || return 1
                                assert_eq "the marker was attempted exactly twice" 2 "$(count_req "$log" 'POST /api/collection*')" || return 1
                                assert_eq "and NOT ONE file was uploaded" 0 "$(count_req "$log" 'POST /api/checkAsync*')"; }

# ── Axis F4 — TLS, against a real handshake ───────────────────────────────────
#
# Every TLS claim in the README and the --help text was, until round 4, either untested or tested
# only against a plaintext listener: --ssl selects a scheme, --insecure disables verification,
# --ca-cert REPLACES the trust store under curl and only ADDS to it under wget, and --ca-cert
# implies --ssl. A self-signed certificate is what makes all of those observable.

test_r4_tls_delivers_with_insecure() { # The happy path over a real handshake.
                                require_python3 || return 77
                                local p log
                                start_listener_tls 127.0.0.1 "$(pick_port)" tlsack || return 77
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --ssl --insecure \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                assert_eq "the file is submitted" 1 "$(co_stat submitted)" || return 1
                                assert_contains "over https" "API endpoint: https://127.0.0.1:$p/api/" "$CO_OUT" || return 1
                                assert_contains "and the TLS mode is stated" "TLS: on" "$CO_OUT" || return 1
                                assert_ge "the peer really received it" 1 "$(count_req "$log" 'POST /api/checkAsync*')" || return 1
                                assert_eq "and the file was acknowledged over TLS" 1 "$(co_stat submitted)"; }

test_r4_tls_untrusted_is_refused() { # Without --insecure an untrusted certificate must stop the run
                                # BEFORE a file is read, and say what to do about it. The listener
                                # records a TLSFAIL line, so "the client refused the certificate" is
                                # distinguishable from "nothing ever connected".
                                require_python3 || return 77
                                local p log
                                start_listener_tls 127.0.0.1 "$(pick_port)" tlsack || return 77
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --ssl \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run fails" 1 "$CO_RC" || return 1
                                assert_contains "naming the cause and the two remedies" \
                                    "server certificate not trusted or name mismatch (use --ca-cert, or --insecure to accept it)" "$CO_OUT" || return 1
                                assert_not_contains "and no file was ever read" "Run completed" "$CO_OUT" || return 1
                                assert_eq "no HTTP request was made" 0 "$(count_req "$log" 'GET *' 'POST *')" || return 1
                                assert_ge "the handshake was attempted and refused" 1 "$(count_req "$log" 'TLSFAIL*')"; }

test_r4_ca_cert_implies_ssl()   { # One line in parse_args, never tested: --ca-cert without --ssl
                                # must still produce an https endpoint, because a CA is meaningless
                                # otherwise and silently sending plaintext would be the worst of the
                                # available behaviours.
                                require_python3 || return 77
                                local p
                                start_listener_tls 127.0.0.1 "$(pick_port)" tlsack || return 77
                                p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --ca-cert "$CERT_OUT" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds against the CA it was given" 0 "$CO_RC" || return 1
                                assert_contains "and --ca-cert alone selected https" "API endpoint: https://" "$CO_OUT" || return 1
                                assert_contains "and curl's semantics are stated" "replaces the trust store" "$CO_OUT" || return 1
                                assert_eq "the file is submitted" 1 "$(co_stat submitted)"; }

test_r4_ca_cert_wrong_is_refused() { # A CA that did not sign this certificate must fail exactly as
                                # no CA does. Otherwise --ca-cert would be decoration.
                                require_python3 || return 77
                                local p other
                                start_listener_tls 127.0.0.1 "$(pick_port)" tlsack || return 77
                                p="$LISTENER_PORT_OUT"
                                other="/etc/ssl/certs/ca-certificates.crt"
                                [ -r "$other" ] || return 77
                                run_collector --server 127.0.0.1 --port "$p" --ssl --ca-cert "$other" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a CA that did not sign it is not enough" 1 "$CO_RC" || return 1
                                assert_contains "and the cause is the certificate" "certificate not trusted" "$CO_OUT"; }

test_r4_ca_cert_missing_file()  { # A path that does not exist is a usage error, before anything is
                                # sent and before any sink is armed.
                                offline_server --server ts.example --ca-cert /nonexistent/r4.pem
                                assert_eq "missing CA file is a usage error" 2 "$CO_RC" || return 1
                                assert_contains "naming the file" "CA certificate file not found" "$CO_OUT"; }

test_r4_ca_cert_and_insecure_agree() { # Both flags together: the run must not claim in one line
                                # that the trust store was replaced and in another that nothing is
                                # verified. Whichever wins, the TLS line must state it once.
                                require_python3 || return 77
                                local p tls
                                start_listener_tls 127.0.0.1 "$(pick_port)" tlsack || return 77
                                p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --ssl --insecure --ca-cert "$CERT_OUT" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                tls="$(printf '%s\n' "$CO_OUT" | grep -c 'TLS: on')"
                                assert_eq "the TLS mode is stated exactly once" 1 "$tls"; }

test_r4_ca_cert_under_wget_says_wget_semantics() { # --ca-cert REPLACES the trust store under curl
                                # and only ADDS to it under wget. The Transport line is where that
                                # difference is disclosed; it has never been read on the wget leg.
                                require_python3 || return 77
                                local p shim
                                shim="$(wget_only_path)" || return 77
                                start_listener_tls 127.0.0.1 "$(pick_port)" tlsack || return 77
                                p="$LISTENER_PORT_OUT"
                                run_collector_env PATH="$shim" -- --server 127.0.0.1 --port "$p" --ssl --ca-cert "$CERT_OUT" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_contains "wget's semantics are stated, not curl's" \
                                    "added to the system trust store — wget cannot replace it" "$CO_OUT"; }

# ── Axis F5 — the proxy, on the wire ──────────────────────────────────────────
#
# The proxy model is elaborate (per-transport variable precedence, no_proxy dialects, credential
# redaction, peer tracking standing down) and every existing test reads the collector's OWN
# "Proxy:" line back. That proves the model agrees with itself. These ask the proxy.

# ── Axis I — withholding, on the wire ─────────────────────────────────────────

test_r4_withholding_is_wire_visible() { # A peer that answers 2xx to everything without ever
                                # acknowledging a sample is not a Thunderstorm. The collector stops
                                # sending after the FIRST such answer -- so with five fixtures the
                                # peer must see exactly one upload, not five, and the run must be a
                                # partial failure that says so.
                                # ackempty, not yes200: round 5 made the preflight require a
                                # Thunderstorm-shaped /api/status body, and yes200 answers '{}' to
                                # everything -- so it now fails the gate and never reaches an
                                # upload. ackempty answers a real status document and then a
                                # NON-acknowledgement ({"id":""}) to uploads, which is exactly the
                                # state this test is about.
                                require_python3 || return 77
                                local p log
                                start_listener ackempty || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "the run is a partial failure" 4 "$CO_RC" || return 1
                                assert_eq "exactly ONE file's bytes reached the peer" 1 "$(count_req "$log" 'POST /api/checkAsync*')" || return 1
                                assert_eq "and none were submitted" 0 "$(co_stat submitted)" || return 1
                                assert_contains "the run says what it decided and why" \
                                    "answered HTTP 2xx without a Thunderstorm answer" "$CO_OUT"; }

test_r4_end_marker_withheld_on_the_wire() { # The same run, one endpoint further: the end marker
                                # carries the host's source name and the run statistics, and is
                                # withheld from that peer. This is the behaviour the collector's own
                                # comment and the README both contradict (finding R6) -- pinned here
                                # as what the CODE does, so the register's contradiction is a fact
                                # about three statements and not an opinion about one.
                                require_python3 || return 77
                                local p log
                                start_listener ackempty || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 --source r4-withheld \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                assert_contains "the run states the withholding" "The end marker was NOT sent" "$CO_OUT" || return 1
                                assert_eq "and no end marker is on the wire" 0 "$(count_req "$log" 'BODY *"type":"end"*')" || return 1
                                # The BEGIN marker did carry the source name, before the peer had
                                # answered anything at all -- which is unavoidable and is exactly
                                # why the END marker is the one worth withholding. Asserted so the
                                # scope of the protection is written down rather than assumed.
                                assert_eq "the begin marker had already carried it" 1 "$(count_req "$log" 'BODY *"type":"begin"*r4-withheld*')" || return 1
                                assert_eq "and no marker at all follows the decision" 1 "$(count_req "$log" 'BODY *')"; }

# ── Axis F6 — signals ─────────────────────────────────────────────────────────

test_r4_signal_marker_goes_only_to_the_validated_host() { # A SIGTERM mid-run must send the
                                # interrupted marker to the host that was validated, name the
                                # signal, and reach no other listener.
                                require_python3 || return 77
                                require_second_loopback || return 77
                                local p log other olog slow rc=0 i=0
                                slow="$(make_slow_curl_path r4sig)" || return 77
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                start_listener_on 127.0.0.2 ackstr || return 1; other="$LISTENER_PORT_OUT"; olog="$LISTENER_LOG_OUT"
                                run_collector_bg_env PATH="$slow:$PATH" -- --server 127.0.0.1 --port "$p" \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                while [ "$i" -lt 200 ]; do
                                    [ "$(count_req "$log" 'POST /api/checkAsync*')" -ge 1 ] && break
                                    sleep 0.05; i=$(( i + 1 ))
                                done
                                kill -TERM "$CO_BG_PID" 2>/dev/null || :
                                bounded_wait "$CO_BG_PID" 600 || { printf "    the signal handler hung\n"; return 1; }
                                [ "$BOUNDED_WAIT_RC" -eq 143 ] || { printf "    the run finished before the signal landed (setup, not a product failure)\n"; return 77; }
                                assert_ge "an interrupted marker was sent" 1 "$(count_req "$log" 'BODY *"type":"interrupted"*')" || rc=1
                                assert_ge "and it names the signal" 1 "$(count_req "$log" 'BODY *"interrupted_by":"TERM"*')" || rc=1
                                assert_no_req "and no other host heard anything" "$olog" || rc=1
                                return "$rc"; }

test_r4_signal_during_validation_sends_nothing() { # The traps are installed at FILE SCOPE, so they
                                # fire during parse_args and validate_config -- before any
                                # destination has been validated. The gate for that is
                                # SERVER_URLHOST_OUT, and test_a_interrupted_marker_needs_validation
                                # checks it by sourcing the collector as a library. This is the same
                                # claim through a REAL process.
                                #
                                # The window is made legitimately: detect_source_name runs
                                # immediately before validate_config and forks `hostname`, so a
                                # hostname that sleeps opens the window without depending on any
                                # defect. (The first version of this test used the quadratic
                                # validator as its window; fixing that closed the window and the
                                # test silently went SKIP. An instrument must not be built out of
                                # the defect it is meant to outlive.)
                                require_python3 || return 77
                                local p log slow
                                slow="$(make_slow_hostname_path)" || return 77
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                # No --source: that would satisfy SOURCE_NAME and skip the fork.
                                run_collector_bg_env PATH="$slow:$PATH" -- --server 127.0.0.1 --port "$p" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                sleep 1
                                kill -0 "$CO_BG_PID" 2>/dev/null || { printf "    the run left the window before the signal (setup)\n"; return 77; }
                                kill -TERM "$CO_BG_PID" 2>/dev/null || :
                                bounded_wait "$CO_BG_PID" 600 || { printf "    the handler hung\n"; return 1; }
                                assert_eq "the run ends on the signal" 143 "$BOUNDED_WAIT_RC" || return 1
                                assert_no_req "a signal before validation sends nothing at all" "$log"; }

test_r4_dry_run_signal_sends_nothing() { # --dry-run is settled in a pre-pass, BEFORE the options
                                # are walked, precisely so a signal arriving during parsing cannot
                                # contact the server. Tested through a real process rather than by
                                # reading the pre-pass.
                                #
                                # The window has to be made, not hoped for: a dry run runs no
                                # transport at all, so the slow-curl shim that widens every other
                                # signal case does nothing here and the first draft of this test
                                # simply finished before the signal and reported SKIP. A tree large
                                # enough to still be printing is the window, and the test waits for
                                # evidence that the run is inside it.
                                require_python3 || return 77
                                local p log tree n i=0
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                tree="$WORK/drytree"
                                if [ ! -d "$tree" ]; then
                                    mkdir -p "$tree" || return 1
                                    while [ "$i" -lt 4000 ]; do printf 'x\n' > "$tree/f$i.txt"; i=$(( i + 1 )); done
                                fi
                                run_collector_bg --server 127.0.0.1 --port "$p" \
                                    --dry-run --no-log-file --no-progress --dir "$tree"
                                i=0
                                while [ "$i" -lt 400 ]; do
                                    n="$(grep -c 'DRY-RUN: would submit' "$CO_BG_OUT_FILE" 2>/dev/null)" || n="${n:-0}"
                                    [ "${n:-0}" -ge 20 ] && break
                                    kill -0 "$CO_BG_PID" 2>/dev/null || break
                                    sleep 0.05; i=$(( i + 1 ))
                                done
                                kill -0 "$CO_BG_PID" 2>/dev/null || { printf "    the dry run finished before the signal (setup)\n"; return 77; }
                                kill -INT "$CO_BG_PID" 2>/dev/null || :
                                bounded_wait "$CO_BG_PID" 600 || { printf "    the handler hung\n"; return 1; }
                                assert_eq "the run ends on the signal" 130 "$BOUNDED_WAIT_RC" || return 1
                                assert_contains "the handler really ran, and says why it is quiet" \
                                    "dry-run: no interrupted marker is sent" "$(co_bg_out)" || return 1
                                # A dry run makes exactly ONE request, the destination check, and a
                                # signal must not add a second: no marker, no upload. "Contacts
                                # nothing" was the old rule and is a weaker assertion than this.
                                assert_eq "one request: the destination check" 1 "$(count_req "$log" 'GET */api/status*')" || return 1
                                assert_eq "no marker, signal or no signal" 0 "$(count_req "$log" '*/api/collection*')" || return 1
                                assert_eq "and no upload" 0 "$(count_req "$log" '*/api/checkAsync*')"; }

# ── Axis H — what the destination path costs ──────────────────────────────────
#
# Reported, not frozen. A fork count asserted exactly fails on every refactor; an unbounded one is
# how a per-file $( ) gets added without anyone noticing. The ceilings below are generous on
# purpose -- they catch an order-of-magnitude regression, which is the one that matters.

test_r4_fork_budget_per_run_and_per_file() { # H6. The first three rounds added helpers to the
                                # per-file path (peer recording, response classification,
                                # redaction) on the stated ground that they are fork-free. This
                                # measures it: the marginal cost of 20 more files, in processes.
                                require_python3 || return 77
                                local p counter one many perfile big i
                                # NOT "$(exec_counter_path …)": it sets EXEC_LOG_OUT, and a command
                                # substitution would set it in a subshell -- the first draft of this
                                # test then truncated a path that did not exist, measured 0 execs
                                # for both runs, and passed by comparing two zeros.
                                exec_counter_path r4forks >/dev/null || return 1
                                counter="$EXEC_COUNTER_DIR"
                                big="$WORK/forkfixtures"; mkdir -p "$big" || return 1
                                i=0; while [ "$i" -lt 21 ]; do printf 'f%s\n' "$i" > "$big/f$i.txt"; i=$(( i + 1 )); done
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                : > "$EXEC_LOG_OUT"
                                run_collector_env PATH="$counter:$PATH" -- --server 127.0.0.1 --port "$p" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                one="$(exec_count)"
                                : > "$EXEC_LOG_OUT"
                                run_collector_env PATH="$counter:$PATH" -- --server 127.0.0.1 --port "$p" \
                                    --no-log-file --no-progress --dir "$big"
                                many="$(exec_count)"
                                perfile=$(( (many - one) / 20 ))
                                printf "\n      [measured] execs: 1 file=%s, 21 files=%s -> %s per additional file\n" "$one" "$many" "$perfile"
                                printf "      [measured] %s\n" "$(exec_breakdown)"
                                # Non-vacuity first: a measurement of zero means the counter was not
                                # on the PATH, not that the collector forks nothing.
                                assert_ge "the counter actually observed the run" 10 "$one" || return 1
                                assert_ge "and the larger run too" "$one" "$many" || return 1
                                assert_le "per-file exec cost stays in single digits" 9 "$perfile" || return 1
                                assert_le "and the fixed cost of a run stays bounded" 120 "$one"; }

test_r4_fork_budget_inside_the_signal_handler() { # H7. on_signal blanks HUP/INT/QUIT/TERM before it
                                # does anything else, so whatever the handler spends is spent
                                # UNINTERRUPTIBLY. The handler runs date, three mktemps, three
                                # json_escapes (a printf|tr pipeline each), a date -u, an awk and
                                # the transport. On a host at its pids limit or under an OOM
                                # sweep, that is where an operator's Ctrl-C stops working.
                                # Reported with a latency bound, which is the part an operator
                                # actually experiences.
                                require_python3 || return 77
                                local p log counter slow before after i=0 t0 t1
                                exec_counter_path r4sigforks >/dev/null || return 1
                                counter="$EXEC_COUNTER_DIR"
                                slow="$(make_slow_curl_path r4sigfork)" || return 77
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector_bg_env PATH="$slow:$counter:$PATH" -- --server 127.0.0.1 --port "$p" \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                while [ "$i" -lt 200 ]; do
                                    [ "$(count_req "$log" 'POST /api/checkAsync*')" -ge 1 ] && break
                                    sleep 0.05; i=$(( i + 1 ))
                                done
                                before="$(exec_count)"
                                t0="$(now_ms)"
                                kill -TERM "$CO_BG_PID" 2>/dev/null || :
                                bounded_wait "$CO_BG_PID" 600 || { printf "    the handler hung\n"; return 1; }
                                t1="$(now_ms)"
                                after="$(exec_count)"
                                [ "$BOUNDED_WAIT_RC" -eq 143 ] || return 77
                                printf "\n      [measured] the signal handler spent %s execs and %s ms\n" "$(( after - before ))" "$(( t1 - t0 ))"
                                assert_ge "the counter actually observed the run" 10 "$before" || return 1
                                assert_ge "and the handler really did something" 1 "$(( after - before ))" || return 1
                                assert_contains "the handler ran" "Received SIGTERM" "$(co_bg_out)" || return 1
                                assert_le "and an operator's signal is honoured promptly" 30000 "$(( t1 - t0 ))"; }

test_r4_validator_costs_nothing_on_real_values() { # The control for R7: the values operators
                                # actually type must be free. If this ever fails, a fix for the
                                # quadratic cost has overcorrected.
                                local v ms
                                for v in 'thunderstorm.example.com' '10.0.0.5' '2001:db8::5' 'x.example'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' accepted" 0 "$CO_RC" || return 1
                                done
                                # A whole dry run, including the walk, on a single file.
                                ms="$CO_MS"
                                assert_le "a dry run over one file stays well under a second" 2000 "$ms"; }

# ── Axis R — confirmed defects, red-first ─────────────────────────────────────

test_r4_hex_in_a_later_label_is_refused() { # R1. THE finding of round 4, and the same class the
                                # validator exists to close: getaddrinfo(3) honours inet_aton's
                                # legacy forms, and the gate only inspects the FIRST label for a
                                # hexadecimal spelling ('0[xX]*', :1047) while
                                # server_labels_all_numeric (:969) gives up on the first non-digit.
                                # So hex anywhere but the front falls through to the DNS-name path
                                # and is accepted as a host name.
                                #
                                #   --server 127.0x0.0.1  -> "Server: 127.0x0.0.1" logged,
                                #                            127.0.0.1 contacted
                                #   --server 1.0x2.3.4    -> reaches 1.2.3.4
                                #
                                # This is byte-for-byte the '0177.0.0.1' finding the suite header
                                # records as fixed, in a spelling the fix did not cover.
                                local v
                                for v in '127.0x0.0.1' '1.0x2.3.4' '127.0.0.0x1' '0x7f.1'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' must be a usage error" 2 "$CO_RC" || return 1
                                    assert_not_contains "'$v' must not reach URL composition" "API endpoint: http" "$CO_OUT" || return 1
                                done; }

test_r4_hex_label_does_not_deliver() { # R1, on the wire. The offline half proves the value is
                                # accepted; this proves what accepting it costs. The listener is on
                                # 127.0.0.1 and the operator typed 127.0x0.0.1 -- a value that does
                                # not look like this listener's address and is not spelled like any
                                # address at all.
                                require_python3 || return 77
                                local p log
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server '127.0x0.0.1' --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_no_req "a host spelled with a hex label reaches no peer" "$log"; }

test_r4_validator_is_not_quadratic() { # R7. server_labels_all_numeric (:969) and server_ipv4_ok
                                # (:901) both walk the value one label at a time, each step copying
                                # the remainder (${_rest#*.}), and BOTH run before any length bound
                                # -- server_dnsname_ok's 253-character check (:982) is reached only
                                # after them. Cost measured on the pure helpers:
                                #     4 KB ->    120 ms
                                #    20 KB ->  2 609 ms
                                #   100 KB ->  3 953 ms   (a single label, no dots at all)
                                # A host name is at most 253 characters and an IPv6 literal at most
                                # 45, so every one of those values is refused -- after burning
                                # seconds of CPU to decide it. On a host under memory pressure this
                                # is also where the allocation happens.
                                local v i=0
                                v=""
                                while [ "$i" -lt 10000 ]; do v="${v}1."; i=$(( i + 1 )); done
                                v="${v}1"
                                offline_server --server "$v"
                                assert_eq "a 20 KB value is a usage error" 2 "$CO_RC" || return 1
                                assert_le "and is refused in under a second" 1000 "$CO_MS"; }

test_r4_0x_prefix_is_not_a_hex_address() { # R8, the same arm from the other side. '0[xX]*' fires on
                                # any value merely BEGINNING '0x', before the name path is reached,
                                # so a registrable domain whose first label starts with those two
                                # characters cannot be named as a destination at all. The gate's
                                # own stated criterion is that it must not cost a legitimate
                                # destination; this one does.
                                local v
                                for v in '0xide.example' '0Xylophone.example' '0x-ray.example'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' is a host name and must be accepted" 0 "$CO_RC" || return 1
                                    assert_eq "and reaches the URL unchanged" "$v" "$(endpoint_host)" || return 1
                                done; }

test_r4_numeric_message_states_a_truth() { # R10/R13. One message (:1052) covers two disjoint
                                # populations: values inet_aton really does read as an address
                                # ('010.0.0.9' -> 8.0.0.9, '2130706433' -> 127.0.0.1), and values no
                                # resolver reads at all. For the second population the sentence
                                # "written like this it reaches a different address than it appears
                                # to name" is a fabricated threat -- measured, each of these is
                                # EAI_NONAME and reaches nothing:
                                #     127.0.0.256   1.2.3.4.5   999.999.999.999   127.0.0.1.
                                # '127.0.0.1.' is the sharpest: one trailing root dot is documented
                                # as legal and IS accepted for a name ('ts.example.'), so the file
                                # is also inconsistent with itself here.
                                local v
                                for v in '127.0.0.256' '1.2.3.4.5' '127.0.0.1.'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' is refused" 2 "$CO_RC" || return 1
                                    assert_not_contains "'$v' must not be accused of retargeting" \
                                        "as typed it reaches a different address" "$CO_OUT" || return 1
                                done; }

test_r4_root_dot_is_legal_at_the_length_bound() { # R12. server_dnsname_ok strips one trailing root
                                # dot into _name (:981) and then measures ${#1} -- the value WITH
                                # the dot (:982). So the documented "one trailing root dot is
                                # legal" stops being true at exactly 253 characters, which is the
                                # one place the rule matters.
                                local base name
                                base="$(printf 'a%.0s' $(seq 1 49))"
                                # 5 x 50 + 3 = 253 characters, then the root dot.
                                name="${base}.${base}.${base}.${base}.${base}.abc"
                                assert_eq "fixture is exactly 253 characters" 253 "${#name}" || return 1
                                offline_server --server "$name"
                                assert_eq "253 characters is accepted" 0 "$CO_RC" || return 1
                                offline_server --server "${name}."
                                assert_eq "and so is the same name with its root dot" 0 "$CO_RC"; }

test_r4_url_shape_is_diagnosed_before_userinfo() { # R11. The '*@*' arm (:1020) precedes '*/*',
                                # '*?*' and '*#*', but '@' only separates userinfo INSIDE the
                                # authority. For 'ts.example.com/api?u=a@b' curl contacts
                                # ts.example.com on port 80 -- the '/' rule -- while the collector
                                # reports the '@' rule, names 'b' as the destination, and
                                # redact_userinfo hides the operator's own value as though the
                                # part before the '@' were a password.
                                offline_server --server 'ts.example.com/api?u=a@b'
                                assert_eq "refused" 2 "$CO_RC" || return 1
                                assert_contains "the rule reported is the one that applies" "contains '/'" "$CO_OUT" || return 1
                                assert_not_contains "and no other host is named as the destination" "would go to 'b'" "$CO_OUT"; }

test_r4_glob_message_matches_the_code() { # R9. The message (:1041) tells the operator curl "would
                                # transfer to every host they expand to". A later round added '-g'
                                # to all three curl invocations, so curl now REFUSES such a URL
                                # (exit 3, "URL using bad/illegal format") and transfers nothing.
                                # Measured both ways. An operator who reads this goes looking for a
                                # leak that did not happen.
                                offline_server --server '127.0.0.[1-2]'
                                assert_eq "refused" 2 "$CO_RC" || return 1
                                assert_not_contains "the consequence stated must be the real one" \
                                    "would transfer to every host they expand to" "$CO_OUT"; }

test_r4_env_is_named_when_the_run_dies_for_it() { # R14. THUNDERSTORM_SERVER is deliberately ignored
                                # -- and the run says so, at :4134, inside prepare_run. But the
                                # fatal for a missing server is raised in validate_config (:2560),
                                # which runs FIRST, so the operator who exported the variable and
                                # forgot the flag is told there is no server and never told that
                                # theirs was seen and discarded. That is the one case where the
                                # announcement was written to help.
                                run_collector_env THUNDERSTORM_SERVER=ts.example -- \
                                    --port 8080 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "still a usage error" 2 "$CO_RC" || return 1
                                assert_contains "and it says the environment was seen and ignored" "IGNORED" "$CO_OUT"; }

test_r4_cron_form_records_the_destination() { # R15. The README documents
                                # `--quiet --no-log-file` as the cron form. On a SUCCESSFUL run it
                                # produces 407 bytes of output -- the ASCII banner, and nothing else.
                                # Measured: not one mention of the server, the endpoint or the peer,
                                # while the listener recorded the upload. Round 3 closed this for
                                # FATALS (force_sink is reached from die/die_runtime); the success
                                # path has no equivalent, so a scheduled collection that worked
                                # leaves no record on the host of where the evidence went.
                                #
                                # This is the same sentence the suite's own header uses to describe
                                # the pre-round-1 '@' bypass: "the total output was 406 bytes of
                                # ASCII banner -- nothing records the destination".
                                require_python3 || return 77
                                local p log
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --quiet --no-log-file \
                                    --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                assert_ge "and evidence really was uploaded" 1 "$(count_req "$log" 'POST /api/checkAsync*')" || return 1
                                assert_contains "so some sink must name where it went" "127.0.0.1" "$CO_OUT"; }

# shellcheck disable=SC1090,SC2034  # the library is built at run time; the assignments are the state under test
test_r4_redirect_default_is_safe_before_prepare_run() { # R4. WGET_EXTRA_OPTS is declared empty at
                                # file scope and only given --max-redirect=0 inside prepare_run,
                                # but the signal traps are installed at file scope and
                                # send_interrupted_marker's only gate is SERVER_URLHOST_OUT, which
                                # validate_config sets EARLIER. A signal in that window runs
                                # collection_marker with an empty option array: wget's default
                                # --max-redirect=20, no --insecure, no --ca-cert, and WGETRC not yet
                                # exported. The redirect defence is absent exactly where the
                                # destination is least supervised.
                                local lib out
                                lib="$WORK/collector-lib-r4.sh"
                                sed '$d' "$COLLECTOR" | sed '$d' > "$lib" || return 1
                                out="$( . "$lib" >/dev/null 2>&1
                                        printf '%s' "${WGET_EXTRA_OPTS[*]:-}" )"
                                assert_contains "the safe redirect default exists before prepare_run runs" \
                                    "--max-redirect=0" "$out"; }

# shellcheck disable=SC1090,SC2034  # the library is built at run time; the assignments are the state under test
test_r4_interrupted_marker_is_withheld_too() { # R2. report_run refuses to send the END marker to a
                                # peer that never acknowledged an upload (:3141-3147), on the stated
                                # ground that the marker carries the host's source name and the
                                # run's complete statistics and "the collector has already decided
                                # it is not [a Thunderstorm], so it stops talking to it -- including
                                # about itself". send_interrupted_marker's gate (:544) is DRY_RUN
                                # and SERVER_URLHOST_OUT only. A signal therefore re-opens exactly
                                # that channel: withholding is still half-applied, one path later
                                # than it was.
                                #
                                # Tested through the gate rather than through a real signal: the
                                # window between "PEER_UNACKNOWLEDGED is set" and "report_run runs"
                                # is microseconds wide, because withheld files are never
                                # transmitted and so cost no time. A signal test here passes
                                # whenever the run simply finished first -- which is what the first
                                # draft of this test did. Same technique as
                                # test_a_interrupted_marker_needs_validation.
                                require_python3 || return 77
                                local p log lib
                                start_listener yes200 || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                lib="$WORK/collector-lib-r2.sh"
                                sed '$d' "$COLLECTOR" | sed '$d' > "$lib" || return 1
                                ( . "$lib" >/dev/null 2>&1
                                  command -v send_interrupted_marker >/dev/null 2>&1 ) || {
                                    printf "    the collector could not be sourced as a library\n"; return 1; }
                                ( . "$lib" >/dev/null 2>&1
                                  DRY_RUN=0
                                  START_TS=0
                                  THUNDERSTORM_SERVER="127.0.0.1"
                                  THUNDERSTORM_PORT="$p"
                                  classify_server "127.0.0.1" >/dev/null 2>&1
                                  # The state report_run refuses to talk to.
                                  PEER_UNACKNOWLEDGED=1
                                  PEER_UNACKNOWLEDGED_AT="http://127.0.0.1:$p/api/checkAsync"
                                  SOURCE_NAME="r4-secret-hostname"
                                  send_interrupted_marker ) >/dev/null 2>&1
                                assert_eq "no interrupted marker reaches an unacknowledged peer" 0 \
                                    "$(count_req "$log" 'POST /api/collection*')" || return 1
                                assert_eq "and the host's source name is not handed to it" 0 \
                                    "$(count_req "$log" 'BODY *r4-secret-hostname*')"; }

test_r4_end_marker_docs_match_the_code() { # R6. The collector's own state comment (:166-167) says
                                # of an unacknowledged peer: "The run still ends normally (end
                                # marker attempted, exit 4)". The README says the same. The code at
                                # :3141-3147 withholds the end marker and logs that it did. Three
                                # statements, two of them wrong; which one is wrong is the owner's
                                # call, but they cannot all stand.
                                local src readme
                                src="$(sed -n '160,175p' "$COLLECTOR")"
                                readme="$(cat "$REPO_ROOT/scripts/bash/README.md" 2>/dev/null)"
                                assert_not_contains "the collector's comment must not claim the end marker is attempted" \
                                    "end marker attempted" "$src" || return 1
                                assert_not_contains "and neither must the README" \
                                    "the end marker is still attempted" "$readme"; }

# ══════════════════════════════════════════════════════════════════════════════
# ROUND 5 — the destination's FUNCTIONALITY, benchmarked against UAC, Velociraptor,
# GRR/Fleetspeak, osquery, Wazuh, Elastic Beats and DFIR ORC. Round 4 hardened the --server
# grammar; these are the things the other collectors do around the destination that we did not.
# Encryption flags are deliberately out of scope for this round.
# ══════════════════════════════════════════════════════════════════════════════

test_r5_unspecified_address_refused() { # S1. The last well-formed value that cannot name a
                                # destination. Measured against a real listener: '0.0.0.0' connects
                                # to 127.0.0.1 and '::' connects to ::1 -- the transport maps the
                                # unspecified address to loopback on connect, so the run would
                                # print "Server: 0.0.0.0" while the evidence went to this host.
                                # That is the same silent-retarget class round 4 closed for
                                # '010.0.0.9'. 255.255.255.255 is the broadcast address: it names
                                # no unicast peer and curl simply cannot connect (measured 000), so
                                # refusing it early beats a transport timeout.
                                #
                                # Wazuh refuses exactly this set (src/config/client-config.c:594-611,
                                # Validate_Address() rejects "0.0.0.0" and the shipped placeholder).
                                local v
                                # '[::]' is no longer in this loop: since round 8 it is refused one
                                # arm earlier, for the brackets, so its reason is the spelling rather
                                # than the destination. Pinned in
                                # test_r4_ipv6_zone_and_bracket_spellings, which asserts both halves.
                                # The needle is per POPULATION, not the shared fragment: the two
                                # reasons make different claims, and the loopback-redirect sentence
                                # is TRUE only of the unspecified address. Asserting only "names no
                                # destination" let either message stand for the other.
                                for v in '0.0.0.0' '::' '255.255.255.255'; do
                                    offline_server --server "$v"
                                    assert_eq "'$v' must be a usage error" 2 "$CO_RC" || return 1
                                    assert_contains "'$v' says it names no destination" "names no destination" "$CO_OUT" || return 1
                                    case "$v" in
                                        255.255.255.255)
                                            assert_contains "'$v' is named as the broadcast address" "is the IPv4 broadcast address" "$CO_OUT" || return 1
                                            assert_not_contains "'$v' must not claim a loopback redirect" "redirects it to this host's own loopback" "$CO_OUT" || return 1 ;;
                                        *)
                                            assert_contains "'$v' is named as the unspecified address" "is the unspecified address" "$CO_OUT" || return 1 ;;
                                    esac
                                    assert_not_contains "'$v' must not reach URL composition" "API endpoint: http" "$CO_OUT" || return 1
                                done
                                # And the neighbours must still be accepted: this is a rule about
                                # three specific addresses, not about zeros or 255s.
                                expect_server_accept "0.0.0.1 is a real address" '0.0.0.1' '0.0.0.1' || return 1
                                expect_server_accept "255.255.255.254 is a real address" '255.255.255.254' '255.255.255.254' || return 1
                                expect_server_accept "::1 is a real address" '::1' '[::1]'; }

test_r5_unspecified_address_reaches_loopback() { # S1, the wire half: proof the refusal is worth
                                # having. The listener is on 127.0.0.1 and the operator typed
                                # 0.0.0.0, which names no host at all.
                                require_python3 || return 77
                                local p log
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server '0.0.0.0' --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_no_req "the unspecified address reaches no peer" "$log"; }

test_r5_preflight_requires_thunderstorm_body() { # S2. Our gate is documented as "REACHABILITY, not
                                # identity: any service answering 2xx on /api/status passes". It
                                # need not be that weak. Beats' pre-publish gate is
                                # `status < 300` AND a successful json.Unmarshal into its own
                                # two-field struct (libbeat/esleg/eslegclient/connection.go:318-327)
                                # -- a 200 carrying a foreign body is not a connection at all.
                                #
                                # /api/status is the one endpoint whose shape production and the
                                # reference stub agree on (measured on production: {"scanned_samples":
                                # 28003,"queued_async_requests":0,...}), which is why round 4 already
                                # made the TEST harness's own probe_live require it. The collector
                                # should hold itself to the same standard.
                                require_python3 || return 77
                                local p log
                                # yes200 answers 200 '{}' to everything, including /api/status: a
                                # permissive service that is not a Thunderstorm.
                                start_listener yes200 || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a foreign 2xx is not a usable server" 1 "$CO_RC" || return 1
                                assert_contains "and the run says why" "did not answer as a Thunderstorm" "$CO_OUT" || return 1
                                # The decisive half: not one file was read or sent.
                                assert_not_contains "nothing was collected" "Run completed" "$CO_OUT" || return 1
                                assert_eq "and no upload was attempted" 0 "$(count_req "$log" 'POST /api/checkAsync*')" || return 1
                                # A real Thunderstorm-shaped status body still passes, so the gate
                                # has not simply been tightened into uselessness.
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a real status document still passes" 0 "$CO_RC" || return 1
                                assert_eq "and the file is submitted" 1 "$(co_stat submitted)"; }

test_r5_preflight_is_not_cacheable() { # S5. GRR sends Cache-Control: no-cache on every request
                                # (comms.py:295-296) in the same file that explains why: the HTTP
                                # status alone cannot tell you whether the request reached the
                                # server. A cached or intermediary-served 200 must not be able to
                                # satisfy a gate whose whole job is to prove the destination is
                                # there right now.
                                require_python3 || return 77
                                local p log
                                start_listener hostecho || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                assert_ge "the preflight sent a no-cache header" 1 "$(count_req "$log" 'HDR cache-control: no-cache*')"; }

test_r5_failure_names_the_path_attempted() { # S4. When the destination cannot be reached the
                                # operator needs to know WHICH PATH failed. GRR's final message
                                # names every path it tried (direct, then configured proxies);
                                # Wazuh classifies an attempt by who could have produced it.
                                # Measured before this change: with a dead proxy the fatal read
                                # "Cannot reach a Thunderstorm server at http://ts.example:8080 --
                                # network failure -- check the host and port", which points the
                                # operator at the host and port when the proxy was the problem.
                                require_python3 || return 77
                                local dead
                                dead="$(refused_port)"
                                run_collector_env http_proxy="http://127.0.0.1:$dead" -- \
                                    --server ts.example --port 8080 --retries 1 \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run fails" 1 "$CO_RC" || return 1
                                assert_contains "and names the proxy that may be in the path" "a proxy is set in the environment" "$CO_OUT" || return 1
                                assert_contains "naming the proxy address" "127.0.0.1:$dead" "$CO_OUT"; }

test_r5_single_server_output_is_unchanged() { # The destination is named ONCE, up front, and the
                                # endpoint matches it. This was the control proving the candidate
                                # list did not tax the single-server default; the list is gone, so
                                # what it now guards is that the two lines stay where they are and
                                # that no selection prose ever comes back.
                                require_python3 || return 77
                                local p
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --source r5one \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                assert_contains "the server is stated once, as before" "Server: 127.0.0.1" "$CO_OUT" || return 1
                                assert_contains "and the endpoint as before" "API endpoint: http://127.0.0.1:$p/api/checkAsync?source=r5one" "$CO_OUT" || return 1
                                assert_not_contains "no candidate list for a single server" "Servers:" "$CO_OUT" || return 1
                                assert_not_contains "and no selection prose" "no candidate answered" "$CO_OUT"; }

test_r5_curl_receives_the_options_it_is_given() { # S4/S7. Both of these options are invisible in
                                # the run's output, and both were briefly DEAD -- added behind a
                                # `[ "$UPLOAD_TOOL" = "curl" ]` guard that ran before the tool was
                                # detected, so the guard could never be true. Nothing in the suite
                                # could see that, because neither option changes anything an
                                # assertion was looking at. An option that decides where evidence
                                # goes has to be assertable where it is handed to the transport.
                                require_python3 || return 77
                                local p shim
                                # NOT "$(curl_argv_capture_path)": it sets CURL_ARGV_LOG_OUT, and a
                                # command substitution would set it in a subshell -- the exact
                                # mistake that made the first draft of this test assert against a
                                # file that did not exist.
                                curl_argv_capture_path >/dev/null || return 77
                                shim="$CURL_ARGV_DIR"
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                : > "$CURL_ARGV_LOG_OUT"
                                # A proxy variable must be set: --suppress-connect-headers is only
                                # meaningful for a proxy CONNECT, and its capability probe is an
                                # extra `curl --version` that a counting test double would score as
                                # an upload -- so the collector only probes when a proxy is in the
                                # environment. no_proxy exempts this host, so nothing is actually
                                # proxied and the run still succeeds directly.
                                run_collector_env PATH="$shim:$PATH" http_proxy="http://127.0.0.1:9" no_proxy="127.0.0.1" -- \
                                    --server 127.0.0.1 --port "$p" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                curl_argv_has '*--suppress-connect-headers*' \
                                    || { printf "    FAIL: curl was never given --suppress-connect-headers\n"; return 1; }
                                # And the flags this file has always relied on, so the capture
                                # itself is proven to be looking at the real invocation.
                                curl_argv_has '*-q *' || { printf "    FAIL: curl was never given -q\n"; return 1; }
                                curl_argv_has '*-g *' || { printf "    FAIL: curl was never given -g\n"; return 1; }
                                # The --resolve half of this test went with --server-addr: nothing in
                                # the file passes --resolve any more, and curl_supports no longer has
                                # a value-taking form to exercise.
                                curl_argv_has '*--resolve*' \
                                    && { printf "    FAIL: curl was given --resolve, which no flag should produce\n"; return 1; }
                                return 0; }

test_r7_dry_run_proves_the_path() { # Was test_r5_test_server_proves_the_path_and_reads_nothing.
                                # --test-server is gone; a dry run answers the same question -- is
                                # the destination there, which address answered, is a proxy in the
                                # way -- and then also reports what it would send. The "reads
                                # nothing" half of the old name is deliberately not asserted any
                                # more: a dry run walks, because a dry run is a real run minus the
                                # transmission.
                                require_python3 || return 77
                                local p log
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_eq "a reachable destination is exit 0" 0 "$CO_RC" || return 1
                                assert_contains "it names the endpoint" "API endpoint: http://127.0.0.1:$p/api/" "$CO_OUT" || return 1
                                # The decisive half: exactly one request, the status probe. No
                                # marker, no upload -- the transmission is what a dry run withholds.
                                assert_eq "exactly one request, the status probe" 1 "$(count_req "$log" 'GET *' 'POST *')" || return 1
                                assert_eq "no marker was sent" 0 "$(count_req "$log" 'POST /api/collection*')" || return 1
                                assert_eq "and no upload" 0 "$(count_req "$log" 'POST /api/checkAsync*')"; }

test_r7_dry_run_names_an_unreachable_destination() { # Was the --test-server version. The
                                # whole point is to learn BEFORE the collection, so an unreachable
                                # destination must be loud and non-zero -- and under the dry-run rule
                                # it is fatal for the same reason a real run is: that is what would
                                # happen.
                                local dead
                                dead="$(pick_port)"
                                run_collector --server 127.0.0.1 --port "$dead" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_contains "the verdict is reported" "Cannot reach a Thunderstorm server" "$CO_OUT" || return 1
                                assert_contains "and names the path attempted" "http://127.0.0.1:$dead" "$CO_OUT"; }

test_r5_dead_destination_stops_the_run() { # S3. A destination that dies mid-run currently costs
                                # one FULL retry budget per remaining file and produces a wall of
                                # identical errors -- on a real host with a large tree that is
                                # minutes of pointless network timeouts and an unreadable log.
                                #
                                # GRR does this in three layers and will not even dequeue evidence
                                # it cannot ship; Wazuh classifies "nothing answered" as the only
                                # state that pauses the run and re-probes. The shape here: after a
                                # few CONSECUTIVE transport failures, re-run the preflight once --
                                # a server that merely hiccupped is forgiven -- and if that fails
                                # too, stop transmitting and account for the rest in one line.
                                require_python3 || return 77
                                local p log tree i=0 attempts
                                start_listener dieupload || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                tree="$WORK/breaker"
                                if [ ! -d "$tree" ]; then
                                    mkdir -p "$tree" || return 1
                                    while [ "$i" -lt 12 ]; do printf 'x\n' > "$tree/f$i.txt"; i=$(( i + 1 )); done
                                fi
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 \
                                    --no-log-file --no-progress --dir "$tree"
                                # The destination died, so this is a partial failure and every file
                                # is still accounted for -- withholding must not lose entries.
                                assert_eq "the run is a partial failure" 4 "$CO_RC" || return 1
                                assert_eq "every discovered file is accounted for" 12 "$(co_stat scanned)" || return 1
                                assert_contains "the run says the destination stopped answering" "stopped answering" "$CO_OUT" || return 1
                                # The decisive half: the collector STOPPED trying. Measured from
                                # its OWN attempt warnings, not from the listener -- once the peer
                                # is gone the connection is refused and the listener records
                                # nothing, so a listener-side count cannot see an attempt at all.
                                # (The first draft of this test asserted on the listener log and
                                # measured 1: the single acknowledged upload.)
                                attempts="$(printf '%s\n' "$CO_OUT" | grep -c "Upload failed for" || printf 0)"
                                assert_le "it stopped attempting uploads" 4 "$attempts" || return 1
                                # And it did not give up on the first failure: the breaker exists to
                                # forgive a hiccup, so it must have tried more than once.
                                assert_ge "but not on the very first failure" 2 "$attempts" || return 1
                                # One bounded line, not twelve identical ones.
                                assert_le "the log is not a wall of identical errors" 4 \
                                    "$(printf '%s\n' "$CO_OUT" | grep -c "Could not upload" || printf 0)" || return 1
                                # And the withheld files are accounted for in one place.
                                assert_contains "the withheld count is stated" "file(s) were counted as failed WITHOUT being transmitted" "$CO_OUT"; }

test_r5_a_single_hiccup_does_not_stop_the_run() { # S3's other half, and the reason the breaker
                                # re-probes instead of tripping on a streak alone: a server that
                                # drops one connection must not cost the rest of the collection.
                                # ackthenhtml fails exactly the THIRD upload and answers every
                                # other one, so a breaker that gave up on isolated failures would
                                # lose the remaining files.
                                require_python3 || return 77
                                local p log
                                start_listener ackthenhtml || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                # One file is refused by the peer; the rest must still be delivered.
                                assert_eq "the run is a partial failure" 4 "$CO_RC" || return 1
                                assert_eq "and all but one file was submitted" "$((FIXTURE_COUNT - 1))" "$(co_stat submitted)" || return 1
                                assert_eq "every file was attempted" "$FIXTURE_COUNT" "$(count_req "$log" 'POST /api/checkAsync*')" || return 1
                                assert_not_contains "the breaker did not trip" "stopped answering" "$CO_OUT"; }

# ── Axis G — the live server ──────────────────────────────────────────────────
#
# Measured against thunderstorm.clu.dev.nextron (46.225.41.31:443, THOR 11.0.0-dev) on
# 2026-09-07. What production actually does, and what no stub could have told us:
#
#   GET  /api/status      -> 200 {"scanned_samples":N,"queued_async_requests":0,...}
#   POST /api/checkAsync  -> 200 {"id":28005}          -- a NUMBER; the reference stub answers a
#                                                         STRING, so only production exercises the
#                                                         numeric branch of the acknowledgement check
#   POST /api/check       -> 200 null                  -- the clean-file answer
#   POST /api/collection  -> 404                       -- production does NOT implement the
#                                                         collection markers at all
#   https://46.225.41.31  -> 404 on /api/status        -- the deployment is NAME-BASED: the IP
#                                                         literal reaches the host and a different
#                                                         vhost answers
#   the certificate is not in the system trust store, so --insecure or --ca-cert is required.
#
# Each case below sends at most one 34-byte fixture, tagged with its own --source.

live_r4() { run_collector --no-log-file --no-progress --source "r4-$1-$$" \
                --server "$LIVE_HOST" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} "${@:2}"; }

test_r4_live_ack_shape_and_markers() { # G1+G2. The two facts the whole live tier rests on, in one
                                # run: production acknowledges with a NUMERIC id (the stub's is a
                                # string, so this is the only place the numeric branch runs), and it
                                # answers 404 on /api/collection -- which the collector must treat
                                # as "not implemented", warn about, and CONTINUE past. Any other
                                # status there makes the begin marker fatal (:4225-4228) and would
                                # abort every collection before a file is read.
                                require_live || return 77
                                live_r4 ackshape --dir "$ONEFILE"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                assert_eq "the file is submitted" 1 "$(co_stat submitted)" || return 1
                                assert_eq "and nothing failed" 0 "$(co_stat failed)" || return 1
                                assert_contains "the markers are absent, not broken" \
                                    "Collection marker 'begin' not supported (HTTP 404)" "$CO_OUT" || return 1
                                assert_contains "and the end marker says the same" \
                                    "Collection marker 'end' not supported (HTTP 404)" "$CO_OUT" || return 1
                                assert_not_contains "a 404 marker is never a fatal" "failed after retry" "$CO_OUT" || return 1
                                # Peer-address reporting was deleted with the proxy verdict, so the
                                # remaining live fact is that the ACK was real: production answers a
                                # NUMERIC id and the file is booked as submitted, which the counters
                                # above already prove. What must not come back is a peer claim.
                                assert_not_contains "no peer address is claimed any more" "Upload peer" "$CO_OUT"; }

test_r4_live_ip_literal_is_honest() { # G5. The validator accepts an IPv4 literal, and this
                                # deployment is name-based: https://46.225.41.31/api/status answers
                                # 404 (measured). The collector must therefore fail, and fail
                                # SAYING SO -- "something is listening there but it did not answer
                                # as a Thunderstorm" -- never collect against the wrong vhost and
                                # never report success. This is the case an operator who pasted an
                                # address out of a ticket will hit.
                                require_live || return 77
                                local ip
                                ip="$(getent ahostsv4 "$LIVE_HOST" 2>/dev/null | awk 'NR==1{print $1}')"
                                [ -n "$ip" ] || return 77
                                run_collector --no-log-file --no-progress --source "r4-literal-$$" \
                                    --server "$ip" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "the run fails rather than collecting" 1 "$CO_RC" || return 1
                                assert_contains "and says what answered" "did not answer as a Thunderstorm" "$CO_OUT" || return 1
                                assert_not_contains "nothing was collected" "Run completed" "$CO_OUT"; }

test_r4_live_tls_untrusted_refused() { # G3. The certificate is not in the system trust store.
                                # Without --insecure the run must stop before a file is read and
                                # name both remedies.
                                require_live || return 77
                                [ "$LIVE_TLS" = "1" ] || return 77
                                run_collector --no-log-file --no-progress --source "r4-notrust-$$" \
                                    --server "$LIVE_HOST" --port "$LIVE_PORT" --ssl --dir "$ONEFILE"
                                assert_eq "the run fails" 1 "$CO_RC" || return 1
                                assert_contains "naming the cause and the remedies" \
                                    "certificate not trusted or name mismatch (use --ca-cert, or --insecure to accept it)" "$CO_OUT" || return 1
                                assert_not_contains "and no file was read" "Run completed" "$CO_OUT"; }

test_r4_live_ca_cert_real_chain() { # G4. --ca-cert against the server's OWN chain, and without
                                # --ssl, so one run proves both documented claims at once: --ca-cert
                                # implies --ssl, and under curl it REPLACES the trust store (a store
                                # that does not contain this certificate).
                                require_live || return 77
                                [ "$LIVE_TLS" = "1" ] || return 77
                                command -v openssl >/dev/null 2>&1 || return 77
                                local chain="$WORK/live-chain.pem"
                                openssl s_client -showcerts -servername "$LIVE_HOST" \
                                    -connect "$LIVE_HOST:$LIVE_PORT" </dev/null 2>/dev/null \
                                    | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$chain" || return 77
                                [ -s "$chain" ] || return 77
                                run_collector --no-log-file --no-progress --source "r4-cacert-$$" \
                                    --server "$LIVE_HOST" --port "$LIVE_PORT" --ca-cert "$chain" --dir "$ONEFILE"
                                # A self-signed leaf validates against itself; a chain whose root is
                                # not included does not. Either outcome is legitimate -- what is not
                                # legitimate is succeeding without https, or failing without saying
                                # the certificate was the reason.
                                assert_contains "--ca-cert alone selected https" "API endpoint: https://" "$CO_OUT" || return 1
                                if [ "$CO_RC" -eq 0 ]; then
                                    assert_contains "and curl's replace semantics were stated" "replaces the trust store" "$CO_OUT" || return 1
                                    assert_eq "the file is submitted" 1 "$(co_stat submitted)"
                                else
                                    assert_eq "or it fails as a trust failure" 1 "$CO_RC" || return 1
                                    assert_contains "naming the certificate" "certificate not trusted" "$CO_OUT"
                                fi; }

test_r4_live_name_spellings()   { # G12+G13. Two spellings the validator accepts and no round has
                                # ever sent to a real, name-based, TLS-terminating deployment: the
                                # trailing root dot (which changes SNI on some stacks) and upper
                                # case. Measured directly with curl: both answer 200 here. If either
                                # ever stops working, an accepted spelling is costing a legitimate
                                # destination and the validator's accept-set has to change.
                                require_live || return 77
                                local upper
                                run_collector --no-log-file --no-progress --source "r4-rootdot-$$" \
                                    --server "${LIVE_HOST}." --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "the trailing root dot delivers" 0 "$CO_RC" || return 1
                                assert_eq "and submits" 1 "$(co_stat submitted)" || return 1
                                upper="$(printf '%s' "$LIVE_HOST" | tr '[:lower:]' '[:upper:]')"
                                run_collector --no-log-file --no-progress --source "r4-upper-$$" \
                                    --server "$upper" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "and so does upper case" 0 "$CO_RC" || return 1
                                assert_eq "and submits too" 1 "$(co_stat submitted)"; }

test_r4_live_wget_delivers()    { # G11. The wget transport against a real TLS peer: the option
                                # spelling differs (--no-check-certificate, --ca-certificate=),
                                # --max-redirect=0 has to be right, and the peer address comes from
                                # a completely different code path (wget's own progress line).
                                require_live || return 77
                                local shim ip
                                shim="$(wget_only_path)" || return 77
                                run_collector_env PATH="$shim" -- --no-log-file --no-progress --source "r4-wget-$$" \
                                    --server "$LIVE_HOST" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "wget delivers over TLS" 0 "$CO_RC" || return 1
                                assert_contains "and used wget" "Transport: wget" "$CO_OUT" || return 1
                                assert_eq "and submitted the file" 1 "$(co_stat submitted)" || return 1
                                assert_eq "and acknowledged the file" 1 "$(co_stat submitted)"; }

test_r4_live_refused_shapes_send_nothing() { # G14. The refused shapes, against a real host, must
                                # cost nothing and take no time -- the proof that the gate runs
                                # before the network, not after it. ':443' is the one that looks
                                # most like something an operator would type.
                                require_live || return 77
                                local v
                                for v in "${LIVE_HOST}/" "${LIVE_HOST}@127.0.0.1" "${LIVE_HOST}:443" \
                                         "${LIVE_HOST}#x" "${LIVE_HOST}?a=b" "https://${LIVE_HOST}"; do
                                    run_collector --no-log-file --no-progress --source "r4-refused-$$" \
                                        --server "$v" --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                    assert_eq "'$v' is a usage error" 2 "$CO_RC" || return 1
                                    assert_not_contains "'$v' collects nothing" "Run completed" "$CO_OUT" || return 1
                                    assert_le "'$v' is refused without touching the network" 3000 "$CO_MS" || return 1
                                done; }

test_r4_live_interrupt_is_prompt() { # G17. An operator's Ctrl-C over real TLS, against a server
                                # whose /api/collection answers 404: the handler still attempts a
                                # marker, over a fresh TLS handshake, and must not make the operator
                                # wait. Bounded rather than timed exactly -- the number is reported.
                                require_live || return 77
                                local slow t0 t1 i=0
                                slow="$(make_slow_curl_path r4live)" || return 77
                                run_collector_bg_env PATH="$slow:$PATH" -- --no-log-file --no-progress \
                                    --source "r4-interrupt-$$" --server "$LIVE_HOST" --port "$LIVE_PORT" \
                                    ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$FIXTURES"
                                while [ "$i" -lt 400 ]; do
                                    grep -q 'Found ' "$CO_BG_OUT_FILE" 2>/dev/null && break
                                    kill -0 "$CO_BG_PID" 2>/dev/null || break
                                    sleep 0.05; i=$(( i + 1 ))
                                done
                                kill -0 "$CO_BG_PID" 2>/dev/null || return 77
                                t0="$(now_ms)"
                                kill -INT "$CO_BG_PID" 2>/dev/null || :
                                bounded_wait "$CO_BG_PID" 900 || { printf "    the handler hung against the live server\n"; return 1; }
                                t1="$(now_ms)"
                                [ "$BOUNDED_WAIT_RC" -eq 130 ] || return 77
                                printf "\n      [measured] live interrupt honoured in %s ms\n" "$(( t1 - t0 ))"
                                assert_contains "the handler ran" "Received SIGINT" "$(co_bg_out)" || return 1
                                assert_le "and the operator is not left waiting" 30000 "$(( t1 - t0 ))"; }

# ---------------------------------------------------------------------------
# H -- round 6: bounds on server-controlled input, and address canonicalisation
#
# Every test in this section was written from a MEASUREMENT taken before the fix, not from what the
# fix was intended to do. Round 5 shipped 114/114 green and this round found 39 defects in it,
# because its own new code was never pinned red first.
# ---------------------------------------------------------------------------

test_r6_huge_status_body_is_bounded() { # The preflight reads /api/status into a shell variable one
                                # line at a time (`acc="$acc$line"`), which is O(n^2) in the number
                                # of lines -- of a body the SERVER chooses, on first contact, before
                                # a single file is read. 8 MB in 128 KB chunks, 131072 lines.
                                #
                                # Chunked with no Content-Length on purpose: measured on curl
                                # 7.88.1, --max-filesize CANNOT bound this (it needs a declared
                                # length), so a bound has to exist on our side of the pipe.
                                # Run in the BACKGROUND with a hard reap. A test that just waits for
                                # the run and then asserts on elapsed time cannot fail in bounded
                                # time -- against the unfixed tree it made the whole suite exceed
                                # its 600 s budget and get killed, which is a hang, not a red test.
                                require_python3 || return 77
                                local p t0 t1
                                start_listener bigchunked || return 1
                                p="$LISTENER_PORT_OUT"
                                t0="$(now_ms)"
                                run_collector_bg --server 127.0.0.1 --port "$p" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                if ! bounded_wait "$CO_BG_PID" 600; then
                                    stop_listener
                                    printf "    still parsing an 8 MB /api/status body after 30 s\n"
                                    return 1
                                fi
                                t1="$(now_ms)"
                                stop_listener
                                printf "\n      [measured] 8 MB /api/status handled in %s ms\n" "$(( t1 - t0 ))"
                                # The body must be REJECTED, and saying so must not cost seconds of
                                # CPU. The run is a dry run, so the verdict is reported rather than
                                # fatal -- what is under test is the BOUND, not the exit code.
                                #
                                # The elapsed ASSERTION, not just the printf: the 30 s reap above is
                                # far too loose to catch the identity loop, which is O(keys x bytes)
                                # over the retained body and measured 26 438 ms here before the
                                # substring guard, 53 ms after. Anything past 5 s means the guard is
                                # gone; the whole run costs well under 1 s when it is present.
                                assert_le "refusing it costs no seconds of CPU" 5000 "$(( t1 - t0 ))" || return 1
                                assert_contains "an 8 MB non-status body is refused" "not a Thunderstorm" "$(co_bg_out)" || return 1
                                assert_contains "and a real run is told what it would have done" "a real run would stop here" "$(co_bg_out)"; }

test_r6_huge_status_body_is_bounded_under_wget() { # Same body, other transport. wget writes the
                                # body with -O and the same read follows, so the cost is identical;
                                # what differs is that wget has no total-transfer bound of its own.
                                require_python3 || return 77
                                local p shim t0 t1
                                shim="$(wget_only_path)" || return 77
                                start_listener bigchunked || return 1
                                p="$LISTENER_PORT_OUT"
                                t0="$(now_ms)"
                                run_collector_bg_env PATH="$shim" -- --server 127.0.0.1 --port "$p" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                if ! bounded_wait "$CO_BG_PID" 600; then
                                    stop_listener
                                    printf "    still parsing an 8 MB /api/status body after 30 s (wget)\n"
                                    return 1
                                fi
                                t1="$(now_ms)"
                                stop_listener
                                printf "\n      [measured] 8 MB /api/status under wget in %s ms\n" "$(( t1 - t0 ))"
                                assert_le "refusing it costs no seconds of CPU" 5000 "$(( t1 - t0 ))" || return 1
                                assert_contains "refused" "not a Thunderstorm" "$(co_bg_out)"; }

test_r6_trickled_status_body_is_bounded() { # One byte every 200 ms, forever. curl is bounded by the
                                # --max-time 15 the preflight already carries; wget's
                                # --read-timeout is a PER-READ timer that every byte resets, so
                                # wget alone has no bound at all here. Run in the background with a
                                # hard reap so a hang fails the test instead of hanging the suite.
                                require_python3 || return 77
                                local p shim
                                shim="$(wget_only_path)" || return 77
                                start_listener trickle || return 1
                                p="$LISTENER_PORT_OUT"
                                # PATH="$shim", NOT "$shim:$PATH" -- prepending leaves the system
                                # curl reachable, so the collector picks curl and the test measures
                                # the wrong transport. Measured: it reported "Transport: curl" and
                                # was bounded at 15 s by --max-time, which is precisely the bound
                                # wget does not have.
                                run_collector_bg_env PATH="$shim" -- --server 127.0.0.1 --port "$p" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                if ! bounded_wait "$CO_BG_PID" 900; then
                                    stop_listener
                                    printf "    wget read a trickled /api/status for 45 s without a bound\n"
                                    return 1
                                fi
                                stop_listener
                                # Assert the TRANSPORT too. The first version of this test used
                                # PATH="$shim:$PATH", the system curl won, and it measured curl's
                                # --max-time while claiming to measure wget's missing bound.
                                assert_contains "the wget path really ran" "Transport: wget" "$(co_bg_out)" || return 1
                                assert_contains "and the bound is named honestly" "total time bound" "$(co_bg_out)"; }

test_r6_pretty_status_document_is_still_recognised() { # The other side of the bound: a VALID,
                                # pretty-printed Thunderstorm status document whose recognised
                                # field sits ~40 KB in. A read bound set too tight (4 KB was my
                                # first proposal) makes the collector call a healthy server "not a
                                # Thunderstorm" -- a regression this pins before it can happen.
                                require_python3 || return 77
                                local p
                                start_listener prettylate || return 1
                                p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_eq "a pretty-printed status document is accepted" 0 "$CO_RC" || return 1
                                assert_eq "and the run proceeds" 0 "$CO_RC"; }

test_r6_mapped_unspecified_is_refused() { # MEASURED: `--server ::ffff:0.0.0.0` exits 0 and reaches
                                # this host's own loopback (curl to [::ffff:0.0.0.0] returned 200
                                # from ::ffff:127.0.0.1), while the plain `0.0.0.0` is refused with
                                # exit 2. The predicate is a character filter (`*[!0:.]*`) and the
                                # mapped spelling contains 'f'.
                                run_collector --server '::ffff:0.0.0.0' --dry-run --no-log-file \
                                    --no-progress --dir "$FIXTURES"
                                assert_eq "the mapped unspecified address is refused" 2 "$CO_RC" || return 1
                                assert_contains "for the same reason as 0.0.0.0" "names no destination" "$CO_OUT"; }

test_r6_mapped_broadcast_is_refused() { # Same bypass, second policy: `::ffff:255.255.255.255` exits
                                # 0 where `255.255.255.255` is refused. Two policies are bypassed by
                                # one spelling, which is why the fix canonicalises instead of adding
                                # a predicate per policy.
                                run_collector --server '::ffff:255.255.255.255' --dry-run --no-log-file \
                                    --no-progress --dir "$FIXTURES"
                                assert_eq "the mapped broadcast address is refused" 2 "$CO_RC" || return 1
                                assert_contains "for the same reason as 255.255.255.255" "names no destination" "$CO_OUT"; }

test_r6_no_marker_before_the_begin_marker() { # The interrupted marker was gated on
                                # SERVER_URLHOST_OUT, which validate_config sets at the very top of
                                # prepare_run -- long before there is anything to interrupt ON THE
                                # SERVER. A signal in that window POSTs the host's source name and
                                # run statistics to a peer that has not been selected yet, and does
                                # it with the option arrays still half-built: no --noproxy, no
                                # --resolve, no -k, no --cacert. The right gate is the begin marker,
                                # because before it no collection exists on the server at all.
                                #
                                # The window is opened with a curl that sleeps 5 s, so the signal
                                # lands inside the PREFLIGHT: destination validated, begin marker
                                # not yet sent.
                                require_python3 || return 77
                                local p log slow
                                slow="$(make_delayed_curl_path 5 premarker)" || return 77
                                start_listener scanid || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector_bg_env PATH="$slow:$PATH" -- --server 127.0.0.1 \
                                    --port "$p" --no-log-file --no-progress --dir "$FIXTURES"
                                # Wait for the run to reach the preflight, then interrupt it there.
                                local i=0
                                while [ "$i" -lt 60 ]; do
                                    grep -q 'Folders:' "$CO_BG_OUT_FILE" 2>/dev/null && break
                                    kill -0 "$CO_BG_PID" 2>/dev/null || break
                                    sleep 0.05; i=$(( i + 1 ))
                                done
                                kill -0 "$CO_BG_PID" 2>/dev/null || { stop_listener; return 77; }
                                kill -INT "$CO_BG_PID" 2>/dev/null || :
                                bounded_wait "$CO_BG_PID" 900 || { stop_listener; printf "    the handler hung\n"; return 1; }
                                stop_listener
                                assert_eq "no collection marker is sent before the begin marker" \
                                    0 "$(count_req "$log" '*/api/collection*')"; }

test_r7_interrupted_dry_run_sends_no_marker() { # Was the --test-server version of this promise.
                                # A dry run transmits nothing, and a signal must not make it
                                # transmit: the interrupted marker carries this host's source name
                                # and the run statistics.
                                require_python3 || return 77
                                local p log slow i=0
                                slow="$(make_delayed_curl_path 5 drysig)" || return 77
                                start_listener ackstr || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector_bg_env PATH="$slow:$PATH" -- --server 127.0.0.1 \
                                    --port "$p" --dry-run --no-log-file --no-progress --dir "$FIXTURES"
                                while [ "$i" -lt 200 ]; do
                                    grep -q 'Port:' "$CO_BG_OUT_FILE" 2>/dev/null && break
                                    kill -0 "$CO_BG_PID" 2>/dev/null || break
                                    sleep 0.05; i=$(( i + 1 ))
                                done
                                kill -0 "$CO_BG_PID" 2>/dev/null || { stop_listener; return 77; }
                                kill -INT "$CO_BG_PID" 2>/dev/null || :
                                bounded_wait "$CO_BG_PID" 900 || { stop_listener; printf "    the handler hung\n"; return 1; }
                                stop_listener
                                assert_eq "an interrupted dry run sends no marker" \
                                    0 "$(count_req "$log" '*/api/collection*')"; }

# shellcheck disable=SC1090,SC2034  # the library is built at run time; the assignments are the state under test
test_r8_marker_refuses_to_transmit_in_a_dry_run() { # The three marker call sites each carry their
                                # own DRY_RUN gate, so "a dry run sends no marker" held only while
                                # every caller remembered. collection_marker now refuses on its own.
                                # Called DIRECTLY here -- that is the fourth call site, the one a
                                # future change adds without a gate.
                                require_python3 || return 77
                                local p log lib out
                                start_listener yes200 || return 1
                                p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                lib="$WORK/collector-lib-r8.sh"
                                sed '$d' "$COLLECTOR" | sed '$d' > "$lib" || return 1
                                ( . "$lib" >/dev/null 2>&1
                                  command -v collection_marker >/dev/null 2>&1 ) || {
                                    printf "    the collector could not be sourced as a library\n"; return 1; }
                                out="$( . "$lib" >/dev/null 2>&1
                                        DRY_RUN=1
                                        SOURCE_NAME="r8-secret-hostname"
                                        UPLOAD_TOOL="curl"
                                        collection_marker "http://127.0.0.1:$p" "begin" "" "" 2>/dev/null )"
                                stop_listener
                                assert_eq "an unguarded caller still sends no marker" \
                                    0 "$(count_req "$log" '*/api/collection*')" || return 1
                                assert_eq "and the host's source name is not handed over" \
                                    0 "$(count_req "$log" '*r8-secret-hostname*')" || return 1
                                # stdout is the scan_id channel: a log line written to it becomes
                                # the caller's SCAN_ID. The refusal must be silent on this stream.
                                assert_eq "the scan_id channel stays empty" "" "$out"; }

test_r9_single_label_refused() { # OWNER DECISION: --server must not depend on the COLLECTED host's
                                # resolver configuration. A dotless name is completed from that
                                # host's search list, so one command line can reach a different
                                # server on every host while every log reads the same.
                                #
                                # The rule is "contains a dot", not "has two labels": a trailing
                                # root dot makes a name absolute, so it is never search-expanded.
                                offline_server --server 'thunderstorm'
                                assert_eq "a single label is a usage error" 2 "$CO_RC" || return 1
                                assert_contains "and says why" "is a single label" "$CO_OUT" || return 1
                                assert_contains "and what to type instead" "give the fully qualified name" "$CO_OUT" || return 1
                                assert_not_contains "nothing is composed from it" "API endpoint: http" "$CO_OUT" || return 1
                                # localhost is the case this costs; pinned so it cannot come back
                                # by accident.
                                offline_server --server 'localhost'
                                assert_eq "localhost is refused too" 2 "$CO_RC" || return 1
                                assert_contains "for the same reason" "is a single label" "$CO_OUT" || return 1
                                # The absolute spellings stay accepted.
                                expect_server_accept "a trailing root dot is absolute" 'thunderstorm.' 'thunderstorm.' || return 1
                                expect_server_accept "and an FQDN is the normal case" 'thunderstorm.nextron.com' 'thunderstorm.nextron.com' || return 1
                                # Addresses are not names and are unaffected.
                                expect_server_accept "IPv4 is unaffected" '127.0.0.1' '127.0.0.1' || return 1
                                expect_server_accept "IPv6 is unaffected" '::1' '[::1]'; }

test_r8_old_curl_falls_back_to_the_header_dump() { # curl before 7.29 does not substitute -w, so
                                # the collector's -w file comes back EMPTY and the status has to be
                                # read from the header dump instead (curl_w_status -> the parser).
                                # old_curl_path has modelled exactly that since round 5 and nothing
                                # ever called it, so the fallback it was built for had no test.
                                require_python3 || return 77
                                local p shim
                                shim="$(old_curl_path)" || return 77
                                start_listener ackstr || return 1
                                p="$LISTENER_PORT_OUT"
                                run_collector_env PATH="$shim" -- --server 127.0.0.1 --port "$p" \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_eq "an old curl still completes the run" 0 "$CO_RC" || return 1
                                assert_eq "and the file is still submitted" 1 "$(co_stat submitted)" || return 1
                                # The failure this guards: an unsubstituted format string reaching
                                # the operator as though it were a value.
                                assert_not_contains "no unsubstituted -w format is printed" "%{" "$CO_OUT"; }

test_r6_source_is_encoded_without_od() { # urlencode shelled out to `od -An -tx1` (plus a `tr` to
                                # upcase the result) once per character outside the unreserved set,
                                # and neither command was detected. With od absent the command
                                # substitution produced nothing, the loop never ran, and the
                                # character was SILENTLY DROPPED -- so the run reported one source
                                # name and the server recorded a different one. Encoding a byte
                                # needs no external command at all.
                                local nood
                                nood="$(path_without od tr)" || return 77
                                run_collector_env PATH="$nood" -- --server ts.example --port 8080 \
                                    --source 'a b&c' --dry-run --no-log-file --no-progress \
                                    --dir "$ONEFILE"
                                assert_eq "the run succeeds without od" 0 "$CO_RC" || return 1
                                assert_contains "and the source is fully encoded" "source=a%20b%26c" "$CO_OUT"; }

# --- issue 4: the destination record -----------------------------------------------------------
# One ~40-line feature carried 13 findings. These five pin the ones a reader of the record could be
# actively misled by, and they are written against the CURRENT file, not against the rewrite.

test_r6_wget_bound_holds_without_timeout() { # wget_bounded has TWO mechanisms: timeout(1) when it
                                # is installed, and its own background-and-reap when it is not --
                                # which is the path that runs on a stock macOS, where the command is
                                # gtimeout. Every other test on this host takes the timeout(1)
                                # branch, so without this one the fallback ships untested.
                                require_python3 || return 77
                                local p shim t0 t1
                                shim="$(path_without curl timeout)" || return 77
                                [ -x "$shim/wget" ] || return 77
                                start_listener trickle || return 1
                                p="$LISTENER_PORT_OUT"
                                t0="$(now_ms)"
                                run_collector_bg_env PATH="$shim" -- --server 127.0.0.1 --port "$p" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                if ! bounded_wait "$CO_BG_PID" 900; then
                                    stop_listener
                                    printf "    the reap fallback did not bound a trickled body\n"
                                    return 1
                                fi
                                t1="$(now_ms)"
                                stop_listener
                                printf "\n      [measured] reap fallback bounded the transfer in %s ms\n" "$(( t1 - t0 ))"
                                assert_contains "the wget path ran" "Transport: wget" "$(co_bg_out)" || return 1
                                assert_contains "and the bound is named" "total time bound" "$(co_bg_out)" || return 1
                                # 15 s limit plus at most one second of poll granularity, and a wide
                                # ceiling so a loaded machine does not make this flaky.
                                assert_le "bounded near the declared limit" 40000 "$(( t1 - t0 ))"; }

# ---------------------------------------------------------------------------
# I -- round 7: a dry run is a real run minus the transmission
#
# The owner's rule: identical collection, identical reported results, the bytes simply do not leave
# the host. Every test here was RED before the change; the numbers in the comments were measured.
# ---------------------------------------------------------------------------

r7_stat() { # $1 output, $2 key -- anchored on the separator, because an unanchored "submitted="
            # matches inside "would_submit=" and a scraper taking the last match reads the wrong one
    printf '%s\n' "$1" | grep -oE "(^|[[:space:]])$2=[0-9]+" | tail -1 | cut -d= -f2
}

test_r7_dry_run_reports_a_dead_destination() { # THE decisive one. Measured before the change: a
                                # real run exits 1 ("Cannot reach a Thunderstorm server") and
                                # collects nothing, while the SAME command line with --dry-run
                                # exited 0 having said NOTHING about the destination -- so a dry run
                                # used to green-light a command line pointing at a host that was not
                                # there.
                                #
                                # It now runs the same check and reports the same verdict. It does
                                # NOT abort: a dry run that aborts shows nothing about what would be
                                # sent, which is the question being asked. So the two runs agree on
                                # the FACT and differ on the consequence, and the dry run says which
                                # consequence a real run would have had.
                                local dead
                                dead="$(pick_port)"
                                run_collector --server 127.0.0.1 --port "$dead" --no-log-file \
                                    --no-progress --dir "$ONEFILE"
                                assert_eq "the real run stops" 1 "$CO_RC" || return 1
                                assert_contains "naming the destination" "Cannot reach a Thunderstorm server" "$CO_OUT" || return 1
                                run_collector --server 127.0.0.1 --port "$dead" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_contains "the dry run reports the same verdict" "Cannot reach a Thunderstorm server" "$CO_OUT" || return 1
                                assert_contains "and says what a real run would do" "a real run would stop here" "$CO_OUT" || return 1
                                # It must not claim the destination answered, and must still preview.
                                assert_not_contains "no false claim of an answer" "Server answered on" "$CO_OUT" || return 1
                                assert_contains "the preview is still produced" "DRY-RUN: would submit" "$CO_OUT"; }

test_r7_dry_run_reports_the_same_collection() { # The other half of the rule: against a destination
                                # that IS there, a dry run must report the same discovery and
                                # selection numbers a real run reports.
                                require_python3 || return 77
                                local p real_out
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --source r7 \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "the real run succeeds" 0 "$CO_RC" || return 1
                                real_out="$CO_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --source r7 --dry-run \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                stop_listener
                                assert_eq "the dry run succeeds too" 0 "$CO_RC" || return 1
                                assert_eq "same discovered count" "$(r7_stat "$real_out" discovered)" "$(r7_stat "$CO_OUT" discovered)" || return 1
                                assert_eq "same scanned count" "$(r7_stat "$real_out" scanned)" "$(r7_stat "$CO_OUT" scanned)" || return 1
                                # ... and the number the operator came for is the same number,
                                # published under a key that does not claim a delivery.
                                assert_eq "the same count, honestly named" "$(r7_stat "$real_out" submitted)" "$(r7_stat "$CO_OUT" would_submit)" || return 1
                                assert_not_contains "nothing is called submitted" " submitted=" "$CO_OUT" || return 1
                                assert_contains "and the line cannot be mistaken for a real run" "Dry-run completed:" "$CO_OUT"; }

test_r7_dry_run_reconciles() { # The counter is deliberately NOT diverted into a parallel one: the
                                # identity at report_run sums FILES_SUBMITTED with the skip/fail/link
                                # counters, so diverting dry-run files out of it would make every dry
                                # run print "Reconciliation failed" and exit 4. This test pins that
                                # decision, symlinks included -- the symlink path books through the
                                # same submit_file.
                                require_python3 || return 77
                                local p
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --dry-run \
                                    --follow-symlinks --no-log-file --no-progress --dir "$FIXTURES"
                                stop_listener
                                assert_not_contains "a dry run reconciles" "Reconciliation failed" "$CO_OUT" || return 1
                                assert_eq "and does not become a partial failure" 0 "$CO_RC"; }

test_r7_dry_run_without_a_server_still_works() { # The offline preview: no destination named, so
                                # there is nothing to check and the run must say so rather than imply
                                # a destination was verified. This is what makes a fatal preflight
                                # acceptable in the case above.
                                offline_no_server() { run_collector --dry-run --no-log-file --no-progress --dir "$ONEFILE"; }
                                offline_no_server
                                assert_eq "a dry run with no --server succeeds" 0 "$CO_RC" || return 1
                                assert_contains "and says no destination was checked" "no --server" "$CO_OUT"; }

test_r7_test_server_flag_is_gone() { # Deleted: --dry-run --server X does strictly more (a dead
                                # destination now fails BEFORE the walk). 21 flags -> 20.
                                run_collector --server ts.example --port 8080 --test-server \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "--test-server is no longer an option" 2 "$CO_RC" || return 1
                                assert_contains "and says so" "Unknown option" "$CO_OUT"; }

# ---------------------------------------------------------------------------
# J -- round 8: --server names the host, in ONE spelling per host
#
# The rule: a DNS name, an IPv4 address, or an IPv6 address written PLAINLY. No port, no scheme, no
# brackets, no path, no credentials. The brackets an IPv6 URL needs are added by build_base_url; the
# operator never types them. --server-addr is gone -- the destination has one flag.
# ---------------------------------------------------------------------------

test_r8_the_three_accepted_shapes() { # The rule stated positively, so a future change cannot narrow
                                # it by accident. These three and nothing else.
                                expect_server_accept "a domain"        'thunderstorm.nextron' 'thunderstorm.nextron' || return 1
                                expect_server_accept "an IPv4 address" '46.225.41.31'         '46.225.41.31' || return 1
                                expect_server_accept "a plain IPv6"    '::1'                  '[::1]'; }

test_r8_brackets_are_refused() { # '::1' and '[::1]' were two spellings of one host, and the bracketed
                                # one also forced shell quoting ('[' and ']' are glob characters). One
                                # spelling per host: the brackets belong to the URL and the collector
                                # adds them.
                                expect_server_reject "bracketed IPv6" '[::1]' "is bracketed" || return 1
                                # The refusal must not tell the operator to write something this
                                # collector rejects -- the old message suggested the bracketed form.
                                # Anchored on "write --server", because the refusal legitimately
                                # ECHOES the rejected value, brackets and all: an assertion on
                                # "--server '[" alone cannot tell the echo from a suggestion.
                                assert_not_contains "no bracketed suggestion" "write --server [" "$CO_OUT" || return 1
                                assert_contains "it names the plain form" "--server ::1" "$CO_OUT"; }

test_r8_bracket_refusal_suggestion_runs() { # The invariant that caught '--port 0' and an empty
                                # '--port' in round 6: an example the operator will paste has to
                                # WORK. This test pastes it back and requires exit 0.
                                offline_server --server '[::1]:8080'
                                assert_eq "bracket + port is refused" 2 "$CO_RC" || return 1
                                local host port
                                host="$(printf '%s\n' "$CO_OUT" | sed -n 's/.*write --server \([^ ]*\).*/\1/p' | head -1)"
                                port="$(printf '%s\n' "$CO_OUT" | sed -n 's/.*--port \([0-9]*\).*/\1/p' | head -1)"
                                [ -n "$host" ] && [ -n "$port" ] || {
                                    printf "    the refusal offered no runnable suggestion\n"; return 1; }
                                run_collector --server "$host" --port "$port" --dry-run \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "and the suggestion it printed is accepted" 0 "$CO_RC" || return 1
                                assert_contains "composing the address it named" "http://[::1]:8080/api/" "$CO_OUT"; }

test_r8_server_addr_is_gone() { # The destination has ONE flag. --server-addr named a second identity
                                # (this name, that address) which the model excludes; address access
                                # to a name-based deployment is a server-side vhost setting.
                                run_collector --server ts.example --port 8080 --server-addr 10.0.0.6 \
                                    --dry-run --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "--server-addr is no longer an option" 2 "$CO_RC" || return 1
                                assert_contains "and says so" "Unknown option" "$CO_OUT"; }

test_r8_no_proxy_flag_is_gone() { # The collector configures no proxy: curl and wget read the
                                # environment themselves, so a flag that only restated that was
                                # 89 lines of no_proxy dialect modelling for one log line. The
                                # capability survives as `http_proxy= https_proxy=` on the command
                                # line, which is documented in --help.
                                run_collector --server ts.example --port 8080 --no-proxy \
                                    --dry-run --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "--no-proxy is no longer an option" 2 "$CO_RC" || return 1
                                assert_contains "and says so" "Unknown option" "$CO_OUT" || return 1
                                run_collector --help
                                assert_contains "and --help names the replacement" "http_proxy=" "$CO_OUT"; }

test_r8_destination_record_flag_is_gone() { # The log already records the destination; a second
                                # artefact for the same fact carried a JSON writer, a percent
                                # encoder, an undelivered side-file and an exit-code rule.
                                run_collector --server ts.example --port 8080 \
                                    --destination-record /tmp/rec.json \
                                    --dry-run --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "--destination-record is no longer an option" 2 "$CO_RC" || return 1
                                assert_contains "and says so" "Unknown option" "$CO_OUT" || return 1
                                # And no message may still advertise it. Asserted on the SOURCE, like
                                # test_a_no_compiled_in_default, because the defect lived in a
                                # log_msg the operator sees only when a destination dies mid-run: it
                                # told them to use a flag that exits 2. $CO_OUT cannot be the probe
                                # here, since the unknown-option error necessarily quotes the flag.
                                local src; src="$(cat "$COLLECTOR")"
                                assert_not_contains "the flag is named nowhere in the collector" \
                                    "--destination-record" "$src" || return 1
                                assert_not_contains "and neither is --no-proxy" "--no-proxy" "$src"; }

test_r8_address_destination_names_the_vhost_cause() { # An address carries no host name, so a server
                                # behind name-based virtual hosting answers it from a different site.
                                # Measured live: 200 by name, 404 by that host's own address. The two
                                # causes the message already offered did not cover it.
                                require_python3 || return 77
                                local p
                                start_listener http404 || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file \
                                    --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_eq "an open port serving something else fails" 1 "$CO_RC" || return 1
                                assert_contains "the address case is named" "carried no host name" "$CO_OUT" || return 1
                                # And NOT offered for a name, or every ordinary failure grows a false hint.
                                run_collector --server ts.example --port 8080 --no-log-file \
                                    --no-progress --dir "$ONEFILE"
                                assert_not_contains "not offered when a name was given" "carried no host name" "$CO_OUT"; }

# --- Axis R9: the fix round's own regressions. Each of these is a path the suite did not cover, ---
# --- named by the adversarial review of the round-7 diff. -----------------------------------------

test_r9_folded_status_cannot_forge_a_submission() { # C1. A peer answering a real 503 plus an obs-fold
                                # continuation spelling 200 was booked as submitted with exit 0 --
                                # evidence the server REFUSED, reported as delivered. curl now takes
                                # its status from %{http_code}, which parses no text at all.
                                require_python3 || return 77
                                local p
                                start_listener statusfold || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_ge "a refused upload is not a success" 1 "$CO_RC" || return 1
                                assert_eq "and nothing is counted as submitted" 0 "$(co_stat submitted)"; }

test_r9_unfolded_status_cannot_forge_a_submission_curl() { # The same refusal with the fake status line
                                # UNFOLDED, at column 0 like an ordinary header. The column-0 rule
                                # cannot reject this one -- %{http_code} is what closes it, which is
                                # why the primary status on the curl path is curl's own answer and
                                # the header parse is only a fallback.
                                require_python3 || return 77
                                local p
                                start_listener statusforge || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_ge "a refused upload is not a success" 1 "$CO_RC" || return 1
                                assert_eq "and nothing is counted as submitted" 0 "$(co_stat submitted)"; }

test_r10_ack_must_be_top_level() { # R10-H1. The acknowledgement gate was an unanchored substring
                                # search over the body, so any 2xx carrying '"id":' at ANY depth, in
                                # ANY content type, booked the file submitted with exit 0. The named
                                # deployment is a reverse proxy that passes /api/status through to
                                # Thunderstorm but routes /api/checkAsync to a different backend,
                                # whose ordinary create-response is {"data":{"id":91}}.
                                require_python3 || return 77
                                local p
                                start_listener acknested || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_ge "a depth-2 id is not an acknowledgement" 1 "$CO_RC" || return 1
                                assert_eq "and nothing is counted submitted" 0 "$(co_stat submitted)" || return 1
                                assert_contains "the peer is named as the problem" \
                                    "did not answer as a Thunderstorm" "$CO_OUT"; }

test_r10_ack_past_the_read_bound_is_retried() { # R10-H2. A VALID acknowledgement beyond the bytes the
                                # collector reads is not evidence about the peer, but it was treated
                                # as an impostor verdict -- and the first such miss latches the
                                # withholding gate, so one pretty-printed answer cost every remaining
                                # file in the run and listed the ACCEPTED file as undelivered.
                                require_python3 || return 77
                                local p log
                                start_listener ackbig || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 2 \
                                    --no-log-file --no-progress --dir "$FIXTURES"
                                stop_listener
                                # It must say it does not KNOW, not that the peer is an impostor.
                                assert_contains "the verdict is 'not known'" \
                                    "whether it carried an acknowledgement is not known" "$CO_OUT" || return 1
                                assert_not_contains "and the peer is NOT called an impostor" \
                                    "did not answer as a Thunderstorm" "$CO_OUT" || return 1
                                # And the gate must not latch: every file is still attempted, so the
                                # request count exceeds the one-file-then-withhold shape.
                                assert_ge "every file was still transmitted" "$FIXTURE_COUNT" \
                                    "$(count_req "$log" 'POST /api/checkAsync*')" || return 1
                                assert_not_contains "nothing is withheld without transmitting" \
                                    "withheld without transmitting" "$CO_OUT"; }

test_r10_status_gate_needs_a_real_key() { # H5 + A3. The identity gate was an unquoted substring test
                                # over the body, with no content-type constraint, so a 200 that merely
                                # MENTIONED a counter name passed it -- measured with
                                # '<html>unknown metric scanned_samples</html>',
                                # '{"no_scanned_samples_here":0}' and
                                # 'ERROR scanned_samples is not a valid field'. It now requires a
                                # TOP-LEVEL key of a JSON object.
                                require_python3 || return 77
                                local p
                                start_listener statushtml || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file \
                                    --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_eq "an HTML page mentioning a counter is not a Thunderstorm" 1 "$CO_RC" || return 1
                                # The run dies at the preflight, so there is no counters line at all
                                # -- asserting submitted=0 would be asserting against an empty string.
                                assert_not_contains "no collection is reported" "Run completed:" "$CO_OUT" || return 1
                                assert_contains "the verdict names the requirement" \
                                    "no top-level counter key" "$CO_OUT"; }

test_r11_peer_body_never_leaks_the_proxy_credential() { # A1. Two sites interpolated the PEER's bytes
                                # into an operator-facing message with no redact_detail: the preflight
                                # identity verdict, and the non-2xx upload message. A gateway or
                                # captive portal that echoes the request URL therefore put the proxy
                                # PASSWORD on the terminal, in the log file and in syslog. The listener
                                # doubles as the proxy, which is how the credential reaches its body.
                                require_python3 || return 77
                                local p log
                                # (a) the preflight identity arm
                                start_listener echocred || return 1; p="$LISTENER_PORT_OUT"
                                run_collector_env http_proxy="http://puser:s3cr3tPW@127.0.0.1:$p/" -- \
                                    --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_not_contains "the preflight verdict must not carry the password" \
                                    "s3cr3tPW" "$CO_OUT" || return 1
                                assert_contains "it quotes the body, redacted" "<redacted>" "$CO_OUT" || return 1
                                # (b) the non-2xx upload arm
                                start_listener echocred5xx || return 1; p="$LISTENER_PORT_OUT"
                                run_collector_env http_proxy="http://puser:s3cr3tPW@127.0.0.1:$p/" -- \
                                    --server 127.0.0.1 --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_not_contains "the upload message must not carry it either" \
                                    "s3cr3tPW" "$CO_OUT" || return 1
                                # ...and the message must still be reached, or this test is vacuous.
                                assert_contains "the upload error is still reported" \
                                    "Server returned HTTP 500" "$CO_OUT"; }

test_r11_redaction_holds_on_the_bash_32_floor() { # A2. redact_detail's second pass used
                                # ${cred/:/\/}; before bash 4.3 the REPLACEMENT of a pattern
                                # substitution is not quote-removed, so it yielded the literal
                                # 'user\/pass', matched nothing, and the password was logged in clear
                                # on the macOS floor -- while redacting correctly on 5.x, which is why
                                # it went unnoticed. Unit-level, because the defect is version-gated.
                                local fn="$WORK/red.fn" out c
                                sed -n '/^redact_detail()/,/^}/p' "$COLLECTOR" > "$fn"
                                for c in 3.2 4.2 5.0 ""; do
                                    out="$(BASH_COMPAT="$c" bash -c '
                                        PROXY_CRED_OUT="puser:s3cr3tPW"; REDACTED_OUT=
                                        . "$1"; redact_detail "wget: using proxy puser/s3cr3tPW@h"
                                        printf "%s" "$REDACTED_OUT"' _ "$fn")"
                                    assert_not_contains "no cleartext at BASH_COMPAT ${c:-native}" \
                                        "s3cr3tPW" "$out" || return 1
                                done
                                # And the colon spelling, which always worked, must keep working.
                                out="$(bash -c 'PROXY_CRED_OUT="puser:s3cr3tPW"; REDACTED_OUT=
                                    . "$1"; redact_detail "to puser:s3cr3tPW@h"; printf "%s" "$REDACTED_OUT"' _ "$fn")"
                                assert_contains "the user:pass spelling still redacts" "<redacted>" "$out"; }

test_r11_retry_after_zero_padded_is_not_inflated() { # A2. The length guard ran BEFORE leading zeros
                                # were stripped, so 'Retry-After: 0000002' -- two seconds, written
                                # padded -- became 999999; the collector then printed a number the
                                # server never sent and waited the 120s cap.
                                local fn="$WORK/ra.fn" hdr="$WORK/ra2.hdr" out
                                sed -n '/^retry_after_seconds()/,/^}/p' "$COLLECTOR" > "$fn"
                                ra() { printf 'HTTP/1.1 503 x\r\nRetry-After: %s\r\n\r\n' "$1" > "$hdr"
                                       bash -c 'RETRY_AFTER_OUT=; . "$1"; retry_after_seconds "$2"; printf "%s" "$RETRY_AFTER_OUT"' _ "$fn" "$hdr"; }
                                assert_eq "a padded 2 is two seconds"      2      "$(ra 0000002)" || return 1
                                assert_eq "all zeros is zero"             0      "$(ra 0000000)" || return 1
                                assert_eq "a plain value is unchanged"    7      "$(ra 7)"       || return 1
                                # the guard it was protecting must still clamp
                                assert_eq "a genuinely huge value clamps" 999999 "$(ra 1234567)"; }

test_r11_mapped_address_refused_in_every_spelling() { # M13. The no-host gate canonicalised only the
                                # DOTTED mapped form, so '::ffff:0:0' and '::ffff:ffff:ffff' were
                                # ACCEPTED while the identical 128 bits written '::ffff:0.0.0.0' and
                                # '255.255.255.255' were refused -- and ::ffff:0:0 reaches the
                                # COLLECTING HOST'S OWN LOOPBACK, the one destination this gate exists
                                # to refuse. Enumerate the property, not the spellings.
                                expect_server_reject "dotted unspecified"   '::ffff:0.0.0.0'         'names no' || return 1
                                expect_server_reject "hex-group unspecified" '::ffff:0:0'            'names no' || return 1
                                expect_server_reject "dotted broadcast"     '::ffff:255.255.255.255' 'names no' || return 1
                                expect_server_reject "hex-group broadcast"  '::ffff:ffff:ffff'       'names no' || return 1
                                # The DEPRECATED IPv4-compatible form is deliberately NOT unmapped:
                                # measured, '[::0.0.0.0]' answers from ::1 while '[::ffff:0.0.0.0]'
                                # answers from this host's loopback, and Python's ipaddress agrees.
                                expect_server_reject "compatible all-zero"  '::0.0.0.0'              'names no' || return 1
                                expect_server_accept "compatible non-zero"  '::1.2.3.4'  '[::1.2.3.4]' || return 1
                                # A well-formed literal an earlier canonicaliser wrongly refused.
                                expect_server_accept "a real host with a dotted tail" \
                                    '0000:0000:0000:0000:0000:0000:255.255.255.255' \
                                    '[0000:0000:0000:0000:0000:0000:255.255.255.255]'; }

test_r10_sync_flag_is_gone()  { # A2. The collector had two endpoints selected by --sync, whose DEFAULT
                                # (main's `local endpoint_name="check"`) was the wrong one -- the only
                                # path anyone used was reached through a double negative. Following
                                # test_r7_test_server_flag_is_gone and test_r8_server_addr_is_gone.
                                run_collector --sync --server 127.0.0.1 --port 8080 --no-log-file \
                                    --no-progress --dry-run --dir "$ONEFILE"
                                assert_eq "--sync is a usage error" 2 "$CO_RC" || return 1
                                assert_contains "named as unknown" "Unknown option: --sync" "$CO_OUT" || return 1
                                # And the endpoint is a constant, not a default that a flag corrects.
                                run_collector --server 127.0.0.1 --port 8080 --source S --no-log-file \
                                    --no-progress --dry-run --dir "$ONEFILE"
                                assert_eq "the endpoint is always checkAsync" \
                                    "http://127.0.0.1:8080/api/checkAsync?source=S" "$(co_endpoint)" || return 1
                                # And --help no longer offers it. `run_collector --help` is the idiom
                                # test_r6_help_says_server_is_repeatable uses.
                                run_collector --help
                                assert_eq "--help succeeds" 0 "$CO_RC" || return 1
                                assert_not_contains "and no longer offers --sync" "--sync" "$CO_OUT"; }

test_r10_ack_check_is_unconditional() { # R10-C1. The 2xx arm dispatched on the ENDPOINT STRING with two
                                # patterns and NO default, so an endpoint matching neither returned 0 --
                                # a 2xx booked as submitted with no identity check at all. Unreachable
                                # while endpoint_name was always check/checkAsync, but the obvious way
                                # to remove --sync (delete the flag and the sync arm, keep main's
                                # `local endpoint_name="check"`) would have ARMED it.
                                #
                                # Unit-level, in the style of test_h_retry_after_is_reported: extract
                                # the classifier and drive it with an endpoint that matches nothing.
                                local fn="$WORK/cls.fn" hdr="$WORK/cls.hdr" resp="$WORK/cls.resp" out
                                # thunderstorm_ack_in delegates to the bounded JSON reader, so the
                                # extraction has to carry it and the two pattern constants with it --
                                # JSON_END_SCALAR/JSON_STRUCTURAL exist because a '}' cannot be
                                # written literally inside a ${x%%[...]} bracket.
                                grep -E "^JSON_(END_SCALAR|STRUCTURAL)=" "$COLLECTOR" > "$fn"
                                for f in http_status_from_headers retry_after_seconds _json_skip_value \
                                         json_top_level_out thunderstorm_ack_in classify_upload_response; do
                                    sed -n "/^${f}()/,/^}/p" "$COLLECTOR"
                                done >> "$fn"
                                printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' > "$hdr"
                                printf '{}' > "$resp"
                                local ep
                                for ep in http://x/api/collection http://x/api/somethingelse http://x/api/checkAsync; do
                                    out="$(bash -c 'HTTP_STATUS_OUT=; RETRY_AFTER_OUT=; RETRY_AFTER_SLEPT=0; TRANSPORT_ERR_OUT=; EFFECTIVE_PROXY_OUT=
                                        log_msg() { :; }; sleep() { :; }
                                        . "$1"; classify_upload_response curl 0 "$4" f "$2" "$3"; printf "%s" "$?"' _ "$fn" "$hdr" "$resp" "$ep")"
                                    assert_eq "a 2xx with no ack is refused for [$ep]" 95 "$out" || return 1
                                done
                                # Control: a real acknowledgement is still accepted.
                                printf '{"id":7}' > "$resp"
                                out="$(bash -c 'HTTP_STATUS_OUT=; RETRY_AFTER_OUT=; RETRY_AFTER_SLEPT=0; TRANSPORT_ERR_OUT=; EFFECTIVE_PROXY_OUT=
                                    log_msg() { :; }; sleep() { :; }
                                    . "$1"; classify_upload_response curl 0 http://x/api/checkAsync f "$2" "$3"; printf "%s" "$?"' _ "$fn" "$hdr" "$resp")"
                                assert_eq "and a real acknowledgement is accepted" 0 "$out"; }

test_r9_unfolded_status_forgery_is_open_on_wget() { # DOCUMENTED RED. wget echoes that unfolded fake
                                # status line INDENTED, like every other header, so the last-match
                                # rule reads 200 and a 503-refused upload is booked as submitted with
                                # exit 0. Pre-existing, and NOT closed by the transport-exact parse:
                                # wget offers no equivalent of curl's %{http_code}, so the answer is
                                # to stop trusting the echoed transcript. Pinned so that whichever
                                # change closes it is noticed.
                                require_python3 || return 77
                                local shim p
                                shim="$(wget_only_path)" || return 77
                                start_listener statusforge || return 1; p="$LISTENER_PORT_OUT"
                                run_collector_env PATH="$shim" -- --server 127.0.0.1 --port "$p" --retries 1 \
                                    --no-log-file --no-progress --dir "$ONEFILE"
                                stop_listener
                                assert_ge "a refused upload is not a success" 1 "$CO_RC" || return 1
                                assert_eq "and nothing is counted as submitted" 0 "$(co_stat submitted)"; }

main() {
    mkdir -p "$WORK/cwd" || { echo "ERROR: cannot create the run directory" >&2; exit 1; }
    make_fixtures || { echo "ERROR: cannot create fixtures" >&2; exit 1; }
    have_python3 && write_listener_src

    printf "${BOLD}Server-flag suite${RESET} — collector: %s\n" "$COLLECTOR"
    printf "  work dir: %s\n" "$WORK"
    if probe_live; then
        # shellcheck disable=SC2034  # read by require_live() in lib/harness.sh
        LIVE_READY=1
        printf "  live tier: ${GREEN}%s:%s${RESET} (api reachable)\n" "$LIVE_HOST" "$LIVE_PORT"
    elif [ -n "$LIVE_HOST" ]; then
        printf "  live tier: ${YELLOW}%s:%s unreachable — skipping${RESET}\n" "$LIVE_HOST" "$LIVE_PORT"
    else
        printf "  live tier: ${DIM}not configured (set THUNDERSTORM_LIVE_HOST) — skipping${RESET}\n"
    fi
    have_python3 || printf "  local tier: ${YELLOW}python3 missing — skipping${RESET}\n"

    section "A — required, and no compiled-in default"
    run_test test_a_missing_server_refused
    run_test test_a_dry_run_is_exempt
    run_test test_a_empty_value_is_distinct
    run_test test_a_no_compiled_in_default
    run_test test_a_env_is_ignored_and_named
    run_test test_a_interrupted_marker_needs_validation

    section "B — accepted grammar"
    run_test test_b_url_shapes_refused
    run_test test_b_bad_names_refused
    run_test test_b_numeric_shapes_refused
    run_test test_b_valid_shapes_accepted
    run_test test_b_second_server_is_a_usage_error
    run_test test_b_bad_ipv6_refused
    run_test test_b_credential_is_redacted
    run_test test_b_equals_and_short_forms

    section "C — the wire"
    run_test test_c_refused_sends_no_packet
    run_test test_c_at_form_does_not_retarget
    run_test test_c_slash_cannot_reach_port_80
    run_test test_c_dry_run_still_validates

    section "D — IPv6 delivery"
    run_test test_d_ipv6_delivers

    section "F — observability"
    run_test test_f_help_documents_server
    run_test test_f_usage_error_writes_none
    run_test test_f_quiet_nolog_still_reports

    section "B4/C4/D/J — round 4: coverage the first three rounds did not reach"
    run_test test_r4_ipv6_group_counting
    run_test test_r4_ipv6_zone_and_bracket_spellings
    run_test test_r4_name_boundaries
    run_test test_r4_punycode_is_accepted
    run_test test_r4_name_frontier_with_numbers
    run_test test_r4_no_value_reaches_a_shell
    run_test test_r4_control_characters
    run_test test_r4_locale_cannot_open_the_gate
    run_test test_r4_exact_request_sequence
    run_test test_r4_debug_adds_no_request
    run_test test_r4_ipv6_delivers_under_wget
    run_test test_r4_hostile_scan_id_cannot_rewrite_the_url
    run_test test_r4_overlong_scan_id_is_dropped
    run_test test_r4_marker_500_aborts_before_any_file

    section "F4/F5/F6/I/H — round 4: TLS, proxy, signals, withholding, cost"
    run_test test_r4_tls_delivers_with_insecure
    run_test test_r4_tls_untrusted_is_refused
    run_test test_r4_ca_cert_implies_ssl
    run_test test_r4_ca_cert_wrong_is_refused
    run_test test_r4_ca_cert_missing_file
    run_test test_r4_ca_cert_and_insecure_agree
    run_test test_r4_ca_cert_under_wget_says_wget_semantics
    run_test test_r4_withholding_is_wire_visible
    run_test test_r4_end_marker_withheld_on_the_wire
    run_test test_r4_signal_marker_goes_only_to_the_validated_host
    run_test test_r4_signal_during_validation_sends_nothing
    run_test test_r4_dry_run_signal_sends_nothing
    run_test test_r4_fork_budget_per_run_and_per_file
    run_test test_r4_fork_budget_inside_the_signal_handler
    run_test test_r4_validator_costs_nothing_on_real_values

    section "R — round 4: the 17 confirmed defects, now fixed"
    run_test test_r4_hex_in_a_later_label_is_refused
    run_test test_r4_hex_label_does_not_deliver
    run_test test_r4_validator_is_not_quadratic
    run_test test_r4_0x_prefix_is_not_a_hex_address
    run_test test_r4_numeric_message_states_a_truth
    run_test test_r4_root_dot_is_legal_at_the_length_bound
    run_test test_r4_url_shape_is_diagnosed_before_userinfo
    run_test test_r4_glob_message_matches_the_code
    run_test test_r4_env_is_named_when_the_run_dies_for_it
    run_test test_r4_redirect_default_is_safe_before_prepare_run
    run_test test_r4_cron_form_records_the_destination
    run_test test_r4_interrupted_marker_is_withheld_too
    run_test test_r4_end_marker_docs_match_the_code
    section "S — round 5: destination functionality"
    run_test test_r5_unspecified_address_refused
    run_test test_r5_unspecified_address_reaches_loopback
    run_test test_r5_preflight_requires_thunderstorm_body
    run_test test_r5_preflight_is_not_cacheable
    run_test test_r5_failure_names_the_path_attempted
    run_test     test_r5_single_server_output_is_unchanged
    run_test test_r5_curl_receives_the_options_it_is_given
    run_test test_r5_dead_destination_stops_the_run
    run_test     test_r5_a_single_hiccup_does_not_stop_the_run
    section "G — round 4: the live server"
    run_test test_r4_live_ack_shape_and_markers
    run_test test_r4_live_ip_literal_is_honest
    run_test test_r4_live_tls_untrusted_refused
    run_test test_r4_live_ca_cert_real_chain
    run_test test_r4_live_name_spellings
    run_test test_r4_live_wget_delivers
    run_test test_r4_live_refused_shapes_send_nothing
    run_test test_r4_live_interrupt_is_prompt

    section "H — round 6: bounds on server input, and address canonicalisation"
    run_test test_r6_huge_status_body_is_bounded
    run_test test_r6_huge_status_body_is_bounded_under_wget
    run_test test_r6_trickled_status_body_is_bounded
    run_test test_r6_pretty_status_document_is_still_recognised
    run_test test_r6_mapped_unspecified_is_refused
    run_test test_r6_mapped_broadcast_is_refused
    run_test test_r6_no_marker_before_the_begin_marker
    run_test test_r6_source_is_encoded_without_od
    run_test test_r6_wget_bound_holds_without_timeout

    section "I — round 7: a dry run is a real run minus the transmission"
    run_test test_r7_dry_run_reports_a_dead_destination
    run_test test_r7_dry_run_proves_the_path
    run_test test_r7_dry_run_names_an_unreachable_destination
    run_test test_r7_interrupted_dry_run_sends_no_marker
    run_test test_r8_marker_refuses_to_transmit_in_a_dry_run
    run_test test_r8_old_curl_falls_back_to_the_header_dump
    run_test test_r9_single_label_refused
    run_test test_r7_dry_run_reports_the_same_collection
    run_test test_r7_dry_run_reconciles
    run_test test_r7_dry_run_without_a_server_still_works
    run_test test_r7_test_server_flag_is_gone

    section "J — round 8: --server names the host, one spelling per host"
    run_test test_r8_the_three_accepted_shapes
    run_test test_r8_brackets_are_refused
    run_test test_r8_bracket_refusal_suggestion_runs
    run_test test_r8_server_addr_is_gone
    run_test test_r8_no_proxy_flag_is_gone
    run_test test_r8_destination_record_flag_is_gone
    run_test test_r8_address_destination_names_the_vhost_cause

    run_test test_r9_folded_status_cannot_forge_a_submission
    run_test test_r9_unfolded_status_cannot_forge_a_submission_curl
    run_test_red test_r9_unfolded_status_forgery_is_open_on_wget "the wget status transcript is forgeable"

    run_test test_r10_sync_flag_is_gone
    run_test test_r11_mapped_address_refused_in_every_spelling
    run_test test_r11_peer_body_never_leaks_the_proxy_credential
    run_test test_r11_redaction_holds_on_the_bash_32_floor
    run_test test_r11_retry_after_zero_padded_is_not_inflated
    run_test test_r10_status_gate_needs_a_real_key
    run_test test_r10_ack_must_be_top_level
    run_test test_r10_ack_past_the_read_bound_is_retried
    run_test test_r10_ack_check_is_unconditional

    section "Live server"
    run_test test_live_delivers
    run_test test_live_transports_agree
    run_test test_live_slash_refused
    run_test test_live_userinfo_refused

    printf "\n"
    if [ "$TESTS_FAILED" -eq 0 ]; then
        printf "${GREEN}Results: %d/%d passed${RESET}" "$TESTS_PASSED" "$TESTS_RUN"
    else
        printf "${RED}Results: %d/%d passed${RESET}" "$TESTS_PASSED" "$TESTS_RUN"
    fi
    [ "$TESTS_SKIPPED" -gt 0 ] && printf ", %d skipped" "$TESTS_SKIPPED"
    [ "$TESTS_RED" -gt 0 ] && printf ", %d documented-red" "$TESTS_RED"
    printf "\n"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf "${RED}%d failed:${RESET}\n" "$TESTS_FAILED"
        printf "%s" "$FAILED_NAMES"
        exit 1
    fi
    if [ "$TESTS_RED" -gt 0 ]; then
        printf "${YELLOW}%d confirmed defects are pinned red-first (round 4, assessment only):${RESET}\n" "$TESTS_RED"
        printf "%s" "$RED_NAMES"
    fi
    # A destination suite that did not run is not a destination suite that passed: without this,
    # a runner missing python3 skipped 15 of 35 tests and still exited 0.
    # Calibrated to the suite's ACTUAL size, not to the 35-test suite this floor was written for.
    # A full local run executes 108 of 121 (the 13 live tests skip without THUNDERSTORM_LIVE_HOST).
    # 95 leaves room for the live tier plus the environment skips (IPv6 loopback, a privileged port,
    # openssl) while still catching the case this exists for: a runner that lost python3 skips ~66
    # and would sail past a floor of 20 having tested neither the preflight gate, the breaker, the
    # withholding latch, nor any signal.
    assert_tests_floor 95 || exit 1
    printf "${GREEN}All server tests passed.${RESET}\n"
    exit 0
}

main "$@"
