# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: all fixture files transmitted (filters configured via build_command.sh)
ARGS=""
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
