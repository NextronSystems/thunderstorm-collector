#!/bin/sh
#
# THOR Thunderstorm Collector - POSIX sh / ash Edition
# Florian Roth / Nextron Systems
#
# Goals:
# - POSIX sh compatible, tested with dash and BusyBox ash
# - No bash required: suitable for embedded Linux, routers, stripped VMs
# - Fail visibly rather than report incomplete or corrupted uploads as success
#
# Limitations vs the bash version:
# - Paths containing literal newlines are rejected, never split into other paths
# - BusyBox wget is not used for multipart uploads
# - The nc fallback requires timeout and length-delimited, plain HTTP responses

VERSION="0.5.0"

# Defaults --------------------------------------------------------------------

LOGFILE="./thunderstorm.log"
LOG_TO_FILE=1
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
WORK_DIR=""
LOG_PATH=""

# Newline-separated list of directories to scan (no bash arrays in ash)
SCAN_DIRS="/root
/tmp
/home
/var
/usr"
SCAN_DIRS_SET=0   # 1 once the user has overridden via --dir

FILES_SCANNED=0
FILES_SUBMITTED=0
FILES_SKIPPED=0
FILES_FAILED=0
SCAN_ERRORS=0
PROGRESS=1
PROGRESS_SET=0

SCRIPT_NAME="${0##*/}"
START_TS="$(date +%s 2>/dev/null || echo 0)"
SOURCE_NAME=""
PROGRESS_ACTIVE=0

# Filesystem exclusions (POSIX-compatible) ------------------------------------
# Space-separated list of paths to prune during find.
EXCLUDE_PATHS="/proc /sys /dev /run /snap /.snapshots"

# Network and special filesystem types
NETWORK_FS_TYPES="nfs nfs4 cifs smbfs smb3 sshfs fuse.sshfs afp webdav davfs2 fuse.rclone fuse.s3fs"
SPECIAL_FS_TYPES="proc procfs sysfs devtmpfs devpts cgroup cgroup2 pstore bpf tracefs debugfs securityfs hugetlbfs mqueue autofs fusectl rpc_pipefs nsfs configfs binfmt_misc selinuxfs efivarfs ramfs"

# Cloud storage folder names (lowercase for comparison)
CLOUD_DIR_NAMES="onedrive dropbox .dropbox googledrive nextcloud owncloud mega megasync tresorit syncthing iclouddrive"

# Cloud directory names that contain spaces — checked separately since the
# space-separated CLOUD_DIR_NAMES list cannot hold them.
CLOUD_DIR_NAMES_SPACED="google drive|icloud drive|onedrive -"

# get_excluded_mounts: parse /proc/mounts, return mount points for network/special FS
get_excluded_mounts() {
    [ -r /proc/mounts ] || return 0
    while IFS=' ' read -r _gem_dev _gem_mp _gem_fs _gem_rest; do
        case " $NETWORK_FS_TYPES $SPECIAL_FS_TYPES " in
            *" $_gem_fs "*) printf '%b\n' "$_gem_mp" ;;
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
    # Check cloud directory names that contain spaces (pipe-separated)
    _icp_old_ifs="$IFS"
    IFS='|'
    for _icp_name in $CLOUD_DIR_NAMES_SPACED; do
        case "$_icp_lower" in
            *"/$_icp_name"*) IFS="$_icp_old_ifs"; return 0 ;;
        esac
    done
    IFS="$_icp_old_ifs"
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
    [ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"
    return 0
}

INTERRUPTED=0

on_exit() {
    cleanup_tmp_files
}

on_signal() {
    trap '' INT TERM
    INTERRUPTED=1
    # Close file descriptors that may be open from the main loop
    exec 3<&- 4<&-
    PROGRESS_ACTIVE=0
    log_msg warn "Signal received - sending interrupted collection marker"
    if [ "$DRY_RUN" -eq 0 ] && [ -n "$WORK_DIR" ] && [ "${_begin_ok:-0}" -eq 1 ]; then
        _sig_elapsed=0
        if [ "$START_TS" -gt 0 ] 2>/dev/null; then
            _sig_elapsed=$(( $(date +%s 2>/dev/null || echo "$START_TS") - START_TS ))
            [ "$_sig_elapsed" -lt 0 ] && _sig_elapsed=0
        fi
        _sig_stats="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"failed\":${FILES_FAILED},\"scan_errors\":${SCAN_ERRORS},\"elapsed_seconds\":${_sig_elapsed}}"
        collection_marker "$_GLOBAL_BASE_URL" "interrupted" "$_GLOBAL_SCAN_ID" "$_sig_stats" >/dev/null
    fi
    cleanup_tmp_files
    exit 1
}

