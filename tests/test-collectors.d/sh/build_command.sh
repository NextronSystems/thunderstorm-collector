collector_build_command() {
    local args=$1
    echo "$BASH_CMD \"$TEMP_SCRIPT_PATH\" $args"
}
