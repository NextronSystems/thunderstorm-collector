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
- Honest accounting: policy exclusions are reported, not silent — `age_filtered=` and `size_filtered=` count the regular files the age and size gates removed at discovery (disjoint: a file that is both oversize and too old counts once, as size), so a run whose whole tree was out of policy is no longer indistinguishable from a complete collection of an empty directory. Each count is measured by matching the files in that category, never by subtracting one walk from another — walks taken at different moments would otherwise publish ordinary churn as a policy exclusion (a directory gaining files mid-run once reported 4710 files "outside the age window" when every file in it was new). `age_ctime_only=` reports how many files matched at discovery by ctime alone, so the cost of the default `any` policy is visible rather than inferred from the server's sample count. Because those walks run after the discovery walk they are not atomic: a tree that changes in between makes the counts a snapshot, which is now detected (`discovered + age_filtered + size_filtered` must equal the regular files present) and labelled rather than presented as fact. `future=` counts collected files whose mtime is ahead of the host clock at the moment of measurement — it carries the full discovery policy, so a future-dated file dropped for size is not claimed as collected, and its reference instant is stamped at counting time rather than at run start, so files merely written *during* the scan are no longer reported as future. The counting walks cover the regular files under each root, so symlink targets collected through `--follow-symlinks` are not attributed to `age_filtered=`/`size_filtered=`/`age_ctime_only=` — a link the two gates removed is counted once in the symlink breakdown, which now names the gate responsible: `filtered_size=` and `filtered_age=`. Those keys are deliberately not spelled `size_filtered=`/`age_filtered=` — those already appear on the summary line, and a scraper taking the last match would read a link count where it wanted a file count. Attribution costs at most one extra `find`, and only for a link that was actually filtered: with one gate disabled the reason follows by elimination and no second walk is spelled. The churn allowance behind that snapshot label is derived from `--max-age` alone, and a size-only run (`--max-age 0`) therefore gets the minimum allowance of one file, so it takes the label more readily. That is deliberate: the allowance exists because the age predicates are *relative* and re-evaluated per walk, so files crossing the window mid-walk are arithmetic rather than churn — a byte bound is absolute and nothing crosses it because time passed. The label is true whenever it fires (the tree really did change), and widening it with an invented churn model would risk masking real drift. `--no-count-filtered` skips every one of those walks — all four counters then read 0 because nothing was measured, which the run states on its own line. Counting is done by deleting everything but the NUL separators from each walk's output and measuring the result, rather than reading it record by record in Bash — a per-record loop cost several times more than the walk that produced it, and two of the walks match nearly every file. It needs `tr` (already used elsewhere in the script) and `wc`; when `wc` is absent the read loop still runs and produces identical counts, so this is not a new hard dependency. Cost of the counting walks, measured on this host: `/usr` (9 080 files) 176 → **105 ms**, a 50 000-file tree 595 → **344 ms**, a 156 625-file tree 2 880 → **534 ms** — the saving grows with the tree because the old cost was per matched record. `failed=` counts every discovered file that was not collected — unreadable (including a symlink target under `--follow-symlinks`), vanished or changed type mid-run, or upload failed — and a `File breakdown:` line names the reason; directories that could not be read are counted in `unreadable_dirs=` (their contents are unknown, so only the directories can be counted), and explicitly named directories that could not be scanned at all in `unusable_dirs=`. Anything the collector or the host got wrong — unreadable file, unreadable directory, failed upload, unusable named target — makes the run a partial failure (**exit 4**), rsync's "partial transfer due to error" (23); a non-root run therefore often exits 4 while still uploading everything it could read. When the *only* losses are files that vanished or changed type mid-run — ordinary churn on a live host — the run exits **5** instead, rsync's "partial transfer due to vanished source files" (24), so routine churn is distinguishable from a real problem. Exit 4 wins when both occurred.
- File age and file size filtering. `--max-age N` keeps files strictly younger than N 24-hour
  periods (not calendar days), measured when each directory is reached; a file aged exactly
  N×24 h is **not** collected, and the window is evaluated to the minute. Where `find` has no
  `-mmin` the window falls back to whole days and the exact boundary becomes that `find`'s own
  rounding, which differs by platform — measured here: GNU `find -mtime -2` **keeps** a file aged
  exactly 2×24 h while `-mmin -2880` and busybox `find -mtime -2` **drop** it; on BSD/macOS
  `-mtime` rounds the age *up*, so the window there is up to a day **tighter** and `--max-age 1`
  collects nothing. The fallback has no single predictable direction of error, which is why
  `-mmin` is used whenever the running `find` offers it. The exclusive boundary is deliberate and matches every reference
  implementation that compares an instant: the Go collector tests `fileTime.After(threshold)`,
  Velociraptor `MTime > MoreRecentThan`, GNU tar `--newer-mtime`. (UAC's `find -mtime -N` is
  written exclusively but inherits whatever the platform's `find` does at the edge — the same
  day-bucket ambiguity described above, so it is a precedent for the intent, not the boundary.) `--max-age 0` disables the age filter entirely —
  it means "no filter", not `find -mtime 0`'s "within the last 24 hours".
  The window is applied to the modification time **or** the inode change time by default: mtime
  can be backdated by anyone who can write the file (`touch -d`), while ctime is
  set to the current time by the same call and cannot be chosen — so an mtime-only window silently
  misses a file whose content reached the disk moments ago. `--age-timestamp mtime|ctime|any`
  selects which. A file whose timestamp lies in the future is always collected and reported
  separately. What the two gates removed at discovery is reported as `age_filtered=` and
  `size_filtered=`, and what the ctime arm alone brought in as `age_ctime_only=`.
  `--max-size N` is measured in **KiB** (1024 bytes, as in the Go collector — not 1000), and
  the bound is **inclusive**: a file of exactly `N×1024` bytes is collected and one of
  `N×1024+1` is not. This is enforced inside `find` as `-size -"(N*1024+1)"c`, the one POSIX
  size unit that behaves identically on GNU, BSD/macOS and busybox (verified on GNU findutils
  4.9.0 and busybox 1.35: `-size -Nc` matches strictly-less-than-N bytes on both), so the check
  costs nothing — `find` reads the size from the `stat` it already performed, and no per-file
  fork is added to the upload loop. The inclusive edge matches every sibling collector: Go skips
  on `MaxFileSize < info.Size()`, and the Python, Perl, PowerShell and Batch collectors all skip
  on `>`, so a file one implementation collects is never dropped by another at the boundary. The
  size measured is the file's **apparent** length — the bytes that would go on the wire — so a
  sparse file counts as its full logical size, which is the number that matters for an upload.
  A zero-byte file is inside every bound and is always collected. The flag is spelled
  `--max-size`, not `--max-size-kb`: `--max-age` does not carry `days` in its name either, so
  the unit belongs in this documentation and in the run log rather than in the flag. The former
  spelling `--max-size-kb` is still accepted, unchanged, so existing runbooks keep working.
  `--max-size 0` turns the
  size filter **off**, the same way `--max-age 0` turns the age filter off; there is no separate
  opt-out flag and no magic maximum to remember. (The Go collector's engine already reads 0 as
  unlimited, in `collector.go`'s `c.MaxFileSize > 0 && c.MaxFileSize < info.Size()`, although
  its CLI still refuses the value.) Under `--follow-symlinks` the same bound is applied to a
  link's resolved **target**, never to the link itself.
