# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: only .txt files transmitted when extension filter is set
ARGS="-s localhost --port PORT -p TESTDIR -e .txt"
EXPECTED_FILES=(
    "small-file.txt"
    "old-file.txt"
    "subdir/nested-file.txt"
)
UNEXPECTED_FILES=(
    "medium-file.log"
    "large-file.dat"
    "script.ps1"
    "executable.sh"
    "document.pdf"
    "subdir/image.jpg"
    "excluded/skip-me.tmp"
)
