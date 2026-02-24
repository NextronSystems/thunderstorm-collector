#!/bin/sh
#
# THOR Thunderstorm Collector — POSIX sh / ash Edition
# Florian Roth / Nextron Systems
#
# Goals:
# - POSIX sh compatible (ash, dash, busybox sh, ksh88)
# - No bash required — suitable for embedded Linux, routers, stripped VMs
# - Functionally equivalent to thunderstorm-collector.sh
#
# Limitations vs the bash version:
# - Filenames containing literal newlines will not be processed correctly
#   (find -print0 / read -d '' require bash; this is an extreme edge case
#   in real deployments and is documented here as a known trade-off)
# - No associative arrays, no C-style for loops — all replaced with
#   POSIX-compatible equivalents

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

# Space-separated list of directories to scan (no bash arrays in ash)
SCAN_DIRS="/root /tmp /home /var /usr"
SCAN_DIRS_SET=0   # 1 once the user has overridden via --dir

FILES_SCANNED=0
FILES_SUBMITTED=0
FILES_SKIPPED=0
FILES_FAILED=0

SCRIPT_NAME="${0##*/}"
START_TS="$(date +%s 2>/dev/null || echo 0)"
SOURCE_NAME=""

# Filesystem exclusions (POSIX-compatible) ------------------------------------
# Space-separated list of paths to prune during find.
EXCLUDE_PATHS="/proc /sys /dev /run /snap /.snapshots"

# Network and special filesystem types
NETWORK_FS_TYPES="nfs nfs4 cifs smbfs smb3 sshfs fuse.sshfs afp webdav davfs2 fuse.rclone fuse.s3fs"
SPECIAL_FS_TYPES="proc procfs sysfs devtmpfs devpts cgroup cgroup2 pstore bpf tracefs debugfs securityfs hugetlbfs mqueue autofs fusectl rpc_pipefs nsfs configfs binfmt_misc selinuxfs efivarfs ramfs"

# Cloud storage folder names (lowercase for comparison)
CLOUD_DIR_NAMES="onedrive dropbox .dropbox googledrive nextcloud owncloud mega megasync tresorit syncthing"

# get_excluded_mounts: parse /proc/mounts, return mount points for network/special FS
get_excluded_mounts() {
    [ -r /proc/mounts ] || return 0
    while IFS=' ' read -r _gem_dev _gem_mp _gem_fs _gem_rest; do
        case " $NETWORK_FS_TYPES $SPECIAL_FS_TYPES " in
            *" $_gem_fs "*) printf '%s\n' "$_gem_mp" ;;
        esac
    done < /proc/mounts
}

# is_cloud_path: check if a path contains a known cloud storage folder name
is_cloud_path() {
    _icp_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for _icp_name in $CLOUD_DIR_NAMES; do
        case "$_icp_lower" in
            *"/$_icp_name"/*|*"/$_icp_name") return 0 ;;
        esac
    done
    case "$_icp_lower" in
        */library/cloudstorage/*|*/library/cloudstorage) return 0 ;;
    esac
    return 1
}

# Helpers ---------------------------------------------------------------------

timestamp() {
    date "+%Y-%m-%d_%H:%M:%S" 2>/dev/null || date
}

cleanup_tmp_files() {
    for _f in $TMP_FILES; do
        [ -n "$_f" ] && [ -f "$_f" ] && rm -f "$_f"
    done
}

on_exit() {
    cleanup_tmp_files
}

trap on_exit EXIT INT TERM

