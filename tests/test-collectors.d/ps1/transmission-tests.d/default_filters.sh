# shellcheck shell=bash
# shellcheck disable=SC2034
# Isolate extension filtering; mtime age selection has its own regressions.
ARGS="-ThunderstormServer localhost -ThunderstormPort PORT -Folder TESTDIR -MaxAge 0"
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
