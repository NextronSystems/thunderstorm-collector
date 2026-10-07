# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: all 10 test files are uploaded when no filters are applied
ARGS="-s localhost --port PORT -p TESTDIR"
JQ_QUERY='[.[] | select(.handler == "CheckAsync")] | length'
PATTERN='^10$'
