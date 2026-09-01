#!/usr/bin/env bash
#
# verify_portable.sh — portability check for the bash collector on a NON-Linux / non-GNU host
# (macOS with /bin/bash 3.2 and BSD find is the primary target; any BSD or busybox system works).
#
# It exercises exactly the constructs the collector depends on that differ between GNU, BSD and
# busybox userlands, then runs the collector itself in --dry-run over a small fixture and checks
# the documented --dir / --follow-symlinks behaviour. Nothing is uploaded; no server is contacted.
#
#   bash scripts/tests/verify_portable.sh [path/to/thunderstorm-collector.sh]
#
# Paste the complete output back to the reviewer. Every line is PASS / FAIL / INFO.

COLLECTOR="${1:-$(cd "$(dirname "$0")/.." && pwd)/bash/thunderstorm-collector.sh}"
[ -f "$COLLECTOR" ] || { printf 'collector not found: %s\n' "$COLLECTOR" >&2; exit 2; }

p=0; f=0
ok(){ printf 'PASS %s\n' "$1"; p=$((p+1)); }
no(){ printf 'FAIL %s\n' "$1"; f=$((f+1)); }
info(){ printf 'INFO %s\n' "$1"; }
g(){ printf '%s\n' "$1" | grep -oE "(^|[[:space:]])$2=[0-9]+" | tail -1 | cut -d= -f2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/tsport.XXXXXX")" || { printf 'cannot create temp dir\n' >&2; exit 2; }
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT

printf '=== environment ===\n'
info "bash: $BASH_VERSION"
info "uname: $(uname -srm 2>/dev/null)"
if fv="$(find --version 2>/dev/null | head -1)"; then info "find: $fv"; else info "find: no --version (BSD-style find)"; fi
info "readlink: $(command -v readlink || echo MISSING)   mktemp: $(command -v mktemp || echo MISSING)   mount: $(command -v mount || echo MISSING)"
info "date +%N gives: '$(date +%N 2>/dev/null)' (literal N or empty on BSD is expected and handled)"
info "/proc/mounts readable: $([ -r /proc/mounts ] && echo yes || echo 'no -> mount(8) output is parsed')"

printf '\n=== collector functions (sourced without running main) ===\n'
# Load every function without executing the run: drop the two trailing lines `main "$@"` / `exit $?`.
sed '$d' "$COLLECTOR" | sed '$d' > "$W/lib.sh"
LOG_TO_FILE=0; LOG_TO_CMDLINE=0
# shellcheck disable=SC1090
if . "$W/lib.sh"; then ok "collector sourced on this bash (no syntax/feature error)"; else no "collector failed to source on this bash"; fi

# in_range / is_integer
in_range 65535 65535 && ! in_range 65536 65535 && in_range 0000007 36500 && ! in_range 99999999999999999999 36500 && ok "in_range bounds incl. leading zeros and 20-digit input" || no "in_range"
# escape_find_glob + the local find's -path semantics
mkdir -p "$W/esc/a*b" "$W/esc/c?d" "$W/esc/e[1]f" "$W/esc/g\\h" "$W/esc/aXXb" "$W/esc/cXd" "$W/esc/e1f" "$W/esc/gh"
for d in 'a*b' 'c?d' 'e[1]f' 'g\h' aXXb cXd e1f gh; do printf 'x\n' > "$W/esc/$d/file.txt"; done
bad=0
for n in 'a*b' 'c?d' 'e[1]f' 'g\h'; do
    escape_find_glob "$W/esc/$n"
    out="$(find "$W/esc" -path "$FIND_GLOB_OUT" -prune -o -type f -print 2>/dev/null)"
    printf '%s\n' "$out" | grep -qF "$W/esc/$n/file.txt" && bad=$((bad+1))
    for dcy in aXXb cXd e1f gh; do printf '%s\n' "$out" | grep -qF "$W/esc/$dcy/file.txt" || bad=$((bad+1)); done
done
[ "$bad" -eq 0 ] && ok "escape_find_glob: -path prunes exactly the literal path on this find (* ? [ \\)" || no "escape_find_glob: $bad mismatches on this find"
# lexical_abs_path / path_covers
lexical_abs_path /a/b/link ../c/./d; [ "$LEXICAL_ABS_OUT" = "/a/c/d" ] && ok "lexical_abs_path collapses . and .." || no "lexical_abs_path -> $LEXICAL_ABS_OUT"
path_covers / /x && path_covers /a /a/b && ! path_covers /a /ab && ok "path_covers root and prefix rules" || no "path_covers"
# resolve_dir -L / -P through a symlinked directory, and a name ending in a newline
mkdir -p "$W/real/sub"; ln -s "$W/real" "$W/lnk"
resolve_dir -L "$W/lnk/sub"; r1="$RESOLVE_DIR_OUT"; resolve_dir -P "$W/lnk/sub"; r2="$RESOLVE_DIR_OUT"
[ "$r1" = "$W/lnk/sub" ] && [ "$r2" = "$(cd -P "$W/real/sub" && pwd)" ] && ok "resolve_dir: -L keeps the link, -P resolves it" || no "resolve_dir -L='$r1' -P='$r2'"
nl="$W/nl"$'\n'; mkdir -p "$nl"
resolve_dir -L "$nl"; r3="$RESOLVE_DIR_OUT"; [ "$r3" = "$nl" ] && ok "resolve_dir keeps a trailing newline when captured with the sentinel" || no "resolve_dir newline"
# resolve_link_chain with a relative 2-hop chain (readlink without -f)
mkdir -p "$W/chain/d1/d2"; printf 't\n' > "$W/chain/d1/d2/target"; ln -s ../d1/d2/target "$W/chain/d1/hop2"; ln -s d1/hop2 "$W/chain/hop1"
if resolve_link_chain "$W/chain/hop1" && [ -f "$LINK_CHAIN_OUT" ] && [ "$(cat "$LINK_CHAIN_OUT")" = "t" ]; then ok "resolve_link_chain: relative 2-hop chain resolved with plain readlink"; else no "resolve_link_chain err=$LINK_CHAIN_ERR out=$LINK_CHAIN_OUT"; fi
# mount table on this platform
MOUNT_TABLE_LOADED=0; MOUNT_POINTS=(); MOUNT_TYPES=(); load_mount_table
[ "${#MOUNT_POINTS[@]}" -gt 0 ] && ok "load_mount_table: ${#MOUNT_POINTS[@]} mounts parsed (root type: $(fs_type_of / || echo '?'))" || no "load_mount_table parsed nothing on this platform"
info "network/pseudo mount points that will be excluded: $(get_excluded_mounts | tr '\n' ' ')"
# link_skip indirect increment (Bash 3.2 arithmetic by name)
LINKS_SKIPPED=0; LINKS_DUP=0; link_skip LINKS_DUP debug "x"; [ "$LINKS_SKIPPED" -eq 1 ] && [ "$LINKS_DUP" -eq 1 ] && ok "link_skip increments by variable name" || no "link_skip"
# sanitizer + urlencode
[ "$(sanitize_filename_for_multipart 'a,b;c"d\e')" = 'a_b_c_d_e' ] && ok "multipart filename sanitizer" || no "sanitizer"
[ "$(urlencode 'a b/ü')" = 'a%20b%2F%C3%BC' ] && ok "urlencode (od/tr based)" || no "urlencode -> $(urlencode 'a b/ü')"

printf '\n=== find semantics on this platform ===\n'
mkdir -p "$W/fs"; head -c 2048 /dev/zero > "$W/fs/eq.bin"; head -c 2049 /dev/zero > "$W/fs/over.bin"; : > "$W/fs/empty"
n="$(find "$W/fs" -type f -size -2049c -print | grep -c .)"; [ "$n" -eq 2 ] && ok "-size -Nc is strict bytes (2048 kept, 2049 dropped, empty kept)" || no "-size -Nc matched $n of 3"
touch -t 200001010000 "$W/fs/old.bin"; n="$(find "$W/fs" -type f -mtime -1 -print | grep -c .)"; [ "$n" -eq 3 ] && ok "-mtime -1 keeps today's files and drops an old one" || no "-mtime -1 matched $n of 3 today's files — BSD find rounds the age UP, so --max-age N covers N-1 days here (the collector's age gate prefers -mmin/-cmin and falls back to -mtime/-ctime)"
n="$(find "$W/fs" -type f -mmin -1440 -print | grep -c .)"; [ "$n" -eq 3 ] && ok "-mmin -1440 keeps today's files (portable alternative for the age gate)" || no "-mmin -1440 matched $n of 3"
printf 'x\n' > "$W/fs/with"$'\n'"newline"; n=0; while IFS= read -r -d '' e; do n=$((n+1)); done < <(find "$W/fs" -type f -print0); [ "$n" -eq 5 ] && ok "-print0 + read -d '' round-trips a newline in a name" || no "-print0 round trip: $n"
mkdir -p "$W/fs/Dropbox/inner/Dropbox"; escape_find_glob "$W/fs/Dropbox"
n="$(find "$W/fs/Dropbox" -type d ! -path "$FIND_GLOB_OUT" -iname dropbox -prune -print | grep -c .)"; [ "$n" -eq 1 ] && ok "'! -path ROOT' keeps the root out of a prune match while nested matches are found" || no "root-exclusion form matched $n"
ln -s "$W/fs/eq.bin" "$W/fs/flink"; n="$(find "$W/fs" -type l -print | grep -c .)"; [ "$n" -eq 1 ] && ok "-type l enumerates a symlink as an entry" || no "-type l: $n"
n="$(find "$W/lnk" -type f -print | grep -c .)"; [ "$n" -eq 0 ] && ok "a symlinked ROOT is not descended (physical walk)" || no "symlinked root descended ($n files)"
info "trailing-slash root 'find link/' descends on this find: $([ "$(find "$W/lnk/" -type d -print | grep -c .)" -gt 1 ] && echo yes || echo no) (collector strips the slash, so it never relies on this)"

printf '\n=== collector dry-run over a fixture ===\n'
F="$W/fixture"; mkdir -p "$F/plain" "$F/g[1]/Dropbox/.dropbox.cache" "$F/cases/Dropbox" "$F/Users/u/Library/CloudStorage/OneDrive-X"
printf 'p\n' > "$F/plain/p.txt"; printf 'k\n' > "$F/g[1]/k.txt"; printf 's\n' > "$F/g[1]/Dropbox/synced.txt"; printf 'n\n' > "$F/cases/Dropbox/nameonly.txt"
printf 'c\n' > "$F/Users/u/Library/CloudStorage/OneDrive-X/c.txt"; head -c 3000 /dev/zero > "$F/plain/big.bin"
mkdir -p "$W/outside"; printf 'o\n' > "$W/outside/o.txt"; ln -s "$W/outside/o.txt" "$F/plain/flink"; ln -s "$W/outside" "$F/plain/dlink"; ln -s /nonexistent "$F/plain/dangling"
DRY="--dry-run --no-progress --server x --ssl -k --max-age 0 --max-size 2"
out="$(bash "$COLLECTOR" $DRY --log-file "$F/g[1]/run.log" --dir "$F" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "dry-run exit 0" || no "dry-run exit $rc"
printf '%s\n' "$out" | grep -q "would submit '$F/plain/p.txt'" && ok "plain file collected" || no "plain file missing"
printf '%s\n' "$out" | grep -q "would submit '$F/plain/big.bin'" && no "3000-byte file not filtered by --max-size 2" || ok "--max-size enforced by find on this platform"
printf '%s\n' "$out" | grep -q "would submit '$F/g\[1\]/run.log'" && no "own log file collected (glob escaping failed on this find)" || ok "own log file excluded under a '[' path"
printf '%s\n' "$out" | grep -q "Excluding cloud storage folder '$F/g\[1\]/Dropbox'" && ! printf '%s\n' "$out" | grep -q "would submit '$F/g\[1\]/Dropbox/synced.txt'" && ok "proven Dropbox pruned (marker evidence)" || no "proven Dropbox handling"
printf '%s\n' "$out" | grep -q "would submit '$F/cases/Dropbox/nameonly.txt'" && ok "name-only Dropbox collected" || no "name-only Dropbox pruned"
printf '%s\n' "$out" | grep -q "would submit '$F/Users/u/Library/CloudStorage/OneDrive-X/c.txt'" && no "CloudStorage collected when reached from above" || ok "Library/CloudStorage pruned when reached from above"
[ "$(g "$out" links_seen)" = "3" ] && [ "$(g "$out" links_collected)" = "0" ] && ok "3 symlinks seen, none followed by default" || no "links_seen=$(g "$out" links_seen) links_collected=$(g "$out" links_collected)"
printf '%s\n' "$out" | grep -q 'symbolic link(s) were not followed' && ok "not-followed hint shown for an operator-scoped run" || no "hint missing"
out="$(bash "$COLLECTOR" $DRY --no-log-file --follow-symlinks --dir "$F" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -q "Collected via symlink: '$F/plain/flink' -> '" && ok "--follow-symlinks: file link collected under its resolved path" || no "file link not collected"
printf '%s\n' "$out" | grep -q "Symlinked directory '$F/plain/dlink' not followed" && ok "--follow-symlinks: directory link surfaced, not traversed" || no "dir link handling"
printf '%s\n' "$out" | grep -q 'Symlink breakdown: dir_surfaced=1 in_scope=0 dup=0 fs_refused=0 self_excluded=0 filtered_size=0 filtered_age=0 dangling=1' && ok "breakdown line reconciles (dir_surfaced=1 dangling=1)" || no "breakdown: $(printf '%s\n' "$out" | grep 'Symlink breakdown')"
out="$(bash "$COLLECTOR" $DRY --no-log-file --dir "$W/lnk" 2>&1)"
printf '%s\n' "$out" | grep -q "is a symbolic link; not following it" && ok "symlinked --dir root reported, not followed" || no "symlinked root hint"
out="$(bash "$COLLECTOR" $DRY --no-log-file --dir "$F/Users/u/Library/CloudStorage" 2>&1)"
[ "$(g "$out" discovered)" = "1" ] && printf '%s\n' "$out" | grep -q 'collecting as requested' && ok "explicit --dir …/Library/CloudStorage collected with a warning" || no "explicit CloudStorage discovered=$(g "$out" discovered)"
out="$(bash "$COLLECTOR" $DRY --no-log-file --dir "$F" --max-size 99999999999999999999 2>&1)"; rc=$?; [ "$rc" -eq 2 ] && ok "oversized --max-size is a usage error (exit 2)" || no "oversized bound rc=$rc"
if [ -L /tmp ] || [ -L /var ]; then
    # macOS: /tmp -> /private/tmp. The BUILT-IN default must be resolved and scanned (F29); the
    # same path named with --dir must not be followed. Simulated with a copy whose default list is /tmp.
    sed "s|^SCAN_FOLDERS=(.*|SCAN_FOLDERS=('/tmp')|" "$COLLECTOR" > "$W/sim.sh"
    out="$(bash "$W/sim.sh" --dry-run --no-log-file --no-progress --server x --ssl -k --max-age 1 --debug 2>&1)"
    printf '%s\n' "$out" | grep -q "Default scan directory '/tmp' resolves to '/private/tmp'" && ok "macOS: built-in default /tmp resolved to /private/tmp and scanned" || no "macOS default alias not resolved: $(printf '%s\n' "$out" | grep -E 'Scanning|Skipping' | head -2)"
    out="$(bash "$COLLECTOR" --dry-run --no-log-file --no-progress --server x --ssl -k --max-age 1 --dir /tmp 2>&1)"
    printf '%s\n' "$out" | grep -q "'/tmp' is a symbolic link; not following it" && ok "macOS: --dir /tmp (operator-named alias) reported, not followed" || no "macOS: --dir /tmp handling"
else
    info "/tmp and /var are not symlinks here; the macOS platform-alias check was skipped"
fi

# --- Audit III portability probes (macOS/BSD hand-off) --------------------------------
printf '\n=== audit III probes ===\n'
# III-01: an own artifact reached through a symlinked TMPDIR must still be pruned, whatever the
# root's spelling. macOS shape: TMPDIR under /var/folders with /var -> /private/var.
mkdir -p "$W/pa/real/sub/x"; ln -s real "$W/pa/link"; ln -s real "$W/pa/link2"; printf s > "$W/pa/real/sub/f.txt"
out="$(TMPDIR="$W/pa/link/sub/x" bash "$COLLECTOR" $DRY --no-log-file --dir "$W/pa/link2/sub" 2>&1)"
printf '%s\n' "$out" | grep -q 'thunderstorm.work' \
    && no "III-01 own work directory collected under a third spelling" \
    || ok "III-01 own work directory pruned under every root spelling"
# III-02: a root spelled '//' must not defeat the absolute prunes.
if [ "$(cd // 2>/dev/null && pwd)" = "//" ]; then
    out="$(bash "$COLLECTOR" $DRY --no-log-file --max-size 1 --max-age 1 --dir "/$W/pa" 2>&1)"
    printf '%s\n' "$out" | grep -q "would submit '//" \
        && no "III-02 '//' root leaks double-slash paths (prunes inert)" \
        || ok "III-02 '//' root normalised to a single slash"
else
    info "III-02 this platform collapses // to / already ($(cd // 2>/dev/null && pwd))"
fi
# III-10: a directory literally named '-'.
( cd "$W" && mkdir -- - 2>/dev/null && printf d > ./-/d.txt
  out="$(bash "$COLLECTOR" $DRY --no-log-file -- - 2>&1)"
  printf '%s\n' "$out" | grep -q "would submit '$W/-/d.txt'" \
      && ok "III-10 '-- -' scans the directory named '-'" \
      || no "III-10 '-- -' mis-handled (OLDPWD echo?)" )
# III-08: on macOS/BSD there is no /proc/mounts, so the mount(8) parser runs for real here.
info "III-08 first mount(8) line on this platform: $(mount 2>/dev/null | head -1)"
MOUNT_TABLE_LOADED=0; MOUNT_POINTS=(); MOUNT_TYPES=(); load_mount_table
rt="$(fs_type_of / 2>/dev/null || printf '?')"
case "$rt" in ''|'?'|rw|ro) no "III-08 mount(8) parser produced no usable root filesystem type ('$rt') — paste the line above" ;;
              *) ok "III-08 mount(8) parser produced a plausible root filesystem type ('$rt')" ;; esac
# III-16: case-insensitive volumes (macOS default) cannot be deduplicated by spelling.
info "III-16 case-insensitive filesystem: run '--dir $W/pa/real --dir $(printf '%s' "$W/pa/real" | tr 'a-z' 'A-Z')' and report whether discovered= doubles"

printf '\n===== %s passed, %s failed ===== (bash %s, %s)\n' "$p" "$f" "$BASH_VERSION" "$(uname -sm 2>/dev/null)"
exit "$f"
