# Bash Collector

Use `thunderstorm-collector.sh` for Unix incident response when Bash is available
but deploying the Go collector is not practical. It uploads regular files to a
THOR Thunderstorm service. It does not scan files locally.

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | Bash 3.2 or newer; not `sh`, `dash`, or BusyBox ash |
| Upload tool | `curl` (preferred) or **GNU wget** with `--no-config`, not BusyBox wget |
| System tools | GNU/BSD `find`, `stat`, `mktemp`, and standard Unix text utilities |
| Permissions | Only files readable by the current user can be uploaded |
| Service | HTTP/HTTPS Thunderstorm; no built-in HTTP authentication options |

The collector does not require Python, jq, or GNU coreutils on macOS. Automated
tests have additional dependencies; those are not collector requirements.
Use the ash collector for BusyBox environments instead of weakening Bash's scope.

## Configuration and Startup Output

Edit the `USER CONFIGURATION` block near the top of the script, or pass options.
Set `THUNDERSTORM_SERVER` to a hostname/IP without a scheme, port or API path;
an empty server stops with exit 2 and an instruction explaining how to set it.
Use `SCAN_FOLDERS=("/var/www" "/home/alice")` for explicit roots. Header roots
are respected; an empty array selects the platform defaults listed below.
Command-line options override header values, and the first `--dir` replaces the
whole root list. `--no-ssl`, `--verify-tls`, `--async`, `--no-dry-run` and
`--no-debug` can turn off corresponding header choices.

The shipped limits are **30 days since modification** and **2048 KiB (2 MiB)**.
Older/larger files are intentionally not collected; use `--max-age 0` for all ages.
Before scanning, the console and enabled file/syslog destinations show one line
per root and the effective limits, including in dry-run. Start with `--dry-run`
and inspect that scope before permitting uploads. `--quiet` explicitly suppresses
console output. Keep externally captured logs outside the input directories.

## Bash-Specific Behavior

- Default roots: existing directories among `/root`, `/tmp`, `/home`, `/var`,
  `/usr`; on macOS, `/Users`, `/tmp`, `/var`, `/usr`. Always supply `--dir`
  during acceptance testing to avoid uploading unrelated files. Missing explicitly
  selected roots remain errors; only absent default roots are omitted.
- The first `--dir` or positional directory replaces the defaults. Further
  directories are additive, including directories after `--`.
- Recursive regular-file collection; symlinks within the tree are not followed.
  Explicit directory roots are resolved to physical absolute paths.
- Default age limit: 30 days, based on **modification time**, not creation time.
  `--max-age 0` disables filtering; other values use `find -mtime -N`.
- Default size limit: 2048 KiB. `--max-size-kb N` includes files up to `N * 1024`
  bytes, including empty files. Oversize files count as skipped.
- HTTP/HTTPS, asynchronous `/api/checkAsync` by default, `--sync` for `/api/check`.
  An accepted asynchronous upload does not mean analysis has finished.
- TLS verification is enabled. `--ca-cert FILE` selects HTTPS and a trusted CA
  bundle. `--insecure` deliberately disables verification; do not use it as a
  routine workaround for a certificate error.
- Binary contents and unusual local filenames are supported. Multipart filename
  metadata replaces quotes, semicolons, backslashes, CR, and LF with underscores.
  This does not change the uploaded bytes.
- Source defaults to the hostname; `--source NAME` overrides it and is URL-encoded.
  Begin/end markers and returned scan IDs are supported. Marker HTTP 404/501 are
  nonfatal for older services without `/api/collection`.
- Only complete HTTP 2xx uploads count as successful. Redirects are not followed.
  Curl/wget configuration files and proxy environment settings are ignored, so
  they cannot silently disable TLS checks or redirect uploads elsewhere.
  Default: three normal attempts per file, configurable with `--retries 1..10`,
  with capped exponential backoff. HTTP 503 has a separate budget of five busy
  responses; integer-seconds `Retry-After` values are honored up to 120 seconds.
  Missing, malformed, or HTTP-date values use a two-second fallback.
