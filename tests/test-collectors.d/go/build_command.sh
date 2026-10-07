# shellcheck shell=bash
# Sourced by test-single.sh
# shellcheck disable=SC2154

collector_build_command() {
    local args="$1"
    echo "\"${GO_BINARY_PATH}\" --template \"${GO_TEMPLATE_PATH}\" ${args}"
}
