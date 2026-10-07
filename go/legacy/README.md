# Legacy NetScaler package (FreeBSD 8.4 / amd64)

This build uses exactly **Go 1.9.7**, `GOOS=freebsd`, `GOARCH=amd64` and `CGO_ENABLED=0`, using the shared collector source and pinned vendored dependencies. No collector features are intentionally removed, and regular builds retain their compilers and package names. HTTP 503 retries in the shared collector are now bounded to three retries, matching transport-error retries.

## Download and select

The first tagged release containing this workflow will attach `thunderstorm-collector-<version>-amd64-freebsd8-netscaler.tar.gz` alongside the regular packages, with a SHA-256 sidecar and inclusion in `SHA256SUMS`. This package is not present in previous releases and must not be described as already downloadable before a containing release is published. The reviewed historical asset names did not identify a dedicated legacy package; this does not establish which compiler built every historical generic binary.

Confirm the appliance actually runs FreeBSD 8.4 on **amd64 / 64-bit x86**. The [Go support table](https://go.dev/wiki/FreeBSD) lists amd64 and 386 for FreeBSD 8-STABLE, ending at Go 1.9.7. The repository's 2020 NetScaler note records a Go 1.9.7 build on FreeBSD 8.4 but does not name an architecture or firmware. The selected amd64 target follows the supported OS/architecture table, not a newly verified historical appliance architecture. No 386 package is included without a demonstrated target need. For other NetScaler versions, select using the actual OS, architecture and verified compatibility evidence. A regular FreeBSD package is not interchangeable with this legacy target.

The archive includes:

- `amd64-freebsd8-netscaler-thunderstorm-collector` (executable)
- The shared, Go 1.9.7-validated `config.yml`
- `COMPATIBILITY.txt` (target, limitations and safe first-use guidance)
- `BUILD-INFO.txt` (actual compiler output, source commit/dirty state, target, flags, toolchain SHA-256 and dependency input hashes)

Check the release checksum, unpack the archive, and start with a small directory containing synthetic files. From the unpacked directory:

```sh
./amd64-freebsd8-netscaler-thunderstorm-collector \
  --dry-run --debug -p /absolute/path/to/collector-test
```

For uploads, use the [shared Go collector CLI](../README.md#usage), specifying your Thunderstorm server and the same small test directory. Keep TLS verification enabled.

## Compatibility evidence and limitations

| Evidence level | Status for this new artifact |
| --- | --- |
| Go 1.9.7 compilation for freebsd/amd64 | Verified on a Linux/amd64 host; static FreeBSD ELF, architecture, permissions, archive contents, metadata and checksums checked |
| Shared source/runtime on Linux | Existing Go tests plus synthetic HTTP integration with Go 1.9.7; checks content, original path, source, selection, config, dry run, bounded 503/recovery, permanent errors and untrusted TLS rejection |
| Runtime on FreeBSD 8.4 | Pending; Linux tests do not execute the FreeBSD binary |
| Nextron runtime test on named NetScaler firmware | Pending; historical NetScaler success lacks a recorded firmware/collector matrix |
| Customer-reported success for this new package | None recorded |

These checks use a controlled local HTTP test service, not a real Thunderstorm service. No suitable FreeBSD 8.4 VM or NetScaler appliance was available for this change. To add validation, record the OS, architecture, appliance firmware, collector source commit and compiler, then check selection and uploads of synthetic files (content, original path and source), error/retry behavior and secure server connectivity. Record the evidence level here; do not turn a Linux mock test into an appliance claim.

**Go 1.9.7 is unsupported** under the [Go release policy](https://go.dev/doc/devel/release#policy). Its shipped runtime and standard library, including HTTP/TLS code, lack later fixes. Using a supported runner and maintained GitHub Actions does not modernize the binary. Do not disable certificate verification or weaken server-side security to obtain compatibility. If secure interoperability fails, use a supported collector/platform instead.

## CI and optional advanced local build

`.github/workflows/legacy-netscaler.yml` runs for PRs, main/master pushes and manual validation, and is reused by tagged releases. It has read-only repository permissions and no release credentials. A modern Go tool prepares only the exact go.mod/go.sum dependencies, verifies them and creates the vendor directory without changing module files. The isolated compiler is downloaded from the official Go archive and checked against the pinned SHA-256; it is never replaced by a newer compiler.

On a Linux/amd64 build host with Git, curl, Python 3.9+, make/coreutils and tar available:

```sh
# From the repository root, prepare pinned dependencies with a modern Go tool.
(cd go && GOFLAGS=-mod=readonly go mod download && go mod verify && go mod vendor)
export LEGACY_TOOLCHAIN_DIR=$(mktemp -d)
bash .github/scripts/install-legacy-go.sh
export LEGACY_GO="$LEGACY_TOOLCHAIN_DIR/go/bin/go"
VERSION=validation-local bash .github/scripts/build-legacy-netscaler.sh
python3 .github/scripts/test-legacy-release.py
```

The build creates only its separate `go/legacy/dist/*-amd64-freebsd8-netscaler.tar.gz` and checksum. The publishing job downloads that required Actions artifact and verifies it before publishing the same tagged GitHub release as the regular packages. Missing/corrupt packages or checksums fail release preparation. Normal build flags, vendor layout and output paths remain intact.

The artifact is a customer download after release; a local old toolchain is only an optional advanced build path. No tags or historical releases are changed to validate this pipeline.
