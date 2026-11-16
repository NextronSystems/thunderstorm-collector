# Running collections from a central orchestrator

[Scanning approaches](SCANNING_APPROACHES.md) · [Collector recommendations](COLLECTOR_RECOMMENDATIONS.md) · [Product integration guides](../integration-guides/README.md)

An orchestrator is one Linux machine that starts every collection run for a group of appliances. For each device, it copies a collector to the device, starts it, fetches its log and removes it again. Where a device cannot run a collector, the same machine pulls the files itself with the [SFTP collector](../sftp/README.md). Schedules, credentials, collector versions and run records then live in one place, and nothing stays installed on the devices between runs.

The orchestrator needs only the OpenSSH client, cron and the collectors; no other software is involved. This page describes the pattern and gives a reference script. The script has not been run against real appliances. The [NetScaler guide](../integration-guides/citrix/netscaler-collection-and-scanning.md#from-a-scheduler-host) has the worked example for one device type, with the same status.

## When to use it

Use an orchestrator when:

- **many appliances or several device types** are collected on a schedule;
- **nothing should change on the devices** between runs, so that firmware upgrades, HA synchronization or someone with shell access cannot drop or alter the setup;
- **one place should show** which runs succeeded, failed or did not happen.

The alternative is a scheduled job on each device, such as cron. The [NetScaler guide compares the two](../integration-guides/citrix/netscaler-collection-and-scanning.md#repeat-collections). A scheduled job on the device needs no inbound SSH, but it is a lasting change on every device. On appliances it also resembles the cron persistence that attackers use.

An orchestrator does not fit:

- a one-time assessment of a few devices; run the collector by hand, or scan over [SSHFS](SCANNING_APPROACHES.md#remote-filesystem-scans-with-sshfs);
- environments where no system may hold administrative SSH keys for the devices;
- devices without SSH, which need the vendor's export procedure (see below).

## What runs where

| Component | Role |
| --- | --- |
| **Orchestrator** | A Linux machine with the OpenSSH client and cron. It holds the inventory, one run directory per device type, the SSH key, the known host keys and the run records. It can also run the SFTP collector. |
| **Devices** | Receive the collector for the duration of a run. They need SSH from the orchestrator and, for collectors that run on the device, a network path to Thunderstorm. |
| **Thunderstorm** | Receives the files: from the devices when a collector runs on them, from the orchestrator in pull mode. |

The orchestrator can run on the Thunderstorm server itself. A separate small VM is the better choice: the orchestrator holds administrative access to every device, and the Thunderstorm server receives potentially malicious files from many sources. Keeping the two apart limits what a compromise of either one exposes.

## Sort the devices into collection modes

Start with an inventory of the device types in scope: vendor, product and model, firmware or OS version, CPU architecture, whether administrators get a shell or only a vendor CLI, whether SSH, SCP or SFTP is available, and whether the device can reach Thunderstorm. The [collector recommendations](COLLECTOR_RECOMMENDATIONS.md#edge-appliances-and-nas) list the candidate collectors for many products. Then assign each device type a mode:

| Mode | The device offers | The orchestrator | Collector | Files reach Thunderstorm from |
| --- | --- | --- | --- | --- |
| **Push, run, remove** | SSH with a shell that can run a collector | Copies the run directory, starts the collector, fetches the log and the exit status, removes the directory | The Go binary or the script collector that fits the device | The device |
| **Pull** | SFTP, but no shell that can run a collector, or no path to Thunderstorm | Runs the [SFTP collector](../sftp/README.md) (prototype) against the device | SFTP collector on the orchestrator | The orchestrator |
| **Export** | Only a vendor CLI or GUI | Collects exports where the vendor can push them on a schedule; otherwise an administrator exports them | THOR in lab mode, or a collector that uploads the exports | The orchestrator or an analysis workstation |

The [FortiGate guide](../integration-guides/fortinet/fortigate-export-thor-lab.md) is an example of the export mode. Vendors restrict shells and third-party software in different ways, so check each device type against its vendor's terms before choosing the push mode.

## Prepare the orchestrator

The reference script expects this layout:

```text
/opt/nextron/
  collect-all.sh                      the reference script below
  inventory.txt                       one line per device
  .ssh/orchestrator_ed25519           private key, readable only by the account that runs cron
  .ssh/known_hosts                    verified host keys of all devices
  types/<type>/nextron-thunderstorm/  run directory copied to devices of this type
  logs/<device>/<UTC time>/           collector log and exit status of each run
```

1. **Create the key.** cron runs without a person present, so the key has no passphrase; protect it with file permissions and use it for nothing else:

   ```bash
   ssh-keygen -t ed25519 -N '' -C thunderstorm-orchestrator -f /opt/nextron/.ssh/orchestrator_ed25519
   ```

2. **Install the public key on every device** with the vendor's procedure, for an account that can run the collector. For NetScaler, see [SSH key-based authentication for local system users](https://docs.netscaler.com/en-us/citrix-adc/current-release/system/authentication-and-authorization-for-system-user/ssh-key-based-authentication-for-system-users.html).

3. **Record the host keys.** The script refuses unknown or changed host keys. Fetch each device's key once and compare its fingerprint with the one shown on the device's console:

   ```bash
   ssh-keyscan -t ed25519 192.0.2.10 >> /opt/nextron/.ssh/known_hosts
   ssh-keygen -lf /opt/nextron/.ssh/known_hosts
   ```

   The script points `UserKnownHostsFile` at this file.

4. **Build one run directory per device type** under `types/<type>/nextron-thunderstorm/`: the collector for that device, its configuration and a `run.sh` that starts it. The configuration must exclude the run directory's path on the device, so the collector does not submit itself. For NetScaler, follow [Prepare a run directory on the workstation](../integration-guides/citrix/netscaler-collection-and-scanning.md#prepare-a-run-directory-on-the-workstation) and add this `run.sh`:

   ```sh
   #!/bin/sh
   # run.sh NAME [AGE]: runs on the device, starts the collector and records its exit status.
   cd "$(dirname "$0")" || exit 1
   ./amd64-freebsd8-netscaler-thunderstorm-collector -t ./netscaler-run.yml -o "$1" --dry-run=false \
     ${2:+-a "$2"} -l ./upload.log >/dev/null 2>&1
   echo $? > ./exit-status
   ```

   For a script collector, `run.sh` starts the script with its own options instead. The script collectors' age options take whole days; see each collector's README.

5. **Write the inventory**, one device per line. The name becomes the source name in Thunderstorm, so list every node of an HA pair or cluster under its own name:

   ```text
   # name        type        address       user
   ns01-node0    netscaler   192.0.2.10    nsadmin
   ns01-node1    netscaler   192.0.2.11    nsadmin
   ```

6. **Run the first collection of each device type by hand** as described in its guide, then run `collect-all.sh` once by hand and check every device's log before scheduling it.

## Reference script

```bash
#!/bin/bash
# collect-all.sh: one collection run on every device in the inventory.
# Usage: collect-all.sh [full]    ("full" runs without the age limit)
set -u
BASE=/opt/nextron
KEY=$BASE/.ssh/orchestrator_ed25519
OPTS=(-i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes
      -o UserKnownHostsFile="$BASE/.ssh/known_hosts" -o ConnectTimeout=30)
AGE=2d; [ "${1:-}" = full ] && AGE=

exec 9>"$BASE/collect-all.lock"
flock -n 9 || { echo "collect-all: the previous run is still active" >&2; exit 1; }

failed=0
while read -r name type address user <&3; do
  case $name in ''|'#'*) continue ;; esac
  case $type in
    netscaler*) parent=/var;     wrap() { printf 'shell "%s"' "$1"; } ;;
    posix*)     parent=/var/tmp; wrap() { printf '%s' "$1"; } ;;
    *) echo "$name: unknown device type '$type'" >&2; failed=1; continue ;;
  esac
  run_dir=$parent/nextron-thunderstorm
  out=$BASE/logs/$name/$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$out"

  scp -O -q -r "${OPTS[@]}" "$BASE/types/$type/nextron-thunderstorm" "$user@$address:$parent/" &&
    ssh -n "${OPTS[@]}" "$user@$address" "$(wrap "sh $run_dir/run.sh $name $AGE")"
  scp -O -q "${OPTS[@]}" "$user@$address:$run_dir/upload.log" "$user@$address:$run_dir/exit-status" "$out/"
  ssh -n "${OPTS[@]}" "$user@$address" "$(wrap "rm -rf $run_dir")"

  status=$(cat "$out/exit-status" 2>/dev/null)
  if [ "$status" = 0 ]; then
    echo "$name: completed; log in $out"
  else
    echo "$name: FAILED (collector exit status: ${status:-none}); see $out" >&2
    failed=1
  fi
done 3< "$BASE/inventory.txt"
exit $failed
```

How it behaves:

- **One device after another.** A lock file stops a new run while the previous one is still active, so a long run cannot overlap the next scheduled one. [flock(1)](https://man7.org/linux/man-pages/man1/flock.1.html)
- **Device types.** The `case` block sets two things per type: the directory on the device that receives the run directory, and how a command is passed to the device's shell. NetScaler commands go through the CLI's `shell` command. `posix…` types cover devices whose SSH account runs commands in a POSIX shell directly; name them by device and CPU, such as `posix-linux-amd64`, and give each its own run directory. Add a `case` entry and a `types/` folder for each new device type.
- **Exit status.** `run.sh` writes the collector's exit status to a file on the device, and the orchestrator fetches it with the log. The result therefore does not depend on whether a vendor CLI passes the exit status through SSH. For the Go collector, status 1 also covers files that could not be read, so an account without read access to some paths shows up as a failed run. See the [Go collector's exit status](../go/README.md#exit-status).
- **Records.** Each run leaves `upload.log` and `exit-status` under `logs/<device>/<UTC time>/`. A device without them did not run. The script prints each failure and exits with status 1 if any device failed, so cron's mail to the account or your monitoring can pick it up.
- **Cleanup.** The run directory is removed even when the collector failed. A device that cannot be reached is reported and skipped.
- **Transfers.** `scp -O` selects the original SCP protocol, which works without an SFTP subsystem on the device; OpenSSH before 8.7 does not know the option and uses that protocol anyway. See the [NetScaler guide's note](../integration-guides/citrix/netscaler-collection-and-scanning.md#access-and-file-transfer).

## Schedule the runs

Schedule the script with cron on the orchestrator, as the account that owns the key. This example runs an incremental collection from Monday to Saturday and a full one on Sundays:

```text
30 2 * * 1-6  /opt/nextron/collect-all.sh
30 2 * * 0    /opt/nextron/collect-all.sh full
```

For a monthly full collection only, use `0 2 1 * * /opt/nextron/collect-all.sh full`. A full run sends every selected file each time, so plan for that load on the network and on Thunderstorm. [Recurring collection](SCANNING_APPROACHES.md#recurring-collection) explains how to combine incremental and full runs.

## Network paths

In push mode, the orchestrator needs SSH to each device's management address, and each device needs a path to the Thunderstorm port. Where a device cannot reach Thunderstorm, three options remain. None of them has been tested with this script:

- **Pull mode.** If the device offers SFTP, the SFTP collector on the orchestrator collects from it, and the device needs no path to Thunderstorm.
- **A proxy on the orchestrator.** The Go collector can send its uploads through an HTTP proxy with `--http-proxy`. The Bash, POSIX sh, Perl and Python collectors always connect directly and ignore proxy settings.
- **SSH remote forwarding.** Adding `-R 18080:thunderstorm.example.org:8080` to the `ssh` call that starts `run.sh` opens port 18080 on the device's loopback interface for the duration of the session and forwards it to Thunderstorm. The collector then connects to `127.0.0.1` port 18080. The device's SSH server must allow TCP forwarding, which OpenSSH does by default and which vendors may disable. With HTTPS, the server certificate must be valid for the name the collector connects to. [ssh(1)](https://man.openbsd.org/ssh) · [sshd_config(5)](https://man.openbsd.org/sshd_config)

## Pull mode with the SFTP collector

The SFTP collector runs on the orchestrator and reads the selected files over SFTP; nothing is copied to the device. Run it from the same schedule, for example from a second script. Its `--manifest` and `--stats-json` files serve as the run records, and its exit status reports failed reads, a lost connection or an unreachable Thunderstorm. It uses SSH keys and a `known_hosts` file like the script above. It is a prototype; see its [usage and limits](../sftp/README.md#usage).

## Secure the orchestrator

The orchestrator can log in to every device with administrative rights. Treat it as a sensitive system:

- Use a dedicated machine or VM that runs nothing else, and allow administrative logins to it only from your administration network.
- Use the key only for collection, and where the devices allow it, accept SSH from the orchestrator's address only. For NetScaler, Citrix describes ACLs for management access in its [secure deployment guidance](https://docs.netscaler.com/en-us/netscaler-adc-secure-deployment/administration-and-management/system-and-user-accounts).
- Keep the run directories writable only by administrators: whatever is in them runs on every device. Verify each collector release against its published checksum before copying it there.
- Keep host key checking strict. A changed host key stops the run for that device until someone has checked why it changed.

## Limits

- The reference script and the network options have not been tested against real appliances. Run every device type by hand first.
- Device types differ in shells, file locations, permissions and vendor restrictions. Each type needs its own run directory, `run.sh` and checks.
- Firmware upgrades can change shell access, remove the key or change the host key. Check the run records after upgrades.
- A collector run sees only files. It does not record process memory, network connections or deleted files; see [evidence coverage](SCANNING_APPROACHES.md#evidence-coverage).
