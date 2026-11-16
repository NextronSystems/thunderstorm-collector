# PowerShell Collectors

The PowerShell collectors upload files from a Windows system to a THOR
Thunderstorm service, which analyzes them. They use .NET and need no curl. They
do not scan files locally.

- [thunderstorm-collector.ps1](thunderstorm-collector.ps1): PowerShell 3 or later
- [thunderstorm-collector-ps2.ps1](thunderstorm-collector-ps2.ps1): standalone
  file for PowerShell 2, with the same parameters

Other collectors: [script chooser](../README.md#choosing-a-collector). If
running a collector is impractical, compare
[SSHFS scanning from an analysis workstation and offline analysis](../../docs/SCANNING_APPROACHES.md);
SSHFS needs suitable SSH/SFTP access on the source, but no local collector.

> [!NOTE]
> Tested against real THOR with PowerShell 7.5.0 on macOS; Windows PowerShell
> 5.1 has synthetic Windows CI checks only. Real PowerShell 2, PowerShell 3 and
> old CLR versions are not yet tested: test the intended Windows/CLR
> combination. This guide describes the current source; for a published asset,
> check the [release availability note](../../README.md#download-a-collector),
> because older releases have different options.
> [Validation status](TESTING.md#validation-status)

## Requirements

| Requirement | `thunderstorm-collector.ps1` | `thunderstorm-collector-ps2.ps1` |
|---|---|---|
| Runtime | PowerShell language 3 or later | PowerShell language 2.0 with Add-Type and the full .NET Framework |
| Collection markers | Supported | Need .NET 3.5 `System.Web.Extensions`; without it markers are off and uploads still work |
| `-CACert`, `-Insecure` | .NET 4.5 or later | .NET 4.5 or later |
| Service | HTTP/HTTPS Thunderstorm, no authentication | Same |

Old systems without TLS 1.2 may not connect to modern HTTPS servers.

## Quick Start

1. Copy `thunderstorm-collector.ps1` (or `thunderstorm-collector-ps2.ps1` for
   PowerShell 2) from the source checkout to a working directory on the target.
2. Open a new PowerShell session and change to that directory.
3. Replace the server and `C:\Samples` with your server and an existing
   absolute directory with a few test files, then preview the selection:

```powershell
.\thunderstorm-collector.ps1 -ThunderstormServer thunderstorm.example.internal `
  -ThunderstormPort 8080 -Folder 'C:\Samples' -Source 'host-example' `
  -MaxAge 14 -MaxSize 2 -DryRun
```

The preview sends no requests. It does not check whether files are readable or
whether TLS works. If the file list looks right, upload:

```powershell
.\thunderstorm-collector.ps1 -ThunderstormServer thunderstorm.example.internal `
  -ThunderstormPort 8080 -Folder 'C:\Samples' -Source 'host-example' `
  -MaxAge 14 -MaxSize 2 -DryRun:$false
```

- **HTTPS:** add `-UseSSL` and the server's HTTPS port. For a private CA, add
  `-CACert` (.NET 4.5 or later), see [TLS](#tls).
- **Execution policy:** follow your organization's policy for downloaded
  scripts. Run the collector as a script; do not dot-source it.
- **Results:** uploads are asynchronous. Check received files and analysis
  results on the server.

## Configuration

Each file has a commented `USER CONFIGURATION` parameter block at the top.
Named parameters override its defaults.

- **Server:** a hostname or IP address only: no scheme, port or path. Without
  a server, the collector exits with **2** and instructions.
- **Directories:** the shipped default is **`C:\`**. Always pass explicit
  roots, for example `-Folder 'C:\Samples','D:\Evidence'`. `-Folder` replaces
  the whole list.
- **Extensions:** `Extensions = @()` uses the `DefaultExtensions` list just
  below the parameters. A nonempty list replaces it; `-AllExtensions` turns
  suffix filtering off. Directory exclusions still apply.
- **Turning off header switches:** use `-DryRun:$false`, `-UseSSL:$false` and
  so on.

At startup, the collector prints the resolved roots, the limits and the
extension selection, also in a dry run. By default it collects files changed in
the **last 30 days** and up to **2 MiB (2048 KiB)**.

## Common Options

This is the complete list; the parameter block comments each one.

| Parameter | Alias | Default | Purpose |
|---|---|---|---|
| `-ThunderstormServer HOST` | `-TS` | none | Thunderstorm server |
| `-ThunderstormPort PORT` | `-TP` | 8080 | Server port, 1 to 65535 |
| `-Folder PATH[,PATH]` | `-F` | `C:\` | Directories to collect recursively |
| `-Source NAME` | `-S` | computer name | Source name shown in Thunderstorm |
| `-MaxAge DAYS` | `-MA` | 30 | Days since last modification, 0 to 36500; `0` disables the filter |
| `-MaxSize MIB` | `-MS` | 2 | Largest file in **MiB**, inclusive, 1 to 200 |
| `-Extensions LIST` | | `DefaultExtensions` | Suffixes to collect, e.g. `'.exe','.ps1'` |
| `-AllExtensions` | | off | Collect files with any suffix |
| `-DryRun` | | off | List files without contacting the server |
| `-UseSSL` | `-SSL` | off | Use HTTPS with certificate and hostname verification |
| `-CACert FILE` | | system trust | Use this CA certificate for HTTPS; needs `-UseSSL` |
| `-Insecure` | `-k` | off | Turn off TLS verification; testing only |
| `-Retries N` | | 3 | Total upload attempts per file, 1 to 10 |
| `-ServerWait SECONDS` | | 600 | How long to wait for an unreachable server, 0 to 86400 |
| `-Debugging` | `-D` | off | Show marker diagnostics |
| `-Progress` | | off | Print the submitted count; `-NoProgress` overrides it |

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Run completed without failed uploads or scan errors |
| `1` | Partial failure (failed uploads or scan errors, such as one missing root), interruption, or service unreachable for `ServerWait` |
| `2` | Invalid configuration, no usable roots, or no HTTP answer to the begin marker |

Marker HTTP answers never set the exit status. Parser or runtime launch errors
can return the interpreter's own code.

The summary line reports `Checked`, `Submitted`, `Failed`, `Skipped` and
`Scan errors`.

## Behavior Details

### File selection

- **Walk:** recursive, literal paths. Junctions and symlinks are not followed.
- **Reparse-point files** are skipped, except Data Deduplication, Windows
  Overlay Filter (CompactOS, `compact /exe`) and Single Instance Storage files.
  Their content is ordinary file data and is read normally.
- **Cloud folders:** known cloud folder names are excluded, even when named as
  a root.
- **Age:** last **modification time** (UTC) at or after the start time minus
  `MaxAge` days. A newer creation time does not override an old modification
  time.
- **Size:** inclusive, in MiB; out-of-range values are rejected, not clamped.
  Empty files are included.
- **Snapshots:** each file is read into memory under a Windows read lock before
  connecting, then checked for size and modification-time changes. Memory use
  can be several times the largest selected file.
- **32-bit PowerShell on 64-bit Windows:** file-system redirection shows
  `%windir%\SysWOW64` as `%windir%\System32`, so the real System32 is not
  collected. The collector prints a warning. Use 64-bit PowerShell; from a
  32-bit host: `%windir%\SysNative\WindowsPowerShell\v1.0\powershell.exe`.

### Uploads and retries

- Uploads use asynchronous `/api/checkAsync` as one binary-safe multipart file.
  The collector does not poll analysis results. Success means the upload was
  accepted, **not** that analysis finished or produced a detection.
- Redirects are not followed, and no proxy is used.
- `Retries` counts **total** attempts, also for HTTP 503. A 503 `Retry-After`
  in whole seconds is honored, capped at **120 seconds**; otherwise the
  collector waits 2 seconds.
- Backslashes, quotes, semicolons and control characters in the uploaded file
  name become underscores. The file contents are unchanged.

### Server loss

After **3 files in a row** got no answer other than 503 (busy), the collector
stops sending and polls `/api/status`. Polls are 2, 4, 8 and up to 60 seconds
apart, for up to `ServerWait` seconds (default **600**).

- If the service answers, the run continues with the next file.
- Otherwise the run stops, sends a best-effort `interrupted` marker and exits
  with **1**.
- `-ServerWait 0` stops at once.

### TLS

- Certificate **and** hostname verification are on by default. TLS 1.2 is
  enabled where the OS and .NET support it.
- Process-wide validation overrides left by other scripts in the session
  (`ServicePointManager` callback, legacy `CertificatePolicy`) are cleared for
  the run and restored afterwards. The collector installs no global trust.
- `-CACert` takes one public root certificate (PEM or DER). The chain must end
  at that root; intermediates sent by the server are used to build it. The
  hostname check, validity and server-auth usage are still checked;
  **revocation is not checked** in this mode.
- `-Insecure` turns verification off and prints a warning. Use it for testing
  only.
- `-CACert` and `-Insecure` need per-request callbacks (.NET 4.5 or later).
  An older CLR rejects them with exit 2; use OS trust there.

### Collection markers

The collector sends begin and end markers to `/api/collection` and tags uploads
with the scan ID the server returns.

- HTTP 404 or 501 turns markers off for the run. THOR 10 and current THOR 11
  answer 404.
- Any other HTTP answer to begin, after one retry, is ignored; uploads go
  without a scan ID.
- Marker problems never change the exit status, with one exception: if the
  begin marker gets **no HTTP answer** on both attempts (no connection,
  timeout, TLS failure, closed or truncated reply), the run stops with exit 2.
  It is the first contact with the service.
- Only a string `scan_id` at the top level of a JSON object is used. Arrays,
  including one-element arrays, nested IDs and non-string IDs are ignored.
- PowerShell 2 without `System.Web.Extensions` turns markers off; it does not
  parse them with regular expressions.
- Marker problems are shown only with `-Debugging`.

See [collection markers](../../docs/COLLECTION_MARKERS.md) for the protocol.

### Logging

The collector logs to the console only, so it creates no log file it could
upload. To keep a log, record a transcript **outside** the collected
directories:

```powershell
Start-Transcript -Path C:\Logs\collector.log
# run the collector
Stop-Transcript
```

### Timeouts and limits

| Item | Limit |
|---|---|
| Read or write stall | 30 s each |
| Upload attempt | 30 s plus the time to send the body at 64 KiB/s |
| Marker requests | 10 s each; begin is retried once after 2 s |
| Status polls during server loss | 10 s each |
| Server answer | 1 MiB; a larger upload answer fails, a larger marker answer gives no scan ID |

DNS and OS scheduling can add time.

## Limitations

- Link and cloud exclusions are best effort, not a security boundary. Do not
  rely on them for network shares, special files or hostile, changing trees.
- Windows paths are the intended targets. Unix tests use regular, isolated
  fixtures only.
- Use a new PowerShell process for deployment. TLS protocol settings are
  restored on normal exit.
- Ctrl+C is best effort. Forced termination or host shutdown cannot guarantee
  an `interrupted` marker.
- No deduplication, resumable scans, syslog, parallel uploads or retry
  idempotency.

## Testing

[TESTING.md](TESTING.md) has the validation status, the manual acceptance
cases against a real Thunderstorm service and the automated loopback suite.
