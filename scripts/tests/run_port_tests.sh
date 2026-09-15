#!/usr/bin/env bash
#
# Port-flag test suite for the bash collector.
#
# Covers --port end to end: parse time, numeric validation, URL composition, the
# scheme/port pairing, every network shape a port can point at, and what the
# operator can actually see when the port is wrong.
#
# Three tiers, so a machine without network access still gets real coverage:
#
#   offline  parsing, validation, exit codes, URL composition, log side effects.
#            No network at all. Always runs.
#   local    python3 listeners on loopback: refused / wrong-app / non-HTTP /
#            redirect / accept-then-silence. Skipped without python3.
#   live     a real Thunderstorm server. Skipped unless THUNDERSTORM_PORT_LIVE_HOST
#            is set AND the host answers, so this suite never fails for lack of
#            access to someone else's server.
#
# Usage:
#   scripts/tests/run_port_tests.sh                    # offline + local
#   THUNDERSTORM_PORT_LIVE_HOST=host.example \
#   THUNDERSTORM_PORT_LIVE_TLS=1 \
#   THUNDERSTORM_PORT_LIVE_INSECURE=1 \
#     scripts/tests/run_port_tests.sh                  # + the live tier
#
# Environment:
#   THUNDERSTORM_PORT_LIVE_HOST      host for the live tier (unset = skip the tier)
#   THUNDERSTORM_PORT_LIVE_PORT      port that serves the API      (default 443)
#   THUNDERSTORM_PORT_LIVE_TLS       1 = pass --ssl                (default 1)
#   THUNDERSTORM_PORT_LIVE_INSECURE  1 = pass --insecure           (default 1)
#   THUNDERSTORM_PORT_LIVE_OPEN_WRONG  a port that is OPEN but serves a different
#                                    app (404s every path)        (default 80)
#   THUNDERSTORM_PORT_LIVE_REFUSED   a port that answers RST       (default 8080)
#   THUNDERSTORM_PORT_LIVE_FILTERED  a port whose packets are dropped (default 8443)
#   TEST_FILTER                      run only tests matching this grep pattern
#
# Exit: 0 all passed, 1 any failed. A test body returning 77 is SKIP (automake
# convention, as in run_tests.sh) and is never counted as a pass.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
COLLECTOR="$REPO_ROOT/scripts/bash/thunderstorm-collector.sh"

[ -r "$COLLECTOR" ] || { echo "ERROR: collector not readable at $COLLECTOR" >&2; exit 1; }


# ── Shared harness ────────────────────────────────────────────────────────────
# Listeners, assertions, dispatch and fixtures live in one place so that this suite and
# run_server_tests.sh cannot drift apart. See scripts/tests/lib/harness.sh.
# shellcheck disable=SC2034  # read by lib/harness.sh when it is sourced below
HARNESS_NAME="ts-port-tests"
# shellcheck source=lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"

# ── Shared expectations ───────────────────────────────────────────────────────

# offline_port -- a dry run against the one-file tree, for parsing, validation
# and URL composition. A REFUSED value never reaches the network. An ACCEPTED
# one does: a dry run still checks the destination, so 127.0.0.1 is probed and
# the refusal is reported without being fatal.
offline_port() {
    run_collector --server 127.0.0.1 --no-log-file --dry-run --no-progress --dir "$ONEFILE" "$@"
}

# expect_reject -- the value must be refused as a usage error (exit 2) with the
# named message. The message is asserted, not just the status: "rejected" is not
# the same fact as "rejected for the right reason".
expect_reject() {
    local label="$1" value="$2" msg="$3"
    offline_port --port "$value"
    assert_eq "$label: exit code" 2 "$CO_RC" || return 1
    assert_contains "$label: message" "$msg" "$CO_OUT" || return 1
    # A raw shell diagnostic must never reach the operator (CLAUDE.md §1).
    assert_not_contains "$label: no raw shell error" "integer expression expected" "$CO_OUT" || return 1
    assert_not_contains "$label: no raw shell error" "value too great" "$CO_OUT" || return 1
}

# expect_accept -- the value must be accepted and canonicalised to $3.
expect_accept() {
    local label="$1" value="$2" canonical="$3"
    offline_port --port "$value"
    assert_eq "$label: exit code" 0 "$CO_RC" || return 1
    assert_contains "$label: logged port" "Port: $canonical" "$CO_OUT" || return 1
}

# ── Axis A — parse time ───────────────────────────────────────────────────────

test_a_long_form()            { expect_accept "--port 8080" 8080 8080; }
test_a_short_form()           { offline_port -p 8080; assert_eq "rc" 0 "$CO_RC" || return 1
                                assert_contains "port" "Port: 8080" "$CO_OUT"; }
test_a_equals_form()          { run_collector --server 127.0.0.1 --no-log-file --dry-run --no-progress --dir "$ONEFILE" --port=8443
                                assert_eq "rc" 0 "$CO_RC" || return 1
                                assert_contains "port" "Port: 8443" "$CO_OUT"; }
test_a_short_equals_refused() { # Only long options are split on '='; '-p=8080' is not a value form.
                                run_collector --server 127.0.0.1 --no-log-file -p=8080 --dry-run --dir "$ONEFILE"
                                assert_eq "rc" 2 "$CO_RC" || return 1
                                assert_contains "msg" "Unknown option: -p=8080" "$CO_OUT"; }
test_a_missing_value()        { run_collector --server 127.0.0.1 --no-log-file --port
                                assert_eq "rc" 2 "$CO_RC" || return 1
                                assert_contains "msg" "Missing value for --port" "$CO_OUT"; }
test_a_does_not_eat_flag()    { run_collector --server 127.0.0.1 --no-log-file --port --ssl --dir "$ONEFILE"
                                assert_eq "rc" 2 "$CO_RC" || return 1
                                assert_contains "msg" "Missing value for --port (got option-like token '--ssl')" "$CO_OUT"; }
test_a_empty_value()          { expect_reject "--port ''" "" "Empty value for --port"; }
test_a_whitespace_value()     { expect_reject "--port '   '" "   " "Whitespace-only value for --port"; }
test_a_equals_empty()         { run_collector --server 127.0.0.1 --no-log-file --port= --dry-run
                                assert_eq "rc" 2 "$CO_RC" || return 1
                                assert_contains "msg" "Empty value for --port" "$CO_OUT"; }
test_a_negative_plain()       { expect_reject "--port -1" "-1" "--port does not take a negative value: '-1'"; }
test_a_negative_equals_form() { # The '=' form suppresses the leading-dash guard on purpose, so this
                                # value reaches the numeric gate instead and gets a different message.
                                run_collector --server 127.0.0.1 --no-log-file --port=-1 --dry-run --dir "$ONEFILE"
                                assert_eq "rc" 2 "$CO_RC" || return 1
                                assert_contains "msg" "Port must be numeric: '-1'" "$CO_OUT"; }
test_a_last_occurrence_wins() { offline_port --port 1 --port 4443
                                assert_eq "rc" 0 "$CO_RC" || return 1
                                assert_contains "port" "Port: 4443" "$CO_OUT" || return 1
                                assert_not_contains "not the first" "Port: 1" "$CO_OUT"; }
test_a_after_double_dash()    { # After '--' every operand is a scan directory, '--port' included.
                                run_collector --server 127.0.0.1 --no-log-file --dry-run --no-progress -- "$ONEFILE" --port 9999
                                assert_contains "port unchanged" "Port: 8080" "$CO_OUT" || return 1
                                assert_contains "consumed as a folder" "'--port'" "$CO_OUT"; }
test_a_bare_operand_is_dir()  { offline_port 9999
                                assert_contains "port unchanged" "Port: 8080" "$CO_OUT" || return 1
                                assert_contains "operand is a folder" "'9999'" "$CO_OUT"; }
test_a_env_var_ignored()      { CO_OUT="$( cd "$WORK/cwd" && THUNDERSTORM_PORT=1234 bash "$COLLECTOR" \
                                    --server 127.0.0.1 --no-log-file --dry-run --no-progress --dir "$ONEFILE" 2>&1 )"
                                assert_contains "env is not honoured" "Port: 8080" "$CO_OUT"; }
test_a_near_miss_spellings()  { local s
                                for s in --ports --por --PORT; do
                                    run_collector --server 127.0.0.1 --no-log-file "$s" 8080 --dry-run
                                    assert_eq "$s exit code" 2 "$CO_RC" || return 1
                                    assert_contains "$s message" "Unknown option: $s" "$CO_OUT" || return 1
                                done; }

# ── Axis B — numeric gate ─────────────────────────────────────────────────────

