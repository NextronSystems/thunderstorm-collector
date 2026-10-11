# THOR Thunderstorm Script Collectors

Use this guide to select a standalone script and find its runtime-specific instructions. The [main README](../README.md) covers the Go-versus-script choice, downloads, and the overall collection workflow. Current scripts use header settings with command-line or environment-variable overrides, depending on the collector; they do not read the Go YAML configuration.

For VMware ESXi, start with the [Python guidance below](#vmware-esxi-use-the-python-collector). For assessment-specific paths and presets, see the [Emerging Threats profiles](../emerging-threats/README.md).

For recommendations by product rather than scripting language, see the [product and platform recommendation list](../docs/COLLECTOR_RECOMMENDATIONS.md). It distinguishes candidate combinations from recorded tests and explains when external file collection is needed.

## Choosing a Collector

The eight collectors are organized by language. Choose a file using the target's available runtime, then follow its guide for all prerequisites and configuration options.

| Available execution environment | Collector | Guide |
| --- | --- | --- |
| Bash on a compatible Unix-like host | [Bash](bash/thunderstorm-collector.sh) | [Requirements and usage](bash/README.md) |
| POSIX sh / ash, including BusyBox and minimal Linux | [POSIX sh / ash](ash/thunderstorm-collector-ash.sh) | [Requirements and usage](ash/README.md) |
| Python 3.4+ | [Python 3](python/thunderstorm-collector.py) | [Requirements and usage](python/README.md) |
| Legacy Python 2.7 | [Python 2](python/thunderstorm-collector-py2.py) | [Requirements and usage](python/README.md) |
| Perl with the required modules | [Perl](perl/thunderstorm-collector.pl) | [Requirements and usage](perl/README.md) |
| Windows PowerShell 3+ | [PowerShell](powershell/thunderstorm-collector.ps1) | [Requirements and usage](powershell/README.md) |
| Legacy Windows PowerShell 2 | [PowerShell 2](powershell/thunderstorm-collector-ps2.ps1) | [Requirements and usage](powershell/README.md) |
| Windows cmd with Windows Script Host and suitable curl | [Batch](batch/thunderstorm-collector.bat) | [Requirements and usage](batch/README.md) |

Each collector is a standalone file; `scripts/tests/` contains development/acceptance tooling and is not needed on the collecting host. Preview the collection using the selected guide's syntax. Most scripts have default collection directories; Batch requires an explicit directory. Override the defaults when you want a different scope. Flags and units differ between languages.

## VMware ESXi: use the Python collector

For VMware ESXi, start with [the Python 3 collector](python/thunderstorm-collector.py) and its [full usage and acceptance guide](python/README.md). Earlier Python collector revisions have been used successfully on ESXi, but the exact firmware versions and collector revisions were not recorded. The revised implementation still requires validation on the intended ESXi system.

### Requirements and compatibility

- The revised Python 3 collector requires **Python 3.4 or later** and only the standard library.
- A separate, standalone [Python 2 collector](python/thunderstorm-collector-py2.py) supports **Python 2.7** for legacy hosts. Prefer Python 3 where available. Verified HTTPS requires Python 2.7.9 or later; older versions refuse it rather than silently disabling certificate verification.
- Select an interpreter already available on the appliance. `python3` in the examples is not a guaranteed ESXi interpreter path. Runtime and SSL availability depend on the appliance; these instructions do not require installing an unsupported runtime or changing ESXi security settings.
- As of **8 October 2026**, the [script acceptance report](../docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md) records successful HTTP/HTTPS tests with Python 3.9.6 on macOS and actual Python 3.4.10 and 2.7.18 in containers against real THOR. These are not ESXi deployment tests.

### Source checkout versus published releases

The quick start below describes the revised source files in `scripts/python/` and later releases containing those files. Each collector is standalone: copy the selected `.py` file to the target; the rest of this repository and the test harness are not required there.

See the [main download guidance](../README.md#download-a-collector) for current release availability. The older `thunderstorm-collector-1.0.1.py` requires Python 3.6+, has no `--dry-run` or configurable age/size options, and uses a 20 MiB size limit. Do not apply the revised examples below to that file. Consult [its tagged source](https://github.com/NextronSystems/thunderstorm-collector/blob/v1.0.1/scripts/thunderstorm-collector.py) and its `--help` output instead.

### Quick start for the revised collector

Copy `scripts/python/thunderstorm-collector.py` to a working directory on the target. From that directory, substitute the actual server and an existing absolute directory containing a few synthetic test files. Begin with a local dry-run:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal --port 8080 \
  --dirs /absolute/path/to/collector-test --source esxi-test \
  --max-age 14 --max-size-kb 2048 --dry-run
```

The dry-run selects files without contacting the server. It does not verify upload connectivity, TLS or payload readability. After checking the selection, use `--no-dry-run` to upload the same fixture files:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal --port 8080 \
  --dirs /absolute/path/to/collector-test --source esxi-test \
  --max-age 14 --max-size-kb 2048 --no-dry-run
```

For a later versioned release file, substitute its actual filename. For the legacy collector, copy `scripts/python/thunderstorm-collector-py2.py` instead and substitute the available Python 2.7 interpreter and that filename; the selection and upload options are the same.

For normal collection, `--dirs` is optional: on ESXi/Unix, omitting it uses `/` unless `SCAN_DIRS` was changed in the header. Use an explicit synthetic-file directory for the test examples above. The revised collector defaults to port 8080, a maximum age of 30 days and a maximum size of **2048 KiB (2 MiB)**, including the exact limit. `--max-age 0` disables age filtering. Symlink entries, special files and configured system/cloud/VM path patterns are skipped; see the Python guide for the full selection rules.

For HTTPS, add `--tls` and the appropriate port. Use `--ca-cert /path/to/ca.pem` for a private CA while retaining certificate and hostname verification. Old SSL libraries can still limit interoperability even when the Python version meets the minimum.

Uploads are asynchronous by default; check received samples and analysis results on the server. The [Python guide](python/README.md) is the reference for synchronous mode, retries, exit codes, exclusions, and manual acceptance checks.

## Manual Acceptance Testing

Each language guide contains acceptance cases for that collector. Run them against the exact source revision or release asset you intend to deploy, starting with synthetic files and explicit directories.

Use the shared [test preparation](MANUAL_TESTING_GUIDE.md#manual-test-preparation) and [acceptance record](MANUAL_TESTING_GUIDE.md#acceptance-record) to capture runtime, service, revision/hash, collection scope, and server-side results. The older PR-stack sections in that document describe the original review process; the collectors are now merged.

## Automated Tests

The [testing overview](../docs/COLLECTOR_TESTING_OVERVIEW.md) explains available backends, prerequisites, and CI coverage. Run focused shared-harness checks from the repository root:

```bash
THUNDERSTORM_TEST_COLLECTORS=bash \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

Supported selector values are `bash`, `ash`, `python3`, `python2`, `perl`, `ps3`, and `ps2`.

Use `THUNDERSTORM_TEST_REQUIRE_MATCH=1` when CI or manual test runs must fail if the requested collector is missing or not runnable.

## Building a Collector for Another Platform

The [collector construction guide](../docs/COLLECTOR_CONSTRUCTION_GUIDE.md) describes the
upload protocol, optional capability profiles, safety requirements and acceptance
tests without prescribing a language-specific implementation. It includes a
reusable assignment for a coding agent targeting a new language, OS or architecture.
