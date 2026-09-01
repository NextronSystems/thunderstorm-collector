#!/usr/bin/env bash
#
# THOR Thunderstorm Bash Collector
# Florian Roth / Nextron Systems
#
# Goals:
# - work on old and new Bash versions (Bash 3+)
# - handle missing dependencies with fallbacks
# - degrade gracefully on partial failures
#
# Exit codes:
# 0        success — everything discovered was collected
# 1        runtime error — could not run (server unreachable, temp-file creation failed)
# 2        usage/config error — bad arguments or invalid configuration
# 3        missing dependency — neither curl nor wget available; or no mkdir / find
# 4        partial failure — ran, but something could not be collected: an upload failed, a
# discovered file was unreadable, a directory could not be read, or an explicitly
# named target was unusable (rsync's exit 23, "partial transfer due to error")
# 5        partial: files VANISHED — every loss was a file that disappeared or changed type
# between discovery and collection, i.e. ordinary churn on a live host and nothing
# the collector or the operator did wrong (rsync's exit 24, "vanished source
# files"). 4 wins when both happened, as rsync lets 23 override 24.
# 130/143  interrupted by SIGINT / SIGTERM (128 + signal number)

VERSION="0.5.0"

# Defaults --------------------------------------------------------------------

LOGFILE="./thunderstorm.log"
LOG_TO_FILE=1
# The file sink stays closed until the command line is parsed: a usage error thrown mid-parse
# (e.g. '--bogus --no-log-file') used to create./thunderstorm.log in the cwd although the
# operator disabled or redirected the log later on the same command line.
LOG_FILE_READY=0
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
# Which timestamp --max-age measures: "mtime", "ctime" or "any" (both). Default "any": touch -d
# backdates mtime freely but necessarily updates ctime, which no userspace call can set; ctime
# alone would miss a forward stomp — the one case where mtime > ctime.
AGE_TIMESTAMP="any"
MAX_FILE_SIZE_KB=2000
# Which spelling of the size flag the operator used, so validate_config's errors name the flag
# they actually typed. require_value already interpolates "$arg"; without this the two halves of
# the diagnostic path disagreed and '--max-size-kb xyz' was answered with "max-size must be
# numeric" — a flag that never appeared on the command line.
MAX_SIZE_FLAG="--max-size"
# Count what the size/age gates removed: up to five extra find walks per root (~135 ms -> 240 ms
# on /usr, 9080 files). --no-count-filtered skips them, and the run says so rather than print zeros.
COUNT_FILTERED=1
DEBUG=0
DRY_RUN=0
RETRIES=3

# The age half of the discovery policy, built once per run by build_age_tests and used by BOTH
# the walk and the symlink-target test, so the two can never drift apart. Empty when the age
# filter is off (--max-age 0).
declare -a AGE_TESTS=()
# The two arms of AGE_TESTS kept separately, so the counting pass can ask "which arm matched
# this file" without re-deriving the window.
declare -a AGE_MTIME_TEST=()
declare -a AGE_CTIME_TEST=()
# The size half of the same policy: six call sites consume it, and a bound that drifted between
# them would silently mean two different policies in one run.
declare -a SIZE_TEST=()
# The POSITIVE spelling of "over the limit", used by the counting walk. It is not merely the
# negation of SIZE_TEST: '! -size -Nc' is also true for a file whose size cannot be READ, and
# find answers '-type f' from the directory entry without a stat, so under a directory that is
# readable but not searchable (mode 0444 — an ordinary non-root situation) every file in it was
# reported as "over the size limit". Reproduced as an unprivileged user: four 100-byte files
# counted as oversize. '-size +Mc' is false when the stat fails, so it counts only files
# actually measured to be too big.
declare -a OVERSIZE_TEST=()
AGE_PRECISION=""       # "minute" or "day" — which predicate family the local find supports
AGE_CUTOFF_TEXT=""     # human-readable absolute cutoff, for the run log ("" if date cannot help)
AGE_FUTURE_REF=""      # file stamped at run start, for the POSIX -newer future-timestamp test

UPLOAD_TOOL=""
# every temp file the collector makes lives in ONE private work directory (created on
# demand, mode 700), which is excluded from scanning by exact path — the collector must
# never collect its own working files. Cleanup is a single rm -rf of this directory.
TS_WORK_DIR=""
declare -a CURL_EXTRA_OPTS=()
declare -a WGET_EXTRA_OPTS=()

# Keep defaults simple and stable for Bash 3+.
# /dev/shm and /run are tmpfs: memory-backed staging areas that Linux malware routinely writes
# to and that leave no trace on disk, so they are scanned by default even though /dev and /run
# are otherwise excluded. Do not remove them as "virtual" paths — the sibling Go
# collector covers them too (it skips proc/sysfs/network filesystems, not tmpfs). Both are
# absent on macOS/BSD, where a missing default is skipped quietly.
SCAN_FOLDERS=('/root' '/tmp' '/home' '/var' '/usr' '/dev/shm' '/run')
# 1 once the operator supplies dirs via --dir/positional (defaults replaced). Lets us treat
# an unreadable explicitly-named dir as a collection failure, but an unreadable built-in
# default dir (e.g. /root on a non-root run) as best-effort — preserving graceful degradation.
SCAN_FOLDERS_FROM_USER=0
# Follow symbolic links when scanning. Default off: a symlinked scan root is absolutized
# but not dereferenced. --follow-symlinks resolves symlinks to the real target instead.
FOLLOW_SYMLINKS=0

FILES_SCANNED=0
FILES_SUBMITTED=0
FILES_SKIPPED=0        # discovered, then skipped by policy. Structurally 0: the size and age
# gates live inside find, so an excluded file is never discovered in the first place. It is kept
# in the summary for compatibility with existing scrapers; the files those gates removed are
# counted below instead. Retiring the key entirely is a breaking change to the summary contract.
# What the size and age gates removed at DISCOVERY, disjoint by construction — a file that is
# both oversize and too old counts once, as size:
#   size_filtered = regular files failing the size gate
#   age_filtered  = regular files passing size but failing the age gate
FILES_AGE_FILTERED=0
FILES_SIZE_FILTERED=0
# Files the ctime arm ALONE brought in under "any". ctime moves on chmod/chown/hardlink/package
# upgrades and can multiply the collection; the size of that trade is reported, not left to be
# inferred from the server's sample count.
FILES_AGE_CTIME_ONLY=0
# Set when the policy counts do not reconcile with the tree: they are measured after the discovery
# walk, so a directory changing in between makes them a snapshot. Reported, never silently corrected.
COUNT_CHURNED=0
# Set when no forward-stamped reference could be made, so future= was never measured for a root.
FUTURE_UNMEASURED=0
# Collected files whose mtime is ahead of the host clock. Collected, never excluded — a forward
# stomp must not hide a file any more than a backward one — but counted and warned, because a
# future timestamp is itself an indicator and how clock skew becomes visible on a fleet.
FILES_FUTURE=0
# A discovered file that was not collected is FAILED, whatever the reason — the convention of
# rsync ("partial transfer", code 23; "vanished", code 24) and of tar/find on unreadable input.
# The breakdown names the reason. Identity, checked at reconciliation:
# FILES_FAILED = FILES_UNREADABLE + FILES_VANISHED + FILES_UPLOAD_FAILED   (link uploads included)
FILES_FAILED=0
FILES_UNREADABLE=0     # discovered, then found unreadable ([ -r ] false; regular files and link targets)
FIRST_UNREADABLE=""    # first such path, named once in the end-of-run error
FILES_VANISHED=0       # discovered, then gone (or of another type) before it could be read
FILES_UPLOAD_FAILED=0  # readable, but every upload attempt failed (regular files and link targets)
# Directories find could not read. A directory is not an artifact: what it held is unknown, so
# the files missed cannot be counted — only the directories can (one find diagnostic each on
# GNU, BSD and busybox). Any such directory makes the run partial (exit 4).
UNREADABLE_DIRS=0
TOTAL_FILES=0
# Explicitly named scan targets that could not be scanned at all (missing, not a
# directory, unreadable, on a refused filesystem, or whose enumeration could not be completed).
# Reported as unusable_dirs=; any makes the run partial (exit 4). Skipped built-in defaults are
# best-effort and are not counted. Each refused operand counts once, however it was spelled.
UNUSABLE_DIRS=0
# Symlink accounting: every enumerated symlink ends up collected (target uploaded),
# skipped (exactly one breakdown counter below names the reason), or failed (upload error or
# unreadable target — also counted in FILES_FAILED, with its FILES_* reason). Identities,
# checked at reconciliation:
# LINKS_SEEN    = LINKS_COLLECTED + LINKS_SKIPPED + LINKS_FAILED
# LINKS_SKIPPED = not_followed + dir_surfaced + fs_refused + self_excluded + in_scope
# + dup + filtered + dangling + unresolvable
LINKS_SEEN=0
LINKS_COLLECTED=0
LINKS_SKIPPED=0
LINKS_FAILED=0
LINKS_NOT_FOLLOWED=0   # default mode: link seen, following is off
LINKS_DIR_SURFACED=0   # directory link: listed, never traversed (opt in with --dir)
LINKS_FS_REFUSED=0     # target on a network or kernel pseudo-filesystem (refused before any stat)
LINKS_SELF_EXCLUDED=0  # target is the collector's own work directory or log file
LINKS_IN_SCOPE=0       # target inside a scan root: the walk already decided about it
LINKS_DUP=0            # another link already delivered this resolved target
# Which gate removed a link target, split so size_filtered= is not silently incomplete under
# --follow-symlinks. Reported as filtered_size=/filtered_age=, deliberately NOT as
# size_filtered=/age_filtered=: those keys already appear on the summary line, and a scraper
# taking the last match would read a link count where it wanted a file count.
LINKS_SIZE_FILTERED=0  # target over the size limit
LINKS_AGE_FILTERED=0   # target inside the size limit but outside the age window
LINKS_DANGLING=0       # dangling, or target is not a regular file (FIFO, device, socket)
LINKS_UNRESOLVABLE=0   # readlink unavailable, chain too long, or broken mid-chain
TOTAL_LINKS=0          # symlinks among the discovered entries (for the discovery summary)
SCAN_ID=""

PROGRESS_MODE=""  # auto (empty), "on", or "off"
SHOW_PROGRESS=0

SCRIPT_NAME="${0##*/}"
START_TS="$(date +%s 2>/dev/null || printf '%s\n' 0)"
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
# A "network filesystem" is another machine's storage mounted into this host's tree (NFS and
# SMB shares, SSHFS, cluster and S3/cloud FUSE mounts). Walking it would submit that machine's
# files as this host's evidence — again on every host mounting the same share — and a dead
# share or autofs trigger hangs the collector unkillably. Every comparable collector excludes
# them by default (the Go sibling unless --all-filesystems, UAC's exclude_file_system, GRR's
# physical-devices-only default). Names are matched exactly: there is deliberately no fuse.*
# prefix rule, because local FUSE filesystems (gocryptfs/encfs decrypted folders, bindfs,
# mergerfs, ntfs-3g as fuseblk) hold user data that must stay collectable.
NETWORK_FS_TYPES="nfs nfs4 cifs smbfs smb3 sshfs fuse.sshfs afp webdav davfs2 fuse.rclone fuse.s3fs 9p ceph fuse.ceph afs glusterfs fuse.glusterfs lustre ocfs2 gfs2 gpfs fuse.juicefs fuse.goofys fuse.gcsfuse fuse.blobfuse2 fuse.gvfsd-fuse"
SPECIAL_FS_TYPES="proc procfs sysfs devtmpfs devpts cgroup cgroup2 pstore bpf tracefs debugfs securityfs hugetlbfs mqueue autofs fusectl rpc_pipefs nsfs configfs binfmt_misc selinuxfs efivarfs ramfs"

# Cloud storage folder names — if any path segment matches (case-insensitive),
# the directory is pruned. Keep names with embedded spaces separate so the
# find-level pruning logic does not accidentally exclude generic names such as
# "Drive" or "Google" on unrelated paths.
CLOUD_DIR_NAMES="OneDrive Dropbox .dropbox GoogleDrive iCloudDrive Nextcloud ownCloud MEGA MEGAsync Tresorit SyncThing"
CLOUD_DIR_NAMES_SPACED="Google Drive|iCloud Drive"
CLOUD_DIR_PATTERNS="OneDrive -|OneDrive-|Nextcloud-"

# Mount table snapshot, taken once per run. The symlink gate consults it for every
# hop of every link, so re-reading and re-parsing the table per lookup was the dominant
# per-link cost. Two parallel indexed arrays keep this Bash 3.2-safe (no associative arrays).
declare -a MOUNT_POINTS=()
declare -a MOUNT_TYPES=()
MOUNT_TABLE_LOADED=0

# load_mount_table: fill MOUNT_POINTS/MOUNT_TYPES once. Linux reads /proc/mounts (mount
# points appear with '\040' for spaces — decoded). Where that cannot be read (macOS, the BSDs,
# a chroot or a container with a masked /proc) `mount` is parsed instead: BSD prints
# "dev on /point (type, opts)", util-linux and busybox print "dev on /point type ext4 (opts)"
# — without this the whole filesystem-class gate would be a silent no-op on exactly the
# platforms where autofs triggers and dead NFS mounts are most common. (util-linux mount itself
# needs /proc or a real /etc/mtab to print anything; an empty result lands on the "mount table
# unavailable" warning in main.) Parsing is line-oriented and quoted throughout, so a mount
# point containing spaces stays intact.
load_mount_table() {
    [ "$MOUNT_TABLE_LOADED" -eq 1 ] && return 0
    MOUNT_TABLE_LOADED=1
    local _dev _mp _fstype _rest _line _linux
    if [ -r /proc/mounts ]; then
        while IFS=' ' read -r _dev _mp _fstype _rest; do
            [ -n "$_mp" ] || continue
            # /proc/mounts escapes space, tab, newline and backslash as \040 \011 \012 \134;
            # decoding only the space left a mount point spelled with any of the others
            # unmatched by the string gate.
            _mp="${_mp//\\040/ }"
            _mp="${_mp//\\011/$'\t'}"
            _mp="${_mp//\\012/$'\n'}"
            _mp="${_mp//\\134/\\}"
            MOUNT_POINTS+=("$_mp")
            MOUNT_TYPES+=("$_fstype")
        done < /proc/mounts
        return 0
    fi
    command -v mount >/dev/null 2>&1 || return 0
    while IFS= read -r _line; do
        # Both shapes carry "dev on /point"; they differ in what follows. On util-linux and
        # busybox the options are ONE space-free word in parentheses, so the LAST word of the
        # line starts with "(":      dev on /point type fstype (rw,relatime)
        # BSD/macOS puts the type first inside a comma+space list, so the last word does not:
        # dev on /point (fstype, local, journaled)
        # The shape decides, not the word "type" — a BSD volume named "my type disk" must stay
        # intact — and the mount point is cut at the LAST " type " / " (" so a point containing
        # those characters survives.
        case "$_line" in
            *" on "*" ("*) ;;
            *) continue ;;
        esac
        _linux=0
        case "$_line" in
            *" on "*" type "*" ("*) case "${_line##* }" in "("*) _linux=1 ;; esac ;;
        esac
        _mp="${_line#* on }"
        if [ "$_linux" -eq 1 ]; then
            _mp="${_mp% type *}"
            _rest="${_line##* type }"
            _fstype="${_rest%% (*}"
        else
            _mp="${_mp% (*}"
            _rest="${_line##* (}"
            _fstype="${_rest%%,*}"
            _fstype="${_fstype%%)*}"
        fi
        _fstype="${_fstype# }"
        [ -n "$_mp" ] && [ -n "$_fstype" ] || continue
        MOUNT_POINTS+=("$_mp")
        MOUNT_TYPES+=("$_fstype")
    done <<< "$(mount 2>/dev/null)"
}

# excluded_mounts_lookup: mount points whose filesystem type is a network or kernel
# pseudo-filesystem, from the one-time snapshot, in the array EXCLUDED_MOUNTS_OUT — an array,
# not stdout, so a mount point containing a newline stays ONE path (and no fork). The collector
# consumes the array; get_excluded_mounts prints the same list one per line for
# scripts/tests/verify_portable.sh, which sources this file.
declare -a EXCLUDED_MOUNTS_OUT=()
excluded_mounts_lookup() {
    EXCLUDED_MOUNTS_OUT=()
    load_mount_table
    local _i=0
    while [ "$_i" -lt "${#MOUNT_POINTS[@]}" ]; do
        case " $NETWORK_FS_TYPES $SPECIAL_FS_TYPES " in
            *" ${MOUNT_TYPES[$_i]} "*) EXCLUDED_MOUNTS_OUT+=("${MOUNT_POINTS[$_i]}") ;;
        esac
        _i=$((_i + 1))
    done
}
# shellcheck disable=SC2317  # not called by the collector itself; kept for verify_portable.sh
get_excluded_mounts() {
    excluded_mounts_lookup
    local _m
    for _m in "${EXCLUDED_MOUNTS_OUT[@]+"${EXCLUDED_MOUNTS_OUT[@]}"}"; do printf '%s\n' "$_m"; done
}