test_b_accepts_boundaries()   { expect_accept "min" 1 1 || return 1
                                expect_accept "http" 80 80 || return 1
                                expect_accept "https" 443 443 || return 1
                                expect_accept "default" 8080 8080 || return 1
                                expect_accept "max" 65535 65535; }
test_b_rejects_zero()         { expect_reject "zero" 0 "Port must be greater than 0: '0'"; }
test_b_rejects_all_zeros()    { expect_reject "00000" 00000 "Port must be greater than 0: '00000'"; }
test_b_rejects_above_max()    { expect_reject "65536" 65536 "Port must be <= 65535: '65536'" || return 1
                                expect_reject "99999" 99999 "Port must be <= 65535: '99999'"; }
test_b_rejects_oversize()     { # in_range compares digit COUNT first, so a value that cannot fit in
                                # 64 bits never reaches Bash arithmetic and never leaks a shell error.
                                expect_reject "20 digits" 99999999999999999999 "Port must be <= 65535" || return 1
                                expect_reject "30 digits" 999999999999999999999999999999 "Port must be <= 65535"; }
test_b_canonicalises_zeros()  { # Bash reads a leading zero as octal; 10# is what stops '08' being an error.
                                expect_accept "08080" 08080 8080 || return 1
                                expect_accept "0443" 0443 443 || return 1
                                expect_accept "000001" 000001 1; }
test_b_rejects_non_decimal()  { expect_reject "plus sign" "+80" "Port must be numeric: '+80'" || return 1
                                expect_reject "decimal" "80.0" "Port must be numeric: '80.0'" || return 1
                                expect_reject "hex" "0x50" "Port must be numeric: '0x50'" || return 1
                                expect_reject "underscore" "8_080" "Port must be numeric: '8_080'" || return 1
                                expect_reject "trailing text" "8080abc" "Port must be numeric: '8080abc'"; }
test_b_rejects_padded()       { expect_reject "leading space" " 8080" "Port must be numeric" || return 1
                                expect_reject "trailing space" "8080 " "Port must be numeric" || return 1
                                expect_reject "embedded tab" "80	80" "Port must be numeric"; }
test_b_rejects_wide_digits()  { # Only ASCII 0-9 are digits here: the case glob is [!0-9], which must
                                # not accept a full-width or Arabic-Indic digit in any locale.
                                expect_reject "full-width" "８０８０" "Port must be numeric" || return 1
                                expect_reject "arabic-indic" "٨٠٨٠" "Port must be numeric"; }

test_b_reported_overflow_set() { # REGRESSION for three defects reported against 9fa849e, the first
                                # commit of the bash rewrite, where validate_config had no upper
                                # bound: --port 1999999999999 and --port 055 were both accepted and
                                # spliced into the URL verbatim, and a value past INT64_MAX made
                                # `[ "$v" -gt 0 ]` emit a raw shell diagnostic ("integer expression
                                # expected") that bypassed die() entirely, followed by the factually
                                # wrong "Port must be greater than 0" for a positive value.
                                # Closed by bc4d5b2 (in_range's digit-count guard). Pinned with the
                                # exact reported values plus the 64-bit boundaries around them.
                                expect_reject "13 digits (reported)" 1999999999999 "Port must be <= 65535" || return 1
                                expect_reject "19 digits, overflows int64 (reported)" 9999999999999999999 "Port must be <= 65535" || return 1
                                expect_reject "INT64_MAX" 9223372036854775807 "Port must be <= 65535" || return 1
                                expect_reject "INT64_MAX + 1" 9223372036854775808 "Port must be <= 65535" || return 1
                                expect_reject "2^64" 18446744073709551616 "Port must be <= 65535" || return 1
                                # expect_reject already asserts no raw shell diagnostic escaped, which
                                # is the half of this defect that bypassed the error taxonomy.
                                expect_accept "055 (reported) is read as decimal 55" 055 55; }

test_c_no_leading_zero_in_url() { # The other half of the 055 report: the port must reach the URL in
                                # canonical form, never as the typed spelling. ':055' in an authority
                                # is not a port a transport is obliged to parse the way the operator
                                # meant it.
                                run_collector --server ts.example --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE" --port 055
                                assert_eq "canonical port in the URL" "http://ts.example:55/api/checkAsync?source=SRC" "$(co_endpoint)" || return 1
                                assert_not_contains "no leading-zero authority" ":055" "$CO_OUT"; }

# ── Axis C — URL composition ──────────────────────────────────────────────────

test_c_endpoint_plain()       { run_collector --server ts.example --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE" --port 8080
                                assert_eq "endpoint" "http://ts.example:8080/api/checkAsync?source=SRC" "$(co_endpoint)"; }
test_c_endpoint_ssl()         { run_collector --server ts.example --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE" --port 443 --ssl
                                assert_eq "endpoint" "https://ts.example:443/api/checkAsync?source=SRC" "$(co_endpoint)"; }
test_c_endpoint_always_async(){ # There is ONE endpoint. --sync used to select /api/check; the flag is
                                # gone and the path is a constant, so no combination of flags can move it.
                                run_collector --server ts.example --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE" --port 443 --ssl
                                assert_eq "endpoint" "https://ts.example:443/api/checkAsync?source=SRC" "$(co_endpoint)" || return 1
                                run_collector --sync --server ts.example --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE"
                                assert_eq "and --sync is refused outright" 2 "$CO_RC" || return 1
                                assert_contains "as an unknown option" "Unknown option: --sync" "$CO_OUT"; }
test_c_endpoint_canonical()   { # The URL carries the canonical port, not the typed spelling.
                                run_collector --server ts.example --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE" --port 08080
                                assert_eq "endpoint" "http://ts.example:8080/api/checkAsync?source=SRC" "$(co_endpoint)"; }
test_c_port_always_appended() { # --ssl does NOT imply 443: the port is appended unconditionally, as in
                                # go/main.go:135-150 and all four sibling collectors. Pinned so a
                                # refactor cannot quietly introduce a scheme-based default.
                                run_collector --server ts.example --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE" --ssl
                                assert_eq "endpoint" "https://ts.example:8080/api/checkAsync?source=SRC" "$(co_endpoint)"; }

# ── Axis E — network shape (local listeners) ──────────────────────────────────


test_e_refused_is_fast()      { local p
                                p="$(refused_port)"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "exit code" 1 "$CO_RC" || return 1
                                assert_contains "message" "Cannot reach a Thunderstorm server at http://127.0.0.1:$p" "$CO_OUT" || return 1
                                # A refused connection returns immediately from the /api/status
                                # preflight (no retry, no sleep). If this starts taking ~10 s, the
                                # connect timeout is being paid on an RST and that is a regression.
                                assert_le "gives up quickly" 12 "$CO_SECS" || return 1
                                # Aborting at the preflight means no scan and no summary line at all.
                                assert_not_contains "never reached the scan" "Run completed" "$CO_OUT"; }

test_e_dry_run_checks_the_destination() { # INVERTED, deliberately. This test used to assert that a
                                # dry run makes "no connection attempt" -- which meant
                                # `--dry-run --server <unreachable>` exited 0 having said nothing
                                # about the destination the operator had just named. A dry run is now
                                # a real run minus the TRANSMISSION: the check is a GET that carries
                                # no evidence, so it runs, and its verdict is reported.
                                local p
                                p="$(refused_port)"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --dry-run --no-progress --dir "$ONEFILE"
                                assert_contains "the unreachable port is reported" "Cannot reach" "$CO_OUT" || return 1
                                assert_contains "with what a real run would have done" "a real run would stop here" "$CO_OUT" || return 1
                                # Reported, not fatal: a dry run that aborts cannot show what would
                                # have been sent, which is the question it is asked.
                                assert_eq "and the preview still completes" 0 "$CO_RC" || return 1
                                assert_contains "with the preview" "would submit" "$CO_OUT"; }

test_e_wrong_app_fails_fast()   { # REGRESSION for H1 (was a characterisation test).
                                # A port that is open but serves a different application used to
                                # be discovered only by trying to upload to it: the begin marker
                                # forgives a 404, so the collector walked the ENTIRE tree and then
                                # failed every upload. The preflight settles it before a single
                                # file is read.
                                require_python3 || return 77
                                local p
                                start_listener http404 || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "refused before scanning" 1 "$CO_RC" || return 1
                                # An OPEN port with the wrong application is an ANSWERED peer, so the fatal says so
                                # instead of claiming the collector could not reach it.
                                assert_contains "and says why" "No usable Thunderstorm server" "$CO_OUT" || return 1
                                assert_contains "naming the status" "answered HTTP 404 on /api/status" "$CO_OUT" || return 1
                                # The proof it never scanned: no summary line is ever produced.
                                assert_not_contains "never walked the tree" "Run completed" "$CO_OUT" || return 1
                                assert_le "and gave up promptly" 15 "$CO_SECS"; }

