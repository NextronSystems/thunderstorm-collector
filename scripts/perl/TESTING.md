# Perl Collector Testing

How to accept the [Perl collector](README.md) before deployment: manual cases
against a real Thunderstorm service, then the automated tests.

## Manual Acceptance Against a Real Service

Test the exact collector revision to be deployed. Follow the shared [manual test preparation](../MANUAL_TESTING_GUIDE.md#manual-test-preparation)
and [acceptance record](../MANUAL_TESTING_GUIDE.md#acceptance-record). Record the
commit, OS/architecture, Perl/LWP/SSL/service versions, outputs and exit codes.
Repeat the cases below on the actual target runtime.

### 1. Isolated Setup

From this folder, substitute service values. Use a shell without `set -e` for
expected failures. Windows Perl builds require equivalent isolated fixtures and path tests.

```sh
PERL=perl
COLLECTOR="$(pwd)/thunderstorm-collector.pl"
SERVER=thunderstorm.example.internal
PORT=8080
SOURCE=manual-perl-yourname
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-perl.XXXXXX")
mkdir -p "$ROOT/input/sub"
printf 'text\n' > "$ROOT/input/plain.txt"
printf '\000\001\377THUNDER\n' > "$ROOT/input/binary.bin"
: > "$ROOT/input/empty.bin"
printf 'nested\n' > "$ROOT/input/sub/nested.txt"
printf 'spaces\n' > "$ROOT/input/file with spaces.txt"
printf 'semicolon\n' > "$ROOT/input/semi;colon.txt"
printf 'quote\n' > "$ROOT/input/double\"quote.txt"
collect() {
  "$PERL" "$COLLECTOR" -s "$SERVER" -p "$PORT" --source "$SOURCE" \
    --max-age 0 --retries 1 --no-dry-run --no-progress "$@"
  code=$?; printf 'exit_code=%s\n' "$code"; return "$code"
}
```

### 2. Positive Upload

```sh
collect -d "$ROOT/input"
```

Expect exit 0 and seven accepted files including empty. Verify stored SHA-256/size
of every payload, wait for async completion, check source if exposed (otherwise
NOT OBSERVABLE). Optional marker 404/501 is acceptable. Empty-file rejection is
a real backend failure, not a successful skip. Change SOURCE for subsequent runs.

### 3. No-network Dry-run and Unreachable Service

```sh
collect -d "$ROOT/input" --dry-run -s 127.0.0.1 -p 1
collect -d "$ROOT/input" -s 127.0.0.1 -p 1
```

Dry-run: exit 0, seven would-submit lines, zero requests. Live: exit 2 at begin,
zero uploads and connection errors. Port 1 must actually be closed. Use an
external watchdog for slow networks; idle timeouts are not run deadlines.

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
collect -d "$ROOT/input" --ssl
collect -d "$ROOT/input" --ssl --ca-cert /path/to/unrelated-valid-ca.pem
collect -d "$ROOT/input" --ssl --ca-cert /path/to/correct-ca.pem
collect -d "$ROOT/input" --ssl --insecure
```

For private untrusted certificates: first two exit 2/no uploads; correct CA and
explicit insecure exit 0/seven uploads. Public trust can legitimately pass the
first case. Missing HTTPS modules must fail visibly. Do not install test CAs
globally; remove private keys afterwards.

### 9. Interruption and Injected Failures

Interrupt a slow run: exit 1, no normal end marker, best-effort interrupted
marker if supported. Do not disrupt a shared real service for failure injection.
The isolated regression suite covers 503 bounds, end HTTP 500, incomplete 2xx,
malformed marker JSON, a lost server (wait, resume, stop) and SIGTERM on the
actual interpreters:

```sh
python3 -B ../tests/test_perl_robustness.py
```

The suite must execute without unexpected skips. Modern CI cannot establish every
old OS/SSL build's compatibility. Keep remaining target-system checks explicit.

## Automated Tests

For shared setup and test-host requirements, see the [testing overview](../../docs/COLLECTOR_TESTING_OVERVIEW.md#shared-stub-integration).
Run these collector-specific commands from the repository root:

```sh
THUNDERSTORM_TEST_COLLECTORS=perl THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 scripts/tests/run_e2e_compliance.sh /path/to/stub
```

For the separate large-payload acceptance check:

```sh
STUB_BIN_PATH=/path/to/stub bash scripts/tests/test_perl_large.sh
```

This starts its own stub on a temporary port and uploads a generated file slightly
larger than 3 MiB. It requires a successful collector exit and exactly one current-run
audit entry with the expected source, unique filename, size, and SHA-256. Existing
services/audit logs are not reused. The owned process and fixtures are removed on
success and failure. An optional `STUB_LOG` must name a new file and is retained;
otherwise the audit stays in the temporary workspace and is removed with it.
