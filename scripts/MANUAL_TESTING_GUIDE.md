# Manual Acceptance Guide for Script Collectors

Use this guide to accept a script collector revision on its target system
before you deploy it. It covers the shared steps: preparation, pass criteria,
what to record, test data and the test sequence. Each collector's README has
the exact commands and expected counts.

> [!NOTE]
> Run acceptance against a real THOR Thunderstorm service whenever one is
> available. The stub server checks the upload protocol only.

- Automated suites and CI: [testing overview](../docs/COLLECTOR_TESTING_OVERVIEW.md)
- Rules for new collectors: [collector construction guide](../docs/COLLECTOR_CONSTRUCTION_GUIDE.md)
- Earlier results: [8 October 2026 acceptance report](../docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)

## Manual Test Preparation

1. **Pick the revision.** Test the exact collector file you will deploy, on the
   target operating system and runtime.
2. **Note the service.** Write down the Thunderstorm host, port and scheme
   (HTTP or HTTPS). Replace the example server in README commands with it.
3. **Agree on the feature scope.** Use the collector's README to list which
   features it supports and which limitations are accepted. The
   [acceptance criteria](#acceptance-criteria) are not a uniform contract for
   every collector.
4. **Choose a source identifier** per collector and test, so runs do not mix in
   Thunderstorm:

   ```text
   manual-<collector>-<test-type>-<tester>-<date>
   ```

   For example `manual-bash-acceptance-alice-2026-05-30` or
   `manual-powershell-locked-file-alice-2026-05-30`.
5. **Create small test data** as described in [Manual Test Data](#manual-test-data).
   Never point a collector at broad production directories during acceptance.

### Result statuses

| Status | Meaning |
|---|---|
| PASS | Supported feature verified on the recorded runtime. |
| FAIL | Supported feature does not behave as specified; fix it before deployment. |
| NOT SUPPORTED | An intentional, reviewed limitation documented in the collector README. |
| NOT TESTED | Missing runtime, service access or evidence. This is not a pass. |

### Runtimes to record separately

- **Python 2** separately from Python 3.
- **PowerShell 2** separately from PowerShell 3+. A PowerShell 2 script that
  runs under Windows PowerShell 5.1 or PowerShell 7 does not prove PowerShell 2
  compatibility.
- **BusyBox ash** separately from dash. Dash does not replace acceptance on the
  intended BusyBox/ash system.

CI runs the Python regressions in pinned Python 2.7 and Python 3.4 containers.
That does not replace a test with the target's own OS and SSL build.

### Test harness prerequisites

The mock-server harness in `tests/` needs Bash 4.3 or newer and GNU-compatible
file utilities. These are requirements of the test host, not of the collectors.
On macOS, put a newer Bash and the GNU utilities first on `PATH`; the system
Bash is too old.

## Acceptance Criteria

Record PASS, FAIL, NOT SUPPORTED or NOT TESTED for each point:

- The collector runs on the intended runtime and operating system.
- It uploads at least one text file and, where supported, one binary file.
- Recursive traversal works where the collector claims it.
- The configured source identifier appears in Thunderstorm.
- Dry-run mode, if supported, does not contact the server.
- An unreachable service fails visibly and does not hang.
- Missing, unreadable or locked files do not crash the whole run.
- Size, age and extension filters work where the collector claims them.
- The [automated stub test](#automated-stub-tests) passes for the collector, or
  an intentional environment skip is recorded.
- The README's limitations match what you observed.

A revision passes acceptance when all supported points pass and the tests show
no silent data loss, no hang and no misleading success report. Add any
limitation you found to the README.

## Acceptance Record

Keep one record per collector. Do not mix results from different collectors
under one source identifier.

```text
Collector and file:
Revision or release asset (commit or hash):
Tester:
Test date:
Target OS:
Runtime version:
Thunderstorm server:
Thunderstorm port:
URL scheme:
Real service or stub:
Source identifier:
Files expected / files seen (Thunderstorm or stub uploads directory):
Checks passed:
Limitations, warnings, timeouts, unexpected exit codes:
```

Leave credentials and secrets out of the record.

For every run, keep the terminal output. If a command fails, keep the exit code
and the last error lines. Capture the exit code right after the command:

| Shell | Command |
|---|---|
| Unix shell | `echo "exit_code=$?"` |
| PowerShell | `$LASTEXITCODE` |
| `cmd.exe` | `echo %ERRORLEVEL%` |

Record versions with these commands:

```bash
git rev-parse --short HEAD
bash --version
python3 --version
python --version
perl -v
pwsh -v
```

```powershell
$PSVersionTable
cmd /c ver
```

For BusyBox, record the BusyBox version.

## Manual Test Data

Use small, harmless files. The goal is to check collector behavior, not to
upload a live system.

### Unix test data

For Bash, ash, Python and Perl:

```bash
COLLECTOR="bash"
TEST_ROOT="/tmp/ts-${COLLECTOR}-manual"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/input/nested" "$TEST_ROOT/errors/readable" "$TEST_ROOT/errors/unreadable" "$TEST_ROOT/filter"

printf 'manual acceptance text\n' > "$TEST_ROOT/input/sample.txt"
printf '\000\001\002THUNDERSTORM\000\377\n' > "$TEST_ROOT/input/sample.bin"
printf 'nested file\n' > "$TEST_ROOT/input/nested/nested.txt"
printf 'old file\n' > "$TEST_ROOT/filter/old.txt"
printf 'small file\n' > "$TEST_ROOT/filter/small.txt"
dd if=/dev/zero of="$TEST_ROOT/filter/large.bin" bs=1024 count=32 2>/dev/null
printf 'readable\n' > "$TEST_ROOT/errors/readable/ok.txt"
printf 'blocked\n' > "$TEST_ROOT/errors/unreadable/blocked.txt"
touch -t 200001010000 "$TEST_ROOT/filter/old.txt"
chmod 000 "$TEST_ROOT/errors/unreadable"
```

Set `COLLECTOR` to `bash`, `ash`, `python` or `perl`. After the
unreadable-path test, restore the permissions:

```bash
chmod 755 "$TEST_ROOT/errors/unreadable"
```

Run unreadable-path tests as a normal user. `root` can still read most files,
so a root run does not test this case; record it as NOT TESTED rather than as
a collector failure.

### Windows test data

For PowerShell and Batch:

```powershell
$Collector = "powershell"
$TestRoot = Join-Path $env:TEMP "ts-$Collector-manual"
Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$TestRoot\input\nested" | Out-Null
New-Item -ItemType Directory -Path "$TestRoot\filter" | Out-Null
New-Item -ItemType Directory -Path "$TestRoot\errors" | Out-Null

Set-Content -Path "$TestRoot\input\sample.txt" -Value "manual acceptance text"
[IO.File]::WriteAllBytes("$TestRoot\input\sample.bin", [byte[]](0,1,2,84,72,85,78,68,69,82))
Set-Content -Path "$TestRoot\input\nested\nested.txt" -Value "nested file"
Set-Content -Path "$TestRoot\filter\include.exe" -Value "include"
Set-Content -Path "$TestRoot\filter\skip.tmp" -Value "skip"
Set-Content -Path "$TestRoot\filter\small.txt" -Value "small"
fsutil file createnew "$TestRoot\filter\large.txt" 32768
Set-Content -Path "$TestRoot\errors\ok.txt" -Value "readable"
Set-Content -Path "$TestRoot\errors\locked.txt" -Value "locked"
```

If `fsutil` needs elevation or is missing, create the large file with
PowerShell instead:

```powershell
[IO.File]::WriteAllBytes("$TestRoot\filter\large.txt", (New-Object byte[] 32768))
```

## Manual Test Sequence

Run each test unless the collector's README documents the feature as
unsupported. Use the README's commands with the test data above. After each run,
check in Thunderstorm which files arrived and under which source identifier.

| # | Test | Run with | Pass | Fail |
|---|---|---|---|---|
| 1 | Help and runtime | Help or an invalid option | Readable output; missing dependencies named (for example `curl`, Perl `LWP::UserAgent`, a blocked execution policy); no upload | Crash, unclear error, or an upload |
| 2 | Basic upload | The `input` directory | `sample.txt`, `sample.bin` (where binary upload is supported) and `nested.txt` (for recursive collectors) arrive under the exact source identifier | Success exit without uploads; wrong or missing source; truncated binary; missing nested file |
| 3 | Dry run | Server `127.0.0.1`, port `1` | Exit 0; output lists the files it would submit; no upload | An upload; a failure caused by the unreachable port; empty or misleading output |
| 4 | Unreachable service | Server `127.0.0.1`, port `1`, the `input` directory | Non-zero exit or clearly reported failures; the error names the connection, upload, begin marker or server; returns in reasonable time; no upload | Hangs; exits 0 although all uploads failed; hides the network error |
| 5 | Missing and unreadable paths | One readable directory, one unreadable directory or locked file, one missing directory | The readable file arrives; bad paths are reported; no unhandled exception; the final status does not claim full success | The readable file is missing; crash without a useful message; silent success |
| 6 | Filters | The `filter` directory | Small files arrive when they match; oversized files skipped with a size limit; old files skipped with an age limit; only requested extensions with an extension filter | Filtered files arrive; expected files missing; skipped files unexplained where the collector claims to report them |
| 7 | README accuracy | Compare the README with the results | Requirements, capabilities and limitations match | A claimed feature failed; a dependency or limitation is missing |

For test 4, collectors that send [collection markers](../docs/COLLECTION_MARKERS.md)
exit 2 when the begin marker gets no HTTP answer. Collectors or transports
without markers report failed uploads instead. Each README states the exact
exit code.

## Collector-Specific Checks

Run these in addition to the [test sequence](#manual-test-sequence). The README
of each collector has the detailed cases.

| Collector | Checks |
|---|---|
| [Bash](bash/README.md) | Run the size filter on `filter`: `small.txt` arrives, `large.bin` is skipped. Record whether warnings, failure counters and exit codes match the README. |
| [POSIX sh / ash](ash/README.md) | See the list below the table. |
| [Python](python/README.md) | Repeat the basic upload and dry run with the Python 2 collector on a real Python 2.7 runtime if Python 2 is in scope. For HTTPS, test `--tls`; test `--insecure` only if disabling verification is acceptable in that environment, and record it. Record Python 2 TLS or Unicode/path limitations as runtime limitations. |
| [Perl](perl/README.md) | Check the dependency first with `perl -MLWP::UserAgent -e 1`. If the target needs HTTPS, test that host's own Perl SSL stack against the real service. |
| [PowerShell](powershell/README.md) | Repeat the basic upload with the PowerShell 2 collector on a real PowerShell 2 host if it is in scope. Locked file: `ok.txt` arrives, `locked.txt` is skipped or reported failed. Extension filter: `include.exe` arrives, `skip.tmp` does not. Record the execution policy used, for example `-ExecutionPolicy Bypass`. |
| [Batch](batch/README.md) | Run from `cmd.exe`; use PowerShell only to create the test files. Confirm that Windows Script Host and ADODB.Stream are enabled and that the collector uses a trusted `curl.exe` 8.4 or later. Extension filter: `include.txt` arrives, `skip.tmp` does not. Size filter: `small.txt` arrives, `large.txt` is skipped. Batch sends no collection markers. Weak error reporting is acceptable only if an operator can still see the failure. |

POSIX sh / ash has the most transport-dependent behavior. Follow the README's
isolated fixture, exact upload counts and exit codes, and check:

- **Shell:** run every command with the target's shell (`sh`, `ash`, `dash` or
  `busybox sh`).
- **Transport:** record curl, GNU wget, or nc with `timeout`. BusyBox or
  unknown wget alone must be refused before any upload. nc supports plain HTTP
  only, sends no collection markers and needs strictly length-framed responses.
- **Binary integrity:** for every supported transport, compare received size
  or hash of text, binary, empty, nested and special-name files. Record a
  transport you could not test as NOT TESTED.
- **Unreachable service:** exit 2 with curl or GNU wget, exit 1 with nc, no
  uploads. Warnings alone are not a pass.
- **Missing or unreadable paths:** exit 1 while readable files are still
  processed. Test permissions as a non-root user.
- **Also test:** newline-path rejection, temporary/log/symlink exclusions, age
  and size boundaries, and TLS where supported.

## Automated Stub Tests

The shared suite starts the
[stub server](https://github.com/Nextron-Labs/thunderstorm-stub-server) itself.
Build the stub in a sibling checkout, then run one selector per collector:

```bash
THUNDERSTORM_TEST_COLLECTORS=bash THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

| Collector | Selector | Note |
|---|---|---|
| Bash | `bash` | |
| POSIX sh / ash | `ash` | Also set `THUNDERSTORM_TEST_REQUIRE_ALL=1` |
| Python 3 | `python3` | |
| Python 2 | `python2` | Fails without a Python 2 runtime; skip only if Python 2 is intentionally missing on the test host, and record that |
| Perl | `perl` | |
| PowerShell 3+ | `ps3` | Needs PowerShell Core on a Unix-like host |
| Batch | none | Use the GitHub Actions Windows job |

The GitHub Actions Windows job is the main automated check for the Windows
collectors. The [testing overview](../docs/COLLECTOR_TESTING_OVERVIEW.md) has
the full commands and explains which stub revision to use.

### Manual runs against the stub

Use this only when the real service is unavailable. Start the stub in a
separate terminal:

```bash
cd /path/to/thunderstorm-stub-server
go build -o thunderstorm-stub-server .
rm -rf /tmp/thunderstorm-stub-uploads
mkdir -p /tmp/thunderstorm-stub-uploads
./thunderstorm-stub-server \
  --port 8080 \
  --uploads-dir /tmp/thunderstorm-stub-uploads \
  --log-file /tmp/thunderstorm-stub-audit.jsonl
```

Point the collector at server `127.0.0.1`, port `8080`. Inspect what arrived:

```bash
ls -la /tmp/thunderstorm-stub-uploads
tail -n 20 /tmp/thunderstorm-stub-audit.jsonl
```

The stub checks the HTTP upload contract and stores samples. It does not check
real scanning, authentication, deployment networking or how the real service
behaves in operation.
