# THOR Thunderstorm Script Collectors

This directory contains script-based THOR Thunderstorm collectors for systems where the Go collector cannot be deployed or where a native script is easier to review, modify, or execute during incident response.

Prefer the Go collector for normal deployments. Use these scripts when runtime constraints, legacy systems, embedded systems, or operational restrictions make the compiled collector impractical.

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
| Cross-platform host with Python 3 | `python/thunderstorm-collector.py` |
| Legacy Unix/Linux host with only Python 2 | `python/thunderstorm-collector-py2.py` |
| Older Unix host with Perl and LWP available | `perl/thunderstorm-collector.pl` |
| Windows with PowerShell 3 or newer | `powershell/thunderstorm-collector.ps1` |
| Windows with only PowerShell 2 | `powershell/thunderstorm-collector-ps2.ps1` |
| Windows without usable PowerShell | `batch/thunderstorm-collector.bat` |

## Manual Acceptance Testing

Each collector directory contains its own `README.md` with a manual acceptance test section. Use that section when reviewing the corresponding collector PR locally.

Recommended reviewer workflow:

1. Check out the collector PR branch.
2. Read the collector-specific README.
3. Run the manual acceptance test against a real Thunderstorm service.
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