trap on_exit 0
trap on_signal INT TERM

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
        case "$_lm_level" in
            error|warn)
                if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
                    printf '\r%80s\r' '' >&2
                fi
                printf "[%s] %s\n" "$_lm_level" "$_lm_clean" >&2
                ;;
            *)
                if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
                    printf '\r%80s\r' '' >&2
                fi
                printf "[%s] %s\n" "$_lm_level" "$_lm_clean" >&2
                ;;
        esac
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
  --max-age <days>           Max file age, 0..36500; 0 disables it (default: 14)
  --max-size-kb <kb>         Max file size, 1..1048576 KiB (default: 2000)
  --source <name>            Source identifier (default: hostname)
  --ssl                      Use HTTPS
  -k, --insecure             Skip TLS certificate verification
  --ca-cert <path>           Path to custom CA certificate bundle for TLS
  --sync                     Use /api/check (default: /api/checkAsync)
  --retries <num>            Total attempts per file, 1..10 (default: 3)
  --dry-run                  Do not upload, only show what would be submitted
  --debug                    Enable debug log messages
  --log-file <path>          Log file path (default: ./thunderstorm.log)
  --no-log-file              Disable file logging
  --syslog                   Enable syslog logging
  --progress                 Force progress reporting on
  --no-progress              Force progress reporting off
  --quiet                    Disable command-line logging
  -h, --help                 Show this help text

Notes:
  This script requires only POSIX sh (ash, dash, busybox sh).
  Paths containing literal newline characters are rejected.
  Uploads require curl, GNU wget, or nc plus timeout (plain HTTP only).
  BusyBox wget alone is not supported; binary integrity is mandatory.
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
    _ue_hex="$(printf '%s' "$1" | od -v -An -tx1 | tr -d '\n')"
    # shellcheck disable=SC2086
    set -- $_ue_hex
    _ue_result=""
    for _ue_byte; do
        [ -z "$_ue_byte" ] && continue
        # Validate hex token: must be exactly 2 hex digits
        case "$_ue_byte" in
            [0-9a-fA-F][0-9a-fA-F]) ;;
            *) continue ;;
        esac
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
    _sz_bytes="$(stat -c '%s' -- "$1" 2>/dev/null)" ||
        _sz_bytes="$(stat -f '%z' "$1" 2>/dev/null)" ||
        { _sz_bytes="$(wc -c < "$1" 2>/dev/null)" || return 1; }
    _sz_bytes="$(printf '%s' "$_sz_bytes" | tr -d ' \t')"
    case "$_sz_bytes" in
        ''|*[!0-9]*) echo -1; return 1 ;;
    esac
    # Avoid overflowing a 32-bit shell on large files; only the limit matters.
    printf '%s\n' "$_sz_bytes" | awk -v limit="$MAX_FILE_SIZE_KB" \
        '{printf "%.0f\n", ($1 > limit * 1024 ? limit + 1 : int(($1 + 1023) / 1024))}'
}

escape_find_path() {
    printf '%s' "$1" | sed 's/[\\*?[]/\\&/g'
}

detect_upload_tool() {
    if command -v curl >/dev/null 2>&1; then
        UPLOAD_TOOL="curl"
        return 0
    fi
    if command -v wget >/dev/null 2>&1 && wget --version 2>/dev/null | head -1 | grep -q '^GNU Wget'; then
        UPLOAD_TOOL="wget"
        return 0
    fi
    if [ "$USE_SSL" -eq 0 ] && command -v nc >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        UPLOAD_TOOL="nc"
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        log_msg warn "Only GNU wget is supported for multipart uploads; BusyBox/unknown wget is refused"
    fi
    return 1
}

upload_with_curl() {
    _uc_endpoint="$1"
    _uc_filepath="$2"
    _uc_filename="$3"
    _uc_safe_name="$(sanitize_filename_for_multipart "$_uc_filename")"
    _uc_resp="$WORK_DIR/upload.response"
    _uc_hdr="$WORK_DIR/upload.headers"
    : > "$_uc_hdr" || return 91

    # Build TLS arguments safely to avoid word-splitting on paths with spaces
    set -- -sS -X POST --connect-timeout 10 --max-time 60 -o "$_uc_resp" -D "$_uc_hdr" -w '%{http_code}'
    [ "$INSECURE" -eq 1 ] && set -- "$@" -k
    [ -n "$CA_CERT" ] && set -- "$@" --cacert "$CA_CERT"
    set -- "$@" "$_uc_endpoint" \
        -F "file=@-;filename=\"${_uc_safe_name}\""

    # Use -w to capture HTTP status code; do NOT use --fail so we can inspect 503
    _uc_http_code="$(curl "$@" < "$_uc_filepath" 2>"${_uc_resp}.err")"
    _uc_code=$?

    if [ "$_uc_code" -ne 0 ]; then
        _uc_err="$(cat "${_uc_resp}.err" 2>/dev/null | tr '\r\n' '  ')"
        log_msg debug "curl error (code $_uc_code) for '$_uc_filepath': $_uc_err"
        return "$_uc_code"
    fi

    # Handle 503 back-pressure: return special code 103 and set RETRY_AFTER
    if [ "$_uc_http_code" = "503" ]; then
        RETRY_AFTER=""
        _uc_ra="$(grep -i '^Retry-After:' "$_uc_hdr" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
        if is_integer "$_uc_ra" 2>/dev/null && [ "$_uc_ra" -gt 0 ] 2>/dev/null; then
            # Cap at 120 seconds
            [ "$_uc_ra" -gt 120 ] && _uc_ra=120
            RETRY_AFTER="$_uc_ra"
        fi
        log_msg warn "Server returned 503 for '$_uc_filepath'"
        return 103
    fi

    # Any other non-2xx status
    case "$_uc_http_code" in
        2[0-9][0-9]) ;;
        *)
            _uc_body="$(cat "$_uc_resp" 2>/dev/null | tr '\r\n' '  ')"
            log_msg error "Server returned HTTP $_uc_http_code for '$_uc_filepath': $_uc_body"
            return 92
            ;;
    esac

    return 0
}

