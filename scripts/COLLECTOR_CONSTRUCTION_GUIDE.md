# Build a THOR Thunderstorm Collector

Use this blueprint to commission a collector in a different language, runtime,
operating system or architecture. A collector reads approved local files and
uploads them to THOR Thunderstorm for analysis. It does not scan locally and
does not need a THOR license on the collecting host.

Start with the upload protocol and an explicit capability profile, not a
translation of another collector's source. A minimal, honest implementation is
preferable to silently weakening security or pretending a legacy runtime has
features it cannot provide. This document contains no collector implementation.

## 1. Specify the Target Before Implementation

Record these inputs in the new collector's README:

| Input | Decision to record |
|---|---|
| Target | OS, architecture, exact language/runtime version and available RAM |
| Deployment | One standalone file or explicitly declared companion files |
| Dependencies | Allowed libraries, HTTP tools, TLS support and installation policy |
| Service | Authorized host, port, HTTP/HTTPS, service version and authentication policy |
| Roots | Explicit approved local directories; never assume a broad system scan is safe |
| Selection | Recursion, extensions, size units/limit, age semantics and exclusions |
| Transport | Async/sync, finite retries, timeouts and response-size limits |
| Optional features | Collection markers, dry-run, signals, logging, CA configuration |
| Restrictions | Unsupported filenames, mounts, paths, TLS modes or runtime features |
| Evidence | Actual runtime tests available and tests requiring human acceptance |

The reviewed script profiles have no built-in HTTP authentication options. Do
not invent credentials, disable a gateway's authentication or place secrets in
URLs. An authenticated deployment needs an explicitly designed, tested extension.
HTTP sends sample contents unencrypted; choose HTTPS or an approved isolated
network according to the deployment's sensitivity.

### Minimum Useful Core

The core is explicit configuration, truthful file selection, binary-safe upload,
finite attempts, visible failures and a nonzero result when an eligible transfer
fails. TLS is optional on an HTTP-only target; if HTTPS is offered, certificate
and hostname verification must be the default. Unsupported HTTPS must fail
clearly rather than downgrade to plaintext.

Dry-run, markers, synchronous uploads, custom CAs, interruption handling, syslog,
extension filters, deduplication, polling and resume are separate capabilities.
Decide which to implement. Do not make an optional feature a hidden prerequisite
for a service or platform that cannot support it.

### Existing Profiles Are Examples, Not One Universal Contract

These profiles describe the separately reviewed replacement scripts. Read the
collector's own README at the exact revision being deployed.

| Profile | Intended target and important differences |
|---|---|
| [Bash](bash/README.md) | Bash 3.2+, curl or GNU wget. All extensions; KiB size units. Optional markers. Wget uses idle-read limits, not a total deadline. HTTP 503 has a separate bounded busy-response budget. |
| [POSIX sh / ash](ash/README.md) | Minimal Unix/BusyBox. All extensions; KiB units. curl/GNU wget preferred. nc plus timeout is HTTP-only, accepts only a restricted complete Content-Length response, and omits markers. BusyBox wget alone is refused. Literal-newline paths are unsupported and reported, never split into other paths. |
| [Python 3 and 2](python/README.md) | Standalone standard-library scripts, Python 3.4+ or 2.7. KiB units, optional markers, bounded in-memory snapshots. Python before 2.7.9 refuses verified HTTPS. Socket timeouts are idle-I/O limits. |
| [Perl](perl/README.md) | Perl 5.8.1 syntax floor, LWP 6+, JSON::PP and Encode; additional HTTPS modules. KiB units; optional markers. Signal handling may be deferred until network I/O returns. The syntax floor is not certification of every old module/SSL combination. |
| [PowerShell 3+ and 2](powershell/README.md) | Separate standalone files, full .NET/Add-Type. MiB units; extension allowlist by default. PS2 marker parsing needs System.Web.Extensions or markers are explicitly disabled. Custom CA/insecure options require a per-request callback on .NET 4.5+; old CLR fails closed. |
| [Windows Batch](batch/README.md) | Single cmd/JScript hybrid, enabled WSH, FileSystemObject, ADODB.Stream and trusted curl 8.4+. Size units are bytes; roots required. No markers, resume, polling or insecure TLS. ADODB reading is not hard memory-bounded against a growing file. |

