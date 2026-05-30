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

Confirm the real THOR Thunderstorm endpoint that will be used for manual acceptance:

```text
Thunderstorm server: <hostname-or-ip>
Thunderstorm port:   <port>
URL scheme:          http or https
```

For collector README commands that use `thunderstorm.local`, substitute the real service values. For example:

```text
server: thunderstorm.example.internal
port: 8080
```

Before running destructive or high-volume tests, use a dedicated test source identifier such as:

```text
manual-bash-acceptance-<tester-name>
manual-python3-error-paths-<tester-name>
```

After each acceptance run, inspect the real Thunderstorm service and verify:

- The expected files were received.
- The source identifier matches the manual test command.
- Text and binary samples appear as separate uploads where applicable.
- Nested files appear when recursive traversal is expected.
- Filtered files are absent when a size, age, or extension filter is being tested.
- Failed or skipped files are visible in collector output and are not reported as successful uploads.

The local `thunderstorm-stub-server` remains useful for repeatable automated checks and CI-style contract validation, but it is not the primary manual acceptance target when a real THOR Thunderstorm service is available.

## Optional Stub Server Setup

Use this only for automated stub tests or when the real service is temporarily unavailable.

Update and build the local stub server:

```bash
cd ../thunderstorm-stub-server
git pull --ff-only
go build -o thunderstorm-stub-server .
```

Start the stub server in a separate terminal:

```bash
cd /path/to/thunderstorm-stub-server
rm -rf /tmp/thunderstorm-stub-uploads
mkdir -p /tmp/thunderstorm-stub-uploads
./thunderstorm-stub-server \
  --port 8080 \
  --uploads-dir /tmp/thunderstorm-stub-uploads \
  --log-file /tmp/thunderstorm-stub-audit.jsonl
```

For stub-server runs, use:

```text
server: 127.0.0.1
port: 8080
```

Inspect uploads and audit logs with:

```bash
ls -la /tmp/thunderstorm-stub-uploads
tail -n 20 /tmp/thunderstorm-stub-audit.jsonl
```

The stub server validates the HTTP upload contract and records uploaded samples. It does not validate production Thunderstorm scanning behavior, authentication, deployment networking, or real-service operational behavior.

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

## Manual Test Preparation

Use one acceptance record per collector PR. Do not mix results from different collectors under the same source identifier.

Before testing a collector, write down:

```text
PR:
Branch:
Commit:
Tester:
Test date:
Target OS:
Runtime version:
Thunderstorm server:
Thunderstorm port:
URL scheme:
Source identifier:
```

Use a source identifier that makes the run easy to find in Thunderstorm:

```text
manual-<collector>-<test-type>-<tester>-<date>
```

Examples:

```text
manual-bash-acceptance-alice-2026-05-30
manual-python3-size-filter-alice-2026-05-30
manual-powershell-locked-file-alice-2026-05-30
```

For every command that is expected to upload files, keep the terminal output. If the command fails, keep the exit code and the last visible error lines.

On Unix-like systems, capture the exit code with:

```bash
echo "exit_code=$?"
```

On Windows PowerShell, capture the exit code with:

```powershell
$LASTEXITCODE
```

On Windows `cmd.exe`, capture the exit code with:

```cmd
echo %ERRORLEVEL%
```

## Manual Test Data

Create small, harmless files. Do not point collectors at broad production directories during acceptance testing. The goal is to validate collector behavior, not to upload a large live system sample set.

### Unix Test Data

Use this structure for Bash, ash, Python, and Perl tests:

