#!/usr/bin/env bash
# Multi-season series tests (Jellyfin-style layouts):
#
#   1. discovery: nested season folders, show-root files + seasons,
#      extras folders ignored, natural order (specials first), symlinked
#      season folders, flat folders unchanged (media_probe.sh
#      series_dirs / series_season_groups)
#   2. season selection parsing ("1,3,5-7", invalid input)
#   3. per-season state (no value leaks into another season), labels
#   4. output paths mirror in/, find_source_for_output with season folders
#   5. series menu end to end with stand-ins (ffprobe / ffmpeg / tmux):
#      season prompt, per-season compatibility exclusion, one CRF per
#      season, compact summary, job with one season batch per season;
#      flat folders: old output and job format
#   6. job runtime: two seasons in one job are separate season batches
#      (a retry in one never re-encodes the other); job scripts without
#      season markers run as generated
#   7. progress-check.sh: one queue row per season (-v: every episode)
#   8. verify.sh: path scope (Location from the path), --brief, grouped
#      summary (season header, one line per episode, totals)
#
#   bash ~/compress/work/tests/series_seasons_tests.sh
#
# Seconds, no ffmpeg needed: every probe / encode is a stand-in.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${SEASONS_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE PROGRESS_VERBOSE SERIES_CRF_SHARED
G=1073741824
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }

for l in ui media_probe naming series_seasons; do
    source "$SRC_WORK/lib/$l.sh"
done

# ------------------------------------------------------------
echo "== 1 discovery"

D="$T/disc"
I="$D/in"
mk() { mkdir -p "$(dirname "$1")"; printf 'x\n' > "$1"; }
C="$I/Columbo (1968)"
mk "$C/Season 00 - Specials/Columbo S00E01.mkv"
mk "$C/Season 01/Columbo S01E01.mkv"
mk "$C/Season 01/Columbo S01E02.mkv"
mk "$C/Season 2/Columbo S02E01.mkv"
mk "$C/Season 10/Columbo S10E01.mkv"
mk "$C/Season 10/Columbo S10E02.mp4"
mk "$C/Extras/Making of.mkv"
mk "$C/Season 01/Featurettes/Interview.mkv"
mk "$C/BEHIND THE SCENES/b.mkv"
mk "$C/theme-music/t.mkv"
mk "$C/Season 01/notes.txt"
ln -s "Season 01" "$C/S1 alias"                       # alias of a season: listed once
mk "$I/Mixed/Mixed Pilot.mkv"
mk "$I/Mixed/Season 01/Mixed S01E01.mkv"
mk "$I/Mixed/Specials/Mixed Special.mkv"
mk "$I/Flat/E01.mkv"
mk "$I/Flat/E02.mkv"
mk "$I/OnlyExtras/Trailers/t.mkv"
mkdir -p "$I/Empty/Season 01"
mk "$D/store/linked-s1/Linked S01E01.mkv"
mk "$I/Linked/Season 02/Linked S02E01.mkv"
ln -s "$D/store/linked-s1" "$I/Linked/Season 01"

names() { local s="$1" g; while IFS= read -r g; do printf '%s|' "$(series_group_name "$s" "$g")"; done; }

eq    "1 series_dirs: nested shows listed, extras-only / empty not" \
    "$(series_dirs "$I" 2>/dev/null | sed "s|$I/||" | tr '\n' '|')" "Columbo (1968)|Flat|Linked|Mixed|"
eq    "1 nested seasons, natural order, specials first, extras ignored" \
    "$(series_season_groups "$C" 2>/dev/null | names "$C")" "Season 00 - Specials|Season 01|Season 2|Season 10|"
eq    "1 show root files + seasons: specials, (root), seasons" \
    "$(series_season_groups "$I/Mixed" | names "$I/Mixed")" "Specials|(root)|Season 01|"
eq    "1 flat folder: one group, the folder itself" \
    "$(series_season_groups "$I/Flat")" "$I/Flat"
eq    "1 flat folder: episodes unchanged"  "$(video_files_in_dir "$I/Flat" | tr '\n' '|')" "$I/Flat/E01.mkv|$I/Flat/E02.mkv|"
eq    "1 symlinked season folder listed under its link name" \
    "$(series_season_groups "$I/Linked" | names "$I/Linked")" "Season 01|Season 02|"
eq    "1 symlinked season folder: episodes through the link" \
    "$(video_files_in_dir "$I/Linked/Season 01")" "$I/Linked/Season 01/Linked S01E01.mkv"
eq    "1 alias of a season folder not listed twice" \
    "$(series_season_groups "$C" 2>/dev/null | grep -c 'Season 01$\|S1 alias$')" "1"
eq    "1 episode count (mp4 included, extras / non-media excluded)" "$(series_episode_count "$C")" "6"
eq    "1 extras-only show: no groups"      "$(series_season_groups "$I/OnlyExtras")" ""
check "1 extras names, any case"           "series_extras_dir 'Behind The Scenes' && series_extras_dir TRAILERS && series_extras_dir theme-music && ! series_extras_dir 'Season 01'"
check "1 specials detection" \
    "series_group_is_specials 'Season 00 - Specials' && series_group_is_specials 'season 0' && series_group_is_specials Specials && ! series_group_is_specials 'Season 01' && ! series_group_is_specials 'Season 10' && ! series_group_is_specials 'Special Ops'"
eq    "1 natural sort: Season 2 < Season 10" \
    "$(printf '%s\n' 'Season 10' 'Season 2' 'Season 1' '(root)' 'Season 00' | series_groups_sort | tr '\n' '|')" "Season 00|(root)|Season 1|Season 2|Season 10|"
ln -s .. "$C/Season 2/loop"
eq    "1 directory loop: groups unchanged, loop warned" \
    "$(series_season_groups "$C" 2> "$T/loop.err" | names "$C")" "Season 00 - Specials|Season 01|Season 2|Season 10|"
check "1 loop warning"                      "grep -q 'circular directory symlink skipped' '$T/loop.err'"
rm -f "$C/Season 2/loop"

# one scan per show, cached: same results as the per-folder scans
mk "$D/store/ep/Columbo S01E09.mkv"
ln -s "$D/store/ep/Columbo S01E09.mkv" "$C/Season 01/Columbo S01E09.mkv"      # symlinked episode
ln -s "Columbo S01E01.mkv" "$C/Season 01/0 alias of E01.mkv"                   # same target: once
ln -s nowhere.mkv "$C/Season 01/Broken.mkv"
series_scan_reset
series_scan_root "$I" 2> "$T/scan.err"
eq    "1 cache: series_scan_root = series_dirs" \
    "$(printf '%s|' "${SERIES_SCAN_DIRS[@]}")" "$(series_dirs "$I" 2>/dev/null | tr '\n' '|')"
check "1 cache: nothing printed while scanning" "[[ ! -s '$T/scan.err' ]]"
ok_all=1
for show in "$C" "$I/Mixed" "$I/Flat" "$I/Linked"; do
    while IFS= read -r g; do
        [[ "$(video_files_in_dir "$g" 2>/dev/null)" == "$(discover_paths "$g" 1 f "${MOVIE_EXTS[@]}" 2>/dev/null | tr '\0' '\n')" ]] || { ok_all=0; echo "    differs: $g"; }
    done < <(series_season_groups "$show" 2>/dev/null)