# generate_safe_boundary: produce a multipart boundary that does not appear in
# the given file.  Regenerates up to 10 times if a collision is detected.
generate_safe_boundary() {
    _gsb_filepath="$1"
    _gsb_attempt=0
    while [ "$_gsb_attempt" -lt 10 ]; do
        _gsb_rand="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        _gsb_boundary="----ThunderstormBoundary${$}${_gsb_rand:-$(date +%s 2>/dev/null || echo 0)${_gsb_attempt}}"
        LC_ALL=C grep -qF -- "$_gsb_boundary" "$_gsb_filepath" 2>/dev/null
        _gsb_rc=$?
        case "$_gsb_rc" in
            1)
                case "$_gsb_filepath" in
                    *"$_gsb_boundary"*) ;;
                    *) printf '%s' "$_gsb_boundary"; return 0 ;;
                esac
                ;;
            0) ;;
            *) return 1 ;;
        esac
        _gsb_attempt=$((_gsb_attempt + 1))
    done
    return 1
}

http_status() {
    awk '$1 ~ /^HTTP\/[0-9]+(\.[0-9]+)?$/ && $2 ~ /^[0-9][0-9][0-9]$/ {status=$2}
         END {print status}' "$1"
}

upload_with_wget() {
    _uw_endpoint="$1"
    _uw_filepath="$2"
    _uw_filename="$3"
    _uw_safe_name="$(sanitize_filename_for_multipart "$_uw_filename")"
    _uw_boundary="$(generate_safe_boundary "$_uw_filepath")" || return 95
    _uw_body="$WORK_DIR/upload.body"
    _uw_resp="$WORK_DIR/upload.response"
    _uw_hdr="$WORK_DIR/upload.headers"

    {
        printf -- "--%s\r\n" "$_uw_boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' \
            "$_uw_safe_name"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$_uw_filepath" || return 95
        printf '\r\n--%s--\r\n' "$_uw_boundary"
    } > "$_uw_body" 2>/dev/null || return 95

    # Use --server-response to capture HTTP status; stderr has the headers
    # Build TLS arguments safely to avoid word-splitting on paths with spaces
    set -- -O "$_uw_resp" -S --tries=1 --max-redirect=0 --connect-timeout=10 --read-timeout=60
    [ "$INSECURE" -eq 1 ] && set -- "$@" --no-check-certificate
    [ -n "$CA_CERT" ] && set -- "$@" "--ca-certificate=$CA_CERT"
    set -- "$@" --header="Content-Type: multipart/form-data; boundary=${_uw_boundary}" \
        --post-file="$_uw_body" \
        "$_uw_endpoint"

    wget "$@" 2>"$_uw_hdr"
    _uw_code=$?

    # Parse HTTP status code from wget's server response output
    # wget -S prints "  HTTP/1.1 200 OK" lines to stderr
    # Only real status lines count, never HTTP-looking diagnostic headers.
    _uw_http_code="$(http_status "$_uw_hdr")"

    # An incomplete 2xx transport is not a successful upload.
    if [ "$_uw_code" -ne 0 ] && [ "$_uw_http_code" != 503 ]; then
        log_msg error "wget failed (code $_uw_code, HTTP ${_uw_http_code:-unknown}) for '$_uw_filepath'"
        return "$_uw_code"
    fi

    # Handle 503 back-pressure
    if [ "$_uw_http_code" = "503" ]; then
        RETRY_AFTER=""
        _uw_ra="$(grep -i 'Retry-After:' "$_uw_hdr" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
        if is_integer "$_uw_ra" 2>/dev/null && [ "$_uw_ra" -gt 0 ] 2>/dev/null; then
            [ "$_uw_ra" -gt 120 ] && _uw_ra=120
            RETRY_AFTER="$_uw_ra"
        fi
        log_msg warn "Server returned 503 for '$_uw_filepath'"
        return 103
    fi

    # Accept 2xx as success
    case "$_uw_http_code" in
        2[0-9][0-9]) ;;
        *) log_msg error "Server returned HTTP ${_uw_http_code:-unknown} for '$_uw_filepath'"; return 92 ;;
    esac

    return 0
}