log_msg() {
    _lm_level="$1"
    shift
    _lm_message="$*"

    [ "$_lm_level" = "debug" ] && [ "$DEBUG" -ne 1 ] && return 0

    _lm_ts="$(timestamp)"
    # Strip CR/LF from message — no ${var//pat/rep} in ash, use tr
    _lm_clean="$(printf '%s' "$_lm_message" | tr '\r\n' '  ')"

    if [ "$LOG_TO_FILE" -eq 1 ]; then
        if ! printf "%s %s %s\n" "$_lm_ts" "$_lm_level" "$_lm_clean" >> "$LOGFILE" 2>/dev/null; then
            LOG_TO_FILE=0
            printf "%s warn Could not write to log file '%s'; disabling file logging\n" \
                "$_lm_ts" "$LOGFILE" >&2
        fi
    fi

    if [ "$LOG_TO_SYSLOG" -eq 1 ] && command -v logger >/dev/null 2>&1; then
        case "$_lm_level" in
            error) _lm_prio="err" ;;
            warn)  _lm_prio="warning" ;;
            debug) _lm_prio="debug" ;;
            *)     _lm_prio="info" ;;
        esac
        logger -p "${SYSLOG_FACILITY}.${_lm_prio}" "${SCRIPT_NAME}: ${_lm_clean}" \
            >/dev/null 2>&1 || true
    fi

    if [ "$LOG_TO_CMDLINE" -eq 1 ]; then
        printf "[%s] %s\n" "$_lm_level" "$_lm_clean" >&2
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
    / / / _ \/ // / _ \/ _  / -_) __(_-</ __/ _ \/ __/  ' \\
   /_/ /_//_/\_,_/_//_/\_,_/\__/_/ /___/\__/\___/_/ /_/_/_/
   v${VERSION} (POSIX sh / ash edition)

   THOR Thunderstorm Collector for Linux/Unix
==============================================================
EOF
}

print_help() {
    cat <<'EOF'
Usage:
  sh thunderstorm-collector-ash.sh [options]

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

Notes:
  This script requires only POSIX sh (ash, dash, busybox sh).
  Filenames containing literal newline characters are not supported.
  For systems with bash available, prefer thunderstorm-collector.sh.

Examples:
  sh thunderstorm-collector-ash.sh --server thunderstorm.local
  sh thunderstorm-collector-ash.sh --server 10.0.0.5 --dir /tmp --dir /home
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

urlencode() {
    # POSIX-safe urlencode: no bash C-style for loop or ${var:i:1}
    # Process od hex output word by word via set --
    _ue_hex="$(printf '%s' "$1" | od -An -tx1 | tr -d '\n')"
    # shellcheck disable=SC2086
    set -- $_ue_hex
    _ue_result=""
    for _ue_byte; do
        [ -z "$_ue_byte" ] && continue
        _ue_dec=$(printf '%d' "0x${_ue_byte}" 2>/dev/null) || continue
        # Pass through RFC 3986 unreserved characters: A-Z a-z 0-9 - _ . ~
        if   { [ "$_ue_dec" -ge 65 ] && [ "$_ue_dec" -le  90 ]; } \
          || { [ "$_ue_dec" -ge 97 ] && [ "$_ue_dec" -le 122 ]; } \
          || { [ "$_ue_dec" -ge 48 ] && [ "$_ue_dec" -le  57 ]; } \
          ||   [ "$_ue_dec" -eq 45 ] \
          ||   [ "$_ue_dec" -eq 95 ] \
          ||   [ "$_ue_dec" -eq 46 ] \
          ||   [ "$_ue_dec" -eq 126 ]; then
            _ue_result="${_ue_result}$(printf "\\$(printf '%03o' "$_ue_dec")")"
        else
            _ue_result="${_ue_result}%$(printf '%02X' "$_ue_dec")"
        fi
    done
    printf '%s' "$_ue_result"
}

build_query_source() {
    [ -n "$1" ] && printf "?source=%s" "$(urlencode "$1")"
}

sanitize_filename_for_multipart() {
    # No ${var//pat/rep} in ash — use sed + tr
    printf '%s' "$1" | sed 's/["\\;]/_/g' | tr '\r\n' '__'
}

file_size_kb() {
    _sz_bytes="$(wc -c < "$1" 2>/dev/null | tr -d ' \t')"
    case "$_sz_bytes" in
        ''|*[!0-9]*) echo -1; return 1 ;;
    esac
    echo $(( (_sz_bytes + 1023) / 1024 ))
}