test_e_nonhttp_listener()     { require_python3 || return 77
                                local p
                                start_listener nonhttp || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "refused as unreachable" 1 "$CO_RC" || return 1
                                assert_contains "message" "Cannot reach a Thunderstorm server" "$CO_OUT" || return 1
                                assert_not_contains "never reached the scan" "Run completed" "$CO_OUT"; }

test_e_redirect_not_followed() { # curl is invoked without -L, so a redirect to another
                                # port must not be chased -- silently uploading evidence to a host
                                # the operator never named would be a far worse outcome than failing.
                                require_python3 || return 77
                                local target p
                                target="$(refused_port)"
                                start_listener redirect "$target" || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "does not follow" 1 "$CO_RC" || return 1
                                assert_contains "reports the status" "received HTTP 302" "$CO_OUT" || return 1
                                assert_not_contains "never reached the scan" "Run completed" "$CO_OUT"; }

test_e_silent_listener()      { # A peer that accepts and never answers is bounded by the preflight's
                                # --max-time 15, once. Unbounded here would mean a wrong port hangs a
                                # collection forever.
                                require_python3 || return 77
                                local p
                                start_listener silent || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "gives up" 1 "$CO_RC" || return 1
                                assert_le "bounded by the marker timeouts" 40 "$CO_SECS" || return 1
                                assert_contains "message" "Cannot reach a Thunderstorm server" "$CO_OUT"; }

test_e_permissive_service_passes() { # (was a CHARACTERISATION test for P0; now pins the fix.)
                                # A wrong port that lands on a service answering 2xx to everything
                                # used to be reported as a complete collection. Thunderstorm answers
                                # every upload with {"id":N}; a peer that does not is not a
                                # Thunderstorm, and after its first unacknowledged 2xx nothing more
                                # is sent to it.
                                #
                                # ROUND 5 CHANGED THE PEER, not the claim. The crude impostor --
                                # 2xx to literally everything, i.e. yes200 -- is now stopped one
                                # layer earlier, by the preflight requiring /api/status to be a
                                # Thunderstorm status document, so it never reaches an upload.
                                # ackempty is the impostor that still gets past that gate: a
                                # correct status page, then {"id":""} to uploads. This test is the
                                # SECOND layer, and it is still needed -- the two together are the
                                # point.
                                require_python3 || return 77
                                local p log
                                start_listener ackempty || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "a run against an impostor is a partial failure" 4 "$CO_RC" || return 1
                                assert_eq "nothing is counted submitted" 0 "$(co_stat submitted)" || return 1
                                assert_eq "every file is counted failed" "$FIXTURE_COUNT" "$(co_stat failed)" || return 1
                                assert_contains "the answer is named for what it is" "did not answer as a Thunderstorm would" "$CO_OUT" || return 1
                                # The run-level line must not call the transmitted file "withheld": its bytes DID reach
                                # the peer. It names that file, and counts the rest as withheld without transmitting.
                                assert_contains "the transmitted file is named as transmitted" "was transmitted to it and not acknowledged" "$CO_OUT" || return 1
                                assert_contains "and the rest as withheld" "$((FIXTURE_COUNT - 1)) further file(s) were withheld without transmitting" "$CO_OUT" || return 1
                                assert_eq "exactly ONE upload reached the impostor" 1 "$(grep -c 'REQ POST /api/checkAsync' "$log")" || return 1
                                # Withholding used to be half-applied: the file BODIES were withheld
                                # and then the END MARKER handed the same peer the host's source
                                # name (the hostname, by default) and the run's full statistics.
                                # Either the peer is a Thunderstorm or it is not.
                                assert_contains "the withheld end marker is reported" "The end marker was NOT sent" "$CO_OUT" || return 1
                                assert_eq "and exactly one marker reached it -- the begin marker, sent before it was judged" \
                                    1 "$(grep -c 'REQ POST /api/collection' "$log")"; }

test_e_dry_run_never_claims_a_submission() { # WAS a characterisation test for OPEN finding P4,
                                # now pins its fix. CLAUDE.md 3 requires a dry-run summary to be
                                # unmistakably distinct from a real one and forbids claiming a
                                # success when nothing was sent; the line reported submitted=N
                                # regardless, so a dry run's log was byte-identical to a real
                                # collection's. The COUNT is unchanged -- a dry run must show what a
                                # real run would send -- and the KEY and the headline now say what
                                # actually happened.
                                run_collector --server 127.0.0.1 --port 8080 --no-log-file --no-progress --dry-run --dir "$FIXTURES"
                                assert_eq "dry run is clean" 0 "$CO_RC" || return 1
                                assert_eq "the same count the operator came for" "$FIXTURE_COUNT" "$(co_stat would_submit)" || return 1
                                assert_eq "and nothing is called submitted" "" "$(co_stat submitted)" || return 1
                                assert_contains "the summary cannot be mistaken for a real run" "Dry-run completed" "$CO_OUT"; }

test_c_trailing_slash_refused() { # WAS a characterisation test for an open finding (report: P2),
                                # now pins its fix. A trailing slash on --server used to put the port
                                # in the URL PATH, so the transport fell back to the scheme's default
                                # port while the log printed "Port: 8080" as fact. Measured before the
                                # fix: with --port 41791 a listener on port 80 received the evidence
                                # and the run exited 0 submitted=1. --server now takes a host only.
                                run_collector --server ts.example/ --source SRC --no-log-file --dry-run --no-progress --dir "$ONEFILE" --port 8080
                                assert_eq "a trailing slash is a usage error" 2 "$CO_RC" || return 1
                                assert_contains "and the cause names the character" "contains '/'" "$CO_OUT" || return 1
                                assert_contains "and says what happens" "the path would silently replace --port" "$CO_OUT" || return 1
                                # The old bug's signature must be gone: no endpoint is ever built.
                                assert_not_contains "no endpoint is announced" "ts.example/:8080" "$CO_OUT" || return 1
                                assert_not_contains "and the port is not claimed" "Port: 8080" "$CO_OUT"; }

test_e_wget_follows_redirect()  { # (was a CHARACTERISATION test for P0; now pins the fix.)
                                # A followed redirect turns wget's POST into a GET with no body, and
                                # the 200 from the redirect target was read as a submitted file --
                                # exit 0, submitted=1, zero bytes delivered, while the same command
                                # line under curl exited 1. wget now runs with --max-redirect=0, so
                                # both transports refuse, and the redirect TARGET sees no request.
                                require_python3 || return 77
                                local shim ok redir oklog
                                shim="$(wget_only_path)" || return 77
                                start_listener yes200 || return 1; ok="$LISTENER_PORT_OUT"; oklog="$LISTENER_LOG_OUT"
                                start_listener redirect "$ok" || return 1; redir="$LISTENER_PORT_OUT"

                                run_collector --server 127.0.0.1 --port "$redir" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "curl refuses" 1 "$CO_RC" || return 1
                                assert_contains "curl names the status" "received HTTP 302" "$CO_OUT" || return 1

                                local wout wrc
                                wout="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$redir" --no-log-file --no-progress \
                                    --dir "$ONEFILE" 2>&1 )" && wrc=0 || wrc=$?
                                assert_eq "wget refuses too" 1 "$wrc" || return 1
                                assert_contains "and names the status" "302" "$wout" || return 1
                                assert_not_contains "no summary claims a collection happened" "Run completed" "$wout" || return 1
                                assert_eq "the redirect target never saw a request" 0 "$(grep -c '^REQ ' "$oklog")"; }

test_g_sentinels_do_not_leak()  { # REGRESSION for the closed return-code set. The uploaders used
                                # to `return $code` -- the transport's OWN exit status -- into a
                                # space where 93/94/97 already meant 503 / vanished / terminal verdict.
                                # A curl that died with 94 (CURLE_AUTH_ERROR) was booked as a vanished
                                # file and steered the run to exit 5; 97 (CURLE_PROXY) was read as a
                                # verdict and the file dropped after one attempt. Every transport exit
                                # is now classified as 90, logged with its reason, and retried.
                                local bin="$WORK/sentinel-bin" code out rc
                                mkdir -p "$bin"
                                rm -f "$bin/curl"
                                cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
# preflight and marker succeed; a sample POST dies with the exit code under test, no status written
hdr=""; out=""; ep=""
while [ $# -gt 0 ]; do case "$1" in -D) hdr="$2"; shift 2;; -o) out="$2"; shift 2;; -F|-H|-d|--max-time|--connect-timeout) shift 2;; http*) ep="$1"; shift;; *) shift;; esac; done
case "$ep" in
  */api/status)     [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"; [ -n "$out" ] && printf '{"scanned_samples":0}' > "$out"; exit 0 ;;
  */api/collection) [ -n "$hdr" ] && printf 'HTTP/1.1 404 Not Found\r\n\r\n' > "$hdr"; exit 0 ;;
  *) exit "${SENTINEL_EXIT:-7}" ;;