done
eq    "1 cache: episode lists = uncached per-folder scan (symlinks, aliases)" "$ok_all" 1
eq    "1 cache: symlinked episode once, regular path preferred" \
    "$(video_files_in_dir "$C/Season 01" 2>/dev/null | sed "s|$C/Season 01/||" | tr '\n' '|')" "Columbo S01E01.mkv|Columbo S01E02.mkv|Columbo S01E09.mkv|"
check "1 cache: broken episode link warned on the episode read" \
    "video_files_in_dir '$C/Season 01' 2>&1 >/dev/null | grep -q 'broken symlink skipped: .*Broken.mkv' && [[ -z \"\$(DISCOVERY_QUIET=1 video_files_in_dir '$C/Season 01' 2>&1 >/dev/null)\" ]]"
check "1 cache: broken link warned on the season read" "series_season_groups '$C' 2>&1 >/dev/null | grep -q 'broken symlink skipped: .*Broken.mkv'"
eq    "1 cache: episode count" "$(series_episode_count "$C")" "7"
# the cache is read, not rescanned: a file added now is not seen until reset
mk "$C/Season 01/Columbo S01E10.mkv"
eq    "1 cache: one scan per show (no rescan)" "$(series_episode_count "$C")" "7"
series_scan_reset
eq    "1 cache: series_scan_reset rescans" "$(series_episode_count "$C")" "8"
finds=$( ( series_scan_reset; find() { echo x >> "$T/finds"; command find "$@"; }; : > "$T/finds"
          series_scan "$C"; series_season_groups "$C" >/dev/null 2>&1; series_episode_count "$C" >/dev/null
          wc -l < "$T/finds" ) )
eq    "1 cache: one find for the whole show" "$finds" 1
rm -f "$C/Season 01/Columbo S01E09.mkv" "$C/Season 01/0 alias of E01.mkv" "$C/Season 01/Broken.mkv" "$C/Season 01/Columbo S01E10.mkv"
series_scan_reset

# ------------------------------------------------------------
echo
echo "== 2 season selection"

eq    "2 1,3,5-7"                 "$(season_parse_selection '1,3,5-7' 11 | tr '\n' ' ')" "1 3 5 6 7 "
eq    "2 spaces, duplicates, order" "$(season_parse_selection ' 7, 2-3 ,2 ' 8 | tr '\n' ' ')" "2 3 7 "
eq    "2 single"                  "$(season_parse_selection 4 4)" "4"
for bad_in in "" "0" "12" "3-1" "1,,2" "1," "a" "1-" "-2" "1;2" "2-12"; do
    check "2 invalid '$bad_in' rejected" "! season_parse_selection '$bad_in' 11 > /dev/null"
done

# ------------------------------------------------------------
echo
echo "== 3 per-season state and labels"

season_state_reset
FILES=(a b); CRF=20; GUARD=(1); EP_LABEL=(S01E01 S01E02); CRF_EP_EST[0:20]=5; DV_POLICY=preserve; EP_CEIL_SKIP=(0 1)
season_state_save A
season_state_reset
FILES=(c); CRF=23
season_state_save B
season_state_load A
eq    "3 season A restored"        "${FILES[*]}|$CRF|${GUARD[*]}|${CRF_EP_EST[0:20]}|$DV_POLICY|${EP_CEIL_SKIP[*]}" "a b|20|1|5|preserve|0 1"
season_state_load B
eq    "3 season B: nothing of A"   "${FILES[*]}|$CRF|${GUARD[*]-}|${CRF_EP_EST[0:20]-unset}|$DV_POLICY|${EP_CEIL_SKIP[*]-}" "c|23||unset|none|"
check "3 unknown season"           "! season_state_load C"
loader() { season_state_load A; }
loader
eq    "3 loaded from inside a function: globals" "${FILES[*]}" "a b"

eq    "3 short labels" \
    "$(for n in 'Season 01' 'Season 1' 'Season 00 - Specials' 'Specials' 'S03' 'Series 4' '(root)' 'Season 01/Disc 2' 'Bonus Material Long'; do printf '%s|' "$(season_short_label "$n")"; done)" \
    "S01|S01|S00|SP|S03|S04|root|S01/Disc 2|Bonus Mater~|"
check "3 labels collide across seasons"     "labels_collide \$'E01\nE02' \$'E01\nE03'"
check "3 distinct labels do not collide"    "! labels_collide \$'S01E01\nS01E02' \$'S02E01'"
check "3 duplicates within one season are not a cross-season collision" "! labels_collide \$'X\nX' \$'Y'"
eq    "3 season CRF range"         "$(season_crf_range 20 19 22 20)" "CRF range: 19-22 across 4 seasons (per-season shared CRF)"
eq    "3 no range for equal CRFs"  "$(season_crf_range 20 20)" ""
eq    "3 describe_list folds repeats" "$(describe_list "6 2 2 2 6 ")|$(describe_list "")|$(describe_list "ac3 ")" "6, 2 x3, 6|none|ac3"
eq    "3 word_count"               "$(word_count "6 2 2 ")|$(word_count "")" "3|0"
eq    "3 fit_line: 120 columns"    "$(fit_line "$(printf 'x%.0s' {1..130})" | wc -c)|$(fit_line short)" "120|short"
eq    "3 fit_line: verbose keeps it" "$(COMPRESS_VERBOSE=1 fit_line "$(printf 'x%.0s' {1..130})" | wc -c)" "130"
eq    "3 season status"            "$(season_status_text 0 0 0)|$(season_status_text 1 2 1)" "OK|1 above ceiling, 2 source kept, 1 skipped"

# ------------------------------------------------------------
echo
echo "== 4 output paths and source pairing"

O=/srv/compress/out
eq    "4 season folder mirrored"   "$(series_output_dir "$O" "/srv/compress/in/Columbo (1968)" "Season 01")" "$O/Columbo (1968)/Season 01"
eq    "4 nested season folder"     "$(series_output_dir "$O" "/srv/compress/in/Show/" "Season 01/Disc 2/")" "$O/Show/Season 01/Disc 2"
eq    "4 root group: show folder"  "$(series_output_dir "$O" /srv/compress/in/Show "(root)")" "$O/Show"
eq    "4 flat (no group): unchanged" "$(series_output_dir "$O" /srv/compress/in/Show)" "$O/Show"

