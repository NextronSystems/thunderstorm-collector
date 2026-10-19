# Scanning AIX on POWER7 with THOR over SSHFS

An AIX system on POWER7 can expose files over SSH/SFTP to THOR running on a
supported Linux analysis workstation. No THOR binary, Go collector, FUSE driver
or SSHFS installation is required on AIX. AIX reads its own filesystems and
serves the file contents; the Linux workstation does not need a JFS/JFS2 driver.

Choose the procedure that fits the incident:

- [Quick incident-response scan](#1-quick-incident-response-scan-using-a-path-allowlist):
  start with a small set of relevant directories and the affected application's
  files, checking only those subtrees before scanning.
- [Thorough assessment](#2-thorough-assessment-with-mount-inventory-and-exclusions):
  inventory the source and configure exclusions before assessing larger trees
  or the entire mounted filesystem.

**SSHFS does not reproduce the AIX mount table on Linux.** Both procedures
account for this: the quick procedure limits where THOR starts its recursive
scan; the thorough procedure also identifies paths that must be excluded within
the larger scope.

This guide is based on IBM and upstream documentation and source inspection;
it has not been tested against a live AIX/POWER7 host during its preparation.

For the alternatives and licensing overview, see
[Choosing a THOR scanning approach](SCANNING_APPROACHES.md).

## 1. Quick incident-response scan using a path allowlist

Have SSHFS/FUSE, full THOR and a Forensic Lab License ready on Linux. Use an
authorized AIX account with read access, preferably root. For access problems,
see [source permissions and SFTP](#arrange-source-permissions-and-sftp-access).

### Choose a small set of relevant paths

| AIX source path | Why include it in a first pass? |
|---|---|
| `/etc` | Configuration and startup files, including [`/etc/inittab`](https://www.ibm.com/docs/en/aix/7.1.0?topic=files-inittab-file). |
| `/tmp` and [`/var/tmp`](https://www.ibm.com/docs/en/aix/7.2.0?topic=tree-var-file-system) | Temporary files, possible dropped payloads and staging scripts. `/usr/tmp` normally aliases `/var/tmp`. |
| `/var/spool/cron` | [Cron and at job files](https://www.ibm.com/docs/en/aix/7.1.0?topic=c-cron-daemon), which can contain persistence commands. |
| `/usr/bin`, `/usr/sbin`, `/sbin` | System programs and scripts; include them when checking for dropped or modified executables. |
| `/usr/lib`, `/usr/local` | System libraries and locally installed software. These add coverage and scan time; omit nonexistent directories. |
| Web/application directories | Start with `/usr/IBM/HTTPServer` and `/usr/IBM/WebSphere/AppServer/profiles` if installed. See [application locations and additional scan paths](#application-locations-and-additional-scan-paths) for the useful subdirectories and other layouts. Prioritize the affected application. |

These ordinary file trees are normally suitable for read-only scanning. The
shorter path list limits work; it does not imply that other directories are
dangerous to read. Large trees take longer and generate more source I/O.

Have the AIX administrator check `mount` output **only for the selected paths
and mounts beneath them**, confirming ordinary file trees without unexpected
remote, pseudo or automounted subtrees. Resolve aliases used as scan roots.
Leave uncertain subtrees out of this pass. No full-host inventory or custom
exclusion file is needed for the confirmed subtrees.

For IBM HTTP Server, check `/usr/IBM/HTTPServer/conf/httpd.conf` first and include
its configured document roots, aliases and script locations. Installation paths
can differ; `/srv` is not a universal AIX webroot. WebSphere applications usually
need their profile's `installedApps` tree as well as the HTTP server's files.

### Mount the source read-only

Run on Linux as the same local user for SSHFS and THOR. Replace the hostname
and use an unused mount directory, or reuse an existing verified mount.

```sh
sudo mkdir /mnt/aix-power7 &&
sudo chown "$(id -u):$(id -g)" /mnt/aix-power7
```

```sh
sshfs -o ro,nodev,nosuid,noexec,reconnect \
  -o ServerAliveInterval=15,ServerAliveCountMax=3 \
  root@aix-power7.example:/ /mnt/aix-power7
```

```sh
findmnt -T /mnt/aix-power7 -o TARGET,FSTYPE,OPTIONS
```

Confirm target `/mnt/aix-power7`, type SSHFS/FUSE and read-only options. Mounting
`/` makes the tree available without requiring a scan of the entire tree.

### Scan only the selected directories

From the local THOR package, remove absent/unconfirmed paths below and add
`-p` for each confirmed application directory, for example
`-p /mnt/aix-power7/usr/IBM/HTTPServer/htdocs` if that is the active webroot. Replace the
result hostname with the actual source identifier.

```sh
mountpoint -q /mnt/aix-power7 &&
./thor-linux-64 --lab \
  -p /mnt/aix-power7/etc \
  -p /mnt/aix-power7/tmp \
  -p /mnt/aix-power7/var/tmp \
  -p /mnt/aix-power7/var/spool/cron \
  -p /mnt/aix-power7/usr/bin \
  -p /mnt/aix-power7/usr/sbin \
  -p /mnt/aix-power7/sbin \
  -p /mnt/aix-power7/usr/lib \
  -p /mnt/aix-power7/usr/local \
  --virtual-map /mnt/aix-power7:/ \
  -j aix-power7-example --threads 0
```

Repeated `-p` arguments restrict the recursive scan to those trees. Add reviewed
application roots as needed; use their relevant subdirectories to limit scan
time. Reserve scanning the entire mounted `/` for the thorough procedure. Keep
SSHFS `follow_symlinks` and THOR `--follow-symlinks` disabled, and preserve
existing exclusions. Top-level `/proc`, `/dev`, `/aha` and `/wpars` are outside
this selection; nested special mounts still need the focused check above.

**Threads:** `--threads 0` uses all cores on the **Linux analysis workstation**,
as `--lab` normally does. POWER7 has no one-thread requirement; `--threads 1`
is an optional load reduction. Have the administrator watch source load and
reduce to `--threads 2` or `--threads 4` if needed. SSHFS, network latency,
storage or SSH encryption can limit speedup.
[THOR thread and lab options](https://thor-manual.nextron-systems.com/en/latest/usage/flags.html)

Review file counts and read errors, save the findings with the selected paths,
and record omitted application/storage paths. After THOR exits, unmount:

```sh
fusermount3 -u /mnt/aix-power7
```

This pass omits user homes, logs and application trees unless added.
THOR can flag suspicious configuration content; proving arbitrary changes also
needs a baseline or manual review. Widen coverage as the incident requires.

## 2. Thorough assessment with mount inventory and exclusions

Use this procedure to widen coverage, handle uncertain or nested mounts, or
prepare a repeatable assessment. A successful quick scan can be the first
stage; it need not wait for all the planning below. Reuse its verified mount
if it is still available.

### Application locations and additional scan paths

Use this reference to expand the quick scan without starting with the whole
filesystem. These are documented defaults or installation layouts to check,
not a promise that every AIX host contains them. Substitute the actual product
and profile paths, then add each selected directory with `-p` using its local
`/mnt/aix-power7` prefix.

#### Common application locations

| Software or layout | Where to look on AIX | Useful scan targets |
|---|---|---|
| IBM HTTP Server | `/usr/IBM/HTTPServer` is the documented AIX installation default. | `conf`, `htdocs`, and `cgi-bin` if present; also every configured document root, script alias and upload directory outside that installation. |
| Traditional WebSphere Application Server | `/usr/IBM/WebSphere/AppServer`; default profiles are under `profiles/<profile>`. | Within each relevant profile: `installedApps`, `config`, `temp` and `wstemp`. Deployed web application code, including JSP files, can be beneath `installedApps/<cell>/<application>.ear/`. |
| Apache HTTP Server built with the upstream AIX layout | `/opt/httpd` and `/var/httpd`, with configuration under `/etc/httpd` or `/var/httpd/etc`. | Read the configuration to identify document roots, script aliases and application content. This layout is build-dependent, not a default for every Apache package. |
| AIX Toolbox software | `/opt/freeware`. | Installed programs, libraries and configuration; include application content elsewhere when configured. |
| Other vendor or locally installed applications | `/opt` and `/usr/local` are useful starting points. Product-specific or administrator-chosen locations may be elsewhere. | The affected product's code, scripts, configuration, upload and working directories. Select large database or backup stores separately. |

IBM documents the [AIX product and profile defaults](https://www.ibm.com/docs/en/was-nd/9.0.5?topic=systems-websphere-application-server-default-directories)
and [HTTP server configuration location](https://www.ibm.com/docs/en/ibm-http-server/8.5.5?topic=server-configuring-http);
its [AIX HTTP Server notes](https://www.ibm.com/docs/en/aix/7.1.0?topic=notes-aix-710-expansion-pack-release)
also identify the `htdocs` and `cgi-bin` content directories.
Its [deployment description](https://www.ibm.com/support/pages/node/1081077)
explains `installedApps`, `config` and `wstemp`; its
[temporary-directory reference](https://www.ibm.com/support/pages/things-know-deleting-temporary-cache-and-log-files-websphere-application-server)
identifies compiled JSP files under the profile's `temp` tree. Non-root
installations can be under the installing user's home, and profiles or
application repositories can be relocated.

For example, a profile named `AppSrv01` in the default installation has a useful
scan root at `/mnt/aix-power7/usr/IBM/WebSphere/AppServer/profiles/AppSrv01/installedApps`.
Add its sibling `config`, `temp` and `wstemp` directories as separate paths.
Scanning only the HTTP server's `htdocs` can miss application code served by
WebSphere behind that server.

Other layout references: [Apache's AIX layout](https://cwiki.apache.org/confluence/spaces/HTTPD/pages/115522217/AIXPlatform),
[AIX Toolbox paths](https://www.ibm.com/support/pages/aix-toolbox-open-source-software-get-started),
and [IBM's AIX directory structure](https://www.ibm.com/docs/en/ssw_aix_72/devicemanagement/filesys_struct.html).

#### More ordinary directories can be included

| Additional scope | What it adds and what to check |
|---|---|
| `/usr/bin`, `/usr/sbin`, `/sbin`, `/usr/lib` | System executable, script and library contents. These are included in the expanded quick example. On standard AIX layouts, `/bin` and `/lib` alias `/usr/bin` and `/usr/lib`; use the real paths instead of scanning aliases again. |
| `/usr/local`, `/opt/freeware` | Local software and open-source packages. Include the entire tree if its size is acceptable, or select the relevant product. |
| `/usr/IBM`, `/opt/IBM`, or the whole `/opt` | Broader vendor software coverage, including products outside the examples above. These are valid scan candidates when present and in scope; narrow them for speed if they contain large installations or data stores. |
| Selected user and service-account homes | Shell startup files, SSH configuration, scripts and user-installed applications. Use each account's configured home; do not assume root's home is `/root`. `/home` can be NFS-backed or automounted. |
| Selected application logs and regular files under `/var/adm` or `/var/log`, where present | Investigation evidence beyond executable content. Prefer relevant log directories or files; `/var/adm` also contains special entries such as the cron FIFO, and logs can be large. |

There is no pathname that guarantees zero operational impact on every host.
Reading ordinary files through a read-only mount does not execute those files
or write their contents. It does consume source I/O, SSH CPU and network
capacity, and can update access times. `/usr` and `/opt` are not inherently
unsafe scan roots: include them when their contents, nested mounts and scan
volume are acceptable. The focused mount check applies to each added subtree;
the explicit exclusions remain relevant to pseudo filesystems, devices and
out-of-scope storage. See IBM's [directory structure](https://www.ibm.com/docs/en/ssw_aix_72/devicemanagement/filesys_struct.html)
and [cron file locations](https://www.ibm.com/docs/en/aix/7.1.0?topic=c-cron-daemon).

### What SSHFS preserves and what it hides

SSHFS exposes a directory tree through SFTP. On Linux, it is normally one
`fuse.sshfs` mount, even when that tree crosses several filesystems on AIX:

| Example source path | Possible AIX filesystem | Workstation view under one SSHFS mount |
|---|---|---|
| `/usr` | JFS or JFS2 | `/mnt/aix-power7/usr` within `fuse.sshfs` |
| `/proc` | procfs | `/mnt/aix-power7/proc` within the same mount |
| `/aha` | ahafs, if mounted there | `/mnt/aix-power7/aha` within the same mount |
| `/home/shared` | NFS, if mounted there | `/mnt/aix-power7/home/shared` within the same mount |

The Linux FUSE implementation reports its own filesystem type. Libfuse ignores
the `st_dev` value supplied through its high-level attribute API, and OpenSSH's
SFTP `statvfs` extension does not transmit a filesystem-type name or the remote
mount table. These interfaces explain why a local type check cannot recover the
distinction between AIX JFS2, procfs and NFS in this tree.
Sources: [Linux FUSE implementation](https://github.com/torvalds/linux/blob/master/fs/fuse/inode.c),
[libfuse attributes](https://libfuse.github.io/doxygen/structfuse__operations.html),
[OpenSSH SFTP extensions](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL).

Consequently, a local `find -xdev` is not a reliable way to avoid crossing AIX
mount boundaries inside one SSHFS mount. Likewise, allowing THOR to scan the
SSHFS mount does not give it the source's mount classifications. A particular
THOR release may also have path-based defaults, but those need verification
against the mounted path. This guide uses explicit scope and exclusions instead
of assuming how undocumented scanner internals behave.

File type and filesystem type are different: SFTP can report whether an entry
is a directory, regular file or device without identifying the filesystem that
contains it. Treating only regular files as eligible does not establish that
they are ordinary disk-backed evidence; pseudo filesystems expose kernel data
through file interfaces.

### Inventory the AIX source

Have the AIX administrator record the following on the source. These commands
inspect the system; the bare `mount` command lists mounts without creating one.

```sh
oslevel -s
prtconf
lslpp -L openssh.base.server
mount
lsfs
```

Record the exact AIX technology/service level, processor model and OpenSSH
fileset. Use the `mount` output for the active mount points, VFS types and
options. `lsfs` describes configured filesystems from `/etc/filesystems`; it is
not a substitute for the active mount list. Ask the administrator about
automount roots and cluster-managed storage that might become visible during
the scan. See IBM's [mount command](https://www.ibm.com/docs/en/aix/7.1.0?topic=m-mount-command)
and [lsfs command](https://www.ibm.com/docs/en/aix/7.1.0?topic=l-lsfs-command).

Build the scan scope from that inventory:

| Source content | Treatment for an initial filesystem assessment |
|---|---|
| Local JFS/JFS2 files | Include relevant readable directories after reviewing nested mounts and application data. |
| procfs, normally `/proc` | Exclude the actual mount point. It exposes live process/thread state through kernel interfaces. |
| Device trees, normally `/dev` | Exclude from ordinary content scanning, including raw disk and other device paths. |
| ahafs, commonly `/aha` | Exclude the actual mount point. These are event-monitoring interfaces. |
| NFS and other remote/shared storage | Exclude unless intentionally in scope; assess separately with the storage owner. |
| `namefs` aliases and workload-partition trees | Inspect the backing object and every visible path; an alias can expose ordinary files or a special filesystem. |
| Automount roots, backups, application database volumes and other large stores | Review individually and exclude or schedule separately as appropriate. |

AIX does have `/proc`: IBM describes it as a pseudo filesystem exposing active
process and thread state, not stored files. AHAFS can be mounted somewhere other
than `/aha`. Excluding these default names alone therefore does not cover every
host. Sources: [IBM on procfs](https://www.ibm.com/support/pages/purpose-proc-file-system)
and [AHAFS mount locations](https://www.ibm.com/docs/en/aix/7.2.0?topic=ahafs-setting-up-aix-event-infrastructure).

If the host uses AIX workload partitions (WPARs), record whether the SSH session
reaches the global environment or one partition. IBM documents shared `/usr`,
`/opt` and `/proc` trees using `namefs`, with partition trees normally under
`/wpars` in the global environment. Inspect the backing paths rather than
blanket-excluding all `namefs` mounts. Exclude out-of-scope partition trees; for
included partitions, also exclude their visible aliases of `/proc`, device
trees and other special mounts. A top-level `/proc` exclusion does not cover
`/wpars/part1/proc`. [IBM WPAR filesystems](https://www.ibm.com/docs/en/aix/7.1?topic=wpars-file-systems-system)

Do not copy Linux's exclusion list mechanically. For example, `/tmp` can contain
valuable compromise evidence on AIX and should not be excluded merely because
it holds temporary files. Include relevant configuration, scripts, startup and
scheduled-task files, application code, user directories and logs within the
agreed scope. An exclusion is a recorded coverage gap, not proof that its
contents are harmless.

### Arrange source permissions and SFTP access

#### Root access is possible when the SSH policy allows it

Mounting `root@host:/` is possible if that AIX host permits the chosen root
authentication method and allows an SFTP session. The source's SSH settings,
account restrictions, keys, `Match` rules and possible chroot determine access.
POWER7 itself does not prevent it. IBM documents that its OpenSSH 7.1 and later
defaults permit non-interactive root authentication such as public keys while
restricting root password login. Check the installed configuration rather than
assuming that default. [IBM root login notes](https://www.ibm.com/support/pages/node/705937)

There are two separate identities:

- The **local Linux user** owns the SSHFS mount and runs THOR.
- The **remote AIX account** determines which source files SFTP can read.

Local `sudo` does not turn a remote non-root SFTP session into root. Conversely,
a regular local Linux user can use an authorized remote root SSH key. Mounting
the directory `/` as a non-root account may work but exposes only what that
account can enumerate and read. See [SSHFS access semantics](https://github.com/libfuse/sshfs/blob/master/sshfs.rst).

Do not enable root password login merely to use this procedure. Use an approved
access method. If direct root login is prohibited, options include an account
with sufficient read access, administrator-exported evidence, or a narrowly
configured privileged SFTP service.

#### Test SFTP separately from an interactive SSH shell

From the Linux workstation, use the intended account and SSH key/configuration:

```sh
sftp -v root@aix-power7.example
```

Within SFTP, list a known ordinary directory such as `/etc` and retrieve a small
approved regular file to verify actual reading. Exit the session afterwards.
A successful directory listing does not establish access to every file. If
SFTP is chrooted, its `/` may be the jail's root rather than the AIX system root.

IBM's AIX OpenSSH configuration commonly uses
`Subsystem sftp /usr/sbin/sftp-server`; `internal-sftp` is another supported
configuration. Unlike the NetScaler procedure, an AIX host does not inherently
need a switch to `internal-sftp`. IBM documents a specific external-server
failure involving permissions on `sshd_config`; have the administrator diagnose
such failures against the installed version before changing configuration.
[IBM AIX SFTP troubleshooting](https://www.ibm.com/support/pages/ibm-aix-regular-users-can-ssh-aix-sftp-fails)

#### Optional privileged SFTP through an existing administrative account

Where the administrator has explicitly configured non-interactive `sudo` for
the exact read-only SFTP server command, SSHFS can launch that command remotely.
Verify the executable location and support for `sftp-server -R` on the installed
AIX OpenSSH build first. `internal-sftp` is an sshd subsystem, not an executable
to pass to `sudo`.

After preparing the empty local mount point in the next section, an alternative
to the direct-root mount is:

```sh
sshfs -o ro,nodev,nosuid,noexec,reconnect \
  -o sftp_server='sudo -n /usr/sbin/sftp-server -R' \
  scanadmin@aix-power7.example:/ /mnt/aix-power7
```

This requires a permitted remote command session with no interactive password
or TTY requirement. Shell startup output on stdout can corrupt the SFTP stream.
Use the exact administrative command that was validated, without granting
general passwordless sudo. The server's `-R` option denies write operations;
the client mount's `ro` option alone does not restrict what the SSH credential
could do through another session. See [SSHFS remote server selection](https://github.com/libfuse/sshfs/blob/master/sshfs.rst)
and [OpenSSH read-only SFTP mode](https://man.openbsd.org/sftp-server).

### Prepare the Linux workstation and mount

Use a supported Linux workstation with SSHFS/FUSE, a current full THOR package
and a Forensic Lab License. Keep the THOR package, logs and reports on local
storage outside the mount. This procedure uses a dedicated THOR package so its
exclusions can be kept with the assessment.

Reuse the verified quick-scan mount if it is still mounted. Otherwise, use a
new mount directory. If `/mnt/aix-power7` already exists, stop and choose
an unused path, updating all paths and exclusion expressions below accordingly.
The following commands intentionally do not reuse an existing directory:

```sh
sudo mkdir /mnt/aix-power7 &&
sudo chown "$(id -u):$(id -g)" /mnt/aix-power7
```

After confirming the intended SSH host identity and SFTP access, run the mount
as your regular local user. Use either this direct-root variant or the approved
privileged-server variant above, not both on the same directory.

```sh
sshfs -o ro,nodev,nosuid,noexec,reconnect \
  -o ServerAliveInterval=15,ServerAliveCountMax=3 \
  root@aix-power7.example:/ /mnt/aix-power7
```

Inspect the local mount without recursively walking the source:

```sh
findmnt -T /mnt/aix-power7 -o TARGET,FSTYPE,OPTIONS
stat -f -c '%T' /mnt/aix-power7
```

Expect the mount table to identify SSHFS/FUSE, not AIX JFS2. Confirm that the
target is exactly `/mnt/aix-power7` and that it is read-only. Run THOR as the
same local user; the example does not need `allow_other`.

The mount's `nodev`, `nosuid` and `noexec` settings control local use of mounted
entries. They do not exclude remote `/dev` or `/proc` from reads. Reading source
files can still update AIX access times, and SSH activity can create source
logs. A read-only SSHFS mount is neither a snapshot nor a forensic write blocker.

### Configure exclusions using the local mounted paths

In the dedicated THOR package, add the following expressions to
`config/directory-excludes.cfg`, preserving its existing entries:

```text
^/mnt/aix-power7/proc($|/)
^/mnt/aix-power7/dev($|/)
^/mnt/aix-power7/aha($|/)
```

These are regular expressions. Add exclusions for every other out-of-scope
mount or directory from the AIX inventory, using its actual local path. For
example, if `/home/shared` is an excluded NFS mount, add:

```text
^/mnt/aix-power7/home/shared($|/)
```

THOR applies directory exclusions to the **real workstation path before virtual
mapping**. A rule anchored at `^/proc` does not cover
`/mnt/aix-power7/proc`, even with `--virtual-map /mnt/aix-power7:/`.
These are THOR scanner configuration expressions; do not substitute the Go
collector's `--exclude` glob syntax. [THOR directory exclusions](https://thor-manual.nextron-systems.com/en/latest/usage/configuration.html#files-and-directories)

Review nested mounts even inside selected paths such as `/home` or `/var`.
Exclude automount roots before traversal can trigger additional remote mounts.
Changes to the source mount layout during a scan require a scope review.

Avoid enabling SSHFS `follow_symlinks` or THOR `--follow-symlinks` for the initial
assessment. A link can introduce another path to an excluded tree or resolve
outside the intended source view. Verify the installed versions' link handling
before enabling traversal; add reviewed target directories explicitly instead.

### Run a staged THOR file scan

First verify exclusions on harmless test directories with the same THOR release.
Use files with a harmless custom detection marker inside and outside the
excluded directory, and inspect diagnostics to establish both inclusion and
exclusion. A scan with no alerts is not sufficient evidence that exclusions
worked. Do not test exclusion behavior by reading live `/proc` entries.

Start with `/etc` after checking its mount inventory. From the dedicated THOR
package on Linux:

```sh
mountpoint -q /mnt/aix-power7 &&
./thor-linux-64 --lab \
  -p /mnt/aix-power7/etc \
  --virtual-map /mnt/aix-power7:/ \
  -j aix-power7-example --threads 0
```

Replace the result hostname with the actual source identifier. The mount check
prevents an absent mount from turning into an empty local-directory scan; also
verify its identity using `findmnt` as above. Review THOR's startup settings,
file counts, exclusions and read errors before widening the assessment.

After that check, add reviewed paths using repeated `-p` arguments, for example:

```sh
mountpoint -q /mnt/aix-power7 &&
./thor-linux-64 --lab \
  -p /mnt/aix-power7/etc \
  -p /mnt/aix-power7/usr \
  -p /mnt/aix-power7/var \
  -p /mnt/aix-power7/tmp \
  -p /mnt/aix-power7/home \
  -p /mnt/aix-power7/opt \
  --virtual-map /mnt/aix-power7:/ \
  -j aix-power7-example --threads 0
```

This is an example selection, not a complete AIX assessment profile. Omit paths
that do not exist, narrow large trees and add relevant application directories.
Inventory-approved exclusions remain necessary for nested mounts. A scan of
the entire mounted `/` should only follow successful exclusion validation and
review of the whole tree.

`--lab` is a filesystem-analysis preset requiring a Lab License. It includes
intense scanning and disables resource safeguards. The examples use all local
cores; see the quick procedure's thread guidance for tuning concurrency.
Setting a thread count does not cap source CPU, disk I/O or bandwidth. THOR
resource measurements run on Linux, not on the AIX source. Have the AIX
administrator observe source load and pause or narrow the scan if needed. Source SSH
encryption and file reads still consume resources.
See [THOR lab options](https://thor-manual.nextron-systems.com/en/latest/usage/flags.html#scan-modes)
and [lab licensing](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#forensic-lab-license).

### Limits that can reduce coverage or stop a scan

| Limitation | Consequence and response |
|---|---|
| Old SSH algorithms or authentication methods | A modern client may fail negotiation. Diagnose with verbose SSH/SFTP output; prefer an AIX OpenSSH update. If a legacy exception is necessary, scope it to the individual host and keep host-key verification. See [OpenSSH legacy guidance](https://www.openssh.org/legacy.html). |
| NFS access through AIX | Root on AIX can be mapped to an anonymous identity by the NFS server. A root SSH session does not bypass those export permissions. See [IBM NFS root authentication](https://www.ibm.com/support/pages/aix-nfs-authentication-root-user). |
| AIX Encrypted File System | Successful SSH public-key login does not necessarily load the EFS keys needed to decrypt files. Validate actual reads in the SFTP session; file mode bits or root login alone are insufficient evidence of coverage. See [IBM EFS and SSH authentication](https://www.ibm.com/support/pages/aix-incorporating-efs-ssh-public-key-authentication). |
| Restricted namespace or unavailable storage | A chroot, workload-partition view or unmounted filesystem can omit evidence. Record the source namespace and excluded/unavailable volumes. |
| Large databases, backups, sparse files and active application files | Transfers can be expensive or inconsistent. Select relevant file evidence and arrange separate acquisition for data requiring a stable view. File-size limits are not a substitute for path exclusions. |
| Broken connections or stale remote storage | Reads may fail or wait. SSH keepalives and reconnect help transport recovery but do not guarantee a deadline for a blocked source filesystem operation. Review and repeat incomplete portions. |
| Changes during enumeration or reading | SSHFS caching and a live source do not provide a point-in-time image. Use an appropriate snapshot/export workflow when consistency is required. |

SSHFS also does not preserve all forensic metadata. In SSHFS 3.7.3's SFTP v3
attribute conversion, `ctime` is populated from `mtime` and the link count is
set to one. Do not interpret the mounted `ctime` as native AIX inode-change time
or use the mounted view as an authoritative record of hard links. Capture
required AIX metadata separately; do not assume native ACLs or extended
attributes have been preserved. [SSHFS 3.7.3 attribute conversion](https://github.com/libfuse/sshfs/blob/sshfs-3.7.3/sshfs.c)

The useful result is THOR analysis of accessible file contents and paths,
including applicable signatures and supported artifact parsing. This procedure
does not provide native AIX process, memory, kernel or configuration-state
inspection, recover deleted/unallocated data, or establish native THOR support
for POWER7. The source OS and SFTP server also supply the evidence; suspected
tampering at that layer calls for independent acquisition.

### Validate and close the assessment

Before expanding a pilot to other hosts, retain:

- AIX level, CPU model, OpenSSH fileset, source namespace and the active mount
  inventory; Linux, SSHFS and THOR versions and signature date.
- The source account and tested read scope, selected paths, exclusions and
  evidence that the exclusion fixture behaved as intended.
- A successful read of an approved sample from each filesystem included in
  scope, with a source-side hash comparison where practical.
- Scan settings, source-load observations, exit status, counts, read errors,
  interrupted portions and any remaining coverage gaps.

After THOR exits and releases its files, unmount on Linux:

```sh
fusermount3 -u /mnt/aix-power7
```

Use `fusermount -u` on installations that provide that command instead. Do not
force-unmount an active scan. Keep results and the source inventory together;
a successful mount or a clean scan alone does not establish complete coverage.
