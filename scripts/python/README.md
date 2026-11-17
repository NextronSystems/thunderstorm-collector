# Python Collectors

Upload files to a THOR Thunderstorm service for analysis. Both scripts need
only the standard library and take the same options:

- [thunderstorm-collector.py](thunderstorm-collector.py): Python 3.4 or later;
  prefer it
- [thunderstorm-collector-py2.py](thunderstorm-collector-py2.py): Python 2.7

Alternatives: [script chooser](../README.md#choosing-a-collector) ·
[ESXi notes](../README.md#vmware-esxi-use-the-python-collector) ·
[scanning without a collector](../../docs/SCANNING_APPROACHES.md)

> [!NOTE]
> Tested against real THOR with Python 3.9.6, 3.4.10 and 2.7.18; ESXi and other
> legacy OS or SSL builds are not yet tested
> ([validation status](TESTING.md#validation-status)). For release downloads,
> see the [download guidance](../../README.md#download-a-collector).

## Requirements

| Requirement | Python 3 file | Python 2 file |
|---|---|---|
| Python | 3.4 or later | 2.7 |
| Verified HTTPS | Supported | **2.7.9** or later; older versions refuse it |

## Quick Start

Copy `thunderstorm-collector.py` to the system, change to its directory and
preview the selection with your server and directory:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123 --dry-run
```

The preview contacts no server and does not check readability. If the list
looks right, upload:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123
```

For Python 2.7, run `thunderstorm-collector-py2.py` instead. For HTTPS, add
`--tls` and the HTTPS port.

By default, the collector takes files changed in the **last 30 days**, up to
**2048 KiB (2 MiB)**.

## Configuration

Edit defaults in the top `USER CONFIGURATION` block; options override them.

- **Server:** `THUNDERSTORM_SERVER`; a hostname or IP address, no scheme, port
  or path. Required.
- **Directories:** `SCAN_DIRS` defaults to the **filesystem root**; set
  explicit roots. The first `--dir` replaces the list; more `--dir` options add
  to it.
- `--no-tls`, `--verify-tls`, `--no-dry-run` and `--no-debug` reverse header
  settings.

## Common Options

`--help` lists all options.

| Option | Default | Purpose |
|---|---|---|
| `-s`, `--server HOST` | none | Thunderstorm server |
| `-p`, `--port PORT` | 8080 | Server port |
| `-d`, `--dir`, `--dirs PATH` | `/` | Directory to collect; repeatable |
| `--max-age DAYS` | 30 | Modified within N days; `0` disables |
| `--max-size-kb KIB` | 2048 | Largest file, inclusive |
| `-S`, `--source NAME` | hostname | Source name |
| `--dry-run` | off | List files, send nothing |
| `-t`, `--tls` | off | Use HTTPS |
| `--ca-cert FILE` | system trust | PEM CA file for HTTPS |
| `-k`, `--insecure` | off | No TLS verification; testing only |
| `--retries N` | 3 | Attempts per file, 1 to 10 |
| `--server-wait SEC` | 600 | Wait for a lost server, 0 to 86400; `0` stops at once |

Progress shows on a terminal; `--no-progress` hides it. `--async` is ignored.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All selected files accepted, or a successful dry run |
| `1` | Failed files, scan errors (such as one missing root), interruption, or server unreachable for `SERVER_WAIT` |
| `2` | Invalid configuration, wrong Python version, no usable root, or no HTTP answer to the begin marker |

Unreadable directories count as `Scan errors`, unreadable files as `Failed`.

## Behavior Details

### File selection

- Recursive, regular files only; symlinks and special files are skipped.
- **Age** uses modification time. **Size** is inclusive; empty files count.
- **Excluded:** `/proc`, `/dev`, `/sys`, `/run`, `/snap`, `/.snapshots`, `/mnt`
  (WSL drives, mounted shares), `.dat`, `.npm`, VM files (`.vmdk`, `.vswp`, `.nvram`, `.vmsd`, `.lck`),
  cloud-sync folders and Linux network or special mounts. Best effort only.
- **Mounts are skipped by path:** excluded trees and the network or special
  mounts in `/proc/mounts` are skipped before any stat, so an unresponsive hard
  NFS mount below a scan root cannot block the walk; a scan root that is itself
  on such a mount still can. Other filesystem types (such as `ceph` or
  `glusterfs`), and every mount on systems without `/proc/mounts`, are walked
  like local directories.
- `/proc/mounts` is read as bytes, so non-ASCII mount paths also work under the
  C/POSIX locale of cron jobs, systemd units and many SSH sessions; a non-ASCII
  `--source` is then sent as the same UTF-8 text.

### Uploads

- Each file is read into memory first; a file that changes meanwhile fails.
- Uploads use `/api/checkAsync`: a 2xx answer means accepted, not analyzed.
- Retry waits double, up to 60 s. HTTP 503 honors `Retry-After`, up to 120 s.
- **Lost server:** when 3 files in a row could not be delivered (no attempt got
  an HTTP answer other than 503), the collector stops sending and checks
  `/api/status` after 2, 4, 8 … up to 60 s, for at most `SERVER_WAIT` seconds. A
  2xx answer resumes with the next file; failed files stay failed. When the time
  runs out, it logs `Thunderstorm unreachable for N seconds`, sends an
  "interrupted" marker, skips the remaining files and exits 1. A dry run never
  waits.
- Quotes, semicolons and control characters in the sent file name become `_`.

### TLS

- `--tls` verifies certificate and host name. `--ca-cert` and `--insecure` need
  `--tls`.
- **Python before 2.7.9** refuses verified HTTPS (exit 2) instead of skipping
  verification.

### Collection markers

Marker problems are shown only with `--debug` and never change the exit code.
Exception: if the begin marker gets no HTTP answer on both attempts, the run
exits with 2 before uploading. SIGINT or SIGTERM sends an "interrupted"
marker if possible. See
[collection markers](../../docs/COLLECTION_MARKERS.md).

### Logging and limits

- Logs go to stderr only, starting with roots and limits. When piping to
  `tee`, check the collector's own exit code.
- Idle timeouts: uploads 30 s, markers 10 s; a slow, steady upload continues.
- Answers over 1 MiB, incomplete or not HTTP/1.x fail.

## Limitations

- Files are read from a live filesystem, not a snapshot.
- No deduplication, resume or extension filter.
- Retries after a lost answer can duplicate uploads.
- Windows paths need testing on the target.

## Testing

[TESTING.md](TESTING.md): manual acceptance cases and automated tests.
