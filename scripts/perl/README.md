# Perl Collector

`thunderstorm-collector.pl` is intended for Unix-like systems where Perl is available and Python or Bash are not suitable.

## Intended Use

Use this collector on older Unix/Linux hosts, Solaris, AIX, HP-UX, or hardened systems where Perl is available and allowed, but installing the Go collector or using Python is impractical.

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | Perl 5 |
| Module | `LWP::UserAgent` |
| OS | Unix-like systems with Perl and network access to Thunderstorm |

## Capabilities

- Recursive directory scanning.
- File age and file size filtering.
- Multipart uploads through Perl LWP.
- Configurable source identifier.
- Dry-run mode.
- Collection markers.

## Limitations

- Requires `LWP::UserAgent`; this is not guaranteed to be installed on minimal systems.
- TLS behavior depends on the installed Perl SSL stack.
- Prefer Bash or Python 3 on systems where those runtimes are already available and tested.

## Basic Usage

```bash
perl scripts/perl/thunderstorm-collector.pl \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp \
  --max-age 14
```

## Manual Acceptance Test

```bash
rm -rf /tmp/ts-perl-acceptance
mkdir -p /tmp/ts-perl-acceptance/subdir
printf 'perl acceptance text\n' > /tmp/ts-perl-acceptance/sample.txt
printf '\x00\x01\x02THUNDER\n' > /tmp/ts-perl-acceptance/sample.bin
printf 'nested\n' > /tmp/ts-perl-acceptance/subdir/nested.txt

perl scripts/perl/thunderstorm-collector.pl \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-perl-acceptance \
  --source manual-perl-acceptance \
  --max-age 30
```

Acceptance criteria:

- The command exits successfully.
- Thunderstorm records uploads for the test files.
- The source field is `manual-perl-acceptance`.
- Text, binary, and nested files are uploaded.

## Manual Robustness Tests

### Dry-run does not contact the server

```bash
perl scripts/perl/thunderstorm-collector.pl \
  --server 127.0.0.1 \
  --port 1 \
  --dir /tmp/ts-perl-acceptance \
  --source manual-perl-dry-run \
  --dry-run
```

Expected result:

- The command exits successfully.
- No upload is visible in Thunderstorm.
- The output reports what would be submitted.

### Thunderstorm service unreachable

```bash
perl scripts/perl/thunderstorm-collector.pl \
  --server 127.0.0.1 \
  --port 1 \
  --dir /tmp/ts-perl-acceptance \
  --source manual-perl-unreachable \
  --max-age 30
```

Expected result:

- The command exits non-zero or reports failed submissions.
- The collector prints a clear connection failure.
- The command does not hang indefinitely.

### Missing and unreadable paths

This test is meaningful only when not running as `root`.

```bash
rm -rf /tmp/ts-perl-errors
mkdir -p /tmp/ts-perl-errors/readable /tmp/ts-perl-errors/unreadable
printf 'readable\n' > /tmp/ts-perl-errors/readable/ok.txt
printf 'secret\n' > /tmp/ts-perl-errors/unreadable/blocked.txt
chmod 000 /tmp/ts-perl-errors/unreadable/blocked.txt

perl scripts/perl/thunderstorm-collector.pl \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-perl-errors/readable \
  --dir /tmp/ts-perl-errors/unreadable \
  --dir /tmp/ts-perl-errors/missing \
  --source manual-perl-error-paths \
  --max-age 30

chmod 644 /tmp/ts-perl-errors/unreadable/blocked.txt
```

Expected result:

- The collector does not crash on missing or unreadable paths.
- The readable file is still submitted.
- Warnings or failed-file statistics are acceptable.

### File size filter

```bash
rm -rf /tmp/ts-perl-filter
mkdir -p /tmp/ts-perl-filter
printf 'small\n' > /tmp/ts-perl-filter/small.txt
dd if=/dev/zero of=/tmp/ts-perl-filter/large.bin bs=1024 count=32 2>/dev/null

perl scripts/perl/thunderstorm-collector.pl \
  --server thunderstorm.local \
  --port 8080 \
  --dir /tmp/ts-perl-filter \
  --source manual-perl-size-filter \
  --max-age 30 \
  --max-size-kb 1
```

Expected result:

- `small.txt` is submitted.
- `large.bin` is skipped by the size filter.

## Automated Stub Test

```bash
THUNDERSTORM_TEST_COLLECTORS=perl THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```