- The size limit bounds **discovery**, not delivery. It is not a promise about what the server
  will accept, and the two can disagree in a way that costs real time: a Thunderstorm behind a
  reverse proxy may cap how long a single upload request may take rather than how large it may
  be, which makes the largest deliverable file a function of the host's bandwidth rather than of
  this flag. Measured against a live deployment: a 300 MB upload succeeded in 59.5 s, a 500 MB
  upload was cut off with `502` after 60.1 s, and a 10 MB upload deliberately throttled to
  100 KB/s was cut off with `502` after 60.2 s having sent only 6.1 MB — a ~60 s per-request
  window, not a body-size limit. The collector now names the HTTP status when a transfer is cut
  off mid-body (it previously reported only `curl exit 18` and discarded the `502` the server
  had already sent) and points at `--max-size` when it happens, and it no longer spends the
  retry budget on a status that cannot change — a `413 Payload Too Large` is uploaded once, not
  `--retries` times. A `5xx` is still genuinely transient and is still retried.
  On a host without `curl`, `--max-size` also sets a **temporary-disk** requirement: the
  `wget` fallback has to build the multipart body itself, so it writes a full second copy of
  each file into the private work directory under `TMPDIR` and reads the file once more before
  that to pick a boundary that does not occur in it. Measured here: a 191 MB file drove the
  work directory to 191 MB. The `curl` path streams the file from a shell redirect and has
  neither cost. Size `TMPDIR` accordingly, or keep `curl` installed, when raising this flag.
- **Accepted residual — the size gate is a discovery filter, not an upload cap.** `find`
  evaluates it once, during the walk, from the `stat` it was already performing; nothing
  re-checks the size before the file is opened. A file that is inside the limit at discovery
  and grows past it before its turn to upload is therefore delivered in full, and a file that
  grew between the discovery walk and the (later) counting walk can be counted in
  `size_filtered=` even though the same run collected it. Both are deliberate. Closing them
  would need a per-file size check in the upload loop, i.e. one `fork` per file, which is
  exactly what moving the limit into `find` removed — a measured 6851 ms -> 391 ms over 5000
  files. The same residual is why the counting walks are labelled a snapshot rather than a
  fact. It is the ordinary discovery-versus-delivery window every copying tool carries; `rsync`
  reports it as "file has vanished / changed size", and this collector reports it through the
  reconciliation caveat rather than pretending the two instants were one.
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
  --max-size 1
```

Expected result:

- `small.txt` is submitted.
- `large.bin` is excluded by the size filter before discovery, and the summary says so:
  `size_filtered=1`. (It is not counted in `skipped=`, which covers files that were discovered and
  then skipped — structurally zero, since both policy gates run inside `find`.)
- The run states the policy in reconcilable terms rather than as a bare number:
  `Size filter: regular files up to 1 KiB (1024 bytes) are collected; a file of exactly 1024
  bytes is kept, one of 1025 is not`.

To see the boundary itself, and that `0` means "no limit":

```bash
rm -rf /tmp/ts-bash-size-edge && mkdir -p /tmp/ts-bash-size-edge
head -c 2047 /dev/zero > /tmp/ts-bash-size-edge/under.bin
head -c 2048 /dev/zero > /tmp/ts-bash-size-edge/exact.bin
head -c 2049 /dev/zero > /tmp/ts-bash-size-edge/over.bin

bash scripts/bash/thunderstorm-collector.sh --dry-run --max-age 0 \
  --dir /tmp/ts-bash-size-edge --max-size 2      # under + exact submitted, size_filtered=1
bash scripts/bash/thunderstorm-collector.sh --dry-run --max-age 0 \
  --dir /tmp/ts-bash-size-edge --max-size 0      # all three submitted, size_filtered=0
```

## Automated Stub Test

```bash
THUNDERSTORM_TEST_COLLECTORS=bash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```
