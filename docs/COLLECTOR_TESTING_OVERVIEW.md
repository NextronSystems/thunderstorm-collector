# Collector Testing Overview

The script collectors in `scripts/` are tested by running the real scripts
against generated files and controlled HTTP services, including failures.
Final acceptance is a human run against a real THOR Thunderstorm service on the
target platform. The Go collector and the older `tests/` harness have
[their own workflows](#other-workflows).

## What to Run for What

Run from the repository root. `$STUB_BIN` is a built stub
([build steps](#shared-stub-integration)).

| Suite | Command | Backend | Covers |
|---|---|---|---|
| Harness safeguards | `python3 -B scripts/tests/test_harness.py` | None | Broken selection, startup, audit/reset or timeouts cannot pass as collector success |
| Release assets | `python3 -B scripts/tests/test_release_assets.py` | None | [Script asset selection and naming](#release-assets) |
| Focused regressions | `python3 -B scripts/tests/test_<collector>_robustness.py` | Fault-injection server in the test | Specific success and failure cases, exit status, requests received |
| Shared e2e | `bash scripts/tests/run_e2e_compliance.sh "$STUB_BIN"` | `thunderstorm-stub-server` | Upload protocol, metadata, counts, file integrity |
| Bash integration | `bash scripts/tests/run_tests.sh "$STUB_BIN"` | Stub | Bash scenarios |
| Perl large file | `STUB_BIN_PATH="$STUB_BIN" bash scripts/tests/test_perl_large.sh` | Own stub | A file just over **3 MiB** |
| [Optional suites](#optional-suites) | `run_detection_tests.sh`, `run_operational_tests.sh`, `run_filter_tests.sh` | Stub with own setup | Extra scenarios; not run in CI |
| [Real-service acceptance](#real-thor-acceptance) | Steps in the collector's guide | Real THOR Thunderstorm | Deployment behavior CI cannot establish |

Only real-service acceptance needs a THOR license.

## Running Tests Locally

- Use the **exact candidate branch**; run only suites whose files exist.
- Use an ordinary **non-root** account: root can read fixtures meant to be
  unreadable.
- Allow loopback listeners, and do not share their ports with another run.

Depending on the suite, the test host needs current Python 3, Bash, the
interpreter under test, curl or GNU wget, Perl modules, OpenSSL for temporary
TLS certificates (no global CA install), netcat and `timeout` for ASH's netcat
cases, Docker for the legacy Python containers, and Go for the stub. Missing
tools cause skips; inspect them.

### Fast harness checks

No Thunderstorm service needed:

```sh
python3 -B scripts/tests/test_harness.py
python3 -B scripts/tests/test_release_assets.py
python3 -B scripts/tests/test_perl_large_harness.py
python3 -B scripts/tests/test_batch_robustness.py BatchAdapterTests
```

### Focused collector tests

Each suite starts its own fault-injection server; do not start a stub. Run what
applies to the host:

```sh
python3 -B scripts/tests/test_bash_robustness.py
COLLECTOR_BASH=/bin/bash python3 -B scripts/tests/test_bash_robustness.py

COLLECTOR_SH=/bin/dash python3 -B scripts/tests/test_ash_robustness.py
COLLECTOR_SH='busybox ash' python3 -B scripts/tests/test_ash_robustness.py

python3 -B scripts/tests/test_python_robustness.py
python2 -B scripts/tests/test_python_robustness.py

python3 -B scripts/tests/test_perl_robustness.py
```

- On macOS, `/bin/bash` can provide the **Bash 3.2** check; record its version.
- The Python suite tests only the collector for its own interpreter. The
  pinned Python 2.7 and 3.4 Docker commands are in the
  [workflow](../.github/workflows/script-collectors.yml).

On Windows, in PowerShell with Python and OpenSSL available:

```powershell
$env:POWERSHELL_RUNTIME = 'powershell.exe'
$env:POWERSHELL_COLLECTOR = Join-Path $PWD 'scripts/powershell/thunderstorm-collector.ps1'
python -B scripts/tests/test_powershell_robustness.py
if ($LASTEXITCODE -ne 0) { throw 'Modern PowerShell tests failed' }

$env:POWERSHELL_COLLECTOR = Join-Path $PWD 'scripts/powershell/thunderstorm-collector-ps2.ps1'
python -B scripts/tests/test_powershell_robustness.py
if ($LASTEXITCODE -ne 0) { throw 'PS2-compatible script tests failed' }

Remove-Item Env:POWERSHELL_COLLECTOR
python -B scripts/tests/test_batch_robustness.py
if ($LASTEXITCODE -ne 0) { throw 'Batch tests failed' }
```

This uses the host's Windows PowerShell, usually 5.1, not a real PS2 runtime.
On Unix, the suite defaults to `pwsh` if installed, which cannot validate
Windows ACLs or native Batch.

### Shared stub integration

To reproduce CI, use the stub revision pinned as `STUB_SERVER_REF` in the
workflow. Check the sibling checkout's revision; do not update or switch
someone else's checkout. Build natively: a Linux binary does not run on macOS.

```sh
STUB_CHECKOUT="$(cd ../thunderstorm-stub-server && pwd)"
git -C "$STUB_CHECKOUT" rev-parse HEAD
STUB_BUILD="$(mktemp -d)"
STUB_BIN="$STUB_BUILD/thunderstorm-stub-server"
(cd "$STUB_CHECKOUT" && go build -o "$STUB_BIN" .)

THUNDERSTORM_TEST_COLLECTORS=bash \
THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
THUNDERSTORM_TEST_REQUIRE_ALL=1 \
  bash scripts/tests/run_e2e_compliance.sh "$STUB_BIN"
```

- **Selectors:** `bash`, `ash`, `python3`, `python2`, `perl`, `ps3`, `ps2`, or
  a comma-separated list. Batch is not a selector; use its Windows tests.
- **Strict flags:** `REQUIRE_MATCH` fails if nothing matches; `REQUIRE_ALL`
  fails unless **every requested** profile runs.
- **Stub:** the suite starts and stops it. For concurrent runs, set a distinct
  unused `STUB_PORT`.

The Bash and Perl stub tests are separate runs:

```sh
bash scripts/tests/run_tests.sh "$STUB_BIN"
STUB_BIN_PATH="$STUB_BIN" bash scripts/tests/test_perl_large.sh
```

The Perl helper starts its own stub on a temporary port, never reusing an old
service or audit log. It checks the collector's exit and waits up to 30
seconds (`STUB_AUDIT_WAIT_SECONDS`) for one current-run audit record with
matching size and hash.

## What Runs in CI

[script-collectors.yml](../.github/workflows/script-collectors.yml) is the
source of truth. It runs on changes to `scripts/`, the `Makefile` or the
workflow, and on manual start, not on docs-only changes. The Linux and Windows
jobs have a **30-minute** limit, the BusyBox job **20 minutes**.

| CI host | Configured execution |
|---|---|
| Ubuntu | Harness checks, release-asset tests, selected collectors against the stub, collector-specific suites. ASH under dash and BusyBox ash; Bash and Perl on the runner's runtimes. |
| Ubuntu, BusyBox job | ASH robustness suite under BusyBox ash with a BusyBox-first `PATH` (`busybox --install -s DIR`): every utility the collector uses is a BusyBox applet; curl and GNU wget still come from Ubuntu. |
| Ubuntu with Docker | Python robustness suite under actual Python 2.7.18 and 3.4.10 in digest-pinned images, as non-root with read-only source mounts. |
| Windows | Both PowerShell files under **Windows PowerShell 5.1**; Batch under native cmd, Windows Script Host and curl; selected collectors upload fixtures to a Windows-built stub. |

How CI picks what to run:

- **Focused suites** run whenever their test file exists.
- **Shared integration** runs the profiles chosen by
  [select_collectors.py](../scripts/tests/select_collectors.py), which also
  checks the expected CLI interface. A collector-specific branch must match
  its own profile; on other branches, automatic selection can find none.
- **Explicit requests** for a missing or incompatible profile fail on that
  job's platform.
- **`python`** means Python 3. Selecting `python2` explicitly needs a
  `python2` executable on the host.

### Optional suites

The script workflow only syntax-checks these:

| Suite | Scenarios | Setup |
|---|---|---|
| [run_detection_tests.sh](../scripts/tests/run_detection_tests.sh) | Detection, path, filtering, failure | YARA-enabled stub and rules |
| [run_operational_tests.sh](../scripts/tests/run_operational_tests.sh) | Markers, interruption, source, `--sync` rejection and `--async` acceptance, multiple roots, retry, progress, fallback | Own stub and rule discovery |
| [run_filter_tests.sh](../scripts/tests/run_filter_tests.sh) | Age, size, extension | A running stub, its audit log, prepared fixtures |

### Other workflows

| Workflow | Role |
|---|---|
| [Collector Tests](../.github/workflows/test-collectors.yml) | `tests/test-collectors.sh all` against the mock/proxy setup, including the Go collector and older script adapters. Cannot establish native Batch execution. Needs Bash 4.3+ and GNU-compatible utilities. |
| [ShellCheck](../.github/workflows/shellcheck.yml) | Shell files under `tests/`, not the collectors under `scripts/`. |
| [Go](../.github/workflows/go.yml) | Go 1.10 and stable. The root `make test` runs the Go tests, **not** the script suites. |

Cases overlap across suites, so do not add up totals. A test file is not
evidence that it ran.

## Test Backends

The three backends are **not interchangeable**:

- **Fault-injection servers** inside the Python regression tests return HTTP
  503, malformed marker JSON, truncated responses, redirects or untrusted TLS
  certificates.
- **[thunderstorm-stub-server](https://github.com/Nextron-Labs/thunderstorm-stub-server)**
  implements the upload endpoints and records audit and storage evidence.
  Detection tests need its YARA-enabled build and matching rules. Neither build
  certifies the real THOR engine.
- **`NextronSystems/thunderstorm-mock`** with an API compatibility proxy serves
  the older `tests/` harness.

## Collector Coverage

Tests follow each collector's capability profile: Batch has no collection
markers, and ASH rejects paths containing newlines. The linked files hold the
assertions and skip conditions.

| Collector | Main tests | Representative coverage |
|---|---|---|
| Bash | [Integration suite](../scripts/tests/run_tests.sh), [robustness tests](../scripts/tests/test_bash_robustness.py) | Async uploads, binary and unusual filenames, exact size and age filters, missing/unreadable roots, dry-run, curl/GNU wget, partial responses, redirects, marker JSON limits, workspace/log exclusion, mount-path decoding, platform defaults, Retry-After parsing |
| POSIX sh / ASH | [Compatibility checks](../scripts/tests/run_ash_regression_tests.sh), [robustness tests](../scripts/tests/test_ash_robustness.py) | dash/BusyBox-shell execution, BusyBox utility self-tests, curl/GNU wget/netcat, rejection of unsafe fallbacks, newline-path refusal, cloud-directory matching, string-only mount exclusions, bounded diagnostics, batched and legacy traversal, retry limits, server-loss wait, closed console, interruption, cleanup |
| Python 3 and 2 | [Small regression checks](../scripts/tests/run_python_regression_tests.sh), [robustness tests](../scripts/tests/test_python_robustness.py) | Payloads and source encoding, filtering, symlinks/FIFOs, missing/unreadable paths, changed-file snapshots, retries, incomplete responses, interruption, no-network dry-run, drift between the two files, simulated absence of legacy TLS verification APIs |
| Perl | [Robustness tests](../scripts/tests/test_perl_robustness.py), [large-file integration](../scripts/tests/test_perl_large.sh), [large-file harness controls](../scripts/tests/test_perl_large_harness.py) | LWP behavior, complete chunked HTTP/HTTPS framing, retries, markers, source alias, directory replacement, interruption during begin/upload, large file by size and SHA-256; negative controls reject stale records and hidden collector failures |
| PowerShell, both files | [Robustness tests](../scripts/tests/test_powershell_robustness.py) | Payloads, filters, optional markers, incomplete/oversized responses, TLS trust versus hostname validation, redirects, file access failures, script drift, explicit timeout failures; locked files on Windows |
| Windows Batch | [Robustness and adapter tests](../scripts/tests/test_batch_robustness.py) | Actual cmd/WSH/curl execution on Windows, shared upload/error/TLS cases, special paths, required dependencies, no-network dry-run, temporary-file cleanup, absence of markers; POSIX tests cover only the legacy adapter's environment and quoting |

The [shared e2e suite](../scripts/tests/run_e2e_compliance.sh) also checks
source identifiers, supported markers, text/binary payload hashes, empty files,
nested paths, special names, upload counts and dry-run. On Windows,
[verify_uploads.py](../scripts/tests/verify_uploads.py) waits for stored
samples and compares their SHA-256 hashes.

**Async only:** each family's tests assert that uploads go only to
`/api/checkAsync` and that the removed `--sync` (PowerShell: `-Sync`) is
rejected as an unknown option. Bash, ash, Python and Perl tests also check that
`--async` is still accepted, so existing cron jobs keep working. For Batch,
which has no options, the POSIX adapter tests check that the source has no
other endpoint, and the Windows run checks that a stale `SYNC` environment
variable does not change it.

## Release Assets

[test_release_assets.py](../scripts/tests/test_release_assets.py) runs the
Makefile in an isolated fixture. It checks for **eight separate versioned
script assets** (no combined ZIP), keeps fake license, backup, documentation,
helper and cache files out, and checks version normalization and the
standalone configuration asset in the full release. Its Go build is a fixture;
the real Go binaries are not validated.

Before a release, rehearse `release-scripts` on the committed candidate in a
clean temporary checkout, compare the packaged files with their sources, and
run the renamed assets from outside the repository. An archive of `HEAD`
excludes uncommitted fixes. Example:
[release rehearsal](SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md#release-rehearsal).

## Real THOR Acceptance

Use the [manual acceptance guide](../scripts/MANUAL_TESTING_GUIDE.md) with the
collector's own manual cases:

| Profile | Target-specific instructions |
|---|---|
| Bash | [Bash tests](../scripts/bash/TESTING.md) |
| POSIX sh / ASH | [ASH tests](../scripts/ash/TESTING.md) |
| Python 3 and 2 | [Python tests](../scripts/python/TESTING.md) |
| Perl | [Perl tests](../scripts/perl/TESTING.md) |
| PowerShell, both versions | [PowerShell tests](../scripts/powershell/TESTING.md) |
| Windows Batch | [Batch tests](../scripts/batch/TESTING.md) |

> [!WARNING]
> Use only small generated fixtures and explicit approved directories. Do not
> scan broad default roots, production files or license directories. Keep
> licenses and private keys outside Git and outside the upload fixtures.

At minimum, check async uploads and payload integrity, supported filters,
no-network dry-run, an unreachable endpoint, missing, unreadable or locked
files, links, TLS where supported, and source and filename attribution in
backend evidence. Provoke malformed HTTP and retry failures only with isolated
synthetic servers, never on a shared real service.

A collector's success shows only its own view, and an accepted async upload is
not a finished analysis: verify received samples and, where visible, completed
analysis on the server. Record optional markers the real THOR version does not
support, even if the stub does.

## Interpreting Results

- **Record** the commit, dirty-tree status, collector filename and hash, OS,
  interpreter, transport/module versions, stub revision or THOR version,
  command, exit status, skipped cases and backend evidence.
- **A green workflow** means only that its executed assertions passed. Check
  the selected-profile list and step logs.
- **A skip is not a pass.** **NOT SUPPORTED**: intentional profile limit.
  **NOT TESTED**: missing runtime, tool, permission or backend result.
  **FAIL**: a supported case failed.
- **Runtimes:** the main Ubuntu job runs BusyBox ash with Ubuntu utilities; the
  BusyBox job swaps in Ubuntu's BusyBox build, but BusyBox features are
  compile-time options and curl/GNU wget still come from Ubuntu. Test the
  appliance userspace too. Modern Perl does not certify Perl 5.8.1 with old
  LWP/SSL; modern PowerShell does not certify PS2 or old .NET.
- **Privileges:** root runs cannot prove non-root behavior; Windows lock tests
  do not cover every ACL or reparse point. Verify on the deployed OS and
  privilege level.
- **Races:** the collectors read a live filesystem and are not atomic
  sandboxes; tests cover specific detected races only. Use the safety limits in
  each guide.
- **Scale:** small fixtures do not establish throughput, appliance resource
  use, production load or real-engine detection accuracy.

The [acceptance report of 8 October 2026](SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)
records earlier results for named revisions, including one-off probes. Later
fixes need new verification; human acceptance is a separate decision.
