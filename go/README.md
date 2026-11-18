# Go Collector

The Go collector is a compiled binary that selects local files and uploads
them to a THOR Thunderstorm service for analysis. Use it wherever a package for
the system's OS and CPU exists.

- Other collectors: [collector selection](../README.md#choose-a-collector) and [script collectors](../scripts/README.md)
- Product-specific scope: [Emerging Threats profiles](../emerging-threats/README.md)
- Nothing can run on the system: SSHFS scanning (see [scanning approaches](../docs/SCANNING_APPROACHES.md)) or the prototype [SFTP collector](../sftp/README.md), which selects files over SSH/SFTP and uploads only those

> [!NOTE]
> This guide describes the current source; for a release, use the guide from
> its tag. Not every binary has been tested on its platform; see the
> [testing overview](../docs/COLLECTOR_TESTING_OVERVIEW.md) and report problems.

## Requirements

| Requirement | Detail |
| --- | --- |
| Runtime | None; no Go installation needed |
| Package | Must match the system's OS and CPU; see [downloads](../README.md#download-a-collector) |
| Compiler | **Go 1.10** for broad OS compatibility; latest stable Go for targets Go 1.10 cannot build |
| Permissions | Only files readable by the current user can be uploaded |
| Service | Thunderstorm over HTTP or HTTPS |

Special cases: [NetScaler / FreeBSD 8.4](#citrix-netscaler-and-freebsd-84), [Windows 2000 and NT](#unsupported-versions), [AIX on POWER7](#aix-on-power7). Historical runs succeeded on Debian 10 and Windows 10 (revisions not recorded).

## Quick Start

Extract the [package](../README.md#quick-start) and change into its directory. Preview the selection:

```sh
./amd64-linux-thunderstorm-collector -p /absolute/path/to/files --dry-run --debug
```

The preview contacts no server. If the list looks right, upload:

```sh
./amd64-linux-thunderstorm-collector -p /absolute/path/to/files -s thunderstorm.example.internal
```

The collector loads `config.yml` from the **current directory**. Without `-p`, it collects from `/` (or `C:\` on Windows).

## Configuration Files

Settings come from YAML; command-line values override them.

- **Which file:** `config.yml` in the **current working directory**, not the executable's directory, or the file given with `-t`/`--template`.
- **Missing file:** a missing `-t` file is an error. Without `config.yml`, built-in defaults apply: filesystem root, **100 MiB**, no extension or magic filter.
- **Startup log:** shows the loaded file's absolute path (or that built-in defaults apply), then roots, limits, filters, upload mode and destination, also with `--dry-run` and in `--logfile`. Check it when running from cron or a service.
- **Keys:** the long option names, such as `path`, `max-filesize`, `thunderstorm-server`. `--help` and `--template` are command-line only.
- **Server:** add `thunderstorm-server: HOST` to the existing `config.yml`; from that directory, no flags are needed.
- **Roots:** the first `--path` replaces the configured roots; repeat it to add more.

A preview-first `my-config.yml`:

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

It selects regular files up to **10 MiB** with a listed extension and a [timestamp](#file-filtering-logic) within 30 days. Preview, then enable uploads:

```sh
./amd64-linux-thunderstorm-collector -t ./my-config.yml --dry-run --debug
./amd64-linux-thunderstorm-collector -t ./my-config.yml --dry-run=false
```

### Default configuration

The packaged [config.yml](config.yml) selects by extension and magic header, up to **64 MiB**, any age. Profiles such as the [NetScaler profile](../emerging-threats/citrix-netscaler/README.md) may select more.

- **All file types:** set both `extension: []` and `magic: []`. Other limits and exclusions still apply.
- **No age cutoff:** `max-age: ""`. The value `"0"` sets the cutoff to the current time; it does not disable the filter.

## Usage

`--help` lists every option with the loaded configuration's defaults; see the [full help output](../README.md#command-line-help).

### Common options

Built-in defaults; the packaged `config.yml` changes some.

| Option | Default | Purpose |
| --- | --- | --- |
| `-s`, `--thunderstorm-server HOST` | none | Server; required unless `--dry-run` |
| `--port PORT` | 8080 | Server port |
| `--ssl` | off | Use HTTPS |
| `--ca FILE` | system CAs | Trust only these PEM CAs; repeatable |
| `--insecure` | off | Skip certificate verification (testing only) |
| `-p`, `--path DIR` | `/` or `C:\` | Root to collect; repeatable |
| `-m`, `--max-filesize MIB` | 100 (**64** in `config.yml`) | Largest file, inclusive |
| `-a`, `--max-age AGE` | none | Skip older files; suffix `s`, `m`, `h` or `d` (default days) |
| `--exclude GLOB` | none | Skip paths; `?`, `*` and `**`; repeatable |
| `-r`, `--threads N` | 1 | Upload workers; `0` all cores, `-2` all but two; minimum 1 |
| `--uploads-per-minute N` | 0 (no limit) | Rate-limit uploads |
| `--upload-synchronous` | off | Wait for scan results (slower) |
| `--response-timeout SEC` | 120 (1800 with `--upload-synchronous`) | Wait for the answer after a request was sent, 0 to 86400; `0` selects the default |
| `--server-wait SEC` | 600 | Wait for an unreachable server to come back, 0 to 86400; `0` stops at once |
| `-o`, `--source NAME` | hostname | Source name in Thunderstorm |
| `--http-proxy URL` | `HTTP_PROXY`/`HTTPS_PROXY` | Proxy |
| `--dry-run` | off | Select files without contacting the server |
| `--debug` | off | Show every file decision and marker answer |
| `-l`, `--logfile FILE` | none | Also write the log to this file |
| `-t`, `--template FILE` | `config.yml` | Configuration file |

`-e`/`--extension`, `--magic` and `--all-filesystems`: see [filtering](#file-filtering-logic) and [filesystem types](#filesystem-types).

### Examples

The `config.yml` filters still apply; preview with `--dry-run --debug` first.

```sh
# Files up to 500 MiB, ten upload workers
./amd64-linux-thunderstorm-collector -t ./config.yml -p /absolute/path/to/files \
  -s thunderstorm.example.internal --dry-run=false -r 10 -m 500

# HTTPS, files from the last ten days
./amd64-linux-thunderstorm-collector -t ./config.yml -p /absolute/path/to/files \
  -s thunderstorm.example.internal --dry-run=false --ssl --port 443 -a 10

# Proxy, scan results, log outside the collected directory
./amd64-linux-thunderstorm-collector -t ./config.yml -p /absolute/path/to/files \
  -s thunderstorm.example.internal --dry-run=false --upload-synchronous \
  --http-proxy http://proxy.example.internal:3128 --logfile ./collector.log
```

## Exit Status

| Status | Meaning |
| --- | --- |
| `0` | Every selected file was read and accepted (dry run: could be opened) |
| `1` | Startup or configuration failed (invalid option, unreachable server); a scan root could not be read; a selected file could not be read or was not accepted; Thunderstorm stayed unreachable for `--server-wait` seconds; or the run was interrupted and sent an `interrupted` marker |
| `130` | A second SIGINT/SIGTERM arrived while the `interrupted` marker was being sent |

[Collection markers](#collection-markers) never change the exit status. The log and statistics show each error.

Not errors: a directory below a root that cannot be listed (such as `System Volume Information`; counted under "Paths that could not be read during the walk"), files skipped on purpose, and files that vanish during the walk (not counted).

## Behavior Details

### File filtering logic

1. **Metadata, before queuing:** size, age and file type. Excluded files are never opened.
2. **Content, after opening:**
   - A matching extension selects the file. Case is ignored: `.exe` also selects `RUN.EXE`.
   - Otherwise, a matching magic header selects it.
   - If either list is configured and nothing matches, the file is skipped.
   - With neither configured, every file passes.

- **Size:** in MiB (1024 × 1024 bytes); a file of exactly the limit is included.
- **Re-check at upload:** when opened, the file must still be a regular file within `--max-filesize` and, on Unix-like systems, the same file the walk saw. It is opened without following a symlink and without blocking on a FIFO or device that replaced it. Exactly the size seen then is sent; a file that shrinks while being read is an error, one that disappeared before reading is not counted.
- **Age:** a file passes if **any** timestamp the platform provides is newer than the cutoff: modification and metadata-change time on many Unix targets, plus birth time on supported BSD/macOS targets; modification and creation time on Windows. The script collectors use modification time only.

### Filesystem types

Unless `--all-filesystems` is set, pseudo and network filesystems are not walked.

| Platform | Detection |
| --- | --- |
| Linux | statfs magic number |
| macOS | type name: `devfs`, `fdesc`, `volfs`, `autofs`, `nfs`, `smbfs`, `afpfs`, `webdav`, `ftp` |
| Windows, FreeBSD, others | none; use `--exclude`. The startup summary says `Filesystems: all filesystem types are scanned (network and pseudo filesystems cannot be recognised on this platform)` |

### Error handling and retry logic

- **Retries:** transport errors and HTTP 503 share **three retries** after the first attempt.
- **Transport errors:** wait 4, 8 and 16 seconds.
- **HTTP 503:** wait for an integer `Retry-After`, capped at **120 seconds**; **30 seconds** if missing or invalid.
- **Timeouts:** connecting gives up after **30 seconds**, the TLS handshake after **10 seconds**, and the whole connection setup, including a proxy's answer to `CONNECT`, after **60 seconds**. An upload fails when Thunderstorm accepts no data for **2 minutes**, so a slow but progressing upload is not cut off. The answer must arrive within `--response-timeout` (**120 seconds**, or **1800** with `--upload-synchronous`); a missing connection or answer counts as a transport error and is retried. A `/api/status` check gives up after **30 seconds**, or sooner if `--response-timeout` is shorter. Response bodies over **16 MiB** are rejected.
- **Server gone:** after **3 files in a row** could not be delivered (transport errors, or HTTP 503 after its retries), the collector stops sending and polls `/api/status` with growing delays (2, 4, 8 … up to 60 seconds) for up to `--server-wait` seconds (**600**). If Thunderstorm answers, collection continues with the next file; files that already failed stay errors. If the time runs out, the walk stops, queued files count as "Not sent", the collector sends an `interrupted` marker instead of `end`, and the run exits with **1**. `--server-wait 0` stops at once.
- **Other HTTP errors** and unreadable response bodies are logged and counted, without a retry.
- **Duplicates:** a lost response can cause a second submission.
- **Redirects** (3xx) are never followed, for the status check, markers or uploads; a replayed upload would have no body. A redirect is logged with its target and counted as an upload error. Check `--ssl`, `--port` and any gateway or proxy.
- **File names** are sent quoted, with `\` and `"` backslash-escaped and control characters (except TAB) and DEL percent-encoded, such as `%0D`. A hostile name cannot add MIME headers, alter the content or make the server reject the upload, whichever Go version built the binary.

### Collection markers

After the status check, the collector sends a `begin` marker to `POST /api/collection` so that Thunderstorm can group the run's samples.

- With a scan ID in the answer, every upload carries it as the `scan_id` query parameter (`/api/check` and `/api/checkAsync`), and an `end` marker with the run's counters closes the run.
- SIGINT (Ctrl+C) or SIGTERM sends an `interrupted` marker instead and exits with status 1; a second signal exits at once.
- `404` or `501` means no marker support (THOR 10 and current THOR 11). No further markers are sent.
- Any other `begin` failure is retried once after 2 seconds; then files upload without a scan ID.
- Failed `end` or `interrupted` markers are ignored. Each marker request times out after **10 seconds**. Dry runs send none.

Marker problems are not logged and never change the exit status; `--debug` shows the answers. The format, shared with the script collectors, is in [Collection markers](../docs/COLLECTION_MARKERS.md).

### Collection statistics

Each run ends with statistics: files discovered, exclusions by reason, uploads, errors and time per phase. With `--debug`, every file to be sent (marked DRY-RUN in a dry run) and every skipped file with its reason is listed too.

<details>
<summary>Example statistics</summary>

```text
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
  - Paths that could not be read during the walk: 0

Timing:
  - File system walk: 2.5s
  - File metadata analysis: 1.2s
  - File read and transmission: 45.3s
  - Total time: 49.3s
```

</details>

### Dry-run mode

`--dry-run` discovers, opens and filters files but sends **no HTTP requests**; statistics count files that would be sent. It checks the selection, not connectivity or analysis. `--dry-run=false` overrides `dry-run: true` from a configuration.

### Performance

Analysis runs on the Thunderstorm server, so scope, file sizes, signatures and server capacity decide processing time. Walking, reading and uploading still load the source. Files are streamed, not held in memory.

- Start small; check server load and results before widening scope or concurrency.
- Pick a configuration or profile that fits the scope; set `--max-filesize` to skip very large files.
- Skip known directories, for example `--exclude "**/node_modules/**"`.
- Limit upload pressure with `--threads` and `--uploads-per-minute`.
- Asynchronous acceptance is not analysis completion; check that separately.

Transfer volume depends on file selection; see [recurring collection](../docs/SCANNING_APPROACHES.md#recurring-collection).

## Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `thunderstorm-server: not specified` | Set `-s` or `thunderstorm-server`, or use `--dry-run` |
| `Unexpected argument(s)` | A value without its option, such as `-s HOST /data`. Give every root its own `-p`; the collector will not guess and walk the whole filesystem |
| `max-filesize: must be > 0` | Use at least 1 MiB |
| `max-age: invalid suffix` | Use `s`, `m`, `h` or `d`, for example `--max-age 10h` |
| `magic header too long` | The limit is **1024 bytes** |
| `Could not open CA file` | Check the `--ca` path and permissions |
| `Could not add CA ... to certificate pool` | The file is not valid PEM |
| `no answer from Thunderstorm within ...` | The server or a gateway accepted the connection but did not answer within `--response-timeout`. Check the server's load and logs; raise the value only if Thunderstorm is known to answer slowly |
| `Thunderstorm did not accept 3 files in a row` / `Thunderstorm unreachable for ..., stopping the collection` | The server went away during the run; see `--server-wait` under [error handling](#error-handling-and-retry-logic) |

## Platform Notes

### Citrix NetScaler and FreeBSD 8.4

The dedicated `amd64-freebsd8-netscaler` binary targets **FreeBSD 8.4/amd64**. It was also VM-tested on FreeBSD 14.3; that is not a firmware boundary, and the two tests do not establish a supported range in between.

#### Choose a collector for your NetScaler

Identify the **firmware/build**, **underlying OS** and **CPU** on the NetScaler instance itself, not on a management host or hypervisor. In the NetScaler CLI:

```text
show ns version
shell
```

Then, in the shell:

```sh
uname -a
```

In Citrix's example, `11.4-NETSCALER-13.1` means **FreeBSD 11.4** under **NetScaler 13.1**; `amd64` is 64-bit x86. Vendor notices list FreeBSD 8.4 for NetScaler 13.0 and FreeBSD 11.4 for 13.1 and 14.1. They are component inventories, not test results; select by the appliance's own output.

Sources: [show ns version](https://developer-docs.netscaler.com/en-us/adc-command-reference-int/current-release/ns/ns-version.html) · [CTX495617](https://support.citrix.com/external/article?articleUrl=CTX495617-how-to-check-the-version-of-freebsd-on-netscaler&language=en_US) · notices [13.0](https://www.citrix.com/content/dam/citrix/en_us/documents/downloads/netscaler-adc/Citrix_ADC_ADM_FreeBSD_13.0_Third_Party_Notices.pdf), [13.1](https://www.citrix.com/content/dam/citrix/en_us/documents/downloads/netscaler-adc/NetScaler_ADC_ADM_FreeBSD_13.1_Third_Party_Notices.pdf), [14.1](https://www.citrix.com/content/dam/citrix/en_us/documents/downloads/netscaler-adc/NetScaler_ADC_ADM_FreeBSD_14.1_Third_Party_Notices.pdf)

| Appliance environment | Try first | Alternative |
| --- | --- | --- |
| **FreeBSD 8.4, amd64** | Dedicated [`amd64-freebsd8-netscaler` package](#dedicated-netscaler-package-and-downloads) | [Bash NetScaler preset](../emerging-threats/citrix-netscaler/README.md#option-2-existing-bash-collector) |
| **Other FreeBSD**, including 8.4 to 14.3 | [Bash NetScaler preset](../emerging-threats/citrix-netscaler/README.md#option-2-existing-bash-collector) | Regular FreeBSD Go package, if the OS meets its compiler's minimum |
| **Other OS or CPU** | Go package for that OS/CPU | Bash preset; see [platform requirements](../docs/COLLECTOR_RECOMMENDATIONS.md#compatibility-boundaries) |

- **Regular FreeBSD Go packages** (Go 1.10) need **FreeBSD 10.3 or later** ([Go 1.10 requirements](https://github.com/golang/go/blob/go1.10.8/doc/install.html)): a minimum, not a tested firmware range. Newer Go builds have their own minimums. The 14.3 VM test does not make the dedicated binary preferable on modern FreeBSD.
- **The Bash preset** does not use the Go binary or its YAML. It needs Bash 3.2+, `curl` or GNU wget with `--no-config`, GNU/BSD utilities, readable paths and writable temporary storage ([Bash requirements](../scripts/bash/README.md#requirements)). Name local roots explicitly; its mount exclusions rely on Linux `/proc/mounts`.
- **No local execution:** copy the relevant files to a workstation and collect them there. Coverage depends on what was copied.
- **First run:** preview and upload a small directory of synthetic files on the intended appliance; record firmware/build, OS/CPU, collector revision, paths and result. Then follow the [NetScaler assessment guide](../emerging-threats/citrix-netscaler/README.md).

#### Dedicated NetScaler package and downloads

Built with **Go 1.9.7** and `CGO_ENABLED=0` for FreeBSD 8.4/amd64; regular FreeBSD packages are not interchangeable with it.

- **v1.1.0:** **`thunderstorm-collector-1.1.0-amd64-freebsd8-netscaler.tar.gz`** and its `.sha256` in the [release assets](https://github.com/NextronSystems/thunderstorm-collector/releases/tag/v1.1.0).
- **Later versions:** `thunderstorm-collector-<version>-amd64-freebsd8-netscaler.tar.gz`.
- **v1.0.1 and earlier** do not contain it.

The package holds the executable, `config.yml`, compatibility notes and `BUILD-INFO.txt` (source commit, compiler). Verify the checksum. CI artifacts and source builds: [legacy build guide](legacy/README.md). Paths and filters: [NetScaler profile](../emerging-threats/citrix-netscaler/README.md).

#### Compatibility evidence as of 2026-10-08

| What | Status |
| --- | --- |
| Dedicated package on FreeBSD 8.4 and 14.3 amd64 | **VM-tested**; 14.3 needs ASLR disabled for the invocation |
| Go 1.9.7 build and shared source on Linux/amd64 | **Automated** |
| HTTPS from the dedicated package on FreeBSD | **Not yet tested**; the VM tests used HTTP |
| Bash NetScaler preset | **Not yet tested** on NetScaler; tested with synthetic files on macOS |
| Any named NetScaler appliance or firmware | **Not yet tested** |

Tested artifact, VMs, server and checksums: [NetScaler/FreeBSD test evidence](../docs/evidence/netscaler-freebsd.md). Later builds are not automatically VM-tested.

#### ASLR when testing on modern FreeBSD

On FreeBSD 14.3, the dedicated binary failed with `runtime: address space conflict` and ran with ASLR disabled for the invocation:

```sh
proccontrol -m aslr -s disable ./amd64-freebsd8-netscaler-thunderstorm-collector --help
```

FreeBSD 8.4 needs no workaround. This is not a required NetScaler configuration change.

> [!WARNING]
> **Go 1.9.7 is unsupported** under the [Go release policy](https://go.dev/doc/devel/release#policy). Its runtime and standard library, including HTTP/TLS, lack later security fixes; an isolated build job does not change that. Keep certificate verification and server security settings. If secure connections fail, use a supported collector or platform instead of weakening them.

### Unsupported versions

The Go collector does not run on **Windows 2000** or **Windows NT**; use a [script collector](../scripts/README.md#choosing-a-collector) with its own interpreter and utilities.

If a prebuilt binary crashes, find the last Go version for your OS in the [Go platform requirements](https://go.dev/wiki/#platform-specific-information). All `os` and `arch` values: [Go install guide](https://golang.org/doc/install/source#environment). `go version <binary>` shows the compiler if your toolchain recognizes the binary's build information; otherwise check the release or build record.

### AIX on POWER7

The standard AIX binaries require **POWER8 or newer**. For POWER7, use a validated script collector, SSHFS scanning from a supported workstation, the [SFTP collector](../sftp/README.md) on another system, or exported evidence: see the [AIX example](../docs/SCANNING_APPROACHES.md#aix-on-power7-as-an-example) and the [POWER7 SSHFS guide](../integration-guides/aix/aix-power7-sshfs-scanning.md). Ask Nextron about any special `gccgo` build.

## Build

### Build requirements

- Go, `make`, a Unix-like shell with standard utilities; `tar`, `gzip` and `zip` for release archives. Downloaded collectors need neither Go nor `make`.
- Regular builds keep **Go 1.10** compatibility where it supports the target; newer targets need a newer compiler. The [NetScaler build](legacy/README.md) uses Go 1.9.7.
- Dependencies are in `go.mod` and `go.sum`. For Go 1.10, first run `go mod vendor` here with a modern Go, then build with Go 1.10; `vendor/` is not committed. The Makefile provides the GOPATH symlink the old compiler needs. The [CI setup action](../.github/actions/setup-go/action.yml) follows these steps.

### Build steps

From this `go/` directory, run one of:

```sh
make              # current OS/architecture
make all          # all supported cross-compilation targets
make linux/amd64  # one target
make release      # distribution archives in dist/
make help         # list targets
```

`go tool dist list` shows the compiler's targets; the Makefile skips those it does not package. Script packaging and tagged releases: [main build guide](../README.md#build-or-extend-a-collector).