P="$T/pair"
mk "$P/in/Show/Season 01/E01.mkv"
mk "$P/in/Show/Season 02/E01.mkv"
mk "$P/in/Show/Pilot.mkv"
mk "$P/in/Other/E01.mkv"
mk "$P/in/Solo/Season 03/Solo S03E01.mkv"
mk "$P/in/Flat/F01.mkv"
build_source_index "$P/in"
fso() { find_source_for_output "$P/out/$1" "$P/in" "$P/out"; }
eq    "4 output in Season 02 -> source in Season 02" "$(fso "Show/Season 02/E01 HEVC High.mkv")" "$(printf 'OK\t%s' "$P/in/Show/Season 02/E01.mkv")"
eq    "4 output in Season 01 -> source in Season 01" "$(fso "Show/Season 01/E01 1080p HEVC Base.mkv")" "$(printf 'OK\t%s' "$P/in/Show/Season 01/E01.mkv")"
eq    "4 root output -> source in the show root"     "$(fso "Show/Pilot HEVC High.mkv")" "$(printf 'OK\t%s' "$P/in/Show/Pilot.mkv")"
eq    "4 flat output of a nested show: season source found" "$(fso "Solo/Solo S03E01 HEVC High.mkv")" "$(printf 'OK\t%s' "$P/in/Solo/Season 03/Solo S03E01.mkv")"
eq    "4 flat output, two seasons match: reported, not guessed" "$(fso "Show/E01 HEVC High.mkv")" \
    "$(printf 'AMBIGUOUS\t%s\t%s' "$P/in/Show/Season 01/E01.mkv" "$P/in/Show/Season 02/E01.mkv")"
eq    "4 flat layout unchanged"     "$(fso "Flat/F01 HEVC Custom.mkv")" "$(printf 'OK\t%s' "$P/in/Flat/F01.mkv")"
eq    "4 old '<series> HEVC High' folder with seasons" "$(fso "Show HEVC High/Season 02/E01 HEVC High.mkv")" "$(printf 'OK\t%s' "$P/in/Show/Season 02/E01.mkv")"
eq    "4 unknown show: whole IN searched" "$(fso "Nope/E01 HEVC High.mkv" | cut -f1)" "AMBIGUOUS"
eq    "4 no source"                 "$(fso "Show/Season 01/E99 HEVC High.mkv")" "NONE"

# ------------------------------------------------------------
# Stand-ins for the menu runs: a source "file" is text with key=value
# lines (dur, res, range, vbps, vrate20 = sample bytes/s at CRF 20)
STUB="$T/stub"
mkdir -p "$STUB"
cat > "$STUB/ffprobe" <<'EOF'
#!/usr/bin/env bash
f=""; for a; do f="$a"; done
[[ -f "$f" ]] && grep -q '^dur=' "$f" 2>/dev/null || exit 1
v() { sed -n "s/^$1=//p" "$f" | head -n 1; }
dur=$(v dur); res=$(v res); rng=$(v range); vbps=$(v vbps); aud=$(v audio)
IFS=, read -ra ach <<< "${aud:-6}"
: "${res:=1920x1080}" "${rng:=SDR}" "${vbps:=40000000}"
w=${res%x*}; h=${res#*x}; pri=bt709; trc=bt709; pix=yuv420p
[[ "$rng" == HDR10 ]] && { pri=bt2020; trc=smpte2084; pix=yuv420p10le; }
case "$*" in
    *format=format_name*)
        echo "format|format_name=mov,mp4,m4a|duration=$dur"
        echo "stream|index=0|codec_type=video|codec_name=h264|bit_rate=$vbps|duration=$dur|disposition:attached_pic=0"
        for n in "${!ach[@]}"; do
            echo "stream|index=$((n + 1))|codec_type=audio|codec_name=ac3|bit_rate=640000|duration=$dur|disposition:attached_pic=0"
        done ;;
    *format=duration*) echo "$dur" ;;
    *stream=index,codec_type,codec_name,channels*)
        echo "index=0|codec_type=video|codec_name=h264|width=$w|height=$h|pix_fmt=$pix|r_frame_rate=24000/1001|color_primaries=$pri|color_transfer=$trc|color_space=bt709|disposition:attached_pic=0"
        for n in "${!ach[@]}"; do
            echo "index=$((n + 1))|codec_type=audio|codec_name=ac3|channels=${ach[$n]}|channel_layout=-|sample_rate=48000|disposition:attached_pic=0"
        done ;;
    *stream=width,height*) echo "${w}x${h}" ;;
    *-show_streams*) printf '[STREAM]\ncodec_name=h264\ncolor_primaries=%s\ncolor_transfer=%s\n[/STREAM]\n' "$pri" "$trc" ;;
esac
exit 0
EOF
cat > "$STUB/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# CRF sample encodes: a sparse file of vrate20 x 0.88^(CRF - 20) x length bytes
in="" len="" crf="" out="" prev=""
for a; do
    case "$prev" in -i) in="$a" ;; -t) len="$a" ;; -crf:v:0) crf="$a" ;; esac
    prev="$a"; out="$a"
done
[[ -n "$in" && -n "$crf" && -f "$in" ]] || exit 0
r=$(sed -n 's/^vrate20=//p' "$in" | head -n 1)
n=$(awk -v r="${r:-400000}" -v c="$crf" -v l="$len" 'BEGIN { printf "%.0f", r * (0.88 ^ (c - 20)) * l }')
truncate -s "$n" "$out"
EOF
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    has-session) exit 1 ;;
    new-session) echo "$*" >> "$TMUX_LOG"; exit 0 ;;
    list-sessions) [[ -n "${TMUX_SESSIONS:-}" ]] && printf '%s\n' "$TMUX_SESSIONS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB/ffprobe" "$STUB/ffmpeg" "$STUB/tmux"
export TMUX_LOG="$T/tmux.log"

H="$T/home"
CB="$H/compress"
mkdir -p "$CB/in" "$CB/out" "$CB/work"
cp -r "$SRC_WORK/lib" "$CB/work/"
cp "$SRC_WORK/series_compress.sh" "$CB/work/"
cp "$ROOT/progress-check.sh" "$ROOT/verify.sh" "$CB/"

# ep PATH KEY=VALUE...  ->  a stand-in source (45 min)
ep() { local p="$1"; shift; mkdir -p "$(dirname "$p")"; printf '%s\n' "dur=2700" "$@" > "$p"; }

S="$CB/in/Columbo (1968)"
ep "$S/Season 00 - Specials/Columbo S00E01.mkv" vrate20=450000
for e in 1 2 3; do ep "$S/Season 01/Columbo S01E0$e.mkv" vrate20=500000; done
ep "$S/Season 2/Columbo S02E01.mkv" vrate20=520000
ep "$S/Season 2/Columbo S02E02.mkv" vrate20=520000 res=1280x720        # resolution mismatch
for e in 1 2; do ep "$S/Season 10/Columbo S10E0$e.mkv" vrate20=700000; done
ep "$S/Extras/Making of.mkv" vrate20=100000
for e in 1 2; do ep "$CB/in/Flat/Flat S01E0$e.mkv" vrate20=600000; done
# file-name labels that clash across seasons ("Episode 1" in both)
ep "$CB/in/Clash/Season 1/Episode 1.mkv" vrate20=500000
ep "$CB/in/Clash/Season 2/Episode 1.mkv" vrate20=500000

menu() {   # INPUT LOG [ENV...]
    local in="$1" log="$2"
    shift 2
    printf "$in" | env HOME="$H" PATH="$STUB:$PATH" "$@" timeout 120 bash "$CB/work/series_compress.sh" > "$log" 2>&1
}
job_of() { ls -t "$CB/work"/series[0-9]*.sh 2>/dev/null | head -n 1; }
has()  { grep -qF -- "$2" "$1"; }
hasx() { grep -qxF -- "$2" "$1"; }

