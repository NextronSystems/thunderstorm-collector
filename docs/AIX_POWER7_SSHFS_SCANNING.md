# Scanning AIX on POWER7 with THOR over SSHFS

An AIX system on POWER7 can expose files over SSH/SFTP to THOR running on a
supported Linux analysis workstation. No THOR binary, Go collector, FUSE driver
or SSHFS installation is required on AIX. AIX reads its own filesystems and
serves the file contents; the Linux workstation does not need a JFS/JFS2 driver.

The main limitation is filesystem visibility: **SSHFS does not reproduce the
AIX mount table on Linux. Do not rely on automatic filesystem-type exclusions
to protect remote `/proc`, monitoring filesystems or network mounts.** Inventory
the source, select the paths to assess and configure explicit path exclusions.

This procedure is based on IBM and upstream documentation and source inspection.
It has not been tested against a live AIX/POWER7 host during its preparation.
Validate the installed AIX, OpenSSH, SSHFS and THOR versions using the acceptance
steps below before using a broad scan on a production system.

For the alternatives and licensing overview, see
[Choosing a THOR scanning approach](SCANNING_APPROACHES.md).

## What SSHFS preserves and what it hides

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

## Inventory the AIX source before mounting it

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

## Arrange source permissions and SFTP access

### Root access is possible when the SSH policy allows it

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

### Test SFTP separately from an interactive SSH shell

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

### Optional privileged SFTP through an existing administrative account

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

## Prepare the Linux workstation and mount

Use a supported Linux workstation with SSHFS/FUSE, a current full THOR package
and a Forensic Lab License. Keep the THOR package, logs and reports on local
storage outside the mount. This procedure uses a dedicated THOR package so its
exclusions can be kept with the assessment.

Use a new mount directory. If `/mnt/aix-power7` already exists, stop and choose
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

## Configure exclusions using the local mounted paths

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

## Run a staged THOR file scan

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
  -j aix-power7-example --threads 1
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
  -j aix-power7-example --threads 1
```

This is an example selection, not a complete AIX assessment profile. Omit paths
that do not exist, narrow large trees and add relevant application directories.
Inventory-approved exclusions remain necessary for nested mounts. A scan of
the entire mounted `/` should only follow successful exclusion validation and
review of the whole tree.

`--lab` is a filesystem-analysis preset requiring a Lab License. It includes
intense scanning and disables resource safeguards. `--threads 1` reduces scan
concurrency but does not cap source CPU, disk I/O or bandwidth. THOR resource
measurements run on Linux, not on the AIX source. Have the AIX administrator
observe source load and pause or narrow the scan if needed. Source SSH
encryption and file reads still consume resources.
See [THOR lab options](https://thor-manual.nextron-systems.com/en/latest/usage/flags.html#scan-modes)
and [lab licensing](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#forensic-lab-license).

## Limits that can reduce coverage or stop a scan

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

## Validate and close the assessment

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