esac
EOF
                                chmod +x "$bin/curl"
                                for code in 94 97 93; do
                                    out="$( cd "$WORK/cwd" && env PATH="$bin:$PATH" SENTINEL_EXIT="$code" bash "$COLLECTOR" \
                                        --server 127.0.0.1 --port 8080 --retries 2 --no-log-file --no-progress \
                                        --dir "$ONEFILE" 2>&1 )" && rc=0 || rc=$?
                                    assert_eq "curl exit $code: an upload failure, exit 4" 4 "$rc" || return 1
                                    assert_contains "curl exit $code: the transport code is logged, not returned" "(curl exit $code)" "$out" || return 1
                                    assert_contains "curl exit $code: retried, not treated as a verdict" "attempt 2/2" "$out" || return 1
                                    assert_contains "curl exit $code: booked as an upload failure" "upload=1" "$out" || return 1
                                    assert_contains "curl exit $code: not as churn" "vanished=0" "$out" || return 1
                                    assert_not_contains "curl exit $code: not as back-pressure" "back-pressure" "$out" || return 1
                                done; }

test_g_status_anchored_to_line_start() { # REGRESSION for N1's anchoring half. The old status
                                # grep was unanchored, so a header VALUE containing "HTTP/1.1 500"
                                # forged the status of a healthy 200. The parser now requires the
                                # status line to start the line.
                                require_python3 || return 77
                                local p
                                start_listener hdrforge || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the forged header value is inert" 0 "$CO_RC" || return 1
                                assert_eq "and the file counts as submitted" 1 "$(co_stat submitted)"; }

test_g_no_status_fails_closed() { # REGRESSION for N1's fail-closed half. An answer with no status
                                # line used to be read as success; a wrong port reported a complete
                                # collection that way. The invariant pinned here is the outcome, not
                                # the branch: modern curl refuses HTTP/0.9 itself (transport failure,
                                # 90), an older one exits 0 and hits the collector's own guard (98).
                                # Either way the file is never counted sent.
                                require_python3 || return 77
                                local p
                                start_listener nostatus || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "fails closed" 4 "$CO_RC" || return 1
                                assert_eq "nothing counted submitted" 0 "$(co_stat submitted)" || return 1
                                assert_eq "the file is counted failed" 1 "$(co_stat failed)"; }

test_g_ack_accepts_both_id_spellings() { # The acknowledgement's TYPE must not be constrained:
                                # production answers {"id":27844} (a number), the reference Go
                                # stub {"id":"<uuid>"} (a string). A digits-only check passed
                                # against production and refused every upload against CI. An id
                                # that is present but EMPTY is still not an acknowledgement.
                                require_python3 || return 77
                                local p
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a string id is an acknowledgement" 0 "$CO_RC" || return 1
                                assert_eq "and the file counts as submitted" 1 "$(co_stat submitted)" || return 1
                                start_listener ackempty || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "an empty id is refused" 4 "$CO_RC" || return 1
                                assert_eq "and nothing is submitted" 0 "$(co_stat submitted)" || return 1
                                assert_contains "the answer is named" "did not answer as a Thunderstorm would" "$CO_OUT"; }

# ---------------------------------------------------------------------------------------------
# h. Pre-push review round: upload identity, rc files, proxy truth, false statements.
# ---------------------------------------------------------------------------------------------

test_h_impostor_refused()     { # C1, re-pointed when --sync was removed. A peer that answers the
                                # status page but not the upload fails closed on BOTH transports, and
                                # exactly one upload reaches it. (Round 5: the cruder
                                # 2xx-to-everything peer is refused at the preflight now, so
                                # ackempty is what exercises this layer -- see
                                # test_e_permissive_service_passes.) The acknowledgement rule is now
                                # UNCONDITIONAL, so this is the only shape it has to police.
                                require_python3 || return 77
                                local p log shim wout wrc
                                start_listener ackempty || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 1 --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "fails closed" 4 "$CO_RC" || return 1
                                assert_eq "nothing counted submitted" 0 "$(co_stat submitted)" || return 1
                                assert_contains "the answer is named" "carried no Thunderstorm acknowledgement" "$CO_OUT" || return 1
                                assert_eq "exactly ONE upload reached the impostor" 1 "$(grep -c 'REQ POST /api/checkAsync?' "$log")" || return 1
                                shim="$(wget_only_path)" || return 77
                                wout="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && wrc=0 || wrc=$?
                                assert_eq "and under wget" 4 "$wrc"; }

test_h_rc_files_are_not_read() { # C2. ~/.curlrc could set proxy= (evidence elsewhere, log says
                                # 'Proxy: none') or location (POST->GET, a body-less upload),
                                # ~/.wgetrc the same. curl runs with -q, wget with WGETRC=<empty file>.
                                require_python3 || return 77
                                local target impostor redir tlog ilog shim out rc
                                start_listener ackstr || return 1; target="$LISTENER_PORT_OUT"
                                start_listener yes200 || return 1; impostor="$LISTENER_PORT_OUT"; ilog="$LISTENER_LOG_OUT"
                                mkdir -p "$WORK/home_proxy" "$WORK/home_loc" "$WORK/home_wget"
                                printf 'proxy = "http://127.0.0.1:%s"\n' "$impostor" > "$WORK/home_proxy/.curlrc"
                                printf 'location\n' > "$WORK/home_loc/.curlrc"
                                printf 'http_proxy = http://127.0.0.1:%s\n' "$impostor" > "$WORK/home_wget/.wgetrc"
                                out="$( cd "$WORK/cwd" && env HOME="$WORK/home_proxy" bash "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$target" --no-log-file --no-progress --dir "$FIXTURES" 2>&1 )" && rc=0 || rc=$?
                                assert_eq ".curlrc proxy= is ignored: the run succeeds directly" 0 "$rc" || return 1
                                assert_eq "and the rc-file proxy saw nothing" 0 "$(grep -c '^REQ ' "$ilog")" || return 1
                                start_listener ackempty || return 1; tlog="$LISTENER_LOG_OUT"
                                start_listener redirect "$LISTENER_PORT_OUT" || return 1; redir="$LISTENER_PORT_OUT"
                                out="$( cd "$WORK/cwd" && env HOME="$WORK/home_loc" bash "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$redir" --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && rc=0 || rc=$?
                                assert_eq ".curlrc location is ignored: the redirect is refused" 1 "$rc" || return 1
                                assert_eq "and the redirect target never saw a request" 0 "$(grep -c '^REQ ' "$tlog")" || return 1
                                shim="$(wget_only_path)" || return 77
                                out="$( cd "$WORK/cwd" && env HOME="$WORK/home_wget" PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$target" --no-log-file --no-progress --dir "$FIXTURES" 2>&1 )" && rc=0 || rc=$?
                                assert_eq ".wgetrc http_proxy is ignored under wget" 0 "$rc" || return 1
                                assert_contains "which really was wget" "Transport: wget" "$out" || return 1
                                assert_eq "and the rc-file proxy still saw nothing" 0 "$(grep -c '^REQ ' "$ilog")"; }

test_h_schemeless_proxy_credential_redacted() { # H2. curl accepts user:pass@host:port with no
                                # scheme; the redaction keyed on '://' and printed the password.
                                local out
                                out="$( cd "$WORK/cwd" && env http_proxy='alice:s3cret@127.0.0.1:1' bash "$COLLECTOR" \
                                    --dry-run --server ts.example --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" || true
                                assert_contains "redacted" "Proxy: <redacted>@127.0.0.1:1" "$out" || return 1
                                assert_not_contains "and the secret is nowhere" "s3cret" "$out"; }