# ------------------------------------------------------------
echo
echo "== 5 series menu (stand-ins)"

L="$T/m1.log"
menu "1\n1\n2\n2\ny\n" "$L"
J1=$(job_of)
check "5 menu line: seasons and episodes"        "hasx '$L' '1) Clash [2 seasons, 2 episodes]' && hasx '$L' '2) Columbo (1968) [4 seasons, 8 episodes]' && hasx '$L' '3) Flat [2 episodes]'"
L="$T/m2.log"
rm -f "$CB"/work/series[0-9]*.sh
menu "2\n1\n1\n1\ny\n" "$L"
J=$(job_of)
check "5 season prompt"                          "hasx '$L' '1) All seasons  (4 seasons, 8 episodes)' && hasx '$L' '2) Select seasons'"
check "5 analysis: one line per season" \
    "grep -qE '^Season 00 - Specials +1  1920x1080 H264  SDR +from metadata +OK\$' '$L' && grep -qE '^Season 2 +2  1920x1080 H264  SDR +from metadata +MISMATCH\$' '$L' && grep -qE '^Season 10 +2 ' '$L'"
check "5 only the problem episodes listed"       "has '$L' 'MISMATCH  Columbo S02E02.mkv' && ! has '$L' 'Columbo S01E02.mkv'"
check "5 incompatible season excluded, rest offered" \
    "has '$L' 'Excluded: resolution or dynamic range differ' && hasx '$L' '1) Continue with the remaining 3 seasons (Season 00 - Specials, Season 01, Season 10)'"
check "5 one CRF line per season, no CRF step lines" \
    "grep -qE '^Season 00 - Specials +CRF [0-9]+ +decisive [0-9.]+ GiB \\(S00E01\\) / ceiling 1\\.88\$' '$L' && grep -qE '^Season 01 +CRF [0-9]+ +decisive' '$L' && ! grep -qE '^(CRF [0-9]+|Result:|Boundary:)' '$L' && ! grep -qE '^  S01E0[0-9]  ~' '$L'"
CRF_S00=$(sed -nE 's/^Season 00 - Specials +CRF ([0-9]+) .*/\1/p' "$L")
CRF_S01=$(sed -nE 's/^Season 01 +CRF ([0-9]+) .*/\1/p' "$L")
CRF_S10=$(sed -nE 's/^Season 10 +CRF ([0-9]+) .*/\1/p' "$L")
check "5 seasons get their own CRF (harder season: higher CRF)" "[[ -n '$CRF_S01' && -n '$CRF_S10' ]] && (( CRF_S10 > CRF_S01 ))"
check "5 expected sizes: one row per season + total" \
    "grep -qE '^Season 01 +3 +$CRF_S01 +[0-9.]+ +[0-9.]+ +[0-9.]+ +[0-9.]+  OK\$' '$L' && grep -qE '^Total +6 +[0-9.]+ ' '$L' && ! grep -qE '^S01E0[0-9] +[0-9]+:[0-9]{2}' '$L'"
check "5 CRF range line"                         "grep -qE '^CRF range: [0-9]+-[0-9]+ across 3 seasons \\(per-season shared CRF\\)\$' '$L'"
check "5 confirmation: one line per season, excluded one named" \
    "grep -qE '^Season 01 +High \\| CRF $CRF_S01 \\| 1920x1080 \\| SDR \\| audio copied  \\(3 episodes\\)\$' '$L' && grep -qE '^Season 2 +excluded: ' '$L'"
check "5 job started"                            "[[ -n '$J' && -f '$J' ]] && has '$TMUX_LOG' 'new-session -d -s series'"
cp "$J" "$T/multi.job"
eq    "5 job: one season block per season"       "$(grep -c '^job_season_begin ' "$J")" "3"
eq    "5 job: season batch boundary per season (+ footer)" "$(grep -c '^job_crf_batch$' "$J")" "4"
check "5 job: season markers carry name / CRF / position / items" \
    "grep -qxF 'job_season_begin Season\\ 01 $CRF_S01 2 3 3' '$J' && grep -qxF 'job_season_begin Season\\ 10 $CRF_S10 3 3 2' '$J'"
check "5 job: items carry season and season CRF" \
    "[[ \$(grep -c 'season=Season\\\\ 01 season_crf=$CRF_S01' '$J') == 3 ]] && grep -q 'season=Season\\\\ 00\\\\ -\\\\ Specials season_crf=$CRF_S00' '$J'"
check "5 job: every item of a season at its season CRF" \
    "[[ \$(grep 'season=Season\\\\ 10 ' '$J' | grep -c ' crf=$CRF_S10 ') == 2 ]]"
check "5 job: outputs mirror the season folders" \
    "grep -qF \"out/Columbo\\\\ \\\\(1968\\\\)/Season\\\\ 01/Columbo\\\\ S01E02\\\\ HEVC\\\\ High.mkv\" '$J' && grep -qF \"out/Columbo\\\\ \\\\(1968\\\\)/Season\\\\ 00\\\\ -\\\\ Specials/Columbo\\\\ S00E01\\\\ HEVC\\\\ High.mkv\" '$J'"
check "5 job: excluded season and extras not queued" "! grep -q 'Season\\\\ 2/' '$J' && ! grep -q 'Making' '$J'"
check "5 season output folders created"          "[[ -d '$CB/out/Columbo (1968)/Season 01' && -d '$CB/out/Columbo (1968)/Season 10' && ! -e '$CB/out/Columbo (1968)/Season 2' ]]"
check "5 job passes bash -n"                     "bash -n '$J'"

# cancel at the exclusion question
L="$T/m3.log"
rm -f "$CB"/work/series[0-9]*.sh
menu "2\n1\n2\n" "$L"
check "5 exclusion: cancel stops before the tier" "has '$L' 'Compression cancelled.' && ! has '$L' 'Compression tier:' && [[ -z \"\$(job_of)\" ]]"

# select seasons: invalid input, then "1,4"
L="$T/m4.log"
menu "2\n2\n9\n1,4\n5\n20\ny\n" "$L"
J=$(job_of)
check "5 numbered season list with episode counts" "grep -qE '^ 1\\) Season 00 - Specials +1 episode\$' '$L' && grep -qE '^ 3\\) Season 2 +2 episodes\$' '$L'"
check "5 invalid selection asked again"          "has '$L' 'Invalid selection: enter season numbers 1-4 and ranges, e.g. 1,3,5-7'"
check "5 only the selected seasons analysed"      "grep -qE '^Season 10 +2 ' '$L' && ! grep -qE '^Season 01 +3 ' '$L' && ! grep -qE '^Season 2 ' '$L'"
check "5 Custom: the entered CRF for every season unchanged" \
    "grep -qxF 'job_season_begin Season\\ 00\\ -\\ Specials 20 1 2 1' '$J' && grep -qxF 'job_season_begin Season\\ 10 20 2 2 2' '$J' && [[ \$(grep -c ' mode=crf crf=20 ' '$J') == 3 ]]"
