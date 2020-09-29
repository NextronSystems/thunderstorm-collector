# THOR Thunderstorm Collector

Thunderstorm Collector is an open-source tool written in Go that can be used to upload files to THOR Thunderstorm.
A Makefile has been added to allow for simplified creation of executables. The generated executables are statically linked so that no further dependencies on the target systems exist.

## Usage

```help
Usage: amd64-windows-thunderstorm-collector.exe [OPTION]...
      --ca strings                   Path to a PEM CA certificate that signed the HTTPS certificate of the Thunderstorm server.
                                     Specify multiple CAs by using this flag multiple times.
      --debug                        Print debugging information.
  -e, --extension strings            File extensions that should be collected. If left empty, file extensions are ignored.
                                     Specify multiple extensions by using this flag multiple times.
                                     Example: -e .exe -e .dll
  -h, --help                         Show this help.
      --http-proxy string            Proxy that should be used for the connection to Thunderstorm.
                                     If left empty, the proxy is filled from the HTTP_PROXY and HTTPS_PROXY environment variables.
      --insecure                     Don't verify the Thunderstorm certificate if HTTPS is used.
  -l, --logfile string               Write the log to this file as well as to the console.
      --magic strings                Magic Header (bytes at file start) that should be collected, written as hex bytes. If left empty, magic headers are ignored.
                                     Specify multiple wanted Magic Headers by using this flag multiple times.
                                     Example: --magic 4d5a --magic cffa
  -a, --max-age string               Max age of collected files. Files with older modification date are ignored.
                                     Unit can be specified using a suffix: s for seconds, m for minutes, h for hour, d for day and defaults to days.
                                     Example: --max-age 10h
  -m, --max-filesize int             Maximum file size up to which files should be uploaded (in MB). (default 100)
  -p, --path strings                 Root paths from where files should be collected.
                                     Specify multiple root paths by using this flag multiple times. (default [C:])
      --port int                     Port on the Thunderstorm Server to which files should be uploaded. (default 8080)
  -o, --source string                Name for this device in the Thunderstorm log messages. (default "maxdebian")
      --ssl                          If true, connect to the Thunderstorm Server using HTTPS instead of HTTP.
  -t, --template string              Process default scan parameters from this YAML file.
  -r, --threads int                  How many threads should upload files simultaneously. (default 1)
  -s, --thunderstorm-server string   FQDN or IP of the Thunderstorm Server to which files should be uploaded.
                                     Examples: --thunderstorm-server my.thunderstorm, --thunderstorm-server 127.0.0.1
      --upload-synchronous           Whether files should be uploaded synchronously to Thunderstorm. If yes, the collector takes longer, but displays the results of all scanned files.
```

## Config Files

The collectors use config files in YAML format, which can be set using the `-t`/`--template` parameter.

You can use all command line parameters, but you have to use their long form. A typical custom config file `my-config.yml` could look like this:

```yaml
thunderstorm-server: my-thunderstorm.local
max-filesize: 10
max-age: 30
extension:
    - .vbs
    - .ps
    - .ps1
    - .rar
    - .tmp
    - .bat
    - .chm
    - .dll
    - .exe
    - .hta
    - .js
    - .lnk
    - .sct
    - .war
    - .jsp
    - .jspx
    - .php
    - .asp
    - .aspx
    - .log
    - .dmp
    - .txt
    - .jar
    - .job
```

In the example above, the collector is instructed to send all samples to a server with the FQDN `my-thunderstorm.local`, send only files smaller 10 Megabyte, changed or created within the last 30 days and only files with the given extensions are collected.

You can then use the config file as a parameter:

```bash
./amd64-linux-thunderstorm-collector -t config.yml
```

### Default Configuration

The default configuration file named `config.yml` is used by default. We provide a reasonable default configuration file that doesn't select ALL files from a source system but only the ones with certain extensions and magic headers. We recommend using this file in use cases in which you consider collecting files from numerous endsystems.

## Precompiled Binaries

You can find precompiled binaries for numerous platforms in the [releases](/releases) section.

## Build

### Build requirements

- Go version 1.12 or higher
- make

[Here](https://www.digitalocean.com/community/tutorials/how-to-install-go-on-debian-10) is an instruction on how to install Go on Debian. Install make with `sudo apt install make`.

### Build Steps

Install golang package dependencies:

```bash
go get -d github.com/spf13/pflag
go get -d gopkg.in/yaml.v3
```

Build executables:

```bash
make
```

If you want to build executables for other platform / architecture combinations than those built in the default configuration, use:

```bash
make bin/<arch>-<os>-thunderstorm-collector
```

A full list of architectures and platforms that can be used is listed at the start of the Makefile. Note that not all combinations are supported.

### Execution examples

Note: The following examples use the amd64-linux-thunderstorm-collector, replace
the name of the executable with the one you are using.

Upload all files that are smaller than 500 MB to thunderstorm.test using HTTP, with 10 Threads in parallel:

```
./amd64-linux-thunderstorm-collector -s thunderstorm.test -r 10 -m 500
```

Upload all files that are smaller than 500 MB and changed in the last 10 days to thunderstorm.test using HTTPS:
```
./amd64-linux-thunderstorm-collector -s thunderstorm.test --ssl -a 10 -m 500
```

Upload all files from a specific directory:
```
./amd64-linux-thunderstorm-collector -s thunderstorm.test -p /path/to/directory
```

Upload using a proxy:
```
./amd64-linux-thunderstorm-collector -s thunderstorm.test --http-proxy http://username@password:proxy.test/
```

Upload synchronously and write the results to a log file:
```
./amd64-linux-thunderstorm-collector -s thunderstorm.test -l collector.log --upload-synchronous
```

### Tested On

Successfully tested on:

- Debian 10
- Windows 10
