# Legacy NetScaler Package (FreeBSD 8.4 / amd64)

[Go collector guide](../README.md) · [Collector downloads](../../README.md#download-a-collector) · [NetScaler assessment guide](../../emerging-threats/citrix-netscaler/README.md)

The dedicated Go collector package for Citrix NetScaler on confirmed
**FreeBSD 8.4, amd64**. Download it from a release or from CI; building it
yourself is optional.

> [!NOTE]
> VM-tested on FreeBSD 8.4. Not yet tested on NetScaler firmware. The
> [compatibility guide](../README.md#citrix-netscaler-and-freebsd-84) records
> validation status and toolchain limitations.

## Download and select

1. **Confirm the target.** Follow the
   [NetScaler selection steps](../README.md#choose-a-collector-for-your-netscaler)
   to check the OS and CPU and to compare the Go binary with the Bash
   alternative.
2. **Download a package**, either:
   - **Release:** open the
     [v1.1.0 release](https://github.com/NextronSystems/thunderstorm-collector/releases/tag/v1.1.0)
     and download `thunderstorm-collector-1.1.0-amd64-freebsd8-netscaler.tar.gz`
     and its `.sha256` file under **Assets**. The
     [main download guide](../../README.md#download-a-collector) covers package
     selection and current source.
   - **Newer CI validation build:** see [CI artifacts](#ci-artifacts) below.
3. **Verify the checksum, then extract:**

   ```sh
   # On macOS: shasum -a 256 -c ...
   sha256sum -c thunderstorm-collector-1.1.0-amd64-freebsd8-netscaler.tar.gz.sha256
   tar -xzf thunderstorm-collector-1.1.0-amd64-freebsd8-netscaler.tar.gz
   ```

### CI artifacts

1. Sign in to GitHub and open the
   [Legacy NetScaler workflow runs](https://github.com/NextronSystems/thunderstorm-collector/actions/workflows/legacy-netscaler.yml).
2. Select a successful run for the branch and commit you intend to use.
3. In the run's **Artifacts** section, download **`netscaler-freebsd8`**.
4. Extract the ZIP. It contains the collector's `.tar.gz` package and its
   `.sha256` file. Verify the checksum, then extract the package.

CI artifacts expire after **14 days**, as set in the
[workflow](../../.github/workflows/legacy-netscaler.yml). If one has expired,
select a newer successful run for a suitable revision, or ask a maintainer to
run the workflow for the revision you need. GitHub documents
[artifact download access and steps](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

### Package contents

| File | Content |
|---|---|
| `amd64-freebsd8-netscaler-thunderstorm-collector` | The executable |
| `config.yml` | The shared configuration, validated with Go 1.9.7 |
| `COMPATIBILITY.txt` | Target, limitations and safe first-use guidance |
| `BUILD-INFO.txt` | Actual compiler output, source commit and dirty state, target, flags, toolchain SHA-256 and dependency input hashes |

## First Run

1. Test compatibility with a small existing directory of synthetic files.
   From the unpacked directory, replace `/absolute/path/to/collector-test`
   and run:

   ```sh
   ./amd64-freebsd8-netscaler-thunderstorm-collector \
     -t ./config.yml --dry-run --debug -p /absolute/path/to/collector-test
   ```

2. Test an upload of the same directory with your Thunderstorm server; see the
   [shared Go collector CLI](../README.md#usage). Keep TLS verification on.
3. For a broad assessment, follow the
   [NetScaler profile guide](../../emerging-threats/citrix-netscaler/README.md)
   and download its separate YAML configuration.

## Build Details

The package is built with exactly **Go 1.9.7**, `GOOS=freebsd`,
`GOARCH=amd64` and `CGO_ENABLED=0`, from the shared collector source and
pinned vendored dependencies.

### CI and releases

The [legacy build workflow](../../.github/workflows/legacy-netscaler.yml) runs
for pull requests, pushes to `main` and `master`, and manual validation. Tagged
releases reuse it.

- It has read-only repository permissions and no release credentials.
- A modern Go tool prepares only the exact `go.mod` and `go.sum`
  dependencies, verifies them and creates the vendor directory without
  changing the module files.
- The isolated compiler comes from the official Go archive and is checked
  against a pinned SHA-256. It is never replaced by a newer compiler.
- CI uploads the package and checksum as the `netscaler-freebsd8` artifact.
  The [tagged-release workflow](../../.github/workflows/release.yml) requires
  and verifies that artifact before attaching the packages to a draft release.
  A maintainer publishes the draft separately after review.

### Optional local build

You need a Linux/amd64 host with Git, curl, Python 3.9+, make, coreutils and
tar. From the repository root:

```sh
# Prepare pinned dependencies with a modern Go tool.
(cd go && GOFLAGS=-mod=readonly go mod download && go mod verify && go mod vendor)
export LEGACY_TOOLCHAIN_DIR=$(mktemp -d)
bash .github/scripts/install-legacy-go.sh
export LEGACY_GO="$LEGACY_TOOLCHAIN_DIR/go/bin/go"
VERSION=validation-local bash .github/scripts/build-legacy-netscaler.sh
python3 .github/scripts/test-legacy-release.py
```

The build creates `go/legacy/dist/*-amd64-freebsd8-netscaler.tar.gz` and its
checksum.