test_h_connect_tunnel_failure_is_not_an_answer() { # H3. A proxy's "200 Connection established"
                                # sits in curl's header file; when the tunnel dies the preflight used to
                                # read it as the server answering, walk the whole tree, and blame the
                                # server for an HTTP 200 it never sent.
                                require_python3 || return 77
                                local p log out rc
                                start_listener connect200 || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                out="$( cd "$WORK/cwd" && env https_proxy="http://127.0.0.1:$p" bash "$COLLECTOR" \
                                    --server 10.255.255.1 --port 443 --ssl -k --debug --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && rc=0 || rc=$?
                                assert_eq "fails before scanning" 1 "$rc" || return 1
                                assert_contains "as unreachable" "Cannot reach a Thunderstorm server" "$out" || return 1
                                assert_not_contains "not as answered" "Server answered" "$out" || return 1
                                assert_not_contains "and nothing was scanned" "Run completed" "$out" || return 1
                                [ "$(grep -c '^REQ CONNECT' "$log")" -ge 1 ] || { printf '    FAIL: the proxy never saw a CONNECT\n'; return 1; }; }

test_h_407_names_the_proxy() {  # H4. 407 is a proxy-only status; it was reported as 'the server
                                # answered' and treated as a terminal server verdict.
                                require_python3 || return 77
                                local p t out rc
                                start_listener status407 || return 1; p="$LISTENER_PORT_OUT"
                                start_listener ackstr || return 1; t="$LISTENER_PORT_OUT"
                                out="$( cd "$WORK/cwd" && env http_proxy="http://127.0.0.1:$p" bash "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$t" --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && rc=0 || rc=$?
                                assert_eq "fails" 1 "$rc" || return 1
                                assert_contains "as an answered, unusable peer" "No usable Thunderstorm server" "$out" || return 1
                                assert_contains "blaming a proxy, not the server" "a proxy refused the request (HTTP 407" "$out"; }

test_h_one_odd_answer_after_acks_is_retried() { # H5. A peer that acknowledged uploads and then
                                # returns one 2xx HTML page used to poison the run: every later file
                                # withheld, 'never acknowledged' printed beside submitted>0.
                                require_python3 || return 77
                                local p
                                start_listener ackthenhtml || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --retries 2 --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "the run succeeds" 0 "$CO_RC" || return 1
                                assert_eq "every file submitted after the retry" "$FIXTURE_COUNT" "$(co_stat submitted)" || return 1
                                assert_contains "the odd answer was retried as one" "2xx without a Thunderstorm answer" "$CO_OUT" || return 1
                                assert_not_contains "and the peer was not declared an impostor" "never acknowledged" "$CO_OUT"; }

test_h_retry_after_date_is_unknown_and_backed_off() { # H7. An HTTP-date Retry-After was digit-mashed
                                # to a huge number, capped to 120 and logged as the server's value; a
                                # missing/unknown value re-sent the body immediately, five times.
                                require_python3 || return 77
                                local p
                                start_listener radate || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "an upload failure" 4 "$CO_RC" || return 1
                                assert_contains "the value is called unknown" "503 without a usable Retry-After; backing off" "$CO_OUT" || return 1
                                assert_not_contains "never attributed to the server" "waiting 120s" "$CO_OUT" || return 1
                                assert_contains "gives up after the cap" "Too many 503" "$CO_OUT" || return 1
                                [ "$CO_SECS" -ge 28 ] || { printf '    FAIL: no backoff between 503 retries (%ss)\n' "$CO_SECS"; return 1; }; }

test_h_preflight_redirect_names_location() { # M2. Every non-2xx was 'usually the wrong port'; an
                                # HTTP->HTTPS front door is the --ssl case and says so.
                                require_python3 || return 77
                                local p
                                start_listener redirectstatus || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "fails" 1 "$CO_RC" || return 1
                                assert_contains "names the redirect" "redirected /api/status (HTTP 302 to https://127.0.0.1:443/api/status); this collector never follows redirects" "$CO_OUT"; }

test_h_preflight_retries_a_503_once() { # M2. A restarting server at start-up hard-failed after one
                                # GET while every upload retried; one bounded, Retry-After-honouring retry.
                                require_python3 || return 77
                                local p
                                start_listener status503once || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "succeeds" 0 "$CO_RC" || return 1
                                assert_contains "after one announced retry" "retrying once in 1s" "$CO_OUT" || return 1
                                assert_eq "every file submitted" "$FIXTURE_COUNT" "$(co_stat submitted)"; }

test_h_pretty_printed_ack_accepted() { # M3. The ack parser read only the first body line.
                                require_python3 || return 77
                                local p
                                start_listener ackpretty || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "accepted" 0 "$CO_RC" || return 1
                                assert_eq "every file submitted" "$FIXTURE_COUNT" "$(co_stat submitted)"; }

test_h_wget_http_error_is_a_status() { # M1. wget exits 8 on every HTTP error; a 500 was booked as
                                # 'transport failed before a verdict' with two error lines.
                                require_python3 || return 77
                                local p shim out rc
                                start_listener up500 || return 1; p="$LISTENER_PORT_OUT"
                                shim="$(wget_only_path)" || return 77
                                out="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && rc=0 || rc=$?
                                assert_eq "an upload failure" 4 "$rc" || return 1
                                assert_contains "classified by its status" "Server returned HTTP 500 for" "$out" || return 1
                                assert_not_contains "not as a transport failure" "wget exit 8" "$out"; }

test_h_minimal_wget_refused() { # M5. busybox's wget rejects --tries/--max-redirect with a usage dump;
                                # presence is not capability. Named exit 3, not a raw usage dump.
                                local shim bb out rc
                                shim="$(wget_only_path)" || return 77
                                bb="$WORK/bbwget"; rm -rf "$bb"; cp -R "$shim" "$bb" || return 1
                                rm -f "$bb/wget"   # a symlink to the real binary: never write THROUGH it
                                printf '#!/bin/sh\nprintf "BusyBox v1.35.0 multi-call binary.\\nUsage: wget [-cqS] [--spider] [-O FILE] URL\\n" >&2\nexit 1\n' > "$bb/wget"
                                chmod +x "$bb/wget"
                                out="$( cd "$WORK/cwd" && env PATH="$bb" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port 8080 --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && rc=0 || rc=$?
                                assert_eq "a named dependency failure" 3 "$rc" || return 1
                                assert_contains "that says what to install" "install GNU wget or curl" "$out"; }

test_h_server_env_announced_ignored() { # M6. THUNDERSTORM_PORT was announced as ignored while
                                # THUNDERSTORM_SERVER -- which decides WHERE evidence goes -- was
                                # overwritten in silence.
                                local out
                                out="$( cd "$WORK/cwd" && env THUNDERSTORM_SERVER=evil.example bash "$COLLECTOR" \
                                    --dry-run --server ts.example --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" || true
                                assert_contains "named and ignored" "THUNDERSTORM_SERVER='evil.example' is set in the environment and was IGNORED" "$out" || return 1
                                assert_contains "and the flag is what runs" "Server: ts.example" "$out"; }

test_h_wget_transport_end_to_end() { # The wget path with its new options (split timeouts,
                                # --content-on-error, WGETRC) still delivers every file to an
                                # acknowledging peer.
                                require_python3 || return 77
                                local p shim out rc
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"
                                shim="$(wget_only_path)" || return 77
                                out="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$FIXTURES" 2>&1 )" && rc=0 || rc=$?
                                assert_eq "succeeds" 0 "$rc" || return 1
                                assert_contains "under wget" "Transport: wget" "$out" || return 1
                                assert_contains "with every file" "submitted=$FIXTURE_COUNT" "$out"; }

