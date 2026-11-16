# Python Collector Testing

How to accept the [Python collectors](README.md) before deployment: manual cases
against a real Thunderstorm service, then the automated tests.

## Validation Status

The [8 October 2026 acceptance report](../../docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)
records HTTP/HTTPS checks against real THOR with Python 3.9.6 on macOS and actual
Python 3.4.10 and 2.7.18 in containers. Evidence applies to the exact revisions
and assets recorded there. It does not establish ESXi or every legacy OS/SSL
combination's compatibility.

## Manual Acceptance Against a Real Service

Follow the [manual test preparation](../MANUAL_TESTING_GUIDE.md#manual-test-preparation)
and [acceptance record](../MANUAL_TESTING_GUIDE.md#acceptance-record) guidance. Record the exact collector revision or asset
hash, OS/architecture and interpreter/SSL versions. Repeat the applicable cases
below on each interpreter and target you intend to deploy.

### 1. Isolated Setup

From this folder, substitute service values. Use a shell without `set -e` for
expected failures. On Windows use equivalent isolated files and Python arguments.

```sh
PYTHON=python3
COLLECTOR="$(pwd)/thunderstorm-collector.py"
# Legacy: PYTHON=python2; COLLECTOR="$(pwd)/thunderstorm-collector-py2.py"
SERVER=thunderstorm.example.internal
PORT=8080
SOURCE=manual-python-yourname
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-python.XXXXXX")
mkdir -p "$ROOT/input/sub"
printf 'text\n' > "$ROOT/input/plain.txt"
printf '\000\001\377THUNDER\n' > "$ROOT/input/binary.bin"
: > "$ROOT/input/empty.bin"
printf 'nested\n' > "$ROOT/input/sub/nested.txt"
printf 'spaces\n' > "$ROOT/input/file with spaces.txt"
printf 'semicolon\n' > "$ROOT/input/semi;colon.txt"
printf 'quote\n' > "$ROOT/input/double\"quote.txt"
collect() {
  "$PYTHON" "$COLLECTOR" -s "$SERVER" -p "$PORT" --source "$SOURCE" \
    --max-age 0 --retries 1 --no-dry-run --no-progress "$@"
  code=$?; printf 'exit_code=%s\n' "$code"; return "$code"
}
```

### 2. No-network Dry-run and Unreachable Service

```sh
collect -d "$ROOT/input" --dry-run -s 127.0.0.1 -p 1
collect -d "$ROOT/input" -s 127.0.0.1 -p 1
```

Dry-run: exit 0, seven would-submit lines, `Submitted: 0 Would submit: 7` in the
summary, zero requests. Live: exit 2 at begin,
zero uploads and connection errors. Port 1 must actually be closed. Use an
external watchdog for slow networks; idle timeouts are not run deadlines.

### 3. Positive Upload

```sh
collect -d "$ROOT/input"
```

Expect exit 0 and seven accepted files including empty. Verify stored SHA-256/size
of every payload, wait for async completion, check source if exposed (otherwise
NOT OBSERVABLE). Optional marker 404/501 is acceptable. Empty-file rejection is
a real backend failure, not a successful skip. Change SOURCE for subsequent runs.

### 4. Missing Roots and Repeated Options

```sh
collect -d "$ROOT/input" -d "$ROOT/missing"
collect -d "$ROOT/missing"
```

Mixed: exit 1, seven uploads, one scan error. All missing: exit 2/no requests.
The second `-d` must not discard the first.

### 5. Permissions (Non-root/Non-administrator)

```sh
mkdir -p "$ROOT/permissions/blocked-dir"
printf readable > "$ROOT/permissions/ok.txt"
printf blocked > "$ROOT/permissions/blocked.txt"
chmod 000 "$ROOT/permissions/blocked.txt" "$ROOT/permissions/blocked-dir"
collect -d "$ROOT/permissions"
chmod 600 "$ROOT/permissions/blocked.txt"
chmod 700 "$ROOT/permissions/blocked-dir"
```

Exit 1, only ok.txt accepted, one failed file and one scan error. Always restore
permissions. Root results do not validate this test.

### 6. Exact Size and Age

```sh
mkdir "$ROOT/size" "$ROOT/age"
dd if=/dev/zero of="$ROOT/size/limit.bin" bs=1024 count=1 2>/dev/null
cp "$ROOT/size/limit.bin" "$ROOT/size/over.bin"
printf x >> "$ROOT/size/over.bin"
collect -d "$ROOT/size" --max-size-kb 1
printf recent > "$ROOT/age/recent.txt"
printf old > "$ROOT/age/old.txt"
touch -t 202001010000 "$ROOT/age/old.txt"
collect -d "$ROOT/age" --max-age 1
collect -d "$ROOT/age" --max-age 0
```

Exit 0 each. Size: only 1024, not 1025 bytes. Age 1: recent only; age 0: both.

### 7. Links and Special Names

```sh
printf outside > "$ROOT/outside.txt"
ln -s "$ROOT/outside.txt" "$ROOT/input/link.txt"
ln -s "$ROOT/input" "$ROOT/input/loop"
collect -d "$ROOT/input"
```

Still seven uploads, exit 0; no outside data/loop. In fresh fixtures add Unicode
and literal-newline names and verify all payload hashes and sanitized headers.

### 8. TLS

Use a test HTTPS service, its actual CA paths and the correct PORT:

```sh
collect -d "$ROOT/input" --tls
collect -d "$ROOT/input" --tls --ca-cert /path/to/unrelated-valid-ca.pem
collect -d "$ROOT/input" --tls --ca-cert /path/to/correct-ca.pem
collect -d "$ROOT/input" --tls --insecure
```

For private untrusted certificates: first two exit 2/no uploads; correct CA and
explicit insecure exit 0/seven uploads. Public trust can legitimately pass the
first case. Python <2.7.9 must refuse verified HTTPS. Do not install test CAs
globally; remove private keys afterwards.

### 9. Interruption and Injected Failures

Interrupt a slow run: exit 1, no normal end marker, best-effort interrupted
marker if supported. Do not disrupt a shared real service for failure injection.
The isolated regression suite covers 503 bounds, end HTTP 500, incomplete 2xx,
malformed marker JSON and SIGTERM on the actual interpreters:

```sh
python3 -B ../tests/test_python_robustness.py
python2 -B ../tests/test_python_robustness.py
```

Both must execute without unexpected skips. Modern CI cannot establish every
old OS/SSL build's compatibility. Keep remaining target-system checks explicit.

## Automated Tests

Use the [testing overview](../../docs/COLLECTOR_TESTING_OVERVIEW.md) for stub setup
and shared options. From the repository root, select each installed interpreter:

```sh
THUNDERSTORM_TEST_COLLECTORS=python3 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 scripts/tests/run_e2e_compliance.sh /path/to/stub
THUNDERSTORM_TEST_COLLECTORS=python2 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 scripts/tests/run_e2e_compliance.sh /path/to/stub
```
