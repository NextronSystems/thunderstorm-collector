# Scanning AIX on POWER7 with THOR over SSHFS

THOR runs on a Linux analysis workstation and reads an AIX system on POWER7
over SSHFS (SSH/SFTP). Nothing is installed on AIX: no THOR binary, Go
collector, FUSE driver or SSHFS. AIX reads its own filesystems and serves the
file contents, so the workstation needs no JFS/JFS2 driver.

> [!NOTE]
> Not yet tested against a live AIX/POWER7 host. This guide is based on IBM
> and upstream documentation and source inspection.

## Choose a Route

| Route | Use it when | What THOR scans |
|---|---|---|
| [1. Quick incident-response scan](#1-quick-incident-response-scan-using-a-path-allowlist) | Incident response; results needed fast | A short path allowlist plus the affected application's files |
| [2. Thorough assessment](#2-thorough-assessment-with-mount-inventory-and-exclusions) | Wider coverage, uncertain or nested mounts, or a repeatable assessment | Larger trees or all of `/`, after a mount inventory and exclusions |

A successful quick scan can be the first stage of a thorough assessment.

**SSHFS does not reproduce the AIX mount table on Linux.** The quick route
therefore limits where THOR starts; the thorough route also excludes paths
inside the larger scope. [Details](#what-sshfs-preserves-and-what-it-hides).

For alternatives and licensing, see
[Choosing a THOR scanning approach](../../docs/SCANNING_APPROACHES.md).

## Before You Start

| Requirement | Detail |
|---|---|
| Linux workstation | Supported Linux with SSHFS/FUSE and a current full THOR package |
| License | **Forensic Lab License**: the `--lab` option requires it |
| AIX account | An authorized account with read access, preferably **root**, that can open an SFTP session. See [source permissions and SFTP access](#arrange-source-permissions-and-sftp-access) |
| AIX administrator | Checks the `mount` output and watches source load during the scan |
| Local storage | Keep the THOR package, logs and reports on local storage outside the mount |

Run SSHFS and THOR as the **same local user**. The examples mount the source at
`/mnt/aix-power7` and use the hostname `aix-power7.example`; replace it.

## 1. Quick incident-response scan using a path allowlist

1. **Choose a small set of paths.** Leave out directories that do not exist.

   | AIX source path | Why include it in a first pass? |
   |---|---|
   | `/etc` | Configuration and startup files, including [`/etc/inittab`](https://www.ibm.com/docs/en/aix/7.1.0?topic=files-inittab-file). |
   | `/tmp` and [`/var/tmp`](https://www.ibm.com/docs/en/aix/7.2.0?topic=tree-var-file-system) | Temporary files, possible dropped payloads and staging scripts. `/usr/tmp` normally aliases `/var/tmp`. |
   | `/var/spool/cron` | [Cron and at job files](https://www.ibm.com/docs/en/aix/7.1.0?topic=c-cron-daemon), which can contain persistence commands. |
   | `/usr/bin`, `/usr/sbin`, `/sbin` | System programs and scripts; include them when checking for dropped or modified executables. |
   | `/usr/lib`, `/usr/local` | System libraries and locally installed software. These add coverage and scan time. |
   | Web/application directories | Start with `/usr/IBM/HTTPServer` and `/usr/IBM/WebSphere/AppServer/profiles` if installed. Prioritize the affected application. |

   For IBM HTTP Server, read `/usr/IBM/HTTPServer/conf/httpd.conf` first and
   include its configured document roots, aliases and script locations.
   Installation paths can differ; `/srv` is not a universal AIX webroot.
   WebSphere applications usually also need their profile's `installedApps`
   tree. More layouts: [application locations and additional scan paths](#application-locations-and-additional-scan-paths).

   These ordinary file trees are normally suitable for read-only scanning. The
   short list limits work; it does not mean other directories are dangerous to
   read. Large trees take longer and cause more source I/O.

2. **Have the AIX administrator check `mount` output for the selected paths
   only**, and for mounts beneath them. Confirm ordinary file trees without
   unexpected remote, pseudo or automounted subtrees. Resolve aliases used as
   scan roots. Leave uncertain subtrees out of this pass.

   No full-host inventory or custom exclusion file is needed for the confirmed
   subtrees.

3. **Mount the source read-only** on Linux. Use an unused mount directory, or
   reuse an existing verified mount.

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

   Confirm target `/mnt/aix-power7`, type SSHFS/FUSE and read-only options.
   Mounting `/` makes the tree available; it does not require scanning all of
   it.

4. **Scan only the selected directories** from the local THOR package. Before
   running it:

   - Remove absent or unconfirmed paths.
   - Add `-p` for each confirmed application directory, for example
     `-p /mnt/aix-power7/usr/IBM/HTTPServer/htdocs` if that is the active
     webroot.
   - Replace the result hostname after `-j` with the actual source identifier.

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

   - Repeated `-p` arguments restrict the recursive scan to those trees. Use
     relevant application subdirectories to limit scan time. Leave a scan of
     the entire mounted `/` to the thorough route.
   - Keep SSHFS `follow_symlinks` and THOR `--follow-symlinks` disabled, and
     keep existing exclusions.
   - Top-level `/proc`, `/dev`, `/aha` and `/wpars` are outside this
     selection. Nested special mounts still need the check in step 2.
   - `--threads 0` uses all cores of the **Linux workstation**. If the
     administrator sees too much source load, reduce to `--threads 2` or
     `--threads 4`. See [threads and source load](#threads-and-source-load).

5. **Review and record the results.** Check file counts and read errors. Save
   the findings with the selected paths, and record the application and
   storage paths you left out.

6. **Unmount** after THOR exits:

   ```sh
   fusermount3 -u /mnt/aix-power7
   ```

This pass omits user homes, logs and application trees unless you added them.
THOR can flag suspicious configuration content; proving arbitrary changes also
needs a baseline or manual review. Widen coverage as the incident requires.

## 2. Thorough assessment with mount inventory and exclusions

Use this route to widen coverage, handle uncertain or nested mounts, or prepare
a repeatable assessment. A quick scan can come first; reuse its verified mount
if it is still available.

1. **Inventory the AIX source.** Have the AIX administrator run these commands
   on AIX. They only inspect the system; the bare `mount` command lists mounts
   without creating one.

   ```sh
   oslevel -s
   prtconf
   lslpp -L openssh.base.server
   mount
   lsfs
   ```

   - Record the exact AIX technology/service level, processor model and
     OpenSSH fileset.
   - Take the active mount points, VFS types and options from `mount`. `lsfs`
     shows the configured filesystems from `/etc/filesystems`; it does not
     replace the active mount list.
   - Ask about automount roots and cluster-managed storage that might become
     visible during the scan.

   Sources: [IBM mount command](https://www.ibm.com/docs/en/aix/7.1.0?topic=m-mount-command) · [IBM lsfs command](https://www.ibm.com/docs/en/aix/7.1.0?topic=l-lsfs-command)

2. **Decide the scope** from the inventory:

   | Source content | Treatment for an initial filesystem assessment |
   |---|---|
   | Local JFS/JFS2 files | **Include** relevant readable directories after reviewing nested mounts and application data. |
   | procfs, normally `/proc` | **Exclude** the actual mount point. AIX `/proc` is a pseudo filesystem exposing live process and thread state, not stored files. |
   | Device trees, normally `/dev` | **Exclude** from ordinary content scanning, including raw disk and other device paths. |
   | ahafs, commonly `/aha` | **Exclude** the actual mount point. These are event-monitoring interfaces. AHAFS can be mounted elsewhere. |
   | NFS and other remote/shared storage | **Exclude** unless intentionally in scope; assess separately with the storage owner. |
   | `namefs` aliases and workload-partition trees | **Inspect** the backing object and every visible path; an alias can expose ordinary files or a special filesystem. See [workload partitions](#workload-partitions-wpars). |
   | Automount roots, backups, application database volumes and other large stores | **Review** individually; exclude or schedule separately. |

   - Use the actual mount points from the inventory; default names alone do
     not cover every host.
   - Do not copy Linux's exclusion list: `/tmp`, for example, can hold
     valuable compromise evidence on AIX.
   - Include relevant configuration, scripts, startup and scheduled-task
     files, application code, user directories and logs within the agreed
     scope. To add paths, use [application locations](#common-application-locations)
     and [more ordinary directories](#more-ordinary-directories-can-be-included).

   An exclusion is a recorded coverage gap, not proof that its contents are
   harmless.

   Sources: [IBM on procfs](https://www.ibm.com/support/pages/purpose-proc-file-system) · [AHAFS mount locations](https://www.ibm.com/docs/en/aix/7.2.0?topic=ahafs-setting-up-aix-event-infrastructure)

3. **Test SFTP itself, not just an interactive SSH shell.** From the Linux
   workstation, use the intended account and SSH key or configuration:

   ```sh
   sftp -v root@aix-power7.example
   ```

   In the session, list a known ordinary directory such as `/etc`, retrieve a
   small approved regular file to prove actual reading, then exit.

   - A directory listing does not prove access to every file.
   - If SFTP is chrooted, its `/` may be the jail's root, not the AIX root.
   - If root login is not allowed or SFTP fails, see
     [source permissions and SFTP access](#arrange-source-permissions-and-sftp-access).

4. **Mount the source read-only.** Reuse the verified quick-scan mount if it is
   still mounted. Otherwise create a new mount directory; the command
   intentionally fails on an existing one. If `/mnt/aix-power7` exists, choose
   an unused path and change all paths and exclusions below.

   ```sh
   sudo mkdir /mnt/aix-power7 &&
   sudo chown "$(id -u):$(id -g)" /mnt/aix-power7
   ```

   After confirming the SSH host identity, mount as your regular local user.
   Use this direct-root command or the
   [privileged SFTP alternative](#optional-privileged-sftp-through-an-existing-administrative-account),
   not both on the same directory.

   ```sh
   sshfs -o ro,nodev,nosuid,noexec,reconnect \
     -o ServerAliveInterval=15,ServerAliveCountMax=3 \
     root@aix-power7.example:/ /mnt/aix-power7
   ```

   Inspect the mount without recursively walking the source:

   ```sh
   findmnt -T /mnt/aix-power7 -o TARGET,FSTYPE,OPTIONS
   stat -f -c '%T' /mnt/aix-power7
   ```

   Expect SSHFS/FUSE (not AIX JFS2), target exactly `/mnt/aix-power7` and
   read-only options. `allow_other` is not needed, because THOR runs as the
   same local user.

5. **Configure exclusions** in a dedicated THOR package, so the exclusions stay
   with this assessment. Add these regular expressions to
   `config/directory-excludes.cfg`, keeping its existing entries:

   ```text
   ^/mnt/aix-power7/proc($|/)
   ^/mnt/aix-power7/dev($|/)
   ^/mnt/aix-power7/aha($|/)
   ```

   Add one for every other out-of-scope mount or directory from the inventory,
   using its local path. For example, if `/home/shared` is an excluded NFS
   mount:

   ```text
   ^/mnt/aix-power7/home/shared($|/)
   ```

   - **Use the local mounted path.** THOR applies directory exclusions to the
     real workstation path **before** virtual mapping. A rule anchored at
     `^/proc` does not match `/mnt/aix-power7/proc`, even with
     `--virtual-map /mnt/aix-power7:/`.
   - These are THOR scanner expressions; do not use the Go collector's
     `--exclude` glob syntax.
   - Review nested mounts inside selected paths such as `/home` or `/var`.
     Exclude automount roots before traversal can trigger more remote mounts.
   - Keep SSHFS `follow_symlinks` and THOR `--follow-symlinks` off for the
     initial assessment: a link can lead into an excluded tree or outside the
     source view. Add reviewed link targets as explicit paths. Verify the
     installed versions' link handling before enabling traversal.

   Source: [THOR directory exclusions](https://thor-manual.nextron-systems.com/en/latest/usage/configuration.html#files-and-directories)

6. **Test the exclusions** on harmless test directories with the same THOR
   release. Put files with a harmless custom detection marker inside and
   outside the excluded directory. Check the diagnostics for both inclusion
   and exclusion; a scan without alerts does not prove the exclusions worked.
   Do not test exclusions by reading live `/proc` entries.

7. **Scan `/etc` first**, after checking its mount inventory. From the
   dedicated THOR package, replacing the result hostname:

   ```sh
   mountpoint -q /mnt/aix-power7 &&
   ./thor-linux-64 --lab \
     -p /mnt/aix-power7/etc \
     --virtual-map /mnt/aix-power7:/ \
     -j aix-power7-example --threads 0
   ```

   The `mountpoint` check keeps an absent mount from turning into a scan of
   the empty local directory; also confirm the mount with `findmnt` as in
   step 4. Review THOR's startup settings, file counts, exclusions and read
   errors before widening.

8. **Widen the scan** with repeated `-p` arguments, for example:

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

   - This is an example selection, not a complete AIX assessment profile.
     Omit paths that do not exist, narrow large trees and add relevant
     application directories.
   - The inventory-based exclusions are still needed for nested mounts.
   - Scan the entire mounted `/` only after the exclusion test succeeded and
     the whole tree was reviewed.
   - If the source mount layout changes during the scan, review the scope.
   - Have the AIX administrator watch source load and pause or narrow the
     scan if needed. See [threads and source load](#threads-and-source-load).

9. **Unmount** on Linux after THOR exits and releases its files:

   ```sh
   fusermount3 -u /mnt/aix-power7
   ```

   Use `fusermount -u` on installations that provide that command instead.
   Do not force-unmount an active scan.

## Verify

Check that `findmnt` shows an SSHFS/FUSE read-only mount at the intended
target, and that THOR's startup settings, file counts, exclusions and read
errors match the scope.

Before expanding a pilot to other hosts, keep these records with the results:

- AIX level, CPU model, OpenSSH fileset, source namespace and the active mount
  inventory; Linux, SSHFS and THOR versions and signature date.
- The source account and tested read scope, selected paths, exclusions and
  evidence that the exclusion test behaved as intended.
- A successful read of an approved sample from each filesystem in scope, with
  a source-side hash comparison where practical.
- Scan settings, source-load observations, exit status, counts, read errors,
  interrupted portions and any remaining coverage gaps.

A successful mount or a clean scan alone does not prove complete coverage.

## Background

### Why SSHFS for AIX on POWER7

- **Nothing runs on AIX.** THOR runs on the Linux workstation, so the AIX CPU
  architecture does not need to support the scanner binary. AIX only serves
  files over SFTP.
- **POWER7 adds no special requirement.** It does not prevent a root SFTP
  session, and there is no one-thread requirement.
- **Licensing:** `--lab` is a filesystem-analysis preset that requires a
  Forensic Lab License.

The useful result is THOR's analysis of accessible file contents and paths,
including applicable signatures and supported artifact parsing. This route
does not provide:

- native AIX process, memory, kernel or configuration-state inspection;
- recovery of deleted or unallocated data;
- native THOR support for POWER7.

The source OS and its SFTP server supply the evidence. If tampering at that
layer is suspected, use independent acquisition.

Sources: [THOR lab options](https://thor-manual.nextron-systems.com/en/latest/usage/flags.html#scan-modes) · [Forensic Lab License](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#forensic-lab-license)

### Threads and source load

`--lab` includes intense scanning and disables resource safeguards.
`--threads 0` uses all cores of the Linux workstation, as `--lab` normally
does.

- `--threads 1` is an optional load reduction. If source load is too high,
  reduce to `--threads 2` or `--threads 4`.
- A thread count does not cap source CPU, disk I/O or bandwidth. THOR measures
  resources on Linux, not on the AIX source.
- SSH encryption and file reads still consume source resources. SSHFS,
  network latency, storage or SSH encryption can also limit the speedup.
- Have the AIX administrator observe source load and pause or narrow the scan
  if needed.

Sources: [THOR thread and lab options](https://thor-manual.nextron-systems.com/en/latest/usage/flags.html)

### Source impact of a read-only mount

No pathname guarantees zero operational impact on every host. Reading ordinary
files through a read-only mount does not execute them or write their contents.
It does consume source I/O, SSH CPU and network capacity, and it can update
AIX access times. SSH activity can create source logs.

The mount's `nodev`, `nosuid` and `noexec` settings control local use of
mounted entries. They do not stop reads of remote `/dev` or `/proc`.

**A read-only SSHFS mount is neither a snapshot nor a forensic write blocker.**

### Application locations and additional scan paths

Use these references to widen a scan without starting with the whole
filesystem. They are documented defaults or layouts to check, not a promise
that every AIX host has them. Substitute the actual product and profile paths,
then add each directory with `-p` and the `/mnt/aix-power7` prefix.

#### Common application locations

| Software or layout | Where to look on AIX | Useful scan targets |
|---|---|---|
| IBM HTTP Server | `/usr/IBM/HTTPServer` (documented AIX default) | `conf`, `htdocs`, and `cgi-bin` if present; every configured document root, script alias and upload directory outside the installation |
| Traditional WebSphere Application Server | `/usr/IBM/WebSphere/AppServer`; default profiles under `profiles/<profile>` | In each relevant profile: `installedApps`, `config`, `temp` and `wstemp`. Deployed code, including JSP files, can be beneath `installedApps/<cell>/<application>.ear/` |
| Apache HTTP Server built with the upstream AIX layout | `/opt/httpd` and `/var/httpd`; configuration under `/etc/httpd` or `/var/httpd/etc` | Document roots, script aliases and application content from the configuration. The layout is build-dependent, not a default for every Apache package |
| AIX Toolbox software | `/opt/freeware` | Installed programs, libraries and configuration; application content elsewhere when configured |
| Other vendor or locally installed applications | Start with `/opt` and `/usr/local`; product-specific or administrator-chosen locations may be elsewhere | The affected product's code, scripts, configuration, upload and working directories. Select large database or backup stores separately |

Non-root installations can be under the installing user's home, and profiles
or application repositories can be relocated.

Example: for a profile named `AppSrv01` in the default installation, scan
`/mnt/aix-power7/usr/IBM/WebSphere/AppServer/profiles/AppSrv01/installedApps`
and add its sibling `config`, `temp` and `wstemp` directories as separate
paths. Scanning only the HTTP server's `htdocs` can miss application code that
WebSphere serves behind it.

IBM documents the `htdocs` and `cgi-bin` content directories, `installedApps`,
`config` and `wstemp`, and compiled JSP files under the profile's `temp` tree.

Sources: [IBM AIX product and profile defaults](https://www.ibm.com/docs/en/was-nd/9.0.5?topic=systems-websphere-application-server-default-directories) · [IBM HTTP server configuration location](https://www.ibm.com/docs/en/ibm-http-server/8.5.5?topic=server-configuring-http) · [IBM AIX HTTP Server notes](https://www.ibm.com/docs/en/aix/7.1.0?topic=notes-aix-710-expansion-pack-release) · [IBM deployment description](https://www.ibm.com/support/pages/node/1081077) · [IBM temporary-directory reference](https://www.ibm.com/support/pages/things-know-deleting-temporary-cache-and-log-files-websphere-application-server) · [Apache's AIX layout](https://cwiki.apache.org/confluence/spaces/HTTPD/pages/115522217/AIXPlatform) · [AIX Toolbox paths](https://www.ibm.com/support/pages/aix-toolbox-open-source-software-get-started) · [IBM AIX directory structure](https://www.ibm.com/docs/en/ssw_aix_72/devicemanagement/filesys_struct.html)

#### More ordinary directories can be included

| Additional scope | What it adds and what to check |
|---|---|
| `/usr/bin`, `/usr/sbin`, `/sbin`, `/usr/lib` | System executables, scripts and libraries (in the quick-route example). On standard layouts, `/bin` and `/lib` alias `/usr/bin` and `/usr/lib`; scan the real paths, not the aliases again. |
| `/usr/local`, `/opt/freeware` | Local software and open-source packages. Include the entire tree if its size is acceptable, or select the relevant product. |
| `/usr/IBM`, `/opt/IBM`, or the whole `/opt` | Broader vendor software, including products not listed above. Valid candidates when present and in scope; narrow them for speed if they hold large installations or data stores. |
| Selected user and service-account homes | Shell startup files, SSH configuration, scripts and user-installed applications. Use each account's configured home; do not assume root's home is `/root`. `/home` can be NFS-backed or automounted. |
| Selected application logs and regular files under `/var/adm` or `/var/log`, where present | Evidence beyond executable content. Prefer relevant log directories or files: `/var/adm` also contains special entries such as the cron FIFO, and logs can be large. |

`/usr` and `/opt` are not inherently unsafe scan roots. Include them when their
contents, nested mounts and scan volume are acceptable. The focused mount check
applies to each added subtree. The explicit exclusions still cover pseudo
filesystems, devices and out-of-scope storage.

Sources: [IBM AIX directory structure](https://www.ibm.com/docs/en/ssw_aix_72/devicemanagement/filesys_struct.html) · [IBM cron file locations](https://www.ibm.com/docs/en/aix/7.1.0?topic=c-cron-daemon)

### What SSHFS preserves and what it hides

SSHFS exposes a directory tree through SFTP. On Linux, it is normally one
`fuse.sshfs` mount, even when that tree crosses several filesystems on AIX:

| Example source path | Possible AIX filesystem | Workstation view under one SSHFS mount |
|---|---|---|
| `/usr` | JFS or JFS2 | `/mnt/aix-power7/usr` within `fuse.sshfs` |
| `/proc` | procfs | `/mnt/aix-power7/proc` within the same mount |
| `/aha` | ahafs, if mounted there | `/mnt/aix-power7/aha` within the same mount |
| `/home/shared` | NFS, if mounted there | `/mnt/aix-power7/home/shared` within the same mount |

A local check cannot recover the difference between AIX JFS2, procfs and NFS:

- The Linux FUSE implementation reports its own filesystem type.
- libfuse ignores the `st_dev` value supplied through its high-level attribute
  API.
- OpenSSH's SFTP `statvfs` extension sends neither a filesystem-type name nor
  the remote mount table.

As a result:

- A local `find -xdev` does not reliably stop at AIX mount boundaries inside
  one SSHFS mount.
- THOR scanning the SSHFS mount does not get the source's mount
  classifications. A THOR release may have path-based defaults, but those need
  verification against the mounted path. This guide uses explicit scope and
  exclusions instead of relying on undocumented scanner internals.
- File type is not filesystem type. SFTP can report whether an entry is a
  directory, regular file or device, but not which filesystem contains it.
  Pseudo filesystems expose kernel data through file interfaces, so treating
  only regular files as eligible does not make them ordinary disk-backed
  evidence.

Sources: [Linux FUSE implementation](https://github.com/torvalds/linux/blob/master/fs/fuse/inode.c) · [libfuse attributes](https://libfuse.github.io/doxygen/structfuse__operations.html) · [OpenSSH SFTP extensions](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL)

### Workload partitions (WPARs)

If the host uses AIX workload partitions, record whether the SSH session
reaches the global environment or one partition. IBM documents shared `/usr`,
`/opt` and `/proc` trees using `namefs`, with partition trees normally under
`/wpars` in the global environment.

- Inspect the backing paths instead of excluding all `namefs` mounts.
- Exclude out-of-scope partition trees.
- For included partitions, also exclude their visible aliases of `/proc`,
  device trees and other special mounts. A top-level `/proc` exclusion does
  not cover `/wpars/part1/proc`.

Source: [IBM WPAR filesystems](https://www.ibm.com/docs/en/aix/7.1?topic=wpars-file-systems-system)

### Arrange source permissions and SFTP access

#### Root access is possible when the SSH policy allows it

Mounting `root@host:/` works if the AIX host permits the chosen root
authentication method and allows an SFTP session. The source's SSH settings,
account restrictions, keys, `Match` rules and any chroot decide this; POWER7
does not prevent it.

IBM documents that its OpenSSH 7.1 and later defaults permit non-interactive
root authentication, such as public keys, while restricting root password
login. Check the installed configuration instead of assuming that default.

There are two separate identities:

- The **local Linux user** owns the SSHFS mount and runs THOR.
- The **remote AIX account** decides which source files SFTP can read.

Local `sudo` does not turn a remote non-root SFTP session into root. A regular
local Linux user can use an authorized remote root SSH key. Mounting `/` as a
non-root account may work, but exposes only what that account can list and
read.

> [!WARNING]
> Do not enable root password login just to use this procedure. Use an
> approved access method. If direct root login is prohibited, use an account
> with enough read access, evidence exported by the administrator, or a
> narrowly configured privileged SFTP service (below).

Sources: [IBM root login notes](https://www.ibm.com/support/pages/node/705937) · [SSHFS access semantics](https://github.com/libfuse/sshfs/blob/master/sshfs.rst)

#### SFTP server configuration

IBM's AIX OpenSSH configuration commonly uses
`Subsystem sftp /usr/sbin/sftp-server`; `internal-sftp` is another supported
configuration. Unlike the NetScaler procedure, AIX does not inherently need a
switch to `internal-sftp`.

IBM documents a specific external-server failure involving permissions on
`sshd_config`. Have the administrator diagnose such failures against the
installed version before changing the configuration.

Source: [IBM AIX SFTP troubleshooting](https://www.ibm.com/support/pages/ibm-aix-regular-users-can-ssh-aix-sftp-fails)

#### Optional privileged SFTP through an existing administrative account

Use this only where the administrator has explicitly configured
non-interactive `sudo` for the exact read-only SFTP server command. SSHFS then
starts that command remotely.

First verify the executable location and that the installed AIX OpenSSH build
supports `sftp-server -R`. `internal-sftp` is an sshd subsystem, not an
executable to pass to `sudo`.

After preparing the empty local mount point (thorough route, step 4), mount
with this command instead of the direct-root one:

```sh
sshfs -o ro,nodev,nosuid,noexec,reconnect \
  -o sftp_server='sudo -n /usr/sbin/sftp-server -R' \
  scanadmin@aix-power7.example:/ /mnt/aix-power7
```

- The account needs a permitted remote command session with no interactive
  password or TTY requirement.
- Shell startup output on stdout can corrupt the SFTP stream.
- Use the exact validated command; do not grant general passwordless sudo.
- The server's `-R` option denies write operations. The client's `ro` option
  alone does not restrict what the SSH credential could do in another session.

Sources: [SSHFS remote server selection](https://github.com/libfuse/sshfs/blob/master/sshfs.rst) · [OpenSSH read-only SFTP mode](https://man.openbsd.org/sftp-server)

### Limits that can reduce coverage or stop a scan

| Limitation | Consequence and response |
|---|---|
| Old SSH algorithms or authentication methods | A modern client may fail negotiation. Diagnose with verbose SSH/SFTP output; prefer an AIX OpenSSH update. Scope any legacy exception to the one host and keep host-key verification. See [OpenSSH legacy guidance](https://www.openssh.org/legacy.html). |
| NFS access through AIX | The NFS server can map AIX root to an anonymous identity; a root SSH session does not bypass export permissions. See [IBM NFS root authentication](https://www.ibm.com/support/pages/aix-nfs-authentication-root-user). |
| AIX Encrypted File System | SSH public-key login does not necessarily load the EFS keys needed to decrypt files. Validate actual reads over SFTP; mode bits or root login do not prove coverage. See [IBM EFS and SSH authentication](https://www.ibm.com/support/pages/aix-incorporating-efs-ssh-public-key-authentication). |
| Restricted namespace or unavailable storage | A chroot, workload-partition view or unmounted filesystem can omit evidence. Record the source namespace and excluded/unavailable volumes. |
| Large databases, backups, sparse files and active application files | Transfers can be expensive or inconsistent. Select relevant files; acquire data that needs a stable view separately. File-size limits do not replace path exclusions. |
| Broken connections or stale remote storage | Reads may fail or wait. Keepalives and `reconnect` help the transport recover but set no deadline for a blocked source filesystem operation. Review and repeat incomplete portions. |
| Changes during enumeration or reading | SSHFS caching and a live source give no point-in-time image. Use a snapshot or export workflow when consistency is required. |

#### Metadata

SSHFS does not preserve all forensic metadata. In SSHFS 3.7.3's SFTP v3
attribute conversion, `ctime` is filled from `mtime` and the link count is set
to one.

- Do not read the mounted `ctime` as the native AIX inode-change time.
- Do not use the mounted view as an authoritative record of hard links.
- Do not assume native ACLs or extended attributes are preserved.
- Capture required AIX metadata separately.

Source: [SSHFS 3.7.3 attribute conversion](https://github.com/libfuse/sshfs/blob/sshfs-3.7.3/sshfs.c)
