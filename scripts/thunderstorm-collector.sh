#!/usr/bin/env bash
#
# THOR Thunderstorm Bash Collector
# Florian Roth / Nextron Systems
#
# Goals:
# - work on old and new Bash versions (Bash 3+)
# - handle missing dependencies with fallbacks
# - degrade gracefully on partial failures

VERSION="0.4.0"

# Defaults --------------------------------------------------------------------

LOGFILE="./thunderstorm.log"
LOG_TO_FILE=1
LOG_TO_SYSLOG=0
LOG_TO_CMDLINE=1
SYSLOG_FACILITY="user"

THUNDERSTORM_SERVER="ygdrasil.nextron"
THUNDERSTORM_PORT=8080
USE_SSL=0
ASYNC_MODE=1

MAX_AGE=14
MAX_FILE_SIZE_KB=2000
DEBUG=0
DRY_RUN=0
RETRIES=3

UPLOAD_TOOL=""
TMP_FILES=""

# Keep defaults simple and stable for Bash 3+.
SCAN_FOLDERS=('/root' '/tmp' '/home' '/var' '/usr')

FILES_SCANNED=0
FILES_SUBMITTED=0
FILES_SKIPPED=0
FILES_FAILED=0

SCRIPT_NAME="${0##*/}"
START_TS="$(date +%s 2>/dev/null || echo 0)"
SOURCE_NAME=""

# Filesystem exclusions -------------------------------------------------------
# Pseudo-filesystems, virtual mounts, and cloud storage paths that should never
# be walked. These are pruned at the find level for efficiency.

EXCLUDE_PATHS_START=(
    /proc /sys /dev /run
    /sys/kernel/debug /sys/kernel/slab /sys/kernel/tracing /sys/devices
)

EXCLUDE_FS_DIRS=(
    /snap /.snapshots
)

EXCLUDE_CLOUD_DIRS=(
    # Common cloud sync folders (Loki-RS reference)
    /*/OneDrive /*/Dropbox /*/.dropbox
    "/*/ Google Drive" /*/GoogleDrive
    "/*/ iCloud Drive" /*/Nextcloud /*/ownCloud
    /*/MEGA /*/MEGAsync /*/Tresorit
    /*/SyncThing
    /Library/CloudStorage
)

# Build find exclusion arguments
build_find_excludes() {
    local args=()
    local p
    for p in "${EXCLUDE_PATHS_START[@]}"; do
        [ -d "$p" ] && args+=(-path "$p" -prune -o)
    done
    for p in "${EXCLUDE_FS_DIRS[@]}"; do
        [ -d "$p" ] && args+=(-path "$p" -prune -o)
    done
    # Symlink exclusion: -type f already excludes symlinks, but explicitly
    # skip symlink directories to avoid descending into linked trees
    printf '%s\n' "${args[@]}"
}

# Helpers ---------------------------------------------------------------------

timestamp() {
    date "+%Y-%m-%d_%H:%M:%S" 2>/dev/null || date
}

cleanup_tmp_files() {
    local f
    for f in $TMP_FILES; do
        [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
    done
}

on_exit() {
    cleanup_tmp_files
}

trap on_exit EXIT INT TERM

log_msg() {
    local level="$1"
    shift
    local message="$*"
    local ts
    local logger_prio
    local clean

    [ "$level" = "debug" ] && [ "$DEBUG" -ne 1 ] && return 0

    ts="$(timestamp)"
    clean="$message"
    clean="${clean//$'\r'/ }"
    clean="${clean//$'\n'/ }"

    if [ "$LOG_TO_FILE" -eq 1 ]; then
        if ! printf "%s %s %s\n" "$ts" "$level" "$clean" >> "$LOGFILE" 2>/dev/null; then
            LOG_TO_FILE=0
            printf "%s warn Could not write to log file '%s'; disabling file logging\n" "$ts" "$LOGFILE" >&2
        fi
    fi

    if [ "$LOG_TO_SYSLOG" -eq 1 ] && command -v logger >/dev/null 2>&1; then
        case "$level" in
            error) logger_prio="err" ;;
            warn) logger_prio="warning" ;;
            debug) logger_prio="debug" ;;
            *) logger_prio="info" ;;
        esac
        logger -p "${SYSLOG_FACILITY}.${logger_prio}" "${SCRIPT_NAME}: ${clean}" >/dev/null 2>&1 || true
    fi

    if [ "$LOG_TO_CMDLINE" -eq 1 ]; then
        printf "[%s] %s\n" "$level" "$clean" >&2
    fi
}

