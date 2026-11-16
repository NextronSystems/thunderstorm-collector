# Emerging Threats: Assessment Guides and Collection Profiles

[Repository guide](../README.md) · [Collector recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md)

These profiles configure existing collectors for product-specific assessments.
Pick a product, read its guide's scope and validation status, then use its
profile.

| Product | Assessment guide | Configuration |
| --- | --- | --- |
| Citrix NetScaler | [Broad file assessment](citrix-netscaler/README.md) | [Go YAML configuration](citrix-netscaler/config.yml) and header settings for the existing Bash collector |

- **What a profile does:** it selects files to send to Thunderstorm. Detection
  happens on the server with its installed signatures.
- **What it is not:** an IOC or YARA rule set. A collection without findings
  does not mean a system is clean.
- **Downloads:** profile files are separate from the collectors. They do not
  change packaged defaults or add release assets. See the
  [repository download guide](../README.md#download-a-collector) for
  published collectors and current source.
