# Citrix NetScaler assessment profile

[All assessment guides](../README.md) · [Collector recommendations](../../docs/COLLECTOR_RECOMMENDATIONS.md) · [Collector downloads](../../README.md#download-a-collector)

Reviewed **2026-10-11**. This profile selects a broad set of NetScaler files for submission to Thunderstorm. Detection uses the server's installed signatures. The profile contains a **Go configuration** and **header settings for the existing Bash collector**.

## Choose the collector first

Use the [NetScaler selection steps](../../go/README.md#choose-a-collector-for-your-netscaler) to identify the firmware/build, underlying OS and CPU. The dedicated Go binary targets confirmed FreeBSD 8.4/amd64; the [Bash preset below](#option-2-existing-bash-collector) is an alternative when its requirements are met. FreeBSD 14.3 appears in the Go test record as a VM environment, not as a NetScaler version boundary. Actual firmware validation remains pending for both options.

## Collection scope

Walk these directories recursively, including hidden files and subdirectories, subject to the collectors' exclusions, access permissions, and file-size limit:

| Root | Purpose |
| --- | --- |
| `/netscaler` | Appliance and web content, including `logon`, `portal`, `gui`, and `ns_gui`. Keep `admin_ui` and `websocketd` in scope; detection-rule exceptions are not collection exclusions. |
| `/netscaler.local` | Locally placed scripts and other files. |
| `/var` | Top-level files plus all subdirectories, including `vpn`, `netscaler`, `tmp`, `core`, logs, and staging areas. |
| `/nsconfig`, `/flash/nsconfig` | Configuration, startup scripts, and cron persistence. See the different symlink handling below. |
| `/tmp`, `/etc` | Temporary staging and system configuration/persistence. |

Collect **all regular file types**, with **no age cutoff** and a **64 MiB per-file limit**. An extension allowlist could miss hidden files, extensionless payloads, and unusual suffixes such as `.1`, `.state`, or `.receiver`. Do not copy IOC limits on basename length or nesting depth into the collection settings.

This broad scope includes ordinary logs and potentially sensitive configuration, certificates, and keys. Review a preview before uploading. Oversized files are skipped, not truncated; increase the limit for a planned large-file collection and check server limits. Neither option imposes a total-byte budget.

## Option 1: Go collector

Select a compatible binary using the [NetScaler package and compatibility guide](../../go/README.md#citrix-netscaler-and-freebsd-84). The examples below use the dedicated **FreeBSD 8.4 amd64 / Go 1.9.7** executable. For source builds, follow the [legacy build guide](../../go/legacy/README.md).

Save this profile's [config.yml](config.yml) as `netscaler-assessment.yml` beside the selected executable. This keeps the assessment configuration separate from the package's default `config.yml`. Preview with the assessment file:

```sh
./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-assessment.yml --dry-run
```

After reviewing the preview, supply your endpoint and appliance name:

```sh
./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-assessment.yml \
  --dry-run=false --thunderstorm-server thunderstorm.example.org \
  --port 8080 --source netscaler-example
```

The configuration defaults to preview mode, one worker, and at most 120 upload starts per minute. `max-age: ""` disables age filtering; `"0"` does not. Empty `extension` and `magic` lists select all regular file types. See the [Go CLI reference](../../go/README.md#usage) for HTTPS and other connection options.

Go does not follow symbolic links, including root-directory links. The profile therefore includes `/flash/nsconfig` explicitly as a common physical location. Inspect the actual layout and add other physical targets when necessary. `--path` replaces the configured root list; repeat it for every desired root when overriding, including for an externally mounted appliance filesystem.

## Option 2: Existing Bash collector

Use the existing [Bash collector](../../scripts/bash/thunderstorm-collector.sh) and its [usage and configuration guide](../../scripts/bash/README.md). Keep the collector maintained in its normal location; adjust a deployment copy for the appliance instead of maintaining another complete collector in this folder.

The script runs independently and reads its own header settings, not the Go YAML file. Confirm the [Bash runtime and upload requirements](../../scripts/bash/README.md#requirements) on the target; NetScaler's FreeBSD shell does not establish that Bash is installed. This preset is not a claim of appliance compatibility.

Replace the corresponding existing variable assignments in the script's header with these values. Some assignments are in its filesystem-exclusion section. Do not prepend a block while leaving later defaults to overwrite it. Set your actual endpoint and source name:

```bash
THUNDERSTORM_SERVER="thunderstorm.example.org"
THUNDERSTORM_PORT=8080
USE_SSL=0
INSECURE=0
CA_CERT=""
SOURCE_NAME="netscaler-example"

SCAN_FOLDERS=('/netscaler' '/netscaler.local' '/var' '/nsconfig' '/tmp' '/etc')
MAX_AGE=0
MAX_FILE_SIZE_KB=65536
DEBUG=1
DRY_RUN=1
RETRIES=3
LOG_TO_FILE=0

# Do not omit NetScaler evidence because a directory has a cloud-service name.
CLOUD_DIR_NAMES=""
CLOUD_DIR_NAMES_SPACED=""
CLOUD_DIR_PATTERNS=""
```

The Bash collector already collects all regular file types; no extension or magic-header setting is needed. `MAX_AGE=0` disables its age filter, and 65536 KiB equals 64 MiB. Uploads are sequential; this version has no setting equivalent to Go's 120 uploads/minute limit. Keep the existing pseudo-filesystem exclusions and other implementation settings. Clearing the cloud-name lists does not remove the script's built-in `Library/CloudStorage` exclusion.

Bash resolves explicit root-directory symlinks, so `/nsconfig` covers `/flash/nsconfig` when it points there. Do not add both aliases: overlapping roots can duplicate uploads. If the real configuration directory is elsewhere, substitute it. Confirm roots exist and are readable; missing roots make the run report an error. Remove roots confirmed absent on that appliance, and investigate unexpectedly missing paths.

Run the edited deployment copy with Bash:

```bash
bash ./thunderstorm-collector.sh --dry-run --no-progress
```

After reviewing the preview, explicitly override the preview default for this invocation:

```bash
bash ./thunderstorm-collector.sh --no-dry-run --no-progress
```

The header can remain at **`DRY_RUN=1`**. There is no Bash `--dry-run=false` option. Use the [Bash guide](../../scripts/bash/README.md) for HTTPS settings and retain certificate verification. An explicit `--dir` replaces the header's root list, with additional `--dir` arguments adding roots.

## Coverage and validation

Avoid overlapping physical roots in either collector: files reached through multiple roots can be uploaded more than once. Both collectors skip symlinks encountered inside directory trees. Inspect physical paths and mounts on the appliance. Bash's automatic mount discovery uses Linux `/proc/mounts`; Go's filesystem-type filtering is not implemented on FreeBSD. Neither therefore guarantees exclusion of network/special mounts on NetScaler. Use known local roots and explicit path exclusions where needed (`exclude` in Go, `EXCLUDE_PATHS` in Bash).

Go can silently skip missing roots and directory-walk permission errors. Bash reports missing/inaccessible roots and incomplete scans. Review actual filenames and coverage, not just the final success count. A live file collection is not a snapshot and does not collect deleted files, process memory, or network state.

The legacy Go binary has separate [reported FreeBSD 8.4 and 14.3 VM tests](https://github.com/NextronSystems/thunderstorm-collector/pull/51#issuecomment-6056935463). Those predate this profile and do not validate its appliance coverage. The reported FreeBSD 14.3 test needed ASLR disabled for that invocation; the 8.4 test did not.

Local Go profile validation on 2026-10-09 used source `d0b05d6b37b9dd26363c6bed6463c0ea2b36c488`, Go 1.26.0, and macOS arm64. Remapped synthetic roots selected 28 small fixtures and an exactly 64 MiB file in preview, with no HTTP requests; larger files and special/symlink entries were skipped. A local HTTP receiver verified all 28 small uploads byte for byte. This was not a real THOR or TLS test.

The exact Bash header assignments above were applied to PR #44 revision `d645a00` and checked with Bash 3.2 on macOS. With only the roots remapped, a synthetic dry run selected 11 eligible files, skipped one oversized file, and reported zero failures or scan errors. Old timestamps, hidden and unexpected file types, deep paths, a cloud-named directory, and a root symlink were covered; the configuration directory was collected once. Those 2026-10-09 checks did not include an actual appliance or a live Bash upload.

Revalidation on **2026-10-11** used [collector source `35a8509`](https://github.com/NextronSystems/thunderstorm-collector/tree/35a8509d943778e6e3b2b341125ed6b9c94ea945), Go 1.21.0, Bash 3.2.57, and macOS arm64. The local Go verification binary used the macOS external linker and an ad-hoc signature. The supplied YAML and the Bash header settings were exercised with synthetic roots: previews made no HTTP requests, and explicit live overrides uploaded 14 Go fixtures and 13 Bash fixtures to a loopback HTTP receiver. Every payload's SHA-256 matched its source file. The one-file difference was Bash's retained `Library/CloudStorage` exclusion.

These checks covered old timestamps, hidden and extensionless files, unusual suffixes, binary bytes, a cloud-named directory, and configuration-root symlink handling. Exactly 64 MiB was included; 64 MiB plus one byte, internal symlinks, and a FIFO were excluded. CLI root overrides selected only the replacement directory in both collectors. This was not an actual NetScaler, real THOR, HTTPS, or Go 1.9.7 runtime test.

The Go profile and Bash preset still require an actual NetScaler preview and a controlled upload with the intended server. Private IOC definitions, scores, and infrastructure indicators are not distributed here.

## Sources for scope

- [Arctic Wolf NetScaler report](https://github.com/rtkwlf/wolf-tools/tree/main/pack_alerts/202609-citrix-netscaler-active-exploitation-cve-2026-88771): staging under `/var`, hidden state under `/var/tmp`, and cron persistence in `/etc` and `/nsconfig`.
- [NetScaler data collection guidance](https://support.citrix.com/external/article/CTX109304/data-collection-procedure-to-troubleshoo.html): older-release configuration under `/flash/nsconfig` and logs under `/var/nslog`.
- [NetScaler CLI `shell` reference](https://developer-docs.netscaler.com/en-us/adc-command-reference-int/current-release/utility/shell.html): entry into the FreeBSD shell.
