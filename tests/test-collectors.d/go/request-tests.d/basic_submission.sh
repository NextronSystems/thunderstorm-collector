# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="-s localhost --port PORT -p TESTDIR"
JQ_QUERY='[.[] | select(.handler == "CheckAsync")] | .[0].response | fromjson | .id'
PATTERN='^[0-9]+$'
