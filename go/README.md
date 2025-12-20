# THOR Thunderstorm Collector

Thunderstorm Collector is an open-source tool written in Go that can be used to upload files to THOR Thunderstorm.
A Makefile has been added to allow for simplified creation of executables. The generated executables are statically linked so that no further dependencies on the target systems exist.

## Usage

```help
Usage: amd64-windows-thunderstorm-collector.exe [OPTION]...
      --all-filesystems              Ignore filesystem types. By default, the collector doesn't collect files from network mounts or special filesystems; with this flag, files are collected regardless of the underlying filesystem type.'
      --ca strings                   Path to a PEM CA certificate that signed the HTTPS certificate of the Thunderstorm server.
                                     Specify multiple CAs by using this flag multiple times.
      --debug                        Print debugging information.
      --exclude strings              Paths that should be excluded. Supports globbing with ?, * and **.
                                     Specify multiple excludes by using this flag multiple times.
                                     Example: --exclude C:\tools --exclude C:\Users\**\.git\**
  -e, --extension strings            File extensions that should be collected. If left empty, file extensions are ignored.
                                     Extensions are checked first; if no extension matches and magic headers are specified, magic headers are checked.
                                     Specify multiple extensions by using this flag multiple times.
                                     Example: -e .exe -e .dll
  -h, --help                         Show this help.
      --http-proxy string            Proxy that should be used for the connection to Thunderstorm.
                                     If left empty, the proxy is filled from the HTTP_PROXY and HTTPS_PROXY environment variables.
      --insecure                     Don't verify the Thunderstorm certificate if HTTPS is used.
  -l, --logfile string               Write the log to this file as well as to the console.
      --magic strings                Magic Header (bytes at file start) that should be collected, written as hex bytes. If left empty, magic headers are ignored.
                                     Specify multiple wanted Magic Headers by using this flag multiple times.
                                     Magic headers are checked only if file extensions don't match (or if no extensions are specified). Maximum magic header length is 1024 bytes.
                                     Example: --magic 4d5a --magic cffa
  -a, --max-age string               Max age of collected files. Files with older modification date are ignored.
                                     Unit can be specified using a suffix: s for seconds, m for minutes, h for hour, d for day and defaults to days.
                                     Example: --max-age 10h
  -m, --max-filesize int             Maximum file size up to which files should be uploaded (in MB). (default 100)
      --min-cache-file-size int      Upload files with at least the given size (in MB) only once, skipping them when re-encountering them. Files are identified by their SHA256 hash to detect duplicates. The hash cache is automatically cleared when it exceeds 10,000 entries to prevent unbounded memory growth. (default 100)
  -p, --path strings                 Root paths from where files should be collected.
                                     Specify multiple root paths by using this flag multiple times. (default [C:\])
      --port int                     Port on the Thunderstorm Server to which files should be uploaded. (default 8080)
  -o, --source string                Name for this device in the Thunderstorm log messages. (default "DESKTOP-EEM5B52")
      --ssl                          If true, connect to the Thunderstorm Server using HTTPS instead of HTTP.
  -t, --template string              Process default scan parameters from this YAML file. (default "config.yml")
  -r, --threads int                  How many threads should upload files simultaneously. (default 1)
  -s, --thunderstorm-server string   FQDN or IP of the Thunderstorm Server to which files should be uploaded.
                                     Examples: --thunderstorm-server my.thunderstorm, --thunderstorm-server 127.0.0.1
      --upload-synchronous           Whether files should be uploaded synchronously to Thunderstorm. If yes, the collector takes longer, but displays the results of all scanned files.
      --uploads-per-minute int       Delay uploads to only upload samples with the given frequency of uploads per minute. Zero means no delays.
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

In the example above, the collector is instructed to send all samples to a server with the FQDN `my-thunderstorm.local`, send only files smaller than 10 Megabyte, changed or created within the last 30 days, and only files with the given extensions are collected.

**Note:** When both extensions and magic headers are specified in the config file, extensions are checked first. If an extension matches, the file is included. If no extension matches, magic headers are checked as a fallback.

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

In case that the pre-build collector crashes on your end system, please see the [platform requirements](https://github.com/golang/go/wiki#platform-specific-information) for the different go versions to get the last supported go version for your OS version.

This [page](https://golang.org/doc/install/source#environment) contains all possible `arch` and `os` values for the latest Go version.

The pre-compiled binaries for IBM AIX do not support Power7 systems. On request, we can provide binaries build with `gccgo` instead of `go` that run on Power7 systems.

The pre-compiled binaries for FreeBSD have been built with Go 1.15, which does only support FreeBSD 11, 12 and 13. If you have to use the collector on older FreeBSD version, visit [this page](https://github.com/golang/go/wiki/FreeBSD) to get information on that last supported Go version. E.g. to build a version of the Thunderstorm Collector that runs on old Citrix Netscaler gateways, we had to use Go 1.9.7 for the FreeBSD 8.4 used on these platform. 

Note: We haven't tested all compiled binaries on the respective platforms. Please report issues with the execution.

## Performance Considerations

In a THOR Thunderstorm setup, the system load moves from the end systems to the Thunderstorm server.

In cases in which you don't use the default configuration file provided with the collectors (`config.yml`) and collect all files from an end system, the Thunderstorm server requires a much higher amount of time to process the samples.

E.g. A Thunderstorm server with 40 CPU Cores (40 threads) needs 1 hour and 15 minutes to process all 400,000 files sent from a Windows 10 end system. Sending all files from 200 Windows 10 end systems to a Thunderstorm server with that specs would take 10 days to process all the samples.

As a rule of thumb, when using the hardware recommended in the setup guide, you can calculate with a processing speed of **130 samples per core per minute**.

We highly recommend using the default configuration file named `config.yml` provided with the collectors.

### File Filtering Logic

The collector uses a two-stage filtering approach for optimal performance:

1. **Metadata filtering** (before queuing): Files are checked for size, age, and file type before being added to the upload queue. This prevents unnecessary processing of files that will be excluded.

2. **Content filtering** (after opening): Files are checked for extension and magic header matches. The logic works as follows:
   - If file extensions are specified and the file matches an extension, it's included
   - If extensions don't match (or aren't specified) and magic headers are specified, magic headers are checked
   - If neither extensions nor magic headers match (and at least one is configured), the file is excluded
   - If no extensions or magic headers are specified, all files pass content filtering

### Error Handling and Retry Logic

The collector includes automatic retry logic for failed uploads:

- **Retry attempts**: Up to 3 retry attempts are made for failed uploads
- **Exponential backoff**: Retry delays use exponential backoff starting at 4 seconds (4s, 8s, 16s)
- **Server rate limiting**: If the server returns HTTP 503 (Service Unavailable), the collector respects the `Retry-After` header or defaults to 30 seconds
- **Error reporting**: All upload errors are logged and counted in the final statistics

### Duplicate File Detection

Files larger than the `--min-cache-file-size` threshold are hashed using SHA256 to detect duplicates. If a file with the same content hash was already processed, it's skipped to avoid redundant uploads. The hash cache is automatically managed:

- **Cache limit**: The cache is automatically cleared when it exceeds 10,000 entries
- **Memory efficient**: Only files above the minimum cache size threshold are hashed
- **Thread-safe**: Hash cache operations are thread-safe for concurrent uploads

## Build

### Build requirements

- Go version 1.15 or higher
  - Note: We maintain Go 1.15 compatibility to support older systems (Windows XP, old Linux). The codebase uses `ioutil` functions which work in all Go versions, though they are deprecated in Go 1.16+.
- make

[Here](https://www.digitalocean.com/community/tutorials/how-to-install-go-on-debian-10) is an instruction on how to install Go on Debian. Install make with `sudo apt install make`.

### Build Steps

Simply call the Makefile to build all targets that Golang supports on your build environment:

```bash
make
```

If you want to build executables for other platform / architecture combinations than those built in the default configuration, use:

```bash
make bin/<arch>-<os>-thunderstorm-collector
```

A full list of architectures and platforms that can be used can be shown using:

```bash
go tool dist list
```


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

### Troubleshooting

#### Common Error Messages

- **"thunderstorm-server: not specified"**: The `--thunderstorm-server` parameter is required. Make sure to specify the server address.
- **"threads: count must be > 0"**: The thread count must be at least 1. Use `-r 1` or higher.
- **"max-filesize: must be > 0"**: The maximum file size must be greater than 0 MB.
- **"max-age: invalid suffix"**: The max-age parameter supports suffixes: `s` (seconds), `m` (minutes), `h` (hours), `d` (days). Example: `--max-age 10h`
- **"magic header too long"**: Magic headers are limited to 1024 bytes. Check your magic header configuration.
- **"Could not open CA file"**: The specified CA certificate file cannot be opened. Check the file path and permissions.
- **"Could not add CA to certificate pool"**: The CA certificate file is not in valid PEM format or cannot be parsed.

#### Performance Tips

- Use the default `config.yml` to avoid collecting unnecessary files
- Set appropriate `--max-filesize` to avoid uploading very large files
- Use `--exclude` patterns to skip known directories (e.g., `--exclude "**/node_modules/**"`)
- Adjust `--threads` based on your network bandwidth and server capacity
- Use `--uploads-per-minute` to rate-limit uploads if needed

#### Memory Usage

The collector is designed to be memory-efficient:
- File hash cache is automatically cleared at 10,000 entries
- Files are processed in a streaming fashion (not loaded entirely into memory)
- Metadata checks happen before files are queued, reducing memory pressure

For very large scans, monitor memory usage and adjust `--min-cache-file-size` if needed (higher values = fewer files hashed = less memory).

### Tested On

Successfully tested on:

- Debian 10
- Windows 10
