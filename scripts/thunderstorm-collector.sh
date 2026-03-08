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

LOGFILE=""
LOG_TO_FILE=0
LOG_TO_SYSLOG=0
LOG_TO_CMDLINE=1
SYSLOG_FACILITY="user"

THUNDERSTORM_SERVER="ygdrasil.nextron"
THUNDERSTORM_PORT=8080
USE_SSL=0
INSECURE=0
CA_CERT=""
ASYNC_MODE=1

MAX_AGE=14
MAX_FILE_SIZE_KB=2000
DEBUG=0
DRY_RUN=0
RETRIES=3

UPLOAD_TOOL=""
CURL_OPTS=()       # TLS-related curl options (-k, --cacert)
WGET_TLS_OPTS=()   # TLS-related wget options (--no-check-certificate, --ca-certificate)
TMP_FILES=()

# Keep defaults simple and stable for Bash 3+.
SCAN_FOLDERS=('/root' '/tmp' '/home' '/var' '/usr')

FILES_SCANNED=0
FILES_SUBMITTED=0
FILES_SKIPPED=0
FILES_FAILED=0
FILES_TOTAL=0

# Progress reporting: auto-detect TTY, overridable with --progress/--no-progress
# 0=off, 1=on, ""=auto (detect TTY)
PROGRESS=""
PROGRESS_INTERVAL=100      # report every N files
PROGRESS_LAST_TIME=0       # last progress timestamp (epoch)
PROGRESS_TIME_INTERVAL=10  # also report if N seconds elapsed

SCRIPT_NAME="${0##*/}"
START_TS="$(date +%s 2>/dev/null || echo 0)"
SOURCE_NAME=""

# Filesystem exclusions -------------------------------------------------------
# Pseudo-filesystems, virtual mounts, network shares, and cloud storage that
# should never be walked. Pruned at the find level for efficiency.

# Hardcoded paths — always excluded
EXCLUDE_PATHS=(
    /proc /sys /dev /run
    /sys/kernel/debug /sys/kernel/slab /sys/kernel/tracing /sys/devices
    /snap /.snapshots
)

# Network and special filesystem types — mount points with these types are
# discovered from /proc/mounts and excluded automatically.
NETWORK_FS_TYPES="nfs nfs4 cifs smbfs smb3 sshfs fuse.sshfs afp webdav davfs2 fuse.rclone fuse.s3fs"
SPECIAL_FS_TYPES="proc procfs sysfs devtmpfs devpts cgroup cgroup2 pstore bpf tracefs debugfs securityfs hugetlbfs mqueue autofs fusectl rpc_pipefs nsfs configfs binfmt_misc selinuxfs efivarfs ramfs"

# Cloud storage folder names — if any path segment matches (case-insensitive),
# the directory is pruned. Covers OneDrive, Dropbox, Google Drive, iCloud,
# Nextcloud, ownCloud, MEGA, Tresorit, Syncthing.
CLOUD_DIR_NAMES=("OneDrive" "Dropbox" ".dropbox" "GoogleDrive" "Google Drive" "iCloud Drive" "iCloudDrive" "Nextcloud" "ownCloud" "MEGA" "MEGAsync" "Tresorit" "SyncThing")

# get_excluded_mounts: parse /proc/mounts and return mount points for
# network and special filesystem types (one per line).
get_excluded_mounts() {
    [ -r /proc/mounts ] || return 0
    # Use awk to reliably extract field 2 (mount point) and field 3 (fs type).
    # /proc/mounts escapes spaces in mount points as \040, so this handles them
    # correctly. We unescape \040 back to literal spaces for the path.
    local _fs_pattern
    _fs_pattern="$(printf '%s|' $NETWORK_FS_TYPES $SPECIAL_FS_TYPES)"
    _fs_pattern="${_fs_pattern%|}"  # strip trailing |
    awk -v pat="$_fs_pattern" '
        BEGIN { split(pat, types, "|"); for (i in types) typeset[types[i]]=1 }
        $3 in typeset {
            mp = $2
            gsub(/\\040/, " ", mp)
            print mp
        }
    ' /proc/mounts
}

# is_cloud_path: check if a path contains a known cloud storage folder name.
# Returns 0 (true) if it matches, 1 (false) otherwise.
is_cloud_path() {
    local path_lower
    path_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local name name_lower
    for name in "${CLOUD_DIR_NAMES[@]}"; do
        name_lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        case "$path_lower" in
            *"/$name_lower"/*|*"/$name_lower") return 0 ;;
        esac
    done
    # macOS: ~/Library/CloudStorage
    case "$path_lower" in
        */library/cloudstorage/*|*/library/cloudstorage) return 0 ;;
    esac
    return 1
}

# Helpers ---------------------------------------------------------------------

