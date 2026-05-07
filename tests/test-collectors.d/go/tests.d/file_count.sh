# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="-s localhost --port PORT -p TESTDIR"
JQ_QUERY='[.[] | select(.handler == "CheckAsync")] | length'
PATTERN='^[1-9][0-9]*$'
