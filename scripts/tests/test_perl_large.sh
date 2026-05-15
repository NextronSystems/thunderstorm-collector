#!/bin/bash
# Quick test for Perl large file detection
set -e

STUB_LOG="${STUB_LOG:-/tmp/perl-quick.jsonl}"
STUB_PORT="${STUB_PORT:-18097}"
STUB_BIN="${STUB_BIN_PATH:-/home/neo/.openclaw/workspace/projects/thunderstorm-stub-server/thunderstorm-stub}"
STUB_RULES="${STUB_RULES_DIR:-/home/neo/.openclaw/workspace/projects/thunderstorm-stub-server/rules}"
COLLECTOR_DIR="/home/neo/.openclaw/workspace/projects/thunderstorm-collector-pr/scripts"

# Start stub if not running
if ! curl -s "http://localhost:$STUB_PORT/api/info" >/dev/null 2>&1; then
    rm -f "$STUB_LOG"
    "$STUB_BIN" -port "$STUB_PORT" -rules-dir "$STUB_RULES" -log-file "$STUB_LOG" &
    sleep 2
fi

# Create fixture
FIXTURES=$(mktemp -d)
mkdir -p "$FIXTURES/large"
dd if=/dev/zero bs=1024 count=3072 2>/dev/null | tr '\0' 'A' > "$FIXTURES/large/big-perl.tmp"
echo "THUNDERSTORM_TEST_MATCH_STRING" >> "$FIXTURES/large/big-perl.tmp"

# Run Perl with large file
echo "Running Perl collector..."
perl "$COLLECTOR_DIR/thunderstorm-collector.pl" \
    -s localhost -p "$STUB_PORT" --dir "$FIXTURES/large" --max-age 30 --max-size-kb 4096 2>&1 | tail -3

# Give stub time to write
sleep 1

# Check log
echo "Checking log for big-perl.tmp..."
python3 -c "
import json
for line in open('$STUB_LOG'):
    d = json.loads(line.strip())
    cf = d.get('subject', {}).get('client_filename', '')
    if 'big-perl.tmp' in cf:
        print(f'FOUND: {cf}')
        print(f'Score: {d.get(\"score\", 0)}')
        exit(0)
print('NOT FOUND')
exit(1)
"

# Cleanup
rm -rf "$FIXTURES"