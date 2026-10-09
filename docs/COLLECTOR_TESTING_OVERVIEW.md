# Collector Testing Overview

The script collectors are tested by running the actual scripts against generated
files and controlled HTTP services, checking both successful uploads and failure
behavior. Tests also check the test harness itself and release packaging. Final
acceptance uses a real THOR Thunderstorm service on the intended target platform.

This overview focuses on the rewritten collectors in `scripts/`. The existing
Go and older integration workflows are distinguished below; they are not a
replacement for the script-specific tests.

**Snapshot: 9 October 2026.** This describes the combined local integration
checkout across the collector PRs, including the pending Copilot-review fixes
and their new tests. Those fixes were not yet committed or pushed when this
overview was written. The documentation PR (#52) does not itself include all
collector implementations or test files; some relative links only resolve in
the combined tree. A collector PR checkout may also contain fewer checks.
Inspect that branch's files and workflow log before claiming coverage. This is
a description of the test setup, not a new acceptance result.

## Test Layers

```text
Generated files + actual collector process
    |
    +-- Local fault-injection server -> precise failure and recovery checks
    +-- thunderstorm-stub-server     -> upload protocol and integrity checks
    +-- Real THOR Thunderstorm      -> deployment and human acceptance

Separate checks: harness safeguards, runtime compatibility, release packaging
```

| Layer | What happens | What it establishes |
|---|---|---|
| Focused regressions | Python tests create isolated files, launch the real collector as a subprocess, and run a small loopback HTTP/HTTPS server. Some tests replace an external utility with a controlled test double. | Expected behavior for specific success and failure cases, including the collector's exit status and requests actually observed. |
| Shared stub integration | Shell suites launch or use the separate `thunderstorm-stub-server`, upload fixtures, and inspect audit records or stored payloads. | Interoperability with the test implementation of the upload protocol, metadata, counts, and file integrity. No THOR license is needed. |
| Runtime matrix | CI repeats applicable suites with different interpreters and operating systems. | Compatibility with the exact runtime and host used, not every platform the language supports. |
| Harness safeguards | Tests deliberately break selection, startup, audit/reset operations, timeouts, and other test prerequisites. | The tested harness failures cannot silently become a successful collector result. |
| Release packaging | An isolated fixture invokes the repository Makefile and checks the resulting asset list. | Correct script selection and naming, without building the real Go collector. |
| Real-service acceptance | A human runs the collector README examples on the target system against approved THOR infrastructure and verifies backend evidence. | Deployment behavior that synthetic services and CI cannot establish. |

### The Backends Are Different

The Python fault-injection servers live inside the regression tests. They can
return HTTP 503, malformed marker JSON, truncated responses, redirects, or
untrusted TLS certificates without disrupting a real service. They are not the
separate stub repository.

The shared [stub server](https://github.com/Nextron-Labs/thunderstorm-stub-server)
implements the upload endpoints and provides audit/storage evidence. The script
workflow pins its source revision with `STUB_SERVER_REF` and builds it for the
runner. Its ordinary build is sufficient for protocol tests; detection-specific
tests require its YARA-enabled build and matching rules. Neither build certifies
the real THOR scanning engine.

The older `tests/` integration harness instead uses
`NextronSystems/thunderstorm-mock` and an API compatibility proxy. These two
repositories and their binaries are **not interchangeable**.

## Collector Coverage

The tests follow each collector's documented capability profile, not one
universal feature contract. For example, Batch deliberately has no collection
markers, and ASH rejects newline-containing paths rather than promising support.

The table lists representative coverage, not a guarantee that every test applies
to every transport or runtime. The linked test files contain the assertions and
skip conditions.

| Collector | Main tests | Representative coverage |
|---|---|---|
| Bash | [Integration suite](../scripts/tests/run_tests.sh), [robustness tests](../scripts/tests/test_bash_robustness.py) | Async/sync uploads, binary and unusual filenames, exact size and age filters, missing/unreadable roots, dry-run, curl/GNU wget, partial responses, redirects, marker JSON limits, workspace/log exclusion, mount-path decoding, platform defaults, and Retry-After parsing. |
| POSIX sh / ASH | [Compatibility checks](../scripts/tests/run_ash_regression_tests.sh), [robustness tests](../scripts/tests/test_ash_robustness.py) | dash/BusyBox-shell execution, curl/GNU wget/netcat behavior, rejection of unsafe fallbacks, newline-path refusal, cloud-directory matching, bounded diagnostics, batched and legacy traversal, retry limits, interruption, and cleanup. |
| Python 3 and 2 | [Small regression checks](../scripts/tests/run_python_regression_tests.sh), [robustness tests](../scripts/tests/test_python_robustness.py) | Payloads and source encoding, filtering, symlinks/FIFOs, missing/unreadable paths, changed-file snapshots, retries, incomplete responses, interruption, no-network dry-run reporting, and drift between the two standalone implementations. Includes simulated absence of legacy TLS verification APIs. |
| Perl | [Robustness tests](../scripts/tests/test_perl_robustness.py), [large-file integration](../scripts/tests/test_perl_large.sh), [large-file harness controls](../scripts/tests/test_perl_large_harness.py) | LWP behavior, complete chunked HTTP/HTTPS framing, retries, marker handling, source alias compatibility, directory replacement, interruption during begin/upload, and a current-run large payload verified by size and SHA-256. Negative controls reject stale records and hidden collector failures. |
| PowerShell, both files | [Robustness tests](../scripts/tests/test_powershell_robustness.py) | Payloads, filters, optional markers, incomplete/oversized responses, TLS trust versus hostname validation, redirects, file access failures, script drift, and explicit timeout failures. Windows runs also test locked files. |
| Windows Batch | [Robustness and adapter tests](../scripts/tests/test_batch_robustness.py) | Actual cmd/WSH/curl execution on Windows, shared applicable upload/error/TLS cases, special paths, required dependencies, no-network dry-run, temporary-file cleanup, and absence of unsupported markers. Separate POSIX tests verify the legacy adapter's environment and quoting, not Batch execution. |

The [shared e2e suite](../scripts/tests/run_e2e_compliance.sh) additionally checks
source identifiers, supported collection markers, text/binary payload hashes,
empty files, nested paths, special names, upload counts, and dry-run behavior.
The Windows workflow uses [verify_uploads.py](../scripts/tests/verify_uploads.py)
to wait for stored samples and compare their SHA-256 hashes.

## What Runs Automatically

The source of truth is
[script-collectors.yml](../.github/workflows/script-collectors.yml).
It runs on relevant script/Makefile/workflow changes and can also be started
manually. Linux and Windows jobs each have a 30-minute job limit. A docs-only
change under `docs/` does not trigger this workflow through its path filter.

| CI host | Configured execution |
|---|---|
| Ubuntu | Shared harness checks, release-asset tests, selected collectors against the stub, and available collector-specific suites. ASH runs under dash and BusyBox ash. Bash and Perl use the runner's installed runtimes. |
| Ubuntu with Docker | The Python robustness suite also runs under actual Python 2.7.18 and Python 3.4.10 in digest-pinned images, as a non-root user with read-only source mounts. |
| Windows | Both PowerShell files run under **Windows PowerShell 5.1**. Batch runs under native cmd, Windows Script Host, and curl. Selected Windows collectors also upload fixtures to a Windows-built stub. |

Collector-specific steps are conditional on their test files existing. This lets
the shared harness land before all collector replacements. Selection also checks
the expected CLI interface: old scripts are not automatically treated as new
implementations merely because their files exist.

[select_collectors.py](../scripts/tests/select_collectors.py) makes a
collector-specific PR branch require its own profile. On a general branch,
automatic selection can legitimately find no new collectors. Explicit requests
for missing/incompatible profiles on the job's platform fail rather than silently
skipping; profiles for the other platform are handled by that other job. The
`python` group means Python 3; Python 2 has separate container coverage, and
explicit shared-harness selection requires a `python2` executable on that host.

This selection governs shared integration checks. Focused suites are separately
gated by file existence, so selecting one profile does not necessarily suppress
all other focused suites present in a combined checkout.

### Optional Suites and Other Workflows

| Entry point | Role and automation boundary |
|---|---|
| [run_detection_tests.sh](../scripts/tests/run_detection_tests.sh) | Additional detection, path, filtering, and failure scenarios. Requires a suitable YARA-enabled stub and rules. Not executed as a suite by the script workflow; it receives a syntax check. |
| [run_operational_tests.sh](../scripts/tests/run_operational_tests.sh) | Additional marker, interruption, source, sync, multi-root, retry, progress, and fallback scenarios. Has its own stub/rule discovery and setup. Syntax-checked, not executed as a suite by that workflow. |
| [run_filter_tests.sh](../scripts/tests/run_filter_tests.sh) | Additional age, size, and extension checks. Requires an already-running stub, its audit log, and prepared fixtures. Syntax-checked, not executed as a suite by that workflow. |
| [Collector Tests workflow](../.github/workflows/test-collectors.yml) | Runs `tests/test-collectors.sh all` against the separate mock/proxy setup, including the Go collector and older script adapters. Its Ubuntu run cannot establish native Batch execution. The harness requires Bash 4.3+ and GNU-compatible utilities. |
| [ShellCheck workflow](../.github/workflows/shellcheck.yml) | Checks shell files under `tests/`; it does not automatically lint every collector under `scripts/`. |
| [Go workflow](../.github/workflows/go.yml) | Separate Go test/build matrix for Go 1.10 and stable. The root `make test` delegates to the Go tests, **not** the script suites described here. |

Some cases overlap across suites. Their existence in the repository is not
evidence they ran, and their totals should not be added as though they were all
distinct scenarios.

## Running Tests Locally

Run these commands from the repository root, on the exact candidate branch.
Only run suites whose files are present there. Use an ordinary, non-root test
account: root can read fixtures that are meant to be unreadable. Tests create
temporary data and local listeners; allow loopback access and do not share their
ports with another run.

The test host needs more tools than the deployed collector. Depending on the
suite, install a current Python 3, Bash, the tested interpreter, curl/GNU wget, Perl modules,
OpenSSL for temporary TLS certificates, and netcat plus `timeout` for ASH's
netcat cases. Docker is needed for CI-equivalent legacy Python containers.
Missing optional tools can cause skips; inspect those rather than assuming full
coverage. TLS fixtures do not require installing a CA globally.

### Fast Harness Checks

These do not need a Thunderstorm service or license:

```sh
python3 -B scripts/tests/test_harness.py
python3 -B scripts/tests/test_release_assets.py
```

On the Perl and Windows collector branches, respectively:

```sh
python3 -B scripts/tests/test_perl_large_harness.py
python3 -B scripts/tests/test_batch_robustness.py BatchAdapterTests
```

### Focused Collector Tests

Each regression suite starts its own fault-injection server; do not start a
separate stub for these commands. Run the applicable lines, not necessarily all
of them on one host:

```sh
python3 -B scripts/tests/test_bash_robustness.py
COLLECTOR_BASH=/bin/bash python3 -B scripts/tests/test_bash_robustness.py

COLLECTOR_SH=/bin/dash python3 -B scripts/tests/test_ash_robustness.py
COLLECTOR_SH='busybox ash' python3 -B scripts/tests/test_ash_robustness.py

python3 -B scripts/tests/test_python_robustness.py
python2 -B scripts/tests/test_python_robustness.py

python3 -B scripts/tests/test_perl_robustness.py
```

Record what `/bin/bash` actually is; on macOS it can provide the Bash 3.2 check.
The Python suite selects the matching collector from the interpreter running the
suite. Running the suite with Python 3 does not test Python 2. For the exact
digest-pinned Python 2.7/3.4 Docker commands, use the workflow linked above.

On Windows, run the following in PowerShell with Python and OpenSSL available:

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

The Windows example uses the host's Windows PowerShell, usually 5.1, not an
actual PS2 runtime. On Unix with `pwsh` installed, the PowerShell regression
suite defaults to that runtime; it cannot validate Windows ACLs or native Batch.

### Shared Stub Integration

Use the stub revision pinned in the candidate branch's workflow when reproducing
CI. Verify the sibling checkout's revision rather than blindly updating or
switching someone else's checkout. Build a native binary with a Go toolchain
supported by the host OS; a Linux binary will not run on macOS.

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

Replace `bash` with `ash`, `python3`, `python2`, `perl`, `ps3`, or `ps2`, or a
comma-separated selection available on this host. Both strict flags are useful:
one requires a match, the other requires **every requested** profile. Batch is
not a selector in this shell suite; use its Windows tests/workflow instead.

The suite owns the stub lifecycle, so no separately started server is needed.
For concurrent runs, assign a distinct unused `STUB_PORT`. On the corresponding
branches, also run:

```sh
bash scripts/tests/run_tests.sh "$STUB_BIN"
STUB_BIN_PATH="$STUB_BIN" bash scripts/tests/test_perl_large.sh
```

The Bash suite checks its own scenarios. The Perl helper starts its own stub on
a temporary port and uploads a generated file just over 3 MiB; it checks the
collector exit and a unique current-run audit record with matching size/hash.
It does not reuse an existing service or old audit log. These are separate runs,
not additional options to the shared e2e suite.

## Release Assets and Real THOR Acceptance

[test_release_assets.py](../scripts/tests/test_release_assets.py) checks that
the nested script locations produce **eight separate versioned script assets**,
not a combined ZIP. Fake license, backup, documentation, helper, and cache files
must stay out of the assets. It also checks version normalization and retention
of the standalone configuration asset in the full release. Its Go build is a
fixture, so this test does not execute or validate the real Go binaries.

Before releasing, also rehearse `release-scripts` on the committed candidate in
a clean temporary checkout, compare the packaged files with their sources, and
execute the renamed standalone assets from outside the repository. The
[dated acceptance report](SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md#release-rehearsal)
contains an example. An archive of `HEAD` excludes uncommitted fixes.

For human acceptance, use the [manual review guide](../scripts/MANUAL_TESTING_GUIDE.md)
and the README from the **same collector branch**:

| Profile | Target-specific instructions |
|---|---|
| Bash | [Bash README](../scripts/bash/README.md) |
| POSIX sh / ASH | [ASH README](../scripts/ash/README.md) |
| Python 3 and 2 | [Python README](../scripts/python/README.md) |
| Perl | [Perl README](../scripts/perl/README.md) |
| PowerShell, both versions | [PowerShell README](../scripts/powershell/README.md) |
| Windows Batch | [Batch README](../scripts/batch/README.md) |

Use only small, generated fixtures and explicit approved directories. Do not
scan broad default roots, production files, or license directories for acceptance.
Keep licenses and private keys outside Git and outside the upload fixtures.

At minimum, check positive async/sync uploads, payload integrity, supported
filters, no-network dry-run, an unreachable endpoint, missing/unreadable or
locked files, link behavior, and TLS where supported. Confirm source and
filename attribution in backend evidence when available. Use isolated synthetic
servers for deliberate malformed HTTP and retry failures; do not disrupt a shared
real service to manufacture them.

The collector reporting success only proves its view of the upload. An async
HTTP acceptance is not proof of completed analysis. Independently verify the
received samples and, where observable, completed backend analysis. Optional
markers may be unsupported by a real THOR version even though the stub supports
them; record that explicitly.

## Interpreting Results

- Record the exact commit, dirty-tree status, collector filename/hash, OS,
  interpreter, transport/module versions, stub revision or THOR version, command,
  exit status, skipped cases, and backend evidence.
- A green workflow means its executed assertions passed. It does not mean every
  collector was selected, every optional suite ran, or every legacy runtime was
  tested. Check the selected-profile list and step logs.
- A skip is not a pass. Distinguish **NOT SUPPORTED** for an intentional profile
  limitation from **NOT TESTED** for a missing runtime, tool, permission, or
  observable backend result. Supported failures are **FAIL**.
- BusyBox ash on Ubuntu still uses many Ubuntu utilities. Test the actual
  appliance userspace as well. A modern Perl run does not certify Perl 5.8.1 and
  old LWP/SSL combinations; modern PowerShell does not certify PS2/old .NET.
- Permission tests run as root cannot prove non-root behavior. Windows lock
  tests do not cover every ACL/reparse-point configuration. Verify the deployed
  OS and privilege level separately.
- These are live filesystem collectors, not atomic filesystem sandboxes.
  Directory-replacement regressions cover particular detected races, not all
  adversarial concurrent mutations. Use the safety limits in each README.
- Small functional fixtures do not establish large-scale throughput, resource
  use on every appliance, production load handling, or real-engine detection
  accuracy. Add deployment-specific tests where those properties matter.

The [8 October acceptance report](SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)
records earlier automated and real-service results for explicitly identified
revisions, including one-off probes that are not all committed CI tests. Later
fixes require renewed verification; those earlier results do not automatically
approve the current working tree. Human acceptance remains a separate decision.
