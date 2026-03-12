# Thunderstorm Collector — Comprehensive Test Plan

## Test Systems

| ID | System | OS / Version | Architecture | Access Method |
|---|---|---|---|---|
| **C1** | colossus | Fedora 43 (Linux 6.18) | x86_64 | local |
| **W1** | thor-win11 | Windows 11 (26100) | x86_64 | SSH via rune (ProxyJump) |
| **D1** | debian9 container | Debian 9 (Stretch) | x86_64 | podman |
| **D2** | centos7 container | CentOS 7 | x86_64 | podman |
| **D3** | alpine container | Alpine 3.18 | x86_64 | podman |
| **D4** | busybox container | BusyBox 1.36 | x86_64 | podman |
| **D5** | bash3 container | Debian 9 + Bash 3.2 | x86_64 | podman |

### Runtime Versions per System

| System | Bash | dash/ash | Python 3 | Python 2 | Perl | PowerShell | curl | wget | nc |
|---|---|---|---|---|---|---|---|---|---|
| **C1** Fedora 43 | 5.3 | 0.5.12 | 3.14 | — | 5.42 | 7.4 (pwsh) | 8.15 | 2.2 (wget2) | ncat 7.92 |
| **W1** Windows 11 | — | — | — | — | — | 5.1 | 8.16 | — | — |
| **D1** Debian 9 | 4.4 | dash | 3.5 | — | 5.24 | — | 7.52 | 1.18 | ✅ |
| **D2** CentOS 7 | 4.2 | — | 3.6 | 2.7.5 | 5.16 | — | 7.29 | 1.14 | — |
| **D3** Alpine 3.18 | — | ash | — | — | — | — | — | BB wget | nc |
| **D4** BusyBox 1.36 | — | ash | — | — | — | — | — | BB wget | nc |
| **D5** Bash 3.2 | 3.2¹ | — | — | — | — | — | 7.52 | 1.18 | — |

¹ bash3-test container uses Debian 9 base with Bash 4.4 available; Bash 3.2 compiled from source.

## Collectors

| ID | Collector | File | Min Runtime |
|---|---|---|---|
| **SH** | Bash | `thunderstorm-collector.sh` | Bash 3.2+ |
| **ASH** | POSIX sh/ash | `thunderstorm-collector-ash.sh` | Any POSIX sh |
| **PY3** | Python 3 | `thunderstorm-collector.py` | Python 3.4+ |
| **PY2** | Python 2 | `thunderstorm-collector-py2.py` | Python 2.7+ |
| **PL** | Perl | `thunderstorm-collector.pl` | Perl 5.16+ / LWP |
| **PS3** | PowerShell 3+ | `thunderstorm-collector.ps1` | PS 3.0+ |
| **PS2** | PowerShell 2+ | `thunderstorm-collector-ps2.ps1` | PS 2.0+ |
| **BAT** | Batch | `thunderstorm-collector.bat` | cmd.exe + curl.exe |
| **GO** | Go binary | `thunderstorm-collector` | none (static binary) |

## Test Matrix

Cells marked `—` indicate the collector cannot run on that system (missing runtime).
Cells marked `( )` are to be filled with ✅ pass, ❌ fail, or ⚠️ partial.

| Collector | C1 Fedora 43 | W1 Windows 11 | D1 Debian 9 | D2 CentOS 7 | D3 Alpine 3.18 | D4 BusyBox 1.36 | D5 Bash 3.2 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **SH** Bash | ( ) | — | ( ) | ( ) | — | — | ( ) |
| **ASH** POSIX sh | ( ) dash | — | ( ) dash | — | ( ) ash | ( ) ash | — |
| **PY3** Python 3 | ( ) | — | ( ) 3.5 | ( ) 3.6 | — | — | — |
| **PY2** Python 2 | — | — | — | ( ) 2.7.5 | — | — | — |
| **PL** Perl | ( ) | — | ( ) | ( ) | — | — | — |
| **PS3** PowerShell 3+ | ( ) pwsh | ( ) PS 5.1 | — | — | — | — | — |
| **PS2** PowerShell 2+ | ( ) pwsh | ( ) PS 5.1 | — | — | — | — | — |
| **BAT** Batch | — | ( ) | — | — | — | — | — |
| **GO** Go binary | ( ) | — | ( ) | ( ) | ( ) | ( ) | ( ) |

**Total test combinations: 28**

## Test Fixtures

Located at `/tmp/collector-tests/` on each system, containing:

| File | Size | Purpose | Expected Behavior |
|---|---|---|---|
| `malware.exe` | 512 KB | Binary with NUL bytes | Submitted; **MD5 must match** (binary integrity) |
| `readme.txt` | ~30 B | Plain text | Submitted (if extension matches) or filtered |
| `my document.doc` | ~12 B | Filename with spaces | Submitted; tests filename handling |
| `file&name(1).tmp` | ~14 B | Special characters in name | Submitted; tests URL encoding |
| `nested/deep/hidden.bat` | ~15 B | Nested directory | Submitted; tests recursive traversal |
| `big.bin` | 3 MB | Large file | **Filtered** by default max-size (most collectors default to 2–20 MB) |
| `ancient.exe` | ~12 B | Old file (90 days) | **Filtered** when max-age is set |

## Test Checks per Run

For each collector × system combination, verify:

