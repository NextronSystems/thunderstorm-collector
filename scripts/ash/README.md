# POSIX sh / BusyBox ash Collector

Use `thunderstorm-collector-ash.sh` on Unix-like systems without Bash: BusyBox/Alpine, embedded Linux, routers, appliances, and recovery environments. Prefer the Bash collector when Bash is available and filenames containing newlines must be supported. No Python, Perl, or Go is required on the collector target.

## Requirements and Transport Selection

The script uses POSIX shell syntax and is tested with dash and BusyBox ash. Test the actual shell and utility versions on your target; a dash run is not evidence for every BusyBox build.

| Requirement | Detail |
|---|---|
| Utilities | `sh`, `find`, `awk`, `sed`, `grep`, `tr`, `wc`, `od`, `cat`, `date`, `head`, `tail`, `rm`, `mktemp`, `dirname`, `basename`, `uname` |
| Temporary storage | Writable `TMPDIR` (default `/tmp`); `mktemp -d TEMPLATE` must work |
| Size metadata | GNU/BSD/BusyBox `stat` when available; otherwise `wc -c` reads the file to measure it |
| Optional tools | `hostname`, `id`, `logger` for hostname discovery, privilege warnings, syslog |
| Server addressing | IPv4 or DNS hostname plus port 1..65535; no URL scheme/path or IPv6 literal |

The first supported transport is selected:

| Transport | HTTP | HTTPS | Binary-safe | Collection markers |
|---|---|---|---|---|
| curl | Yes | Verified by default | Yes | If the service supports them |
| GNU wget | Yes | Verified by default | Yes | If the service supports them |
| nc + timeout | Yes | No | Yes | Not sent |
| BusyBox/unknown wget alone | Refused | Refused | Not accepted as a safe fallback | Not sent |

Curl/wget configuration files and proxy environment settings are ignored, so
they cannot silently disable TLS verification or redirect uploads. GNU wget must
support `--no-config`.

Netcat requires `nc -w SECONDS HOST PORT` and GNU/BusyBox-compatible `timeout SECONDS COMMAND`. Its minimal HTTP/1.0 client requires a complete header section, exactly one `Content-Length`, no `Transfer-Encoding`, and the exact declared body length. Chunked, close-delimited, informational, malformed and incomplete responses fail. Prefer curl/GNU wget if your backend needs those features. HTTP is unencrypted; use an appropriately isolated network.

## Capabilities

- Recursive regular-file scanning; no traversal of symlink entries. Explicit symlink roots resolve to their physical directory.
- All extensions are eligible. No executable-only selector or extension-filter option.
- Age: `--max-age 0..36500`, default 14. Zero disables filtering; positive values use `find -mtime -N` (24-hour buckets, not calendar dates).
- Size: `--max-size-kb 1..1048576`, default 2000. One unit is 1024 bytes; the exact limit is included. Empty files are eligible, subject to backend support.
- Known cloud-folder paths are skipped. `/proc`, `/sys`, `/dev`, `/run`, `/snap`, `/.snapshots` and detected Linux network/special mounts are excluded. These are best-effort exclusions, not a security boundary.
- A private workspace and the active log are excluded from scanning. Scratch files are reused and removed on exit.
- Source is percent-encoded in the query string; payload bytes remain unchanged. Multipart filename metadata replaces quotes, backslashes, semicolons and CR/LF with underscores.
- Async `/api/checkAsync` submission by default; `--sync` uses `/api/check`. Async success means accepted, not analysis completed. The collector does not poll async results.
- Optional begin/end/interrupted `/api/collection` markers. HTTP 404/501 is nonfatal and supplies no scan ID. Other begin failures retry once after two seconds, then abort; end failures produce a nonzero exit.
- Marker IDs must be top-level JSON strings of at most 256 bytes without control characters. Unicode escapes are decoded; nested, duplicate, non-string and malformed IDs are ignored with a warning.
- Marker JSON above 64 KiB is not parsed: uploads continue without a scan ID and a warning is emitted. This bounds parser work on older awk runtimes.
- `--retries 1..10` bounds total attempts per file, including HTTP 503. Retry-After integer seconds cap at 120; otherwise backoff starts at two seconds and caps at 60. A lost response can cause duplicates; no deduplication or resume.
- Dry-run needs no upload tool and never contacts the server. CLI, file and optional syslog logging are supported.

