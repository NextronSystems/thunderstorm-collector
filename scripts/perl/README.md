# Perl Collector

Use on Unix-like or legacy hosts where Perl and LWP are available. The standalone script has a Perl 5.8.1 syntax floor and requires LWP::UserAgent 6+, HTTP::Request, JSON::PP and Encode. JSON::PP is core on Perl 5.14+; install it separately on older builds. HTTPS additionally requires LWP::Protocol::https and IO::Socket::SSL with a usable CA store. Tests on modern Perl do not certify every 5.8/SSL build; validate the actual target.

## Capability Profile

- Iterative recursive regular-file collection, binary/empty/Unicode/newline names. Symlink entries and special files are skipped; explicit roots resolve physically.
- Built-in exclusions: /proc, /dev, /sys, /run, /snap, /.snapshots, Linux detected special/network mounts, known cloud folders, /mnt trees, .dat, .npm and .lck paths. These are best effort, not a security boundary.
- Default age 14 days; --max-age 0..36500, zero disables filtering; otherwise mtime compared to start minus N times 86400 seconds.
- Default size 2048 KiB; --max-size-kb 1..204800 includes exact limit. Bounded in-memory snapshot precedes network access; multipart construction needs several times the configured file size in RAM. Replaced/changed/unreadable files fail; newly oversized files are skipped. Not a filesystem-wide atomic snapshot.
- Async /api/checkAsync, --sync uses /api/check. Complete 2xx means accepted, not finished analysis; no polling/resume/deduplication. Lost responses/retries can duplicate uploads.
- Optional markers: 404/501 nonfatal without scan ID; real JSON parsing rather than regex extraction. Begin retries once after two seconds, then exits 2; failed end exits 1. SIGINT/SIGTERM sets an interruption flag; network I/O completes or times out before best-effort interrupted marker and exit 1. No further uploads after interruption is observed.
- --retries 1..10 counts total attempts; 503 integer Retry-After caps at 120 seconds, exponential delays at 60. No automatic redirects or environment-proxy discovery.
- Upload timeout 30 seconds and marker timeout 10 are LWP idle-I/O limits, not whole-run deadlines. Response limit 1 MiB; aborted or length-incomplete 2xx responses fail.
- --ssl verifies hostname and peer explicitly; --ca-cert FILE selects a CA; --insecure is explicit bypass. TLS-only options without --ssl are rejected, never silently converted to plaintext.
- Dry-run sends no network requests, including markers, and does not prove file readability. Repeated --dir/-d options accumulate. Default root is /; use explicit approved roots.
- Source is UTF-8 encoded in the query and JSON. Invalid filename bytes are replaced in metadata only; payloads remain unchanged. Port 1..65535; DNS/IPv4 or bracketed IPv6, subject to installed LWP/SSL support.

| Exit | Meaning |
|---|---|
| 0 | All eligible files accepted or successful dry-run; intentional skips allowed |
| 1 | Failed files, traversal/partial-root errors, interruption or end-marker failure |
| 2 | Invalid config/dependencies, no valid roots or failed begin |

Unreadable directories count as Scan errors; unreadable selected files as Failed. Existing empty roots can succeed; missing roots cannot. Missing Perl/modules can fail before the script starts with the interpreter's own exit code (commonly 255); check dependencies first. Legacy Perl/SSL and Windows builds require their own target-system acceptance. Transport limits follow the [LWP documentation](https://metacpan.org/pod/LWP::UserAgent).

## Manual Acceptance

Record PR #47, exact commit, OS/architecture, Perl/LWP/SSL/service versions,
outputs and exit codes. Repeat applicable cases on the actual target runtime. Mark each
PASS/FAIL/NOT SUPPORTED/NOT TESTED. Never scan default system roots or production
data for acceptance. Keep licenses outside fixtures and Git.

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
    --max-age 0 --retries 1 --no-progress "$@"
  code=$?; printf 'exit_code=%s\n' "$code"; return "$code"
}
```

### 2. Positive and Sync

```sh
collect -d "$ROOT/input"
SOURCE=manual-perl-sync-yourname
collect -d "$ROOT/input" --sync
```

Each: exit 0, seven accepted files including empty. Verify stored SHA-256/size
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
malformed marker JSON and SIGTERM on the actual interpreters:

```sh
python3 -B ../tests/test_perl_robustness.py
```

The suite must execute without unexpected skips. Modern CI cannot establish every
old OS/SSL build's compatibility. Keep remaining target-system checks explicit.

## Shared Stub E2E

From repository root with a stub compiled for the test host:

```sh
THUNDERSTORM_TEST_COLLECTORS=perl THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 scripts/tests/run_e2e_compliance.sh /path/to/stub
```
