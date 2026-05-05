collector_build_command() {
    local args=$1
    local script_path="${TEMP_SCRIPT_PATH:-$PROJECT_ROOT/scripts/thunderstorm-collector.pl}"
    echo "$PERL_CMD \"$script_path\" -- $args"
}
