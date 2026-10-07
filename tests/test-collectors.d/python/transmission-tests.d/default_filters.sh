# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: Python collector default filters skip .dat files and files older than 14 days
ARGS="-s localhost -p PORT --dirs TESTDIR"
EXPECTED_FILES=(
    "small-file.txt"
    "medium-file.log"
    "script.ps1"
    "executable.sh"
    "document.pdf"
    "subdir/nested-file.txt"
    "subdir/image.jpg"
    "excluded/skip-me.tmp"
)
UNEXPECTED_FILES=(
    "large-file.dat"
    "old-file.txt"
)
