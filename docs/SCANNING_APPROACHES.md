# Choosing a THOR scanning approach

THOR can assess systems by running a compatible scanner directly on the system,
scanning a remotely mounted filesystem, analyzing files submitted to THOR
Thunderstorm, or scanning exported evidence on an analysis workstation. These
options extend file analysis to legacy systems and appliances that cannot run
a native THOR binary.

Use a native scan when it is supported and operationally suitable. For other
systems, choose an approach based on available access, permitted software,
network connectivity and how often assessments are needed. SSHFS is a useful
alternative for an immediate assessment; a scheduled Thunderstorm collector is
often a better fit for recurring assessments.

## Scanning methods at a glance

| Approach | Where THOR runs | Source system requirements | Typical use |
|---|---|---|---|
| **1. Native THOR scan** | On the source system | Compatible THOR binary for the OS, CPU and runtime; sufficient permissions | Assessment using the native checks available on that platform |
| **2a. Remote filesystem scan via SSHFS** | On a supported analysis workstation | Reachable SSH/SFTP service and credentials that can read the relevant paths | Ad-hoc assessment without installing a scanner or collector on the source |
| **2b. Thunderstorm with a collector** | On a central Thunderstorm server | Compatible collector or script, readable files and connectivity to the service | Recurring assessments with configurable file selection |
| **3. Offline analysis of exported evidence** | On a supported analysis workstation | A way to export files, backups or filesystem images | Analysis when direct access or on-system execution is impractical |

The numbering groups SSHFS and Thunderstorm as two ways to analyze files over
the network. It does not imply equal evidence coverage or a mandatory sequence.
Both can also serve one-time investigations; SSHFS scans can be scheduled if
their connection and access requirements are acceptable.

## Native THOR scans

A native scan runs THOR on the system being assessed. The scanner must support
the operating system, processor architecture and required runtime libraries.
Available modules and checks vary by platform; a supported native binary does
not imply that every platform has the same scan capabilities.

Native execution allows THOR to use the live-system checks available for that
platform. Remotely starting a native THOR binary is still a native scan: the
scanner executes on the source system, even if an administrator launches it
from elsewhere.

## Remote filesystem scans with SSHFS

SSHFS mounts directories exposed by an SSH server's SFTP subsystem on the
analysis workstation. THOR reads the mounted files and performs the analysis
there. The source system does not run THOR, a Thunderstorm collector or SSHFS.
Its CPU architecture therefore does not need to support the scanner binary.

