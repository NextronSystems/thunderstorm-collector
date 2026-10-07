# THOR Thunderstorm Collector Scripts

The Thunderstorm collector script library is a library of script examples that you can use for sample collection purposes.

## VMware ESXi: use the Python collector

For VMware ESXi, use [the Python collector](thunderstorm-collector.py). Nextron has used this collector successfully on ESXi systems. The generic Bash collector is not the recommended starting point for ESXi.

### Requirements and compatibility

- Python **3.6 or later** is required by the current implementation (it uses f-strings). All imported modules are part of the Python standard library; no third-party packages are needed.
- Check that your appliance already provides a suitable Python interpreter. This guidance does not recommend installing an unsupported runtime or changing ESXi security settings.
- Exact tested ESXi firmware versions and collector revisions have not been supplied. Historical success is not a compatibility guarantee for every ESXi release or for later collector changes.

### Download and quick start

Download the Python file from [the published releases](https://github.com/NextronSystems/thunderstorm-collector/releases). Existing releases provide an individual versioned file, for example `thunderstorm-collector-1.0.1.py`; there is currently no released scripts ZIP package. The source linked above reflects this branch, while release files reflect their tagged version.

Use an existing, explicitly selected directory containing only a few synthetic test files. Replace the directory and server placeholders, and adapt the filename to the downloaded release:

```sh
python3 ./thunderstorm-collector-1.0.1.py \
  --server thunderstorm.example.internal --port 8080 \
  --dirs /absolute/path/to/collector-test --source esxi-test
```

This **uploads** matching files; it is not a dry run. `python3` denotes an available compatible interpreter, not a guaranteed ESXi interpreter path. Always pass an absolute directory to `--dirs`; omitting it selects `/`. Explicitly pass `--port`: although the script's help mentions 8080, the current argument definition does not set that default.

The script selects files modified within 14 days and no larger than 20 MiB, skips symlinks, `/proc`, `/dev`, `/sys` and its configured path patterns (including common virtual disk files). These filters are configured in the source; there is no YAML configuration or dry-run option. Supported arguments are `--dirs` (`-d`), `--server` (`-s`, required), `--port` (`-p`), `--tls` (`-t`), `--source` (`-S`), `--debug`, and `--insecure` (`-k`). For HTTPS, add `--tls` and the configured HTTPS port, retaining certificate verification.

The current script has limited error handling: its submitted counter is not a reliable success count, and some HTTP error responses can cause repeated attempts without a fixed limit. Begin with a small controlled test and check server-side results. Improvements under review in separate script PRs are not assumed by these instructions.

## thunderstorm-collector Shell Script

A shell script for Linux.

### Requirements

- bash
- wget

### Usage

You can run it like:

```bash
bash ./thunderstorm-collector.sh
```

The most common use case would be a collector script that looks e.g. for files that have been created or modified within the last X days and runs every X days.

### Tested On

Successfully tested on:

- Debian 10

## thunderstorm-collector Batch Script

A Batch script for Windows.

Warning: The FOR loop used in the Batch script tends to [leak memory](https://stackoverflow.com/questions/6330519/memory-leak-in-batch-for-loop). We couldn't figure out a clever hack to avoid this behaviour and therefore recommend using the Go based Thunderstorm Collector on Windows systems.

### Requirements

- curl (Download [here](https://curl.haxx.se/windows/))

#### Note on Windows 10

Windows 10 already includes a curl since build 17063, so all versions newer than version 1709 (Redstone 3) from October 2017 already meet the requirements

#### Note on very old Windows versions

The last version of curl that works with Windows 7 / Windows 2008 R2 and earlier is v7.46.0 and can be still be downloaded from [here](https://bintray.com/vszakats/generic/download_file?file_path=curl-7.46.0-win32-mingw.7z)

### Usage

You can run it like:

```bash
thunderstorm-collector.bat
```

### Tested On

Successfully tested on:

- Windows 10
- Windows 2003
- Windows XP

## thunderstorm-collector PowerShell Script

A PowerShell script for Windows.

### Requirements

- PowerShell version 3

### Usage

You can run it like:

```bash
powershell.exe -ep bypass .\thunderstorm-collector.ps1
```

Collect files from a certain directory

```bash
powershell.exe -ep bypass .\thunderstorm-collector.ps1 -ThunderstormServer my-thunderstorm.local -Folder C:\ProgramData\Suspicious
```

Collect all files created within the last 24 hours from partition C:\

```bash
powershell.exe -ep bypass .\thunderstorm-collector.ps1 -ThunderstormServer my-thunderstorm.local -MaxAge 1
```

### Configuration

Please review the configuration section in the PowerShell script for more settings.

### Tested On

Successfully tested on:

- Windows 10
- Windows 7

## thunderstorm-collector Perl Script

A Perl script collector.

### Requirements

- Perl version 5
- LWP::UserAgent

### Usage

You can run it like:

```bash
perl thunderstorm-collector.pl -- -s thunderstorm.internal.net
```

Collect files from a certain directory

```bash
perl thunderstorm-collector.pl -- --dir /home --server thunderstorm.internal.net
```

### Configuration

Please review the configuration section in the Perl script for more settings like the maximum age, maximum file size or directory exclusions.

### Tested On

Successfully tested on:

- Debian 10