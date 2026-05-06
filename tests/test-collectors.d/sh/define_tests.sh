# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154
# shellcheck disable=SC2034

COLLECTOR_NAME="Shell"

COLLECTOR_TESTS=(
    "basic_submission;;.[0].response | fromjson | .id;^[0-9]+$"
    "file_count;;length;^[1-9][0-9]*$"
)
