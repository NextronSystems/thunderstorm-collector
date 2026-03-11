#!/usr/bin/env bash
#
# THOR Thunderstorm Bash Collector
# Florian Roth / Nextron Systems
#
# Goals:
# - work on old and new Bash versions (Bash 3+)
# - handle missing dependencies with fallbacks
# - degrade gracefully on partial failures

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
declare -a TMP_FILES_ARR=()

# Keep defaults simple and stable for Bash 3+.
SCAN_FOLDERS=('/root' '/tmp' '/home' '/var' '/usr')

FILES_SCANNED=0
FILES_SUBMITTED=0
FILES_SKIPPED=0
FILES_FAILED=0
TOTAL_FILES=0

PROGRESS_MODE=""  # auto (empty), "on", or "off"
SHOW_PROGRESS=0

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
CLOUD_DIR_NAMES="OneDrive Dropbox .dropbox GoogleDrive Google Drive iCloud Drive iCloudDrive Nextcloud ownCloud MEGA MEGAsync Tresorit SyncThing"

# get_excluded_mounts: parse /proc/mounts and return mount points for
# network and special filesystem types (one per line).
get_excluded_mounts() {
    [ -r /proc/mounts ] || return 0
    while IFS=' ' read -r _dev _mp _fstype _rest; do
        case " $NETWORK_FS_TYPES $SPECIAL_FS_TYPES " in
            *" $_fstype "*) printf '%s\n' "$_mp" ;;
        esac
    done < /proc/mounts
}

# is_cloud_path: check if a path contains a known cloud storage folder name.
# Returns 0 (true) if it matches, 1 (false) otherwise.
is_cloud_path() {
    local path_lower
    path_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local name name_lower
    for name in $CLOUD_DIR_NAMES; do
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
    for f in "${TMP_FILES_ARR[@]}"; do
        [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
    done
}

INTERRUPTED=0

send_interrupted_marker() {
    if [ "$DRY_RUN" -eq 0 ] && [ -n "$THUNDERSTORM_SERVER" ]; then
        local _elapsed=0
        local _now
        _now="$(date +%s 2>/dev/null || echo "$START_TS")"
        if [ "$START_TS" -gt 0 ] 2>/dev/null; then
            _elapsed=$(( _now - START_TS ))
            [ "$_elapsed" -lt 0 ] && _elapsed=0
        fi
        local _stats="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"failed\":${FILES_FAILED},\"elapsed_seconds\":${_elapsed}}"
        local _scheme="http"
        [ "$USE_SSL" -eq 1 ] && _scheme="https"
        local _base="${_scheme}://${THUNDERSTORM_SERVER}:${THUNDERSTORM_PORT}"
        _base="${_base%/}"
        collection_marker "$_base" "interrupted" "${SCAN_ID:-}" "$_stats" >/dev/null 2>&1
    fi
}

on_signal() {
    INTERRUPTED=1
    log_msg warn "Received signal, sending interrupted marker and exiting..."
    send_interrupted_marker
    cleanup_tmp_files
    # Exit 1 for partial failure (interrupted collection)
    exit 1
}

on_exit() {
    cleanup_tmp_files
}

trap on_exit EXIT
trap on_signal INT TERM

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
        case "$level" in
            error|warn)
                printf "[%s] %s\n" "$level" "$clean" >&2
                ;;
            *)
                printf "[%s] %s\n" "$level" "$clean"
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
  --ca-cert <path>           Path to custom CA certificate bundle for TLS
  --sync                     Use /api/check (default: /api/checkAsync)
  --retries <num>            Retry attempts per file (default: 3)
  --dry-run                  Do not upload, only show what would be submitted
  --progress                 Force progress reporting
  --no-progress              Disable progress reporting
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

