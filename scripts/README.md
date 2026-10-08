# THOR Thunderstorm Script Collectors

This directory contains script-based THOR Thunderstorm collectors for systems where the Go collector cannot be deployed or where a native script is easier to review, modify, or execute during incident response.

Prefer the Go collector for normal deployments; for VMware ESXi, start with the [Python guidance below](#vmware-esxi-use-the-python-collector). Use these scripts when runtime constraints, legacy systems, embedded systems, or operational restrictions make the compiled collector impractical.

## Directory Layout

| Directory | Collector type | Intended use |
|---|---|---|
| `bash/` | Bash collector | Modern Linux, macOS, WSL, and Unix-like systems with Bash. |
| `ash/` | POSIX sh / ash collector | BusyBox, Alpine, embedded Linux, network appliances, and stripped-down systems without Bash. |
| `python/` | Python collectors | Python 3 for general cross-platform use; Python 2 for legacy systems without Python 3. |
| `perl/` | Perl collector | Unix systems where Perl is available but Bash or Python are not suitable. |
| `powershell/` | PowerShell collectors | Windows systems with PowerShell 3+ or legacy PowerShell 2. |
| `batch/` | Windows Batch collector | Last-resort Windows collector for systems without usable PowerShell. |
| `tests/` | Test harness | Shared stub-server-backed tests for automated validation. |

## Choosing a Collector

| Scenario | Recommended collector |
|---|---|
| Current Linux or macOS host with Bash | `bash/thunderstorm-collector.sh` |
| BusyBox, Alpine, embedded Linux, router, IoT, minimal appliance | `ash/thunderstorm-collector-ash.sh` |
| Cross-platform host with Python 3.4+ | `python/thunderstorm-collector.py` |
| Legacy Unix/Linux host with only Python 2.7 | `python/thunderstorm-collector-py2.py` |
| Older Unix host with Perl and LWP available | `perl/thunderstorm-collector.pl` |
| Windows with PowerShell 3 or newer | `powershell/thunderstorm-collector.ps1` |
| Windows with only PowerShell 2 | `powershell/thunderstorm-collector-ps2.ps1` |
| Windows without usable PowerShell | `batch/thunderstorm-collector.bat` |

## VMware ESXi: use the Python collector

For VMware ESXi, start with [the Python 3 collector](python/thunderstorm-collector.py) and its [full usage and acceptance guide](python/README.md). Earlier Python collector revisions have been used successfully on ESXi, but the exact firmware versions and collector revisions were not recorded. The revised implementation still requires validation on the intended ESXi system.

### Requirements and compatibility

- The revised Python 3 collector requires **Python 3.4 or later** and only the standard library.
- A separate, standalone [Python 2 collector](python/thunderstorm-collector-py2.py) supports **Python 2.7** for legacy hosts. Prefer Python 3 where available. Verified HTTPS requires Python 2.7.9 or later; older versions refuse it rather than silently disabling certificate verification.
- Select an interpreter already available on the appliance. `python3` in the examples is not a guaranteed ESXi interpreter path. Runtime and SSL availability depend on the appliance; these instructions do not require installing an unsupported runtime or changing ESXi security settings.
- As of **8 October 2026**, the [script acceptance report in PR #52](https://github.com/NextronSystems/thunderstorm-collector/pull/52) records successful HTTP/HTTPS tests with Python 3.9.6 on macOS and actual Python 3.4.10 and 2.7.18 in containers against real THOR. These are not ESXi deployment tests.

### Source checkout versus published releases

The quick start below describes the revised source files in `scripts/python/` and later releases containing those files. Each collector is standalone: copy the selected `.py` file to the target; the rest of this repository and the test harness are not required there.

As of 8 October 2026, the latest published release is **v1.0.1**; **v1.0.2 has not been published**. The older `thunderstorm-collector-1.0.1.py` requires Python 3.6+, has no `--dry-run` or configurable age/size options, and uses a 20 MiB size limit. Do not apply the revised examples below to that file. Consult [its tagged source](https://github.com/NextronSystems/thunderstorm-collector/blob/v1.0.1/scripts/thunderstorm-collector.py) and its `--help` output instead. Release files are downloaded individually from [Releases](https://github.com/NextronSystems/thunderstorm-collector/releases); there is no scripts ZIP archive.

### Quick start for the revised collector

Copy `scripts/python/thunderstorm-collector.py` to a working directory on the target. From that directory, substitute the actual server and an existing absolute directory containing a few synthetic test files. Begin with a local dry-run:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal --port 8080 \
  --dirs /absolute/path/to/collector-test --source esxi-test \
  --max-age 14 --max-size-kb 2048 --dry-run
```

The dry-run selects files without contacting the server. It does not verify upload connectivity, TLS or payload readability. After checking the selection, remove `--dry-run` to upload the same fixture files:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal --port 8080 \
  --dirs /absolute/path/to/collector-test --source esxi-test \
  --max-age 14 --max-size-kb 2048
```

For a later versioned release file, substitute its actual filename. For the legacy collector, copy `scripts/python/thunderstorm-collector-py2.py` instead and substitute the available Python 2.7 interpreter and that filename; the selection and upload options are the same.

Always pass an explicit directory: omitting `--dirs` selects `/`. The revised collector defaults to port 8080, a maximum age of 14 days and a maximum size of **2048 KiB (2 MiB)**, including the exact limit. `--max-age 0` disables age filtering. Symlink entries, special files and configured system/cloud/VM path patterns are skipped; see the Python guide for the full selection rules.

For HTTPS, add `--tls` and the appropriate port. Use `--ca-cert /path/to/ca.pem` for a private CA while retaining certificate and hostname verification. Old SSL libraries can still limit interoperability even when the Python version meets the minimum.

Uploads are asynchronous by default; `--sync` selects synchronous requests. An accepted asynchronous upload is not proof that analysis has finished. Check received samples and results on the server. `--retries` bounds total upload attempts, including the first (default 3); a lost response can still lead to duplicate submissions. Exit 0 means successful selection or accepted uploads, exit 1 reports partial failures/interruption, and exit 2 reports invalid configuration or a fatal startup failure. Refer to the [Python guide](python/README.md) for detailed behavior and acceptance checks.

## Manual Acceptance Testing

Each collector directory contains its own `README.md` with a manual acceptance test section. Use that section when reviewing the corresponding collector PR locally.

For the full PR checkout order and manual reviewer checklist, see [`MANUAL_TESTING_GUIDE.md`](MANUAL_TESTING_GUIDE.md).

Recommended reviewer workflow:

1. Check out the collector PR branch.
2. Read the collector-specific README.
3. Run the manual acceptance test against a real THOR Thunderstorm service.
4. Run the automated stub-server test if the required runtime is available.
5. Review uploaded samples and source identifiers in Thunderstorm.

## Automated Tests

The shared test harness can run only selected collectors:

```bash
THUNDERSTORM_TEST_COLLECTORS=bash \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

Supported selector values are `bash`, `ash`, `python3`, `python2`, `perl`, `ps3`, and `ps2`.

Use `THUNDERSTORM_TEST_REQUIRE_MATCH=1` when CI or manual test runs must fail if the requested collector is missing or not runnable.
