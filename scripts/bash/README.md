# Bash Collector

`thunderstorm-collector.sh` is the preferred script collector for Unix-like systems with Bash. It is more feature-complete than the minimal POSIX sh collector and should be used on Linux, macOS, WSL, and similar systems whenever Bash is available.

## Intended Use

Use this collector for incident response and triage on modern Linux or macOS systems where deploying the Go collector is not possible but Bash plus `curl` or `wget` is available.

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | Bash |
| Upload tool | `curl` or `wget` |
| OS | Linux, macOS, WSL, and Unix-like systems |

## Capabilities

- Recursive directory scanning. Without `--dir`, the defaults are `/root /tmp /home /var /usr /dev/shm /run` — the last two are tmpfs (memory-backed) staging areas that malware uses and that leave nothing on disk; `/dev` and `/run` remain excluded when reached from above. A default directory that does not exist on the platform is skipped quietly; a default that lies on a network filesystem (for example `/home` on NFS) is skipped with a warning and is collected only when named with `--dir`. A network filesystem here means storage on another machine mounted into this host's tree — NFS and SMB/CIFS shares, SSHFS, cluster and S3/cloud FUSE mounts; walking one would submit that machine's files as this host's evidence and can hang on a dead share, so the collector never walks them by default (see the next point). Overlapping directories (`--dir /a --dir /a/b`) are scanned once: each file is collected one time, the first directory wins — decided by where the directories really are, so two spellings of one directory (`/data/link/sub` and `/data/real/sub`) are also collected once.
- Filesystem exclusions are decided from the mount table by exact filesystem-type name (`nfs`, `nfs4`, `cifs`, `sshfs`, `fuse.sshfs`, `fuse.rclone`, `fuse.s3fs`, … — deliberately no `fuse.*` prefix rule, so local FUSE filesystems such as gocryptfs, bindfs or ntfs-3g stay collectable) and applied to the path as a string before the location is touched, so a dead share or an autofs trigger cannot hang the run. Explicit scope wins: a directory you name on a network filesystem is collected, and the log names its filesystem type before the first access; kernel pseudo-filesystems (`proc`, `sysfs`, `autofs`, …) are refused even when named. (The Go collector decides by statfs magic number, does not skip FUSE mounts, and refuses a named root on a skipped filesystem — the two collectors are not identical here.)
- Honest accounting: `failed=` counts every discovered file that was not collected — unreadable (including a symlink target under `--follow-symlinks`), vanished or changed type mid-run, or upload failed — and a `File breakdown:` line names the reason; directories that could not be read are counted in `unreadable_dirs=` (their contents are unknown, so only the directories can be counted), and explicitly named directories that could not be scanned at all in `unusable_dirs=`. Anything the collector or the host got wrong — unreadable file, unreadable directory, failed upload, unusable named target — makes the run a partial failure (**exit 4**), rsync's "partial transfer due to error" (23); a non-root run therefore often exits 4 while still uploading everything it could read. When the *only* losses are files that vanished or changed type mid-run — ordinary churn on a live host — the run exits **5** instead, rsync's "partial transfer due to vanished source files" (24), so routine churn is distinguishable from a real problem. Exit 4 wins when both occurred.
- File age and file size filtering.
- HTTP and HTTPS uploads.
- Configurable source identifier.
- Collection begin/end markers.
- Retry behavior for transient upload failures.
- Dry-run mode for local validation.
- Symlink-aware collection: physical walk always; opt-in `--follow-symlinks` for file targets (see [Symbolic Links](#symbolic-links)).
- Optional log file and syslog output.

## Limitations

- Not compatible with plain `sh`, `dash`, or BusyBox `ash`; use the ash collector for those systems.
- Requires an external upload tool.
- Shell behavior still depends on the local Bash and coreutils environment.

## Basic Usage

```bash
bash scripts/bash/thunderstorm-collector.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp \
  --max-age 14
```

Dry-run:

```bash
bash scripts/bash/thunderstorm-collector.sh \
  --server thunderstorm.local \
  --dir /tmp \
  --dry-run
```

## Symbolic Links

Symbolic links are never traversed. The directory walk is physical in every mode, so a planted link cannot bypass the path-based exclusions or pull an unbounded subtree into the collection.

- **Default:** links are counted (`links_seen`) and left alone; a scan root **you name** is reported, not followed. The built-in default directories are resolved to their real location first, so a platform alias such as macOS `/tmp` -> `/private/tmp` is still scanned — resolving the collector's own defaults extends the scope by nothing, whereas dereferencing a path you named would.
- **`--follow-symlinks`:** a symlinked scan root is resolved and scanned; a link to a **file** is collected; a link to a **directory** is listed with a hint and only scanned when named explicitly with `--dir`.

With `--follow-symlinks`, every link target passes these steps, in this order:

1. **Filesystem-class gate on the link text alone.** The target string is absolutized lexically (no filesystem access) and matched against the mount table; a target on a network or kernel pseudo-filesystem (`nfs`, `cifs`, `sshfs`, `proc`, `sysfs`, `autofs`, …) is refused *before* it is stat'ed, so a dead share or an autofs trigger cannot hang the collector.
2. **One resolution** of the link chain (40-hop cap) to the real path.
3. **One policy pass** on the resolved path: the collector's own work directory and log file, targets already inside a scan root (the walk decided about those), a target another link already delivered, filesystem class again, size/age.
4. **One open, of the resolved path.** The file is read and reported to the server under its real path; the log records the mapping: `Collected via symlink: '<link>' -> '<target>'`.

The run summary reports `links_seen`, `links_collected` and `links_skipped`; when following was on, a `Symlink breakdown:` line names the skip reasons (`dir_surfaced in_scope dup fs_refused self_excluded filtered dangling unresolvable`) and the links whose target could not be read or uploaded (`links_failed`, also counted in `failed=`). Discovered entries reconcile against these counters, and a mismatch is reported as a collection failure (exit 4).

An entry whose type changes between discovery and upload — a symlink replaced by a regular file, or the reverse — is not collected and counts as failed (`vanished`), because find's size and age predicates were never applied to the new object.

**Residual risk — stated plainly.** Opening the resolved path means re-pointing the link after validation cannot change what is uploaded. What remains is the same race every regular file has: the target itself (or a parent directory) renamed or replaced between validation and upload. Following reduces the symlink case to that baseline; it does not eliminate it. No additional canonicalize/re-check cycle is performed, because each extra open would add a window rather than close one.

## Manual Acceptance Test

Create a small test directory and upload it to a Thunderstorm service:

```bash
rm -rf /tmp/ts-bash-acceptance
mkdir -p /tmp/ts-bash-acceptance/subdir
printf 'bash acceptance text\n' > /tmp/ts-bash-acceptance/sample.txt
printf '\x00\x01\x02THUNDER\n' > /tmp/ts-bash-acceptance/sample.bin
printf 'nested\n' > /tmp/ts-bash-acceptance/subdir/nested.txt

bash scripts/bash/thunderstorm-collector.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-bash-acceptance \
  --source manual-bash-acceptance \
  --max-age 30
```

Acceptance criteria:

- The command exits successfully.
- Thunderstorm records uploads for the test files.
- The source field is `manual-bash-acceptance`.
- Text and binary files are uploaded.
- Nested files are uploaded.

## Manual Robustness Tests

Run these after the basic acceptance test. They are intended for human review of expected failure handling, not for upload-volume validation.

### Dry-run does not contact the server

```bash
bash scripts/bash/thunderstorm-collector.sh \
  --server 127.0.0.1 \
  --port 1 \
  --dir /tmp/ts-bash-acceptance \
  --source manual-bash-dry-run \
  --dry-run
```

Expected result:

- The command exits successfully.
- No upload is visible in Thunderstorm.
- The output lists files that would be submitted.

### Thunderstorm service unreachable

```bash
bash scripts/bash/thunderstorm-collector.sh \
  --server 127.0.0.1 \
  --port 1 \
  --dir /tmp/ts-bash-acceptance \
  --source manual-bash-unreachable \
  --max-age 30
```

Expected result:

- The command exits non-zero.
- The collector prints a clear connection or begin-marker failure.
- The command returns within a reasonable time and does not hang indefinitely.

### Missing and unreadable paths

This test is meaningful only when not running as `root`, because `root` can usually read files with mode `000`.

```bash
rm -rf /tmp/ts-bash-errors
mkdir -p /tmp/ts-bash-errors/readable /tmp/ts-bash-errors/unreadable
printf 'readable\n' > /tmp/ts-bash-errors/readable/ok.txt
printf 'secret\n' > /tmp/ts-bash-errors/unreadable/blocked.txt
chmod 000 /tmp/ts-bash-errors/unreadable/blocked.txt

bash scripts/bash/thunderstorm-collector.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-bash-errors/readable \
  --dir /tmp/ts-bash-errors/unreadable \
  --dir /tmp/ts-bash-errors/missing \
  --source manual-bash-error-paths \
  --max-age 30

chmod 644 /tmp/ts-bash-errors/unreadable/blocked.txt
```

Expected result:

- The collector does not crash on the missing directory.
- The collector does not crash on the unreadable file.
- The readable file is still submitted.
- Warnings or failed-file statistics are acceptable and should be reviewed.

### File size filter

```bash
rm -rf /tmp/ts-bash-filter
mkdir -p /tmp/ts-bash-filter
printf 'small\n' > /tmp/ts-bash-filter/small.txt
dd if=/dev/zero of=/tmp/ts-bash-filter/large.bin bs=1024 count=32 2>/dev/null

bash scripts/bash/thunderstorm-collector.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-bash-filter \
  --source manual-bash-size-filter \
  --max-age 30 \
  --max-size-kb 1
```

Expected result:

- `small.txt` is submitted.
- `large.bin` is skipped by the size filter.

## Automated Stub Test

```bash
THUNDERSTORM_TEST_COLLECTORS=bash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```
