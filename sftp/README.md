# Thunderstorm SFTP Collector (prototype)

**Status: prototype.** Not released, not built by CI and not covered by the
collector test suites. It has not been tested on any product or appliance.
Options and behavior may change. Build it from source as described below.

The SFTP collector is for systems whose files should be analyzed by THOR
Thunderstorm, but on which nothing may run. It runs somewhere else: on the
Thunderstorm host, or on a system that can reach both the source over SSH and
Thunderstorm over HTTP(S). It lists the source's filesystem through the SFTP
subsystem of its SSH server, selects files mostly by what the directory
listing already says about them, and streams only the selected files to
Thunderstorm. The source runs no collector, script or scanner, and keeps no
copied file or scheduled task.

## When to Use It

Use the SFTP collector when SSH with SFTP is available on the source and one
of these applies:

- **Nothing can run on the source.** No compatible binary or interpreter
  exists, as on AIX on POWER7 or on systems below the
  [Go runtime floor](../docs/COLLECTOR_RECOMMENDATIONS.md#compatibility-boundaries);
  the shell is restricted; the vendor does not permit third-party software;
  or the account is limited to SFTP, for example with OpenSSH's
  `ForceCommand internal-sftp` or a chroot.
- **The source cannot reach Thunderstorm.** The Go and script collectors
  connect from the source to Thunderstorm. Here the source only accepts an
  SSH connection, and the collector host sends the files on.
- **Nothing on the source should change.** The collector reads files and
  writes nothing there.
- **One host should collect from many sources**, on a schedule, with the same
  filters.

Prefer another route in these cases:

- **The Go collector or a script collector can run on the source and reach
  Thunderstorm.** They see more about each file (on Linux the Go collector
  also checks change times) and need no inbound SSH or stored credentials.
- **The SSH server has no SFTP subsystem.** An interactive login is not
  enough; some embedded SSH servers, such as Dropbear, ship without an SFTP
  server.
- **The device offers only a vendor CLI or export.** Use the vendor's
  procedure and upload the exports, as described in the
  [collector recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md#external-collection-and-file-visibility).

## How It Differs from the Other Collectors

| | Go and script collectors | SFTP collector |
|---|---|---|
| Runs on | The source system | The Thunderstorm host, or a system with SSH access to the source |
| Source needs | A compatible binary or interpreter, its tools and HTTP(S) access to Thunderstorm | An SSH server with the SFTP subsystem and an account that can read the files in scope |
| Connections | Source to Thunderstorm | Collector host to source (SSH) and to Thunderstorm (HTTP or HTTPS) |
| Credentials | None stored for other systems | An SSH key for every source, kept on the collector host |
| Age filter | Go on Linux uses modification and change time; scripts differ | Modification time only |
| Filesystem types | The Go collector skips network and pseudo filesystems | Not reported over SFTP; scope with paths and excludes |
| Source platform | Must match the binary or runtime | Any system with a working SFTP server |

The filter options and the YAML keys are those of the
[Go collector](../go/README.md), so its `config.yml` loads with `-t`.

## Compared with THOR over SSHFS

Both approaches use the same access: the source's SFTP service, with nothing
running on the source. They differ in where files are selected and what reads
them.

THOR scanning an [SSHFS mount](../docs/SCANNING_APPROACHES.md#remote-filesystem-scans-with-sshfs)
reads every file it checks through the mount. The documented example uses a
lab scan, which [scans every file regardless of its extension or magic
header](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning),
up to `max_file_size_intense` (200 MB by default). The content of nearly every
file in scope therefore crosses the network. The SFTP collector decides from
the listing and, where a header check is configured, from the first bytes of
a file. Only the selected files are transferred.

**Advantages of the SFTP collector:**

- **Traffic and source load follow the selection.** Network traffic and disk
  reads on the source depend on the files selected, not on the data in scope.
  This matters most for recurring runs with an age filter, slow links and
  weak devices.
- **Header checks read only the bytes they compare.** The read length is
  that of the longest configured header.
- **No FUSE mount.** The collecting host needs no SSHFS, and there is no
  mount to manage or unmount.
- **License.** Analysis runs on Thunderstorm, which needs a Thunderstorm
  Service License. Full THOR scanning of a mounted filesystem needs a
  Forensic Lab License. See [licensing](../docs/SCANNING_APPROACHES.md#prerequisites).
- **Original paths and source names.** Every sample carries its path on the
  source and the source name, so no `--virtual-map` is needed.
- **Repeatable collection from many sources.** One host can run scheduled
  collections against several sources, and `--manifest` records every listed
  file with its metadata and the decision taken.

**Advantages of THOR over SSHFS:**

- **Every file in scope is checked**, including filename IOCs and metadata
  rules on files that a collector profile would not select. The SFTP
  collector's results cover only the files it sent.
- **No Thunderstorm service is needed.** An analysis workstation with THOR and
  a Forensic Lab License is enough for a one-time assessment.

The two combine well: assess a scope once with THOR over SSHFS, then run
scheduled SFTP collections with an age filter. Repeat collections without an
age filter regularly, so that new signatures reach older files and files with
a manipulated modification time are not missed.

## Selecting Without Transfer

Most filters use metadata that the directory listing already carries:

| Filter | Information used | File data read from the source |
|---|---|---|
| `-p`, `--exclude` | Path | None |
| `-e` | File name | None |
| `-m` | Size from the listing | None |
| `-a` | Modification time from the listing | None |
| `--executable` | Permission bits from the listing | None |
| `--magic` | First bytes of the file | One read of the longest header length |
| Selected files | | The whole file, streamed to Thunderstorm |

Selected files are not staged on disk. A file matches the type filters if its
extension, its execute bit (with `--executable`) or its header matches; the
header is read only when the listing has not decided.

## Build

Go 1.22 or newer:

```sh
cd sftp
go build -o thunderstorm-sftp-collector .
```

The module is separate from the [Go collector](../go/README.md), which keeps
an old Go version for legacy platforms. The SFTP collector runs on the
analysis side, where a current toolchain is available.

## Usage

```sh
./thunderstorm-sftp-collector \
  --sftp-host appliance01.example.internal --sftp-user audit --sftp-key ~/.ssh/audit_ed25519 \
  -s thunderstorm.example.internal \
  -p /var/www -p /usr/local -p /tmp -p /etc \
  -e .php -e .jsp -e .sh --magic 7f454c46 --magic 2321 --executable -m 20 \
  --manifest appliance01.jsonl
```

- The host key must already be in `--known-hosts` (default
  `~/.ssh/known_hosts`). Unknown or changed keys abort the run; there is no
  trust-on-first-use.
- Without `--sftp-key`, keys from `ssh-agent` are used. Passphrase-protected
  key files need the agent.
- `-t config.yml` loads a Go collector configuration. Its filter and
  Thunderstorm keys apply; options that only make sense on the source, such
  as `all-filesystems`, are ignored. Command-line options override the file.
- `--dry-run` selects files without sending them. A dry run without
  `--magic` reads no file data at all.
- `--manifest` writes every listed entry with its metadata and the decision
  taken, one JSON object per line.
- `--threads` sets parallel header checks and uploads, `--walk-threads`
  parallel directory listings. Over high-latency links, listing time grows
  with the number of directories; more walk threads shorten it.

Run `--help` for all options. Exit status 1 means that a selected file could
not be read or sent, a root could not be read, the configuration was invalid,
or the SSH or Thunderstorm connection failed, as with the Go collector.

## Limits

- **Modification time only.** OpenSSH implements SFTP version 3, which reports
  access and modification times but no inode change or birth time. The Go
  collector on Linux also checks the change time, so it still selects a file
  whose modification time was set back; this collector does not. Repeat
  collections without `-a` regularly.
- **No filesystem types.** SFTP does not report them, so pseudo filesystems
  and network mounts on the source are not skipped automatically. Limit `-p`
  to the relevant paths and exclude mounts such as `/proc` and `/sys`.
- **SFTP subsystem required.** See [When to Use It](#when-to-use-it).
- **Coverage.** Files that are not selected are never analyzed. The manifest
  keeps their paths and metadata for review.
- **Source side effects.** Reading a file can update its access time on the
  source, and the source's SSH server may log each file opened.
- **Credentials.** The collector host holds SSH keys for every source it
  collects from. Use a dedicated read-only account where the source allows
  it, for example OpenSSH's `internal-sftp -R`.