```bash
COLLECTOR="bash"
TEST_ROOT="/tmp/ts-${COLLECTOR}-manual"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/input/nested" "$TEST_ROOT/errors/readable" "$TEST_ROOT/errors/unreadable" "$TEST_ROOT/filter"

printf 'manual acceptance text\n' > "$TEST_ROOT/input/sample.txt"
printf '\000\001\002THUNDERSTORM\000\377\n' > "$TEST_ROOT/input/sample.bin"
printf 'nested file\n' > "$TEST_ROOT/input/nested/nested.txt"
printf 'old file\n' > "$TEST_ROOT/filter/old.txt"
printf 'small file\n' > "$TEST_ROOT/filter/small.txt"
dd if=/dev/zero of="$TEST_ROOT/filter/large.bin" bs=1024 count=32 2>/dev/null
printf 'readable\n' > "$TEST_ROOT/errors/readable/ok.txt"
printf 'blocked\n' > "$TEST_ROOT/errors/unreadable/blocked.txt"
touch -t 200001010000 "$TEST_ROOT/filter/old.txt"
chmod 000 "$TEST_ROOT/errors/unreadable"
```

After unreadable-file testing, always restore permissions:

```bash
chmod 755 "$TEST_ROOT/errors/unreadable"
```

If the test is run as `root`, unreadable-file checks may not behave as expected because `root` can still read most files. Record that limitation instead of treating it as a collector failure.

### Windows Test Data

Use this structure for PowerShell and Batch tests:

```powershell
$Collector = "powershell"
$TestRoot = Join-Path $env:TEMP "ts-$Collector-manual"
Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$TestRoot\input\nested" | Out-Null
New-Item -ItemType Directory -Path "$TestRoot\filter" | Out-Null
New-Item -ItemType Directory -Path "$TestRoot\errors" | Out-Null

Set-Content -Path "$TestRoot\input\sample.txt" -Value "manual acceptance text"
[IO.File]::WriteAllBytes("$TestRoot\input\sample.bin", [byte[]](0,1,2,84,72,85,78,68,69,82))
Set-Content -Path "$TestRoot\input\nested\nested.txt" -Value "nested file"
Set-Content -Path "$TestRoot\filter\include.exe" -Value "include"
Set-Content -Path "$TestRoot\filter\skip.tmp" -Value "skip"
Set-Content -Path "$TestRoot\filter\small.txt" -Value "small"
fsutil file createnew "$TestRoot\filter\large.txt" 32768
Set-Content -Path "$TestRoot\errors\ok.txt" -Value "readable"
Set-Content -Path "$TestRoot\errors\locked.txt" -Value "locked"
```

If `fsutil` requires elevation or is unavailable, create a large file with PowerShell instead:

```powershell
[IO.File]::WriteAllBytes("$TestRoot\filter\large.txt", (New-Object byte[] 32768))
```

## Manual Test Sequence

Run these tests for each collector PR unless the collector README explicitly documents that the feature is unsupported.

### Test 1: Help and Runtime Smoke Test

Purpose:

- Confirm that the intended interpreter can start the collector.
- Confirm that missing dependencies are reported clearly.
- Confirm that the collector does not require a broad system scan just to display usage or fail validation.

Expected result:

- Help output or validation output is readable.
- Missing runtime dependencies are explicit, for example missing `curl`, missing Perl `LWP::UserAgent`, or blocked PowerShell execution policy.
- The command does not upload files.

### Test 2: Basic Upload

Purpose:

- Confirm the collector can upload normal text files.
- Confirm the collector can upload binary files where supported.
- Confirm recursive traversal finds nested files.
- Confirm the configured source identifier appears in Thunderstorm.

Use the collector-specific README command for the manual acceptance test. Set the scan directory to the test data `input` directory and use a unique source identifier.

Expected result in Thunderstorm:

- `sample.txt` is present.
- `sample.bin` is present where binary upload is supported.
- `nested.txt` is present for recursive collectors.
- The source identifier exactly matches the command.

Failure conditions:

- The collector exits successfully but no upload appears in Thunderstorm.
- The source identifier is missing or wrong.
- Binary upload is truncated or corrupted on a collector that claims binary-safe upload support.
- Nested files are missing on a collector that claims recursive traversal support.

### Test 3: Dry Run

Purpose:

- Confirm dry-run mode does not contact Thunderstorm.
- Confirm dry-run output still shows what would be processed.

Use `127.0.0.1` with port `1` for this test. That endpoint should be unreachable, so any server contact would normally fail.

Expected result:

