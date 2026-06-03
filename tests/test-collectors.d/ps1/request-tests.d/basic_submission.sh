# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="-ThunderstormServer localhost -ThunderstormPort PORT -Folder TESTDIR"
JQ_QUERY='.[0].response | fromjson | .id'
PATTERN='^[0-9]+$'