test_h_retry_after_cap_is_stated() { # H7's other half, without the 120 s sleep: when the cap applies
                                # the log must state BOTH numbers, never attribute 120 to the server;
                                # a plain value is honoured as sent. The classifier is unit-tested with
                                # sleep and log_msg stubbed.
                                local fn="$WORK/classify.fn" hdr="$WORK/ra.hdr" resp="$WORK/ra.resp" out
                                for f in http_status_from_headers retry_after_seconds classify_upload_response; do
                                    sed -n "/^${f}()/,/^}/p" "$COLLECTOR"
                                done > "$fn"
                                : > "$resp"
                                printf 'HTTP/1.1 503 Service Unavailable\r\nRetry-After: 3600\r\n\r\n' > "$hdr"
                                out="$(bash -c 'HTTP_STATUS_OUT=; RETRY_AFTER_OUT=; RETRY_AFTER_SLEPT=0; TRANSPORT_ERR_OUT=; EFFECTIVE_PROXY_OUT=
                                    log_msg() { printf "%s\n" "$2"; }; sleep() { printf "SLEPT=%s\n" "$1"; }
                                    . "$1"; classify_upload_response curl 0 http://x/api/checkAsync f "$2" "$3"; printf "rc=%s slept_flag=%s\n" "$?" "$RETRY_AFTER_SLEPT"' _ "$fn" "$hdr" "$resp")"
                                assert_contains "both numbers are stated" "Retry-After asked for 3600s, waiting 120s (cap 120)" "$out" || return 1
                                assert_contains "and 120 is what was slept" "SLEPT=120" "$out" || return 1
                                assert_contains "as back-pressure, with the sleep recorded for the caller" "rc=93 slept_flag=1" "$out" || return 1
                                printf 'HTTP/1.1 503 Service Unavailable\r\nretry-after: 7\r\n\r\n' > "$hdr"
                                out="$(bash -c 'HTTP_STATUS_OUT=; RETRY_AFTER_OUT=; RETRY_AFTER_SLEPT=0; TRANSPORT_ERR_OUT=; EFFECTIVE_PROXY_OUT=
                                    log_msg() { printf "%s\n" "$2"; }; sleep() { printf "SLEPT=%s\n" "$1"; }
                                    . "$1"; classify_upload_response curl 0 http://x/api/checkAsync f "$2" "$3"' _ "$fn" "$hdr" "$resp")"
                                assert_contains "a plain value is honoured as sent (case-insensitive header)" "waiting 7s (Retry-After)" "$out" || return 1
                                assert_contains "and slept" "SLEPT=7" "$out"; }

test_h_url_globbing_refused() { # curl expands {a,b} and [1-2] in a URL by default, and --server is
                                # interpolated into that URL, so ONE invocation performed one transfer
                                # PER expansion: measured, the preflight, both markers and the sample
                                # all went to two hosts, the evidence reached a host the operator never
                                # named, and the run then reported the file FAILED because the second
                                # transfer found stdin (the streamed file) at EOF. curl now runs with
                                # -g, so the value is refused before a packet leaves.
                                require_python3 || return 77
                                local p log
                                start_listener ackstr || return 1; p="$LISTENER_PORT_OUT"; log="$LISTENER_LOG_OUT"
                                # A range whose FIRST expansion is the listener's own address: pre-fix it
                                # answered the preflight, so a zero-request assertion is meaningful.
                                run_collector --server '127.0.0.[1-2]' --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                # Now refused as a usage error by validate_config, BEFORE any
                                # transport runs -- so this is no longer curl's exit 3 (which the
                                # -g flag produces and which is still mapped for a value that
                                # reaches curl some other way), but exit 2 naming the character.
                                assert_eq "a globbed --server is a usage error" 2 "$CO_RC" || return 1
                                # Round 8 split the arm: '[' and ']' are refused as the wrong spelling
                                # of an IPv6 address (one spelling per host), and the glob arm now owns
                                # '{' and '}' alone -- which is the value driven a few lines below.
                                assert_contains "and the cause names the character" "contains '[' or ']'" "$CO_OUT" || return 1
                                # '127.0.0.[1-2]' is a RANGE, not a bracketed IPv6 address, so the
                                # accurate diagnosis is the range one -- telling this operator how to
                                # write IPv6 would be advice for a mistake they did not make.
                                assert_contains "and says why it matters" "does not name one host" "$CO_OUT" || return 1
                                assert_not_contains "nothing was collected" "Run completed" "$CO_OUT" || return 1
                                assert_eq "and NOT ONE request reached the peer" 0 "$(grep -c '^REQ ' "$log")" || return 1
                                run_collector --server '{127.0.0.1,127.0.0.2}' --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a brace list fails too" 2 "$CO_RC" || return 1
                                assert_eq "still no request reached the peer" 0 "$(grep -c '^REQ ' "$log")" || return 1
                                # Since round 8 the collector refuses a bracketed literal itself -- one
                                # spelling per host -- so it never reaches curl and -g cannot be blamed
                                # for it. What is pinned here is that the refusal is OUR diagnosis, not
                                # curl's glob complaint: the operator is told how to write the address.
                                run_collector --server '[::1]' --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "a bracketed literal is a usage error" 2 "$CO_RC" || return 1
                                assert_contains "and the refusal tells them how to write it" "is bracketed" "$CO_OUT" || return 1
                                assert_not_contains "never blamed on curl's URL globbing" "URL range" "$CO_OUT" || return 1
                                assert_not_contains "and never on a malformed URL" "URL was malformed" "$CO_OUT" || return 1
                                # The bare form is accepted too and is bracketed for the URL, which is
                                # the only spelling RFC 3986 allows. Same peer, same failure class.
                                run_collector --server '::1' --port "$p" --retries 1 --no-log-file --no-progress --dir "$ONEFILE"
                                assert_contains "a bare IPv6 literal is bracketed for the URL" "http://[::1]:$p" "$CO_OUT" || return 1
                                assert_not_contains "and is not refused" "the port belongs to --port" "$CO_OUT" || return 1
                                # Control: the same peer, named plainly, still receives the file.
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "the control run succeeds" 0 "$CO_RC" || return 1
                                assert_eq "and delivers" 1 "$(co_stat submitted)"; }

test_g_causes_and_transport_local() { # REGRESSION for H3 and N4 in the default tiers: the live
                                # tier was the only place either was asserted, and it is skipped by
                                # default. Two wrong-port shapes must produce two different sentences,
                                # and the run must say which transport it used.
                                require_python3 || return 77
                                local dead p shim wout wrc
                                dead="$(refused_port)"
                                run_collector --server 127.0.0.1 --port "$dead" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_contains "refused is named" "connection refused" "$CO_OUT" || return 1
                                assert_contains "and the transport is recorded" "Transport: curl" "$CO_OUT" || return 1
                                start_listener http404 || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_contains "a wrong application is named differently" "answered HTTP 404" "$CO_OUT" || return 1
                                assert_not_contains "and is not called refused" "connection refused" "$CO_OUT" || return 1
                                shim="$(wget_only_path)" || return 77
                                wout="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$dead" --no-log-file --no-progress \
                                    --dir "$ONEFILE" 2>&1 )" && wrc=0 || wrc=$?
                                assert_contains "wget is recorded as the transport" "Transport: wget" "$wout"; }

test_a_env_port_is_announced_ignored() { # An exported THUNDERSTORM_PORT is deliberately not
                                # honoured -- the environment must not redirect evidence -- but it is
                                # announced rather than silently dropped.
                                local out
                                out="$( cd "$WORK/cwd" && env THUNDERSTORM_PORT=1234 bash "$COLLECTOR" \
                                    --dry-run --server ts.example --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" || true
                                assert_contains "the environment value is named and ignored" "THUNDERSTORM_PORT='1234'" "$out" || return 1
                                assert_contains "and the flag default is what runs" "Port: 8080" "$out"; }

test_g_posix_grep_survives()    { # REGRESSION for N1 (was a characterisation test for the defect).
                                # The HTTP status is now parsed with pure parameter expansion, so
                                # `grep -o` -- a GNU extension absent on Solaris/AIX, and never
                                # detected -- is no longer on the status path at all. Before the
                                # fix this exact shim turned a wrong port into `exit 0
                                # submitted=5` with ZERO error lines; the run must now fail the
                                # same way it does with GNU grep.
                                require_python3 || return 77
                                local shim p out rc
                                shim="$(posix_grep_path)" || return 77
                                start_listener upload404 || return 1; p="$LISTENER_PORT_OUT"
                                out="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$p" --no-log-file --no-progress \
                                    --dir "$FIXTURES" 2>&1 )" && rc=0 || rc=$?
                                assert_eq "fails like any wrong port" 4 "$rc" || return 1
                                assert_contains "uploaded nothing" "submitted=0" "$out" || return 1
                                assert_contains "and says why" "Server returned HTTP 404" "$out" || return 1
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$FIXTURES"
                                assert_eq "GNU grep agrees" 4 "$CO_RC" || return 1
                                assert_eq "same count" 0 "$(co_stat submitted)"; }

test_g_proxy_env_records()     { # REGRESSION for N3 (was a characterisation test).
                                # curl and wget both honour http_proxy/https_proxy. The collector
                                # used to neither clear nor report them, so `Port:` and `API
                                # endpoint:` could both be false statements about where the bytes
                                # went. The effective proxy is now recorded -- with credentials
                                # redacted, since a proxy URL is routinely user:pass@host.
                                require_python3 || return 77
                                local good dead out rc
                                start_listener yes200 || return 1; good="$LISTENER_PORT_OUT"
                                dead="$(refused_port)"
                                out="$( cd "$WORK/cwd" && env http_proxy="http://u:s3cret@127.0.0.1:$dead" \
                                    https_proxy="http://u:s3cret@127.0.0.1:$dead" bash "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$good" --no-log-file --no-progress \
                                    --dir "$ONEFILE" 2>&1 )" && rc=0 || rc=$?
                                assert_eq "fails via the proxy" 1 "$rc" || return 1
                                assert_contains "the proxy is recorded" "Proxy: http://<redacted>@127.0.0.1:$dead" "$out" || return 1
                                assert_not_contains "and the password is not" "s3cret" "$out" || return 1
                                assert_contains "the port is still named" "Port: $good" "$out"; }