check "5 Custom: no retry batch"                 "! grep -q '^job_batch_add' '$J' && ! grep -q 'batch_mode=season' '$J'"
rm -f "$CB"/work/series[0-9]*.sh

# labels unique across seasons
L="$T/m5.log"
menu "1\n1\n1\ny\n" "$L"
J=$(job_of)
check "5 clashing labels get their season"       "grep -qE '^Season 1 +CRF [0-9]+ +decisive [0-9.]+ GiB \\(S01/Episode [0-9]\\)' '$L' && grep -qE '^Season 2 +CRF [0-9]+ +decisive [0-9.]+ GiB \\(S02/Episode [0-9]\\)' '$L'"
check "5 job labels unique"                      "grep -q 'ep_label=S01/Episode\\\\ 1' '$J' && grep -q 'ep_label=S02/Episode\\\\ 1' '$J'"
rm -f "$CB"/work/series[0-9]*.sh

# flat folder: no season prompt, earlier output and job format
L="$T/m6.log"
menu "3\n1\ny\n" "$L"
J=$(job_of)
check "5 flat: no season prompt, analysis line as before" \
    "! has '$L' 'Select seasons' && grep -qE '^Analyzing 2 episodes\\.\\.\\. OK    Source stats: from metadata    Compatibility: OK\$' '$L'"
check "5 flat: per-episode expected sizes as before" "grep -qE '^S01E01 +45:00 ' '$L' && has '$L' 'Season:'"
check "5 flat: confirmation line as before"      "grep -qE '^High \\| CRF [0-9]+ \\| 1920x1080 \\| SDR \\| audio copied\$' '$L'"
check "5 flat: no season markers in the job"     "! grep -q 'job_season_begin\\|season=' '$J' && [[ \$(grep -c '^job_crf_batch\$' '$J') == 1 ]]"
check "5 flat: output in out/<show>/"            "grep -qF 'out/Flat/Flat\\ S01E01\\ HEVC\\ High.mkv' '$J'"
rm -f "$CB"/work/series[0-9]*.sh

# prompts inside a season come under its name: source-quality guard
# (Season B sources are already small), skipped episodes in the summary
G2="$CB/in/Guard"
for e in 1 2; do ep "$G2/Season A/Guard S01E0$e.mkv" vrate20=500000; done
ep "$G2/Season B/Guard S02E01.mkv" vrate20=500000 vbps=2000000
ep "$G2/Season B/Guard S02E02.mkv" vrate20=500000
L="$T/m8.log"
menu "4\n1\n1\n3\ny\n" "$L"
J=$(job_of)
check "5 guard prompt under the season header" \
    "grep -B12 'Source-quality guard: 1 episode' '$L' | grep -qx -- '---- Season B ----' && ! grep -qx -- '---- Season A ----' '$L'"
check "5 skipped episode: season status and problem list" \
    "grep -qE '^Season B +2 +[0-9]+ .*1 skipped\$' '$L' && grep -qE '^  S02E01 +SKIPPED \\(source-quality guard\\)\$' '$L'"
check "5 skipped episode not queued"            "! grep -q 'Guard\\\\ S02E01' '$J' && grep -qxF 'job_season_begin Season\\ B '\"\$(sed -nE 's/^Season B +CRF ([0-9]+) .*/\\1/p' '$L')\"' 2 2 1' '$J'"
rm -f "$CB"/work/series[0-9]*.sh

# existing outputs in two seasons: one question for every season
mkdir -p "$CB/out/Guard/Season A" "$CB/out/Guard/Season B"
: > "$CB/out/Guard/Season A/Guard S01E01 HEVC High.mkv.part"     # another encode writing it
: > "$CB/out/Guard/Season B/Guard S02E02 HEVC High.mkv.part"
L="$T/m9.log"
menu "4\n1\n1\n3\n3\ny\n" "$L"
J=$(job_of)
eq    "5 existing outputs: one question"         "$(grep -c '^1) Keep both' "$L")" "1"
check "5 existing outputs listed per season" \
    "has '$L' '2 episode(s) already have an output with the same settings' && grep -qE '^  Season A +1 episode: S01E01 \$' '$L' && grep -qE '^  Season B +1 episode: S02E02 \$' '$L'"
check "5 existing outputs skipped in both seasons" "! grep -q 'Guard\\\\ S01E01\\|Guard\\\\ S02E02' '$J' && grep -q 'Guard\\\\ S01E02' '$J'"
rm -f "$CB"/work/series[0-9]*.sh "$CB/out/Guard/Season A/"*.part "$CB/out/Guard/Season B/"*.part

# leftover CRF attempt files of any selected season: not started
: > "$CB/out/Guard/Season B/Guard S02E02 HEVC High.mkv.retry-crf13.part"
L="$T/m10.log"
menu "4\n1\n1\n3\ny\n" "$L"
check "5 leftover CRF attempt in one season: cancelled, listed" \
    "has '$L' 'Leftover CRF attempt files' && has '$L' 'Season B/Guard S02E02 HEVC High.mkv.retry-crf13.part' && [[ -z \"\$(job_of)\" ]]"
rm -f "$CB/out/Guard/Season B/"*.part

# resolution asked once; only the season above 1080p is downscaled
U="$CB/in/Mixed Res"
for e in 1 2; do ep "$U/Season 01/Mixed S01E0$e.mkv" vrate20=900000 res=3840x2160; done
for e in 1 2; do ep "$U/Season 02/Mixed S02E0$e.mkv" vrate20=500000; done
L="$T/m11.log"
menu "5\n1\n2\n1\ny\n" "$L"
J=$(job_of)
eq    "5 resolution asked once"                  "$(grep -c '^Output resolution:' "$L")" "1"
check "5 resolution prompt names the season it applies to" "has '$L' '(applies to Season 01; the other seasons are 1080p or less)'"
check "5 only the 2160p season downscaled" \
    "[[ \$(grep -c 'Mixed\\\\ S01E0[12]\\\\ 1080p\\\\ HEVC\\\\ High.mkv' '$J') -ge 2 ]] && grep -q 'Mixed\\\\ S02E01\\\\ HEVC\\\\ High.mkv' '$J' && grep -qE '^Season 01 +High \\| CRF [0-9]+ \\| 1920x1080 ' '$L'"
rm -f "$CB"/work/series[0-9]*.sh

# audio layout differs between episodes: reported (OK*), never a reason
# to exclude the season (only resolution / dynamic range are)
A="$CB/in/Tracks"
ep "$A/Season 01/Tracks S01E01.mkv" vrate20=500000 audio=6,2
ep "$A/Season 01/Tracks S01E02.mkv" vrate20=500000 audio=6
ep "$A/Season 01/Tracks S01E03.mkv" vrate20=500000 audio=2,2
ep "$A/Season 02/Tracks S02E01.mkv" vrate20=500000 audio=6,2
ep "$A/Season 02/Tracks S02E02.mkv" vrate20=500000 audio=6,2
L="$T/m12.log"
menu "6\n1\n1\ny\n" "$L"
J=$(job_of)
check "5 audio layout differs: OK*, not excluded" \
    "grep -qE '^Season 01 +3  1920x1080 H264  SDR +from metadata +OK\\*\$' '$L' && ! has '$L' 'MISMATCH' && ! has '$L' 'Excluded' && ! has '$L' 'Continue with the remaining'"