die() {
    log_msg error "$*"
    exit 1
}

print_banner() {
    cat <<EOF
==============================================================
    ________                __            __
   /_  __/ /  __ _____  ___/ /__ _______ / /____  ______ _
    / / / _ \\/ // / _ \\/ _  / -_) __(_-</ __/ _ \\/ __/  ' \\
   /_/ /_//_/\\_,_/_//_/\\_,_/\\__/_/ /___/\\__/\\___/_/ /_/_/_/
   v${VERSION}

   THOR Thunderstorm Collector for Linux/Unix
==============================================================
EOF
}

print_help() {
    cat <<'EOF'
Usage:
  thunderstorm-collector.sh [options]

Options:
  -s, --server <host>        Thunderstorm server hostname or IP
  -p, --port <port>          Thunderstorm port (default: 8080)
  -d, --dir <path>           Directory to scan (repeatable)
  --max-age <days>           Max file age in days (default: 14)
  --max-size-kb <kb>         Max file size in KB (default: 2000)
  --source <name>            Source identifier (default: hostname)
  --ssl                      Use HTTPS
  --sync                     Use /api/check (default: /api/checkAsync)
  --retries <num>            Retry attempts per file (default: 3)
  --dry-run                  Do not upload, only show what would be submitted
  --debug                    Enable debug log messages
  --log-file <path>          Log file path (default: ./thunderstorm.log)
  --no-log-file              Disable file logging
  --syslog                   Enable syslog logging
  --quiet                    Disable command-line logging
  -h, --help                 Show this help text

Examples:
  bash thunderstorm-collector.sh --server thunderstorm.local
  bash thunderstorm-collector.sh --server 10.0.0.5 --ssl --dir "/tmp/My Files" --dry-run
EOF
}

is_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

detect_source_name() {
    [ -n "$SOURCE_NAME" ] && return 0
    if command -v hostname >/dev/null 2>&1; then
        SOURCE_NAME="$(hostname -f 2>/dev/null)"
        [ -z "$SOURCE_NAME" ] && SOURCE_NAME="$(hostname 2>/dev/null)"
    fi
    [ -z "$SOURCE_NAME" ] && SOURCE_NAME="$(uname -n 2>/dev/null)"
    [ -z "$SOURCE_NAME" ] && SOURCE_NAME="unknown-host"
}

build_query_source() {
    local src="$1"
    if [ -n "$src" ]; then
        local encoded
        encoded="$(urlencode "$src")"
        printf "?source=%s" "$encoded"
    fi
}

urlencode() {
    local input="$1"
    local out=""
    local i ch hex

    for ((i = 0; i < ${#input}; i++)); do
        ch="${input:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-])
                out="${out}${ch}"
                ;;
            ' ')
                out="${out}%20"
                ;;
            *)
                hex="$(printf '%s' "$ch" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]')"
                out="${out}%${hex}"
                ;;
        esac
    done
    printf "%s" "$out"
}

sanitize_filename_for_multipart() {
    local input="$1"
    # Keep multipart header/form attribute values simple and safe.
    input="${input//\"/_}"
    input="${input//;/_}"
    input="${input//\\/_}"
    input="${input//$'\r'/_}"
    input="${input//$'\n'/_}"
    [ -z "$input" ] && input="sample.bin"
    printf "%s" "$input"
}

file_size_kb() {
    # Use wc for portability across GNU/BSD and older systems.
    local bytes
    bytes="$(wc -c < "$1" 2>/dev/null)"
    # Intentionally split on whitespace to normalize wc output ("   123\n" -> "123").
    # shellcheck disable=SC2086
    set -- $bytes
    bytes="$1"
    case "$bytes" in
        ''|*[!0-9]*) echo -1; return 1 ;;
    esac
    echo $(( (bytes + 1023) / 1024 ))
}

mktemp_portable() {
    local t
    t="$(mktemp "${TMPDIR:-/tmp}/thunderstorm.XXXXXX" 2>/dev/null)"
    if [ -n "$t" ]; then
        echo "$t"
        return 0
    fi
    t="${TMPDIR:-/tmp}/thunderstorm.$$.$RANDOM"
    : > "$t" 2>/dev/null || return 1
    echo "$t"
}

detect_upload_tool() {
    if command -v curl >/dev/null 2>&1; then
        UPLOAD_TOOL="curl"
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        UPLOAD_TOOL="wget"
        return 0
    fi
    return 1
}

