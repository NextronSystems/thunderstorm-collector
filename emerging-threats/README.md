# Emerging Threats: assessment guides and collection profiles

[Repository guide](../README.md) · [Collector recommendations](../docs/COLLECTOR_RECOMMENDATIONS.md)

These profiles configure existing Thunderstorm collectors for product-specific assessments. They select files to send to Thunderstorm; detection happens on the server using its installed signatures. They are not IOC or YARA rule sets, and a collection without findings does not establish that a system is clean.

| Product | Assessment guide | Configuration |
| --- | --- | --- |
| Citrix NetScaler | [Broad file assessment](citrix-netscaler/README.md) | [Go YAML configuration](citrix-netscaler/config.yml) and header settings for the existing Bash collector |

Download profile files separately from the collector; they do not change packaged defaults or add release assets. See the [repository download guide](../README.md#download-a-collector) for published collectors and current source. Check each assessment guide's scope and validation status before using its profile.
