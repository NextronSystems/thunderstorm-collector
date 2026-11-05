# Export FortiGate evidence and scan it with THOR on Linux

Use either workflow below to collect data from a physical FortiGate or a FortiGate VM running FortiOS. The GUI is convenient for a configuration backup and a time range of logs. The CLI can send a backup to a Linux SFTP server and print diagnostics that an investigator can capture over SSH. Run THOR with a **Forensic Lab license** on a dedicated Linux analysis workstation after collection.

| Access available | What you can collect |
| --- | --- |
| FortiGate management GUI over HTTPS | Configuration in the administrator's scope, retained event and traffic logs, FortiCare debug report |
| FortiGate CLI over SSH or console | Configuration backup pushed to an external SFTP server, crash records, process and file listings, and file hashes on supported builds |
| Separately acquired system files or VM disks | File contents from the accessible filesystems, including binaries that appear only by name or hash in diagnostics |

## Prepare a case directory on Linux

Use one directory per appliance or HA member and collection run. On the **analysis workstation**, run these commands in Bash. Keep this shell open for the later steps. Replace `FG01` with the source device's hostname.

```bash
umask 077
device=FG01
case_dir=$(mktemp -d "$HOME/${device}-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir -p "$case_dir"/{originals,scan-input,results}
printf '%s\n' "$case_dir"
```