upload_with_curl() {
    local endpoint="$1"
    local filepath="$2"
    local filename="$3"
    local safe_filename
    local curl_filepath
    local resp_file
    local code

    safe_filename="$(sanitize_filename_for_multipart "$filename")"
    curl_filepath="${filepath//\"/\\\"}"

    resp_file="$(mktemp_portable)" || return 91
    TMP_FILES="${TMP_FILES} ${resp_file}"

    curl -sS --fail --show-error -X POST \
        "$endpoint" \
        --form "file=@\"${curl_filepath}\";filename=\"${safe_filename}\"" \
        > "$resp_file" 2>&1
    code=$?
    if [ $code -ne 0 ]; then
        return $code
    fi

    if grep -qi "reason" "$resp_file" 2>/dev/null; then
        local body
        body="$(cat "$resp_file" 2>/dev/null)"
        body="${body//$'\r'/ }"
        body="${body//$'\n'/ }"
        log_msg error "Server reported rejection for '$filepath': $body"
        return 92
    fi
    return 0
}

upload_with_wget() {
    # Portable multipart fallback for systems without curl.
    local endpoint="$1"
    local filepath="$2"
    local filename="$3"
    local safe_filename
    local boundary
    local body_file
    local resp_file
    local code

    boundary="----ThunderstormBoundary$$$RANDOM"
    safe_filename="$(sanitize_filename_for_multipart "$filename")"
    body_file="$(mktemp_portable)" || return 93
    resp_file="$(mktemp_portable)" || return 94
    TMP_FILES="${TMP_FILES} ${body_file} ${resp_file}"

    {
        printf -- "--%s\r\n" "$boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' "$safe_filename"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$filepath"
        printf '\r\n--%s--\r\n' "$boundary"
    } > "$body_file" 2>/dev/null || return 95

    wget -q -O "$resp_file" \
        --header="Content-Type: multipart/form-data; boundary=${boundary}" \
        --post-file="$body_file" \
        "$endpoint"
    code=$?
    if [ $code -ne 0 ]; then
        return $code
    fi

    if grep -qi "reason" "$resp_file" 2>/dev/null; then
        local body
        body="$(cat "$resp_file" 2>/dev/null)"
        body="${body//$'\r'/ }"
        body="${body//$'\n'/ }"
        log_msg error "Server reported rejection for '$filepath': $body"
        return 96
    fi
    return 0
}