is_positive_integer() {
    is_integer "$1" || return 1
    [ "$1" -gt 0 ] 2>/dev/null || return 1
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
    local i ch hex_bytes byte

    for ((i = 0; i < ${#input}; i++)); do
        ch="${input:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-])
                out="${out}${ch}"
                ;;
            *)
                # Get hex bytes (handles multi-byte UTF-8 characters)
                hex_bytes="$(printf '%s' "$ch" | od -An -tx1 | tr -d ' \n')"
                while [ -n "$hex_bytes" ]; do
                    byte="${hex_bytes:0:2}"
                    hex_bytes="${hex_bytes:2}"
                    [ -n "$byte" ] && out="${out}%$(printf '%s' "$byte" | tr '[:lower:]' '[:upper:]')"
                done
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
    if [ -n "$t" ] && [ -f "$t" ]; then
        echo "$t"
        return 0
    fi
    # Fallback: RANDOM may be empty in non-bash shells
    t="${TMPDIR:-/tmp}/thunderstorm.$$.${RANDOM:-0}.$(date +%N 2>/dev/null || echo 0)"
    ( umask 077 && : > "$t" ) 2>/dev/null || return 1
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
    local resp_file
    local header_file
    local code
    local http_code

    safe_filename="$(sanitize_filename_for_multipart "$filename")"

    resp_file="$(mktemp_portable)" || return 91
    header_file="$(mktemp_portable)" || return 91
    TMP_FILES_ARR+=("$resp_file" "$header_file")

    # Build form argument safely — curl handles @path internally
    local form_arg="file=@${filepath};filename=${safe_filename}"

    # shellcheck disable=SC2086
    curl -sS --show-error -X POST $CURL_EXTRA_OPTS \
        -D "$header_file" \
        "$endpoint" \
        -F "$form_arg" \
        -F "hostname=${SOURCE_NAME}" \
        -F "source_path=${filepath}" \
        > "$resp_file" 2>&1
    code=$?

    # Extract HTTP status code from headers
    http_code="$(grep -oE 'HTTP/[0-9.]+ [0-9]+' "$header_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"

    # Handle 503 back-pressure
    if [ "$http_code" = "503" ]; then
        local retry_after
        retry_after="$(grep -i '^Retry-After:' "$header_file" 2>/dev/null | head -1 | sed 's/[^0-9]//g')"
        if [ -n "$retry_after" ] && [ "$retry_after" -gt 0 ] 2>/dev/null; then
            [ "$retry_after" -gt 120 ] && retry_after=120
            log_msg warn "Server returned 503, waiting ${retry_after}s (Retry-After)"
            sleep "$retry_after"
        fi
        return 93
    fi

    if [ $code -ne 0 ]; then
        return $code
    fi

    # Check for non-2xx HTTP status
    if [ -n "$http_code" ] && [ "$http_code" -ge 400 ] 2>/dev/null; then
        local body
        body="$(cat "$resp_file" 2>/dev/null)"
        body="${body//$'\r'/ }"
        body="${body//$'\n'/ }"
        log_msg error "Server returned HTTP $http_code for '$filepath': $body"
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
    local header_file
    local code

    boundary="----ThunderstormBoundary${$}${RANDOM}${RANDOM}"
    safe_filename="$(sanitize_filename_for_multipart "$filename")"
    body_file="$(mktemp_portable)" || return 93
    resp_file="$(mktemp_portable)" || return 94
    header_file="$(mktemp_portable)" || return 94
    TMP_FILES_ARR+=("$body_file" "$resp_file" "$header_file")

    {
        printf -- "--%s\r\n" "$boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' "$safe_filename"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$filepath"
        printf '\r\n--%s\r\n' "$boundary"
        printf 'Content-Disposition: form-data; name="hostname"\r\n\r\n'
        printf '%s' "$SOURCE_NAME"
        printf '\r\n--%s\r\n' "$boundary"
        printf 'Content-Disposition: form-data; name="source_path"\r\n\r\n'
        printf '%s' "$filepath"
        printf '\r\n--%s--\r\n' "$boundary"
    } > "$body_file" 2>/dev/null || return 95

    # shellcheck disable=SC2086
    wget -S -O "$resp_file" $WGET_EXTRA_OPTS \
        --header="Content-Type: multipart/form-data; boundary=${boundary}" \
        --post-file="$body_file" \
        "$endpoint" 2>"$header_file"
    code=$?

    # Extract HTTP status code from headers (wget -S writes headers to stderr with leading spaces)
    local http_code
    http_code="$(grep -oE 'HTTP/[0-9.]+[[:space:]]+[0-9]+' "$header_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"

    # Handle 503 back-pressure
    if [ "$http_code" = "503" ]; then
        local retry_after
        retry_after="$(grep -i 'Retry-After' "$header_file" 2>/dev/null | head -1 | sed 's/[^0-9]//g')"
        if [ -n "$retry_after" ] && [ "$retry_after" -gt 0 ] 2>/dev/null; then
            [ "$retry_after" -gt 120 ] && retry_after=120
            log_msg warn "Server returned 503, waiting ${retry_after}s (Retry-After)"
            sleep "$retry_after"
        fi
        return 93
    fi

    if [ $code -ne 0 ]; then
        return $code
    fi

    # Check for non-2xx HTTP status
    if [ -n "$http_code" ] && [ "$http_code" -ge 400 ] 2>/dev/null; then
        local body
        body="$(tr '\r\n' '  ' < "$resp_file" 2>/dev/null)"
        log_msg error "Server returned HTTP $http_code for '$filepath': $body"
        return 96
    fi

    return 0
}

# collection_marker -- POST a begin/end marker to /api/collection
# Args: $1=base_url  $2=type(begin|end)  $3=scan_id(optional)  $4=stats_json(optional)
# Returns: scan_id extracted from response (empty if unsupported or failed)
json_escape() {
    local s="$1"
    # Order matters: escape backslashes first, then other special chars
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\010'/\\b}"   # backspace
    s="${s//$'\014'/\\f}"   # form feed
    # Remove remaining control characters (0x00-0x1f) that could break JSON
    s="$(printf '%s' "$s" | tr -d '\000-\007\013\016-\037')"
    printf '%s' "$s"
}

# collection_marker -- POST a begin/end marker to /api/collection
# Args: $1=base_url  $2=type(begin|end)  $3=scan_id(optional)  $4=stats_json(optional)
# Outputs: scan_id extracted from response on stdout (empty if unsupported or failed)
# Returns: 0 on success, non-zero on failure
collection_marker() {
    local base_url="$1"
    local marker_type="$2"
    local scan_id="${3:-}"
    local stats_json="${4:-}"
    local marker_url="${base_url}/api/collection"
    local body scan_id_out resp_file header_file

    resp_file="$(mktemp_portable)" || return 1
    header_file="$(mktemp_portable)" || return 1
    TMP_FILES_ARR+=("$resp_file" "$header_file")

    # Build JSON body with proper escaping
    local safe_source safe_scan_id
    safe_source="$(json_escape "$SOURCE_NAME")"
    safe_scan_id="$(json_escape "$scan_id")"

    local safe_marker_type
    safe_marker_type="$(json_escape "$marker_type")"
    body="{\"type\":\"${safe_marker_type}\""
    body="${body},\"source\":\"${safe_source}\""
    body="${body},\"collector\":\"bash/${VERSION}\""
    body="${body},\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u)\""
    [ -n "$scan_id"    ] && body="${body},\"scan_id\":\"${safe_scan_id}\""
    [ -n "$stats_json" ] && body="${body},${stats_json}"
    body="${body}}"

    local _marker_rc=1
    local _marker_attempts=1
    [ "$marker_type" = "begin" ] && _marker_attempts=2

    local _attempt=0
    while [ "$_attempt" -lt "$_marker_attempts" ]; do
        _attempt=$((_attempt + 1))
        _marker_rc=1
        : > "$header_file"
        # Attempt POST — capture HTTP status to detect server-side errors
        if command -v curl >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            curl -sS -D "$header_file" -o "$resp_file" $CURL_EXTRA_OPTS \
                -H "Content-Type: application/json" \
                -d "$body" \
                --max-time 10 \
                "$marker_url" 2>/dev/null
            _marker_rc=$?
        elif command -v wget >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            wget -S -O "$resp_file" $WGET_EXTRA_OPTS \
                --header "Content-Type: application/json" \
                --post-data "$body" \
                --timeout=10 \
                "$marker_url" 2>"$header_file"
            _marker_rc=$?
        fi
        # If transport succeeded, validate HTTP status code
        if [ "$_marker_rc" -eq 0 ]; then
            local _http_code
            _http_code="$(grep -oE 'HTTP/[0-9.]+[[:space:]]+[0-9]+' "$header_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"
            if [ -n "$_http_code" ] && [ "$_http_code" -ge 400 ] 2>/dev/null; then
                log_msg warn "Collection marker '$marker_type' received HTTP $_http_code"
                _marker_rc=1
            fi
        fi
        if [ "$_marker_rc" -eq 0 ]; then
            break
        fi
        if [ "$_attempt" -lt "$_marker_attempts" ]; then
            log_msg warn "Begin marker failed (attempt $_attempt/$_marker_attempts), retrying in 2s..."
            sleep 2
        fi
    done

    # Extract scan_id from response, handling JSON escapes (e.g. \" and \\ inside the value).
    # Uses awk to find the "scan_id" key and parse the JSON string value properly.
    scan_id_out="$(awk '
    BEGIN { found = 0 }
    {
        s = s $0
    }
    END {
        # Find "scan_id" key
        idx = index(s, "\"scan_id\"")
        if (idx == 0) exit
        rest = substr(s, idx + length("\"scan_id\""))
        # Skip whitespace and colon
        gsub(/^[[:space:]]*:[[:space:]]*/, "", rest)
        # Must start with quote
        if (substr(rest, 1, 1) != "\"") exit
        rest = substr(rest, 2)
        val = ""
        while (length(rest) > 0) {
            c = substr(rest, 1, 1)
            if (c == "\\") {
                # Escaped character
                nc = substr(rest, 2, 1)
                if (nc == "\"") { val = val "\""; rest = substr(rest, 3) }
                else if (nc == "\\") { val = val "\\"; rest = substr(rest, 3) }
                else if (nc == "n") { val = val "\n"; rest = substr(rest, 3) }
                else if (nc == "r") { val = val "\r"; rest = substr(rest, 3) }
                else if (nc == "t") { val = val "\t"; rest = substr(rest, 3) }
                else if (nc == "/") { val = val "/"; rest = substr(rest, 3) }
                else if (nc == "b") { val = val "\b"; rest = substr(rest, 3) }
                else if (nc == "f") { val = val "\f"; rest = substr(rest, 3) }
                else if (nc == "u") {
                    # \uXXXX unicode escape
                    hex = substr(rest, 3, 4)
                    rest = substr(rest, 7)
                    if (length(hex) == 4) {
                        # Convert hex to decimal
                        cp = 0
                        for (hi = 1; hi <= 4; hi++) {
                            hc = substr(hex, hi, 1)
                            if (hc >= "0" && hc <= "9") cp = cp * 16 + (hc + 0)
                            else if (hc == "a" || hc == "A") cp = cp * 16 + 10
                            else if (hc == "b" || hc == "B") cp = cp * 16 + 11
                            else if (hc == "c" || hc == "C") cp = cp * 16 + 12
                            else if (hc == "d" || hc == "D") cp = cp * 16 + 13
                            else if (hc == "e" || hc == "E") cp = cp * 16 + 14
                            else if (hc == "f" || hc == "F") cp = cp * 16 + 15
                            else { cp = -1; break }
                        }
                        if (cp >= 32 && cp <= 126) {
                            val = val sprintf("%c", cp)
                        } else if (cp >= 0) {
                            # Non-ASCII or control char: replace with underscore
                            val = val "_"
                        }
                        # cp == -1: invalid hex, skip silently
                    }
                }
                else { val = val nc; rest = substr(rest, 3) }
            } else if (c == "\"") {
                break
            } else {
                val = val c
                rest = substr(rest, 2)
            }
        }
        printf "%s", val
    }' "$resp_file" 2>/dev/null)"

    # Validate scan_id: reject empty values, control characters, and unreasonably long values.
    # The value is JSON-escaped for markers and URL-encoded for query parameters, so we only
    # need to guard against control characters and excessive length.
    if [ ${#scan_id_out} -gt 256 ]; then
        scan_id_out=""
    else
        # Remove any control characters (0x00-0x1f, 0x7f) — if the result differs, reject it
        local _sanitized
        _sanitized="$(printf '%s' "$scan_id_out" | tr -d '\000-\037\177')"
        if [ "$_sanitized" != "$scan_id_out" ]; then
            scan_id_out=""
        fi
    fi

    printf '%s' "$scan_id_out"
    return "$_marker_rc"
}

submit_file() {
    local endpoint="$1"
    local filepath="$2"
    local filename
    local try=1
    local rc=1
    local wait=2
    local max_503_retries=5
    local _503_count=0

    # Preserve client-side path in multipart filename for server-side audit logs.
    filename="$filepath"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_msg info "DRY-RUN: would submit '$filepath'"
        return 0
    fi

    while [ "$try" -le "$RETRIES" ]; do
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

        # 503 back-pressure: sleep already happened in upload function,
        # retry without counting against the normal retry budget (up to a cap)
        if [ "$rc" -eq 93 ]; then
            _503_count=$((_503_count + 1))
            if [ "$_503_count" -lt "$max_503_retries" ]; then
                log_msg warn "Retrying '$filepath' after 503 back-pressure ($_503_count/$max_503_retries)"
                continue
            fi
            log_msg warn "Too many 503 responses for '$filepath', giving up"
            return "$rc"
        fi

        log_msg warn "Upload failed for '$filepath' (attempt ${try}/${RETRIES}, code ${rc})"
        if [ "$try" -lt "$RETRIES" ]; then
            sleep "$wait"
            wait=$((wait * 2))
            # Cap backoff at 60 seconds
            [ "$wait" -gt 60 ] && wait=60
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
                [ -n "${2:-}" ] || die "Missing value for $arg"
                THUNDERSTORM_SERVER="$2"
                shift
                ;;
            -p|--port)
                [ -n "${2:-}" ] || die "Missing value for $arg"
                THUNDERSTORM_PORT="$2"
                shift
                ;;
            -d|--dir)
                [ -n "${2:-}" ] || die "Missing value for $arg"
                if [ "$add_dir_mode" -eq 0 ]; then
                    SCAN_FOLDERS=()
                    add_dir_mode=1
                fi
                SCAN_FOLDERS+=("$2")
                shift
                ;;
            --max-age)
                [ -n "${2:-}" ] || die "Missing value for $arg"
                MAX_AGE="$2"
                shift
                ;;
            --max-size-kb)
                [ -n "${2:-}" ] || die "Missing value for $arg"
                MAX_FILE_SIZE_KB="$2"
                shift
                ;;
            --source)
                [ -n "${2:-}" ] || die "Missing value for $arg"
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
                [ -n "${2:-}" ] || die "Missing value for $arg"
                CA_CERT="$2"
                USE_SSL=1
                shift
                ;;
            --sync)
                ASYNC_MODE=0
                ;;
            --retries)
                [ -n "${2:-}" ] || die "Missing value for $arg"
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
                [ -n "${2:-}" ] || die "Missing value for $arg"
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
            --progress)
                PROGRESS_MODE="on"
                ;;
            --no-progress)
                PROGRESS_MODE="off"
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
    [ "$RETRIES" -ge 1 ] || die "retries must be >= 1"

    [ -n "$THUNDERSTORM_SERVER" ] || die "Server must not be empty"
    [ "${#SCAN_FOLDERS[@]}" -gt 0 ] || die "At least one directory is required"
    if [ -n "$CA_CERT" ] && [ ! -f "$CA_CERT" ]; then
        die "CA certificate file not found: '$CA_CERT'"
    fi
    if [ -n "$CA_CERT" ] && [ "$INSECURE" -eq 1 ]; then
        log_msg warn "--ca-cert and --insecure are both set; --insecure takes precedence"
    fi
}