Python 2 means an actual Python 2 run, not a Python 3 run of a similar file.
PowerShell 5.1/7 execution of the PS2 file is not an actual PowerShell 2 test.
Test BusyBox ash and its utilities, not just dash. OS, TLS libraries and external
tool builds matter as much as language syntax.

## 2. Implement the Upload Protocol

### Endpoint and Query

| Operation | Request | Meaning |
|---|---|---|
| Async submission | POST `/api/checkAsync?source=<encoded-source>` | Accepted for asynchronous analysis |
| Sync submission | POST `/api/check?source=<encoded-source>` | Analysis response returned with the request |
| Optional result inspection | GET `/api/getAsyncResults?id=<encoded-job-id>` | Inspect one asynchronous sample job |
| Optional service inspection | GET `/api/status` | Service counters, not proof of one file's attribution |
| Optional collection lifecycle | POST `/api/collection` | Begin/end/interrupted markers where supported |

Use the native `/api/...` paths. The older repository mock/API-proxy adapter's
`/api/v1/...` rewriting is test infrastructure, not the native wire contract.

Validate scheme, host and port before network activity. Ports are 1..65535.
Separate a host/IP parameter from a full URL unless a full-URL interface is
explicitly designed. Reject embedded credentials, paths, query fragments,
control characters and shell metacharacter interpretation. IPv6 support is a
profile decision; support URL brackets correctly or reject it explicitly.

`source` is the collecting host/run identifier, not the server's hostname. Encode
its UTF-8 bytes as one query value, including spaces, ampersands, percent signs,
plus signs and Unicode. An example encoded value is
`manual%20host%20%C3%A4`. Never concatenate an unescaped source or scan ID into a URL.

### Multipart Body

Send one file per request, using `multipart/form-data`, field name **file**, and
`Content-Type: application/octet-stream` for that part. Include the original
file's bytes unchanged, including NUL, 0xff, CR/LF and zero-length payloads.
Do not text-decode, base64-encode, newline-normalize or implicitly append bytes
to the sample. Multipart separators are additional framing, not sample data.

The following is a schematic request, not a copy-paste HTTP fixture. Every shown
line break in headers/framing is CRLF; replace bracketed placeholders and compute
Content-Length from the complete encoded body, not character counts.

```http
POST /api/checkAsync?source=manual%20host%20%C3%A4 HTTP/1.1
Host: thunderstorm.example.internal:8080
Content-Type: multipart/form-data; boundary=ts-random-boundary
Content-Length: <complete-body-byte-count>

--ts-random-boundary
Content-Disposition: form-data; name="file"; filename="/approved/input/sample.bin"
Content-Type: application/octet-stream

<raw-sample-bytes>
--ts-random-boundary--
```

There is one framing CRLF after the raw bytes before the closing boundary, even
for an empty sample. Prefer a correct runtime multipart encoder; otherwise
verify framing independently. Choose a sufficiently unpredictable boundary and
avoid collision with sample contents when constructing a body yourself. Publish
an exact byte length or explicitly verify the server accepts another transfer
framing; do not assume legacy backends accept chunked request bodies.

Filename metadata is a client-side path used for attribution and file-type
context; do not substitute a random scratch filename. Sanitize quotes,
backslashes, semicolons and control characters so a path cannot inject headers.
Keep the useful basename/extension. Existing profiles differ in full-path versus
basename presentation. Document the choice and verify the server's parser;
do not promise it retains the original path verbatim. Encoding or sanitizing
metadata must never change payload bytes. Reject or explicitly replace invalid
filename encodings in metadata only. Never run a filename as shell syntax.