upload_with_nc() {
    # Raw HTTP POST via netcat — binary-safe, no NUL truncation.
    # Used as a fallback when only BusyBox wget + nc are available.
    # WARNING: nc does not support TLS — only works with plain HTTP.
    _nc_endpoint="$1"    # full URL: http://host:port/path?query
    case "$_nc_endpoint" in
        https://*) log_msg error "nc (netcat) does not support HTTPS; use curl or wget"; return 99 ;;
    esac
    _nc_filepath="$2"
    _nc_filename="$3"
    _nc_safe_name="$(sanitize_filename_for_multipart "$_nc_filename")"
    _nc_boundary="$(generate_safe_boundary "$_nc_filepath")" || return 97
    _nc_body="$WORK_DIR/upload.body"
    _nc_resp_file="$WORK_DIR/upload.response"
    _nc_request="$WORK_DIR/upload.request"

    # Build multipart body
    {
        printf -- "--%s\r\n" "$_nc_boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' \
            "$_nc_safe_name"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$_nc_filepath" || return 98
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

    # Spool before connecting so a failed copy cannot become a truncated upload.
    {
        printf "POST %s HTTP/1.0\r\n" "$_nc_path"
        printf "Host: %s\r\n" "$_nc_hostport"
        printf "Content-Type: multipart/form-data; boundary=%s\r\n" "$_nc_boundary"
        printf "Content-Length: %s\r\n" "$_nc_content_length"
        printf "Connection: close\r\n"
        printf "\r\n"
        cat "$_nc_body" || return 98
    } > "$_nc_request" || return 98
    timeout 60 nc -w 30 "$_nc_host" "$_nc_port" < "$_nc_request" > "$_nc_resp_file" 2>/dev/null
    _nc_rc=$?

    # No response or connection failure
    if [ "$_nc_rc" -ne 0 ] || [ ! -s "$_nc_resp_file" ]; then
        log_msg error "Incomplete nc transport (code $_nc_rc) for '$_nc_filepath'"
        return 1
    fi

    # Parse HTTP status code from the first line (e.g. "HTTP/1.1 200 OK")
    _nc_status_line="$(head -1 "$_nc_resp_file" | tr -d '\r')"
    _nc_http_code="$(printf '%s\n' "$_nc_status_line" | awk \
        '$1 ~ /^HTTP\/1\.[01]$/ && $2 ~ /^[0-9][0-9][0-9]$/ {print $2}')"

    if [ -z "$_nc_http_code" ]; then
        log_msg error "Could not parse HTTP status for '$_nc_filepath': $_nc_status_line"
        return 99
    fi

    # This deliberately small HTTP client requires unambiguous length framing.
    # Do not accept truncated, chunked, duplicate-length or close-delimited data.
    _nc_framing="$(LC_ALL=C awk '
        BEGIN {bytes=0; lengths=0; bad=0}
        {
            bytes += length($0) + 1
            line=$0
            sub(/\r$/, "", line)
            if (NR == 1) next
            if (line == "") {
                if (lengths == 1 && !bad) printf "%.0f %.0f\n", bytes, length_value
                exit
            }
            lower=tolower(line)
            if (lower ~ /^content-length:/) {
                sub(/^[^:]*:[ \t]*/, "", line)
                sub(/[ \t]*$/, "", line)
                lengths++
                if (line !~ /^[0-9]+$/ || length(line) > 10) bad=1
                length_value=line
            }
            if (lower ~ /^transfer-encoding:/) bad=1
        }' "$_nc_resp_file")"
    set -- $_nc_framing
    if [ "$#" -ne 2 ]; then
        log_msg error "nc requires a complete response with a single Content-Length"
        return 99
    fi
    _nc_actual_bytes="$(wc -c < "$_nc_resp_file" | tr -d ' \t')"
    if ! awk -v actual="$_nc_actual_bytes" -v headers="$1" -v body="$2" \
        'BEGIN {exit !(actual == headers + body)}'; then
        log_msg error "Truncated or excess nc response for '$_nc_filepath'"
        return 99
    fi

    # Handle 503 back-pressure
    if [ "$_nc_http_code" = "503" ]; then
        RETRY_AFTER=""
        _nc_ra="$(grep -i '^Retry-After:' "$_nc_resp_file" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
        if is_integer "$_nc_ra" 2>/dev/null && [ "$_nc_ra" -gt 0 ] 2>/dev/null; then
            [ "$_nc_ra" -gt 120 ] && _nc_ra=120
            RETRY_AFTER="$_nc_ra"
        fi
        log_msg warn "Server returned 503 for '$_nc_filepath'"
        return 103
    fi

    # Accept 2xx as success
    case "$_nc_http_code" in
        2[0-9][0-9])
            return 0
            ;;
    esac

    # All other statuses are errors
    log_msg error "Server returned HTTP $_nc_http_code for '$_nc_filepath': $_nc_status_line"
    return 99
}

