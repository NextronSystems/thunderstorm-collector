# Connect ESXi 7 without Secure Boot to THOR Thunderstorm

This document describes on how to install a persistend THOR Thunderstorm collector on an ESXi host without Secure Boot enabled.

## Preparing THOR Thunderstorm


### Choose Port for Outgoing Network Communication of ESXi

After [installing THOR Thunderstorm](https://github.com/NextronSystems/nextron-helper-scripts/tree/master/thunderstorm), you need to select which port ESXi is using for outgoing communication. Configuring a custom port in the host based firewall of ESXi is not trivial. We suggest using an existing, unused rule such as `Software iSCI Client` or an existing and already enabled rule such as `NTP Client`. See `Navigator` > `Networking` > `Firewall rules` for your options.

This guide uses `NTP Client` firwall rule and its `1514/tcp` outgoing port for further illustrations.

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

Edit `/etc/ufw/before.rule` and insert at the very top (excluding comments, i.e. below the comments):
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

1. Download the Python collector script from [scripts/thunderstorm-collector.py](../../scripts/thunderstorm-collector.py) and change any settings in the `Configuration` if you like to.

2. Place the collector script on persistent storage of your choice and create a directory for it: `/vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py`

3. Add these lines to `/etc/rc.local.d/local.sh`. They recreate the needed cronjob after every reboot
```sh
echo "15   02    *    *    *    /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514" >> /var/spool/cron/crontabs/root
touch /var/spool/cron/crontabs/cron.update
```
The first line adds the cronjob to run at 2:15 am every night and can be adapted for your own preferences. (For a bigger number of hosts, the cronjob ideally shouldn't start at the same time for each). The second line touches a file to signal to the cron service to update its configuration.

4. We add the cronjob for the current session by appending to `/var/spool/cron/crontabs/root`
```sh
15   02	  *    *    *    /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514
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
<date> crond[1049149]: USER root pid 1053495 cmd /bin/python /vmfs/volumes/<persistent-storage>/THOR/thunderstorm-collector.py -s <THOR-Thunderstorm-IP/FQDN> -p 1514
```
