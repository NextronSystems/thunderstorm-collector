#!/usr/bin/env bash
#
# THOR Thunderstorm Bash Collector
# Florian Roth / Nextron Systems
#
# Goals:
# - work on Bash 3.2 and newer
# - handle missing dependencies with fallbacks
# - degrade gracefully on partial failures

VERSION="0.5.0"

if (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    printf 'ERROR: This collector requires Bash 3.2 or newer.\n' >&2
    exit 2
fi

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
declare -a CURL_EXTRA_OPTS=()
declare -a WGET_EXTRA_OPTS=()

# Keep defaults simple and stable for Bash 3+.
SCAN_FOLDERS=('/root' '/tmp' '/home' '/var' '/usr')

FILES_SCANNED=0
FILES_SUBMITTED=0
FILES_SKIPPED=0
FILES_FAILED=0
SCAN_ERRORS=0
TOTAL_FILES=0
SCAN_ID=""

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
# the directory is pruned. Keep names with embedded spaces separate so the
# find-level pruning logic does not accidentally exclude generic names such as
# "Drive" or "Google" on unrelated paths.
CLOUD_DIR_NAMES="OneDrive Dropbox .dropbox GoogleDrive iCloudDrive Nextcloud ownCloud MEGA MEGAsync Tresorit SyncThing"
CLOUD_DIR_NAMES_SPACED="Google Drive|iCloud Drive"
CLOUD_DIR_PATTERNS="OneDrive -|OneDrive-|Nextcloud-"

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
    local old_ifs
    old_ifs="$IFS"
    IFS='|'
    for name in $CLOUD_DIR_NAMES_SPACED; do
        name_lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        case "$path_lower" in
            *"/$name_lower"/*|*"/$name_lower") IFS="$old_ifs"; return 0 ;;
        esac
    done
    for name in $CLOUD_DIR_PATTERNS; do
        name_lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        case "$path_lower" in
            *"/$name_lower"*) IFS="$old_ifs"; return 0 ;;
        esac
    done
    IFS="$old_ifs"
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
    [ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"
    return 0
}

INTERRUPTED=0

send_interrupted_marker() {
    if [ "$DRY_RUN" -eq 0 ] && [ -n "$WORK_DIR" ] && [ -n "$UPLOAD_TOOL" ]; then
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
    # Prevent recursive signal handling
    trap '' INT TERM
    INTERRUPTED=1
    log_msg warn "Received signal, sending interrupted marker and exiting..."
    send_interrupted_marker
    cleanup_tmp_files
    # Exit 1 for partial failure (interrupted collection)
    exit 1
}

on_exit() {
    [ "$INTERRUPTED" -eq 0 ] && cleanup_tmp_files
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
        # Clear progress line before printing log messages to avoid interleaving
        if [ "$SHOW_PROGRESS" -eq 1 ]; then
            printf '\r\033[K' >&2
        fi
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
  --retries <num>            Normal attempts per file, 1..10 (default: 3)
  --dry-run                  Do not upload or contact the server; only show what would be submitted
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
    local bytes
    bytes="$(stat -c '%s' -- "$1" 2>/dev/null)" ||
        bytes="$(stat -f '%z' "$1" 2>/dev/null)" || { echo -1; return 1; }
    case "$bytes" in
        ''|*[!0-9]*) echo -1; return 1 ;;
    esac
    echo $(( (bytes + 1023) / 1024 ))
}

mktemp_portable() {
    [ -n "$WORK_DIR" ] || return 1
    mktemp "$WORK_DIR/list.XXXXXX"
}

escape_find_path() {
    local path="$1"
    path="${path//\\/\\\\}"
    path="${path//\*/\\*}"
    path="${path//\?/\\?}"
    path="${path//\[/\\[}"
    printf '%s' "$path"
}

# The sentinel preserves trailing newlines; command substitution alone does not.
resolve_directory() {
    local resolved
    resolved="$(CDPATH='' cd -- "$1" && pwd -P && printf '.')" || return 1
    resolved="${resolved%.}"
    RESOLVED_DIR="${resolved%$'\n'}"
}