## Limits and Exit Codes

Paths containing literal newlines are **not supported**. Explicit newline roots are rejected before contacting the server. Discovered newline paths are never submitted or split into other paths; the run records scan errors and continues with supported files.
This also applies to physical paths reached through symlinks. A resolved newline
root is a scan error; a newline workspace or log path is a fatal configuration error.

Missing/inaccessible roots, traversal errors, unreadable/disappeared files and failed uploads are visible failures, not successful skips. Other readable files can still be submitted. `scan_errors` counts root/traversal/unsupported-path errors separately from per-file `failed` counts.

| Exit | Meaning |
|---|---|
| 0 | All eligible supported files submitted, or successful dry-run; intentional filter skips allowed |
| 1 | Partial/incomplete run, interruption, failed file, scan error, or failed end marker |
| 2 | Invalid configuration, missing dependencies, workspace failure, or failed begin after retry |

An empty existing root can succeed with zero files; missing roots cannot. Netcat has no begin connectivity check, so an unreachable service fails per-file with exit 1 rather than curl/GNU wget's begin-stage exit 2. Logging failures disable file logging with a warning; they do not alone fail uploads.

Curl attempts have a 10-second connect timeout and 60-second total timeout. GNU wget uses one internal attempt, no redirects, a 10-second connect timeout and 60-second idle-read timeout; this is not a total wall-clock deadline. Netcat attempts are wrapped in a 60-second timeout. Finite attempts do not imply a fixed deadline for the whole scan.

Responses are limited to 1 MiB (including headers for netcat). Each transport
output file also has an operating-system write limit of at most 2 MiB, including
headers and diagnostics. Oversized responses fail; error-body logging is limited
to 4 KiB. Large sample spooling is not subject to the response limit.

Collection is not an atomic snapshot. Files can change between enumeration, measurement and reading; hostile replacement/symlink races are not prevented. Directory listings consume temporary disk space. Without `stat`, measuring size reads whole files, even oversized ones. Mount detection depends on Linux `/proc/mounts`; do not assume equivalent detection elsewhere. POSIX syntax alone does not establish compatibility with untested ksh or legacy BusyBox versions.

## Basic Usage

From this directory:

```sh
busybox ash ./thunderstorm-collector-ash.sh \
  --server thunderstorm.example.internal --port 8080 \
  --dir /path/to/approved/input --source appliance-test \
  --max-age 14 --max-size-kb 2000
```

Use `sh` or `dash` instead only when that is the runtime being validated. Run `--help` for all options. Never use the broad default system roots for acceptance tests.

## Manual Acceptance Against Real THOR

### 1. Record Environment and Prepare Harmless Fixtures

Record PR #45, exact commit, tester, OS/architecture, shell/BusyBox version, selected upload-tool version, service version, HTTP/HTTPS and source. Keep licenses outside the repository. Never use production data for these tests.

Run from the directory containing the collector. Substitute the real service values. Examples use `sh`; change the invocation inside `collect` to `busybox ash` if `/bin/sh` is not already BusyBox ash.

