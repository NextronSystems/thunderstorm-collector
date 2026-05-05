collector_setup() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.ps1)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.ps1" "$TEMP_SCRIPT_PATH"
}
