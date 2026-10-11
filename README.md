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

For appliances and infrastructure platforms, start with the **[collector recommendations by product and platform](docs/COLLECTOR_RECOMMENDATIONS.md)**. The table covers Nutanix, VMware, Cisco, F5, Kubernetes, Amazon Linux, and Citrix NetScaler, including runtime prerequisites and available test evidence. For VMware ESXi, see the [Python quick start](scripts/README.md#vmware-esxi-use-the-python-collector); for older NetScaler systems, check the [dedicated FreeBSD 8.4 package guidance](go/README.md#citrix-netscaler-and-freebsd-84).

## Emerging Threats: Assessment Guides and Collection Profiles

Use the [Emerging Threats guides](emerging-threats/README.md) to choose the files and directories to collect for a particular assessment. Profiles configure existing collectors; analysis uses the signatures installed on the Thunderstorm server.

| Assessment | Guide and configuration |
| --- | --- |
| **Citrix NetScaler** | [Broad assessment guide](emerging-threats/citrix-netscaler/README.md), with a [Go configuration](emerging-threats/citrix-netscaler/config.yml) and presets for the existing Bash collector. |

Each guide documents its scope, limits, execution requirements, and validation status. Profiles are repository files downloaded separately from release packages. Go uses the profile's YAML file; the Bash preset is applied to the script's configuration header.

## Download a Collector

Use [Releases](https://github.com/NextronSystems/thunderstorm-collector/releases) for published versions. Select the asset matching your OS and architecture, and follow the documentation for that release.

- **Go packages** contain the executable and a default `config.yml`. Windows packages use ZIP; other platforms use `.tar.gz`. The standalone `config-<version>.yml` asset is an additional copy of that configuration.
- **Script assets** are individual, versioned files. Download the selected collector and check its runtime requirements. Each script runs independently; the repository's test harness is not required on the target.

**Release availability, 11 October 2026:** v1.0.1 is the latest published release; v1.0.2 has not been published. The revised script collectors, additional legacy script variants, and dedicated NetScaler package described on `master` are newer than v1.0.1. For those scripts, use the current [source and language guides](scripts/README.md); for the NetScaler binary, follow the [legacy build and artifact instructions](go/legacy/README.md). The [v1.0.1 Go guide](https://github.com/NextronSystems/thunderstorm-collector/blob/v1.0.1/go/README.md) documents the published binary release.

## Quick Start

This example uses the **Linux amd64 Go package from v1.0.1**. Download it from Releases and extract it:

```sh
tar -xzf thunderstorm-collector-1.0.1-amd64-linux.tar.gz
cd thunderstorm-collector-amd64-linux
```

Review `config.yml` for the file filters and limits. Replace `/absolute/path/to/files` with an existing directory you intend to collect. Preview the selected filenames before uploading:

```sh
./amd64-linux-thunderstorm-collector -t ./config.yml \
  --path /absolute/path/to/files --dry-run --debug
```

After checking the selection, supply your server and a source name identifying the collecting system:

```sh
./amd64-linux-thunderstorm-collector -t ./config.yml \
  --path /absolute/path/to/files --dry-run=false \
  --thunderstorm-server thunderstorm.example.internal \
  --port 8080 --source host-example
```

`--path` replaces the configuration's directory list; repeat it for multiple roots. For an assessment profile, follow its guide and pass its configuration with `-t`. For HTTPS, add `--ssl`, select the endpoint's port, and use `--ca /path/to/ca.pem` if a custom CA is required. See the [Go configuration guide](go/README.md#configuration-files) for the remaining options.

For scripts, follow the selected [language guide](scripts/README.md) to configure and preview the collection using its header settings, command-line options, or environment variables. Scripts use their own settings rather than the Go YAML file. Uploads are asynchronous by default in the examples above; check received files and analysis results on the server after collection.

## Product Integration Guides

[Product integration guides](integration-guides/Readme.md) describe deployment, networking, and recurring collection on particular systems. The existing [ESXi 7 without Secure Boot guide](integration-guides/esxi/esxi7-wo-secure-boot.md) covers a persistent Python deployment. Start with the current [ESXi collector requirements and quick start](scripts/README.md#vmware-esxi-use-the-python-collector) before scheduling collection.

## Testing and Compatibility

- [Testing overview](docs/COLLECTOR_TESTING_OVERVIEW.md): automated checks, local HTTP/HTTPS test backends, runtime coverage, and commands for running focused tests.
- [Script acceptance report, 8 October 2026](docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md): real-THOR results for the exact revisions and assets recorded there, plus remaining checks.
- [NetScaler compatibility and FreeBSD VM evidence](go/README.md#citrix-netscaler-and-freebsd-84): the tested legacy binary, OS versions, and the FreeBSD 14.3 ASLR note.

Automated checks and recorded VM/runtime tests have specific scopes. Confirm the collector and collection profile on the intended product and firmware; each guide identifies remaining target-system validation.

## Build or Extend a Collector

From the repository root, use the [Go build instructions](go/README.md#build) and these targets:

```sh
make -C go           # Build the Go collector for the current platform
make release-scripts # Package individual script assets
make release         # Build regular Go packages and script assets
make help            # List available targets
```

Regular binary archives are created in `go/dist/`; versioned release assets are assembled in `release/`. The dedicated NetScaler package has a separate [legacy build procedure](go/legacy/README.md). The [tagged-release workflow](.github/workflows/release.yml) builds both regular and legacy packages, verifies the required assets, and publishes them with checksums after its required jobs succeed.

To add a language or platform, follow the [collector construction guide](docs/COLLECTOR_CONSTRUCTION_GUIDE.md). It covers the upload protocol, optional features, resource limits, acceptance tests, and a reusable coding-agent assignment. The separate [thunderstormAPI Python library](https://github.com/NextronSystems/thunderstormAPI) is another resource for custom integrations.
