# Windows Batch Collector

`thunderstorm-collector.bat` is a last-resort Windows collector for systems where PowerShell is not available or cannot be executed.

## Intended Use

Use this collector only on legacy Windows systems or highly restricted environments where neither the Go collector nor PowerShell collectors can be used.

## Requirements

| Requirement | Detail |
|---|---|
| Runtime | `cmd.exe` |
| Upload tool | `curl.exe` |
| OS | Legacy Windows systems without usable PowerShell |

## Capabilities

- Directory scanning through Windows Batch.
- File extension filtering through environment variables.
- File size and age controls through environment variables.
- Upload through `curl.exe`.

## Limitations

- Least capable script collector.
- Batch has weak error handling and quoting semantics compared with PowerShell.
- Pure Batch cannot reliably implement all metadata and JSON behavior available in PowerShell.
- Large directory walks can be slow and fragile.
- Prefer PowerShell or the Go collector whenever possible.

## Basic Usage

Configure through environment variables and run the batch file:

```cmd
set THUNDERSTORM_SERVER=thunderstorm.local
set THUNDERSTORM_PORT=8080
set URL_SCHEME=http
set COLLECT_DIRS=C:\Temp
set RELEVANT_EXTENSIONS=.exe;.dll;.ps1;.bat;.txt
set COLLECT_MAX_SIZE=50000000
set MAX_AGE=14
set SOURCE=manual-batch
scripts\batch\thunderstorm-collector.bat
```

## Manual Acceptance Test

```cmd
set TESTDIR=%TEMP%\ts-batch-acceptance
rmdir /s /q "%TESTDIR%" 2>nul
mkdir "%TESTDIR%"
echo batch acceptance text > "%TESTDIR%\sample.txt"

set THUNDERSTORM_SERVER=thunderstorm.local
set THUNDERSTORM_PORT=8080
set URL_SCHEME=http
set COLLECT_DIRS=%TESTDIR%
set RELEVANT_EXTENSIONS=.txt
set COLLECT_MAX_SIZE=50000000
set MAX_AGE=30
set SOURCE=manual-batch-acceptance
scripts\batch\thunderstorm-collector.bat
```

Acceptance criteria:

- The command exits successfully.
- Thunderstorm records the uploaded test file.
- The source field, if supported by the active Batch collector version, identifies the run as `manual-batch-acceptance`.

## Automated Stub Test

The Batch collector is validated by the Windows job in `.github/workflows/script-collectors.yml`.

