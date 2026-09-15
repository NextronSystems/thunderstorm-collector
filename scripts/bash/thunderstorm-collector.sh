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
# 129/130/131/143  interrupted by SIGHUP / SIGINT / SIGQUIT / SIGTERM (128 + signal number).
# Each sends an interrupted marker naming the signal and removes the work directory.
# Under nohup, HUP is ignored on entry and cannot be trapped — the run simply
# continues and ends normally.

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

# Captured before the defaults overwrite them, so the run can say the environment was ignored
# rather than ignoring it in silence. Deliberately NOT honoured: an exported variable that can
# redirect where evidence is sent is not something a forensic collector should obey -- and the
# server decides that even more than the port does.
THUNDERSTORM_SERVER_ENV="${THUNDERSTORM_SERVER:-}"
# No default: --server is required (validate_config), because a default here is a default
# DESTINATION FOR EVIDENCE. Kept as an assignment rather than deleted -- verify_portable.sh sources
# this file as a library, and the capture above reads the variable.
THUNDERSTORM_SERVER=""
THUNDERSTORM_PORT_ENV="${THUNDERSTORM_PORT:-}"
THUNDERSTORM_PORT=8080
USE_SSL=0
# The destination-down breaker. A server that dies mid-run used to cost one FULL retry budget per
# remaining file and print an identical error for each -- on a large tree, minutes of pointless
# timeouts and an unreadable log. GRR will not even dequeue evidence it cannot ship; Wazuh treats
# "nothing answered" as the only state that pauses the run and re-probes before giving up.
#
# Only sentinel 90 counts (transport failed before a verdict): a file the SERVER refused says
# nothing about whether the destination is still there. Three consecutive 90s trigger one
# re-preflight -- a server that merely hiccupped is forgiven -- and only if that fails too does the
# run stop transmitting. Every remaining file is still COUNTED, so the discovered-vs-accounted
# reconciliation cannot silently lose entries.
DEST_DOWN=0
DEST_DOWN_STREAK=0
DEST_DOWN_THRESHOLD=3
DEST_DOWN_REARMS=0      # recoveries used so far; a breaker that re-arms without a cap is not a breaker
DEST_DOWN_REARM_MAX=5   # after this many recover-then-fail cycles the destination is called down
DEST_DOWN_WITHHELD=0
DEST_DOWN_AT=""
# The base URL of the SELECTED destination, so the breaker can re-probe it. A global because
# base_url is a local of main.
RUN_BASE_URL=""
INSECURE=0
CA_CERT=""

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
# --dry-run: a real run minus the TRANSMISSION. Identical discovery, filters, per-file decisions and
# reported numbers; the ONE request it still makes is the destination check (GET /api/status), which
# carries no evidence. Full rule in README.md.
#
# FOUR things can leave this host, and each gates on this flag: the file body (submit_file), and the
# begin/end/interrupted markers (prepare_run, report_run, send_interrupted_marker -- plus a backstop
# inside collection_marker itself). Every other read decides only what the operator is SHOWN.
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
# "this entry's size could be READ": every statable file satisfies exactly one of "zero bytes" and
# "non-zero", so matching neither means the stat failed. It qualifies any counting walk whose
# category is matched by NEGATION — '! <age test>' is true both for a file outside the window and
# for one whose stat was refused, which reported every file hidden by an unsearchable directory as
# "outside the age window". The size category sidesteps this by matching positively.
declare -a STATABLE_TEST=(\( -size -1c -o -size +0c \))
AGE_PRECISION=""       # "minute" or "day" — which predicate family the local find supports
AGE_CUTOFF_TEXT=""     # human-readable absolute cutoff, for the run log ("" if date cannot help)
AGE_FUTURE_REF=""      # file stamped at run start, for the POSIX -newer future-timestamp test

UPLOAD_TOOL=""
WGET_IS_MINIMAL=0   # the wget found rejects the options this file relies on (busybox applet)
# 1 once --no-config is on the wget command line, i.e. NO rc file can influence the transport. Until
# then wget still reads the SYSTEM rc, which can define a proxy this collector cannot see -- so this
# flag is what the proxy verdict's honesty depends on. See prepare_run, where it is set.
WGET_RC_SEALED=0
TIMEOUT_CMD=""      # timeout(1), when present: the cheap way to bound a wget that cannot bound itself
# every temp file the collector makes lives in ONE private work directory (created on
# demand, mode 700), which is excluded from scanning by exact path — the collector must
# never collect its own working files. Cleanup is a single rm -rf of this directory.
TS_WORK_DIR=""
declare -a CURL_EXTRA_OPTS=()
# --max-redirect=0 is DECLARED here, not granted by prepare_run. A signal trap firing before the
# options were assembled once ran collection_marker with an empty array -- wget's default
# --max-redirect=20, no --insecure/--ca-cert, ~/.wgetrc in force. send_interrupted_marker is now
# gated on BEGIN_MARKER_SENT so it cannot fire that early, and this default is the standing
# defence behind that: a security default must not be something a later function grants.
declare -a WGET_EXTRA_OPTS=(--max-redirect=0)

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
# Set when a 2xx is not a Thunderstorm answer (no {"id":N} from /api/checkAsync, the one endpoint
# this collector uses) BEFORE any upload has ever been acknowledged: from then on submit_file
# withholds every
# file without transmitting, so evidence stops flowing to a peer that has not proved what it is. A
# peer that already acknowledged uploads is not poisoned by one odd answer -- that is retried like
# any other failed attempt. The run then ends with exit 4 and BOTH markers are WITHHELD from that
# peer -- the end marker in report_run and the interrupted marker in send_interrupted_marker -- for
# the same reason the file bodies are: a marker carries the host's source name and the run's
# statistics, and the collector has already decided this peer is not a Thunderstorm. (This comment
# used to say "end marker attempted", which the code had never done since the withholding landed.)
PEER_UNACKNOWLEDGED=0
PEER_UNACKNOWLEDGED_AT=""
PEER_UNACKNOWLEDGED_FILE=""  # the ONE file whose bytes reached the peer before the flow stopped
FILES_UNACKNOWLEDGED=0 # that file plus every one withheld; a subset of FILES_UPLOAD_FAILED
# Directories find could not read. A directory is not an artifact: what it held is unknown, so
# the files missed cannot be counted — only the directories can (one find diagnostic each on
# GNU, BSD and busybox). Any such directory makes the run partial (exit 4).
UNREADABLE_DIRS=0
# The two classes behind UNREADABLE_DIRS, because they are different forensic facts: a directory
# that cannot be LISTED hides even the names of what it held, while one that can be listed but
# not SEARCHED yields its names and nothing else. UNREADABLE_DIRS is their sum.
UNLISTABLE_DIRS=0
UNSEARCHABLE_DIRS=0
FIRST_UNREADABLE_DIR=""
# Entries that are KNOWN to exist — the walk listed their names — whose stat failed, so no size
# or age predicate could be evaluated and discovery dropped them without a word. They never
# entered the collection pipeline, so like UNREADABLE_DIRS they are in no reconciliation
# identity; they are a coverage gap, reported and made to change the exit code.
UNSTATABLE_ENTRIES=0
FIRST_UNSTATABLE=""
# 1 when a directory was found unsearchable but the probe listed none of its entries. busybox
# find stats unconditionally and so cannot see them at all, and an empty directory looks the
# same — say "not measured here" rather than print a bare 0 (as future= already does).
UNSTATABLE_UNMEASURED=0
# Same "unstatable= is not a measured zero", different reason: both discovery gates are off, so
# the probe stands down by configuration. Kept apart because the two sentences are not
# interchangeable, and printing the platform one here was false on a find that CAN list them.
UNSTATABLE_UNMEASURED_GATES=0
# 1 when a discovery walk reported an error that neither probe could attribute to a directory or
# an entry. A FLAG, not a count: the number of diagnostics is precisely the quantity that cannot
# be measured, and inventing one is the defect this replaces (the old code answered "I do not
# know" with "1 directory").
WALK_ERRORS_UNEXPLAINED=0
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
        # shellcheck disable=SC2015  # A && B || C is EXACTLY what is wanted: skip the line unless
        # both fields are present. There is no else-branch to get wrong.
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

# shellcheck disable=SC2317  # trap-invoked only; ShellCheck cannot see the trap as a caller
cleanup_tmp_files() {
    if [ -n "$TS_WORK_DIR" ] && [ -d "$TS_WORK_DIR" ]; then
        rm -rf -- "$TS_WORK_DIR" 2>/dev/null || :
    fi
}

INTERRUPTED=0
# Which signal ended the run, for the interrupted marker. The server could not previously tell an
# operator stopping a scan (INT/QUIT) from infrastructure cutting it off (HUP/TERM) — the one
# distinction that decides whether a gap in the collection needs investigating.
INTERRUPTED_BY=""
# The backstop's two facts: we announced the scan to the server, and we never announced its end.
BEGIN_MARKER_SENT=0
RUN_FINISHED=0

# build_stats_json -- the run's counters as the marker payload's "stats" object, in
# STATS_JSON_OUT. $1 is the elapsed seconds to report.
#
# ONE spelling of this object, because there are two markers that carry it (the end
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
    # interrupted_by only when a signal ended the run, so the end marker's JSON is unchanged
    # byte for byte and no existing consumer sees a new field on a normal run.
    local _by=""
    [ -n "$INTERRUPTED_BY" ] && _by="\"interrupted_by\":\"${INTERRUPTED_BY}\","
    submitted_key
    STATS_JSON_OUT="\"stats\":{${_by}\"scanned\":${FILES_SCANNED},\"${SUBMIT_KEY_OUT}\":${FILES_SUBMITTED},\"skipped\":${FILES_SKIPPED},\"age_filtered\":${FILES_AGE_FILTERED},\"size_filtered\":${FILES_SIZE_FILTERED},\"age_ctime_only\":${FILES_AGE_CTIME_ONLY},\"future\":${FILES_FUTURE},\"max_size_kb\":${MAX_FILE_SIZE_KB},\"size_bound_bytes\":$(( MAX_FILE_SIZE_KB * 1024 )),\"max_age\":${MAX_AGE},\"age_timestamp\":\"${AGE_TIMESTAMP}\",\"age_precision\":\"${AGE_PRECISION:-none}\",\"counts_measured\":${COUNT_FILTERED},\"failed\":${FILES_FAILED},\"links_seen\":${LINKS_SEEN},\"links_collected\":${LINKS_COLLECTED},\"links_skipped\":${LINKS_SKIPPED},\"unreadable_dirs\":${UNREADABLE_DIRS},\"unstatable\":${UNSTATABLE_ENTRIES},\"walk_errors_unexplained\":${WALK_ERRORS_UNEXPLAINED},\"unusable_dirs\":${UNUSABLE_DIRS},\"elapsed_seconds\":${1:-0}}"
}

# build_base_url -- put "<scheme>://<server>:<port>" into BASE_URL_OUT.
#
# There were two of these: prepare_run built it for the run, and send_interrupted_marker built it
# again from a trap, re-deriving the scheme with its own copy of the USE_SSL test. Two spellings of
# one address is the divergence class build_stats_json's comment already argues against -- and here
# the consequence was two URLs for one run. There is no longer a residual here: the interrupted
# marker is gated on BEGIN_MARKER_SENT, which cannot be set before the destination has been
# selected and the option arrays built, so a signal arriving mid-parse or mid-selection sends
# nothing at all. (This comment said "gated on SERVER_URLHOST_OUT" until that gate was replaced --
# SERVER_URLHOST_OUT is set at the TOP of prepare_run and was far too early to mean what it said.)
#
# Note there is no trailing-slash strip. Both copies used to end with "${_base%/}" under a comment
# saying it stripped a trailing slash; it never could, because the string always ends in the port's
# digits. Dead code with a comment that described something it did not do.
# run_elapsed -- whole seconds since the run started, in RUN_ELAPSED_OUT. Never negative (a clock
# stepped backwards mid-run must not publish a negative duration) and 0 when the start is unknown.
#
# There were THREE copies of this arithmetic: report_run's, send_interrupted_marker's, and -- once
# the destination record started carrying stats -- the record's, which read report_run's published
# value and therefore stamped elapsed_seconds:0 on every INTERRUPTED run, because a signal means
# report_run never ran. A false number in exactly the case the record was extended to cover. One
# function, so the three cannot disagree again.
RUN_ELAPSED_OUT=0
run_elapsed() {
    local _now
    RUN_ELAPSED_OUT=0
    [ "$START_TS" -gt 0 ] 2>/dev/null || return 0
    _now="$(date +%s 2>/dev/null || printf '%s\n' "$START_TS")"
    RUN_ELAPSED_OUT=$(( _now - START_TS ))
    [ "$RUN_ELAPSED_OUT" -lt 0 ] && RUN_ELAPSED_OUT=0
    return 0
}

BASE_URL_OUT=""
build_base_url() {
    local _scheme="http"
    [ "$USE_SSL" -eq 1 ] && _scheme="https"
    # SERVER_URLHOST_OUT is the host in its URL spelling -- identical to what the operator typed,
    # except that an IPv6 literal is bracketed, which is the only spelling RFC 3986 allows and
    # cannot change which host is named (--port is the sole source of the port).
    #
    # No fallback to the raw value: classify_server is the only thing that sets this, and the one
    # caller that could run before it (send_interrupted_marker, from a trap) is now gated on it
    # being set. That also retires the port residual this comment used to describe -- the port is
    # canonicalised in the same validate_config pass, so a marker can no longer carry ":08080".
    BASE_URL_OUT="${_scheme}://${SERVER_URLHOST_OUT}:${THUNDERSTORM_PORT}"
}

# shellcheck disable=SC2317  # trap-invoked only; ShellCheck cannot see the trap as a caller
send_interrupted_marker() {
    # THE GATE. An "interrupted" marker says a collection that had STARTED did not finish, so the
    # question is not "is a destination known?" but "is there something on the server to interrupt?"
    # -- and the answer to that is exactly BEGIN_MARKER_SENT.
    #
    # It was gated on SERVER_URLHOST_OUT, which validate_config sets in the first few lines of
    # prepare_run. Everything below happens after that and before the begin marker, and a signal in
    # any of these windows sent the marker anyway:
    #
    #   * before CURL_EXTRA_OPTS/WGET_EXTRA_OPTS are assembled -- the POST then goes out with none
    #     of --noproxy, --resolve, -k or --cacert: through the proxy the operator excluded, to
    #     whatever DNS returns, and without the CA the run was told to trust;
    #   * during the candidate selection that several --server values once allowed -- the marker,
    #     carrying this host's source name and statistics, went to a candidate never selected;
    #   * during the destination check of a --dry-run, which transmits nothing by definition;
    #   * after a successful run, between RUN_FINISHED=1 and exit -- reporting a completed run as
    #     interrupted.
    #
    # RUN_FINISHED covers the last of those and BEGIN_MARKER_SENT the rest, so this gate is SMALLER
    # than the one it replaces and closes all four. Preferred over a new DEST_ARMED flag: that would
    # be a sixth state variable for a condition BEGIN_MARKER_SENT already expresses.
    #
    # Note for the field: production answers 404 on /api/collection, and collection_marker treats
    # that as warn-and-continue (rc 0), so BEGIN_MARKER_SENT is still set there -- the gate is not
    # accidentally dead against a real Thunderstorm.
    [ "$DRY_RUN" -eq 0 ] || return 0
    [ "$RUN_FINISHED" -eq 0 ] || return 0
    [ "$BEGIN_MARKER_SENT" -eq 1 ] || return 0
    if [ "$PEER_UNACKNOWLEDGED" -eq 1 ]; then
        # The same rule report_run applies to the END marker, for the same reason: this marker
        # carries the host's source name and the run's complete statistics, and the collector has
        # already decided this peer is not a Thunderstorm. Withholding was half-applied -- the
        # normal path refused it and a signal handed it over anyway.
        log_msg warn "No interrupted marker was sent to $PEER_UNACKNOWLEDGED_AT: that peer never acknowledged an upload, so this run does not hand it the host's source name and run statistics either"
    else
        local _stats
        run_elapsed
        build_stats_json "$RUN_ELAPSED_OUT"
        _stats="$STATS_JSON_OUT"
        build_base_url
        collection_marker "$BASE_URL_OUT" "interrupted" "${SCAN_ID:-}" "$_stats" >/dev/null 2>&1
    fi
}

# on_signal -- end the run deliberately on a signal: tell the server, remove the work directory,
# and exit 128+signum. $1 is that exit code, $2 the signal name for the log and the marker.
# shellcheck disable=SC2317  # trap-invoked only; ShellCheck cannot see the trap as a caller
on_signal() {
    # Prevent recursive signal handling. QUIT is ignored here with the rest: 'trap - QUIT' was
    # tried, to let a second Ctrl-\ escalate past a slow handler, and it DOES NOT WORK — bash
    # defers a disposition change requested from inside a running trap until that trap returns,
    # and this one exits instead. Measured: the process survived the second QUIT. The handler is
    # therefore uninterruptible, which is acceptable only because it is bounded — the marker POST
    # carries a connect timeout AND a total timeout on both transports: --max-time under curl, and
    # under wget the reap in wget_bounded, since wget has no total bound of its own. That second
    # half was missing and this comment claimed it anyway: a trickling peer held the disarmed
    # handler open indefinitely, leaving SIGKILL as the only way out and the private work directory
    # — which holds a copy of a collected file — behind on the triaged host.
    trap '' HUP INT QUIT TERM
    INTERRUPTED=1
    INTERRUPTED_BY="${2:-}"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_msg warn "Received SIG${2:-NAL}, exiting (dry-run: no interrupted marker is sent)"
    else
        log_msg warn "Received SIG${2:-NAL}, sending interrupted marker and exiting..."
    fi
    send_interrupted_marker
    cleanup_tmp_files
    # Exit 128+signum (129 HUP / 130 INT / 131 QUIT / 143 TERM); the trap passes the code.
    exit "${1:-130}"
}

# on_exit -- last rites, and the backstop for a run that dies without on_signal having run.
#
# $? is captured first (CLAUDE.md §1) but is NOT the trigger: measured on bash 5.2.15, a shell
# killed by an untrapped signal enters its EXIT trap with $? == 0 — the 128+n is what the PARENT
# sees, not what the trap sees. The trigger is therefore state, not status: we told the server
# the scan had begun, we never told it the scan ended, and no signal handler ran.
#
# That happens for real. Bash can fail to parse a trap action when the signal lands while it is
# expanding a command substitution — measured as one lost SIGHUP in 60, with
# "trap: unexpected EOF while looking for matching ')'" — and on_signal then never runs. Without
# this the run would die exactly the way trapping HUP was meant to prevent: the server keeps a
# begin marker and nothing else, indistinguishable from a scan still in progress, and the
# private work directory stays behind on the host being triaged.
# shellcheck disable=SC2317  # trap-invoked only; ShellCheck cannot see the trap as a caller
on_exit() {
    local _rc=$?
    if [ "$INTERRUPTED" -eq 0 ] && [ "$BEGIN_MARKER_SENT" -eq 1 ] && [ "$RUN_FINISHED" -eq 0 ]; then
        INTERRUPTED=1
        # Which signal is genuinely unknown here — the handler that would have named it is the
        # one that did not run — so the marker says so rather than guessing.
        INTERRUPTED_BY="unknown"
        log_msg warn "Run ended without completing and without a signal handler running (exit status $_rc); sending the interrupted marker from the exit trap so the server is not left holding an open scan"
        send_interrupted_marker
        cleanup_tmp_files
        return 0
    fi
    # Also on the ordinary path: main writes the record itself, so this only fires when the run
    [ "$INTERRUPTED" -eq 0 ] && cleanup_tmp_files
    return 0
}

trap on_exit EXIT
# HUP and QUIT end a run exactly as INT and TERM do, and were previously left at their default
# disposition: the process died without sending an interrupted marker (the server was left
# holding a begin marker and nothing else, indistinguishable from a scan still in progress) and
# without report_run. HUP is the one that actually happens in the field — an ssh session
# dropping is the most likely way a long remote collection ends. QUIT matters because the
# private work directory it would leave behind holds, on the wget path, a full copy of the last
# collected file, on the host being triaged.
#
# Under nohup — and for a background job of a non-interactive shell, which is why the test suite
# needs 'set -m' to exercise the INT path — the signal arrives as SIG_IGN and bash cannot trap
# it: 'trap' silently installs nothing. That is benign rather than broken, because such a
# process is not killed by the signal either and finishes normally.
trap 'on_signal 129 HUP' HUP
trap 'on_signal 130 INT' INT
trap 'on_signal 131 QUIT' QUIT
trap 'on_signal 143 TERM' TERM

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

# force_sink -- make sure the next message reaches SOMEWHERE. The terminal is forced while the
# log file is not yet open, and whenever every sink is disabled (--quiet --no-log-file with no
# --syslog). Only ever called immediately before exiting, so forcing the sink changes nothing else.
#
# This was inline in die(). It is a function because die() is not the only fatal path: the runtime
# fatals in prepare_run used a bare `log_msg error` + `exit`, so under `--quiet --no-log-file` --
# the ordinary cron/CI invocation -- the single line naming an unreachable server reached no sink
# at all and the operator got a bare exit 1 with a decorative banner. die() cannot simply be reused
# there: it is hard-wired to exit 2, and these are not usage errors.
force_sink() {
    if [ "$LOG_FILE_READY" -ne 1 ] || { [ "$LOG_TO_CMDLINE" -eq 0 ] \
        && [ "$LOG_TO_FILE" -eq 0 ] && [ "$LOG_TO_SYSLOG" -eq 0 ]; }; then
        LOG_TO_CMDLINE=1
    fi
}

# die_runtime -- a fatal that is NOT a usage error: force a sink, report, exit with $1.
die_runtime() {
    local _code="$1"
    shift
    force_sink
    log_msg error "$*"
    exit "$_code"
}

die() {
    force_sink
    log_msg error "$*"
    exit 2
}

