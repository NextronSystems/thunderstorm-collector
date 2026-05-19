# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: PowerShell collector default Extensions filter skips .dat, .sh, .jpg
ARGS="-ThunderstormServer localhost -ThunderstormPort PORT -Folder TESTDIR"
EXPECTED_FILES=(
    "small-file.txt"
    "medium-file.log"
    "old-file.txt"
    "script.ps1"
    "document.pdf"
    "subdir/nested-file.txt"
    "excluded/skip-me.tmp"
)
UNEXPECTED_FILES=(
    "large-file.dat"
    "executable.sh"
    "subdir/image.jpg"
)