Record the serial number, FortiOS version and build, device time zone, collection time in UTC, HA member and virtual domain (VDOM) in the case notes. Record the log source and time window too. Members of an HA cluster have their own diagnostic state. A VDOM administrator can collect only the configuration within their scope. [Fortinet's multi-VDOM backup guide](https://docs.fortinet.com/document/fortigate/7.6.4/administration-guide/87472) · [Fortinet's IoC collection procedure](https://community.fortinet.com/fortigate-3/technical-tip-collect-indicators-of-compromise-ioc-debug-outputs-on-a-fortigate-vdom-and-non-vdom-manually-177342)

## Method 1 — Download files from the FortiGate GUI

1. **Configuration.** Sign in to the FortiGate management GUI. Open the administrator menu at the upper right, choose **Configuration > Backup**, then **Local PC**. Select the FortiOS configuration format if offered. In multi-VDOM mode, a global administrator can choose **Global** for the appliance configuration or **VDOM** for one domain. Save the download under `originals/`. Configuration exports can contain credentials and private keys. Use password masking if required and record that choice. If policy requires backup encryption, preserve the encrypted original and obtain an approved readable copy for scanning. [FortiOS configuration backup options](https://docs.fortinet.com/document/fortigate/7.6.0/administration-guide/702257)
2. **Event and traffic logs.** Open **Log & Report**, select **System Events** (or **General System Events**) and choose the log source that holds the period of interest. Set the time range and filters, clear any individual row selection, then use **Download**. Repeat for relevant categories such as VPN events and **Forward Traffic**. If logs are retained on FortiAnalyzer or another central logger, export the same device, VDOM and period there. Verify the time span and row count in the downloaded files. GUI limits vary by release, so split the window if a download stops short. Save the files under `originals/`. [Fortinet's log download procedure](https://community.fortinet.com/fortigate-3/technical-tip-how-to-download-logs-from-fortigate-gui-97198)
3. **Diagnostic report.** With `super_admin` access, go to **System > Settings**. On FortiOS 7.4 and 7.6, select **FortiCare Debug Report > Download**. On 7.0 and 7.2 the control is **Debug Logs > Download**. Save the file under `originals/`. For a more complete transcript, use the SSH procedure below. [Fortinet's debug report instructions](https://community.fortinet.com/fortigate-3/technical-tip-download-debug-logs-and-execute-tac-report-92352)

## Method 2 — Push a configuration backup and capture CLI output

### Prepare the SFTP destination

The **FortiGate initiates** the backup connection. The receiver can be the Linux analysis workstation or a separate staging host. It needs a running SFTP service, a route from the FortiGate's management context to its listening port, and a dedicated account with write access to an upload directory. This example uses a password-authenticated account called `fgt_export`, a receiver at `192.0.2.20:22`, and a writable `/incoming` directory as seen by that account. In an SFTP chroot, that path starts at the account's restricted root. For a new receiver, Fortinet provides a Linux OpenSSH setup example with a restricted upload account. [Linux SFTP receiver setup](https://community.fortinet.com/fortigate-3/technical-tip-how-to-send-automated-backups-of-the-configuration-from-a-fortigate-with-an-automation-stitch-using-tftp-ftp-or-sftp-server-and-a-recommendation-for-configuring-a-linux-machine-99783)

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

Open the **FortiGate CLI** over the management console or SSH (for example, `ssh -p 22 iradmin@192.0.2.10` from Linux). Complete the backup before starting the evidence transcript below. Run `get system status` to confirm the source. In multi-VDOM mode, use the intended administrative context. For an appliance-wide backup, a global administrator can enter `config global`. Check the available destinations with `execute backup config ?`. Fortinet documents SFTP configuration backup in the 7.0.1 release. If SFTP is unavailable, use the GUI download or the SCP alternative below. [Fortinet's SFTP backup syntax](https://docs.fortinet.com/document/fortigate/7.0.0/new-features/932215/sftp-configuration-backup-7-0-1)

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

**Alternative when the receiver cannot accept connections from the firewall.** If SSH management and `admin-scp` are already enabled and your FortiGate account has backup privileges, pull the named configuration object directly from Linux. Use this in place of the SFTP transfer. OpenSSH's uppercase `-O` selects legacy SCP. The named object provides the configuration only. SSHFS and the Thunderstorm SFTP collector require an inbound SFTP service exposing readable paths on the source. [Fortinet's SCP backup procedure](https://community.fortinet.com/fortigate-3/technical-tip-how-to-download-a-fortigate-configuration-file-and-upload-a-firmware-file-using-secure-copy-scp-98734)

```bash
scp -O -P 22 iradmin@192.0.2.10:sys_config "$case_dir/originals/FG01.conf"
```

### Save diagnostics from a management session

On the **Linux workstation**, start a fresh SSH session using util-linux `script` to save terminal output. Keep the password-bearing backup command in the earlier session. With a serial console, enable output logging in the terminal client instead.

```bash
script -q -c 'ssh -p 22 iradmin@192.0.2.10' "$case_dir/originals/cli-session.txt"
```

At the **FortiGate prompt**, run the following commands **one at a time**. Advance any pager until the prompt returns. Use `config global` for the global diagnostics on VDOM-enabled units if authorized. The TAC report and `fnsysctl` require the `super_admin` profile. Fortinet documents `diagnose sys filesystem hash` starting with 7.0.13, 7.2.6 and 7.4.1 in their respective release lines. Record unavailable commands or paths for the particular build. [Fortinet's manual IoC procedure and full command list](https://community.fortinet.com/fortigate-3/technical-tip-collect-indicators-of-compromise-ioc-debug-outputs-on-a-fortigate-vdom-and-non-vdom-manually-177342)

| FortiGate command | Evidence in the transcript |
| --- | --- |
| `get system status` | Device identity and running firmware build |
| `diagnose debug crashlog read` | Retained crash records |
| `fnsysctl ps` | Processes visible at collection time |
| `fnsysctl ls -la /data/lib` | Names and metadata in one directory of interest |
| `diagnose sys filesystem hash` | Device-reported file hashes for integrity comparison |
| `execute tac report` | Diagnostic report, including system and process crash information |

For a small event-log sample over the CLI, select the intended VDOM and check `execute log filter device ?` and `execute log filter category ?`. The example below selects memory logs on builds where device `0` is memory and category `1` is event. Choose the listed disk source instead when it holds the events. This request returns up to 100 entries. Use the log download in Method 1 or the central logger for a longer period. [Fortinet's CLI log display guide](https://community.fortinet.com/fortigate-3/technical-tip-displaying-logs-via-fortigate-s-cli-95301)

```text
execute log filter reset
execute log filter device 0
execute log filter category 1
execute log filter view-lines 100
execute log display
```

Exit any configuration context with `end`, then log out of SSH. Check the saved transcript for complete output, pager interruptions and permission errors. Record which commands succeeded. Preserve the original even if you clean terminal control characters from a working copy.

## Scan the exported files with THOR Lab

1. **Preserve the collected files.** Check that `originals/` contains the exports you expected for this device. In the same Linux shell, create a SHA-256 inventory, then make a working copy.

   ```bash
   (cd "$case_dir/originals" && find . -type f -exec sha256sum -- {} +) > "$case_dir/SHA256SUMS"
   cp -a "$case_dir/originals/." "$case_dir/scan-input/"
   ```

2. **Prepare the scan input.** Keep readable configuration and log files in `scan-input/`. Unpack compressed logs or diagnostic archives there with a tool for their format. Keep the originals and inventory outside that tree. For example, FortiOS 8.0 can upload rolled disk logs in standard LZ4 or Fortinet FLZ4 format. The formats require different decoders. Encrypted backups require an authorized readable copy to inspect their contents. [FortiOS log formats and extraction](https://docs.fortinet.com/document/fortigate/8.0.0/new-features/772671/secure-log-upload-enhancements-with-sftp-and-lz4-support)

3. **Run THOR on the dedicated workstation.** Use the current Linux THOR package and signatures and place the workstation's valid **Forensic Lab** `.lic` file in the THOR program directory. From that directory, run the example below (x86-64 Linux). `-p` selects the evidence directory, `-j` labels findings with the source device, and `-e` writes reports outside the evidence. [License setup](https://thor-manual.nextron-systems.com/en/latest/usage/beforeyoubegin.html) · [Lab mode](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#lab-scanning) · [Scan output options](https://thor-manual.nextron-systems.com/en/latest/usage/scan.html)

   ```bash
   ./thor-linux-64 --lab -p "$case_dir/scan-input" -j "$device" -e "$case_dir/results"
   ```

4. **Check coverage before reporting a result.** In `results/`, review the THOR log for the source label, input path, completion status, files scanned, errors and skips (including size limits). Report findings against the collection time, VDOM and files examined. A file listing or hash lets an analyst identify a path or compare a hash with the expected firmware build. THOR needs the underlying bytes to match a content rule against that binary. A clean scan applies only to the readable evidence examined.

## When the investigation requires system binaries

For a **FortiGate VM**, acquire a snapshot or copy of the deployed OS disk and any separate data or log disks in scope using the hypervisor or cloud provider. For example, Azure can create a managed-disk snapshot and a working disk from it. Preserve the originals. On Linux, use compatible forensic tools to mount the copy read-only or extract its files. Confirm that the relevant directories contain actual readable files. Some FortiOS builds store the root filesystem inside an encrypted `rootfs.gz`, which requires build-compatible extraction. For **physical appliances**, confirm the available acquisition procedure for that model and build with Fortinet TAC or the forensic team before offering this level of coverage. [FortiGate VM snapshot example](https://community.fortinet.com/fortigate-3/technical-tip-taking-a-snapshot-of-a-fortigate-vm-hosted-on-azure-196588) · [Dissect FortiOS filesystem support](https://docs.dissect.tools/en/latest/api/dissect/target/plugins/os/unix/linux/fortios/_os/index.html) · [Fortinet's forensic image guidance](https://community.fortinet.com/fortigate-3/technical-tip-fortigate-forensic-image-to-detect-coathanger-176054)

If `/mnt/fg01-root` presents the appliance's actual root tree, the following scan maps paths in findings back to their FortiOS locations. For loose exported files, use the directory scan above. [THOR virtual path mapping](https://thor-manual.nextron-systems.com/en/latest/usage/special-scan-modes.html#virtual-drive-mapping)

```bash
mkdir -p "$case_dir/results/filesystem"
./thor-linux-64 --lab -p /mnt/fg01-root --virtual-map /mnt/fg01-root:/ \
  -j "$device" -e "$case_dir/results/filesystem"
```
