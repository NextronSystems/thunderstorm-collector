# POSIX sh / BusyBox ash Collector

`thunderstorm-collector-ash.sh` uploads files to a THOR Thunderstorm service
from Unix systems without Bash: BusyBox/Alpine, embedded Linux, appliances and
recovery environments. It needs no Python, Perl or Go.

Alternatives: [Bash collector](../bash/README.md) (newline file
names) · [script chooser](../README.md#choosing-a-collector) ·
[SSHFS and offline scanning](../../docs/SCANNING_APPROACHES.md)

> [!NOTE]
> Tested with dash and BusyBox ash; check the shell, utilities and transport on
> your target. This guide describes the current source; for releases, see the
> [download guidance](../../README.md#download-a-collector).

## Requirements

<a id="requirements-and-transport-selection"></a>

| Requirement | Detail |
|---|---|
| Runtime | POSIX `sh`, such as BusyBox ash or dash |
| System tools | `find`, `awk`, `sed`, `grep`, `tr`, `wc`, `od`, `cat`, `date`, `head`, `tail`, `rm`, `mktemp`, `dirname`, `basename`, `uname` |
| Utility features | `od -v -An -tx1` and `head -c BYTES`; a startup self-test exits 2 before any request if they are missing (BusyBox `od` built without `CONFIG_DESKTOP` lacks `-A`/`-t`) |
| Temporary storage | Writable `TMPDIR` (default `/tmp`) |
| Optional | `stat` (else files are read in full to measure size); `hostname`, `id`, `logger` |

The first available upload tool is used:

- **curl** or **GNU wget** (with `--no-config`): HTTP or verified HTTPS, with
  collection markers.
- **`nc` + `timeout`**: plain HTTP only, no markers
  ([netcat transport](#netcat-transport)).
- BusyBox or unknown wget alone is **refused** (exit 2): binary integrity is
  required.

## Quick Start

Preview which files would be uploaded; this contacts no server:

```sh
busybox ash ./thunderstorm-collector-ash.sh \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123 --dry-run
```

If the file list looks right, upload:

```sh
busybox ash ./thunderstorm-collector-ash.sh \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123
```

Use `sh` or `dash` if that is your validated shell. Defaults: files
changed in the **last 30 days**, up to **2048 KiB (2 MiB)**; `--max-age 0`
removes the age filter. Roots and limits are printed first.

## Configuration

Options override the `USER CONFIGURATION` block at the top of the script.

- **Server:** `THUNDERSTORM_SERVER` or `--server`, required (else exit 2). Only
  a DNS name or IPv4 address: no scheme, port, path or IPv6 literal.
- **Directories:** `SCAN_DIRS`, one path per line. The shipped list (`/root`,
  `/tmp`, `/home`, `/var`, `/usr`) is broad; replace it. The first `--dir`
  replaces the list, further ones add to it.
- `--no-ssl`, `--verify-tls`, `--no-dry-run` and `--no-debug` reverse header
  settings.
- **CA certificate:** `--ca-cert` or `CA_CERT` turns on HTTPS. Combined with
  `--no-ssl`, in either order, it exits 2 before any request.

## Common Options

`--help` lists all options.

| Option | Default | Purpose |
|---|---|---|
| `-s`, `--server HOST` | none | Thunderstorm server |
| `-p`, `--port PORT` | 8080 | Server port |
| `-d`, `--dir PATH` | `SCAN_DIRS` | Directory to collect; repeatable |
| `--max-age DAYS` | 30 | Days since modification; `0` disables |
| `--max-size-kb KIB` | 2048 | Largest file, inclusive |
| `--source NAME` | hostname | Source name in Thunderstorm |
| `--dry-run` | off | List files, send nothing |
| `--ssl` | off | Use HTTPS |
| `--ca-cert FILE` | system trust | Use HTTPS and trust only this CA |
| `--retries N` | 3 | Attempts per file, 1 to 10 |
| `--server-wait SEC` | 600 | Wait for a lost server, 0 to 86400; `0` stops at once |
| `--debug` | off | Extra diagnostics, including markers |
| `--log-file PATH` | `./thunderstorm.log` | `--no-log-file` disables it |

`--async` is accepted and ignored.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | No errors detected (an empty directory is fine) |
| `1` | Failed file, scan error, missing root, interruption, or server unreachable for the whole server wait |
| `2` | Invalid configuration, missing tool or utility feature, unusable workspace, or no HTTP answer to the begin marker |

The summary counts `failed` files (unreadable or not uploaded) and
`scan_errors` (missing roots, traversal errors, rejected paths). With `nc`
(no begin marker), an unreachable server fails three files, then waits up to
`--server-wait` seconds and exits **1**.

## Behavior Details

### File selection

- **Walk:** recursive, regular files, all extensions. Symlinks are not
  followed; a symlinked root resolves to its physical path.
- **Age:** modification time (`find -mtime -N`, 24-hour periods).
- **Size:** up to `N * 1024` bytes, including empty files.
- **Excluded:** `/proc`, `/sys`, `/dev`, `/run`, `/snap`, `/.snapshots`,
  cloud-sync directories (not file names), and network or special mounts
  (Linux `/proc/mounts` only). Best effort, not a security boundary.
- **Mounts are compared as text:** `/proc/mounts` is read once before the
  begin marker, and mount points are never accessed, so a stale NFS, CIFS or
  sshfs mount outside the roots cannot hang the run. Inside a root, `find` may
  still block on a stale mount before pruning it, and a root on such a mount
  is still walked.
- **Missing roots** are scan errors, shipped ones too.
- **Own files:** the log and the private workspace are never uploaded; the
  workspace is removed on exit. Keep other logs outside the roots.

### Paths with newlines

Not supported. A `--dir`, workspace or log path with a newline exits 2 before
any request. A root resolving to such a path, or a found file with a newline,
is a scan error; such files are never uploaded or split into other paths.

### Uploads and retries

- Uploads use asynchronous `/api/checkAsync`: accepted is not yet analyzed.
- Only a complete HTTP 2xx counts. Redirects are not followed.
- curl/wget configuration files and proxy variables are ignored, so they
  cannot weaken TLS or redirect uploads.
- `--retries` includes HTTP 503 answers. Waits start at 2 s, doubling to 60 s;
  `Retry-After` seconds are honored up to 120 s. A failed file does not stop
  the run.
- **Lost server:** after 3 files in a row got no HTTP status (or only 503),
  uploads pause and `/api/status` is polled after 2, 4, 8 … s (at most 60 s
  apart) for up to `--server-wait` seconds (`SERVER_WAIT`, default 600). A 2xx
  answer resumes with the next file; failed files stay failed. Any other HTTP
  status, including 4xx and 500, means the server is up. When the time runs
  out, the collector logs `Server unreachable for Ns, stopping`, sends an
  "interrupted" marker and exits 1; remaining files are not attempted or
  counted. A dry run never waits.
- Quotes, semicolons, backslashes and control characters in the uploaded file
  name become underscores; contents are unchanged.

### Netcat transport

Needs `nc -w SECONDS HOST PORT` and `timeout SECONDS COMMAND`. BusyBox
`timeout` before 1.30 only accepts `-t SECONDS`: the collector tests
`timeout 5 sh -c :` first and, if that fails, warns and does not use nc (exit 2
without another transport). Traffic is
unencrypted, so use an isolated network. The answer needs one
`Content-Length`, no `Transfer-Encoding` and the full body; chunked,
close-delimited or incomplete answers fail.

### TLS

Verification is on by default. `--ca-cert` turns on HTTPS and makes that
bundle the **only** trusted CA; with `--no-ssl` it is a configuration error
(exit 2). `-k`, `--insecure` disables verification: testing only.

### Collection markers

Begin and end [collection markers](../../docs/COLLECTION_MARKERS.md)
(`/api/collection`) return a scan ID that tags uploads.

- HTTP 404 or 501 (no support, as in THOR 10): no scan ID, the run continues.
- Any other non-2xx begin result, or no answer, is retried once after 2 s.
- Marker problems show only with `--debug` and never change the exit code,
  except: no HTTP answer to either begin attempt stops the run with exit 2.

### Dry run

`--dry-run` sends **no requests** and needs no upload tool; `submitted`
then means "would submit".

### Logging

- An unwritable log file turns file logging off with a warning.
- If the console goes away (an SSH session without a terminal, or a `| tee`
  ended with Ctrl-C), console output stops; the run continues with file and
  syslog logging, markers and cleanup.
- SIGINT, SIGTERM, SIGHUP or SIGQUIT: best-effort "interrupted" marker,
  workspace removed, exit 1.

### Timeouts and limits

| Item | Limit |
|---|---|
| curl | 10 s connect, 60 s total |
| GNU wget | 10 s connect, 60 s idle read (no total deadline) |
| `nc` | 60 s |
| Markers | 10 s per request |
| `/api/status` polls | 10 s per request (15 s with `nc`) |
| Server answer | 1 MiB (2 MiB output file) |
| Logged excerpts | 4 KiB per error body and per root's traversal errors |
| Marker JSON | 64 KiB; scan ID: top-level string, ≤ 256 bytes |

## Limitations

- No snapshot: files can change, or be swapped, during the run.
- No deduplication, resume or parallel upload; a retry can submit a file twice.
- No deadline for the whole run.

## Testing

[TESTING.md](TESTING.md) has the manual acceptance cases and automated tests.
