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

You can find precompiled binaries for numerous platforms in the [releases](https://github.com/NextronSystems/thunderstorm-collector/releases) section.

### Unsupported Versions

The Go Collector does not run on:

- Windows 2000
- Windows NT

You could try to use the [collector scripts](https://github.com/NextronSystems/thunderstorm-collector/tree/master/scripts) on unsupported systems.

The pre-compiled binaries for IBM AIX do not support Power7 systems. On request, we can provide binaries build with `gccgo` instead of `go` that run on Power7 systems.

The pre-compiled binarries for FreeBSD have been built with Go 1.15, which does only support FreeBSD 11, 12 and 13. If you have to use the collector on older FreeBSD version, visit [this page](https://github.com/golang/go/wiki/FreeBSD) to get information on that last supported Go version. E.g. to build a version of the Thunderstorm Collector that runs on old Citrix Netscaler gateways, we had to use Go 1.9.7 for the FreeBSD 8.4 used on these platform. 

Note: We haven't tested all compiled binaries on the respective platforms. Please report issues with the execution.

## Performance Considerations

In a THOR Thunderstorm setup, the system load moves from the end systems to the Thunderstorm server.

In cases in which you don’t use the default configuration file provided with the collectors (`config.yml`) and collect all files from an end system, the Thunderstorm server requires a much higher amount of time to process the samples.

E.g. A Thunderstorm server with 40 CPU Cores (40 threads) needs 1 hour and 15 minutes to process all 400,000 files sent from a Windows 10 end system. Sending all files from 200 Windows 10 end systems to a Thunderstorm server with that specs would take 10 days to process all the samples.

As a rule of thumb, when using the hardware recommended in the setup guide, you can calculate with a processing speed of **130 samples per core per minute**.

We highly recommend using the default configuration file named `config.yml` provided with the collectors.

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
