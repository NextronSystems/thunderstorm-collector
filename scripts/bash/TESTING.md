# Bash Collector Testing

How to accept the [Bash collector](README.md) before deployment: manual cases
against a real Thunderstorm service, then the automated tests.

## Manual Acceptance Against a Real Service

Test the exact collector revision to be deployed, from the directory containing
its standalone file. Follow the shared [manual test preparation](../MANUAL_TESTING_GUIDE.md#manual-test-preparation)
and [acceptance record](../MANUAL_TESTING_GUIDE.md#acceptance-record); the cases below
supply the Bash-specific commands and expected results.

### 1. Prepare an Isolated Fixture

Run these in Bash. Replace host/port with the real test service. For HTTPS, set
`TRANSPORT` to the example below, using a CA that actually trusts the service.
Never add a real license, credentials, or investigation evidence to this fixture.

```bash
SERVER=thunderstorm.example.internal
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
    --source "$RUN_ID-$CASE" --max-age 0 --no-dry-run --no-log-file --no-progress "$@"
  rc=$?
  printf 'exit=%s\n' "$rc"
  return "$rc"
}
```

Record the commit, OS, Bash version (`bash --version`), upload tool/version,
service version, source, output, and exit code per case.

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
A service without markers answers HTTP 404/501; with `--debug`, as here, a debug
line names the status, and the run still succeeds. If your service rejects empty
samples, document the limitation and observed nonzero result instead of counting
this case as passed.

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

For shared setup and test-host requirements, see the [testing overview](../../docs/COLLECTOR_TESTING_OVERVIEW.md#running-tests-locally).
Run these collector-specific commands from the repository root:

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
