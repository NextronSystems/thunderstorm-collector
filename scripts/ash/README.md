# POSIX sh / ash Collector

`thunderstorm-collector-ash.sh` is intended for minimal Unix-like systems where Bash is not available. Typical targets are BusyBox, Alpine Linux, embedded Linux, routers, network appliances, containers, and stripped-down recovery environments.

## Intended Use

Use this collector when the target system only provides POSIX `sh`, BusyBox `ash`, `dash`, or another minimal Bourne-compatible shell.

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | POSIX-compatible `sh` such as `ash`, `dash`, or `busybox sh` |
| Upload tool | Prefer `curl`; fallback support depends on the collector implementation and local tools |
| Utilities | Standard POSIX tools such as `find`, `sed`, `grep`, `tr`, `wc`, and `od` |

## Capabilities

- Designed to avoid Bash-only syntax.
- Recursive directory scanning.
- File age and file size filtering.
- Configurable source identifier.
- Dry-run mode.
- Collection markers when supported by the target environment and upload tool.

## Limitations

- Less feature-rich than the Bash collector.
- Filename handling is constrained by POSIX shell limitations.
- Minimal upload tools, especially BusyBox `wget`, can have binary upload limitations.
- Use the Bash collector instead when Bash is available and reliable binary-safe uploads are required.

## Basic Usage

```sh
sh scripts/ash/thunderstorm-collector-ash.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp \
  --max-age 14
```

## Manual Acceptance Test

```sh
rm -rf /tmp/ts-ash-acceptance
mkdir -p /tmp/ts-ash-acceptance/subdir
printf 'ash acceptance text\n' > /tmp/ts-ash-acceptance/sample.txt
printf 'nested\n' > /tmp/ts-ash-acceptance/subdir/nested.txt

sh scripts/ash/thunderstorm-collector-ash.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-ash-acceptance \
  --source manual-ash-acceptance \
  --max-age 30
```

Acceptance criteria:

- The command exits successfully.
- Thunderstorm records uploads for the test files.
- The source field is `manual-ash-acceptance`.
- Nested files are uploaded.

If binary uploads are relevant for the target environment, add a binary test file and verify that Thunderstorm receives the full file.

## Manual Robustness Tests

These tests focus on behavior in constrained POSIX environments. Use `sh`, `ash`, or `busybox sh` consistently with the target system you are validating.

### Dry-run does not contact the server

```sh
sh scripts/ash/thunderstorm-collector-ash.sh \
  --server 127.0.0.1 \
  --port 1 \
  --dir /tmp/ts-ash-acceptance \
  --source manual-ash-dry-run \
  --dry-run
```

Expected result:

- The command exits successfully.
- No upload is visible in Thunderstorm.
- The output shows what would be submitted.

### Thunderstorm service unreachable

```sh
sh scripts/ash/thunderstorm-collector-ash.sh \
  --server 127.0.0.1 \
  --port 1 \
  --dir /tmp/ts-ash-acceptance \
  --source manual-ash-unreachable \
  --max-age 30
```

Expected result:

- The command exits non-zero or reports failed submissions.
- The collector prints a clear connection/upload failure.
- The command does not hang indefinitely.

### Missing and unreadable paths

This test is meaningful only when not running as `root`.

```sh
rm -rf /tmp/ts-ash-errors
mkdir -p /tmp/ts-ash-errors/readable /tmp/ts-ash-errors/unreadable
printf 'readable\n' > /tmp/ts-ash-errors/readable/ok.txt
printf 'secret\n' > /tmp/ts-ash-errors/unreadable/blocked.txt
chmod 000 /tmp/ts-ash-errors/unreadable/blocked.txt

sh scripts/ash/thunderstorm-collector-ash.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-ash-errors/readable \
  --dir /tmp/ts-ash-errors/unreadable \
  --dir /tmp/ts-ash-errors/missing \
  --source manual-ash-error-paths \
  --max-age 30

chmod 644 /tmp/ts-ash-errors/unreadable/blocked.txt
```

Expected result:

- The collector does not crash on missing or unreadable paths.
- The readable file is still submitted.
- Warnings or failed-file statistics are acceptable.

### Binary upload check for minimal tools

Run this when validating BusyBox or systems without `curl`:

```sh
rm -rf /tmp/ts-ash-binary
mkdir -p /tmp/ts-ash-binary
printf '\x00\x01\x02THUNDER\x00\xff\n' > /tmp/ts-ash-binary/binary.bin

sh scripts/ash/thunderstorm-collector-ash.sh \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-ash-binary \
  --source manual-ash-binary \
  --max-age 30
```

Expected result:

- Thunderstorm receives `binary.bin`.
- The uploaded file size/hash should match the local file.
- If only BusyBox `wget` is available, review warnings carefully because some BusyBox variants are not binary-safe for multipart uploads.

## Automated Stub Test

```bash
THUNDERSTORM_TEST_COLLECTORS=ash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```
