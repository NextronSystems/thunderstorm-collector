collector_cleanup() {
    if [ -n "$TEMP_SCRIPT_PATH" ] && [ -f "$TEMP_SCRIPT_PATH" ]; then
        $RM_CMD -f "$TEMP_SCRIPT_PATH"
        TEMP_SCRIPT_PATH=""
    fi
    if [ -n "$GO_TEMPLATE_PATH" ] && [ -f "$GO_TEMPLATE_PATH" ]; then
        $RM_CMD -f "$GO_TEMPLATE_PATH"
        GO_TEMPLATE_PATH=""
    fi
}
