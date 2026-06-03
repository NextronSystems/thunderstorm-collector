# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="--server localhost --port PORT --source test-client --dir TESTDIR"
JQ_QUERY='.[0].uri | capture("source=(?<src>[^&]*)") | .src'
PATTERN='^test-client$'