- The command exits successfully.
- No new upload appears in Thunderstorm.
- Output lists files that would be submitted, or clearly reports dry-run processing.

Failure conditions:

- A new upload appears in Thunderstorm.
- The command fails only because `127.0.0.1:1` is unreachable.
- Dry-run output is misleading or empty despite matching test files.

### Test 4: Unreachable Thunderstorm Service

Purpose:

- Confirm network failures are visible.
- Confirm the collector does not hang indefinitely.
- Confirm failed uploads are not reported as successful.

Use `127.0.0.1` with port `1` and the normal test input directory.

Expected result:

- The command exits non-zero or clearly reports upload failures.
- The error mentions connection, upload, begin marker, or server failure.
- The command returns within a reasonable time for that collector.
- No new upload appears in Thunderstorm.

Failure conditions:

- The command hangs indefinitely.
- The command exits successfully while all uploads failed.
- The output hides the network failure.

### Test 5: Missing and Unreadable Paths

Purpose:

- Confirm one bad path does not stop all readable files.
- Confirm warnings or failed-file counters are visible.

Use one readable directory, one unreadable directory or locked file, and one missing directory.

Expected result:

- The readable file is uploaded.
- Missing or unreadable paths are reported.
- The collector does not terminate with an unhandled exception.
- The final status does not imply that every file was uploaded successfully when some files were skipped or failed.

Failure conditions:

- The readable file is not uploaded because another path failed.
- The collector crashes without a useful message.
- The collector silently ignores unreadable input while reporting full success.

### Test 6: Filter Behavior

Purpose:

- Confirm file size, age, and extension filters include and exclude the intended files.

Use the files in the `filter` test directory.

Expected result:

- Small files are uploaded when they match the active filter.
- Oversized files are skipped when a size limit is set.
- Old files are skipped when an age limit excludes them.
- Extension filters include only the requested extensions.

Failure conditions:

- Filtered-out files appear in Thunderstorm.
- Expected included files are missing.
- The collector output does not explain skipped files where the collector claims to report filtering.

### Test 7: README Accuracy

Purpose:

- Confirm documentation matches observed behavior.

After testing, compare the collector README with actual results.

Expected result:

- Intended use, requirements, capabilities, and limitations are accurate.
- Any observed runtime limitation is already documented or should be added before merge.

Failure conditions:

- README claims support for behavior that failed during testing.
- README omits a material dependency or limitation found during testing.

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

Manual test procedure:

- Set `COLLECTOR="bash"` when creating Unix test data.
- Run the README manual acceptance command against the real Thunderstorm service with `--dir "$TEST_ROOT/input"`.
- Verify `sample.txt`, `sample.bin`, and `nested/nested.txt` in Thunderstorm.
- Run the README dry-run command with `--server 127.0.0.1 --port 1` and verify no Thunderstorm upload appears.
- Run the unreachable-service command with `--server 127.0.0.1 --port 1` and verify visible failure.
- Run the missing/unreadable path command with the readable, unreadable, and missing test directories.
- Run the file size filter command with the `filter` directory and verify `small.txt` is uploaded while `large.bin` is skipped.
- Record whether warnings, failed counters, and exit codes match the README expectations.

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

Manual test procedure:

- Set `COLLECTOR="ash"` when creating Unix test data.
- Run all commands with the shell that represents the target environment, for example `sh`, `ash`, `dash`, or `busybox sh`.
- Run the README manual acceptance command against the real Thunderstorm service with the test `input` directory.
- Verify `sample.txt` and `nested/nested.txt` in Thunderstorm.
- If the target environment should support binary upload, add `sample.bin` to the acceptance check and compare size/hash if Thunderstorm exposes that data.
- Run the dry-run test against `127.0.0.1:1` and verify no upload appears.
- Run the unreachable-service test and verify a visible failure or failed-submission report.
- Run missing/unreadable path testing and verify readable files are still processed.
- On BusyBox-only systems, explicitly record which upload tool was used, for example BusyBox `wget` or `curl`.

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

Manual test procedure:

