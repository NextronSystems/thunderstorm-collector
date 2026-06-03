# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: synchronous upload transmits files correctly (hash in immediate response)
ARGS="-s localhost --port PORT -p TESTDIR -e .txt --upload-synchronous"
EXPECTED_FILES=(
    "small-file.txt"
    "old-file.txt"
    "subdir/nested-file.txt"
)
UNEXPECTED_FILES=(
    "medium-file.log"
    "large-file.dat"
)
