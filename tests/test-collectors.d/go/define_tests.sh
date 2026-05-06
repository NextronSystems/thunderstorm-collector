# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154
# shellcheck disable=SC2034

COLLECTOR_NAME="Go"

# Note: The Go collector issues a GET /api/status health check before uploading,
# so jq queries must filter for checkAsync entries to skip the status request.
COLLECTOR_TESTS=(
    "basic_submission;-s localhost --port PORT -p TESTDIR;[.[] | select(.handler == \"CheckAsync\")] | .[0].response | fromjson | .id;^[0-9]+$"
    "source_param;-s localhost --port PORT -o test-device -p TESTDIR;[.[] | select(.handler == \"CheckAsync\")] | .[0].uri | capture(\"source=(?<src>[^&]*)\") | .src;^test-device$"
    "file_count;-s localhost --port PORT -p TESTDIR;[.[] | select(.handler == \"CheckAsync\")] | length;^[1-9][0-9]*$"
)
