# Citrix NetScaler: Broad File Assessment

[All assessment guides](../README.md) · [NetScaler integration guide](../../integration-guides/citrix/netscaler-collection-and-scanning.md) · [Collector recommendations](../../docs/COLLECTOR_RECOMMENDATIONS.md) · [Collector downloads](../../README.md#download-a-collector)

This profile selects a broad set of NetScaler files and sends them to
Thunderstorm, which analyzes them with its installed signatures. It comes as a
**Go configuration** ([config.yml](config.yml)) and as **header settings for the
existing Bash collector**. Reviewed **2026-10-11**.

> [!NOTE]
> Both options are tested with synthetic files on macOS. **Not yet tested** on
> NetScaler firmware, against a real THOR server or over HTTPS.
> [Validation record](TESTING.md)

## Before You Start

1. **Choose the collector.** Follow the
   [NetScaler selection steps](../../go/README.md#choose-a-collector-for-your-netscaler)
   to identify the firmware build, the underlying OS and the CPU.
   - **Go ([option 1](#option-1-go-collector)):** the dedicated binary targets
     confirmed **FreeBSD 8.4 on amd64**.
   - **Bash ([option 2](#option-2-existing-bash-collector)):** an alternative
     when its requirements are met.

   FreeBSD 14.3 appears in the Go test record as a VM environment, not as a
   NetScaler version boundary.
2. **Plan access and runs.** The
   [NetScaler integration guide](../../integration-guides/citrix/netscaler-collection-and-scanning.md)
   covers access, running a collector on each node, repeat runs and the routes
   that run nothing on the appliance.
3. **Plan to review a preview.** Both options start in preview mode. Check the
   file list before you upload.

## Collection Scope

Both options walk these directories recursively, including hidden files and
subdirectories, within the collectors' exclusions, access permissions and
file-size limit:

| Root | Purpose |
| --- | --- |
| `/netscaler` | Appliance and web content, including `logon`, `portal`, `gui` and `ns_gui`. Keep `admin_ui` and `websocketd` in scope; detection-rule exceptions are not collection exclusions. |
| `/netscaler.local` | Locally placed scripts and other files |
| `/var` | Top-level files and all subdirectories, including `vpn`, `netscaler`, `tmp`, `core`, logs and staging areas |
| `/nsconfig`, `/flash/nsconfig` | Configuration, startup scripts and cron persistence; symlink handling differs per option |
| `/tmp`, `/etc` | Temporary staging and system configuration or persistence |

Settings:

- **All regular file types.** An extension allowlist could miss hidden files,
  extensionless payloads and unusual suffixes such as `.1`, `.state` or
  `.receiver`.
- **No age cutoff.**
- **64 MiB per file.** Larger files are skipped, not truncated. For a planned
  large-file collection, raise the limit and check the server's limits.
- **No total-byte budget** in either option.
- Do not copy IOC limits on basename length or nesting depth into the
  collection settings.

> [!WARNING]
> This scope includes ordinary logs and potentially sensitive configuration,
> certificates and keys. Review the preview before uploading.

## Option 1: Go collector

1. Select a compatible binary with the
   [NetScaler package and compatibility guide](../../go/README.md#citrix-netscaler-and-freebsd-84).
   The examples use the dedicated **FreeBSD 8.4 amd64 / Go 1.9.7** executable.
   For source builds, follow the [legacy build guide](../../go/legacy/README.md).
2. Save this profile's [config.yml](config.yml) as `netscaler-assessment.yml`
   beside the executable. This keeps it apart from the package's default
   `config.yml`.
3. Preview:

   ```sh
   ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-assessment.yml --dry-run
   ```

4. After reviewing the preview, upload with your server and appliance name:

   ```sh
   ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-assessment.yml \
     --dry-run=false --thunderstorm-server thunderstorm.example.internal \
     --port 8080 --source netscaler-example
   ```

For HTTPS and other connection options, see the
[Go CLI reference](../../go/README.md#usage).

What the configuration sets:

- Preview mode, one worker, and at most **120 upload starts per minute**.
- `max-age: ""` disables age filtering; `"0"` does **not**.
- Empty `extension` and `magic` lists select all regular file types.

Roots:

- Go does not follow symbolic links, including links given as roots. The
  profile therefore lists `/flash/nsconfig`, a common physical location,
  explicitly. Inspect the actual layout and add other physical targets when
  necessary.
- `--path` replaces the configured root list. When overriding, repeat it for
  every root you want, including for an externally mounted appliance
  filesystem.

## Option 2: Existing Bash collector

The preset adjusts the existing
[Bash collector](../../scripts/bash/thunderstorm-collector.sh); see its
[usage and configuration guide](../../scripts/bash/README.md). The script reads
its own header settings, not the Go YAML file. This preset is not a claim of
appliance compatibility.

1. **Check the requirements.** Confirm the
   [Bash runtime and upload requirements](../../scripts/bash/README.md#requirements)
   on the target. NetScaler's FreeBSD shell does not mean that Bash is
   installed.
2. **Make a deployment copy** of the script for the appliance. Keep the
   collector itself in its normal location; do not maintain another complete
   collector in this folder.
3. **Edit the header.** Replace the matching existing assignments with these
   values; some are in the filesystem-exclusion section. Do not prepend a
   block, because later defaults would overwrite it. Set your server and source
   name:

   ```bash
   THUNDERSTORM_SERVER="thunderstorm.example.internal"
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

4. **Check the roots.** Bash resolves root directories given as symlinks, so
   `/nsconfig` covers `/flash/nsconfig` when it points there.
   - Do not add both aliases: overlapping roots can duplicate uploads.
   - If the real configuration directory is elsewhere, substitute it.
   - Missing roots make the run report an error. Remove roots confirmed absent
     on that appliance, and investigate unexpectedly missing paths.
5. **Preview:**

   ```bash
   bash ./thunderstorm-collector.sh --dry-run --no-progress
   ```

6. **Upload** after reviewing the preview, overriding the preview default for
   this run:

   ```bash
   bash ./thunderstorm-collector.sh --no-dry-run --no-progress
   ```

   The header can stay at **`DRY_RUN=1`**. Bash has no `--dry-run=false`
   option.

Notes on the preset:

- Bash already collects all regular file types; no extension or header setting
  is needed.
- `MAX_AGE=0` disables the age filter. 65536 KiB is 64 MiB.
- Uploads are sequential; there is no equivalent to Go's 120 uploads per
  minute.
- Keep the existing pseudo-filesystem exclusions and other implementation
  settings. Clearing the cloud-name lists does not remove the built-in
  `Library/CloudStorage` exclusion.
- For HTTPS, use the [Bash guide](../../scripts/bash/README.md) and keep
  certificate verification on.
- An explicit `--dir` replaces the header's root list; further `--dir`
  arguments add roots.

## Verify

Review the actual file names and coverage, not just the final success count.

- **Missing roots and unreadable directories:** Bash reports missing or
  inaccessible roots and incomplete scans. The v1.1.0 Go package skips
  missing roots and unreadable directories silently. Current Go source reports
  an unreadable root as an error and logs unreadable directories below it.
- **Overlapping roots:** files reached through more than one root can be
  uploaded more than once in either collector.
- **Symlinks** inside directory trees are skipped by both collectors.
- **Mounts:** Bash discovers mounts only from Linux `/proc/mounts`, and Go's
  filesystem-type filtering is not implemented on FreeBSD. Neither guarantees
  that network or special mounts on NetScaler are skipped. Inspect physical
  paths and mounts, use known local roots, and add path exclusions where needed
  (`exclude` in Go, `EXCLUDE_PATHS` in Bash).
- **Live collection:** not a snapshot. Deleted files, process memory and network
  state are not collected.

Private IOC definitions, scores and infrastructure indicators are not
distributed here.

## Background

Sources for the scope:

- [Arctic Wolf NetScaler report](https://github.com/rtkwlf/wolf-tools/tree/main/pack_alerts/202609-citrix-netscaler-active-exploitation-cve-2026-88771): staging under `/var`, hidden state under `/var/tmp`, and cron persistence in `/etc` and `/nsconfig`.
- [NetScaler data collection guidance](https://support.citrix.com/external/article/CTX109304/data-collection-procedure-to-troubleshoo.html): older-release configuration under `/flash/nsconfig` and logs under `/var/nslog`.
- [NetScaler CLI `shell` reference](https://developer-docs.netscaler.com/en-us/adc-command-reference-int/current-release/utility/shell.html): entry into the FreeBSD shell.