check "5 audio layout differs: reported per episode" \
    "has '$L' 'differs: audio tracks 1 vs 2 (each episode'\''s tracks copied as they are)' && has '$L' 'differs: audio channels [2 x2] vs [6, 2]'"
check "5 audio layout differs: header shows the track range" "grep -qE '^Audio: +1-2 tracks per episode, copied unchanged\$' '$L'"
check "5 audio layout differs: both seasons queued" \
    "grep -q '^job_season_begin Season\\\\ 01 ' '$J' && grep -q '^job_season_begin Season\\\\ 02 ' '$J' && [[ \$(grep -c '^job_batch_add ' '$J') == 5 ]]"
check "5 audio layout differs: lines fit 120 columns" "[[ \$(awk 'length > 120' '$L' | grep -c .) == 0 ]]"
rm -f "$CB"/work/series[0-9]*.sh
L="$T/m13.log"
menu "6\n2\n1\n1\nn\n" "$L" COMPRESS_VERBOSE=1
check "5 audio layout differs, one season: header and stream notes" \
    "has '$L' 'Audio tracks:  1-2 (differs per episode)' && has '$L' 'differs: audio channels [6] vs [6, 2]' && has '$L' 'All files compatible.' && has '$L' '(tracks of Tracks S01E01.mkv; each episode'\''s own tracks are copied)'"

# verbose: per-episode detail grouped under season headers
L="$T/m7.log"
menu "2\n2\n1,3\n2\nn\n" "$L" COMPRESS_VERBOSE=1
check "5 verbose: season headers, per-episode detail" \
    "has '$L' '---- Season 00 - Specials ----' && has '$L' '---- Season 2 ----' && has '$L' 'Verifying 2 files against Columbo S02E01.mkv...' && has '$L' 'Season 2 is excluded.'"

# over target (Base 1.0 GiB/h): Season 02's dense 22 min S02E01 cannot fit
# its 0.37 GiB ceiling even at CRF 27; no question, the season encoded at
# CRF 27, marked in the season line, the summary and before the
# confirmation; Season 01 unaffected
Z="$CB/in/Zover"
for e in 1 2; do ep "$Z/Season 01/Zover S01E0$e.mkv" vrate20=500000; done
mkdir -p "$Z/Season 02"; printf '%s\n' dur=1320 vrate20=3000000 > "$Z/Season 02/Zover S02E01.mkv"
ep "$Z/Season 02/Zover S02E02.mkv" vrate20=500000
L="$T/m13o.log"
rm -f "$CB"/work/series[0-9]*.sh
menu "7\n1\n2\ny\n" "$L"
J=$(job_of)
sed -n '/^Expected sizes/,$p' "$L" | sed 's/^/  | /'
check "5 over target: no question"             "! has '$L' 'Encode every episode' && ! has '$L' 'WARNING' && ! has '$L' 'Compression cancelled'"
check "5 over target: season line"             "grep -qE '^Season 02 +CRF 27 +decisive [0-9.]+ GiB \\(S02E01\\) / ceiling 0\\.37 +over target\$' '$L' && grep -qE '^Season 01 +CRF [0-9]+ ' '$L' && ! grep -qE '^Season 01 .*over target' '$L'"
check "5 over target: summary status + episode vs ceiling" \
    "grep -qE '^Season 02 +2 +27 .*over target \\(1 ep\\)\$' '$L' && grep -qE '^Season 01 +2 .*  OK\$' '$L' && grep -qE '^  S02E01 +OVER TARGET ~[0-9.]+ GiB video / 0\\.37 GiB ceiling \\(\\+[0-9.]+, sampled\\)\$' '$L'"
check "5 over target: shown again before the confirmation" \
    "hasx '$L' 'Over target (Base ceilings cannot be met within CRF 11-27; encoded at CRF 27):' && hasx '$L' '  Season 02 (CRF 27):' && grep -qE '^    S02E01 +~[0-9.]+ GiB video / 0\\.37 GiB ceiling' '$L' && grep -qE '^Season 02 +Base \\| CRF 27 \\| .*\\| over target  \\(2 episodes\\)\$' '$L'"
check "5 over target: Season 02 at CRF 27, its own ceilings" \
    "[[ -n '$J' ]] && [[ \$(grep -c 'crf=27 .*ceiling_vbytes=[0-9]* crf_min=11 crf_max=27 .*batch_mode=season' '$J') == 2 ]] && grep -q 'ceiling_vbytes=393705335 crf_min=11 crf_max=27' '$J' && grep -q 'ceiling_vbytes=805306368 crf_min=11 crf_max=27' '$J'"

# ------------------------------------------------------------
echo
echo "== 6 job runtime: one season batch per season"