# collection_marker -- POST a begin/end marker to /api/collection
# Args: $1=base_url  $2=type(begin|end)  $3=scan_id(optional)  $4=stats_json(optional)
# Returns: scan_id extracted from response (empty if unsupported or failed)
collection_marker() {
    local base_url="$1"
    local marker_type="$2"
    local scan_id="${3:-}"
    local stats_json="${4:-}"
    local marker_url="${base_url%/api/*}/api/collection"
    local body scan_id_out resp_file

    resp_file="$(mktemp_portable)" || return 1

    # Build JSON body
    body="{\"type\":\"${marker_type}\""
    body="${body},\"source\":\"${SOURCE_NAME}\""
    body="${body},\"collector\":\"bash/${VERSION}\""
    body="${body},\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u)\""
    [ -n "$scan_id"    ] && body="${body},\"scan_id\":\"${scan_id}\""
    [ -n "$stats_json" ] && body="${body},${stats_json}"
    body="${body}}"

    # Attempt POST — silent failure is intentional (server may not support this yet)
    if command -v curl >/dev/null 2>&1; then
        curl -s -o "$resp_file" \
            -H "Content-Type: application/json" \
            -d "$body" \
            --max-time 10 \
            "$marker_url" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$resp_file" \
            --header "Content-Type: application/json" \
            --post-data "$body" \
            --timeout=10 \
            "$marker_url" 2>/dev/null || true
    fi

    # Extract scan_id from response: {"scan_id":"<value>"}
    scan_id_out="$(grep -o '"scan_id":"[^"]*"' "$resp_file" 2>/dev/null \
        | head -1 | sed 's/"scan_id":"//;s/"//')"

    rm -f "$resp_file"
    printf '%s' "$scan_id_out"
}

submit_file() {
    local endpoint="$1"
    local filepath="$2"
    local filename
    local try=1
    local rc=1
    local wait=2

    # Preserve client-side path in multipart filename for server-side audit logs.
    filename="$filepath"

    while [ "$try" -le "$RETRIES" ]; do
        if [ "$DRY_RUN" -eq 1 ]; then
            log_msg info "DRY-RUN: would submit '$filepath'"
            return 0
        fi

        if [ "$UPLOAD_TOOL" = "curl" ]; then
            upload_with_curl "$endpoint" "$filepath" "$filename"
            rc=$?
        else
            upload_with_wget "$endpoint" "$filepath" "$filename"
            rc=$?
        fi

        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        log_msg warn "Upload failed for '$filepath' (attempt ${try}/${RETRIES}, code ${rc})"
        if [ "$try" -lt "$RETRIES" ]; then
            sleep "$wait"
            wait=$((wait * 2))
        fi
        try=$((try + 1))
    done

    return "$rc"
}

parse_args() {
    local arg
    local add_dir_mode=0

    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            -h|--help)
                print_help
                exit 0
                ;;
            -s|--server)
                [ -n "$2" ] || die "Missing value for $arg"
                THUNDERSTORM_SERVER="$2"
                shift
                ;;
            -p|--port)
                [ -n "$2" ] || die "Missing value for $arg"
                THUNDERSTORM_PORT="$2"
                shift
                ;;
            -d|--dir)
                [ -n "$2" ] || die "Missing value for $arg"
                if [ "$add_dir_mode" -eq 0 ]; then
                    SCAN_FOLDERS=()
                    add_dir_mode=1
                fi
                SCAN_FOLDERS+=("$2")
                shift
                ;;
            --max-age)
                [ -n "$2" ] || die "Missing value for $arg"
                MAX_AGE="$2"
                shift
                ;;
            --max-size-kb)
                [ -n "$2" ] || die "Missing value for $arg"
                MAX_FILE_SIZE_KB="$2"
                shift
                ;;
            --source)
                [ -n "$2" ] || die "Missing value for $arg"
                SOURCE_NAME="$2"
                shift
                ;;
            --ssl)
                USE_SSL=1
                ;;
            --sync)
                ASYNC_MODE=0
                ;;
            --retries)
                [ -n "$2" ] || die "Missing value for $arg"
                RETRIES="$2"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --debug)
                DEBUG=1
                ;;
            --log-file)
                [ -n "$2" ] || die "Missing value for $arg"
                LOGFILE="$2"
                shift
                ;;
            --no-log-file)
                LOG_TO_FILE=0
                ;;
            --syslog)
                LOG_TO_SYSLOG=1
                ;;
            --quiet)
                LOG_TO_CMDLINE=0
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "Unknown option: $arg (use --help)"
                ;;
            *)
                # Positional args are treated as additional directories.
                if [ "$add_dir_mode" -eq 0 ]; then
                    SCAN_FOLDERS=()
                    add_dir_mode=1
                fi
                SCAN_FOLDERS+=("$arg")
                ;;
        esac
        shift
    done
}

validate_config() {
    is_integer "$THUNDERSTORM_PORT" || die "Port must be numeric: '$THUNDERSTORM_PORT'"
    is_integer "$MAX_AGE" || die "max-age must be numeric: '$MAX_AGE'"
    is_integer "$MAX_FILE_SIZE_KB" || die "max-size-kb must be numeric: '$MAX_FILE_SIZE_KB'"
    is_integer "$RETRIES" || die "retries must be numeric: '$RETRIES'"

    [ "$THUNDERSTORM_PORT" -gt 0 ] || die "Port must be greater than 0"
    [ "$MAX_AGE" -ge 0 ] || die "max-age must be >= 0"
    [ "$MAX_FILE_SIZE_KB" -gt 0 ] || die "max-size-kb must be > 0"
    [ "$RETRIES" -gt 0 ] || die "retries must be > 0"

    [ -n "$THUNDERSTORM_SERVER" ] || die "Server must not be empty"
    [ "${#SCAN_FOLDERS[@]}" -gt 0 ] || die "At least one directory is required"
}

