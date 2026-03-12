# Thunderstorm Collector — Test Results

**Date:** 2026-02-22  
**Stub Server:** `thunderstorm-stub` on colossus (port 19888) and rune (port 19888 for Windows VM)  
**Verification:** MD5 hash comparison of uploaded files against known fixture hashes via JSONL audit log

## Test Fixtures

| File | Size | MD5 | Purpose |
|---|---|---|---|
| `malware.exe` | 524,288 B | `6efc58e8b533f9f15d47d6acb8179140` | Binary with NUL bytes (integrity check) |
| `readme.txt` | 29 B | `d0fe2d47fb44c5fa7b29a0c56d0a9176` | Plain text |
| `my document.doc` | 12 B | `7a4c0e37af25f5ec76ddd4fb3751d0a0` | Filename with spaces |
| `file&name(1).tmp` | 14 B | `daaa8634f50dbf3d4fb9ea5e0808cc06` | Special characters in filename |
| `nested/deep/hidden.bat` | 15 B | `f626fbfcfbf5785c1ec8edc9ba8d5ba4` | Recursive traversal |
| `big.bin` | 3,145,728 B | `b2c53022dc34e2d64cdd038df8e302ff` | Large file (size filter test) |
| `ancient.exe` | 12 B | `c9a9459e4266ea35a612b90dc3653112` | 90 days old (age filter test) |

## Results

| # | Collector | System | Files | Binary MD5 | Spaces | Special | Nested | Age Filter | Source |
|---|---|---|---|---|---|---|---|---|---|
| 1 | SH Bash | Fedora 43 (Bash 5.3) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 2 | SH Bash | Debian 9 (Bash 4.4) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 3 | SH Bash | CentOS 7 (Bash 4.2) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 4 | SH Bash | Bash 3.2 (compiled) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 5 | ASH POSIX | Fedora 43 (dash 0.5.12) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 6 | ASH POSIX | Debian 9 (dash) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 7 | ASH POSIX | Alpine 3.18 (ash) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 8 | ASH POSIX | BusyBox 1.36 (ash+nc) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 9 | PY3 Python 3 | Fedora 43 (3.14) | 6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 10 | PY3 Python 3 | Debian 9 (3.5) | 6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 11 | PY3 Python 3 | CentOS 7 (3.6) | 6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 12 | PY2 Python 2 | CentOS 7 (2.7.5) | 6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 13 | PL Perl | Fedora 43 (5.42) | 6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 14 | PL Perl | Debian 9 (5.24) | 6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 15 | PL Perl | CentOS 7 (5.16) | 6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 16 | PS3 PowerShell 3+ | Fedora 43 (pwsh 7.4) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 17 | PS3 PowerShell 3+ | Windows 11 (PS 5.1) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 18 | PS2 PowerShell 2+ | Fedora 43 (pwsh 7.4) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 19 | PS2 PowerShell 2+ | Windows 11 (PS 5.1) | 5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 20 | BAT Batch | Windows 11 (cmd.exe) | 3 | ✅ | ❌¹ | ✅ | ❌² | ✅ | ✅ |
| 21 | GO binary | Fedora 43 | 7 | ✅ | ✅ | ✅ | ✅ | ⚠️³ | ✅ |
| 22 | GO binary | Debian 9 | 7 | ✅ | ✅ | ✅ | ✅ | ⚠️³ | ✅ |
| 23 | GO binary | CentOS 7 | 7 | ✅ | ✅ | ✅ | ✅ | ⚠️³ | ✅ |
| 24 | GO binary | Alpine 3.18 | 7 | ✅ | ✅ | ✅ | ✅ | ⚠️³ | ✅ |
| 25 | GO binary | BusyBox 1.36 | 7 | ✅ | ✅ | ✅ | ✅ | ⚠️³ | ✅ |
| 26 | GO binary | Bash 3.2 (Debian 9) | 7 | ✅ | ✅ | ✅ | ✅ | ⚠️³ | ✅ |

### Notes

¹ **BAT — Spaces in filenames:** The `FOR` loop in `cmd.exe` does not correctly handle filenames containing spaces. Known `cmd.exe` limitation.

² **BAT — No recursive traversal:** The batch collector only scans the immediate directories listed in `COLLECT_DIRS`, not subdirectories recursively. `hidden.bat` in `nested/deep/` was not discovered.

³ **GO — Age filter:** The Go collector's `-a 30d` flag did not filter `ancient.exe` (90 days old). The age flag syntax/behavior may differ from expected. This is pre-existing Go collector behavior, not related to our script changes. To be investigated separately.

## File Count Explanation

Different collectors submit different numbers of files due to their built-in defaults:

| Collector | Files | Filtered | Reason |
|---|---|---|---|
| Bash | 5 | `big.bin` (>2MB default), `ancient.exe` (>30d) | `--max-size-kb 2000` default |
| Ash | 5 | `big.bin` (>2MB default), `ancient.exe` (>30d) | Same as Bash |
| Python 3/2 | 6 | `ancient.exe` (>14d hardcoded) | `max_size = 20` MB allows `big.bin` |
| Perl | 6 | `ancient.exe` (>3d hardcoded) | `max_size = 10` MB allows `big.bin` |
| PS 3+/2+ | 5 | `big.bin` (>20MB? No — it's 3MB), `ancient.exe` (>30d) | MaxSize=20 MB; big.bin is 3 MB — actually filtered by extension (no `.bin` in default list) |
| Batch | 3 | Spaces, nested, big.bin (>3MB), ancient.exe (>30d) | Spaces + no recursion = known limitations |
| Go | 7 | None | Age filter didn't trigger; `.bin` in config |

## Summary

- **26 tests executed** across 9 collectors and 7 test environments
- **Binary integrity verified** in all 26 tests (512KB file with NUL bytes, MD5 match)
- **Zero encoding corruption** — no UTF-8 re-encoding observed in any collector
- **All script collectors pass all applicable checks** (tests 1–19)
- **Batch collector** has known `cmd.exe` limitations (spaces, no recursion) — pre-existing, documented
- **Go collector** age filter behavior to be investigated separately — not related to script changes
- **Static Go binary** required for old glibc systems (Debian 9, CentOS 7); Alpine needs static build too (musl vs glibc)

## Test Environment Details

| System | OS | Arch | Bash | Python | Perl | PowerShell | curl | wget |
|---|---|---|---|---|---|---|---|---|
| colossus | Fedora 43 | x86_64 | 5.3 | 3.14 | 5.42 | pwsh 7.4 | 8.15 | wget2 2.2 |
| thor-win11 | Windows 11 | x86_64 | — | — | — | 5.1 | 8.16 | — |
| debian9 | Debian 9 (container) | x86_64 | 4.4 | 3.5 | 5.24 | — | 7.52 | 1.18 |
| centos7 | CentOS 7 (container) | x86_64 | 4.2 | 3.6 / 2.7.5 | 5.16 | — | 7.29 | 1.14 |
| alpine | Alpine 3.18 (container) | x86_64 | — | — | — | — | — | BB wget |
| busybox | BusyBox 1.36 (container) | x86_64 | — | — | — | — | — | BB wget |
| bash3 | Debian 9 + Bash 3.2 (container) | x86_64 | 3.2 | — | — | — | 7.52 | 1.18 |
