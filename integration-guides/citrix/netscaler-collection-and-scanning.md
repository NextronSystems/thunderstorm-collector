# Citrix NetScaler ADC and Gateway: Collection and Scanning

Bring the files of NetScaler ADC and NetScaler Gateway, formerly Citrix ADC and
Citrix Gateway, to THOR's signatures. The guide covers MPX, VPX and SDX
instances, which run the NetScaler software on a FreeBSD base; the CLI command
`shell` opens the FreeBSD shell. Pick one of the four routes below.

> [!NOTE]
> Not yet tested on NetScaler firmware. The dedicated Go build is VM-tested on
> FreeBSD 8.4 and 14.3, and the Bash preset is tested with synthetic files. The
> SFTP collector is a prototype, and both ways of scheduling repeat runs rest on
> Citrix procedures without a test on an appliance.
> [Compatibility evidence](../../go/README.md#compatibility-evidence-as-of-2026-10-08)

Sources: [NetScaler CLI `shell` reference](https://developer-docs.netscaler.com/en-us/adc-command-reference-int/current-release/utility/shell.html)

## Which Route

| Route | When to use | What runs on the appliance | Effort |
| --- | --- | --- | --- |
| [1. Collector on the appliance](#route-1-run-a-collector-on-the-appliance) | Selective collection, repeat runs, many appliances | The Go or Bash collector, copied for each run and removed afterwards; it stays installed only where cron starts the runs | Test, preview and collect on each node; about 6 MB of collector transfer per run and node |
| [2. SFTP collector on another host](#route-2-pull-files-with-the-sftp-collector) (prototype) | The appliance cannot reach Thunderstorm, or nothing may run on it | Nothing; files are read over SFTP | Preview and collect from another host |
| [3. THOR over SSHFS](#route-3-scan-over-sshfs-with-thor) | One complete assessment, as in incident response | Nothing; files are read over SFTP | Every file in scope is read over the connection; 30 to 60 minutes per scan in Nextron's article |
| [4. Exported evidence](#route-4-scan-exported-evidence) | No live access to the files, or a second look at configuration and logs | `show techsupport` writes a support archive; a VPX disk copy needs nothing on the instance | Copy one archive, or obtain a disk copy from the hypervisor |

- **Licensing:** routes 1 and 2 need a Thunderstorm service; routes 3 and 4
  need a Forensic Lab License, or exports can be
  [uploaded to Thunderstorm](#thunderstorm-instead-of-a-forensic-lab-license).
  [Choosing a THOR scanning approach](../../docs/SCANNING_APPROACHES.md)
  compares these routes in general and explains the licensing.
- **What to collect:** the
  [NetScaler assessment profile](../../emerging-threats/citrix-netscaler/README.md)
  lists the directories and supplies the Go configuration and Bash settings
  that routes 1 and 2 use.

## Before You Start

### Identify the instance

1. Connect to the instance being assessed, not to the SDX management service or
   the hypervisor.
2. In the NetScaler CLI, record the firmware build and the high-availability
   state, then open the shell:

   ```text
   show ns version
   show ha node
   shell
   ```

3. In the shell, record the FreeBSD version and the CPU architecture:

   ```sh
   uname -a
   ```

   In Citrix's example, `11.4-NETSCALER-13.1` identifies FreeBSD 11.4 beneath
   NetScaler 13.1 on `amd64`.
4. Start case notes for each node: hostname, management address (NSIP),
   firmware build, FreeBSD version and CPU, HA role, time zone and collection
   time in UTC.
5. Throughout the work, note the account used and every change made on the
   appliance, such as copied files, an SSH configuration change or a generated
   support archive.

Sources: [Citrix: FreeBSD version on NetScaler](https://support.citrix.com/external/article/CTX495617) · [`show ns version`](https://developer-docs.netscaler.com/en-us/adc-command-reference-int/current-release/ns/ns-version.html)

Other NetScaler form factors need a different route:

- **NetScaler BLX** runs as a Linux process on a Linux server. Collect on that
  server with a Linux collector that matches its CPU, as for other Linux
  servers. The paths in this guide come from the FreeBSD-based appliances;
  check the BLX documentation for its file locations.
  [About NetScaler BLX](https://docs.netscaler.com/en-us/blx/current-release/about-netscaler-blx.html)
- **NetScaler CPX** runs as a container. See
  [scanning-containers](https://github.com/NextronSystems/scanning-containers).
- **NetScaler Console**, formerly ADM, is a separate product and is not covered
  here.

### Access and file transfer

The examples use the account `nsadmin` and the NSIP `192.0.2.10`. Use a
separate superuser account instead of `nsroot`, as Citrix recommends. Check that
the account can open the shell and read the paths in scope.

| Task | Form |
| --- | --- |
| Interactive work | `ssh nsadmin@192.0.2.10`, then `shell` |
| Single commands | `ssh nsadmin@192.0.2.10 'shell <command>'`; several commands go in double quotes inside the single quotes |
| File transfer | `scp -O`, as Citrix documents copying files off the appliance with SCP |

- **Key login:** Citrix describes SSH key login for `nsroot` so that no
  password prompt appears.
- **Why `-O`:** OpenSSH 9.0 and later run `scp` over SFTP by default. `-O`
  selects the original SCP protocol, which does not depend on the appliance's
  SFTP subsystem.
- **Older clients:** the option exists from OpenSSH 8.7 on. Older clients
  reject it as unknown but already use the original protocol, so leave `-O` out
  there. Check the version with `ssh -V`.

> [!WARNING]
> Change nothing under `/nsconfig` or `/flash`. Citrix warns that deleting key
> fragment files from the shell can cause configuration loss, synchronization
> failure and logon failure.

Sources: [Citrix: system and user accounts](https://docs.netscaler.com/en-us/netscaler-adc-secure-deployment/administration-and-management/system-and-user-accounts) · [Citrix CTX116453](https://support.citrix.com/external/article/CTX116453/how-to-run-the-netscaler-shell-commands.html) · [Citrix: technical support bundle](https://docs.netscaler.com/en-us/citrix-adc/current-release/citrix-adc-support-for-telecom-service-providers/ns_tcp_optimization/ns_tcp_opt_troubleshooting) · [OpenSSH 9.0 release notes](https://www.openssh.com/txt/release-9.0) · [OpenSSH 8.7 release notes](https://www.openssh.com/txt/release-8.7)

## Route 1: Run a Collector on the Appliance

**Needs:** shell access, a network path from the appliance to Thunderstorm, and
a Thunderstorm service.

### Choose the collector

| `uname -a` shows | Collector | Notes |
| --- | --- | --- |
| FreeBSD 8.4 on `amd64` | Dedicated **`amd64-freebsd8-netscaler`** Go package | Built with Go 1.9.7 for this target. Regular FreeBSD packages are not interchangeable with it. |
| Another FreeBSD version | Bash collector with the profile's preset | Needs Bash 3.2 or later, `curl` or GNU wget and Unix utilities. A regular FreeBSD Go package is a candidate after the compiler checks in the Go guide. |
| Another OS or CPU | A Go package for that OS and CPU, or the Bash preset | Select by the actual environment, not by the product name. |

- The [NetScaler selection steps](../../go/README.md#choose-a-collector-for-your-netscaler)
  explain each case and the FreeBSD versions listed in Citrix's third-party
  notices.
- Download the dedicated package as described under
  [dedicated NetScaler package and downloads](../../go/README.md#dedicated-netscaler-package-and-downloads).

### Prepare the network path

1. Allow the collector's connection from the appliance to the Thunderstorm
   port, **8080** in the profile, in every firewall between the appliance and
   the Thunderstorm server.
2. During the test upload below, confirm the source address that the firewall
   or the Thunderstorm server sees. Citrix documents that some features running
   on the FreeBSD layer send their traffic from the NSIP.
3. For HTTPS, set `ssl: true`, put the CA certificate into the run directory
   described below and list its path on the appliance under `ca`. Keep
   certificate verification.

> [!WARNING]
> Go 1.9.7, which builds the dedicated package, no longer receives security
> fixes, including for its TLS code. If HTTPS does not work with it, use
> another route instead of `insecure`.

Sources: [Citrix: FreeBSD traffic and SNIP](https://docs.netscaler.com/en-us/citrix-adc/current-release/networking/source-citrix-adc-freebsd-traffic-from-snip.html) · [Go collector: Go 1.9.7 note](../../go/README.md#aslr-when-testing-on-modern-freebsd)

### Prepare a run directory on the workstation

1. On the workstation, verify and unpack the package, then build a directory
   that holds everything copied to the appliance:

   ```bash
   sha256sum -c thunderstorm-collector-<version>-amd64-freebsd8-netscaler.tar.gz.sha256
   tar -xzf thunderstorm-collector-<version>-amd64-freebsd8-netscaler.tar.gz
   mkdir -p nextron-thunderstorm/test
   cp thunderstorm-collector-<version>-amd64-freebsd8-netscaler/amd64-freebsd8-netscaler-thunderstorm-collector nextron-thunderstorm/
   ```

2. Put one or two harmless text files into `nextron-thunderstorm/test` for the
   test upload.
3. Save the profile's [config.yml](../../emerging-threats/citrix-netscaler/config.yml)
   as `nextron-thunderstorm/netscaler-run.yml` and change these settings:

   ```yaml
   thunderstorm-server: "thunderstorm.example.org"
   port: 8080
   exclude:
     - /var/nextron-thunderstorm
   ```

4. Keep `dry-run: true` in the file; the upload command below overrides it.

The exclusion is needed because the profile collects all of `/var`. Without it,
the collector would also submit its own run directory; a Go exclusion that
matches a directory skips everything below it. The run directory is
deliberately outside `/var/tmp`; [Background](#why-the-run-directory-is-not-in-vartmp)
explains why.

### Copy, test, preview and collect

1. Copy the run directory to the appliance. With `-r`, `scp` creates
   `/var/nextron-thunderstorm`:

   ```bash
   scp -O -r nextron-thunderstorm nsadmin@192.0.2.10:/var/
   ```

2. Open a session with `ssh nsadmin@192.0.2.10` and `shell`. Run the next steps
   in that shell, in order.
3. Upload only the test files. `-o` names the node in Thunderstorm; use a
   distinct name for each node.

   ```sh
   cd /var/nextron-thunderstorm
   ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml \
     -p /var/nextron-thunderstorm/test -o ns01-node0 --dry-run=false
   ```

4. Check that the test files arrived at Thunderstorm under the source name.
5. Preview the full profile and write the list of selected files to a log:

   ```sh
   ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml \
     -o ns01-node0 -l ./preview.log
   ```

6. Copy `preview.log` to the workstation with
   `scp -O nsadmin@192.0.2.10:/var/nextron-thunderstorm/preview.log .` and
   review it. The broad scope includes configuration, certificates and
   **private keys**.
7. When the selection is right, start the collection:

   ```sh
   ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml \
     -o ns01-node0 --dry-run=false -l ./upload.log
   ```

   Keep the session open until the collector prints its summary; a dropped
   connection can end the run.
8. Copy `upload.log` to the case directory.
9. Remove the run directory in the shell:

   ```sh
   rm -rf /var/nextron-thunderstorm
   ```

### Bash collector instead of Go

1. Check the runtime with `bash --version` and `curl --version`. Check the
   [Bash requirements](../../scripts/bash/README.md#requirements) on the
   actual build.
2. Apply the profile's
   [Bash header settings](../../emerging-threats/citrix-netscaler/README.md#option-2-existing-bash-collector)
   to a copy of the script.
3. In that copy, add `/var/nextron-thunderstorm` to `EXCLUDE_PATHS`.
4. Put the script into the run directory, and copy the run directory to the
   appliance as above.
5. From the run directory, preview with
   `bash ./thunderstorm-collector.sh --dry-run --no-progress`, then collect with
   `--no-dry-run` in place of `--dry-run`. Add `--source ns01-node0` to name the
   node.
6. Remove the run directory as above.

### HA pairs and clusters

Repeat the collection on every node with its own source name. Each node of an
HA pair or cluster has its own NSIP and its own files, and a collection from one
node does not show the other node's files. `show ha node` lists the nodes of an
HA pair.

To repeat collections on a schedule, see [Scheduling](#scheduling).

## Route 2: Pull Files with the SFTP Collector

The [SFTP collector](../../sftp/README.md) runs on another host, reads the files
over SFTP and sends the selected ones to Thunderstorm. Nothing is copied to the
appliance, and the appliance needs no route to Thunderstorm.

**Needs:** a working SFTP subsystem on the appliance (see
[check SFTP access](#check-sftp-access)), SSH key login for the account, the
appliance's host key in `known_hosts`, and a Thunderstorm service.

1. Preview with the profile's configuration, which keeps `dry-run: true`:

   ```bash
   ./thunderstorm-sftp-collector -t ./netscaler-assessment.yml \
     --sftp-host 192.0.2.10 --sftp-user nsadmin --sftp-key ~/.ssh/netscaler_audit_ed25519 \
     -s thunderstorm.example.org -o ns01-node0 --manifest ns01-node0-preview.jsonl
   ```

2. Review the manifest.
3. Repeat the command with `--dry-run=false` and a new manifest name.

How it handles the profile:

- **No duplicates:** a root that is a symbolic link is followed, and a directory
  reached twice is listed once. The profile's `/nsconfig` and `/flash/nsconfig`
  therefore do not cause duplicate uploads.
- **Age limit:** SFTP reports only the modification time, so an age limit
  cannot catch a file whose modification time was set back.

## Route 3: Scan over SSHFS with THOR

THOR on a Linux analysis workstation mounts the appliance's file system over
SSHFS and scans it, following
[Nextron's NetScaler article](https://www.nextron-systems.com/2023/07/20/how-to-perform-compromise-assessments-on-netscaler-citrix-adc-appliances-using-thor/).
A lab scan reads every file in scope over the connection.

**Needs:** a working SFTP subsystem, a Linux workstation with SSHFS, and a
Forensic Lab License. The
[SSHFS section](../../docs/SCANNING_APPROACHES.md#remote-filesystem-scans-with-sshfs)
covers the prerequisites and licensing.

### Check SFTP access

Routes 2 and 3 need the appliance's SFTP subsystem.

1. Test it from the workstation before changing anything:

   ```bash
   sftp nsadmin@192.0.2.10
   ```

   ```text
   ls -la /var
   bye
   ```

2. If the listing works, no change is needed.
3. Otherwise, follow Nextron's article: change the SSH server's subsystem line
   from `Subsystem sftp /usr/lib/openssh/sftp-server` to
   `Subsystem sftp internal-sftp` and reload the server. The article edits one
   of two files:
   - `/flash/nsconfig/sshd_config`, which persists;
   - a copy in `/etc/ssh/sshd_config`, which lasts until the next reboot.

> [!WARNING]
> Step 3 changes the system under investigation.
>
> - Prefer the temporary copy. Run `ls -l /etc/ssh/sshd_config` first: if it is
>   a link into `/nsconfig`, editing it changes the persistent file. Citrix
>   describes such links for `/etc` files copied to `/nsconfig`.
> - Save the original file, keep the current session open and test a new login
>   before closing it.
> - Record the change in the case notes and restore the original file after the
>   scan.

Sources: [Citrix: customized files in /etc](https://docs.netscaler.com/en-us/citrix-adc/current-release/upgrade-downgrade-citrix-adc-appliance/upgrade-considerations-customized-files.html)

### Mount and scan

1. Mount the appliance read-only and check the mount:

   ```bash
   mkdir -p "$HOME/thor-mounts/ns01"
   sshfs -o ro,reconnect nsadmin@192.0.2.10:/ "$HOME/thor-mounts/ns01"
   ls "$HOME/thor-mounts/ns01/netscaler" "$HOME/thor-mounts/ns01/var"
   ```

2. Run `mount` in the appliance shell. If network mounts lie below the root,
   exclude them as described in
   [remote filesystem boundaries](../../docs/SCANNING_APPROACHES.md#remote-filesystem-boundaries).
3. From the THOR program directory, with a valid Forensic Lab License, start
   the scan. `--virtual-map` shows findings under their paths on the appliance,
   and `-j` names the node.

   ```bash
   ./thor-linux-64 --lab -p "$HOME/thor-mounts/ns01" \
     --virtual-map "$HOME/thor-mounts/ns01:/" -j ns01-node0
   ```

4. After THOR has finished, unmount with
   `fusermount3 -u "$HOME/thor-mounts/ns01"`.
5. Revert any SSH configuration change.

Nextron's article notes that a network interruption pauses the scan, while a
forced unmount ends it.

## Route 4: Scan Exported Evidence

**Needs:** SCP access or hypervisor access, and a Forensic Lab License.

### Support archive

1. In the NetScaler CLI, run `show techsupport`. It writes a
   `collector_….tar.gz` archive to `/var/tmp/support` and links
   `/var/tmp/support/support.tgz` to it. Record this write in the case notes.
2. Copy the archive to the workstation:

   ```bash
   scp -O nsadmin@192.0.2.10:/var/tmp/support/support.tgz ./ns01-node0-support.tgz
   ```

3. Extract the archive into an empty directory. Check the extracted tree for
   the directories you need, and use routes 1 to 3 for the rest.
4. Scan it with THOR in lab mode, which checks every file and checks the lines
   of files it recognizes as logs. The
   [FortiGate guide's scan steps](../fortinet/fortigate-export-thor-lab.md#scan-the-exported-files-with-thor-lab)
   show the inventory, working copy and THOR command for such an export.

- **Contents:** Citrix describes the archive as the current configuration, the
  installed firmware version, log files, outstanding cores and other data. It
  is a support bundle, not a copy of the file system.
- **Sensitive:** it contains the configuration, so handle it as sensitive.

Sources: [Citrix: technical support bundle](https://docs.netscaler.com/en-us/citrix-adc/current-release/citrix-adc-support-for-telecom-service-providers/ns_tcp_optimization/ns_tcp_opt_troubleshooting) · [THOR lab scanning](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning)

### VPX disk copy

1. Obtain a copy of the VPX's virtual disk from the hypervisor.
2. On Linux, mount the partitions that hold `/flash` and `/var` read-only with
   `mount -t ufs -o ro,ufstype=<type>`. The type is `ufs2` for UFS2 and `44bsd`
   for UFS1.
3. Scan them with `--lab` and a `--virtual-map` for each mount point, as in
   route 3.

Mandiant's IoC scanner documentation prefers offline analysis of a disk image
over live response. This guide does not cover imaging physical MPX appliances.

Sources: [Mandiant IoC scanner](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519) · [Linux UFS documentation](https://docs.kernel.org/admin-guide/ufs.html)

### Thunderstorm instead of a Forensic Lab License

Upload the exports from the workstation with the [Go](../../go/README.md) or
[Python](../../scripts/python/README.md) collector. Findings then show the
workstation's paths, not the appliance's.

## Verify Coverage

Review each collector log for the selected files, skip counts and oversized
files, not only the success count. Then check these points:

- **Missing and unreadable paths.** Both collectors log missing roots and
  unreadable directories. A directory below a root that cannot be listed does
  not change the Go collector's [exit status](../../go/README.md#exit-status).
- **Mounts.** Neither collector skips network mounts on NetScaler
  automatically: the Go collector's filesystem-type check is not implemented on
  FreeBSD, and the Bash collector reads mounts from Linux `/proc/mounts`. Use
  known local roots and explicit exclusions.
- **Symbolic links.** Both collectors skip links inside the directory trees.
  The Go collector does not follow a root that is a link, so the profile lists
  `/flash/nsconfig` as well as `/nsconfig`.
- **Persistence files.** The profile's roots include the places where attackers
  have kept NetScaler persistence: `/etc/crontab`, `/nsconfig/crontab`,
  `/var/cron/tabs`, `/nsconfig/rc.netscaler`, and the cron log under `/var/log`
  that records the jobs cron ran. A collection scheduled with cron appears
  there too, so compare these files with the recorded changes.
- **Live state.** A file collection is not a snapshot. It does not include
  deleted files, process memory or network connections.
- **Scope.** A result without findings applies only to the files examined.
  Campaign-specific scanners, such as
  [Mandiant's for CVE-2023-3519](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519),
  check other indicators and complement these routes.

Report findings with the node, collection time and route, and keep the logs and
case notes with them.

## Scheduling

Repeat runs apply to route 1.

### Repeat collections

Start repeat runs from a **scheduler host** (**recommended**). Use cron on the
appliance only where no scheduler host can reach the appliances over SSH.
[Background](#why-a-scheduler-host-instead-of-cron) explains the choice.

| | Scheduler host (recommended) | Cron on the appliance |
| --- | --- | --- |
| What stays on the appliance | Nothing between runs | The run directory on every node, and one line in the system crontab |
| What each run needs | Inbound SSH from the scheduler host with key login | Only the network path to Thunderstorm |
| Upkeep | Credentials on the scheduler host | Reapplying the crontab line after each firmware upgrade; keeping the change recorded |

### From a scheduler host

The scheduler host repeats route 1's steps with SSH key login and Citrix's
single-command form:

```bash
scp -O -r nextron-thunderstorm nsadmin@192.0.2.10:/var/
ssh nsadmin@192.0.2.10 'shell "cd /var/nextron-thunderstorm && ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml -o ns01-node0 --dry-run=false -a 2d -l ./upload.log"'
scp -O nsadmin@192.0.2.10:/var/nextron-thunderstorm/upload.log "ns01-node0-$(date -u +%Y%m%dT%H%M%SZ).log"
ssh nsadmin@192.0.2.10 'shell "rm -rf /var/nextron-thunderstorm"'
```

- Check each copied log rather than the SSH exit status.
- Protect the scheduler host and its SSH key like an administrator workstation,
  and use the key for nothing else.
- For several appliances or device types,
  [Running collections from a central orchestrator](../../docs/COLLECTION_ORCHESTRATOR.md)
  extends this sequence with an inventory, run records and one script for all
  devices.

### With cron on the appliance

Use this only where no scheduler host can reach the appliance over SSH. It
follows Citrix's procedure for keeping a changed system crontab: `crontab` is
one of the `/etc` files that the appliance takes from `/nsconfig` at boot.
Citrix's log rotation article edits `/etc/crontab` and then copies it to
`/nsconfig/crontab`.

> [!WARNING]
> Do not add the line through `rc.netscaler`. Citrix calls that older method of
> adding crontab entries obsolete.

1. On every node, install the run directory as described in
   [copy, test, preview and collect](#copy-test-preview-and-collect). Run the
   test upload and the preview, then leave the directory in place. Remove
   `test/` and `preview.log` from it.
2. In the shell of the standalone appliance or the HA primary, check whether the
   crontab was customized before, and keep a copy of the current one:

   ```sh
   ls -l /etc/crontab /nsconfig/crontab
   cp /etc/crontab /var/nextron-thunderstorm/crontab.before
   ```

   If `/etc/crontab` is a link into `/nsconfig`, the next step changes the
   persistent copy directly, and step 4 is not needed.
3. Append the collection line. The system crontab has a user column. The
   comment names the owner and the change record, so that analysts can tell the
   line from attacker persistence:

   ```sh
   cat >> /etc/crontab <<'EOF'
   # Nextron Thunderstorm collection, change CHG-1234, owner: security operations
   30 2 * * * root cd /var/nextron-thunderstorm && ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml --dry-run=false -a 2d -l ./last-run.log >/dev/null 2>&1
   EOF
   ```

   - Without `-o`, each node reports under its own hostname.
   - The Go collector creates its log file anew for each run, so `last-run.log`
     holds only the latest run.
   - Cron mails a command's output to the crontab's owner. The redirection
     discards that console copy; the log file keeps it.
   - FreeBSD's cron rereads `/etc/crontab` within a minute of a change, so the
     line takes effect without a restart.
4. Keep the change across reboots:

   ```sh
   cp /etc/crontab /nsconfig/crontab
   ```

   During boot, the appliance replaces the default `/etc/crontab` with
   `/nsconfig/crontab`. CTX327915 ends its procedure with a reboot; after the
   next reboot, check that `/etc/crontab` still contains the line.

**Bash collector:** the cron line runs the full path that `command -v bash`
prints, with
`./thunderstorm-collector.sh --no-dry-run --no-progress --max-age 2 > ./last-run.log 2>&1`.

Sources: [Citrix CTX327915](https://support.citrix.com/external/article/CTX327915/how-to-install-custom-freebsd-configuration-files-on-a-netscaler.html) · [Citrix CTX277306](https://support.citrix.com/external/article/277306/how-to-modify-the-interval-for-nslog-rot.html) · [FreeBSD cron(8)](https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8&manpath=FreeBSD+8.4-RELEASE)

#### Keeping the cron line correct

- **HA pairs.** Change the crontab only on the primary: HA file sync copies
  these customized files to the secondary, which then runs the same line. That
  is why every node needs the run directory. HA file sync itself runs from the
  system crontab, as an `nsfsyncd -p` line every minute; leave Citrix's own
  lines unchanged. Check the line on both nodes after the reboot.
- **Firmware upgrades.** The copy in `/nsconfig` replaces the whole system
  crontab, including Citrix's own lines for log rotation and HA file sync, with
  the version of the build it was copied on. Before an upgrade, follow Citrix's
  procedure for customized files:
  1. Move `/nsconfig/crontab` to `/var/nsconfig_backup/` and delete the
     `/etc/crontab` link.
  2. Upgrade.
  3. Add the collection line to the new release's `/etc/crontab` and copy that
     file to `/nsconfig` again.
- **Look-alike persistence.** Attackers use the same mechanism. Arctic Wolf saw
  a payload try to add a root cron line that runs every five minutes to
  `/etc/crontab` or `/nsconfig/crontab`. Rapid7 describes cron and
  `rc.netscaler` persistence with scripts under `/flash`. Record the line in
  change management and tell the teams that assess the appliance: a collection
  line that nobody documented looks like persistence to the next assessment.
- **Removal.**
  1. Delete the two lines from `/etc/crontab`.
  2. If it is not a link into `/nsconfig`, copy it to `/nsconfig/crontab` again.
  3. If the crontab had no other customization, move `/nsconfig/crontab` aside
     and reboot, as CTX327915 describes for upgrades, so that the appliance uses
     the release's own crontab again.
  4. Delete `/var/nextron-thunderstorm` on every node.

Sources: [Citrix CTX327915](https://support.citrix.com/external/article/CTX327915/how-to-install-custom-freebsd-configuration-files-on-a-netscaler.html) · [Citrix CTX206613](https://support.citrix.com/external/article/CTX206613/on-netscaler-making-changes-to-rcnetscal.html) · [Citrix: customized files in /etc](https://docs.netscaler.com/en-us/citrix-adc/current-release/upgrade-downgrade-citrix-adc-appliance/upgrade-considerations-customized-files.html) · [Arctic Wolf report](https://github.com/rtkwlf/wolf-tools/tree/main/pack_alerts/202609-citrix-netscaler-active-exploitation-cve-2026-88771) · [Rapid7 analysis](https://www.rapid7.com/blog/post/ra-netscaler-intrusions-chaining-cve-2026-88771-and-cve-2026-88779)

### Age limit for repeat runs

`-a 2d` collects files changed in the last two days; with a daily schedule, the
runs overlap. Repeat full runs without an age limit at regular intervals.

- **Go collector:** on FreeBSD, it compares the modification, change and birth
  times of each file and collects it if any of them is recent. A file whose
  modification time was set back is therefore still collected after a recent
  change. [Source: gettime_timespec.go](../../go/gettime_timespec.go)
- **Bash collector:** `--max-age` uses only the modification time.

## Background

### Why a scheduler host instead of cron

- **Nothing changes on the appliance between runs.** The scheduler host brings
  the collector and its configuration for each run and removes them afterwards.
  Cron needs a lasting change to the system crontab and a collector that stays
  installed on every node.
- **Nothing to lose or alter between runs.** A firmware upgrade or HA file sync
  can drop or overwrite a crontab line. Anyone with shell access can change an
  installed collector or its configuration, for example to exclude a directory.
  Fresh copies from the scheduler host confine such changes to a single run,
  although a compromised appliance can still interfere while the collector
  runs.
- **Missing runs show up.** The scheduler host fetches the log of every run, so
  a failed or skipped run is visible there. A cron line that was removed simply
  stops sending files.
- **No look-alike persistence.** Nothing on the appliance resembles the cron and
  boot persistence that attackers use on NetScaler, so a later assessment has
  nothing to explain.

The cost is the transfer of the collector, about 6 MB per run and node, and a
scheduler host that can log in to every appliance as a superuser.

### Why the run directory is not in /var/tmp

- Attackers have staged tools in `/var/tmp`. Mandiant's NetScaler IoC scanner
  reports every running process and every cron log line that names `/var/tmp`.
  A recognizable name under `/var` keeps the collector apart from such
  findings.
- Citrix's upgrade procedure also uses `/var`: it stores customized
  configuration files in `/var/nsconfig_backup` while the appliance is
  upgraded.

Sources: [Mandiant scanner checks](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519/tree/main/scanners) · [Citrix: customized files in /etc](https://docs.netscaler.com/en-us/citrix-adc/current-release/upgrade-downgrade-citrix-adc-appliance/upgrade-considerations-customized-files.html)

### Bash on NetScaler

Mandiant ships its NetScaler IoC scanner as a Bash script and calls Bash a
common denominator across Citrix ADC appliances; that scanner supports versions
12.0 to 13.1.

Sources: [Mandiant IoC scanner](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519)

### Basis of this guide

This guide is based on the repository's collector documentation, NetScaler
documentation and
[Nextron's NetScaler SSHFS article](https://www.nextron-systems.com/2023/07/20/how-to-perform-compromise-assessments-on-netscaler-citrix-adc-appliances-using-thor/).
