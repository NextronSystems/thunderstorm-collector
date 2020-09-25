# THOR Thunderstorm Collector Executable

The Thunderstorm collector executable is an open-source tool written in Go to upload files to THOR Thunderstorm.
A Makefile has been added to allow for simplified creation of executables. The generated executables are statically linked, and no further dependencies on
the target systems exist.

## Usage

```help
Usage: amd64-windows-thunderstorm-collector.exe [OPTION]...
      --ca strings                   Path to a PEM CA certificate that signed the HTTPS certificate of the Thunderstorm server.
  -e, --extensions strings           File extensions that should be collected. If left empty, all files are collected.
  -h, --help                         Show this help.
      --http-proxy string            Proxy that should be used for the connection to Thunderstorm.
                                     If left empty, the proxy is filled from the HTTP_PROXY and HTTPS_PROXY environment variables.
      --insecure                     Don't verify the Thunderstorm certificate if HTTPS is used.
  -l, --logfile string               Write the log to this file.
  -a, --max-age int                  Max age of collected files; older files are ignored.
  -m, --max-filesize int             Maximum file size up to which files should be uploaded (in MB). (default 100)
  -p, --path strings                 Root paths from where files should be collected. (default [C:])
  -t, --template string              Process default scan parameters from this YAML file.
  -r, --threads int                  How many threads should upload information simultaneously. (default 1)
  -s, --thunderstorm-server string   Thunderstorm URL to which files should be uploaded.
      --upload-synchronous           Whether files should be uploaded synchronously to Thunderstorm.
```

## Config Files

The collectors use config files in YAML format, which can be set using the `-t`/`--template` parameter.

You can use all command line parameters, but you have to use their long form. A typical config file `config.yml` could look like this:

```yaml
thunderstorm-server: my-thunderstorm.local
max-filesize: 10
max-age: 30
extensions:
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

## Precompiled Binaries

You can find precompiled binaries for numerous platforms in the [releases](/releases) section.

## Build

### Build requirements

- Go version 1.12 or higher
- make

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
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 -r 10 -m 500
```

Upload all files that are smaller than 500 MB and changed in the last 10 days to thunderstorm.test using HTTPS:
```
./amd64-linux-thunderstorm-collector -s https://thunderstorm.test:8080 -a 10 -m 500
```

Upload all files from a specific directory:
```
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 -p /path/to/directory
```

Upload using a proxy:
```
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 --http-proxy http://username@password:proxy.test/
```

Upload synchronously and write the results to a log file:
```
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 -l collector.log --upload-synchronous
```

### Tested On

Successfully tested on:

- Debian 10
- Windows 10
