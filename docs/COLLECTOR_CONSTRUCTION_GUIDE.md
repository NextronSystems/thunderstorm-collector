# Build a THOR Thunderstorm Collector

Use this specification to build a collector for another language, runtime,
operating system or architecture. A collector reads approved local files and
uploads them to THOR Thunderstorm for analysis. It does not scan locally and
needs no THOR license on the collecting host.

Before you build one:

- **Compare the [scanning approaches](SCANNING_APPROACHES.md).** With suitable
  SSH/SFTP access, SSHFS can expose the source files to THOR on an analysis
  workstation, so the source needs no collector. Exported evidence is another
  option.
- **[Check reuse](#check-reuse-before-building-a-new-profile)** of existing
  collectors, build variants and companion repositories.
- **Start from the upload protocol and an explicit capability profile**, not
  from a translation of another collector's source.

A minimal, honest implementation is better than one that silently weakens
security or pretends a legacy runtime has features it cannot provide. This page
contains no collector implementation. Coding agents: [section 8](#8-give-the-agent-a-self-contained-assignment)
holds a ready assignment.

> [!NOTE]
> Exact reviewed revisions, real-service results and remaining platform checks
> are in the [acceptance report of 8 October 2026](SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md).

## Contents

1. [Specify the target](#1-specify-the-target-before-implementation): inputs, core, existing profiles, reuse
2. [Upload protocol](#2-implement-the-upload-protocol): endpoints, multipart body, success rules
3. [Collection markers](#3-add-collection-markers-only-when-supported): optional run begin and end
4. [File selection and resource limits](#4-make-file-selection-and-resource-limits-explicit)
5. [Network limits and TLS](#5-bound-network-work-without-weakening-security)
6. [Operator visible outcomes](#6-define-operator-visible-outcomes): dry run, diagnostics, exit codes
7. [Tests](#7-test-the-profile-before-calling-it-complete): acceptance matrix and harness
8. [Coding-agent assignment](#8-give-the-agent-a-self-contained-assignment)
9. [Delivery](#9-deliver-a-reviewable-collector): PR scope and final checks

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
| Transport | Finite retries, timeouts and response-size limits |
| Optional features | Collection markers, dry-run, signals, logging, CA configuration |
| Restrictions | Unsupported filenames, mounts, paths, TLS modes or runtime features |
| Evidence | Actual runtime tests available and tests requiring human acceptance |

Authentication and transport security:

- The reviewed script profiles have **no built-in HTTP authentication** options.
- Do not invent credentials, disable a gateway's authentication or put secrets
  in URLs. An authenticated deployment needs an explicitly designed, tested
  extension.
- HTTP sends sample contents unencrypted. Choose HTTPS or an approved isolated
  network, depending on the deployment's sensitivity.

### Minimum useful core

Every collector needs:

- explicit configuration;
- truthful file selection;
- binary-safe upload;
- finite attempts;
- visible failures;
- a **nonzero result** when an eligible transfer fails.

TLS is optional on an HTTP-only target. If the profile offers HTTPS,
certificate and hostname verification **must be the default**. Unsupported
HTTPS must fail clearly, never downgrade to plaintext.

These are separate capabilities; decide which to implement: dry-run, markers,
custom CAs, interruption handling, syslog, extension filters, deduplication,
polling and resume. Do not make an optional feature a hidden prerequisite for a
service or platform that cannot support it.

### Existing profiles are examples, not one universal contract

These are the separately reviewed replacement scripts. Read each collector's own
README at the exact revision being deployed.

| Profile | Runtime and dependencies | Size unit | Markers | Other differences |
|---|---|---|---|---|
| [Bash](../scripts/bash/README.md) | Bash 3.2+, curl or GNU wget | KiB | Yes | All extensions. Wget uses idle-read limits, not a total deadline. HTTP 503 has a separate bounded busy-response budget. |
| [POSIX sh / ash](../scripts/ash/README.md) | Minimal Unix/BusyBox; curl or GNU wget preferred; nc plus timeout as fallback | KiB | Not with nc | All extensions. nc is HTTP-only and accepts only a restricted complete Content-Length response. BusyBox wget alone is refused. Literal-newline paths are unsupported and reported, never split into other paths. |
| [Python 3 and 2](../scripts/python/README.md) | Standalone standard-library scripts, Python 3.4+ or 2.7 | KiB | Yes | Bounded in-memory snapshots. Python before 2.7.9 refuses verified HTTPS. Socket timeouts are idle-I/O limits. |
| [Perl](../scripts/perl/README.md) | Perl 5.8.1 syntax floor, LWP 6+, JSON::PP and Encode; more modules for HTTPS | KiB | Yes | Signal handling may wait until network I/O returns. The syntax floor does not certify every old module/SSL combination. |
| [PowerShell 3+ and 2](../scripts/powershell/README.md) | Separate standalone files, full .NET/Add-Type | MiB | PS2 only with System.Web.Extensions, otherwise explicitly disabled | Extension allowlist by default. Custom CA and insecure options need a per-request callback on .NET 4.5+; older CLRs fail closed. |
| [Windows Batch](../scripts/batch/README.md) | Single cmd/JScript hybrid; enabled WSH, FileSystemObject, ADODB.Stream and trusted curl 8.4+ | bytes | No | Roots required. No resume, polling or insecure TLS. ADODB reading is not hard memory-bounded against a growing file. |

Test on the real runtime:

- Python 2 means an actual Python 2 run, not a Python 3 run of a similar file.
- Running the PS2 file on PowerShell 5.1 or 7 is not a PowerShell 2 test.
- Test BusyBox ash and its utilities, not just dash.
- OS, TLS libraries and external tool builds matter as much as language syntax.

### Check reuse before building a new profile

Build a new profile only for a **named target that no existing option serves**.
Record in its README why each option below fails.

The Go collector is a compiled profile outside the table above; see its
[README](../go/README.md) and the
[published binary inventory](COLLECTOR_RECOMMENDATIONS.md#published-go-binary-targets).

| Option | What it can reach | Check before relying on it |
|---|---|---|
| Published Go package | The OS and CPU targets in the inventory | The package's own kernel and CPU floor. Standard Go `ppc64` builds need POWER8 or newer, so they do not serve POWER7. |
| Existing script profile | Hosts that already have that runtime | The profile README's exact interpreter, module and tool list. |
| The prototype [SFTP collector](../sftp/README.md) | Any source with a working SFTP server, read from the Thunderstorm host or another system; nothing runs on the source | An SSH account that can read the files in scope, and the collector's [limits](../sftp/README.md#limits): modification time only and no filesystem types. Not tested on products. |
| The Go collector built with another toolchain, such as `gccgo` | CPUs and systems that Go's own compiler does not support, such as AIX on POWER7 | The toolchain on the build host, and validation on the real target. The [Go README](../go/README.md) says to contact Nextron about special `gccgo` builds. |
| A script profile limited to core modules | Older Unix hosts that have Perl or Python but not the libraries the current profiles need | Perl before 5.14 has no core JSON::PP or HTTP::Tiny, and TLS needs modules that are not core. Expect HTTP only and no markers. |
| A JVM profile | Hosts without Go support that already have a supported Java runtime | An installed, supported JRE and that Java version's TLS defaults. One JAR serves every CPU. |
| A C profile | Hosts with a compiler and no other runtime | The highest memory-safety and maintenance burden. Keep the scope to asynchronous upload, and add TLS only through a maintained library. |

Targets that do not give you a collector:

- The `wasip1` WebAssembly port of Go has no outbound sockets
  ([golang/go#65928](https://github.com/golang/go/issues/65928)).
- The published JavaScript and WASI packages need a host runtime and are not
  tested end to end, as the
  [collector recommendations](COLLECTOR_RECOMMENDATIONS.md#published-go-binary-targets)
  note.
- A browser page can read only folders the user selects. Uploads from another
  origin need CORS support from the service or a same-origin proxy.

Rust, Node.js, PHP, Ruby, Lua and Tcl profiles add reach only on a target that
has that runtime and none of the options above. Rust's Tier 1 baselines (Linux
3.2 on x86, Windows 10) are newer than those of the Go 1.10 builds.

### Clients that do not walk the filesystem

Mail, proxy, object-storage and container integrations get their sample bytes
from another source but submit them through the same API.

| Sections | Apply |
|---|---|
| 2, 5, 6 and 7 | Unchanged: multipart framing, complete 2xx responses, bounded retries, TLS verification and truthful counts |
| 3 and 4 | Only where the client has a run lifecycle or selects files |

Decide these points explicitly:

- **Sync or async.** The script profiles submit asynchronously only. A client
  that must act on the verdict before it releases content, such as a mail
  filter, needs `/api/check` and a policy for slow or unavailable analysis:
  release or hold.
- **Attribution.** Send a `source` that names the system or tenant and a
  filename that identifies the object, such as a message part, object key or
  container path. Verify which of them the Thunderstorm log records.
- **Duplicates.** Event-driven clients see redelivery.
  [Section 5](#duplicates) explains why exactly-once delivery cannot be promised.

Check the existing clients under
[related Nextron repositories](../integration-guides/README.md#related-nextron-repositories)
before starting another.

## 2. Implement the Upload Protocol

### Endpoint and query

| Operation | Request | Meaning |
|---|---|---|
| Async submission | POST `/api/checkAsync?source=<encoded-source>` | Accepted for asynchronous analysis; the only submission endpoint the reviewed script profiles use |
| Sync submission | POST `/api/check?source=<encoded-source>` | Analysis response returned with the request; protocol background only, not implemented by the reviewed script profiles |
| Optional result inspection | GET `/api/getAsyncResults?id=<encoded-job-id>` | Inspect one asynchronous sample job |
| Optional service inspection | GET `/api/status` | Service counters, not proof of one file's attribution |
| Optional collection lifecycle | POST `/api/collection` | Begin/end/interrupted markers where supported |

- A new profile follows the upload core of the reviewed script profiles: they
  submit only to `/api/checkAsync` and have no synchronous mode, so there is no
  sync/async decision to make.
- Use the native `/api/...` paths. The `/api/v1/...` rewriting in the older
  repository mock/API-proxy adapter is test infrastructure, not the native wire
  contract.

Server address:

- Validate scheme, host and port **before any network activity**. Ports are
  1..65535.
- Keep a host/IP parameter separate from a full URL, unless a full-URL
  interface is explicitly designed.
- Reject embedded credentials, paths, query fragments and control characters.
  Never let shell metacharacters be interpreted.
- IPv6 support is a profile decision: support URL brackets correctly or reject
  IPv6 explicitly.

The `source` parameter:

- `source` identifies the collecting host or run, not the server's hostname.
- Encode its UTF-8 bytes as one query value, including spaces, ampersands,
  percent signs, plus signs and Unicode. Example: `manual%20host%20%C3%A4`.
- Never concatenate an unescaped source or scan ID into a URL.

### Multipart body

- Send **one file per request** as `multipart/form-data`, field name **`file`**,
  with `Content-Type: application/octet-stream` for that part.
- Send the original file's bytes unchanged, including NUL, 0xff, CR/LF and
  zero-length payloads.
- Do not text-decode, base64-encode, newline-normalize or append bytes to the
  sample. Multipart separators are framing, not sample data.

Schematic request, not a copy-paste fixture. Every line break in headers and
framing is CRLF. Replace the bracketed placeholders, and compute Content-Length
in bytes from the complete encoded body, not in characters.

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

Framing rules:

- One framing CRLF follows the raw bytes before the closing boundary, even for
  an empty sample.
- Prefer a correct runtime multipart encoder. Otherwise verify the framing
  independently.
- When you build the body yourself, choose a sufficiently unpredictable
  boundary and avoid collisions with the sample contents.
- Send an exact byte length, or verify that the server accepts another transfer
  framing. Do not assume legacy backends accept chunked request bodies.

Filename metadata:

- Send the client-side path, used for attribution and file-type context. Never
  substitute a random scratch filename.
- Sanitize quotes, backslashes, semicolons and control characters so a path
  cannot inject headers. Keep the useful basename and extension.
- Existing profiles differ: some send the full path, some the basename.
  Document the choice and verify the server's parser. Do not promise that the
  server keeps the original path verbatim.
- Encoding or sanitizing metadata must never change payload bytes. Reject or
  explicitly replace invalid filename encodings in the metadata only.
- Never run a filename as shell syntax.

Paths from copies, mounts and exports:

- A collector that reads copies, mounts or extracted exports sends the path it
  sees locally, not the path on the source system. State in the profile which
  path is sent.
- The Go collector sends the absolute local path. No current collector can map
  a local prefix back to the original one; THOR on an analysis workstation can,
  with `--virtual-map`.
- If original paths matter for the assessment, design and test an explicit
  prefix mapping instead of rewriting names ad hoc.

### Successful transport is not completed analysis

A submission succeeds only after a **complete HTTP 2xx response** and no
transport error.

| Response | Required handling |
|---|---|
| Complete 2xx, no transport error | Success |
| 2xx with a truncated Content-Length body | Failure |
| Chunked 2xx without the terminal zero chunk and complete trailer section; EOF during chunk data or before the final trailer delimiter | Failure, even if an older HTTP library reports a normal end of body |
| Protocol error | Failure |
| Larger than the declared response cap | Failure. The focused replacements commonly use **1 MiB**; choose and test the new profile's own bound. |
| 3xx | Not a success. Do not follow it implicitly: it may forward samples to another host or replay the POST as a GET. |
| 4xx or 5xx | Not a success |
| A header value containing `HTTP/1.1 200` | Not a status line |

Test valid chunks and trailers as well as truncation, over both HTTP and HTTPS.

The async service returns a sample job ID, for example:

```json
{"id":12345}
```

- On THOR 10.7 the `id` is a JSON integer; the stub returns a UUID string.
- This `id` is **not** the collection `scan_id`.

Polling is optional. The reviewed collectors do not poll; an independent tester
can. If you implement it:

- parse the JSON, keep the sample job ID and bound the polling;
- inspect the status and result schema of the actual deployed service.

THOR 10.7 reports completion as `Sample analysis complete` and, once finished,
returns a `result` field. The stub reports `done` and uses a `results` field. Do
not assume the full responses are interchangeable.

A complete accepted transfer, a completed analysis and a positive detection are
three different observations. Benign samples can produce empty result arrays.
An empty result does not prove that the source or original-path attribution was
kept.

## 3. Add Collection Markers Only When Supported

Markers are an optional capability; a useful collector does not need them.

- THOR 10 and the current THOR 11 versions answer `/api/collection` with
  **404**. This is the normal case, not a problem to report. In acceptance,
  native THOR 10.7.30 returned 404 while sample uploads worked.
- The stub implements the endpoint for lifecycle tests. Its behavior is not a
  promise about every production service version.
- [Collection markers](COLLECTION_MARKERS.md) describes what the existing
  collectors send and what a server has to do with it.

### Begin request

If the profile supports markers, POST UTF-8 JSON with
`Content-Type: application/json`:

```json
{
  "type":"begin",
  "source":"manual-host-run",
  "hostname":"collecting-host",
  "collector":"language-profile/version",
  "timestamp":"2026-10-08T01:00:00Z"
}
```

Keep `type`, a nonempty `source`, the collector identity and a UTC `timestamp`
consistent. `hostname` is optional metadata. A successful begin may return:

```json
{"scan_id":"collection-id"}
```

### Begin answer

| Begin answer | Required behavior |
|---|---|
| 2xx, JSON object with a usable string `scan_id` | Use the ID |
| 2xx without a usable scan ID | Continue without one; say so in debug output |
| 404 or 501 | Markers are unsupported. Continue uploads without a scan ID, even if the error body contains a plausible `scan_id` field. |
| Any other HTTP answer | Not a scan ID. The existing profiles try begin **twice** with a **two-second** pause, then continue without an ID. |
| No HTTP answer at all (connection, TLS or timeout failure) | May serve as the profile's connectivity check and stop the run before uploading, as the script profiles do |

None of these answers is a warning or changes the exit status. Show them only in
debug output, so that operators do not suspect a failed collection. Document any
intentionally different policy.

### Parsing the scan ID

- Accept `scan_id` only from a **parsed JSON object's string field**. Null,
  numbers, arrays, nested lookalike text or malformed JSON never become URL
  identifiers.
- A regex over arbitrary JSON text is not a safe parser. If the runtime cannot
  parse the response reliably, omit or disable markers.
- Validate the root shape before any runtime feature that unwraps
  single-element arrays.
- Preserve the string type: JSON `123` is not the string `"123"`.
- Decode escapes without replacing identifier characters. Reject unsupported
  encodings instead of silently changing the ID.
- Bound parsing work separately from response storage, and test the
  parser-size boundary, not only the HTTP response-size limit. Large valid
  strings can consume substantial CPU in older awk implementations.

For reference, the shell profiles reject duplicate `scan_id` keys, control
characters, IDs over **256 bytes** and JSON deeper than **32 levels**. They do
not parse marker JSON larger than **64 KiB**, although transport permits up to
1 MiB; they continue without an ID and say so only in debug output.

### Uploads, end and interruption

When begin returns a valid scan ID, URL-encode it as the optional `scan_id`
query parameter on the following uploads, and keep it in the `end` or
`interrupted` JSON:

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

Counters:

- Use numeric counts and define their meaning.
- `submitted` means accepted files, not HTTP attempts, discovered candidates or
  completed analyses.
- Count traversal failures separately from per-file failures.
- Optional `elapsed_seconds` and `in_flight` describe timing and current work;
  they do not establish delivery.
- Profiles enumerate filtered candidates differently, so do not invent a
  universal equation between the counters.

End and interruption:

- `end` may summarize a partial run.
- A failed `end` or `interrupted` request **does not change the overall
  result**: the uploads decide it. Show the failure only in debug output.
- On graceful interruption, send type `interrupted`, optionally with `reason`,
  instead of claiming normal completion.
- This notification is best effort. Signals or host shutdown can prevent it; no
  marker is guaranteed after SIGKILL, power loss or blocked filesystem I/O.

## 4. Make File Selection and Resource Limits Explicit

### Roots

- Validate the configuration first. Use explicit local roots in every test.
- Report missing or unreadable roots and incomplete enumeration.
- Continue with other readable roots where feasible.
- Distinguish an empty existing directory from a missing one.
- Repeated root options follow the documented additive or replacement rule.
- State whether overlapping roots can cause duplicates.

### Size and age

- Define size units unambiguously: KiB = **1024** bytes, MiB = **1048576**
  bytes, or literal bytes.
- Include a file of exactly the limit; reject limit plus one.
- Include empty regular files unless the backend explicitly cannot accept them.
- Reject invalid or overflowing numbers instead of clamping them silently.
- Define age by **modification time** and a recorded run-start cutoff, or
  document `find -mtime` bucket semantics explicitly.
- If the interface exposes age zero, it must mean "disabled".
- Creation time must not quietly override modification-time filtering.

### Extensions and exclusions

- Default extension allowlists, case handling and the all-extensions override
  are profile choices. Do not broaden a legacy allowlist without review.
- Known cloud, network and pseudo-filesystem exclusions are best effort and
  platform-specific. Do not describe a `/proc/mounts` check as equivalent
  coverage on Windows or macOS.

### Links, special files and unusual names

- Do not follow discovered symlinks, junctions or reparse entries.
- Do not upload sockets, FIFOs or devices.
- Explicit root-link resolution needs its own documented rule.
- Use literal path APIs, not wildcard expansion.
- Filenames with newlines or delimiters either work or fail visibly; they are
  never split into additional paths. Apply this after resolving explicit root
  symlinks too.
- Shell command substitution strips trailing newlines, so a plain
  `root=$(cd ... && pwd)` can select a different existing sibling. Preserve the
  path bytes or reject them without scanning the altered path. This includes
  workspace and log-exclusion paths.

### Reading files

- Where feasible, read a bounded snapshot **before** opening a network
  connection.
- Check regular-file identity, size and time before and after reading, and
  retry the same immutable snapshot.
- Prevent blocking on special files where the runtime allows it.
- Account for multipart buffers: peak RAM can be several times the selected
  size.
- Legacy ADODB-style whole-file reads need an honest growth/RAM limitation, not
  a false claim of a hard bound.

A live walk is not an atomic or adversary-proof filesystem snapshot. Checks
cannot guarantee safety against a privileged process racing replacements. When
you need such guarantees, select stable trusted trees or use an independently
provided snapshot.

### Logs and scratch data

- Keep logs and scratch data outside the input, or exclude them explicitly.
- Create temporary workspaces exclusively, with restricted permissions or a
  private TEMP. Never reuse predictable names.
- Remove only the current run's own workspace. Do not delete another process's
  files to recover from a collision.
- Document that forced termination can leave copied sensitive samples behind.

## 5. Bound Network Work Without Weakening Security

### Retries and HTTP 503

- Record whether "retries" means total attempts or retries after the first
  attempt.
- Count HTTP 503 within a finite budget. A separate busy-response budget, as in
  Bash, must be bounded too; test mixed error sequences.
- Parse a numeric `Retry-After` conservatively and clamp it. The replacement
  profiles cap it at **120 seconds**.
- Bound the fallback backoff and stop after exhaustion.
- Malformed or huge headers must not cause an overflow, an infinite loop or an
  unbounded sleep.

### Timeouts

- Set connect and I/O timeouts.
- Add a whole-attempt watchdog if the platform can support one safely.
  Idle/read timeouts are not total deadlines when a peer keeps sending data.
- Close response streams and request resources on success **and** failure.
- Test unreachable endpoints and aborted requests for runtime-specific
  deadlocks.
- Use a separate bounded test watchdog, even if the collector has its own
  limits.

### Response limits

- Enforce response limits **while receiving**, not only after reading the whole
  body into RAM or onto disk.
- Count headers, error bodies and diagnostics in the storage budget.
- Do not apply the response cap to legitimate multipart sample spooling by
  accident. Bound error-body logging separately.

For reference: Bash and ash run each HTTP process under a file-size limit, then
apply their logical 1 MiB response cap before parsing. Their physical
per-output-file cap is at most 2 MiB across their supported shell limit units.
Netcat counts headers in its 1 MiB cap.

### Duplicates

- A lost response can follow a successful server-side submission, so a retry
  can create a duplicate sample.
- Do not promise exactly-once delivery without an actual idempotency protocol.
- An HTTP error or a stub audit event alone does not establish accepted-file
  counts.

### TLS

- Keep certificate-chain **and** hostname verification enabled.
- A private CA option keeps hostname validation and trusts only the configured
  anchor, without installing machine-wide trust.
- Use per-request callbacks where required. Never leave a global accept-all TLS
  callback behind.
- If a legacy runtime cannot verify HTTPS or implement custom trust safely,
  reject that mode and document the limit.
- Protocol support and revocation checking also depend on the platform and
  profile.

An explicit insecure option, if one exists:

- Label it a deliberate security bypass, not automatic error recovery.
- Never combine its successful test with a claim that verified TLS worked.

TLS tests:

- Use a correctly CA-signed end-entity server certificate with the appropriate
  SAN/EKU, not an invalid CA-as-server fixture.
- Test rejection of an unrelated CA and a hostname mismatch under a trusted CA
  separately.
- Do not install test roots globally. Remove generated private keys after
  testing.

### Proxies, external tools and configuration

- Disable unintended proxies, redirects and user tool configuration, or make
  them explicitly reviewed configuration.
- Find external executables in trusted paths, not the implicit current
  directory.
- Pass arguments without shell evaluation. Windows CALL, delayed expansion and
  `%...%` process expansion need particular care.
- **curl:** the option that disables automatic configuration must be the first
  argument. Old builds differ in response limiting: `--max-filesize` is
  enforced for unknown-length responses only from **8.4**, which is why the
  Batch profile requires it. See the
  [curl documentation](https://curl.se/docs/manpage.html#--max-filesize).
- **GNU wget:** use a version that can disable both user and system startup
  configuration.
- Test hostile temporary tool settings that request insecure TLS or redirect
  following. Neither may silently override the collector profile.

### HTTP library defaults

Library defaults can contradict this section. Check them for the runtime in use:

| Client | Default or behavior to check |
|---|---|
| Go `net/http` | Follows redirects unless `CheckRedirect` refuses them; the Go collector refuses. A body of unknown length is sent chunked, as the Go collector does for uploads, and native THOR accepted its uploads in the recorded VM tests. |
| Java `HttpURLConnection` | Follows redirects. Buffers the whole request body in memory unless fixed-length or chunked streaming is set; a fixed length also publishes an exact `Content-Length`. The JDK property `sun.net.http.retryPost` defaults to true, so a POST can be resent without the caller noticing. |
| libcurl | Redirects are off unless `CURLOPT_FOLLOWLOCATION` is set. Proxy environment variables are honored unless a proxy is set; an empty string disables the proxy. `.curlrc` is read by the curl tool, not by the library. |
| Node.js | `fetch` follows redirects unless `redirect` is set to `manual`. `NODE_TLS_REJECT_UNAUTHORIZED=0` disables certificate verification for the whole process, so treat it as hostile configuration. A multipart body built from an in-memory `Buffer` or `Blob` holds the entire file. |

## 6. Define Operator Visible Outcomes

### Dry run

- A dry run performs **zero HTTP requests**, including marker handshakes, TLS
  probes and status requests.
- Say whether it only selects candidates or also checks readability.
- Keep would-submit output separate from accepted-upload counters.

### Diagnostics and counts

- Keep diagnostics concise: path, failure stage and safe status information.
- Never print license contents, authorization tokens, unbounded server error
  bodies or sample contents as routine diagnostics.
- Keep counts truthful. Intentional age, size or extension skips are not read
  or transport failures.

### Exit codes

Recommended mapping for a new profile:

| Code | Meaning |
|---|---|
| `0` | Completed, or valid dry run |
| `1` | Partial failure or interruption |
| `2` | Configuration, dependency or startup failure |

- Adopt it or document a deliberate alternative.
- Native interpreter or WSH launch errors can use their own nonzero codes.
- No usable roots must not look like success.
- Without markers, an empty eligible set need not prove that the service is
  reachable.

## 7. Test the Profile Before Calling It Complete

Ground rules:

- Use isolated harmless fixtures and an authorized real service.
- Keep licenses, credentials and incident evidence out of fixtures and version
  control.
- Verify all payloads with independent sizes and SHA-256/count multisets.
  Unordered traversal is normal; silent omissions and unexplained duplicates
  are not.
- Run programmable failures against loopback fixtures or the stub. Never
  sabotage a shared production service.
- Repeat target-dependent tests on the actual runtime.

| Test | Required observation or explicit profile decision |
|---|---|
| Text, NUL/binary, empty, nested | Every eligible payload arrives unchanged; compare count, size and SHA-256, not just one upload |
| Spaces, Unicode, quote, comma, semicolon, percent, exclamation | No shell expansion/header injection; bytes unchanged; unsupported names fail visibly |
| Literal-newline paths and symlink roots resolving to them | Correct literal handling OR documented refusal; never reinterpret a name or scan its newline-stripped sibling |
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
| Truncated Content-Length/chunked 2xx, incomplete trailers, oversized response | Nonzero failure even with 2xx headers; response storage remains bounded, including errors |
| Marker 404/501 and other HTTP answers to begin | Uploads continue without a scan ID; no warning and no exit-status change without debug; a begin without any HTTP answer follows the profile's declared connectivity rule |
| Marker JSON with null/number/single-element array/nested lookalike text | No fake scan ID propagated; valid escaped strings are preserved and safely encoded |
| End 500 after accepted uploads | Exit status unchanged and nothing logged without debug; accepted uploads are not retransmitted |
| Untrusted CA, unrelated CA, correct CA, wrong hostname | Verified failures stay failures; correct CA+hostname succeeds; insecure tested separately if supported |
| Tool config enabling insecure TLS or redirects | Defaults remain enforced; no upload to an unapproved redirect target |
| Graceful interruption | Nonzero status, no false normal completion; best-effort marker only if implemented |
| Actual oldest supported runtime | Execute the same applicable cases, including dependencies and TLS; syntax checks alone are insufficient |
| Real service completion | Accepted payloads stored/processed, async jobs completed; attribution/detection verified only if observable |

### Shared test harness

- The harness selects available compatible collectors. An explicitly requested
  collector that is missing or cannot run **must fail**, not produce a green
  empty run.
- Its interface probes are routing, not a universal feature contract.
- Add a new selector intentionally, with tests:
  - script collectors register in `COLLECTORS` in
    [`select_collectors.py`](../scripts/tests/select_collectors.py);
  - the mock-based suite in [`tests/`](../tests/test-collectors.sh) takes one
    directory per collector under `tests/test-collectors.d/`.
- The harness runs against the
  [thunderstorm-stub-server](https://github.com/Nextron-Labs/thunderstorm-stub-server),
  which also implements the optional collection endpoint. The mock-based suite
  uses the [thunderstorm-mock](https://github.com/NextronSystems/thunderstorm-mock)
  behind the proxy described in [section 2](#endpoint-and-query).
- Pin the stub revision in CI and compile it for the test host. An
  incompatible release binary's "Exec format error" is not a collector result.
- After launching a local stub, check that the owned process is still alive as
  well as ready. A different listener on the port is not the spawned stub;
  failed startup must stop before any reset or fixture request reaches it.

### Regression tests and acceptance

- Keep deterministic regression tests separate from real-service acceptance.
- Stub-only `/api/test/...` endpoints must never become collector dependencies.
- A stub audit entry may record a rejected attempt. Use response success and
  independent verification of the stored payloads, not every audit line, as the
  measure of accepted uploads.

### Recording results

- Record each result as **PASS**, **FAIL**, **NOT SUPPORTED** or **NOT
  TESTED**, and as **NOT OBSERVABLE** where server evidence is unavailable.
- A skip is not a pass.
- A run on a newer interpreter is not legacy certification.

For each run, record:
commit, target OS and architecture, runtime/tool/SSL versions, service version,
source, command, exit code, expected and observed payloads, timeouts and each
skip reason. Keep raw licensed-service logs private.

## 8. Give the Agent a Self Contained Assignment

Fill in the placeholders. Give the agent this guide and the chosen capability
decisions.

```text
Build a THOR Thunderstorm collector from the supplied construction guide.

Target profile:
- Language and exact minimum version: <...>
- Target OS and architecture: <...>
- Allowed libraries/external tools and RAM/storage budget: <...>
- Delivery format: <standalone file or declared package>
- Authorized test endpoint/version/authentication policy: <...>
- Capability decisions: <recursion, extensions, size units, mtime policy,
  markers, dry-run, TLS/custom CA, signals/logging, supported path encodings,
  path sent as the filename, API base path>
- Existing options checked: <collectors, build variants and clients considered,
  and why each does not serve this target>
- Accepted restrictions: <...>
- Actual target runtimes available for verification: <...>

Implementation:
- First produce the concrete profile and identify unsupported requirements.
- Do not silently relax TLS, expand scan scope, install dependencies or invent
  features.
- Implement the binary-safe /api/checkAsync upload core and only the agreed
  extras.
- Keep source and optional scan_id encoded; keep sample job IDs distinct.
- Bound attempts and resources, require complete 2xx responses and report
  partial failures.
- Do not copy another collector's implementation as the specification.

Documentation and tests:
- Add a README with dependencies, selectors/units, limitations, exit codes and
  copy-paste manual positive AND failure tests with expected results.
- Add focused isolated regressions for the chosen profile and integrate
  explicit CI selection.
- Use harmless fixtures, an independent payload hash/count oracle and an
  external watchdog. Never use broad default roots, license files or
  production samples.
- Verify on each actual claimed runtime; label unavailable targets NOT TESTED.

Limits and delivery:
- Do not merge PRs, change unrelated Go code/dependencies or install global
  trust.
- Deliver a reviewable PR, an evidence matrix and the remaining human
  acceptance steps.
```

## 9. Deliver a Reviewable Collector

PR scope:

- Keep the collector, its profile README and focused tests together in **one
  PR**.
- Put shared-harness preparation into a separate prerequisite PR if needed.
- Limit changes to the new language profile and its necessary test and release
  integration.
- Keep standalone release asset basenames, or review a naming change
  explicitly.
- The root Makefile recursively collects matching collector scripts outside
  tests. Add a packaging regression if a new file type or layout needs changes.
- Do not invent a new combined ZIP or change Go release behavior as a side
  effect.

Before review:

- Run whitespace and syntax checks, focused regressions, selected stub tests and
  real-target acceptance.
- Check the final PR's exact head, not a previous green commit.
- List skipped or unavailable environments and the security and resource
  limits.
- Inspect staged filenames explicitly. No licenses, credentials, generated
  private keys, copied samples, local binaries or raw THOR logs belong in the
  commit.

Human acceptance using the [manual test guide](../scripts/MANUAL_TESTING_GUIDE.md)
remains the **merge gate**.
