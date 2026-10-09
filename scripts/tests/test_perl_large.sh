#!/usr/bin/env bash
# Isolated large-payload check against an owned thunderstorm-stub-server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STUB_BIN="${STUB_BIN_PATH:-$REPO_ROOT/../thunderstorm-stub-server/thunderstorm-stub-server}"
COLLECTOR="$REPO_ROOT/scripts/perl/thunderstorm-collector.pl"
WORK_DIR="$(mktemp -d)"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
STUB_LOG="${STUB_LOG:-$WORK_DIR/audit.jsonl}"
STUB_PID=""

cleanup() {
    local result=$?
    trap - EXIT
    if [ -n "$STUB_PID" ]; then
        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
    fi
    if [ "$result" -ne 0 ] && [ -f "$WORK_DIR/stub.log" ]; then
        tail -20 "$WORK_DIR/stub.log" >&2
    fi
    rm -rf "$WORK_DIR"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -x "$STUB_BIN" ] || { echo "ERROR: set STUB_BIN_PATH to a runnable stub binary" >&2; exit 1; }
[ ! -e "$STUB_LOG" ] && [ ! -L "$STUB_LOG" ] || {
    echo "ERROR: STUB_LOG must be a new audit file, not an earlier run" >&2; exit 1;
}
STUB_PORT="${STUB_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
stub_args=(-port "$STUB_PORT" -log-file "$STUB_LOG" -uploads-dir "$WORK_DIR/uploads")
if [ -n "${STUB_RULES_DIR:-}" ]; then
    stub_args+=(-rules-dir "$STUB_RULES_DIR")
fi
"$STUB_BIN" "${stub_args[@]}" > "$WORK_DIR/stub.log" 2>&1 &
STUB_PID=$!
ready=0
for ((i=0; i<50; i++)); do
    sleep 0.1
    kill -0 "$STUB_PID" 2>/dev/null || break
    if curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$STUB_PORT/api/status" >/dev/null 2>&1 &&
        kill -0 "$STUB_PID" 2>/dev/null; then
        ready=1
        break
    fi
done
[ "$ready" -eq 1 ] || { echo "ERROR: owned stub failed to become ready" >&2; exit 1; }

mkdir "$WORK_DIR/samples"
fixture="$WORK_DIR/samples/big-perl-${WORK_DIR##*/}.tmp"
dd if=/dev/zero bs=1024 count=3072 2>/dev/null | tr '\0' 'A' > "$fixture"
printf 'THUNDERSTORM_TEST_MATCH_STRING\n' >> "$fixture"
source="perl-large-${WORK_DIR##*/}"
echo "Running Perl collector..."
# Sync makes the audit assertion independent of async worker scheduling.
perl "$COLLECTOR" -s 127.0.0.1 -p "$STUB_PORT" --dir "$WORK_DIR/samples" \
    --source "$source" --sync --max-age 0 --max-size-kb 4096 --retries 1 --no-progress 2>&1 | tail -3

python3 - "$STUB_LOG" "$fixture" "$source" <<'PY'
import hashlib
import json
import os
import re
import sys

log, fixture, source = sys.argv[1:]
with open(fixture, "rb") as stream:
    payload = stream.read()
# Go's multipart parser retains only the basename. Both it and the source are
# unique to this run; size and hash additionally verify the actual payload.
filename = os.path.basename(re.sub(r'[\\";\r\n\t\x00]', '_', fixture))
with open(log, encoding="utf-8") as stream:
    records = [json.loads(line) for line in stream if line.strip()]
matches = [entry["subject"] for entry in records
           if entry.get("subject", {}).get("client_filename") == filename
           and entry["subject"].get("source") == source]
if len(matches) != 1:
    raise SystemExit("FAIL: expected exactly one upload from this test run")
subject = matches[0]
if subject.get("size") != len(payload) or subject.get("hashes", {}).get("sha256") != hashlib.sha256(payload).hexdigest():
    raise SystemExit("FAIL: uploaded size or SHA-256 differs from the fixture")
print("PASS: current large-file upload has the exact expected size and SHA-256")
PY