- Failed uploads, unreadable/disappeared files, and incomplete directory scans
  do not prevent other readable files from being processed. They make the overall
  result nonzero. An end-marker failure also makes the result nonzero even when
  uploads succeeded; check the service before repeating the run.
- Dry-run filters files but sends **no HTTP requests**, including markers. It
  works without an upload tool. Its `submitted` count means **would submit**.
- Private temporary workspace, excluded from collection and removed on exit.
  The configured collector log file is also excluded. Workspace creation failure
  is fatal; there is no predictable temporary-file fallback.
- Optional logging, syslog, debug output, progress, and best-effort interrupted
  markers on SIGINT/SIGTERM. `--log-file` enables file logging; `--no-log-file`
  disables it. If both are present, the last option wins.

| Exit Code | Meaning |
|---|---|
| `0` | Completed without detected errors; an empty readable directory is valid |
| `1` | Partial failure, incomplete scan, failed end marker, or interrupted run |
| `2` | Invalid configuration, missing upload tool, unusable workspace, or failed begin handshake |

The summary reports `scanned`, `submitted`, `skipped`, `failed`, and `scan_errors`.
`failed` counts file failures; `scan_errors` counts incomplete directory scans.
Missing roots are errors, not successful empty collections.

## Limitations

- This is a live filesystem walk, not an atomic snapshot. Files may change between
  discovery, size checking, and upload. Symlink checks are not a security boundary
  against a hostile process concurrently replacing filesystem entries.
- Overlapping roots can submit the same file repeatedly. There is no deduplication,
  resume database, content-type filter, or concurrent uploading.
- Known pseudo-filesystems and cloud-folder names are pruned. Automatic detection
  of network/special mounts uses Linux `/proc/mounts`; it is not comprehensive on
  other systems. Select known local roots on macOS and other Unix systems.
- Curl: 10-second connection timeout and 300-second total upload timeout. GNU wget:
  10-second connection timeout, 300-second read timeout, one internal attempt.
  Wget's read timeout is **not a total wall-clock deadline** for a server that
  keeps sending data. Prefer curl.
- Marker requests have 10-second timeouts; begin is tried twice. Large collections
  and repeated busy responses can take much longer than a smoke test.
- Responses are limited to 1 MiB. Each transport output file has an additional
  operating-system write limit of at most 2 MiB, including headers and diagnostics.
  Oversized responses fail the request; error-body logging is limited to 4 KiB.
  Marker IDs must be top-level JSON strings of at most 256 bytes without control
  characters. Nested, duplicate, non-string, or malformed IDs are ignored with a
  warning. Unicode escapes are decoded without changing the identifier.
  Marker JSON above 64 KiB is not parsed: uploads continue without a scan ID
  and a warning is emitted. This bounds parser work on older awk runtimes.
- SIGKILL, power loss, or an unresponsive filesystem can prevent cleanup/markers.
  Retries after ambiguous network failures can duplicate a server-side submission;
  the collector cannot promise exactly-once delivery.

## Basic Usage

From this directory:

```bash
bash ./thunderstorm-collector.sh --help
bash ./thunderstorm-collector.sh \
  --server thunderstorm.example.org --port 8080 \
  --dir /path/to/collection --source incident-123 --max-age 30
```

## Manual Acceptance Against a Real Service