# fs_type_lookup: filesystem type of the mount containing $1, by longest-prefix match over
# the snapshot. $1 is used as a STRING only — the path itself is never touched, which is what
# makes it safe to call before a target has been stat'ed. Result in FS_TYPE_OUT (no subshell,
# so the per-symlink gate costs no fork and no file read). Empty + return 1 when the
# mount table is unavailable or nothing matches — callers then keep path-based behavior.
# fs_type_of is the same lookup printed to stdout.
FS_TYPE_OUT=""
fs_type_lookup() {
    FS_TYPE_OUT=""
    load_mount_table
    local _path="$1" _best="" _best_type="" _mp _i=0
    while [ "$_i" -lt "${#MOUNT_POINTS[@]}" ]; do
        _mp="${MOUNT_POINTS[$_i]}"
        case "$_path" in
            "$_mp"|"$_mp"/*) : ;;
            *) [ "$_mp" = "/" ] || { _i=$((_i + 1)); continue; } ;;
        esac
        # Longest mount point wins; on equal length the later entry (mounted over) wins.
        if [ "${#_mp}" -ge "${#_best}" ]; then
            _best="$_mp"
            _best_type="${MOUNT_TYPES[$_i]}"
        fi
        _i=$((_i + 1))
    done
    [ -n "$_best_type" ] || return 1
    FS_TYPE_OUT="$_best_type"
}
# shellcheck disable=SC2317  # not called by the collector itself; kept for verify_portable.sh
fs_type_of() {
    fs_type_lookup "$1" || return 1
    printf '%s' "$FS_TYPE_OUT"
}

# fs_class_of_path: name the refused filesystem class for path $1 ("network filesystem" /
# "pseudo-filesystem") in FS_CLASS_OUT and return 0; return 1 when the path may proceed.
# String-only, like fs_type_lookup — safe before any access.
FS_CLASS_OUT=""
FS_CLASS_TYPE_OUT=""
fs_class_of_path() {
    FS_CLASS_OUT=""
    FS_CLASS_TYPE_OUT=""
    fs_type_lookup "$1" || return 1
    case " $NETWORK_FS_TYPES $SPECIAL_FS_TYPES " in
        *" $FS_TYPE_OUT "*) ;;
        *) return 1 ;;
    esac
    FS_CLASS_TYPE_OUT="$FS_TYPE_OUT"
    case " $NETWORK_FS_TYPES " in
        *" $FS_TYPE_OUT "*) FS_CLASS_OUT="network filesystem" ;;
        *)                  FS_CLASS_OUT="pseudo-filesystem" ;;
    esac
    return 0
}

# cloud_dir_evidence: decide whether a directory is REAL, actively-synced cloud storage.
# A name like "Dropbox" is only a hint — a user (or an attacker hiding files) can name any
# folder that way — so exclusion requires positive evidence: marker files that only the cloud
# client itself creates inside its sync root, or an OS-mandated cloud location. Cloud/network
# FUSE mounts are covered separately by fstype (excluded_mounts_lookup).
# Outputs the evidence label on stdout and returns 0 if proven; returns 1 when there is none.
cloud_dir_evidence() {
    local _d="$1" _f
    if [ -e "$_d/.dropbox.cache" ] || [ -e "$_d/.dropbox" ]; then
        printf 'dropbox markers'
        return 0
    fi
    if [ -d "$_d/.stfolder" ]; then
        printf 'syncthing marker'
        return 0
    fi
    if [ -d "$_d/.debris" ]; then
        printf 'megasync marker'
        return 0
    fi
    # Nextcloud/ownCloud desktop clients keep a sync database in the sync root. The glob is
    # guarded: with no match Bash keeps the literal pattern, which the -e test rejects.
    for _f in "$_d"/.sync_*.db; do
        if [ -e "$_f" ]; then
            printf 'nextcloud/owncloud sync database'
            return 0
        fi
    done
    case "$_d" in
        */Library/CloudStorage/*|*/Library/CloudStorage|*"/Library/Mobile Documents/"*|*"/Library/Mobile Documents")
            printf 'OS cloud location'
            return 0
            ;;
    esac
    return 1
}

# Helpers ---------------------------------------------------------------------

timestamp() {
    date "+%Y-%m-%d_%H:%M:%S" 2>/dev/null || date
}

cleanup_tmp_files() {
    if [ -n "$TS_WORK_DIR" ] && [ -d "$TS_WORK_DIR" ]; then
        rm -rf -- "$TS_WORK_DIR" 2>/dev/null || :
    fi
}

INTERRUPTED=0

# build_stats_json -- the run's counters as the marker payload's "stats" object, in
# STATS_JSON_OUT. $1 is the elapsed seconds to report.
#
# ONE spelling of this 19-field object, because there are two markers that carry it (the end
# marker and the interrupted marker) and they were written out twice, verbatim. That
# duplication is not hypothetical drift: max_size_kb was added to the end marker's copy and
# not to the interrupted one, so a run that was interrupted reported size_filtered= with no
# way to know which limit produced it. A shared builder makes that class of divergence
# unrepresentable rather than merely fixed once.
#
# size_bound_bytes accompanies max_size_kb because the wire format is the one place the KB/KiB
# ambiguity still bit: "kb" in a field name is exactly what the run log was rewritten to stop
# relying on, and a disabled size gate had to be INFERRED from max_size_kb:0 where the age gate
# states it outright with age_precision:"none". Derived from MAX_FILE_SIZE_KB, not from
# SIZE_TEST, so it is correct even when an interrupt fires before the policy arrays are built.
STATS_JSON_OUT=""
build_stats_json() {
    STATS_JSON_OUT="\"stats\":{\"scanned\":${FILES_SCANNED},\"submitted\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"age_filtered\":${FILES_AGE_FILTERED},\"size_filtered\":${FILES_SIZE_FILTERED},\"age_ctime_only\":${FILES_AGE_CTIME_ONLY},\"future\":${FILES_FUTURE},\"max_size_kb\":${MAX_FILE_SIZE_KB},\"size_bound_bytes\":$(( MAX_FILE_SIZE_KB * 1024 )),\"max_age\":${MAX_AGE},\"age_timestamp\":\"${AGE_TIMESTAMP}\",\"age_precision\":\"${AGE_PRECISION:-none}\",\"counts_measured\":${COUNT_FILTERED},\"failed\":${FILES_FAILED},\"links_seen\":${LINKS_SEEN},\"links_collected\":${LINKS_COLLECTED},\"links_skipped\":${LINKS_SKIPPED},\"unreadable_dirs\":${UNREADABLE_DIRS},\"unusable_dirs\":${UNUSABLE_DIRS},\"elapsed_seconds\":${1:-0}}"
}

send_interrupted_marker() {
    if [ "$DRY_RUN" -eq 0 ] && [ -n "$THUNDERSTORM_SERVER" ]; then
        local _elapsed=0
        local _now
        _now="$(date +%s 2>/dev/null || printf '%s\n' "$START_TS")"
        if [ "$START_TS" -gt 0 ] 2>/dev/null; then
            _elapsed=$(( _now - START_TS ))
            [ "$_elapsed" -lt 0 ] && _elapsed=0
        fi
        local _stats
        build_stats_json "$_elapsed"
        _stats="$STATS_JSON_OUT"
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
    # Exit 128+signum (130 SIGINT / 143 SIGTERM); the trap passes the code.
    exit "${1:-130}"
}

on_exit() {
    [ "$INTERRUPTED" -eq 0 ] && cleanup_tmp_files
}

trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

log_msg() {
    local level="$1"
    shift
    local message="$*"
    local ts
    local logger_prio
    local clean

    [ "$level" = "debug" ] && [ "$DEBUG" -ne 1 ] && return 0

    clean="$message"
    clean="${clean//$'\r'/ }"
    clean="${clean//$'\n'/ }"

    if [ "$LOG_TO_FILE" -eq 1 ] && [ "$LOG_FILE_READY" -eq 1 ]; then
        # the timestamp (a `date` fork) is only needed by the file sink — computing it
        # unconditionally cost one fork per logged message even with all sinks disabled.
        ts="$(timestamp)"
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
    # A usage error must never exit without reaching some sink: force the terminal while the log
    # file is not ready, and whenever every sink is disabled (--quiet --no-log-file, no --syslog).
    # die exits, so forcing the sink here changes nothing else.
    if [ "$LOG_FILE_READY" -ne 1 ] || { [ "$LOG_TO_CMDLINE" -eq 0 ] \
        && [ "$LOG_TO_FILE" -eq 0 ] && [ "$LOG_TO_SYSLOG" -eq 0 ]; }; then
        LOG_TO_CMDLINE=1
    fi
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
  -d, --dir <path>           Directory to scan (repeatable; replaces the defaults)
  --max-age <days>           Collect files younger than <days>; 0 = no age filter (default: 14)
  --age-timestamp <which>    File clock --max-age is measured on: mtime, ctime, or any
                             of the two (default: any - a backdated mtime cannot hide a file)
  --max-size <kb>            Collect files up to <kb> KiB (1 KiB = 1024 bytes);
                             0 = no size filter (default: 2000 KiB = 2048000 bytes)
                             (--max-size-kb is the former name and still works)
  --no-count-filtered        Skip the counting walks; age_filtered=, size_filtered=,
                             age_ctime_only= and future= then read 0, unmeasured
  --source <name>            Source identifier (default: hostname)
  --ssl                      Use HTTPS
  -k, --insecure             Skip TLS certificate verification
  --ca-cert <path>           Path to custom CA certificate bundle for TLS
  --sync                     Use /api/check (default: /api/checkAsync)
  --retries <num>            Retry attempts per file (default: 3)
  --follow-symlinks          Collect the files symlinks point to (default: off)
  --dry-run                  Show what would be submitted; contact no server
  --progress                 Force progress reporting
  --no-progress              Disable progress reporting
  --debug                    Enable debug log messages
  --log-file <path>          Log file path (default: ./thunderstorm.log)
  --no-log-file              Disable file logging
  --syslog                   Enable syslog logging
  --quiet                    Disable command-line logging
  -h, --help                 Show this help text

Notes:
  Long options also accept the --option=value form. Short options take the next argument:
  they do not bundle (-dk) and do not accept -d=value. For a directory whose name starts
  with '-', use './-name', an absolute path, or end the options with '--'.
  Bare arguments are scan directories too. The first directory you supply
  replaces the built-in defaults: /root /tmp /home /var /usr /dev/shm /run.
  A directory you name that cannot be scanned is an error (exit 4);
  an unavailable built-in default is only a warning.
  Directories named twice, or inside one another, are scanned once.
  Symbolic links are never followed by default. With --follow-symlinks a link to a FILE is
  collected under its real path; a link to a DIRECTORY is listed and scanned only if you
  name it with --dir.
  --max-age counts 24-hour periods measured when each directory is reached, not calendar days:
  --max-age 14 keeps files strictly younger than 14x24h, so a file aged exactly 14x24h is left
  out. The window is evaluated to the minute; where find has no -mmin it falls back to whole
  days and the exact boundary becomes that find's own rounding: GNU keeps the exactly-14x24h
  file, busybox drops it, and BSD/macOS rounds the age UP, which makes the window up to a day
  TIGHTER there (--max-age 1 collects nothing). Prefer a find with -mmin when the edge matters.
  --max-age 0 turns the age filter OFF and collects every file whatever its timestamp. The
  window is measured against the modification time OR the inode change time (ctime), because
  anyone who can write a file can backdate its mtime with touch while ctime cannot be set that
  way; --age-timestamp mtime narrows it to mtime alone, ctime to ctime alone. A file whose
  timestamp lies in the future is always collected, and counted in future=. The run summary
  reports age_filtered= and size_filtered= for what the two gates removed at discovery, and
  age_ctime_only= for the files the ctime arm alone brought in.
  --max-size is measured in KiB (1024 bytes), as in the Go collector, and the bound is
  INCLUSIVE: --max-size 2000 collects a file of exactly 2048000 bytes and leaves out one of
  2048001. It is measured on the file's apparent size — the bytes that would go on the wire —
  so a sparse file counts as its full logical length. A zero-byte file is inside every bound.
  --max-size 0 turns the size filter OFF, the way --max-age 0 turns the age filter off.
  With --follow-symlinks the same bound is applied to a link's resolved TARGET, not to the
  link; a target the gate removes is counted in the symlink breakdown's filtered=, which does
  not split size from age, rather than in size_filtered=.
  The size limit bounds DISCOVERY only. It is not a promise about what the server will accept:
  a Thunderstorm behind a reverse proxy may cap how long one upload request may take, which
  makes the largest deliverable file a function of your bandwidth rather than of this flag.
  Never collected: kernel pseudo-filesystems, network filesystems unless you name them, and
  cloud-sync folders excluded on positive evidence (their client's marker files).
  scripts/bash/README.md documents the exclusion, accounting and exit-code rules in full.

Exit codes:
  0 success · 1 runtime error · 2 usage/config · 3 missing dependency · 4 partial failure
  5 partial: files vanished mid-run (host churn only) · 130/143 interrupted

Examples:
  bash thunderstorm-collector.sh --server thunderstorm.local
  bash thunderstorm-collector.sh --server 10.0.0.5 --ssl --dir "/tmp/My Files" --dry-run
  bash thunderstorm-collector.sh --server=thunderstorm.local --dir=/evidence --max-age=30
EOF
}

is_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# in_range -- true when the unsigned decimal $1 (already checked with is_integer) is <= $2.
# Leading zeros are dropped and the digit COUNT is compared before the values are, so a
# 30-digit input never reaches Bash arithmetic: `[ n -le m ]` on an oversized number prints a
# raw shell diagnostic, and `$(( kb * 1024))` wraps silently — either way the user would have
# seen a find failure ("could not be read", zero files, exit 0) instead of a usage error.
in_range() {
    local _v="$1"
    _v="${_v#"${_v%%[!0]*}"}"
    [ -n "$_v" ] || _v=0
    [ "${#_v}" -lt "${#2}" ] && return 0
    [ "${#_v}" -gt "${#2}" ] && return 1
    [ "$_v" -le "$2" ]
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
    # This value is attacker-influenced (it is the collected file's own path) and is spliced
    # into a curl -F value and a Content-Disposition header, so every byte with meaning in
    # either grammar must go. The comma is not cosmetic: curl splits an -F value on ',' into
    # its documented MULTI-FILE list — even inside a filename= sub-parameter — so a path
    # containing ",/etc/shadow" made curl open and upload that second file, past every policy
    # gate, with the run still reporting success. ';' ends a sub-parameter, '"' and '\' break
    # the quoted header, CR/LF inject header lines.
    input="${input//\"/_}"
    input="${input//;/_}"
    input="${input//,/_}"
    input="${input//\\/_}"
    input="${input//$'\r'/_}"
    input="${input//$'\n'/_}"
    [ -z "$input" ] && input="sample.bin"
    printf "%s" "$input"
}

# ensure_work_dir -- create the private work directory on first use (atomic mkdir under
# umask 077 => mode 700; safe against symlink swaps in a shared /tmp). If a directory with
# our name already exists (a crashed run's leftover with a recycled PID), reuse it only
# when we own it and can write to it — never a directory someone else pre-created.
ensure_work_dir() {
    [ -n "$TS_WORK_DIR" ] && return 0
    local _dir="${TMPDIR:-/tmp}/thunderstorm.work.$$"
    # A TMPDIR spelled with a leading dash would make every scratch path an option to cat/grep/
    # mktemp — in a real run upload_with_curl then reads no HTTP status and counts the upload as
    # submitted whatever the server answered. './' keeps it a plain operand (same idiom as
    # resolve_dir for the name '-').
    case "$_dir" in -*) _dir="./$_dir" ;; esac
    if ! ( umask 077 && mkdir -- "$_dir" ) 2>/dev/null; then
        if [ ! -d "$_dir" ] || [ ! -O "$_dir" ] || [ ! -w "$_dir" ]; then
            return 1
        fi
    fi
    TS_WORK_DIR="$_dir"
}

# mktemp_portable -- create a temp file inside the private work directory and print its
# path. mktemp(1) flags differ across GNU/BSD, so a template is used; when mktemp is
# missing entirely, a predictable name is safe because the directory itself is mode 700.
mktemp_portable() {
    ensure_work_dir || return 1
    local t
    t="$(mktemp -- "$TS_WORK_DIR/f.XXXXXX" 2>/dev/null)"
    if [ -n "$t" ] && [ -f "$t" ]; then
        printf '%s\n' "$t"
        return 0
    fi
    t="$TS_WORK_DIR/f.${RANDOM:-0}.$(date +%N 2>/dev/null || printf '%s\n' 0)"
    : > "$t" 2>/dev/null || return 1
    printf '%s\n' "$t"
}

# scratch_file -- print the path of the per-run scratch file named $1 inside the private work
# directory, truncated. Uploads used to take three fresh temp files per attempt (four with
# wget, one of them a complete multipart copy of the file being sent) and released none of them
# until exit: a 16k-file collection left ~50k files behind in the work directory, and on the
# wget path the directory grew by the size of the entire collection — on the host being
# triaged. Fixed names bound that to a handful of files and the largest single upload, and save
# three mktemp forks per file. The directory is mode 700, so the names carry no risk.
scratch_file() {
    ensure_work_dir || return 1
    : > "$TS_WORK_DIR/$1" 2>/dev/null || return 1
    printf '%s\n' "$TS_WORK_DIR/$1"
}

# resolve_dir -- canonicalize an existing, readable directory ($2) into RESOLVE_DIR_OUT.
# $1 is the cd mode: -L keeps symlinks (default), -P resolves them (--follow-symlinks).
# cd runs in a subshell so the caller's cwd is untouched; 'unset CDPATH' and discarding cd's
# stdout keep a CDPATH echo out of the capture; 'cd --' makes a leading-dash name safe, except
# the exact name '-', which cd reads as "previous directory" and is therefore spelled './-'.
# The 'printf x' sentinel preserves a name ending in a newline, and the result travels in a
# variable rather than on stdout so no caller can strip it again.
# A leading '//' is collapsed to '/': POSIX leaves it implementation-defined and Bash keeps it,
# but find prints the root as given, so a '//'-spelled root would defeat every absolute -path
# prune and the mount lookup.
# Returns non-zero with RESOLVE_DIR_OUT empty when cd or pwd fails, so the caller can keep the
# original path instead of dropping the directory.
resolve_dir() {
    local _mode="$1" _dir="$2" _out
    RESOLVE_DIR_OUT=""
    case "$_dir" in -) _dir="./-" ;; esac
    _out="$( unset CDPATH; cd "$_mode" -- "$_dir" >/dev/null 2>&1 && pwd && printf x )" || return 1
    _out="${_out%x}"
    _out="${_out%$'\n'}"
    case "$_out" in //*) _out="/${_out#"${_out%%[!/]*}"}" ;; esac
    [ -n "$_out" ] || return 1
    RESOLVE_DIR_OUT="$_out"
}

