# Windows Batch Collector

Use [thunderstorm-collector.bat](thunderstorm-collector.bat) on Windows hosts
where the Go and PowerShell collectors are impractical. This standalone file is
a cmd/JScript hybrid: Windows Script Host handles file data. It requires enabled
WSH/JScript, FileSystemObject, ADODB.Stream and a trusted curl.exe 8.4 or later.

These instructions describe the current source file. Check the
[release availability note](../../README.md#download-a-collector) before using a
published asset; older releases have different options. See
[script selection](../README.md#choosing-a-collector) for alternatives.

## Quick Start

Copy `scripts/batch/thunderstorm-collector.bat` from the source checkout to a
working directory on the target. Open `cmd.exe /d /v:off` and change to that
directory. Replace the server, curl path and `C:\Samples` with your endpoint,
trusted executable and an existing absolute directory containing a few synthetic
files. Preview the selection:

```cmd
set "THUNDERSTORM_SERVER=thunderstorm.example.internal"
set "THUNDERSTORM_PORT=8080"
set "URL_SCHEME=http"
set "CURL_PATH=C:\trusted-tools\curl.exe"
set "COLLECT_DIRS=C:\Samples"
set "SOURCE=host-example"
set "MAX_AGE=14"
set "COLLECT_MAX_SIZE=2097152"
set "DRY_RUN=1"
.\thunderstorm-collector.bat
```

Review the selected paths, then enable uploads in the same command session:

```cmd
set "DRY_RUN=0"
.\thunderstorm-collector.bat
```

For HTTPS, set `URL_SCHEME=https`, choose the endpoint's port and, if needed,
set `CURL_CA_BUNDLE` to a PEM CA file. Dry-run makes no requests and does not check
curl availability, payload readability or TLS connectivity. Uploads are
always asynchronous; check received files and analysis results on the server.

## Configuration and Startup Output

Edit the commented JScript `USER CONFIGURATION` block immediately below the
launcher, or set environment variables of the same names. Nonempty environment
values override header defaults; use `0` to turn a header flag off. Leave the
launcher unchanged. In quoted script values double backslashes, for example
`var COLLECT_DIRS = "C:\\Samples;D:\\Evidence";`. In cmd environment assignments
use ordinary paths: `set "COLLECT_DIRS=C:\Samples;D:\Evidence"`.

`THUNDERSTORM_SERVER` (hostname/IP without scheme/port/path) and `COLLECT_DIRS` are
required. Missing values exit 2 with configuration instructions; no broad scan is
implicit. Defaults are **30 days since modification** and **2097152 bytes
(2048 KiB / 2 MiB)**. Older/larger files are not collected. Startup output shows
resolved roots, limits, and selected extensions, including with `DRY_RUN=1`.
Review that preview before enabling uploads. To retain a log, redirect output
to a file outside the input roots, e.g. `thunderstorm-collector.bat > C:\Logs\collector.log 2>&1`,
then inspect it with `type C:\Logs\collector.log`. Redirection replaces live console
output; the collector does not create a separate log itself.

## Requirements and Limits

| Item | Profile |
|---|---|
| Runtime | cmd.exe + enabled Windows Script Host/JScript + FileSystemObject + ADODB.Stream. No PowerShell dependency in the collector. |
| Upload tool | Trusted curl.exe 8.4+; explicit CURL_PATH preferred, then script directory, system directory, PATH. Never searched in the current working directory implicitly. |
| Why curl 8.4+ | Earlier versions cannot bound unknown-length response downloads with max-filesize; see the official curl manual. Verify the binary supports the actual legacy Windows OS. |
| Traversal | Recursive, literal filenames, skips reparse-point/junction entries and known cloud directory names. Not a filesystem sandbox. An entry that vanishes or cannot be read during the walk is counted on its own (a file as failed, a subdirectory as a scan error) and the rest of its directory is still processed. |
| Filtering | MAX_AGE uses last modification time, days; default 30, 0 disables. COLLECT_MAX_SIZE is BYTES, inclusive, 1..209715200; default 2097152 (2 MiB). Extension list default .exe;.dll;.ps1;.bat;.txt; * includes all extensions. |
| Upload | Binary/empty-file safe snapshots, one multipart file; async `/api/checkAsync` only. Source UTF-8 percent-encoded. |
| Deliberately absent | Collection markers/scan_id, interrupted markers, result polling, deduplication, resume, custom insecure TLS mode, syslog, parallelism. |
| TLS | curl certificate/hostname verification stays enabled; CURL_CA_BUNDLE is passed explicitly as --cacert, including Schannel builds. No machine trust changes. |
| Retries | UPLOAD_ATTEMPTS 1..10 TOTAL attempts, default 3; 503 Retry-After integer capped at 120 seconds. Each curl attempt has connect 10s / total 30s limits plus 40s process watchdog. |
| Exit | 0 completed transfer/selection run, 1 partial failures, 2 invalid config/no usable roots/missing dependency. WSH launch failures may use host-specific nonzero codes. |
| Temporary data | Exclusively created per-run directory under TEMP; contains copied sample payloads, removed on normal/error completion. Forced termination can leave it behind. |

COLLECT_DIRS separates roots by semicolons; a ROOT containing a semicolon is not
supported. Semicolons, commas, spaces, Unicode, percent, exclamation, brackets and
ampersands in filenames within a root are supported. TEMP and curl executable paths
and custom CA paths containing percent signs, quotes or control characters are rejected to avoid WSH
process expansion; choose a trusted ordinary path. Never disable organizational
WSH policy just to run this collector.

The explicit CA argument avoids curl's Schannel-specific omission of the
CURL_CA_BUNDLE environment setting; see the [curl TLS documentation](https://curl.se/docs/manpage.html#--cacert).
The curl build and Windows version must support that mode; failures do not
automatically disable verification or certificate revocation checking.

ADODB loads selected files into memory; size/mtime checks catch many file changes,
but the size limit is NOT a hard memory bound if a source grows during that read.
Use stable files in a trusted tree, with sufficient RAM; memory can be several times
the file size. A graceful cleanup does not protect against a hostile shared TEMP
directory or shutdown. Keep TEMP private. Filename metadata sanitizes backslash,
quote, semicolon and control characters; payload bytes are untouched.

A 32-bit process on 64-bit Windows runs under file-system redirection: %SystemRoot%\System32 shows the contents of %SystemRoot%\SysWOW64, so the real System32 is not collected. The collector logs a warning in that case; start it from a 64-bit command prompt (from a 32-bit host: %SystemRoot%\SysNative\cmd.exe).

Success means the transfer was accepted, not analysis complete or a positive finding.
An empty eligible set does not probe service availability.

## Validation Status

The [8 October 2026 acceptance report](../../docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)
records synthetic Windows CI checks with real cmd/WSH/curl for the revision
listed there. Batch was not executed against real THOR in that report. Native
old Windows/WSH and the packaged file still need target-system acceptance.

## Setup for Human Acceptance

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

## 1. Offline Dry Run

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

## 2. Upload and Binary Integrity

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

## 3. Unreachable and Missing Dependencies

```cmd
set "THUNDERSTORM_SERVER=127.0.0.1"
set "THUNDERSTORM_PORT=1"
set "SOURCE=manual-batch-offline-unique"
thunderstorm-collector.bat
echo exit_code=%ERRORLEVEL%
```

Expected: exit 1, Failed equals eligible file count, Submitted 0, no uploads.
With UPLOAD_ATTEMPTS=1 each sample has a bounded 30-second request; time the run.

Repeat a LIVE run with CURL_PATH=C:\missing-curl.exe: exit 2 BEFORE network.
Check blocked WSH fails nonzero on the target; do not bypass its security policy.
Restore server, port and trusted curl for later cases.

## 4. Missing Roots and Locked Files

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
[PowerShell lock example](../powershell/README.md#5-missing-roots-and-a-locked-file)
on a test host. The collector itself does not need PowerShell. Other readable siblings must upload; locked file counts Failed,
exit 1. Close the handle; do not mistake an editor without a read-denying lock
for a successful lock test.

## 5. Filters and Exact Boundary

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

## 6. Junctions, Special Names and TLS

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

## 7. Synthetic Fault Tests

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

## Cleanup and Record

Release locks and remove test junctions first. Remove only the unique TESTROOT you
created. Record commit, OS, WSH/curl versions, every command/exit code and independent
server evidence. Keep service credentials/licenses/private keys out of the repo.
Reference: [curl response limits](https://curl.se/docs/manpage.html#--max-filesize).
