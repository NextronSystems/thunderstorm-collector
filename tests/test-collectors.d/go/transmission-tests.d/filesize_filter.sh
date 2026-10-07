# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: large file skipped when filesize limit is set to 1 MB
ARGS="-s localhost --port PORT -p TESTDIR -m 1"
EXPECTED_FILES=(
    "small-file.txt"
    "medium-file.log"
    "old-file.txt"
    "script.ps1"
    "executable.sh"
    "document.pdf"
    "subdir/nested-file.txt"
    "subdir/image.jpg"
    "excluded/skip-me.tmp"
)
UNEXPECTED_FILES=(
    "large-file.dat"
)
