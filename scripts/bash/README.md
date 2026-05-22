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

## Automated Stub Test

```bash
THUNDERSTORM_TEST_COLLECTORS=bash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

