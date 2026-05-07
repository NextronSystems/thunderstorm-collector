# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="--server localhost:PORT --dir TESTDIR"
JQ_QUERY='.[0].response | fromjson | .id'
PATTERN='^[0-9]+$'
