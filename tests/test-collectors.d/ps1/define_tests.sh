# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154
# shellcheck disable=SC2034

COLLECTOR_NAME="PowerShell"

COLLECTOR_TESTS=(
    "basic_submission;-ThunderstormServer localhost -ThunderstormPort PORT -Folder TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
    "file_count;-ThunderstormServer localhost -ThunderstormPort PORT -Folder TESTDIR;length;^[1-9][0-9]*$"
)
