# Emerging threat collection profiles

These profiles configure existing Thunderstorm collectors for product-specific assessments. They select files to send to Thunderstorm; detection happens on the server using its installed signatures. They are not IOC or YARA rule sets, and a collection without findings does not establish that a system is clean.

| Product | Profile | Execution |
| --- | --- | --- |
| Citrix NetScaler | [Broad file assessment](citrix-netscaler/README.md) | Go YAML configuration and header settings for the existing Bash collector |

Profiles are distributed as repository files. Adding a profile does not change the default configuration in binary packages or add a release asset. Check each profile's documented scope and test status before using it.