# walk_reaches -- true when a walk rooted at the scanned directory $1 has reached the directory
# $2 (which lies under $1): no exclusion anchor among $3.. covers $2 without also covering $1
# (an anchor equal to the root is dropped), no proven cloud folder sits between them,
# and $2 is not under a macOS CloudStorage location the root itself is outside of. Used by the
# overlap rule: a child root the parent's walk already covered would be collected twice; a
# child the parent's walk pruned is the explicit-into-excluded case and must be scanned.
walk_reaches() {
    local _parent="$1" _child="$2" _a _p
    shift 2
    for _a in "$@"; do
        if path_covers "$_a" "$_child" && ! path_covers "$_a" "$_parent"; then
            return 1
        fi
    done
    case "$_parent" in
        */Library/CloudStorage|*/Library/CloudStorage/*) ;;
        *) case "$_child" in */Library/CloudStorage|*/Library/CloudStorage/*) return 1 ;; esac ;;
    esac
    _p="$_child"
    while [ -n "$_p" ] && [ "$_p" != "$_parent" ]; do
        cloud_dir_evidence "$_p" >/dev/null && return 1
        _p="${_p%/*}"
        [ -z "$_p" ] && _p="/"
    done
    return 0
}

# resolve_link_chain -- follow the symlink at $1 to its final path without letting a stat touch a
# filesystem the collector refuses. Every hop BEYOND the link itself is passed through the
# string-only filesystem-class gate before it is lstat'ed; because that lookup matches by longest
# mount prefix, a refused ancestor mount refuses the whole path. This is what stops a chain whose
# second hop lands on a dead NFS export or an autofs trigger from parking the run in D state.
# The link's own path is not gated: it was already lstat'ed by the walk, and gating it would
# refuse every link inside an explicitly named network root whatever its target.
# Hops are followed WITHOUT lexical normalization so the kernel resolves a '..' beside a
# symlinked component, while the gate sees the normalized form. 40-hop cap above the kernel's
# ELOOP. The final path may be of any type; the caller classifies it.
# Results (never on stdout, so nothing can strip a trailing newline):
#   LINK_CHAIN_OUT   final path, on return 0
#   LINK_CHAIN_ERR   on return 1: noreadlink | broken | toolong | refused
#   LINK_CHAIN_PATH / LINK_CHAIN_TYPE / LINK_CHAIN_CLASS   detail for the refused case
LINK_CHAIN_OUT=""
LINK_CHAIN_ERR=""
LINK_CHAIN_PATH=""
LINK_CHAIN_TYPE=""
LINK_CHAIN_CLASS=""
resolve_link_chain() {
    LINK_CHAIN_OUT=""
    LINK_CHAIN_ERR=""
    LINK_CHAIN_PATH=""
    LINK_CHAIN_TYPE=""
    LINK_CHAIN_CLASS=""
    command -v readlink >/dev/null 2>&1 || { LINK_CHAIN_ERR="noreadlink"; return 1; }
    local _cur="$1" _gate _tgt _hops=0
    # Hop 0 is the link itself: the walk's find already lstat'ed it, so testing it here
    # touches nothing new — and gating its OWN path would refuse every link inside an
    # explicitly named network root (explicit scope wins) whatever the target.
    while [ -h "$_cur" ]; do
        _hops=$((_hops + 1))
        [ "$_hops" -gt 40 ] && { LINK_CHAIN_ERR="toolong"; return 1; }
        # Byte-exact capture: command substitution strips ALL trailing newlines, which would
        # corrupt a target name ending in one. The guard 'x' preserves them; then only
        # readlink's own single delimiter newline is stripped (as in resolve_dir).
        _tgt="$(readlink "$_cur" 2>/dev/null && printf x)" || { LINK_CHAIN_ERR="broken"; return 1; }
        _tgt="${_tgt%x}"
        _tgt="${_tgt%$'\n'}"
        [ -n "$_tgt" ] || { LINK_CHAIN_ERR="broken"; return 1; }
        lexical_abs_path "$_cur" "$_tgt"
        _gate="$LEXICAL_ABS_OUT"
        if fs_class_of_path "$_gate"; then
            LINK_CHAIN_ERR="refused"
            LINK_CHAIN_PATH="$_gate"
            LINK_CHAIN_TYPE="$FS_CLASS_TYPE_OUT"
            LINK_CHAIN_CLASS="$FS_CLASS_OUT"
            return 1
        fi
        case "$_tgt" in
            /*) _cur="$_tgt" ;;
            *)  _cur="${_cur%/*}/$_tgt" ;;
        esac
    done
    LINK_CHAIN_OUT="$_cur"
    return 0
}

# canonical_file_path -- canonical path of the regular file $1: its directory resolved
# physically (resolve_dir -P) plus the original basename. Prints the result; callers capture
# with the "$( … && printf x)" sentinel so a name ending in a newline survives.
canonical_file_path() {
    local _dir="${1%/*}"
    [ -n "$_dir" ] || _dir="/"
    resolve_dir -P "$_dir" || return 1
    printf '%s' "${RESOLVE_DIR_OUT%/}/${1##*/}"
}

# path_covers -- true if $2 is $1 or lies underneath $1. Handles the root ("/") correctly,
# where the naive "$1"/* pattern would become "//*" and match nothing.
path_covers() {
    [ "$1" = "$2" ] && return 0
    case "$1" in
        /) case "$2" in /?*) return 0 ;; esac ;;
        *) case "$2" in "$1"/*) return 0 ;; esac ;;
    esac
    return 1
}

# spell_under_root -- how the walk rooted at $1 (as spelled) prints the physical path $3,
# given the root's physical location $2: '<root as spelled>/<tail of $3 below $2>'. find
# prints every entry under the spelling of its starting point and a physical walk never
# crosses a symlink, so this is the ONLY spelling an absolute -path prune can match — an
# artifact reached through a symlinked TMPDIR, cwd or intermediate directory matches neither
# its logical nor its physical spelling. Result in SPELL_UNDER_ROOT_OUT; returns 1 (result
# empty) when $3 does not lie under $2 — the walk cannot reach it. String operations only (no
# fork). Used for the collector's own artifacts, for child roots pruned from a parent's
# walk and for the exclusion anchors.
SPELL_UNDER_ROOT_OUT=""
spell_under_root() {
    SPELL_UNDER_ROOT_OUT=""
    path_covers "$2" "$3" || return 1
    if [ "$3" = "$2" ]; then
        SPELL_UNDER_ROOT_OUT="$1"
    else
        SPELL_UNDER_ROOT_OUT="${1%/}/${3#"${2%/}/"}"
    fi
}

# escape_find_glob -- make the literal path $1 safe as a find -path PATTERN. find matches -path
# with fnmatch(3), so '*', '?', '[' and '\' inside a real path silently turn an exact-path prune
# into a pattern: a log file named 'run[1].log' stopped excluding itself (the collector uploaded
# its own live log) and started excluding a user's 'run1.log' instead, and a proven cloud folder
# under such a path was announced as excluded and then walked. Pure string operations; result in
# FIND_GLOB_OUT (no fork). ']' needs no escape — it is literal outside a bracket expression.
FIND_GLOB_OUT=""
escape_find_glob() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\*/\\*}"
    _s="${_s//\?/\\?}"
    _s="${_s//\[/\\[}"
    FIND_GLOB_OUT="$_s"
}

# lexical_abs_path -- absolutize a raw symlink target ($2) against the directory of the link
# it was read from ($1, absolute) and collapse '.'/'..' segments with STRING OPERATIONS ONLY —
# no filesystem access at all. The result is not canonical (a '..' beside a symlinked
# component resolves differently in the kernel); it exists solely so the filesystem-class
# gate can refuse a network / pseudo-fs target BEFORE the first stat touches it — a
# stat on a dead NFS share or an autofs trigger can hang the collector in D state. Result in
# LEXICAL_ABS_OUT (no subshell: nothing to fork, nothing to strip).
LEXICAL_ABS_OUT=""
lexical_abs_path() {
    local _link="$1" _rest="$2" _out="" _seg
    case "$_rest" in
        /*) _rest="${_rest#/}" ;;
        *)  _out="${_link%/*}" ;;
    esac
    while [ -n "$_rest" ]; do
        case "$_rest" in
            */*) _seg="${_rest%%/*}"; _rest="${_rest#*/}" ;;
            *)   _seg="$_rest";       _rest="" ;;
        esac
        case "$_seg" in
            ''|.) ;;
            ..)   _out="${_out%/*}" ;;
            *)    _out="$_out/$_seg" ;;
        esac
    done
    LEXICAL_ABS_OUT="${_out:-/}"
}

# link_skip -- account one enumerated symlink that will not be collected: bump the umbrella
# LINKS_SKIPPED and exactly one breakdown counter ($1 — a LINKS_* variable NAME written in
# this script, never external input; the arithmetic expansion increments it by name), then
# log the reason at level $2 with message $3.
link_skip() {
    LINKS_SKIPPED=$((LINKS_SKIPPED + 1))
    : "$(( $1 += 1 ))"
    log_msg "$2" "$3"
}

# link_fs_class_refused -- filesystem-class gate for a symlink target path ($2), accounting
# the link ($1) as fs_refused with the note $3 appended to the reason. The path is used as a
# STRING only (fs_class_of_path matches it against the mount snapshot and never touches it),
# so this is safe to call before the target has been accessed. Returns 0 when the link was
# refused and accounted, 1 when the target may proceed.
link_fs_class_refused() {
    fs_class_of_path "$2" || return 1
    link_skip LINKS_FS_REFUSED info "Skipping symlink '$1' -> '$2' (target on ${FS_CLASS_TYPE_OUT} ${FS_CLASS_OUT}${3})"
    return 0
}

# root_fs_class_refused -- the filesystem-class policy for a scan root whose location
# fs_class_of_path has just classified (FS_CLASS_OUT / FS_CLASS_TYPE_OUT are set): a kernel
# pseudo-filesystem is refused outright, a network filesystem is refused for built-in defaults
# only (explicit scope wins). $1 is the root as the operator sees it, $2 a note prefixed to the
# reason ("really '...'; " or empty). Returns 0 when the root was refused and reported, 1
# when it may proceed. Mirrors link_fs_class_refused; both gates of the root loop — the
# string-only one before any access and the physical one after resolution — go through here,
# so the two refusal messages and the pseudo/network/default decision exist exactly once.
root_fs_class_refused() {
    if [ "$FS_CLASS_OUT" = "pseudo-filesystem" ]; then
        report_unusable_dir "$1" "${2}on a ${FS_CLASS_TYPE_OUT} pseudo-filesystem (kernel data, not collectable)"
        return 0
    fi
    if [ "$SCAN_FOLDERS_FROM_USER" -eq 0 ]; then
        report_unusable_dir "$1" "${2}on a ${FS_CLASS_TYPE_OUT} network filesystem, excluded by default; name it with --dir to collect it"
        return 0
    fi
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

# http_status_is_terminal -- true ONLY for a 4xx the server means as a verdict about THIS
# request, which re-sending the same body cannot change: 413 Payload Too Large above all, since
# retrying it re-uploads the whole file for a guaranteed second refusal (CLAUDE.md §2: "retry
# only failures the protocol classifies as transient ... not most 4xx"). 408 and 429 are the two
# 4xx the protocol documents as retryable and are excluded.
#
# The default is RETRY, and the direction of that default is the whole point. Written the other
# way round -- "retryable unless in a known-good set" -- the status seen when a transfer dies
# partway is often not a verdict at all, and the collector silently stops retrying real transient
# failures. Measured: a peer that answers "100 Continue" and then drops the connection leaves
# HTTP/1.1 100 Continue as the ONLY status line in curl's -D file, so the parser yields 100;
# under the inverted spelling that ordinary network failure was classified non-retryable and the
# file was abandoned after one attempt instead of the configured --retries.
http_status_is_terminal() {
    case "$1" in
        408|429)     return 1 ;;
        4[0-9][0-9]) return 0 ;;
        *)           return 1 ;;
    esac
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

    resp_file="$(scratch_file curl.resp)" || return 91
    header_file="$(scratch_file curl.hdr)" || return 91

    # The file is streamed from stdin ('@-'), never named to curl as '@path': curl splits an
    # -F value on ';' and honours sub-parameters, so a collected file whose own name contains
    # ';filename=' or ';type=' would rewrite the multipart metadata. The shell opens the path
    # (no parsing), curl reads fd 0, and only the sanitized filename reaches the form.
    local form_arg="file=@-;filename=${safe_filename}"

    local err_file
    err_file="$(scratch_file curl.err)" || return 91

    # A total timeout alone leaves a black-holed SYN eating the whole budget per file
    # (CLAUDE.md §2 asks for connect AND total). --max-time bounds the transfer; note it is a
    # CLIENT bound only — a reverse proxy in front of Thunderstorm may enforce a much shorter
    # per-request window, in which case it, not this value, decides the largest file that can
    # actually be delivered. See the note in submit_file.
    curl -sS --show-error -X POST "${CURL_EXTRA_OPTS[@]}" \
        --connect-timeout 10 \
        --max-time 300 \
        -D "$header_file" \
        "$endpoint" \
        -F "$form_arg" \
        < "$filepath" > "$resp_file" 2>"$err_file"
    code=$?

    if [ $code -ne 0 ]; then
        local _curl_err
        _curl_err="$(cat "$err_file" 2>/dev/null)"
        [ -n "$_curl_err" ] && log_msg debug "curl error: $_curl_err"
    fi

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
        # The server's verdict must not be thrown away just because the transfer also failed.
        # curl exits 18 (partial transfer) / 28 (timeout) when a proxy closes the request
        # mid-body, and the status line it already sent was being discarded here: the operator
        # saw only "code 18" for what was in fact a reported HTTP 502. Observed against a live
        # Thunderstorm behind a proxy with a ~60 s per-request window: a 450 MB upload was cut
        # at 60 s with 502, three times over, and nothing in the log named the status.
        if [ -n "$http_code" ]; then
            log_msg error "Upload of '$filepath' failed after the server returned HTTP $http_code (curl exit $code, transfer incomplete)"
            http_status_is_terminal "$http_code" && return 97
        fi
        # A transfer that dies partway through a large body is usually the peer's per-request
        # window, not a flaky link — and every retry re-sends the whole file. Name the knob.
        case "$code" in
            18|28) log_msg warn "'$filepath' was cut off mid-transfer; if this repeats for large files the server or a proxy in front of it is enforcing a shorter per-request window than this client — lower --max-size so files stay inside it" ;;
        esac
        return $code
    fi

    # Only 2xx responses count as a successful submission.
    if [ -n "$http_code" ]; then
        case "$http_code" in
            2[0-9][0-9]) ;;
            *)
                local body
                body="$(cat "$resp_file" 2>/dev/null)"
                body="${body//$'\r'/ }"
                body="${body//$'\n'/ }"
                log_msg error "Server returned HTTP $http_code for '$filepath': $body"
                http_status_is_terminal "$http_code" && return 97
                return 92
                ;;
        esac
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

    safe_filename="$(sanitize_filename_for_multipart "$filename")"

    # Generate a boundary that does not appear in the file content or metadata.
    # Retry with different random seeds to avoid multipart corruption.
    local _boundary_attempts=0
    boundary="----ThunderstormBoundary${$}${RANDOM}${RANDOM}$(date +%s%N 2>/dev/null || printf '%s\n' 0)"
    while [ "$_boundary_attempts" -lt 10 ]; do
        # '-e' is not optional: the boundary begins with '----', so without it grep parses the
        # pattern as an option bundle, exits 2 WITHOUT READING A BYTE, 2>/dev/null hides the
        # diagnostic and the leading '!' turns that error into "no collision found". The guard
        # was inert for every file; a file containing the boundary would have silently produced
        # a corrupt multipart body.
        if ! LC_ALL=C grep -qF -e "$boundary" "$filepath" 2>/dev/null; then
            # Also check it doesn't appear in metadata fields
            case "${SOURCE_NAME}${filepath}" in
                *"$boundary"*) ;;
                *) break ;;
            esac
        fi
        _boundary_attempts=$((_boundary_attempts + 1))
        boundary="----ThunderstormBoundary${$}${RANDOM}${RANDOM}${_boundary_attempts}$(date +%s%N 2>/dev/null || printf '%s\n' 0)"
    done
    if [ "$_boundary_attempts" -ge 10 ]; then
        log_msg warn "Could not find safe multipart boundary for '$filepath', upload may be malformed"
    fi
    body_file="$(scratch_file wget.body)" || return 91
    resp_file="$(scratch_file wget.resp)" || return 91
    header_file="$(scratch_file wget.hdr)" || return 91

    # _body_rc, not the compound's own status: a brace group reports the exit status of its LAST
    # command, so a 'cat' that failed (the file vanished or became unreadable between the
    # pre-open check and here) was masked by the trailing printf. The group then succeeded, the
    # body went out with an EMPTY file part, the server answered 200 and the run reported the
    # file as submitted — a collector claiming to have collected bytes it never sent. Braces do
    # not fork, so the assignment inside is visible here.
    local _body_rc=0
    {
        printf -- "--%s\r\n" "$boundary"
        printf 'Content-Disposition: form-data; name="file"; filename="%s"\r\n' "$safe_filename"
        printf 'Content-Type: application/octet-stream\r\n\r\n'
        cat "$filepath" || _body_rc=1
        printf '\r\n--%s--\r\n' "$boundary"
    # 91, like every other local failure in this function. These used to return 93, 94 and 95 —
    # the codes submit_file reads as "503 back-pressure", "no longer a regular file" and (since
    # the terminal-verdict sentinel was added) "the server refused it". A full disk here was
    # therefore reported as a server verdict and the file was dropped without a retry.
    } > "$body_file" 2>/dev/null || _body_rc=1
    if [ "$_body_rc" -ne 0 ]; then
        # Classify honestly: gone or no longer a regular file is churn (94 -> vanished=, exit 5);
        # anything else is a local failure (91), never a silent success.
        if [ ! -f "$filepath" ]; then
            log_msg warn "'$filepath' disappeared while its upload body was being built; not uploaded"
            return 94
        fi
        log_msg error "Could not build the upload body for '$filepath'"
        return 91
    fi

    # --tries=1: wget retries network-level failures 20 times by default (measured: one
    # collector attempt opened 20 connections when the peer reset mid-upload), which silently
    # multiplied RETRIES=3 into up to 60 full-body uploads of the same file. Retry policy
    # belongs to submit_file, which counts and logs its attempts; the tool must not add its own
    # (CLAUDE.md §2, "bound total attempts including any tool's own retry policy").
    # --timeout is wget's dns/connect/read timeout, not a total, so it is not a transfer bound.
    wget -S -O "$resp_file" "${WGET_EXTRA_OPTS[@]}" \
        --tries=1 \
        --timeout=300 \
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
        # wget exits 8 for EVERY HTTP error response, so returning here unconditionally made the
        # status classification below unreachable on this path: a 413 was retried --retries times
        # exactly as before. The server's verdict is honoured first, as on the curl path.
        if [ -n "$http_code" ]; then
            log_msg error "Upload of '$filepath' failed after the server returned HTTP $http_code (wget exit $code)"
            http_status_is_terminal "$http_code" && return 97
        fi
        return $code
    fi

    # Only 2xx responses count as a successful submission.
    if [ -n "$http_code" ]; then
        case "$http_code" in
            2[0-9][0-9]) ;;
            *)
                local body
                body="$(tr '\r\n' '  ' < "$resp_file" 2>/dev/null)"
                log_msg error "Server returned HTTP $http_code for '$filepath': $body"
                http_status_is_terminal "$http_code" && return 97
                return 96
                ;;
        esac
    fi

    return 0
}

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
        # Attempt POST — capture HTTP status to detect server-side errors
        if command -v curl >/dev/null 2>&1; then
            curl -sS -D "$header_file" -o "$resp_file" "${CURL_EXTRA_OPTS[@]}" \
                --connect-timeout 10 \
                -H "Content-Type: application/json" \
                -d "$body" \
                --max-time 10 \
                "$marker_url" 2>/dev/null
            _marker_rc=$?
        elif command -v wget >/dev/null 2>&1; then
            wget -S -O "$resp_file" "${WGET_EXTRA_OPTS[@]}" \
                --tries=1 \
                --header "Content-Type: application/json" \
                --post-data "$body" \
                --timeout=10 \
                "$marker_url" 2>"$header_file"
            _marker_rc=$?
        fi
        # Validate the HTTP status code even when wget exits non-zero on 4xx/5xx.
        # 404/501 means the server doesn't implement marker endpoint; continue without scan_id.
        _http_code="$(grep -oE 'HTTP/[0-9.]+[[:space:]]+[0-9]+' "$header_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"
        if [ -n "$_http_code" ]; then
            case "$_http_code" in
                2[0-9][0-9])
                    _marker_rc=0
                    ;;
                404|501)
                    log_msg warn "Collection marker '$marker_type' not supported (HTTP $_http_code) — server does not implement /api/collection"
                    _marker_rc=0
                    ;;
                *)
                    log_msg warn "Collection marker '$marker_type' received HTTP $_http_code"
                    _marker_rc=1
                    ;;
            esac
        elif [ "$_marker_rc" -eq 0 ]; then
            # Some clients may succeed without exposing a parseable status line.
            _marker_rc=0
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
    local backoff=2
    local max_503_retries=5
    local _503_count=0

    # Preserve the client-side path in the multipart filename for server-side audit logs.
    # For a file reached through a symlink the caller passes the RESOLVED path, which is
    # both what gets opened and what the server is told.
    filename="$filepath"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_msg info "DRY-RUN: would submit '$filepath'"
        return 0
    fi

    # Last type check before the open. The upload opens the path through a shell redirect, so
    # if it has become a FIFO or a device since the discovery-time check the process blocks in
    # open(2) — where neither curl's --max-time nor an external timeout wrapper can reach it
    # (the redirect happens in the forked child before the wrapper is exec'd; verified: curl
    # --max-time 3 on a FIFO was still blocked after 20 s). Re-asserting the type here is what
    # UAC's _remove_non_regular_files and tar's file_dumpable_p amount to; it narrows the
    # window to the microseconds between this test and the redirect, which is the same residual
    # every copy tool carries. 94 = "no longer a regular file": churn, not an upload error.
    # Type only, deliberately not size. The size gate is a DISCOVERY filter: a file that grew
    # past --max-size since the walk is uploaded in full. Re-checking it here would cost a
    # fork per file (Bash has no stat builtin), undoing the measured 6851 ms -> 391 ms win from
    # moving the limit into find. Documented as an accepted residual in README.md rather than
    # paid for in the hot loop.
    if [ ! -f "$filepath" ]; then
        log_msg warn "'$filepath' is no longer a regular file; not uploaded"
        return 94
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

        # 95 = the server gave a verdict about THIS request that re-sending cannot change
        # (413 Payload Too Large above all). Retrying would re-upload the whole body for a
        # guaranteed second refusal, so the attempt budget is not spent on it.
        if [ "$rc" -eq 97 ]; then
            log_msg error "Server rejected '$filepath' with a non-retryable status; not retrying"
            return "$rc"
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
            sleep "$backoff"
            backoff=$((backoff * 2))
            # Cap backoff at 60 seconds
            [ "$backoff" -gt 60 ] && backoff=60
        fi
        try=$((try + 1))
    done

    return "$rc"
}