print_banner() {
    emit_lines <<EOF
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
    emit_lines <<'EOF'
Usage:
  thunderstorm-collector.sh [options]

Options:
  -s, --server <host>        Thunderstorm server: a fully qualified name, an IPv4, or an IPv6
                             written plainly (::1, not [::1]); required unless --dry-run.
                             A name needs a dot -- 'thunderstorm' alone is completed from the
                             collected host's search domain, so it can reach a different
                             server on each host. Example: --server thunderstorm.local
  -p, --port <port>          Thunderstorm port (default: 8080). Always appended to the URL:
                             --ssl does NOT change it to 443, so an HTTPS server on the
                             standard port needs --ssl --port 443.
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
  --ca-cert <path>           CA certificate bundle for TLS. Replaces the trust store under
                             curl; under wget it is only ADDED to the system store.
                             On wget 1.19+ no rc file is read at all
                             (--no-config), so a CA configured only in
                             /etc/wgetrc is NOT used -- name it here instead.
                             An older wget still reads its system rc.
  --retries <num>            Retry attempts per file (default: 3)
  --follow-symlinks          Collect the files symlinks point to (default: off)
  --dry-run                  Do everything a real run does except send: the destination is checked
                             (when --server is given), the files are selected and reported, and
                             nothing is transmitted. --server is optional here; without it the run
                             reports only what it would collect.
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
  unreadable_dirs= counts DIRECTORIES the run could not read in full, one per directory, split in
  the log between those it could not list (what they held is unknown) and those it could list but
  not search. unstatable= counts the entries the latter hide: they are known to exist, nothing
  about them could be read, not even their type, so no filter could be applied and they were not
  collected. Both make the run a partial failure (exit 4). A directory you cannot search hides
  its children's attributes, not their names.
  Never collected: kernel pseudo-filesystems, network filesystems unless you name them, and
  cloud-sync folders excluded on positive evidence (their client's marker files).
  scripts/bash/README.md documents the exclusion, accounting and exit-code rules in full.

Destination:
  Before any file is read the server must answer GET /api/status. Redirects are never followed.
  A 2xx is not a delivered file: it must carry Thunderstorm's own acknowledgement ({"id":N})
  from /api/checkAsync, or the file is not counted as submitted.
  ~/.curlrc and ~/.wgetrc are not read, and THUNDERSTORM_SERVER / THUNDERSTORM_PORT in the
  environment are ignored (and announced as ignored): only the command line decides where
  evidence goes. Proxy variables are honoured as the transport in use reads them; credentials
  in a proxy URL are never logged. This collector configures no proxy of its own and does not
  predict whether one is used -- it reports which variable is set and leaves the decision to
  curl/wget. To force a direct connection, run with http_proxy= https_proxy= set empty.

Exit codes:
  0 success · 1 runtime error · 2 usage/config · 3 missing dependency · 4 partial failure
  5 partial: files vanished mid-run (host churn only)
  129/130/131/143 interrupted by SIGHUP / SIGINT / SIGQUIT / SIGTERM

Examples:
  bash thunderstorm-collector.sh --server thunderstorm.local
  bash thunderstorm-collector.sh --server 10.0.0.5 --ssl --port 443 --dir "/tmp/My Files"
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

# ── --server: the value decides WHERE the evidence goes ──────────────────────
#
# --server names a HOST: a DNS name, an IPv4, or a PLAIN IPv6 ('::1'). build_base_url interpolates
# it into "<scheme>://<server>:<port>", so any character that can end a URL authority moves the
# destination while the run still exits 0 -- and getaddrinfo honours inet_aton, so '010.0.0.9'
# reaches 8.0.0.9. A name and an address are NOT disjoint sets. The value is therefore validated
# POSITIVELY against SERVER_OK, and one that could mean two things is refused, never rewritten.
# The brackets a URL needs around an IPv6 literal are added here, not typed: --port is the sole
# source of the port. Why each character matters: README, "the destination is the operator's to
# name". Fork-free `case` and parameter expansion throughout; Bash 3.2 safe.

# Every byte the three accepted shapes can hold, plus '[' and ']', which are diagnosed structurally
# below. ']' first and '-' last so it stays a literal set inside a negated bracket expression.
SERVER_OK='][0-9A-Za-z._:-'

# server_ipv4_ok -- true when $1 is exactly four decimal octets 0-255. A leading zero is refused
# because inet_aton reads it as octal: '010.0.0.9' resolves to 8.0.0.9, not to 10.0.0.9.
server_ipv4_ok() {
    local _rest _o _n=0
    case "$1" in *.*.*.*) ;; *) return 1 ;; esac
    _rest="$1."
    while [ -n "$_rest" ]; do
        _o="${_rest%%.*}"; _rest="${_rest#*.}"
        case "$_o" in
            0) ;;
            ''|0*|*[!0-9]*) return 1 ;;
            *) [ "${#_o}" -le 3 ] && [ "$_o" -le 255 ] || return 1 ;;
        esac
        _n=$(( _n + 1 ))
    done
    [ "$_n" -eq 4 ]
}

# server_v6_run -- count the 16-bit groups in one ':'-separated run $1 into V6_GROUPS_OUT; return 1
# if any group is malformed. $2 = "tail" where a trailing IPv4 quad is allowed (the
# '::ffff:127.0.0.1' and NAT64 '64:ff9b::192.0.2.33' forms), which counts as two groups.
V6_GROUPS_OUT=0
server_v6_run() {
    local _rest="$1" _tail="$2" _g _n=0
    V6_GROUPS_OUT=0
    [ -n "$_rest" ] || return 0            # an empty side of '::' contributes no groups
    _rest="$_rest:"
    while [ -n "$_rest" ]; do
        _g="${_rest%%:*}"; _rest="${_rest#*:}"
        [ -n "$_g" ] || return 1           # an empty group is a stray ':'
        case "$_g" in
            *.*) # only as the very last element, and only where a tail is allowed
                 [ "$_tail" = tail ] && [ -z "$_rest" ] || return 1
                 server_ipv4_ok "$_g" || return 1
                 _n=$(( _n + 2 )); continue ;;
            *[!0-9A-Fa-f]*) return 1 ;;
        esac
        [ "${#_g}" -le 4 ] || return 1
        _n=$(( _n + 1 ))
    done
    V6_GROUPS_OUT="$_n"
    return 0
}

# server_ipv6_ok -- a real check, not a shape test: eight groups, at most seven explicit around one
# '::', an IPv4 tail worth two. The tail reuses server_ipv4_ok, so '::010.0.0.1' is refused as octal.
server_ipv6_ok() {
    local _a="$1" _nl _nr
    [ "${#_a}" -le 45 ] || return 1        # the longest literal that exists is 45 characters
    case "$_a" in *[!0-9A-Fa-f:.]*) return 1 ;; esac
    case "$_a" in *:::*) return 1 ;; esac
    case "$_a" in
        *::*)
            case "${_a%%::*}" in *::*) return 1 ;; esac      # exactly one '::'
            case "${_a#*::}"  in *::*) return 1 ;; esac
            server_v6_run "${_a%%::*}" plain || return 1; _nl="$V6_GROUPS_OUT"
            server_v6_run "${_a#*::}"  tail  || return 1; _nr="$V6_GROUPS_OUT"
            [ $(( _nl + _nr )) -le 7 ] ;;  # '::' stands for at least one all-zero group
        *)
            case "$_a" in *:*) ;; *) return 1 ;; esac
            server_v6_run "$_a" tail || return 1
            [ "$V6_GROUPS_OUT" -eq 8 ] ;;
    esac
}

# server_v6_canon -- a VALIDATED literal as eight zero-padded groups in V6_CANON_OUT, so the policy
# below sees ONE spelling per address: '::ffff:0:0' and '::ffff:0.0.0.0' are the same host, and it
# is this machine's loopback. No case fold needed -- printf renders hex lower case. The input is
# already well formed, which is what bounds the arithmetic below.
V6_CANON_OUT=""
server_v6_canon() {
    local _v="$1" _l _r _g _q _a _b _c _d _out="" _i _lc=0 _rc=0
    case "$_v" in                                     # a dotted tail is two groups
        *:*.*.*.*)
            _q="${_v##*:}"; _v="${_v%:*}:"
            _a="${_q%%.*}"; _q="${_q#*.}"
            _b="${_q%%.*}"; _q="${_q#*.}"
            _c="${_q%%.*}"; _d="${_q#*.}"
            printf -v _q '%02x%02x:%02x%02x' "$_a" "$_b" "$_c" "$_d"
            _v="$_v$_q" ;;
    esac
    case "$_v" in                                     # '::' stands for the missing zero groups
        *::*)
            _l="${_v%%::*}"; _r="${_v#*::}"
            if [ -n "$_l" ]; then _lc=1; _g="$_l"; while [ "${_g#*:}" != "$_g" ]; do _lc=$(( _lc + 1 )); _g="${_g#*:}"; done; fi
            if [ -n "$_r" ]; then _rc=1; _g="$_r"; while [ "${_g#*:}" != "$_g" ]; do _rc=$(( _rc + 1 )); _g="${_g#*:}"; done; fi
            _v="$_l"; _i=$(( 8 - _lc - _rc ))
            while [ "$_i" -gt 0 ]; do _v="$_v:0"; _i=$(( _i - 1 )); done
            [ -n "$_r" ] && _v="$_v:$_r"
            _v="${_v#:}" ;;
    esac
    _g="$_v"
    while : ; do                                      # one pass: zero-pad every group
        case "$_g" in *:*) _q="${_g%%:*}"; _g="${_g#*:}" ;; *) _q="$_g"; _g="" ;; esac
        printf -v _q '%04x' $(( 0x0$_q ))             # 0x0$_q: an omitted group is empty, and 0x0 is 0
        _out="$_out:$_q"
        [ -n "$_g" ] || break
    done
    V6_CANON_OUT="${_out#:}"
}

# server_addr_names_no_host -- true when $1 (already a valid literal) names no peer, reason in
# SERVER_WHY_OUT. Matched on the CANONICAL form so every spelling gets one answer: the unspecified
# address, which the stack redirects to loopback so the evidence returns to the host being
# collected, and the IPv4 broadcast. '::255.255.255.255' is IPv4-compatible, not mapped, so not it.
server_addr_names_no_host() {
    local _a="$1"
    case "$_a" in *:*) server_v6_canon "$_a"; _a="$V6_CANON_OUT" ;; esac
    case "$_a" in
        255.255.255.255|0000:0000:0000:0000:0000:ffff:ffff:ffff)
            SERVER_WHY_OUT="is the IPv4 broadcast address, which names no destination"
            return 0 ;;
        0000:0000:0000:0000:0000:ffff:0000:0000) ;;   # the mapped unspecified address
        *[!0:.]*) return 1 ;;
    esac
    SERVER_WHY_OUT="is the unspecified address and names no destination; on connect the stack redirects it to this host's own loopback, so the evidence would be sent to the machine being collected"
    return 0
}

# server_addr_shape -- true when every dot-separated part is a C integer, i.e. an ADDRESS was typed,
# not a name. inet_aton(3)'s grammar, not "all digits": decimal, 0-octal or 0x-hex. An address
# attempt must never reach the name path, because '010.0.0.9' is a legal RFC 1123 name the resolver
# reads as 8.0.0.9. ADDR_LEGACY_OUT flags the spellings it reads DIFFERENTLY from how they look --
# octal, hex, or under four parts -- and only chooses between two messages, each true of its own
# population.
ADDR_LEGACY_OUT=0
server_addr_shape() {
    local _rest _part _n=0
    ADDR_LEGACY_OUT=0
    [ -n "${1%.}" ] || return 1
    _rest="${1%.}."
    while [ -n "$_rest" ]; do
        _part="${_rest%%.*}"; _rest="${_rest#*.}"
        _n=$(( _n + 1 ))
        case "$_part" in
            '')       return 1 ;;
            0[xX]*)   case "${_part#0[xX]}" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
                      ADDR_LEGACY_OUT=1 ;;
            *[!0-9]*) return 1 ;;
            0?*)      ADDR_LEGACY_OUT=1 ;;
        esac
    done
    [ "$_n" -ge 4 ] || ADDR_LEGACY_OUT=1
    return 0
}

# server_dnsname_ok -- RFC 1123 STRUCTURE only, with the reason in SERVER_WHY_OUT; the character
# rule is SERVER_OK, already applied.
# '_' is tolerated because internal zones use it. The 253 bound excludes the legal trailing root
# dot, or that tolerance would stop being true at exactly 253 -- the one length where it matters.
server_dnsname_ok() {
    local _name="${1%.}" _rest _label
    [ "${#_name}" -le 253 ] || { SERVER_WHY_OUT="is longer than 253 characters"; return 1; }
    [ -n "$_name" ] || { SERVER_WHY_OUT="is only a dot"; return 1; }
    # The destination must not depend on the COLLECTED host's resolver configuration. A name with no
    # dot is completed from that host's search list, so one command line can reach a different
    # server on every host it runs on, while every log reads the same. Tested on the RAW value: a
    # trailing root dot makes the name absolute, so 'thunderstorm.' is exact and stays accepted.
    case "$1" in
        *.*) ;;
        *)   SERVER_WHY_OUT="is a single label, so the collected host's own search domain would complete it and it can reach a different server on each host; give the fully qualified name"
             return 1 ;;
    esac
    _rest="$_name."
    while [ -n "$_rest" ]; do
        _label="${_rest%%.*}"; _rest="${_rest#*.}"
        case "$_label" in
            '')    SERVER_WHY_OUT="has an empty label (a leading dot, or two dots in a row)"; return 1 ;;
            -*|*-) SERVER_WHY_OUT="has a label that starts or ends with '-'"; return 1 ;;
        esac
        [ "${#_label}" -le 63 ] || { SERVER_WHY_OUT="has a label longer than 63 characters"; return 1; }
    done
    return 0
}

# classify_server -- the one gate on the one flag that says where the evidence goes. No port, no
# scheme, no brackets, no path, no credentials: everything else a URL carries belongs to another
# flag (--port, --ssl) or does not exist here (every client hard-codes /api/... at the root).
# $1 is the raw value. On success sets SERVER_KIND_OUT (name|ipv4|ipv6) and SERVER_URLHOST_OUT (the
# host as a URL needs it, IPv6 bracketed here). On failure sets SERVER_WHY_OUT, phrased to complete
# "the value ... ", and never echoes the whole value -- before an '@' it is a password, and the
# caller's message is the one place it is logged.
# LC_ALL=C makes every pattern here and in the helpers a BYTE test: a range like '[!\ -~]' is
# collation-dependent in any other locale, which the operator does not choose.
SERVER_KIND_OUT=""
SERVER_URLHOST_OUT=""
SERVER_WHY_OUT=""
classify_server() {
    local LC_ALL=C
    local _v="$1" _head _c _inner _port
    SERVER_KIND_OUT=""; SERVER_URLHOST_OUT=""; SERVER_WHY_OUT=""
    # BEFORE the scan: the first-offending-byte extraction is O(n^2) in bash, so an unbounded
    # value made a 100 KB paste cost 56 ms instead of 1. Over-long is true and actionable anyway.
    if [ "${#_v}" -gt 254 ]; then SERVER_WHY_OUT="is longer than 253 characters"; return 1; fi

    # Shapes where naming one character would be true but useless.
    case "$_v" in
        '')            SERVER_WHY_OUT="is empty"; return 1 ;;
        *[[:space:]]*) SERVER_WHY_OUT="contains whitespace"; return 1 ;;
        *\{*|*\}*)     SERVER_WHY_OUT="contains '{' or '}'; that is curl's URL list syntax, so the value does not name one host"; return 1 ;;
        # After the braces arm, so 'http://{a,b}.example' keeps the more specific message. Naming
        # the '/' here would be true and useless: the mistake is the scheme, and --ssl is its fix.
        *://*)         SERVER_WHY_OUT="is a URL, not a host; drop the scheme (--ssl selects https) and any port (--port)"; return 1 ;;
    esac

    # The offending byte is COMPUTED from the set that IS allowed, so there is no deny-list to keep
    # in step with curl's URL grammar: a character it learns to treat specially tomorrow is refused
    # today. shellcheck disable=SC2295 -- SERVER_OK is the bracket BODY, not a literal string.
    # shellcheck disable=SC2295
    _head="${_v%%[!$SERVER_OK]*}"
    if [ "${#_head}" -lt "${#_v}" ]; then
        _c="${_v:${#_head}:1}"
        # The fallback names any byte, so ';' and '^' need no arm. These five keep one because each
        # has a CONSEQUENCE -- where the evidence would go -- that naming the character alone hides.
        case "$_c" in
            [!\ -~]) SERVER_WHY_OUT="contains a non-ASCII byte; pass the punycode (xn--) form, which curl and wget read identically" ;;
            @)   SERVER_WHY_OUT="contains '@'; the collection would go to '${_v##*@}' and the rest be offered to it as a credential" ;;
            /)   SERVER_WHY_OUT="contains '/'; --server takes a host only, and the path would silently replace --port" ;;
            '?') SERVER_WHY_OUT="contains '?'; --server takes a host only, and the API path would be discarded" ;;
            '#') SERVER_WHY_OUT="contains '#'; --server takes a host only, and nothing after it is ever requested" ;;
            %)   SERVER_WHY_OUT="contains '%'; percent-encoding and IPv6 zone ids are not accepted here" ;;
            *)   SERVER_WHY_OUT="contains '$_c', which is not a letter, digit, '-', '_' or '.'; --server takes a host, never a URL" ;;
        esac
        return 1
    fi

    case "$_v" in
        *\[*|*\]*)
            # ONE SPELLING PER HOST: build_base_url adds the brackets. Four cases, because
            # brackets arrive from four different mistakes and naming the wrong one is advice for a
            # mistake the operator did not make. The suggested command is offered only when it
            # would be ACCEPTED -- an example that fails is worse than none.
            _inner="${_v#\[}"; _inner="${_inner%%\]*}"
            case "$_v" in *\]:*) _port="${_v##*\]:}" ;; *) _port="" ;; esac
            if is_integer "$_port" && in_range "$_port" 65535 && [ "$(( 10#$_port ))" -gt 0 ]; then
                _port=" --port $(( 10#$_port ))"
            else
                _port=""
            fi
            if server_ipv6_ok "$_inner"; then
                if server_addr_names_no_host "$_inner"; then
                    SERVER_WHY_OUT="is bracketed, and the address inside names no destination even written plainly"
                else
                    SERVER_WHY_OUT="is bracketed: write --server ${_inner}${_port} (the brackets belong to the URL and are added for you)"
                fi
            else
                case "$_inner" in
                    *:*) SERVER_WHY_OUT="is not a valid IPv6 address inside the brackets; write one plainly, as --server ::1" ;;
                    *)   SERVER_WHY_OUT="contains '[' or ']'; that is curl's URL range syntax, so the value does not name one host" ;;
                esac
            fi
            return 1 ;;
        *:*:*)
            server_ipv6_ok "$_v" || { SERVER_WHY_OUT="is not an IPv6 literal"; return 1; }
            server_addr_names_no_host "$_v" && return 1
            SERVER_KIND_OUT="ipv6"; SERVER_URLHOST_OUT="[$_v]"; return 0 ;;
        *:*)
            SERVER_WHY_OUT="contains ':'; the port belongs to --port (an IPv6 literal has at least two colons)"; return 1 ;;
    esac

    if server_addr_shape "$_v"; then
        if server_ipv4_ok "$_v"; then
            server_addr_names_no_host "$_v" && return 1
            SERVER_KIND_OUT="ipv4"; SERVER_URLHOST_OUT="$_v"; return 0
        fi
        # Two populations, two true sentences: one message covering both accused values that
        # reach NOTHING ('1.2.3.4.5', '127.0.0.256') of reaching somewhere else.
        case "$_v" in
            *.) SERVER_WHY_OUT="is not four decimal octets 0-255; a trailing dot is legal in a NAME but not in an address, so this names nothing" ;;
            *)  if [ "$ADDR_LEGACY_OUT" -eq 1 ]; then
                    SERVER_WHY_OUT="is not four decimal octets 0-255; a leading zero is octal, '0x' is a hexadecimal address, and a short form fills the middle octets, so as typed it reaches a different address"
                else
                    SERVER_WHY_OUT="is not four decimal octets 0-255; every part is a number, so it is not read as a name either"
                fi ;;
        esac
        return 1
    fi

    server_dnsname_ok "$_v" || return 1
    SERVER_KIND_OUT="name"; SERVER_URLHOST_OUT="$_v"; return 0
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

# URLENC_HEX -- a lookup table that replaces `od`. Indexing a string is a parameter expansion;
# `od` is an external command this file used without detecting it.
URLENC_HEX="0123456789ABCDEF"
urlencode() {
    local input="$1"
    local out="" i ch n
    # LC_ALL=C, scoped to this function and restored on return, for two reasons at once:
    # percent-encoding is defined on BYTES, and in a UTF-8 locale ${input:i:1} yields a CHARACTER.
    # Under C both the slice and printf's "'X" form are byte-oriented, so a multi-byte character
    # encodes as its individual %XX bytes -- the behaviour the od pipeline was there to provide.
    #
    # NO EXTERNAL COMMAND. This was `$(printf '%s' "$ch" | od -An -tx1 | tr -d ' \n')` plus a second
    # `$(... | tr '[:lower:]' '[:upper:]')` per byte: two forks per encoded character, and NEITHER
    # od nor tr was detected. Measured with od absent: the substitution produced nothing, the inner
    # loop never ran, and the character was silently DROPPED -- the run printed one --source and the
    # server recorded another.
    local LC_ALL=C
    for ((i = 0; i < ${#input}; i++)); do
        ch="${input:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-])
                out="${out}${ch}"
                ;;
            *)
                # "'X" is the POSIX printf form for the numeric value of X's first byte.
                n=$(printf '%d' "'$ch" 2>/dev/null) || n=0
                [ "$n" -lt 0 ] && n=$(( n + 256 ))
                out="${out}%${URLENC_HEX:$(( n / 16 )):1}${URLENC_HEX:$(( n % 16 )):1}"
                ;;
        esac
    done
    printf "%s" "$out"
}

SAFE_FILENAME_OUT=""
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
    SAFE_FILENAME_OUT="$input"
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

# scratch_file -- put the path of the per-run scratch file named $1, truncated, in
# SCRATCH_FILE_OUT. It returns through a global rather than stdout so callers need no command
# substitution: three of these run per uploaded file, and on bash 5.2 a signal arriving while the
# shell expands a "$( )" can lose that signal's trap entirely (a known bug — bug-bash 2023-09,
# fixed in 5.3, never backported). Fewer dolparens in the upload loop is fewer chances to lose an
# operator's interrupt, and it saves a subshell per call. Uploads used to take three fresh temp files per attempt (four with
# wget, one of them a complete multipart copy of the file being sent) and released none of them
# until exit: a 16k-file collection left ~50k files behind in the work directory, and on the
# wget path the directory grew by the size of the entire collection — on the host being
# triaged. Fixed names bound that to a handful of files and the largest single upload, and save
# three mktemp forks per file. The directory is mode 700, so the names carry no risk.
SCRATCH_FILE_OUT=""
# read_head FILE [MAX] -- at most MAX bytes (default 4096) of FILE in READ_HEAD_OUT, raw.
#
# Replaces `$(cat FILE)` at the four places that quote a short diagnostic or a scan id. Three gains:
# no fork, no undetected `cat`, and a BOUND on text the peer controls -- `$(cat)` on a response body
# is as unbounded as the loop this round already removed from the preflight. Raw on purpose: the
# callers that want newlines flattened do it themselves, and the scan-id caller must NOT have them
# flattened, because a control character is exactly what makes it reject the value.
#
# Trailing newlines are stripped, which is the one behaviour of `$(...)` worth keeping.
READ_HEAD_OUT=""
read_head() {
    READ_HEAD_OUT=""
    [ -f "$1" ] || return 1
    IFS= read -r -d '' -n "${2:-4096}" READ_HEAD_OUT 2>/dev/null < "$1" || :
    while :; do
        case "$READ_HEAD_OUT" in
            *$'\n') READ_HEAD_OUT="${READ_HEAD_OUT%$'\n'}" ;;
            *)       break ;;
        esac
    done
    return 0
}

# emit_lines -- print the here-document on stdin, without `cat`.
#
# `cat <<EOF` is how --help and --version were printed, and `cat` was never detected: on a host
# without it the shell's own "command not found" was the entire help text and the collector still
# EXITED 0. The shell already holds the here-document, so reading it needs no external command.
emit_lines() {
    local _l
    while IFS= read -r _l || [ -n "$_l" ]; do
        printf '%s\n' "$_l"
    done
}

scratch_file() {
    SCRATCH_FILE_OUT=""
    ensure_work_dir || return 1
    : > "$TS_WORK_DIR/$1" 2>/dev/null || return 1
    SCRATCH_FILE_OUT="$TS_WORK_DIR/$1"
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
    # timeout(1) is OPTIONAL, not a dependency: wget_bounded falls back to its own reap when it is
    # absent. Resolved with `type -P` rather than `command -v` because only an external binary can
    # be exec'd -- `command -v` would also answer for a shell function or alias named "timeout".
    TIMEOUT_CMD="$(type -P timeout 2>/dev/null || true)"
    [ -n "$TIMEOUT_CMD" ] && [ -x "$TIMEOUT_CMD" ] || TIMEOUT_CMD=""
    if command -v wget >/dev/null 2>&1; then
        UPLOAD_TOOL="wget"
        # Presence is not capability (the grep -o lesson): busybox's wget applet rejects --tries,
        # --max-redirect and --content-on-error with a usage dump. It announces itself on
        # --version (which it also rejects, printing "BusyBox vX.Y.Z"), so that is the probe:
        # once, offline, no URL a test double could count, and keyed on the signature rather than
        # the exit status so a wrapper that exits non-zero for unknown arguments is not misjudged.
        case "$(wget --version 2>&1)" in *[Bb]usy[Bb]ox*) WGET_IS_MINIMAL=1 ;; esac
        return 0
    fi
    return 1
}

