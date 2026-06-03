# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: all files transmitted correctly with no filters applied
ARGS="-s localhost --port PORT -p TESTDIR"
EXPECTED_FILES=(
    "small-file.txt"
    "medium-file.log"
    "large-file.dat"
    "old-file.txt"
    "script.ps1"
    "executable.sh"
    "document.pdf"
    "subdir/nested-file.txt"
    "subdir/image.jpg"
    "excluded/skip-me.tmp"
)
UNEXPECTED_FILES=()