Check out [PR #44](https://github.com/NextronSystems/thunderstorm-collector/pull/44),
then enter `scripts/bash`. Its branch includes the shared harness/layout
prerequisites. Do not merge the PR merely to test it.

### 1. Prepare an Isolated Fixture

Run these in Bash. Replace host/port with the real test service. For HTTPS, set
`TRANSPORT` to the example below, using a CA that actually trusts the service.
Never add a real license, credentials, or investigation evidence to this fixture.

```bash
SERVER=thunderstorm.example.org
PORT=8080
TRANSPORT=()
# HTTPS example:
# PORT=8443
# TRANSPORT=(--ssl --ca-cert /secure/path/service-ca.pem)

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-bash-acceptance.XXXXXX")
mkdir -p "$TEST_ROOT/samples/subdir"
printf 'plain text\n' > "$TEST_ROOT/samples/plain.txt"
printf '\x00\x01\xffTHUNDER\n' > "$TEST_ROOT/samples/binary.bin"
printf 'nested\n' > "$TEST_ROOT/samples/subdir/nested.txt"
: > "$TEST_ROOT/samples/empty.bin"
printf 'spaces\n' > "$TEST_ROOT/samples/file with spaces.txt"
printf 'semicolon\n' > "$TEST_ROOT/samples/semi;colon.txt"
printf 'comma\n' > "$TEST_ROOT/samples/comma,name.txt"
printf 'quote\n' > "$TEST_ROOT/samples/double\"quote.txt"
RUN_ID="manual-bash-$(date +%Y%m%d-%H%M%S)"

collector() {
  bash ./thunderstorm-collector.sh \
    --server "$SERVER" --port "$PORT" "${TRANSPORT[@]}" \
    --source "$RUN_ID-$CASE" --max-age 0 --no-log-file --no-progress "$@"
  rc=$?
  printf 'exit=%s\n' "$rc"
  return "$rc"
}
```

Record the commit, OS, Bash version (`bash --version`), upload tool/version,
service version, source, output, and exit code per case. Skipped cases are not
passed. The [manual guide](../MANUAL_TESTING_GUIDE.md) defines acceptance statuses.

### 2. Normal Upload and Integrity

```bash
CASE=basic
collector --dir "$TEST_ROOT/samples" --debug
```

Expect exit `0`, `scanned=8 submitted=8 skipped=0 failed=0 scan_errors=0`.
Wait for asynchronous processing and verify **all eight payloads** in the service,
not just one result. Check source `$RUN_ID-basic`, nested/text/binary/empty files,
and special-name payloads. Where available, check client filename sanitization
and compare downloaded bytes or SHA-256 hashes with the originals.

If markers are supported, verify begin/end, consistent scan ID, and statistics.
An older service can warn about marker HTTP 404/501 and still succeed. If your
service rejects empty samples, document the limitation and observed nonzero
result instead of counting this case as passed.

### 3. Dry-Run and Unreachable Service

Use an unused local port for the unreachable case, not a production endpoint.

```bash
CASE=dry-run
collector --server 127.0.0.1 --port 1 --dir "$TEST_ROOT/samples" --dry-run
CASE=unreachable
started=$SECONDS
collector --server 127.0.0.1 --port 1 --dir "$TEST_ROOT/samples" --retries 1
printf 'elapsed=%ss\n' "$((SECONDS - started))"
```

Dry-run: exit `0`, eight `would submit` entries, no service records for that source.
Automated regressions additionally assert zero HTTP requests.
Unreachable: exit `2`, clear begin-handshake failure, no endless retries; this
small connection test should finish within about 30 seconds. This is not the same
as an upload failing after a successful begin; automated tests cover that separately.

### 4. Missing and Unreadable Paths

```bash
CASE=missing
collector --dir "$TEST_ROOT/samples" --dir "$TEST_ROOT/missing"
CASE=all-missing
collector --dir "$TEST_ROOT/missing" --dry-run
```

Both exit `1` with `scan_errors=1`. The first still uploads eight readable files;
the second must not report a successful empty collection.

For permission testing, run **without root privileges**:

```bash
mkdir -p "$TEST_ROOT/permissions/blocked-dir"
printf 'readable\n' > "$TEST_ROOT/permissions/ok.txt"
printf 'blocked\n' > "$TEST_ROOT/permissions/blocked.txt"
printf 'hidden\n' > "$TEST_ROOT/permissions/blocked-dir/hidden.txt"
chmod 000 "$TEST_ROOT/permissions/blocked.txt" "$TEST_ROOT/permissions/blocked-dir"
CASE=permissions
collector --dir "$TEST_ROOT/permissions"
chmod 600 "$TEST_ROOT/permissions/blocked.txt"
chmod 700 "$TEST_ROOT/permissions/blocked-dir"
```

Expect exit `1`, warnings, `submitted=1 failed=1 scan_errors=1`, and only `ok.txt`
uploaded. Root or unusual ACL behavior invalidates this test; record NOT TESTED
and repeat under a suitable account. Restore permissions even after failure.

### 5. Size and Age Boundaries

```bash
mkdir -p "$TEST_ROOT/size" "$TEST_ROOT/age"
dd if=/dev/zero of="$TEST_ROOT/size/limit.bin" bs=1024 count=1 2>/dev/null
dd if=/dev/zero of="$TEST_ROOT/size/too-large.bin" bs=1025 count=1 2>/dev/null
CASE=size
collector --dir "$TEST_ROOT/size" --max-size-kb 1
printf 'recent\n' > "$TEST_ROOT/age/recent.txt"
printf 'old\n' > "$TEST_ROOT/age/old.txt"
touch -t 202001010000 "$TEST_ROOT/age/old.txt"
CASE=age-limited
collector --dir "$TEST_ROOT/age" --max-age 1
CASE=age-disabled
collector --dir "$TEST_ROOT/age" --max-age 0
```

All exit `0`. Size: only `limit.bin`, with `skipped=1`. Age-limited: only
`recent.txt`. Age-disabled: both files. Verify by source in the service.

### 6. Symlinks and Internal Files

```bash
printf 'must stay local\n' > "$TEST_ROOT/outside.txt"
ln -s "$TEST_ROOT/outside.txt" "$TEST_ROOT/samples/link.txt"
CASE=internal-files
TMPDIR="$TEST_ROOT/samples" collector --dir "$TEST_ROOT/samples" \
  --log-file "$TEST_ROOT/samples/collector.log"
```

Expect exit `0` and still eight uploads. Neither the symlink target, the collector
log, nor any `thunderstorm.*` workspace file may reach the service. The log remains
local after exit; the private workspace is removed. Unrelated directories must
remain untouched.

### 7. TLS Verification, if HTTPS Is Available

First pass normal uploads with a valid certificate/CA. Then:

```bash
printf 'not a CA certificate\n' > "$TEST_ROOT/wrong-ca.pem"
CASE=wrong-ca
collector --ssl --ca-cert "$TEST_ROOT/wrong-ca.pem" --dir "$TEST_ROOT/size"
```

Expect exit `2` and no accepted uploads with that source. Do not add `--insecure`
to make the case pass. Record TLS as NOT TESTED for an HTTP-only environment.

### 8. Cleanup and Sign-Off

Retain results first, then remove only the workspace created above:

```bash
rm -rf -- "$TEST_ROOT"
```

Mark applicable cases PASS, FAIL, or NOT TESTED and document accepted service/runtime
limitations. Local upload success alone is not human acceptance. Do not merge with
unexplained missing uploads, successful exits for incomplete scans, internal-file
uploads, or an unreviewed TLS workaround.

## Automated Tests

From the repository root, using a native stub binary for your OS:

```bash
bash scripts/tests/run_tests.sh /path/to/thunderstorm-stub-server
python3 -B scripts/tests/test_bash_robustness.py
COLLECTOR_BASH=/bin/bash python3 -B scripts/tests/test_bash_robustness.py
THUNDERSTORM_TEST_COLLECTORS=bash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 \
  bash scripts/tests/run_e2e_compliance.sh /path/to/thunderstorm-stub-server
```

The Python regressions use only the standard library, synthetic fixtures, and a
loopback HTTP server. `COLLECTOR_BASH` selects the **collector** interpreter,
independently of the shared harness's Bash 4.3+ requirement. Verify `/bin/bash`'s
version instead of assuming it; on macOS it normally provides Bash 3.2.
