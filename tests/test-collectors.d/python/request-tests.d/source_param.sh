# shellcheck shell=bash
# shellcheck disable=SC2034
ARGS="-s localhost -p PORT -S test-host --dirs TESTDIR"
JQ_QUERY='.[0].uri | capture("source=(?<src>[^&]*)") | .src'
PATTERN='^test-host$'