### Successful Transport Is Not Completed Analysis

A submission is successful only after a **complete** HTTP 2xx response and no
transport error. Reject truncated Content-Length bodies, protocol errors and
responses exceeding a declared cap. The focused replacements commonly use a
1 MiB response cap; choose and test the new profile's own bound. A header value
containing `HTTP/1.1 200` is not a status line. Do not follow 3xx redirects
implicitly: they may forward samples to another host or replay a POST as a GET.

The async service returns a sample job identifier, for example:

```json
{"id":"sample-job-id"}
```

This `id` is NOT the collection `scan_id`. If implementing polling, parse JSON,
retain the sample job ID, bound polling and inspect the actual deployed service's
status/result schema. Native THOR acceptance used the completion status
`Sample analysis complete`. The stub uses a `results` field; other service
versions can use `result`. Do not assume those entire responses are interchangeable.
The reviewed collectors do not poll; an independent tester can do so.

A complete accepted transfer, completed analysis and positive detection are
three different observations. Benign samples can produce empty result arrays.
An empty result is not proof that source or original-path attribution was retained.

## 3. Add Collection Markers Only When Supported

Markers are a separate capability, not required for a useful collector. Native
THOR 10.7.30 in acceptance returned HTTP 404 for `/api/collection` while sample
uploads worked. The stub implements this extended endpoint for lifecycle tests;
its behavior is not a promise about every production service version.

If markers are supported by the profile, POST UTF-8 JSON with
`Content-Type: application/json`. A begin example is:

```json
{
  "type":"begin",
  "source":"manual-host-run",
  "hostname":"collecting-host",
  "collector":"language-profile/version",
  "timestamp":"2026-10-08T01:00:00Z"
}
```

`hostname` is optional metadata. Keep type, nonempty source, collector identity
and a UTC timestamp consistent. A successful begin may return:

```json
{"scan_id":"collection-id"}
```

Accept scan_id only from a parsed JSON object's string field. Null, numbers,
arrays, nested lookalike text or malformed JSON do not become URL identifiers.
A successful response without a usable scan ID can continue without one, with
an explicit diagnostic. A regex matching arbitrary JSON text is not a safe parser;
if the runtime cannot parse this response reliably, omit/disable this capability.

HTTP 404/501 means markers are unsupported: continue uploads without inventing a
scan ID. Other begin transport/HTTP failures must not silently look successful.
The replacement marker profiles try begin twice with a two-second pause, then
fail before uploading. Document any intentionally different policy.

When begin returns a valid scan ID, URL-encode it as the optional `scan_id` query
parameter on subsequent uploads. Preserve it in end/interrupted JSON:

```json
{
  "type":"end",
  "source":"manual-host-run",
  "collector":"language-profile/version",
  "timestamp":"2026-10-08T01:02:00Z",
  "scan_id":"collection-id",
  "stats":{"scanned":3,"submitted":2,"skipped":0,"failed":1,"scan_errors":0}
}
```

Use numeric counts and define their semantics. `submitted` means accepted files,
not HTTP attempts, discovered candidates or completed analyses. Count traversal
failures separately from per-file failures. Optional `elapsed_seconds` and
`in_flight` describe timing/current work; they do not establish delivery.
Different profiles enumerate filtered candidates differently, so do not invent
a universal equation between these counters.

End may summarize a partial run. An end request failing unexpectedly makes the
overall result nonzero even if uploads succeeded. Tell the operator to inspect
the service before repeating the scan. On graceful interruption use type
`interrupted`, optionally `reason`, rather than claiming normal completion.
Signals/host shutdown can prevent this best-effort notification; no marker is
guaranteed after SIGKILL, power loss or blocked filesystem I/O.

## 4. Make File Selection and Resource Limits Explicit

