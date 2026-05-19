# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: Perl collector default filters skip .dat files and files older than 3 days
ARGS="--server localhost:PORT --dir TESTDIR"
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
