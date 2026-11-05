# Export FortiGate evidence and scan it with THOR on Linux

Use either workflow below to collect data from a physical FortiGate or a FortiGate VM running FortiOS. The GUI is convenient for a configuration backup and a time range of logs. The CLI can transfer a configuration backup and print diagnostics that an investigator can capture over SSH. Run THOR with a **Forensic Lab License** on a dedicated Linux analysis workstation after collection. This is the offline analysis of exported evidence described in [Choosing a THOR scanning approach](../../docs/SCANNING_APPROACHES.md#offline-analysis-of-exported-evidence), which also covers licensing.

No collector runs on the FortiGate itself. FortiOS gives administrators a CLI, not a general-purpose shell, and its Linux base does not make a Linux Go binary usable there. SSHFS and the [SFTP collector](../../sftp/README.md) need SFTP access to the source's files; Fortinet documents SCP access to named objects such as the configuration, but no SFTP access to the filesystem. To analyze the exports with Thunderstorm instead of a Forensic Lab License, upload them from the workstation with the [Go](../../go/README.md) or [Python](../../scripts/python/README.md) collector; the Thunderstorm service needs its own license.

| Access available | What you can collect | What THOR can check in it |
| --- | --- | --- |
| FortiGate management GUI over HTTPS | Configuration in the administrator's scope, retained event and traffic logs, FortiCare debug report | Log lines and configuration text against IOCs and signatures |
| FortiGate CLI over SSH or console | Configuration backup over SCP or SFTP, crash records, process and file listings, and file hashes on supported builds | Paths and strings in the transcripts, once saved as `.log` files. Hashes printed in a transcript are not compared with hash IOCs; Fortinet TAC compares them with the expected build. |
| Separately acquired VM disks | File contents from the accessible filesystems, including binaries that appear only by name or hash in diagnostics | Content and hashes of the files themselves |

THOR checks each line of a file it recognizes as a log, by a `.log` name or a timestamp at the start of the file, against its filename and keyword IOCs and its log signatures. In lab mode it also checks every file as a whole, whatever its name. [THOR LogScan module](https://thor-manual.nextron-systems.com/en/latest/usage/scan-modes.html#scan-module-explanation)

## Prepare a case directory on Linux

Use one directory per appliance or HA member and collection run. On the **analysis workstation**, run these commands in Bash. Keep this shell open for the later steps. Replace `FG01` with the source device's hostname.

```bash
umask 077
device=FG01
case_dir=$(mktemp -d "$HOME/${device}-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir -p "$case_dir"/{originals,scan-input,results}
printf '%s\n' "$case_dir"
```

Record the serial number, FortiOS version and build, device time zone, collection time in UTC, HA member and virtual domain (VDOM) in the case notes. Record the log source and time window too. A VDOM administrator can collect only the configuration within their scope. [Fortinet's multi-VDOM backup guide](https://docs.fortinet.com/document/fortigate/7.6.4/administration-guide/87472) · [Fortinet's IoC collection procedure](https://community.fortinet.com/fortigate-3/technical-tip-collect-indicators-of-compromise-ioc-debug-outputs-on-a-fortigate-vdom-and-non-vdom-manually-177342)

Members of an HA cluster have their own diagnostic state, and Fortinet suggests collecting from each of them. Give each member its own case directory. To reach another member's CLI, start a new session to the primary, with its own transcript as described below, and enter `execute ha manage <index> <admin-username>`; `execute ha manage ?` lists the indexes. [Fortinet's HA member access](https://community.fortinet.com/fortigate-3/technical-tip-how-to-access-the-secondary-unit-from-the-primary-with-the-execute-ha-manage-command-97867)

## Method 1 — Download files from the FortiGate GUI

1. **Configuration.** Sign in to the FortiGate management GUI. Open the administrator menu at the upper right, choose **Configuration > Backup**, then **Local PC**. Select the FortiOS configuration format if offered. In multi-VDOM mode, a global administrator can choose **Global** for the appliance configuration or **VDOM** for one domain. Save the download under `originals/`. Configuration exports can contain credentials and private keys. Use password masking if required and record that choice. If policy requires backup encryption, preserve the encrypted original and obtain an approved readable copy for scanning. [FortiOS configuration backup options](https://docs.fortinet.com/document/fortigate/7.6.0/administration-guide/702257)
2. **Event and traffic logs.** Open **Log & Report**, select **System Events** (or **General System Events**) and choose the log source that holds the period of interest. Set the time range and filters, clear any individual row selection, then use **Download**. On 7.6 and later, a **Download Logs** dialog opens: Fortinet recommends **Download and combine** for more than 50,000 entries, and without a time range the download covers the last 7 days. One download holds at most 400,000 entries, so split a longer period. Keep the default text format, which saves a `.log` file that THOR checks line by line; a CSV export, offered on 7.4 to 7.6.3, is not recognized as a log. Repeat for relevant categories such as VPN events and **Forward Traffic**. If logs are retained on FortiAnalyzer or another central logger, export the same device, VDOM and period there. Verify the time span and row count in the downloaded files. Save the files under `originals/`. For the complete raw log files, Fortinet gives `execute backup disk alllogs`, which sends them only to an FTP or TFTP server; neither protocol encrypts the transfer. [Fortinet's log download procedure](https://community.fortinet.com/fortigate-3/technical-tip-how-to-download-logs-from-fortigate-gui-97198)
3. **Diagnostic report.** With `super_admin` access, go to **System > Settings**. On FortiOS 7.4 and 7.6, select **FortiCare Debug Report > Download**. On 7.0 and 7.2 the control is **Debug Logs > Download**. Save the file under `originals/`. For a more complete transcript, use the SSH procedure below. [Fortinet's debug report instructions](https://community.fortinet.com/fortigate-3/technical-tip-download-debug-logs-and-execute-tac-report-92352)

## Method 2 — Transfer the configuration and capture CLI output

Choose one way to transfer the configuration. Where SSH management and `admin-scp` are already enabled, pull it with SCP: no new credential is entered on the firewall, and the firewall needs no route to another host. Otherwise, have the FortiGate push it to an SFTP receiver, or use the GUI download in Method 1.

### Pull the configuration with SCP

On FortiOS 7.4.4 and later, the account needs `super_admin` or a custom profile with Read/Write for **Administrator Users** and Read for all other access controls. The `-O` option selects the legacy SCP protocol, which OpenSSH 9.0 and later need for this transfer; older clients do not need it. The named object `sys_config` holds the configuration only. [Fortinet's SCP backup procedure](https://community.fortinet.com/fortigate-3/technical-tip-how-to-download-a-fortigate-configuration-file-and-upload-a-firmware-file-using-secure-copy-scp-98734)

```bash
scp -O -P 22 iradmin@192.0.2.10:sys_config "$case_dir/originals/FG01.conf"
```

Confirm that the file contains a FortiOS configuration header for the expected model and build.

### Prepare an SFTP receiver

The **FortiGate initiates** the backup connection, and the receiver's password is typed on the device under investigation. Use a separate staging host rather than the analysis workstation. Give the transfer a dedicated account that is limited to SFTP in a chroot (`ForceCommand internal-sftp` and `ChrootDirectory`, as in Fortinet's Linux receiver example), and disable the account or change its password after the transfer. The receiver needs a running SFTP service, a route from the FortiGate's management context to its listening port, and an upload directory the account can write to. This example uses a password-authenticated account called `fgt_export`, a receiver at `192.0.2.20:22`, and a writable `/incoming` directory as seen by that account. In an SFTP chroot, that path starts at the account's restricted root. [Linux SFTP receiver setup](https://community.fortinet.com/fortigate-3/technical-tip-how-to-send-automated-backups-of-the-configuration-from-a-fortigate-with-an-automation-stitch-using-tftp-ftp-or-sftp-server-and-a-recommendation-for-configuring-a-linux-machine-99783)

For example, if an administrator has already provisioned the account on the **Linux receiver** with `ChrootDirectory /var/sftp`, this command creates its writable subdirectory. Keep the chroot root owned by root. Adapt the path to the receiver's existing OpenSSH configuration.

```bash
sudo install -d -m 0700 -o fgt_export -g "$(id -gn fgt_export)" /var/sftp/incoming
```

From the **workstation**, connect to the receiver. Verify the host key against the receiver's fingerprint on first use. At the `sftp>` prompt, create a fresh directory for the run. Replace `FG01-case123` throughout the examples with a unique name.

```bash
sftp -P 22 fgt_export@192.0.2.20
```

```text
cd /incoming
mkdir FG01-case123
cd FG01-case123
pwd
bye
```

### Send the backup from FortiOS

Open the **FortiGate CLI** over the management console or SSH (for example, `ssh -p 22 iradmin@192.0.2.10` from Linux). Complete the backup before starting the evidence transcript below. Run `get system status` to confirm the source. In multi-VDOM mode, use the intended administrative context. For an appliance-wide backup, enter `config global` with a `super_admin` account; Fortinet notes that the full configuration is not sent without it. Check the available destinations with `execute backup config ?`. Fortinet documents SFTP configuration backup in the 7.0.1 release. If SFTP is unavailable, use SCP or the GUI download. [Fortinet's SFTP backup syntax](https://docs.fortinet.com/document/fortigate/7.0.0/new-features/932215/sftp-configuration-backup-7-0-1)

At the **FortiGate prompt**, enter the command below, substituting the receiver account's password for `<SFTP_PASSWORD>`. The arguments are the **destination filename**, **receiver address and port**, **receiver username** and **receiver password**. Use a short-lived credential because CLI auditing or session recording can retain the command.

```text
execute backup config sftp /incoming/FG01-case123/FG01.conf 192.0.2.20:22 fgt_export <SFTP_PASSWORD>
```

The optional **fifth argument** is a separate password for encrypting the backup file. This example requests a readable configuration over an encrypted transfer. For an export including default settings, use `execute backup full-config sftp` if the device offers it. Both commands export configuration settings. [Backup types](https://community.fortinet.com/fortigate-3/technical-tip-differences-between-fortigate-cli-commands-execute-backup-config-and-execute-backup-full-config-98533)

Wait for a success message such as `Send config file to sftp server OK`. If the transfer fails, check outbound routing from the relevant VDOM, the port, account credentials and the destination path as shown by SFTP's `pwd`. [SFTP troubleshooting](https://community.fortinet.com/fortigate-3/troubleshooting-tip-sftp-configuration-backup-issues-for-fortigate-160883)

Back on the **workstation**, retrieve the completed file. Use a separate read account if the upload account is write-only. If the receiver is local, you can instead copy the file from its actual Linux storage path into `originals/`.

```bash
cd "$case_dir/originals"
sftp -P 22 fgt_export@192.0.2.20
```

```text
ls -l /incoming/FG01-case123/FG01.conf
get /incoming/FG01-case123/FG01.conf
bye
```

Confirm that the local file size matches the completed transfer and that the readable backup contains a FortiOS configuration header for the expected model and build.

### Save diagnostics from a management session

On the **Linux workstation**, start a fresh SSH session using util-linux `script` to save terminal output. Keep the password-bearing backup command out of this session. With a serial console, enable output logging in the terminal client instead.

```bash
script -q -c 'ssh -p 22 iradmin@192.0.2.10' "$case_dir/originals/cli-session.txt"
```

At the **FortiGate prompt**, run the commands below **one at a time**, waiting for each to finish. They are Fortinet's IoC command list, with the crash log added. On VDOM-enabled units, enter `config global` first. `fnsysctl` and the TAC report require a `super_admin` account. Record unavailable commands or paths for the particular build. Advance any pager until the prompt returns. Fortinet's procedure turns the pager off with `config system console`, `set output standard` and `end`. That changes the configuration of the device under investigation, so check the current value with `get system console`, record the change and restore the value afterwards. [Fortinet's manual IoC procedure](https://community.fortinet.com/fortigate-3/technical-tip-collect-indicators-of-compromise-ioc-debug-outputs-on-a-fortigate-vdom-and-non-vdom-manually-177342)

```text
get system status
diagnose debug crashlog read
fnsysctl ls -la /
fnsysctl ls -la /bin
fnsysctl ls -la /sbin
fnsysctl ls -la /lib
fnsysctl ls -la /tmp
fnsysctl ls -la /usr
fnsysctl ls -la /usr/bin
fnsysctl ls -la /var
fnsysctl ls -la /data
fnsysctl ls -la /data2
fnsysctl ls -la /data/lib
fnsysctl ls -la /data/etc
fnsysctl ls -la /data/bin
fnsysctl ls -la /data/cmdb
fnsysctl ls -la /data/config
diagnose sys csum /data/rootfs.gz
diagnose sys csum /data/flatkc
diagnose sys csum /data/lib
diagnose sys csum /bin
diagnose sys csum /bin/sysctl
diagnose sys csum /bin/smit
diagnose sys csum /bin/init
diagnose sys csum /bin/smartctl
diagnose sys csum /bin/lspci
diagnose sys csum /sbin/init
fnsysctl ps
execute tac report
```

| FortiGate command | Evidence in the transcript |
| --- | --- |
| `get system status` | Device identity and running firmware build |
| `diagnose debug crashlog read` | Retained crash records |
| `fnsysctl ls -la <directory>` | Names, sizes, owners and times of files in system and data directories |
| `diagnose sys csum <path>` | Checksums of the root filesystem archive, the kernel image and selected binaries |
| `fnsysctl ps` | Processes visible at collection time |
| `execute tac report` | Diagnostic report, including system and process crash information |

For a small event-log sample over the CLI, select the intended VDOM and check `execute log filter device ?` and `execute log filter category ?`. The example below selects memory logs on builds where device `0` is memory and category `1` is event. Choose the listed disk source instead when it holds the events. This request returns up to 100 entries. Use the log download in Method 1 or the central logger for a longer period. [Fortinet's CLI log display guide](https://community.fortinet.com/fortigate-3/technical-tip-displaying-logs-via-fortigate-s-cli-95301)

```text
execute log filter reset
execute log filter device 0
execute log filter category 1
execute log filter view-lines 100
execute log display
```

Exit any configuration context with `end`, then log out of SSH.

As in Fortinet's procedure, run the file-hash command in a second session with its own transcript. Fortinet documents `diagnose sys filesystem hash` from 7.0.13, 7.2.6 and 7.4.1 onward in their release lines. On VDOM-enabled units, enter `config global` first.

```bash
script -q -c 'ssh -p 22 iradmin@192.0.2.10' "$case_dir/originals/cli-hash.txt"
```

```text
get system status
diagnose sys filesystem hash
```

Fortinet's procedure sends these outputs, with the configuration, the debug report and the system event logs, to Fortinet TAC, where an engineer checks them for signs of compromise. THOR does not replace that check: it compares hash IOCs with the files it reads, not with hashes printed in a transcript.

Check both transcripts for complete output, pager interruptions and permission errors. Record which commands succeeded. Keep the transcripts unchanged in `originals/`; the scan steps below clean a working copy.

## Scan the exported files with THOR Lab

1. **Preserve the collected files.** Check that `originals/` contains the exports you expected for this device. In the same Linux shell, create a SHA-256 inventory, then make a working copy.

   ```bash
   (cd "$case_dir/originals" && find . -type f -exec sha256sum -- {} +) > "$case_dir/SHA256SUMS"
   cp -a "$case_dir/originals/." "$case_dir/scan-input/"
   ```

2. **Prepare the scan input.** THOR checks a file line by line only when it recognizes it as a log, by a `.log` name or a timestamp at the start, and it skips files that do not look like plain-text logs. The CLI transcripts start with the device prompt, so save them as `.log` files without terminal control sequences. The `sed` expressions below use GNU sed syntax.

   ```bash
   for name in cli-session cli-hash; do
     [ -f "$case_dir/originals/$name.txt" ] || continue
     sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' -e 's/.*\r//' \
       "$case_dir/originals/$name.txt" > "$case_dir/scan-input/$name.log"
     rm -- "$case_dir/scan-input/$name.txt"
   done
   ```

   Keep readable configuration and log files in `scan-input/`, and give decompressed logs a `.log` name. Rolled disk logs that FortiOS uploads as they appear on disk use Fortinet's FLZ4 format, for which Fortinet names a third-party `lz4_reader` tool. FortiOS 8.0 can upload standard LZ4 instead, which `lz4 -d` decompresses. Unpack diagnostic archives with a tool for their format. Keep the originals and inventory outside that tree. Encrypted backups require an authorized readable copy to inspect their contents. [FortiOS log formats and extraction](https://docs.fortinet.com/document/fortigate/8.0.0/new-features/772671/secure-log-upload-enhancements-with-sftp-and-lz4-support) · [THOR LogScan module](https://thor-manual.nextron-systems.com/en/latest/usage/scan-modes.html#scan-module-explanation)

3. **Run THOR on the dedicated workstation.** Use the current Linux THOR package and signatures and place the workstation's valid **Forensic Lab License** `.lic` file in the THOR program directory. From that directory, run the example below (x86-64 Linux). `-p` selects the evidence directory, `-j` labels findings with the source device, and `-e` writes reports outside the evidence. [License setup](https://thor-manual.nextron-systems.com/en/latest/usage/beforeyoubegin.html) · [Lab mode](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning) · [Scan output options](https://thor-manual.nextron-systems.com/en/latest/usage/scan.html)

   ```bash
   ./thor-linux-64 --lab -p "$case_dir/scan-input" -j "$device" -e "$case_dir/results"
   ```

4. **Check coverage before reporting a result.** In `results/`, review the THOR log for the source label, input path, completion status, files scanned, errors and skips (including size limits). Report findings against the collection time, VDOM and files examined. A path in a file listing can match a filename IOC once the transcript is scanned as a log, and Fortinet TAC compares the printed hashes with the expected build. To match a content rule or hash IOC against a binary, THOR needs the binary's bytes. A clean scan applies only to the readable evidence examined.

## When the investigation requires system binaries

For a **FortiGate VM**, capture the CLI diagnostics above first: Fortinet's Azure example recommends stopping the VM before the snapshot, which ends its running state. Then acquire a snapshot or copy of the deployed OS disk and any separate data or log disks in scope using the hypervisor or cloud provider. For example, Azure can create a managed-disk snapshot and a working disk from it. Preserve the originals. On Linux, use compatible forensic tools to mount the copy read-only or extract its files, and confirm that the relevant directories contain actual readable files. Some FortiOS builds store the root filesystem inside an encrypted `rootfs.gz`, which requires build-compatible extraction. Dissect's FortiOS support includes decrypting `rootfs.gz`; this guide has not tested it. [FortiGate VM snapshot example](https://community.fortinet.com/fortigate-3/technical-tip-taking-a-snapshot-of-a-fortigate-vm-hosted-on-azure-196588) · [Dissect FortiOS filesystem support](https://docs.dissect.tools/en/latest/api/dissect/target/plugins/os/unix/linux/fortios/_os/index.html)

For **physical appliances**, Fortinet states that it does not provide forensic disk images. There, the IoC outputs above, reviewed by Fortinet TAC, are the documented way to check system files. [Fortinet on forensic images](https://community.fortinet.com/fortigate-3/technical-tip-fortigate-forensic-image-to-detect-coathanger-176054)

If `/mnt/fg01-root` presents the appliance's actual root tree, the following scan maps paths in findings back to their FortiOS locations. For loose exported files, use the directory scan above. [THOR virtual path mapping](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#virtual-drive-mapping)

```bash
mkdir -p "$case_dir/results/filesystem"
./thor-linux-64 --lab -p /mnt/fg01-root --virtual-map /mnt/fg01-root:/ \
  -j "$device" -e "$case_dir/results/filesystem"
```