main() {
    local scheme="http"
    local endpoint_name="check"
    local query_source=""
    local api_endpoint=""
    local base_url=""
    SCAN_ID=""
    local scandir
    local file_path
    local size_kb
    local elapsed=0
    local find_mtime
    local find_results_file

    parse_args "$@"
    detect_source_name
    validate_config
    print_banner

    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        log_msg warn "Running without root privileges; some files may be inaccessible"
    fi

    if [ "$USE_SSL" -eq 1 ]; then
        scheme="https"
    fi
    CURL_EXTRA_OPTS=""
    WGET_EXTRA_OPTS=""
    if [ "$INSECURE" -eq 1 ]; then
        CURL_EXTRA_OPTS="-k"
        WGET_EXTRA_OPTS="--no-check-certificate"
    fi
    if [ -n "$CA_CERT" ]; then
        CURL_EXTRA_OPTS="${CURL_EXTRA_OPTS} --cacert \"${CA_CERT}\""
        WGET_EXTRA_OPTS="${WGET_EXTRA_OPTS} --ca-certificate=\"${CA_CERT}\""
    fi
    if [ "$ASYNC_MODE" -eq 1 ]; then
        endpoint_name="checkAsync"
    fi

    query_source="$(build_query_source "$SOURCE_NAME")"
    base_url="${scheme}://${THUNDERSTORM_SERVER}:${THUNDERSTORM_PORT}"
    # Strip any trailing slash from base_url
    base_url="${base_url%/}"
    api_endpoint="${base_url}/api/${endpoint_name}${query_source}"

    if [ "$DRY_RUN" -eq 0 ]; then
        if ! detect_upload_tool; then
            log_msg error "Neither 'curl' nor 'wget' is installed; unable to upload samples"
            exit 2
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
        local _begin_resp_file
        _begin_resp_file="$(mktemp_portable)" || { log_msg error "Cannot create temp file"; exit 2; }
        TMP_FILES_ARR+=("$_begin_resp_file")
        collection_marker "$base_url" "begin" "" "" > "$_begin_resp_file"
        local _begin_rc=$?
        SCAN_ID="$(cat "$_begin_resp_file" 2>/dev/null)"
        # If the begin marker failed after retry, the server is unreachable — fatal error
        if [ "$_begin_rc" -ne 0 ]; then
            log_msg error "Cannot connect to Thunderstorm server at ${base_url} (begin marker failed after retry)"
            exit 2
        fi
        if [ -n "$SCAN_ID" ]; then
            log_msg info "Collection scan_id: $SCAN_ID"
            case "$api_endpoint" in
                *\?*) api_endpoint="${api_endpoint}&scan_id=$(urlencode "$SCAN_ID")" ;;
                *)    api_endpoint="${api_endpoint}?scan_id=$(urlencode "$SCAN_ID")" ;;
            esac
        fi
    fi

    # Determine progress display mode
    if [ "$PROGRESS_MODE" = "on" ]; then
        SHOW_PROGRESS=1
    elif [ "$PROGRESS_MODE" = "off" ]; then
        SHOW_PROGRESS=0
    elif [ -t 2 ]; then
        SHOW_PROGRESS=1
    else
        SHOW_PROGRESS=0
    fi

    # Build find exclusions once (shared across all scan dirs)
    local find_excludes=()
    local _ep
    for _ep in "${EXCLUDE_PATHS[@]}"; do
        [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
    done
    while IFS= read -r _ep; do
        [ -n "$_ep" ] && [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
    done <<< "$(get_excluded_mounts)"

    # Prune known cloud storage directory names at the find level so they are
    # excluded from both the file count and processing (keeps progress accurate).
    local _cloud_name _cloud_lower
    for _cloud_name in $CLOUD_DIR_NAMES; do
        _cloud_lower="$(printf '%s' "$_cloud_name" | tr '[:upper:]' '[:lower:]')"
        # -iname is supported by GNU find and most BSD finds
        find_excludes+=(\( -iname "$_cloud_name" -type d -prune \) -o)
    done
    # Also prune macOS CloudStorage
    find_excludes+=(\( -iname "CloudStorage" -path "*/Library/CloudStorage" -type d -prune \) -o)

    # First pass: collect all file lists and count total files for progress
    local all_find_files=()
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
        TMP_FILES_ARR+=("$find_results_file")
        if [ "$MAX_AGE" -gt 0 ]; then
            find "$scandir" "${find_excludes[@]}" -type f -mtime "-${MAX_AGE}" -print0 > "$find_results_file" 2>/dev/null || true
        else
            find "$scandir" "${find_excludes[@]}" -type f -print0 > "$find_results_file" 2>/dev/null || true
        fi
        all_find_files+=("$find_results_file")

        # Count files in this result set
        local _count=0
        if [ -s "$find_results_file" ]; then
            _count="$(tr -cd '\0' < "$find_results_file" 2>/dev/null | wc -c)"
            # shellcheck disable=SC2086
            set -- $_count; _count="${1:-0}"
        fi
        TOTAL_FILES=$((TOTAL_FILES + _count))
    done

    log_msg info "Found $TOTAL_FILES candidate files"

    local _processed=0
    for find_results_file in "${all_find_files[@]}"; do
        while IFS= read -r -d '' file_path; do
            # Check for interruption between files
            [ "$INTERRUPTED" -eq 1 ] && break 2

            _processed=$((_processed + 1))

            # Show progress
            if [ "$SHOW_PROGRESS" -eq 1 ] && [ "$TOTAL_FILES" -gt 0 ]; then
                printf '\r[%d/%d] %d%%' "$_processed" "$TOTAL_FILES" "$(( _processed * 100 / TOTAL_FILES ))" >&2
            fi

            [ -f "$file_path" ] || continue

            FILES_SCANNED=$((FILES_SCANNED + 1))

            # Skip files inside cloud storage folders
            if is_cloud_path "$file_path"; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping cloud storage path '$file_path'"
                continue
            fi

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

    # Clear progress line if we were showing progress
    if [ "$SHOW_PROGRESS" -eq 1 ]; then
        printf '\r\033[K' >&2
    fi

    log_msg info "Run completed: scanned=$FILES_SCANNED submitted=$FILES_SUBMITTED skipped=$FILES_SKIPPED failed=$FILES_FAILED seconds=$elapsed"

    # Send collection end marker with run statistics
    if [ "$DRY_RUN" -eq 0 ]; then
        local stats_json="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"failed\":${FILES_FAILED},\"elapsed_seconds\":${elapsed}}"
        collection_marker "$base_url" "end" "$SCAN_ID" "$stats_json" >/dev/null
    fi

    if [ "$FILES_FAILED" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
exit $?