timestamp() {
    date "+%Y-%m-%d_%H:%M:%S" 2>/dev/null || date
}

cleanup_tmp_files() {
    local f
    for f in "${TMP_FILES[@]}"; do
        [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
    done
}

# Signal handling: send "interrupted" marker before exiting
INTERRUPTED_SIGNAL=""

on_signal() {
    local sig="$1"
    INTERRUPTED_SIGNAL="$sig"
    # Send interrupted marker if we have a scan_id and a server
    if [ -n "$SCAN_ID" ] && [ -n "$THUNDERSTORM_SERVER" ] && [ "$DRY_RUN" -eq 0 ] 2>/dev/null; then
        local elapsed=0
        if [ "$START_TS" -gt 0 ] 2>/dev/null; then
            elapsed=$(( $(date +%s 2>/dev/null || echo "$START_TS") - START_TS ))
            [ "$elapsed" -lt 0 ] && elapsed=0
        fi
        local stats_json="\"stats\":{\"scanned\":${FILES_SCANNED:-0},\"submitted\":${FILES_SUBMITTED:-0},\"skipped\":${FILES_SKIPPED:-0},\"failed\":${FILES_FAILED:-0},\"elapsed_seconds\":${elapsed}}"
        local reason_json="\"reason\":\"signal\""
        local _scheme="http"
        [ "$USE_SSL" -eq 1 ] 2>/dev/null && _scheme="https"
        local base_url="${_scheme}://${THUNDERSTORM_SERVER}:${THUNDERSTORM_PORT}"
        collection_marker "$base_url" "interrupted" "$SCAN_ID" "${stats_json},${reason_json}" >/dev/null 2>&1
    fi
    cleanup_tmp_files
    # Exit with 128 + signal number (SIGINT=2→130, SIGTERM=15→143)
    case "$sig" in
        INT)  exit 130 ;;
        TERM) exit 143 ;;
        *)    exit 1 ;;
    esac
}

on_exit() {
    # Only clean up if not already handled by signal handler
    if [ -z "$INTERRUPTED_SIGNAL" ]; then
        cleanup_tmp_files
    fi
}

trap on_exit EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

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
    exit 2
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
  -k, --insecure             Skip TLS certificate verification
  --ca-cert FILE             Custom CA certificate bundle for TLS verification
  --sync                     Use /api/check (default: /api/checkAsync)
  --retries <num>            Retry attempts per file (default: 3)
  --dry-run                  Do not upload, only show what would be submitted
  --debug                    Enable debug log messages
  --progress                 Force progress reporting on
  --no-progress              Force progress reporting off
  --log-file <path>          Log file path (enables file logging; default: none)
  --no-log-file              Disable file logging
  --syslog                   Enable syslog logging
  --quiet                    Disable command-line logging
  -h, --help                 Show this help text