# http_status_from_headers -- put the LAST HTTP status code in the header file $1 into
# HTTP_STATUS_OUT, or "" when the file holds no status line at all.
#
# Pure parameter expansion, for three reasons. It was `grep -oE ... | tail -1 | grep -oE`,
# spelled two different ways at three call sites:
#   1. CORRECTNESS. `grep -o` is a GNU extension, absent on Solaris/AIX, and `grep` was never
#      detected. Where -o is unsupported the status came back EMPTY, and an empty status was
#      read as success by both uploaders and the marker -- so a wrong port reported a complete
#      collection with no errors. The status path must not depend on an undetected tool.
#   2. COST. Three forks and a subshell per uploaded file; a 10k-file run spent ~30k processes
#      deciding what it had already been told. This is also why the result comes back in a
#      global rather than through $( ) -- see scratch_file's comment on the bash 5.2 lost-signal
#      bug in the per-file path.
#   3. TRUTHFULNESS. The old expression was unanchored, so it matched a status line anywhere on
#      a line -- a response header whose VALUE contained "HTTP/1.1 500" forged the status of a
#      healthy request. Anchoring to the start (after optional leading space, because `wget -S`
#      indents its copy of the headers and `curl -D` does not) makes a header value inert.
#
# Last match wins, as before: a "100 Continue" followed by a real status resolves to the real
# one, and a bare 100 stays 100 (see http_status_is_terminal's note on why that matters).
HTTP_STATUS_OUT=""
http_status_from_headers() {
    HTTP_STATUS_OUT=""
    local _line _rest _code _tool="${2:-}" _unindented=""
    while IFS= read -r _line || [ -n "$_line" ]; do
        # WHERE a status line may begin is a property of the TRANSPORT, and the two are opposites.
        # Measured, byte for byte:
        #
        #   curl -D : status line at COLUMN 0, CRLF        "HTTP/1.1 200 OK^M"
        #   wget -S : echoed headers INDENTED two spaces   "  HTTP/1.1 200 OK"
        #             wget's own prose at column 0         "Connecting to 127.0.0.1:8080..."
        #
        # THE OBS-FOLD FORGERY IS A CURL DEFECT, and the curl arm is what closes it. Stripping
        # leading blanks and keeping the LAST match is right for wget and catastrophic for curl: an
        # RFC 9112 obs-fold continuation is a header line that BEGINS with SP or HTAB, so a peer
        # answering a real 503 plus a folded " HTTP/1.1 200 OK" was read as 200 -- the refused
        # upload counted as submitted, failed=0, exit 0. Reproduced with controls both ways, and
        # again with a 413 masked the same way. (On the curl path this parser is now only the
        # FALLBACK; curl_w_status reads %{http_code} from curl itself and parses no text at all.)
        #
        # That folded response is NOT forgeable through wget, measured: GNU wget UNFOLDS the
        # continuation into the PRECEDING header's value before echoing it under -S --
        #
        #     "  HTTP/1.1 503 Service Unavailable"
        #     "  X-Note: harmless   HTTP/1.1 200 OK"   <- the fold, absorbed into X-Note's value
        #
        # -- so the HTTP/[0-9]* anchor below already rejects it.
        #
        # The wget rule therefore PREFERS an indented line but does not REQUIRE one. Preferring it
        # rejects column-0 status text in wget's stderr, which is reachable: `debug = on` in an rc
        # makes wget dump the raw response, putting "HTTP/1.1 200 OK" at column 0 (measured) --
        # a channel --no-config closes on a wget that accepts it, but not on an older one. Requiring
        # it would be the wrong trade: the two-space -S prefix is UNDOCUMENTED, and a build that
        # echoed headers unindented would then yield no status at all, which
        # classify_upload_response turns into sentinel 98 for EVERY file -- a whole collection lost
        # to a formatting change. The fallback keeps that impossible.
        #
        # KNOWN AND STILL OPEN on the wget path, recorded here because it is the same class and
        # neither this arm nor the fallback closes it: a peer answering a real 503 plus a second,
        # UNFOLDED header line "HTTP/1.1 200 OK: forged" gets that line echoed INDENTED like any
        # other header, so the last-match rule reads 200. Measured end to end -- wget submitted=2
        # exit 0 for uploads the peer refused with 503, where curl on the same peer reports 503 and
        # exits 4. It is PRE-EXISTING (the same measurement against the pre-round file gives
        # submitted=1 exit 0) and closing it needs a wget-side equivalent of curl's %{http_code},
        # which wget does not provide: the answer is to stop trusting the echoed transcript, not to
        # tighten this pattern.
        #
        # With no $2 the old lenient behaviour is kept DELIBERATELY: the one caller that omits it is
        # inside collection_marker, which this round does not touch by decision.
        case "$_tool" in
            curl) case "$_line" in [![:space:]]*) ;; *) continue ;; esac ;;
        esac
        _rest="${_line#"${_line%%[![:space:]]*}"}"
        case "$_rest" in HTTP/[0-9]*) ;; *) continue ;; esac
        _rest="${_rest#HTTP/}"          # "1.1 200 OK"
        _rest="${_rest#*[!0-9.]}"       # "200 OK"  (drop the version and its separator)
        _code="${_rest%%[![:digit:]]*}" # "200"
        case "$_code" in [0-9][0-9][0-9]) ;; *) continue ;; esac
        if [ "$_tool" = "wget" ]; then
            case "$_line" in
                [[:space:]]*) HTTP_STATUS_OUT="$_code" ;;   # an echoed header: authoritative
                *)            _unindented="$_code" ;;       # column-0 text: only if nothing better
            esac
        else
            HTTP_STATUS_OUT="$_code"
        fi
    done < "$1"
    # Only reached when wget echoed no indented status line at all.
    [ -n "$HTTP_STATUS_OUT" ] || HTTP_STATUS_OUT="$_unindented"
}

# curl_w_status -- the HTTP status curl itself reported, from its '-w' output file $1, in
# CURL_HTTP_STATUS_OUT (empty when there is nothing usable).
#
# This is the PRIMARY status on the curl path; parsing the header dump is only the fallback. curl
# computes the final response code itself, so a forged obs-fold header line cannot reach it:
# measured against a peer answering 503 plus a folded "HTTP/1.1 200 OK", '-w %{http_code}' reported
# 503 -- the truth -- while the -D file carried the forged 200 on its third line.
#
# VALIDATED rather than trusted: a curl too old for a given -w
# variable does not substitute it, and '000' is what curl reports when no response arrived at all.
# Neither is a status, and both fall back to the parser.
#
# What the suite's old_curl_path double actually models is the EMPTY case, not the echo case: its
# stub runs `printf '%{remote_ip}\n'`, and `%{` is not a valid printf directive in dash or bash, so
# it writes nothing at all. That exercises the empty -w file and the parser fallback; it does not
# exercise a literal '%{http_code}' surviving into line 2. The three-digit test covers both, but
# only the first is under test.
CURL_HTTP_STATUS_OUT=""
curl_w_status() {
    CURL_HTTP_STATUS_OUT=""
    local _code
    [ -f "$1" ] || return 0
    # The ONLY line of the -w output. '%{remote_ip}' used to precede it; when that was dropped the
    # index had to move with it, or every request would have read the status from a line that no
    # longer exists and classify_upload_response would have failed every file closed (sentinel 98).
    IFS= read -r _code < "$1" 2>/dev/null || :
    case "$_code" in
        000) ;;
        [0-9][0-9][0-9]) CURL_HTTP_STATUS_OUT="$_code" ;;
    esac
    return 0
}

# _json_skip_value -- given JSON text starting at a VALUE in $1, put the text that FOLLOWS that
# value into JSON_SKIP_REST_OUT. Returns 1 if the value is malformed or runs off the end of the
# buffer, which callers must treat as "cannot tell", never as "absent".
#
# Bounded and fork-free: it jumps between STRUCTURAL bytes with ${x%%[...]*} rather than walking
# every byte, so the cost is O(number of structural bytes), not O(length). Strings recurse exactly
# one level; nested objects and arrays use a depth counter, so nesting costs no stack.
# A '}' inside a bracket expression CANNOT be written literally inside ${x%%...}: bash's parser ends
# the expansion at that '}', so ${r%%[,}]*} silently becomes the pattern '[,' followed by the literal
# text ']*}'. Measured: '27844}tail' came back as '27844}tail\]]*}' instead of '27844', which made the
# scalar and structural scans below no-ops and the whole acknowledgement gate wrong. Holding the
# pattern in a variable side-steps the parser; verified identical at BASH_COMPAT 3.2, 4.2 and native.
# (A 'case' pattern has no such problem -- only parameter expansion does.)
JSON_END_SCALAR='[,}]'
JSON_STRUCTURAL='[][{}"]'
JSON_SKIP_REST_OUT=""
_json_skip_value() {
    local _r="$1" _d=0 _run
    local LC_ALL=C
    case "$_r" in
        \"*)
            _r="${_r#\"}"
            while :; do
                case "$_r" in *[\\\"]*) ;; *) JSON_SKIP_REST_OUT=""; return 1 ;; esac
                _run="${_r%%[\\\"]*}"
                _r="${_r#"$_run"}"
                case "$_r" in
                    \\?*) _r="${_r#??}" ;;            # an escape pair: skip both bytes
                    \")    JSON_SKIP_REST_OUT=""; return 1 ;;
                    \"*)   _r="${_r#\"}"; break ;;
                    *)     JSON_SKIP_REST_OUT=""; return 1 ;;
                esac
            done
            JSON_SKIP_REST_OUT="$_r"; return 0 ;;
        \{*|\[*)
            while :; do
                # Unquoted on purpose: quoting the expansion would make it a LITERAL string instead
                # of a pattern, which is the whole mechanism here.
                # shellcheck disable=SC2295
                _run="${_r%%$JSON_STRUCTURAL*}"
                # _run == _r means no structural byte is left, i.e. the value runs off the end of the
                # buffer. Comparing lengths is also one scan cheaper than a second `case` guard.
                [ "${#_run}" -ne "${#_r}" ] || { JSON_SKIP_REST_OUT=""; return 1; }
                _r="${_r#"$_run"}"
                case "$_r" in
                    \"*) _json_skip_value "$_r" || return 1
                         _r="$JSON_SKIP_REST_OUT"; continue ;;
                    \{*|\[*) _d=$(( _d + 1 )); _r="${_r#?}" ;;
                    *)       _d=$(( _d - 1 )); _r="${_r#?}"
                             if [ "$_d" -le 0 ]; then JSON_SKIP_REST_OUT="$_r"; return 0; fi ;;
                esac
            done ;;
        '') JSON_SKIP_REST_OUT=""; return 1 ;;
        *)  # number, true, false, null -- ends at the next structural byte
            # shellcheck disable=SC2295
            _run="${_r%%$JSON_END_SCALAR*}"
            [ "${#_run}" -ne "${#_r}" ] || { JSON_SKIP_REST_OUT=""; return 1; }
            _r="${_r#"$_run"}"
            JSON_SKIP_REST_OUT="$_r"; return 0 ;;
    esac
}

# json_top_level_out KEY BUFFER -- put the raw text of the value of TOP-LEVEL key $1 into
# JSON_TL_OUT and set JSON_TL_FOUND=1; set JSON_TL_FOUND=0 when the object is well formed and has
# no such key; return 1 when the buffer is not a parseable object (so the answer is UNKNOWN).
#
# "Top-level" is the whole point. The test this replaces was a substring search, so anything
# carrying the key at any depth, in any content type, satisfied it -- measured: a 200 text/html
# page containing <script>var x={"id":5}</script>, a body {"data":{"id":91}}, a {"trace":{"id":...}}
# error envelope and an {"errors":[{"id":1}]} array all passed, and every one of them booked a file
# the peer never took as submitted, exit 0.
JSON_TL_OUT=""
JSON_TL_FOUND=0
json_top_level_out() {
    local _want="$1" _r="$2" _key
    local LC_ALL=C
    JSON_TL_OUT=""; JSON_TL_FOUND=0
    _r="${_r#"${_r%%[![:space:]]*}"}"
    case "$_r" in \{*) _r="${_r#\{}" ;; *) return 1 ;; esac
    while :; do
        _r="${_r#"${_r%%[![:space:],]*}"}"           # whitespace and the separating comma
        case "$_r" in
            '')  return 1 ;;                          # ran off the end: unknown, not absent
            \}*) return 0 ;;                          # well-formed object, key absent
            \"*) ;;
            *)   return 1 ;;                          # a key was required here
        esac
        _r="${_r#\"}"
        case "$_r" in *\"*) ;; *) return 1 ;; esac
        _key="${_r%%\"*}"
        _r="${_r#"$_key"}"; _r="${_r#\"}"
        _r="${_r#"${_r%%[![:space:]]*}"}"
        case "$_r" in :*) _r="${_r#:}" ;; *) return 1 ;; esac
        _r="${_r#"${_r%%[![:space:]]*}"}"
        if [ "$_key" = "$_want" ]; then
            _json_skip_value "$_r" || return 1
            # the value is everything up to what follows it
            if [ -n "$JSON_SKIP_REST_OUT" ]; then
                JSON_TL_OUT="${_r%"$JSON_SKIP_REST_OUT"}"
            else
                JSON_TL_OUT="$_r"
            fi
            JSON_TL_FOUND=1
            return 0
        fi
        _json_skip_value "$_r" || return 1
        _r="$JSON_SKIP_REST_OUT"
    done
}

# thunderstorm_ack_in -- Thunderstorm's upload acknowledgement in the body in file $1: a TOP-LEVEL
# "id" key with a non-empty value. A foreign service answering 200 to everything returns '{}', HTML
# or nothing, so a 2xx alone must not count as a submitted file -- GRR and Fleetspeak both refuse to
# trust a bare status, because captive proxies answer 200 without connectivity, and Thunderstorm
# already returns the id on /api/checkAsync at no extra cost.
#
# THREE outcomes, not two, and the third is why this is not a boolean:
#   0  an acknowledgement is present               -> the file is submitted
#   1  the body is well formed and carries none    -> this peer is not a Thunderstorm (sentinel 95)
#   2  the body could not be parsed to the end     -> UNKNOWN (retryable, sentinel 92)
# Collapsing 2 into 1 was measured to cost a whole collection: the first miss latches
# PEER_UNACKNOWLEDGED, so one body this function could not finish reading withheld every remaining
# file and listed the file the peer HAD accepted as undelivered.
#
# The id's TYPE is deliberately not constrained, because the API family uses both spellings and a
# collector that accepted only one would refuse a legitimate peer: production answers '{"id":27844}'
# (a number) while the reference stub answers '{"id":"<uuid>"}' (a string). Requiring digits passed
# against production and rejected every upload against the stub -- caught by running the suite, not
# by reading the code.
#
# 64 KiB, the same bound server_preflight uses for the same kind of recognition, and for the reason
# its comment already gives: a 4 KiB bound "would make the collector call a healthy Thunderstorm
# 'not a Thunderstorm'". Measured at 4 KiB -- a valid '{"id":27844}' at offset 4711 of a 4722-byte
# body was rejected, and the run reported submitted=0 failed=4 exit 4 against a peer that had
# accepted a file.
thunderstorm_ack_in() {
    local _ack=""
    IFS= read -r -d '' -n 65536 _ack 2>/dev/null < "$1" || [ -n "$_ack" ] || return 1
    if json_top_level_out id "$_ack"; then
        [ "$JSON_TL_FOUND" -eq 1 ] || return 1
        case "$JSON_TL_OUT" in
            '""') return 1 ;;   # {"id":""}    -- present but empty is not an acknowledgement
            '')   return 1 ;;
            [0-9]*|-[0-9]*) return 0 ;;
            \"*) return 0 ;;
            *)   return 1 ;;    # true/false/null/an array/an object: not an id
        esac
    fi
    # The parse did not complete. "UNKNOWN" must mean the bytes ran out, NOT "unparseable": a body
    # that is definitively not a JSON object -- HTML, a WAF interstitial, plain text -- IS a
    # definitive non-acknowledgement and must fail CLOSED, or the poison-peer gate would retry
    # against an HTML-serving peer instead of refusing it. Only a read that filled the buffer can
    # have hidden an acknowledgement from us.
    [ "${#_ack}" -ge 65536 ] && return 2
    return 1
}

# retry_after_seconds -- put the LAST Retry-After value in header file $1 into RETRY_AFTER_OUT as a
# number of seconds, or "" when there is none we can honour. RFC 9110 also allows an HTTP-date;
# that is "unknown" here, never a number: the old `sed 's/[^0-9]//g'` turned
# "Fri, 04 Sep 2026 10:00:00 GMT" into 042026100000 and the log then attributed the capped value
# to the server. Pure expansion, case-insensitive (Bash 3.2 has no ${var,,}), wget's indent tolerated.
RETRY_AFTER_OUT=""
retry_after_seconds() {
    RETRY_AFTER_OUT=""
    local _line _v
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line#"${_line%%[![:space:]]*}"}"
        case "$_line" in
            [Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:*) ;;
            *) continue ;;
        esac
        _v="${_line#*:}"
        _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"
        case "$_v" in
            ''|*[!0-9]*) RETRY_AFTER_OUT="" ;;
            *) # Strip leading zeros BEFORE the length guard. The guard exists to avoid 64-bit games
               # on a SERVER-chosen number, but it measured the DIGIT COUNT, so a padded
               # 'Retry-After: 0000002' -- two seconds -- became 999999 and the collector printed a
               # number the server never sent, then waited the 120s cap. Measured: 0000002 -> 2,
               # 0000000 -> 0, 00000000000005 -> 5, and a genuine 1234567 still clamps to 999999.
               _v="${_v#"${_v%%[!0]*}"}"; [ -z "$_v" ] && _v=0
               [ "${#_v}" -gt 6 ] && _v=999999
               RETRY_AFTER_OUT=$((10#$_v)) ;;
        esac
    done < "$1"
}


# redact_userinfo -- $1 with any user:pass@ replaced by <redacted>@, scheme or no scheme (curl
# accepts and USES a proxy spelled user:pass@host:port with no scheme). Result in REDACTED_OUT.
# redact_detail  -- $1 with the effective proxy's credential (PROXY_CRED_OUT, set by
# proxy_env_note) blanked in both the user:pass and wget's user/pass spelling. The transports echo
# the raw proxy URL in some of their own diagnostics, which this file now keeps and logs.
REDACTED_OUT=""
PROXY_CRED_OUT=""
redact_userinfo() {
    local _h
    case "$1" in
        *@*)
            _h="${1##*@}"
            case "$1" in
                *://*) REDACTED_OUT="${1%%://*}://<redacted>@${_h}" ;;
                *)     REDACTED_OUT="<redacted>@${_h}" ;;
            esac ;;
        *) REDACTED_OUT="$1" ;;
    esac
}
redact_detail() {
    REDACTED_OUT="$1"
    [ -n "$PROXY_CRED_OUT" ] || return 0
    REDACTED_OUT="${REDACTED_OUT//"$PROXY_CRED_OUT"/<redacted>}"
    # wget spells the same credential user/pass. Built from the two halves rather than with
    # ${PROXY_CRED_OUT/:/\/}: before bash 4.3 the REPLACEMENT of a pattern substitution is not
    # quote-removed, so that expression yielded the literal 'user\/pass', matched nothing, and the
    # password reached the log IN CLEAR on the 3.2 floor this file targets. Measured old vs new:
    #   BASH_COMPAT 3.2, 4.2 -> old "using proxy puser/s3cr3tPW@h"   new "<redacted>"
    #   BASH_COMPAT 5.0, none -> both redact, which is why this went unnoticed for so long.
    # Same pre-4.3 class as the JSON escaper defect (C4), in a different function.
    case "$PROXY_CRED_OUT" in
        *:*) REDACTED_OUT="${REDACTED_OUT//"${PROXY_CRED_OUT%%:*}/${PROXY_CRED_OUT#*:}"/<redacted>}" ;;
    esac
}

# last_diagnostic_line -- the last line of a `wget -S` stderr capture ($1) that is NOT an echoed
# header (wget indents those); i.e. wget's own last word on what went wrong. In DIAG_LINE_OUT.
DIAG_LINE_OUT=""
last_diagnostic_line() {
    DIAG_LINE_OUT=""
    local _line _tab
    _tab="$(printf '\t')"
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|' '*|"$_tab"*) continue ;; esac
        DIAG_LINE_OUT="$_line"
    done < "$1"
}

# sentinel_name -- the closed-set value $1 as words, for the operator-facing attempt line. The
# numbers are an implementation detail documented only in this file; "code 92" told nobody anything.
SENTINEL_NAME_OUT=""
# destination_unusable -- what a failed destination check MEANS for this run. $1 is the sentence,
# already phrased for the operator. Fatal for a real run (there is nowhere to send the evidence);
# reported and survivable for a dry run, which cannot show what would be sent if it aborts.
destination_unusable() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_msg warn "$1 — a real run would stop here; this dry run continues and reports what it would have collected"
        return 0
    fi
    die_runtime 1 "$1"
}

# server_ip_literal_hint -- the extra clause a destination named by ADDRESS needs when it answers as
# something other than a Thunderstorm. In SERVER_IP_HINT_OUT, and EMPTY when --server named a host
# name, so the common sentence is unchanged.
#
# A request that carries no host name is answered by whichever site a name-based virtual host serves
# by default. Measured on a live deployment: 200 by name, 404 by that host's own address. The two
# causes the message already offers -- the port, or a reverse proxy that does not pass /api through --
# do not cover it, and it is the likeliest cause for an operator who typed an address.
#
# Reads SERVER_KIND_OUT, set once by classify_server in validate_config.
SERVER_IP_HINT_OUT=""
server_ip_literal_hint() {
    SERVER_IP_HINT_OUT=""
    case "$SERVER_KIND_OUT" in
        ipv4|ipv6)
            SERVER_IP_HINT_OUT=" -- and --server named an address, so the request carried no host name: if this host serves several names, name it (--server <name>)" ;;
    esac
}

# submitted_key -- the published name for FILES_SUBMITTED, in SUBMIT_KEY_OUT. The COUNT is the same
# quantity in both modes -- a dry run must show what a real run would send -- so the KEY carries the
# difference. A parallel counter would break report_run's two reconciliation identities and still
# need this key. 'submitted=' does not occur inside 'would_submit=', so scrapers stay unambiguous.
SUBMIT_KEY_OUT="submitted"
submitted_key() {
    if [ "$DRY_RUN" -eq 1 ]; then
        SUBMIT_KEY_OUT="would_submit"
    else
        SUBMIT_KEY_OUT="submitted"
    fi
}

sentinel_name() {
    case "$1" in
        90) SENTINEL_NAME_OUT="transport failure" ;;
        91) SENTINEL_NAME_OUT="local failure" ;;
        92) SENTINEL_NAME_OUT="non-2xx status" ;;
        93) SENTINEL_NAME_OUT="503 back-pressure" ;;
        95) SENTINEL_NAME_OUT="2xx without a Thunderstorm answer" ;;
        96) SENTINEL_NAME_OUT="withheld: the destination stopped answering" ;;
        98) SENTINEL_NAME_OUT="no readable HTTP status" ;;
        *)  SENTINEL_NAME_OUT="code $1" ;;
    esac
}

