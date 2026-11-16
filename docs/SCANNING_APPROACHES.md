# Choosing a THOR scanning approach

Run THOR on the system when it is supported and permitted: no file-based method
replaces its live checks. Otherwise, choose the method that needs the least on
the source while still covering the files and the schedule you need. The
alternatives extend file analysis to legacy systems and appliances that cannot
run a native THOR binary.

> [!NOTE]
> The SFTP collector is a **prototype**. It has not been tested on products or
> on AIX. Product-specific choices are in the
> [collector recommendations](COLLECTOR_RECOMMENDATIONS.md).

## Recommended method by situation

| Situation | Recommended | Alternative | Why |
|---|---|---|---|
| A system that meets the standard THOR requirements, where THOR may run | THOR on the system | Go collector for frequent checks of new files between full scans | Only a native scan adds the live checks. |
| A Windows version older than the standard THOR requirements | THOR Legacy, with its license | Go collector; its Go 1.10 builds keep support for XP- and Vista-era Windows | Native checks on the old system. The collector covers files where THOR Legacy is not available. |
| Many systems with frequent checks of new or changed files | Go collector with an age filter | A script collector where the Go binary does not fit | Light runs on the sources, central analysis. Repeat runs without an age filter periodically. |
| A system THOR does not support that can run a Go binary, such as an appliance or an unsupported CPU | Go collector | Script collector | One binary without runtime dependencies. |
| A system with a suitable interpreter but no matching Go build, or where binaries may not be run | Script collector | SFTP collector or THOR over SSHFS | Uses what is already installed. |
| Only SSH/SFTP is available, and one complete assessment is needed, as in incident response | THOR over SSHFS | SFTP collector | Checks every file in scope, also by filename IOCs, and needs no Thunderstorm service. |
| Only SSH/SFTP is available, and collection repeats, covers many systems or runs over slow links | SFTP collector (prototype) | THOR over SSHFS | Transfers only the selected files; one host covers many sources. |
| The source accepts SSH but cannot reach Thunderstorm | SFTP collector (prototype) | THOR over SSHFS | The connection starts from the collector host; the source needs no outbound path. |
| No live access, an isolated network, or files available only as a vendor export | Exported evidence with THOR | Upload the exports with a collector on another system | Analysis without touching the live system. |

## Scanning methods at a glance

![Five ways to cover a system: THOR or THOR Legacy on the system itself; a Go or script collector on the system sending selected files to Thunderstorm; the SFTP collector reading selected files from a system that only offers SSH; THOR scanning an SSHFS mount; and THOR scanning exported evidence on a workstation.](../images/coverage-methods.svg)