Validate configuration first. Use explicit local roots in every test. Recursive
walking must report missing/unreadable roots and incomplete enumeration, continue
other readable roots where feasible, and distinguish an empty existing directory
from a missing one. Repeated root options must follow the documented additive
or replacement rule. State whether overlapping roots can cause duplicates.

Define size units unambiguously: KiB = 1024 bytes, MiB = 1048576 bytes, or literal
bytes. Include the exact limit and reject limit-plus-one. Include empty regular
files unless the backend explicitly cannot accept them. Reject invalid/overflowing
numbers rather than clamping silently. Define age by modification time and a
recorded run-start cutoff, or explicitly document `find -mtime` bucket semantics;
age zero must mean disabled if that is the exposed interface. Creation time must
not quietly override modification-time filtering.

Default extension allowlists, case handling and the all-extensions override are
profile choices. Do not broaden a legacy allowlist without review. Known cloud,
network and pseudo-filesystem exclusions are best effort and platform-specific.
Do not describe a `/proc/mounts` check as equivalent coverage on Windows or macOS.

Do not follow discovered symlinks/junctions/reparse entries or upload sockets,
FIFOs and devices. Explicit root-link resolution needs its own documented rule.
Use literal path APIs, not wildcard expansion. Newline/delimiter filenames must
either work or fail visibly without being split into additional paths.

Where feasible, read a bounded snapshot before opening a network connection,
check regular-file identity/size/time before and after reading, and retry the
same immutable snapshot. Prevent blocking on special files where the runtime
allows it. Account for multipart buffers: peak RAM can be several times the
selected size. Legacy ADODB-style whole-file reads need an honest growth/RAM
limitation rather than a false claim of a hard bound.

A live walk is not an atomic or adversary-proof filesystem snapshot. Checks
cannot guarantee safety against a privileged process racing replacements.
Select stable trusted trees or use an independently provided snapshot when such
guarantees are necessary.

Keep logs and scratch data outside the input or explicitly exclude them. Create
temporary workspaces exclusively with restricted permissions/private TEMP;
never reuse predictable names. Remove only the current run's owned workspace.
Do not delete another process's files to recover from a collision. Document
that forced termination can leave copied sensitive samples behind.

## 5. Bound Network Work Without Weakening Security

Record whether retries mean total attempts or retries after the first attempt.
Count HTTP 503 within a finite budget. If a separate busy-response budget is
chosen, as in Bash, bound it too and test mixed error sequences. Parse numeric
Retry-After conservatively and clamp it; the replacement profiles cap it at
120 seconds. Bound fallback backoff and stop after exhaustion. Malformed/huge
headers must not cause overflow, an infinite loop or an unbounded sleep.

Set connect and I/O timeouts; add a whole-attempt watchdog if the platform can
support one safely. Idle/read timeouts are not total deadlines when a peer keeps
sending data. Close response streams and request resources on success AND failure;
test unreachable endpoints and aborted requests for runtime-specific deadlocks.
Use a separate bounded test watchdog even if the collector has its own limits.

A lost response can follow a successful server-side submission. Retrying then
can create duplicate samples. Do not promise exactly-once delivery without an
actual idempotency protocol. An HTTP error or stub audit event alone does not
establish accepted-file counts.

Keep certificate-chain AND hostname verification enabled. A private CA option
must retain hostname validation and trust only the configured anchor, without
installing machine-wide trust. Use per-request callbacks where required; never
leave a global accept-all TLS callback behind. If a legacy runtime cannot safely
verify HTTPS or implement custom trust, reject that mode and document the limit.
Protocol support and revocation checking also depend on the platform/profile.

If an explicit insecure option exists, label it a deliberate security bypass,
not automatic error recovery. Never combine its successful test with a claim
that verified TLS worked. Test a correctly CA-signed end-entity server certificate
with the appropriate SAN/EKU, not an invalid CA-as-server fixture. Test unrelated
CA rejection and trusted-CA hostname mismatch separately. Do not install test
roots globally; remove generated private keys after testing.

