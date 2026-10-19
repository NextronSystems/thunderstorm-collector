# Connect ESXi 7 without Secure Boot to THOR Thunderstorm

This guide describes persistent THOR Thunderstorm collection on an ESXi 7 host without Secure Boot enabled. Before scheduling it, follow the current [ESXi collector requirements and quick start](../../scripts/README.md#vmware-esxi-use-the-python-collector) to select and validate the Python collector on the target.

## Alternative for an Ad Hoc Assessment

For a one-time assessment, you can also mount accessible ESXi directories over
**SSHFS** and scan them with THOR on a supported analysis workstation. The ESXi
host needs suitable SSH/SFTP access and read permissions; it does not run a
scanner or collector. This alternative does not require the persistent collector
setup below. Check the host's access policy separately.

See [Choosing a THOR scanning approach](../../docs/SCANNING_APPROACHES.md) for
prerequisites, licensing and evidence coverage, and the
[ESXi SSHFS walkthrough](https://www.nextron-systems.com/2023/02/14/how-to-scan-esxi-systems-using-thor/)
for the appliance example. A scheduled collector is useful for recurring
assessments where on-host execution is permitted.

## Preparing THOR Thunderstorm


### Choose Port for Outgoing Network Communication of ESXi

After [installing THOR Thunderstorm](https://github.com/NextronSystems/nextron-helper-scripts/tree/master/thunderstorm), choose a TCP port that the ESXi host is permitted to use for connections to that server. Inspect the rules under `Navigator` > `Networking` > `Firewall rules` and confirm the protocol, port, and allowed destinations.

The examples below use TCP port 1514, which Broadcom lists as an outbound port of the [syslog firewall ruleset](https://knowledge.broadcom.com/external/article/318939/configuring-syslog-on-vmware-vsphere-esx.html). Verify that the applicable rule is enabled and permits connections to the Thunderstorm endpoint. If your collection procedure uses a different allowed TCP port, substitute it throughout the examples.

### Configure THOR Thunderstorm Listening Port

You have two options:

1. Change the listening port of THOR Thunderstorm to match the ESXi outgoing port
2. Configure local port forwarding to relay incoming ESXi connections to the THOR Thunderstorm listening port

Generally the second option is preferred because it offers greater flexibility in heterogenous environments at the cost of some additional configuration effort.

#### 1. Changing the THOR Thunderstorm Listening Port

<details>
    <summary>Expand Details</summary>
   
If you choose this approach, change `server-port` in `/etc/thunderstorm/thunderstorm.yml` to your desired port (e.g. 1514).

To verify the change:

```sh
$ grep server-port /etc/thunderstorm/thunderstorm.yml
server-port: 1514
```

And restart the service:
```sh
$ systemctl restart thor-thunderstorm.service
```
</details>

#### 2. Configure Local Port Forwarding

<details>
    <summary>Expand Details</summary>
   
We are going to use the host based firewall for local port forwarding. On Debian one easy choice is `ufw` which can be installed using

```sh
$ sudo apt install ufw -y
```

Allow incoming communication for SSH and the THOR Thunderstorm listening ports:
```sh
sudo ufw allow proto tcp to any port 22   # SSH
sudo ufw allow proto tcp to any port 8080 # general purpose
sudo ufw allow proto tcp to any port 1514 # ESXi
```

Edit `/etc/ufw/before.rules` and insert at the very top (excluding comments, i.e. below the comments):
```sh
*nat
:PREROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport 1514 -j REDIRECT --to-port 8080
COMMIT
```

Verify with:
```sh
$ sudo grep -vE "^$|^#" /etc/ufw/before.rules | head -4
*nat
:PREROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport 1514 -j REDIRECT --to-port 8080
COMMIT
```

Now enable and start/reload the firewall:
```sh
sudo ufw enable
sudo ufw reload
```
</details>


## Configure the ESXi Host

The examples below use `/bin/python` as a placeholder for the available interpreter. Verify its version: the current Python 3 collector requires Python 3.4+, while the separate Python 2 collector requires Python 2.7. Substitute the selected interpreter and script filename in both cron examples. Replace the collection-directory placeholder with an explicit path for the intended assessment, and verify a manual preview and upload before scheduling it.

1. Download the [Python 3 collector](../../scripts/python/thunderstorm-collector.py), or the [Python 2 collector](../../scripts/python/thunderstorm-collector-py2.py) if required, and configure its `USER CONFIGURATION` block or command-line options as described in the [Python guide](../../scripts/python/README.md).

2. Place the collector script on persistent storage of your choice and create a directory for it: `/vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py`

3. Add these lines to `/etc/rc.local.d/local.sh`. They recreate the needed cronjob after every reboot
```sh
echo "15   02    *    *    *    /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514 --dirs /absolute/path/to/collection-root" >> /var/spool/cron/crontabs/root
touch /var/spool/cron/crontabs/cron.update
```
The first line adds the cronjob to run at 2:15 am every night and can be adapted for your own preferences. (For a bigger number of hosts, the cronjob ideally shouldn't start at the same time for each). The second line touches a file to signal to the cron service to update its configuration.

4. We add the cronjob for the current session by appending to `/var/spool/cron/crontabs/root`
```sh
15   02	  *    *    *    /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514 --dirs /absolute/path/to/collection-root
```
5. and signaling the configuration update.
```sh
touch /var/spool/cron/crontabs/cron.update
```



## Troubleshooting

1. Do I have Secure Boot enabled?

Check using:
```sh
[root@esxi-host:~] /usr/lib/vmware/secureboot/bin/secureBoot.py -s
Disabled
[root@esxi-host:~] esxcli system settings encryption get
   Mode: NONE
   Require Executables Only From Installed VIBs: false
   Require Secure Boot: false
```

2. Do I have network connectivity to THOR Thunderstorm?

You can verify using openssl. If successful, the return will be instant.
```sh
[root@esxi-host:~] openssl s_client -connect <Thunderstorm-IP>:1514
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
If there's no connectivity, you most likely will run into a timeout.

3. Is the cron job actually starting?

If it doesn't show in the THOR Thunderstorm status page, you can check syslog on the ESXi host:
```sh
[root@esxintern-30:~] grep crond /var/log/syslog.log |grep thunderstorm
<date> crond[1049149]: USER root pid 1053495 cmd /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514 --dirs /absolute/path/to/collection-root
```
