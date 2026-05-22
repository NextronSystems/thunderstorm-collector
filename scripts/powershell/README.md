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

## Automated Stub Test

Windows CI validates PowerShell collectors through `.github/workflows/script-collectors.yml`.

For local PowerShell Core based validation on Unix-like hosts:

```bash
THUNDERSTORM_TEST_COLLECTORS=ps3 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