# add_scan_dir -- append one directory to the scan set. The first operator-supplied directory
# replaces the built-in defaults and marks the set as operator-supplied (which drives the
# explicit-vs-default failure handling in /). Shared by --dir, bare positional args, and
# operands following '--', so the "replace defaults once" rule lives in exactly one place.
add_scan_dir() {
    if [ "$SCAN_FOLDERS_FROM_USER" -eq 0 ]; then
        SCAN_FOLDERS=()
        SCAN_FOLDERS_FROM_USER=1
    fi
    SCAN_FOLDERS+=("$1")
}

# report_unusable_dir -- log a scan target ($1) that cannot be scanned, with the reason ($2).
# An explicitly named target is a collection failure (counted in UNUSABLE_DIRS, reported as
# unusable_dirs= and driving the partial-failure exit); an unusable built-in default is
# best-effort (warn only), preserving
# graceful degradation. Shared by the (permission)  (missing/not-a-dir) checks.
report_unusable_dir() {
    if [ "$SCAN_FOLDERS_FROM_USER" -eq 1 ]; then
        log_msg error "Cannot scan '$1' ($2); not collected"
        UNUSABLE_DIRS=$((UNUSABLE_DIRS + 1))
    else
        log_msg warn "Skipping '$1' ($2)"
    fi
}

# require_value -- validate the value of an option that requires one. $1 = option name (for
# messages), $2 = number of args remaining at the option ($2 >= 2 means a value token
# follows), $3 = the candidate value, $4 = 1 when the value came from the '--option=value'
# form. Rejects a missing token, an empty string, an option-like '-...' token (a forgotten
# value — so it can't silently eat the next flag; except in the '=' form, where a leading
# dash is unambiguously a value), and a whitespace-only value. Dies with usage error (exit 2).
require_value() {
    if [ "$2" -lt 2 ]; then
        die "Missing value for $1"
    fi
    case "$3" in
        '') die "Empty value for $1" ;;
        -*)
            if [ "${4:-0}" -ne 1 ]; then
                # A negative number is a value the user meant, not a forgotten one: say so,
                # instead of reporting it as a missing value the way any other -token is.
                case "$3" in
                    -[0-9]*) die "$1 does not take a negative value: '$3'" ;;
                    *)       die "Missing value for $1 (got option-like token '$3')" ;;
                esac
            fi
            ;;
    esac
    case "$3" in
        *[![:space:]]*) ;;
        *)              die "Whitespace-only value for $1" ;;
    esac
}

parse_args() {
    local arg
    local _eq
    local _val

    while [ $# -gt 0 ]; do
        arg="$1"
        # accept the GNU '--option=value' form for value-taking long options by
        # splitting it into '--option value'. _eq marks the split so require_value can
        # accept a leading-dash value here ('--dir=-x' is unambiguously a value). A flag
        # option given '=value' is a usage error; anything else (e.g. '--bogus=x', '-d=x')
        # falls through unsplit to the normal unknown-option handling.
        _eq=0
        case "$arg" in
            --?*=*)
                _val="${arg#*=}"
                case "${arg%%=*}" in
                    --server|--port|--dir|--max-age|--age-timestamp|--max-size|--max-size-kb|--source|--ca-cert|--retries|--log-file)
                        arg="${arg%%=*}"
                        set -- "$arg" "$_val" "${@:2}"
                        _eq=1
                        ;;
                    --ssl|--insecure|--sync|--follow-symlinks|--dry-run|--debug|--no-log-file|--syslog|--quiet|--progress|--no-progress|--no-count-filtered|--help)
                        die "Option ${arg%%=*} does not take a value"
                        ;;
                esac
                ;;
        esac
        case "$arg" in
            -h|--help)
                print_help
                exit 0
                ;;
            -s|--server)
                require_value "$arg" "$#" "${2:-}" "$_eq"
                THUNDERSTORM_SERVER="$2"
                shift
                ;;
            -p|--port)
                require_value "$arg" "$#" "${2:-}" "$_eq"
                THUNDERSTORM_PORT="$2"
                shift
                ;;
            -d|--dir)
                require_value "$arg" "$#" "${2:-}" "$_eq"
                add_scan_dir "$2"
                shift
                ;;
            --max-age)
                require_value "$arg" "$#" "${2:-}" "$_eq"
                MAX_AGE="$2"
                shift
                ;;
            --age-timestamp)
                require_value "$arg" "$#" "${2:-}" "$_eq"
                # Validated here rather than in validate_config so the message can name the
                # accepted set; is_integer-style checks would not.
                case "$2" in
                    mtime|ctime|any) AGE_TIMESTAMP="$2" ;;
                    *) die "--age-timestamp must be 'mtime', 'ctime' or 'any': '$2'" ;;
                esac
                shift
                ;;
            # --max-size is the canonical spelling: --max-age does not carry "days" in its
            # name either, and the unit belongs in the documentation and the run log (see
            # log_size_policy), not in the flag. --max-size-kb is the original spelling and
            # keeps working unchanged — it is in deployed runbooks and CI, and breaking a
            # documented flag of a forensic collector is not worth the tidiness.
            --max-size|--max-size-kb)
                require_value "$arg" "$#" "${2:-}" "$_eq"
                MAX_FILE_SIZE_KB="$2"
                MAX_SIZE_FLAG="$arg"
                shift
                ;;
            --source)
                require_value "$arg" "$#" "${2:-}" "$_eq"
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
                require_value "$arg" "$#" "${2:-}" "$_eq"
                CA_CERT="$2"
                USE_SSL=1
                shift
                ;;
            --sync)
                ASYNC_MODE=0
                ;;
            --follow-symlinks)
                FOLLOW_SYMLINKS=1
                ;;
            --retries)
                require_value "$arg" "$#" "${2:-}" "$_eq"
                RETRIES="$2"
                shift
                ;;
            --no-count-filtered)
                COUNT_FILTERED=0
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --debug)
                DEBUG=1
                ;;
            --log-file)
                require_value "$arg" "$#" "${2:-}" "$_eq"
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
                # End of options: every remaining argument is a scan directory (operand),
                # including names that begin with '-'. Consume them all, then stop parsing.
                shift
                while [ $# -gt 0 ]; do
                    add_scan_dir "$1"
                    shift
                done
                break
                ;;
            -*)
                die "Unknown option: $arg (use --help)"
                ;;
            *)
                # Bare positional args are treated as scan directories.
                add_scan_dir "$arg"
                ;;
        esac
        shift
    done
}