- Set `COLLECTOR="python"` when creating Unix test data.
- Run the Python 3 README manual acceptance command against the real Thunderstorm service with the test `input` directory.
- Verify `sample.txt`, `sample.bin`, and `nested/nested.txt` in Thunderstorm.
- Repeat the same basic upload test with the Python 2 collector on a real Python 2.7 runtime if Python 2 support is in scope.
- Run the dry-run test against `127.0.0.1:1` for Python 3, and repeat for Python 2 if in scope.
- Run the unreachable-service test and verify a visible connection failure.
- Run missing/unreadable path testing and verify readable files still upload.
- Run the file size filter test and verify `small.txt` uploads while `large.bin` is skipped.
- If HTTPS is required, test `--tls`; if the certificate is private or self-signed, test the documented insecure mode only if that is acceptable for the environment.
- Record any Python 2 TLS or Unicode/path limitation as a runtime limitation.

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

Manual test procedure:

- Set `COLLECTOR="perl"` when creating Unix test data.
- Verify the runtime dependency before testing with `perl -MLWP::UserAgent -e 1`.
- Run the README manual acceptance command against the real Thunderstorm service with the test `input` directory.
- Verify `sample.txt`, `sample.bin`, and `nested/nested.txt` in Thunderstorm.
- Run the dry-run test against `127.0.0.1:1` and verify no upload appears.
- Run the unreachable-service test and verify a visible connection failure.
- Run missing/unreadable path testing and verify readable files still upload.
- Run the file size filter test and verify `small.txt` uploads while `large.bin` is skipped.
- If HTTPS is required on the target host, explicitly test that host's Perl SSL stack against the real service.

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

Manual test procedure for PowerShell:

- Set `$Collector = "powershell"` when creating Windows test data.
- Run the README PowerShell 3+ manual acceptance command against the real Thunderstorm service with `$TestRoot\input`.
- Verify `sample.txt` and `sample.bin` in Thunderstorm.
- Repeat the basic upload test with the PowerShell 2 collector on a real PowerShell 2 host if PowerShell 2 support is in scope.
- Run the unreachable-service test against `127.0.0.1:1` and verify visible failure.
- Run the missing-folder test and verify the collector reports the issue without an unhandled exception.
- Run the locked-file test and verify `ok.txt` uploads while `locked.txt` is skipped or reported failed.
- Run the extension filter test and verify `include.exe` uploads while `skip.tmp` is absent.
- Record the execution policy used, for example `-ExecutionPolicy Bypass`.

Manual test procedure for Batch:

- Run tests from `cmd.exe`, not PowerShell, unless PowerShell is only used to prepare test files.
- Confirm `curl.exe` is available with `where curl`.
- Run the README Batch manual acceptance command against the real Thunderstorm service with `%TEMP%\ts-batch-acceptance` or the prepared `$TestRoot\input` path translated to `%TESTDIR%`.
- Verify the matching `.txt` file appears in Thunderstorm.
- Run the unreachable-service test against `127.0.0.1:1` and verify curl/upload errors are visible.
- Run the missing-folder test and verify the collector reports no matching files or invalid input without crashing the shell.
- Run the extension filter test and verify `include.txt` uploads while `skip.tmp` is absent.
- Run the file size filter test and verify `small.txt` uploads while `large.txt` is skipped.
- Treat weak Batch error reporting as acceptable only if the failure is visible enough for an operator to detect.

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
- Whether the real Thunderstorm service and/or the stub server was used.
- Thunderstorm endpoint details, excluding credentials or secrets.
- The source identifier used in the test.
- Number of files expected and number of files observed in Thunderstorm.
- For stub runs, number of files observed in `/tmp/thunderstorm-stub-uploads`.
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
- The manual acceptance test from the collector README passes against the real THOR Thunderstorm service.
- The robustness checks do not reveal silent data loss, hangs, or misleading success reports.
- The README accurately describes any limitation found during testing.

Recommended merge sequence after acceptance remains:

1. Merge #43.
2. Merge #49.
3. Merge accepted collector PRs #44 through #48.

If a collector fails manual acceptance, keep its PR open and merge only the PRs that passed.