This approach applies to systems with suitable SFTP access, rather than to a
fixed list of operating systems. Existing examples cover
[NetScaler appliances](https://www.nextron-systems.com/2023/07/20/how-to-perform-compromise-assessments-on-netscaler-citrix-adc-appliances-using-thor/)
and [VMware ESXi](https://www.nextron-systems.com/2023/02/14/how-to-scan-esxi-systems-using-thor/).
See the [SSHFS documentation](https://github.com/libfuse/sshfs#about) for the
underlying SFTP requirements.

### Prerequisites

- A supported analysis workstation with THOR and SSHFS/FUSE support. The example
  below uses Linux.
- Network access from the workstation to the source's SSH port, usually 22/tcp,
  and a working SFTP subsystem. An interactive SSH login alone is insufficient.
- SSH credentials with permission to enumerate directories and read the files
  in scope. An SFTP chroot or restricted account may expose only part of the
  filesystem.
- A Forensic Lab License for full THOR remote filesystem scanning. The linked
  articles also describe THOR Lite as an option with its own detection and
  feature limits; the full THOR example below requires the Lab License.

Some appliances need SFTP configuration changes. The NetScaler article describes
switching its subsystem to `internal-sftp`; this is a NetScaler-specific step,
not a requirement to apply that setting to every SSH server. Check the target's
configuration before making changes.

### Remote filesystem boundaries

An SSHFS mount does not expose the source's filesystem types as native local
mount types. For a fast first pass, allowlist a small set of relevant directories
and check only those subtrees for unexpected nested mounts. For a broader scan,
inventory the source and explicitly exclude pseudo filesystems, device trees
and out-of-scope remote mounts using their paths on the analysis workstation.
Do not rely on local filesystem-type detection to skip remote `/proc` or NFS
mounts. The [AIX on POWER7 SSHFS guide](../integration-guides/aix/aix-power7-sshfs-scanning.md) provides a
[quick path-allowlist procedure](../integration-guides/aix/aix-power7-sshfs-scanning.md#1-quick-incident-response-scan-using-a-path-allowlist)
and a [thorough assessment procedure](../integration-guides/aix/aix-power7-sshfs-scanning.md#2-thorough-assessment-with-mount-inventory-and-exclusions).

### Read only mount and scan example

Run these commands on the Linux analysis workstation. Replace the source account
and hostname, and use a mount directory that is not already mounted. The example
exposes the source's `/`; select narrower source directories when appropriate.

```sh
mkdir -p "$HOME/thor-mounts/target"
sshfs -o ro,reconnect analyst@target.example:/ "$HOME/thor-mounts/target"
```

Confirm that the mount succeeded and exposes the expected directories before
starting THOR. Run THOR as the same local user that mounted the filesystem;
SSHFS restricts access to that user by default. Remote file access is determined
by the SSH account's permissions, not the workstation user's privileges.

The following is an initial scan of `/etc`, after reviewing that path's nested
mounts. Add other reviewed paths after setting the appropriate exclusions.
From a full THOR package with a valid Forensic Lab License:

```sh
./thor-linux-64 --lab \
  -p "$HOME/thor-mounts/target/etc" \
  --virtual-map "$HOME/thor-mounts/target:/" \
  -j target-example --threads 0
```

The `-p` option selects the directory to scan. Virtual mapping restores the original
path prefix for path-based analysis, and `-j` attributes results to the source
hostname. Set that value to the actual source identifier. The `--lab` preset
enables filesystem analysis across platforms, intense scanning and other lab
settings, including disabling resource safeguards. `--threads 0` explicitly uses
all cores on the analysis workstation, as `--lab` normally does. More threads
can help, but source storage, SSH encryption or the network may limit throughput.
Use an explicit count such as `--threads 2` or `--threads 4` if source load
requires less concurrency; a thread count does not impose a source I/O or
network bandwidth limit. Size the scan for the source's capacity.
See the [THOR command line options](https://thor-manual.nextron-systems.com/en/latest/usage/flags.html)
and [lab scanning documentation](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning).

After THOR has finished and released the mount, unmount it on the workstation:

```sh
fusermount3 -u "$HOME/thor-mounts/target"
```

Some Linux installations use `fusermount -u` instead. Do not force an unmount
while THOR is reading the filesystem. A read-only mount prevents writes through
that mount; it does not freeze the source or create a consistent snapshot.

### Scope and performance

The connection must remain usable while THOR reads files. Reconnection support
does not guarantee that every interrupted read succeeds; inspect scan errors
and repeat incomplete portions as needed. Unreadable or unexposed paths are
outside the assessment.

File data read by THOR travels over the SSHFS connection, along with directory
and metadata requests. Large scopes, high latency and intensive settings can
produce substantial traffic and source disk activity. Select relevant paths
and exclusions, and account for large data stores and virtual machine disks.
Scan duration depends on the source, scope and network; timings from the older
appliance articles are examples, not a general performance guarantee.

## File submission with THOR Thunderstorm

A collector enumerates and reads files on the source, then submits them to a
central Thunderstorm service. The server performs the analysis. This is useful
for appliances, legacy systems and other environments where deploying THOR
itself is impractical.

Choose the [Go collector](../go/README.md) when its platform requirements fit.
Otherwise, use a compatible [script collector](../scripts/README.md) and validate
its interpreter, utilities and HTTP/TLS dependencies on the actual target.
Collector features and defaults differ; not every script supports every filter
or the same time units.

For a permanent deployment, the source initiates submissions to the service;
no inbound SSH connection or mounted remote filesystem is required for that
collection path. HTTPS is available when configured on the server and supported
by the collector's transport. Use certificate verification and a suitable CA
store. The service requires a Thunderstorm Service License; a collector does
not need a local THOR scanner license.
See [Thunderstorm deployment and licensing](https://thor-manual.nextron-systems.com/en/latest/usage/deployment.html#thor-thunderstorm-service).

### Recurring collection

File selection can reduce repeated transfers and central analysis work. Depending
on the collector, selection may use paths, size, modification age, extensions
or file headers. For example, the Go collector accepts an hourly age window;
many script collectors express age in whole days. Check the selected collector's
README before configuring a schedule.

For recurring assessments:

1. Start with a broader assessment of the relevant paths so older files are
   included.
2. Schedule narrower collections with enough overlap to cover scan duration,
   scheduling delays and short outages. Detect failures and backfill missed
   periods; a fixed age window is not a record of successful collection.
3. Repeat broader assessments periodically, including unchanged files, so new
   signatures can detect older evidence. Timestamp manipulation can also defeat
   a filter based only on modification time.
4. Review exclusions and size limits alongside age filters. A successful upload
   run covers only eligible files; asynchronous acceptance does not mean that
   analysis has completed.

Reduced traffic comes from the scope and selection policy, not inherently from
using HTTP instead of SSHFS. A collector still consumes source CPU, disk I/O and
network capacity while enumerating and uploading files; the detection workload
moves to the server.

## Offline analysis of exported evidence

Export files, backups or filesystem images and analyze them on a supported
workstation when live access or collector execution is unavailable. The source
can remain online during an export; the analysis itself no longer depends on
an active connection to it.

Mount or extract evidence with compatible tools, preserve original paths and
relevant metadata where possible, and record the source and acquisition time.
For full THOR, use a Forensic Lab License and the appropriate lab settings,
including virtual path mapping when needed. A scanner that runs on the analysis
workstation does not automatically understand every filesystem image format.
See [THOR lab scanning](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#forensic-lab-license).

## AIX on POWER7 as an example

For detailed instructions, see
[Scanning AIX on POWER7 with THOR over SSHFS](../integration-guides/aix/aix-power7-sshfs-scanning.md).
Start with its quick path-allowlist procedure for incident response, then use
the thorough procedure for wider coverage. It also covers thread selection,
root permissions, mount inventory, exclusions and metadata limits.

OS compatibility and CPU compatibility are separate requirements. Standard Go
`ppc64` builds require POWER8 or newer, so the standard Go-based AIX collector
is not an alternative for actual POWER7 hardware.
See [Go platform requirements](https://go.dev/wiki/MinimumRequirements#ppc64-big-endian).
Validate the native THOR package against its own documented requirements too.

For an AIX system running on POWER7, consider:

- **SSHFS:** scan accessible files from a supported analysis workstation if the
  AIX system provides suitable SSH/SFTP access. SSHFS runs on the workstation.
- **Thunderstorm:** use a script collector whose interpreter, dependencies and
  transport work on that AIX installation. A script's language alone does not
  establish compatibility with every AIX release.
- **Exported evidence:** transfer files or a supported export for lab analysis
  when neither live network approach is suitable.

Any special collector build using another toolchain, such as `gccgo`, needs
separate confirmation of availability and validation on the intended system.
None of these file-analysis alternatives establishes native THOR support for
that OS or CPU.

## Evidence coverage

SSHFS, Thunderstorm submissions and offline exports provide analysis of the
evidence they expose. They do not automatically reproduce native inspection of
running processes, live memory or other platform-specific system state.
Thunderstorm can also parse supported submitted forensic artifacts, such as
event logs, registry hives and memory dumps; its full-featured mode is broader
than a pure YARA scan. Available context and analysis mode affect the result.
See [Thunderstorm analysis modes](https://www.nextron-systems.com/thor-thunderstorm/).

When describing an assessment, record the source, accessible paths, collection
or acquisition time, filters, unreadable files and scan errors. Describe the
result as analysis of that evidence rather than promising identical coverage
across all four approaches.
