#!/usr/bin/env bash
# Directory layout tests: ~/compress/in, out and work each as a regular
# directory or as a symlink to a directory on another "disk", in all 8
# combinations (no ffmpeg / tmux needed; df / tmux / ffprobe are stubbed
# where used).
#
#   bash ~/compress/work/tests/dir_layout_tests.sh
#
# Covers:
#   1. file discovery through a symlinked root (video_files_in_dir,
#      series_dirs, media_files_recursive), symlink chains, relative
#      links, trailing slash
#   2. compress_dir_ready never replaces anything: valid symlink kept,
#      broken symlink / symlink to a file / regular file refused and left
#      unchanged, missing directory created, read-only refused, pinned
#      location (paths.conf) checked, the git-replaced work/ detected
#   3. for every in/out/work combination: the movie and series menus
#      start and list the source, each path keeps its type and target
#   4. for every combination: the job runtime writes its .part to out/
#      and its intermediates below work/logs/ (on the symlink target);
#      a failed item deletes its own .part and the large video
#      intermediates, keeps the small diagnostics, never touches a
#      foreign .part, unrelated files or a symlink's target
#   5. for every combination: the disk-space preflight sees the
#      filesystem each path really is on (the incident: work/ silently on
#      the small root disk -> refused before the encode), same-filesystem
#      needs added, retry shortage asks, warn override, estimates
#   6. progress-check.sh finds ended jobs with work/ as a directory and
#      as a symlink
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${1:-}" == --keep ]]; then
    echo "Test files kept in $T"
else
    trap 'chmod -R u+w -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

# symlinks must be real symlinks (Git Bash without native symlinks copies)
ln -s "$T" "$T/.probe" 2>/dev/null
if [[ ! -L "$T/.probe" ]]; then
    echo "SKIP: this system does not create real symlinks (run on Linux / WSL)."
    exit 0
fi
rm -f -- "$T/.probe"

source "$SRC_WORK/lib/media_probe.sh"
source "$SRC_WORK/lib/bitrate.sh"
source "$SRC_WORK/lib/fs_guard.sh"

G=1073741824

# kind PATH  ->  link | dir | file | broken | none
kind() {
    if [[ -L "$1" ]]; then [[ -e "$1" ]] && echo link || echo broken
    elif [[ -d "$1" ]]; then echo dir
    elif [[ -e "$1" ]]; then echo file
    else echo none; fi
}

# ------------------------------------------------------------
echo "== 1 discovery through a symlinked root"
D="$T/d1"
mkdir -p "$D/disk2/in/Show" "$D/disk2/deep" "$D/home/compress" "$D/disk3"
printf m > "$D/disk2/in/Movie.mkv"
printf e > "$D/disk2/in/Show/S01E01.mkv"
ln -s "$D/disk2/in" "$D/home/compress/in"
ln -s ../disk2/in "$D/disk3/rel-in"                       # relative link
ln -s "$D/home/compress/in" "$D/disk3/chain-in"           # link -> link -> dir
R="$D/home/compress/in"
eq    "movies through symlinked in/"         "$(video_files_in_dir "$R")" "$R/Movie.mkv"
eq    "movies, trailing slash"               "$(video_files_in_dir "$R/")" "$R/Movie.mkv"
eq    "series folder through symlinked in/"  "$(series_dirs "$R")" "$R/Show"
eq    "episodes through symlinked in/"       "$(video_files_in_dir "$R/Show")" "$R/Show/S01E01.mkv"
eq    "recursive through symlinked in/"      "$(media_files_recursive "$R" | tr '\0' '\n' | wc -l | tr -d ' ')" 2
eq    "relative root symlink"                "$(video_files_in_dir "$D/disk3/rel-in")" "$D/disk3/rel-in/Movie.mkv"
eq    "chained root symlink"                 "$(video_files_in_dir "$D/disk3/chain-in")" "$D/disk3/chain-in/Movie.mkv"
eq    "no warnings for a symlinked root"     "$(video_files_in_dir "$R" 2>&1 >/dev/null)" ""
check "root symlinks untouched"              "[[ -L '$R' && \"\$(readlink '$R')\" == '$D/disk2/in' && -L '$D/disk3/rel-in' ]]"
ln -s "$D/nowhere" "$D/home/compress/gone"
eq    "broken root symlink: nothing, no error" "$(video_files_in_dir "$D/home/compress/gone" 2>&1; echo "rc=$?")" "rc=0"