mktemp_portable() {
    _mp_t="$(mktemp "${TMPDIR:-/tmp}/thunderstorm.XXXXXX" 2>/dev/null)"
    if [ -n "$_mp_t" ]; then
        echo "$_mp_t"
        return 0
    fi
    _mp_t="${TMPDIR:-/tmp}/thunderstorm.$$.$(date +%s 2>/dev/null || echo 0)"
    : > "$_mp_t" 2>/dev/null || return 1
    echo "$_mp_t"
}

_wget_is_busybox() {
    # BusyBox wget truncates --post-file at the first NUL byte, making it
    # unable to upload binary files.  Detect it so we can fall back to nc.
    wget --version 2>&1 | grep -qi busybox
}

detect_upload_tool() {
    if command -v curl >/dev/null 2>&1; then
        UPLOAD_TOOL="curl"
        return 0
    fi
    # Prefer nc over BusyBox wget for binary-safe uploads
    if command -v wget >/dev/null 2>&1 && ! _wget_is_busybox; then
        UPLOAD_TOOL="wget"
        return 0
    fi
    if command -v nc >/dev/null 2>&1; then
        UPLOAD_TOOL="nc"
        return 0
    fi
    # Fall back to BusyBox wget (works for text files, truncates binary at NUL)
    if command -v wget >/dev/null 2>&1; then
        UPLOAD_TOOL="wget"
        log_msg warn "BusyBox wget detected; binary files with NUL bytes may fail to upload"
        return 0
    fi
    return 1
}

upload_with_curl() {
    _uc_endpoint="$1"
    _uc_filepath="$2"
    _uc_filename="$3"
    _uc_safe_name="$(sanitize_filename_for_multipart "$_uc_filename")"
    _uc_resp="$(mktemp_portable)" || return 91
    TMP_FILES="${TMP_FILES} ${_uc_resp}"

    # Escape double-quotes in filepath for curl's --form
    _uc_escaped="$(printf '%s' "$_uc_filepath" | sed 's/"/\\"/g')"

    curl -sS --fail --show-error -X POST \
        "$_uc_endpoint" \
        --form "file=@\"${_uc_escaped}\";filename=\"${_uc_safe_name}\"" \
        > "$_uc_resp" 2>&1
    _uc_code=$?
    [ "$_uc_code" -ne 0 ] && return "$_uc_code"

    if grep -qi "reason" "$_uc_resp" 2>/dev/null; then
        _uc_body="$(cat "$_uc_resp" 2>/dev/null | tr '\r\n' '  ')"
        log_msg error "Server reported rejection for '$_uc_filepath': $_uc_body"
        return 92
    fi
    return 0
}

upload_with_wget() {
    _uw_endpoint="$1"
    _uw_filepath="$2"
    _uw_filename="$3"
    _uw_safe_name="$(sanitize_filename_for_multipart "$_uw_filename")"
    _uw_boundary="----ThunderstormBoundary$$"
    _uw_body="$(mktemp_portable)" || return 93
    _uw_resp="$(mktemp_portable)" || return 94
    TMP_FILES="${TMP_FILES} ${_uw_body} ${_uw_resp}"

    {
        printf -- "--%s\r\n" "$_uw_boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' \
            "$_uw_safe_name"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$_uw_filepath"
        printf '\r\n--%s--\r\n' "$_uw_boundary"
    } > "$_uw_body" 2>/dev/null || return 95

    wget -q -O "$_uw_resp" \
        --header="Content-Type: multipart/form-data; boundary=${_uw_boundary}" \
        --post-file="$_uw_body" \
        "$_uw_endpoint"
    _uw_code=$?
    [ "$_uw_code" -ne 0 ] && return "$_uw_code"

    if grep -qi "reason" "$_uw_resp" 2>/dev/null; then
        _uw_body_content="$(cat "$_uw_resp" 2>/dev/null | tr '\r\n' '  ')"
        log_msg error "Server reported rejection for '$_uw_filepath': $_uw_body_content"
        return 96
    fi
    return 0
}

