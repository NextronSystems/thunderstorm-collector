![Thunderstorm Collector](images/thunderstorm-collector-logo.png)

# THOR Thunderstorm Collector

THOR Thunderstorm collectors facilitate effortless file uploads to a THOR Thunderstorm instance. More details on THOR Thunderstorm are available [here](https://www.nextron-systems.com/2020/10/01/theres-a-thunderstorm-coming/).

Users can filter files based on their size, age, extension or type.

This repository features:

- **[Go Collector](go/)** - Compiled binary for 46+ platforms (Linux, Windows, macOS, BSD, etc.)
- **[Collection Scripts](scripts/)** - Alternative scripts in Bash, PowerShell, Python, Perl, and Batch

For a comprehensive guide on each collector, refer to the linked subdirectories.

## Download Pre-Built Releases

The easiest way to get started is to download a pre-built release from the [Releases](../../releases) page.

### Binary Packages

Each release includes platform-specific packages containing:
- Pre-compiled binary for your platform
- Default configuration file (`config.yml`)

**Download the package for your platform:**
- **Linux:** `thunderstorm-collector-amd64-linux.tar.gz` (or arm64, 386, etc.)
- **Windows:** `thunderstorm-collector-amd64-windows.zip` (or arm64, 386, etc.)
- **macOS:** `thunderstorm-collector-amd64-darwin.tar.gz` or `thunderstorm-collector-arm64-darwin.tar.gz`
- **BSD:** FreeBSD, OpenBSD, NetBSD packages available
- **Other:** AIX, Solaris, Plan9, and more

**Quick start:**
```bash
# Linux/macOS example
tar -xzf thunderstorm-collector-amd64-linux.tar.gz
cd thunderstorm-collector-amd64-linux
./amd64-linux-thunderstorm-collector --help
```

### Script Assets

Each available collector is attached to the release as a separate, versioned script asset, for example `thunderstorm-collector-<version>.sh` or `thunderstorm-collector-py2-<version>.py`. There is no combined scripts ZIP archive.

Source code and per-collector documentation are organized in:
- `scripts/bash/` (Bash)
- `scripts/ash/` (POSIX sh / ash)
- `scripts/python/` (Python 3 and Python 2)
- `scripts/perl/` (Perl)
- `scripts/powershell/` (PowerShell 3+ and PowerShell 2)
- `scripts/batch/` (Windows Batch)

See the [scripts README](scripts/README.md) for usage instructions.

## Building from Source

To build the Thunderstorm Collector from source:

### Go Collector

```bash
cd go
make        # Build for your current platform
make all    # Build binaries for all platforms
make release # Create distribution packages for all platforms
make help   # Show all available build targets
```

### Creating Release Packages Locally

From the repository root:

```bash
make release           # Build binary packages and individual script assets
make release-binary    # Build binary packages and copy standalone config
make release-scripts   # Copy individual script assets only
make help              # Show all available targets
```

This creates:
- **Binary packages:** `go/dist/*.tar.gz` and `go/dist/*.zip` (46+ platforms)
- **Release assets:** versioned binary packages, individual collector scripts, and `config-<version>.yml` in `release/`

## Which Collector Should You Choose?

**Go Collector (Recommended)** - Our top recommendation for most use cases:
- ✅ Pre-compiled binaries for 46+ platforms
- ✅ Fast, efficient, single binary
- ✅ No runtime dependencies
- ✅ Includes configuration file
- ✅ Comprehensive features (dry-run mode, statistics, rate limiting, etc.)

**Scripts** - Use when:
- Running a compiled binary isn't feasible
- Using unsupported platforms (proprietary OS, IoT devices)
- Requiring low-effort customization of collection logic

## Automated Releases

When a version tag is pushed (e.g., `v1.2.3`), GitHub Actions automatically:
1. Builds binaries for all 46 supported platforms
2. Creates compressed packages (tar.gz/zip) with binary + config
3. Copies each available collector script and the standalone configuration into versioned release assets
4. Publishes a GitHub release with binary packages and individual assets attached

## Craft Your Own Collector

Use the [collector construction guide](docs/COLLECTOR_CONSTRUCTION_GUIDE.md)
to build a standalone collector in another language or for an unusual platform.
It covers the HTTP upload contract, optional features, security/resource limits,
tests and a reusable coding-agent assignment.

Interested in creating a unique collector? A Python module, `thunderstormAPI`, is available in [this](https://github.com/NextronSystems/thunderstormAPI) repository for your use.