validate_config() {
    is_integer "$THUNDERSTORM_PORT" || die "Port must be numeric: '$THUNDERSTORM_PORT'"
    is_integer "$MAX_AGE" || die "max-age must be numeric: '$MAX_AGE'"
    is_integer "$MAX_FILE_SIZE_KB" || die "${MAX_SIZE_FLAG#--} must be numeric: '$MAX_FILE_SIZE_KB'"
    is_integer "$RETRIES" || die "retries must be numeric: '$RETRIES'"

    # Upper bounds first: the numeric tests below would print raw shell errors on a value that
    # does not fit in 64 bits, and MAX_FILE_SIZE_KB is multiplied by 1024 for find.
    in_range "$THUNDERSTORM_PORT" 65535 || die "Port must be <= 65535: '$THUNDERSTORM_PORT'"
    in_range "$MAX_AGE" 36500 || die "max-age must be <= 36500 days: '$MAX_AGE'"
    in_range "$MAX_FILE_SIZE_KB" 1073741824 || die "${MAX_SIZE_FLAG#--} must be <= 1073741824 KiB (1 TiB): '$MAX_FILE_SIZE_KB'"
    in_range "$RETRIES" 100 || die "retries must be <= 100: '$RETRIES'"

    # Canonical decimal, AFTER the range checks (they compare by string length so an over-64-bit
    # value never reaches arithmetic). Bash reads a leading zero as octal: without 10#,
    # '--max-age 010' means 8 days and '08' is a raw arithmetic error.
    THUNDERSTORM_PORT=$(( 10#$THUNDERSTORM_PORT ))
    MAX_AGE=$(( 10#$MAX_AGE ))
    MAX_FILE_SIZE_KB=$(( 10#$MAX_FILE_SIZE_KB ))
    RETRIES=$(( 10#$RETRIES ))

    [ "$THUNDERSTORM_PORT" -gt 0 ] || die "Port must be greater than 0"
    # No ">= 1" check for max-size: 0 turns the size filter OFF, exactly as --max-age 0 turns
    # the age filter off, so the two policy gates are spelled the same way on the command line.
    # (The Go collector's engine already reads 0 as unlimited -- collector.go's
    # "c.MaxFileSize > 0 && c.MaxFileSize < info.Size()" -- though its CLI still refuses it.)
    [ "$RETRIES" -ge 1 ] || die "retries must be >= 1"

    [ -n "$THUNDERSTORM_SERVER" ] || die "Server must not be empty"
    if [ -n "$CA_CERT" ] && [ ! -f "$CA_CERT" ]; then
        die "CA certificate file not found: '$CA_CERT'"
    fi
    if [ -n "$CA_CERT" ] && [ "$INSECURE" -eq 1 ]; then
        log_msg warn "--ca-cert and --insecure are both set; --insecure takes precedence"
    fi
}

# collect_symlink_entry -- account, and with --follow-symlinks collect, ONE symlink entry
# ($1 = its path from the physical walk, $2 = API endpoint). Never traverses the link.
# Reads main's arrays: _seen_dirs, _self_paths, link_stat_test, _link_targets_done (appended).
# Every path bumps LINKS_SEEN and then exactly one of LINKS_COLLECTED, LINKS_FAILED, or a
# breakdown counter via link_skip.
#
# Order, and why it is this order:
#   1. resolve first, gating every hop as a STRING before it is lstat'ed, so a chain landing on
#      a dead NFS export or autofs trigger is refused instead of parking the run in D state.
#      Classifying through the link ([ -d "$link" ]) would make the kernel walk the whole chain;
#   2. classify the RESOLVED path: directory -> surfaced, non-regular -> dangling, file -> on;
#   3. one policy pass on the canonical path: own artifacts, scope, duplicate, filesystem class,
#      size/age, readable;
#   4. one open, of the RESOLVED path. Opening through the link would let anyone who can write
#      the link's directory swap the content after validation. What remains is the ordinary
#      regular-file residual; no extra re-stat is added, since each would open a new window.
collect_symlink_entry() {
    local link="$1" endpoint="$2"
    local _resolved _target _dtgt _known _done _out _rc

    LINKS_SEEN=$((LINKS_SEEN + 1))
    if [ "$FOLLOW_SYMLINKS" -eq 0 ]; then
        link_skip LINKS_NOT_FOLLOWED debug "Symlink not followed: '$link'"
        return 0
    fi

    # 1. Resolve the chain with a filesystem-class gate in front of every hop.
    if ! resolve_link_chain "$link"; then
        case "$LINK_CHAIN_ERR" in
            refused)
                link_skip LINKS_FS_REFUSED info "Skipping symlink '$link' -> '$LINK_CHAIN_PATH' (target on ${LINK_CHAIN_TYPE} ${LINK_CHAIN_CLASS}; refused before access)"
                ;;
            noreadlink)
                link_skip LINKS_UNRESOLVABLE debug "Skipping symlink '$link' (readlink is not available; link targets cannot be resolved)"
                ;;
            toolong)
                link_skip LINKS_UNRESOLVABLE debug "Skipping symlink '$link' (link chain longer than 40 hops)"
                ;;
            *)
                link_skip LINKS_UNRESOLVABLE debug "Skipping symlink '$link' (cannot read link target)"
                ;;
        esac
        return 0
    fi
    _resolved="$LINK_CHAIN_OUT"

    # 2. Classify the resolved path — never through the link.
    if [ -d "$_resolved" ]; then
        # A directory link is SURFACED, never followed (owner decision): a file link
        # extends scope by one bounded file, a directory link by an unbounded subtree
        # (KAPE / ClamAV / rsync --safe-links norm). The operator opts in per directory —
        # unless the target already lies inside a scan root, which is only debug-worthy.
        if resolve_dir -P "$_resolved"; then _dtgt="$RESOLVE_DIR_OUT"; else _dtgt="$_resolved"; fi
        for _known in "${_seen_dirs[@]+"${_seen_dirs[@]}"}"; do
            if path_covers "$_known" "$_dtgt"; then
                link_skip LINKS_DIR_SURFACED debug "Symlinked directory '$link' -> '$_dtgt' is already inside a scan root; not followed"
                return 0
            fi
        done
        link_skip LINKS_DIR_SURFACED info "Symlinked directory '$link' not followed (add it with --dir to scan it)"
        return 0
    fi
    if [ ! -f "$_resolved" ]; then
        link_skip LINKS_DANGLING debug "Skipping symlink '$link' (dangling or special target)"
        return 0
    fi
    # Sentinel capture keeps a resolved name ending in a newline byte-exact.
    if ! _target="$(canonical_file_path "$_resolved" && printf x)"; then
        link_skip LINKS_UNRESOLVABLE debug "Skipping symlink '$link' (target unresolvable)"
        return 0
    fi
    _target="${_target%x}"

    # 3. One policy pass on the resolved path.
    for _known in "${_self_paths[@]+"${_self_paths[@]}"}"; do
        if path_covers "$_known" "$_target"; then
            link_skip LINKS_SELF_EXCLUDED info "Skipping symlink '$link' -> '$_target' (the collector's own work directory or log file)"
            return 0
        fi
    done
    for _known in "${_seen_dirs[@]+"${_seen_dirs[@]}"}"; do
        if path_covers "$_known" "$_target"; then
            # The walk already made the policy decision for that path (collected, or
            # excluded by cloud/self/size policy) — collecting it via the link would either
            # duplicate or bypass policy.
            link_skip LINKS_IN_SCOPE debug "Skipping symlink '$link' (target '$_target' is in scope)"
            return 0
        fi
    done
    for _done in "${_link_targets_done[@]+"${_link_targets_done[@]}"}"; do
        if [ "$_done" = "$_target" ]; then
            link_skip LINKS_DUP debug "Skipping symlink '$link' (target '$_target' already delivered via another link)"
            return 0
        fi
    done
    link_fs_class_refused "$link" "$_target" "" && return 0
    # Exit status first: find fails when the target cannot be examined at all (gone between
    # resolution and this test) — the link dangles now; only a clean empty result is policy.
    _out="$(find "$_target" "${link_stat_test[@]}" -print 2>/dev/null)"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        link_skip LINKS_DANGLING debug "Skipping symlink '$link' (target '$_target' vanished or could not be examined)"
        return 0
    fi
    if [ -z "$_out" ]; then
        # Name the gate that removed it. The combined test above already failed, so at most one
        # extra find is needed, and only when BOTH gates are active — with one gate off the
        # reason is the other gate by elimination, and no second walk is spelled at all. The
        # probe is the same single-path, -prune form, so it costs one stat on a link the run
        # was already discarding.
        if [ "${#SIZE_TEST[@]}" -eq 0 ]; then
            link_skip LINKS_AGE_FILTERED debug "Skipping symlink '$link' (target '$_target' outside the age window)"
        elif [ "${#AGE_TESTS[@]}" -eq 0 ]; then
            link_skip LINKS_SIZE_FILTERED debug "Skipping symlink '$link' (target '$_target' over the size limit)"
        elif [ -n "$(find "$_target" -prune -type f "${SIZE_TEST[@]}" -print 2>/dev/null)" ]; then
            link_skip LINKS_AGE_FILTERED debug "Skipping symlink '$link' (target '$_target' outside the age window)"
        else
            link_skip LINKS_SIZE_FILTERED debug "Skipping symlink '$link' (target '$_target' over the size limit)"
        fi
        return 0
    fi
    # Readability is checked here, as the regular-file path does: without it an
    # unreadable target would be reported as collected in --dry-run and would burn the whole
    # upload retry loop in a real run — the two modes must agree. Discovered (through the
    # link) and not collected: failed, not skipped — same reason, same end-of-run error and
    # same exit 4 as an unreadable regular file (, CLAUDE.md §3).
    if [ ! -r "$_target" ]; then
        LINKS_FAILED=$((LINKS_FAILED + 1))
        FILES_FAILED=$((FILES_FAILED + 1))
        FILES_UNREADABLE=$((FILES_UNREADABLE + 1))
        [ -n "$FIRST_UNREADABLE" ] || FIRST_UNREADABLE="$_target"
        log_msg debug "Unreadable symlink target (counted as failed): '$link' -> '$_target'"
        return 0
    fi

    # 4. One open — of the resolved path. Recorded first, so a second link to the same
    # target is a duplicate whether or not this upload succeeds.
    _link_targets_done+=("$_target")
    submit_file "$endpoint" "$_target"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        LINKS_COLLECTED=$((LINKS_COLLECTED + 1))
        log_msg info "Collected via symlink: '$link' -> '$_target'"
    elif [ "$_rc" -eq 94 ]; then
        # The target stopped being a regular file before the open: churn, counted as vanished.
        LINKS_FAILED=$((LINKS_FAILED + 1))
        FILES_FAILED=$((FILES_FAILED + 1))
        FILES_VANISHED=$((FILES_VANISHED + 1))
    else
        LINKS_FAILED=$((LINKS_FAILED + 1))
        FILES_FAILED=$((FILES_FAILED + 1))
        FILES_UPLOAD_FAILED=$((FILES_UPLOAD_FAILED + 1))
        log_msg error "Could not upload symlink target '$link' -> '$_target'"
    fi
    return 0
}

# compose_root_excludes -- build this root's complete find prune set in walk_excludes, and warn
# once when the operator named a location that is excluded by default.
# Every prune is spelled the way THIS root's walk prints paths: find prints each entry under the
# spelling of its start point and a physical walk never crosses a symlink, so that is the only
# spelling an absolute -path can match. spell_under_root produces it; escape_find_glob keeps a
# literal path from acting as an fnmatch pattern.
# Four sources: the exclusion anchors (built-ins plus network / pseudo-fs mount points; the anchor
# that IS this root is dropped, since a walk cannot start inside its own prune, and for a named
# root that drop is announced); the macOS CloudStorage location; this run's own artifacts; and
# roots already scanned that lie under this one.
# Reads: scandir, _physdir, _fstype, exclude_path_list, cloudstorage_prune, _self_paths,
# _child_prunes, SCAN_FOLDERS_FROM_USER.  Writes: walk_excludes, _excluded_note.
compose_root_excludes() {
    local _ep _p _known _keep_cloudstorage

    walk_excludes=()
    _excluded_note=""
    for _ep in "${exclude_path_list[@]+"${exclude_path_list[@]}"}"; do
        # The anchor equal to this root (by either spelling — an aliased path is under the
        # anchor in reality even when its spelling is not) is mechanics, not policy.
        if [ "$_ep" = "$scandir" ] || [ "$_ep" = "$_physdir" ]; then
            [ "$SCAN_FOLDERS_FROM_USER" -eq 1 ] && _excluded_note="$_ep"
            continue
        fi
        if [ "$SCAN_FOLDERS_FROM_USER" -eq 1 ]; then
            case "$scandir" in "$_ep"/*) _excluded_note="$_ep" ;; esac
            case "$_physdir" in "$_ep"/*) _excluded_note="$_ep" ;; esac
        fi
        # An anchor outside this root's physical subtree keeps its own spelling: the walk can
        # never reach it, so the prune is harmless either way.
        if spell_under_root "$scandir" "$_physdir" "$_ep"; then
            escape_find_glob "$SPELL_UNDER_ROOT_OUT"
        else
            escape_find_glob "$_ep"
        fi
        walk_excludes+=(-path "$FIND_GLOB_OUT" -prune -o)
    done

    _keep_cloudstorage=1
    for _p in "$scandir" "$_physdir"; do
        case "$_p" in
            */Library/CloudStorage|*/Library/CloudStorage/*) _keep_cloudstorage=0 ;;
        esac
    done
    [ "$_keep_cloudstorage" -eq 1 ] && walk_excludes+=("${cloudstorage_prune[@]}")

    for _known in "${_self_paths[@]+"${_self_paths[@]}"}"; do
        if spell_under_root "$scandir" "$_physdir" "$_known"; then
            escape_find_glob "$SPELL_UNDER_ROOT_OUT"
            walk_excludes+=(-path "$FIND_GLOB_OUT" -prune -o)
        fi
    done
    walk_excludes+=("${_child_prunes[@]+"${_child_prunes[@]}"}")

    if [ -n "$_excluded_note" ]; then
        log_msg warn "'$scandir' is excluded by default (under '$_excluded_note'${_fstype:+, filesystem: $_fstype}); collecting as requested"
    fi
    return 0
}

# collect_entries -- the upload pass: walk every classified list produced by the discovery pass
# and deliver each entry. Routing is by the class recorded AT DISCOVERY (first byte: f regular
# file, l symlink), never by what the path is now: an entry whose type changed since is not the
# object find checked, so it is counted as vanished rather than uploaded unchecked or fed to the
# link policy under a false identity. $1 is the upload endpoint.
# Reads: all_find_files, TOTAL_FILES, SHOW_PROGRESS, INTERRUPTED.  Writes: the FILES_*/LINKS_*
# counters and FIRST_UNREADABLE.
collect_entries() {
    local api_endpoint="$1"
    local find_results_file file_path _kind _sub_rc
    local _processed=0
    local _sub_rc
    for find_results_file in "${all_find_files[@]}"; do
        while IFS= read -r -d '' file_path; do
            # Check for interruption between files
            [ "$INTERRUPTED" -eq 1 ] && break 2

            _processed=$((_processed + 1))

            # Show progress
            if [ "$SHOW_PROGRESS" -eq 1 ] && [ "$TOTAL_FILES" -gt 0 ]; then
                printf '\r[%d/%d] %d%%' "$_processed" "$TOTAL_FILES" "$(( _processed * 100 / TOTAL_FILES ))" >&2
            fi

            # route by the class recorded at discovery (first byte: f file, l symlink).
            # A symlink entry is accounted and — with --follow-symlinks — collected in
            # collect_symlink_entry, never traversed here. An entry whose type changed since
            # discovery is not the object find checked: failed (vanished) — the rsync code-24
            # convention for a mid-run change — never uploaded unchecked and never fed to the
            # link policy under a false identity. Every l entry bumps LINKS_SEEN, so
            # LINKS_SEEN == TOTAL_LINKS holds by construction (checked at reconciliation).
            _kind="${file_path:0:1}"
            file_path="${file_path#?}"
            case "$_kind" in
                l)
                    if [ ! -h "$file_path" ]; then
                        LINKS_SEEN=$((LINKS_SEEN + 1))
                        LINKS_FAILED=$((LINKS_FAILED + 1))
                        FILES_FAILED=$((FILES_FAILED + 1))
                        FILES_VANISHED=$((FILES_VANISHED + 1))
                        if [ -e "$file_path" ]; then
                            log_msg warn "Symbolic link '$file_path' was replaced by a non-link after discovery; not collected, counted as failed"
                        else
                            log_msg debug "Vanished before collection: '$file_path'"
                        fi
                        continue
                    fi
                    collect_symlink_entry "$file_path" "$api_endpoint"
                    continue
                    ;;
                *)
                    if [ -h "$file_path" ]; then
                        FILES_FAILED=$((FILES_FAILED + 1))
                        FILES_VANISHED=$((FILES_VANISHED + 1))
                        log_msg warn "File '$file_path' became a symbolic link after discovery; not collected, counted as failed"
                        continue
                    fi
                    ;;
            esac

            # Discovered, then gone before it could be read (renamed or removed mid-run): failed,
            # with its own reason — rsync reports vanished files the same way (code 24) — so the
            # reconciliation holds by construction instead of inferring the loss afterwards.
            if [ ! -f "$file_path" ]; then
                FILES_FAILED=$((FILES_FAILED + 1))
                FILES_VANISHED=$((FILES_VANISHED + 1))
                log_msg debug "Vanished before collection: '$file_path'"
                continue
            fi

            FILES_SCANNED=$((FILES_SCANNED + 1))

            # size is filtered by find at discovery; only a fork-free readability check
            # remains here, keeping unreadable files away from the upload retry loop. A discovered
            # file that cannot be read was NOT collected: failed, not skipped (CLAUDE.md §3; tar
            # and rsync treat it as an error and finish with a partial status).
            if [ ! -r "$file_path" ]; then
                FILES_FAILED=$((FILES_FAILED + 1))
                FILES_UNREADABLE=$((FILES_UNREADABLE + 1))
                [ -n "$FIRST_UNREADABLE" ] || FIRST_UNREADABLE="$file_path"
                log_msg debug "Unreadable file (counted as failed): '$file_path'"
                continue
            fi

            log_msg debug "Submitting '$file_path'"
            submit_file "$api_endpoint" "$file_path"
            _sub_rc=$?
            if [ "$_sub_rc" -eq 0 ]; then
                FILES_SUBMITTED=$((FILES_SUBMITTED + 1))
            elif [ "$_sub_rc" -eq 94 ]; then
                # Type changed between the discovery-time check and the open: the same class as
                # a vanished file, so it is counted as one (and reaches exit 5, not 4).
                FILES_FAILED=$((FILES_FAILED + 1))
                FILES_VANISHED=$((FILES_VANISHED + 1))
            else
                FILES_FAILED=$((FILES_FAILED + 1))
                FILES_UPLOAD_FAILED=$((FILES_UPLOAD_FAILED + 1))
                log_msg error "Could not upload '$file_path'"
            fi
        done < "$find_results_file"
    done
    return 0
}

# report_run -- close the run out: elapsed time, the summary line, the failure and symlink
# breakdowns, the reconciliation identities and the end marker. $1 is the server base URL.
# Returns the run exit code (0, 4 or 5) so main can hand it straight to the caller.
# Reads every counter; writes elapsed and reconcile_failed.
report_run() {
    local base_url="$1"
    local _excluded_by
    if [ "$START_TS" -gt 0 ] 2>/dev/null; then
        elapsed=$(( $(date +%s 2>/dev/null || printf '%s\n' "$START_TS") - START_TS ))
        [ "$elapsed" -lt 0 ] && elapsed=0
    fi

    # Clear progress line if we were showing progress
    if [ "$SHOW_PROGRESS" -eq 1 ]; then
        printf '\r\033[K' >&2
    fi

    log_msg info "Run completed: discovered=$TOTAL_FILES scanned=$FILES_SCANNED submitted=$FILES_SUBMITTED skipped=$FILES_SKIPPED age_filtered=$FILES_AGE_FILTERED size_filtered=$FILES_SIZE_FILTERED age_ctime_only=$FILES_AGE_CTIME_ONLY future=$FILES_FUTURE failed=$FILES_FAILED links_seen=$LINKS_SEEN links_collected=$LINKS_COLLECTED links_skipped=$LINKS_SKIPPED unreadable_dirs=$UNREADABLE_DIRS unusable_dirs=$UNUSABLE_DIRS seconds=$elapsed"

    # Each caveat below is reported unconditionally — never gated on a count being > 0, or an
    # all-zero failed run says nothing. Counter names appear without "=": the summary's keys must
    # not recur after the summary line (see the reconciliation comment below).
    if [ "$COUNT_FILTERED" -eq 0 ]; then
        # "not because nothing was excluded" is only true while a gate is actually ON. With both
        # gates disabled nothing COULD have been excluded, so the zeros are the truth and saying
        # they are unmeasured is the collector contradicting the policy lines it just printed.
        if [ "${#AGE_TESTS[@]}" -eq 0 ] && [ "${#SIZE_TEST[@]}" -eq 0 ]; then
            log_msg info "Not measured this run (--no-count-filtered): age_filtered and size_filtered read zero, which is also what they would be — both discovery gates are disabled. future= and age_ctime_only= are unmeasured."
        else
            log_msg info "Not measured this run (--no-count-filtered): the age_filtered, size_filtered, age_ctime_only and future counters read zero because the counting walks were skipped, not because nothing was excluded"
        fi
    else
        if [ "$COUNT_MATCHING_PARTIAL" -eq 1 ]; then
            log_msg info "Policy-exclusion counts are a lower bound: a counting walk could not finish (an unreadable directory, or no room for the scratch list)"
        elif [ "$COUNT_CHURNED" -eq 1 ]; then
            log_msg info "Policy-exclusion counts are a snapshot: they are measured after the walk, and this tree gained or lost files in between"
        fi
        if [ "$FILES_AGE_FILTERED" -gt 0 ] || [ "$FILES_SIZE_FILTERED" -gt 0 ]; then
            # Name only the gates that are actually ON. Printing "0 file(s) over the size
            # limit" in a run whose own policy line said "Size filter: disabled" asserts a
            # limit that does not exist — the counter is right, the sentence is not.
            _excluded_by=""
            if [ "${#AGE_TESTS[@]}" -gt 0 ]; then
                _excluded_by="$FILES_AGE_FILTERED file(s) outside the age window"
            fi
            if [ "${#SIZE_TEST[@]}" -gt 0 ]; then
                [ -n "$_excluded_by" ] && _excluded_by="$_excluded_by, "
                _excluded_by="$_excluded_by$FILES_SIZE_FILTERED file(s) over the size limit"
            fi
            log_msg info "Excluded at discovery by policy: $_excluded_by"
        fi
        if [ "$FUTURE_UNMEASURED" -eq 1 ]; then
            log_msg info "The future-timestamp check did not run: no forward-stamped reference could be created, so the future counter reads zero unmeasured"
        fi
    fi
    if [ "$FILES_AGE_CTIME_ONLY" -gt 0 ]; then
        log_msg info "$FILES_AGE_CTIME_ONLY file(s) matched at discovery by ctime only; --age-timestamp mtime would have left them out"
    fi
    if [ "$FILES_FUTURE" -gt 0 ]; then
        log_msg warn "$FILES_FUTURE collected file(s) have modification times more than a minute ahead of this host's clock (skew or tampering); a future timestamp is never a reason to exclude a file"
    fi

    # name the reasons behind failed= once (same shape as the symlink breakdown), and
    # say plainly what could not be read — the summary is often the only artifact kept.
    if [ "$FILES_FAILED" -gt 0 ]; then
        log_msg info "File breakdown: unreadable=$FILES_UNREADABLE vanished=$FILES_VANISHED upload=$FILES_UPLOAD_FAILED"
    fi
    if [ "$FILES_UNREADABLE" -gt 0 ]; then
        log_msg error "$FILES_UNREADABLE file(s) could not be read (first: '$FIRST_UNREADABLE'); counted as failed"
    fi

    # in default mode a narrow, operator-scoped scan may hide a payload behind an
    # unfollowed link — say so once. (Suppressed for default broad scans, where thousands of
    # benign system symlinks would make this pure noise.)
    if [ "$FOLLOW_SYMLINKS" -eq 0 ] && [ "$LINKS_SEEN" -gt 0 ] && [ "$SCAN_FOLDERS_FROM_USER" -eq 1 ]; then
        log_msg info "$LINKS_SEEN symbolic link(s) were not followed (use --follow-symlinks to collect the files they point to; symlinked directories must be named with --dir)"
    fi
    # name the reasons behind links_skipped once, when following was on (in default
    # mode every link is simply not followed).
    if [ "$FOLLOW_SYMLINKS" -eq 1 ] && [ "$LINKS_SEEN" -gt 0 ]; then
        log_msg info "Symlink breakdown: dir_surfaced=$LINKS_DIR_SURFACED in_scope=$LINKS_IN_SCOPE dup=$LINKS_DUP fs_refused=$LINKS_FS_REFUSED self_excluded=$LINKS_SELF_EXCLUDED filtered_size=$LINKS_SIZE_FILTERED filtered_age=$LINKS_AGE_FILTERED dangling=$LINKS_DANGLING unresolvable=$LINKS_UNRESOLVABLE links_failed=$LINKS_FAILED"
    fi

    # (Layer 2): reconcile the discovered count against what we accounted for. Every
    # discovered file must end up submitted, skipped, or failed. Since round 3 a file that
    # vanished mid-run is counted (failed/vanished), so this holds by construction and the check
    # is a bookkeeping guard: a mismatch is a bug, surfaced like any shortfall. Skipped when
    # interrupted (a partial run is expected then).
    _accounted=$(( FILES_SUBMITTED + FILES_SKIPPED + FILES_FAILED + LINKS_COLLECTED + LINKS_SKIPPED ))
    if [ "$INTERRUPTED" -eq 0 ] && [ "$_accounted" -ne "$TOTAL_FILES" ]; then
        log_msg error "Reconciliation failed: discovered $TOTAL_FILES file(s) but accounted for $_accounted; $(( TOTAL_FILES - _accounted )) discovered file(s) were not collected"
        reconcile_failed=1
    fi
    # The failure reasons must add up to failed= (link failures — upload error, unreadable
    # target — are counted in both). Prose, not key=value, below: the summary's keys must not
    # recur after the summary line, or a scraper taking the last match reads the wrong number.
    if [ "$INTERRUPTED" -eq 0 ] && [ "$FILES_FAILED" -ne $(( FILES_UNREADABLE + FILES_VANISHED + FILES_UPLOAD_FAILED )) ]; then
        log_msg error "Reconciliation failed: $FILES_FAILED failed file(s) but the reasons sum to $(( FILES_UNREADABLE + FILES_VANISHED + FILES_UPLOAD_FAILED )) ($FILES_UNREADABLE unreadable, $FILES_VANISHED vanished, $FILES_UPLOAD_FAILED upload)"
        reconcile_failed=1
    fi
    # the link counters must close too — every seen link is collected, failed, or in
    # exactly one skip class. A mismatch is a bookkeeping bug, surfaced like any shortfall.
    _link_breakdown=$(( LINKS_NOT_FOLLOWED + LINKS_DIR_SURFACED + LINKS_FS_REFUSED + LINKS_SELF_EXCLUDED + LINKS_IN_SCOPE + LINKS_DUP + LINKS_SIZE_FILTERED + LINKS_AGE_FILTERED + LINKS_DANGLING + LINKS_UNRESOLVABLE ))
    if [ "$INTERRUPTED" -eq 0 ] && { [ "$LINKS_SEEN" -ne $(( LINKS_COLLECTED + LINKS_SKIPPED + LINKS_FAILED )) ] || [ "$LINKS_SKIPPED" -ne "$_link_breakdown" ]; }; then
        log_msg error "Reconciliation failed: $LINKS_SEEN symlink(s) seen but $LINKS_COLLECTED collected, $LINKS_SKIPPED skipped (breakdown sums to $_link_breakdown) and $LINKS_FAILED failed"
        reconcile_failed=1
    fi
    # Every discovered symlink went through the link path (typed lists), so the discovery count
    # and links_seen must agree.
    if [ "$INTERRUPTED" -eq 0 ] && [ "$LINKS_SEEN" -ne "$TOTAL_LINKS" ]; then
        log_msg error "Reconciliation failed: $TOTAL_LINKS symlink(s) discovered but $LINKS_SEEN accounted as seen"
        reconcile_failed=1
    fi

    # Send collection end marker with run statistics
    if [ "$DRY_RUN" -eq 0 ]; then
        # Link uploads are real POSTs: without these fields the server's record of the run
        # would undercount what it received while the local summary reported it honestly.
        local stats_json
        build_stats_json "$elapsed"
        stats_json="$STATS_JSON_OUT"
        collection_marker "$base_url" "end" "$SCAN_ID" "$stats_json" >/dev/null
    fi

    # Exit 4 vs 5: rsync splits "partial transfer due to error" (23) from "partial transfer due
    # to vanished source files" (24) because they ask different things of the operator — one is
    # a problem to investigate, the other is a live host changing under the walk. A full-host
    # run on a busy machine always loses a few cache and log files this way, so collapsing both
    # into 4 made 4 the normal outcome and stripped it of meaning. Vanished losses alone -> 5;
    # anything else -> 4, which wins when both occurred (rsync lets 23 override 24). An
    # explicitly named target that was unusable is UNUSABLE_DIRS, so it stays 4 even if the
    # only file losses were vanished ones (tar treats a named-but-missing operand the same way).
    if [ "$FILES_UNREADABLE" -gt 0 ] || [ "$FILES_UPLOAD_FAILED" -gt 0 ] \
        || [ "$UNREADABLE_DIRS" -gt 0 ] || [ "$UNUSABLE_DIRS" -gt 0 ] || [ "$reconcile_failed" -eq 1 ]; then
        return 4
    fi
    if [ "$FILES_VANISHED" -gt 0 ]; then
        return 5
    fi
    return 0
}
# root_already_covered -- duplicate and overlap rules, judged on the PHYSICAL location so two
# spellings of one directory are collected once. Returns 0 to skip this root, 1 to scan it.
# A child inside an already-scanned parent is redundant only if the parent's walk actually
# reached it; an exclusion anchor or a proven cloud folder in between means it did not, and
# skipping it would drop what the operator asked for. A parent named after its child prunes
# that child instead.
# Reads: scandir, _physdir, _cmpdir, _seen_dirs, _seen_phys, exclude_path_list.
# Writes: _child_prunes.
root_already_covered() {
    local _i _dup _covered

    # skip a directory already queued for scanning (exact physical duplicate).
    # Comparing the physical location collapses a repeated --dir, '/x' vs '/x/', and
    # symlink-equivalent aliases, so nothing is scanned or submitted twice. Overlapping
    # parent/child paths are intentionally not deduped here (that interacts with the
    # explicit-into-excluded policy).
    _dup=0
    _i=0
    while [ "$_i" -lt "${#_seen_phys[@]}" ]; do
        [ "${_seen_phys[$_i]}" = "$_cmpdir" ] && { _dup=1; break; }
        _i=$((_i + 1))
    done
    if [ "$_dup" -eq 1 ]; then
        log_msg info "Skipping duplicate directory '$scandir' (already scanned)"
        return 0
    fi

    # overlapping roots — each file once, the first root wins (rsync sorts and
    # de-duplicates its transfer list; Velociraptor merges hits per file; KAPE: "the first
    # file found wins"). A root inside an already-scanned root is skipped — unless the
    # parent's walk never reached it (an exclusion anchor, a proven cloud folder or the
    # CloudStorage location in between): that is the explicit-into-excluded case, scanned as
    # before. A parent named AFTER one of its children prunes that child from its own walk,
    # spelled the way THIS walk prints it (spell_under_root).
    _covered=""
    _child_prunes=()
    _i=0
    while [ "$_i" -lt "${#_seen_phys[@]}" ]; do
        if path_covers "${_seen_phys[$_i]}" "$_cmpdir"; then
            if walk_reaches "${_seen_phys[$_i]}" "$_cmpdir" "${exclude_path_list[@]+"${exclude_path_list[@]}"}"; then
                _covered="${_seen_dirs[$_i]}"
                break
            fi
        elif spell_under_root "$scandir" "$_physdir" "${_seen_phys[$_i]}"; then
            escape_find_glob "$SPELL_UNDER_ROOT_OUT"
            _child_prunes+=(-path "$FIND_GLOB_OUT" -prune -o)
            log_msg info "'${_seen_dirs[$_i]}' was already scanned; not walked again under '$scandir'"
        fi
        _i=$((_i + 1))
    done
    if [ -n "$_covered" ]; then
        log_msg info "Skipping '$scandir' (inside '$_covered', already scanned)"
        return 0
    fi
    return 1
}
# classify_root -- decide whether the current scan root can be walked, and how. Returns 1 when it
# must be skipped (already reported, duplicate, or inside a scanned root), 0 when it is ready.
# Order is deliberate: nothing touches the path before the string-only filesystem-class gate, or a
# dead NFS export parks the run in D state; existence, type and permission are separated so each
# gets its own message; the root is canonicalised logically (what the walk prints) and resolved
# physically (where it is), and every SAFETY decision uses the physical path.
# Operates on the loop variable scandir, which it rewrites to the canonical spelling.
# Writes: scandir, _physdir, _physnote, _cmpdir, _fstype, _root_is_link, _child_prunes.
classify_root() {
        # Classify the root by its mount BEFORE anything touches it (the rule, applied to
        # roots): '[ -d ]' on a dead NFS/CIFS export or an autofs trigger parks the collector
        # in uninterruptible D state, and the built-in defaults (/home on NFS is the common
        # shape) are exactly the paths nobody named. String operations only: the operand is
        # absolutized against $PWD and normalized lexically — '//', '.', '..' (a cwd or an
        # operand spelled '//x' would otherwise match no mount point) — then matched against
        # the mount snapshot. The physical (-P) gate further below stays: only it sees an
        # alias through a symlinked intermediate component. A default that is absent
        # AND lies under a refused mount is reported here instead of skipped quietly:
        # telling the two apart would take the very stat this gate exists to avoid.
        _p="$scandir"
        case "$_p" in /*) ;; *) _p="$PWD/$_p" ;; esac
        lexical_abs_path / "$_p"
        if fs_class_of_path "$LEXICAL_ABS_OUT"; then
            root_fs_class_refused "$LEXICAL_ABS_OUT" "" && return 1
            # Explicit scope wins: proceed, but say so BEFORE the first stat — on a dead
            # share this line is the last thing the operator sees. The policy warning
            # ("excluded by default... collecting as requested") still follows where it applies.
            log_msg info "'$LEXICAL_ABS_OUT' lies on a ${FS_CLASS_TYPE_OUT} network filesystem; proceeding as requested (a dead or unresponsive share can stall the collector from here on)"
        fi

        if [ ! -d "$scandir" ]; then
            # '[ -e ]' tells "exists but not a directory" apart from "absent or
            # unreachable" (a real directory behind an unreadable parent reports as the
            # latter; ENOENT vs EACCES is deliberately not split).
            if [ -e "$scandir" ]; then
                report_unusable_dir "$scandir" "not a directory"
            elif [ -h "$scandir" ]; then
                # [ -e ] followed the link and found nothing (ENOENT) or could not finish
                # following it (ELOOP): a broken or looping symlink named as a root.
                report_unusable_dir "$scandir" "dangling or looping symbolic link (target missing or unresolvable)"
            elif [ "$SCAN_FOLDERS_FROM_USER" -eq 0 ]; then
                # a built-in default that does not exist on this platform is a platform
                # difference, not an incident (/dev/shm and /run are Linux-only; /root is
                # absent on macOS). Stay quiet — an unreadable default still warns via,
                # and an explicitly named target is still an error.
                log_msg debug "Default scan directory '$scandir' does not exist here; skipping"
            else
                report_unusable_dir "$scandir" "does not exist or is not accessible"
            fi
            return 1
        fi

        # a 000 / no-read / no-execute directory passes the [ -d ] test above, yet find
        # cannot read it and (below) its error is silenced. Listing entries and stat-ing
        # their types needs both read AND execute on the directory.
        if [ ! -r "$scandir" ] || [ ! -x "$scandir" ]; then
            report_unusable_dir "$scandir" "permission denied"
            return 1
        fi

        # resolve the validated scan root to an absolute path before find runs, so
        # a relative or leading-dash path can't be misparsed by find, the absolute
        # exclusion prunes match, and the server receives an absolute filename.
        # -P follows symlinks (--follow-symlinks); -L (default) absolutizes without
        # dereferencing the final symlink. On any failure keep the original path so an
        # explicitly-named directory is never dropped, and note it for debugging.
        # a symlinked root is not followed by default — say so, or "Found 0" would be
        # indistinguishable from an empty directory.
        # whether a symlinked scan root is dereferenced depends on WHO chose it.
        # A path the operator named is not dereferenced by default — that is the
        # --follow-symlinks contract. The built-in defaults are the collector's own configuration, and on
        # macOS/BSD two of them are platform aliases (/tmp -> /private/tmp,
        # /var -> /private/var): resolving those extends scope by nothing (it is the same
        # directory under its canonical name), while refusing them silently skips two of the
        # highest-value forensic locations. So defaults resolve physically, operator input
        # stays logical. A resolved default still passes every check below (gate,
        # exclusions, cloud proof).
        _canon_mode="-L"
        if [ "$FOLLOW_SYMLINKS" -eq 1 ] || [ "$SCAN_FOLDERS_FROM_USER" -eq 0 ]; then
            _canon_mode="-P"
        fi

        # "not following it" is only true for a root the operator named; saying it about a
        # resolved default would be a lie.
        # Strip trailing '/' and '/.' spellings first ('link//', 'link/.'): [ -h ] would resolve
        # through them, and the hint must not depend on how the root was typed.
        _p="$scandir"
        while :; do
            case "$_p" in
                */.)  _p="${_p%/.}" ;;
                ?*/)  _p="${_p%/}" ;;
                *)    break ;;
            esac
        done
        _root_is_link=0
        if [ "$_canon_mode" = "-L" ] && [ -h "$_p" ]; then
            _root_is_link=1
            log_msg warn "'$scandir' is a symbolic link; not following it (use --follow-symlinks to scan its target)"
        fi

        if resolve_dir "$_canon_mode" "$scandir"; then
            _resolved="$RESOLVE_DIR_OUT"
            if [ "$_resolved" != "$scandir" ] && [ "$SCAN_FOLDERS_FROM_USER" -eq 0 ]; then
                log_msg debug "Default scan directory '$scandir' resolves to '$_resolved'"
            fi
            scandir="$_resolved"
        else
            log_msg debug "Could not canonicalize '$scandir'; scanning as given"
        fi

        # every safety decision below is made about where the root REALLY is, not about
        # how it was spelled. In default mode the root is canonicalized logically (cd -L, the
        # same choice the Go collector makes with filepath.Abs), so a symlinked INTERMEDIATE
        # component would otherwise hide the true location: `--dir /alias/sub` with
        # `/alias -> /proc` was walked as `/alias/sub`, which no absolute prune and no
        # fstype lookup could recognise — 1867 /proc pseudo-files were accepted as evidence,
        # silently, exit 0. The kernel resolves the alias regardless, so the checks must too.
        # This mirrors the Go collector, which asks the kernel directly (syscall.Statfs).
        # The checks, the duplicate/overlap comparison and the spelling of every prune use the
        # physical path; the walk and the reported filenames stay on the operator's logical path.
        _physdir="$scandir"
        if [ "$_canon_mode" = "-L" ]; then
            if resolve_dir -P "$scandir"; then
                _physdir="$RESOLVE_DIR_OUT"
            else
                log_msg debug "Could not resolve the physical location of '$scandir'; checking it as given"
            fi
        fi
        # Name the real location in messages when it differs, so a refusal is explainable.
        _physnote=""
        [ "$_physdir" != "$scandir" ] && _physnote="really '$_physdir'; "

        # Roots are compared by WHERE they are, not by how they were spelled: the walk is
        # physical (find never follows a link), so two spellings of one directory would collect
        # everything twice, and a spelling that leaves the tree through a symlinked component
        # is NOT inside the parent's walk. One exception: a root whose final component is
        # itself a symlink (default mode) is walked as a single link entry and covers nothing,
        # so it is keyed by its own spelling and never mistaken for its target. _seen_dirs
        # keeps the logical spelling for messages and for collect_symlink_entry (which only
        # consults it with --follow-symlinks, where the two spellings coincide).
        _cmpdir="$_physdir"
        [ "$_root_is_link" -eq 1 ] && _cmpdir="$scandir"

        root_already_covered && return 1

        # classify the target by the filesystem type of its mount — path spelling must
        # not decide collection. Kernel pseudo-filesystems hold no disk evidence and can
        # hang collection (measuring /proc/kcore reads terabytes), so they are refused
        # whole, regardless of how the path was written or reached. (The string pre-gate at
        # the loop head already refused plainly spelled roots; this one sees the alias.)
        _fstype=""
        fs_type_lookup "$_physdir" && _fstype="$FS_TYPE_OUT"
        if fs_class_of_path "$_physdir"; then
            root_fs_class_refused "$scandir" "$_physnote" && return 1
        fi

        # compose this root's prune set from the base path list. For an explicitly
        # requested root the anchor equal to the root is dropped (find could never start
        # otherwise) and an excluded-by-default location is announced instead of silently
        # emptied — explicit scope wins,. Default roots keep every prune
        # (default-scan behavior unchanged).
    # Reaching here means the root is ready to walk; say so explicitly, because the caller
    # tests this status and the last statement above is a conditional.
    return 0
}
# enumerate_root -- verify the cloud-named folders under this root, walk it, and record what was
# found. Returns 1 when the root produced no usable list (it was reported by report_unusable_dir).
#
# The walk is PHYSICAL in every mode: find never follows a symlink, so one planted link cannot
# bypass a path-anchored exclusion or drag an unbounded subtree in. Symlinks are enumerated as
# entries so they can be counted and — with --follow-symlinks — collected without traversal.
# Each entry is then re-listed with a one-byte class prefix (f regular file, l symlink) because
# every root is enumerated before any upload: the upload pass must route by what an entry WAS at
# discovery, not by what it has become since.
# Reads: scandir, walk_excludes, _in_cloud_scope, SIZE_TEST, AGE_TESTS.
# Writes: cloud_prunes, all_find_files, TOTAL_FILES, TOTAL_LINKS, UNREADABLE_DIRS.
enumerate_root() {
    local _cand_file _cand _cloud_ev _find_err _entry _count _lcount _k _typed _typed_ok
    local find_results_file find_rc _find_msg _dir_errs _word
        # Verify cloud-named folders before excluding them: enumerate the directories under this
        # root whose NAME matches a known cloud service (outermost matches only), then prune just
        # the ones with positive sync evidence — visibly. A folder that merely shares the name is
        # scanned. The walk starts at the root itself so every absolute prune in walk_excludes can
        # match: a "$scandir/." start point made find print "/root/./sub", which no absolute -path
        # matches, so that pass once walked /proc, /sys, the work directory and every network mount
        # under the root. '! -path' keeps the root out of the match, so a root named like a cloud
        # service is still descended. A root inside proven cloud storage prunes nothing as cloud —
        # the operator chose that scope. If the temp file cannot be made, scan cloud-named folders
        # rather than skip them.
        cloud_prunes=()
        if [ "$_in_cloud_scope" -eq 1 ]; then
            log_msg debug "Cloud-folder pruning is off under '$scandir' (inside the requested cloud scope)"
        elif _cand_file="$(mktemp_portable)"; then
            escape_find_glob "$scandir"
            LC_ALL=C find "$scandir" "${walk_excludes[@]}" -type d ! -path "$FIND_GLOB_OUT" \( "${cloud_name_tests[@]}" \) -prune -print0 \
                > "$_cand_file" 2>/dev/null \
                || log_msg debug "Cloud-folder candidate pass under '$scandir' ended with errors (a predicate this find lacks, or an unreadable subtree); cloud-named folders it did not verify are scanned, not excluded"
            while IFS= read -r -d '' _cand; do
                if _cloud_ev="$(cloud_dir_evidence "$_cand")"; then
                    escape_find_glob "$_cand"
                    cloud_prunes+=(-path "$FIND_GLOB_OUT" -prune -o)
                    log_msg info "Excluding cloud storage folder '$_cand' ($_cloud_ev)"
                else
                    log_msg info "Scanning '$_cand' despite cloud-like name (no cloud sync evidence)"
                fi
            done < "$_cand_file"
        else
            log_msg warn "Could not create temp file for cloud-folder checks under '$scandir'; cloud-named folders will be scanned"
        fi

        log_msg info "Scanning '$scandir'"
        find_results_file="$(mktemp_portable)" || {
            log_msg error "Could not create temporary file list for '$scandir'"
            return 1
        }
        # the walk is PHYSICAL in every mode (never find -L over a tree — that would let
        # one planted link bypass every path-anchored exclusion and drag in unbounded
        # content). Symlinks are enumerated as entries (-type l) so they can be counted,
        # policy-checked, and — with --follow-symlinks — collected without traversal.
        _find_err="$(scratch_file find.err)" || _find_err=/dev/null
        # ONE spelling of the discovery expression for every configuration: AGE_TESTS is empty
        # when --max-age is 0, so the age arm disappears instead of needing a second,
        # near-identical find command that has to be kept in sync by hand. The size and age
        # predicates read the stat find already performed, so both gates are free here.
        find "$scandir" "${walk_excludes[@]}" "${cloud_prunes[@]+"${cloud_prunes[@]}"}" \
            \( -type f "${SIZE_TEST[@]+"${SIZE_TEST[@]}"}" "${AGE_TESTS[@]+"${AGE_TESTS[@]}"}" -o -type l \) \
            -print0 > "$find_results_file" 2>"$_find_err"
        find_rc=$?
        # find exits non-zero when a subtree under this (readable) dir could not
        # be read, writing one diagnostic per directory (GNU, BSD, busybox). A directory is not
        # an artifact: what it held is unknown, so the DIRECTORIES are counted
        # (UNREADABLE_DIRS) and the run is partial — as rsync (code 23), tar and find report it.
        # Keep the files find DID return. When find failed and returned NOTHING, the target was
        # not enumerated at all — a rejected predicate, a path that vanished, find itself
        # failing — an unusable target under the rules (explicit -> error and exit 4,
        # default -> warn), not a silent "Found 0".
        if [ "$find_rc" -ne 0 ]; then
            _find_msg="$(head -1 "$_find_err" 2>/dev/null)"
            _find_msg="${_find_msg//$'\n'/ }"
            if [ ! -s "$find_results_file" ]; then
                report_unusable_dir "$scandir" "file enumeration failed${_find_msg:+: $_find_msg}"
                return 1
            fi
            _dir_errs=0
            while IFS= read -r _entry || [ -n "$_entry" ]; do
                _dir_errs=$((_dir_errs + 1))
            done < "$_find_err"
            [ "$_dir_errs" -gt 0 ] || _dir_errs=1
            UNREADABLE_DIRS=$((UNREADABLE_DIRS + _dir_errs))
            _word="directories"
            [ "$_dir_errs" -eq 1 ] && _word="directory"
            log_msg error "$_dir_errs $_word under '$scandir' could not be read (first: ${_find_msg:-no diagnostic}); their files are unknown and were not collected"
        fi
        # Count entries (each is null-terminated by -print0; fork-free) and RECORD each one's
        # class as a one-byte prefix in a rewritten list: f regular file, l symlink (one lstat
        # each — the lstat the summary already needed). find's -size/-mtime apply to
        # -type f only and every root is enumerated before any upload, so the upload loop must
        # route each entry by what it WAS at discovery: a link swapped for a regular file must
        # never become an unchecked upload, a file swapped for a link must never enter the link
        # policy. A list that cannot be written makes the root unusable, as a failed mktemp
        # does above (the same work directory would fail every real upload of this root anyway).
        local _count=0 _lcount=0 _k
        _typed="$find_results_file.typed"
        if ! { : > "$_typed"; } 2>/dev/null; then
            report_unusable_dir "$scandir" "could not write the classified file list under '$TS_WORK_DIR'"
            return 1
        fi
        _typed_ok=1
        while IFS= read -r -d '' _entry; do
            _count=$((_count + 1))
            _k=f
            if [ -h "$_entry" ]; then _lcount=$((_lcount + 1)); _k=l; fi
            printf '%s%s\0' "$_k" "$_entry" 2>/dev/null >&3 || _typed_ok=0
        done < "$find_results_file" 3> "$_typed"
        if [ "$_typed_ok" -eq 0 ]; then
            report_unusable_dir "$scandir" "could not write the classified file list under '$TS_WORK_DIR'"
            return 1
        fi
        # Recorded only now, with the list that will actually be processed: a root that was
        # not scanned must not "cover" a later child, must not make a link target look
        # like the walk's business (in_scope), and must not turn a repeated spelling of
        # itself into "already scanned". The filesystem gate above was already excluded this
        # way; the three failures that abandon a root AFTER it (enumeration returning nothing,
        # and either write of the classified list) were not, so an explicitly named child was
        # dropped with "inside '<parent>', already scanned" and a link into the parent was
        # booked in_scope, while the parent had collected nothing. Nothing between the
        # duplicate/overlap loops and here reads these arrays for the CURRENT root, and the
        # upload pass runs after every root is enumerated, so recording late is equivalent for
        # every path that succeeds.
        count_filtered_under "$(( _count - _lcount ))"
        _seen_dirs+=("$scandir")
        _seen_phys+=("$_cmpdir")
        TOTAL_FILES=$((TOTAL_FILES + _count))
        TOTAL_LINKS=$((TOTAL_LINKS + _lcount))
        all_find_files+=("$_typed")
        : > "$find_results_file"   # the untyped list is now redundant; free its space
    return 0
}
# root_cloud_scope -- decide whether this root lies inside PROVEN cloud storage, walking the
# PHYSICAL ancestry so an aliased path is judged by where it really is. When it does, the root is
# still collected — explicit scope overrides a default exclusion, which is what the operator asked
# for — but the run says so, and cloud pruning is switched off for this root: pruning inside a
# scope the operator deliberately chose would empty it silently.
# Reads: scandir, _physdir.  Writes: _in_cloud_scope.
root_cloud_scope() {
    local _p _cloud_ev
    _in_cloud_scope=0
    _p="$_physdir"
    while [ -n "$_p" ]; do
        if _cloud_ev="$(cloud_dir_evidence "$_p")"; then
            # $_p is the physical ancestor, so it names the real location itself.
            log_msg warn "'$scandir' is inside cloud storage '$_p' ($_cloud_ev); collecting as requested"
            _in_cloud_scope=1
            return 0
        fi
        [ "$_p" = "/" ] && return 0
        _p="${_p%/*}"
        [ -z "$_p" ] && _p="/"
    done
    return 0
}

