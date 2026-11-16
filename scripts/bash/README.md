# Bash Collector

`thunderstorm-collector.sh` uploads files from a Unix system to a THOR
Thunderstorm service, which analyzes them. Use it when Bash is available but the
Go collector is not practical. It does not scan files locally.

- Other collectors: [script chooser](../README.md#choosing-a-collector)
- BusyBox or plain `sh`: [ash collector](../ash/README.md)
- Nothing can run on the system: [scanning approaches](../../docs/SCANNING_APPROACHES.md)

> [!NOTE]
> This guide describes the current source. For a release download, check the
> [download guidance](../../README.md#download-a-collector) and use the guide
> from that release.

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | Bash 3.2 or newer; not `sh`, `dash`, or BusyBox ash |
| Upload tool | `curl` (preferred) or **GNU wget** with `--no-config`, not BusyBox wget |
| System tools | GNU/BSD `find`, `stat`, `mktemp`, and standard Unix text utilities |
| Permissions | Only files readable by the current user can be uploaded |
| Service | HTTP/HTTPS Thunderstorm; no built-in HTTP authentication options |

Python, jq and GNU coreutils on macOS are not needed.

## Quick Start

Copy the script to the system and change to its directory. Replace the server
and the directory, then preview which files would be uploaded:

```bash
bash ./thunderstorm-collector.sh \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123 --dry-run
```

The preview contacts no server. If the file list looks right, upload:

```bash
bash ./thunderstorm-collector.sh \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123
```

At startup, the collector prints each root directory and the effective limits.
By default it collects files changed in the **last 30 days** and up to
**2048 KiB (2 MiB)**. Use `--max-age 0` to collect files of any age.

## Configuration

Settings come from the `USER CONFIGURATION` block at the top of the script.
Command-line options override them.

- **Server:** set `THUNDERSTORM_SERVER` or use `--server`. Give only a DNS
  name, IPv4 address or bracketed IPv6 address: no scheme, port, credentials
  or path. Anything else is rejected before any request. Without a server, the
  collector stops with exit 2.
- **Directories:** set `SCAN_FOLDERS=("/var/www" "/home/alice")`. If it is
  empty, the [default directories](#file-selection) apply. The first `--dir`
  replaces the whole list; further `--dir` options add to it.
- **Turning off header settings:** `--no-ssl`, `--verify-tls`, `--no-dry-run`
  and `--no-debug` reverse the matching settings in the block.

## Common Options

`--help` lists all options.

| Option | Default | Purpose |
|---|---|---|
| `-s`, `--server HOST` | none | Thunderstorm server |
| `-p`, `--port PORT` | 8080 | Server port |
| `-d`, `--dir PATH` | [defaults](#file-selection) | Directory to collect; repeatable |
| `--max-age DAYS` | 30 | Days since last modification; `0` disables the filter |
| `--max-size-kb KIB` | 2048 | Largest file to upload, inclusive |
| `--source NAME` | hostname | Source name shown in Thunderstorm |
| `--dry-run` | off | List files without contacting the server |
| `--ssl` | off | Use HTTPS |
| `--ca-cert FILE` | system trust | Use HTTPS and trust only this CA bundle |
| `--retries N` | 3 | Upload attempts per file, 1 to 10 |
| `--server-wait SEC` | 600 | Wait for a lost server to come back; `0` stops at once |
| `--debug` | off | Explain each decision, including marker problems |
| `--log-file PATH` | `./thunderstorm.log` | Log file; `--no-log-file` disables it |
| `--syslog` | off | Also log to syslog |
| `--quiet` | off | No console output |

`--async` is accepted and ignored so existing command lines keep working.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Completed without detected errors; an empty readable directory is valid |
| `1` | Partial failure, incomplete scan, missing root, interrupted run, or server lost for longer than `SERVER_WAIT` |
| `2` | Invalid configuration, missing upload tool, unusable workspace, or no HTTP answer to the begin marker |

The summary line reports `scanned`, `submitted`, `skipped`, `failed` and
`scan_errors`. `failed` counts files that could not be uploaded; `scan_errors`
counts directories that could not be fully read.

## Behavior Details

### File selection

- **Default directories:** `/root`, `/tmp`, `/home`, `/var`, `/usr`; on macOS,
  `/Users`, `/tmp`, `/var`, `/usr`. Missing defaults are skipped; a missing
  directory you named is an error.
- **Walk:** recursive, regular files only. Symlinks are not followed. Named
  directories are resolved to their physical absolute paths.
- **Age:** based on **modification time**, not creation time (`find -mtime -N`).
- **Size:** files up to `N * 1024` bytes, including empty files. Larger files
  count as skipped.
- **Skipped directories:** known pseudo-filesystems and cloud-sync folders.
  Cloud names match directories only, so a file called `OneDrive-Setup.exe` is
  still collected.
- **Network mounts:** detected from `/proc/mounts` on Linux only. On macOS and
  other Unix systems, name local directories explicitly. Mount points are
  compared with the roots as text and never accessed, so a hung network mount
  outside the roots does not stall the run. The exclusions are built before the
  begin marker is sent.
- **Own files:** the collector's log file and its private temporary workspace
  are never uploaded; the workspace is removed on every exit the shell handles,
  including after a signal. Keep other captured logs outside the collected
  directories.

### Uploads and retries

- Uploads use asynchronous `/api/checkAsync`. An accepted upload does not mean
  the analysis has finished.
- Only a complete HTTP 2xx answer counts as success. Redirects are not
  followed.
- curl and wget configuration files and proxy environment variables are
  ignored, so they cannot disable TLS checks or redirect uploads.
- Each file gets three attempts by default, with capped exponential backoff.
- HTTP 503 has a separate budget of five answers. A `Retry-After` value in
  seconds is honored, capped at 120 seconds. A missing value or an HTTP date
  waits two seconds.
- **Server loss:** when three files in a row get no HTTP answer (refused,
  timeout, reset) or use up their 503 budget, the collector takes no new file
  and polls `/api/status` after 2, 4, 8 … seconds (at most 60 apart) for up to
  `SERVER_WAIT` seconds (default 600, `--server-wait`). A 2xx answer resumes
  with the next file; files that already failed stay failed. When the time runs
  out, it logs `Server unreachable for N s, stopping`, sends an "interrupted"
  marker and exits 1; files not attempted are not counted. Any other HTTP
  answer, such as 500, resets the count. A dry run never waits.
- A failed file does not stop the run. It makes the exit code nonzero.
- Quotes, semicolons, backslashes and control characters in the uploaded file
  name become underscores. The file contents are unchanged.

### TLS

- Certificate verification is on by default.
- `--ca-cert FILE` (or `CA_CERT` in the header) turns on HTTPS, even with
  `USE_SSL=0`, and makes that bundle the **only** trusted CA; system CAs are not
  added.
- `--no-ssl` together with a CA certificate is a configuration error (exit 2),
  so samples never go out over plain HTTP while a CA is configured.
- `--insecure` turns verification off. Use it for testing only, not to work
  around a certificate error.

### Collection markers

The collector tells the server when a run begins and ends, and tags uploads with
the scan ID the server returns.

- THOR 10 and current THOR 11 do not support markers. The run continues without
  a scan ID; `--debug` shows why.
- Marker problems never change the exit code, with one exception: if the begin
  marker gets no HTTP answer on both attempts, the run stops with exit 2 before
  uploading.

See [collection markers](../../docs/COLLECTION_MARKERS.md) for the protocol.

### Dry run

`--dry-run` sends **no HTTP requests**, including markers, and works without an
upload tool. In the summary, `submitted` means "would submit".

### Logging

- Logging to `./thunderstorm.log` is on by default. If both `--log-file` and
  `--no-log-file` are given, the last one wins.
- `--syslog`, `--debug` and progress output are optional.
- On SIGINT, SIGTERM, SIGHUP or SIGQUIT, the collector tries to send an
  "interrupted" marker and exits with 1.
- If the console goes away (a dropped SSH session without a terminal, or a pipe
  reader such as `tee` that ends), the run continues: console output stops,
  file and syslog logging go on.

### Timeouts and limits

| Item | Limit |
|---|---|
| curl | 10 s to connect, 300 s per upload |
| GNU wget | 10 s to connect, 300 s read timeout (not a total deadline), one attempt per call |
| Marker requests, `/api/status` probes | 10 s each; begin is tried twice |
| Server answer | 1 MiB; a larger upload answer fails, a larger marker answer is ignored |
| Transport output file | 2 MiB, including headers and diagnostics |
| Logged error body | 4 KiB |
| Parsed marker JSON | 64 KiB; larger answers give no scan ID |
| Scan ID | One top-level JSON string, at most 256 bytes, no control characters; anything else is ignored |

Prefer curl: a wget read timeout does not end an upload to a server that keeps
sending data.

## Limitations

- The walk reads a live filesystem, not a snapshot. Files can change between
  selection and upload. Symlink checks do not protect against a hostile process
  swapping files during the run.
- Overlapping directories upload the same file more than once. There is no
  deduplication, resume, content-type filter or parallel upload.
- A retry after an unclear network failure can submit a file twice.
- SIGKILL, power loss or a hanging filesystem can prevent cleanup and the end
  marker.
- Large collections and repeated busy answers take much longer than a test run.

## Testing

[TESTING.md](TESTING.md) has the manual acceptance cases against a real
Thunderstorm service and the automated test commands.
