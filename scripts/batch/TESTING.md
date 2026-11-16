# Batch Collector Testing

How to accept the [Batch collector](README.md) before deployment: the recorded
validation status, manual cases against a real Thunderstorm service, and the
synthetic fault tests in case 7.

## Validation Status

The [8 October 2026 acceptance report](../../docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)
records synthetic Windows CI checks with real cmd/WSH/curl for the revision
listed there. Batch was not executed against real THOR in that report. Native
old Windows/WSH and the packaged file still need target-system acceptance.

## Manual Acceptance Against a Real Service

### Setup

Follow the [manual test preparation](../MANUAL_TESTING_GUIDE.md#manual-test-preparation)
and [acceptance record](../MANUAL_TESTING_GUIDE.md#acceptance-record) guidance. Transfer the standalone file to the actual
Windows target and change into its directory. Use a dedicated normal-user
cmd.exe with delayed expansion disabled:

```cmd
cmd.exe /d /v:off
set "THUNDERSTORM_SERVER=thunderstorm.example.internal"
set "THUNDERSTORM_PORT=8080"
set "URL_SCHEME=http"
set "CURL_PATH=C:\trusted-tools\curl.exe"
"%CURL_PATH%" --version
set "TESTROOT=%TEMP%\ts-batch-%RANDOM%-%RANDOM%"
if exist "%TESTROOT%" echo Choose a different TESTROOT before continuing
mkdir "%TESTROOT%\input\nested"
echo harmless text> "%TESTROOT%\input\plain.txt"
echo nested> "%TESTROOT%\input\nested\space name.txt"
type nul> "%TESTROOT%\input\empty.txt"
echo literal> "%TESTROOT%\input\semi;comma,bang!.txt"
set "COLLECT_DIRS=%TESTROOT%\input"
set "RELEVANT_EXTENSIONS=*"
set "MAX_AGE=0"
set "COLLECT_MAX_SIZE=2097152"
set "UPLOAD_ATTEMPTS=1"
set "SOURCE=manual-batch-unique-tester-date"
set "DRY_RUN=0"
```

Substitute your real service and a TRUSTED absolute curl path. Do not upload the
whole TEMP/Windows directory. Create a binary fixture with an approved binary tool,
or copy a small known binary into input\binary.bin; record its SHA256 before testing.
Do not use a license file as a sample. Use a separate source suffix for every run.
For HTTPS set URL_SCHEME=https and, if needed, CURL_CA_BUNDLE to the approved public
root file. HTTP is unencrypted.

### 1. Offline Dry Run

```cmd
set "DRY_RUN=1"
set "THUNDERSTORM_SERVER=127.0.0.1"
set "THUNDERSTORM_PORT=1"
thunderstorm-collector.bat
echo exit_code=%ERRORLEVEL%
```

Expected: exit 0, four would-submit files (five with binary.bin), Submitted 0,
NO network and no temporary sample copy. Repeat with CURL_PATH=C:\missing-curl.exe:
dry run still succeeds. Restore the trusted CURL_PATH afterwards.

### 2. Upload and Binary Integrity

```cmd
set "DRY_RUN=0"
set "THUNDERSTORM_SERVER=thunderstorm.example.internal"
set "THUNDERSTORM_PORT=8080"
set "SOURCE=manual-batch-basic-unique"
thunderstorm-collector.bat
echo exit_code=%ERRORLEVEL%
```

Expected: exit 0, all four/five files submitted; nested and empty samples included.
Independently compare sizes and SHA256 against service-side stored samples.
Use certutil -hashfile with SHA256 where available or an approved hash utility.
Confirm source exactly in service audit/findings if exposed; empty finding arrays
do not establish source correctness. Wait for async analysis to finish separately.

### 3. Unreachable and Missing Dependencies

```cmd
set "THUNDERSTORM_SERVER=127.0.0.1"
set "THUNDERSTORM_PORT=1"
set "SOURCE=manual-batch-offline-unique"
set "SERVER_WAIT=0"
thunderstorm-collector.bat
echo exit_code=%ERRORLEVEL%
```

Expected: exit 1, Failed 3 (or the eligible file count if lower), Submitted 0, no
uploads, and a message that the collection stops because the service is
unreachable. Repeat with SERVER_WAIT=20: the run waits about 20 seconds before it
stops.

Repeat a LIVE run with CURL_PATH=C:\missing-curl.exe: exit 2 BEFORE network.
Check blocked WSH fails nonzero on the target; do not bypass its security policy.
Restore server, port and trusted curl for later cases.

### 4. Missing Roots and Locked Files

```cmd
set "COLLECT_DIRS=%TESTROOT%\input;%TESTROOT%\does-not-exist"
set "SOURCE=manual-batch-missing-unique"
thunderstorm-collector.bat
echo exit_code=%ERRORLEVEL%
set "COLLECT_DIRS=%TESTROOT%\does-not-exist"
thunderstorm-collector.bat
echo exit_code=%ERRORLEVEL%
set "COLLECT_DIRS=%TESTROOT%\input"
```

Expected: mixed roots exit 1, readable input still submitted, Scan errors 1.
All missing exit 2 before upload. Hold a fixture file exclusively open using an
approved test helper/editor that actually denies reads, or the
[PowerShell lock example](../powershell/TESTING.md#5-missing-roots-and-a-locked-file)
on a test host. The collector itself does not need PowerShell. Other readable siblings must upload; locked file counts Failed,
exit 1. Close the handle; do not mistake an editor without a read-denying lock
for a successful lock test.

### 5. Filters and Exact Boundary

In a NEW filter subdirectory create include.exe, reject.bin and an old.txt whose
last-modification date is 2000-01-01 using an approved target-compatible tool.
Set COLLECT_DIRS to this directory, RELEVANT_EXTENSIONS=.exe and MAX_AGE=0.
Expected: include.exe only, exit 0.

With RELEVANT_EXTENSIONS=* and MAX_AGE=1, recent files upload, old.txt does not.
With MAX_AGE=0, old.txt uploads too. Creation time must not override old mtime.

For size, create exactly 1024-byte limit.bin and 1025-byte over.bin in a separate
size directory (fsutil file createnew if permitted, otherwise an approved tool).

```cmd
set "COLLECT_DIRS=%TESTROOT%\size"
set "RELEVANT_EXTENSIONS=*"
set "MAX_AGE=0"
set "COLLECT_MAX_SIZE=1024"
set "SOURCE=manual-batch-size-unique"
thunderstorm-collector.bat
echo exit_code=%ERRORLEVEL%
```

Expected: only limit.bin submitted, over.bin skipped, exit 0. Verify server absence,
not merely local counters. Invalid numeric values (THUNDERSTORM_PORT=0,
COLLECT_MAX_SIZE=0, MAX_AGE=-1, UPLOAD_ATTEMPTS=11) must fail exit 2 before network,
not be evaluated as shell arithmetic or reset to defaults.

### 6. Junctions, Special Names and TLS

Make a test junction from input to a separate fixture sentinel directory using
mklink /J; rerun basic upload. Expect no sentinel uploads or recursion loop.
Remove the junction itself before deleting fixtures; never delete the target recursively.

The synthetic Windows suite additionally checks percent/exclamation/ampersand/Unicode
filenames and a Unicode source. Do not construct such fixtures by pasting unsafe
unquoted echo commands into cmd; use a filesystem tool that treats names literally.

Against your authorized HTTPS TEST service, an untrusted certificate must fail with
Submitted 0 and exit 1. The right CURL_CA_BUNDLE should allow transfers; an unrelated
CA/wrong server hostname must not. Do not work around failures with -k or a global
trust change. Source uploads still have NO collection markers by design.

### 7. Synthetic Fault Tests

From the repository root on a Windows TEST HOST with Python 3:

```cmd
python -B scripts\tests\test_batch_robustness.py
echo exit_code=%ERRORLEVEL%
```

The collector does not depend on this test-host Python or the PowerShell lock helper.
Tests cover byte integrity, missing roots, locked files, dry run, filters, bounded
503 recovery/exhaustion, incomplete 2xx replies and redirects without disturbing the
real service. Explicit skipped PowerShell-marker cases are NOT Batch feature passes.

For forced-stop behavior, use a dedicated test source and small fixture tree, stop
the process once, verify no later uploads, and inspect only this run's
TEMP\thunderstorm-* directory for leftovers. WSH Ctrl+C may bypass finally, so cleanup
and interrupted markers cannot be promised. Delete only confirmed OWN test leftovers.

### Cleanup and Record

Release locks and remove test junctions first. Remove only the unique TESTROOT you
created. Record commit, OS, WSH/curl versions, every command/exit code and independent
server evidence. Keep service credentials/licenses/private keys out of the repo.
Reference: [curl response limits](https://curl.se/docs/manpage.html#--max-filesize).
