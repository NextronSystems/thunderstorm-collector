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

## Manual Robustness Tests

Run the same tests with Python 3 and, when validating legacy support, repeat them with Python 2 by replacing the interpreter and script path.

### Dry-run does not contact the server

```bash
python3 scripts/python/thunderstorm-collector.py \
  -s 127.0.0.1 \
  -p 1 \
  -d /tmp/ts-python-acceptance \
  --source manual-python3-dry-run \
  --dry-run
```

Expected result:

- The command exits successfully.
- No upload is visible in Thunderstorm.
- The output reports what would be submitted.

### Thunderstorm service unreachable

```bash
python3 scripts/python/thunderstorm-collector.py \
  -s 127.0.0.1 \
  -p 1 \
  -d /tmp/ts-python-acceptance \
  --source manual-python3-unreachable \
  --max-age 30
```

Expected result:

- The command exits non-zero or reports failed submissions.
- The collector prints a clear connection failure.
- The command does not hang indefinitely.

### Missing and unreadable paths

This test is meaningful only when not running as `root`.

```bash
rm -rf /tmp/ts-python-errors
mkdir -p /tmp/ts-python-errors/readable /tmp/ts-python-errors/unreadable
printf 'readable\n' > /tmp/ts-python-errors/readable/ok.txt
printf 'secret\n' > /tmp/ts-python-errors/unreadable/blocked.txt
chmod 000 /tmp/ts-python-errors/unreadable/blocked.txt

python3 scripts/python/thunderstorm-collector.py \
  -s thunderstorm.local \
  -p 8080 \
  -d /tmp/ts-python-errors/readable \
  -d /tmp/ts-python-errors/unreadable \
  -d /tmp/ts-python-errors/missing \
  --source manual-python3-error-paths \
  --max-age 30

chmod 644 /tmp/ts-python-errors/unreadable/blocked.txt
```

Expected result:

- The collector does not crash on missing or unreadable paths.
- The readable file is still submitted.
- Warnings or failed-file statistics are acceptable.

### File size filter

```bash
rm -rf /tmp/ts-python-filter
mkdir -p /tmp/ts-python-filter
printf 'small\n' > /tmp/ts-python-filter/small.txt
dd if=/dev/zero of=/tmp/ts-python-filter/large.bin bs=1024 count=32 2>/dev/null

python3 scripts/python/thunderstorm-collector.py \
  -s thunderstorm.local \
  -p 8080 \
  -d /tmp/ts-python-filter \
  --source manual-python3-size-filter \
  --max-age 30 \
  --max-size-kb 1
```

Expected result:

- `small.txt` is submitted.
- `large.bin` is skipped by the size filter.

### Python 2 repeat

When validating the Python 2 collector, repeat the above commands with:

```bash
python scripts/python/thunderstorm-collector-py2.py
```

Expected result:

- Behavior is equivalent where the Python 2 runtime and SSL stack support the requested operation.
- TLS issues on very old Python 2 runtimes should be documented as runtime limitations, not silently ignored.

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