W="$T/jobwork"
mkdir -p "$W/logs" "$T/jout/A" "$T/jout/B" "$T/jin/A" "$T/jin/B"
(
    WORK_DIR="$W"
    cp -r "$SRC_WORK/lib" "$W/"
    for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy naming job_runtime; do
        source "$W/lib/$l.sh" > /dev/null
    done
    main_video_index()   { echo 0; }
    probe_hdr()          { HDR_DV=0; HDR_HDR10PLUS=0; HDR_DV_PROFILE=""; }
    build_stream_map()   { MAP_ARGS="-map 0:0"; MAP_CODEC_ARGS=""; MAP_META_ARGS=""; MAP_OTHER_ARGS=""; MAP_COVERS=(); MAP_NOTES=(); }
    x265_color_params()  { :; }
    color_output_args()  { :; }
    libx265_has_option() { return 1; }
    stale_stats_args()   { :; }
    matroska_mux_args()  { :; }
    STUBS='
get_duration() { echo 100; }
media_stream_totals() { local v a c; read -r v a c < "$1"; echo "$v $a"; }
item_verify_output() { echo "$ITEM_INDEX:${ITEM_EXP[crf]}" >> "'"$T"'/$JOB_SESSION.verified"; }
item_restore_mkv_chapters() { return 0; }
item_step() { shift; "$@"; }
refresh_mkv_stats() { return 0; }
item_run() {
    local c="${ITEM_EXP[crf]}" s
    s="${SIZES[$ITEM_INDEX:$c]:-}"
    echo "$ITEM_INDEX:$c" >> "'"$T"'/$JOB_SESSION.encoded"
    [[ -z "$s" || "$s" == fail ]] && return 1
    echo "$s $c" > "$ITEM_PART"
}
'
    sz() { printf "[%s]='%s %s'" "$1" "$(gib "$2")" "$(gib 0.5)"; }
    for e in 1 2; do echo a > "$T/jin/A/A.S01E0$e.mkv"; echo b > "$T/jin/B/B.S02E0$e.mkv"; done
    spec=$(series_season_retry_spec High "$(gib 5)" 21 8)

    # s1: season A planned 16 (E01 over -> whole season A at 17), season B
    # planned 20 (fits; CRF 19 tested, over -> stays 20)
    {
        emit_job_header s1 series 4
        printf '%s\n' "$STUBS" "declare -A SIZES=($(sz 1:16 5.4) $(sz 2:16 4) $(sz 1:17 4.8) $(sz 2:17 3.6) $(sz 3:20 4) $(sz 4:20 4.2) $(sz 3:19 4.6) $(sz 4:19 5.2))"
        emit_job_season "Season A" 16 1 2 2
        EMIT_SEASON="Season A" EMIT_SEASON_CRF=16
        for e in 1 2; do
            EMIT_EP_LABEL="S01E0$e"
            emit_encode_item "$e" "$T/jin/A/A.S01E0$e.mkv" "$T/jout/A/E0$e.mkv" High crf:16 "" "" 0 "$(gib 4.5)" "$spec" "" "16=$(gib 4.5)"
        done
        emit_job_season_end
        emit_job_season "Season B" 20 2 2 2
        EMIT_SEASON="Season B" EMIT_SEASON_CRF=20
        for e in 3 4; do
            EMIT_EP_LABEL="S02E0$((e - 2))"
            emit_encode_item "$e" "$T/jin/B/B.S02E0$((e - 2)).mkv" "$T/jout/B/E0$((e - 2)).mkv" High crf:20 "" "" 0 "$(gib 4.5)" "$spec" "" "20=$(gib 4.5)"
        done
        emit_job_season_end
        emit_job_footer
    } > "$W/s1.sh"
    cp "$W/s1.sh" "$T/s1.job"
    unset EMIT_SEASON EMIT_SEASON_CRF EMIT_EP_LABEL

    # s2: the same two seasons as an earlier single-batch job script (no
    # season markers): still runs as generated, ONE batch for all items
    {
        emit_job_header s2 series 4
        printf '%s\n' "$STUBS" "declare -A SIZES=($(sz 1:16 4) $(sz 2:16 4) $(sz 3:16 4) $(sz 4:16 4) $(sz 1:15 6) $(sz 2:15 4) $(sz 3:15 4) $(sz 4:15 4))"
        for e in 1 2 3 4; do
            emit_encode_item "$e" "$T/jin/A/A.S01E0$(( (e + 1) / 2 )).mkv" "$T/jout/old-E0$e.mkv" High crf:16 "" "" 0 "$(gib 4.5)" "$spec" "" ""
        done
        emit_job_footer
    } > "$W/s2.sh"
    cp "$W/s2.sh" "$T/s2.job"
)
bash -n "$W/s1.sh" && bash "$W/s1.sh" < /dev/null > "$T/s1.log" 2>&1
bash -n "$W/s2.sh" && bash "$W/s2.sh" < /dev/null > "$T/s2.log" 2>&1
encoded() { tr '\n' ' ' < "$T/$1.encoded" 2>/dev/null; }
eq    "6 seasons encoded one after the other; a retry only re-encodes its season" \
    "$(encoded s1)" "1:16 2:16 1:17 2:17 3:20 4:20 3:19 4:19 "
eq    "6 every item verified at its own season's final CRF" "$(tr '\n' ' ' < "$T/s1.verified")" "1:17 2:17 3:20 4:20 "
eq    "6 final outputs at the season CRFs" \
    "$(for f in "$T"/jout/A/E01.mkv "$T"/jout/A/E02.mkv "$T"/jout/B/E01.mkv "$T"/jout/B/E02.mkv; do awk '{ printf "%s ", $3 }' "$f"; done)" "17 17 20 20 "
check "6 season banner and compact season check lines" \
    "grep -q '^Season 1/2: Season A  (2 episodes, season CRF 16)\$' '$T/s1.log' && grep -q '^Season A CRF 16 actual: 2 episodes, largest 5.40 GiB (S01E01) / 5.00 GiB ceiling -> 1 over the ceiling\$' '$T/s1.log' && grep -q '^  S01E01 5.40 GiB / 5.00 GiB -> over ceiling\$' '$T/s1.log' && grep -q '^Season B CRF 20 actual: 2 episodes, largest 4.20 GiB (S02E02) / 5.00 GiB ceiling -> every episode fits\$' '$T/s1.log'"
check "6 no per-episode fit lines in a multi-season check" "! grep -q -- '-> fits\$' '$T/s1.log'"
check "6 final CRF per season"                   "grep -q '^Final season CRF: 17 (Season A)\$' '$T/s1.log' && grep -q '^Final season CRF: 20 (Season B)\$' '$T/s1.log'"
check "6 job finished, nothing left"             "grep -q 'All encodes finished: 4 ok, 0 failed' '$T/s1.log' && [[ -z \$(find '$T/jout' -name '*.part') ]]"
eq    "6 earlier job script: one batch for every item (one CRF)" "$(encoded s2)" "1:16 2:16 3:16 4:16 1:15 2:15 3:15 4:15 "
check "6 earlier job script: per-episode season lines, final CRF" \
    "grep -q '^Season CRF 16 actual results:\$' '$T/s2.log' && grep -q '^Final season CRF: 16\$' '$T/s2.log' && grep -q 'All encodes finished: 4 ok, 0 failed' '$T/s2.log'"
check "6 provenance metadata in the items"       "grep -q \"ep_label=S01E01 season=Season\\\\\\\\ A season_crf=16\" '$T/s1.job'"

# ------------------------------------------------------------
echo
echo "== 7 progress-check (multi-season job)"

PW="$CB/work"
cp "$T/multi.job" "$PW/series7.sh"
touch -d '@1' "$PW/series7.sh"
now=$(date +%s)
mkdir -p "$PW/logs/series7"
{
    printf 'version=1\nsession=series7\ntype=series\nstatus=running\nitem=3\nitems=6\nok=0\nfailed=0\n'
    printf 'name=Columbo S01E02.mkv\ninput=%s\noutput=x\ntier=High\npass=encode\nmode=crf\ncrf=%s\nduration=2700\n' "$S/Season 01/Columbo S01E02.mkv" "$CRF_S01"
    printf 'started=%s\nupdated=%s\nprogress=%s\nlog_dir=%s\n' "$((now - 600))" "$now" "$PW/series7.progress" "$PW/logs/series7"
    printf 'season=Season 01\nseason_no=2\nseasons=3\nseason_crf=%s\nseason_items=3\nseason_state=retry:%s\nlabel=S01E02\nseason_final_1=%s\n' \
        "$CRF_S01" "$((CRF_S01 + 1))" "$((CRF_S00 + 1))"
} > "$PW/series7.state"
printf 'out_time_us=270000000\nspeed=1.0x\nprogress=continue\n' > "$PW/series7.progress"
pc() { ( cd "$H" && HOME="$H" COLUMNS=120 TMUX_SESSIONS="series7 $((now - 600))" PATH="$STUB:$PATH" bash "$CB/progress-check.sh" "$@" ) > "$T/pc.out" 2>&1; }
pc
check "7 one row per season with state" \
    "grep -qE '^  \\[DONE\\] +Season 00 - Specials +1/1   CRF $((CRF_S00 + 1))\$' '$T/pc.out' && grep -qE '^  \\[NOW\\] +Season 01 +1/3   CRF $((CRF_S01 + 1))   current: S01E02   \\(retry at CRF $((CRF_S01 + 1))\\)\$' '$T/pc.out' && grep -qE '^  \\[NEXT\\] +Season 10 +0/2   CRF $CRF_S10\$' '$T/pc.out'"
