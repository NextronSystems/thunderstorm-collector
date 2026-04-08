#!/usr/bin/env bash
#
# Focused regression tests for the Python 3 collector.
#
# Covers:
#   1. /proc/mounts escape decoding for excluded mount points
#   2. Multipart header building for undecodable POSIX filenames

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COLLECTOR="$REPO_ROOT/scripts/thunderstorm-collector.py"

PASS=0
FAIL=0
SKIP=0

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[1;33m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    BOLD=''
    RESET=''
fi

pass() {
    PASS=$((PASS + 1))
    printf "  %sPASS%s %s\n" "$GREEN" "$RESET" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "  %sFAIL%s %s\n" "$RED" "$RESET" "$1"
}

skip() {
    SKIP=$((SKIP + 1))
    printf "  %sSKIP%s %s\n" "$YELLOW" "$RESET" "$1"
}

run_python_case() {
    local name="$1"
    local code="$2"
    if ! command -v python3 >/dev/null 2>&1; then
        skip "$name: python3 not available"
        return 0
    fi
    if COLLECTOR_PATH="$COLLECTOR" python3 - <<'PY' "$code"; then
import importlib.util
import io
import os
import sys

collector_path = os.environ["COLLECTOR_PATH"]
code = sys.argv[1]

spec = importlib.util.spec_from_file_location("thunderstorm_collector_py3", collector_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

namespace = {"module": module, "io": io, "os": os}
exec(code, namespace, namespace)
PY
        pass "$name"
    else
        fail "$name"
    fi
}

printf "\n%sPython Regression Tests%s\n" "$BOLD" "$RESET"
printf "============================================\n"
printf " Collector: %s\n" "$COLLECTOR"
printf "============================================\n\n"

run_python_case \
    "python/mount-path-decode: escaped /proc/mounts entries are honored" \
    $'import builtins\norig_open = builtins.open\nsample = "server:/share /mnt/Remote\\\\040Share cifs rw 0 0\\n"\ndef fake_open(path, mode="r", *args, **kwargs):\n    if path == "/proc/mounts":\n        return io.StringIO(sample)\n    return orig_open(path, mode, *args, **kwargs)\nbuiltins.open = fake_open\ntry:\n    mounts = module.get_excluded_mounts()\nfinally:\n    builtins.open = orig_open\nassert mounts == ["/mnt/Remote Share"], mounts\nmodule.hard_skips[:] = mounts\nassert module.is_under_excluded("/mnt/Remote Share/secret.bin")'

run_python_case \
    "python/surrogate-filename: multipart preamble survives undecodable path bytes" \
    $'boundary = "boundary-test"\npreamble = module._build_multipart_preamble(boundary, "/tmp/bad_\\udcff.bin")\nassert b"boundary-test" in preamble\nassert b"bad_\\xff.bin" in preamble'

printf "\n============================================\n"
printf " Results: %s%d passed%s, %s%d failed%s, %s%d skipped%s\n" \
    "$GREEN" "$PASS" "$RESET" \
    "$RED" "$FAIL" "$RESET" \
    "$YELLOW" "$SKIP" "$RESET"
printf "============================================\n"

[ "$FAIL" -eq 0 ]
