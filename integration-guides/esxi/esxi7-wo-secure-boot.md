# Connect ESXi 7 without Secure Boot to THOR Thunderstorm

Run the Python collector on an ESXi 7 host without Secure Boot, started every
night by cron. A line in `/etc/rc.local.d/local.sh` recreates the cron job
after each reboot.

> [!NOTE]
> Earlier Python collector revisions ran on ESXi, but the versions were not
> recorded. Validate the current collector on the target first with the
> [ESXi collector requirements and quick start](../../scripts/README.md#vmware-esxi-use-the-python-collector).

For a one-time assessment without anything running on the host, see
[SSHFS as an ad hoc alternative](#sshfs-alternative-for-an-ad-hoc-assessment).

## Before You Start

| Requirement | Detail |
|---|---|
| ESXi host | ESXi 7 with **Secure Boot disabled** (check below) |
| Thunderstorm | An installed THOR Thunderstorm server, for example with the [Thunderstorm installer scripts](https://github.com/NextronSystems/nextron-helper-scripts/tree/master/thunderstorm) |
| Network | An outbound TCP port the ESXi firewall allows to the Thunderstorm server. The examples use **1514** |
| Python | An interpreter already on the host: **Python 3.4+** for the Python 3 collector, **Python 2.7** for the separate Python 2 collector |
| Storage | Persistent storage for the script under `/vmfs/volumes/<persistent-storage>/` |
| Scope | An explicit collection directory for the assessment |

Use an interpreter that is already available. The
[ESXi quick start](../../scripts/README.md#vmware-esxi-use-the-python-collector)
does not require installing an unsupported runtime or changing ESXi security
settings.

Check that Secure Boot is disabled:

```sh
/usr/lib/vmware/secureboot/bin/secureBoot.py -s
esxcli system settings encryption get
```

Expected output (the first line comes from `secureBoot.py`):

```text
Disabled
   Mode: NONE
   Require Executables Only From Installed VIBs: false
   Require Secure Boot: false
```

## Steps

### 1. Choose the outbound port

On the ESXi host, open `Navigator` > `Networking` > `Firewall rules`.
Find a rule that allows outbound TCP connections to the Thunderstorm server,
and confirm its protocol, port and allowed destinations.

The examples use TCP port **1514**, which Broadcom lists as an outbound port
of the syslog firewall ruleset. Check that this rule is enabled and permits
connections to the Thunderstorm endpoint. If you use a different allowed port,
substitute it in all examples.

Sources: [Broadcom: configuring syslog on ESXi](https://knowledge.broadcom.com/external/article/318939/configuring-syslog-on-vmware-vsphere-esxi.html)

### 2. Make Thunderstorm reachable on that port

Choose one option on the Thunderstorm server:

| Option | When to use it |
|---|---|
| **A. Port forwarding** (preferred) | Thunderstorm keeps its port (8080 here); the firewall redirects 1514 to it. More flexible in mixed environments, at the cost of extra setup |
| **B. Change the listening port** | Thunderstorm listens on 1514 directly |

<details>
<summary>Option A: local port forwarding with ufw (Debian)</summary>

1. Install `ufw`:

   ```sh
   sudo apt install ufw -y
   ```

2. Allow incoming SSH and the Thunderstorm ports:

   ```sh
   sudo ufw allow proto tcp to any port 22   # SSH
   sudo ufw allow proto tcp to any port 8080 # general purpose
   sudo ufw allow proto tcp to any port 1514 # ESXi
   ```

3. Edit `/etc/ufw/before.rules` and insert these lines at the very top, below
   the leading comments:

   ```sh
   *nat
   :PREROUTING ACCEPT [0:0]
   -A PREROUTING -p tcp --dport 1514 -j REDIRECT --to-port 8080
   COMMIT
   ```

   Check the result:

   ```sh
   sudo grep -vE "^$|^#" /etc/ufw/before.rules | head -4
   ```

   Expected output:

   ```text
   *nat
   :PREROUTING ACCEPT [0:0]
   -A PREROUTING -p tcp --dport 1514 -j REDIRECT --to-port 8080
   COMMIT
   ```

4. Enable and reload the firewall:

   ```sh
   sudo ufw enable
   sudo ufw reload
   ```

</details>

<details>
<summary>Option B: change the Thunderstorm listening port</summary>

1. Set `server-port` in `/etc/thunderstorm/thunderstorm.yml` to the port, for
   example 1514. Check it:

   ```sh
   grep server-port /etc/thunderstorm/thunderstorm.yml
   ```

   Expected output: `server-port: 1514`

2. Restart the service:

   ```sh
   systemctl restart thor-thunderstorm.service
   ```

</details>

### 3. Install the collector on persistent storage

1. Download the [Python 3 collector](../../scripts/python/thunderstorm-collector.py),
   or the [Python 2 collector](../../scripts/python/thunderstorm-collector-py2.py)
   if required. Configure its `USER CONFIGURATION` block or command-line
   options as described in the [Python guide](../../scripts/python/README.md).
2. Create a directory on persistent storage of your choice and place the
   script there: `/vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py`
3. Run a manual preview and upload, and check them, before scheduling.

In the cron lines below, replace:

- `/bin/python` with the selected interpreter (it is a placeholder; check its
  version);
- the script filename, if you use the Python 2 collector;
- `<THOR-Thunderstorm-IP/FQDN>` and the port, if not 1514;
- `/absolute/path/to/collection-root` with the explicit collection directory.

### 4. Recreate the cron job at every boot

Add these lines to `/etc/rc.local.d/local.sh`:

```sh
echo "15   02    *    *    *    /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514 --dirs /absolute/path/to/collection-root" >> /var/spool/cron/crontabs/root
touch /var/spool/cron/crontabs/cron.update
```

- The first line adds a cron job that runs every night at **2:15 am**. Adapt
  the time as needed; with many hosts, do not start them all at the same
  time.
- The second line signals the cron service to reload its configuration.

### 5. Add the cron job for the current session

1. Append this line to `/var/spool/cron/crontabs/root`:

   ```sh
   15   02	  *    *    *    /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514 --dirs /absolute/path/to/collection-root
   ```

2. Signal the configuration update:

   ```sh
   touch /var/spool/cron/crontabs/cron.update
   ```

## Verify

1. **Network connectivity.** From the ESXi host, connect with `openssl`:

   ```sh
   openssl s_client -connect <Thunderstorm-IP>:1514
   ```

   If the port is reachable, the answer is instant and starts with
   `CONNECTED`. Without connectivity, the command most likely runs into a
   timeout.

   <details>
   <summary>Example output</summary>

   ```text
   CONNECTED(00000003)
   331003098216:error:140770FC:SSL routines:SSL23_GET_SERVER_HELLO:unknown protocol:s23_clnt.c:827:
   ---
   no peer certificate available
   ---
   No client certificate CA names sent
   ---
   SSL handshake has read 7 bytes and written 215 bytes
   ---
   New, (NONE), Cipher is (NONE)
   Secure Renegotiation IS NOT supported
   Compression: NONE
   Expansion: NONE
   No ALPN negotiated
   SSL-Session:
       Protocol  : TLSv1.2
       Cipher    : 0000
       Session-ID:
       Session-ID-ctx:
       Master-Key:
       Key-Arg   : None
       PSK identity: None
       PSK identity hint: None
       SRP username: None
       Start Time: 1707482030
       Timeout   : 300 (sec)
       Verify return code: 0 (ok)
   ---
   ```

   </details>

2. **Cron job runs.** Check the THOR Thunderstorm status page. If the host
   does not show up there, search the ESXi syslog:

   ```sh
   grep crond /var/log/syslog.log |grep thunderstorm
   ```

   A started job looks like this:

   ```text
   <date> crond[1049149]: USER root pid 1053495 cmd /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514 --dirs /absolute/path/to/collection-root
   ```

## Background

### SSHFS: alternative for an ad hoc assessment

For a one-time assessment, you can mount accessible ESXi directories over
**SSHFS** and scan them with THOR on a supported analysis workstation. The ESXi
host needs suitable SSH/SFTP access and read permissions; it runs no scanner
or collector, and none of the setup above is needed. Check the host's access
policy separately.

A scheduled collector is useful for recurring assessments where on-host
execution is permitted.

Sources: [Choosing a THOR scanning approach](../../docs/SCANNING_APPROACHES.md) (prerequisites, licensing, evidence coverage) · [ESXi SSHFS walkthrough](https://www.nextron-systems.com/2023/02/14/how-to-scan-esxi-systems-using-thor/)
