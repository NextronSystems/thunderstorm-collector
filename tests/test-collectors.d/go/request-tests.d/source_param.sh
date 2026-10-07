# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="-s localhost --port PORT -o test-device -p TESTDIR"
JQ_QUERY='[.[] | select(.handler == "CheckAsync")] | .[0].uri | capture("source=(?<src>[^&]*)") | .src'
PATTERN='^test-device$'
