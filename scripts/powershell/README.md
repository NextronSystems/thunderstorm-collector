# PowerShell Collectors

The PowerShell collectors are the preferred script collectors for Windows systems. Use the PowerShell 3+ collector on supported systems. Use the PowerShell 2 collector only for legacy hosts that cannot run newer PowerShell.

## Intended Use

Use `thunderstorm-collector.ps1` on Windows systems with PowerShell 3 or newer. Use `thunderstorm-collector-ps2.ps1` on legacy systems where only PowerShell 2 is available.

## Requirements

| Collector | Runtime | Intended target |
|---|---|---|
| `thunderstorm-collector.ps1` | PowerShell 3+ | Windows 7 / Server 2008 R2 and newer when PowerShell 3+ is installed |
| `thunderstorm-collector-ps2.ps1` | PowerShell 2 | Legacy Windows hosts with only PowerShell 2 |

## Capabilities

- Recursive directory scanning.
- File age and file size filtering.
- Extension filtering.
- Optional all-extension mode.
- HTTP and HTTPS uploads.
- Configurable source identifier.
- Collection markers.

## Limitations

- PowerShell execution policy can block script execution unless bypassed by the operator.
- PowerShell 2 has older .NET and TLS behavior; modern TLS endpoints may require OS-level updates.
- Use the Batch collector only when PowerShell is not available or cannot be executed.

## Basic Usage

PowerShell 3+:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\powershell\thunderstorm-collector.ps1 `
  -ThunderstormServer thunderstorm.local `
  -ThunderstormPort 8080 `
  -Folder C:\Temp `
  -MaxAge 14
```

PowerShell 2:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\powershell\thunderstorm-collector-ps2.ps1 `
  -ThunderstormServer thunderstorm.local `
  -ThunderstormPort 8080 `
  -Folder C:\Temp `
  -MaxAge 14
```

## Manual Acceptance Test

```powershell
$dir = "$env:TEMP\ts-powershell-acceptance"
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dir | Out-Null
Set-Content -Path "$dir\sample.txt" -Value "powershell acceptance text"
[IO.File]::WriteAllBytes("$dir\sample.bin", [byte[]](0,1,2,84,72,85,78,68,69,82))

powershell.exe -ExecutionPolicy Bypass -File .\scripts\powershell\thunderstorm-collector.ps1 `
  -ThunderstormServer thunderstorm.local `
  -ThunderstormPort 8080 `
  -Folder $dir `
  -Source manual-powershell-acceptance `
  -MaxAge 30 `
  -AllExtensions
```

Acceptance criteria:

- The command exits successfully.
- Thunderstorm records uploads for the test files.
- The source field is `manual-powershell-acceptance`.
- Text and binary files are uploaded.

Repeat the same test with `thunderstorm-collector-ps2.ps1` when validating the PowerShell 2 collector.

## Manual Robustness Tests

Run these from an elevated shell only if the test setup requires changing ACLs. The normal happy-path test should not require elevation.

### Thunderstorm service unreachable

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\powershell\thunderstorm-collector.ps1 `
  -ThunderstormServer 127.0.0.1 `
  -ThunderstormPort 1 `
  -Folder $env:TEMP `
  -Source manual-powershell-unreachable `
  -MaxAge 1 `
  -AllExtensions
```

Expected result:

- The command exits non-zero or reports failed submissions.
- The collector prints a clear connection or upload failure.
- The command does not hang indefinitely.

### Missing folder

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\powershell\thunderstorm-collector.ps1 `
  -ThunderstormServer thunderstorm.local `
  -ThunderstormPort 8080 `
  -Folder "$env:TEMP\ts-powershell-does-not-exist" `
  -Source manual-powershell-missing-folder `
  -MaxAge 30 `
  -AllExtensions
```

Expected result:

- The collector does not crash with an unhandled exception.
- The output clearly indicates that the folder is missing or no files were processed.

### Locked or unreadable file

Create one readable file and one file locked by another PowerShell process:

```powershell
$dir = "$env:TEMP\ts-powershell-errors"
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dir | Out-Null
Set-Content -Path "$dir\ok.txt" -Value "readable"
Set-Content -Path "$dir\locked.txt" -Value "locked"

$lock = [System.IO.File]::Open("$dir\locked.txt", 'Open', 'ReadWrite', 'None')
try {
  powershell.exe -ExecutionPolicy Bypass -File .\scripts\powershell\thunderstorm-collector.ps1 `
    -ThunderstormServer thunderstorm.local `
    -ThunderstormPort 8080 `
    -Folder $dir `
    -Source manual-powershell-locked-file `
    -MaxAge 30 `
    -AllExtensions
} finally {
  $lock.Close()
}
```

Expected result:

- The collector does not crash on the locked file.
- `ok.txt` is still submitted.
- The locked file is skipped or counted as failed with a readable warning.

### Extension filter

```powershell
$dir = "$env:TEMP\ts-powershell-filter"
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dir | Out-Null
Set-Content -Path "$dir\include.exe" -Value "include"
Set-Content -Path "$dir\skip.tmp" -Value "skip"

powershell.exe -ExecutionPolicy Bypass -File .\scripts\powershell\thunderstorm-collector.ps1 `
  -ThunderstormServer thunderstorm.local `
  -ThunderstormPort 8080 `
  -Folder $dir `
  -Source manual-powershell-extension-filter `
  -MaxAge 30 `
  -Extensions ".exe"
```

Expected result:

- `include.exe` is submitted.
- `skip.tmp` is not submitted.

Repeat relevant tests with `thunderstorm-collector-ps2.ps1` when validating PowerShell 2 behavior.

## Automated Stub Test

Windows CI validates PowerShell collectors through `.github/workflows/script-collectors.yml`.

For local PowerShell Core based validation on Unix-like hosts:

```bash
THUNDERSTORM_TEST_COLLECTORS=ps3 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```
