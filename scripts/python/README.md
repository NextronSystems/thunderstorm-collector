# Python Collectors

Prefer `thunderstorm-collector.py` (Python 3.4+). Use the standalone
`thunderstorm-collector-py2.py` only on legacy hosts with Python 2.7.
Both need only the standard library. Python 2 is end-of-life.

## Capability Profile

- Recursive regular files; symlink entries/special files are skipped. Explicit
  roots resolve physically. All extensions except built-in exclusions: `/mnt`
  trees, `.dat`, `.npm`, and VM artifacts ending in `.vmdk`, `.vswp`, `.nvram`,
  `.vmsd`, `.lck`. Cloud folders and Linux network/special mounts are best-effort
  exclusions, not a security boundary. Explicit excluded roots remain excluded.
- Age defaults to 14 days; `--max-age 0..36500`, zero disables filtering.
  Positive values compare mtime to run start minus N times 86400 seconds.
- Size defaults to 2048 KiB; `--max-size-kb 1..204800`, exact limit included.
  Binary/empty/Unicode/newline files work. Unsafe multipart filename characters
  are sanitized, not payload bytes. Metadata may not survive the backend verbatim.
- Bounded in-memory snapshots before network access; allow selected size plus
  overhead in RAM. Changed/replaced/unreadable files fail. Files that grow past
  selectors before reading are skipped. No atomic filesystem snapshot or defense
  against privileged races.
- Async `/api/checkAsync`; `--sync` selects `/api/check`. Complete 2xx means
  accepted, not completed analysis. No polling, resume or deduplication.
- Optional markers: 404/501 is nonfatal, without scan ID. Begin retries once
  after two seconds then exits 2; end failure exits 1. SIGINT/SIGTERM exits 1
  with a best-effort interrupted marker for a live started collection.
- `--retries 1..10` counts total attempts, including first. 503 Retry-After
  integer seconds clamp to 0..120; other exponential delays cap at 60 seconds.
  Lost responses/retries can duplicate samples.
- Socket idle-I/O timeouts: uploads 30 seconds, markers 10. **Not whole-attempt
  or run deadlines**. Responses over 1 MiB or incomplete responses fail.
- TLS verifies CA/hostname; custom CA via `--tls --ca-cert FILE`, explicit bypass
  via `--tls --insecure`. Python before 2.7.9 refuses verified HTTPS rather than
  silently disabling verification. Old SSL protocol support can still limit it.
- Dry-run never contacts the service. It enumerates/selects but does not prove
  payload readability or TLS connectivity. Repeated `-d` options accumulate.
- Port 1..65535; IPv4/DNS and runtime-supported IPv6. Progress is count-based;
  `--debug` is accepted for compatibility, with path errors already always shown.

| Exit | Meaning |
|---|---|
| 0 | All eligible files accepted, or successful dry-run; intentional skips allowed |
| 1 | Failed files, traversal/partial-root errors, interruption or failed end marker |
| 2 | Invalid config/TLS setup, no valid roots or failed begin |

Unreadable directories count as `Scan errors`; unreadable selected files as
`Failed`. Empty existing roots may succeed; missing roots cannot. Actual legacy
SSL and Windows paths require target-system verification, not modern CI inference.

## Manual Acceptance

Record PR #46, exact commit, OS/architecture, interpreter/SSL/service versions,
outputs and exit codes. Repeat applicable cases on both interpreters. Mark each
PASS/FAIL/NOT SUPPORTED/NOT TESTED. Never scan default system roots or production
data for acceptance. Keep licenses outside fixtures and Git.

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
    --max-age 0 --retries 1 --no-progress "$@"
  code=$?; printf 'exit_code=%s\n' "$code"; return "$code"
}
```

### 2. Positive and Sync

```sh
collect -d "$ROOT/input"
SOURCE=manual-python-sync-yourname
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

Dry-run: exit 0, seven would-submit lines, `Submitted: 0 Would submit: 7` in the
summary, zero requests. Live: exit 2 at begin,
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

## Shared Stub E2E

From repository root with a stub binary compiled for the host:

```sh
THUNDERSTORM_TEST_COLLECTORS=python3 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 scripts/tests/run_e2e_compliance.sh /path/to/stub
THUNDERSTORM_TEST_COLLECTORS=python2 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  THUNDERSTORM_TEST_REQUIRE_ALL=1 scripts/tests/run_e2e_compliance.sh /path/to/stub
```
