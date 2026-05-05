collector_setup() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.pl)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.pl" "$TEMP_SCRIPT_PATH"
    $CHMOD_CMD +x "$TEMP_SCRIPT_PATH"
}