# json_escape: escape a string for safe inclusion in JSON values
# Handles backslash, double-quote, and all control characters (0x00-0x1F)
# Uses od + byte-by-byte rebuild for full POSIX portability
json_escape() {
    _je_hex="$(printf '%s' "$1" | od -v -An -tx1 | tr -d '\n')"
    _je_result=""
    # shellcheck disable=SC2086
    set -- $_je_hex
    for _je_byte; do
        [ -z "$_je_byte" ] && continue
        _je_dec=$(printf '%d' "0x${_je_byte}" 2>/dev/null) || continue
        if [ "$_je_dec" -eq 92 ]; then
            # backslash
            _je_result="${_je_result}\\\\"
        elif [ "$_je_dec" -eq 34 ]; then
            # double quote
            _je_result="${_je_result}\\\""
        elif [ "$_je_dec" -eq 8 ]; then
            _je_result="${_je_result}\\b"
        elif [ "$_je_dec" -eq 9 ]; then
            _je_result="${_je_result}\\t"
        elif [ "$_je_dec" -eq 10 ]; then
            _je_result="${_je_result}\\n"
        elif [ "$_je_dec" -eq 12 ]; then
            _je_result="${_je_result}\\f"
        elif [ "$_je_dec" -eq 13 ]; then
            _je_result="${_je_result}\\r"
        elif [ "$_je_dec" -lt 32 ]; then
            # Other control characters: emit \u00XX
            _je_result="${_je_result}$(printf '\\u00%02x' "$_je_dec")"
        else
            _je_result="${_je_result}$(printf "\\$(printf '%03o' "$_je_dec")")"
        fi
    done
    printf '%s' "$_je_result"
}

# collection_marker -- POST a begin/end marker to /api/collection
# Args: $1=base_url  $2=type(begin|end)  $3=scan_id(optional)  $4=stats_json(optional)
# Returns: scan_id from response (empty if unsupported/failed)
# Exit status: 0 = success, 1 = connection/request failure
collection_marker() {
    _cm_base_url="$1"
    _cm_type="$2"
    _cm_scan_id="${3:-}"
    _cm_stats="${4:-}"
    _cm_url="${_cm_base_url%/}/api/collection"
    if [ "$UPLOAD_TOOL" = nc ]; then
        log_msg warn "Skipping collection marker '$_cm_type': curl or GNU wget is required for /api/collection"
        return 0
    fi
    _cm_resp="$WORK_DIR/marker.response"
    _cm_hdr="$WORK_DIR/marker.headers"

    _cm_safe_source="$(json_escape "$SOURCE_NAME")"
    _cm_body="{\"type\":\"${_cm_type}\""
    _cm_safe_hostname="$(json_escape "$(uname -n 2>/dev/null || echo unknown)")"
    _cm_body="${_cm_body},\"source\":\"${_cm_safe_source}\""
    _cm_body="${_cm_body},\"hostname\":\"${_cm_safe_hostname}\""
    _cm_body="${_cm_body},\"collector\":\"ash/${VERSION}\""
    _cm_body="${_cm_body},\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)\""
    [ -n "$_cm_scan_id" ] && _cm_body="${_cm_body},\"scan_id\":\"${_cm_scan_id}\""
    [ -n "$_cm_stats"   ] && _cm_body="${_cm_body},${_cm_stats}"
    _cm_body="${_cm_body}}"

    _cm_ok=0
    : > "$_cm_resp" || return 1
    : > "$_cm_hdr" || return 1
    if [ "$UPLOAD_TOOL" = curl ]; then
        set -- -sS -o "$_cm_resp" -D "$_cm_hdr" -w '%{http_code}' -H "Content-Type: application/json" -d "$_cm_body" --connect-timeout 5 --max-time 10
        [ "$INSECURE" -eq 1 ] && set -- "$@" -k
        [ -n "$CA_CERT" ] && set -- "$@" --cacert "$CA_CERT"
        set -- "$@" "$_cm_url"
        _cm_http_code="$(curl "$@" 2>/dev/null)"
        _cm_curl_rc=$?
        if [ "$_cm_curl_rc" -eq 0 ]; then
            case "$_cm_http_code" in
                2[0-9][0-9]) _cm_ok=1 ;;
                404|501) log_msg warn "Collection marker '$_cm_type' not supported (HTTP $_cm_http_code)"; return 0 ;;
                *) log_msg warn "Collection marker '$_cm_type' got HTTP $_cm_http_code" ;;
            esac
        fi
    elif [ "$UPLOAD_TOOL" = wget ]; then
        set -- -O "$_cm_resp" -S --tries=1 --max-redirect=0 --header "Content-Type: application/json" --post-data "$_cm_body" --timeout=10
        [ "$INSECURE" -eq 1 ] && set -- "$@" --no-check-certificate
        [ -n "$CA_CERT" ] && set -- "$@" "--ca-certificate=$CA_CERT"
        set -- "$@" "$_cm_url"
        wget "$@" 2>"$_cm_hdr"
        _cm_wget_rc=$?
        _cm_http_code="$(http_status "$_cm_hdr")"
        case "$_cm_http_code" in
            404|501) log_msg warn "Collection marker '$_cm_type' not supported (HTTP $_cm_http_code)"; return 0 ;;
            2[0-9][0-9]) [ "$_cm_wget_rc" -eq 0 ] && _cm_ok=1 ;;
            *) log_msg warn "Collection marker '$_cm_type' got HTTP ${_cm_http_code:-unknown}" ;;
        esac
    else
        return 1
    fi
    [ "$_cm_ok" -eq 1 ] || return 1

    # Extract scan_id value using a strict regex that only matches plain
    # (unescaped) JSON string values containing safe characters.
    # This avoids partial JSON unescaping bugs — if the server returns an
    # escaped scan_id we simply won't match it, which is safe (we continue
    # without a scan_id).
    _cm_id="$(sed -n 's/.*"scan_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._:-]*\)".*/\1/p' "$_cm_resp" 2>/dev/null | head -1)"
    printf '%s' "$_cm_id"
    [ "$_cm_ok" -eq 1 ]
}

