# SFTP Collector

The SFTP collector reads files from a source system over SFTP and sends the
selected ones to THOR Thunderstorm for analysis. Use it when nothing may run on
the source but its SSH server offers SFTP. The collector runs on the
Thunderstorm host or on a system between the source and Thunderstorm.

- When to choose it over other collectors: [When to Use It](#when-to-use-it)
- How it compares with THOR over SSHFS: [comparison](#compared-with-thor-over-sshfs)

> [!NOTE]
> **Prototype.** Not tested on any product or appliance; options and behavior
> may change. CI builds and tests it.

## Requirements

| Requirement | Detail |
|---|---|
| Collector host | Linux amd64 or arm64 for the release packages; other platforms [build from source](#download-or-build) |
| Network | Collector host reaches the source over SSH and Thunderstorm over HTTP or HTTPS |
| Source | SSH server with the SFTP subsystem; an account that can read the files in scope |
| SSH key | Unencrypted key file (`--sftp-key`) or `ssh-agent` (`SSH_AUTH_SOCK`); passphrase-protected keys need the agent |
| Host key | The source's key must already be in `~/.ssh/known_hosts` (or `--known-hosts`) |
| Service | Thunderstorm, which needs a Thunderstorm Service License |

## Download or Build

Releases after v1.1.0 include
`thunderstorm-sftp-collector-<version>-<arch>-linux.tar.gz` for `amd64` and
`arm64`. Each holds the binary, `<arch>-linux-thunderstorm-sftp-collector`, and
this README. Verify it against the release's `SHA256SUMS`.

For other platforms, build with the Go version in [go.mod](go.mod) or newer:

```sh
cd sftp
go build -o thunderstorm-sftp-collector .
```

`make release` builds both Linux packages into `dist/`. The module is separate
from the [Go collector](../go/README.md), which keeps an old Go version for
legacy platforms.

## Usage

1. Make sure the source's host key is in `~/.ssh/known_hosts`. Unknown or
   changed keys abort the run; there is no trust-on-first-use.

2. Preview the selection. A dry run lists the source but contacts no
   Thunderstorm server. From a release package, the binary is
   `./<arch>-linux-thunderstorm-sftp-collector`.

   ```sh
   ./thunderstorm-sftp-collector \
     --sftp-host appliance01.example.internal --sftp-user audit \
     --sftp-key ~/.ssh/audit_ed25519 \
     -s thunderstorm.example.internal \
     -p /var/www -p /usr/local -p /tmp -p /etc \
     -e .php -e .jsp -e .sh --magic 7f454c46 --magic 2321 --executable -m 20 \
     --manifest appliance01.jsonl --dry-run
   ```

   This selects PHP, JSP and shell files, files that start with an ELF or `#!`
   header, and executables, up to **20 MiB**. `--manifest` records every listed
   file and the decision taken.

3. Upload: run the same command without `--dry-run`.

Without `-p` and type filters, the collector takes **every regular file under
`/`** up to **100 MiB**. Set roots and filters for each source.

## Configuration

- `-t config.yml` loads options from a YAML file. The other long options have
  keys of the same name, for example `sftp-host` or `walk-threads`.
- A [Go collector](../go/README.md) `config.yml` loads as is. Its filter and
  Thunderstorm keys apply; keys that only make sense on the source, such as
  `all-filesystems`, are ignored.
- Command-line options override the file.

## Common Options

`--help` lists all options.

| Option | Default | Purpose |
|---|---|---|
| **Source** | | |
| `--sftp-host HOST` | none, required | System to collect from |
| `--sftp-port PORT` | 22 | SSH port |
| `--sftp-user USER` | `$USER` | SSH user |
| `--sftp-key FILE` | `ssh-agent` | Unencrypted private key file |
| `--known-hosts FILE` | `~/.ssh/known_hosts` | Host keys to verify against |
| **Selection** | | |
| `-p`, `--path PATH` | `/` | Remote root; repeatable |
| `--exclude GLOB` | none | Remote path to skip; `?`, `*` and `**`; repeatable |
| `-e`, `--extension EXT` | none | Collect files with this extension; repeatable |
| `--magic HEX` | none | Collect files that start with these bytes; repeatable |
| `--executable` | off | Collect files with an execute bit set |
| `-m`, `--max-filesize MB` | 100 | Largest file, in MiB, inclusive |
| `-a`, `--max-age AGE` | none | Modified within this time; suffix `s`, `m`, `h` or `d`, days without |
| **Thunderstorm** | | |
| `-s`, `--thunderstorm-server HOST` | none | Server; required unless `--dry-run` |
| `--port PORT` | 8080 | Server port |
| `--ssl` | off | Use HTTPS |
| `--ca FILE` | system trust | PEM CA certificate; repeatable |
| `--insecure` | off | Do not verify the HTTPS certificate |
| `-o`, `--source NAME` | SFTP host | Source name shown in Thunderstorm |
| `--upload-synchronous` | off | Use `/api/check` and log each result |
| **Run** | | |
| `--dry-run` | off | Select files, upload nothing |
| `--debug` | off | Log the decision for every file, and marker answers |
| `--manifest FILE` | none | Every listed entry with metadata and decision, as JSON lines |
| `--stats-json FILE` | none | Run statistics as JSON |
| `-r`, `--threads N` | 4 | Parallel header checks and uploads |
| `--walk-threads N` | 4 | Parallel directory listings; more help over high-latency links |
| `--response-timeout`, `--sftp-timeout`, `--server-wait` | see [timeouts](#timeouts-and-limits) | Waits for Thunderstorm and the source |

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Completed without errors |
| `1` | A selected file could not be read or sent, a root could not be read, the configuration was invalid, the SSH connection failed or was lost, Thunderstorm could not be reached or stayed unreachable for `--server-wait`, or the run was interrupted |
| `130` | A second SIGINT or SIGTERM ended the run at once |

The statistics show what is incomplete. Unreadable directories below a root
are counted there but do not change the exit code. Collection markers never
change it.

## Behavior Details

### File selection

Most filters use what the directory listing already says, so only selected
files are transferred:

| Filter | Information used | File data read from the source |
|---|---|---|
| `-p`, `--exclude` | Path | None |
| `-e` | File name | None |
| `-m` | Size from the listing | None |
| `-a` | Modification time from the listing | None |
| `--executable` | Permission bits from the listing | None |
| `--magic` | First bytes of the file | One read, as long as the longest header |
| Selected files | | The whole file, streamed to Thunderstorm |

- **Type filters:** a file matches if its extension, its execute bit (with
  `--executable`) or its header matches. The header is read only when the
  listing has not decided. Without type filters, every regular file matches.
- **Dry run:** without `--magic`, a dry run reads no file data at all.
- **No staging:** selected files are streamed, not stored on disk.
- **Symbolic links** below a root are recorded, not followed.
- **Re-check on open:** a file must still be a regular file within
  `--max-filesize`, and exactly its size at that moment is sent. A file that
  grows or shrinks while it is read counts as a file error.

### Roots

- Excludes apply to roots as to listed entries.
- A root that is a symbolic link is followed to its target, which the log
  names. Excludes written for the root as given still apply below it.
- A directory given twice is listed once.
- Below a root of `/`, `/proc`, `/sys` and `/dev` are skipped. Give them as
  roots to list them.

### Uploads

- Uploads go to `/api/checkAsync`, or to `/api/check` with
  `--upload-synchronous`. Before a real run, the collector checks
  `/api/status`.
- Uploads use HTTP/1.1, also over HTTPS, so that the stall check works.
  Redirects are not followed.
- **Thunderstorm unavailable:** after 3 files in a row got no answer (or only
  503 until the retries were used up), the collector stops sending and polls
  `/api/status`. It continues when Thunderstorm answers, or stops when
  `--server-wait` runs out. `0` stops at once.

### TLS

- `--ssl` turns on HTTPS. Certificate verification is on by default.
- With `--ca`, only the given CA certificates are trusted; system CAs are not
  added. `--ca` takes effect only together with `--ssl`.
- `--insecure` turns verification off.

### Collection markers

Like the Go and script collectors, the collector sends a `begin` marker to
`POST /api/collection` once the source is connected. If Thunderstorm answers
with a scan ID, every upload carries it as the `scan_id` query parameter. The
run closes with `end`, or with `interrupted` after a signal, a lost SSH
connection or Thunderstorm unreachable for `--server-wait`.

- THOR 10 and current THOR 11 answer 404 or 501; the run is then the same as
  without markers.
- Any other `begin` failure is retried once after 2 seconds, then files are
  sent without a scan ID.
- Marker problems are shown only with `--debug` and never change the exit
  code.
- Markers carry the `--source` and, as `hostname`, the system that runs the
  collector.

[Collection markers](../docs/COLLECTION_MARKERS.md) describes the format.

### Interruption

SIGINT or SIGTERM ends the run: pending uploads are cancelled, the manifest
and `--stats-json` are written, and the exit code is 1. A second signal exits
at once.

### Timeouts and limits

| Item | Limit |
|---|---|
| Connect, SSH handshake and SFTP start | 30 s |
| Pending SFTP request (`--sftp-timeout`), for example a source hanging on a dead network mount | 5 min; then the connection is closed |
| Thunderstorm answer after an upload (`--response-timeout`) | 2 min; 30 min with `--upload-synchronous` |
| Upload stall: Thunderstorm accepts no data | 2 min |
| Thunderstorm unreachable (`--server-wait`, seconds) | 600 s |
| Marker request | 10 s |

Timeouts take values such as `90s` or `5m`. A plain number is seconds, as in
the Go collector's `config.yml`.

## Limits

- **Modification time only.** OpenSSH implements SFTP version 3, which reports
  access and modification times but no change or birth time. The Go collector
  on Linux also checks the change time, so it still selects a file whose
  modification time was set back; this collector does not. Repeat collections
  without `-a` regularly.
- **No filesystem types.** SFTP does not report them, so network mounts on the
  source are not skipped, and pseudo filesystems only below a root of `/`.
  Limit `-p` to the relevant paths and exclude other mounts.
- **No reconnect.** A lost connection ends the run; directories not yet listed
  are not collected. Run it again.
- **SFTP subsystem required.** See [When to Use It](#when-to-use-it).
- **Coverage.** Files that are not selected are never analyzed. The manifest
  keeps their paths and metadata for review.
- **Source side effects.** Reading a file can update its access time, and the
  source's SSH server may log each file opened.
- **Credentials.** The collector host holds SSH keys for every source. Use a
  dedicated read-only account where the source allows it, for example
  OpenSSH's `internal-sftp -R`.

## When to Use It

Use it when the source offers SSH with SFTP and one of these applies:

- **Nothing can run on the source:** no compatible binary or interpreter (AIX
  on POWER7, systems below the
  [Go runtime floor](../docs/COLLECTOR_RECOMMENDATIONS.md#compatibility-boundaries)),
  a restricted shell, a vendor ban on third-party software, or an SFTP-only
  account (OpenSSH `ForceCommand internal-sftp` or a chroot).
- **The source cannot reach Thunderstorm.** The source only accepts an SSH
  connection; the collector host sends the files on.
- **Nothing on the source should change.** The collector writes nothing there.
- **One host collects from many sources**, on a schedule, with the same filters.

Use something else when:

- **The Go or a script collector can run on the source and reach
  Thunderstorm.** They see more about each file and need no inbound SSH or
  stored credentials.
- **The SSH server has no SFTP subsystem.** An interactive login is not enough;
  some embedded SSH servers, such as Dropbear, ship without one.
- **The device offers only a vendor CLI or export.** Upload the exports as
  described in the
  [collector recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md#external-collection-and-file-visibility).

## How It Differs from the Other Collectors

![A source system that cannot run the Go or a script collector but offers SSH with SFTP. The SFTP collector reads the listing, headers and only the selected files over SFTP and sends them over HTTP(S) to Thunderstorm. The collector and Thunderstorm can run on one system, or the collector on a separate system in between.](../images/sftp-collector-flow.svg)

| | Go and script collectors | SFTP collector |
|---|---|---|
| Runs on | The source system | The Thunderstorm host, or a system with SSH access to the source |
| Source needs | A compatible binary or interpreter, its tools and HTTP(S) access to Thunderstorm | An SSH server with the SFTP subsystem and an account that can read the files in scope |
| Connections | Source to Thunderstorm | Collector host to source (SSH) and to Thunderstorm (HTTP or HTTPS) |
| Credentials | None stored for other systems | An SSH key for every source, kept on the collector host |
| Age filter | Go on Linux uses modification and change time; scripts differ | Modification time only |
| Filesystem types | The Go collector skips network and pseudo filesystems | Not reported over SFTP; scope with paths and excludes |
| Source platform | Must match the binary or runtime | Any system with a working SFTP server |

The filter options and YAML keys are those of the
[Go collector](../go/README.md).

What the collector is for, where it runs and how it compares with SSHFS (an
89-second animation, no sound; the findings in it are illustrative):

https://github.com/user-attachments/assets/88adb24b-eae9-413a-94b9-3bb71efca313

## Compared with THOR over SSHFS

Both use the same access: the source's SFTP service, with nothing running on
the source. They differ in where files are selected.

- **THOR over an [SSHFS mount](../docs/SCANNING_APPROACHES.md#remote-filesystem-scans-with-sshfs)**
  reads every file it checks through the mount. The documented example uses a
  [lab scan](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning),
  which scans every file regardless of extension or header, up to
  `max_file_size_intense` (200 MB by default). Nearly every file in scope
  crosses the network.
- **The SFTP collector** decides from the listing and, with `--magic`, from the
  first bytes of a file. Only selected files are transferred.

**Advantages of the SFTP collector:**

- **Traffic and source load follow the selection,** not the data in scope.
  This matters most for recurring runs with an age filter, slow links and weak
  devices.
- **No FUSE mount.** The collecting host needs no SSHFS, and there is no mount
  to manage.
- **License:** Thunderstorm needs a Thunderstorm Service License; full THOR
  scanning of a mounted filesystem needs a Forensic Lab License. See
  [licensing](../docs/SCANNING_APPROACHES.md#prerequisites).
- **Original paths and source names** on every sample, so no `--virtual-map`
  is needed.
- **Repeatable collection from many sources** on a schedule; `--manifest`
  records every decision.

**Advantages of THOR over SSHFS:**

- **Every file in scope is checked**, including filename IOCs and metadata
  rules on files that a collector profile would not select.
- **No Thunderstorm service is needed.** An analysis workstation with THOR and
  a Forensic Lab License is enough for a one-time assessment.

**Combine them:** assess a scope once with THOR over SSHFS, then run scheduled
SFTP collections with an age filter. Repeat collections without an age filter
regularly, so that new signatures reach older files and files with a
manipulated modification time are not missed.

## Testing

`make test` runs `go vet` and the tests. CI runs them with the Go version in
[go.mod](go.mod) and with the newest Go release.
