#!/usr/bin/env bash
# Menu output format tests (compact default, COMPRESS_VERBOSE=1, colours).
#
#   bash ~/compress/work/tests/ui_tests.sh
#
# Needs ffmpeg / ffprobe with libx265 (tiny 2 s synthetic sources; the
# sample encodes take seconds); script(1) for the terminal checks. tmux
# is stubbed, no encode job is run. Covers:
#   1. helpers: source stats summary, episode ids, labels, colours only
#      on a terminal
#   2. HDR10+ / Dolby Vision: compact PRESERVED lines; tool paths and
#      internals only in verbose mode or with a warning / error
#   3. series menu: compact layout, no file names / policy text / ANSI
#      codes / tabs, lines <= 120 columns; verbose keeps the diagnostics;
#      a mismatch and a missed ceiling still show their details
#   4. movie menu: compact layout; verbose keeps the diagnostics; Quality
#      CRF search wording, source guard, Video / Target / Band block, CRF job
#   5. colours on a terminal, none when redirected
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${UI_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE NO_COLOR
ESC=$'\e'

# compact LOG  ->  0 when LOG has no ANSI codes, no tabs, no line > 120
compact() {
    ! grep -q "$ESC" "$1" && ! grep -qP '\t' "$1" && [[ $(awk 'length > 120' "$1" | grep -c .) == 0 ]]
}

# ------------------------------------------------------------
echo "== helpers"
# (sourced with stdout redirected: colours are decided at source time)
source "$SRC_WORK/lib/ui.sh" > /dev/null
source "$SRC_WORK/lib/naming.sh"
source "$SRC_WORK/lib/media_probe.sh"
source "$SRC_WORK/lib/media_stats.sh"
source "$SRC_WORK/lib/bitrate.sh"
source "$SRC_WORK/lib/encode_common.sh"
source "$SRC_WORK/lib/hdr_dovi.sh"

eq "stats: all cached"            "$(ui_stats_summary tags tags tags)" "cached"
eq "stats: mixed"                 "$(ui_stats_summary tags packets tags tags packets tags)" "4 cached, 2 scanned"
eq "stats: scanned + refreshed"   "$(ui_stats_summary packets:refreshed packets:refreshed)" "scanned + refreshed"
eq "stats: partly refreshed"      "$(ui_stats_summary packets:refreshed packets)" "scanned"
eq "stats: mixed + refreshed"     "$(ui_stats_summary tags packets:refreshed)" "1 cached, 1 scanned + refreshed"
eq "stats: metadata"              "$(ui_stats_summary meta meta)" "from metadata"
eq "episode: S01E03"              "$(episode_label "/x/Slow.Horses.S01E03.2160p.mkv")" "S01E03"
eq "episode: s2e10"               "$(episode_label "Show - s2e10.mkv")" "S02E10"
eq "episode: 1x05"                "$(episode_label "Show 1x05.mkv")" "S01E05"
eq "episode: E01"                 "$(episode_label "E01.mkv")" "E01"
eq "episode: 1920x1080 is no id"  "$(episode_label "Film.1920x1080.mkv")" "Film.1920x1080"
eq "episode: long name shortened" "$(episode_label "Another long episode name.mkv")" "Another long episod~"
eq "episodes: clash -> names"     "$(episode_labels a/S01E01.mkv a/S01E01.mp4 | tr '\n' ' ')" "S01E01 S01E01 "
eq "bit depth"                    "$(ui_bit_depth yuv420p10le)/$(ui_bit_depth yuv420p)" "10-bit/8-bit"
eq "plural"                       "$(ui_plural 1 track)/$(ui_plural 6 episode)" "1 track/6 episodes"
check "no colour when redirected" "[[ \"\$(ui_ok OK; ui_warn W; ui_err E; ui_bold B)\" != *\$ESC* ]]"

HAVE_SCRIPT=0
command -v script >/dev/null && HAVE_SCRIPT=1
if (( HAVE_SCRIPT == 1 )); then
    printf 'source %q; ui_ok OK; ui_warn W; ui_err E; ui_bold B\n' "$SRC_WORK/lib/ui.sh" > "$T/colour.sh"
    script -qec "bash $T/colour.sh" /dev/null > "$T/colour.out"
    check "colours on a terminal" \
        "grep -qF \$'\\e[32mOK' '$T/colour.out' && grep -qF \$'\\e[33mW' '$T/colour.out' && grep -qF \$'\\e[31mE' '$T/colour.out' && grep -qF \$'\\e[1mB' '$T/colour.out'"
    NO_COLOR=1 script -qec "bash $T/colour.sh" /dev/null > "$T/colour2.out"
    check "NO_COLOR on a terminal"    "! grep -q \"\$ESC\" '$T/colour2.out'"
else
    echo "  (script not found: terminal colour checks skipped)"
fi

# ------------------------------------------------------------
echo
echo "== HDR10+ / Dolby Vision lines"

# tools as found by hdr_tools_detect (no real tools needed)
hdr_fake() {
    HDR_TOOLS_DETECTED=1 X265_HDR10PLUS=1 FFMPEG_DOVI_BSF=0 FFMPEG_X265_DV=0
    DOVI_TOOL=/opt/bin/dovi_tool DOVI_TOOL_VERSION=2.1.2 DOVI_TOOL_OK=1
    HDR10PLUS_TOOL=/opt/bin/hdr10plus_tool MKVMERGE=/usr/bin/mkvmerge
    HDR_CODEC=hevc HDR_KIND=HDR10 HDR_HDR10PLUS=1 HDR_DV=1 HDR_DV_PROFILE=8 HDR_DV_COMPAT=1
    HDR_DV_EL="" HDR_MASTER="" HDR_CLL="" HDR_PRIMARIES=bt2020 HDR_TRANSFER=smpte2084 HDR_MATRIX=bt2020nc
}

hdr_fake
eq "label: DV 8.1 + HDR10 + HDR10+"  "$(hdr_compact_label)" "Dolby Vision 8.1 + HDR10 + HDR10+"
confirm_dynamic_range Show < /dev/null > "$T/hdr1.out"
eq "compact: only PRESERVED lines"   "$(cat "$T/hdr1.out")" $'\nHDR10+:         PRESERVED\nDolby Vision:   PRESERVED'
eq "short policy"                    "$(hdr_policy_short)" "DV/HDR10+ preserved"

hdr_fake
COMPRESS_VERBOSE=1 confirm_dynamic_range Show < /dev/null > "$T/hdr2.out"
check "verbose: tool report + internals" \
    "grep -q '^HDR tools:' '$T/hdr2.out' && grep -q '/opt/bin/dovi_tool' '$T/hdr2.out' && grep -q 'RPU re-injected with dovi_tool' '$T/hdr2.out' && grep -q '^Dynamic range:' '$T/hdr2.out'"

hdr_fake
DOVI_TOOL="" DOVI_TOOL_OK=0
printf '2\n' | confirm_dynamic_range Show > "$T/hdr3.out" 2>&1
eq "warning: skip returns 1"         "$?" 1
check "warning: details + tool report" \
    "grep -q '^HDR tools:' '$T/hdr3.out' && grep -q 'dovi_tool: *not found' '$T/hdr3.out' && grep -q '^WARNING: Dolby Vision profile 8 cannot be preserved' '$T/hdr3.out' && grep -q 'dovi_tool not found (needed' '$T/hdr3.out'"

hdr_fake
HDR_HDR10PLUS=0 HDR_DV_PROFILE=7 HDR_DV_COMPAT=6
printf 'y\n' | confirm_dynamic_range Show > "$T/hdr4.out" 2>&1
check "profile 7: converted + NOTE kept" \
    "grep -q '^Dolby Vision:   PRESERVED as profile 8.1$' '$T/hdr4.out' && grep -q '^NOTE: profile 7 is dual-layer' '$T/hdr4.out' && ! grep -q 'HDR tools' '$T/hdr4.out'"

hdr_fake
HDR_DV=0 HDR_HDR10PLUS=0
confirm_dynamic_range Show < /dev/null > "$T/hdr5.out"
eq "HDR10 only: nothing printed"     "$(cat "$T/hdr5.out")" ""
eq "HDR10 only: short policy"        "$(hdr_policy_short)" "HDR10"

# ------------------------------------------------------------
for t in ffmpeg ffprobe; do
    command -v "$t" >/dev/null || { echo "$t not found: menu tests skipped"; echo; echo "passed: $PASS  failed: $FAIL"; exit $(( FAIL > 0 )); }
done

echo
echo "== series menu"

H="$T/home"
mkdir -p "$H/compress/in/Show" "$H/compress/in/Mixed" "$H/compress/out" "$T/stub"
cp -r "$SRC_WORK" "$H/compress/work"
rm -rf "$H/compress/work/tests" "$H/compress/work/logs" "$H/compress/work/cache"
rm -f "$H/compress/work"/[a-z]*[0-9].sh "$H/compress/work"/*.state "$H/compress/work"/*.progress
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"

# src SIZE SECONDS OUT  ->  lossless H.264 + AAC (every CRF estimate is far
# below it: no source-quality guard prompt)
src() {
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=$1:r=24:d=$2" -f lavfi -i "sine=f=440:r=48000:d=$2" \
        -c:v libx264 -preset ultrafast -qp 0 -pix_fmt yuv420p -c:a aac -b:a 96k "$3"
}
for e in 1 2 3; do src 320x180 2 "$H/compress/in/Show/Show.S01E0$e.mkv"; done
src 320x180 2 "$H/compress/in/Mixed/Mixed.S01E01.mkv"
src 640x360 2 "$H/compress/in/Mixed/Mixed.S01E02.mkv"

# series High CRF_MIN of the project config (where every series sample starts)
SHMIN=$(sed -n 's/^SERIES_HIGH_CRF_MIN=//p' "$H/compress/work/lib/compress.conf")

menu() {   # SCRIPT INPUT LOG [CONF]
    printf "$2" | HOME="$H" PATH="$T/stub:$PATH" COMPRESS_CONF="${4:-$H/compress/work/lib/compress.conf}" \
        bash "$H/compress/work/$1" > "$3" 2>&1
}

L="$T/series1.log"
menu series_compress.sh "2\n2\nn\n" "$L"
sed 's/^/  | /' "$L"
check "list: episodes count"             "grep -q '^2) Show \[3 episodes\]$' '$L'"
check "no policy dump"                   "! grep -qE 'Policy:|video policy|^Audio:\$|audio_compress_menu' '$L'"
check "no file names"                    "! grep -q 'Show\\.S01E0' '$L'"
check "one analysis line"                "grep -qE '^Analyzing 3 episodes\\.\\.\\. OK    Source stats: (scanned|scanned \\+ refreshed)    Compatibility: OK\$' '$L'"
check "header"                           "grep -qE '^Series: +Show +Episodes: 3\$' '$L' && grep -qE '^Video: +320x180 H264 8-bit\$' '$L' && grep -qE '^Dynamic range: +SDR\$' '$L' && grep -qE '^Audio: +1 track, copied unchanged\$' '$L'"
check "avg video from stats"             "grep -qE '^Avg video: +[0-9]+\\.[0-9]{2} GiB/episode   [0-9]+\\.[0-9] Mb/s\$' '$L'"
check "tier menu"                        "grep -qE '^1\\) Base    CRF [0-9]+-[0-9]+ +<=[0-9.]+ GiB/episode\$' '$L' && grep -qE '^2\\) High    CRF $SHMIN-21 +<=5 GiB/episode\$' '$L' && grep -q '^3) Custom  exact CRF' '$L'"
check "no repeated tier policy"          "! grep -q 'CRF range' '$L'"
check "estimating line"                  "grep -q '^Estimating High at 320x180\\.\\.\\.\$' '$L'"
check "per-episode samples"              "grep -q '^CRF $SHMIN\$' '$L' && [[ \$(grep -cE '^  S01E0[123]  ~[0-9]+\\.[0-9]{2} GiB\$' '$L') == 3 ]]"
check "CRF result"                       "grep -qE '^Median: +[0-9.]+ GiB\$' '$L' && grep -qE '^Largest: +[0-9.]+ GiB\$' '$L' && grep -q '^Ceiling:  5.00 GiB\$' '$L' && grep -q '^Selected: CRF $SHMIN\$' '$L'"
check "no long blocks"                   "! grep -qE '^Tier:|Video encode:|Per-episode rules|Object audio|Season totals|^-----' '$L'"
check "table header, no extra columns"   "grep -q '^Episode   Runtime   Video   Audio   Total\$' '$L' && ! grep -qE 'Estimate|Status|^ *CRF +Video' '$L'"
check "table rows"                       "[[ \$(grep -cE '^S01E0[123]    0:02      [0-9.]+ +[0-9.]+ +[0-9.]+\$' '$L') == 3 ]]"
check "season block"                     "grep -q '^Season:\$' '$L' && grep -qE '^  Video:   ~[0-9.]+ GiB\$' '$L' && grep -qE '^  Audio:   ~[0-9.]+ GiB\$' '$L' && grep -qE '^  Total:   ~[0-9.]+ GiB\$' '$L' && grep -qE '^  Average: ~[0-9.]+ GiB/episode\$' '$L'"
check "no median/largest in season"      "! grep -qE '^  (Median|Largest|Above)' '$L'"
check "confirmation line"                "grep -q '^High | CRF $SHMIN | 320x180 | SDR | audio copied\$' '$L'"
check "compact: no ANSI / tabs / long lines" "compact '$L'"

L="$T/series_verbose.log"
COMPRESS_VERBOSE=1 menu series_compress.sh "2\n2\nn\n" "$L"
check "verbose: policy"                  "grep -q '^Policy: ' '$L' && grep -q '^High video policy:' '$L'"
check "verbose: per-file verification"   "grep -q '^OK        Show.S01E01.mkv\$' '$L' && grep -q '^All files match.\$' '$L'"
check "verbose: stats source"            "grep -q 'stored MKV statistics tags: 3 files' '$L' || grep -q 'packet scan: 3 files' '$L'"
check "verbose: sampling detail"         "grep -q 'sampling CRF $SHMIN, episode 1/3 (Show.S01E01.mkv)' '$L'"
check "verbose: long summary"            "grep -q '^Season totals' '$L' && grep -q 'Per-episode rules' '$L'"
check "verbose: no ANSI when redirected" "! grep -q \"\$ESC\" '$L'"

if command -v mkvpropedit >/dev/null; then
    L="$T/series2.log"
    menu series_compress.sh "2\n2\nn\n" "$L"
    check "stats cached on the next run" "grep -qE '^Analyzing 3 episodes\\.\\.\\. OK    Source stats: cached    Compatibility: OK\$' '$L'"
fi

L="$T/series_start.log"
menu series_compress.sh "2\n2\ny\n" "$L"
check "job: one CRF retry item per episode" "! grep -q '^job_batch_add' '$H/compress/work/series1.sh' && [[ \$(grep -c '^   item_crf_encode item_encode_' '$H/compress/work/series1.sh') == 3 ]] && [[ \$(grep -c 'ceiling_vbytes=5368709120 crf_min=$SHMIN crf_max=21 down_headroom_pct=20 down_max=1 down_fit_pct=5 crf_est=$SHMIN=[0-9]' '$H/compress/work/series1.sh') == 3 ]]"
rm -rf "$H/compress/out/Show"

L="$T/series_mismatch.log"
menu series_compress.sh "1\n" "$L"
sed 's/^/  | /' "$L"
check "mismatch: flagged"                "grep -qE '^Analyzing 2 episodes\\.\\.\\. OK    Source stats: .*    Compatibility: MISMATCH\$' '$L'"
check "mismatch: file + details shown"   "grep -q '^MISMATCH  Mixed.S01E02.mkv\$' '$L' && grep -q -- '- resolution 640x360 vs 320x180' '$L' && grep -q 'Compression cancelled.' '$L'"

cp "$H/compress/work/lib/compress.conf" "$T/tiny.conf"
sed -i 's/^SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=.*/SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=0.000001/' "$T/tiny.conf"
L="$T/series_ceiling.log"
menu series_compress.sh "2\n2\n1\nn\n" "$L" "$T/tiny.conf"
sed -n '/^Estimating/,$p' "$L" | sed 's/^/  | /'
# far above the ceiling: the adaptive search jumps 2 CRFs at a time,
# CRF_MAX (21) is the last step
check "ceiling: too large -> jumping 2 CRFs" "grep -q '^Result:   too large -> jumping to CRF $((SHMIN + 2))\$' '$L' && ! grep -q '^CRF $((SHMIN + 1))\$' '$L'"
check "ceiling: last step clamped to 21"     "grep -qE '^Result:   too large -> (trying|jumping to) CRF 21\$' '$L' && grep -q '^CRF 21\$' '$L' && ! grep -q '^CRF 22\$' '$L'"
check "ceiling: limit reached"           "grep -q '^Result:   too large (CRF 21 is the High limit)\$' '$L' && ! grep -q '^Selected:' '$L'"
check "ceiling: warning kept"            "grep -q '^WARNING: the 0.000001 GiB per-episode video ceiling cannot be met' '$L' && grep -q 'gives a largest regular episode of' '$L'"
check "ceiling: outliers listed"         "grep -q 'Warning: 3 episodes are estimated above' '$L' && grep -qE '^  S01E01 +~[0-9.]+ GiB video, \+' '$L'"
check "ceiling: Status column"           "grep -q '^Episode   Runtime   Video   Audio   Total   Status\$' '$L' && [[ \$(grep -c ' ABOVE CEILING\$' '$L') == 3 ]]"
check "ceiling: confirmation flags it"   "grep -q '^High | CRF 21 | 320x180 | SDR | audio copied | ceiling not met\$' '$L'"
check "ceiling: compact"                 "compact '$L'"

if (( HAVE_SCRIPT == 1 )); then
    script -qec "printf '2\n2\nn\n' | HOME=$H PATH=$T/stub:\$PATH bash $H/compress/work/series_compress.sh" /dev/null \
        > "$T/series_tty.log" 2>&1
    check "terminal: OK green, CRF bold"  "grep -qF \$'\\e[32mOK\\e[0m' '$T/series_tty.log' && grep -qF \$'\\e[1mCRF $SHMIN\\e[0m' '$T/series_tty.log'"
    # (no prompt check: read -p shows it only when stdin is a terminal)
    check "terminal: progress counter"    "grep -qF 'Analyzing 3 episodes... 1/3' '$T/series_tty.log'"
fi

# ------------------------------------------------------------
echo
echo "== movie menu"

src 320x180 2 "$H/compress/in/Film.mkv"

L="$T/movie1.log"
menu movie_compress.sh "1\n2\nn\n" "$L"
sed 's/^/  | /' "$L"
check "no policy dump"                   "! grep -qE 'Policy:|video policy|^Audio:\$' '$L'"
check "analysis line"                    "grep -qE '^Analyzing source\\.\\.\\. OK    Source stats: (scanned|scanned \\+ refreshed)\$' '$L'"
check "header"                           "grep -qE '^Source: +Film.mkv\$' '$L' && grep -qE '^Runtime: +00:00:02\$' '$L' && grep -qE '^Video: +320x180 H264 8-bit +[0-9.]+ Mb/s   [0-9.]+ GiB\$' '$L' && grep -qE '^Dynamic range: +SDR\$' '$L' && grep -qE '^Audio: +1 track, [0-9.]+ GiB, copied unchanged\$' '$L'"
check "tier menu"                        "grep -qE '^1\\) Quality  CRF search  <=[0-9.]+ GiB \\(source-limited\\)\$' '$L' && grep -qE '^2\\) High     CRF 12-23 +<=7 GiB\$' '$L' && grep -q '^4) Custom   exact CRF' '$L'"
check "estimating + samples"             "grep -q '^Estimating High at 320x180\\.\\.\\.\$' '$L' && grep -qE '^  CRF 12   ~[0-9.]+ GiB\$' '$L' && ! grep -q 'sampling CRF' '$L'"
check "CRF result"                       "grep -qE '^Video: +~[0-9.]+ GiB\$' '$L' && grep -q '^Ceiling:  7.00 GiB\$' '$L' && grep -q '^Selected: CRF 12\$' '$L' && grep -qE '^Total: +~[0-9.]+ GiB\$' '$L'"
check "compact summary"                  "grep -q '^Added: Film.mkv\$' '$L' && grep -q '^  High | CRF 12 | 320x180 | SDR | audio copied\$' '$L' && grep -q '^  Output: Film HEVC High.mkv\$' '$L'"
check "no long summary"                  "! grep -qE 'Video encode:|Compression tier: +High|^-----|Object audio' '$L'"
check "compact: no ANSI / tabs / long lines" "compact '$L'"
check "job: High CRF retry planned"      "grep -q 'mode=crf crf=12 .* ceiling_vbytes=7516192768 crf_min=12 crf_max=23' '$H/compress/work/c1.sh' && grep -q '^   item_crf_encode item_encode_1\$' '$H/compress/work/c1.sh'"

rm -f "$H/compress/work"/c[0-9]*.sh "$H/compress/work"/*.state
L="$T/movie_verbose.log"
COMPRESS_VERBOSE=1 menu movie_compress.sh "1\n2\nn\n" "$L"
check "verbose: policy + sampling + summary" \
    "grep -q '^Policy: ' '$L' && grep -q 'sampling CRF 12 (' '$L' && grep -q '^Values from: ' '$L' && grep -q '^Added:\$' '$L' && grep -q 'Video encode: *x265 CRF 12' '$L'"

# Quality: the tiny source is smaller than the 20 GiB target -> source guard
# first; "encode anyway" = lowest Quality CRF estimated below the source
rm -f "$H/compress/work"/c[0-9]*.sh "$H/compress/work"/*.state "$H/compress/out"/*.mkv
L="$T/movie_quality.log"
menu movie_compress.sh "1\n1\n2\nn\n" "$L"
sed -n '/^Compression tier:/,$p' "$L" | sed 's/^/  | /'
check "Quality: source guard before sampling" \
    "grep -q '^Quality source guard: the source video (0.00 GiB) is already at or' '$L' && grep -q '^1) (not available: keeping the source video needs an HEVC source,' '$L' && [[ \$(grep -n 'Quality source guard' '$L' | cut -d: -f1) -lt \$(grep -n '^Estimating Quality' '$L' | cut -d: -f1) ]]"
check "Quality: source-limited estimate" \
    "grep -q '^Estimating Quality at 320x180\\.\\.\\.\$' '$L' && grep -q '^Target:   below the source video (0.00 GiB)\$' '$L' && grep -q '^Band:     not applied (source-limited)\$' '$L' && grep -qE '^Selected: CRF [0-9]+\$' '$L'"
check "Quality (source-limited): search starts at CRF_START (8)" \
    "[[ \"\$(grep -A1 '^Estimating Quality at 320x180\\.\\.\\.\$' '$L' | tail -n 1)\" =~ ^'  CRF 8    ~' ]]"
check "Quality: never called two-pass"   "! grep -qi 'two-pass' '$L'"
check "Quality: compact"                 "compact '$L'"
QJ=$(ls "$H/compress/work"/c[0-9]*.sh 2>/dev/null | head -n 1)
check "Quality job (source-limited): CRF, below the source, no lower CRF" \
    "[[ -n '$QJ' ]] && grep -q 'mode=crf crf=' '$QJ' && grep -q 'qstatus=source-limited' '$QJ' && grep -q 'down_max=0' '$QJ' && ! grep -q 'down_below_vbytes' '$QJ'"

# Quality with a band the source can reach: CRF search from CRF_MIN up
cp "$H/compress/work/lib/compress.conf" "$T/qtiny.conf"
sed -i 's/^MOVIE_QUALITY_TARGET_VIDEO_GIB=.*/MOVIE_QUALITY_TARGET_VIDEO_GIB=0.00012/; s/^MOVIE_QUALITY_ACCEPT_MIN_GIB=.*/MOVIE_QUALITY_ACCEPT_MIN_GIB=0.00001/; s/^MOVIE_QUALITY_ACCEPT_MAX_GIB=.*/MOVIE_QUALITY_ACCEPT_MAX_GIB=0.0002/; s/^MOVIE_QUALITY_CRF_MIN=.*/MOVIE_QUALITY_CRF_MIN=20/; s/^MOVIE_QUALITY_CRF_START=.*/MOVIE_QUALITY_CRF_START=30/; s/^MOVIE_QUALITY_CRF_MAX=.*/MOVIE_QUALITY_CRF_MAX=45/' "$T/qtiny.conf"
rm -f "$H/compress/work"/c[0-9]*.sh "$H/compress/work"/*.state "$H/compress/out"/*.mkv
L="$T/movie_quality2.log"
menu movie_compress.sh "1\n1\nn\n" "$L" "$T/qtiny.conf"
sed -n '/^Compression tier:/,$p' "$L" | sed 's/^/  | /'
check "Quality: CRF search menu line"    "grep -q '^1) Quality  CRF search  ~0.00012 GiB (0.00001-0.0002)\$' '$L'"
check "Quality: search starts at CRF_START (30), not CRF_MIN (20)" \
    "[[ \"\$(grep -A1 '^Estimating Quality at 320x180\\.\\.\\.\$' '$L' | tail -n 1)\" =~ ^'  CRF 30   ~'[0-9.]+' GiB'\$ ]] && ! grep -q 'source guard' '$L'"
check "Quality: each CRF estimated once, in one direction" \
    "awk '/^Estimating Quality/ { on = 1; next } on && /^  CRF / { print \$2 } on && /^\$/ { exit }' '$L' > '$T/qcrfs' && [[ \$(sort '$T/qcrfs' | uniq -d | wc -l) == 0 ]] && { sort -n '$T/qcrfs' | cmp -s - '$T/qcrfs' || sort -rn '$T/qcrfs' | cmp -s - '$T/qcrfs'; }"
check "Quality: normal UI never shows START or 'minimum'" "! grep -qiE 'start|minimum' <(sed -n '/^Compression tier:/,/^Added:/p' '$L')"
check "Quality: Video / Target / Band / Selected / Audio / Total" \
    "grep -qE '^Video:    ~[0-9.]+ GiB\$' '$L' && grep -q '^Target:   0.00 GiB\$' '$L' && grep -q '^Band:     0.00-0.00 GiB\$' '$L' && grep -qE '^Selected: CRF [0-9]+' '$L' && grep -qE '^Audio:    ~[0-9.]+ GiB copied\$' '$L' && grep -qE '^Total:    ~[0-9.]+ GiB\$' '$L'"
check "Quality: queue summary says CRF"  "grep -qE '^  Quality \\| CRF [0-9]+ \\| 320x180 \\| SDR \\| audio copied\$' '$L'"
check "Quality: never called two-pass"   "! grep -qi 'two-pass' '$L'"
check "Quality: compact"                 "compact '$L'"
QJ=$(ls "$H/compress/work"/c[0-9]*.sh 2>/dev/null | head -n 1)
check "Quality job: single-pass CRF, no two-pass" \
    "[[ -n '$QJ' ]] && grep -q -- '-crf:v:0' '$QJ' && ! grep -qE 'pass=1|pass=2|stats=|-b:v' '$QJ' && ! ls -d '$H/compress/work'/c[0-9]*_passes >/dev/null 2>&1"
check "Quality job: band retry planned (audio not part of it)" \
    "grep -q 'qtarget_vbytes=128849 qmin_vbytes=10737 qmax_vbytes=214748 qstatus=band down_below_vbytes=10737' '$QJ' && grep -q '^   item_crf_encode item_encode_1\$' '$QJ'"

rm -f "$H/compress/work"/c[0-9]*.sh "$H/compress/work"/*.state "$H/compress/out"/*.mkv
L="$T/movie_quality3.log"
COMPRESS_VERBOSE=1 menu movie_compress.sh "1\n1\nn\n" "$L" "$T/qtiny.conf"
check "Quality verbose: CRF policy, no two-pass" \
    "grep -q '^Quality CRF search:$' '$L' && grep -q '^  Range: 20-45$' '$L' && grep -q '^  Start: 30 (first CRF sampled' '$L' && grep -q '^  Target: 0.00012 GiB$' '$L' && grep -q '^  Band: 0.00001-0.0002 GiB' '$L' && grep -q '^1) Quality     CRF search (start 30, range 20-45), video ~0.00012 GiB (0.00001-0.0002)$' '$L' && grep -q 'Video encode: *x265 CRF' '$L' && ! grep -qi 'two-pass' '$L'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