# ------------------------------------------------------------
echo "== 2 compress_dir_ready never replaces anything"
D="$T/d2"
mkdir -p "$D/b" "$D/disk2/work"
printf keep > "$D/disk2/work/marker"
ln -s "$D/disk2/work" "$D/b/work"
compress_dir_ready "$D/b/work" work rw 2> "$D/e"; rc=$?
eq    "valid symlink accepted"             "$rc" 0
check "valid symlink kept as is"           "[[ -L '$D/b/work' && \"\$(readlink '$D/b/work')\" == '$D/disk2/work' && \"\$(cat '$D/disk2/work/marker')\" == keep ]]"
eq    "no probe file left behind"          "$(ls -A "$D/disk2/work")" marker

ln -s "$D/disk2/unmounted" "$D/b/out"
compress_dir_ready "$D/b/out" out rw 2> "$D/e"; rc=$?
eq    "broken symlink refused"             "$rc" 1
check "broken symlink explained"           "grep -q 'broken symlink' '$D/e'"
check "broken symlink left unchanged"      "[[ \$(kind '$D/b/out') == broken && ! -e '$D/disk2/unmounted' ]]"

printf x > "$D/disk2/file"
ln -s "$D/disk2/file" "$D/b/in"
compress_dir_ready "$D/b/in" in 2> "$D/e"; rc=$?
eq    "symlink to a file refused"          "$rc" 1
check "symlink to a file kept"             "[[ -L '$D/b/in' && \"\$(cat '$D/disk2/file')\" == x ]]"

printf data > "$D/b/plain"
compress_dir_ready "$D/b/plain" in 2> /dev/null; rc=$?
eq    "regular file refused"               "$rc" 1
eq    "regular file unchanged"             "$(cat "$D/b/plain")" data

compress_dir_ready "$D/b/new" in; rc=$?
check "missing directory created"          "[[ $rc == 0 && \$(kind '$D/b/new') == dir ]]"

mkdir -p "$D/ro"; chmod a-w "$D/ro"
if ! ( : > "$D/ro/t" ) 2>/dev/null; then
    compress_dir_ready "$D/ro" out rw 2> "$D/e"; rc=$?
    eq    "read-only directory refused"    "$rc" 1
    check "read-only explained"            "grep -q 'not writable' '$D/e'"
else
    echo "  skip  read-only directory (running as root)"
    rm -f -- "$D/ro/t"
fi
chmod u+w "$D/ro"

# pins
printf '# pins\nwork=%s\n' "$D/disk2/work" > "$D/b/paths.conf"
compress_dir_ready "$D/b/work" work 2> "$D/e"; rc=$?
eq    "pinned symlink at its place"        "$rc" 0
# what `git checkout -- work` / `git restore work` does to a symlinked work/
mkdir -p "$D/c/work/lib"; cp "$D/b/paths.conf" "$D/c/paths.conf"
compress_dir_ready "$D/c/work" work 2> "$D/e"; rc=$?
eq    "git-replaced work/ detected"        "$rc" 1
check "git replacement explained"          "grep -q 'now a regular directory' '$D/e' && grep -q 'ln -sfn' '$D/e'"
check "replaced work/ not touched"         "[[ \$(kind '$D/c/work') == dir && -d '$D/c/work/lib' ]]"
printf 'work=%s\n' "$D/disk2/unmounted" > "$D/c/paths.conf"
compress_dir_ready "$D/c/work" work 2> "$D/e"; rc=$?
eq    "pinned target missing refused"      "$rc" 1
compress_dirs_init "$D/b" new work:rw 2> /dev/null; rc=$?
eq    "compress_dirs_init all fine"        "$rc" 0
compress_dirs_init "$D/b" out work:rw 2> "$D/e"; rc=$?
eq    "compress_dirs_init reports a bad one" "$rc" 1

# ------------------------------------------------------------
echo "== 2b version detection with a symlinked work/"
if command -v git >/dev/null 2>&1; then
    D="$T/d2b"
    mkdir -p "$D/compress/work/lib" "$D/disk2"
    cp "$SRC_WORK/lib/encode_common.sh" "$SRC_WORK/lib/ui.sh" "$D/compress/work/lib/"
    git -C "$D/compress" init -q 2>/dev/null
    git -C "$D/compress" add -A >/dev/null 2>&1
    git -C "$D/compress" -c user.name=t -c user.email=t@t commit -qm v1 >/dev/null 2>&1
    sha=$(git -C "$D/compress" rev-parse --short HEAD)
    v=$(bash -c 'source "$1/lib/encode_common.sh" >/dev/null 2>&1; compresser_version' _ "$D/compress/work")
    eq    "version with a real work/"           "$v" "$sha"
    mv "$D/compress/work" "$D/disk2/work"
    ln -s "$D/disk2/work" "$D/compress/work"
    v=$(bash -c 'source "$1/lib/encode_common.sh" >/dev/null 2>&1; compresser_version' _ "$D/compress/work")
    # git sees the tracked files behind the symlink as missing: dirty
    eq    "version through a symlinked work/"   "$v" "$sha-dirty"
