# THOR Thunderstorm Script Collectors

Pick the script that matches the runtime on the target, then follow its guide.
For the choice between Go and scripts, downloads and the overall workflow, see
the [main README](../README.md).

- Recommendations by product: [product and platform list](../docs/COLLECTOR_RECOMMENDATIONS.md)
- Assessment paths and presets: [Emerging Threats profiles](../emerging-threats/README.md)

## Choosing a Collector

| Available execution environment | Collector | Guide |
| --- | --- | --- |
| Bash on a compatible Unix-like host | [Bash](bash/thunderstorm-collector.sh) | [Bash guide](bash/README.md) |
| POSIX sh / ash, including BusyBox and minimal Linux | [POSIX sh / ash](ash/thunderstorm-collector-ash.sh) | [ash guide](ash/README.md) |
| Python 3.4+ | [Python 3](python/thunderstorm-collector.py) | [Python guide](python/README.md) |
| Legacy Python 2.7 | [Python 2](python/thunderstorm-collector-py2.py) | [Python guide](python/README.md) |
| Perl with the required modules | [Perl](perl/thunderstorm-collector.pl) | [Perl guide](perl/README.md) |
| Windows PowerShell 3+ | [PowerShell](powershell/thunderstorm-collector.ps1) | [PowerShell guide](powershell/README.md) |
| Legacy Windows PowerShell 2 | [PowerShell 2](powershell/thunderstorm-collector-ps2.ps1) | [PowerShell guide](powershell/README.md) |
| Windows cmd with Windows Script Host and suitable curl | [Batch](batch/thunderstorm-collector.bat) | [Batch guide](batch/README.md) |

- **One file is enough.** Each collector is standalone; `scripts/tests/` is
  test tooling, not needed on the collecting host.
- **Settings** live in the script header, with command-line or
  environment-variable overrides depending on the collector. Scripts do not
  read the Go YAML configuration.
- **Directories:** most scripts have defaults; Batch requires an explicit
  directory. Preview the collection first. Flags and units differ between
  languages.

## VMware ESXi: Use the Python Collector

Use the [Python 3 collector](python/thunderstorm-collector.py) and its
[guide](python/README.md).

> [!NOTE]
> Earlier Python collector revisions ran successfully on ESXi; firmware and
> collector versions were not recorded. The revised collector is **not yet
> tested** on ESXi. The
> [acceptance report of 8 October 2026](../docs/SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md)
> records tests against real THOR with Python 3.9.6 on macOS and Python 3.4.10
> and 2.7.18 in containers.

### Requirements

| File | Interpreter | Notes |
| --- | --- | --- |
| `thunderstorm-collector.py` | **Python 3.4+**, standard library only | Preferred |
| `thunderstorm-collector-py2.py` | **Python 2.7** | Legacy hosts. Verified HTTPS needs 2.7.9+; older versions refuse HTTPS instead of disabling certificate checks |

Use an interpreter already on the appliance; `python3` is not a guaranteed
ESXi path. No unsupported runtime or ESXi security change is required.

### Quick start

Copy `scripts/python/thunderstorm-collector.py` to a working directory on the
target. Replace the server, and point `--dirs` at an existing absolute
directory with a few synthetic test files. Preview first:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal --port 8080 \
  --dirs /absolute/path/to/collector-test --source esxi-test \
  --max-age 14 --max-size-kb 2048 --dry-run
```

The dry run contacts no server, so it does not check connectivity, TLS or
file readability. If the selection is right, upload:

```sh
python3 ./thunderstorm-collector.py \
  --server thunderstorm.example.internal --port 8080 \
  --dirs /absolute/path/to/collector-test --source esxi-test \
  --max-age 14 --max-size-kb 2048 --no-dry-run
```

For Python 2.7, use `thunderstorm-collector-py2.py` with that interpreter; the
options are the same. For a versioned release file, use its filename.

- **Defaults:** port **8080**, files changed in the last **30 days**
  (`--max-age 0` disables the filter), up to **2048 KiB (2 MiB)** inclusive.
- **Directories:** without `--dirs`, the collector uses `/` unless `SCAN_DIRS`
  was changed in the header.
- **Skipped:** symlink entries, special files and configured system, cloud and
  VM path patterns. The [Python guide](python/README.md) has the full rules,
  retries and exit codes.
- **HTTPS:** add `--tls` and the port. For a private CA, add
  `--ca-cert /path/to/ca.pem`; certificate and hostname checks stay on. Old SSL
  libraries can still limit interoperability.
- **Results:** uploads are always asynchronous. Check received samples and
  analysis results on the server.

### Release v1.0.1

The steps above apply to the current source and later releases
([download guidance](../README.md#download-a-collector)).
`thunderstorm-collector-1.0.1.py` needs Python 3.6+, has no `--dry-run` or
age/size options, and has a 20 MiB size limit. Do not use the examples above
with it; see
[its tagged source](https://github.com/NextronSystems/thunderstorm-collector/blob/v1.0.1/scripts/thunderstorm-collector.py)
and its `--help` output.

## Alternatives to Running a Collector

If no script can be deployed on the source:

- **SSHFS scanning:** mount the source directories on a supported analysis
  workstation and run THOR there. The source needs SSH/SFTP access and read
  permissions; nothing runs on it.
- **[SFTP collector](../sftp/README.md)** (prototype): same access, no mount.
  It runs on the Thunderstorm host or another system and sends only the files
  it selects from the SFTP directory listing.

[Choosing a THOR scanning approach](../docs/SCANNING_APPROACHES.md) has the
SSHFS example and compares it with native scans, Thunderstorm submissions and
offline analysis,
including licensing and evidence coverage.

## Testing

**Manual acceptance:** each language guide's testing section contains or links
to that collector's cases: [Bash](bash/README.md), [ash](ash/README.md),
[Python](python/README.md), [Perl](perl/README.md),
[PowerShell](powershell/README.md), [Batch](batch/README.md). Run them on the
exact revision or release asset you will deploy, with synthetic files and
explicit directories. Record the results with the shared
[test preparation](MANUAL_TESTING_GUIDE.md#manual-test-preparation) and
[acceptance record](MANUAL_TESTING_GUIDE.md#acceptance-record).

**Automated tests:** the [testing overview](../docs/COLLECTOR_TESTING_OVERVIEW.md)
covers backends, prerequisites and CI. A focused run from the repository
root:

```bash
THUNDERSTORM_TEST_COLLECTORS=bash \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

Selectors: `bash`, `ash`, `python3`, `python2`, `perl`, `ps3`, `ps2`. Set
`THUNDERSTORM_TEST_REQUIRE_MATCH=1` to fail when the requested collector is
missing or not runnable.

## Building a Collector for Another Platform

The [collector construction guide](../docs/COLLECTOR_CONSTRUCTION_GUIDE.md)
describes the upload protocol, capability profiles, safety requirements and
acceptance tests, with a reusable coding-agent assignment for a new language,
OS or architecture.
