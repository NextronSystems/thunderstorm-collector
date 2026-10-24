# Thunderstorm SFTP Collector (prototype)

**Status: prototype.** Not released, not built by CI and not covered by the
test suites. Options and behavior may change.

The SFTP collector pulls files instead of pushing them. It runs on the
Thunderstorm host or on a system between the source and Thunderstorm,
connects to the source over SSH, lists the filesystem through the SFTP
subsystem and streams only the selected files to THOR Thunderstorm. Nothing is
installed or run on the source besides its SFTP server.

Unlike scanning an SSHFS mount, where the scanner reads each file it checks,
most of the selection happens on metadata that the directory listing already
carries:

| Filter | Information used | File data read from the source |
|---|---|---|
| `-p`, `--exclude` | Path | None |
| `-e` | File name | None |
| `-m` | Size from the listing | None |
| `-a` | Modification time from the listing | None |
| `--executable` | Permission bits from the listing | None |
| `--magic` | First bytes of the file | One read of the longest header length |
| Selected files | | The whole file, streamed to Thunderstorm |

Selected files are not staged on disk. The remote path is sent as the file
name and the SFTP host as the source name, unless `-o` sets another.

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
  parallel directory listings.

Run `--help` for all options. Exit status 1 means that a selected file could
not be read or sent, a root could not be read, the configuration was invalid,
or the SSH or Thunderstorm connection failed, as with the Go collector.

## Limits

- **Modification time only.** OpenSSH implements SFTP version 3, which reports
  access and modification times but no inode change or birth time. The Go
  collector on Linux also considers the change time, so a file whose
  modification time was set back can pass its age filter but not this one.
  Repeat collections without `-a` regularly.
- **No filesystem types.** SFTP does not report them, so pseudo filesystems
  and network mounts on the source are not skipped automatically. Limit `-p`
  to the relevant paths and exclude mounts such as `/proc` and `/sys`.
- **SFTP subsystem required.** An SSH login alone is not enough. Some
  embedded SSH servers, such as Dropbear, ship without an SFTP server.
- **Coverage.** Files that are not selected are never analyzed. The manifest
  keeps their paths and metadata for review.
- **Source side effects.** Reading a file can update its access time on the
  source, and the source's SSH server may log each file opened.
- **Credentials.** The collector host holds SSH keys for every source it
  collects from. Use a dedicated read-only account where the source allows
  it, for example OpenSSH's `internal-sftp -R`.