```sh
COLLECTOR="$(pwd)/thunderstorm-collector-ash.sh"
SERVER=thunderstorm.example.internal
PORT=8080
SOURCE=manual-ash-acceptance-yourname
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-ash-acceptance.XXXXXX")
mkdir -p "$ROOT/input/nested" "$ROOT/scratch"
printf 'manual text\n' > "$ROOT/input/sample.txt"
printf '\000\001\377THUNDER\000\n' > "$ROOT/input/binary.bin"
: > "$ROOT/input/empty.bin"
printf 'nested\n' > "$ROOT/input/nested/nested.txt"
printf 'spaces\n' > "$ROOT/input/file with spaces.txt"
printf 'semicolon\n' > "$ROOT/input/semi;colon.txt"
printf 'comma\n' > "$ROOT/input/comma,name.txt"
printf 'quote\n' > "$ROOT/input/double\"quote.txt"

collect() {
  sh "$COLLECTOR" --server "$SERVER" --port "$PORT" \
    --source "$SOURCE" --max-age 0 --retries 1 \
    --no-log-file --no-progress "$@"
  code=$?
  printf 'exit_code=%s\n' "$code"
  return "$code"
}
```

Use a shell without `set -e` for intentionally failing cases. Keep output and exit codes. Use separate source identifiers when otherwise repeated runs would be mixed in the service.

### 2. Positive Uploads and Sync Mode

```sh
collect --dir "$ROOT/input"
collect --dir "$ROOT/input" --sync --source manual-ash-sync-yourname
```

Each run: exit 0, `scanned=8 submitted=8 skipped=0 failed=0 scan_errors=0`. Verify **eight new uploads per run**, including empty, binary and nested files. Compare received sizes/hashes, not just success messages. Inspect completion of asynchronous analyses in the service; `/api/getAsyncResults?id=<returned-sample-id>` is the native result endpoint. Collector exit 0 alone does not prove completion. If benign results contain no attribution fields, record source/filename verification as NOT TESTED until logs/UI/backend records confirm it.

### 3. TLS Trust

Set `SERVER` and `PORT` to the service's HTTPS listener before these commands.

```sh
collect --dir "$ROOT/input" --ssl --ca-cert /path/to/trusted-ca.pem
collect --dir "$ROOT/input" --ssl --ca-cert /path/to/unrelated-valid-ca.pem
```

Correct CA: exit 0 and eight matching uploads. Unrelated **valid** CA: no uploads, exit 2 during begin. A nonexistent certificate only tests path validation, not trust. Do not use `--insecure` for normal acceptance; if explicitly tested, record that verification was disabled. Netcat cannot run HTTPS cases.

### 4. Dry-run and Unreachable Service

Use a known closed local port, not a real service you intend to stop:

```sh
collect --dir "$ROOT/input" --server 127.0.0.1 --port 1 --dry-run
collect --dir "$ROOT/input" --server 127.0.0.1 --port 1
```

Dry-run: exit 0, eight would-submit messages, **no requests**. Unreachable: no uploads, visible error, exit 2 with curl/GNU wget or exit 1 with netcat. No indefinite hang. Server-side absence of requests is stronger evidence than a client summary alone.

### 5. Missing and Unreadable Paths

```sh
mkdir -p "$ROOT/errors/locked-dir"
printf 'readable\n' > "$ROOT/errors/ok.txt"
printf 'unreadable\n' > "$ROOT/errors/blocked.txt"
printf 'hidden\n' > "$ROOT/errors/locked-dir/hidden.txt"
chmod 000 "$ROOT/errors/blocked.txt" "$ROOT/errors/locked-dir"
collect --dir "$ROOT/errors" --dir "$ROOT/does-not-exist"
chmod 600 "$ROOT/errors/blocked.txt"
chmod 700 "$ROOT/errors/locked-dir"
collect --dir "$ROOT/does-not-exist" --dry-run
```

Run permissions as non-root. Expected: only `ok.txt` submitted, exit 1, `failed=1 scan_errors=2` (unreadable file, inaccessible subtree, missing root). All-missing dry-run: exit 1, `scan_errors=1`. Restore permissions even after interruption. Root results do not establish this behavior; record NOT TESTED rather than PASS.

### 6. Exact Size Limit and Age Filter

