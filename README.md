![Thunderstorm Collector](images/thunderstorm-collector-logo.png)

# THOR Thunderstorm Collector

THOR Thunderstorm collectors facilitate effortless file uploads to a THOR Thunderstorm instance. More details on THOR Thunderstorm are available [here](https://www.nextron-systems.com/2020/10/01/theres-a-thunderstorm-coming/).

Users can filter files based on their size, age, extension or type.

This repository features:

- **[Go Collector](go/)** - Compiled binary for 46+ platforms (Linux, Windows, macOS, BSD, etc.)
- **[Collection Scripts](scripts/)** - Alternative scripts in Bash, PowerShell, Python, Perl, and Batch

For a comprehensive guide on each collector, refer to the linked subdirectories.

## Appliance Collector Recommendations

Choose the collector for your appliance before selecting a generic OS download.

| Appliance or target | Recommended collector | Requirements and testing status | Download or instructions |
| --- | --- | --- | --- |
| VMware ESXi | Python collector (`scripts/thunderstorm-collector.py`) | Python 3.6+ and standard library only. Nextron has used it successfully on ESXi; exact firmware versions and collector revisions are not recorded. | [ESXi quick start and compatibility notes](scripts/README.md#vmware-esxi-use-the-python-collector) |
| Older Citrix NetScaler based on FreeBSD 8.4 (amd64) | Separate legacy Go collector built with Go 1.9.7 | A regular FreeBSD package is not interchangeable. Check release availability; appliance validation remains pending. | [NetScaler package selection and testing status](go/README.md#citrix-netscaler-and-freebsd-84) |
| Other NetScaler versions | Select for the actual OS version and architecture | Verify compatibility for your appliance; neither Go 1.9.7 nor a generic FreeBSD package is suitable for every NetScaler. | [NetScaler compatibility guidance](go/README.md#citrix-netscaler-and-freebsd-84) |

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

### Collection Scripts

Published releases currently provide individual, versioned script files such as `thunderstorm-collector-1.0.1.py`. Download the Python, Bash, PowerShell, Perl or Batch file from the [Releases](../../releases) page. Use the [scripts README](scripts/README.md) for usage instructions. For ESXi, start with the [Python guidance](scripts/README.md#vmware-esxi-use-the-python-collector).

A scripts ZIP package is not available in the currently published releases. If a future release provides one, check that release's contents and instructions.

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
make release           # Build binary packages and versioned script files
make help              # Show all available targets
```

This creates:
- **Binary packages:** `go/dist/*.tar.gz` and `go/dist/*.zip` (46+ platforms)
- **Scripts:** individual versioned files in `release/`

## Which Collector Should You Choose?

**Go Collector** - Our recommendation for most general-purpose systems; use the appliance recommendations above for ESXi and NetScaler:
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
3. Copies the individual collection scripts as versioned release files
4. Publishes a GitHub release with all packages attached

## Craft Your Own Collector

Interested in creating a unique collector? A Python module, `thunderstormAPI`, is available in [this](https://github.com/NextronSystems/thunderstormAPI) repository for your use.
