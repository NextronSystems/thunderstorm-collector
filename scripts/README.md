# THOR Thunderstorm Helper Scripts

This folder contains scripts that help you with the installation and sample collection for THOR Thunderstorm.

## Thunderstorm Installer

The Thunderstorm installer scripts facilitate the installation of THOR Thunderstorm as service.

All you need is a valid "service" license.

All installer scripts include an "uninstall" function that completely removes all components after a testing phase. 

### thunderstorm-installer Shell Script

A shell script for Linux.

#### Requirements

- bash
- wget

#### Installation

The steps to install THOR Thunderstorm as a service are:

1. Save a "service" license to the current working directory
2. Switch you context to root `sudo -s`
3. Run `wget -O - https://raw.githubusercontent.com/NextronSystems/nextron-helper-scripts/master/thunderstorm/thunderstorm-installer.sh | bash`

#### Tested On

Successfully tested on:

- Debian 10

## Thunderstorm Collector Scripts

The Thunderstorm collector script library is a library of script examples that you can use for sample collection purposes.

### thunderstorm-collector Shell Script

A shell script for Linux.

#### Requirements

- bash
- wget

#### Usage

You can run it like:

```bash
bash ./thunderstorm-collector.sh
```

The most common use case would be a collector script that looks e.g. for files that have been created or modified within the last X days and runs every X days.

#### Tested On

Successfully tested on:

- Debian 10

### thunderstorm-collector Batch Script

A Batch script for Windows.

#### Requirements

- curl (Download [here](https://curl.haxx.se/windows/))

##### Note on Windows 10
Windows 10 already includes a curl since build 17063, so all versions newer than version 1709 (Redstone 3) from October 2017 already meet the requirements

##### Note on very old Windows versions

The last version of curl that works with Windows 7 / Windows 2008 R2 and earlier is v7.46.0 and can be still be downloaded from [here](https://bintray.com/vszakats/generic/download_file?file_path=curl-7.46.0-win32-mingw.7z)

#### Usage

You can run it like:

```bash
thunderstorm-collector.bat
```

#### Tested On

Successfully tested on:

- Windows 10
- Windows 2003
- Windows XP
