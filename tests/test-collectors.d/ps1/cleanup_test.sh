collector_cleanup() {
    if [ -n "$TEMP_SCRIPT_PATH" ] && [ -f "$TEMP_SCRIPT_PATH" ]; then
        $RM_CMD -f "$TEMP_SCRIPT_PATH"
        TEMP_SCRIPT_PATH=""
    fi
}