submit_file() {
    _sf_endpoint="$1"
    _sf_filepath="$2"
    _sf_filename="$_sf_filepath"
    _sf_try=1
    _sf_rc=1
    _sf_wait=2
    RETRY_AFTER=""

    if [ "$DRY_RUN" -eq 1 ]; then
        log_msg info "DRY-RUN: would submit '$_sf_filepath'"
        return 0
    fi

    while [ "$_sf_try" -le "$RETRIES" ]; do
        RETRY_AFTER=""

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
            # Use Retry-After from 503 if available, otherwise exponential backoff
            if [ "$_sf_rc" -eq 103 ] && [ -n "$RETRY_AFTER" ]; then
                log_msg info "Server requested Retry-After: ${RETRY_AFTER}s"
                sleep "$RETRY_AFTER"
            else
                sleep "$_sf_wait"
                _sf_wait=$((_sf_wait * 2))
                [ "$_sf_wait" -gt 60 ] && _sf_wait=60
            fi
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
                add_scan_dir "$2"
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
            -k|--insecure)
                INSECURE=1
                ;;
            --ca-cert)
                [ -n "$2" ] || die "Missing value for $_pa_arg"
                CA_CERT="$2"
                shift
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
            --progress)
                PROGRESS=1
                PROGRESS_SET=1
                ;;
            --no-progress)
                PROGRESS=0
                PROGRESS_SET=1
                ;;
            --)
                shift
                for _pa_dir do add_scan_dir "$_pa_dir"; done
                break
                ;;
            -*)
                die "Unknown option: $_pa_arg (use --help)"
                ;;
            *)
                add_scan_dir "$_pa_arg"
                ;;
        esac
        shift
    done
}

add_scan_dir() {
    case "$1" in
        *'
'*) die "Scan directory paths containing newlines are not supported" ;;
    esac
    [ -n "$1" ] || die "Scan directory must not be empty"
    if [ "$SCAN_DIRS_SET" -eq 0 ]; then
        SCAN_DIRS=""
        SCAN_DIRS_SET=1
    fi
    SCAN_DIRS="${SCAN_DIRS:+$SCAN_DIRS
}$1"
}

normalize_uint() {
    is_integer "$1" || die "$4 must be numeric"
    _nu_value="$(printf '%s' "$1" | sed 's/^0*//')"
    _nu_value="${_nu_value:-0}"
    [ "${#_nu_value}" -le "${#3}" ] || die "$4 must be in $2..$3"
    [ "$_nu_value" -ge "$2" ] && [ "$_nu_value" -le "$3" ] || die "$4 must be in $2..$3"
    printf '%s' "$_nu_value"
}

validate_config() {
    THUNDERSTORM_PORT="$(normalize_uint "$THUNDERSTORM_PORT" 1 65535 Port)" || exit 2
    MAX_AGE="$(normalize_uint "$MAX_AGE" 0 36500 max-age)" || exit 2
    MAX_FILE_SIZE_KB="$(normalize_uint "$MAX_FILE_SIZE_KB" 1 1048576 max-size-kb)" || exit 2
    RETRIES="$(normalize_uint "$RETRIES" 1 10 retries)" || exit 2
    case "$THUNDERSTORM_SERVER" in
        ''|-*|*[!a-zA-Z0-9._-]*) die "Server must be an IPv4 address or DNS hostname, without a scheme or path" ;;
    esac
    [ -n "$SCAN_DIRS" ]              || die "At least one directory is required"
    if [ -n "$CA_CERT" ]; then
        [ -f "$CA_CERT" ] && [ -r "$CA_CERT" ] || die "CA certificate file is missing or unreadable"
    fi
    if [ "$INSECURE" -eq 1 ]; then
        log_msg warn "TLS certificate verification is explicitly disabled by --insecure"
    fi
}

