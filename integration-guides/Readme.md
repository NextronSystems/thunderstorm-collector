# Product Integration Guides

These guides cover deployment, networking, and recurring collection on specific products. Start with the [main README](../README.md) and [platform recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md) to choose a collector and check its prerequisites.

Choose an approach before setting up a persistent collector. For an ad-hoc
assessment, **SSHFS** can expose files to THOR on an analysis workstation without
installing a scanner or collector on the source, provided suitable SSH/SFTP
access is available.

- [Choosing a THOR scanning approach](../docs/SCANNING_APPROACHES.md) — Native
  scans, SSHFS, Thunderstorm collectors and offline evidence analysis, including
  prerequisites and licensing.
- [AIX on POWER7 via SSHFS](../docs/AIX_POWER7_SSHFS_SCANNING.md) — A quick path-allowlist
  scan for incident response, plus a thorough procedure with mount inventory
  and exclusions.

- [ESXi 7 without Secure Boot](esxi/esxi7-wo-secure-boot.md): persistent Python collection, with the current [ESXi quick start](../scripts/README.md#vmware-esxi-use-the-python-collector) as the first validation step.

For assessment-specific file paths and collector configurations, use the separate [Emerging Threats profiles](../emerging-threats/README.md).