test_e_transports_agree_plain() { # Regression pin, and the control for the live TLS case.
                                # On a PLAINTEXT 404-everything port the two transports agree: both
                                # parse the 404, forgive it, scan, and fail every upload -> exit 4.
                                # If they ever diverge here, that is news.
                                require_python3 || return 77
                                local shim p wout wrc
                                shim="$(wget_only_path)" || return 77
                                start_listener upload404 || return 1; p="$LISTENER_PORT_OUT"
                                run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                assert_eq "curl" 4 "$CO_RC" || return 1
                                wout="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server 127.0.0.1 --port "$p" --no-log-file --no-progress \
                                    --dir "$ONEFILE" 2>&1 )" && wrc=0 || wrc=$?
                                assert_eq "wget agrees on plaintext" 4 "$wrc" || return 1
                                assert_contains "both scanned" "Run completed" "$wout"; }

test_c_source_encoding_needs_od() { # REGRESSION for a harness defect, and a collector finding (N5).
                                # urlencode shells out to `od -An -tx1` for every character outside
                                # the unreserved set; od is never detected. Without it the character
                                # is silently DROPPED from the query and a raw "od: command not
                                # found" escapes past the logging.
                                run_collector --server ts.example --source 'a b' --no-log-file --dry-run \
                                    --no-progress --dir "$ONEFILE" --port 8080
                                assert_eq "space is percent-encoded" "http://ts.example:8080/api/checkAsync?source=a%20b" "$(co_endpoint)" || return 1
                                local shim
                                shim="$(wget_only_path)" || return 77
                                [ -x "$shim/od" ] || {
                                    printf "    ${RED}FAIL${RESET}: wget shim is missing od\n"; return 1; }; }

# ── Axis F — observability ────────────────────────────────────────────────────

test_f_run_log_names_target()  { offline_port --port 4443
                                 assert_contains "port line" "Port: 4443" "$CO_OUT" || return 1
                                 assert_contains "endpoint line" "API endpoint: http://127.0.0.1:4443/api/" "$CO_OUT"; }

test_f_usage_error_writes_none() { # REGRESSION for M4 (was a characterisation test).
                                  # The file sink is now armed AFTER validate_config, so no usage
                                  # error leaves a file behind in the directory the operator ran
                                  # from. Previously '--port abc' created ./thunderstorm.log while
                                  # '--port' with no value did not -- two exit-2 usage errors, one
                                  # with an on-disk side effect.
                                  local d out
                                  d="$WORK/logcwd-reject"
                                  rm -rf "$d"; mkdir -p "$d"
                                  out="$( cd "$d" && bash "$COLLECTOR" --server 127.0.0.1 --port abc --dir "$ONEFILE" 2>&1 )" || true
                                  if [ -f "$d/thunderstorm.log" ]; then
                                      printf "    ${RED}FAIL${RESET}: a usage error still wrote ./thunderstorm.log\n"
                                      return 1
                                  fi
                                  assert_contains "still reported" "Port must be numeric" "$out"; }

test_f_parse_error_writes_none() { # The other half of the same pair: a port error caught during
                                   # parse_args is reported while the file sink is still closed, so
                                   # nothing is written. Two exit-2 port errors, two different
                                   # on-disk side effects.
                                   local d="$WORK/logcwd-parse"
                                   rm -rf "$d"; mkdir -p "$d"
                                   ( cd "$d" && bash "$COLLECTOR" --server 127.0.0.1 --port ) >/dev/null 2>&1
                                   if [ -f "$d/thunderstorm.log" ]; then
                                       printf "    ${RED}FAIL${RESET}: ./thunderstorm.log was written for a parse-time error\n"
                                       return 1
                                   fi; }

test_f_help_documents_port()   { local out
                                 out="$(bash "$COLLECTOR" --help 2>&1)"
                                 assert_contains "help lists the flag" "-p, --port" "$out" || return 1
                                 assert_contains "help states the default" "default: 8080" "$out" || return 1
                                 assert_contains "help says --ssl does not imply 443" "does NOT change it to 443" "$out"; }

test_f_failure_lines_name_target() { # REGRESSION for L1 (was a characterisation test).
                                   # Per-file upload failures used to name the file and the status
                                   # but not the destination, so a grep-filtered or truncated log
                                   # could not be tied back to a target. They now carry it.
                                   require_python3 || return 77
                                   local p failures
                                   start_listener upload404 || return 1; p="$LISTENER_PORT_OUT"
                                   run_collector --server 127.0.0.1 --port "$p" --no-log-file --no-progress --dir "$ONEFILE"
                                   failures="$(printf '%s\n' "$CO_OUT" | grep 'Server returned HTTP 404' || true)"
                                   assert_contains "a failure line exists" "Server returned HTTP 404" "$failures" || return 1
                                   assert_contains "and it names the target" ":$p" "$failures"; }

test_f_quiet_nolog_still_reports() { # REGRESSION for N2 (was a characterisation test).
                                # The runtime fatals used a bare `log_msg error` + exit, so they
                                # missed die()'s sink-forcing guard: under --quiet --no-log-file
                                # with no --syslog, the one line naming an unreachable port reached
                                # nobody and the operator got a bare exit 1 under a banner. They now
                                # go through die_runtime, which forces a sink first.
                                local p out rc
                                p="$(refused_port)"
                                ( cd "$WORK/cwd" && bash "$COLLECTOR" --server 127.0.0.1 --port "$p" \
                                    --quiet --no-log-file --no-progress --dir "$ONEFILE" ) \
                                    >"$WORK/q.out" 2>"$WORK/q.err" && rc=0 || rc=$?
                                assert_eq "runtime failure" 1 "$rc" || return 1
                                assert_contains "the reason reaches stderr" "Cannot reach" "$(cat "$WORK/q.err")" || return 1
                                assert_contains "and it names the port" ":$p" "$(cat "$WORK/q.err")" || return 1
                                # A usage error under the identical flags is still forced through.
                                out="$( cd "$WORK/cwd" && bash "$COLLECTOR" --server 127.0.0.1 --port 99999 \
                                    --quiet --no-log-file --dir "$ONEFILE" 2>&1 )" || true
                                assert_contains "usage errors too" "Port must be <= 65535" "$out"; }

# ── Live tier ─────────────────────────────────────────────────────────────────


live_collector() {
    run_collector --server "$LIVE_HOST" --no-log-file --no-progress \
        --source "port-audit-$$" "$@"
}

test_live_transports_agree()   { # REGRESSION for N4 (was a characterisation test).
                                # curl and wget used to DISAGREE about the target's port 80: their
                                # TLS stacks differ, so curl completed the handshake, read the 404,
                                # forgave it and scanned the whole tree (exit 4) while wget failed
                                # the handshake and aborted (exit 1) -- same command line, same
                                # server, different outcome, and the log never said which transport
                                # ran. The preflight makes both refuse the port up front, and the
                                # run now records the transport either way.
                                require_live || return 77
                                local shim wout wrc
                                shim="$(wget_only_path)" || return 77
                                live_collector --port "$LIVE_OPEN_WRONG" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "curl refuses the port" 1 "$CO_RC" || return 1
                                assert_contains "and names its transport" "Transport: curl" "$CO_OUT" || return 1
                                wout="$( cd "$WORK/cwd" && env PATH="$shim" "$(type -P bash)" "$COLLECTOR" \
                                    --server "$LIVE_HOST" --port "$LIVE_OPEN_WRONG" \
                                    ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --source "port-audit-$$" \
                                    --no-log-file --no-progress --dir "$ONEFILE" 2>&1 )" && wrc=0 || wrc=$?
                                assert_eq "wget agrees now" 1 "$wrc" || return 1
                                assert_contains "and names its transport too" "Transport: wget" "$wout"; }

