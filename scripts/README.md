# THOR Thunderstorm Collector Scripts

Lightweight, dependency-minimal scripts for collecting and submitting file samples to a [THOR Thunderstorm](https://www.nextron-systems.com/thor-thunderstorm/) server for YARA-based scanning.

Designed for forensic triage, incident response, and continuous monitoring — often on systems where installing a full agent is impractical or undesirable.

## Cross-Platform Test Matrix

All collectors are tested against a comprehensive matrix of operating systems and environments:

### Linux Containers (podman/Docker)

| Distro | Bash | Ash/sh | Python3 | Perl |
|--------|------|--------|---------|------|
| Alpine Linux | ✅ | ✅ | ✅ | ✅ |
| Debian | ✅ | ✅ | ✅ | ✅ |
| Ubuntu 22.04 | ✅ | ✅ | ✅ | ✅ |
| Fedora | ✅ | ✅ | ✅ | ✅ |
| CentOS Stream 9 | ✅ | ✅ | ✅ | ✅ |
| Arch Linux | ✅ | ✅ | ✅ | ✅ |
| openSUSE Tumbleweed | ✅ | ✅ | ✅ | ✅ |
| Amazon Linux 2023 | ✅ | ✅ | ✅ | ✅ |
| Rocky Linux 9 | ✅ | ✅ | ✅ | ✅ |

### BSD VMs

| OS | Bash | sh | Python3 | Perl |
|----|------|-----|---------|------|
| FreeBSD 14.3 | ✅ | ✅ | ✅ | ✅ |
| OpenBSD 7.8 | ✅ | ✅ | — | ✅ |

**Total: 43 tests, 43 passing** (tested 2025-02-25)

---

## Quick Start

```bash
# Linux/macOS — Bash
bash thunderstorm-collector.sh --server thunderstorm.local --dir /home

# Embedded Linux / BusyBox / Alpine — POSIX sh
sh thunderstorm-collector-ash.sh --server thunderstorm.local --dir /tmp

# Cross-platform — Python 3
python3 thunderstorm-collector.py -s thunderstorm.local -d /home

# Legacy systems — Python 2
python thunderstorm-collector-py2.py -s thunderstorm.local -d /home

# Unix with Perl
perl thunderstorm-collector.pl -s thunderstorm.local --dir /home

# Windows — PowerShell 3+
powershell.exe -ep bypass .\thunderstorm-collector.ps1 -ThunderstormServer thunderstorm.local

# Windows — PowerShell 2+
powershell.exe -ep bypass .\thunderstorm-collector-ps2.ps1 -ThunderstormServer thunderstorm.local

# Windows — Batch (legacy)
thunderstorm-collector.bat
```

## Choosing the Right Collector

| Scenario | Recommended Collector |
|---|---|
| Modern Linux server or workstation | `thunderstorm-collector.sh` (Bash) |
| macOS (any version) | `thunderstorm-collector.sh` (Bash) |
| Embedded Linux / BusyBox / router / IoT | `thunderstorm-collector-ash.sh` (POSIX sh) |
| Alpine Docker container | `thunderstorm-collector-ash.sh` (POSIX sh) |
| Cross-platform, single script | `thunderstorm-collector.py` (Python 3) |
| Legacy Linux (RHEL/CentOS 7, Debian 7/8) | `thunderstorm-collector-py2.py` (Python 2) |
| Solaris, AIX, HP-UX | `thunderstorm-collector.pl` (Perl) |
| Windows 7+ / Server 2008 R2+ (PS 3+) | `thunderstorm-collector.ps1` |
| Windows 7 / Server 2008 R2 (PS 2) | `thunderstorm-collector-ps2.ps1` |
| Windows XP / Server 2003 / no PowerShell | `thunderstorm-collector.bat` |

---

## Collector Reference

### Bash Collector — `thunderstorm-collector.sh`

The most feature-complete Linux/macOS collector. Supports both `curl` and `wget` as upload backends with automatic detection and fallback.

**Use on:** Linux servers, workstations, macOS, WSL, any system with Bash 3.2+.

| Requirement | Detail |
|---|---|
| Shell | Bash 3.2+ |
| Upload tool | `curl` or `wget` (at least one) |
| TLS | Via curl/wget flags (`--ssl`) |

**Features:**
- Automatic curl/wget detection and fallback
- Retry with exponential backoff (configurable)
- Safe handling of filenames with spaces, quotes, and special characters (`find -print0`)
- URL-encoded source identifiers
- Syslog integration (`--syslog`), log file output (`--log-file`), dry-run mode (`--dry-run`)

**Limitations:**
- Not compatible with `ash`, `dash`, or plain `sh` — uses Bash arrays, `${var//pattern}`, `read -d ''`, C-style for loops
- Requires `curl` or `wget` as external dependency

**Tested Environments:**

| Environment | Bash | curl | wget | Result |
|---|---|---|---|---|
| Fedora 43 | 5.2 | ✅ | ✅ | ✅ 28/28 tests, 10/10 files |
| CentOS 7 | 4.2 | ✅ | ✅ | ✅ 10/10 files |
| Debian 9 (Stretch) | 4.4 | ✅ | ✅ | ✅ 10/10 files |
| Alpine 3.18 | 5.2 | ✅ | ✅ | ✅ 10/10 files |
| Bash 3.2 (compiled, macOS-equivalent) | 3.2 | ✅ | ✅ | ✅ 10/10 files |

**Usage:**
```bash
bash thunderstorm-collector.sh --server thunderstorm.local
bash thunderstorm-collector.sh --server 10.0.0.5 --ssl --dir /home --dir /tmp --max-age 7
bash thunderstorm-collector.sh --help
```

---

### POSIX sh / ash Collector — `thunderstorm-collector-ash.sh`

A POSIX-compliant rewrite that runs on any Bourne-compatible shell. Designed for minimal environments where Bash is unavailable.

**Use on:** BusyBox-based firmware, Alpine Docker containers, embedded Linux, network appliances, routers, IoT devices, stripped-down VMs.

| Requirement | Detail |
|---|---|
| Shell | Any POSIX sh (`ash`, `dash`, `busybox sh`, `ksh`) |
| Upload tool | `curl`, `wget`, or `nc` (at least one) |
| Utilities | `find`, `wc`, `od`, `tr`, `sed`, `grep` (standard POSIX) |
| TLS | Via curl/wget flags (`--ssl`) |

**Features:**
- Same CLI interface, retry logic, logging, and syslog support as the Bash collector
- Three upload backends with automatic detection: `curl` → GNU `wget` → `nc` → BusyBox `wget`
- URL-encoding via `od` + POSIX arithmetic (no Bash constructs)

**Limitations:**
- Filenames containing literal newline characters (`\n`) are not supported — the Bash version handles this via `find -print0` + `read -d ''`, which requires Bash. Extremely rare in practice.
- BusyBox `wget --post-file` truncates binary files at the first NUL byte (0x00). The collector detects this and prefers `nc` automatically. If neither `curl` nor `nc` is available, BusyBox `wget` is used with a warning.

**Tested Environments:**

| Environment | Shell | curl | nc | wget | Result |
|---|---|---|---|---|---|
| BusyBox 1.36 | ash | — | ✅ | ⚠️ truncates | ✅ 10/10 files (via nc) |
| Alpine 3.18 | ash | ✅ | ✅ | ✅ | ✅ 10/10 files |
| Fedora 43 | dash | ✅ | ✅ | ✅ | ✅ 10/10 files |
| Debian 9 (Stretch) | dash | ✅ | ✅ | ✅ | ✅ 10/10 files |

**Usage:**
```sh
sh thunderstorm-collector-ash.sh --server thunderstorm.local
sh thunderstorm-collector-ash.sh --server 10.0.0.5 --dir /var --dir /tmp --max-age 7
```

---

### Python 3 Collector — `thunderstorm-collector.py`

Cross-platform collector using only the Python 3 standard library. No external packages required.

**Use on:** Any system with Python 3.4+ — Linux, macOS, Windows, BSD, Solaris. Good default choice when Python is available and you want a single script that works everywhere.

| Requirement | Detail |
|---|---|
| Runtime | Python 3.4+ |
| Dependencies | None (stdlib only: `http.client`, `ssl`, `mimetypes`) |
| TLS | Built-in (`--tls`, `--insecure`) |

**Features:**
- Built-in HTTP/HTTPS client (no curl/wget needed)
- TLS with certificate verification or `--insecure` mode
- Multipart form-data upload, URL-encoded source identifiers
- Configurable skip patterns (regex), directory exclusions, file size/age limits

**Limitations:**
- Python 2 not supported — use `thunderstorm-collector-py2.py` instead
- Skip patterns and directory exclusions are configured in source code, not CLI flags
- No syslog integration

**Tested Environments:**

| Environment | Python | Result |
|---|---|---|
| Fedora 43 | 3.14 | ✅ 10/10 files |
| Alpine 3.18 | 3.11 | ✅ 10/10 files |
| CentOS 7 | 3.6 | ✅ 10/10 files |
| Debian 9 (Stretch) | 3.5 | ✅ 10/10 files (requires .format(), f-strings removed) |

**Usage:**
```bash
python3 thunderstorm-collector.py -s thunderstorm.local -d /home -d /tmp
python3 thunderstorm-collector.py -s thunderstorm.local -p 443 -t -k  # HTTPS, skip cert verify
```

---

### Python 2 Collector — `thunderstorm-collector-py2.py`

Functionally equivalent to the Python 3 collector, using Python 2 standard library modules (`httplib`, `urllib`).

**Use on:** Legacy systems where Python 3 is unavailable — RHEL/CentOS 6–7, Debian 7/8, older Solaris, AIX. Python 2 reached end-of-life in January 2020; prefer the Python 3 version when possible.

| Requirement | Detail |
|---|---|
| Runtime | Python 2.7+ |
| Dependencies | None (stdlib only: `httplib`, `urllib`, `ssl`) |
| TLS | Built-in; full support requires Python 2.7.9+ (SNI, cert verification) |

**Features:**
- Same feature set as the Python 3 collector
- Graceful TLS fallback for Python 2.7.0–2.7.8 (connects without SNI/cert verification)
- Version guard: exits with a clear error if accidentally run under Python 3

**Limitations:**
- TLS on Python 2.7.0–2.7.8: connects but without SNI or certificate verification (limited by the `ssl` module)
- Same configuration limitations as the Python 3 version

**Tested Environments:**

| Environment | Python | TLS | Result |
|---|---|---|---|
| CentOS 7 | 2.7.5 | ⚠️ no SNI (pre-2.7.9) | ✅ |

**Usage:**
```bash
python thunderstorm-collector-py2.py -s thunderstorm.local -d /home
python thunderstorm-collector-py2.py -s thunderstorm.local -p 443 -t -k
```

---

### Perl Collector — `thunderstorm-collector.pl`

**Use on:** Unix/Linux systems where Perl is available but Python and Bash may not be. Common on older Solaris, AIX, HP-UX, and hardened systems that strip other scripting languages.

| Requirement | Detail |
|---|---|
| Runtime | Perl 5.16+ |
| Dependencies | `LWP::UserAgent` (not in Perl core since 5.14) |
| TLS | Via LWP SSL configuration |

**Features:**
- Multipart form-data upload via LWP
- URL-encoded source identifiers
- Recursive directory scanning with configurable age and size limits
- Debug mode

**Limitations:**
- Requires `LWP::UserAgent` (`apt-get install libwww-perl` / `yum install perl-libwww-perl`)
- No retry logic on upload failure
- Configuration (skip patterns, extensions, size/age limits) is in source code, not CLI flags
- No syslog integration

**Tested Environments:**

| Environment | Perl | LWP | Result |
|---|---|---|---|
| Fedora 43 | 5.40 | ✅ | ✅ 10/10 files |
| CentOS 7 | 5.16 | ✅ | ✅ 10/10 files |
| Debian 9 (Stretch) | 5.24 | ✅ | ✅ 10/10 files |
| Alpine 3.18 | 5.36 | ✅ | ✅ 10/10 files |

**Usage:**
```bash
perl thunderstorm-collector.pl -s thunderstorm.internal.net
perl thunderstorm-collector.pl --dir /home --server thunderstorm.internal.net --debug
```

---

### PowerShell 3+ Collector — `thunderstorm-collector.ps1`

**Use on:** Windows 7 SP1+, Windows Server 2008 R2 SP1+ — any system with PowerShell 3.0 or newer. This covers most modern Windows deployments.

| Requirement | Detail |
|---|---|
| Runtime | PowerShell 3.0+ |
| Dependencies | None |
| TLS | Built-in (`-UseSSL` flag, enforces TLS 1.2+) |

**Features:**
- Recursive file scanning with extension, age, and size filtering
- HTTPS support with TLS 1.2/1.3 enforcement (`-UseSSL`)
- Source identifier for audit trail
- Debug output (`-Debugging`)
- Log file output
- Retry with exponential backoff, 503 back-pressure handling with `Retry-After`
- Auto-detection of Microsoft Defender ATP Live Response environment

**Limitations:**
- PowerShell 2.0 is not supported — use `thunderstorm-collector-ps2.ps1` instead
- Uses `Invoke-WebRequest` with `-UseBasicParsing`

**Tested Environments:**

| Environment | PowerShell | .NET | Upload Integrity | Result |
|---|---|---|---|---|
| Windows 11 | 5.1.26100 | 4.x | ✅ MD5 verified (512KB binary w/ NUL bytes) | ✅ |
| Fedora 43 (pwsh) | 7.4.6 | — | ✅ MD5 verified | ✅ |

**Usage:**
```powershell
# Basic scan
powershell.exe -ep bypass .\thunderstorm-collector.ps1 -ThunderstormServer thunderstorm.local

# HTTPS with TLS
powershell.exe -ep bypass .\thunderstorm-collector.ps1 -ThunderstormServer thunderstorm.local -UseSSL

# Scan specific folder, files modified in last 24 hours
powershell.exe -ep bypass .\thunderstorm-collector.ps1 -ThunderstormServer ts.local -Folder C:\ProgramData -MaxAge 1

# Debug mode
powershell.exe -ep bypass .\thunderstorm-collector.ps1 -ThunderstormServer ts.local -Debugging
```

---

### PowerShell 2+ Collector — `thunderstorm-collector-ps2.ps1`

A PowerShell 2.0–compatible variant using `System.Net.HttpWebRequest` instead of `Invoke-WebRequest` (which was introduced in PowerShell 3.0).

**Use on:** Windows 7 (pre-SP1 or without WMF 3.0 update), Windows Server 2008 R2 (pre-SP1), or any environment where PowerShell 2.0 is the only option and cannot be upgraded. Also works on all newer PowerShell versions.

| Requirement | Detail |
|---|---|
| Runtime | PowerShell 2.0+ |
| Dependencies | None |
| TLS | Built-in (`-UseSSL` flag); requires .NET 4.5+ for TLS 1.2 |

**Features:**
- Same scanning and filtering as the PS 3+ version
- Raw byte stream upload via `HttpWebRequest.GetRequestStream()` — no encoding layer, binary-safe
- HTTPS with TLS 1.2+ enforcement via numeric `SecurityProtocol` enum values (works without .NET 4.5 type names)
- Retry with exponential backoff, 503 back-pressure with `Retry-After`
- PS 2–compatible file enumeration (`Where-Object { -not $_.PSIsContainer }` instead of `-File`)

**Limitations:**
- TLS 1.2 requires .NET Framework 4.5 or newer installed on the system. Windows 7 RTM ships with .NET 3.5; if .NET 4.5 is not installed, HTTPS connections will fail
- No auto-detection of MDATP Live Response environment (rare on PS 2 systems)

**Tested Environments:**

| Environment | PowerShell | .NET | Upload Integrity | Result |
|---|---|---|---|---|
| Windows 11 | 5.1.26100 | 4.x | ✅ MD5 verified (512KB binary w/ NUL bytes) | ✅ |
| Fedora 43 (pwsh) | 7.4.6 | — | ✅ MD5 verified | ✅ |

**Usage:**
```powershell
# Basic scan
powershell.exe -ep bypass .\thunderstorm-collector-ps2.ps1 -ThunderstormServer thunderstorm.local

# HTTPS
powershell.exe -ep bypass .\thunderstorm-collector-ps2.ps1 -ThunderstormServer thunderstorm.local -UseSSL
```

---

### Batch Collector — `thunderstorm-collector.bat`

A minimal `cmd.exe` script for very old Windows systems.

**Use on:** Windows XP, Server 2003, Server 2008 — systems where PowerShell is unavailable or restricted. Last resort for legacy environments.

| Requirement | Detail |
|---|---|
| Runtime | cmd.exe (Windows XP+) |
| Upload tool | `curl.exe` (included in Windows 10 1709+; download separately for older) |
| TLS | Not supported |

**Features:**
- Minimal dependencies — runs on virtually any Windows version
- `FORFILES` for age-based file filtering

**Limitations:**
- **Known memory leak** in the `FOR` loop for directory traversal ([details](https://stackoverflow.com/questions/6330519/memory-leak-in-batch-for-loop)). For large scans, prefer a PowerShell or Go collector.
- No TLS, limited error handling, hardcoded configuration
- Requires `curl.exe` to be available in `PATH`

> **Old Windows note:** The last curl version supporting Windows 7 / 2008 R2 and earlier is [v7.46.0](https://bintray.com/vszakats/generic/download_file?file_path=curl-7.46.0-win32-mingw.7z).

**Usage:**
```cmd
thunderstorm-collector.bat
```

---

## Harmonized CLI Flags

All collectors use consistent command-line flags:

| Flag | Bash | Ash | Python | Perl | PS3+ | PS2 | Batch |
|------|------|-----|--------|------|------|-----|-------|
| `-s/--server` | ✅ | ✅ | ✅ | ✅ | `-ThunderstormServer` | ✅ | (config) |
| `-p/--port` | ✅ | ✅ | ✅ | ✅ | `-ThunderstormPort` | ✅ | (config) |
| `-d/--dir` | ✅ | ✅ | ✅ | ✅ | `-Folder` | ✅ | (config) |
| `--max-age` | ✅ | ✅ | ✅ | ✅ | `-MaxAge` | ✅ | ✅ |
| `--max-size-kb` | ✅ | ✅ | ✅ | ✅ | — | — | — |
| `--source` | ✅ | ✅ | `-S/--source` | ✅ | `-Source` | ✅ | — |
| `--ssl` | ✅ | ✅ | `-t/--tls` | ✅ | `-UseSSL` | ✅ | — |
| `-k/--insecure` | ✅ | ✅ | ✅ | ✅ | — | — | — |
| `--sync` | ✅ | ✅ | ✅ | ✅ | — | — | — |
| `--dry-run` | ✅ | ✅ | ✅ | ✅ | — | — | — |
| `--retries` | ✅ | ✅ | ✅ | ✅ | — | — | — |
| `--debug` | ✅ | ✅ | ✅ | ✅ | `-Debugging` | ✅ | — |
| `--log-file` | ✅ | ✅ | — | — | `-LogFile` | ✅ | — |
| `--syslog` | ✅ | ✅ | — | — | — | — | — |
| `--quiet` | ✅ | ✅ | — | — | — | — | — |

**Defaults:** `--max-age 14` (days), `--max-size-kb 2048` (KB), `--retries 3`

## Configuration

All collectors support basic configuration via command-line flags:

| Parameter | Description | Default |
|---|---|---|
| Server | Hostname or IP of the Thunderstorm server | (required) |
| Port | Server port | 8080 |
| Directory | Path(s) to scan | `/` or `C:\` |
| Max age | Only submit files modified within N days | 14 days |
| Max size | Skip files larger than N KB | 2048 KB |
| Source | Identifier string for audit trail | hostname |

Advanced settings (skip patterns, extension filters, directory exclusions) are configured in the script source for most collectors.

## Common Use Cases

### Scheduled collection via cron (Linux)

```bash
# Every 6 hours, scan /home and /tmp for files modified in the last 7 days
0 */6 * * * bash /opt/thunderstorm-collector.sh --server ts.local --dir /home --dir /tmp --max-age 7 --quiet
```

### One-shot incident response triage

```bash
# Scan entire system, everything modified in the last 30 days
bash thunderstorm-collector.sh --server 10.0.0.5 --dir / --max-age 30 --source "IR-case-2024-001"
```

### Windows scheduled task

```powershell
schtasks /create /tn "ThunderstormCollector" /tr "powershell.exe -ep bypass C:\tools\thunderstorm-collector.ps1 -ThunderstormServer ts.local" /sc daily /st 02:00
```

### BusyBox / embedded system

```sh
# On a router or IoT device with only BusyBox
sh /tmp/thunderstorm-collector-ash.sh --server 10.0.0.5 --dir /var --max-age 7
```
