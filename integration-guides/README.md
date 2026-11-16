# Product Integration Guides

Deployment, networking and recurring collection on specific products and
platforms. To choose a collector and check its prerequisites first, see the
[main README](../README.md) and the
[platform recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md).
Last reviewed: **20 October 2026**.

## Platform Guides

| Guide | Approach | Status |
| --- | --- | --- |
| [Fortinet FortiGate / FortiOS](fortinet/fortigate-export-thor-lab.md) | Export configurations, logs and diagnostics through the GUI or CLI, then scan them on Linux with THOR Lab | **Not yet tested** on a live appliance |
| [VMware ESXi 7 without Secure Boot](esxi/esxi7-wo-secure-boot.md) | Persistent Python collector started from cron | **Not yet tested** with the current collector¹ |
| [IBM AIX on POWER7](aix/aix-power7-sshfs-scanning.md) | THOR on a Linux workstation reads the host over SSHFS; nothing runs on AIX | **Not yet tested** on a live AIX/POWER7 host |
| [Citrix NetScaler ADC and Gateway](citrix/netscaler-collection-and-scanning.md) | Go or Bash collector on the appliance, the SFTP collector, THOR over SSHFS, or a support archive scanned with THOR Lab | **VM-tested** (FreeBSD); not yet tested on named NetScaler firmware² |

1. Earlier Python collector revisions ran on ESXi; the versions were not
   recorded. See the [ESXi quick start](../scripts/README.md#vmware-esxi-use-the-python-collector).
2. The legacy Go build was tested in FreeBSD 8.4 and 14.3 VMs and the Bash
   preset with synthetic files. The SSHFS route follows Nextron's published
   procedure. Paths and configuration come from the
   [NetScaler assessment profile](../emerging-threats/citrix-netscaler/README.md).

The FortiGate guide is based on Fortinet and THOR documentation; the AIX guide
on IBM and upstream documentation.

Other products, including appliances that cannot run a collector, are covered
by the [collector recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md), which
separate candidate combinations from recorded tests.

## Choose an Approach First

Decide how to scan before setting up a persistent collector:

| Situation | Approach |
| --- | --- |
| Ad hoc assessment, SSH/SFTP access available | **SSHFS**: THOR on an analysis workstation reads the files; nothing is installed on the source |
| Only SSH/SFTP, files collected selectively or repeatedly | The prototype [SFTP collector](../sftp/README.md) pulls selected files and sends them to Thunderstorm |
| Recurring collection where the source can run a collector | A persistent Thunderstorm collector, as in the platform guides above |

[Choosing a THOR scanning approach](../docs/SCANNING_APPROACHES.md) compares
native scans, SSHFS, Thunderstorm collectors and offline evidence analysis,
including prerequisites and licensing.

## Where Documentation Lives

| Location | Content |
| --- | --- |
| `integration-guides/<platform>/` | Running Thunderstorm collection, or an alternative such as SSHFS or exported evidence, on one platform |
| [`emerging-threats/`](../emerging-threats/README.md) | Time-bound collection profiles for a named assessment, such as the NetScaler profile |
| [`docs/`](../docs/) | Cross-cutting references: scanning approaches, collector recommendations, the [collection orchestrator](../docs/COLLECTION_ORCHESTRATOR.md) for scheduled runs on many devices, construction guide, testing overview, acceptance report |
| [`go/`](../go/README.md), [`scripts/`](../scripts/README.md) and [`sftp/`](../sftp/README.md) | Reference for each collector: options, requirements and compatibility evidence |

## Related Nextron repositories

These repositories already submit files to Thunderstorm from other places, or
help test and run it. Check them before building a new integration. Each
defines its own scope and support; this repository does not test them.

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

For assessment-specific file paths and collector configurations, use the
[Emerging Threats profiles](../emerging-threats/README.md).