# submit_file's return space is a CLOSED SET, and every value in it is defined here. It is
# closed because it used to leak: the two uploaders ended with `return $code`, handing the
# transport's OWN exit status back into the same numbers. Modern curl reaches into that range --
# 92 CURLE_HTTP2_STREAM, 93, 94 CURLE_AUTH_ERROR, 96 CURLE_QUIC_CONNECT_ERROR, 97 CURLE_PROXY --
# so a curl that failed its proxy handshake (97) was read as "the server gave a terminal verdict"
# and the file was dropped after one attempt; curl 94 was read as "the file vanished", inflating
# vanished= and steering the run to exit 5; curl 93 was read as 503 back-pressure. The transport's
# exit code is now CLASSIFIED and LOGGED instead of returned.
#
#   0   submitted
#   90  transport failed before a verdict (see transport_error_reason for the cause)
#   91  local failure (scratch file, body build)
#   92  retryable: a non-2xx from the server, or a 2xx whose body exceeded the 64 KiB this
#       collector reads, so whether it acknowledged the file is not known (see
#       thunderstorm_ack_in -- unknown is not evidence about the peer)
#   93  503 back-pressure
#   94  file vanished or changed type
#   95  2xx that is not a Thunderstorm answer: no {"id":N} from /api/checkAsync
#   96  withheld without transmitting: the destination stopped answering (the breaker tripped)
#   97  terminal server verdict; re-sending cannot change it
#   98  transport exited 0 but produced no readable HTTP status
#
# transport_error_reason -- put a human cause for tool exit code $2 ("curl" or "wget" in $1)
# into TRANSPORT_ERR_OUT. Every tool benchmarked for this collector (Velociraptor, GRR,
# osquery, UAC) leaves this to the runtime's error string; curl's exit codes are better raw
# material than any of them has, so they are named here rather than printed as a bare number.
TRANSPORT_ERR_OUT=""
transport_error_reason() {
    TRANSPORT_ERR_OUT=""
    if [ "$1" = "curl" ]; then
        case "$2" in
            3)  TRANSPORT_ERR_OUT="the URL was malformed — check --server (it takes a host name or IP only, with no scheme, path, port or credentials)" ;;
            1|8) TRANSPORT_ERR_OUT="the peer did not answer with HTTP — wrong port, or a service that does not speak HTTP (a TLS-only port without --ssl looks like this too)" ;;
            5)  TRANSPORT_ERR_OUT="could not resolve the proxy" ;;
            6)  TRANSPORT_ERR_OUT="could not resolve the host name" ;;
            7)  TRANSPORT_ERR_OUT="connection refused or unreachable — check the port" ;;
            16|92) TRANSPORT_ERR_OUT="HTTP/2 framing error" ;;
            18) TRANSPORT_ERR_OUT="transfer ended early" ;;
            23) TRANSPORT_ERR_OUT="could not write the response locally" ;;
            26) TRANSPORT_ERR_OUT="could not read the file being uploaded" ;;
            28) TRANSPORT_ERR_OUT="timed out (connecting, or the transfer exceeded the client's window)" ;;
            35) TRANSPORT_ERR_OUT="TLS handshake failed" ;;
            51|60) TRANSPORT_ERR_OUT="server certificate not trusted or name mismatch (use --ca-cert, or --insecure to accept it)" ;;
            52) TRANSPORT_ERR_OUT="empty reply — the peer may not speak HTTP on this port, or it is TLS-only and --ssl is missing" ;;
            55|56) TRANSPORT_ERR_OUT="network send/receive error" ;;
            77) TRANSPORT_ERR_OUT="CA certificate file could not be read" ;;
            97) TRANSPORT_ERR_OUT="proxy handshake failed (see the Proxy: line)" ;;
            *)  TRANSPORT_ERR_OUT="see curl(1) exit code $2" ;;
        esac
        return 0
    fi
    case "$2" in
        1) TRANSPORT_ERR_OUT="generic failure (see wget's own message)" ;;
        2) TRANSPORT_ERR_OUT="wget rejected an option or its configuration file (an old or busybox wget?)" ;;
        3) TRANSPORT_ERR_OUT="local file I/O error" ;;
        4) TRANSPORT_ERR_OUT="network failure — check the host and port" ;;
        5) TRANSPORT_ERR_OUT="TLS verification failed (use --ca-cert, or --insecure to accept it)" ;;
        6) TRANSPORT_ERR_OUT="authentication failure" ;;
        7) TRANSPORT_ERR_OUT="the peer did not answer with HTTP — wrong port, or a service that does not speak HTTP" ;;
        8) TRANSPORT_ERR_OUT="server returned an error status" ;;
        124) TRANSPORT_ERR_OUT="the transfer was stopped at its total time bound (wget has no --max-time of its own; the peer may be trickling bytes to keep the connection alive)" ;;
        *) TRANSPORT_ERR_OUT="see wget(1) exit code $2" ;;
    esac
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
        407)         return 1 ;;   # a PROXY status (RFC 9110 15.5.8): the server said nothing
        408|429)     return 1 ;;
        4[0-9][0-9]) return 0 ;;
        *)           return 1 ;;
    esac
}

# classify_upload_response -- turn one transport attempt into a value from the closed set above.
# $1 tool (curl|wget), $2 its exit status, $3 endpoint, $4 file, $5 header file, $6 body file.
# One function for both transports: the two copies it replaces had already drifted in three places
# (Retry-After anchoring, body flattening, 92 vs 96) and every later fix would have been made twice.
# Sets RETRY_AFTER_SLEPT so the 503 arm's caller knows whether to back off itself.
RETRY_AFTER_SLEPT=0
# The transport's own last words about a failed attempt, already redacted. Set by upload_with_curl;
# wget's equivalent is read from its output file by last_diagnostic_line.
TRANSPORT_DETAIL_OUT=""
classify_upload_response() {
    local _tool="$1" _code="$2" _endpoint="$3" _filepath="$4" _hdr="$5" _resp="$6" _ackrc=0
    local _http _body _wait
    RETRY_AFTER_SLEPT=0
    # curl's own %{http_code} first; the header dump only when it is unusable (a pre-7.29 curl).
    if [ "$_tool" = "curl" ] && [ -n "$CURL_HTTP_STATUS_OUT" ]; then
        _http="$CURL_HTTP_STATUS_OUT"
    else
        http_status_from_headers "$_hdr" "$_tool"; _http="$HTTP_STATUS_OUT"
    fi

    # 503 back-pressure. The server's value is honoured and REPORTED truthfully: when the cap
    # applies the line says both numbers; when there is no usable value the line says so and the
    # caller applies its own backoff instead of re-sending the whole body at once.
    if [ "$_http" = "503" ]; then
        retry_after_seconds "$_hdr"
        if [ -n "$RETRY_AFTER_OUT" ]; then
            _wait="$RETRY_AFTER_OUT"
            [ "$_wait" -gt 120 ] && _wait=120
            if [ "$_wait" != "$RETRY_AFTER_OUT" ]; then
                log_msg warn "Server returned 503; Retry-After asked for ${RETRY_AFTER_OUT}s, waiting ${_wait}s (cap 120)"
            else
                log_msg warn "Server returned 503, waiting ${_wait}s (Retry-After)"
            fi
            sleep "$_wait"
            RETRY_AFTER_SLEPT=1
        else
            log_msg warn "Server returned 503 without a usable Retry-After; backing off before retrying"
        fi
        return 93
    fi

    # 407 comes from a proxy, never from the server (RFC 9110 15.5.8): a transport-class failure,
    # retried like one and blamed on the right party.
    if [ "$_http" = "407" ]; then
        log_msg error "Upload of '$_filepath' failed: a proxy refused the request (HTTP 407 Proxy Authentication Required)"
        return 90
    fi

    if [ "$_code" -ne 0 ]; then
        # wget exits 8 for EVERY HTTP error response: that is a verdict with a status line, and it
        # is classified with the statuses below. Any other non-zero exit with a status line means
        # the transfer died AFTER a status arrived -- a proxy closing the request mid-body after a
        # 502, or a proxy's own "200 Connection established" before the tunnel failed. Reported as
        # what it is: a status line received, not the server's verdict on the file.
        if [ -n "$_http" ] && { [ "$_tool" != "wget" ] || [ "$_code" -ne 8 ]; }; then
            log_msg error "Upload of '$_filepath' failed: an HTTP $_http status line was received before the transfer completed ($_tool exit $_code; a proxy's CONNECT reply counts as one)"
            http_status_is_terminal "$_http" && return 97
            case "${_tool}:${_code}" in
                curl:18|curl:28) log_msg warn "'$_filepath' was cut off mid-transfer; if this repeats for large files the server or a proxy in front of it is enforcing a shorter per-request window than this client — lower --max-size so files stay inside it" ;;
            esac
            transport_error_reason "$_tool" "$_code"
            log_msg error "Upload of '$_filepath' to $_endpoint failed: $TRANSPORT_ERR_OUT ($_tool exit $_code)"
            return 90
        fi
        if [ -z "$_http" ]; then
            transport_error_reason "$_tool" "$_code"
            DIAG_LINE_OUT=""
            if [ "$_tool" = "wget" ]; then
                last_diagnostic_line "$_hdr"
                redact_detail "$DIAG_LINE_OUT"
            else
                # Already captured and redacted by upload_with_curl.
                REDACTED_OUT="$TRANSPORT_DETAIL_OUT"
            fi
            log_msg error "Upload of '$_filepath' to $_endpoint failed: $TRANSPORT_ERR_OUT ($_tool exit $_code)${REDACTED_OUT:+: $REDACTED_OUT}"
            return 90
        fi
    fi

    if [ -z "$_http" ]; then
        # The transport exited 0 but said nothing we could read as a status. That is not permission
        # to call the file submitted: a truncated header, an HTTP/0.9 peer or a header file we could
        # not write all look like this, and reading silence as success is exactly how a wrong port
        # came to report a complete collection. Fail closed.
        log_msg error "No readable HTTP status for '$_filepath' (target $_endpoint); not counted as submitted"
        return 98
    fi

    case "$_http" in
        2[0-9][0-9])
            # A 2xx alone is not a submitted file: the peer must answer as a Thunderstorm does on the
            # ONE endpoint this collector uses -- {"id":N} from /api/checkAsync. A foreign service
            # answering 200 to everything returns no such thing (GRR and Fleetspeak refuse to trust a
            # bare status for the same reason: captive proxies answer 200 without connectivity).
            #
            # UNCONDITIONAL, and that is the whole point of having one endpoint. This was a `case` on
            # the endpoint STRING with two arms and NO default, so an endpoint matching neither fell
            # through to `return 0` -- a 2xx booked as submitted with no identity check at all. It was
            # unreachable while endpoint_name was always "check" or "checkAsync", but removing --sync
            # by deleting just the flag and the sync arm would have ARMED it: the endpoint would still
            # have been /api/check, matching neither surviving pattern, and a peer answering 200 '{}'
            # to every upload would have been reported as submitted with exit 0. Measured before this
            # change: `classify_upload_response curl 0 http://x/api/collection f <200> <{}>` returned
            # 0, while the two matching endpoints correctly returned 95. With one endpoint there is
            # one rule and no dispatch left to get wrong.
            thunderstorm_ack_in "$_resp"; _ackrc=$?
            case "$_ackrc" in
                0) return 0 ;;
                2) # The body filled the 64 KiB read, so an acknowledgement may be past it. That is
                   # NOT evidence about the peer, and treating it as such cost a whole collection:
                   # the first miss latches PEER_UNACKNOWLEDGED, which withholds every remaining
                   # file. Retry the file instead of judging the destination.
                   log_msg warn "HTTP $_http from $_endpoint for '$_filepath': the response did not fit the 64 KiB this collector reads, so whether it carried an acknowledgement is not known; retrying rather than judging the peer"
                   return 92 ;;
            esac
            log_msg error "HTTP $_http from $_endpoint carried no Thunderstorm acknowledgement for '$_filepath'; the peer did not answer as a Thunderstorm would"
            return 95 ;;
    esac
    # Bounded, and fork-free. This was `$(tr '\r\n' '  ' < "$_resp")`, which loads a body the
    # SERVER chooses -- in full -- into a shell variable and then logs all of it: one hostile or
    # merely verbose error page per failed file. It also made `tr` an undetected dependency whose
    # absence silently emptied the message. 4 KB is more than any diagnosis needs.
    IFS= read -r -d '' -n 4096 _body 2>/dev/null < "$_resp" || :
    _body="${_body//$'\r'/ }"
    _body="${_body//$'\n'/ }"
    [ "${#_body}" -gt 500 ] && _body="${_body:0:500}..."
    # Same redaction as every other place a PEER-chosen string reaches a sink. This site had none,
    # so a proxy error page that quoted the request URL logged the credential once per failed file.
    # ${VAR:+...} rather than a bare ': $_body': where the transport could not keep the error body
    # the sentence must not end in a colon, which reads as "the server sent nothing".
    redact_detail "$_body"
    log_msg error "Server returned HTTP $_http for '$_filepath' (target $_endpoint)${REDACTED_OUT:+: $REDACTED_OUT}"
    http_status_is_terminal "$_http" && return 97
    return 92
}

upload_with_curl() {
    local endpoint="$1"
    local filepath="$2"
    local filename="$3"
    local safe_filename
    local resp_file
    local header_file
    local code

    sanitize_filename_for_multipart "$filename"; safe_filename="$SAFE_FILENAME_OUT"

    scratch_file curl.resp || return 91; resp_file="$SCRATCH_FILE_OUT"
    scratch_file curl.hdr || return 91; header_file="$SCRATCH_FILE_OUT"

    # The file is streamed from stdin ('@-'), never named to curl as '@path': curl splits an
    # -F value on ';' and honours sub-parameters, so a collected file whose own name contains
    # ';filename=' or ';type=' would rewrite the multipart metadata. The shell opens the path
    # (no parsing), curl reads fd 0, and only the sanitized filename reaches the form.
    local form_arg="file=@-;filename=${safe_filename}"

    local err_file
    scratch_file curl.err || return 91; err_file="$SCRATCH_FILE_OUT"
    local ip_file
    scratch_file curl.ip || return 91; ip_file="$SCRATCH_FILE_OUT"

    # A total timeout alone leaves a black-holed SYN eating the whole budget per file
    # (CLAUDE.md §2 asks for connect AND total). --max-time bounds the transfer; note it is a
    # CLIENT bound only — a reverse proxy in front of Thunderstorm may enforce a much shorter
    # per-request window, in which case it, not this value, decides the largest file that can
    # actually be delivered. See the note in submit_file.
    # -q FIRST: it disables ~/.curlrc, $CURL_HOME and $XDG_CONFIG_HOME/curlrc, which can otherwise
    # set proxy=, location (redirect following, C1 all over again) or insecure behind the
    # collector's back while the log describes a run that did not happen. Same rule as the ignored
    # THUNDERSTORM_PORT: a file on the host must not decide where evidence goes.
    #
    # -g turns OFF curl's URL globbing, and it is load-bearing for the same reason. curl expands
    # {a,b} lists and [1-2] ranges in a URL by default, and --server is interpolated into that URL,
    # so ONE invocation performed one transfer PER expansion. Measured with --server '127.0.0.[1-2]':
    # the preflight, the begin marker and the end marker each went to BOTH 127.0.0.1 and 127.0.0.2,
    # and the sample's bytes were delivered to a host the operator never named. The upload then
    # stalled, because the file is streamed from stdin ('-F file=@-') and the second transfer found
    # stdin at EOF -- so the run finally reported the file as FAILED, telling the operator nothing
    # was sent when it had already left the machine. wget has no glob layer, so without this the two
    # transports contacted different sets of hosts for the same command line.
    curl -q -g -sS --show-error -X POST "${CURL_EXTRA_OPTS[@]}" \
        --connect-timeout 10 \
        --max-time 300 \
        -D "$header_file" \
        -o "$resp_file" \
        -w '%{http_code}\n' \
        "$endpoint" \
        -F "$form_arg" \
        < "$filepath" > "$ip_file" 2>"$err_file"
    code=$?
    # The body moved from a shell redirect to '-o' so stdout is free for '-w %{remote_ip}'. On the
    # same stream the address would have been prepended to the response body that the
    # acknowledgement check parses; '-o' and '>' are equivalent for the body itself.
    TRANSPORT_DETAIL_OUT=""
    if [ $code -ne 0 ]; then
        local _curl_err
        read_head "$err_file" 2048; _curl_err="$READ_HEAD_OUT"
        _curl_err="${_curl_err//$'\r'/ }"
        _curl_err="${_curl_err//$'\n'/ }"
        redact_detail "$_curl_err"
        [ -n "$REDACTED_OUT" ] && log_msg debug "curl error: $REDACTED_OUT"
        # Promoted, not just logged at debug. wget's diagnostic already reached the error line and
        # curl's did not, so the SAME failure read differently per transport: a DNS timeout came out
        # as "the transfer window elapsed" under curl, with curl's own "Resolving timed out after
        # 10001 ms" visible only under --debug. The operator who needs it most is the one who ran
        # without --debug.
        TRANSPORT_DETAIL_OUT="$REDACTED_OUT"
    fi
    # The status curl itself reported, read before classification so the header parser is only a
    # fallback. Set per attempt, so a value from an earlier file cannot leak into this one.
    curl_w_status "$ip_file"
    classify_upload_response curl "$code" "$endpoint" "$filepath" "$header_file" "$resp_file"
}

# wget_bounded LIMIT -- run `wget "$@"` under LC_ALL=C with a TOTAL wall-clock bound of LIMIT
# seconds, and return wget's own exit code (124 if the bound stopped it, the code timeout(1) uses).
#
# Why this exists. curl bounds every request with --max-time; wget has no equivalent. Its
# --read-timeout is a PER-READ timer that every arriving byte resets, so a peer that trickles one
# byte every 200 ms holds wget forever. MEASURED 2026-09-08: bare wget with --read-timeout=15
# against such a peer was still running when a 40 s kill arrived, having written 197 bytes; curl
# with --max-time 15 gave up on its own (exit 28). Three wget calls were affected -- the upload, the
# collection marker and the preflight -- and each one's curl arm already declares the bound it
# intends, so the limit passed here is curl's own number rather than a new policy.
#
# The consequence was not only a slow run. on_signal disarms HUP/INT/QUIT/TERM and then sends the
# interrupted marker, justifying the disarm as "bounded". On the wget path it was not bounded, so
# the collector became unkillable except by SIGKILL -- which skips cleanup_tmp_files and leaves the
# private work directory, holding a copy of a collected file, on the host being triaged.
#
# Two mechanisms because `timeout` cannot be assumed (coreutils; absent from a stock macOS, where
# it is gtimeout, and from some minimal images). LC_ALL=C is preserved in both: this file parses
# wget's own sentences to find the peer address, and a translated locale silently disables that.
wget_bounded() {
    local _limit="$1"; shift
    local _pid _waited=0 _rc=0
    if [ -n "$TIMEOUT_CMD" ]; then
        LC_ALL=C "$TIMEOUT_CMD" "$_limit" wget "$@"
        return $?
    fi
    # `exec` inside the subshell, not a plain subshell: exec REPLACES the subshell with wget, so $!
    # is wget's own pid and the kill below reaches the transport. Backgrounding a subshell instead
    # would make $! the wrapper's pid -- the test harness lost three signal assertions to exactly
    # that mistake, passing while nothing was ever signalled.
    ( export LC_ALL=C; exec wget "$@" ) &
    _pid=$!
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_waited" -ge "$_limit" ]; then
            kill -TERM "$_pid" 2>/dev/null
            sleep 1
            kill -KILL "$_pid" 2>/dev/null
            wait "$_pid" 2>/dev/null || :
            return 124
        fi
        sleep 1
        _waited=$(( _waited + 1 ))
    done
    wait "$_pid" || _rc=$?
    return "$_rc"
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

    sanitize_filename_for_multipart "$filename"; safe_filename="$SAFE_FILENAME_OUT"

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
    scratch_file wget.body || return 91; body_file="$SCRATCH_FILE_OUT"
    scratch_file wget.resp || return 91; resp_file="$SCRATCH_FILE_OUT"
    scratch_file wget.hdr || return 91; header_file="$SCRATCH_FILE_OUT"

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
    # wget has no total-transfer bound (curl's --max-time); --timeout=N would have set DNS, connect
    # AND idle-read to N each, so a peer that stopped accepting cost 300 s per attempt where curl
    # gave up after 10. The three are set separately (wget >= 1.10). The residual -- a peer that
    # trickles a byte every <300 s holds one upload open -- is documented in README.
    # --content-on-error keeps the body of a non-2xx answer so the status line can quote it, as
    # the curl path does.
    # 300 = the --max-time the curl arm of this same upload declares. Without the wrapper this
    # request had no total bound at all, so one trickling peer could hold the run indefinitely on
    # a single file.
    wget_bounded 300 -S -O "$resp_file" "${WGET_EXTRA_OPTS[@]}" \
        --tries=1 \
        --dns-timeout=10 --connect-timeout=10 --read-timeout=300 \
        --content-on-error \
        --header="Content-Type: multipart/form-data; boundary=${boundary}" \
        --post-file="$body_file" \
        "$endpoint" 2>"$header_file"
    code=$?
    # wget writes "Connecting to <host>|<addr>|:<port>... connected." into this same file, so the
    # address costs nothing on this transport either. Guarded on the return code for the same
    # reason as the curl site: an address printed while opening a connection that then failed is
    # not an upload that "reached" anywhere, and report_run says "reached".
    classify_upload_response wget "$code" "$endpoint" "$filepath" "$header_file" "$resp_file"
}