Exit codes:
  0     Clean run (all uploads succeeded)
  1     Partial failure (some uploads failed)
  2     Fatal error (bad config, missing tool, etc.)
  130   Interrupted by SIGINT (Ctrl+C)
  143   Interrupted by SIGTERM

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
    # Bash 3+ compatible urlencode (no C-style for loops or ${var:i:1})
    local input="$1"
    local out=""
    local _ue_hex

    # Process byte-by-byte via od hex dump
    _ue_hex="$(printf '%s' "$input" | od -An -tx1 | tr -d '\n')"
    local _ue_byte _ue_dec
    for _ue_byte in $_ue_hex; do
        [ -z "$_ue_byte" ] && continue
        _ue_dec=$(printf '%d' "0x${_ue_byte}" 2>/dev/null) || continue
        # Pass through RFC 3986 unreserved characters: A-Z a-z 0-9 - _ . ~
        if { [ "$_ue_dec" -ge 65 ] && [ "$_ue_dec" -le 90 ]; } \
          || { [ "$_ue_dec" -ge 97 ] && [ "$_ue_dec" -le 122 ]; } \
          || { [ "$_ue_dec" -ge 48 ] && [ "$_ue_dec" -le 57 ]; } \
          || [ "$_ue_dec" -eq 45 ] \
          || [ "$_ue_dec" -eq 95 ] \
          || [ "$_ue_dec" -eq 46 ] \
          || [ "$_ue_dec" -eq 126 ]; then
            out="${out}$(printf "\\$(printf '%03o' "$_ue_dec")")"
        else
            out="${out}%$(printf '%02X' "$_ue_dec")"
        fi
    done
    printf '%s' "$out"
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
    if [ -n "$t" ] && [ -f "$t" ]; then
        echo "$t"
        return 0
    fi
    # No secure fallback possible without mktemp — refuse to continue
    return 1
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
    curl_filepath="${curl_filepath//;/\\;}"

    resp_file="$(mktemp_portable)" || return 91
    TMP_FILES+=("$resp_file")

    curl -sS --fail --show-error -X POST "${CURL_OPTS[@]}" \
        "$endpoint" \
        --form "file=@\"${curl_filepath}\";filename=\"${safe_filename}\"" \
        > "$resp_file" 2>&1
    code=$?
    if [ $code -ne 0 ]; then
        rm -f "$resp_file" 2>/dev/null
        return $code
    fi

    if grep -qi "reason" "$resp_file" 2>/dev/null; then
        local body
        body="$(cat "$resp_file" 2>/dev/null)"
        body="${body//$'\r'/ }"
        body="${body//$'\n'/ }"
        log_msg error "Server reported rejection for '$filepath': $body"
        rm -f "$resp_file" 2>/dev/null
        return 92
    fi
    rm -f "$resp_file" 2>/dev/null
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
    TMP_FILES+=("$body_file" "$resp_file")

    {
        printf -- "--%s\r\n" "$boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' "$safe_filename"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$filepath"
        printf '\r\n--%s--\r\n' "$boundary"
    } > "$body_file" 2>/dev/null || return 95

    wget -q -O "$resp_file" \
        --timeout=30 \
        "${WGET_TLS_OPTS[@]}" \
        --header="Content-Type: multipart/form-data; boundary=${boundary}" \
        --post-file="$body_file" \
        "$endpoint"
    code=$?
    rm -f "$body_file" 2>/dev/null
    if [ $code -ne 0 ]; then
        rm -f "$resp_file" 2>/dev/null
        return $code
    fi

    if grep -qi "reason" "$resp_file" 2>/dev/null; then
        local body
        body="$(cat "$resp_file" 2>/dev/null)"
        body="${body//$'\r'/ }"
        body="${body//$'\n'/ }"
        log_msg error "Server reported rejection for '$filepath': $body"
        rm -f "$resp_file" 2>/dev/null
        return 96
    fi
    rm -f "$resp_file" 2>/dev/null
    return 0
}

# collection_marker -- POST a begin/end marker to /api/collection
# Args: $1=base_url  $2=type(begin|end)  $3=scan_id(optional)  $4=stats_json(optional)
# Returns: scan_id extracted from response (empty if unsupported or failed)
json_escape() {
    # Escape a string for safe inclusion in JSON values
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

collection_marker() {
    local base_url="$1"
    local marker_type="$2"
    local scan_id="${3:-}"
    local stats_json="${4:-}"
    local marker_url="${base_url%/api/*}/api/collection"
    local body scan_id_out resp_file

    resp_file="$(mktemp_portable)" || return 1

    # Build JSON body (with proper escaping)
    body="{\"type\":\"$(json_escape "${marker_type}")\""
    body="${body},\"source\":\"$(json_escape "${SOURCE_NAME}")\""
    body="${body},\"collector\":\"bash/${VERSION}\""
    body="${body},\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u)\""
    [ -n "$scan_id"    ] && body="${body},\"scan_id\":\"$(json_escape "${scan_id}")\""
    [ -n "$stats_json" ] && body="${body},${stats_json}"
    body="${body}}"

    # Attempt POST — silent failure is intentional (server may not support this yet)
    if command -v curl >/dev/null 2>&1; then
        curl -s -o "$resp_file" "${CURL_OPTS[@]}" \
            -H "Content-Type: application/json" \
            -d "$body" \
            --max-time 10 \
            "$marker_url" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$resp_file" \
            "${WGET_TLS_OPTS[@]}" \
            --header "Content-Type: application/json" \
            --post-data "$body" \
            --timeout=10 \
            "$marker_url" 2>/dev/null || true
    fi

    # Extract scan_id from response: {"scan_id":"<value>"} or {"scan_id": "<value>"}
    scan_id_out="$(grep -oE '"scan_id"\s*:\s*"[^"]*"' "$resp_file" 2>/dev/null \
        | head -1 | sed 's/"scan_id"[[:space:]]*:[[:space:]]*"//;s/"//')"

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
            -k|--insecure)
                INSECURE=1
                ;;
            --ca-cert)
                [ -n "$2" ] || die "Missing value for $arg"
                CA_CERT="$2"
                shift
                ;;
            --sync)
                ASYNC_MODE=0
                ;;
            --retries)
                [ -n "$2" ] || die "Missing value for $arg"
                RETRIES="$2"
                shift
                ;;
            --progress)
                PROGRESS=1
                ;;
            --no-progress)
                PROGRESS=0
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
                LOG_TO_FILE=1
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