else
    echo "  skip  version detection (no git)"
fi

# ------------------------------------------------------------
# layout HOME IN OUT WORK  ->  ~/compress with each of in/out/work a
# real directory ("dir") or a symlink ("link") to $HOME/../disk2/NAME
layout() {
    local h="$1" n t
    mkdir -p "$h/compress" "$h/../disk2"
    shift
    for n in in out work; do
        t="$1"; shift
        if [[ "$t" == link ]]; then
            mkdir -p "$h/../disk2/$n"
            ln -s "$(cd "$h/../disk2/$n" && pwd)" "$h/compress/$n"
        else
            mkdir -p "$h/compress/$n"
        fi
    done
    cp -r "$SRC_WORK/lib" "$h/compress/work/"
    cp "$SRC_WORK/movie_compress.sh" "$SRC_WORK/series_compress.sh" "$h/compress/work/"
    cp "$ROOT/progress-check.sh" "$h/compress/"
}

# df stub: the filesystem of a path is chosen by the longest prefix of
# its resolved path in $DF_MAP ("PREFIX FS MOUNT AVAIL_KIB" lines)
mkdir -p "$T/stub"
cat > "$T/stub/df" <<'EOF'
#!/usr/bin/env bash
for a; do p="$a"; done
r=$(readlink -f -- "$p")
best="" line=""
while read -r pre fs mnt kib; do
    [[ "$r" == "$pre" || "$r" == "$pre"/* ]] || continue
    (( ${#pre} > ${#best} )) && { best="$pre"; line="$fs $kib $mnt"; }
done < "$DF_MAP"
[[ -n "$line" ]] || exit 1
read -r fs kib mnt <<< "$line"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "$fs 999999999 1 $kib 1% $mnt"
EOF
# tmux stub: no server, no sessions
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stub/tmux"
# ffprobe stub: nothing known (durations empty)
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stub/ffprobe"
chmod +x "$T/stub/df" "$T/stub/tmux" "$T/stub/ffprobe"

for IN_T in dir link; do
for OUT_T in dir link; do
for WORK_T in dir link; do
    C="in=$IN_T out=$OUT_T work=$WORK_T"
    echo "== 3-6 $C"
    B="$T/c-$IN_T-$OUT_T-$WORK_T"
    H="$B/home"
    layout "$H" "$IN_T" "$OUT_T" "$WORK_T"
    CB="$H/compress"
    before=$(for n in in out work; do printf '%s:%s:%s ' "$n" "$(kind "$CB/$n")" "$(readlink "$CB/$n")"; done)
    mkdir -p "$CB/in/Show"
    printf m > "$CB/in/Film.mkv"
    printf e > "$CB/in/Show/S01E01.mkv"

    # ---- 3 menus start and list the source
    HOME="$H" PATH="$T/stub:$PATH" bash "$CB/work/movie_compress.sh" < /dev/null > "$B/movie.out" 2>&1
    check "$C: movie menu lists the movie"     "grep -q ' 1) Film.mkv' '$B/movie.out' && ! grep -q 'No movies found' '$B/movie.out'"
    HOME="$H" PATH="$T/stub:$PATH" bash "$CB/work/series_compress.sh" < /dev/null > "$B/series.out" 2>&1
    check "$C: series menu lists the series"   "grep -q '1) Show \[1 episode\]' '$B/series.out'"

    # ---- 4 job runtime: .part in out/, intermediates in work/logs/
    printf precious > "$B/precious"
    printf other > "$CB/out/Other.mkv.part"           # another job's encode
    mkdir -p "$CB/work/logs"; printf u > "$CB/work/logs/unrelated.txt"
    (
        export HOME="$H" PATH="$T/stub:$PATH"
        WORK_DIR="$CB/work"
        cd "$B" || exit 1
        for l in media_probe media_stats bitrate encode_common hdr_dovi job_runtime; do
            source "$WORK_DIR/lib/$l.sh"
        done
        {
            emit_job_header c1 movie 1
            cat <<EOF
if item_begin 1 $(printf %q "$CB/in/Film.mkv") $(printf %q "$CB/out/Film HEVC Base.mkv") Base 0 ""; then
    printf enc > "\$ITEM_PART"
    printf v > "\$ITEM_TMP/video.hevc"; printf w > "\$ITEM_TMP/video_dv.mkv"
    printf r > "\$ITEM_TMP/source.rpu"; printf l > "\$ITEM_TMP/dovi_tool.log"
    ln -s $(printf %q "$B/precious") "\$ITEM_TMP/video_dv.hevc"
    printf '%s\n' "\$ITEM_PART" > $(printf %q "$B/part")
    printf '%s\n' "\$ITEM_TMP" > $(printf %q "$B/tmp")
    item_part_complete && printf '%s\n' "\$(ls -A "\$ITEM_TMP" | tr '\n' ' ')" > $(printf %q "$B/after_complete")
    item_failed "No space left on device"
fi
EOF
            emit_job_footer
        } > "$WORK_DIR/c1.sh"
        bash "$WORK_DIR/c1.sh" < /dev/null > "$B/job.out" 2>&1
    )
    part=$(cat "$B/part" 2>/dev/null); itmp=$(cat "$B/tmp" 2>/dev/null)
    eq    "$C: .part written in out/"               "$part" "$CB/out/Film HEVC Base.mkv.part"
    check "$C: item tmp below work/logs/"           "[[ '$itmp' == '$CB/work/logs/'c1-*/item-1.tmp ]]"
    if [[ "$WORK_T" == link ]]; then
        check "$C: intermediates on the work disk"  "[[ \"\$(readlink -f '$itmp')\" == '$(cd "$B/disk2/work" && pwd)'/logs/* ]]"
    fi
    eq    "$C: complete encode drops video intermediates" "$(cat "$B/after_complete" 2>/dev/null)" "dovi_tool.log source.rpu "
    check "$C: failed item removed its .part"       "[[ ! -e '$part' ]]"
    check "$C: diagnostics kept"                    "[[ -f '$itmp/source.rpu' && -f '$itmp/dovi_tool.log' && ! -e '$itmp/video.hevc' && ! -e '$itmp/video_dv.mkv' ]]"
    eq    "$C: symlink target never touched"        "$(cat "$B/precious")" precious
    eq    "$C: foreign .part kept"                  "$(cat "$CB/out/Other.mkv.part")" other
    eq    "$C: unrelated work file kept"            "$(cat "$CB/work/logs/unrelated.txt")" u
    check "$C: failure recorded"                    "grep -q 'No space left on device' '$CB/work/logs/'c1-*/failed.tsv"
    check "$C: job script moved to its logs"        "[[ ! -e '$CB/work/c1.sh' && -f \$(echo '$CB/work/logs/'c1-*/job.sh) ]]"
    eq    "$C: in/out/work unchanged"               "$(for n in in out work; do printf '%s:%s:%s ' "$n" "$(kind "$CB/$n")" "$(readlink "$CB/$n")"; done)" "$before"

    # ---- 5 preflight: home disk 10 GiB free, disk2 500 GiB free;
    # a Dolby Vision movie: 20 GiB output, 2 x 21 GiB intermediates
    hreal=$(cd "$H" && pwd -P); dreal=$(cd "$B/disk2" && pwd -P)
    printf '%s rootfs / %s\n%s disk2 /dev/disk2 %s\n' \
        "$hreal" $((10 * 1024 * 1024)) "$dreal" $((500 * 1024 * 1024)) > "$B/df.map"
    out_b=$((20 * G)); work_b=$(item_work_estimate 1 $((21 * G)))
    DF_MAP="$B/df.map" PATH="$T/stub:$PATH" \
        compress_space_preflight "$CB/out" "$out_b" "$out_b" "$CB/work" "$work_b" > "$B/pf.out" 2>&1; rc=$?
    want=1; [[ "$OUT_T" == link && "$WORK_T" == link ]] && want=0
    eq    "$C: preflight verdict"                   "$rc" "$want"
    if [[ "$WORK_T" == dir ]]; then
        check "$C: work/ on the root disk reported" "grep -q 'NOT ENOUGH SPACE on /:' '$B/pf.out'"
    fi
    if [[ "$OUT_T" == "$WORK_T" ]]; then
        check "$C: same filesystem: needs added"    "grep -q 'same filesystem' '$B/pf.out'"
    else
        check "$C: separate filesystems listed"     "grep -q '^  out ' '$B/pf.out' && grep -q '^  work ' '$B/pf.out' && ! grep -q 'same filesystem' '$B/pf.out'"
    fi
    eq    "$C: preflight left no files"             "$(ls -A "$CB/out" | grep -c write-test)" 0

    # ---- 6 progress-check finds an ended job
    printf 'version=1\nsession=c7\ntype=movie\nstatus=finished\nitem=1\nitems=1\nok=1\nfailed=0\nupdated=%s\nstarted=%s\n' \
        "$(date +%s)" "$(date +%s)" > "$CB/work/c7.state"
    HOME="$H" PATH="$T/stub:$PATH" bash "$CB/progress-check.sh" < /dev/null > "$B/pc.out" 2>&1
    check "$C: progress-check lists the ended job"  "grep -q '^c7 .*finished: 1/1 ok' '$B/pc.out'"
