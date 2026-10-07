# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="-s localhost -p PORT --dirs TESTDIR"
JQ_QUERY='.[0].response | fromjson | .id'
PATTERN='^[0-9]+$'