# json_escape_out -- JSON-escape $1 into JSON_ESCAPED_OUT.
#
# ONE gated pass, and it has to be a pass rather than a chain of ${//} substitutions: bash before
# 4.3 does not double a backslash that way. Measured under BASH_COMPAT for the input 'a\b':
#
#     s="${s//\\/\\\\}"            5.2: a\\b     3.2 and 4.2: a\b      <- silently NOT escaped
#     bs='\'; s="${s//"$bs"/...}"  5.2: a\\b     3.2 and 4.2: a"\"b    <- actively mangled
#     s="${s//$bs/$bs$bs}"         wrong on every version
#
# So on the 3.2 floor -- macOS /bin/bash -- the chain this replaces emitted invalid JSON for any
# source name, server name, scan id or collected path containing a backslash, and a mixed
# backslash-quote value ('both\"x') terminated the JSON string early. The destination record is the
# artefact a re-run depends on, so that is a silent loss of the one thing the operator needs.
#
# The pass is CHUNKED: each iteration copies the whole RUN of bytes needing no escape. That makes it
# far better than a per-byte walk, but it is NOT O(escapes) -- each iteration re-scans the remainder
# to find the next offender, so the cost is O(length x escapes). An earlier version of this comment
# claimed O(escapes) and quoted a 10 ms / 391 ms pair; both were wrong and are corrected here.
#
# Measured per call, against the ${//} chain this replaces (which is C-speed but silently WRONG
# below bash 4.3 -- see the table above):
#
#     input                                     chain    this
#     88-byte path, nothing to escape            24 us   21 us   <- the fast path, no loop at all
#     90-byte path, one backslash                20 us   49 us
#     31-byte path, six backslashes              16 us   67 us
#     150-byte value, 50 escapes                 36 us  1021 us
#     600-byte value, 200 escapes               107 us  6487 us
#     255 backslashes (a filename-length worst case)     2935 us
#
# So the trade is: identical on the path essentially every call takes, and progressively worse the
# denser the escaping gets. It is still the right way round, for three reasons. Correctness first --
# the chain emits invalid JSON below 4.3 and no amount of speed rescues an unparseable record.
# Frequency second: of 17032 real paths under /usr and /etc, ZERO contain a backslash or a quote.
# And the cost is BOUNDED: the input is one path or one server-supplied identifier, not a stream, and
# the filename-length worst case above is ~3 ms.
#
# Two alternatives were measured and rejected. Dropping the per-iteration `case` guard and comparing
# ${#_safe} to ${#_rest} instead (one scan rather than two) is SLOWER -- 155 ms against 135 ms at six
# escapes, 2014 against 1946 at two hundred -- because `case` short-circuits on the first match while
# two ${#} expansions do not. And selecting the chain at runtime on a bash that doubles backslashes
# correctly would need a second control-byte-dropping path of its own (the chain handles the seven
# named escapes but not the other C0 bytes, which is why the pre-4.3 code had a walk after it), i.e.
# it doubles the correctness surface of the fix for a CRITICAL defect to speed up a case that does
# not occur in the field. If a hostile tree ever makes this matter, that is the change to make.
#
# LC_ALL=C so the class tests and the slice are BYTES: JSON
# requires every byte below 0x20 to be escaped or removed, and a UTF-8 continuation byte must not be
# mistaken for one. Measured: 'unicode' with combining accents round-trips unchanged.
#
# One consequence worth naming, since it is a behaviour change: under a UTF-8 caller locale
# [[:cntrl:]] also matched the C1 block, so U+0080-U+009F used to be DROPPED; as a byte test it does
# not, and those two-byte sequences now reach the marker verbatim. That is correct for JSON, which
# requires escaping only below 0x20 -- and it is the right trade anyway, because the
# locale-dependent version silently deleted valid text from a filename. Terminal safety is log_msg's
# job.
#
# The out-parameter form avoids a fork per escaped string.
JSON_ESCAPED_OUT=""
json_escape_out() {
    local s="$1" _out _safe _c _rest
    local LC_ALL=C
    # Fast path: no backslash, no quote, no control byte -- nothing to escape.
    case "$s" in
        *[\\\"]*|*[[:cntrl:]]*) ;;
        *) JSON_ESCAPED_OUT="$s"; return 0 ;;
    esac
    _out=""; _rest="$s"
    while :; do
        case "$_rest" in
            *[\\\"]*|*[[:cntrl:]]*) ;;
            *) _out="$_out$_rest"; break ;;
        esac
        _safe="${_rest%%[\\\"[:cntrl:]]*}"      # the run that needs no escaping
        _out="$_out$_safe"
        _rest="${_rest#"$_safe"}"
        _c="${_rest:0:1}"; _rest="${_rest:1}"   # the one byte that does
        case "$_c" in
            \\)     _out="$_out\\\\" ;;
            '"')     _out="$_out\\\"" ;;
            $'\n')   _out="$_out\\n" ;;
            $'\r')   _out="$_out\\r" ;;
            $'\t')   _out="$_out\\t" ;;
            $'\010') _out="$_out\\b" ;;         # backspace
            $'\014') _out="$_out\\f" ;;         # form feed
            *)       ;;                         # any other C0/DEL byte is dropped, as before
        esac
    done
    JSON_ESCAPED_OUT="$_out"
}

# json_escape -- the same escaping on stdout, for the callers that read it through $( ).
json_escape() {
    json_escape_out "$1"
    printf '%s' "$JSON_ESCAPED_OUT"
}

# Why the last collection_marker POST failed, for the caller's fatal message.
MARKER_ERR_OUT=""
# collection_marker -- POST a begin/end marker to /api/collection
# Args: $1=base_url  $2=type(begin|end)  $3=scan_id(optional)  $4=stats_json(optional)
# Outputs: scan_id extracted from response on stdout (empty if unsupported or failed)
# Returns: 0 on success, non-zero on failure
collection_marker() {
    # A marker is data ABOUT the run -- the host's source name and its statistics -- so a dry run
    # withholds it whoever asks. The three call sites gate this too, for their own wording; this
    # backstop is what makes the guarantee independent of them, so reaching it is a caller bug.
    # warn, never info/debug: those go to STDOUT, and this function's stdout is the scan_id channel.
    if [ "$DRY_RUN" -eq 1 ]; then
        log_msg warn "Collection marker '${2:-}' was not sent: this is a dry run"
        return 0
    fi
    local base_url="$1"
    local marker_type="$2"
    local scan_id="${3:-}"
    local stats_json="${4:-}"
    local marker_url="${base_url}/api/collection"
    local body scan_id_out resp_file header_file err_file
    local _marker_tool="" _marker_detail=""

    resp_file="$(mktemp_portable)" || return 1
    header_file="$(mktemp_portable)" || return 1
    err_file="$(mktemp_portable)" || return 1

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
    # The interrupted marker can fire from a trap before prepare_run detected the transport.
    [ -n "$UPLOAD_TOOL" ] || detect_upload_tool || true

    local _http_code
    local _attempt=0
    while [ "$_attempt" -lt "$_marker_attempts" ]; do
        _attempt=$((_attempt + 1))
        _marker_rc=1
        : > "$header_file"
        # Attempt POST — capture HTTP status to detect server-side errors
        if [ "$UPLOAD_TOOL" = "curl" ]; then
            # curl's stderr used to go to /dev/null here, even though -sS was passed precisely to
            # make it explain itself. That is why a refused port, a filtered port, a rejected
            # certificate and a DNS failure all produced one identical sentence: the collector
            # threw away the only thing that told them apart. Keep it and name the cause.
            curl -q -g -sS -D "$header_file" -o "$resp_file" "${CURL_EXTRA_OPTS[@]}" \
                --connect-timeout 10 \
                -H "Content-Type: application/json" \
                -d "$body" \
                --max-time 10 \
                "$marker_url" 2>"$err_file"
            _marker_rc=$?
            _marker_tool="curl"
        elif [ "$UPLOAD_TOOL" = "wget" ]; then
            # 10 = the --max-time the curl arm declares. This is the call on_signal makes with
            # every signal disarmed, so an unbounded version of it is what made the collector
            # unkillable except by SIGKILL.
            wget_bounded 10 -S -O "$resp_file" "${WGET_EXTRA_OPTS[@]}" \
                --tries=1 \
                --header "Content-Type: application/json" \
                --post-data "$body" \
                --dns-timeout=10 --connect-timeout=10 --read-timeout=10 \
                "$marker_url" 2>"$header_file"
            _marker_rc=$?
            _marker_tool="wget"
            # wget writes both its headers and its diagnostics to the same stream, so the header
            # file is also the error file on this path.
            err_file="$header_file"
        fi
        # Whatever the transport said about WHY, keep it for the caller's fatal message.
        MARKER_ERR_OUT=""
        if [ "$_marker_rc" -ne 0 ] && [ -n "$_marker_tool" ]; then
            transport_error_reason "$_marker_tool" "$_marker_rc"
            MARKER_ERR_OUT="$TRANSPORT_ERR_OUT"
            if [ "$_marker_tool" = "wget" ]; then
                # wget's own last word, not its whole -S header dump
                last_diagnostic_line "$err_file"; _marker_detail="$DIAG_LINE_OUT"
            else
                read_head "$err_file" 2048; _marker_detail="$READ_HEAD_OUT"
            fi
            _marker_detail="${_marker_detail//$'\r'/ }"
            _marker_detail="${_marker_detail//$'\n'/ }"
            redact_detail "$_marker_detail"
            [ -n "$REDACTED_OUT" ] && MARKER_ERR_OUT="$MARKER_ERR_OUT: $REDACTED_OUT"
        fi
        # Validate the HTTP status code even when wget exits non-zero on 4xx/5xx.
        # 404/501 means the server doesn't implement marker endpoint; continue without scan_id.
        http_status_from_headers "$header_file"; _http_code="$HTTP_STATUS_OUT"
        if [ -n "$_http_code" ]; then
            case "$_http_code" in
                2[0-9][0-9])
                    # Only when the transport itself succeeded: a proxy's "200 Connection
                    # established" survives in curl's header file after a failed tunnel.
                    if [ "$_marker_rc" -ne 0 ]; then
                        log_msg warn "Collection marker '$marker_type': an HTTP $_http_code status line was received but the transport failed${MARKER_ERR_OUT:+ ($MARKER_ERR_OUT)}"
                    fi
                    ;;
                404|501)
                    log_msg warn "Collection marker '$marker_type' not supported (HTTP $_http_code) — server does not implement /api/collection"
                    _marker_rc=0
                    ;;
                *)
                    log_msg warn "Collection marker '$marker_type' received HTTP $_http_code"
                    [ -n "$MARKER_ERR_OUT" ] || MARKER_ERR_OUT="HTTP $_http_code from /api/collection"
                    _marker_rc=1
                    ;;
            esac
        elif [ "$_marker_rc" -eq 0 ]; then
            # The tool exited 0 and produced no readable status line. Previously that counted as
            # a delivered marker, which made the begin marker -- the run's only reachability
            # gate -- pass on any peer whose reply we could not parse. Treat it as a failure so
            # the gate cannot be satisfied by silence.
            log_msg warn "Collection marker '$marker_type' produced no readable HTTP status"
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
        # A control character anywhere (0x00-0x1f, 0x7f) rejects the value. This was "strip them
        # with tr and compare", which is the same test through a fork and an undetected `tr`;
        # [[:cntrl:]] is that byte set, DEL included.
        case "$scan_id_out" in
            *[[:cntrl:]]*) scan_id_out="" ;;
        esac
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

    # Nothing more goes to a peer that failed to acknowledge as a Thunderstorm.
    [ "$PEER_UNACKNOWLEDGED" -eq 0 ] || return 95
    # Nor to a destination that has stopped answering: reading and transmitting a file that cannot
    # arrive costs the operator time and tells them nothing. Counted, never sent.
    [ "$DEST_DOWN" -eq 0 ] || return 96

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
    while [ "$try" -le "$RETRIES" ]; do
        # Inside the loop, not before it: a file that vanished between attempts used to be
        # re-attempted with backoff and booked as an upload failure (exit 4). It is churn (94).
        if [ ! -f "$filepath" ]; then
            log_msg warn "'$filepath' is no longer a regular file; not uploaded"
            return 94
        fi
        # THE TRANSMISSION BOUNDARY, and it must stay BELOW the checks above: a dry run makes every
        # decision a real run makes and skips only the transport call -- at the top of the function
        # it reported "would submit" for files that had vanished. return 0 keeps report_run's
        # reconciliation identity true without a second counter; the key is what differs.
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

        # 97 = the server gave a verdict about THIS request that re-sending cannot change
        # (413 Payload Too Large above all). Retrying would re-upload the whole body for a
        # guaranteed second refusal, so the attempt budget is not spent on it.
        if [ "$rc" -eq 97 ]; then
            log_msg error "Server rejected '$filepath' with a non-retryable status; not retrying"
            return "$rc"
        fi
        # 95: a 2xx that was not a Thunderstorm answer. From a peer that has NEVER acknowledged an
        # upload, re-sending cannot change the answer and every further file would be disclosed to
        # a party of unknown identity: stop the flow, and remember which file's bytes did reach it.
        # From a peer that has already proved itself, one odd answer (a proxy's HTML error page, a
        # backend out of rotation) is an anomaly like any other failed attempt: retried, and if it
        # persists, booked below as an upload failure -- not as an impostor.
        if [ "$rc" -eq 95 ] && [ "$FILES_SUBMITTED" -eq 0 ] && [ "$LINKS_COLLECTED" -eq 0 ]; then
            PEER_UNACKNOWLEDGED=1
            PEER_UNACKNOWLEDGED_AT="$endpoint"
            PEER_UNACKNOWLEDGED_FILE="$filepath"
            return "$rc"
        fi

        # 503 back-pressure: retried without counting against the normal retry budget (up to a cap).
        # The upload function slept for Retry-After when the server sent a usable one; otherwise the
        # ordinary backoff applies here, so an overloaded peer is never re-sent the body at once.
        if [ "$rc" -eq 93 ]; then
            _503_count=$((_503_count + 1))
            if [ "$_503_count" -lt "$max_503_retries" ]; then
                if [ "$RETRY_AFTER_SLEPT" -eq 0 ]; then
                    sleep "$backoff"
                    backoff=$((backoff * 2))
                    [ "$backoff" -gt 60 ] && backoff=60
                fi
                log_msg warn "Retrying '$filepath' after 503 back-pressure ($_503_count/$max_503_retries)"
                continue
            fi
            log_msg warn "Too many 503 responses for '$filepath', giving up"
            return "$rc"
        fi

        sentinel_name "$rc"
        log_msg warn "Upload failed for '$filepath' (attempt ${try}/${RETRIES}: ${SENTINEL_NAME_OUT})"
        # Network backoff is for the network. A local failure (91: scratch file, body build) is not
        # helped by waiting on the peer; it is retried at once and then given up.
        if [ "$try" -lt "$RETRIES" ] && [ "$rc" -ne 91 ]; then
            sleep "$backoff"
            backoff=$((backoff * 2))
            # Cap backoff at 60 seconds
            [ "$backoff" -gt 60 ] && backoff=60
        fi
        try=$((try + 1))
    done

    # A 2xx-without-answer from a peer that had already proved itself is, once the attempts are
    # spent, an ordinary upload failure -- not an unacknowledged peer.
    [ "$rc" -eq 95 ] && rc=92
    return "$rc"
}

