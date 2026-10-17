# THOR Thunderstorm Collector

This guide covers the compiled Go collector: configuration, filtering, platform compatibility, and builds. Start with the [main README](../README.md) for collector selection, downloads, and a minimal quick start with an optional preview. Published binaries do not require an installed Go runtime, but their OS/kernel and CPU requirements still apply.

For product-specific collection scope, use the [Emerging Threats profiles](../emerging-threats/README.md). Script collectors have their own [configuration and runtime guides](../scripts/README.md).

## Usage

Run your executable with `--help` to see every available option and the effective defaults for the loaded configuration. The [main README contains the complete help output](../README.md#command-line-help). It shows built-in Unix defaults; a loaded YAML configuration can change them, including the file-size limit.

## Configuration Files

The **Go collector** reads YAML. By default it looks for `config.yml` in the current working directory. Use `-t`/`--template` to select a configuration explicitly: a missing explicit file is an error, while an absent implicit `config.yml` falls back to built-in defaults. Those defaults include the filesystem root and no extension or magic-header filter.

At startup the collector logs which configuration file it loaded, with its absolute path, or that it found none and uses the built-in defaults. A summary of the settings that decide what the run collects (scan roots, size and age limits, filters, upload mode and destination) follows. Both appear with `--dry-run` and in the `--logfile`. Because `config.yml` is read from the working directory rather than from the executable's directory, check these lines when the collector starts from cron, a service, or by absolute path.

Command-line values override YAML values. The server can be set once as `thunderstorm-server: HOST` in the existing `config.yml`; from that directory, the executable then needs no flags for a normal collection. With the shipped configuration, only `-s HOST` is needed if the server is not stored in YAML. The first `--path` replaces the configured roots; repeat it to add more roots. YAML uses configuration names such as `path`, `max-filesize`, and `thunderstorm-server`; `--help` and `--template` are command-line controls.

For example, save this preview-first configuration as `my-config.yml`, replacing the input path and server:

```yaml
path:
  - /absolute/path/to/files
thunderstorm-server: thunderstorm.example.internal
max-filesize: 10
max-age: "30"
extension:
  - .ps1
  - .sh
  - .php
  - .log
magic: []
dry-run: true
```

This selects regular files up to and including **10 MiB** with a listed extension and a qualifying timestamp within 30 days. Timestamp selection is platform-dependent; see [file filtering](#file-filtering-logic). Preview the configuration, then explicitly enable uploads after reviewing it:

```sh
./amd64-linux-thunderstorm-collector -t ./my-config.yml --dry-run --debug
./amd64-linux-thunderstorm-collector -t ./my-config.yml --dry-run=false
```

### Default Configuration

Binary packages include [config.yml](config.yml), which selects extensions and magic headers with a **64 MiB** limit and no age cutoff. The built-in size limit without that file is **100 MiB**. Review the configuration for the intended assessment; a profile may deliberately select a broader set of files. The [NetScaler profile](../emerging-threats/citrix-netscaler/README.md) provides one such configuration.

To collect all regular file types, set both `extension: []` and `magic: []`; other limits and exclusions still apply. For no age cutoff, use `max-age: ""`. A value of `"0"` sets a current-time threshold and does not disable the age filter.

## Precompiled Binaries

See [downloads and current release availability](../README.md#download-a-collector) for package selection and contents. This guide describes the current source; use the tagged documentation for a downloaded release.

**Note:** In general, Go 1.10 is used to build the binaries to ensure the broadest possible compatibility with older operating system versions. Additionally, this is complemented by builds with the latest stable Go version for targets that are not supported by Go 1.10.

### Citrix NetScaler and FreeBSD 8.4

For older Citrix NetScaler appliances based on **FreeBSD 8.4**, select the separate **amd64 (64-bit x86)** collector built with **Go 1.9.7** and `CGO_ENABLED=0`. Confirm the appliance's OS and architecture first; regular FreeBSD packages are not interchangeable with this legacy target. Other NetScaler versions need a collector selected using their actual OS, architecture and verified compatibility evidence.

**Release availability:** `thunderstorm-collector-<version>-amd64-freebsd8-netscaler.tar.gz` is included starting with the first tagged release containing the legacy packaging workflow. **v1.0.1 and earlier do not contain this dedicated package.** Check the [selected release's assets](https://github.com/NextronSystems/thunderstorm-collector/releases): if the package is absent, that release does not provide the legacy build. This guidance does not imply that a containing release has already been published.

The package contains the executable, `config.yml`, compatibility notes and `BUILD-INFO.txt`. Verify the checksum and consult its build information for the exact source commit and compiler. The [legacy build guide](legacy/README.md) covers CI artifacts and building from source when a release asset is unavailable. For assessment paths and filters, use the [NetScaler collection profile](../emerging-threats/citrix-netscaler/README.md).

#### Compatibility evidence as of 2026-10-08

| Evidence level | Status for the dedicated legacy build |
| --- | --- |
| Compilation for freebsd/amd64 with Go 1.9.7 | Verified, including static FreeBSD ELF, architecture, executable permissions, package contents and checksums |
| Shared source/runtime on Linux/amd64 with Go 1.9.7 | Automated Go tests and synthetic HTTP checks verified; these do not execute the FreeBSD binary |
| Runtime on FreeBSD 8.4-RELEASE amd64 | Reported successful in a KVM/QEMU VM without a workaround; 253 files uploaded with zero errors |
| Runtime on FreeBSD 14.3-RELEASE amd64 | Reported successful in a KVM/QEMU VM with per-process ASLR disabled; 302 files uploaded with zero errors |
| Runtime on a named NetScaler appliance/firmware | Pending; the VM results do not establish appliance/firmware compatibility |

##### How the FreeBSD binaries were tested

The [external test report on PR #51](https://github.com/NextronSystems/thunderstorm-collector/pull/51#issuecomment-6056935463), supplied on **8 October 2026**, used the same GitHub Actions artifact on both VMs. These are reported VM results, separate from the automated Linux tests. The artifact identity and archive checksum were independently checked against the CI download; the VM runs were performed by the report's author.

| Test environment | Startup | Dry run over `/etc` | Upload to Thunderstorm |
| --- | --- | --- | --- |
| FreeBSD 8.4-RELEASE amd64, r251259 (2013-06-02); KVM/QEMU, qemu64 CPU, RTL8139 NIC, IDE disk | Ran directly, without an ASLR workaround | `--dry-run -p /etc`: 253 files would be sent, zero errors | 253 successful uploads, zero read/transmission errors |
| FreeBSD 14.3-RELEASE amd64; KVM/QEMU, host-passthrough CPU, virtio NIC | Direct start failed with `runtime: address space conflict`; ran with ASLR disabled for the invocation | `--dry-run -p /etc`: 600 files discovered, 302 selected, zero errors | 302 successful uploads, zero errors |

The server was **Thunderstorm v10**, using **THOR 10.7.32 (build 1cabaee)** over **HTTP port 8082**. The report records 555 scanned samples across both runs, no denied requests and no upload errors. These tests cover startup, file collection/filtering and HTTP submission; they do not establish HTTPS/TLS interoperability or compatibility with a particular NetScaler firmware. `/etc` describes the VM test input; for a first appliance test, use a small directory containing synthetic files.

The reported FreeBSD 8.4 installation ISO SHA-256 was `2fb17d77d4eba34736eb98c142c56546dd73a4e7ac38895bb6c8517949282438`.

##### Exact tested artifact

| Field | Value |
| --- | --- |
| CI run / artifact | [Legacy NetScaler run 37743060852](https://github.com/NextronSystems/thunderstorm-collector/actions/runs/37743060852), artifact `netscaler-freebsd8`, ID `11534377782` |
| PR head at the time of the run | `2af4e908e078674a3821b9f106eaee85a576f97b` |
| Built source commit from `BUILD-INFO.txt` | `ed70dd980d4e4132e319f15090a58f927cd85035` (the PR test-merge commit; clean source tree) |
| Compiler / target | Go 1.9.7 on Linux/amd64; `GOOS=freebsd`, `GOARCH=amd64`, `CGO_ENABLED=0` |
| Archive | `thunderstorm-collector-validation-ed70dd980d4e-amd64-freebsd8-netscaler.tar.gz` |
| Archive SHA-256, verified against its sidecar | `018efbc71a7b0ac5f53b5b376f2e155fa64c542ca98a7eb6e683c29cd8186b92` |
| Executable | `amd64-freebsd8-netscaler-thunderstorm-collector`, 5,644,000 bytes; static, stripped FreeBSD ELF64 x86-64 |
| Executable SHA-256, computed from the downloaded artifact | `3cf8abd09c964095f795dc8f680d646c24e91541e01da605d94c5bc803dee3d4` |
| Go Build ID, matching the report | `24b3731e01aa0df55459eb274cafee81a99d5de4` |

These runtime results apply to the identified artifact. Later builds are not automatically VM-tested. The `pending` runtime fields in its `BUILD-INFO.txt` reflect the CI build-time checks, which preceded these external tests; this section records the subsequent VM evidence.

##### ASLR when testing on modern FreeBSD

For the FreeBSD 14.3 VM, the per-invocation workaround can be applied to a help check as follows:

```sh
proccontrol -m aslr -s disable ./amd64-freebsd8-netscaler-thunderstorm-collector --help
```

The failure and workaround are consistent with an ASLR-sensitive legacy runtime. The [FreeBSD 13.2 release notes](https://www.freebsd.org/releases/13.2R/relnotes/#kernel) document default ASLR for 64-bit executables and this per-invocation control. The FreeBSD 8.4 VM ran without this workaround. It is not a required NetScaler configuration change.

The repository also records historical Go 1.9.7 use on FreeBSD 8.4 NetScaler gateways, without their firmware, architecture or collector revision. The [official Go FreeBSD table](https://go.dev/wiki/FreeBSD) supports the amd64 toolchain choice. No 386 legacy package is promised without a verified target need. Add future OS/appliance results and their artifact identities here so compatibility evidence has one reference location.

**Go 1.9.7 is unsupported** under the [Go release policy](https://go.dev/doc/devel/release#policy). Its shipped runtime and standard library, including HTTP/TLS code, lack later security fixes. An isolated build job does not remove these limitations. Retain certificate verification and server security settings; if secure interoperability fails, use a supported collector/platform rather than weakening them.

### Unsupported Versions

The Go Collector does not run on:

- Windows 2000
- Windows NT

For an alternative, consult the [script selection and runtime requirements](../scripts/README.md#choosing-a-collector). Each script requires its own supported interpreter and utilities.

In case that the pre-build collector crashes on your end system, please see the [platform requirements](https://go.dev/wiki/#platform-specific-information) for the different go versions to get the last supported go version for your OS version.

This [page](https://golang.org/doc/install/source#environment) contains all possible `arch` and `os` values for the latest Go version.

Use `go version <binary>` when the executable contains build information recognized by your Go toolchain. For older binaries, consult the matching release/build record. The dedicated NetScaler package records its compiler and source commit in `BUILD-INFO.txt`.

The pre-compiled binaries for IBM AIX do not support Power7 systems. On request, we can provide binaries build with `gccgo` instead of `go` that run on Power7 systems.

Regular FreeBSD packages follow the normal Go 1.10/stable build process. For FreeBSD 8.4 NetScaler gateways, see the [separate legacy package guidance](#citrix-netscaler-and-freebsd-84) above.

Note: We haven't tested all compiled binaries on the respective platforms. Please report issues with the execution.

## Performance Considerations

Analysis runs on the Thunderstorm server. Collection scope, file sizes, signatures, and server capacity determine processing time. The packaged filters are a general starting point; use the assessment profile when its broader scope is required.

Start with a small collection and inspect server load and results before increasing scope or concurrency. Adjust `--threads` and `--uploads-per-minute` to control upload pressure. Asynchronous acceptance means the server accepted a file; check analysis completion separately.

### Filesystem Types

Unless `--all-filesystems` is set, the collector does not walk directories on pseudo or network filesystems. Linux recognises them by the statfs magic number and macOS by the filesystem type name (`devfs`, `fdesc`, `volfs`, `autofs`, `nfs`, `smbfs`, `afpfs`, `webdav`, `ftp`). Other platforms, including Windows and FreeBSD, do not detect filesystem types; use `--exclude` for such paths.

### File Filtering Logic

The collector uses a two-stage filtering approach for optimal performance:

1. **Metadata filtering** (before queuing): Files are checked for size, age, and file type before being added to the upload queue. This prevents unnecessary processing of files that will be excluded.

2. **Content filtering** (after opening): Files are checked for extension and magic header matches. The logic works as follows:
   - If file extensions are specified and the file matches an extension, it's included
   - If extensions don't match (or aren't specified) and magic headers are specified, magic headers are checked
   - If neither extensions nor magic headers match (and at least one is configured), the file is excluded
   - If no extensions or magic headers are specified, all files pass content filtering

File-size limits are in MiB (1024 × 1024 bytes), with the exact boundary included. The age check accepts a file if any timestamp provided by the platform is newer than the cutoff: modification and metadata-change times on many Unix targets, plus birth time on supported BSD/macOS targets; Windows uses modification and creation times. This differs from the script collectors' modification-time-only rules.

### Error Handling and Retry Logic

Transport errors and HTTP 503 share a budget of **three retries after the initial attempt**. Transport failures use exponential delays of 4, 8, and 16 seconds; HTTP 503 uses an integer `Retry-After` value, or 30 seconds when it is missing or invalid. Other HTTP errors and response-body read failures are logged and counted without a retry. A lost response can still cause a duplicate submission.

## Build

### Build requirements

Use Go, `make`, and a Unix-like shell with standard command-line utilities. Creating release archives also requires `tar`, `gzip`, and `zip`. Running downloaded collectors requires no Go compiler or `make`; scripts still need the runtimes and tools listed in their guides. Regular builds retain Go 1.10 compatibility where that compiler supports the target; newer targets require a newer compiler. The separate [NetScaler procedure](legacy/README.md) prepares its Go 1.9.7 build.

Dependencies are declared in `go.mod` and `go.sum`. For a Go 1.10 build, first run `go mod vendor` from this directory with a modern Go toolchain, then select Go 1.10 for the build. The generated `vendor/` directory is not committed. The [CI setup action](../.github/actions/setup-go/action.yml) follows that preparation sequence; the Makefile provides the GOPATH symlink needed by the legacy compiler.

### Build Steps

From this `go/` directory, choose the target you need. These commands are alternatives, not a sequence:

```sh
make              # Build for the current OS/architecture
make all          # Build the Makefile's supported cross-compilation targets
make linux/amd64   # Build one target
make release      # Create regular distribution archives in dist/
make help         # List build targets
```

`go tool dist list` shows the compiler's OS/architecture combinations; the Makefile excludes targets it does not package. Repository-wide script packaging and the tagged release workflow are described in the [main build guide](../README.md#build-or-extend-a-collector).

## Usage Examples

Start with the [main quick start](../README.md#quick-start). These additional Linux amd64 examples load `config.yml` explicitly and restrict collection to one directory. Substitute your executable, directory, and server. Preview the chosen options with `--dry-run --debug` before enabling uploads; the configuration's extension/magic filters still apply.

Allow files up to 500 MiB and use ten upload workers:

```sh
./amd64-linux-thunderstorm-collector -t ./config.yml -p /absolute/path/to/files \
  -s thunderstorm.example.internal --dry-run=false -r 10 -m 500
```

Apply a ten-day age cutoff and use HTTPS:

```sh
./amd64-linux-thunderstorm-collector -t ./config.yml -p /absolute/path/to/files \
  -s thunderstorm.example.internal --dry-run=false --ssl --port 443 -a 10
```

Upload through an HTTP proxy:

```sh
./amd64-linux-thunderstorm-collector -t ./config.yml -p /absolute/path/to/files \
  -s thunderstorm.example.internal --dry-run=false \
  --http-proxy http://proxy.example.internal:3128
```

Wait for synchronous responses and write them to a log outside the collection directory:

```sh
./amd64-linux-thunderstorm-collector -t ./config.yml -p /absolute/path/to/files \
  -s thunderstorm.example.internal --dry-run=false \
  --upload-synchronous --logfile ./collector.log
```

## Collection Statistics

At the end of each collection run, the collector displays comprehensive statistics.

**Example output:**

```
=== Collection Statistics ===

Files discovered during walk: 1234

Exclusions:
  - Too big (exceeds max-filesize): 45
  - Wrong type (no matching extension/magic): 234
  - Too old (exceeds max-age): 12
  - Irregular file type: 3
  - Excluded by glob pattern: 78
  - Skipped directories: 23

Processing:
  - Successfully uploaded: 763
  - Read/transmission errors: 2

Timing:
  - File system walk: 2.5s
  - File metadata analysis: 1.2s
  - File read and transmission: 45.3s
  - Total time: 49.3s
```

**Statistics include:**
- Total files discovered during filesystem walk
- Detailed breakdown of exclusions by reason (size, type, age, etc.)
- Processing results (successful uploads, errors)
- Timing breakdown for different phases (walk, read, transmit)

**Debug Mode:**
When `--debug` is enabled, the collector prints detailed information for every file:
- Files that would be sent (with DRY-RUN indicator in dry-run mode)
- Files that are skipped with specific reasons (too big, wrong type, too old, etc.)

This makes it easy to understand why files are included or excluded from collection.

## Dry-Run Mode

`--dry-run` discovers, opens, and filters files without a server connection or HTTP requests. Add `--debug` to list eligible filenames and skip reasons; statistics report files that would be sent. This checks selection, not connectivity or server-side analysis.

```sh
./amd64-linux-thunderstorm-collector -t ./config.yml \
  -p /absolute/path/to/files --dry-run --debug
```

After reviewing the preview, use the same configuration and roots for upload. `--dry-run=false` explicitly overrides a configuration with preview mode enabled.

## Troubleshooting

### Common Error Messages

- **"thunderstorm-server: not specified"**: The `--thunderstorm-server` parameter is required (unless using `--dry-run`). Make sure to specify the server address or use `--dry-run` for testing.
- **Thread count options**: Use `-r 4` for a specific number of threads, `-r 0` for all available CPU cores, or negative values to reserve cores (e.g., `-r -2` uses all cores except 2). The minimum is always 1 thread.
- **"max-filesize: must be > 0"**: The maximum file size must be greater than 0 MB.
- **"max-age: invalid suffix"**: The max-age parameter supports suffixes: `s` (seconds), `m` (minutes), `h` (hours), `d` (days). Example: `--max-age 10h`
- **"magic header too long"**: Magic headers are limited to 1024 bytes. Check your magic header configuration.
- **"Could not open CA file"**: The specified CA certificate file cannot be opened. Check the file path and permissions.
- **"Could not add CA to certificate pool"**: The CA certificate file is not in valid PEM format or cannot be parsed.

### Performance Tips

- Choose the packaged configuration or an assessment profile appropriate to the collection scope
- Set appropriate `--max-filesize` to avoid uploading very large files
- Use `--exclude` patterns to skip known directories (e.g., `--exclude "**/node_modules/**"`)
- Adjust `--threads` based on your network bandwidth and server capacity
- Use `--uploads-per-minute` to rate-limit uploads if needed

### Memory Usage

The collector is designed to be memory-efficient:
- Files are processed in a streaming fashion (not loaded entirely into memory)
- Metadata checks happen before files are queued, reducing memory pressure

## Tested On

Historical successful runs were recorded on Debian 10 and Windows 10 without exact revisions or runtime details. For scoped evidence, see the [NetScaler/FreeBSD record](#compatibility-evidence-as-of-2026-10-08) and the [testing overview](../docs/COLLECTOR_TESTING_OVERVIEW.md).