# prepare_run -- everything that must be true before the first directory is touched: open the log
# file sink, validate the configuration, announce the run, build the endpoint URLs, create the
# private work directory, send the begin marker and settle the progress display. Exits the script
# on a condition that makes collecting pointless (missing upload tool, unusable work directory,
# unreachable server) — those are runtime errors, not partial results.
# Writes: scheme, endpoint_name, query_source, base_url, api_endpoint, CURL/WGET_EXTRA_OPTS,
# SHOW_PROGRESS, SCAN_ID, LOG_FILE_READY, TS_WORK_DIR.
prepare_run() {
    LOG_FILE_READY=1
    detect_source_name
    validate_config
    print_banner

    if [ "$(id -u 2>/dev/null || printf '%s\n' 1)" != "0" ]; then
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
    log_msg info "Source: $SOURCE_NAME"
    # Each folder quoted: an unquoted, space-joined list is ambiguous once a name has a space.
    _folders=""
    for _f in "${SCAN_FOLDERS[@]}"; do _folders="$_folders '$_f'"; done
    log_msg info "Folders:$_folders"
    [ "$DRY_RUN" -eq 1 ] && log_msg info "Dry-run mode enabled"

    # Every run needs a private work directory, and Bash has no builtin that creates one, so
    # 'mkdir' is a hard dependency (POSIX-mandatory, but still detected rather than assumed —
    # otherwise its absence surfaces as a generic "cannot create temp file" runtime error
    # instead of a named missing dependency).
    if ! command -v mkdir >/dev/null 2>&1; then
        log_msg error "'mkdir' is not available; cannot create the private work directory"
        exit 3
    fi
    # find does the entire discovery; without it every root would fail the same way and be
    # reported as "could not be read" — a named missing dependency (exit 3) instead.
    if ! command -v find >/dev/null 2>&1; then
        log_msg error "'find' is not available; cannot enumerate files"
        exit 3
    fi
    # Fast policy counting: counting NUL separators with tr|wc beats a per-record read loop by
    # several times, stays NUL-exact (a newline in a filename cannot inflate it), and is not a new
    # hard dependency — 'tr' is already used unguarded here, and without 'wc' the read loop runs
    # instead with identical counts.
    if command -v tr >/dev/null 2>&1 && command -v wc >/dev/null 2>&1; then
        COUNT_FAST=1
        log_msg debug "Policy counts use the tr/wc path"
    else
        log_msg debug "Policy counts use the read-loop path ('tr' or 'wc' unavailable)"
    fi
    # Create the work directory HERE, in the main shell. mktemp_portable runs inside "$(...)"
    # subshells, so a directory first created there was never recorded in the parent's
    # TS_WORK_DIR: a run that ended before the scan phase (begin marker failed -> exit 1, the
    # most common failure) left /tmp/thunderstorm.work.<pid> behind on the host, and a
    # --dry-run on an unusable TMPDIR reported "Found 0 candidates" with exit 0.
    if ! ensure_work_dir; then
        log_msg error "Cannot create the private work directory under '${TMPDIR:-/tmp}' (not writable, or a directory of that name exists and is not ours)"
        exit 1
    fi

    # Send collection begin marker; capture scan_id if server returns one
    if [ "$DRY_RUN" -eq 0 ]; then
        if ! detect_upload_tool; then
            log_msg error "Neither 'curl' nor 'wget' is installed; unable to upload samples"
            exit 3
        fi
        local _begin_resp_file
        local _begin_rc=0
        _begin_resp_file="$(mktemp_portable)" || { log_msg error "Cannot create temp file"; exit 1; }
        collection_marker "$base_url" "begin" "" "" > "$_begin_resp_file"
        _begin_rc=$?
        SCAN_ID="$(cat "$_begin_resp_file" 2>/dev/null)"
        # If the begin marker failed after retry, the server is unreachable — fatal error
        if [ "$_begin_rc" -ne 0 ]; then
            log_msg error "Cannot connect to Thunderstorm server at ${base_url} (begin marker failed after retry)"
            exit 1
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
    return 0
}

