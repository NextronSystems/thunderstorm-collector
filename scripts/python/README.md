# Python Collectors

The Python collectors are cross-platform script collectors for systems where Python is available. Prefer the Python 3 collector. Use the Python 2 collector only for legacy systems that do not provide Python 3.

## Intended Use

Use `thunderstorm-collector.py` on systems with Python 3. Use `thunderstorm-collector-py2.py` on legacy Unix/Linux systems where Python 2 is the only available Python runtime.

## Requirements

| Collector | Runtime | Dependencies |
|---|---|---|
| `thunderstorm-collector.py` | Python 3 | Python standard library |
| `thunderstorm-collector-py2.py` | Python 2.7 | Python standard library |

## Capabilities

- No external `curl` or `wget` dependency.
- Recursive directory scanning.
- File age and file size filtering.
- HTTP and HTTPS upload support.
- Configurable source identifier.
- Dry-run mode.
- Collection markers.

## Limitations

- Python 2 is end-of-life and should only be used for legacy hosts.
- TLS behavior on older Python 2 runtimes can be limited by the runtime SSL module.
- Runtime-specific path and Unicode behavior can differ on old systems.

## Basic Usage

Python 3:

```bash
python3 scripts/python/thunderstorm-collector.py \
  -s thunderstorm.local \
  -p 8080 \
  -d /tmp \
  --max-age 14
```

Python 2:

```bash
python scripts/python/thunderstorm-collector-py2.py \
  -s thunderstorm.local \
  -p 8080 \
  -d /tmp \
  --max-age 14
```

## Manual Acceptance Test

Python 3:

```bash
rm -rf /tmp/ts-python-acceptance
mkdir -p /tmp/ts-python-acceptance/subdir
printf 'python acceptance text\n' > /tmp/ts-python-acceptance/sample.txt
printf '\x00\x01\x02THUNDER\n' > /tmp/ts-python-acceptance/sample.bin
printf 'nested\n' > /tmp/ts-python-acceptance/subdir/nested.txt

python3 scripts/python/thunderstorm-collector.py \
  -s thunderstorm.local \
  -p 8080 \
  -d /tmp/ts-python-acceptance \
  --source manual-python3-acceptance \
  --max-age 30
```

Python 2, if applicable:

```bash
python scripts/python/thunderstorm-collector-py2.py \
  -s thunderstorm.local \
  -p 8080 \
  -d /tmp/ts-python-acceptance \
  --source manual-python2-acceptance \
  --max-age 30
```

Acceptance criteria:

- The command exits successfully.
- Thunderstorm records uploads for the test files.
- The source field matches the selected manual test source.
- Text, binary, and nested files are uploaded.

## Automated Stub Test

Python 3:

```bash
THUNDERSTORM_TEST_COLLECTORS=python3 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

Python 2:

```bash
THUNDERSTORM_TEST_COLLECTORS=python2 THUNDERSTORM_TEST_REQUIRE_MATCH=1 \
  scripts/tests/run_e2e_compliance.sh ../thunderstorm-stub-server/thunderstorm-stub-server
```