1. **Submission count** — correct number of files submitted (respecting filters)
2. **Binary integrity** — `malware.exe` MD5 on server matches source (critical: catches UTF-8 encoding bugs)
3. **Filename handling** — files with spaces and special characters submitted successfully
4. **Recursive traversal** — nested file discovered and submitted
5. **Size filter** — `big.bin` correctly filtered when max-size applies
6. **Age filter** — `ancient.exe` correctly filtered when max-age is set
7. **Extension filter** — correct files selected when extension filter is active
8. **Exit code** — script exits cleanly (exit 0)
9. **Source parameter** — source identifier correctly transmitted and URL-encoded

## Test Procedure

### Setup (once)

1. Start stub server on colossus: `thunderstorm-stub -port 19888 -uploads-dir /tmp/stub-uploads -log-file /tmp/stub-audit.jsonl`
2. Create test fixtures on colossus at `/tmp/collector-tests/`
3. Record MD5 hashes of all fixtures
4. For containers: mount fixtures and scripts as volumes
5. For Windows VM: copy fixtures and scripts via SCP

### Per-Collector Run

1. Clear stub server uploads dir and JSONL log
2. Run collector against stub server with:
   - Extensions filter: `.exe,.txt,.doc,.tmp,.bat,.bin`
   - Max age: 30 days (should filter `ancient.exe`)
   - Source: `<collector>-<system>` (e.g., `bash-fedora43`)
3. Check JSONL log:
   - Count submissions
   - Verify `malware.exe` MD5 hash matches
   - Verify source parameter
   - Verify filenames (spaces, special chars)
4. Check uploads dir:
   - MD5 of uploaded `malware.exe` binary matches original
5. Record result in matrix

### Expected Submission Counts

With extensions `.exe,.txt,.doc,.tmp,.bat,.bin` and max-age 30 days:

| File | Extension | Age | Size | Expected |
|---|---|---|---|---|
| `malware.exe` | ✅ .exe | ✅ new | 512 KB ✅ | **Submitted** |
| `readme.txt` | ✅ .txt | ✅ new | 30 B ✅ | **Submitted** |
| `my document.doc` | ✅ .doc | ✅ new | 12 B ✅ | **Submitted** |
| `file&name(1).tmp` | ✅ .tmp | ✅ new | 14 B ✅ | **Submitted** |
| `nested/deep/hidden.bat` | ✅ .bat | ✅ new | 15 B ✅ | **Submitted** |
| `big.bin` | ✅ .bin | ✅ new | 3 MB | **Depends on max-size default** |
| `ancient.exe` | ✅ .exe | ❌ 90 days | 12 B ✅ | **Filtered (age)** |

Expected: **5–6 files submitted** (depending on max-size config per collector)

## Results Table (to be filled during testing)

| # | Collector | System | Files Sent | Binary MD5 ✅ | Spaces ✅ | Special Chars ✅ | Nested ✅ | Age Filter ✅ | Source ✅ | Exit 0 ✅ | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | SH Bash | C1 Fedora 43 | | | | | | | | | |
| 2 | SH Bash | D1 Debian 9 | | | | | | | | | |
| 3 | SH Bash | D2 CentOS 7 | | | | | | | | | |
| 4 | SH Bash | D5 Bash 3.2 | | | | | | | | | |
| 5 | ASH POSIX | C1 Fedora 43 (dash) | | | | | | | | | |
| 6 | ASH POSIX | D1 Debian 9 (dash) | | | | | | | | | |
| 7 | ASH POSIX | D3 Alpine (ash) | | | | | | | | | |
| 8 | ASH POSIX | D4 BusyBox (ash) | | | | | | | | | |
| 9 | PY3 Python 3 | C1 Fedora 43 | | | | | | | | | |
| 10 | PY3 Python 3 | D1 Debian 9 | | | | | | | | | |
| 11 | PY3 Python 3 | D2 CentOS 7 | | | | | | | | | |
| 12 | PY2 Python 2 | D2 CentOS 7 | | | | | | | | | |
| 13 | PL Perl | C1 Fedora 43 | | | | | | | | | |
| 14 | PL Perl | D1 Debian 9 | | | | | | | | | |
| 15 | PL Perl | D2 CentOS 7 | | | | | | | | | |
| 16 | PS3 PowerShell 3+ | C1 Fedora 43 (pwsh) | | | | | | | | | |
| 17 | PS3 PowerShell 3+ | W1 Windows 11 | | | | | | | | | |
| 18 | PS2 PowerShell 2+ | C1 Fedora 43 (pwsh) | | | | | | | | | |
| 19 | PS2 PowerShell 2+ | W1 Windows 11 | | | | | | | | | |
| 20 | BAT Batch | W1 Windows 11 | | | | | | | | | |
| 21 | GO binary | C1 Fedora 43 | | | | | | | | | |
| 22 | GO binary | D1 Debian 9 | | | | | | | | | |
| 23 | GO binary | D2 CentOS 7 | | | | | | | | | |
| 24 | GO binary | D3 Alpine 3.18 | | | | | | | | | |
| 25 | GO binary | D4 BusyBox 1.36 | | | | | | | | | |
| 26 | GO binary | D5 Bash 3.2 | | | | | | | | | |

**26 total test runs** (2 matrix cells dropped: Alpine/BusyBox have no Bash 3.2 or additional runtimes to add value)