| Method | Where THOR runs | Details |
|---|---|---|
| **THOR or THOR Legacy on the system** | On the source system | [Native THOR scans](#native-thor-scans) |
| **THOR over SSHFS** | On a supported analysis workstation | [Remote filesystem scans with SSHFS](#remote-filesystem-scans-with-sshfs) |
| **Go or script collector** on the source | On a central Thunderstorm server | [File submission with THOR Thunderstorm](#file-submission-with-thor-thunderstorm) |
| **SFTP collector** (prototype) on another host | On a central Thunderstorm server | [Pulling files over SFTP](#pulling-files-over-sftp) |
| **Exported evidence** | On a supported analysis workstation | [Offline analysis of exported evidence](#offline-analysis-of-exported-evidence) |

Every network route also suits one-time investigations, and SSHFS scans can be
scheduled if their connection and access requirements are acceptable.

## Advantages and disadvantages

| Method | Advantages | Disadvantages |
|---|---|---|
| **THOR on the system** | The most complete coverage of one host: files plus the live checks THOR offers on that platform. No central service is needed. | Needs a supported OS, CPU and runtime, and permission to run THOR. A full scan takes time and uses CPU and disk on the host. |
| **THOR Legacy on the system** | Native scans of older Windows versions that the standard THOR release no longer supports. | Needs the dedicated THOR Legacy version and a THOR Legacy license. These systems receive only limited support. |
| **Go collector** | One binary for many OS and CPU targets, including old Windows and Linux releases, with no installed runtime. Metadata filters skip unsuitable files before reading them, which keeps the load low. Suits frequent runs with an age filter; one Thunderstorm service serves many sources. | Needs a Thunderstorm service, a network path from the source to it, and permission to run a binary. Analyzes submitted files only, with no process, memory or other live checks. Files outside the filters are not analyzed. |
| **Script collectors** | Use a runtime the system already has (Bash, POSIX sh, Python, Perl, PowerShell or Batch). No binary to deploy, and the code is easy to review and adapt. | Depend on the interpreter version and tools such as curl; features and defaults differ between scripts. Same file-only scope and Thunderstorm requirements as the Go collector. |
| **SFTP collector** (prototype) | Nothing runs on the source and nothing is copied there. Only selected files cross the network. The source needs no route to Thunderstorm, and one host can collect from many sources. | Needs the SFTP subsystem, inbound SSH and stored SSH credentials. The age filter uses only the modification time, and filesystem types are not reported. File-only scope. |
| **THOR over SSHFS** | Nothing runs on the source. Every file in scope is checked, including by filename IOCs. No Thunderstorm service is needed. | Needs a Forensic Lab License and an analysis workstation with SSHFS. A lab scan reads every file in scope, so traffic and disk reads on the source grow with the data in scope. The connection must stay up for the whole scan. |
| **Exported evidence** | Needs no live access or network path to the source and suits isolated networks. The same evidence can be scanned again. | Needs a Forensic Lab License, an export or imaging process and storage. The result reflects the time of the export, not the live system. |

## Native THOR scans

THOR runs on the system being assessed and can use the live-system checks
available for that platform. Starting the binary remotely is still a native
scan: the scanner executes on the source, even if an administrator launches it
from elsewhere.

**When:** the system meets THOR's requirements, and THOR may run there.

**Needs:**

- A THOR binary that supports the operating system, processor architecture and
  required runtime libraries.
- Sufficient permissions on the system.
- For Windows versions older than the standard requirements: the dedicated
  **THOR Legacy** version and a **THOR Legacy license**. The
  [THOR requirements](https://thor-manual.nextron-systems.com/en/latest/usage/requirements.html#legacy-systems)
  list the Windows versions for the THOR release in use.

**Limits:**

- Available modules and checks vary by platform. A supported native binary does
  not mean that every platform has the same scan capabilities.
- Systems scanned with THOR Legacy receive only limited support.

## Remote filesystem scans with SSHFS

THOR runs on an analysis workstation and reads the source's files through an
SSHFS mount. SSHFS mounts directories that the source's SSH server exposes
through its SFTP subsystem. The source runs neither THOR, a collector nor SSHFS,
so its CPU architecture does not need to support the scanner binary.

**When:** only SSH/SFTP is available and you need one complete assessment, for
example in incident response. Every file in scope is checked, also by filename
IOCs, and no Thunderstorm service is needed.

The approach depends on suitable SFTP access, not on a fixed list of operating
systems. Published examples cover
[NetScaler appliances](https://www.nextron-systems.com/2023/07/20/how-to-perform-compromise-assessments-on-netscaler-citrix-adc-appliances-using-thor/)
and [VMware ESXi](https://www.nextron-systems.com/2023/02/14/how-to-scan-esxi-systems-using-thor/).
The [SSHFS documentation](https://github.com/libfuse/sshfs#about) describes the
underlying SFTP requirements.

### Prerequisites

- **Workstation:** a supported analysis workstation with THOR and SSHFS/FUSE
  support. The example below uses Linux.
- **Network:** access from the workstation to the source's SSH port, usually
  22/tcp, and a working SFTP subsystem. An interactive SSH login alone is not
  enough.
- **Account:** SSH credentials that can list directories and read the files in
  scope. An SFTP chroot or restricted account may expose only part of the
  filesystem.
- **License:** a **Forensic Lab License** for full THOR remote filesystem
  scanning, as in the example below. The linked articles also describe THOR Lite
  as an option, with its own detection and feature limits.

Some appliances need SFTP configuration changes. The NetScaler article switches
its subsystem to `internal-sftp`. That step is specific to NetScaler, not a
setting for every SSH server; check the target's configuration before changing
it.

### Remote filesystem boundaries

An SSHFS mount does not expose the source's filesystem types as native local
mount types. Do not rely on local filesystem-type detection to skip remote
`/proc` or NFS mounts. Instead, choose a scope:

- **Fast first pass:** allowlist a small set of relevant directories, and check
  only those subtrees for unexpected nested mounts.
- **Broader scan:** inventory the source, then exclude pseudo filesystems,
  device trees and out-of-scope remote mounts by their paths on the analysis
  workstation.

The [AIX on POWER7 SSHFS guide](../integration-guides/aix/aix-power7-sshfs-scanning.md)
shows both: a
[quick path-allowlist procedure](../integration-guides/aix/aix-power7-sshfs-scanning.md#1-quick-incident-response-scan-using-a-path-allowlist)
and a
[thorough assessment procedure](../integration-guides/aix/aix-power7-sshfs-scanning.md#2-thorough-assessment-with-mount-inventory-and-exclusions).

### Read only mount and scan example

Run these steps on the Linux analysis workstation.

1. **Mount read-only.** Replace the source account and hostname, and use a
   mount directory that is not already mounted. The example exposes the
   source's `/`; select narrower source directories when appropriate.

   ```sh
   mkdir -p "$HOME/thor-mounts/target"
   sshfs -o ro,reconnect analyst@target.example:/ "$HOME/thor-mounts/target"
   ```

2. **Check the mount.** Confirm that it succeeded and exposes the expected
   directories.

3. **Scan.** Run THOR as the same local user that mounted the filesystem;
   SSHFS restricts access to that user by default. Remote file access follows
   the SSH account's permissions, not the workstation user's privileges.

   This first scan covers `/etc`, after reviewing that path's nested mounts.
   Add other reviewed paths after setting the appropriate exclusions. From a
   full THOR package with a valid Forensic Lab License:

   ```sh
   ./thor-linux-64 --lab \
     -p "$HOME/thor-mounts/target/etc" \
     --virtual-map "$HOME/thor-mounts/target:/" \
     -j target-example --threads 0
   ```

4. **Unmount** after THOR has finished and released the mount. Some Linux
   installations use `fusermount -u` instead. Do not force an unmount while
   THOR is reading the filesystem.

   ```sh
   fusermount3 -u "$HOME/thor-mounts/target"
   ```

What the scan options do:

| Option | Effect |
|---|---|
| `-p` | Selects the directory to scan |
| `--virtual-map` | Restores the original path prefix for path-based analysis |
| `-j` | Attributes results to the source hostname; set it to the actual source identifier |
| `--lab` | Enables filesystem analysis across platforms, intense scanning and other lab settings, including **disabling resource safeguards** |
| `--threads 0` | Uses all cores on the analysis workstation explicitly, as `--lab` normally does |

Threads and source load:

- More threads can help, but source storage, SSH encryption or the network may
  limit throughput.
- If the source needs less concurrency, set an explicit count such as
  `--threads 2` or `--threads 4`.
- A thread count does not limit source I/O or network bandwidth. Size the scan
  for the source's capacity.

Sources: [THOR command line options](https://thor-manual.nextron-systems.com/en/latest/usage/flags.html) · [THOR lab scanning](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning)

### Scope and performance

- **Connection:** it must stay usable while THOR reads files. Reconnection
  support does not guarantee that every interrupted read succeeds; inspect scan
  errors and repeat incomplete portions.
- **Coverage:** unreadable or unexposed paths are outside the assessment.
- **Not a snapshot:** a read-only mount prevents writes through that mount. It
  does not freeze the source or create a consistent snapshot.
- **Traffic:** file data, directory and metadata requests all travel over the
  connection. Large scopes, high latency and intensive settings can produce
  substantial traffic and source disk activity.
- **Lab scans read every file:** a lab scan
  [scans every file regardless of its extension or magic header](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning),
  up to its size limit. Traffic grows with the data in scope, not with the
  files of interest. Select relevant paths and exclusions, and account for
  large data stores and virtual machine disks.
- **Duration:** depends on the source, scope and network. Timings in the older
  appliance articles are examples, not a general performance guarantee.

To transfer only selected files over the same access, see
[Pulling files over SFTP](#pulling-files-over-sftp).

## File submission with THOR Thunderstorm

A collector enumerates and reads files on the source and submits them to a
central Thunderstorm service, which performs the analysis. This suits
appliances, legacy systems and other environments where deploying THOR itself
is impractical.

**When:** recurring assessments with configurable file selection. One
Thunderstorm service serves many sources.

**Needs:**

- A Thunderstorm service with a **Thunderstorm Service License**. A collector
  does not need a local THOR scanner license. See
  [Thunderstorm deployment and licensing](https://thor-manual.nextron-systems.com/en/latest/usage/deployment.html#thor-thunderstorm-service).
- A collector for the source: the [Go collector](../go/README.md) when its
  platform requirements fit, otherwise a compatible
  [script collector](../scripts/README.md). Validate a script's interpreter,
  utilities and HTTP/TLS dependencies on the actual target.
- Readable files and a network path from the source to the service. The source
  initiates the submissions, so no inbound SSH connection or mounted remote
  filesystem is needed.

**Example:** preview with the Go collector, then run the same command without
`--dry-run` to upload.

```sh
./amd64-linux-thunderstorm-collector -s thunderstorm.example.internal -p /var/www --dry-run --debug
```

**Limits:**

- Collector features and defaults differ. Not every script supports every
  filter or the same time units.
- Only submitted files are analyzed: no process, memory or other live checks.
  See [Evidence coverage](#evidence-coverage).
- HTTPS is available when configured on the server and supported by the
  collector's transport. Use certificate verification and a suitable CA store.

### Pulling files over SFTP

The prototype [SFTP collector](../sftp/README.md) serves systems that offer
SSH/SFTP access but can run neither THOR nor a collector. It runs on the
Thunderstorm host or on a system that reaches both, lists the source's
filesystem over SFTP and sends only the selected files. Nothing runs on the
source, and the source needs no route to Thunderstorm.

**Needs:**

- The SFTP subsystem on the source, and inbound SSH access to it from the
  collector host. The connection runs the other way than for the collectors
  above.
- SSH credentials for the source, kept on the collector host.
- A Linux amd64 or arm64 package from a release after v1.1.0, or a build from
  source.

**Example:** preview the selection from `/etc` on an appliance.

```sh
./thunderstorm-sftp-collector \
  --sftp-host appliance01.example.internal --sftp-user audit --sftp-key ~/.ssh/audit_ed25519 \
  -s thunderstorm.example.internal -p /etc --dry-run
```

All options are in the [SFTP collector usage](../sftp/README.md#usage).

**Compared with THOR over SSHFS:**

- **Selection before transfer.** Path, name, size, modification time and
  permission filters use the directory listing. A header filter reads only the
  first bytes of a file.
- **Less traffic.** Network traffic and disk reads on the source follow the
  selection, while a lab scan of an SSHFS mount reads every file in scope.
- **Narrower coverage.** Files outside the selection are never analyzed, not
  even by filename IOCs.
- **Modification time only.** SFTP version 3, which OpenSSH implements, reports
  no change time, so the age filter can use only the modification time.

A complete SSHFS assessment followed by scheduled SFTP collections combines the
two. The collector's
[comparison with SSHFS](../sftp/README.md#compared-with-thor-over-sshfs) covers
both sides.

### Recurring collection

File selection reduces repeated transfers and central analysis work. Depending
on the collector, it may use paths, size, modification age, extensions or file
headers. Age units differ: the Go collector accepts an hourly window, while
many script collectors use whole days. Check the collector's README before
configuring a schedule.

1. **Start broad.** Assess the relevant paths with a broader scope first, so
   older files are included.
2. **Schedule narrower runs with overlap.** The overlap covers scan duration,
   scheduling delays and short outages. Detect failures and backfill missed
   periods; a fixed age window is not a record of successful collection.
3. **Repeat broad runs periodically,** including unchanged files, so new
   signatures can detect older evidence. Timestamp manipulation can also defeat
   a filter based only on modification time.
4. **Review exclusions and size limits** together with age filters. A
   successful upload run covers only eligible files, and asynchronous acceptance
   does not mean that analysis has completed.

Lower traffic comes from scope and selection, not from using HTTP instead of
SSHFS. A collector still uses source CPU, disk I/O and network capacity while it
enumerates and uploads files; the detection workload moves to the server.

To run scheduled collections for many appliances from one Linux machine, with
nothing left installed on them between runs, see
[Running collections from a central orchestrator](COLLECTION_ORCHESTRATOR.md).

## Offline analysis of exported evidence

Export files, backups or filesystem images, and analyze them on a supported
workstation. The source can stay online during an export; the analysis no
longer depends on an active connection to it.

**When:** live access or collector execution is unavailable, the network is
isolated, or files exist only as a vendor export.

**Needs:**

- An export or imaging process, and storage for the evidence.
- For full THOR, a **Forensic Lab License** and the appropriate lab settings,
  including virtual path mapping when needed. See
  [THOR lab scanning](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#forensic-lab-license).

**Steps:**

- Mount or extract the evidence with compatible tools. A scanner on the
  analysis workstation does not automatically understand every filesystem
  image format.
- Preserve original paths and relevant metadata where possible.
- Record the source and the acquisition time.

**Example:** [Export FortiGate evidence and scan it with THOR on Linux](../integration-guides/fortinet/fortigate-export-thor-lab.md).

**Limits:** the result reflects the time of the export, not the live system.

## AIX on POWER7 as an example

For step-by-step instructions, see
[Scanning AIX on POWER7 with THOR over SSHFS](../integration-guides/aix/aix-power7-sshfs-scanning.md).
Start with its quick path-allowlist procedure for incident response, then use
the thorough procedure for wider coverage. It also covers thread selection,
root permissions, mount inventory, exclusions and metadata limits.

The standard Go-based AIX collector is **not** an option on actual POWER7
hardware: standard Go `ppc64` builds require POWER8 or newer. OS and CPU
compatibility are separate requirements. See
[Go platform requirements](https://go.dev/wiki/MinimumRequirements#ppc64-big-endian).
Validate the native THOR package against its own documented requirements too.

| Method | On AIX running on POWER7 |
|---|---|
| **SSHFS** | Scan accessible files from a supported analysis workstation if the AIX system provides suitable SSH/SFTP access. SSHFS runs on the workstation. |
| **Thunderstorm** | Use a script collector whose interpreter, dependencies and transport work on that AIX installation. A script's language alone does not establish compatibility with every AIX release. |
| **SFTP collector** | Send selected files to Thunderstorm from a system with SSH/SFTP access to AIX; nothing runs on AIX. |
| **Exported evidence** | Transfer files or a supported export for lab analysis when none of the live network approaches fits. |

A special collector build with another toolchain, such as `gccgo`, needs
separate confirmation of availability and validation on the intended system.
None of these file-analysis alternatives establishes native THOR support for
that OS or CPU.

## Evidence coverage

SSHFS, Thunderstorm submissions and offline exports analyze the evidence they
expose. They do not automatically reproduce native inspection of running
processes, live memory or other platform-specific system state.

Thunderstorm can also parse supported forensic artifacts submitted as files,
such as event logs, registry hives and memory dumps. Its full-featured mode is
broader than a pure YARA scan; available context and analysis mode affect the
result. See [Thunderstorm analysis modes](https://www.nextron-systems.com/thor-thunderstorm/).

When you describe an assessment, record:

- the source and the accessible paths
- the collection or acquisition time
- the filters
- unreadable files and scan errors

Describe the result as analysis of that evidence, not as identical coverage
across these approaches.
