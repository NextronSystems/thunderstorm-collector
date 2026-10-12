![Thunderstorm Collector](images/thunderstorm-collector-logo.png)

# THOR Thunderstorm Collector

Thunderstorm collectors provide lightweight, agentless file collection for analysis by the [THOR Thunderstorm](https://www.nextron-systems.com/thor-thunderstorm/) service. They walk configured directories on an endpoint, apply filters for file size, age, and type, and send matching file samples to the service.

Selective collection keeps endpoint workload and network traffic low. Metadata filters exclude unsuitable files without reading their full contents, and only matching samples are sent for analysis. For recurring collection, an age filter can focus each run on recently created or modified files. This supports frequent checks with broad coverage of relevant files within the configured scope, while the Thunderstorm service performs the computationally intensive analysis.

No collector installation or permanently running endpoint agent is required. Collectors run as portable binaries or standalone scripts using the required runtime and tools available on the endpoint. They can be started remotely through Ansible or another automation script, or placed on the endpoint and scheduled with cron or Windows Task Scheduler. Each invocation performs a collection pass and exits.

This repository provides a compiled Go collector, standalone script collectors, and assessment guides with collection configurations. Available filters, dependencies, and capabilities vary by collector.

## Choose a Collector

| Starting point | When to use it | Documentation |
| --- | --- | --- |
| **Go collector** | Recommended for most general-purpose systems with a compatible OS and CPU architecture. Runs as a compiled binary without an installed Go runtime. | [Go usage, configuration, and platform compatibility](go/README.md) |
| **Script collectors** | Use an available scripting runtime when a compiled binary is impractical or you need to adapt the collection logic. | [Script selection and requirements](scripts/README.md#choosing-a-collector) |

The eight standalone scripts are organized into [Bash](scripts/bash/README.md), [POSIX sh / ash](scripts/ash/README.md), [Python](scripts/python/README.md), [Perl](scripts/perl/README.md), [PowerShell](scripts/powershell/README.md), and [Batch](scripts/batch/README.md) directories. Python and PowerShell each include a separate legacy variant.

For platform-specific selection, start with the **[collector recommendations](docs/COLLECTOR_RECOMMENDATIONS.md)**. They are ordered approximately by deployment prevalence, with related products grouped together:

- **Common systems and infrastructure:** Windows, Linux (including legacy kernels), macOS, VMware, Amazon Linux, and Kubernetes.
- **Edge appliances and NAS:** Cisco, Fortinet, Palo Alto Networks, Citrix NetScaler, F5, Check Point, Sophos, Ivanti, SonicWall, Synology, QNAP, pfSense/OPNsense, and OpenWrt.
- **Specialist platforms:** Nutanix, FreeBSD, OpenBSD, NetBSD, Solaris/illumos, and IBM AIX. The [binary inventory](docs/COLLECTOR_RECOMMENDATIONS.md#published-go-binary-targets) covers their available CPU targets, including ARM, MIPS, PowerPC, s390x, RISC-V, and LoongArch on applicable systems.

Prefer direct THOR scanning where the target is supported and local scanning is permitted. **THOR 11 is planned to add Windows ARM64 and Linux ARM64 support**, reducing the need for collectors on those supported systems. Collectors remain useful for legacy systems, appliances, other architectures, and central file-analysis workflows. See the [announcement and selection guidance](docs/COLLECTOR_RECOMMENDATIONS.md#direct-thor-scanning-and-arm64).

For VMware ESXi, use the [Python quick start](scripts/README.md#vmware-esxi-use-the-python-collector); for older NetScaler systems, check the [dedicated FreeBSD 8.4 package guidance](go/README.md#citrix-netscaler-and-freebsd-84).

## Emerging Threats: Assessment Guides and Collection Profiles

Use the [Emerging Threats guides](emerging-threats/README.md) to choose the files and directories to collect for a particular assessment. Profiles configure existing collectors; analysis uses the signatures installed on the Thunderstorm server.

| Assessment | Guide and configuration |
| --- | --- |
| **Citrix NetScaler** | [Broad assessment guide](emerging-threats/citrix-netscaler/README.md), with a [Go configuration](emerging-threats/citrix-netscaler/config.yml) and presets for the existing Bash collector. |

These profiles are optional and downloaded separately from release packages. Each guide documents its scope, limits, execution requirements, and validation status. For Go, download the profile YAML using GitHub's **Download raw file** control and load it with `-t`; for Bash, apply the guide's preset to a deployment copy of the script.

## Download a Collector

Use [Releases](https://github.com/NextronSystems/thunderstorm-collector/releases) for published versions. Under **Assets**, select the package matching your OS and architecture: `amd64` means x86-64, and `arm64` means AArch64. Follow the documentation for that release.

- **Go packages** contain the executable and a default `config.yml`. Windows packages use ZIP; other platforms use `.tar.gz`. The standalone `config-<version>.yml` asset is an additional copy of that configuration.
- **Script assets** are individual, versioned files. Download the selected collector and check its runtime requirements. Each script runs independently; the repository's test harness is not required on the target.

**Release availability, 12 October 2026:** v1.0.1 is the latest published release; v1.0.2 has not been published. The revised script collectors, additional legacy script variants, and dedicated NetScaler package described on `master` are newer than v1.0.1.

- **Current scripts:** open the collector file linked in the [script selection table](scripts/README.md#choosing-a-collector) and use GitHub's **Download raw file** control, preserving the filename and extension. A single script is sufficient; no repository clone or build is needed. Follow its language guide for runtime requirements and settings.
- **Current NetScaler binary:** follow the [CI artifact download steps](go/legacy/README.md#download-and-select) to get a prebuilt package. Local compilation is optional.
- **Published v1.0.1 Go binaries:** use the [matching Go guide](https://github.com/NextronSystems/thunderstorm-collector/blob/v1.0.1/go/README.md).

## Quick Start

For the **Linux amd64 Go package from v1.0.1**, download the archive from [Releases](https://github.com/NextronSystems/thunderstorm-collector/releases/tag/v1.0.1), extract it, and enter the package directory:

```sh
tar -xzf thunderstorm-collector-1.0.1-amd64-linux.tar.gz
cd thunderstorm-collector-amd64-linux
```

Start collecting by supplying just your Thunderstorm server's hostname or IP address:

```sh
./amd64-linux-thunderstorm-collector -s thunderstorm.example.internal
```

Replace `thunderstorm.example.internal` with your server. The collector automatically loads `config.yml` from the **current directory**, uses its file filters and limits, and uploads matching readable files. With the bundled configuration, collection starts at `/` on Linux/Unix or `C:\` on Windows; HTTP port **8080** and the local hostname as the source name are already the defaults. No other options or configuration edits are needed for that setup.

### Save the server once

For repeated use, add this line to the **existing** `config.yml`, keeping its filters and other settings:

```yaml
thunderstorm-server: thunderstorm.example.internal
```

Then, from the package directory, simply run:

```sh
./amd64-linux-thunderstorm-collector
```

The server setting can be supplied in YAML or with `-s`; it does not need to be specified in both places. Use a hostname or IP only; HTTPS and non-default ports have separate settings below.

### Optional preview

To see which files would be uploaded without contacting the server:

```sh
./amd64-linux-thunderstorm-collector --dry-run --debug
```

Normal runs upload files by default. `--dry-run=false` is only needed when overriding `dry-run: true` in a loaded configuration, such as a preview-enabled assessment profile.

### Common command-line and YAML settings

Command-line options override YAML settings. **Only the server address is required for uploads**, and it can be stored in `config.yml`. Everything else below is optional. The defaults shown assume the bundled configuration is loaded.

| Setting | Command-line option | YAML key | Default / when to change it |
| --- | --- | --- | --- |
| Server | `-s HOST` / `--thunderstorm-server HOST` | `thunderstorm-server` | Required for uploads, in YAML or on the command line; unnecessary for a preview. |
| Configuration file | `-t FILE` / `--template FILE` | — | Automatically reads `config.yml` in the current directory. Use `-t` for another file or location. |
| Collection directories | `-p DIR` / `--path DIR` | `path` | `/` on Unix, `C:\` on Windows. Override only to change the scope. |
| Server port | `--port PORT` | `port` | `8080`. |
| HTTPS | `--ssl` | `ssl` | `false` (HTTP). Enabling HTTPS does not change the port automatically. |
| Custom CA certificate | `--ca FILE` | `ca` | Uses system trust by default; set for a custom CA. |
| Source name | `-o NAME` / `--source NAME` | `source` | The local hostname. |
| Maximum file size | `-m MiB` / `--max-filesize MiB` | `max-filesize` | **64 MiB** per file. |
| Maximum file age | `-a 7d` / `--max-age 7d` | `max-age` | No age cutoff. In YAML, `max-age: ""` disables the cutoff; `"0"` does not. |
| Preview only | `--dry-run` | `dry-run` | `false`: files are uploaded. Set `true` to preview. |
| Verbose output | `--debug` | `debug` | `false`. Add to a preview to list filenames and skip reasons. |
| Wait for analysis results | `--upload-synchronous` | `upload-synchronous` | `false`: asynchronous uploads. Check results on the server. |
| Upload workers | `-r N` / `--threads N` | `threads` | `1`. |
| Upload rate limit | `--uploads-per-minute N` | `uploads-per-minute` | `0`: no rate limit. |

List-valued YAML settings use lists, for example `path: ["/var/www", "/home"]` or `ca: ["/path/to/ca.pem"]`. The first `--path` replaces the default or configured directory list; repeat it to add more roots. To adjust extension/magic filters or exclusions, see the [Go configuration guide](go/README.md#configuration-files). Use `--help` or the [full Go option reference](go/README.md#usage) for all flags.

These settings apply to the **Go collector**. Script collectors have their own defaults and option names; use the selected [language guide](scripts/README.md). For an assessment profile, follow its guide and load its configuration with `-t`.

## Product Integration Guides

[Product integration guides](integration-guides/Readme.md) describe deployment, networking, and recurring collection on particular systems. The existing [ESXi 7 without Secure Boot guide](integration-guides/esxi/esxi7-wo-secure-boot.md) covers a persistent Python deployment. Start with the current [ESXi collector requirements and quick start](scripts/README.md#vmware-esxi-use-the-python-collector) before scheduling collection.

## Testing and Compatibility

- [Testing overview](docs/COLLECTOR_TESTING_OVERVIEW.md): automated checks, local HTTP/HTTPS test backends, runtime coverage, and commands for running focused tests.
- [Script acceptance report, 8 October 2026](docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md): real-THOR results for the exact revisions and assets recorded there, plus remaining checks.
- [NetScaler compatibility and FreeBSD VM evidence](go/README.md#citrix-netscaler-and-freebsd-84): the tested legacy binary, OS versions, and the FreeBSD 14.3 ASLR note.

Automated checks and recorded VM/runtime tests have specific scopes. Confirm the collector and collection profile on the intended product and firmware; each guide identifies remaining target-system validation.

## Build or Extend a Collector

Downloaded binaries and standalone scripts can be run directly; building is optional. For source builds, follow the [Go build requirements](go/README.md#build-requirements). From the repository root, choose the target you need; these commands are independent:

```sh
make -C go           # Build the Go collector for the current platform
make release-scripts # Package individual script assets
make release         # Package all regular targets supported by the installed Go compiler, plus scripts
make help            # List available targets
```

A current-platform build writes its executable to `go/bin/`. To use the packaged filters, pass `-t go/config.yml` when running it from the repository root. Regular binary archives are created in `go/dist/`; versioned release assets are assembled locally in `release/`. `make release` prepares files locally; publishing is handled by the tagged workflow below. The dedicated NetScaler package has a separate [legacy build procedure](go/legacy/README.md). The [tagged-release workflow](.github/workflows/release.yml) builds both regular and legacy packages, verifies the required assets, and publishes them with checksums after its required jobs succeed.

To add a language or platform, follow the [collector construction guide](docs/COLLECTOR_CONSTRUCTION_GUIDE.md). It covers the upload protocol, optional features, resource limits, acceptance tests, and a reusable coding-agent assignment. The separate [thunderstormAPI Python library](https://github.com/NextronSystems/thunderstormAPI) is another resource for custom integrations.