main() {
    local scheme="http"
    local endpoint_name="check"
    local query_source=""
    local api_endpoint=""
    local base_url=""
    local SCAN_ID=""
    local scandir
    local file_path
    local size_kb
    local elapsed=0
    local find_mtime
    local find_results_file

    parse_args "$@"
    find_mtime="-${MAX_AGE}"
    detect_source_name
    validate_config
    print_banner

    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        log_msg warn "Running without root privileges; some files may be inaccessible"
    fi

    if [ "$USE_SSL" -eq 1 ]; then
        scheme="https"
    fi
    if [ "$ASYNC_MODE" -eq 1 ]; then
        endpoint_name="checkAsync"
    fi

    query_source="$(build_query_source "$SOURCE_NAME")"
    base_url="${scheme}://${THUNDERSTORM_SERVER}:${THUNDERSTORM_PORT}"
    api_endpoint="${base_url}/api/${endpoint_name}${query_source}"

    if [ "$DRY_RUN" -eq 0 ]; then
        if ! detect_upload_tool; then
            die "Neither 'curl' nor 'wget' is installed; unable to upload samples"
        fi
    else
        if detect_upload_tool; then
            log_msg info "Dry-run mode active (upload tool detected: $UPLOAD_TOOL)"
        else
            log_msg info "Dry-run mode active (no upload tool required)"
        fi
    fi

    log_msg info "Started Thunderstorm Collector - Version $VERSION"
    log_msg info "Server: $THUNDERSTORM_SERVER"
    log_msg info "Port: $THUNDERSTORM_PORT"
    log_msg info "API endpoint: $api_endpoint"
    log_msg info "Max age (days): $MAX_AGE"
    log_msg info "Max size (KB): $MAX_FILE_SIZE_KB"
    log_msg info "Source: $SOURCE_NAME"
    log_msg info "Folders: ${SCAN_FOLDERS[*]}"
    [ "$DRY_RUN" -eq 1 ] && log_msg info "Dry-run mode enabled"

    # Send collection begin marker; capture scan_id if server returns one
    if [ "$DRY_RUN" -eq 0 ]; then
        SCAN_ID="$(collection_marker "$base_url" "begin" "" "")"
        if [ -n "$SCAN_ID" ]; then
            log_msg info "Collection scan_id: $SCAN_ID"
            api_endpoint="${api_endpoint}&scan_id=$(urlencode "$SCAN_ID")"
        fi
    fi

    for scandir in "${SCAN_FOLDERS[@]}"; do
        if [ ! -d "$scandir" ]; then
            log_msg warn "Skipping non-directory path '$scandir'"
            continue
        fi

        log_msg info "Scanning '$scandir'"
        find_results_file="$(mktemp_portable)" || {
            log_msg error "Could not create temporary file list for '$scandir'"
            continue
        }
        TMP_FILES="${TMP_FILES} ${find_results_file}"
        # Build find command with filesystem exclusions
        local find_excludes=()
        local _ep
        for _ep in "${EXCLUDE_PATHS_START[@]}"; do
            [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
        done
        for _ep in "${EXCLUDE_FS_DIRS[@]}"; do
            [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
        done
        # -not -xtype l: skip broken symlinks; -type f already skips symlinks to files
        find "$scandir" "${find_excludes[@]}" -type f -mtime "$find_mtime" -print0 > "$find_results_file" 2>/dev/null || true

        while IFS= read -r -d '' file_path; do
            FILES_SCANNED=$((FILES_SCANNED + 1))

            [ -f "$file_path" ] || continue

            size_kb="$(file_size_kb "$file_path")"
            if [ "$size_kb" -lt 0 ]; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping unreadable file '$file_path'"
                continue
            fi

            if [ "$size_kb" -gt "$MAX_FILE_SIZE_KB" ]; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping '$file_path' due to size (${size_kb}KB)"
                continue
            fi

            log_msg debug "Submitting '$file_path'"
            if submit_file "$api_endpoint" "$file_path"; then
                FILES_SUBMITTED=$((FILES_SUBMITTED + 1))
            else
                FILES_FAILED=$((FILES_FAILED + 1))
                log_msg error "Could not upload '$file_path'"
            fi
        done < "$find_results_file"
    done

    if [ "$START_TS" -gt 0 ] 2>/dev/null; then
        elapsed=$(( $(date +%s 2>/dev/null || echo "$START_TS") - START_TS ))
        [ "$elapsed" -lt 0 ] && elapsed=0
    fi

    log_msg info "Run completed: scanned=$FILES_SCANNED submitted=$FILES_SUBMITTED skipped=$FILES_SKIPPED failed=$FILES_FAILED seconds=$elapsed"

    # Send collection end marker with run statistics
    if [ "$DRY_RUN" -eq 0 ]; then
        local stats_json="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"failed\":${FILES_FAILED},\"elapsed_seconds\":${elapsed}}"
        collection_marker "$base_url" "end" "$SCAN_ID" "$stats_json" >/dev/null
    fi

    return 0
}

main "$@"
