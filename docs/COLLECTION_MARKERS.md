# Collection Markers: What the Collectors Send

This page is for developers of the Thunderstorm service. It describes what the
collectors in this repository send to `POST /api/collection`, how they react to
each answer, and what a server can conclude from it. Collector authors should
follow
[section 3 of the construction guide](COLLECTOR_CONSTRUCTION_GUIDE.md#3-add-collection-markers-only-when-supported)
instead.

> [!NOTE]
> Describes the collectors on `master`, last reviewed on **16 November 2026**.
> THOR 10 and the current THOR 11 versions answer `/api/collection` with
> **404**. That means "markers unsupported" and is the normal case: the
> collectors upload as before, without a scan ID.

## Contents

- [The Contract in Short](#the-contract-in-short)
- [Support Today](#support-today)
- [What a Server Must Do](#what-a-server-must-do)
- [Requests](#requests)
- [The Begin Answer](#the-begin-answer)
- [Uploads in a Run](#uploads-in-a-run)
- [How Collectors React to Answers](#how-collectors-react-to-answers)
- [When Markers Are Sent](#when-markers-are-sent)
- [What the Server Can Conclude](#what-the-server-can-conclude)
- [Questions for the Server Design](#questions-for-the-server-design)
- [Testing](#testing)
- [Why Markers Exist](#why-markers-exist)
- [History](#history)

## The Contract in Short

1. Before the first upload, the collector sends a **`begin`** marker: a JSON
   object, `POST /api/collection`.
2. The server answers **2xx** with `{"scan_id": "<id>"}`.
3. The collector adds **`scan_id=<id>`** to the query of every upload of the run.
4. After the walk, it sends **`end`** with the same `scan_id` and its counters.
   On Ctrl+C or SIGTERM it sends **`interrupted`** instead.
5. The server answers 2xx. The collector ignores the body.

To switch markers off, answer **404** or **501**. Marker answers never change a
collector's exit status, and marker problems appear only in debug output.

```mermaid
sequenceDiagram
    participant C as Collector
    participant T as Thunderstorm
    C->>T: POST /api/collection (type begin)
    T-->>C: 200 with scan_id
    loop every selected file
        C->>T: POST /api/checkAsync?source=...&scan_id=...
        T-->>C: 200 with job id
    end
    alt walk finished
        C->>T: POST /api/collection (type end, scan_id, stats)
    else Ctrl+C or SIGTERM
        C->>T: POST /api/collection (type interrupted, scan_id, stats)
    end
    T-->>C: 2xx
```

A dry run sends no request at all, markers included.

## Support Today

### Collectors

| Collector | Sends markers | `collector` value | Notes |
|---|---|---|---|
| [Bash](../scripts/bash/README.md) | Yes | `bash/0.5.0` | curl or GNU wget. Sends no `hostname` field. |
| [POSIX sh / ash](../scripts/ash/README.md) | Yes, with curl or GNU wget | `ash/0.5.0` | The netcat transport sends no markers. |
| [Python 3](../scripts/python/README.md) | Yes | `python3/0.2` | The only collector that sends `stats.in_flight`. |
| [Python 2](../scripts/python/README.md) | Yes | `python2/0.2` | Same marker code as Python 3. |
| [Perl](../scripts/perl/README.md) | Yes | `perl/0.3` | |
| [PowerShell 3+](../scripts/powershell/README.md) | Yes | `powershell3/0.3` | Also sends `interrupted` when it gives up on an unreachable server. |
| [PowerShell 2](../scripts/powershell/README.md) | Yes, if a JSON parser is available | `powershell2/0.3` | Needs .NET 3.5 `System.Web.Extensions`; without it, no markers. |
| [Windows Batch](../scripts/batch/README.md) | **No** | | Removed by design in March 2026. |
| [Go collector](../go/README.md) | Yes | `go` | Also adds `scan_id` to `/api/check` in synchronous mode. A failed begin does not stop the run. |
| [SFTP collector](../sftp/README.md) | Yes | `sftp` | `hostname` is the system that runs the collector, not the SFTP source. Same begin rule as Go. |

Treat the `collector` value as a label and do not parse it. A script's value
follows that script's own version number; Go and SFTP send no version.

### Servers

| Server | `POST /api/collection` | `scan_id` on uploads |
|---|---|---|
| THOR 10 Thunderstorm | Not implemented: HTTP 404, [recorded with THOR 10.7.30](SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md#what-these-results-do-not-establish) | Never sent, because begin fails with 404 |
| THOR 11 Thunderstorm | Not implemented in current versions: HTTP 404. Planned. | Planned |
| [thunderstorm-stub-server](https://github.com/Nextron-Labs/thunderstorm-stub-server) (test server) | Accepts begin, end and interrupted, returns a UUID, logs each marker | Ignored: every upload gets its own ID |

No server links uploaded samples to a run yet. That link is the server-side work.

## What a Server Must Do

A server that breaks one of these rules breaks collections that work against
THOR 10 today. The reasons follow from the
[client behavior](#how-collectors-react-to-answers).

1. **Keep `POST /api/collection` at least as available as `/api/checkAsync`.**
   - Do not answer begin with 503 because the sample queue is full.
   - Keep proxies from answering it with 401 or 403.
   - Apply back-pressure to uploads, not to markers.

   Either answer makes every collector upload the run without an ID, and the
   collectors report this only in debug output.
2. **To switch markers off, answer 404 or 501**, never 400 or 403.
3. **Answer within a few seconds.** The clients give up after about 10.
4. **Do not redirect** `/api/collection`.
5. **Answer begin with a small JSON object** holding `scan_id` as a non-empty
   string of **at most 256 bytes**. An ID made only of letters, digits, `-`,
   `_`, `.` and `:`, such as a UUID, is safe in URLs, file names and every
   collector.
6. **Accept the documented fields** without answering 400 when an optional one
   is missing (`hostname`, `scan_id`, `stats`). Ignore unknown fields.

   A 400 on begin silently drops the run's ID; on end, the run stays open on the
   server.
7. **Accept `end` and `interrupted` with an unknown `scan_id`**, for example
   after a server restart, and record them. The stub server does the same.
8. **Accept uploads with an unknown, closed or missing `scan_id`.**
9. **Normalize both `source` values alike.** If the server changes the upload
   `source`, for example by removing characters, apply the same rule to the
   marker `source` so that both match.

## Requests

Every marker request is:

- `POST /api/collection` on the same scheme, host, port and TLS settings as the
  uploads, without authentication headers;
- a single JSON object in UTF-8 with `Content-Type: application/json`;
- sent with a client timeout of about **10 seconds**;
- labeled with the same `source` string that the run's uploads carry in the
  `source` query parameter.

### Fields

| Field | Type | Present in | Sent by | Meaning |
|---|---|---|---|---|
| `type` | string | all | all | `begin`, `end` or `interrupted` |
| `source` | string | all | all | The run's source label: the host name by default, or the value the operator set. The uploads carry the same string. |
| `hostname` | string | all | all except Bash | The name of the machine that runs the collector, independent of `source`. For the SFTP collector, this is not the system it collects from. |
| `collector` | string | all | all | Collector name and version, see [Collectors](#collectors) |
| `timestamp` | string | all | all | Client clock in UTC, `YYYY-MM-DDTHH:MM:SSZ`, whole seconds |
| `scan_id` | string | end, interrupted | all | The ID from the begin answer. Absent when the run has none. |
| `stats` | object | end, interrupted | all | Run counters, see below |

No collector sends a `reason` field today. The stub server accepts one for
`interrupted`.

### Counters

| Key | Type | Meaning |
|---|---|---|
| `scanned` | integer | Candidate files the collector examined. Some collectors apply age or extension filters while listing, so this is not "all files on the host". |
| `submitted` | integer | Files the server answered with 2xx. For `/api/checkAsync` this means queued, not analyzed. |
| `skipped` | integer | Candidates the collector's filters excluded, such as size, age, file type or exclusion lists. Which filters count here differs per collector. |
| `failed` | integer | Candidates that could not be read or uploaded after retries |
| `scan_errors` | integer | Directories or roots that could not be listed. Nonzero means the walk was incomplete. |
| `elapsed_seconds` | integer | Seconds since the collector started |
| `in_flight` | string | Python only: the path being uploaded when the marker was built. In practice it only appears in `interrupted`. |

Do not expect `scanned = submitted + skipped + failed`: the collectors count
candidates differently.

### Examples

Begin, Python 3:

```json
{
  "type": "begin",
  "source": "web-01",
  "hostname": "web-01.example.org",
  "collector": "python3/0.2",
  "timestamp": "2026-11-06T02:00:00Z"
}
```

End, Bash (no `hostname`):

```json
{
  "type": "end",
  "source": "web-01",
  "collector": "bash/0.5.0",
  "timestamp": "2026-11-06T02:47:13Z",
  "scan_id": "6f1c2a9e-3b7d-4e55-9a0c-1d2e3f405162",
  "stats": {"scanned": 18240, "submitted": 912, "skipped": 41, "failed": 2,
            "scan_errors": 0, "elapsed_seconds": 2833}
}
```

Interrupted, Python 3, stopped with Ctrl+C during an upload:

```json
{
  "type": "interrupted",
  "source": "web-01",
  "hostname": "web-01.example.org",
  "collector": "python3/0.2",
  "timestamp": "2026-11-06T02:12:09Z",
  "scan_id": "6f1c2a9e-3b7d-4e55-9a0c-1d2e3f405162",
  "stats": {"scanned": 5120, "submitted": 260, "skipped": 9, "failed": 0,
            "scan_errors": 0, "elapsed_seconds": 729,
            "in_flight": "/var/www/html/upload.php"}
}
```

## The Begin Answer

A collector takes the run ID only from a **2xx** answer whose body is a JSON
object with a **top-level string field `scan_id`**:

```json
{"scan_id": "6f1c2a9e-3b7d-4e55-9a0c-1d2e3f405162"}
```

In every other case the collector runs without an ID and says so only in debug
output:

| Begin answer | Ignored by |
|---|---|
| Body is not a JSON object | all |
| `scan_id` missing, null, a number, an empty string, or only in a nested object | all |
| ID longer than 256 bytes, or containing control characters | Bash, ash, Go, SFTP |
| Body larger than 64 KiB | Bash, ash, Python, Go, SFTP |
| Duplicate `scan_id` keys, or JSON nested deeper than 32 levels | Bash, ash |

The collectors ignore all other fields of the begin answer, the bodies of the
answers to `end` and `interrupted`, and the response `Content-Type`.

## Uploads in a Run

After a begin answer with a usable ID, every upload of the run carries it as a
second, percent-encoded query parameter. Retries of a file reuse the same URL.

```text
POST /api/checkAsync?source=web-01&scan_id=6f1c2a9e-3b7d-4e55-9a0c-1d2e3f405162
```

- The multipart body does not change: the file is in the `file` field, and the
  ID is not repeated there.
- The script collectors upload only to `/api/checkAsync`.
- The Go and SFTP collectors also add the ID to `/api/check` when they upload
  synchronously (`--upload-synchronous`).

## How Collectors React to Answers

| Answer | begin | end | interrupted |
|---|---|---|---|
| 2xx | The run starts, with the ID if it is usable | Success | Not checked |
| 404 or 501 | Markers are unsupported. The run continues and uploads carry no `scan_id`. | Ignored | Ignored |
| Any other status (400, 401, 403, 500, 503 ...) or a redirect | Retried once after 2 seconds. If that fails too, the run continues and uploads carry no `scan_id`. | Ignored | Ignored |
| No HTTP answer: a timeout, a connection or TLS error, or an incomplete reply | Retried once after 2 seconds. If that fails too, a **script collector stops before the first upload** with exit code **2**. The Go and SFTP collectors upload every file without `scan_id`. | Ignored | Ignored |
| Attempts | 2 | 1 | 1 |

**Exit status and logging**

- Marker answers never change a collector's exit code.
- The collectors do not log marker problems. A run against THOR 10 looks the
  same as a run before markers existed.
- The debug option (`--debug`, PowerShell `-Debugging`) shows every marker
  answer.
- An `interrupted` run always exits with code 1, because the collection is
  incomplete, not because of the marker.

**Follow-up markers**

- No collector follows redirects.
- After a 404 or 501 on begin, PowerShell, Go and SFTP send no further markers
  in that run. The other script collectors still send `end`.
- Go and SFTP send `end` or `interrupted` only after a 2xx answer to begin.

**Begin as connectivity check**

- For the script collectors, begin is also the connectivity check. Only a begin
  that gets no HTTP answer at all stops them.
- The Go and SFTP collectors check `/api/status` first, so they keep uploading
  in that case too.
- Whenever begin fails, the samples of that run carry no ID, and nobody is told
  unless the collector runs with its debug option.

## When Markers Are Sent

| Marker | When |
|---|---|
| `begin` | Once, after the configuration is checked, before the first upload. Go sends it after its `/api/status` check, SFTP after it has connected to the source. |
| `end` | Once, after the walk finished. Runs with failed files or unreadable directories end normally; the counters show the problems. |
| `interrupted` | Best effort on Ctrl+C or SIGTERM. See the list below. |
| nothing | After SIGKILL, power loss, a reboot, a killed container, a hung file system, or a network failure at the end of the run. The server sees a begin and uploads, but no closing marker. |

Details for `interrupted`:

- ash also sends it on SIGHUP and SIGQUIT.
- PowerShell and SFTP also send it when they stop because the server did not
  answer for `ServerWait` or `--server-wait` seconds (**600** by default).
- SFTP also sends it when its SSH connection to the source was lost.
- Bash can send it during the begin request, so it may arrive without
  `scan_id`.

There are no heartbeats. A run that is still uploading and a run that died look
the same until the next upload with that `scan_id` arrives, or does not.

## What the Server Can Conclude

- **A run** is a begin, the uploads that carry its `scan_id`, and an `end` or
  `interrupted` with the same `scan_id`. That gives Thunderstorm the grouping
  that THOR's scan ID gives a scan of one system.
- **A run without a closing marker** is still running or ended without notice.
  Collections can run for days, so there is no natural time limit. The server
  needs its own rule to call a run abandoned, for example the time since the
  last upload with that ID.
- **Counters come from the client.** `submitted` counts the 2xx answers the
  collector received. The server may have stored more samples under the ID (a
  retry after a lost answer delivers the same file again) or fewer (if it lost
  state). Compare the numbers, but do not expect them to be equal.
- **Timestamps come from the client clock**, which can be wrong. Record the
  server's receive time as well.
- **`source` does not identify a run or a host.** Several runs share it (cron),
  can overlap (a slow run and the next scheduled one), or come from different
  hosts with the same label. Only `scan_id` separates them.
- **Uploads without `scan_id`** come from collectors without markers, from older
  script versions and from runs whose begin answer had no usable ID. They must
  keep working as they do today.

## Questions for the Server Design

The collectors leave these to the server:

- **ID format.** Should the ID use THOR's scan ID format, so that sample log
  lines carry it in the same field as the lines of a THOR scan?
- **Where the ID appears.** Per-sample log lines, `/api/getAsyncResults`, the
  queue and sample history, syslog and SIEM output.
- **Run records.** Does the server keep a table of runs with their state (open,
  ended, interrupted, abandoned), their counters and the number of samples
  received? Does it survive a restart?
- **Abandoned runs.** Which rule closes a run that never sends a closing marker?
- **Unknown IDs.** Accept and log uploads with an unknown or closed `scan_id`
  (required above), or also flag them?
- **Reporting.** Should runs be listed by an API endpoint or in the web
  interface?

## Testing

| Test | What it covers |
|---|---|
| [Stub server](https://github.com/Nextron-Labs/thunderstorm-stub-server) | Implements the endpoint for collector tests. Writes a `collection_marker` entry per marker to its JSONL log. `--strict` rejects markers without `type`, `source`, `collector` or `timestamp`. Does not read `scan_id` on uploads. |
| [run_operational_tests.sh](../scripts/tests/run_operational_tests.sh) | Sends begin, end and interrupted markers from the script collectors to the stub server. |
| `scripts/tests/test_*_robustness.py` | Per language, with local fake servers: 404 and 501, failed and malformed begin answers, failed end markers, interruption by signals. Checks that marker answers stay out of the log and the exit code unless the debug option is set. The [testing overview](COLLECTOR_TESTING_OVERVIEW.md) explains how to run them. |
| `go/markers_test.go`, `sftp/markers_test.go` | The same answers for the Go and SFTP collectors. |
| [test-legacy-runtime.py](../.github/scripts/test-legacy-runtime.py) | Go 1.9.7 runtime check for the NetScaler package: runs the Go binary against a server that answers 404 and one that returns a scan ID. |

To watch the markers against a development server, run a script collector on a
small directory:

```bash
python3 scripts/python/thunderstorm-collector.py --server 127.0.0.1 --port 8080 \
    --dir /tmp/marker-test --source marker-test --max-age 0
```

## Why Markers Exist

When THOR scans a system, every log line of that scan carries the scan ID of
the run. Thunderstorm has no such run. A collector sends one file per request,
labeled only with a `source` value, which is usually the host name.

A collector started every night by cron sends the same `source` every night, and
one run can take minutes or days. The server cannot tell whether two samples
came from the same run, from consecutive runs, or from two runs that overlap.

Markers close that gap. The collector announces the start of a run, receives a
run ID from the server, attaches it to every upload, and reports the end or the
interruption of the run together with its counters.

## History

Markers were added to the script collectors in February 2026, together with a
first specification in the stub repository,
[COLLECTOR_SESSIONS.md](https://github.com/Nextron-Labs/thunderstorm-stub-server/blob/main/COLLECTOR_SESSIONS.md).
Its wire format still applies. Where it and this page disagree, this page
describes what the collectors do.

Changes since the first specification that matter to a server:

- **Failure handling.** For a while, a failed begin other than 404 or 501
  stopped a script collector's run, and a failed end made the exit code 1.
  Since November 2026 the collectors follow the first specification again: a
  marker answer never aborts a collection or changes its exit code, and only the
  debug option shows it. A begin that gets no HTTP answer at all still stops the
  script collectors, as their connectivity check.
- **`interrupted`** was added as a third type. The first specification listed an
  `abort` type as a future idea.
- **New fields:** `hostname`, `stats.scan_errors` and `stats.in_flight`.
- **`scan_id` in `end`** is left out when begin produced none. The first
  specification marked it as required.
- **Collector version strings** have changed.
- **Batch** dropped markers in March 2026 when it stopped depending on
  PowerShell.
- **Go and SFTP** gained markers in November 2026.
