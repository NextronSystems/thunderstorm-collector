# THOR Thunderstorm Collector Scripts

The Thunderstorm collector script library is a library of script examples that you can use for sample collection purposes.

## thunderstorm-collector Shell Script

A shell script for Linux.

### Requirements

- bash
- curl **or** wget

### Usage

You can run it like:

```bash
bash ./thunderstorm-collector.sh
```

Show available options:

```bash
bash ./thunderstorm-collector.sh --help
```

Example dry-run for a custom folder with spaces in the path:

```bash
bash ./thunderstorm-collector.sh --server thunderstorm.local --dir "/tmp/Suspicious Files" --dry-run
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
