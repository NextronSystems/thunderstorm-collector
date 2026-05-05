collector_build_command() {
    local args=$1
    local script_path="${TEMP_SCRIPT_PATH:-$PROJECT_ROOT/scripts/thunderstorm-collector.py}"
    echo "$PYTHON_CMD \"$script_path\" $args"
}