upload_with_nc() {
    # Raw HTTP POST via netcat — binary-safe, no NUL truncation.
    # Used as a fallback when only BusyBox wget + nc are available.
    _nc_endpoint="$1"    # full URL: http://host:port/path?query
    _nc_filepath="$2"
    _nc_filename="$3"
    _nc_safe_name="$(sanitize_filename_for_multipart "$_nc_filename")"
    _nc_boundary="----ThunderstormBoundary$$"
    _nc_body="$(mktemp_portable)" || return 97
    TMP_FILES="${TMP_FILES} ${_nc_body}"

    # Build multipart body
    {
        printf -- "--%s\r\n" "$_nc_boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' \
            "$_nc_safe_name"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$_nc_filepath"
        printf '\r\n--%s--\r\n' "$_nc_boundary"
    } > "$_nc_body" 2>/dev/null || return 98

    _nc_content_length="$(wc -c < "$_nc_body" | tr -d ' \t')"

    # Parse host and port from the endpoint URL
    # Strip scheme
    _nc_hostpath="${_nc_endpoint#*://}"
    # Extract host:port
    _nc_hostport="${_nc_hostpath%%/*}"
    _nc_host="${_nc_hostport%%:*}"
    _nc_port="${_nc_hostport##*:}"
    [ "$_nc_port" = "$_nc_host" ] && _nc_port=80
    # Extract path+query
    _nc_path="/${_nc_hostpath#*/}"

    # Send raw HTTP via nc (cat merges headers + binary body into one stream)
    _nc_resp="$(
        {
            printf "POST %s HTTP/1.1\r\n" "$_nc_path"
            printf "Host: %s\r\n" "$_nc_hostport"
            printf "Content-Type: multipart/form-data; boundary=%s\r\n" "$_nc_boundary"
            printf "Content-Length: %s\r\n" "$_nc_content_length"
            printf "Connection: close\r\n"
            printf "\r\n"
            cat "$_nc_body"
        } | nc "$_nc_host" "$_nc_port" -w 30 2>/dev/null
    )"

    # Check for HTTP 200
    case "$_nc_resp" in
        *"200 OK"*|*"200 ok"*) return 0 ;;
    esac

    # Check for error indicators
    case "$_nc_resp" in
        *"400 Bad"*|*"500 Internal"*|*"503 Service"*)
            _nc_status="$(printf '%s' "$_nc_resp" | head -1 | tr '\r\n' '  ')"
            log_msg error "Server error for '$_nc_filepath': $_nc_status"
            return 99
            ;;
    esac

    # No response or connection failure
    [ -z "$_nc_resp" ] && return 1
    return 0
}

# collection_marker -- POST a begin/end marker to /api/collection
# Args: $1=base_url  $2=type(begin|end)  $3=scan_id(optional)  $4=stats_json(optional)
# Returns: scan_id from response (empty if unsupported/failed)
collection_marker() {
    _cm_base_url="$1"
    _cm_type="$2"
    _cm_scan_id="${3:-}"
    _cm_stats="${4:-}"
    _cm_url="${_cm_base_url%/api/*}/api/collection"
    _cm_resp="${TMPDIR:-/tmp}/thunderstorm.marker.$$"

    _cm_body="{\"type\":\"${_cm_type}\""
    _cm_body="${_cm_body},\"source\":\"${SOURCE_NAME}\""
    _cm_body="${_cm_body},\"collector\":\"ash/${VERSION}\""
    _cm_body="${_cm_body},\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)\""
    [ -n "$_cm_scan_id" ] && _cm_body="${_cm_body},\"scan_id\":\"${_cm_scan_id}\""
    [ -n "$_cm_stats"   ] && _cm_body="${_cm_body},${_cm_stats}"
    _cm_body="${_cm_body}}"

    : > "$_cm_resp" 2>/dev/null || true
    if command -v curl >/dev/null 2>&1; then
        curl -s -o "$_cm_resp" \
            -H "Content-Type: application/json" \
            -d "$_cm_body" \
            --max-time 10 \
            "$_cm_url" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$_cm_resp" \
            --header "Content-Type: application/json" \
            --post-data "$_cm_body" \
            --timeout=10 \
            "$_cm_url" 2>/dev/null || true
    fi

    _cm_id="$(grep -oE '"scan_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$_cm_resp" 2>/dev/null \
        | head -1 | sed 's/"scan_id"[[:space:]]*:[[:space:]]*"//;s/"//')"
    rm -f "$_cm_resp"
    printf '%s' "$_cm_id"
}