test_live_happy_path()        { require_live || return 77
                                live_collector --port "$LIVE_PORT" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$FIXTURES"
                                assert_eq "clean run" 0 "$CO_RC" || return 1
                                assert_eq "discovered" "$FIXTURE_COUNT" "$(co_stat discovered)" || return 1
                                # The point of the live tier: bytes actually reached the server.
                                assert_eq "submitted" "$FIXTURE_COUNT" "$(co_stat submitted)" || return 1
                                assert_eq "nothing failed" 0 "$(co_stat failed)"; }

test_live_refused_port()      { require_live || return 77
                                live_collector --port "$LIVE_REFUSED" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "exit code" 1 "$CO_RC" || return 1
                                assert_contains "names the target" ":$LIVE_REFUSED" "$CO_OUT" || return 1
                                assert_le "fails fast on RST" 12 "$CO_SECS"; }

test_live_filtered_port()     { require_live || return 77
                                live_collector --port "$LIVE_FILTERED" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                assert_eq "exit code" 1 "$CO_RC" || return 1
                                assert_contains "names the target" ":$LIVE_FILTERED" "$CO_OUT" || return 1
                                # One preflight attempt at --connect-timeout 10.
                                assert_le "bounded by the connect timeout" 40 "$CO_SECS"; }

test_live_wrong_app_fails_fast() { # REGRESSION for H1, against the real server.
                                # The target's port 80 is open, protocol-sniffs http and TLS, and
                                # 404s every path. That used to cost a full filesystem walk before
                                # anything was reported; it must now cost seconds.
                                require_live || return 77
                                live_collector --port "$LIVE_OPEN_WRONG" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$FIXTURES"
                                assert_eq "refused before scanning" 1 "$CO_RC" || return 1
                                assert_not_contains "never walked the tree" "Run completed" "$CO_OUT" || return 1
                                assert_le "promptly" 20 "$CO_SECS"; }

test_live_causes_distinguish() { # REGRESSION for H3 (was a characterisation test).
                                # Refused, filtered and TLS-rejected ports used to produce one
                                # identical sentence, because collection_marker sent curl's stderr
                                # to /dev/null and never logged its exit code. Each now names its
                                # own cause, so an operator can tell a wrong port from a firewall
                                # from an untrusted certificate without re-running curl by hand.
                                require_live || return 77
                                local refused_msg filtered_msg
                                live_collector --port "$LIVE_REFUSED" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                refused_msg="$(printf '%s\n' "$CO_OUT" | grep -m1 'Cannot reach')"
                                live_collector --port "$LIVE_FILTERED" ${LIVE_TLS_OPTS[@]+"${LIVE_TLS_OPTS[@]}"} --dir "$ONEFILE"
                                filtered_msg="$(printf '%s\n' "$CO_OUT" | grep -m1 'Cannot reach')"
                                assert_contains "refused names its cause" "refused" "$refused_msg" || return 1
                                assert_contains "filtered names its cause" "timed out" "$filtered_msg" || return 1
                                if [ "$refused_msg" = "$filtered_msg" ]; then
                                    printf "    ${RED}FAIL${RESET}: two different causes still produce one message\n"
                                    return 1
                                fi; }

# ── Runner ────────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$WORK/cwd" || { echo "ERROR: cannot create the run directory" >&2; exit 1; }
    make_fixtures || { echo "ERROR: cannot create fixtures" >&2; exit 1; }
    have_python3 && write_listener_src

    printf "${BOLD}Port-flag suite${RESET} — collector: %s\n" "$COLLECTOR"
    printf "  work dir: %s\n" "$WORK"
    if probe_live; then
        # shellcheck disable=SC2034  # read by require_live() in lib/harness.sh
        LIVE_READY=1
        printf "  live tier: ${GREEN}%s:%s${RESET} (api reachable)\n" "$LIVE_HOST" "$LIVE_PORT"
    elif [ -n "$LIVE_HOST" ]; then
        printf "  live tier: ${YELLOW}%s:%s unreachable — skipping${RESET}\n" "$LIVE_HOST" "$LIVE_PORT"
    else
        printf "  live tier: ${DIM}not configured (set THUNDERSTORM_PORT_LIVE_HOST) — skipping${RESET}\n"
    fi
    have_python3 || printf "  local tier: ${YELLOW}python3 missing — skipping${RESET}\n"

    section "A — parse time"
    run_test test_a_long_form
    run_test test_a_short_form
    run_test test_a_equals_form
    run_test test_a_short_equals_refused
    run_test test_a_missing_value
    run_test test_a_does_not_eat_flag
    run_test test_a_empty_value
    run_test test_a_whitespace_value
    run_test test_a_equals_empty
    run_test test_a_negative_plain
    run_test test_a_negative_equals_form
    run_test test_a_last_occurrence_wins
    run_test test_a_after_double_dash
    run_test test_a_bare_operand_is_dir
    run_test test_a_env_var_ignored
    run_test test_a_near_miss_spellings

    section "B — numeric gate"
    run_test test_b_accepts_boundaries
    run_test test_b_rejects_zero
    run_test test_b_rejects_all_zeros
    run_test test_b_rejects_above_max
    run_test test_b_rejects_oversize
    run_test test_b_canonicalises_zeros
    run_test test_b_rejects_non_decimal
    run_test test_b_rejects_padded
    run_test test_b_rejects_wide_digits
    run_test test_b_reported_overflow_set

    section "C — URL composition"
    run_test test_c_endpoint_plain
    run_test test_c_endpoint_ssl
    run_test test_c_endpoint_always_async
    run_test test_c_endpoint_canonical
    run_test test_c_port_always_appended
    run_test test_c_trailing_slash_refused
    run_test test_c_no_leading_zero_in_url
    run_test test_c_source_encoding_needs_od

    section "E — network shape (local)"
    run_test test_e_refused_is_fast
    run_test test_e_dry_run_checks_the_destination
    run_test test_e_wrong_app_fails_fast
    run_test test_e_nonhttp_listener
    run_test test_e_redirect_not_followed
    run_test test_e_silent_listener
    run_test test_e_permissive_service_passes
    run_test test_e_dry_run_never_claims_a_submission
    run_test test_e_wget_follows_redirect
    run_test test_g_proxy_env_records
    run_test test_g_sentinels_do_not_leak
    run_test test_g_status_anchored_to_line_start
    run_test test_g_no_status_fails_closed
    run_test test_g_ack_accepts_both_id_spellings
    run_test test_h_impostor_refused
    run_test test_h_rc_files_are_not_read
    run_test test_h_schemeless_proxy_credential_redacted
    run_test test_h_connect_tunnel_failure_is_not_an_answer
    run_test test_h_407_names_the_proxy
    run_test test_h_one_odd_answer_after_acks_is_retried
    run_test test_h_retry_after_date_is_unknown_and_backed_off
    run_test test_h_preflight_redirect_names_location
    run_test test_h_preflight_retries_a_503_once
    run_test test_h_pretty_printed_ack_accepted
    run_test test_h_wget_http_error_is_a_status
    run_test test_h_minimal_wget_refused
    run_test test_h_server_env_announced_ignored
    run_test test_h_wget_transport_end_to_end
    run_test test_h_retry_after_cap_is_stated
    run_test test_h_url_globbing_refused
    run_test test_g_causes_and_transport_local
    run_test test_a_env_port_is_announced_ignored
    run_test test_e_transports_agree_plain
    run_test test_g_posix_grep_survives

    section "F — observability"
    run_test test_f_run_log_names_target
    run_test test_f_usage_error_writes_none
    run_test test_f_parse_error_writes_none
    run_test test_f_help_documents_port
    run_test test_f_failure_lines_name_target
    run_test test_f_quiet_nolog_still_reports

    section "D/E — live server"
    run_test test_live_happy_path
    run_test test_live_refused_port
    run_test test_live_filtered_port
    run_test test_live_wrong_app_fails_fast
    run_test test_live_causes_distinguish
    run_test test_live_transports_agree

    printf "\n${BOLD}Results:${RESET} %d/%d passed" "$TESTS_PASSED" "$TESTS_RUN"
    [ "$TESTS_SKIPPED" -gt 0 ] && printf ", ${YELLOW}%d skipped${RESET}" "$TESTS_SKIPPED"
    printf "\n"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf "${RED}%d failed:${RESET}\n%b" "$TESTS_FAILED" "$FAILED_NAMES"
        exit 1
    fi
    # This suite had no floor at all: 34 of its 80 tests are skip-gated, so a runner that lost
    # python3 could execute a handful, exit 0, and read as a clean run. A full local run executes
    # 74; 60 leaves room for the live tier and the environment skips.
    assert_tests_floor 60 || exit 1
    printf "${GREEN}All port tests passed.${RESET}\n"
    exit 0
}

main "$@"