check "7 no per-episode rows"                    "! grep -qE '^  \\[(DONE|NOW|NEXT|WAIT)\\] +[0-9]+\\. ' '$T/pc.out'"
check "7 CURRENT block unchanged"                "grep -q '^CURRENT: Columbo S01E02.mkv\$' '$T/pc.out' && grep -q 'Encoding' '$T/pc.out'"
pc -v
check "7 -v: every episode"                      "grep -qE '^  \\[NOW\\]  3\\. Columbo S01E02\\.mkv' '$T/pc.out' && grep -qE '^  \\[WAIT\\] 6\\. Columbo S10E02\\.mkv' '$T/pc.out'"
( cd "$H" && HOME="$H" COLUMNS=120 PROGRESS_VERBOSE=1 TMUX_SESSIONS="series7 $((now - 600))" PATH="$STUB:$PATH" bash "$CB/progress-check.sh" ) > "$T/pc2.out" 2>&1
check "7 PROGRESS_VERBOSE=1: every episode"      "grep -qE '^  \\[NEXT\\] 4\\. Columbo S01E03\\.mkv' '$T/pc2.out'"
sed -i 's/^season_state=.*/season_state=encoding/' "$PW/series7.state"
pc
check "7 encoding state"                         "grep -qE '^  \\[NOW\\] +Season 01 +1/3   CRF $CRF_S01   current: S01E02   \\(encoding\\)\$' '$T/pc.out'"
rm -f "$PW/series7.sh" "$PW/series7.state" "$PW/series7.progress"

# ------------------------------------------------------------
echo
echo "== 8 verify.sh: scope and grouped summary"

OC="$CB/out/Columbo (1968)"
ep "$OC/Season 01/Columbo S01E01 HEVC High.mkv"
ep "$OC/Season 01/Columbo S01E07 HEVC High.mkv"        # no source
ep "$OC/Season 00 - Specials/Columbo S00E01 HEVC High.mkv"
ep "$CB/out/Flat/Flat S01E01 HEVC High.mkv"
vrun() { local in="$1" log="$2"; shift 2; printf "$in" | HOME="$H" PATH="$STUB:$PATH" timeout 60 bash "$CB/verify.sh" "$@" > "$log" 2>&1; }

vrun "2\n1\n" "$T/v1.log"
check "8 no Scope prompt (Location + Mode only)" "grep -qx '2) OUT' '$T/v1.log' && grep -qx '1) Verify' '$T/v1.log' && ! grep -qi 'scope:\|one show\|one season' '$T/v1.log'"
check "8 header per show, sub-header per season" \
    "grep -qx '== Columbo (1968)' '$T/v1.log' && grep -q '^-- Season 00 - Specials: 1 episode, ' '$T/v1.log' && grep -q '^-- Season 01: 2 episodes, ' '$T/v1.log' && grep -qx '== Flat' '$T/v1.log' && grep -q '^-- (root): 1 episode' '$T/v1.log'"
check "8 one line per episode (S00E01 labels)" \
    "grep -qE '^  S01E01  .*  OK\$' '$T/v1.log' && grep -qE '^  S01E07  .*  UNPAIRED\$' '$T/v1.log'"
check "8 detail only for a real problem (unpaired)" \
    "grep -q '^    Columbo (1968)/Season 01/Columbo S01E07 HEVC High.mkv\$' '$T/v1.log' && ! grep -q '^    Columbo (1968)/Season 01/Columbo S01E01 HEVC High.mkv\$' '$T/v1.log'"
check "8 no whitespace-only lines"               "! grep -qE '^[[:space:]]+\$' '$T/v1.log'"
check "8 nested output paired with its season source" "! grep -q 'S00E01.*UNPAIRED' '$T/v1.log'"
check "8 total line" \
    "grep -qx 'Total: 2 shows, 3 seasons, 4 files; problems: 1 (0 CHECK REQUIRED, 1 UNPAIRED); titles to correct: 0' '$T/v1.log'"

vrun "1\n" "$T/v2.log" out/Flat
check "8 path: show (Location from the path)"   "! grep -q 'Location:' '$T/v2.log' && grep -qx 'Verify: out/Flat' '$T/v2.log' && grep -q '^Total: 1 show, 1 season, 1 file;' '$T/v2.log' && ! grep -q 'S01E01  .*UNPAIRED' '$T/v2.log'"
vrun "" "$T/v2b.log" --verify "Columbo (1968)/Season 01/Columbo S01E07 HEVC High.mkv"
check "8 path: file relative to out/"           "grep -qx 'Verify: out/Columbo (1968)/Season 01/Columbo S01E07 HEVC High.mkv' '$T/v2b.log' && grep -q '^Total: 1 show, 1 season, 1 file;' '$T/v2b.log'"
vrun "" "$T/v3.log" --verify "out/Columbo (1968)/Season 01"
check "8 path: season, --verify (no prompt)"   "! grep -q 'Select' '$T/v3.log' && grep -q '^Total: 1 show, 1 season, 2 files;' '$T/v3.log' && ! grep -q 'S00E01' '$T/v3.log'"
COMPRESS_VERBOSE=1 vrun "" "$T/v4.log" --verify "$OC/Season 01"
check "8 COMPRESS_VERBOSE=1: detail for every file" "grep -q '^    Columbo (1968)/Season 01/Columbo S01E01 HEVC High.mkv\$' '$T/v4.log'"
vrun "" "$T/v5.log" --verify --brief "$OC"
check "8 --brief: one line per season"          "[[ \$(grep -c '^  Columbo (1968) / ' '$T/v5.log') == 2 ]] && grep -q '^  Columbo (1968) / Season 01: 2 eps, video .*, 1 OK, 1 UNPAIRED' '$T/v5.log' && ! grep -q '^  S01E01' '$T/v5.log'"
vrun "1\n1\n" "$T/v6.log"
check "8 IN: sources grouped, extras folder its own group" "grep -q '^-- Extras: 1 episode' '$T/v6.log' && grep -qE '^  S01E01  ' '$T/v6.log'"
vrun "" "$T/v7.log" --verify "Columbo (1968)"
eq    "8 path in both in/ and out/: exit 1"     "$(HOME="$H" PATH="$STUB:$PATH" bash "$CB/verify.sh" --verify "Columbo (1968)" > /dev/null 2>&1; echo $?)" 1
check "8 path in both in/ and out/: clear error" "grep -q 'found in both in/ and out/' '$T/v7.log'"
vrun "" "$T/v8.log" --verify "No Such Show"
check "8 missing path: clear error"             "grep -q '^verify.sh: No Such Show: not found' '$T/v8.log' && ! grep -q 'Select' '$T/v8.log'"
vrun "" "$T/v9.log" --verify /etc
check "8 path outside in/ and out/: refused"    "grep -q 'not inside' '$T/v9.log'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
