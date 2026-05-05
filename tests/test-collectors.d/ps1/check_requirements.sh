collector_check_requirements() {
    if ! command -v $PWSH_CMD >/dev/null 2>&1; then
        echo "ERROR: PowerShell interpreter not found ($PWSH_CMD)"
        if [ "$PLATFORM" = "linux" ]; then
            echo "Install PowerShell Core: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
        fi
        return 1
    fi
}
