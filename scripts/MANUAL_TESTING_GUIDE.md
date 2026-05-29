# Manual Test Guide for Script Collector PRs

This guide is intended for a human reviewer who wants to check out the stacked script collector PRs locally, test each collector, and decide which collector PRs are ready to merge.

The individual collector READMEs contain the detailed command blocks. This document explains the review order, what each PR is expected to change, and what evidence should be collected during manual acceptance.

## PR Stack

Review and merge the PRs in this order:

| Order | PR | Branch | Base | Purpose |
|---|---:|---|---|---|
| 1 | [#43](https://github.com/NextronSystems/thunderstorm-collector/pull/43) | `codex/script-test-base` | `master` | Adds the shared script collector test harness and CI workflow. |
| 2 | [#49](https://github.com/NextronSystems/thunderstorm-collector/pull/49) | `codex/script-layout-docs` | `codex/script-test-base` | Moves script collectors into dedicated subdirectories and adds per-collector documentation. |
| 3 | [#44](https://github.com/NextronSystems/thunderstorm-collector/pull/44) | `codex/script-bash` | `codex/script-layout-docs` | Replaces the Bash collector. |
| 4 | [#45](https://github.com/NextronSystems/thunderstorm-collector/pull/45) | `codex/script-ash` | `codex/script-layout-docs` | Adds the POSIX sh / ash collector. |
| 5 | [#46](https://github.com/NextronSystems/thunderstorm-collector/pull/46) | `codex/script-python` | `codex/script-layout-docs` | Replaces the Python 3 collector and adds the Python 2 collector. |
| 6 | [#47](https://github.com/NextronSystems/thunderstorm-collector/pull/47) | `codex/script-perl` | `codex/script-layout-docs` | Replaces the Perl collector. |
| 7 | [#48](https://github.com/NextronSystems/thunderstorm-collector/pull/48) | `codex/script-windows` | `codex/script-layout-docs` | Replaces the PowerShell collector, adds the PowerShell 2 collector, and updates the Batch collector. |

PRs #43 and #49 are prerequisite infrastructure PRs. The actual collector behavior acceptance happens in PRs #44 through #48.

## Local Setup

Fetch all PR branches:

```bash
cd /path/to/thunderstorm-collector
git fetch origin
```

Update and build the local stub server:

```bash
cd ../thunderstorm-stub-server
git pull --ff-only
go build -o thunderstorm-stub-server .
```

Start the stub server in a separate terminal when a test needs a local Thunderstorm-compatible endpoint:

```bash
cd /path/to/thunderstorm-stub-server
rm -rf /tmp/thunderstorm-stub-uploads
mkdir -p /tmp/thunderstorm-stub-uploads
./thunderstorm-stub-server \
  --port 8080 \
  --uploads-dir /tmp/thunderstorm-stub-uploads \
  --log-file /tmp/thunderstorm-stub-audit.jsonl
```

For collector README commands that use `thunderstorm.local`, substitute:

```text
server: 127.0.0.1
port: 8080
```

After each acceptance run, inspect:

```bash
ls -la /tmp/thunderstorm-stub-uploads
tail -n 20 /tmp/thunderstorm-stub-audit.jsonl
```

The stub server validates the HTTP upload contract and records uploaded samples. It does not replace a final test against a real Thunderstorm service if that is part of the release acceptance process.

## General Acceptance Criteria

For each collector PR, record whether these points pass:

- The collector runs on the intended runtime and operating system.
- The collector uploads at least one text file and, where supported, one binary file.
- Recursive directory traversal works when the collector claims to support it.
- The configured source identifier appears in the uploaded records.
- Dry-run mode, if supported, does not contact the server.
- An unreachable Thunderstorm service fails visibly and does not hang indefinitely.
- Missing, unreadable, or locked files do not crash the whole collector.
- File size, age, and extension filters work where the collector claims to support them.
- The automated stub-server harness passes for the collector selector.
- Limitations documented in the collector README match observed behavior.

## Checking Out a PR

Use a local branch that tracks the remote PR branch:

```bash
git checkout -B codex/script-bash origin/codex/script-bash
```

Replace `codex/script-bash` with the branch under review.

Before testing, confirm the expected branch:

```bash
git status --short --branch
```

## PR #43: Shared Test Harness

Checkout:

```bash
git checkout -B codex/script-test-base origin/codex/script-test-base
```

What to review:

- `.github/workflows/script-collectors.yml` adds Linux and Windows script collector test jobs.
- `scripts/tests/` contains shared operational, detection, filter, and compliance tests.
- The harness can run selected collectors instead of forcing every collector to exist in every branch.

Suggested checks:

```bash
bash -n scripts/tests/run_detection_tests.sh \
  scripts/tests/run_e2e_compliance.sh \
  scripts/tests/run_filter_tests.sh \
  scripts/tests/run_operational_tests.sh

ruby -e 'require "yaml"; YAML.load_file(".github/workflows/script-collectors.yml")'
```

Manual collector acceptance is not required for this PR. This PR is about test infrastructure.

## PR #49: Layout and Documentation

Checkout:

```bash
git checkout -B codex/script-layout-docs origin/codex/script-layout-docs
```

What to review:

- Collectors are organized below `scripts/bash`, `scripts/ash`, `scripts/python`, `scripts/perl`, `scripts/powershell`, and `scripts/batch`.
- `scripts/README.md` explains which collector should be used in which scenario.
- Each collector directory has a README with intended use, requirements, capabilities, limitations, manual acceptance tests, robustness tests, and automated stub test commands.
- `Makefile` packages the new script directory layout for releases.

Suggested checks:

```bash
bash -n scripts/tests/run_detection_tests.sh \
  scripts/tests/run_e2e_compliance.sh \
  scripts/tests/run_filter_tests.sh \
  scripts/tests/run_operational_tests.sh

ruby -e 'require "yaml"; YAML.load_file(".github/workflows/script-collectors.yml")'

make -n release-scripts
```

Manual collector acceptance is optional on this PR because it should not change collector behavior. It should be reviewed primarily for structure, documentation quality, and release packaging.

## PR #44: Bash Collector

Checkout:

```bash
git checkout -B codex/script-bash origin/codex/script-bash
```

Detailed manual test instructions:

```text
scripts/bash/README.md
```

Minimum required manual checks:

- Basic upload of text, binary, and nested files.
- Dry-run against `127.0.0.1:1` does not contact the server.
- Unreachable server fails visibly.
- Missing and unreadable paths do not crash the collector.
- File size filtering skips oversized files.

Automated stub test:

```bash
THUNDERSTORM_TEST_COLLECTORS=bash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

## PR #45: POSIX sh / ash Collector

Checkout:

```bash
git checkout -B codex/script-ash origin/codex/script-ash
```

Detailed manual test instructions:

```text
scripts/ash/README.md
```

Minimum required manual checks:

- Basic upload using the target shell, for example `sh`, `ash`, `dash`, or `busybox sh`.
- Dry-run against `127.0.0.1:1` does not contact the server.
- Unreachable server fails visibly or reports failed submissions.
- Missing and unreadable paths do not crash the collector.
- Binary upload behavior is reviewed on the intended minimal environment, especially when only BusyBox tooling is available.

Automated stub test:

```bash
THUNDERSTORM_TEST_COLLECTORS=ash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

## PR #46: Python Collectors

Checkout:

```bash
git checkout -B codex/script-python origin/codex/script-python
```

Detailed manual test instructions:

```text
scripts/python/README.md
```

Minimum required manual checks:

- Python 3 collector uploads text, binary, and nested files.
- Python 2 collector is tested on a real Python 2.7 runtime if Python 2 support is part of the acceptance target.
- Dry-run against `127.0.0.1:1` does not contact the server.
- Unreachable server fails visibly.
- Missing and unreadable paths do not crash the collector.
- File size filtering skips oversized files.
- Any TLS limitation on old Python 2 runtimes is documented as a runtime limitation.

Automated stub tests:

```bash
THUNDERSTORM_TEST_COLLECTORS=python3 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server

THUNDERSTORM_TEST_COLLECTORS=python2 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

Skip the Python 2 automated test only if Python 2 is intentionally unavailable on the test machine. Record that as a test environment limitation.

## PR #47: Perl Collector

Checkout:

```bash
git checkout -B codex/script-perl origin/codex/script-perl
```

Detailed manual test instructions:

```text
scripts/perl/README.md
```

Minimum required manual checks:

- Perl has `LWP::UserAgent` available.
- Basic upload of text, binary, and nested files.
- Dry-run against `127.0.0.1:1` does not contact the server.
- Unreachable server fails visibly.
- Missing and unreadable paths do not crash the collector.
- File size filtering skips oversized files.
- TLS behavior is reviewed on the intended legacy Perl runtime if HTTPS is required.

Automated stub test:

```bash
THUNDERSTORM_TEST_COLLECTORS=perl THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

## PR #48: Windows Collectors

Checkout:

```bash
git checkout -B codex/script-windows origin/codex/script-windows
```

Detailed manual test instructions:

```text
scripts/powershell/README.md
scripts/batch/README.md
```

Minimum required manual checks for PowerShell:

- PowerShell 3+ collector uploads text and binary files.
- PowerShell 2 collector is tested on a real PowerShell 2 host if PowerShell 2 support is part of the acceptance target.
- Unreachable server fails visibly.
- Missing folder does not crash with an unhandled exception.
- Locked or unreadable file does not stop submission of readable files.
- Extension filtering includes and excludes the expected files.

Minimum required manual checks for Batch:

- Batch collector uploads a simple matching file through `curl.exe`.
- Unreachable server reports upload or curl failure.
- Missing folder fails visibly or reports no matching files.
- Extension filtering includes and excludes the expected files.
- File size filtering skips oversized files.
- Known Batch limitations are acceptable for the intended last-resort use case.

Automated checks:

- Use the GitHub Actions Windows job as the primary automated Windows validation.
- If PowerShell Core is available on a Unix-like machine, run:

```bash
THUNDERSTORM_TEST_COLLECTORS=ps3 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

## Evidence to Record

For each collector PR, record:

- Branch and commit SHA tested.
- Operating system and runtime version, for example Bash version, BusyBox version, Python version, Perl version, PowerShell version, or Windows version.
- Whether the stub server or a real Thunderstorm service was used.
- The source identifier used in the test.
- Number of files expected and number of files observed in Thunderstorm or the stub upload directory.
- Which robustness checks passed.
- Any limitation, warning, timeout, or unexpected exit code.

Useful commands:

```bash
git rev-parse --short HEAD
bash --version
python3 --version
python --version
perl -v
pwsh -v
```

On Windows:

```powershell
$PSVersionTable
cmd /c ver
```

## Merge Decision

A collector PR is ready to merge when:

- The automated CI checks are green.
- The automated stub-server test for that collector passes or an intentional environment skip is documented.
- The manual acceptance test from the collector README passes.
- The robustness checks do not reveal silent data loss, hangs, or misleading success reports.
- The README accurately describes any limitation found during testing.

Recommended merge sequence after acceptance remains:

1. Merge #43.
2. Merge #49.
3. Merge accepted collector PRs #44 through #48.

If a collector fails manual acceptance, keep its PR open and merge only the PRs that passed.
