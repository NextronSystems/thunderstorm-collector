# Collect from and scan Citrix NetScaler ADC and Gateway

This guide covers NetScaler ADC and NetScaler Gateway, formerly Citrix ADC and Citrix Gateway, on MPX, VPX and SDX instances. These run the NetScaler software on a FreeBSD base. Administrators manage them through the NetScaler CLI over SSH, and the CLI command `shell` opens the underlying FreeBSD shell. [NetScaler CLI `shell` reference](https://developer-docs.netscaler.com/en-us/adc-command-reference-int/current-release/utility/shell.html)

Four routes bring the appliance's files to THOR's signatures:

| Route | What runs on the NetScaler | Requirements | Suited to |
| --- | --- | --- | --- |
| [1. Collector on the appliance](#route-1-run-a-collector-on-the-appliance) | The Go or Bash collector, copied for each run, or installed for runs started by cron | Shell access, a network path from the appliance to Thunderstorm, a Thunderstorm service | Selective collection, repeat runs, many appliances |
| [2. SFTP collector on another host](#route-2-pull-files-with-the-sftp-collector) (prototype) | Nothing; files are read over SFTP | A working SFTP subsystem, SSH key login, a Thunderstorm service | Appliances that cannot reach Thunderstorm, or where nothing may run |
| [3. THOR over SSHFS](#route-3-scan-over-sshfs-with-thor) | Nothing; files are read over SFTP | A working SFTP subsystem, a Linux workstation with SSHFS, a Forensic Lab License | One complete assessment, as in incident response |
| [4. Exported evidence](#route-4-scan-exported-evidence) | `show techsupport` writes a support archive; a VPX disk copy needs nothing on the instance | SCP access or hypervisor access, a Forensic Lab License | No live access to the files, or a second look at configuration and logs |

[Choosing a THOR scanning approach](../../docs/SCANNING_APPROACHES.md) compares these routes in general and explains the licensing. For a defined assessment, the [NetScaler assessment profile](../../emerging-threats/citrix-netscaler/README.md) lists the directories to collect and supplies the Go configuration and Bash settings that routes 1 and 2 use below.

This guide is based on the repository's collector documentation, NetScaler documentation and [Nextron's NetScaler SSHFS article](https://www.nextron-systems.com/2023/07/20/how-to-perform-compromise-assessments-on-netscaler-citrix-adc-appliances-using-thor/). The dedicated Go build passed tests in FreeBSD 8.4 and 14.3 VMs, and the Bash preset was tested with synthetic files. Neither has been tested on a named NetScaler firmware; see the [compatibility evidence](../../go/README.md#compatibility-evidence-as-of-2026-10-08).

## Identify the instance

Connect to the instance being assessed, not to the SDX management service or the hypervisor. In the NetScaler CLI, record the firmware build and the high-availability state, then open the shell:

```text
show ns version
show ha node
shell
```

In the shell, record the FreeBSD version and the CPU architecture:

```sh
uname -a
```

In Citrix's example, `11.4-NETSCALER-13.1` identifies FreeBSD 11.4 beneath NetScaler 13.1 on `amd64`. [Citrix: FreeBSD version on NetScaler](https://support.citrix.com/external/article/CTX495617) · [`show ns version`](https://developer-docs.netscaler.com/en-us/adc-command-reference-int/current-release/ns/ns-version.html)

Keep case notes for each node: hostname, management address (NSIP), firmware build, FreeBSD version and CPU, HA role, time zone and collection time in UTC. Also note the account used and every change made on the appliance, such as copied files, an SSH configuration change or a generated support archive.

Other NetScaler form factors need a different route:

- **NetScaler BLX** runs as a Linux process on a Linux server. [About NetScaler BLX](https://docs.netscaler.com/en-us/blx/current-release/about-netscaler-blx.html) Collect on that server with a Linux collector that matches its CPU, as for other Linux servers. The paths in this guide come from the FreeBSD-based appliances; check the BLX documentation for its file locations.
- **NetScaler CPX** runs as a container. See [scanning-containers](https://github.com/NextronSystems/scanning-containers).
- **NetScaler Console**, formerly ADM, is a separate product and is not covered here.

## Access and file transfer

The examples use the account `nsadmin` and the NSIP `192.0.2.10`. Citrix recommends creating a separate superuser account and using it instead of `nsroot`. [Citrix: system and user accounts](https://docs.netscaler.com/en-us/netscaler-adc-secure-deployment/administration-and-management/system-and-user-accounts) Check that the account can open the shell and read the paths in scope.

- **Interactive work:** `ssh nsadmin@192.0.2.10`, then `shell`.
- **Single commands:** Citrix documents the form `ssh nsadmin@192.0.2.10 'shell <command>'`; several commands go in double quotes inside the single quotes. Citrix describes SSH key login for `nsroot` so that no password prompt appears. [Citrix CTX116453](https://support.citrix.com/external/article/CTX116453/how-to-run-the-netscaler-shell-commands.html)
- **File transfer:** Citrix documents copying files off the appliance with SCP. [Citrix: technical support bundle](https://docs.netscaler.com/en-us/citrix-adc/current-release/citrix-adc-support-for-telecom-service-providers/ns_tcp_optimization/ns_tcp_opt_troubleshooting) OpenSSH 9.0 and later run `scp` over SFTP by default. The examples pass `-O` for the original SCP protocol, which does not depend on the appliance's SFTP subsystem. [OpenSSH 9.0 release notes](https://www.openssh.com/txt/release-9.0)

Change nothing under `/nsconfig` or `/flash`. Citrix warns that deleting key fragment files from the shell can cause configuration loss, synchronization failure and logon failure. [Citrix: system and user accounts](https://docs.netscaler.com/en-us/netscaler-adc-secure-deployment/administration-and-management/system-and-user-accounts)

## Route 1: Run a collector on the appliance

### Choose the collector

| `uname -a` shows | Collector | Notes |
| --- | --- | --- |
| FreeBSD 8.4 on `amd64` | Dedicated **`amd64-freebsd8-netscaler`** Go package | Built with Go 1.9.7 for this target. Regular FreeBSD packages are not interchangeable with it. |
| Another FreeBSD version | Bash collector with the profile's preset | Needs Bash 3.2 or later, `curl` or GNU wget and Unix utilities. A regular FreeBSD Go package is a candidate after the compiler checks in the Go guide. |
| Another OS or CPU | A Go package for that OS and CPU, or the Bash preset | Select by the actual environment, not by the product name. |

The [NetScaler selection steps](../../go/README.md#choose-a-collector-for-your-netscaler) explain each case and the FreeBSD versions listed in Citrix's third-party notices. Download the dedicated package as described under [dedicated NetScaler package and downloads](../../go/README.md#dedicated-netscaler-package-and-downloads).

### Prepare the network path

The collector on the appliance opens the connection to the Thunderstorm port, 8080 in the profile. Allow it in every firewall between the appliance and the Thunderstorm server. Citrix documents that some features running on the FreeBSD layer send their traffic from the NSIP. [Citrix: FreeBSD traffic and SNIP](https://docs.netscaler.com/en-us/citrix-adc/current-release/networking/source-citrix-adc-freebsd-traffic-from-snip.html) Confirm the source address that the firewall or the Thunderstorm server sees during the test upload below.

For HTTPS, set `ssl: true`, put the CA certificate into the run directory described below and list its path on the appliance under `ca`. Keep certificate verification. Go 1.9.7, which builds the dedicated package, no longer receives security fixes, including for its TLS code. If HTTPS does not work with it, use another route instead of `insecure`. [Go collector: Go 1.9.7 note](../../go/README.md#aslr-when-testing-on-modern-freebsd)

### Prepare a run directory on the workstation

On the workstation, verify and unpack the package, then build a directory that holds everything copied to the appliance:

```bash
sha256sum -c thunderstorm-collector-<version>-amd64-freebsd8-netscaler.tar.gz.sha256
tar -xzf thunderstorm-collector-<version>-amd64-freebsd8-netscaler.tar.gz
mkdir -p nextron-thunderstorm/test
cp thunderstorm-collector-<version>-amd64-freebsd8-netscaler/amd64-freebsd8-netscaler-thunderstorm-collector nextron-thunderstorm/
```

Put one or two harmless text files into `nextron-thunderstorm/test` for the test upload. Save the profile's [config.yml](../../emerging-threats/citrix-netscaler/config.yml) as `nextron-thunderstorm/netscaler-run.yml` and change these settings:

```yaml
thunderstorm-server: "thunderstorm.example.org"
port: 8080
exclude:
  - /var/nextron-thunderstorm
```

The profile collects all of `/var`. Without the exclusion, the collector would also submit its own run directory; a Go exclusion that matches a directory skips everything below it. Keep `dry-run: true` in the file; the upload command below overrides it.

The run directory is deliberately outside `/var/tmp`. Attackers have staged tools there, and Mandiant's NetScaler IoC scanner reports every running process and every cron log line that names `/var/tmp`. [Mandiant scanner checks](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519/tree/main/scanners) A recognizable name under `/var` keeps the collector apart from such findings. Citrix's upgrade procedure also uses `/var`: it stores customized configuration files in `/var/nsconfig_backup` while the appliance is upgraded. [Citrix: customized files in /etc](https://docs.netscaler.com/en-us/citrix-adc/current-release/upgrade-downgrade-citrix-adc-appliance/upgrade-considerations-customized-files.html)

### Copy, test, preview and collect

Copy the run directory to the appliance. With `-r`, `scp` creates `/var/nextron-thunderstorm`:

```bash
scp -O -r nextron-thunderstorm nsadmin@192.0.2.10:/var/
```

Open a session with `ssh nsadmin@192.0.2.10` and `shell`, then run these steps in order. `-o` names the node in Thunderstorm; use a distinct name for each node.

```sh
cd /var/nextron-thunderstorm
./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml \
  -p /var/nextron-thunderstorm/test -o ns01-node0 --dry-run=false
```

This uploads only the test files. Check that they arrived at Thunderstorm under the source name. Then preview the full profile and write the list of selected files to a log:

```sh
./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml \
  -o ns01-node0 -l ./preview.log
```

Copy `preview.log` to the workstation with `scp -O nsadmin@192.0.2.10:/var/nextron-thunderstorm/preview.log .` and review it. The broad scope includes configuration, certificates and private keys. When the selection is right, start the collection:

```sh
./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml \
  -o ns01-node0 --dry-run=false -l ./upload.log
```

Keep the session open until the collector prints its summary; a dropped connection can end the run. Copy `upload.log` to the case directory, then remove the run directory in the shell:

```sh
rm -rf /var/nextron-thunderstorm
```

### Bash collector instead of Go

Check the runtime first with `bash --version` and `curl --version`. Mandiant ships its NetScaler IoC scanner as a Bash script and calls Bash a common denominator across Citrix ADC appliances; that scanner supports versions 12.0 to 13.1. [Mandiant IoC scanner](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519) Check the [Bash requirements](../../scripts/bash/README.md#requirements) on the actual build.

Apply the profile's [Bash header settings](../../emerging-threats/citrix-netscaler/README.md#option-2-existing-bash-collector) to a copy of the script and put it into the run directory. Also add `/var/nextron-thunderstorm` to `EXCLUDE_PATHS` in that copy. Copy and remove the run directory as above, and run the script from it with `bash ./thunderstorm-collector.sh --dry-run --no-progress`, then with `--no-dry-run`. Use `--source ns01-node0` to name the node.

### HA pairs and clusters

Each node of an HA pair or cluster has its own NSIP and its own files. `show ha node` lists the nodes of an HA pair. Repeat the collection on every node with its own source name. A collection from one node does not show the other node's files.

### Repeat collections

Repeat runs can start from a scheduler host or from cron on the appliance:

| | Scheduler host | Cron on the appliance |
| --- | --- | --- |
| What stays on the appliance | Nothing between runs | The run directory on every node, and one line in the system crontab |
| What each run needs | Inbound SSH from the scheduler host with key login | Only the network path to Thunderstorm |
| Upkeep | Credentials on the scheduler host | Reapplying the crontab line after each firmware upgrade; keeping the change recorded |

Neither way has been tested with the collectors on an appliance. Both rest on the Citrix procedures cited below.

#### From a scheduler host

The scheduler host repeats the steps above with SSH key login and Citrix's single-command form:

```bash
scp -O -r nextron-thunderstorm nsadmin@192.0.2.10:/var/
ssh nsadmin@192.0.2.10 'shell "cd /var/nextron-thunderstorm && ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml -o ns01-node0 --dry-run=false -a 2d -l ./upload.log"'
scp -O nsadmin@192.0.2.10:/var/nextron-thunderstorm/upload.log "ns01-node0-$(date -u +%Y%m%dT%H%M%SZ).log"
ssh nsadmin@192.0.2.10 'shell "rm -rf /var/nextron-thunderstorm"'
```

This sequence follows the documented command form but has not been tested on an appliance. Check each copied log rather than the SSH exit status.

#### With cron on the appliance

Citrix documents how to keep a changed system crontab. `crontab` is one of the `/etc` files that the appliance takes from `/nsconfig` at boot, and Citrix's log rotation article edits `/etc/crontab` and then copies it to `/nsconfig/crontab`. [Citrix CTX327915](https://support.citrix.com/external/article/CTX327915/how-to-install-custom-freebsd-configuration-files-on-a-netscaler.html) · [Citrix CTX277306](https://support.citrix.com/external/article/277306/how-to-modify-the-interval-for-nslog-rot.html) FreeBSD's cron rereads `/etc/crontab` within a minute of a change, so a new line takes effect without a restart. [FreeBSD cron(8)](https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8&manpath=FreeBSD+8.4-RELEASE) Citrix calls the older method of adding crontab entries through `rc.netscaler` obsolete; do not use it.

1. On every node, install the run directory as described in [copy, test, preview and collect](#copy-test-preview-and-collect). Run the test upload and the preview, then leave the directory in place. Remove `test/` and `preview.log` from it.
2. In the shell of the standalone appliance or the HA primary, check whether the crontab was customized before, and keep a copy of the current one:

   ```sh
   ls -l /etc/crontab /nsconfig/crontab
   cp /etc/crontab /var/nextron-thunderstorm/crontab.before
   ```

   If `/etc/crontab` is a link into `/nsconfig`, the next step changes the persistent copy directly, and step 4 is not needed.
3. Append the collection line. The system crontab has a user column. The comment names the owner and the change record, so that analysts can tell the line from attacker persistence:

   ```sh
   cat >> /etc/crontab <<'EOF'
   # Nextron Thunderstorm collection, change CHG-1234, owner: security operations
   30 2 * * * root cd /var/nextron-thunderstorm && ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml --dry-run=false -a 2d -l ./last-run.log >/dev/null 2>&1
   EOF
   ```

   Without `-o`, each node reports under its own hostname. The Go collector creates its log file anew for each run, so `last-run.log` holds only the latest run. Cron mails a command's output to the crontab's owner; the redirection discards that console copy, while the log file keeps it.
4. Keep the change across reboots:

   ```sh
   cp /etc/crontab /nsconfig/crontab
   ```

   The edited `/etc/crontab` is in effect at once. During boot, the appliance replaces the default `/etc/crontab` with `/nsconfig/crontab`. CTX327915 ends its procedure with a reboot; after the next reboot, check that `/etc/crontab` still contains the line.

For the Bash collector, the line runs the full path that `command -v bash` prints, with `./thunderstorm-collector.sh --no-dry-run --no-progress --max-age 2 > ./last-run.log 2>&1`.

**HA pairs.** HA file sync copies these customized files to the secondary, so Citrix changes them only on the primary. [Citrix CTX327915](https://support.citrix.com/external/article/CTX327915/how-to-install-custom-freebsd-configuration-files-on-a-netscaler.html) The secondary then runs the same line, which is why every node needs the run directory. HA file sync itself runs from the system crontab, as an `nsfsyncd -p` line every minute; leave Citrix's own lines unchanged. [Citrix CTX206613](https://support.citrix.com/external/article/CTX206613/on-netscaler-making-changes-to-rcnetscal.html) Check the line on both nodes after the reboot.

**Firmware upgrades.** The copy in `/nsconfig` replaces the whole system crontab, including Citrix's own lines for log rotation and HA file sync, with the version of the build it was copied on. Before an upgrade, follow Citrix's procedure for customized files: move `/nsconfig/crontab` to `/var/nsconfig_backup/` and delete the `/etc/crontab` link, upgrade, add the collection line to the new release's `/etc/crontab` and copy that file to `/nsconfig` again. [Citrix: customized files in /etc](https://docs.netscaler.com/en-us/citrix-adc/current-release/upgrade-downgrade-citrix-adc-appliance/upgrade-considerations-customized-files.html)

**Look-alike persistence.** Attackers use the same mechanism. Arctic Wolf saw a payload try to add a root cron line that runs every five minutes to `/etc/crontab` or `/nsconfig/crontab`. Rapid7 describes cron and `rc.netscaler` persistence with scripts under `/flash`. [Arctic Wolf report](https://github.com/rtkwlf/wolf-tools/tree/main/pack_alerts/202609-citrix-netscaler-active-exploitation-cve-2026-88771) · [Rapid7 analysis](https://www.rapid7.com/blog/post/ra-netscaler-intrusions-chaining-cve-2026-88771-and-cve-2026-88779) Record the line in change management and tell the teams that assess the appliance. A collection line that nobody documented looks like persistence to the next assessment.

**Removal.** Delete the two lines from `/etc/crontab`. If it is not a link into `/nsconfig`, copy it to `/nsconfig/crontab` again. If the crontab had no other customization, move `/nsconfig/crontab` aside and reboot, as CTX327915 describes for upgrades, so that the appliance uses the release's own crontab again. Then delete `/var/nextron-thunderstorm` on every node.

#### Age limit for repeat runs

`-a 2d` collects files changed in the last two days; with a daily schedule, the runs overlap. On FreeBSD, the Go collector compares the modification, change and birth times of each file and collects it if any of them is recent. [Source: gettime_timespec.go](../../go/gettime_timespec.go) A file whose modification time was set back is therefore still collected after a recent change. The Bash collector's `--max-age` uses only the modification time. Repeat full runs without an age limit at regular intervals.

## Route 2: Pull files with the SFTP collector

The [SFTP collector](../../sftp/README.md) runs on another host, reads the files over SFTP and sends the selected ones to Thunderstorm. Nothing is copied to the appliance, and the appliance needs no route to Thunderstorm. It is a prototype and has not been tested on NetScaler.

It needs a working SFTP subsystem on the appliance (see [check SFTP access](#check-sftp-access)), SSH key login for the account and the appliance's host key in `known_hosts`. Preview with the profile's configuration, which keeps `dry-run: true`:

```bash
./thunderstorm-sftp-collector -t ./netscaler-assessment.yml \
  --sftp-host 192.0.2.10 --sftp-user nsadmin --sftp-key ~/.ssh/netscaler_audit_ed25519 \
  -s thunderstorm.example.org -o ns01-node0 --manifest ns01-node0-preview.jsonl
```

After reviewing the manifest, repeat the command with `--dry-run=false` and a new manifest name. A root that is a symbolic link is followed, and a directory reached twice is listed once, so the profile's `/nsconfig` and `/flash/nsconfig` do not cause duplicate uploads. SFTP reports only the modification time, so an age limit cannot catch a file whose modification time was set back.

## Route 3: Scan over SSHFS with THOR

THOR on a Linux analysis workstation mounts the appliance's file system over SSHFS and scans it. This follows [Nextron's NetScaler article](https://www.nextron-systems.com/2023/07/20/how-to-perform-compromise-assessments-on-netscaler-citrix-adc-appliances-using-thor/), which reports scan times of 30 to 60 minutes on customer appliances. A lab scan reads every file in scope over the connection. The [SSHFS section](../../docs/SCANNING_APPROACHES.md#remote-filesystem-scans-with-sshfs) covers the prerequisites and licensing.

### Check SFTP access

Routes 2 and 3 need the appliance's SFTP subsystem. Test it from the workstation before changing anything:

```bash
sftp nsadmin@192.0.2.10
```

```text
ls -la /var
bye
```

If the listing works, no change is needed. Otherwise, Nextron's article changes the SSH server's subsystem line from `Subsystem sftp /usr/lib/openssh/sftp-server` to `Subsystem sftp internal-sftp` and reloads the server. The article edits either `/flash/nsconfig/sshd_config`, which persists, or a copy in `/etc/ssh/sshd_config`, which lasts until the next reboot. This changes the system under investigation:

- Prefer the temporary copy. Run `ls -l /etc/ssh/sshd_config` first: if it is a link into `/nsconfig`, editing it changes the persistent file. Citrix describes such links for `/etc` files copied to `/nsconfig`. [Citrix: customized files in /etc](https://docs.netscaler.com/en-us/citrix-adc/current-release/upgrade-downgrade-citrix-adc-appliance/upgrade-considerations-customized-files.html)
- Save the original file, keep the current session open and test a new login before closing it.
- Record the change in the case notes and restore the original file after the scan.

### Mount and scan

```bash
mkdir -p "$HOME/thor-mounts/ns01"
sshfs -o ro,reconnect nsadmin@192.0.2.10:/ "$HOME/thor-mounts/ns01"
ls "$HOME/thor-mounts/ns01/netscaler" "$HOME/thor-mounts/ns01/var"
```

Before scanning, run `mount` in the appliance shell. If network mounts lie below the root, exclude them as described in [remote filesystem boundaries](../../docs/SCANNING_APPROACHES.md#remote-filesystem-boundaries). From the THOR program directory, with a valid Forensic Lab License:

```bash
./thor-linux-64 --lab -p "$HOME/thor-mounts/ns01" \
  --virtual-map "$HOME/thor-mounts/ns01:/" -j ns01-node0
```

`--virtual-map` shows findings under their paths on the appliance, and `-j` names the node. Nextron's article notes that a network interruption pauses the scan, while a forced unmount ends it. After THOR has finished, unmount with `fusermount3 -u "$HOME/thor-mounts/ns01"` and revert any SSH configuration change.

## Route 4: Scan exported evidence

### Support archive

`show techsupport` in the NetScaler CLI writes a `collector_….tar.gz` archive to `/var/tmp/support` and links `/var/tmp/support/support.tgz` to it. Citrix describes its contents as the current configuration, the installed firmware version, log files, outstanding cores and other data. [Citrix: technical support bundle](https://docs.netscaler.com/en-us/citrix-adc/current-release/citrix-adc-support-for-telecom-service-providers/ns_tcp_optimization/ns_tcp_opt_troubleshooting) Copy it to the workstation:

```bash
scp -O nsadmin@192.0.2.10:/var/tmp/support/support.tgz ./ns01-node0-support.tgz
```

The archive is a support bundle, not a copy of the file system. Check the extracted tree for the directories you need, and use routes 1 to 3 for the rest. It contains the configuration, so handle it as sensitive. Generating it writes to the appliance's `/var/tmp/support`; record that in the case notes.

Extract the archive into an empty directory and scan it with THOR in lab mode, which checks every file and checks the lines of files it recognizes as logs. The [FortiGate guide's scan steps](../fortinet/fortigate-export-thor-lab.md#scan-the-exported-files-with-thor-lab) show the inventory, working copy and THOR command for such an export. [THOR lab scanning](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning)

### VPX disk copy

For a VPX, the hypervisor can provide a copy of the virtual disk. Mandiant's IoC scanner documentation prefers offline analysis of a disk image over live response. [Mandiant IoC scanner](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519) On Linux, mount the partitions that hold `/flash` and `/var` read-only with `mount -t ufs -o ro,ufstype=<type>`, where the type is `ufs2` for UFS2 and `44bsd` for UFS1. [Linux UFS documentation](https://docs.kernel.org/admin-guide/ufs.html) Scan them with `--lab` and a `--virtual-map` for each mount point, as in route 3. This guide does not cover imaging physical MPX appliances.

To analyze exports with Thunderstorm instead of a Forensic Lab License, upload them from the workstation with the [Go](../../go/README.md) or [Python](../../scripts/python/README.md) collector. Findings then show the workstation's paths, not the appliance's.

## Check coverage

- **Missing and unreadable paths.** Both collectors log missing roots and unreadable directories. A directory below a root that cannot be listed does not change the Go collector's [exit status](../../go/README.md#exit-status). Review the log for the selected files, skip counts and oversized files, not only the success count.
- **Mounts.** The Go collector's filesystem-type check is not implemented on FreeBSD, and the Bash collector reads mounts from Linux `/proc/mounts`. Neither skips network mounts on NetScaler automatically. Use known local roots and explicit exclusions.
- **Symbolic links.** Both collectors skip links inside the directory trees. The Go collector does not follow a root that is a link, so the profile lists `/flash/nsconfig` as well as `/nsconfig`.
- **Persistence files.** The profile's roots include the places where attackers have kept NetScaler persistence, `/etc/crontab`, `/nsconfig/crontab`, `/var/cron/tabs` and `/nsconfig/rc.netscaler`, and the cron log under `/var/log` that records the jobs cron ran. A collection scheduled with cron appears there too, so compare these files with the recorded changes.
- **Live state.** A file collection is not a snapshot. It does not include deleted files, process memory or network connections.
- **Scope.** A result without findings applies only to the files examined. Campaign-specific scanners, such as [Mandiant's for CVE-2023-3519](https://github.com/mandiant/citrix-ioc-scanner-cve-2023-3519), check other indicators and complement these routes.

Report findings with the node, collection time and route, and keep the logs and case notes with them.
