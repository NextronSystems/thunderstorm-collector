# Script Collector Acceptance: 8 October 2026

## Decision Summary

The reviewed revisions below passed the available automated checks and the
real-service matrix described here. This is **agent-run verification, not human
approval or certification of every advertised legacy platform**. No PR was
merged. No Go source/dependencies or license files were changed.

The second pass found and fixed one additional issue: near-1 MiB marker JSON
could occupy older awk parsers for more than 15 seconds. Bash and ash now parse
at most 64 KiB of marker JSON. Larger otherwise acceptable responses produce a
warning and no collection ID; file uploads continue. The transport response
limit remains 1 MiB. Boundary regressions cover 64 KiB, 64 KiB + 1, and 1 MiB.

The remaining acceptance work is primarily native deployment testing, especially
Windows Batch against real THOR, actual PowerShell 2/older .NET, and older Perl
module combinations. Backend source/filename attribution also needs inspection.

## Exact Revisions

| PR | Branch | Tested revision | Role |
|---|---|---|---|
| [#43](https://github.com/NextronSystems/thunderstorm-collector/pull/43) | `codex/script-test-base` | `f17b4e1d50de999c10b2c31a0a73615ab54411ba` | Shared harness |
| [#49](https://github.com/NextronSystems/thunderstorm-collector/pull/49) | `codex/script-layout-docs` | `c2b2e06dc596a97e3ce519e9e719dd25018a4b68` | Layout, documentation, release packaging |
| [#44](https://github.com/NextronSystems/thunderstorm-collector/pull/44) | `codex/script-bash` | `d645a00fbab60e44007615a7655282388d435b54` | Bash |
| [#45](https://github.com/NextronSystems/thunderstorm-collector/pull/45) | `codex/script-ash` | `22f9b69c87ca1ccc38f35b5b0c160b992bbf523c` | POSIX sh / ash |
| [#46](https://github.com/NextronSystems/thunderstorm-collector/pull/46) | `codex/script-python` | `95be9b4e7d20c725224014692829cb699f321aba` | Python 3 and 2 |
| [#47](https://github.com/NextronSystems/thunderstorm-collector/pull/47) | `codex/script-perl` | `1823cf45ae4c82a597bc1670b82ac9fa82c7c2d5` | Perl |
| [#48](https://github.com/NextronSystems/thunderstorm-collector/pull/48) | `codex/script-windows` | `f7e1e0b6692d43aca009bdd58d789cfac6380b40` | PowerShell and Batch |

The local combined rehearsal commit was
`00602e4dbeec0c225c07f41074b256d8fcee56c0`. It combined the independent PRs without
conflicts; it is not a replacement PR or a merge into master. Documentation PR
[#52](https://github.com/NextronSystems/thunderstorm-collector/pull/52) carries
this report and the construction guide, not the collector implementations.

Results apply to these revisions and the file hashes below. A later source
change requires renewed verification. Green checks on a documentation or
harness branch do not establish that every replacement collector ran there.

## Real THOR Results

The final run used native **THOR 10.7.30**, separately in HTTP and HTTPS modes,
bound only to loopback on macOS 27.0.1 arm64. Only generated fixtures were sent.
The license stayed outside the repository. Test CAs were not installed in the
system trust store. Owned services were stopped and ephemeral TLS private keys
removed afterward. Raw licensed-service logs are not included in this report.

Every row executed the **renamed standalone release asset**, from a fixture
working directory rather than the repository. Legacy Python ran in containers,
as a non-root user, against the same native THOR service.

| Collector asset / actual runtime | HTTP | HTTPS | Result |
|---|---:|---:|---|
| Bash / macOS Bash 3.2.57 | 16/16 | 5/5 | PASS |
| Bash / Homebrew Bash 5.2.37 | 16/16 | 5/5 | PASS |
| POSIX sh / macOS `/bin/dash` | 19/19 | 5/5 | PASS; not a real-THOR BusyBox run |
| Python 3 / Python 3.9.6 | 15/15 | 4/4 | PASS |
| Python 2 / actual Python 2.7.18 | 15/15 | 4/4 | PASS |
| Python 3 / actual Python 3.4.10 | 15/15 | 4/4 | PASS |
| Perl / Perl 5.34.1 | 15/15 | 4/4 | PASS |
| PowerShell 3+ file / PowerShell 7.5.0 on macOS | 15/15 | 4/4 | PASS; not native Windows |
| PowerShell 2 file / PowerShell 7.5.0 on macOS | 15/15 | 4/4 | PASS; **not actual PowerShell 2** |
| Batch / native Windows with real THOR | NOT RUN | NOT RUN | Human acceptance required |

Total: **180 cases passed, zero failures** on the final assets. Perl used LWP
6.44, Net::HTTP 6.19 and IO::Socket::SSL 2.068. Shell transport coverage included
macOS curl 8.7.1 and GNU wget 1.25.0; ash additionally exercised netcat over HTTP.

### Cases and Independent Evidence

- Positive asynchronous and synchronous uploads included binary bytes, empty
  files, nested paths, spaces, semicolons, commas and quotes. Each upload case
  compared the multiset of SHA-256 hashes and counts of stored samples against
  the fixtures, and checked the native scan-counter delta.
- Every asynchronous uploaded sample was independently polled through
  `/api/getAsyncResults?id=...` until `Sample analysis complete`; the queue had
  to drain. The collector's own success message was not the evidence of receipt.
- Dry-run, dry-run with an unreachable endpoint, an unreachable live endpoint,
  mixed valid/missing roots, all-missing roots, empty roots, and unreadable files
  and subdirectories were checked against profile-specific exit codes/counts.
  Permission cases ran non-root. Dry-run request absence is additionally covered
  by stub regressions; native scan counters alone do not prove no HTTP request.
- Exact size boundaries and one-byte-over-limit files were checked. The test
  used each profile's actual units: KiB for Unix/Python/Perl and MiB for
  PowerShell. Age filtering and `MaxAge=0`/`--max-age 0` were exercised separately.
- Symlinks were excluded. Shell runs additionally checked exclusion of the
  active log and private workspace. GNU wget fallback was exercised with curl
  absent; ash also tested netcat success/failure and safe refusal of newline
  filenames. Shell invocations covered BSD and GNU tool search paths.
- HTTPS rejected an untrusted issuing CA by default and an unrelated valid CA,
  without uploads. The correct CA succeeded. Explicit insecure mode was tested
  separately and is not a recommendation. Shell GNU wget custom-CA runs passed.

### What These Results Do Not Establish

This THOR version returns HTTP 404 for `/api/collection`. Uploads continued
correctly, but native collection IDs, end statistics and interruption markers
were **not supported/verified against real THOR**. The stub covers those cases.

Benign analysis results had no observable source/original-filename attribution
fields. Payload integrity and completed analysis passed; attribution remains
**NOT TESTED** until confirmed in backend logs, UI or another suitable record.
No positive-detection, production-load, quota or hostile live-filesystem race
certification is claimed. Deliberate malformed HTTP, retries and response limits
were tested against synthetic servers, not by disrupting real THOR.

## Regression and Review Evidence

| Check on the reviewed sources | Result |
|---|---|
| Combined focused regression discovery on macOS | 182 tests: 151 passed, 31 skipped |
| Bash focused suite | 31/31 passed |
| ash focused suite on macOS dash | 41/41 passed |
| Shared stub e2e, explicitly requiring all six selected profiles | 68/68 passed, zero skipped |
| Harness safeguards | 20/20 passed |
| Release asset selection fixtures | 4/4 passed |
| Bash/ash ShellCheck at warning severity | Passed |
| Additional one-off adversarial probes | 880/880 passed |
| Changed parser on actual BusyBox 1.37.0 ash **and awk** | 6/6 passed, non-root |

The 880 probes comprised 834 shell JSON cases across Bash 3.2, Bash 5 and dash,
six additional Perl chunk-framing cases, and 40 curl/GNU wget response-limit
cases across Bash/ash. They covered escaped/raw Unicode, nested lookalikes,
duplicate keys, invalid encodings, truncation, trailing garbage, excessive
depth/ID length, large valid marker strings, bad chunk lengths/separators and
trailers, and chunked/close-delimited oversized responses without Content-Length.
These were one-off review probes, not 880 newly committed CI tests. The new
64 KiB boundary regressions are committed in the respective collector PRs.

The macOS skips were all 29 Batch tests requiring Windows, one Windows-only
PowerShell locked-file test, and one Perl invalid-byte-filename case unsupported
by the local filesystem. The combined discovery uses the modern PowerShell file;
the PS2 file was also executed separately in real-service acceptance and CI.

### CI and Platform Qualifications

- [Bash current-head checks](https://github.com/NextronSystems/thunderstorm-collector/actions/runs/37757902090)
  passed after the new parser fix.
- [ash current-head Linux job](https://github.com/NextronSystems/thunderstorm-collector/actions/runs/37758037039/job/113247352468)
  ran 41/41 regressions under dash and 41/41 under BusyBox ash. This uses Ubuntu
  utilities; it is not a wholly BusyBox userspace.
- [Windows collector job](https://github.com/NextronSystems/thunderstorm-collector/actions/runs/37744865981/job/113203843039)
  ran each PowerShell file under Windows PowerShell 5.1: 25 passed, two skipped
  per file. Batch ran with actual cmd/WSH/curl: 21 passed, eight skipped. Skips
  cover POSIX permission/symlink cases and, for Batch, deliberately absent
  markers plus a PowerShell-only drift check. Native locked-file tests ran.
- A full local Alpine rerun could not install curl/wget/OpenSSL because package
  index HTTPS retrieval failed, including one bounded retry. TLS verification
  was not disabled. The cached image did run the six parser checks above using
  actual BusyBox ash/awk; full BusyBox-shell coverage also passed in Ubuntu CI.

All collector PR current-head GitHub checks were successful when checked for
this report. This is a dated observation, not a guarantee for subsequent pushes.

## Release Rehearsal

The actual `release-scripts` target was run on the combined tracked Makefile and
script tree with `VERSION=v2026.10.08-acceptance`. It produced **eight separate
versioned assets**, not a ZIP. Every asset was byte-identical to its reviewed
source. No license, README, helper, test file or bytecode appeared in the release
directory. The Go build targets and GitHub release publication were not run.

Seven distinct assets executed successfully in the real-service matrix above.
The Batch asset was packaged and hash-verified but **not executed as a packaged
asset on Windows**. Windows CI validates its byte-identical source, which is
useful supporting evidence but not a substitute for that final deployment test.

| Asset stem and extension (version inserted before extension) | SHA-256 |
|---|---|
| `thunderstorm-collector.sh` | `06499f38abd288ea8259ac0997b38e87e5d662a2eb3b58c5a0458fcc6cbe94dd` |
| `thunderstorm-collector-ash.sh` | `c10ef272aa43b29e50839441f14710c54ba1e3b3214d1413b4ca51c5d9a4e412` |
| `thunderstorm-collector.py` | `d5ec76564bc42ea3be85a051dc22d49011f0f0b378ad6d5f0004e813d8f10305` |
| `thunderstorm-collector-py2.py` | `beca5cb54738723baf5bf9940a88704545bc5693ff4096c077c8ec9a6d6fea63` |
| `thunderstorm-collector.pl` | `13f93e83e1e88dc62d4812fba3cd0e731a0ee1eaa88d8931e849857a5397dc78` |
| `thunderstorm-collector.ps1` | `d2db2ddd9411e595a8fcabf6c5c696f6cad1c3de13ef86cf6fdcb83b93f8c588` |
| `thunderstorm-collector-ps2.ps1` | `427ecaa236cd3ca90836e6285014bcacaec13d9d6155d89dc40666d92fc766a2` |
| `thunderstorm-collector.bat` | `ee54b5be1a5fa19b6fc26a9efa3d032af083a7e706e814a905395fa2572ae557` |

For a later combined checkout, repeat packaging in a new empty directory rather
than reusing a release directory containing stale assets:

```sh
OUT=$(mktemp -d)
git archive HEAD Makefile scripts | tar -x -C "$OUT"
make -C "$OUT" release-scripts VERSION=vmanual-acceptance
find "$OUT/release" -type f -print
```

Run the renamed assets from outside the checkout against approved synthetic
fixtures. Do not run them without explicit fixture directories. Match their
hashes to their source files before interpreting a test result.

## Human Handoff

Check out the PR being accepted, record its current commit, and use its own
README, not a README from another branch. Follow the
[manual review guide](../scripts/MANUAL_TESTING_GUIDE.md) and retain actual exit
codes, received counts/hashes, runtime versions and backend observations.

| PR / instructions | Remaining deployment-specific acceptance |
|---|---|
| #44 / [Bash](../scripts/bash/README.md) | Smoke/error/TLS cases on the intended Unix host and its installed curl or GNU wget; verify source/filename attribution. |
| #45 / [ash](../scripts/ash/README.md) | Real appliance/BusyBox utilities and chosen transport; newline-path refusal, netcat restrictions where used, missing/unreadable roots, TLS if supported. |
| #46 / [Python](../scripts/python/README.md) | Intended OS and SSL build, both versions if deployed. Actual 2.7.18/3.4.10 were tested; Python before 2.7.9 must refuse verified HTTPS. |
| #47 / [Perl](../scripts/perl/README.md) | Oldest deployed Perl/LWP/Net::HTTP/SSL combination. A Perl 5.34 test does not certify the 5.8.1 syntax floor or old TLS libraries. |
| #48 / [PowerShell](../scripts/powershell/README.md) | Both files on intended Windows hosts, real THOR, ACLs/reparse points, TLS trust, and actual PS2/CLR if that profile will be supported. |
| #48 / [Batch](../scripts/batch/README.md) | Execute the packaged BAT with real cmd/WSH/trusted curl 8.4+, real THOR, locked/unreadable files, filters, special paths, unavailable server and HTTPS. |

For every applicable profile, independently confirm backend source/filename
attribution. Mark unsupported markers and unavailable legacy tests explicitly;
do not turn them into passes. Deployment of a profile with an untested required
capability should wait for that check or an explicit support-scope decision.

Merge #43 first, then #49. Retarget the independent collector PRs #44 through
#48 to master after their prerequisites land, and require green checks on the
updated bases. Each collector can then be approved and merged independently;
they do not have to merge on the same day. Merge #52 after reconciling its
capability descriptions with the versions actually accepted. No merge is
authorized or performed by this report.