Disable unintended proxies, redirects and user tool configuration, or explicitly
make them reviewed configuration. Find external executables in trusted paths,
not the implicit current directory. Pass arguments without shell evaluation;
Windows CALL/delayed expansion and `%...%` process expansion require particular
care. Old curl builds differ in response limiting: unknown-length enforcement
for `--max-filesize` requires 8.4+, which is why the Batch profile requires it.
See the [official curl documentation](https://curl.se/docs/manpage.html#--max-filesize).

## 6. Define Operator Visible Outcomes

Dry-run must perform **zero HTTP requests**, including marker handshakes, TLS
probes and status requests. Say whether it merely selects candidates or also
checks readability. Separate would-submit output from accepted-upload counters.

Use concise diagnostics with path, failure stage and safe status information.
Never print license contents, authorization tokens, complete server error bodies
without bounds or sample contents as routine diagnostics. Keep counts truthful.
Intentional age/size/extension skips are not read or transport failures.

For a new profile, the recommended exit mapping is 0 = completed/valid dry-run,
1 = partial failure/interruption, 2 = configuration/dependency/startup failure.
Adopt it or document a deliberate alternative. Native interpreter/WSH launch errors
can use their own nonzero codes. No usable roots must not look like success.
Without markers, an empty eligible set need not prove that the service is reachable.

## 7. Test the Profile Before Calling It Complete

Use isolated harmless fixtures and an authorized real service. Keep licenses,
credentials and incident evidence outside fixtures and version control. Verify
all payloads using independent sizes and SHA-256/count multisets; unordered
traversal is normal, silent omissions and unexplained duplicates are not.

Run programmable failures against loopback fixtures/the stub, never sabotage a
shared production service. Repeat target-dependent tests on the actual runtime.

| Test | Required observation or explicit profile decision |
|---|---|
| Text, NUL/binary, empty, nested | Every eligible payload arrives unchanged; compare count, size and SHA-256, not just one upload |
| Spaces, Unicode, quote, comma, semicolon, percent, exclamation | No shell expansion/header injection; bytes unchanged; unsupported names fail visibly |
| Literal-newline paths | Correct literal handling OR documented refusal; never reinterpret a name as two files |
| Exact size and plus one | Exact limit uploaded, plus one skipped; verify KiB/MiB/byte conversion |
| Recent, old, age zero | Only intended mtime cutoff applies; zero includes both |
| Repeated roots, mixed valid/missing, all missing | Root-option semantics hold; readable work continues; missing work causes nonzero status |
| Non-root unreadable file and directory | File failure and traversal error reported; readable file still arrives; restore permissions |
| Windows sharing lock | A separate FileShare.None holder makes a file unavailable; unlock afterwards; not a POSIX chmod substitute |
| Links, junctions, special files | No outside-target upload, recursion loop or FIFO/device hang |
| Active log and scratch under a root | No self-generated artifacts uploaded; only owned scratch removed |
| Mid-read mutation/replacement | Detect failure/skip as documented; never count an incomplete body as accepted |
| Offline dry-run | Zero requests observed by the fixture, not merely a plausible console message |
| Closed local port | Clear nonzero result within a watchdog; no deadlock/unbounded retries |
| 503 then success; permanent 503 | Correct attempt count/backoff, recovery or bounded failure; include malformed/huge Retry-After |
| 3xx, 4xx/5xx, misleading header text | Not counted as success; no unintended redirect or status-header confusion |
| Truncated 2xx and oversized response | Nonzero failure even when a 2xx status was received |
| Marker 404/501 and other begin failures | Optional endpoint degrades as declared; real handshake failures do not masquerade as success |
| Marker JSON with null/number/array/lookalike text | No fake scan ID propagated; valid string IDs are safely encoded |
| End 500 after accepted uploads | Nonzero result; accepted uploads remain visible and are not silently retransmitted |
| Untrusted CA, unrelated CA, correct CA, wrong hostname | Verified failures stay failures; correct CA+hostname succeeds; insecure tested separately if supported |
| Graceful interruption | Nonzero status, no false normal completion; best-effort marker only if implemented |
| Actual oldest supported runtime | Execute the same applicable cases, including dependencies and TLS; syntax checks alone are insufficient |
| Real service completion | Accepted payloads stored/processed, async jobs completed; attribution/detection verified only if observable |

The shared harness in this repository selects available compatible collectors.
An explicitly requested missing/unrunnable collector must fail rather than
silently produce a green empty run. Its interface probes are routing, not a
universal feature contract. Add a new selector intentionally, with tests.
Pin the stub revision in CI and compile it for the test host. An incompatible
release binary's Exec format error is not a collector result.

Separate deterministic regression tests from real-service acceptance. Stub-only
`/api/test/...` endpoints must never become collector dependencies. A stub audit
entry may record a rejected attempt; use response success and independent stored
payload verification rather than treating every audit line as an accepted upload.

Record PASS, FAIL, NOT SUPPORTED, NOT TESTED and, for unavailable server evidence,
NOT OBSERVABLE. A skip is not a pass. A run on a newer interpreter is not legacy
certification. Record commit, target OS/architecture, runtime/tool/SSL versions,
service version, source, command, exit code, expected and observed payloads,
timeouts and each skip reason. Keep raw licensed-service logs private.

## 8. Give the Agent a Self Contained Assignment

Fill the placeholders and supply this guide plus the selected capability decisions:

```text
Build a THOR Thunderstorm collector from the supplied construction guide.
Language and exact minimum version: <...>
Target OS and architecture: <...>
Allowed libraries/external tools and RAM/storage budget: <...>
Delivery format: <standalone file or declared package>
Authorized test endpoint/version/authentication policy: <...>
Capability decisions: <recursion, extensions, size units, mtime policy, async/sync,
markers, dry-run, TLS/custom CA, signals/logging, supported path encodings>
Accepted restrictions: <...>
Actual target runtimes available for verification: <...>

First produce the concrete profile and identify unsupported requirements. Do not
silently relax TLS, expand scan scope, install dependencies or invent features.
Implement the binary-safe /api/checkAsync upload core and only the agreed extras.
Keep source and optional scan_id encoded; keep sample job IDs distinct. Bound
attempts/resources, require complete 2xx responses and report partial failures.
Do not copy another collector's implementation as the specification.

Add a README with dependencies, selectors/units, limitations, exit codes and
copy-paste manual positive AND failure tests with expected results. Add focused
isolated regressions for the chosen profile and integrate explicit CI selection.
Use harmless fixtures, an independent payload hash/count oracle and an external
watchdog. Never use broad default roots, license files or production samples.
Verify on each actual claimed runtime; label unavailable targets NOT TESTED.
Do not merge PRs, change unrelated Go code/dependencies or install global trust.
Deliver a reviewable PR, evidence matrix and remaining human acceptance steps.
```

## 9. Deliver a Reviewable Collector

Keep the collector, its profile README and focused tests together in one PR.
Shared-harness preparation belongs in a separate prerequisite if needed. Limit
changes to the new language profile and its necessary test/release integration.
Retain standalone release asset basenames or explicitly review a naming change.
The root Makefile recursively collects matching collector scripts outside tests;
add a packaging regression if a new file type/layout requires changes. Do not
invent a new combined ZIP or change Go release behavior as a side effect.

Run whitespace/syntax checks, focused regressions, selected stub tests and real
target acceptance. Check the final PR's exact head, not a previous green commit.
List skipped/unavailable environments and security/resource limits. Inspect staged
filenames explicitly: no licenses, credentials, generated private keys, copied
samples, local binaries or raw THOR logs belong in the commit. Human acceptance
using the [manual test guide](MANUAL_TESTING_GUIDE.md) remains the merge gate.