main() {
    _scheme="http"
    _endpoint_name="check"
    _query_source=""
    _api_endpoint=""
    _base_url=""
    _SCAN_ID=""
    _elapsed=0
    _results_file=""
    _GLOBAL_BASE_URL=""
    _GLOBAL_SCAN_ID=""

    parse_args "$@"
    detect_source_name
    validate_config
    for _required in sh find awk sed grep tr wc od cat date head tail rm mktemp dirname basename uname; do
        command -v "$_required" >/dev/null 2>&1 || {
            printf "ERROR: Required utility '%s' is missing\n" "$_required" >&2
            exit 2
        }
    done
    WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/thunderstorm.XXXXXX")" ||
        die "Cannot create private temporary directory"
    _work_physical="$(CDPATH='' cd -- "$WORK_DIR" && pwd -P)" || die "Cannot access temporary directory"
    WORK_DIR="$_work_physical"
    if [ "$LOG_TO_FILE" -eq 1 ]; then
        _log_dir="$(dirname -- "$LOGFILE")"
        if _log_dir="$(CDPATH='' cd -- "$_log_dir" && pwd -P)"; then
            LOG_PATH="$_log_dir/$(basename -- "$LOGFILE")"
        fi
    fi
    print_banner

    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        log_msg warn "Running without root privileges; some files may be inaccessible"
    fi

    [ "$USE_SSL"    -eq 1 ] && _scheme="https"
    if [ -n "$CA_CERT" ]; then
        [ -f "$CA_CERT" ] || die "CA certificate file not found: '$CA_CERT'"
    fi
    [ "$ASYNC_MODE" -eq 1 ] && _endpoint_name="checkAsync"

    _query_source="$(build_query_source "$SOURCE_NAME")"
    _base_url="${_scheme}://${THUNDERSTORM_SERVER}:${THUNDERSTORM_PORT}"
    _api_endpoint="${_base_url}/api/${_endpoint_name}${_query_source}"
    log_msg debug "Base URL: $_base_url"
    log_msg debug "API endpoint: $_api_endpoint"

    if [ "$DRY_RUN" -eq 0 ]; then
        if ! detect_upload_tool; then
            if [ "$USE_SSL" -eq 1 ] && command -v nc >/dev/null 2>&1; then
                die "HTTPS uploads require 'curl' or 'wget'; 'nc' does not support TLS"
            fi
            die "Uploads require curl, GNU wget, or nc plus timeout (plain HTTP only)"
        fi
    else
        log_msg info "Dry-run mode active (no upload tool or server connection required)"
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

    # TTY auto-detection for progress reporting
    if [ "$PROGRESS_SET" -eq 0 ]; then
        if [ -t 2 ]; then
            PROGRESS=1
        else
            PROGRESS=0
        fi
    fi

    # Store in globals for signal handler access
    _GLOBAL_BASE_URL="$_base_url"
    _GLOBAL_SCAN_ID=""

    # Send collection begin marker; capture scan_id if server returns one
    # Retry once after 2s on initial connection failure
    if [ "$DRY_RUN" -eq 0 ]; then
        _begin_ok=0
        _scan_id_file="$WORK_DIR/begin.id"
        if collection_marker "$_base_url" "begin" "" "" > "$_scan_id_file"; then
            IFS= read -r _SCAN_ID < "$_scan_id_file" || true
            _begin_ok=1
        fi
        if [ "$_begin_ok" -eq 0 ]; then
            log_msg warn "Begin marker failed; retrying in 2 seconds..."
            sleep 2
            if collection_marker "$_base_url" "begin" "" "" > "$_scan_id_file"; then
                IFS= read -r _SCAN_ID < "$_scan_id_file" || true
                _begin_ok=1
            else
                die "Cannot connect to Thunderstorm server at ${_base_url}/api/collection after retry"
            fi
        fi
        rm -f "$_scan_id_file"
        if [ -n "$_SCAN_ID" ]; then
            log_msg info "Collection scan_id: $_SCAN_ID"
            _GLOBAL_SCAN_ID="$_SCAN_ID"
            # Check if endpoint already has query params
            case "$_api_endpoint" in
                *"?"*) _api_endpoint="${_api_endpoint}&scan_id=$(urlencode "$_SCAN_ID")" ;;
                *)     _api_endpoint="${_api_endpoint}?scan_id=$(urlencode "$_SCAN_ID")" ;;
            esac
            log_msg debug "API endpoint (with scan_id): $_api_endpoint"
        else
            log_msg warn "Could not obtain scan_id from server; continuing without it"
        fi
    fi

    # Write the newline-separated directory list to a temp file so the while
    # loop runs in the current shell (not a subshell). A pipe would lose all
    # counter increments (FILES_SCANNED etc.) due to POSIX subshell semantics.
    get_excluded_mounts > "$WORK_DIR/mounts.list" || die "Cannot write excluded mount list"
    _dirs_file="$WORK_DIR/directories.list"
    printf '%s\n' "$SCAN_DIRS" > "$_dirs_file" || die "Cannot write directory list"

    exec 3< "$_dirs_file"
    while IFS= read -r _scandir <&3; do
        [ "$INTERRUPTED" -eq 1 ] && break
        [ -z "$_scandir" ] && continue

        if [ ! -d "$_scandir" ]; then
            log_msg warn "Skipping non-directory path '$_scandir'"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi

        log_msg info "Scanning '$_scandir'"
        if ! _scandir="$(CDPATH='' cd -- "$_scandir" && pwd -P)"; then
            log_msg warn "Cannot access scan directory"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi

        _results_file="$WORK_DIR/files.list"
        : > "$WORK_DIR/path.errors" || die "Cannot write path error list"

        # Validate each unsplit find operand before emitting line-based records.
        # A newline filename must never turn into an unrelated relative path.
        (
            set -- "$_scandir"
            set -- "$@" -path "$(escape_find_path "$WORK_DIR")" -prune -o
            [ -n "$LOG_PATH" ] && set -- "$@" -path "$(escape_find_path "$LOG_PATH")" -prune -o
            for _ep in $EXCLUDE_PATHS; do
                [ -d "$_ep" ] && set -- "$@" -path "$_ep" -prune -o
            done
            while IFS= read -r _ep; do
                [ -n "$_ep" ] && [ -d "$_ep" ] && set -- "$@" -path "$(escape_find_path "$_ep")" -prune -o
            done < "$WORK_DIR/mounts.list"
            set -- "$@" -type f
            [ "$MAX_AGE" -gt 0 ] && set -- "$@" -mtime "-${MAX_AGE}"
            set -- "$@" -exec sh -c '
                case "$1" in
                    *"
"*) printf "unsupported newline path\n" >> "$2" || exit 1 ;;
                    *) printf "%s\n" "$1" ;;
                esac' sh '{}' "$WORK_DIR/path.errors" ';'
            find "$@"
        ) > "$_results_file" 2> "$WORK_DIR/find.stderr"
        if [ "$?" -ne 0 ] || [ -s "$WORK_DIR/find.stderr" ]; then
            log_msg warn "Incomplete scan of '$_scandir': $(cat "$WORK_DIR/find.stderr")"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
        fi
        _path_errors="$(wc -l < "$WORK_DIR/path.errors" | tr -d ' \t')"
        if [ "$_path_errors" -gt 0 ]; then
            SCAN_ERRORS=$((SCAN_ERRORS + _path_errors))
            log_msg warn "Rejected $_path_errors paths containing unsupported newline characters"
        fi

        # Count total lines for progress reporting
        _total_in_dir="$(wc -l < "$_results_file" 2>/dev/null | tr -d ' \t')"
        [ -z "$_total_in_dir" ] && _total_in_dir=0
        _current_in_dir=0

        exec 4< "$_results_file"
        while IFS= read -r _file_path <&4; do
            [ "$INTERRUPTED" -eq 1 ] && break
            [ -z "$_file_path" ] && continue

            _current_in_dir=$((_current_in_dir + 1))

            # Progress reporting (based on lines consumed, not files processed)
            if [ "$PROGRESS" -eq 1 ] && [ "$_total_in_dir" -gt 0 ]; then
                _pct=$(( _current_in_dir * 100 / _total_in_dir ))
                printf '\r[%d/%d] %d%% - %s' "$_current_in_dir" "$_total_in_dir" "$_pct" "$_scandir" >&2
                PROGRESS_ACTIVE=1
            fi

            FILES_SCANNED=$((FILES_SCANNED + 1))

            if [ ! -f "$_file_path" ] || [ -L "$_file_path" ] || [ ! -r "$_file_path" ]; then
                FILES_FAILED=$((FILES_FAILED + 1))
                log_msg warn "File disappeared, changed type, or is unreadable: '$_file_path'"
                continue
            fi

            # Skip files inside cloud storage folders
            if is_cloud_path "$_file_path"; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping cloud storage path '$_file_path'"
                continue
            fi

            if ! _size_kb="$(file_size_kb "$_file_path")"; then
                FILES_FAILED=$((FILES_FAILED + 1))
                log_msg warn "Cannot determine size of '$_file_path'"
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
        # Clear progress line
        if [ "$PROGRESS" -eq 1 ] && [ "$_total_in_dir" -gt 0 ]; then
            printf '\r%80s\r' '' >&2
            PROGRESS_ACTIVE=0
        fi
    done
    exec 3<&-

    if [ "$START_TS" -gt 0 ] 2>/dev/null; then
        _elapsed=$(( $(date +%s 2>/dev/null || echo "$START_TS") - START_TS ))
        [ "$_elapsed" -lt 0 ] && _elapsed=0
    fi

    log_msg info "Run completed: scanned=$FILES_SCANNED submitted=$FILES_SUBMITTED skipped=$FILES_SKIPPED failed=$FILES_FAILED scan_errors=$SCAN_ERRORS seconds=$_elapsed"

    # Send collection end marker with run statistics
    if [ "$DRY_RUN" -eq 0 ]; then
        _stats="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"failed\":${FILES_FAILED},\"scan_errors\":${SCAN_ERRORS},\"elapsed_seconds\":${_elapsed}}"
        collection_marker "$_base_url" "end" "$_SCAN_ID" "$_stats" >/dev/null || {
            log_msg warn "Collection end marker failed; uploads may still have succeeded"
            return 1
        }
    fi

    # Exit code: 0 = success, 1 = incomplete collection.
    if [ "$FILES_FAILED" -gt 0 ] || [ "$SCAN_ERRORS" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
exit $?
