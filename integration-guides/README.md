# Product Integration Guides

These guides cover deployment, networking, and recurring collection on specific products and platforms. Start with the [main README](../README.md) and [platform recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md) to choose a collector and check its prerequisites. Last reviewed: **20 October 2026**.

Choose an approach before setting up a persistent collector. For an ad-hoc
assessment, **SSHFS** can expose files to THOR on an analysis workstation without
installing a scanner or collector on the source, provided suitable SSH/SFTP
access is available. [Choosing a THOR scanning approach](../docs/SCANNING_APPROACHES.md)
compares native scans, SSHFS, Thunderstorm collectors and offline evidence
analysis, including prerequisites and licensing. Where only SSH/SFTP is
available and files should be collected selectively or repeatedly, the
prototype [SFTP collector](../sftp/README.md) pulls the selected files from
another system and sends them to Thunderstorm.

## Platform guides

| Platform | Approach | Guide | Evidence |
| --- | --- | --- | --- |
| VMware ESXi 7 without Secure Boot | Persistent Python collector started from cron | [ESXi 7 without Secure Boot](esxi/esxi7-wo-secure-boot.md) | Earlier Python collector revisions ran on ESXi; versions were not recorded, and the current collector still needs validation there. See the [ESXi quick start](../scripts/README.md#vmware-esxi-use-the-python-collector). |
| IBM AIX on POWER7 | THOR on a Linux analysis workstation reads the host over SSHFS; nothing runs on AIX | [AIX on POWER7 via SSHFS](aix/aix-power7-sshfs-scanning.md) | Prepared from IBM and upstream documentation; not tested against a live AIX/POWER7 host. |
| Citrix NetScaler | Collection profile for the Go or Bash collector, kept with the [Emerging Threats profiles](../emerging-threats/README.md) | [NetScaler assessment profile](../emerging-threats/citrix-netscaler/README.md) | Legacy Go build tested in FreeBSD 8.4 and 14.3 VMs; Bash preset tested with synthetic files; named NetScaler firmware not yet tested. |

Other products, including appliances that cannot run a collector, are covered by the [collector recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md), which separates candidate combinations from recorded tests.

## Where documentation lives

| Location | Content |
| --- | --- |
| `integration-guides/<platform>/` | Running Thunderstorm collection, or an alternative such as SSHFS, on one platform |
| [`emerging-threats/`](../emerging-threats/README.md) | Time-bound collection profiles for a named assessment, such as the NetScaler profile |
| [`docs/`](../docs/) | Cross-cutting references: scanning approaches, collector recommendations, construction guide, testing overview, acceptance report |
| [`go/`](../go/README.md), [`scripts/`](../scripts/README.md) and [`sftp/`](../sftp/README.md) | Reference for each collector: options, requirements and compatibility evidence |

## Related Nextron repositories

These repositories already submit files to Thunderstorm from other places, or help test and run it. Check them before building a new integration. Each repository defines its own scope and support; this repository does not test them.

| Repository | Use it for |
| --- | --- |
| [thunderstormAPI](https://github.com/NextronSystems/thunderstormAPI) | A Python module and the `thunderstorm-cli` client for submitting files and reading status and results from your own scripts |
| [scanning-containers](https://github.com/NextronSystems/scanning-containers) | Guides and scripts for scanning container images and running containers, including AWS, with THOR or Thunderstorm |
| [postfix2thunderstorm](https://github.com/NextronSystems/postfix2thunderstorm) | A Postfix milter that scans incoming mail with Thunderstorm's synchronous `/api/check` endpoint and can hold mail on the verdict |
| [thunderstorm-stub-server](https://github.com/Nextron-Labs/thunderstorm-stub-server) | A minimal Thunderstorm-compatible test server for collectors and API clients; this repository's script collector CI runs against it |
| [thunderstorm-deployment](https://github.com/NextronSystems/thunderstorm-deployment) | A container image and Compose file that run the Thunderstorm service itself; not a collector |
| [nextron-helper-scripts: thunderstorm](https://github.com/NextronSystems/nextron-helper-scripts/tree/master/thunderstorm) | Installer and update scripts for the Thunderstorm service |
| [Thunderstorm setup guide](https://thor-thunderstorm-setup-guide.nextron-systems.com/en/latest/) | The official documentation, including the collectors and the API client |

Integrations that run THOR itself rather than Thunderstorm:

| Repository | Use it for |
| --- | --- |
| [velociraptor-artifacts-thor](https://github.com/NextronSystems/velociraptor-artifacts-thor) | Velociraptor artifacts that run THOR on endpoints |
| [thor-microsoft-defender-guide](https://github.com/NextronSystems/thor-microsoft-defender-guide) | The THOR integration guide for Microsoft Defender |
| [veeam-integration](https://github.com/NextronSystems/veeam-integration) | Scanning Veeam Backup & Replication restore points with THOR |

For assessment-specific file paths and collector configurations, use the [Emerging Threats profiles](../emerging-threats/README.md).