submit_file() {
    _sf_endpoint="$1"
    _sf_filepath="$2"
    _sf_filename="$_sf_filepath"
    _sf_try=1
    _sf_rc=1
    _sf_wait=2

    while [ "$_sf_try" -le "$RETRIES" ]; do
        if [ "$DRY_RUN" -eq 1 ]; then
            log_msg info "DRY-RUN: would submit '$_sf_filepath'"
            return 0
        fi

        case "$UPLOAD_TOOL" in
            curl)
                upload_with_curl "$_sf_endpoint" "$_sf_filepath" "$_sf_filename"
                _sf_rc=$? ;;
            nc)
                upload_with_nc "$_sf_endpoint" "$_sf_filepath" "$_sf_filename"
                _sf_rc=$? ;;
            *)
                upload_with_wget "$_sf_endpoint" "$_sf_filepath" "$_sf_filename"
                _sf_rc=$? ;;
        esac

        [ "$_sf_rc" -eq 0 ] && return 0

        log_msg warn "Upload failed for '$_sf_filepath' (attempt ${_sf_try}/${RETRIES}, code ${_sf_rc})"
        if [ "$_sf_try" -lt "$RETRIES" ]; then
            sleep "$_sf_wait"
            _sf_wait=$((_sf_wait * 2))
        fi
        _sf_try=$((_sf_try + 1))
    done

    return "$_sf_rc"
}

parse_args() {
    while [ $# -gt 0 ]; do
        _pa_arg="$1"
        case "$_pa_arg" in
            -h|--help)
                print_help
                exit 0
                ;;
            -s|--server)
                [ -n "$2" ] || die "Missing value for $_pa_arg"
                THUNDERSTORM_SERVER="$2"
                shift
                ;;
            -p|--port)
                [ -n "$2" ] || die "Missing value for $_pa_arg"
                THUNDERSTORM_PORT="$2"
                shift
                ;;
            -d|--dir)
                [ -n "$2" ] || die "Missing value for $_pa_arg"
                if [ "$SCAN_DIRS_SET" -eq 0 ]; then
                    SCAN_DIRS=""
                    SCAN_DIRS_SET=1
                fi
                # Append to space-separated list (quote-safe for dirs without spaces)
                # Dirs with spaces are handled via IFS manipulation during iteration
                SCAN_DIRS="${SCAN_DIRS:+$SCAN_DIRS
}$2"
                shift
                ;;
            --max-age)
                [ -n "$2" ] || die "Missing value for $_pa_arg"
                MAX_AGE="$2"
                shift
                ;;
            --max-size-kb)
                [ -n "$2" ] || die "Missing value for $_pa_arg"
                MAX_FILE_SIZE_KB="$2"
                shift
                ;;
            --source)
                [ -n "$2" ] || die "Missing value for $_pa_arg"
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
                [ -n "$2" ] || die "Missing value for $_pa_arg"
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
                [ -n "$2" ] || die "Missing value for $_pa_arg"
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
                die "Unknown option: $_pa_arg (use --help)"
                ;;
            *)
                # Positional args treated as additional directories
                if [ "$SCAN_DIRS_SET" -eq 0 ]; then
                    SCAN_DIRS=""
                    SCAN_DIRS_SET=1
                fi
                SCAN_DIRS="${SCAN_DIRS:+$SCAN_DIRS
}$_pa_arg"
                ;;
        esac
        shift
    done
}

