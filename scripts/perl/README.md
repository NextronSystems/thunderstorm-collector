# Perl Collector

[thunderstorm-collector.pl](thunderstorm-collector.pl) uploads files from a
Unix-like or legacy system to a THOR Thunderstorm service, which analyzes them.

Alternatives: [script chooser](../README.md#choosing-a-collector) ·
[scanning without a collector](../../docs/SCANNING_APPROACHES.md) ·
[AIX SSHFS guide](../../integration-guides/aix/aix-power7-sshfs-scanning.md)

> [!NOTE]
> Tested against real THOR with Perl 5.34.1 and LWP 6.44. Older Perl and SSL
> builds are not yet tested; test the actual target. For release downloads, see
> the [download guidance](../../README.md#download-a-collector).

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | Perl **5.8.1** or newer |
| Modules | LWP::UserAgent 6+, LWP::Protocol::http, HTTP::Request, JSON::PP, Encode, Sys::Hostname, plus the standard Getopt::Long, Cwd, File::Spec, Fcntl, POSIX |
| HTTPS | LWP::Protocol::https and IO::Socket::SSL with a usable CA store |

Distributions can package JSON::PP and Sys::Hostname separately, even on
current Perl. On Fedora:

```sh
sudo dnf install perl-libwww-perl perl-JSON-PP perl-Sys-Hostname
```

Check the modules without collecting:

```sh
perl -c ./thunderstorm-collector.pl
perl -MLWP::Protocol::https -MIO::Socket::SSL -e 'print "HTTPS modules available\n"'
```

Sources: Fedora packages
[LWP](https://packages.fedoraproject.org/pkgs/perl-libwww-perl/perl-libwww-perl/) ·
[JSON::PP](https://packages.fedoraproject.org/pkgs/perl-JSON-PP/perl-JSON-PP/) ·
[Sys::Hostname](https://packages.fedoraproject.org/pkgs/perl/perl-Sys-Hostname/)

## Quick Start

Copy the script to the system and change to its directory. Replace the server
and the directory, then preview which files would be uploaded:

```sh
perl ./thunderstorm-collector.pl \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123 --dry-run
```

The preview contacts no server and does not check readability. If the list
looks right, upload:

```sh
perl ./thunderstorm-collector.pl \
  --server thunderstorm.example.internal \
  --dir /path/to/collection --source incident-123
```

For HTTPS, add `--ssl` and the HTTPS port.

By default, the collector takes files changed in the **last 30 days**, up to
**2048 KiB (2 MiB)**.

## Configuration

Edit defaults in the top `USER CONFIGURATION` block; options override them.

- **Server:** `$THUNDERSTORM_SERVER`; a DNS name, IPv4 address or bracketed
  IPv6 address, no scheme, port or path. Required.
- **Directories:** `@SCAN_DIRS` defaults to `/`; set explicit roots. The first
  `--dir` replaces the list; more `--dir` options add to it.
- `--no-tls`, `--verify-tls`, `--no-dry-run` and `--no-debug` reverse header
  settings.

## Common Options

`--help` lists all options.

| Option | Default | Purpose |
|---|---|---|
| `-s`, `--server HOST` | none | Thunderstorm server |
| `-p`, `--port PORT` | 8080 | Server port |
| `-d`, `--dir PATH` | `/` | Directory to collect; repeatable |
| `--max-age DAYS` | 30 | Modified within N days; `0` disables |
| `--max-size-kb KIB` | 2048 | Largest file, inclusive |
| `--source NAME` | hostname | Source name; legacy alias `--so` |
| `--dry-run` | off | List files, send nothing |
| `--ssl`, `--tls` | off | Use HTTPS |
| `--ca-cert FILE` | system trust | PEM CA file for HTTPS |
| `-k`, `--insecure` | off | No TLS verification; testing only |
| `--retries N` | 3 | Attempts per file, 1 to 10 |
| `--server-wait SEC` | 600 | Wait for a lost server, 0 to 86400; `0` stops at once |

Progress shows on a terminal; `--no-progress` hides it. `--async` is ignored.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All selected files accepted, or a successful dry run |
| `1` | Failed files, scan errors (such as one missing root), interruption, or server unreachable for `$SERVER_WAIT` |
| `2` | Invalid configuration, missing HTTPS modules, no usable root, or no HTTP answer to the begin marker |

Unreadable directories count as `Scan errors`, unreadable files as `Failed`. A
missing module stops Perl itself, with its own nonzero code.

## Behavior Details

### File selection

- Recursive, regular files only; symlinks and special files are skipped.
- **Age** uses modification time. **Size** is inclusive; empty files count.
- **Excluded:** `/proc`, `/dev`, `/sys`, `/run`, `/snap`, `/.snapshots`, `/mnt`
  (WSL drives, mounted shares), `.dat`, `.npm`, `.lck`, cloud-sync folders and Linux network or special
  mounts. Best effort only.
- **Mounts are skipped by path:** excluded trees and the network or special
  mounts in `/proc/mounts` are skipped before any stat, so an unresponsive hard
  NFS mount cannot block the run. Other filesystem types (such as `ceph` or
  `glusterfs`), and every mount on systems without `/proc/mounts`, are walked
  like local directories.
- Directories are rechecked during the walk; a detected replacement fails.

### Uploads

- Each file is read into memory first; allow several times the size limit in
  RAM. A file that changes meanwhile fails.
- Uploads use `/api/checkAsync`: a 2xx answer means accepted, not analyzed.
- Retry waits double, up to 60 s. HTTP 503 honors `Retry-After`, up to 120 s.
- **Lost server:** when 3 files in a row could not be delivered (no attempt got
  an HTTP answer other than 503), the collector stops sending and checks
  `/api/status` after 2, 4, 8 … up to 60 s, for at most `$SERVER_WAIT` seconds.
  A 2xx answer resumes with the next file; failed files stay failed. When the
  time runs out, it logs `Thunderstorm unreachable for N seconds`, sends an
  "interrupted" marker, skips the remaining files and exits 1. SIGINT or SIGTERM
  during the wait ends the run as an interruption. A dry run never waits.
- Redirects are not followed; proxy environment variables are ignored.
- Quotes, backslashes, semicolons and control characters in the sent file name
  become `_`; invalid UTF-8 in it is replaced. File contents are unchanged.

### TLS

- `--ssl` verifies certificate and host name. `--ca-cert` and `--insecure` need
  `--ssl`; they never fall back to plain HTTP.

### Collection markers

Marker problems are shown only with `--debug` and never change the exit code.
Exception: if the begin marker gets no HTTP answer on both attempts, the run
exits with 2 before uploading. See
[collection markers](../../docs/COLLECTION_MARKERS.md).

On SIGINT or SIGTERM, the current request finishes or times out; then the
collector sends no more files, tries an "interrupted" marker and exits with 1.

### Logging and limits

- Roots, limits and errors go to stderr; there is no log file. When piping to
  `tee`, check the collector's own exit code.
- LWP idle timeouts: uploads 30 s, markers 10 s; not run deadlines.
- Answers over 1 MiB, incomplete or not HTTP/1.x fail. Chunked answers need
  the final zero chunk and trailers; socket EOF does not count.

Sources: [LWP::UserAgent](https://metacpan.org/pod/LWP::UserAgent)

## Limitations

- The path checks are not an atomic sandbox; a hostile process can still race
  them. Use a read-only snapshot or a quiet, trusted tree when that matters.
- No deduplication, resume or extension filter.
- Retries after a lost answer can duplicate uploads.
- Windows Perl builds need testing on the target.

## Testing

[TESTING.md](TESTING.md): manual acceptance cases and automated tests.
