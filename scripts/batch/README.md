# Windows Batch Collector

[thunderstorm-collector.bat](thunderstorm-collector.bat) uploads files from a
Windows system to a THOR Thunderstorm service, which analyzes them. Use it when
the Go and PowerShell collectors are impractical. It does not scan files
locally.

The file is a cmd/JScript hybrid: Windows Script Host (WSH) handles the file
data, and curl sends it.

Other collectors: [script chooser](../README.md#choosing-a-collector). If
running a collector is impractical, compare
[SSHFS scanning from an analysis workstation and offline analysis](../../docs/SCANNING_APPROACHES.md);
SSHFS needs suitable SSH/SFTP access on the source, but no local collector.

> [!NOTE]
> Synthetic Windows CI checks with real cmd, WSH and curl only; not yet tested
> against real THOR. Native old Windows/WSH and the packaged file need
> acceptance on the target system. This guide describes the current source;
> for a published asset, check the
> [release availability note](../../README.md#download-a-collector), because
> older releases have different options.
> [Validation status](TESTING.md#validation-status)

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | `cmd.exe` with enabled WSH/JScript, FileSystemObject and ADODB.Stream; no PowerShell needed |
| Upload tool | Trusted **curl.exe 8.4 or later** that supports the Windows version |
| Service | HTTP/HTTPS Thunderstorm, no authentication |

curl must be 8.4 or later because earlier versions cannot bound response
downloads of unknown length with `--max-filesize`.

**Never** disable organizational WSH policy just to run this collector.

Sources: [curl --max-filesize](https://curl.se/docs/manpage.html#--max-filesize)

## Quick Start

1. Copy `thunderstorm-collector.bat` from the source checkout to a working
   directory on the target.
2. Open `cmd.exe /d /v:off` and change to that directory.
3. Replace the server, the curl path and `C:\Samples` with your server, a
   trusted curl.exe and an existing absolute directory with a few test files.
   Then preview the selection:

```cmd
set "THUNDERSTORM_SERVER=thunderstorm.example.internal"
set "THUNDERSTORM_PORT=8080"
set "URL_SCHEME=http"
set "CURL_PATH=C:\trusted-tools\curl.exe"
set "COLLECT_DIRS=C:\Samples"
set "SOURCE=host-example"
set "MAX_AGE=14"
set "COLLECT_MAX_SIZE=2097152"
set "DRY_RUN=1"
.\thunderstorm-collector.bat
```

The preview sends no requests. It does not check curl, whether files are
readable, or whether TLS works. If the file list looks right, upload in the same
session:

```cmd
set "DRY_RUN=0"
.\thunderstorm-collector.bat
```

- **HTTPS:** set `URL_SCHEME=https` and the server's HTTPS port. For a private
  CA, set `CURL_CA_BUNDLE` to a PEM file.
- **Results:** uploads are asynchronous. Check received files and analysis
  results on the server.

## Configuration

Settings come from the commented JScript `USER CONFIGURATION` block just below
the launcher, or from environment variables of the same names.

- **Precedence:** a nonempty environment variable overrides the header value.
  Use `0` to turn a header flag off.
- **Required:** `THUNDERSTORM_SERVER` and `COLLECT_DIRS`. If either is missing,
  the collector exits with **2** and instructions. There is no implicit broad
  scan.
- **Server:** a hostname or IP address only: no scheme, port or path.
- **Backslashes:** double them in quoted script values, e.g.
  `var COLLECT_DIRS = "C:\\Samples;D:\\Evidence";`. In cmd, use ordinary
  paths: `set "COLLECT_DIRS=C:\Samples;D:\Evidence"`.
- **Launcher:** leave the lines above the configuration block unchanged.

At startup, the collector prints the resolved roots, the limits and the selected
extensions, also with `DRY_RUN=1`. By default it collects files changed in the
**last 30 days** and up to **2097152 bytes (2 MiB)**.

## Common Settings

This is the complete list; the configuration block comments each setting.

| Setting | Default | Purpose |
|---|---|---|
| `THUNDERSTORM_SERVER` | none | Thunderstorm server; required |
| `THUNDERSTORM_PORT` | 8080 | Server port, 1 to 65535 |
| `URL_SCHEME` | `http` | `http` or `https` |
| `CURL_CA_BUNDLE` | curl/system trust | PEM CA file for HTTPS |
| `SOURCE` | computer name | Source name shown in Thunderstorm |
| `COLLECT_DIRS` | none | Directories to collect recursively, separated by `;`; required |
| `MAX_AGE` | 30 | Days since last modification, 0 to 36500; `0` disables the filter |
| `COLLECT_MAX_SIZE` | 2097152 | Largest file in **bytes**, inclusive, 1 to 209715200 |
| `RELEVANT_EXTENSIONS` | `.exe;.dll;.ps1;.bat;.txt` | Suffixes to collect; `*` collects all |
| `UPLOAD_ATTEMPTS` | 3 | Total upload attempts per file, 1 to 10 |
| `SERVER_WAIT` | 600 | Seconds to wait for an unreachable server, 0 to 86400 |
| `DRY_RUN` | 0 | `1` lists files without contacting the server |
| `CURL_PATH` | search | Trusted path to curl.exe 8.4 or later |

There are no collection-marker, insecure-TLS, progress or debug settings.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Run completed without failed uploads or scan errors |
| `1` | Partial failure (failed uploads or scan errors, such as one missing root), service unreachable for `SERVER_WAIT`, or temporary directory not removed |
| `2` | Invalid configuration, no usable roots, or missing dependency such as curl 8.4 or later |

WSH launch failures can return host-specific nonzero codes.

The summary line reports `Checked`, `Submitted`, `Failed`, `Skipped` and
`Scan errors`.

## Behavior Details

### File selection

- **Walk:** recursive, literal file names. Reparse points and junctions are
  skipped. This is not a filesystem sandbox.
- **Deduplicated files:** FileSystemObject shows no reparse tag, so Data
  Deduplication files are skipped like links. The run ends with a warning that
  counts them. Use the [PowerShell collector](../powershell/README.md) on
  deduplicated volumes.
- **Compressed files** (CompactOS, `compact /exe`) appear as ordinary files and
  are collected.
- **Cloud folders:** known cloud directory names are excluded.
- **Age:** based on last **modification time**.
- **Size:** in **bytes**, inclusive. Empty files are included.
- **Roots:** `COLLECT_DIRS` separates roots by semicolons, so a root containing
  a semicolon is not supported. Inside a root, file names with semicolons,
  commas, spaces, Unicode, percent signs, exclamation marks, brackets and
  ampersands are supported.
- **Vanishing entries:** an entry that vanishes or cannot be read during the
  walk is counted on its own: a file as failed, a subdirectory as a scan error.
  The rest of its directory is still processed.
- **32-bit process on 64-bit Windows:** file-system redirection shows
  `%SystemRoot%\SysWOW64` as `%SystemRoot%\System32`, so the real System32 is
  not collected. The collector logs a warning. Start it from a 64-bit command
  prompt; from a 32-bit host: `%SystemRoot%\SysNative\cmd.exe`.

### curl discovery

1. `CURL_PATH`, if set
2. The script's directory
3. The Windows system directory
4. `PATH`

The current working directory is never searched implicitly. Prefer an explicit
`CURL_PATH`.

### Uploads and retries

- Each file is copied into a snapshot and sent as one binary-safe multipart
  file to asynchronous `/api/checkAsync`. The collector does not poll analysis
  results.
- Success means the transfer was accepted, **not** that analysis finished or
  produced a finding.
- The user's curl configuration file and proxy settings are ignored.
- The source name is sent UTF-8 percent-encoded.
- `UPLOAD_ATTEMPTS` counts **total** attempts, including the first. A 503
  `Retry-After` value in whole seconds is honored, capped at **120 seconds**;
  without one the collector waits 2 seconds.
- Backslashes, quotes, semicolons and control characters in the uploaded file
  name become underscores. The file contents are unchanged.

### Server loss

After **3 files in a row** got no answer other than 503 (busy), the collector
stops sending and polls `/api/status`. Polls are 2, 4, 8 and up to 60 seconds
apart, for up to `SERVER_WAIT` seconds (default **600**).

- If the service answers, the run continues with the next file.
- Otherwise the run stops and exits with **1**.
- `SERVER_WAIT=0` stops at once.

An empty set of eligible files does not probe the service.

### TLS

- curl certificate and hostname verification stay on. There is no insecure
  mode.
- `CURL_CA_BUNDLE` is passed explicitly as `--cacert`, also to Schannel builds
  of curl, which ignore the `CURL_CA_BUNDLE` environment setting. The curl build
  and Windows version must support this.
- A TLS failure does not turn off verification or revocation checking. The
  collector changes no machine trust.

Sources: [curl --cacert](https://curl.se/docs/manpage.html#--cacert)

### Collection markers

The Batch collector sends **no** collection markers, by design: no begin, end
or `interrupted` marker and no scan ID. See
[collection markers](../../docs/COLLECTION_MARKERS.md) for the collectors that
do.

### Temporary data and logging

- Non-dry runs create a private per-run directory under `TEMP`. It holds copies
  of the sample payloads and is removed when the run ends normally or with an
  error. If removal fails, the exit code is **1**.
- `TEMP`, curl and CA paths containing percent signs, quotes, line breaks or
  NUL characters are rejected, to avoid WSH process expansion. Choose a
  trusted, ordinary path.
- The collector creates no log file. To keep one, redirect output to a file
  **outside** the collected directories. Redirection replaces the live console
  output.

```cmd
thunderstorm-collector.bat > C:\Logs\collector.log 2>&1
type C:\Logs\collector.log
```

### Timeouts and limits

| Item | Limit |
|---|---|
| curl connect | 10 s |
| Upload attempt | 30 s plus the time to send the body at 64 KiB/s |
| Slow transfer | Ends below 1 KiB/s for 30 s |
| curl process watchdog | 10 s above the upload attempt limit |
| Status polls during server loss | 20 s each |
| Server answer | 1 MiB |

## Limitations

- ADODB loads each selected file into memory. Size and modification-time checks
  catch many changes, but the size limit is **not** a hard memory bound if a
  file grows during the read. Memory use can be several times the file size.
  Use stable files in a trusted tree and enough RAM.
- Keep `TEMP` private. Cleanup does not protect against a hostile shared `TEMP`
  directory or a shutdown; forced termination can leave sample copies behind.
- No collection markers, result polling, deduplication, resume, insecure TLS
  mode, syslog or parallel uploads.

## Testing

[TESTING.md](TESTING.md) has the validation status, the manual acceptance
cases against a real Thunderstorm service and the synthetic fault tests.