```sh
mkdir "$ROOT/size" "$ROOT/age"
dd if=/dev/zero of="$ROOT/size/limit.bin" bs=1024 count=1 2>/dev/null
cp "$ROOT/size/limit.bin" "$ROOT/size/too-large.bin"
printf x >> "$ROOT/size/too-large.bin"
collect --dir "$ROOT/size" --max-size-kb 1
printf 'recent\n' > "$ROOT/age/recent.txt"
printf 'old\n' > "$ROOT/age/old.txt"
touch -t 202001010000 "$ROOT/age/old.txt"
collect --dir "$ROOT/age" --max-age 1
collect --dir "$ROOT/age" --max-age 0
```

All exit 0. Size: one 1024-byte upload, 1025-byte file skipped. Age 1: recent only. Age 0: both. Confirm excluded files are absent from that run's backend records.

### 7. Log, Workspace and Symlink Exclusions

```sh
printf 'outside - must stay local\n' > "$ROOT/outside.txt"
ln -s "$ROOT/outside.txt" "$ROOT/input/link.txt"
TMPDIR="$ROOT/input" collect --dir "$ROOT/input" \
  --log-file "$ROOT/input/collector.log"
```

Expected: exit 0, only eight original payloads. No outside target, log, file list, marker or multipart scratch data uploaded. No `thunderstorm.*` workspace remains after exit. The log remains for inspection.

### 8. Unsupported Newline Filename Fails Safely

```sh
mkdir "$ROOT/newline"
name=$(printf 'line\nbreak.txt')
printf 'unsupported path\n' > "$ROOT/newline/$name"
printf 'readable\n' > "$ROOT/newline/ok.txt"
collect --dir "$ROOT/newline"
```

Expected: exit 1, only `ok.txt` uploaded, `scan_errors=1`, explicit unsupported-path warning. Never upload a path fragment instead of the actual file.

### 9. Validate the Deployment Transport

Repeat positive binary/special-name tests on the actual appliance where curl is absent. Record the selected tool with `--debug`. A test PATH must retain required utilities; removing `/usr/bin` can invalidate the environment.

- GNU wget: eight matching payloads; repeat HTTPS/CA checks if used in deployment.
- BusyBox nc + timeout: eight matching payloads over HTTP, no markers; repeat the unreachable-service test. Actual nc options vary by build.
- BusyBox wget without a safe alternative: exit 2 before uploads. Install curl, GNU wget or nc + timeout; warnings followed by corrupted submissions are not acceptable.

### 10. Interruption and Server Failures

Interrupt an isolated fixture run with Ctrl-C or SIGTERM, not a broad system-directory scan. Expected: exit 1 and workspace cleanup. Interrupted markers are best-effort and only available with curl/GNU wget and a supporting service. A client message does not prove receipt.

Do not disrupt real THOR to simulate HTTP 500/503 or truncated responses. The regression suite injects those failures locally, checks retry bounds, and rejects incomplete responses despite a 2xx status. A service returning 404/501 for markers can pass uploads; record marker functionality as NOT SUPPORTED.

### 11. Acceptance Record and Cleanup

For each case record PASS, FAIL, NOT SUPPORTED or NOT TESTED, with commit/runtime/transport, exit, summary, upload count, hashes and backend evidence. Fix supported failures before approval; agree on intentional limitations. Agent-run tests do not replace human sign-off on the target appliance.

After retaining evidence and restoring permissions:

```sh
rm -rf -- "$ROOT"
```

## Automated Tests

From the repository root, with Python 3 on the **test host**, not the collector target:

```sh
COLLECTOR_SH=/bin/dash python3 -B scripts/tests/test_ash_robustness.py
COLLECTOR_SH='/bin/busybox ash' python3 -B scripts/tests/test_ash_robustness.py
ASH_SHELL='/bin/busybox ash' sh scripts/tests/run_ash_regression_tests.sh
THUNDERSTORM_TEST_COLLECTORS=ash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

Shared e2e requires Bash and GNU-compatible test-host utilities. Build the stub for your OS/architecture; a Linux binary does not run on macOS. Use a Unix host with curl/GNU wget for the complete matrix and non-root for permissions. CI runs under dash and BusyBox ash. Only synthetic local fixtures are used; no THOR license is needed for regression/stub suites.
