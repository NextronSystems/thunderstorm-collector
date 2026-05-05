collector_setup() {
    TEMP_SCRIPT_PATH=$($MKTEMP_CMD --suffix=.sh)
    $CP_CMD "$PROJECT_ROOT/scripts/thunderstorm-collector.sh" "$TEMP_SCRIPT_PATH"

    # Modify variables for testing
    sed_inplace "s/THUNDERSTORM_SERVER=.*/THUNDERSTORM_SERVER=\"localhost\"/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/THUNDERSTORM_PORT=.*/THUNDERSTORM_PORT=$MOCK_PORT/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s|declare -a SCAN_FOLDERS=.*|declare -a SCAN_FOLDERS=('$TEST_DATA_DIR')|" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/DEBUG=.*/DEBUG=0/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/MAX_AGE=.*/MAX_AGE=365/" "$TEMP_SCRIPT_PATH"
    sed_inplace "s/MAX_FILE_SIZE=.*/MAX_FILE_SIZE=20000/" "$TEMP_SCRIPT_PATH"

    $CHMOD_CMD +x "$TEMP_SCRIPT_PATH"
}