done
done
done

# ------------------------------------------------------------
echo "== 5 preflight details"
D="$T/d5"
mkdir -p "$D/out" "$D/work"
dreal=$(cd "$D" && pwd -P)
printf '%s/out fsA /a %s\n%s/work fsB /b %s\n' "$dreal" $((30 * 1024 * 1024)) "$dreal" $((100 * 1024 * 1024)) > "$D/map"
pf() { DF_MAP="$D/map" PATH="$T/stub:$PATH" compress_space_preflight "$D/out" "$@" > "$D/pf.out" 2>&1; echo $?; }
eq "enough everywhere"                       "$(pf $((10 * G)) $((20 * G)) "$D/work" $((40 * G)))" 0
eq "retry attempts may not fit -> 2"         "$(pf $((20 * G)) $((40 * G)) "$D/work" 0)" 2
check "retry shortage warned"                "grep -q 'may run out of space if CRF retry' '$D/pf.out'"
eq "outputs do not fit -> 1"                 "$(pf $((40 * G)) $((40 * G)) "$D/work" 0)" 1
eq "warn override -> 0"                      "$(COMPRESS_SPACE_CHECK=warn pf $((40 * G)) $((40 * G)) "$D/work" 0)" 0
printf '%s fsA /a %s\n' "$dreal" $((30 * 1024 * 1024)) > "$D/map"
eq "same filesystem: 20 + 15 GiB > 30 GiB"   "$(pf $((20 * G)) $((20 * G)) "$D/work" $((15 * G)))" 1
eq "df failing -> 1"                         "$(DF_MAP=/nonexistent PATH="$T/stub:$PATH" compress_space_preflight "$D/out" 1 1 "$D/work" 0 >/dev/null 2>&1; echo $?)" 1
eq "confirm: retry shortage, answer n"       "$(printf 'n\n' | DF_MAP="$D/map" PATH="$T/stub:$PATH" compress_space_confirm "$D/out" $((20 * G)) $((40 * G)) "$D/work" 0 >/dev/null 2>&1; echo $?)" 1
eq "confirm: retry shortage, answer y"       "$(printf 'y\n' | DF_MAP="$D/map" PATH="$T/stub:$PATH" compress_space_confirm "$D/out" $((20 * G)) $((40 * G)) "$D/work" 0 >/dev/null 2>&1; echo $?)" 0
eq "output estimate: source - video + est"   "$(item_output_estimate $((10 * G)) $((8 * G)) $((3 * G)))" $((5 * G))
eq "output estimate: copy = source"          "$(item_output_estimate $((10 * G)) $((8 * G)) "")" $((10 * G))
eq "output estimate: video size unknown"     "$(item_output_estimate $((10 * G)) "" $((3 * G)))" $((10 * G))
eq "work estimate: DV keeps two copies"      "$(item_work_estimate 1 $((21 * G)))" $((42 * G))
eq "work estimate: no DV"                    "$(item_work_estimate 0 $((21 * G)))" 0
eq "bytes_sum / bytes_max"                   "$(bytes_sum 1 2 x 3) $(bytes_max 1 5 x 3)" "6 5"

# work/ a real directory (git-managed), only work/logs/ on the big disk
mkdir -p "$D/big/logs" "$D/w2"
ln -s "$D/big/logs" "$D/w2/logs"
printf '%s/out fsA /a %s\n%s/w2 fsA /a %s\n%s/big fsB /big %s\n' "$dreal" $((30 * 1024 * 1024)) \
    "$dreal" $((30 * 1024 * 1024)) "$dreal" $((500 * 1024 * 1024)) > "$D/map"
eq "work/logs symlink: its disk is checked"  "$(pf $((20 * G)) $((20 * G)) "$D/w2" $((42 * G)))" 0
check "work/logs symlink: shown"             "grep -q '^  work  $dreal/big/logs (filesystem /big)' '$D/pf.out'"
rm -f "$D/w2/logs"; ln -s "$D/big/unmounted" "$D/w2/logs"
eq "work/logs broken symlink refused"        "$(pf 1 1 "$D/w2" 0)" 1
check "work/logs broken symlink kept"        "[[ \$(kind '$D/w2/logs') == broken ]]"

echo
echo "dir_layout_tests: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