validate_config() {
    is_integer "$THUNDERSTORM_PORT"  || die "Port must be numeric: '$THUNDERSTORM_PORT'"
    is_integer "$MAX_AGE"            || die "max-age must be numeric: '$MAX_AGE'"
    is_integer "$MAX_FILE_SIZE_KB"   || die "max-size-kb must be numeric: '$MAX_FILE_SIZE_KB'"
    is_integer "$RETRIES"            || die "retries must be numeric: '$RETRIES'"
    [ "$THUNDERSTORM_PORT" -gt 0 ]   || die "Port must be greater than 0"
    [ "$MAX_AGE" -ge 0 ]             || die "max-age must be >= 0"
    [ "$MAX_FILE_SIZE_KB" -gt 0 ]    || die "max-size-kb must be > 0"
    [ "$RETRIES" -gt 0 ]             || die "retries must be > 0"
    [ -n "$THUNDERSTORM_SERVER" ]    || die "Server must not be empty"
    [ -n "$SCAN_DIRS" ]              || die "At least one directory is required"
}

main() {
    _scheme="http"
    _endpoint_name="check"
    _query_source=""
    _api_endpoint=""
    _base_url=""
    _SCAN_ID=""
    _elapsed=0
    _find_mtime=""
    _results_file=""

    parse_args "$@"
    _find_mtime="-${MAX_AGE}"
    detect_source_name
    validate_config
    print_banner

    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        log_msg warn "Running without root privileges; some files may be inaccessible"
    fi

    [ "$USE_SSL"    -eq 1 ] && _scheme="https"
    [ "$ASYNC_MODE" -eq 1 ] && _endpoint_name="checkAsync"

    _query_source="$(build_query_source "$SOURCE_NAME")"
    _base_url="${_scheme}://${THUNDERSTORM_SERVER}:${THUNDERSTORM_PORT}"
    _api_endpoint="${_base_url}/api/${_endpoint_name}${_query_source}"

    if [ "$DRY_RUN" -eq 0 ]; then
        detect_upload_tool || die "Neither 'curl' nor 'wget' is installed; unable to upload samples"
    else
        if detect_upload_tool; then
            log_msg info "Dry-run mode active (upload tool detected: $UPLOAD_TOOL)"
        else
            log_msg info "Dry-run mode active (no upload tool required)"
        fi
    fi

    log_msg info "Started Thunderstorm Collector (ash) - Version $VERSION"
    log_msg info "Server: $THUNDERSTORM_SERVER"
    log_msg info "Port: $THUNDERSTORM_PORT"
    log_msg info "API endpoint: $_api_endpoint"
    log_msg info "Max age (days): $MAX_AGE"
    log_msg info "Max size (KB): $MAX_FILE_SIZE_KB"
    log_msg info "Source: $SOURCE_NAME"
    log_msg info "Folders: $(printf '%s' "$SCAN_DIRS" | tr '\n' ' ')"
    [ "$DRY_RUN" -eq 1 ] && log_msg info "Dry-run mode enabled"

    # Send collection begin marker; capture scan_id if server returns one
    if [ "$DRY_RUN" -eq 0 ]; then
        _SCAN_ID="$(collection_marker "$_base_url" "begin" "" "")"
        if [ -n "$_SCAN_ID" ]; then
            log_msg info "Collection scan_id: $_SCAN_ID"
            _api_endpoint="${_api_endpoint}&scan_id=$(urlencode "$_SCAN_ID")"
        fi
    fi

    # Write the newline-separated directory list to a temp file so the while
    # loop runs in the current shell (not a subshell). A pipe would lose all
    # counter increments (FILES_SCANNED etc.) due to POSIX subshell semantics.
    _dirs_file="$(mktemp_portable)" || die "Could not create temp file for directory list"
    TMP_FILES="${TMP_FILES} ${_dirs_file}"
    printf '%s\n' "$SCAN_DIRS" > "$_dirs_file"

    exec 3< "$_dirs_file"
    while IFS= read -r _scandir <&3; do
        [ -z "$_scandir" ] && continue

        if [ ! -d "$_scandir" ]; then
            log_msg warn "Skipping non-directory path '$_scandir'"
            continue
        fi

        log_msg info "Scanning '$_scandir'"

        _results_file="$(mktemp_portable)" || {
            log_msg error "Could not create temporary file list for '$_scandir'"
            continue
        }
        TMP_FILES="${TMP_FILES} ${_results_file}"

        # Note: find without -print0 is safe for all filenames EXCEPT those
        # containing literal newline characters (an extremely rare edge case).
        # If your environment has such filenames, use thunderstorm-collector.sh
        # (requires bash) which uses find -print0 + read -d ''.
        # Build find exclusions from EXCLUDE_PATHS
        _find_cmd="find \"$_scandir\""
        for _ep in $EXCLUDE_PATHS; do
            [ -d "$_ep" ] && _find_cmd="$_find_cmd -path \"$_ep\" -prune -o"
        done
        # Exclude mount points of network and special filesystems
        _mount_excludes="$(get_excluded_mounts)"
        for _ep in $_mount_excludes; do
            [ -d "$_ep" ] && _find_cmd="$_find_cmd -path \"$_ep\" -prune -o"
        done
        _find_cmd="$_find_cmd -type f -mtime \"$_find_mtime\" -print"
        eval "$_find_cmd" > "$_results_file" 2>/dev/null || true

        exec 4< "$_results_file"
        while IFS= read -r _file_path <&4; do
            [ -z "$_file_path" ] && continue
            [ -f "$_file_path" ] || continue

            FILES_SCANNED=$((FILES_SCANNED + 1))

            # Skip files inside cloud storage folders
            if is_cloud_path "$_file_path"; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping cloud storage path '$_file_path'"
                continue
            fi

            _size_kb="$(file_size_kb "$_file_path")"
            if [ "$_size_kb" -lt 0 ]; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping unreadable file '$_file_path'"
                continue
            fi

            if [ "$_size_kb" -gt "$MAX_FILE_SIZE_KB" ]; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping '$_file_path' due to size (${_size_kb}KB)"
                continue
            fi

            log_msg debug "Submitting '$_file_path'"
            if submit_file "$_api_endpoint" "$_file_path"; then
                FILES_SUBMITTED=$((FILES_SUBMITTED + 1))
            else
                FILES_FAILED=$((FILES_FAILED + 1))
                log_msg error "Could not upload '$_file_path'"
            fi
        done
        exec 4<&-
    done
    exec 3<&-

    if [ "$START_TS" -gt 0 ] 2>/dev/null; then
        _elapsed=$(( $(date +%s 2>/dev/null || echo "$START_TS") - START_TS ))
        [ "$_elapsed" -lt 0 ] && _elapsed=0
    fi

    log_msg info "Run completed: scanned=$FILES_SCANNED submitted=$FILES_SUBMITTED skipped=$FILES_SKIPPED failed=$FILES_FAILED seconds=$_elapsed"

    # Send collection end marker with run statistics
    if [ "$DRY_RUN" -eq 0 ]; then
        _stats="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"failed\":${FILES_FAILED},\"elapsed_seconds\":${_elapsed}}"
        collection_marker "$_base_url" "end" "$_SCAN_ID" "$_stats" >/dev/null
    fi

    return 0
}

main "$@"