# Bound every response/header/error file even with older curl/wget versions.
# Shells express this limit in 512- or 1024-byte units, so the physical cap is
# at most 2 MiB. Apply the logical 1 MiB response limit before parsing anything.
run_http() (
    ulimit -f 2048 || exit 97
    "$@"
)

response_is_bounded() {
    local file bytes
    for file in "$@"; do
        bytes="$(wc -c < "$file")" || return 1
        if [ "$bytes" -gt 1048576 ]; then
            log_msg error "HTTP response exceeds the 1 MiB limit"
            return 1
        fi
    done
}

# Parse the entire JSON document, not a substring that happens to name scan_id.
# Keep this POSIX awk implementation standalone for machines without Python/jq.
read_scan_id() {
    LC_ALL=C awk '
    BEGIN { for (i=1;i<256;i++) byte[sprintf("%c",i)]=i }
    function ws() { while (substr(s,p,1) ~ /^[ \t\r\n]$/) p++ }
    function fail() { exit 1 }
    function hex4(    i,c,n) {
        n=0
        for (i=0;i<4;i++) {
            c=index("0123456789abcdef",tolower(substr(s,p+i,1)))-1
            if (length(substr(s,p+i,1)) != 1 || c<0) fail()
            n=n*16+c
        }
        p+=4
        return n
    }
    function utf8(n) {
        if (n<128) return sprintf("%c",n)
        if (n<2048) return sprintf("%c%c",192+int(n/64),128+n%64)
        if (n<65536) return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64)
        return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)
    }
    function string(    out,c,n,lo,lead,count,j,nextbyte) {
        if (substr(s,p++,1)!="\"") fail()
        out=""
        while (p<=length(s)) {
            c=substr(s,p++,1)
            if (c=="\"") { parsed=out; return }
            if (c ~ /[[:cntrl:]]/) fail()
            lead=byte[c]
            if (lead>=128) {
                if (lead<194 || lead>244) fail()
                count=(lead<224 ? 1 : (lead<240 ? 2 : 3))
                for (j=1;j<=count;j++) {
                    nextbyte=byte[substr(s,p,1)]
                    if (nextbyte<128 || nextbyte>191) fail()
                    if (j==1 && ((lead==224 && nextbyte<160) ||
                        (lead==237 && nextbyte>159) || (lead==240 && nextbyte<144) ||
                        (lead==244 && nextbyte>143))) fail()
                    c=c substr(s,p++,1)
                }
            }
            if (c=="\\") {
                c=substr(s,p++,1)
                if (c=="u") {
                    n=hex4()
                    # Some awk implementations cannot preserve embedded NULs.
                    if (n==0) fail()
                    if (n>=55296 && n<=56319) {
                        if (substr(s,p,2)!="\\u") fail()
                        p+=2; lo=hex4()
                        if (lo<56320 || lo>57343) fail()
                        n=65536+(n-55296)*1024+lo-56320
                    } else if (n>=56320 && n<=57343) fail()
                    c=utf8(n)
                } else if (c=="n") c="\n"
                else if (c=="r") c="\r"
                else if (c=="t") c="\t"
                else if (c=="b") c=sprintf("%c",8)
                else if (c=="f") c=sprintf("%c",12)
                else if (c!="\"" && c!="\\" && c!="/") fail()
            }
            out=out c
        }
        fail()
    }
    function value(depth,    c,key,closing) {
        if (depth>32) fail()
        ws(); c=substr(s,p,1)
        if (c=="\"") { string(); kind="string"; return }
        if (c=="{" || c=="[") {
            closing=(c=="{" ? "}" : "]"); p++; ws()
            if (substr(s,p,1)!=closing) {
                while (1) {
                    if (c=="{") {
                        ws(); string(); key=parsed; ws()
                        if (substr(s,p++,1)!=":") fail()
                    }
                    value(depth+1)
                    if (depth==1 && c=="{" && key=="scan_id") {
                        if (++ids>1 || kind!="string") invalid_id=1
                        else id=parsed
                    }
                    ws()
                    if (substr(s,p,1)==closing) break
                    if (substr(s,p++,1)!=",") fail()
                }
            }
            p++; kind=(c=="{" ? "object" : "array"); return
        }
        if (match(substr(s,p),/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
            p+=RLENGTH; kind="number"; return
        }
        if (match(substr(s,p),/^(true|false|null)/)) {
            p+=RLENGTH; kind="literal"; return
        }
        fail()
    }
    { s=s $0 "\n" }
    END {
        p=1; value(1); ws()
        if (p<=length(s) || kind!="object" || invalid_id) fail()
        if (length(id)>256 || id ~ /[[:cntrl:]]/) fail()
        printf "%s",id
    }' "$1"
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

    resp_file="$WORK_DIR/upload.response"
    header_file="$WORK_DIR/upload.headers"
    local err_file="$WORK_DIR/upload.stderr"
    : > "$header_file" || return 91

    # Read through stdin so curl never interprets delimiters in the local path.
    local form_arg="file=@-;filename=\"${safe_filename}\""

    run_http curl --disable --noproxy '*' --globoff -sS --show-error -X POST "${CURL_EXTRA_OPTS[@]}" \
        --connect-timeout 10 --max-time 300 \
        -D "$header_file" \
        "$endpoint" \
        -F "$form_arg" \
        < "$filepath" > "$resp_file" 2>"$err_file"
    code=$?
    response_is_bounded "$resp_file" "$header_file" || return 97

    if [ $code -ne 0 ]; then
        local _curl_err
        _curl_err="$(head -c 4096 "$err_file" 2>/dev/null)"
        [ -n "$_curl_err" ] && log_msg debug "curl error: $_curl_err"
    fi

    # Extract HTTP status code from headers
    http_code="$(grep -oE '^HTTP/[0-9.]+[[:space:]]+[0-9]+' "$header_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"

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

    # Only 2xx responses count as a successful submission.
    case "$http_code" in
        2[0-9][0-9]) ;;
        *)
            local body
            body="$(head -c 4096 "$resp_file" 2>/dev/null)"
            body="${body//$'\r'/ }"
            body="${body//$'\n'/ }"
            log_msg error "Server returned HTTP ${http_code:-unknown} for '$filepath': $body"
            return 92
            ;;
    esac

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

    safe_filename="$(sanitize_filename_for_multipart "$filename")"

    # Generate a boundary that does not appear in the file content or metadata.
    # Retry with different random seeds to avoid multipart corruption.
    local _boundary_attempts=0
    boundary="----ThunderstormBoundary${$}${RANDOM}${RANDOM}$(date +%s%N 2>/dev/null || echo 0)"
    while [ "$_boundary_attempts" -lt 10 ]; do
        if ! LC_ALL=C grep -qF -- "$boundary" "$filepath" 2>/dev/null; then
            # Also check it doesn't appear in metadata fields
            case "${SOURCE_NAME}${filepath}" in
                *"$boundary"*) ;;
                *) break ;;
            esac
        fi
        _boundary_attempts=$((_boundary_attempts + 1))
        boundary="----ThunderstormBoundary${$}${RANDOM}${RANDOM}${_boundary_attempts}$(date +%s%N 2>/dev/null || echo 0)"
    done
    if [ "$_boundary_attempts" -ge 10 ]; then
        log_msg error "Could not find safe multipart boundary for '$filepath'"
        return 95
    fi
    body_file="$WORK_DIR/upload.body"
    resp_file="$WORK_DIR/upload.response"
    header_file="$WORK_DIR/upload.headers"

    {
        printf -- "--%s\r\n" "$boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' "$safe_filename"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat -- "$filepath" || return 95
        printf '\r\n--%s--\r\n' "$boundary"
    } > "$body_file" 2>/dev/null || return 95

    run_http wget --no-config --no-proxy -S -O "$resp_file" "${WGET_EXTRA_OPTS[@]}" \
        --tries=1 --max-redirect=0 --connect-timeout=10 --read-timeout=300 \
        --header="Content-Type: multipart/form-data; boundary=${boundary}" \
        --post-file="$body_file" \
        "$endpoint" 2>"$header_file"
    code=$?
    response_is_bounded "$resp_file" "$header_file" || return 97

    # Extract HTTP status code from headers (wget -S writes headers to stderr with leading spaces)
    local http_code
    http_code="$(grep -oE '^[[:space:]]*HTTP/[0-9.]+[[:space:]]+[0-9]+' "$header_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"

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

    # Only 2xx responses count as a successful submission.
    case "$http_code" in
        2[0-9][0-9]) ;;
        *)
            local body
            body="$(head -c 4096 "$resp_file" 2>/dev/null | tr '\r\n' '  ')"
            log_msg error "Server returned HTTP ${http_code:-unknown} for '$filepath': $body"
            return 96
            ;;
    esac

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

    resp_file="$WORK_DIR/marker.response"
    header_file="$WORK_DIR/marker.headers"

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

    local _http_code
    local _attempt=0
    while [ "$_attempt" -lt "$_marker_attempts" ]; do
        _attempt=$((_attempt + 1))
        _marker_rc=1
        : > "$header_file"
        : > "$resp_file"
        # Attempt POST — capture HTTP status to detect server-side errors
        if command -v curl >/dev/null 2>&1; then
            run_http curl --disable --noproxy '*' --globoff -sS -D "$header_file" -o "$resp_file" "${CURL_EXTRA_OPTS[@]}" \
                -H "Content-Type: application/json" \
                -d "$body" \
                --connect-timeout 10 --max-time 10 \
                "$marker_url" 2>/dev/null
            _marker_rc=$?
        elif command -v wget >/dev/null 2>&1; then
            run_http wget --no-config --no-proxy -S -O "$resp_file" "${WGET_EXTRA_OPTS[@]}" \
                --header "Content-Type: application/json" \
                --post-data "$body" \
                --tries=1 --max-redirect=0 --timeout=10 \
                "$marker_url" 2>"$header_file"
            _marker_rc=$?
        fi
        response_is_bounded "$resp_file" "$header_file" || return 97
        # Validate the HTTP status code even when wget exits non-zero on 4xx/5xx.
        # 404/501 means the server doesn't implement marker endpoint; continue without scan_id.
        _http_code="$(grep -oE '^[[:space:]]*HTTP/[0-9.]+[[:space:]]+[0-9]+' "$header_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"
        if [ -n "$_http_code" ]; then
            case "$_http_code" in
                2[0-9][0-9])
                    # Keep a transport failure even if 2xx headers were received.
                    ;;
                404|501)
                    log_msg warn "Collection marker '$marker_type' not supported (HTTP $_http_code) — server does not implement /api/collection"
                    # Wget uses 8 for complete HTTP error responses.
                    case "$_marker_rc" in 0|8) return 0 ;; esac
                    ;;
                *)
                    log_msg warn "Collection marker '$marker_type' received HTTP $_http_code"
                    _marker_rc=1
                    ;;
            esac
        else
            _marker_rc=1
        fi
        if [ "$_marker_rc" -eq 0 ]; then
            break
        fi
        if [ "$_attempt" -lt "$_marker_attempts" ]; then
            log_msg warn "Begin marker failed (attempt $_attempt/$_marker_attempts), retrying in 2s..."
            sleep 2
        fi
    done

    [ "$_marker_rc" -eq 0 ] || return "$_marker_rc"

    scan_id_out="$(read_scan_id "$resp_file")" || {
        log_msg warn "Ignoring invalid collection marker JSON or scan_id"
        scan_id_out=""
    }

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
                PROGRESS_MODE="on"
                ;;
            --no-progress)
                PROGRESS_MODE="off"
                ;;
            --)
                shift
                if [ $# -gt 0 ]; then
                    if [ "$add_dir_mode" -eq 0 ]; then
                        SCAN_FOLDERS=()
                    fi
                    SCAN_FOLDERS+=("$@")
                fi
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
    [ "$THUNDERSTORM_PORT" -le 65535 ] || die "Port must be <= 65535"
    [ "$MAX_AGE" -ge 0 ] || die "max-age must be >= 0"
    [ "$MAX_FILE_SIZE_KB" -gt 0 ] || die "max-size-kb must be > 0"
    [ "$RETRIES" -ge 1 ] || die "retries must be >= 1"
    [ "$RETRIES" -le 10 ] || die "retries must be <= 10"

    [ -n "$THUNDERSTORM_SERVER" ] || die "Server must not be empty"
    if [ "${#SCAN_FOLDERS[@]}" -eq 0 ]; then
        die "At least one directory is required"
    fi
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
    local scandir
    local file_path
    local size_kb
    local elapsed=0
    local find_results_file

    parse_args "$@"
    detect_source_name
    validate_config
    print_banner

    WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/thunderstorm.XXXXXX")" ||
        die "Cannot create private temporary directory"
    resolve_directory "$WORK_DIR" || die "Cannot access temporary directory"
    WORK_DIR="$RESOLVED_DIR"

    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        log_msg warn "Running without root privileges; some files may be inaccessible"
    fi

    if [ "$USE_SSL" -eq 1 ]; then
        scheme="https"
    fi
    CURL_EXTRA_OPTS=()
    WGET_EXTRA_OPTS=()
    if [ "$INSECURE" -eq 1 ]; then
        CURL_EXTRA_OPTS+=("-k")
        WGET_EXTRA_OPTS+=("--no-check-certificate")
    fi
    if [ -n "$CA_CERT" ]; then
        CURL_EXTRA_OPTS+=("--cacert" "$CA_CERT")
        WGET_EXTRA_OPTS+=("--ca-certificate=$CA_CERT")
    fi
    if [ "$ASYNC_MODE" -eq 1 ]; then
        endpoint_name="checkAsync"
    fi

    query_source="$(build_query_source "$SOURCE_NAME")"
    base_url="${scheme}://${THUNDERSTORM_SERVER}:${THUNDERSTORM_PORT}"
    # Strip any trailing slash from base_url
    base_url="${base_url%/}"
    api_endpoint="${base_url}/api/${endpoint_name}${query_source}"

    if [ "$DRY_RUN" -eq 1 ]; then
        detect_upload_tool || true
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
        if ! detect_upload_tool; then
            log_msg error "Neither 'curl' nor 'wget' is installed; unable to upload samples"
            exit 2
        fi
        local _begin_resp_file
        local _begin_rc=0
        _begin_resp_file="$WORK_DIR/begin.response"
        collection_marker "$base_url" "begin" "" "" > "$_begin_resp_file"
        _begin_rc=$?
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
    else
        log_msg info "Dry-run mode: skipping server connection"
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
    find_excludes+=(-path "$(escape_find_path "$WORK_DIR")" -prune -o)
    if [ "$LOG_TO_FILE" -eq 1 ]; then
        local log_dir log_path
        log_dir="${LOGFILE%/*}"
        [ "$log_dir" != "$LOGFILE" ] || log_dir=.
        [ -n "$log_dir" ] || log_dir=/
        if resolve_directory "$log_dir"; then
            log_path="$RESOLVED_DIR/${LOGFILE##*/}"
            log_path="$(escape_find_path "$log_path"; printf '.')"
            find_excludes+=(-path "${log_path%.}" -prune -o)
        fi
    fi
    local _ep
    for _ep in "${EXCLUDE_PATHS[@]}"; do
        [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
    done
    local _mount_list
    _mount_list="$(get_excluded_mounts)"
    if [ -n "$_mount_list" ]; then
        while IFS= read -r _ep; do
            [ -n "$_ep" ] && [ -d "$_ep" ] && find_excludes+=(-path "$_ep" -prune -o)
        done <<< "$_mount_list"
    fi

    # Prune known cloud storage directory names at the find level so they are
    # excluded from both the file count and processing (keeps progress accurate).
    local _cloud_name
    for _cloud_name in $CLOUD_DIR_NAMES; do
        find_excludes+=(\( -iname "$_cloud_name" -type d -prune \) -o)
    done
    local _old_ifs="$IFS"
    IFS='|'
    for _cloud_name in $CLOUD_DIR_NAMES_SPACED; do
        find_excludes+=(\( -iname "$_cloud_name" -type d -prune \) -o)
    done
    for _cloud_name in $CLOUD_DIR_PATTERNS; do
        find_excludes+=(\( -iname "${_cloud_name}*" -type d -prune \) -o)
    done
    IFS="$_old_ifs"
    # Also prune macOS CloudStorage
    find_excludes+=(\( -iname "CloudStorage" -path "*/Library/CloudStorage" -type d -prune \) -o)

    # First pass: collect all file lists and count total files for progress
    local all_find_files=()
    for scandir in "${SCAN_FOLDERS[@]}"; do
        if [ ! -d "$scandir" ]; then
            log_msg warn "Skipping non-directory path '$scandir'"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi

        if ! resolve_directory "$scandir"; then
            log_msg warn "Cannot access scan directory"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        scandir="$RESOLVED_DIR"

        log_msg info "Scanning '$scandir'"
        find_results_file="$(mktemp_portable)" || {
            log_msg error "Could not create temporary file list for '$scandir'"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        }
        if [ "$MAX_AGE" -gt 0 ]; then
            find "$scandir" "${find_excludes[@]}" -type f -mtime "-${MAX_AGE}" -print0 > "$find_results_file" 2> "$WORK_DIR/find.stderr"
        else
            # MAX_AGE=0 means no age filter — collect all files regardless of modification time
            find "$scandir" "${find_excludes[@]}" -type f -print0 > "$find_results_file" 2> "$WORK_DIR/find.stderr"
        fi
        if [ "$?" -ne 0 ]; then
            log_msg warn "Incomplete scan of '$scandir': $(cat "$WORK_DIR/find.stderr")"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
        fi
        all_find_files+=("$find_results_file")

        # Count files in this result set (each entry is null-terminated by -print0)
        local _count=0
        if [ -s "$find_results_file" ]; then
            # Count null bytes = number of file entries from -print0
            _count="$(tr -cd '\0' < "$find_results_file" 2>/dev/null | wc -c)"
            # Normalize whitespace from wc output
            _count="${_count//[[:space:]]/}"
            _count="${_count:-0}"
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

            FILES_SCANNED=$((FILES_SCANNED + 1))
            if [ ! -f "$file_path" ] || [ -L "$file_path" ] || [ ! -r "$file_path" ]; then
                FILES_FAILED=$((FILES_FAILED + 1))
                log_msg warn "File disappeared, changed type, or is unreadable: '$file_path'"
                continue
            fi

            # Skip files inside cloud storage folders
            if is_cloud_path "$file_path"; then
                FILES_SKIPPED=$((FILES_SKIPPED + 1))
                log_msg debug "Skipping cloud storage path '$file_path'"
                continue
            fi

            size_kb="$(file_size_kb "$file_path")"
            if [ "$size_kb" -lt 0 ]; then
                FILES_FAILED=$((FILES_FAILED + 1))
                log_msg warn "Cannot determine size of '$file_path'"
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

    log_msg info "Run completed: scanned=$FILES_SCANNED submitted=$FILES_SUBMITTED skipped=$FILES_SKIPPED failed=$FILES_FAILED scan_errors=$SCAN_ERRORS seconds=$elapsed"

    # Send collection end marker with run statistics
    if [ "$DRY_RUN" -eq 0 ]; then
        local stats_json="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"failed\":${FILES_FAILED},\"elapsed_seconds\":${elapsed}}"
        collection_marker "$base_url" "end" "$SCAN_ID" "$stats_json" >/dev/null || {
            log_msg warn "Collection end marker failed; uploads may still have succeeded"
            return 1
        }
    fi

    if [ "$FILES_FAILED" -gt 0 ] || [ "$SCAN_ERRORS" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
exit $?
