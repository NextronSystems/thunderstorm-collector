# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: Batch collector RELEVANT_EXTENSIONS filter skips .dat, .sh, .pdf, .jpg
ARGS=""
EXPECTED_FILES=(
    "small-file.txt"
    "medium-file.log"
    "old-file.txt"
    "script.ps1"
    "subdir/nested-file.txt"
    "excluded/skip-me.tmp"
)
UNEXPECTED_FILES=(
    "large-file.dat"
    "executable.sh"
    "document.pdf"
    "subdir/image.jpg"
)
