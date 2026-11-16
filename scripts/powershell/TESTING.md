# PowerShell Collector Testing

How to accept the [PowerShell collectors](README.md) before deployment: the
recorded validation status, manual cases against a real Thunderstorm service,
and the automated loopback suite in case 8.

## Validation Status

The [8 October 2026 acceptance report](../../docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)
records both files running against real THOR under PowerShell 7.5.0 on macOS, and
synthetic Windows CI checks under Windows PowerShell 5.1. Those results apply to
the recorded revisions and assets; they do not establish actual PowerShell 2,
PowerShell 3 or old CLR compatibility. Test the intended Windows/CLR combination.

## Manual Acceptance Against a Real Service

### Setup

Follow the [manual test preparation](../MANUAL_TESTING_GUIDE.md#manual-test-preparation)
and [acceptance record](../MANUAL_TESTING_GUIDE.md#acceptance-record) guidance. Transfer the chosen standalone file to the
actual target, change into its directory, and run the following in PowerShell
as a normal user. Choose one file and repeat the complete sequence separately
for each profile on its intended host:

```powershell
$Collector = (Join-Path $PWD 'thunderstorm-collector.ps1')
# Legacy alternative:
# $Collector = (Join-Path $PWD 'thunderstorm-collector-ps2.ps1')
$PSVersionTable.PSVersion
[Environment]::Version
$Server = 'thunderstorm.example.internal'  # your authorized real service
$Port = 8080
$Tag = 'manual-ps-' + [Guid]::NewGuid().ToString('N')
$Root = Join-Path $env:TEMP $Tag
New-Item -ItemType Directory -Path $Root | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Root 'input') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Root 'input\nested') | Out-Null
[IO.File]::WriteAllText((Join-Path $Root 'input\plain.txt'), "harmless text")
[IO.File]::WriteAllBytes((Join-Path $Root 'input\binary.bin'), [byte[]](0,1,255,84,72,10))
[IO.File]::WriteAllBytes((Join-Path $Root 'input\empty.bin'), (New-Object byte[] 0))
[IO.File]::WriteAllText((Join-Path $Root 'input\nested\space name.txt'), 'nested')
[IO.File]::WriteAllText((Join-Path $Root 'input\semi;percent%PATH%!&.txt'), 'literal name')
$InputDir = Join-Path $Root 'input'
```

Keep the collector and logs outside the input directory.

For HTTPS, add -UseSSL to EVERY service command below, and -CACert with an approved
public CA on a supported CLR if needed. Never copy the service license to the
collector machine. HTTP transmits sample contents unencrypted.

### 1. Dry Run Without a Service

```powershell
& $Collector -ThunderstormServer 127.0.0.1 -ThunderstormPort 1 -Folder $InputDir -Source "$Tag-dry" -MaxAge 0 -AllExtensions -DryRun
$LASTEXITCODE
```

Expected: exit 0, five would-submit entries, submitted counter 0, NO HTTP requests
including markers. The nonexistent service must not cause a failure.

### 2. Real Upload, Bytes and Source

```powershell
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $InputDir -Source "$Tag-basic" -MaxAge 0 -AllExtensions -Retries 1
$LASTEXITCODE
```

Expected: exit 0, Checked 5 / Submitted 5 / Failed 0 / Scan errors 0. Independently
confirm five stored files, including nested and empty. Compare SHA256 and sizes
against the originals with service-side stored samples or audit output. On PS4+,
Get-FileHash can hash the originals; on PS2 use an approved independent hash tool.
Confirm the source string exactly where server output exposes it. Empty finding
arrays are NOT proof of source metadata or byte integrity. Wait for async completion
in the service before deciding whether scanning succeeded.

PS2 without a JSON parser disables collection markers; -Debugging shows it. Record
NOT SUPPORTED rather than declaring the marker test passed.

### 3. Extension, Age and Size Boundaries

```powershell
$Filter = Join-Path $Root 'filter'
New-Item -ItemType Directory -Path $Filter | Out-Null
[IO.File]::WriteAllText((Join-Path $Filter 'include.exe'), 'include')
[IO.File]::WriteAllText((Join-Path $Filter 'skip.bin'), 'skip')
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $Filter -Source "$Tag-ext" -MaxAge 0 -Extensions '.exe' -Retries 1
$LASTEXITCODE
$Ages = Join-Path $Root 'age'
New-Item -ItemType Directory -Path $Ages | Out-Null
[IO.File]::WriteAllText((Join-Path $Ages 'old.txt'), 'old')
[IO.File]::WriteAllText((Join-Path $Ages 'recent.txt'), 'recent')
[IO.File]::SetLastWriteTimeUtc((Join-Path $Ages 'old.txt'), [DateTime]::Parse('2000-01-01').ToUniversalTime())
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $Ages -Source "$Tag-age" -MaxAge 1 -AllExtensions -Retries 1
$LASTEXITCODE
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $Ages -Source "$Tag-age-off" -MaxAge 0 -AllExtensions -Retries 1
$LASTEXITCODE
$Sizes = Join-Path $Root 'size'
New-Item -ItemType Directory -Path $Sizes | Out-Null
[IO.File]::WriteAllBytes((Join-Path $Sizes 'limit.bin'), (New-Object byte[] 1048576))
[IO.File]::WriteAllBytes((Join-Path $Sizes 'over.bin'), (New-Object byte[] 1048577))
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $Sizes -Source "$Tag-size" -MaxAge 0 -MaxSize 1 -AllExtensions -Retries 1
$LASTEXITCODE
```

Expected: all exit 0. Extension run uploads only include.exe; age run only recent.txt;
age-off run both; size run only exactly 1 MiB limit.bin. Check rejected samples are
absent from the service, not merely mentioned as skipped locally.

### 4. Unreachable Service and Invalid Configuration

```powershell
& $Collector -ThunderstormServer 127.0.0.1 -ThunderstormPort 1 -Folder $InputDir -Source "$Tag-offline" -MaxAge 0 -AllExtensions -Retries 1
$LASTEXITCODE
& $Collector -ThunderstormServer $Server -ThunderstormPort 0 -Folder $InputDir -DryRun
$LASTEXITCODE
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $InputDir -MaxSize 201 -DryRun
$LASTEXITCODE
```

Expected: invalid configurations exit 2 before network. Offline exits 2 after bounded
begin attempts when markers are supported, or 1 for failed uploads when PS2 markers
are disabled. No successful submissions; time the command. Do not test a broad C:\ scan.

### 5. Missing Roots and a Locked File

```powershell
$Missing = Join-Path $Root 'does-not-exist'
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder @($InputDir,$Missing) -Source "$Tag-missing" -MaxAge 0 -AllExtensions -Retries 1
$LASTEXITCODE
& $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $Missing -DryRun
$LASTEXITCODE
$Errors = Join-Path $Root 'errors'
New-Item -ItemType Directory -Path $Errors | Out-Null
[IO.File]::WriteAllText((Join-Path $Errors 'ok.txt'), 'readable')
[IO.File]::WriteAllText((Join-Path $Errors 'locked.txt'), 'locked')
$Lock = [IO.File]::Open((Join-Path $Errors 'locked.txt'),'Open','ReadWrite','None')
try {
  & $Collector -ThunderstormServer $Server -ThunderstormPort $Port -Folder $Errors -Source "$Tag-lock" -MaxAge 0 -AllExtensions -Retries 1
  $LASTEXITCODE
} finally { $Lock.Close() }
```

Expected: mixed roots exit 1 but all five readable files upload; all missing exit 2
without network. Locked-file run exits 1, only ok.txt uploads, Failed 1. Always release
the lock. Run the lock case on Windows; Unix sharing semantics are not equivalent.

For an ACL-denied directory, use a separate throwaway non-admin account/test directory,
deny only that directory under organizational policy, then restore the exact original
ACL. Readable siblings should upload, scan_errors should increase and exit should be 1.
Do not alter real user folders or consider an administrator/root permission test a pass.

### 6. Junction Scope and Cloud Exclusion

Create a junction using the target's approved tool (mklink /J or New-Item -ItemType
Junction on newer PowerShell), pointing from the fixture input to a separate directory
containing a unique harmless sentinel. Re-run the basic test with a new source.
Expected: original five files only; sentinel absent; no loop/hang. Do NOT use recursive
cleanup on the junction target: remove the junction itself first.

Create Root\Dropbox\local.txt; scan Root\Dropbox explicitly. Expected: zero uploads,
exit 0, because the known cloud root is excluded even when explicitly supplied.
This is name-based protection, not detection of every cloud provider/offline placeholder.

### 7. TLS Negative Tests

Against an authorized HTTPS test endpoint with a valid public certificate, repeat
the basic test with -UseSSL: five uploads, exit 0. For a private test CA, add -CACert
C:\test\approved-root.pem on .NET 4.5+. Repeat with an unrelated CA: nonzero, no uploads.
Use a deliberately wrong hostname on the TEST endpoint only: nonzero, no uploads,
including with the approved CA. Do not change a production DNS entry.

An untrusted test certificate must fail by default. -UseSSL -Insecure is an explicit
test-only exception on a supported CLR; it prints a warning. Do not use it to make
production acceptance pass. Actual old CLR must reject unsupported custom TLS options
with exit 2 rather than disabling verification. Record old TLS endpoints separately.

### 8. Retries, Incomplete Replies and Interruption

Do NOT destabilize the real service. Run the synthetic loopback regression suite from
the repository root (Python 3 is a TEST-HOST dependency, not a collector dependency):

```powershell
$env:POWERSHELL_RUNTIME = (Get-Process -Id $PID).Path
python -B scripts/tests/test_powershell_robustness.py
$env:POWERSHELL_COLLECTOR = (Resolve-Path scripts/powershell/thunderstorm-collector-ps2.ps1).Path
python -B scripts/tests/test_powershell_robustness.py
Remove-Item Env:\POWERSHELL_COLLECTOR
Remove-Item Env:\POWERSHELL_RUNTIME
```

This checks complete/truncated replies, ignored redirects, bounded 503 retries and
recovery, ignored marker failures, bytes, source escaping, filters and missing/locked files.
Read skips: PS5.1/PS7 runs are not PS2 certification.

For Ctrl+C, use a deliberately larger synthetic test tree against an authorized
test service, interrupt once while uploading, and check no later files are sent.
Expect nonzero exit and a best-effort interrupted marker only if supported.
Record terminal/host behavior: killing the process is NOT the same as graceful Ctrl+C.

### Cleanup and Acceptance Record

Delete only this run's unique Root after releasing locks/removing junctions.
Keep commit hash, OS, PowerShell AND CLR version, exact commands, exit codes,
server-side byte/source evidence and each PASS/FAIL/NOT SUPPORTED/NOT TESTED result.
Use the legacy file only after the intended old runtime has been tested.
