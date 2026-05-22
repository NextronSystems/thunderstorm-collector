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

## Automated Stub Test

```bash
THUNDERSTORM_TEST_COLLECTORS=perl THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

