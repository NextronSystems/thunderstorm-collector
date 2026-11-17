# POSIX sh / BusyBox ash Collector Testing

How to accept the [ash collector](README.md) before deployment: manual cases
against a real Thunderstorm service, then the automated tests.

## Manual Acceptance Against a Real Service

Test the exact collector revision to be deployed. Follow the shared [manual test preparation](../MANUAL_TESTING_GUIDE.md#manual-test-preparation)
and [acceptance record](../MANUAL_TESTING_GUIDE.md#acceptance-record); the cases below
supply the ash-specific commands and expected results.

### 1. Record Environment and Prepare Harmless Fixtures

Record the exact commit, tester, OS/architecture, shell/BusyBox version, selected upload-tool version, service version, HTTP/HTTPS and source.

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
    --no-dry-run --no-log-file --no-progress "$@"
  code=$?
  printf 'exit_code=%s\n' "$code"
  return "$code"
}
```

Use a shell without `set -e` for intentionally failing cases. Keep output and exit codes. Use separate source identifiers when otherwise repeated runs would be mixed in the service.

### 2. Positive Uploads

```sh
collect --dir "$ROOT/input"
```

Expect exit 0 and `scanned=8 submitted=8 skipped=0 failed=0 scan_errors=0`. Verify **eight new uploads**, including empty, binary and nested files. Compare received sizes/hashes, not just success messages. Inspect completion of asynchronous analyses in the service; `/api/getAsyncResults?id=<returned-sample-id>` is the native result endpoint. Collector exit 0 alone does not prove completion. If benign results contain no attribution fields, record source/filename verification as NOT TESTED until logs/UI/backend records confirm it.

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

Dry-run: exit 0, eight would-submit messages, **no requests**. Unreachable: no uploads, visible error, exit 2 with curl/GNU wget or exit 1 with netcat. With netcat, three files fail before the collector polls `/api/status` for the server wait (default 600 s); add `--server-wait 0` to end this case at once. No indefinite hang. Server-side absence of requests is stronger evidence than a client summary alone.

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

Repeat positive binary/special-name tests on the actual appliance where curl is absent. For live runs, `--debug` prints `Upload transport: curl`, `Upload transport: wget` (GNU wget), or `Upload transport: nc`; record that line. Dry-run selects no transport and makes no network requests. A test PATH must retain required utilities; removing `/usr/bin` can invalidate the environment.

- GNU wget: eight matching payloads; repeat HTTPS/CA checks if used in deployment.
- BusyBox nc + timeout: eight matching payloads over HTTP, no markers; repeat the unreachable-service test. Actual nc options vary by build.
- BusyBox wget without a safe alternative: exit 2 before uploads. Install curl, GNU wget or nc + timeout; warnings followed by corrupted submissions are not acceptable.

### 10. Interruption and Server Failures

Interrupt an isolated fixture run with Ctrl-C, SIGTERM, SIGHUP or SIGQUIT, not a broad system-directory scan. Expected: exit 1 and workspace cleanup. Interrupted markers are best-effort and only available with curl/GNU wget and a supporting service. A client debug message does not prove receipt.

Do not disrupt real THOR to simulate HTTP 500/503 or truncated responses. The regression suite injects those failures locally, checks retry bounds, and rejects incomplete responses despite a 2xx status. A service returning 404/501 for markers can pass uploads; `--debug` then shows `not supported (HTTP 404)`. Record marker functionality as NOT SUPPORTED.

### 11. Acceptance Record and Cleanup

For each case record PASS, FAIL, NOT SUPPORTED or NOT TESTED, with commit/runtime/transport, exit, summary, upload count, hashes and backend evidence. Fix supported failures before approval; agree on intentional limitations. Agent-run tests do not replace human sign-off on the target appliance.

After retaining evidence and restoring permissions:

```sh
rm -rf -- "$ROOT"
```

## Automated Tests

For shared setup and test-host requirements, see the [testing overview](../../docs/COLLECTOR_TESTING_OVERVIEW.md#running-tests-locally).
Run these collector-specific commands from the repository root, with Python 3 on
the **test host**, not the collector target:

```sh
COLLECTOR_SH=/bin/dash python3 -B scripts/tests/test_ash_robustness.py
COLLECTOR_SH='/bin/busybox ash' python3 -B scripts/tests/test_ash_robustness.py
ASH_SHELL='/bin/busybox ash' sh scripts/tests/run_ash_regression_tests.sh
THUNDERSTORM_TEST_COLLECTORS=ash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

CI runs the suite under dash, under BusyBox ash with Ubuntu utilities, and
under BusyBox ash with a BusyBox-first `PATH` (`busybox --install -s DIR`), in
which every utility the collector uses is a BusyBox applet; curl and GNU wget
still come from Ubuntu there. BusyBox features are compile-time options, so
validate the actual appliance shell, utilities and selected transport separately.
Run permission cases as non-root.