# Progress reporting ----------------------------------------------------------
# Resolve auto-detect: if PROGRESS is empty, check if stdout is a terminal.
resolve_progress() {
    if [ -z "$PROGRESS" ]; then
        if [ -t 1 ]; then
            PROGRESS=1
        else
            PROGRESS=0
        fi
    fi
    # Init time tracker so time-based progress works even for small file sets
    PROGRESS_LAST_TIME="$(date +%s 2>/dev/null || echo 0)"
}

# Count null-delimited entries in a file. Works with bash 3+ and coreutils.
count_find_results() {
    local file="$1"
    local n
    # tr + wc is portable to ancient coreutils; avoids bash-4 mapfile/readarray.
    # Find uses -print0 (null-delimited), so count null bytes.
    n="$(tr -cd '\0' < "$file" 2>/dev/null | wc -c)"
    # Strip whitespace (some wc implementations pad with spaces)
    # shellcheck disable=SC2086
    set -- $n
    echo "${1:-0}"
}

# Print progress line if conditions are met (interval by count or time).
maybe_progress() {
    [ "$PROGRESS" -eq 1 ] 2>/dev/null || return 0
    [ "$FILES_TOTAL" -gt 0 ] || return 0

    local now
    local do_report=0

    # Report every PROGRESS_INTERVAL files
    if [ "$((FILES_SCANNED % PROGRESS_INTERVAL))" -eq 0 ]; then
        do_report=1
    fi

    # Also report if enough time has passed
    if [ "$do_report" -eq 0 ]; then
        now="$(date +%s 2>/dev/null || echo 0)"
        if [ "$now" -gt 0 ] && [ "$PROGRESS_LAST_TIME" -gt 0 ]; then
            if [ "$((now - PROGRESS_LAST_TIME))" -ge "$PROGRESS_TIME_INTERVAL" ]; then
                do_report=1
            fi
        fi
    fi

    [ "$do_report" -eq 1 ] || return 0

    now="${now:-$(date +%s 2>/dev/null || echo 0)}"
    PROGRESS_LAST_TIME="$now"

    # Calculate percentage — integer arithmetic only, no bc/awk dependency
    local pct=0
    if [ "$FILES_TOTAL" -gt 0 ]; then
        pct=$(( (FILES_SCANNED * 100) / FILES_TOTAL ))
    fi

    printf '[%d/%d] %d%% processed\n' "$FILES_SCANNED" "$FILES_TOTAL" "$pct"
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
    SCAN_ID=""  # global — signal handler needs access
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
    resolve_progress
    print_banner

    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        log_msg warn "Running without root privileges; some files may be inaccessible"
    fi

    if [ "$USE_SSL" -eq 1 ]; then
        scheme="https"
    fi
    if [ "$INSECURE" -eq 1 ]; then
        CURL_OPTS+=("-k")
        WGET_TLS_OPTS+=("--no-check-certificate")
    fi
    if [ -n "$CA_CERT" ]; then
        [ -f "$CA_CERT" ] || die "CA certificate file not found: $CA_CERT"
        CURL_OPTS+=("--cacert" "$CA_CERT")
        WGET_TLS_OPTS+=("--ca-certificate=$CA_CERT")
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

    # Send collection begin marker (retry once on failure)
    if [ "$DRY_RUN" -eq 0 ]; then
        SCAN_ID="$(collection_marker "$base_url" "begin" "" "")"
        if [ -z "$SCAN_ID" ]; then
            log_msg warn "Begin marker failed, retrying in 2s..."
            sleep 2
            SCAN_ID="$(collection_marker "$base_url" "begin" "" "")"
        fi
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
        TMP_FILES+=("$find_results_file")
        # Build find exclusions: hardcoded paths + mount points of special/network FS
        local find_excludes=()
        local _ep
        for _ep in "${EXCLUDE_PATHS[@]}"; do
            [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
        done
        while IFS= read -r _ep; do
            [ -n "$_ep" ] && [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
        done <<< "$(get_excluded_mounts)"
        find "$scandir" "${find_excludes[@]}" -type f -mtime "$find_mtime" -print0 > "$find_results_file" 2>/dev/null || true

        # Count files for progress reporting
        FILES_TOTAL=$((FILES_TOTAL + $(count_find_results "$find_results_file")))

        while IFS= read -r -d '' file_path; do
            FILES_SCANNED=$((FILES_SCANNED + 1))
            maybe_progress

            [ -f "$file_path" ] || continue

            # Skip files inside cloud storage folders
            if is_cloud_path "$file_path"; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping cloud storage path '$file_path'"
                continue
            fi

            size_kb="$(file_size_kb "$file_path")"
            if [ "$size_kb" -lt 0 ]; then
                FILES_FAILED=$((FILES_FAILED + 1))
                log_msg warn "Cannot read file '$file_path' (permission denied)"
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

    # Exit codes: 0=clean, 1=partial failure, 2=fatal
    if [ "$FILES_FAILED" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
exit $?
