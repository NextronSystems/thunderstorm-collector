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

- Recursive directory scanning.
- File age and file size filtering.
- HTTP and HTTPS uploads.
- Configurable source identifier.
- Collection begin/end markers.
- Retry behavior for transient upload failures.
- Dry-run mode for local validation.
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