# count_matching -- how many entries a find expression matches under the root $1. Counted with a
# NUL-delimited read so a name containing a newline counts once, not twice. find's own errors are
# discarded: the discovery walk already reported unreadable directories through UNREADABLE_DIRS,
# and a short count is better than none. Result in COUNT_MATCHING_OUT (no subshell for the value,
# so nothing can strip it).
COUNT_MATCHING_OUT=0
COUNT_MATCHING_PARTIAL=0   # 1 when find could not finish, so the count is a lower bound
COUNT_FAST=0               # 1 when tr+wc are present, so counting need not loop per record
count_matching() {
    local _root="$1"
    shift
    local _n=0 _e _list _rc
    COUNT_MATCHING_OUT=0
    # A scratch file rather than '< <(find ...)': process substitution hides the producer's exit
    # status, and a counting walk that died partway would then publish a silently short number as
    # if it were the truth. scratch_file reuses a fixed name, so this costs no temp-file growth.
    _list="$(scratch_file count.lst)" || { COUNT_MATCHING_PARTIAL=1; return 0; }
    find "$_root" "$@" -print0 > "$_list" 2>/dev/null
    _rc=$?
    if [ "$COUNT_FAST" -eq 1 ]; then
        # One NUL per record; everything else is deleted, so the byte count IS the record count.
        # wc pads its output on some implementations, hence the digit strip.
        _n="$(tr -d -c '\000' < "$_list" 2>/dev/null | wc -c 2>/dev/null)" || _n=""
        _n="${_n//[^0-9]/}"
        [ -n "$_n" ] || { _n=0; COUNT_MATCHING_PARTIAL=1; }
    else
        while IFS= read -r -d '' _e; do
            _n=$(( _n + 1 ))
        done < "$_list"
    fi
    [ "$_rc" -eq 0 ] || COUNT_MATCHING_PARTIAL=1
    COUNT_MATCHING_OUT="$_n"
    : > "$_list" 2>/dev/null || :
}

# stamp_future_ref -- stamp AGE_FUTURE_REF one minute AHEAD of the host clock: a file written
# during the walk cannot reach it, while clock skew and a forward stomp both clear it. There is
# deliberately no fallback to "now" — that would count ordinary scan-time writes as future and
# make the warning false. Failing means the future count is skipped, and the run says so.
stamp_future_ref() {
    [ -n "$AGE_FUTURE_REF" ] || return 1
    local _now _when _stamp
    # date output is external input: unguarded, junk here is a raw shell arithmetic error
    _now="$(date +%s 2>/dev/null)" || return 1
    is_integer "$_now" || return 1
    _when=$(( _now + 60 ))
    # date's epoch flag is not POSIX; touch -t is, so try both date spellings for the stamp
    _stamp="$(date -d "@$_when" '+%Y%m%d%H%M.%S' 2>/dev/null \
           || date -r "$_when" '+%Y%m%d%H%M.%S' 2>/dev/null)" || _stamp=""
    [ -n "$_stamp" ] || return 1
    touch -t "$_stamp" "$AGE_FUTURE_REF" 2>/dev/null || return 1
    return 0
}
# count_filtered_under -- attribute the regular files this root's policy removed to the two
# disjoint reasons; $1 = regular files the discovery walk emitted. Every walk reuses the discovery
# walk's prune set, built once into _base, so all counts describe one tree.
# Each category is MEASURED by matching it, never derived by subtracting one walk from another:
# the walks are not simultaneous, and a derived count publishes churn as a policy exclusion.
# They do run after discovery, so a changing tree still makes the counts a snapshot — detected
# (discovered + age + size must equal a bare -type f total) and labelled, never printed as fact.
# Reads: scandir, walk_excludes, cloud_prunes, SIZE_TEST, AGE_TESTS, AGE_MTIME_TEST,
#        AGE_CTIME_TEST, AGE_TIMESTAMP, AGE_FUTURE_REF, MAX_AGE, COUNT_FILTERED.
# Writes: FILES_SIZE_FILTERED, FILES_AGE_FILTERED, FILES_AGE_CTIME_ONLY, FILES_FUTURE,
#         FUTURE_UNMEASURED, COUNT_CHURNED, COUNT_MATCHING_PARTIAL.
count_filtered_under() {
    [ "$COUNT_FILTERED" -eq 1 ] || return 0
    local _discovered="${1:-0}" _size=0 _age=0 _count_start
    local -a _base
    _base=("$scandir" "${walk_excludes[@]}" "${cloud_prunes[@]+"${cloud_prunes[@]}"}")
    _count_start="$(date +%s 2>/dev/null)" || _count_start=0
    is_integer "$_count_start" || _count_start=0
    # Only when a bound exists. A bare "! " with SIZE_TEST empty is not a no-op: find reads it
    # as "! -print0", which matches every regular file and would publish the whole tree as
    # size_filtered — the same silent-inflation class the derived counts were removed to avoid.
    _size=0
    if [ "${#OVERSIZE_TEST[@]}" -gt 0 ]; then
        count_matching "${_base[@]}" -type f "${OVERSIZE_TEST[@]}"
        _size="$COUNT_MATCHING_OUT"
        FILES_SIZE_FILTERED=$(( FILES_SIZE_FILTERED + _size ))
    fi
    # The size test keeps the two categories disjoint: oversize-and-too-old counts once, as size.
    if [ "${#AGE_TESTS[@]}" -gt 0 ]; then
        count_matching "${_base[@]}" -type f "${SIZE_TEST[@]+"${SIZE_TEST[@]}"}" ! "${AGE_TESTS[@]}"
        _age="$COUNT_MATCHING_OUT"
        FILES_AGE_FILTERED=$(( FILES_AGE_FILTERED + _age ))
        # What the ctime arm alone contributed: in the window, but only because ctime moved.
        if [ "$AGE_TIMESTAMP" = "any" ]; then
            # Length-checked, not merely "[@]+"-guarded: the guard prevents an unset-variable
            # error, it does NOT prevent the degeneracy. An empty arm here leaves a bare "!"
            # in front of the appended -print0, which find reads as "! -print0" — matching the
            # whole tree and inflating age_ctime_only exactly as an empty SIZE_TEST once
            # inflated size_filtered. Only a length check rules that out, and it rules it out
            # LOCALLY instead of relying on build_age_tests keeping the two arms in lockstep
            # with AGE_TESTS.
            if [ "${#AGE_MTIME_TEST[@]}" -gt 0 ] && [ "${#AGE_CTIME_TEST[@]}" -gt 0 ]; then
                count_matching "${_base[@]}" -type f "${SIZE_TEST[@]+"${SIZE_TEST[@]}"}" \
                    ! "${AGE_MTIME_TEST[@]}" "${AGE_CTIME_TEST[@]}"
                FILES_AGE_CTIME_ONLY=$(( FILES_AGE_CTIME_ONLY + COUNT_MATCHING_OUT ))
            fi
        fi
    fi
    # The future count carries the whole discovery policy, not just -newer: otherwise it counts
    # files the run dropped and the "collected" warning would be false.
    if stamp_future_ref; then
        count_matching "${_base[@]}" -type f "${SIZE_TEST[@]+"${SIZE_TEST[@]}"}" \
            "${AGE_TESTS[@]+"${AGE_TESTS[@]}"}" -newer "$AGE_FUTURE_REF"
        FILES_FUTURE=$(( FILES_FUTURE + COUNT_MATCHING_OUT ))
    else
        # future=0 must not mean three different things (none found / not counted / no reference).
        FUTURE_UNMEASURED=1
    fi
    # Reconciliation walk: discovered + age + size must exhaust a bare -type f total, or the tree
    # changed. Skipped when a counting walk already failed (all-zero counts would be blamed on the
    # host), and the drift gets an allowance: the age predicates are relative and re-evaluated per
    # walk, so files crossing the window mid-walk (~ total x span / window) are arithmetic, not churn.
    [ "$COUNT_MATCHING_PARTIAL" -eq 0 ] || return 0
    local _total _accounted _drift _allow=1 _span=0 _now
    count_matching "${_base[@]}" -type f
    [ "$COUNT_MATCHING_PARTIAL" -eq 0 ] || return 0
    _total="$COUNT_MATCHING_OUT"
    _accounted=$(( _discovered + _age + _size ))
    _drift=$(( _total - _accounted ))
    # A file whose size cannot be read (its directory is readable but not searchable) fails the
    # keep test and the over test alike, so it lands in no category. It needs no accounting of
    # its own here: find cannot stat it either, so every counting walk over that subtree exits
    # non-zero, COUNT_MATCHING_PARTIAL is already set, and this reconciliation was skipped above
    # with the run saying the counts are a lower bound. (Verified as an unprivileged user: a
    # 0444 directory makes find exit non-zero and the "lower bound" line is what gets printed.)
    [ "$_drift" -lt 0 ] && _drift=$(( - _drift ))
    _now="$(date +%s 2>/dev/null)" || _now=""
    if is_integer "$_now" && [ "$_count_start" -gt 0 ] 2>/dev/null; then
        _span=$(( _now - _count_start ))
        [ "$_span" -lt 0 ] && _span=0
    fi
    if [ "$MAX_AGE" -gt 0 ] && [ "$_span" -gt 0 ]; then
        _allow=$(( 1 + (_total * _span) / (MAX_AGE * 86400) ))
    fi
    if [ "$_drift" -gt "$_allow" ]; then
        COUNT_CHURNED=1
        log_msg debug "Filter accounting for '$scandir' drifted by $_drift file(s) (allowance $_allow over ${_span}s): $_total regular file(s) now, $_discovered discovered + $_age outside the age window + $_size over the size limit = $_accounted"
    fi
    return 0
}

