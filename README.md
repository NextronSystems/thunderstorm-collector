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

### Scripts Package

If you prefer scripts over compiled binaries, download `thunderstorm-collector-scripts.zip` which includes:
- `thunderstorm-collector.sh` (Bash)
- `thunderstorm-collector.ps1` (PowerShell)
- `thunderstorm-collector.py` (Python)
- `thunderstorm-collector.pl` (Perl)
- `thunderstorm-collector.bat` (Batch)

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
make release           # Build both binary packages and scripts package
make release-binary    # Build binary packages only
make release-scripts   # Build scripts package only
make help              # Show all available targets
```

This creates:
- **Binary packages:** `go/dist/*.tar.gz` and `go/dist/*.zip` (46+ platforms)
- **Scripts package:** `release/thunderstorm-collector-scripts.zip`

## Which Collector Should You Choose?

**Go Collector (Recommended)** - Our top recommendation for most use cases:
- ✅ Pre-compiled binaries for 46+ platforms
- ✅ Fast, efficient, single binary
- ✅ No runtime dependencies
- ✅ Includes configuration file
- ✅ Comprehensive features (dry-run mode, statistics, rate limiting, etc.)

**Scripts** - Use when:
- Running a compiled binary isn't feasible
- Working in highly-sensitive environments requiring source code review
- Using unsupported platforms (proprietary OS, IoT devices)
- Requiring low-effort customization of collection logic

## Automated Releases

When a version tag is pushed (e.g., `v1.2.3`), GitHub Actions automatically:
1. Builds binaries for all 46 supported platforms
2. Creates compressed packages (tar.gz/zip) with binary + config
3. Creates a scripts package with all collection scripts
4. Publishes a GitHub release with all packages attached

## Craft Your Own Collector

Interested in creating a unique collector? A Python module, `thunderstormAPI`, is available in [this](https://github.com/NextronSystems/thunderstormAPI) repository for your use.
