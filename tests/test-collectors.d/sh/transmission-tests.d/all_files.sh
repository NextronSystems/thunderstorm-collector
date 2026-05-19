# shellcheck shell=bash
# shellcheck disable=SC2034
# Test: all files transmitted (MAX_AGE=365, MAX_FILE_SIZE=20000 via setup_test.sh)
# Shell collector uses no CLI args; config is patched into the script by setup_test.sh
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