# add_scan_dir -- append one directory to the scan set. The first operator-supplied directory
# replaces the built-in defaults and marks the set as operator-supplied (which drives the
# explicit-vs-default failure handling in classify_root). Shared by --dir, bare positional args,
# and operands following '--', so the "replace defaults once" rule lives in exactly one place.
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
    local _pre

    # --dry-run is settled BEFORE the options are walked, because the signal traps are installed at
    # file scope (below main) and therefore fire during parsing. send_interrupted_marker is gated on
    # "$DRY_RUN" -eq 0, so a signal arriving after --server had been read but before --dry-run was
    # reached used to contact the server -- the one thing --dry-run exists to prevent. The window is
    # microseconds wide and the marker carries no evidence, but it is an action the operator
    # explicitly forbade, so it is closed rather than documented.
    #
    # The scan stops at '--': operands after it are scan directories, so a directory legitimately
    # named "--dry-run" must not turn the run into a dry run.
    for _pre in "$@"; do
        case "$_pre" in
            --) break ;;
            --dry-run) DRY_RUN=1; break ;;
        esac
    done

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
                    --ssl|--insecure|--follow-symlinks|--dry-run|--debug|--no-log-file|--syslog|--quiet|--progress|--no-progress|--no-count-filtered|--help)
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
                # ONE collection, ONE destination. Neither value is quoted back: a refusal is the
                # one place a rejected value reaches terminal, log file and syslog at once, and
                # 'user:pass@host' would leak there.
                [ -z "$THUNDERSTORM_SERVER" ] || die "--server given twice; it names one destination"
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
    # Keep the spelling the operator typed: the canonicalisation below overwrites the variable
    # in place, so "Port must be greater than 0" could not quote its value the way every other
    # port message does ('--port 00000' reported a rule without saying what broke it).
    local _port_raw="$THUNDERSTORM_PORT"
    THUNDERSTORM_PORT=$(( 10#$THUNDERSTORM_PORT ))
    MAX_AGE=$(( 10#$MAX_AGE ))
    MAX_FILE_SIZE_KB=$(( 10#$MAX_FILE_SIZE_KB ))
    RETRIES=$(( 10#$RETRIES ))

    [ "$THUNDERSTORM_PORT" -gt 0 ] || die "Port must be greater than 0: '$_port_raw'"
    # No ">= 1" check for max-size: 0 turns the size filter OFF, exactly as --max-age 0 turns
    # the age filter off, so the two policy gates are spelled the same way on the command line.
    # (The Go collector's engine already reads 0 as unlimited -- collector.go's
    # "c.MaxFileSize > 0 && c.MaxFileSize < info.Size()" -- though its CLI still refuses it.)
    [ "$RETRIES" -ge 1 ] || die "retries must be >= 1"

    # --server is REQUIRED unless nothing will be sent, mirroring go/main.go:134
    # ("thunderstorm-server: not specified (required unless using --dry-run)"). It used to default
    # to a Nextron-internal host name that RESOLVES, so a forgotten flag was not a usage error: the
    # collector dialled vendor infrastructure from a customer host on its own initiative, and the
    # literal disclosed that infrastructure in a file shipped to licensees. Thunderstorm is licensed
    # per customer -- the destination is theirs, so they have to name it. Exit 2 (usage), not Go's 1,
    # because this file's exit taxonomy owns that meaning; and this runs before the log-file sink is
    # armed, so a usage error still leaves nothing behind in the operator's cwd.
    # The classify_server call below is the ONE validation gate, and it runs before the log-file
    # sink is armed and before any file is read, so an unusable destination is a usage error with
    # no on-disk side effect.
    if [ -z "$THUNDERSTORM_SERVER" ]; then
        # The "was IGNORED" announcement lives in prepare_run, which this fatal never reaches -- so
        # the operator who exported THUNDERSTORM_SERVER and forgot the flag was told there was no
        # server and never told that theirs had been seen and discarded. That announcement exists
        # precisely for this person; say it here too.
        if [ "$DRY_RUN" -ne 1 ] && [ -n "${THUNDERSTORM_SERVER_ENV:-}" ]; then
            # Redacted like the --server refusal below, and for the same reason: the operator chose
            # this value too. The example is generic on purpose -- echoing the exported value back
            # would prescribe a command line this collector refuses whenever that value is not one
            # of the three accepted shapes.
            redact_userinfo "$THUNDERSTORM_SERVER_ENV"
            die "No Thunderstorm server given: THUNDERSTORM_SERVER='$REDACTED_OUT' is set in the environment and was IGNORED (a variable must not decide where evidence goes), so pass -s/--server <host> on the command line, e.g. --server thunderstorm.local --port 8080"
        fi
        [ "$DRY_RUN" -eq 1 ] || die "No Thunderstorm server given: pass -s/--server <host> (required unless --dry-run), e.g. --server thunderstorm.local --port 8080"
    elif ! classify_server "$THUNDERSTORM_SERVER"; then
        # Redacted: for the '@' shape the part before the '@' is a password, and every site that
        # echoes an operator-chosen destination reaches the terminal, the log file and syslog.
        redact_userinfo "$THUNDERSTORM_SERVER"
        die "--server '$REDACTED_OUT' $SERVER_WHY_OUT. Give a host name, an IPv4, or an IPv6 written plainly (::1)"
    fi
    if [ -n "$CA_CERT" ] && [ ! -f "$CA_CERT" ]; then
        die "CA certificate file not found: '$CA_CERT'"
    fi
    # NOTE: the --ca-cert/--insecure warning lives in prepare_run, after the log sink is armed.
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
        # "Not a regular file" and "not allowed to look" are the same answer from '[ -f ]'.
        # Calling the second one dangling booked a permission failure as a skip, at debug level,
        # and let the run exit 0 — CLAUDE.md §3 says an inaccessible target is a failure and must
        # be surfaced. Only a target we could actually examine is dangling.
        if entry_stat_denied "$_resolved"; then
            LINKS_FAILED=$((LINKS_FAILED + 1))
            FILES_FAILED=$((FILES_FAILED + 1))
            FILES_UNREADABLE=$((FILES_UNREADABLE + 1))
            [ -n "$FIRST_UNREADABLE" ] || FIRST_UNREADABLE="$_resolved"
            log_msg error "Symlink '$link' -> '$_resolved' could not be examined (its directory is not searchable); counted as unreadable, not skipped"
            return 0
        fi
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
    elif [ "$_rc" -eq 95 ]; then
        LINKS_FAILED=$((LINKS_FAILED + 1))
        FILES_FAILED=$((FILES_FAILED + 1))
        FILES_UPLOAD_FAILED=$((FILES_UPLOAD_FAILED + 1))
        FILES_UNACKNOWLEDGED=$((FILES_UNACKNOWLEDGED + 1))
    elif [ "$_rc" -eq 94 ]; then
        # The target stopped being a regular file before the open: churn, counted as vanished.
        LINKS_FAILED=$((LINKS_FAILED + 1))
        FILES_FAILED=$((FILES_FAILED + 1))
        FILES_VANISHED=$((FILES_VANISHED + 1))
    else
        LINKS_FAILED=$((LINKS_FAILED + 1))
        FILES_FAILED=$((FILES_FAILED + 1))
        FILES_UPLOAD_FAILED=$((FILES_UPLOAD_FAILED + 1))
        if [ "$_rc" -eq 96 ]; then
            DEST_DOWN_WITHHELD=$((DEST_DOWN_WITHHELD + 1))
        else
            log_msg error "Could not upload symlink target '$link' -> '$_target'"
        fi
    fi
    dest_health_note "$_rc"
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

# first_record -- the first NUL-terminated record of file $1, in FIRST_RECORD_OUT. One builtin
# read, so a path containing a newline survives intact. Lets every loss name a real path instead
# of quoting find's diagnostic, whose format is locale-dependent and unparseable.
FIRST_RECORD_OUT=""
first_record() {
    FIRST_RECORD_OUT=""
    IFS= read -r -d '' FIRST_RECORD_OUT < "$1" 2>/dev/null
    [ -n "$FIRST_RECORD_OUT" ]
}

# dir_searchable -- can this process stat something INSIDE directory $1? That needs search
# permission only; read permission is what lets you LIST a directory, which is a different
# question and the one attribute_walk_errors asks (it tests -r and -x separately, to tell
# "contents unknown" from "names known, attributes not"). Requiring both here was wrong: a
# mode-0111 directory is searchable but not listable — legitimate, and anything a user can chmod
# their own directory to — so a file that genuinely vanished under one was reported as a
# permission failure.
#
# '[ -x ]' is access(2) through the shell, so it answers for THIS caller, honouring ACLs and the
# root bypass, where '-perm' only reads mode bits and would call /root at 0700 executable for a
# stranger. It also works where find's -readable/-executable do not: -readable is GNU-only,
# busybox has just -executable, and neither exists on BSD/macOS — the platforms
# verify_portable.sh targets. Verified for uid 0 on a mode-000 directory: bash answers true and
# root can indeed cd into it, so no privileged special case is needed.
dir_searchable() {
    [ -x "$1" ]
}

# entry_stat_denied -- true when a stat on $1 just failed BECAUSE its directory cannot be
# searched, rather than because $1 is gone. In Bash the two are otherwise indistinguishable:
# '[ -e ]' needs the very stat that failed, so ENOENT and EACCES both answer "no". Without this
# an entry that is still perfectly there, merely locked away, was booked as VANISHED — which the
# exit taxonomy defines as ordinary host churn and "nothing the collector or the operator did
# wrong" (exit 5) — for what is a permission failure that lost evidence (exit 4).
# Called only on the failure paths; the hot loop never pays for it.
entry_stat_denied() {
    local _d
    case "$1" in
        */*) _d="${1%/*}"; [ -n "$_d" ] || _d="/" ;;   # "/x" -> "/", not ""
        *)   _d="." ;;
    esac
    # Three outcomes, and the third is why this recurses.
    #
    #  - The parent is searchable: we can look inside it, so the entry really is gone -> churn.
    #  - The parent is visibly a directory but not searchable: the entry is there and we are
    #    locked out -> denied.
    #  - Neither: the parent's own absence might itself be churn (rm -rf of a subtree, a parent
    #    replaced by a file, a symlinked parent whose target went away) OR permission denial one
    #    level further up. '[ -r ]'/'[ -x ]'/'[ -d ]' cannot tell EACCES from ENOENT, so asking
    #    about the parent is the same question again — recurse until an ancestor answers it.
    #    Bounded by the path depth, and only ever reached on a failure path.
    dir_searchable "$_d" && return 1
    [ -d "$_d" ] && return 0
    case "$_d" in
        /|.) return 0 ;;    # nothing above it can be consulted; treat as denied
    esac
    entry_stat_denied "$_d"
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
            # discovery is not the object find checked: never uploaded unchecked and never fed
            # to the link policy under a false identity. Every l entry bumps LINKS_SEEN, so
            # LINKS_SEEN == TOTAL_LINKS holds by construction (checked at reconciliation).
            _kind="${file_path:0:1}"
            file_path="${file_path#?}"
            case "$_kind" in
                l)
                    if [ ! -h "$file_path" ]; then
                        LINKS_SEEN=$((LINKS_SEEN + 1))
                        LINKS_FAILED=$((LINKS_FAILED + 1))
                        FILES_FAILED=$((FILES_FAILED + 1))
                        if entry_stat_denied "$file_path"; then
                            FILES_UNREADABLE=$((FILES_UNREADABLE + 1))
                            [ -n "$FIRST_UNREADABLE" ] || FIRST_UNREADABLE="$file_path"
                            log_msg error "Symbolic link '$file_path' could not be examined (its directory is not searchable); counted as unreadable, not vanished"
                        elif [ -e "$file_path" ]; then
                            FILES_VANISHED=$((FILES_VANISHED + 1))
                            log_msg warn "Symbolic link '$file_path' was replaced by a non-link after discovery; not collected, counted as failed"
                        else
                            FILES_VANISHED=$((FILES_VANISHED + 1))
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
                # The gates-off case has NO other signal: with --max-size 0 --max-age 0 the walk
                # needs no stat, so find succeeds, prints nothing to stderr, and the entries under
                # an unsearchable directory are discovered normally — then every one of them fails
                # '[ -f ]' here. Booking them as vanished made the run exit 5 and say the loss was
                # ordinary churn that nobody could have prevented. It is a permission failure and
                # it lost evidence: unreadable, exit 4 (CLAUDE.md §3).
                if entry_stat_denied "$file_path"; then
                    FILES_UNREADABLE=$((FILES_UNREADABLE + 1))
                    [ -n "$FIRST_UNREADABLE" ] || FIRST_UNREADABLE="$file_path"
                    log_msg error "'$file_path' could not be examined (its directory is not searchable); counted as unreadable, not vanished"
                else
                    FILES_VANISHED=$((FILES_VANISHED + 1))
                    log_msg debug "Vanished before collection: '$file_path'"
                fi
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
            elif [ "$_sub_rc" -eq 95 ]; then
                # Withheld from an unacknowledged peer: one run-level line names them all.
                FILES_FAILED=$((FILES_FAILED + 1))
                FILES_UPLOAD_FAILED=$((FILES_UPLOAD_FAILED + 1))
                FILES_UNACKNOWLEDGED=$((FILES_UNACKNOWLEDGED + 1))
            elif [ "$_sub_rc" -eq 96 ]; then
                # Withheld because the destination stopped answering: counted, never transmitted,
                # and named ONCE at the end rather than once per file.
                FILES_FAILED=$((FILES_FAILED + 1))
                FILES_UPLOAD_FAILED=$((FILES_UPLOAD_FAILED + 1))
                DEST_DOWN_WITHHELD=$((DEST_DOWN_WITHHELD + 1))
            else
                FILES_FAILED=$((FILES_FAILED + 1))
                FILES_UPLOAD_FAILED=$((FILES_UPLOAD_FAILED + 1))
                log_msg error "Could not upload '$file_path'"
            fi
            dest_health_note "$_sub_rc"
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
    local _excluded_by _withheld
    run_elapsed
    elapsed="$RUN_ELAPSED_OUT"

    # Clear progress line if we were showing progress
    if [ "$SHOW_PROGRESS" -eq 1 ]; then
        printf '\r\033[K' >&2
    fi

    # Every line that echoes a PATH is emitted BEFORE the summary, deliberately. A path is
    # attacker-controlled content: a directory named '... unreadable_dirs=0' would otherwise
    # appear after the summary line, and a scraper taking the LAST match of
    # '(^|[[:space:]])key=[0-9]+' would read the planted number instead of the real one — a
    # silent lie about how much of the host was actually covered. Printing them first means the
    # authoritative summary is always the last word, whatever a path happens to contain.
    if [ "$UNREADABLE_DIRS" -gt 0 ]; then
        log_msg error "$UNREADABLE_DIRS directory(ies) could not be read in full (first: '$FIRST_UNREADABLE_DIR'): $UNLISTABLE_DIRS could not be listed, so what they held is unknown; $UNSEARCHABLE_DIRS could be listed but not searched"
    fi
    if [ "$UNSTATABLE_ENTRIES" -gt 0 ]; then
        log_msg error "$UNSTATABLE_ENTRIES entry(ies) known to exist could not be examined (first: '$FIRST_UNSTATABLE') and were not collected; nothing about them could be read, not even their type"
    fi
    if [ "$FILES_UNREADABLE" -gt 0 ]; then
        log_msg error "$FILES_UNREADABLE file(s) could not be read (first: '$FIRST_UNREADABLE'); counted as failed"
    fi
    if [ "$DEST_DOWN" -eq 1 ]; then
        log_msg error "The destination at $DEST_DOWN_AT stopped answering during the run: $DEST_DOWN_WITHHELD file(s) were counted as failed WITHOUT being transmitted, because sending a file that cannot arrive costs time and proves nothing. Re-run when the server is back"
    fi
    if [ "$PEER_UNACKNOWLEDGED" -eq 1 ]; then
        _withheld=$((FILES_UNACKNOWLEDGED - 1)); [ "$_withheld" -lt 0 ] && _withheld=0
        log_msg error "The peer at $PEER_UNACKNOWLEDGED_AT answered HTTP 2xx without a Thunderstorm answer and never acknowledged an upload: '$PEER_UNACKNOWLEDGED_FILE' was transmitted to it and not acknowledged; $_withheld further file(s) were withheld without transmitting; all counted as failed — check --server and --port"
    fi


    # A collection that SUCCEEDED must leave a record of WHERE the evidence went. Under the
    # documented cron form (--quiet --no-log-file) every sink is off, and the entire output of a
    # successful run was 407 bytes of ASCII banner -- measured -- with the server, the endpoint and
    # the peer named nowhere on the host. force_sink already guarantees this for a fatal; a
    # delivered collection deserves it at least as much, and this is the one line that cannot be
    # reconstructed afterwards from anything else the run leaves behind.
    #
    # One line, on stderr, only when nothing else would say it: on an ordinary run the info lines
    # above already carry all of it and repeating them would be noise.
    # A dry run gets this line too, now that it has a checked destination worth naming -- it was
    # suppressed outright, so the documented `--quiet --no-log-file` form said nothing at all about
    # a dry run. The key still tells the truth about what was delivered.
    # Guarded on the value this line PRINTS, as the three other "was a destination named?" sites are.
    if [ -n "$THUNDERSTORM_SERVER" ] \
        && [ "$LOG_TO_CMDLINE" -eq 0 ] && [ "$LOG_TO_FILE" -eq 0 ] && [ "$LOG_TO_SYSLOG" -eq 0 ]; then
        submitted_key
        printf '%s destination server=%s port=%s %s=%s failed=%s\n' \
            "$(timestamp)" "$THUNDERSTORM_SERVER" "$THUNDERSTORM_PORT" \
            "$SUBMIT_KEY_OUT" "$FILES_SUBMITTED" "$FILES_FAILED" >&2
    fi

    # One line, two words chosen first: the headline so a dry run's log can never be mistaken for a
    # real collection's (it was byte-identical), and the key so the count does not claim a delivery
    # that did not happen (CLAUDE.md 3). The 20-key line itself is not duplicated.
    submitted_key
    local _headline="Run completed"
    [ "$DRY_RUN" -eq 1 ] && _headline="Dry-run completed"
    log_msg info "${_headline}: discovered=$TOTAL_FILES scanned=$FILES_SCANNED ${SUBMIT_KEY_OUT}=$FILES_SUBMITTED skipped=$FILES_SKIPPED age_filtered=$FILES_AGE_FILTERED size_filtered=$FILES_SIZE_FILTERED age_ctime_only=$FILES_AGE_CTIME_ONLY future=$FILES_FUTURE failed=$FILES_FAILED links_seen=$LINKS_SEEN links_collected=$LINKS_COLLECTED links_skipped=$LINKS_SKIPPED unreadable_dirs=$UNREADABLE_DIRS unstatable=$UNSTATABLE_ENTRIES unusable_dirs=$UNUSABLE_DIRS seconds=$elapsed"

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
    if [ "$WALK_ERRORS_UNEXPLAINED" -eq 1 ]; then
        log_msg error "At least one discovery walk reported an error that could not be attributed to a directory or entry still present when it was checked; the usual cause is a path that disappeared during the walk"
    fi
    if [ "$UNSTATABLE_ENTRIES" -eq 0 ] && [ "$UNSTATABLE_UNMEASURED_GATES" -eq 1 ]; then
        log_msg info "Entries hidden by an unsearchable directory were not counted because both discovery gates are off: the regular files among them are enumerated and reported individually instead, but a subdirectory in that position reaches no counter, so the zero is unmeasured rather than a statement that none were hidden"
    elif [ "$UNSTATABLE_ENTRIES" -eq 0 ] && [ "$UNSTATABLE_UNMEASURED" -eq 1 ]; then
        log_msg info "Entries hidden by an unsearchable directory were not counted on this platform: this find cannot list an entry it cannot stat, so the zero is unmeasured rather than a statement that none were hidden"
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
    if [ "$DRY_RUN" -eq 0 ] && [ "$PEER_UNACKNOWLEDGED" -eq 1 ]; then
        # Withholding was half-applied: file BODIES were withheld from a peer that answered 2xx
        # without a Thunderstorm answer, and then this marker sent it the host's source name (the
        # hostname, by default) and the run's complete statistics anyway. Either the peer is a
        # Thunderstorm or it is not; the collector has already decided it is not, so it stops
        # talking to it -- including about itself.
        log_msg warn "The end marker was NOT sent to $PEER_UNACKNOWLEDGED_AT: that peer never acknowledged an upload, so this run does not hand it the host's source name and run statistics either"
    elif [ "$DRY_RUN" -eq 0 ]; then
        # Link uploads are real POSTs: without these fields the server's record of the run
        # would undercount what it received while the local summary reported it honestly.
        local stats_json
        build_stats_json "$elapsed"
        stats_json="$STATS_JSON_OUT"
        collection_marker "$base_url" "end" "$SCAN_ID" "$stats_json" >/dev/null
    fi
    # The server has now been told the scan ended, so the exit trap's backstop must stand down:
    # from here an exit is a normal one whatever code it carries.
    RUN_FINISHED=1

    # Exit 4 vs 5: rsync splits "partial transfer due to error" (23) from "partial transfer due
    # to vanished source files" (24) because they ask different things of the operator — one is
    # a problem to investigate, the other is a live host changing under the walk. A full-host
    # run on a busy machine always loses a few cache and log files this way, so collapsing both
    # into 4 made 4 the normal outcome and stripped it of meaning. Vanished losses alone -> 5;
    # anything else -> 4, which wins when both occurred (rsync lets 23 override 24). An
    # explicitly named target that was unusable is UNUSABLE_DIRS, so it stays 4 even if the
    # only file losses were vanished ones (tar treats a named-but-missing operand the same way).
    if [ "$FILES_UNREADABLE" -gt 0 ] || [ "$FILES_UPLOAD_FAILED" -gt 0 ] \
        || [ "$UNREADABLE_DIRS" -gt 0 ] || [ "$UNSTATABLE_ENTRIES" -gt 0 ] \
        || [ "$WALK_ERRORS_UNEXPLAINED" -eq 1 ] || [ "$UNUSABLE_DIRS" -gt 0 ] \
        || [ "$reconcile_failed" -eq 1 ]; then
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
# attribute_walk_errors -- explain why this root's discovery walk exited non-zero, by re-deriving
# the facts from the TREE rather than from find's stderr. Called ONLY after a walk failed, so a
# clean run pays nothing for it.
#
# find's diagnostics cannot be counted, let alone parsed. One directory that is readable but not
# searchable (mode 0444) holding four files produces FOUR lines, each naming a FILE inside it —
# so the old line count read 4 for one directory — while a directory that cannot be opened at all
# produces ONE line naming the directory. Two different losses, one spelling
# ('find: <path>: <strerror>'), and the text is not recoverable anyway: GNU quotes with ' in the
# C locale and U+2018/U+2019 in a UTF-8 one (findutils ignores QUOTING_STYLE), busybox never
# quotes and splits a newline-bearing path across lines, real paths contain colons, and the
# prefix is argv[0]. The first line is quoted as a human note and nothing numeric comes from it.
#
# Reads: scandir, walk_excludes, cloud_prunes. Writes: UNREADABLE_DIRS, UNLISTABLE_DIRS,
# UNSEARCHABLE_DIRS, FIRST_UNREADABLE_DIR, UNSTATABLE_ENTRIES, FIRST_UNSTATABLE,
# UNSTATABLE_UNMEASURED, and the per-root ATTR_* values for the caller's message.
# Returns 0 when at least one directory was attributed, 1 when nothing could be explained.
ATTR_DIRS_OUT=0
ATTR_UNLISTABLE_OUT=0
ATTR_UNSEARCHABLE_OUT=0
ATTR_ENTRIES_OUT=0
ATTR_FIRST_DIR_OUT=""
ATTR_FIRST_ENTRY_OUT=""
attribute_walk_errors() {
    ATTR_DIRS_OUT=0; ATTR_UNLISTABLE_OUT=0; ATTR_UNSEARCHABLE_OUT=0; ATTR_ENTRIES_OUT=0
    # BOTH first-* values reset here. Omitting ATTR_FIRST_ENTRY_OUT left it sticky across roots —
    # verbatim the defect the per-root value was added to fix: every root after the first named
    # an earlier root's file as its own example.
    ATTR_FIRST_DIR_OUT=""; ATTR_FIRST_ENTRY_OUT=""
    # Announced so "this never runs on a clean root" is an observable fact rather than an
    # assertion about counters that would read zero either way.
    log_msg debug "Attributing walk errors under '$scandir'"
    local _dlist _elist _d
    scratch_file walk.dirs || return 1; _dlist="$SCRATCH_FILE_OUT"
    # Same prune set as the discovery walk: a directory this run deliberately did not enter is
    # not a directory it could not read.
    find "$scandir" "${walk_excludes[@]}" "${cloud_prunes[@]+"${cloud_prunes[@]}"}" \
        -type d -print0 > "$_dlist" 2>/dev/null
    while IFS= read -r -d '' _d; do
        if [ ! -r "$_d" ]; then
            # opendir would fail: not even the names of what it held are knowable.
            ATTR_UNLISTABLE_OUT=$(( ATTR_UNLISTABLE_OUT + 1 ))
        elif [ ! -x "$_d" ]; then
            # Listable, not searchable: the names are known and every stat on them fails.
            ATTR_UNSEARCHABLE_OUT=$(( ATTR_UNSEARCHABLE_OUT + 1 ))
            # Count what it hides. Every entry that CAN be stat'ed satisfies exactly one of
            # '-size -1c' (zero bytes) and '-size +0c' (non-zero), so matching neither means the
            # stat failed. '-type f' is deliberately absent: the type is exactly what cannot be
            # read here, and requiring it would report zero on a filesystem without d_type —
            # precisely where the loss is largest. find cannot descend a directory it cannot
            # search, so this stays one level deep by construction.
            # Only when a gate is on. With BOTH gates off the walk needs no stat, so find
            # enumerates these entries from the directory entry and they reach collect_entries,
            # which books each one as unreadable — counting them here as well would name the
            # same file twice, under two counters that mean different things.
            if [ "${#SIZE_TEST[@]}" -eq 0 ] && [ "${#AGE_TESTS[@]}" -eq 0 ]; then
                # Not measured, and it must say WHY — the reason here is the configuration, not
                # the platform. With both gates off the probe would double-count the regular files
                # (the upload pass already books them), but a SUBDIRECTORY in that position is
                # matched by neither -type f nor -type l and reaches no counter at all, so
                # unstatable=0 is still not a measured zero.
                UNSTATABLE_UNMEASURED_GATES=1
            elif scratch_file walk.entries && _elist="$SCRATCH_FILE_OUT"; then
                # '! -type l': a symlink here is enumerated by the discovery walk's '-o -type l'
                # arm and accounted by the upload pass, so counting it again would book one object
                # under two counters that mean different things. It is NOT in links_seen — that
                # counter comes from '[ -h ]', which is exactly the lstat this directory refuses,
                # so such a symlink is carried as a regular file and lands in failed=/unreadable=.
                # Counted once either way; the earlier wording named the wrong counter.
                find "$_d" ! -size -1c ! -size +0c ! -type l -print0 > "$_elist" 2>/dev/null
                if count_records "$_elist" && [ "$COUNT_RECORDS_OUT" -gt 0 ]; then
                    ATTR_ENTRIES_OUT=$(( ATTR_ENTRIES_OUT + COUNT_RECORDS_OUT ))
                    if first_record "$_elist"; then
                        # Per-root, for this root's own message. FIRST_UNSTATABLE is a RUN-global
                        # and interpolating it into a per-root line made every root after the
                        # first name an EARLIER root's evidence path as its own example.
                        [ -n "$ATTR_FIRST_ENTRY_OUT" ] || ATTR_FIRST_ENTRY_OUT="$FIRST_RECORD_OUT"
                        [ -n "$FIRST_UNSTATABLE" ] || FIRST_UNSTATABLE="$FIRST_RECORD_OUT"
                    fi
                elif ! find "$_d" -print0 > /dev/null 2>&1; then
                    # Counted nothing. A plain listing that ALSO fails means this find cannot
                    # name an entry it cannot stat (busybox does not), so the zero is unmeasured.
                    # A plain listing that succeeds means the directory really is empty, and
                    # saying "unmeasured" there would be its own false statement.
                    UNSTATABLE_UNMEASURED=1
                fi
                : > "$_elist" 2>/dev/null || :
            else
                UNSTATABLE_UNMEASURED=1
            fi
        else
            continue
        fi
        [ -n "$ATTR_FIRST_DIR_OUT" ] || ATTR_FIRST_DIR_OUT="$_d"
    done < "$_dlist"
    : > "$_dlist" 2>/dev/null || :

    ATTR_DIRS_OUT=$(( ATTR_UNLISTABLE_OUT + ATTR_UNSEARCHABLE_OUT ))
    [ "$ATTR_DIRS_OUT" -gt 0 ] || return 1
    UNLISTABLE_DIRS=$(( UNLISTABLE_DIRS + ATTR_UNLISTABLE_OUT ))
    UNSEARCHABLE_DIRS=$(( UNSEARCHABLE_DIRS + ATTR_UNSEARCHABLE_OUT ))
    UNREADABLE_DIRS=$(( UNREADABLE_DIRS + ATTR_DIRS_OUT ))
    UNSTATABLE_ENTRIES=$(( UNSTATABLE_ENTRIES + ATTR_ENTRIES_OUT ))
    [ -n "$FIRST_UNREADABLE_DIR" ] || FIRST_UNREADABLE_DIR="$ATTR_FIRST_DIR_OUT"
    return 0
}

# enumerate_root -- verify the cloud-named folders under this root, walk it, and record what was
# found. Returns 1 when the root produced no usable list (it was reported by report_unusable_dir).
#
# The walk is PHYSICAL in every mode: find never follows a symlink, so one planted link cannot
# bypass a path-anchored exclusion or drag an unbounded subtree in. Symlinks are enumerated as
# entries so they can be counted and — with --follow-symlinks — collected without traversal.
# Each entry is then re-listed with a one-byte class prefix (f regular file, l symlink), because
# every root is enumerated before any upload: the upload pass must route by what an entry WAS at
# discovery, not by what it has become since. An entry whose type cannot be READ is written as
# 'f' and resolved honestly in the upload pass (see the loop's comment), never guessed at.
# Reads: scandir, walk_excludes, _in_cloud_scope, SIZE_TEST, AGE_TESTS.
# Writes: cloud_prunes, all_find_files, TOTAL_FILES, TOTAL_LINKS, UNREADABLE_DIRS,
#         UNLISTABLE_DIRS, UNSEARCHABLE_DIRS, UNSTATABLE_ENTRIES, WALK_ERRORS_UNEXPLAINED.
enumerate_root() {
    local _cand_file _cand _cloud_ev _find_err
    local find_results_file find_rc _find_msg _word
    local _entry _count _lcount _k _typed _typed_ok
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
        if scratch_file find.err; then _find_err="$SCRATCH_FILE_OUT"; else _find_err=/dev/null; fi
        # ONE walk, and the class is refined per entry afterwards. That is the shape every
        # portable collector converges on — unix_collector walks
        # '\( -type f -o -type d -o -type l \)' once and refines per entry; UAC uses -type only
        # as a FILTER and re-tests with '[ -f ] || [ -h ]' in remove_non_regular_files.sh —
        # because there is no portable way to make find report WHICH arm matched: -printf is
        # GNU-only (FreeBSD's is a documented stub with no %y, macOS has none) and busybox has
        # neither -printf nor -ls.
        #
        # A previous revision split this into a -type l walk and a -type f walk so the class
        # would come from find itself. It was reverted: two walks are not simultaneous, so an
        # entry that changed type between them matched NEITHER and left the inventory with no
        # counter and no diagnostic, and the count-based check added to detect that reported
        # ordinary file CREATION as a lost entry and forced exit 4 (measured: 14 false losses on
        # a tree gaining 400 files mid-scan). One walk cannot lose an entry that way.
        #
        # What the split was really trying to fix — a symlink under a readable-but-not-searchable
        # directory being misclassified — is fixed instead where it belongs, in the upload pass:
        # '[ -h ]' fails there for want of an lstat, and entry_stat_denied then books the entry
        # as UNREADABLE rather than inventing a type or calling it churn.
        #
        # ONE spelling of the discovery expression for every configuration: SIZE_TEST and
        # AGE_TESTS are empty when their gate is off, so the arm disappears instead of needing a
        # second, near-identical find command kept in sync by hand. Both gates read the stat find
        # already performed, so they are free here.
        find "$scandir" "${walk_excludes[@]}" "${cloud_prunes[@]+"${cloud_prunes[@]}"}" \
            \( -type f "${SIZE_TEST[@]+"${SIZE_TEST[@]}"}" "${AGE_TESTS[@]+"${AGE_TESTS[@]}"}" -o -type l \) \
            -print0 > "$find_results_file" 2>"$_find_err"
        find_rc=$?
        # A walk exits non-zero when part of the tree could not be read. Attribute that to the
        # DIRECTORIES responsible by measuring them, never by counting diagnostics. Keep whatever
        # the walks did return; only a root that was not enumerated at all is unusable.
        if [ "$find_rc" -ne 0 ]; then
            _find_msg="$(head -1 "$_find_err" 2>/dev/null)"
            _find_msg="${_find_msg//$'\n'/ }"
            # One list again, so this is the original condition: find failed AND returned
            # nothing, i.e. the target was not enumerated at all. The two-walk revision judged
            # the file walk alone, which let a single mode-0000 directory discard an entire root
            # — symlinks the run had already discovered included.
            if [ ! -s "$find_results_file" ]; then
                report_unusable_dir "$scandir" "file enumeration failed${_find_msg:+: $_find_msg}"
                return 1
            fi
            if attribute_walk_errors; then
                _word="directories"
                [ "$ATTR_DIRS_OUT" -eq 1 ] && _word="directory"
                log_msg error "$ATTR_DIRS_OUT $_word under '$scandir' could not be read in full (first: '$ATTR_FIRST_DIR_OUT'): $ATTR_UNLISTABLE_OUT could not be listed, so what they held is unknown, and $ATTR_UNSEARCHABLE_OUT could be listed but not searched"
                if [ "$ATTR_ENTRIES_OUT" -gt 0 ]; then
                    log_msg error "$ATTR_ENTRIES_OUT entry(ies) inside them are known to exist and could not be examined (first: '$ATTR_FIRST_ENTRY_OUT'); their type, size and age could not be read, so the discovery filters were never applied to them and they were not collected"
                fi
            else
                # Nothing in the tree explains it now — most often a path that disappeared during
                # the walk. Say so instead of inventing a directory, and keep the run partial:
                # relaxing a forensic guarantee inside a bug fix would be the wrong trade.
                WALK_ERRORS_UNEXPLAINED=1
                log_msg error "The walk of '$scandir' reported an error that could not be attributed to a directory it cannot read or an entry it cannot examine (first: ${_find_msg:-no diagnostic}); reported as a partial run rather than guessed at"
            fi
        fi
        # Count the entries (each NUL-terminated by -print0; fork-free) and record each one's
        # class as a one-byte prefix in a rewritten list: f regular file, l symlink. One lstat
        # per entry — the same refinement UAC performs with '[ -f ] || [ -h ]'. The upload pass
        # must route by what an entry WAS at discovery, because every root is enumerated before
        # any upload: a link swapped for a regular file must never become an unchecked upload,
        # and a file swapped for a link must never enter the link policy.
        #
        # '[ -h ]' answering false is NOT taken as proof of a regular file. It also answers false
        # when the lstat itself was refused, which is what a readable-but-not-searchable parent
        # does. Such an entry is written as 'f' here and then fails '[ -f ]' in the upload pass,
        # where entry_stat_denied books it as unreadable — a named failure and exit 4 — instead
        # of the churn it used to be called. A list that cannot be written makes the root
        # unusable, as a failed mktemp does above.
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

# curl_supports -- true when the INSTALLED curl understands option $1 (with optional value $2).
#
# Presence is not capability -- the lesson this file already applies to busybox wget and to a
# `find` predicate. The probe RUNS curl with the option and --version: curl parses its options
# first, so it exits 0 when the option is known and 2 when it is not. No network, no URL, one
# process, and the answer is cached for the run so a per-file path never pays for it.
#
# Why probe at all: --suppress-connect-headers is curl 7.54+, and passing an option an older curl
# does not know makes it exit 2 -- turning a supported run into "URL malformed", exactly the
# misdiagnosis this file keeps closing.
#
# Valueless only. The two-argument form existed for --resolve, which left with --server-addr; a
# branch with no caller and a docblock naming an option this file no longer passes are both things a
# reader has to disprove.
CURL_SUPPORTS_CACHE=""
curl_supports() {
    local _opt="$1"
    case " $CURL_SUPPORTS_CACHE " in
        *" ${_opt}=1 "*) return 0 ;;
        *" ${_opt}=0 "*) return 1 ;;
    esac
    if curl -q "$_opt" --version >/dev/null 2>&1; then
        CURL_SUPPORTS_CACHE="$CURL_SUPPORTS_CACHE ${_opt}=1"; return 0
    fi
    CURL_SUPPORTS_CACHE="$CURL_SUPPORTS_CACHE ${_opt}=0"
    return 1
}

# wget_supports -- true when the INSTALLED wget understands option $1. curl_supports' twin, and for
# the same reason: presence is not capability, and passing an option wget does not know makes it
# exit 2, which transport_error_reason reports as "wget rejected an option or its configuration
# file (an old or busybox wget?)" -- a run turned into a false "cannot reach the server".
#
# Every caller must GATE it: the probe is an extra `wget --version` invocation, and any test double
# that counts invocations scores that as an upload (this file records the same lesson for
# curl_supports and transport_version, where it moved two assertions from 1 to 2 and from 2 to 3).
# The cache mirrors curl_supports' shape and is not load-bearing today -- there is exactly one
# caller, so it is written once and never read. It is kept for symmetry and for the next caller.
WGET_SUPPORTS_CACHE=""
wget_supports() {
    local _opt="$1"
    case " $WGET_SUPPORTS_CACHE " in
        *" ${_opt}=1 "*) return 0 ;;
        *" ${_opt}=0 "*) return 1 ;;
    esac
    if LC_ALL=C wget "$_opt" --version >/dev/null 2>&1; then
        WGET_SUPPORTS_CACHE="$WGET_SUPPORTS_CACHE ${_opt}=1"; return 0
    fi
    WGET_SUPPORTS_CACHE="$WGET_SUPPORTS_CACHE ${_opt}=0"
    return 1
}

# transport_version -- the first line of the transport's own --version, for the run record.
# Read with a builtin rather than `| head -1`: this is the only place the collector would need
# `head`, and it is not a dependency worth acquiring for one cosmetic line.
transport_version() {
    local _v="" _tool="" _num=""
    IFS= read -r _v < <("$1" --version 2>/dev/null) || _v=""
    # "curl 7.88.1 (aarch64...) libcurl/7.88.1 ..." / "GNU Wget 1.21.3 built on linux-gnu."
    # Keep the tool and its version number; the rest is a paragraph, not a log line.
    case "$_v" in
        curl\ *)     _tool="curl"; _num="${_v#curl }"; _num="${_num%% *}" ;;
        GNU\ Wget\ *) _tool="wget"; _num="${_v#GNU Wget }"; _num="${_num%% *}" ;;
        *)           printf '%s' "${_v:-version unknown}"; return 0 ;;
    esac
    printf '%s %s' "$_tool" "$_num"
}

# The transports read http_proxy/https_proxy from the environment by themselves; this collector
# configures no proxy and does not predict whether one is used -- curl and wget decide that by their
# own no_proxy rules, which differ from each other. It reports what is SET, so a run through an
# intermediary is never silent, and keeps the credential so redact_detail can scrub it out of the
# transports' own error text (both echo the proxy URL, password included).
PROXY_ENV_OUT=""
PROXY_CRED_OUT=""
proxy_env_note() {
    local _p=""
    PROXY_ENV_OUT=""; PROXY_CRED_OUT=""
    if [ "$USE_SSL" -eq 1 ]; then _p="${https_proxy:-${HTTPS_PROXY:-}}"; else _p="${http_proxy:-}"; fi
    [ -n "$_p" ] || _p="${all_proxy:-${ALL_PROXY:-}}"
    [ -n "$_p" ] || return 0
    # Extracted before anything is logged: a proxy URL is routinely http://user:pass@host.
    case "$_p" in
        *@*) PROXY_CRED_OUT="${_p%@*}"; PROXY_CRED_OUT="${PROXY_CRED_OUT##*://}" ;;
    esac
    redact_userinfo "$_p"
    PROXY_ENV_OUT="$REDACTED_OUT"
}

# destination_report_proxy -- the ONE Proxy: line.
destination_report_proxy() {
    if [ -n "$PROXY_ENV_OUT" ]; then
        log_msg info "Proxy: $PROXY_ENV_OUT is set in the environment; ${UPLOAD_TOOL:-the transport} decides by its own no_proxy rules whether this run uses it. Run with http_proxy= https_proxy= to force a direct connection"
    else
        log_msg debug "Proxy: no proxy variable is set for this scheme"
    fi
}

# dest_health_note -- update the destination-down breaker from one upload's outcome. $1 is
# submit_file's sentinel. Never fails the caller.
dest_health_note() {
    # The breaker re-probes /api/status. A dry run has no failed uploads to react to, so this was
    # already unreachable -- but only via submit_file's return value. Stated, it stays true.
    [ "$DRY_RUN" -eq 0 ] || return 0
    [ "$DEST_DOWN" -eq 0 ] || return 0
    case "$1" in
        0)  DEST_DOWN_STREAK=0; return 0 ;;
        90) ;;
        *)  return 0 ;;
    esac
    DEST_DOWN_STREAK=$(( DEST_DOWN_STREAK + 1 ))
    [ "$DEST_DOWN_STREAK" -ge "$DEST_DOWN_THRESHOLD" ] || return 0
    [ -n "$RUN_BASE_URL" ] || return 0
    # The recovery is CAPPED. A destination that answers /api/status and then fails every upload --
    # a half-broken reverse proxy, a server out of disk -- re-armed the breaker every three files
    # with no limit: on a large tree that is an unbounded number of extra preflights, each with its
    # own sleep, against a peer that has already been shown not to work. After this many recoveries
    # the pattern is the answer, so stop asking.
    if [ "$DEST_DOWN_REARMS" -ge "$DEST_DOWN_REARM_MAX" ]; then
        DEST_DOWN=1
        DEST_DOWN_AT="$RUN_BASE_URL"
        log_msg error "The destination at $RUN_BASE_URL has recovered and failed $DEST_DOWN_REARMS times in this run; it is not usable. Every remaining file is counted as failed WITHOUT being transmitted -- re-run when the server is stable"
        return 0
    fi
    DEST_DOWN_REARMS=$(( DEST_DOWN_REARMS + 1 ))
    log_msg warn "$DEST_DOWN_STREAK consecutive uploads could not reach the destination; re-checking ${RUN_BASE_URL}/api/status once before giving up on it"
    # Jittered, so a fleet of collectors that all lost the same server do not re-probe in lockstep.
    sleep $(( 1 + RANDOM % 3 ))
    if server_preflight "$RUN_BASE_URL"; then
        log_msg warn "The destination answered again; continuing with the collection"
        DEST_DOWN_STREAK=0
        return 0
    fi
    DEST_DOWN=1
    DEST_DOWN_AT="$RUN_BASE_URL"
    log_msg error "The destination at $RUN_BASE_URL stopped answering (${DEST_DOWN_STREAK} consecutive uploads failed to reach it, and a fresh /api/status check also failed: ${PREFLIGHT_ERR_OUT}). Every remaining file is counted as failed WITHOUT being transmitted -- re-run when the server is back"
    return 0
}


# server_preflight -- ask the server for its status page and require a 2xx before a single file
# is read. $1 is the base url. Returns 0 when the server answered; 1 otherwise, with the reason in
# PREFLIGHT_ERR_OUT.
#
# Why this exists: a wrong --port was previously only discovered by trying to upload to it. The
# collection marker is not a reachability gate -- a 404 there is forgiven, deliberately, because
# /api/collection is optional -- so a port that answers HTTP at all passed, the collector walked
# the entire filesystem, and every upload failed at the end. On a real host that is hours of I/O
# for nothing. The Go collector settles this before it reads anything (CheckThunderstormUp ->
# os.Exit(1)), and UAC does the same with a test transfer; this is that gate.
#
# STATUS_IDENTITY_KEYS is intentionally a space-delimited STRING, not an array: it is iterated with
# an unquoted expansion in a `for`, which Bash 3.2 handles identically, and it interpolates directly
# into the operator-facing verdict so the message can never drift from the set actually tested.
#
# It is a reachability gate that also asks for a MINIMUM proof of identity: a 2xx is not enough,
# the body must be Thunderstorm's own status document. Beats settles its pre-publish gate the same
# way -- `status < 300` AND a successful unmarshal into its own struct
# (libbeat/esleg/eslegclient/connection.go:318-327) -- because a 200 carrying a foreign body is not
# a connection to the thing you meant. Measured on production, /api/status answers
# {"scanned_samples":28003,"queued_async_requests":0,"avg_scan_time_milliseconds":14,...}; it is the
# one endpoint whose shape production and the reference stub agree on, which is why this suite's own
# probe_live already requires it.
#
# ANY ONE of these keys is enough, deliberately: requiring all of them would turn a single
# server-side rename into "no collection happens anywhere", and the point is to exclude a captive
# portal or a wrong service, not to pin a schema. It still fails CLOSED -- there is no flag to skip
# it -- so the error names the set and quotes what actually answered.
#
# NOT "the documented fields", which is what this comment used to say and was FALSE: the OpenAPI
# contract gives /api/status no response schema and no field names at all, only the prose "map with
# values to scan times, scanned samples, wait times, ...". The set below is therefore a MEASUREMENT,
# and it is the union of the two sources that exist, because they disagree:
#   production (THOR 11.0.0-dev): scanned_samples, queued_async_requests,
#                                 avg_scan_time_milliseconds, avg_wait_time_milliseconds
#   Nextron's own client README:  scanned_samples, queued_async_requests, avg_scan_time_ms,
#                                 avg_total_time_ms, uptime_s, and five quota counters
# Two of the four this gate accepted before (avg_scan_time_milliseconds, uptime_seconds) appear in
# NO Nextron publication, and uptime_seconds is not sent by production either -- the gate passed only
# because scanned_samples happens to be in all three lists.
#
# TOP-LEVEL keys of a JSON object, checked with json_top_level_out, not a substring of the body.
# The substring test was satisfied by '<html>unknown metric scanned_samples</html>', by
# '{"no_scanned_samples_here":0}' and by 'ERROR scanned_samples is not a valid field' -- all
# measured. That is the same reasoning the upload acknowledgement uses, and the same one Beats
# applies by unmarshalling into its own struct.
#
# Proving the peer is really Thunderstorm beyond this needs the upload acknowledgement, which is a
# separate question: this gate cannot tell a replayed status document from a live one.
# location_from_headers -- the LAST Location header value in file $1, or "", into LOCATION_OUT.
LOCATION_OUT=""
location_from_headers() {
    LOCATION_OUT=""
    local _line _v
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line#"${_line%%[![:space:]]*}"}"
        case "$_line" in [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:*) ;; *) continue ;; esac
        _v="${_line#*:}"; _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"
        LOCATION_OUT="$_v"
    done < "$1"
}

# This runs under --dry-run too, by design: it is the ONE request a dry run is allowed to make, and
# it carries no evidence. Do not add a DRY_RUN branch here -- the check is what makes a dry run
# worth running, and the suite pins it (exactly one request, a GET /api/status).
PREFLIGHT_ERR_OUT=""
PREFLIGHT_ANSWERED=0   # 1 when a status line was read: the fatal says "no usable server", not "cannot reach"
STATUS_IDENTITY_KEYS="scanned_samples queued_async_requests avg_scan_time_milliseconds avg_wait_time_milliseconds avg_scan_time_ms avg_total_time_ms uptime_seconds uptime_s"
server_preflight() {
    PREFLIGHT_ERR_OUT=""
    PREFLIGHT_ANSWERED=0
    local _url="$1/api/status" _k
    local _hdr _err _ip _body _rc=1 _tool="" _attempt=0 _answered=0 _wait _detail
    local _body_text=""

    # scratch_file, not mktemp_portable: four fixed names inside the private work directory instead
    # of four forks and four NEW files per call. This function is called again by the breaker's
    # recovery check, so the old form leaked four temp files every time --
    # they were never registered for cleanup. Fixed names are safe here because each call truncates
    # them and no two preflights overlap.
    scratch_file preflight.hdr  || { PREFLIGHT_ERR_OUT="could not create a temp file"; return 1; }
    _hdr="$SCRATCH_FILE_OUT"
    scratch_file preflight.err  || { PREFLIGHT_ERR_OUT="could not create a temp file"; return 1; }
    _err="$SCRATCH_FILE_OUT"
    scratch_file preflight.ip   || { PREFLIGHT_ERR_OUT="could not create a temp file"; return 1; }
    _ip="$SCRATCH_FILE_OUT"
    scratch_file preflight.body || { PREFLIGHT_ERR_OUT="could not create a temp file"; return 1; }
    _body="$SCRATCH_FILE_OUT"

    # Two attempts, but only for what every other request in this file already treats as
    # transient (5xx from a restarting server or its proxy, 408, 429), honouring Retry-After.
    while [ "$_attempt" -lt 2 ]; do
        _attempt=$((_attempt + 1))
        : > "$_hdr"
        if [ "$UPLOAD_TOOL" = "curl" ]; then
            _tool="curl"
            : > "$_err"
            : > "$_ip"
            : > "$_body"
            # -H Cache-Control: no-cache -- a gate whose whole job is to prove the destination is
            # answering NOW must not be satisfiable by a cached or intermediary-served 200. GRR
            # sends this on every request for the same reason (comms.py:295-296).
            curl -q -g -sS -D "$_hdr" -o "$_body" -w '%{http_code}\n' "${CURL_EXTRA_OPTS[@]}" \
                --connect-timeout 10 \
                --max-time 15 \
                -H 'Cache-Control: no-cache' \
                "$_url" >"$_ip" 2>"$_err"
            _rc=$?
            # A redirect, not a command substitution: this file removes $( ) from paths a signal
            # can interrupt, because Bash 5.2 can lose a trapped signal that arrives inside one.
            curl_w_status "$_ip"
        elif [ "$UPLOAD_TOOL" = "wget" ]; then
            _tool="wget"
            : > "$_body"
            # 15 = the --max-time the curl arm declares. First contact with an unknown peer is
            # exactly where an unbounded read is least acceptable.
            wget_bounded 15 -S -O "$_body" "${WGET_EXTRA_OPTS[@]}" \
                --tries=1 \
                --dns-timeout=10 --connect-timeout=10 --read-timeout=15 \
                --header='Cache-Control: no-cache' \
                --content-on-error \
                "$_url" 2>"$_hdr"
            _rc=$?
            _err="$_hdr"
        else
            PREFLIGHT_ERR_OUT="no upload tool available"
            return 1
        fi
        # curl's own %{http_code} first, the header dump only as the fallback -- the same order
        # classify_upload_response uses, and for the same reason: a folded header line cannot forge
        # what curl computed for itself.
        if [ "$_tool" = "curl" ] && [ -n "$CURL_HTTP_STATUS_OUT" ]; then
            HTTP_STATUS_OUT="$CURL_HTTP_STATUS_OUT"
        else
            http_status_from_headers "$_hdr" "$_tool"
        fi
        # "Answered" means a status line AND a transport that did not fail -- except wget's exit 8,
        # which it uses for every HTTP error response. curl -D keeps a proxy's "200 Connection
        # established" in the same file, so after a failed tunnel (exit 35/56) that 200 is all
        # there is, and the origin never spoke: not an answer.
        _answered=0
        if [ -n "$HTTP_STATUS_OUT" ]; then
            if [ "$_rc" -eq 0 ] || { [ "$_tool" = "wget" ] && [ "$_rc" -eq 8 ]; }; then _answered=1; fi
        fi
        # ONE bounded read of the body, for ANY status. Two reasons it lives here rather than inside
        # the 2xx arm below:
        #
        # Bounded. This was a `while read -r; _body_text="$_body_text$_line"` accumulation, which is
        # O(n^2) in the number of LINES of a body the SERVER chooses, on first contact, before a
        # single file has been read. Measured against an 8 MB chunked body of 131072 lines: still
        # parsing after 30 s, with peak RSS a multiple of the body. `read -n` makes the cost O(1) in
        # body size -- 1 ms on a 2.7 MB body.
        #
        # curl's --max-filesize is NOT the answer and is deliberately not used: it needs a declared
        # Content-Length, and measured on curl 7.88.1 a chunked 7.8 MB body sailed past
        # --max-filesize 1048576 with rc=0 and all 7.8 MB written. The transfer bound is --max-time
        # (curl) and the bounded reap in on_signal (wget); this read bounds what is RETAINED. The
        # parse over it is bounded separately, by the substring guard in the identity loop below.
        #
        # 65536, not 4096: production answers 114 bytes on one line, but a pretty-printed document
        # can carry the recognised field well past 4 KB, and a bound that tight would make the
        # collector call a healthy Thunderstorm "not a Thunderstorm". 64 KB costs 1 ms.
        #
        # For any status: the body is the server's own explanation of what went wrong, and reading
        # it only in the 2xx arm meant every failure message below described causes it had already
        # ruled out instead of quoting what the peer actually said.
        IFS= read -r -d '' -n 65536 _body_text 2>/dev/null < "$_body" || :
        _body_text="${_body_text//$'\r'/ }"
        _body_text="${_body_text//$'\n'/ }"
        if [ "$_answered" -eq 1 ]; then
            case "$HTTP_STATUS_OUT" in
                2[0-9][0-9])
                    for _k in $STATUS_IDENTITY_KEYS; do
                        # json_top_level_out is O(keys x bytes) and this loop would pay it eight
                        # times over a body the PEER sizes: 64 KB of foreign keys cost ~40 s of CPU
                        # before a single file was read. A name absent as a substring cannot be a
                        # top-level key (keys are compared as raw bytes), so this only skips parses
                        # whose answer is already known.
                        case "$_body_text" in *"\"$_k\""*) ;; *) continue ;; esac
                        if json_top_level_out "$_k" "$_body_text" && [ "$JSON_TL_FOUND" -eq 1 ]; then
                            return 0
                        fi
                    done
                    _detail="$_body_text"
                    [ "${#_detail}" -gt 120 ] && _detail="${_detail:0:120}..."
                    # REDACTED, like the non-2xx arm below has always done with the identical data.
                    # This arm interpolated the peer's bytes verbatim, so a gateway or captive portal
                    # echoing the request URL back put the proxy PASSWORD on the terminal, in the log
                    # file and in syslog. Reproduced: the secret appeared once per run.
                    redact_detail "$_detail"
                    server_ip_literal_hint
                    PREFLIGHT_ERR_OUT="the server answered HTTP $HTTP_STATUS_OUT on /api/status but the body is not a Thunderstorm status document (no top-level counter key -- none of: $STATUS_IDENTITY_KEYS), so something is listening there but it did not answer as a Thunderstorm${SERVER_IP_HINT_OUT}${REDACTED_OUT:+ -- it sent: $REDACTED_OUT}"
                    PREFLIGHT_ANSWERED=1
                    return 1 ;;
                500|502|503|504|408|429)
                    if [ "$_attempt" -lt 2 ]; then
                        retry_after_seconds "$_hdr"
                        _wait="${RETRY_AFTER_OUT:-2}"; [ "$_wait" -gt 120 ] && _wait=120
                        log_msg warn "Server answered HTTP $HTTP_STATUS_OUT on /api/status; retrying once in ${_wait}s"
                        sleep "$_wait"
                        continue
                    fi ;;
            esac
        fi
        break
    done

    if [ "$_answered" -eq 0 ]; then
        if [ "$_rc" -ne 0 ]; then
            transport_error_reason "$_tool" "$_rc"
            PREFLIGHT_ERR_OUT="$TRANSPORT_ERR_OUT"
            if [ "$_tool" = "wget" ]; then
                last_diagnostic_line "$_err"; _detail="$DIAG_LINE_OUT"
            else
                read_head "$_err" 2048; _detail="$READ_HEAD_OUT"
            fi
            _detail="${_detail//$'\r'/ }"
            _detail="${_detail//$'\n'/ }"
            redact_detail "$_detail"
            [ -n "$REDACTED_OUT" ] && PREFLIGHT_ERR_OUT="$PREFLIGHT_ERR_OUT: $REDACTED_OUT"
            return 1
        fi
        PREFLIGHT_ANSWERED=1
        PREFLIGHT_ERR_OUT="the peer answered on /api/status but produced no readable HTTP status line"
        return 1
    fi
    PREFLIGHT_ANSWERED=1
    case "$HTTP_STATUS_OUT" in
        3[0-9][0-9])
            location_from_headers "$_hdr"
            PREFLIGHT_ERR_OUT="the server redirected /api/status (HTTP ${HTTP_STATUS_OUT}${LOCATION_OUT:+ to $LOCATION_OUT}); this collector never follows redirects — use the scheme and port the redirect names (e.g. --ssl --port 443)" ;;
        401|403)
            PREFLIGHT_ERR_OUT="the peer requires authentication (HTTP $HTTP_STATUS_OUT) that this collector cannot supply; a Thunderstorm must be reachable without credentials, or exempted on the proxy" ;;
        407)
            PREFLIGHT_ERR_OUT="a proxy refused the request (HTTP 407 Proxy Authentication Required)" ;;
        *)
            # Quote the peer's own explanation. The body is read for every status now, so this no
            # longer has to guess between two causes it cannot distinguish: a reverse proxy's 404
            # page and a Thunderstorm behind the wrong path say different things, and the operator
            # can only tell them apart if the collector passes the message on.
            _detail="$_body_text"
            [ "${#_detail}" -gt 120 ] && _detail="${_detail:0:120}..."
            redact_detail "$_detail"
            server_ip_literal_hint
            PREFLIGHT_ERR_OUT="the server answered HTTP $HTTP_STATUS_OUT on /api/status; something is listening there but it did not answer as a Thunderstorm — the port, or a reverse proxy in front of it that does not pass /api through${SERVER_IP_HINT_OUT}${REDACTED_OUT:+ — it sent: $REDACTED_OUT}" ;;
    esac
    return 1
}

# prepare_run -- everything that must be true before the first directory is touched: open the log
# file sink, validate the configuration, announce the run, build the endpoint URLs, create the
# private work directory, send the begin marker and settle the progress display. Exits the script
# on a condition that makes collecting pointless (missing upload tool, unusable work directory,
# unreachable server) — those are runtime errors, not partial results.
# Writes: scheme, query_source, base_url, api_endpoint, UPLOAD_TOOL,
# CURL/WGET_EXTRA_OPTS, SHOW_PROGRESS, SCAN_ID, LOG_FILE_READY, TS_WORK_DIR,
# THUNDERSTORM_SERVER, SERVER_KIND_OUT/SERVER_URLHOST_OUT (via
# classify_server), RUN_BASE_URL (published for the breaker),
# BEGIN_MARKER_SENT, TIMEOUT_CMD, COUNT_FAST, PROXY_ENV_OUT
# (via proxy_env_note) and PREFLIGHT_* (via server_preflight).
#
# That list is long because this function is long -- 350+ lines across six distinct jobs (config,
# dependency gates, work directory, transport options, destination selection, reporting). Splitting
# it along those seams is worth doing and is deliberately NOT done here: it is a behaviour-preserving
# refactor and this change is a behaviour fix, so mixing them would make both harder to review.
prepare_run() {
    detect_source_name
    # validate_config runs BEFORE the file sink is armed. A usage error must not leave a file
    # behind in whatever directory the operator happened to run from: '--port abc' used to create
    # ./thunderstorm.log while '--port' with no value (rejected earlier, in parse_args) did not --
    # two usage errors, both exit 2, one with an on-disk side effect. die() still forces the
    # terminal when no sink is ready, so the operator sees the message either way.
    validate_config
    # Configuration is good; from here every runtime error is logged to the configured file.
    LOG_FILE_READY=1
    # Deferred out of validate_config so it lands in the log rather than only on the terminal.
    if [ -n "$CA_CERT" ] && [ "$INSECURE" -eq 1 ]; then
        log_msg warn "--ca-cert and --insecure are both set; --insecure takes precedence"
    fi
    print_banner

    # EUID is a bash builtin variable, so the common case costs no fork and cannot be defeated by
    # a missing `id` -- which used to make a root run announce it was unprivileged. `id` remains the
    # fallback for the theoretical shell that does not set EUID.
    if [ "${EUID:-$(id -u 2>/dev/null || printf '%s\n' 1)}" != "0" ]; then
        log_msg warn "Running without root privileges; some files may be inaccessible"
    fi

    CURL_EXTRA_OPTS=()
    # A followed redirect turns wget's POST into a GET with no body, and the 200 that comes back
    # was read as a submitted file. curl never follows (no -L); make wget match it.
    WGET_EXTRA_OPTS=(--max-redirect=0)
    if [ "$INSECURE" -eq 1 ]; then
        CURL_EXTRA_OPTS+=("-k")
        WGET_EXTRA_OPTS+=("--no-check-certificate")
    fi
    if [ -n "$CA_CERT" ]; then
        CURL_EXTRA_OPTS+=("--cacert" "$CA_CERT")
        WGET_EXTRA_OPTS+=("--ca-certificate=$CA_CERT")
    fi
    # Detected here rather than at first use so the run can RECORD which transport it had.
    # curl and wget do not agree about a wrong port -- their TLS stacks disagree about a
    # protocol-sniffing listener, so the same command line exits 4 under one and 1 under the
    # other -- and the log previously never said which one ran. The fatal "neither is installed"
    # check stays where it was, below, so its message and exit code are unchanged.
    detect_upload_tool || true
    # Transport-SPECIFIC options are added here, AFTER detect_upload_tool -- not in the array build
    # above, where UPLOAD_TOOL is still empty. Both of the options below were briefly dead for
    # exactly that reason: a `[ "$UPLOAD_TOOL" = "curl" ]` guard evaluated before the tool was
    # detected can never be true. This is the same shape as the redirect default that existed in
    # one place and was absent where it mattered.
    # --suppress-connect-headers (curl 7.54+): a forward proxy's "200 Connection established" from
    # its CONNECT reply lands in the SAME header file the status parser reads, so without this a
    # proxy's own answer can be read as the destination's. Wazuh sets the libcurl equivalent
    # unconditionally and documents the same attribution bug. wget has no equivalent; its headers
    # come from its own stderr, where the anchored parser already separates them.
    # Probed and added ONLY when a proxy variable is actually set. Two reasons, and the second is
    # the one that bit: the option is meaningless without a proxy CONNECT, and the probe is an
    # extra `curl --version` invocation -- which any test double that counts its invocations scores
    # as an upload. This file already records that lesson for transport_version ("probing it
    # unconditionally made any test double that counts its invocations count the probe as an
    # upload"); measured again here, it turned two upload-retry assertions from 1 into 2 and from
    # 2 into 3.
    if [ "$UPLOAD_TOOL" = "curl" ] \
        && [ -n "${http_proxy:-}${https_proxy:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ] \
        && curl_supports --suppress-connect-headers; then
        CURL_EXTRA_OPTS+=("--suppress-connect-headers")
    fi
    # --no-config (wget 1.19+): the ONLY way to stop wget reading the SYSTEM rc.
    #
    # WGETRC replaces the USER rc and nothing else, because wget reads the system file first --
    # /etc/wgetrc, or wherever $SYSTEM_WGETRC points. Measured with a proxy configured only there
    # and no proxy variable set at all: the proxy received all 10 requests of a run, the origin
    # received none, and the collector reported "Proxy: none" while naming the PROXY's address as
    # the server's peer. That is the silent-retarget class this file exists to close, reached
    # through a file the operator may not own and cannot see from here.
    #
    # --no-config closes it outright ("do not read any config file"): measured, the same run then
    # sent all 10 requests to the origin and none to the proxy. It also makes the debug line below
    # true, and it retires the second half of the same channel -- a malformed system rc used to
    # make wget exit 2, which surfaced as "Cannot reach a Thunderstorm server ... (an old or
    # busybox wget?)" for a server that was answering perfectly.
    #
    # WGETRC is kept as well rather than deleted: on a wget too old for --no-config it is still the
    # only defence against the user rc, and the two do not conflict.
    #
    # WHAT ELSE THIS SUPPRESSES, since "do not read any config file" means all of it and not just
    # proxies. Measured, each directive placed in the system rc and the run watched:
    #
    #   ca_certificate / ca_directory / check_certificate  -> no longer applied. A deployment that
    #       trusted an internal CA ONLY through the system rc now fails verification (wget exit 5).
    #       Recoverable: pass it as --ca-cert. This is the one case that can break a working run,
    #       and it is why the change is called out in --help and README rather than left implicit.
    #   header, user_agent, bind_address                   -> no longer applied, and these have NO
    #       flag equivalent here, so an affected deployment cannot recover without editing this
    #       file. Accepted deliberately: none of the three can change WHETHER the evidence arrives,
    #       only how the request looks or which local address it leaves from.
    #   proxy / use_proxy / no_proxy                       -> the channel this was added for.
    #   timeout / tries / max_redirect                     -> already overridden on the command
    #       line, so nothing changes.
    #
    # The default cost is zero: a stock Debian /etc/wgetrc contains exactly one active directive,
    # passive_ftp = on, which is FTP-only and cannot affect an HTTP upload. The risk is confined to
    # hosts whose administrator customised the file, and there a loud, diagnosable TLS failure is a
    # better outcome than the silent proxy retarget it replaces.
    WGET_RC_SEALED=0
    if [ "$UPLOAD_TOOL" = "wget" ] && wget_supports --no-config; then
        WGET_EXTRA_OPTS+=("--no-config")
        WGET_RC_SEALED=1
    fi


    query_source="$(build_query_source "$SOURCE_NAME")"
    build_base_url
    base_url="$BASE_URL_OUT"
    api_endpoint="${base_url}/api/checkAsync${query_source}"

    log_msg info "Started Thunderstorm Collector - Version $VERSION"
    # Under --dry-run there may be no server at all, and "Server: " with nothing after it reads
    # like a bug. Say what is true instead.
    log_msg info "Server: ${THUNDERSTORM_SERVER:-none given (--dry-run): nothing is sent anywhere}"
    log_msg info "Port: $THUNDERSTORM_PORT"
    # With no --server (only possible under --dry-run) api_endpoint would read
    # "http://:8080/api/..." -- a URL that names no host, printed as if it were the destination.
    # A run must not state something that is not true, however harmless the run.
    #
    # Deferred to AFTER the preflight in every case, because the scan_id is appended to
    # api_endpoint once the begin marker returns one -- so printing it here named a URL that no
    # request in the run ever used. See the single announcement further down.
    if [ -z "$THUNDERSTORM_SERVER" ]; then
        log_msg info "API endpoint: none (no --server was given; --dry-run reads files and sends nothing)"
    fi
    local _tls_mode="off"
    if [ "$USE_SSL" -eq 1 ]; then
        _tls_mode="on"
        if [ -n "$CA_CERT" ]; then
            # curl --cacert REPLACES the trust store; wget --ca-certificate only ADDS to the
            # system store (its OpenSSL and GnuTLS backends both load the default paths first).
            if [ "$UPLOAD_TOOL" = "wget" ]; then
                _tls_mode="on (--ca-cert $CA_CERT, added to the system trust store — wget cannot replace it)"
            else
                _tls_mode="on (--ca-cert $CA_CERT replaces the trust store)"
            fi
        fi
        [ "$INSECURE" -eq 1 ] && _tls_mode="on, certificate NOT verified (--insecure)"
    fi
    log_msg info "Transport: ${UPLOAD_TOOL:-none detected} | TLS: $_tls_mode"
    # The version costs an extra invocation of the transport, so it is only asked for when
    # someone is actually diagnosing. That is not just fork economy: probing it unconditionally
    # ran the transport once per run for a cosmetic string, and any test double that counts its
    # invocations -- several in this repo's own suite do -- counted the probe as an upload.
    [ "$DEBUG" -eq 1 ] && [ -n "$UPLOAD_TOOL" ] && \
        log_msg debug "Transport version: $(transport_version "$UPLOAD_TOOL")"
    proxy_env_note
    destination_report_proxy
    # An exported THUNDERSTORM_PORT is deliberately ignored -- letting the environment redirect
    # evidence is wrong for a forensic collector -- but silently ignoring it is worse than saying so.
    if [ -n "${THUNDERSTORM_PORT_ENV:-}" ] && [ "$THUNDERSTORM_PORT_ENV" != "$THUNDERSTORM_PORT" ]; then
        log_msg warn "THUNDERSTORM_PORT='$THUNDERSTORM_PORT_ENV' is set in the environment and was IGNORED; the port is $THUNDERSTORM_PORT (use --port)"
    fi
    if [ -n "${THUNDERSTORM_SERVER_ENV:-}" ] && [ "$THUNDERSTORM_SERVER_ENV" != "$THUNDERSTORM_SERVER" ]; then
        # Redacted: this is a warn, so under --quiet it exists ONLY in the log file left behind on
        # the triaged host, where an exported 'user:pw@host' would otherwise be readable.
        redact_userinfo "$THUNDERSTORM_SERVER_ENV"
        log_msg warn "THUNDERSTORM_SERVER='$REDACTED_OUT' is set in the environment and was IGNORED; the server is ${THUNDERSTORM_SERVER:-none given (--dry-run: nothing is sent anywhere)} (use --server)"
    fi
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
        die_runtime 3 "'mkdir' is not available; cannot create the private work directory"
    fi
    # find does the entire discovery; without it every root would fail the same way and be
    # reported as "could not be read" — a named missing dependency (exit 3) instead.
    if ! command -v find >/dev/null 2>&1; then
        die_runtime 3 "'find' is not available; cannot enumerate files"
    fi
    # 'cat' streams the file into wget's multipart body, and only there: a byte-exact copy of an
    # arbitrary file is not a job for the shell. Detected rather than assumed because without it the
    # body was empty and the upload reported success for a file whose bytes never left the host.
    # curl needs nothing here (-F reads the file itself), so the check follows the transport.
    if [ "$UPLOAD_TOOL" = "wget" ] && ! command -v cat >/dev/null 2>&1; then
        die_runtime 3 "'cat' is not available and the wget transport needs it to assemble the upload body; install curl, or cat"
    fi
    # 'rm' removes the private work directory, which on the wget path holds a copy of the last file
    # collected. Its absence is not fatal -- the collection is still valid -- but it must not be
    # silent: leaving evidence behind on a triaged host is exactly what that directory exists to
    # avoid.
    if ! command -v rm >/dev/null 2>&1; then
        log_msg warn "'rm' is not available: the private work directory will be LEFT BEHIND on this host at the end of the run, and on the wget transport it holds a copy of the last file collected — remove it by hand"
    fi
    # Fast policy counting: counting NUL separators with tr|wc beats a per-record read loop by
    # several times and stays NUL-exact (a newline in a filename cannot inflate it). Both are
    # OPTIONAL: nothing else in this file uses either command any more, and without them the read
    # loop runs instead with identical counts.
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
        die_runtime 1 "Cannot create the private work directory under '${TMPDIR:-/tmp}' (not writable, or a directory of that name exists and is not ours)"
    fi
    # wget's USER rc is switched off the way -q does it for curl: WGETRC names an EMPTY regular
    # file (an unreadable target such as /dev/null makes wget exit 1), so ~/.wgetrc is ignored. The
    # SYSTEM rc is a different channel and WGETRC does not touch it -- that is what --no-config is
    # for, above, and WGET_RC_SEALED records whether this wget accepted it.
    WGETRC="$TS_WORK_DIR/wgetrc"
    if : > "$WGETRC" 2>/dev/null; then
        export WGETRC
    else
        unset WGETRC
        # What that costs depends on whether the rc channel is sealed at all, which is known here.
        if [ "$WGET_IS_MINIMAL" -eq 1 ]; then
            log_msg warn "Could not create an empty WGETRC in the work directory; this wget ignores WGETRC anyway and reads no rc file"
        elif [ "$WGET_RC_SEALED" -eq 1 ]; then
            log_msg warn "Could not create an empty WGETRC in the work directory; --no-config is in force, so no rc file is read regardless"
        else
            log_msg warn "Could not create an empty WGETRC in the work directory; wget will read ~/.wgetrc"
        fi
    fi
    # This line used to say "Transport rc files are not read" unconditionally, which was FALSE on
    # the wget transport: the system rc was still in force and could redirect every request through
    # a proxy. Say exactly which files are sealed.
    if [ "$UPLOAD_TOOL" = "wget" ] && [ "$WGET_IS_MINIMAL" -eq 1 ]; then
        # It rejects --no-config, but not for being old: a minimal build reads no rc file and
        # ignores WGETRC entirely. Naming the GNU channels here would describe the wrong tool.
        log_msg debug "This wget is a minimal build: it reads no rc file and ignores WGETRC"
    elif [ "$UPLOAD_TOOL" = "wget" ] && [ "$WGET_RC_SEALED" -eq 1 ]; then
        log_msg debug "No transport rc file is read (wget --no-config) and URL globbing is off"
    elif [ "$UPLOAD_TOOL" = "wget" ]; then
        log_msg debug "This wget is too old for --no-config, so only its USER rc is suppressed (WGETRC${WGETRC:+=$WGETRC}); its SYSTEM rc still applies and may set a proxy or options this run cannot see"
    elif [ "$UPLOAD_TOOL" = "curl" ]; then
        log_msg debug "Transport rc files are not read and URL globbing is off (curl -q -g)"
    fi
    # No arm for an EMPTY UPLOAD_TOOL: reachable under --dry-run with neither transport installed,
    # and a bare `else` here credited curl's flags on a run that had no transport at all.

    # The question here is "was a destination NAMED?", not "is this a real run?": the check is a GET
    # that carries no evidence, and it lands before the walk, so a bad destination costs no file
    # work. Whether to TRANSMIT is asked further down, over the marker alone.
    if [ -n "$THUNDERSTORM_SERVER" ]; then
        if [ -z "$UPLOAD_TOOL" ]; then
            die_runtime 3 "Neither 'curl' nor 'wget' is installed; unable to upload samples"
        fi
        if [ "$UPLOAD_TOOL" = "wget" ] && [ "$WGET_IS_MINIMAL" -eq 1 ]; then
            # It cannot refuse redirects (--max-redirect) or stop its own retries (--tries), so it
            # cannot keep this collector's guarantees; a raw usage dump is not an error message.
            die_runtime 3 "the wget found is a minimal build (busybox?) that cannot refuse redirects or bound its own retries; install GNU wget or curl"
        fi
        # Settle whether the server is there BEFORE reading a single file. One destination, checked
        # once: if it does not answer as a Thunderstorm the run stops here, before any file is read.
        local _sel=0 _path_note=""
        # How the request may have been routed, for the messages below: an operator told "check the
        # host and port" when a PROXY was dead looks in the wrong place.
        if [ -n "$PROXY_ENV_OUT" ]; then
            _path_note=" (a proxy is set in the environment: $PROXY_ENV_OUT)"
        fi
        if server_preflight "$base_url"; then
            _sel=1
        elif [ "$PREFLIGHT_ANSWERED" -eq 1 ]; then
            # It ANSWERED but not as a Thunderstorm: a different fault from silence, and a
            # different place to look.
            destination_unusable "No usable Thunderstorm server at ${base_url}${_path_note} — ${PREFLIGHT_ERR_OUT}"
        else
            # Name the PATH, not just the host: with a dead proxy, "check the host and port" points
            # the operator at the wrong thing.
            destination_unusable "Cannot reach a Thunderstorm server at ${base_url}${_path_note} — ${PREFLIGHT_ERR_OUT}"
        fi
        # The breaker re-probes this, and base_url is a local of main.
        RUN_BASE_URL="$base_url"
        if [ "$_sel" -eq 1 ]; then
            log_msg debug "Server answered on ${base_url}/api/status"
        fi
        # The begin marker opens a scan and hands over this host's source name, so it is
        # transmission and a dry run withholds it (collection_marker refuses it too).
        if [ "$_sel" -eq 0 ]; then
            # Dry run only: the check failed and was reported as a warning above.
            log_msg info "Dry-run: the destination did not answer, so nothing further was asked of it; the file preview below is what a reachable destination would have received"
        elif [ "$DRY_RUN" -eq 0 ]; then
            local _begin_resp_file
            local _begin_rc=0
            _begin_resp_file="$(mktemp_portable)" || die_runtime 1 "Cannot create temp file"
            collection_marker "$base_url" "begin" "" "" > "$_begin_resp_file"
            _begin_rc=$?
            read_head "$_begin_resp_file" 1024; SCAN_ID="$READ_HEAD_OUT"
            # If the begin marker failed after retry, the server is unreachable — fatal error
            if [ "$_begin_rc" -ne 0 ]; then
                # The preflight has already connected by now, so this is never "cannot connect".
                die_runtime 1 "Thunderstorm server at ${base_url} answered on /api/status but the begin marker to /api/collection failed after retry${MARKER_ERR_OUT:+ — $MARKER_ERR_OUT}"
            fi
            BEGIN_MARKER_SENT=1
            if [ -n "$SCAN_ID" ]; then
                log_msg info "Collection scan_id: $SCAN_ID"
                case "$api_endpoint" in
                    *\?*) api_endpoint="${api_endpoint}&scan_id=$(urlencode "$SCAN_ID")" ;;
                    *)    api_endpoint="${api_endpoint}?scan_id=$(urlencode "$SCAN_ID")" ;;
                esac
            fi
        else
            log_msg info "Dry-run: the destination was checked above; no collection marker is sent and no file will be transmitted"
        fi
    else
        # Only reachable under --dry-run, which is the one mode that does not require --server.
        log_msg info "Dry-run: no --server was given, so no destination was checked; this reports what would be collected locally"
    fi
    # The endpoint, announced ONCE and only now. It used to be printed up with Server:/Port:, which
    # is before the begin marker returns a scan_id -- and the scan_id is appended to this very
    # string a few lines above, so the URL the run announced was not the URL any request used. A
    # single line, after the value is final, is both true and easier to read.
    if [ -n "$THUNDERSTORM_SERVER" ]; then
        log_msg info "API endpoint: $api_endpoint"
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
# count_records -- how many NUL-terminated records file $1 holds, in COUNT_RECORDS_OUT.
# Extracted from count_matching so the discovery pass can count its own lists the same way:
# deleting everything but the separators and measuring beats reading record by record several
# times over, and the read loop remains as the fallback when wc is absent. Returns 1 when the
# fast path produced no digits, so the caller can decide (count_matching calls that partial).
COUNT_RECORDS_OUT=0
count_records() {
    local _f="$1" _n=0 _e
    COUNT_RECORDS_OUT=0
    if [ "$COUNT_FAST" -eq 1 ]; then
        # One NUL per record; everything else is deleted, so the byte count IS the record count.
        # wc pads its output on some implementations, hence the digit strip.
        _n="$(tr -d -c '\000' < "$_f" 2>/dev/null | wc -c 2>/dev/null)" || _n=""
        _n="${_n//[^0-9]/}"
        if [ -z "$_n" ]; then
            COUNT_RECORDS_OUT=0
            return 1
        fi
    else
        while IFS= read -r -d '' _e; do
            _n=$(( _n + 1 ))
        done < "$_f"
    fi
    COUNT_RECORDS_OUT="$_n"
    return 0
}

count_matching() {
    local _root="$1"
    shift
    local _list _rc
    COUNT_MATCHING_OUT=0
    # A scratch file rather than '< <(find ...)': process substitution hides the producer's exit
    # status, and a counting walk that died partway would then publish a silently short number as
    # if it were the truth. scratch_file reuses a fixed name, so this costs no temp-file growth.
    scratch_file count.lst || { COUNT_MATCHING_PARTIAL=1; return 0; }
    _list="$SCRATCH_FILE_OUT"
    find "$_root" "$@" -print0 > "$_list" 2>/dev/null
    _rc=$?
    count_records "$_list" || COUNT_MATCHING_PARTIAL=1
    [ "$_rc" -eq 0 ] || COUNT_MATCHING_PARTIAL=1
    COUNT_MATCHING_OUT="$COUNT_RECORDS_OUT"
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
        count_matching "${_base[@]}" -type f "${STATABLE_TEST[@]}" "${SIZE_TEST[@]+"${SIZE_TEST[@]}"}" ! "${AGE_TESTS[@]}"
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
    local _known
    local _in_cloud_scope
    local _keep_cloudstorage_prune
    local _find_err
    local _find_msg
    local _covered
    local _child_prunes
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
    local _report_rc=$?
    return "$_report_rc"
}

main "$@"
exit $?