# build_age_tests -- build the age half of the discovery policy ONCE per run into AGE_TESTS, used
# by the walk, the counting walks and the symlink-target test. Empty when --max-age is 0.
# Timestamp (AGE_TIMESTAMP): mtime is freely forgeable (touch -d), while writing or backdating a
# file always updates ctime, which no userspace call can set. The default ORs both because a
# FORWARD stomp is the one case where mtime > ctime, so ctime alone would miss it. Birth time is
# not exposed by any Linux find; atime is meaningless under relatime/noatime.
# Predicate: -mmin/-cmin (minutes) are preferred — the -mtime day buckets make the exact boundary
# implementation-defined (GNU keeps a file aged exactly N days, busybox drops it, BSD/macOS
# rounds the age up). They are not POSIX, so support is probed once; -mtime/-ctime stay as the
# Solaris/AIX fallback.
build_age_tests() {
    AGE_TESTS=()
    AGE_MTIME_TEST=()
    AGE_CTIME_TEST=()
    AGE_PRECISION=""
    AGE_CUTOFF_TEXT=""

    local _probe="${TS_WORK_DIR:-.}" _mpred _cpred _v _cut
    # Reference file for the POSIX '-newer' future check, re-stamped a minute ahead by
    # stamp_future_ref at counting time. It lives in the work directory, which every walk prunes.
    if [ -n "$TS_WORK_DIR" ] && : > "$TS_WORK_DIR/runstart.ref" 2>/dev/null; then
        AGE_FUTURE_REF="$TS_WORK_DIR/runstart.ref"
    fi
    # -prune keeps each probe to one directory: just "does this find accept the predicate", both
    # arms. The reference above exists even at --max-age 0, so future= still reports there.
    [ "$MAX_AGE" -gt 0 ] || return 0
    if find "$_probe" -prune -mmin -1 >/dev/null 2>&1 && find "$_probe" -prune -cmin -1 >/dev/null 2>&1; then
        AGE_PRECISION="minute"
        _v=$(( MAX_AGE * 1440 ))
        _mpred="-mmin"
        _cpred="-cmin"
    else
        AGE_PRECISION="day"
        _v="$MAX_AGE"
        _mpred="-mtime"
        _cpred="-ctime"
    fi
    AGE_MTIME_TEST=("$_mpred" "-$_v")
    AGE_CTIME_TEST=("$_cpred" "-$_v")
    case "$AGE_TIMESTAMP" in
        mtime) AGE_TESTS=("${AGE_MTIME_TEST[@]}") ;;
        ctime) AGE_TESTS=("${AGE_CTIME_TEST[@]}") ;;
        # Parenthesised so that a later "! ${AGE_TESTS[@]}" negates the whole disjunction and not
        # just its first arm.
        *)     AGE_TESTS=(\( "${AGE_MTIME_TEST[@]}" -o "${AGE_CTIME_TEST[@]}" \)) ;;
    esac

    # Absolute cutoff for the log only, and AT RUN START (the line says so): each root's find
    # re-evaluates the window when reached, so a later root's cutoff is marginally newer/tighter.
    # date's epoch form differs across implementations; when neither works the line omits it.
    if [ "$START_TS" -gt 0 ] 2>/dev/null; then
        _cut=$(( START_TS - MAX_AGE * 86400 ))
        AGE_CUTOFF_TEXT="$(date -d "@$_cut" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                        || date -r "$_cut" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || AGE_CUTOFF_TEXT=""
    fi
    return 0
}

# log_age_policy -- state the age policy once, in terms an operator can reconcile against the
# filesystem later. "Max age (days): 0" used to be printed for the unlimited case, which reads as
# its exact opposite.
log_age_policy() {
    local _which _msg
    if [ "$MAX_AGE" -le 0 ] 2>/dev/null; then
        log_msg info "Age filter: disabled (--max-age 0); files are collected regardless of age (--age-timestamp has no effect)"
        return 0
    fi
    case "$AGE_TIMESTAMP" in
        mtime) _which="mtime" ;;
        ctime) _which="ctime" ;;
        *)     _which="mtime or ctime" ;;
    esac
    _msg="Age filter: $_which within $MAX_AGE day(s), ${AGE_PRECISION:-day} precision"
    [ -n "$AGE_CUTOFF_TEXT" ] && _msg="$_msg; at run start that is files newer than $AGE_CUTOFF_TEXT"
    log_msg info "$_msg"
    return 0
}

# log_size_policy -- state the size policy once, in the same reconcilable terms as
# log_age_policy. The old line was a bare "Max size (KB): 2000", which says neither that KB
# means KiB (1024, as in the Go collector, not 1000) nor which side of the boundary is kept —
# the two questions an analyst asks when a file is missing from the collection.
log_size_policy() {
    if [ "${#SIZE_TEST[@]}" -eq 0 ]; then
        log_msg info "Size filter: disabled (--max-size 0); files are collected whatever their size"
        return 0
    fi
    local _bytes
    _bytes=$(( MAX_FILE_SIZE_KB * 1024 ))
    log_msg info "Size filter: regular files up to $MAX_FILE_SIZE_KB KiB ($_bytes bytes) are collected; a file of exactly $_bytes bytes is kept, one of $(( _bytes + 1 )) is not"
    return 0
}

# build_exclusion_base -- assemble the run-wide inputs the per-root exclusion machinery consumes:
# the anchor list (built-ins plus every network / pseudo-filesystem mount point), the cloud-name
# tests, the CloudStorage prune, the byte bound derived from --max-size, this run\'s own
# artifacts, and the predicates used to judge a symlink target. Per-root spelling happens later in
# compose_root_excludes; this function only decides WHAT is excluded, never HOW it is spelled.
# Writes: exclude_path_list, cloud_name_tests, cloudstorage_prune, _self_paths,
# link_stat_test, _link_targets_done.
build_exclusion_base() {
    # Base exclusions, kept as a plain path list so each scan root composes its own prune
    # set: an explicitly requested root must not be blocked by its own anchor, while
    # everything else stays pruned.
    exclude_path_list=()
    local _ep _cloud_name _old_ifs _selfp _logdir _logbase
    for _ep in "${EXCLUDE_PATHS[@]}"; do
        [ -d "$_ep" ] && exclude_path_list+=("$_ep")
    done
    # Never stat a network or pseudo-filesystem mount point — not even '[ -d ]'. A dead NFS
    # or CIFS export, or an autofs trigger, answers stat with an uninterruptible hang, and
    # this list is built before any scanning on EVERY run. The type is already known from
    # the mount table; a -path prune on a path that turns out not to exist is harmless. The
    # points arrive as an array (excluded_mounts_lookup), so one containing a newline stays
    # one prune.
    excluded_mounts_lookup
    exclude_path_list+=("${EXCLUDED_MOUNTS_OUT[@]+"${EXCLUDED_MOUNTS_OUT[@]}"}")
    # With no mount table the two filesystem-class gates (roots and every link hop) can refuse
    # nothing — say so once per run, here, before any scanning. Dry-run is the mode operators
    # use to check exactly this.
    load_mount_table   # idempotent; guarantees the table is in THIS process, not a subshell
    if [ "${#MOUNT_POINTS[@]}" -eq 0 ]; then
        log_msg warn "Mount table unavailable (/proc/mounts unreadable and no usable mount(8) output): network and kernel pseudo-filesystems cannot be recognised; only the built-in path exclusions apply"
    fi

    # Cloud storage exclusion: a folder NAME like "Dropbox" is only a candidate — real
    # cloud storage is excluded only with positive evidence (cloud_dir_evidence). Build the
    # name tests once here; each scan root then runs a candidate pass that verifies matches
    # and prunes only proven sync folders. The macOS CloudStorage location is proof by
    # itself, so it stays a direct prune in the base excludes.
    cloud_name_tests=()
    for _cloud_name in $CLOUD_DIR_NAMES; do
        [ "${#cloud_name_tests[@]}" -gt 0 ] && cloud_name_tests+=(-o)
        cloud_name_tests+=(-iname "$_cloud_name")
    done
    _old_ifs="$IFS"
    IFS='|'
    for _cloud_name in $CLOUD_DIR_NAMES_SPACED; do
        cloud_name_tests+=(-o -iname "$_cloud_name")
    done
    for _cloud_name in $CLOUD_DIR_PATTERNS; do
        cloud_name_tests+=(-o -iname "${_cloud_name}*")
    done
    IFS="$_old_ifs"
    # The macOS CloudStorage location is positive evidence by itself — always pruned. -path
    # alone pins the exact, case-sensitive final component; the former -iname test was
    # redundant and non-POSIX, and a find without -iname made EVERY root fail enumeration.
    cloudstorage_prune=(\( -path "*/Library/CloudStorage" -type d -prune \) -o)

    # the size limit is enforced by find during discovery. '-size -Nc' (bytes) is the
    # one POSIX size unit — identical on GNU/BSD/macOS/busybox — and find reads the size
    # from the stat it already performs, so the check is free (no per-file fork later).
    # Keeping bytes makes the boundary bit-identical to the former KB rule:
    # ceil(bytes/1024) <= MAX  <=>  bytes <= MAX*1024  <=>  -size -"(MAX*1024+1)"c.
    # Empty at --max-size 0, so the size arm disappears from every expression the way the
    # age arm does at --max-age 0 — one spelling of the walk for every configuration. Every
    # consumer must therefore expand it with the "[@]+" guard and must not build a predicate
    # around it unguarded: '-type f ! ${SIZE_TEST[@]}' with SIZE_TEST empty is not an empty
    # test, it is '-type f ! -print0', which matches EVERY regular file (measured: 3 of 3
    # instead of 1) and would report the whole tree as size_filtered.
    if [ "$MAX_FILE_SIZE_KB" -gt 0 ]; then
        # keep: bytes <= MAX*1024   ->  -size -(MAX*1024+1)c
        # over: bytes >  MAX*1024   ->  -size +(MAX*1024)c
        # Exact complements over files that can be stat'ed, and both false when the stat fails.
        SIZE_TEST=(-size "-$(( MAX_FILE_SIZE_KB * 1024 + 1 ))c")
        OVERSIZE_TEST=(-size "+$(( MAX_FILE_SIZE_KB * 1024 ))c")
    else
        SIZE_TEST=()
        OVERSIZE_TEST=()
    fi

    # the age half of the policy, built once and shared by the walk and the symlink-target
    # test, then stated in terms the operator can reconcile against the filesystem afterwards.
    build_age_tests
    log_age_policy
    log_size_policy

    # never collect our own artifacts. The private work directory and the log file are
    # excluded from every walk by EXACT path — never by name pattern (a pattern would
    # over-exclude user files and hand attackers a camouflage name, the same hole closed
    # for cloud folders). Stale work dirs from crashed runs are collected on purpose:
    # over-collection is the safe forensic direction.
    # Both are kept as PHYSICAL (-P) paths (logical only if -P fails): the symlink-target
    # check judges a link by its fully resolved target, and the walk prune is spelled
    # PER ROOT from the physical relationship (spell_under_root, at prune composition) —
    # find prints '<root as spelled>/<physical tail>', which matches neither the logical nor
    # the physical spelling of an artifact reached through a symlinked TMPDIR or cwd (macOS:
    # /var -> /private/var, /tmp -> /private/tmp), so the collector uploaded its own
    # find.err, result lists and live log.
    _self_paths=()
    if ensure_work_dir && { resolve_dir -P "$TS_WORK_DIR" || resolve_dir -L "$TS_WORK_DIR"; }; then
        _self_paths+=("$RESOLVE_DIR_OUT")
        log_msg debug "Excluding own work directory '$RESOLVE_DIR_OUT'"
    fi
    if [ "$LOG_TO_FILE" -eq 1 ]; then
        case "$LOGFILE" in
            */*) _logdir="${LOGFILE%/*}"; _logbase="${LOGFILE##*/}" ;;
            *)   _logdir=".";             _logbase="$LOGFILE" ;;
        esac
        if resolve_dir -P "${_logdir:-/}" || resolve_dir -L "${_logdir:-/}"; then
            _self_paths+=("${RESOLVE_DIR_OUT%/}/$_logbase")
            log_msg debug "Excluding own log file '${RESOLVE_DIR_OUT%/}/$_logbase'"
        fi
    fi

    # predicates for testing a symlink's DEREFERENCED target (single path, -prune, no
    # traversal) — the same size/age policy the walk applies to regular files.
    link_stat_test=(-prune -type f "${SIZE_TEST[@]+"${SIZE_TEST[@]}"}" "${AGE_TESTS[@]+"${AGE_TESTS[@]}"}")
    # resolved targets already delivered through a link this run — a second link to
    # the same file is accounted as a duplicate, not uploaded again.
    _link_targets_done=()
    return 0
}
main() {
    local scheme="http"
    local endpoint_name="check"
    local query_source=""
    local api_endpoint=""
    local base_url=""
    local scandir
    local file_path
    local elapsed=0
    local find_results_file
    local find_rc=0
    local _canon_mode
    local _resolved
    local _accounted=0
    local _link_breakdown=0
    local reconcile_failed=0
    local _i
    local _dup
    local _cmpdir
    local _root_is_link
    local cloud_prunes
    local _cand_file
    local _cand
    local _cloud_ev
    local _p
    local walk_excludes
    local _fstype
    local _excluded_note
    local _physdir
    local _physnote
    local _entry
    local _known
    local _in_cloud_scope
    local _keep_cloudstorage_prune
    local _find_err
    local _find_msg
    local _covered
    local _child_prunes
    local _dir_errs
    local _word
    local _folders _f
    local _typed _typed_ok _kind

    parse_args "$@"
    # Options are known: open the file sink. validate_config's usage errors and every runtime
    # error from here on are logged to the configured file (or nowhere, with --no-log-file).
    prepare_run

    build_exclusion_base

    # First pass: collect all file lists and count total files for progress
    local all_find_files=()
    local _seen_dirs=()
    local _seen_phys=()
    for scandir in "${SCAN_FOLDERS[@]}"; do
        classify_root || continue
        compose_root_excludes

        root_cloud_scope
        enumerate_root || continue
    done

    log_msg info "Found $TOTAL_FILES candidates ($((TOTAL_FILES - TOTAL_LINKS)) files, $TOTAL_LINKS symlinks)"

    collect_entries "$api_endpoint"

    report_run "$base_url"
    return $?
}

main "$@"
exit $?
