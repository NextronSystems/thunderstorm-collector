# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: files in subdir/ skipped when exclude glob is set
ARGS="-s localhost --port PORT -p TESTDIR --exclude **/subdir/**"
EXPECTED_FILES=(
    "small-file.txt"
    "medium-file.log"
    "large-file.dat"
    "old-file.txt"
    "script.ps1"
    "executable.sh"
    "document.pdf"
    "excluded/skip-me.tmp"
)
UNEXPECTED_FILES=(
    "subdir/nested-file.txt"
    "subdir/image.jpg"
)
