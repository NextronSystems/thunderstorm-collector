collector_build_command() {
    local args=$1
    local script_path="${TEMP_SCRIPT_PATH:-$PROJECT_ROOT/scripts/thunderstorm-collector.ps1}"
    local ps1_path
    ps1_path=$(to_native_path "$script_path")
    echo "$PWSH_CMD -ExecutionPolicy Bypass -File \"$ps1_path\" $args"
}
