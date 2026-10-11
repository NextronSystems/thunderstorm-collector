# Legacy NetScaler package (FreeBSD 8.4 / amd64)

[Go collector guide](../README.md) · [Collector downloads](../../README.md#download-a-collector) · [NetScaler assessment guide](../../emerging-threats/citrix-netscaler/README.md)

This build uses exactly **Go 1.9.7**, `GOOS=freebsd`, `GOARCH=amd64` and `CGO_ENABLED=0`, using the shared collector source and pinned vendored dependencies.

## Download and select

Use the [NetScaler package and compatibility guide](../README.md#citrix-netscaler-and-freebsd-84) for release availability, target selection, validation status and unsupported-toolchain limitations.

The archive includes:

- `amd64-freebsd8-netscaler-thunderstorm-collector` (executable)
- The shared, Go 1.9.7-validated `config.yml`
- `COMPATIBILITY.txt` (target, limitations and safe first-use guidance)
- `BUILD-INFO.txt` (actual compiler output, source commit/dirty state, target, flags, toolchain SHA-256 and dependency input hashes)

Check the release checksum, unpack the archive, and start with a small directory containing synthetic files. From the unpacked directory:

```sh
./amd64-freebsd8-netscaler-thunderstorm-collector \
  -t ./config.yml --dry-run --debug -p /absolute/path/to/collector-test
```

For uploads, use the [shared Go collector CLI](../README.md#usage), specifying your Thunderstorm server and the same small test directory. Keep TLS verification enabled. For a broad assessment, follow the [NetScaler profile guide](../../emerging-threats/citrix-netscaler/README.md) and download its separate YAML configuration.

## CI and optional advanced local build

The [legacy build workflow](../../.github/workflows/legacy-netscaler.yml) runs for PRs, main/master pushes and manual validation, and is reused by tagged releases. It has read-only repository permissions and no release credentials. A modern Go tool prepares only the exact go.mod/go.sum dependencies, verifies them and creates the vendor directory without changing module files. The isolated compiler is downloaded from the official Go archive and checked against the pinned SHA-256; it is never replaced by a newer compiler.

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

The local build creates `go/legacy/dist/*-amd64-freebsd8-netscaler.tar.gz` and its checksum. CI uploads them as the `netscaler-freebsd8` artifact. The [tagged-release workflow](../../.github/workflows/release.yml) requires and verifies that artifact before publishing the release.
