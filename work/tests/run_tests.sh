#!/usr/bin/env bash
# Regression tests for the encode pipeline (Linux, no sudo).
#
#   bash ~/compress/work/tests/run_tests.sh [--keep]
#
#  1. bash -n on every script
#  2. unit: audio title rewriting / false-claim detection (Atmos, DTS:X,
#     codec names, bitrates, commentary text kept)
#  3. SDR source, audio copied: plain two-pass job (no DV steps); tracks,
#     flags, languages, titles (unchanged), chapters, attachments kept
#  4. HDR10 source, audio -> AAC: HDR10 metadata kept; transcoded audio
#     titles rewritten and verified
#  5. MP4 source with styled mov_text: conversion + styling loss reported
#  6. needs mkvtoolnix: ordered chapters / 2 editions / nesting / hidden
#     / multi-language names / segment reference restored and verified
#  7. needs dovi_tool + mkvtoolnix: synthetic Dolby Vision profile 8.1,
#     DV preserved and downscaled, L5 offsets rescaled
#
# Runs in a temporary copy of work/ so real logs/jobs are untouched.
# Everything here is synthetic: it proves the mechanics, not behaviour
# with real discs (real Profile 8 / 7 sources are not covered).
set -uo pipefail

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
PASS=0
FAIL=0
SKIPPED=()

cleanup() {
    if (( KEEP == 1 )); then
        echo "Kept: $T"
    else
        rm -rf -- "$T"
    fi
}
trap cleanup EXIT

ok()   { echo "  ok    $1"; ((PASS += 1)); }
bad()  { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

# ------------------------------------------------------------
echo "== syntax"
while IFS= read -r f; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n ${f#"$ROOT"/}"; else bad "bash -n ${f#"$ROOT"/}"; fi
done < <(find "$ROOT" -name '*.sh' -not -path '*/in/*' -not -path '*/out/*' -not -path '*/logs/*' | sort)

# ------------------------------------------------------------
echo
echo "== discovery: regular files and symlinks"
source "$SRC_WORK/lib/media_probe.sh"
{
    D="$T/disc"
    mkdir -p "$D/in" "$D/store/Show" "$D/in/RealShow"
    : > "$D/in/Normal.mkv"                                # 1 normal only
    : > "$D/store/Linked.mkv"
    ln -s ../store/Linked.mkv "$D/in/OnlyLink.mkv"        # 2 symlink only
    : > "$D/in/Both.mkv"
    ln -s Both.mkv "$D/in/0-alias-of-both.mkv"            # 3 normal + symlink (sorts first)
    ln -s missing.mkv "$D/in/Broken.mkv"                  # 4 broken symlink
    : > "$D/store/Show/S01E01.mkv"
    ln -s ../store/Show "$D/in/LinkedShow"                # 5 symlinked series dir
    : > "$D/in/RealShow/E01.mkv"
    ln -s RealShow "$D/in/AliasShow"                      #   + alias of a real dir
    ln -s .. "$D/in/RealShow/up"                          # 6 circular dir symlinks
    ln -s . "$D/in/self"

    movies=$(video_files_in_dir "$D/in" 2> "$D/warn.txt")
    eq "1 normal file listed"            "$(grep -c '/Normal.mkv$' <<< "$movies")" 1
    eq "2 symlink-only file listed"      "$(grep -c '/OnlyLink.mkv$' <<< "$movies")" 1
    eq "3 regular file preferred"        "$(grep -c '/Both.mkv$' <<< "$movies")" 1
    eq "3 duplicate symlink not listed"  "$(grep -c 'alias-of-both' <<< "$movies")" 0
    eq "4 broken symlink not listed"     "$(grep -c '/Broken.mkv$' <<< "$movies")" 0
    check "4 broken symlink warned"      "grep -q 'broken symlink skipped: .*/Broken.mkv' '$D/warn.txt'"
    eq "movie list size"                 "$(grep -c . <<< "$movies")" 3

    dirs=$(series_dirs "$D/in" 2> "$D/warn2.txt")
    eq "5 symlinked series dir listed"   "$(grep -c '/LinkedShow$' <<< "$dirs")" 1
    eq "5 real dir preferred over alias" "$(grep -c '/RealShow$' <<< "$dirs")/$(grep -c '/AliasShow$' <<< "$dirs")" "1/0"
    eq "6 dir loop to root not a series" "$(grep -c '/self$' <<< "$dirs")" 0
    check "6 dir loop warned"            "grep -q 'circular directory symlink skipped: .*/self' '$D/warn2.txt'"
    eq "5 episodes through dir symlink"  "$(video_files_in_dir "$D/in/LinkedShow" 2>/dev/null)" "$D/in/LinkedShow/S01E01.mkv"

    all=$(timeout 20 bash -c 'source "$1"; media_files_recursive "$2" | tr "\0" "\n"' _ \
        "$SRC_WORK/lib/media_probe.sh" "$D/in" 2> "$D/warn3.txt")
    eq "6 recursion terminates"          "$?" 0
    eq "6 no duplicates in recursion"    "$(sort <<< "$all" | uniq -d | grep -c .)" 0
    eq "6 each target once"              "$(while IFS= read -r f; do readlink -f -- "$f"; done <<< "$all" | sort | uniq -d | grep -c .)" 0
    eq "recursive finds 5 files"         "$(grep -c . <<< "$all")" 5
    check "6 recursive loop warned"      "grep -q 'circular directory symlink skipped' '$D/warn3.txt'"
    check "symlinks left untouched"      "[[ -L '$D/in/OnlyLink.mkv' && -L '$D/in/LinkedShow' && -L '$D/in/Broken.mkv' ]]"
    eq "file_bytes follows symlink"      "$(printf 12345 > "$D/store/Linked.mkv"; file_bytes "$D/in/OnlyLink.mkv")" 5
}

for t in ffmpeg ffprobe; do
    command -v "$t" >/dev/null || { echo "$t not found: functional tests skipped"; exit $(( FAIL > 0 )); }
done

# ------------------------------------------------------------
# sandbox
WORK_DIR="$T/work"
mkdir -p "$T/in" "$T/out" "$WORK_DIR"
cp -r "$SRC_WORK/lib" "$WORK_DIR/"
[[ -d "$SRC_WORK/bin" ]] && cp -r "$SRC_WORK/bin" "$WORK_DIR/bin"

for l in media_probe media_stats bitrate encode_common hdr_dovi policy; do
    source "$WORK_DIR/lib/$l.sh"
done

# the project's default policy file (work/lib/compress.conf)
cp "$SRC_WORK/lib/compress.conf" "$T/compress.conf"
export COMPRESS_CONF="$T/compress.conf"

HAVE_MKV=0
command -v mkvmerge >/dev/null && command -v mkvextract >/dev/null &&
    command -v mkvpropedit >/dev/null && HAVE_MKV=1

# ------------------------------------------------------------
echo
echo "== policy: compress.conf loading and validation"

# expected values are computed from the config, not hardcoded
exp_clamp() {   # size_gib floor max dur  ->  clamp(bitrate(size), floor, max>0 ? max : inf)
    awk -v g="$1" -v f="$2" -v m="$3" -v d="$4" 'BEGIN {
        t = g * 1073741824 * 8 / d / 1000000
        if (m > 0 && t > m) t = m
        if (t < f) t = f
        printf "%.3f", t }'
}

check "default compress.conf loads"           "load_policy 2>'$T/pol.err'"
{
    load_policy 2>/dev/null
    for tier in High Base; do
        u=${tier^^}; g="MOVIE_${u}_VIDEO_TARGET_GIB"; f="MOVIE_${u}_VIDEO_FLOOR_MBPS"; m="MOVIE_${u}_VIDEO_MAX_MBPS"
        for dur in 1800 5400 9000 20000; do
            movie_video_plan "$tier" "$dur"
            eq "movie $tier ${dur}s target from config" "$PLAN_TARGET_MBPS" "$(exp_clamp "${!g}" "${!f}" "${!m}" "$dur")"
        done
    done

    movie_video_plan Quality 5400
    eq "movie Quality 90 min = min(max Mb/s, size)" "$PLAN_TARGET_MBPS" \
        "$(awk -v m="$MOVIE_QUALITY_VIDEO_MAX_MBPS" -v g="$MOVIE_QUALITY_VIDEO_MAX_GIB" 'BEGIN {
            s = g * 1073741824 * 8 / 5400 / 1000000; printf "%.3f", (m < s ? m : s) }')"
    eq "movie Quality 90 min not below floor" "$PLAN_BELOW_FLOOR" 0
    movie_video_plan Quality 20000
    eq "movie Quality 5.5 h below floor -> asks" "$PLAN_BELOW_FLOOR" 1

    eq "movie High AAC 5.1 from config"   "$(movie_aac_kbps High 6)" "$MOVIE_HIGH_AAC_KBPS_6"
    eq "movie Base AAC stereo from config" "$(movie_aac_kbps Base 2)" "$MOVIE_BASE_AAC_KBPS_2"
    eq "movie High audio cap from config" "$(movie_audio_cap_gib High)" "$MOVIE_HIGH_AUDIO_MAX_GIB"
    eq "movie Quality audio copied"       "$(movie_audio_cap_gib Quality)" 0
    eq "series Base AAC 5.1 from config"  "$(series_aac_kbps Base 6)" "$SERIES_BASE_AAC_KBPS_6"
    eq "series Custom uses High AAC"      "$(series_aac_kbps Custom 2)" "$SERIES_HIGH_AAC_KBPS_2"
    eq "series reserve from config"       "$(series_media_kbps 10000)" \
        "$(awk -v r="$SERIES_CONTAINER_RESERVE_PCT" 'BEGIN { printf "%.0f", 10000 * (100 - r) / 100 }')"
    eq "audio menu High 5.1 from config"  "$(audio_menu_high_kbps 6)" "$AUDIO_HIGH_KBPS_5TO6"
}

# changing compress.conf changes the calculated targets
conf_with() {   # NAME KEY=VALUE...  ->  modified copy of the default config
    local f="$T/conf_$1.conf" kv
    shift
    cp "$SRC_WORK/lib/compress.conf" "$f"
    for kv in "$@"; do
        sed -i "s|^${kv%%=*}=.*|${kv}|" "$f"
        grep -q "^${kv%%=*}=" "$f" || echo "$kv" >> "$f"
    done
    printf '%s' "$f"
}

{
    load_policy 2>/dev/null
    movie_video_plan High 5400; before="$PLAN_TARGET_MBPS"
    COMPRESS_CONF=$(conf_with high5 MOVIE_HIGH_VIDEO_TARGET_GIB=5 MOVIE_HIGH_VIDEO_FLOOR_MBPS=4 MOVIE_HIGH_VIDEO_MAX_MBPS=9)
    load_policy 2>/dev/null
    movie_video_plan High 5400
    check "edited conf changes High target"  "[[ '$PLAN_TARGET_MBPS' != '$before' ]]"
    eq "edited conf High target = new values" "$PLAN_TARGET_MBPS" "$(exp_clamp 5 4 9 5400)"

    COMPRESS_CONF=$(conf_with nomax MOVIE_HIGH_VIDEO_MAX_MBPS=0 MOVIE_HIGH_VIDEO_TARGET_GIB=40)
    load_policy 2>/dev/null
    movie_video_plan High 5400
    eq "MAX_MBPS=0: size decides"         "$PLAN_TARGET_MBPS" "$(exp_clamp 40 "$MOVIE_HIGH_VIDEO_FLOOR_MBPS" 0 5400)"

    COMPRESS_CONF=$(conf_with qnomax MOVIE_QUALITY_VIDEO_MAX_MBPS=0)
    load_policy 2>/dev/null
    movie_video_plan Quality 5400
    eq "Quality MAX_MBPS=0: size ceiling" "$PLAN_TARGET_MBPS" "$(bitrate_for_gib "$MOVIE_QUALITY_VIDEO_MAX_GIB" 5400)"

    COMPRESS_CONF=$(conf_with aac MOVIE_HIGH_AAC_KBPS_6=500 MOVIE_HIGH_AAC_KBPS_2=100)
    load_policy 2>/dev/null
    eq "edited AAC rates in audio args"   "$(build_audio_args 10000 "6 2" High)" "-c:a aac -b:a:0 500k -b:a:1 100k"

    COMPRESS_CONF=$(conf_with series SERIES_BASE_TOTAL_GIB_PER_HOUR=2.5 SERIES_BASE_AAC_KBPS_6=300)
    load_policy 2>/dev/null
    eq "edited series GiB/hour"           "$(series_gib_per_hour Base)" 2.5
    eq "edited series AAC rate"           "$(series_aac_kbps Base 6)" 300

    COMPRESS_CONF=$(conf_with qaudio MOVIE_QUALITY_AUDIO_MODE=cap MOVIE_QUALITY_AUDIO_MAX_GIB=3)
    load_policy 2>/dev/null
    eq "Quality audio mode cap"           "$(movie_audio_cap_gib Quality)" 3
}
COMPRESS_CONF="$T/compress.conf"

reject() {   # LABEL PATTERN KEY=VALUE...
    local label="$1" pat="$2"
    shift 2
    reject_file "$label" "$pat" "$(conf_with "rej$RANDOM" "$@")"
}
reject_file() {   # LABEL PATTERN CONF
    local label="$1" pat="$2" f="$3"
    if ( COMPRESS_CONF="$f" load_policy ) > "$T/rej.out" 2>&1; then
        bad "rejects $label (was accepted)"
    elif grep -q -- "$pat" "$T/rej.out"; then
        ok "rejects $label"
    else
        bad "rejects $label (message: $(tr '\n' ' ' < "$T/rej.out"))"
    fi
}
reject "negative size"            "must not be negative"     MOVIE_HIGH_VIDEO_TARGET_GIB=-3
reject "negative bitrate"         "must not be negative"     MOVIE_BASE_VIDEO_FLOOR_MBPS=-1
reject "non-numeric value"        "not a number"             MOVIE_HIGH_VIDEO_MAX_MBPS=twelve
reject "floor above nonzero max"  "is greater than MOVIE_HIGH_VIDEO_MAX_MBPS" MOVIE_HIGH_VIDEO_FLOOR_MBPS=15
reject "zero size target"         "must be greater than 0"   MOVIE_BASE_VIDEO_TARGET_GIB=0
reject "decimal kb/s"             "whole number of kb/s"     SERIES_HIGH_AAC_KBPS_6=640.5
reject "bad audio mode"           "must be \"copy\" or \"cap\"" MOVIE_QUALITY_AUDIO_MODE=lossless
reject "Quality without ceiling"  "Quality needs a size or bitrate ceiling" MOVIE_QUALITY_VIDEO_MAX_GIB=0 MOVIE_QUALITY_VIDEO_MAX_MBPS=0
reject "bad Base audio choice"    "is not a size greater than 0" 'MOVIE_BASE_AUDIO_MAX_GIB_CHOICES="1 none"'
f=$(conf_with unset); sed -i '/^SERIES_MIN_VIDEO_KBPS=/d' "$f"
reject_file "missing setting"     "SERIES_MIN_VIDEO_KBPS is not set" "$f"
reject_file "missing file"        "Compression policy file not found" "$T/nope.conf"
check "floor = 0 max = 0 allowed" "( COMPRESS_CONF=\$(conf_with zero MOVIE_HIGH_VIDEO_FLOOR_MBPS=0 MOVIE_HIGH_VIDEO_MAX_MBPS=0) load_policy )"
check "no policy numbers left in movie menu" \
    "! grep -nE '(VIDEO_(FLOOR|PREFERRED|UPPER|MAX_GIB|TARGET_GIB))=[0-9]|AUDIO_CAP_GIB=[0-9]|echo (768|640|512|448|320|256|192|128|96|64)\$' '$SRC_WORK/movie_compress.sh'"
check "no policy numbers left in series menu" \
    "! grep -nE 'echo (768|640|384|320|256|192|128|96|64)\$|GIB_PER_HOUR=\"[0-9]|0\\.99|< 500' '$SRC_WORK/series_compress.sh'"
check "no policy numbers left in audio menu" \
    "! grep -nE 'TRIGGER_KBPS=[0-9]|LIMIT_GIB=\"?[0-9]|echo (1280|1024|640|384|320|192|128|96)\$' '$ROOT/audio_compress_menu.sh'"

load_policy 2>/dev/null

# ------------------------------------------------------------
echo
echo "== output path is a symlink"
OS="$T/osym"
mkdir -p "$OS/out" "$OS/store"
printf 'precious target\n' > "$OS/store/target.mkv"
TSUM=$(md5sum < "$OS/store/target.mkv")
ln -s "$OS/store/target.mkv" "$OS/out/Valid.mkv"
ln -s "$OS/store/missing.mkv" "$OS/out/Broken.mkv"

check "valid symlink counts as taken"     "path_taken '$OS/out/Valid.mkv'"
check "broken symlink counts as taken"    "path_taken '$OS/out/Broken.mkv'"
eq    "unique name skips a broken symlink" "$(unique_output_path "$OS/out/Broken.mkv")" "$OS/out/Broken (2).mkv"

for kind in Valid Broken; do
    resolve_output_conflict "$OS/out/$kind.mkv" <<< "3" > "$T/roc_$kind.out" 2>&1; rc=$?
    eq "$kind symlink + cancel: skipped"   "$rc" 1
    check "$kind symlink + cancel: link kept" "[[ -L '$OS/out/$kind.mkv' ]]"

    resolve_output_conflict "$OS/out/$kind.mkv" <<< "2" > "$T/roc2_$kind.out" 2>&1; rc=$?
    eq "$kind symlink + overwrite: confirmed" "$rc/$RESOLVED_OVERWRITE/$RESOLVED_OUT" "0/1/$OS/out/$kind.mkv"
done
check "valid symlink notice"   "grep -q 'Existing output is a symlink:' '$T/roc_Valid.out' && grep -q 'Overwrite will replace the symlink itself.' '$T/roc_Valid.out' && grep -q 'The target file will NOT be modified.' '$T/roc_Valid.out' && grep -q -- '-> $OS/store/target.mkv' '$T/roc_Valid.out'"
check "broken symlink notice"  "grep -q 'Existing output is a broken symlink:' '$T/roc_Broken.out' && grep -q -- '-> $OS/store/missing.mkv' '$T/roc_Broken.out'"
check "overwrite option names the symlink" "grep -q '2) Overwrite: replace the symlink itself' '$T/roc_Valid.out' && grep -q '2) Overwrite: replace the broken symlink' '$T/roc_Broken.out'"
eq    "target unchanged after cancel/confirm" "$(md5sum < "$OS/store/target.mkv")" "$TSUM"

echo
echo "== unit: audio titles after transcoding"
eq "TrueHD Atmos -> AAC"            "$(audio_title_rewrite "English TrueHD Atmos" aac 8)"           "English AAC"
eq "TrueHD Atmos 7.1 -> AAC"        "$(audio_title_rewrite "English TrueHD Atmos 7.1" aac 8)"       "English AAC 7.1"
eq "commentary text kept"           "$(audio_title_rewrite "Director Commentary - AC-3" aac 2)"     "Director Commentary - AAC"
eq "brackets kept"                  "$(audio_title_rewrite "Director's Commentary (AC3 2.0)" aac 2)" "Director's Commentary (AAC 2.0)"
eq "DTS-HD MA + tech details"       "$(audio_title_rewrite "DTS-HD MA 5.1 [24-bit/48kHz]" aac 6)"    "AAC 5.1"
eq "DTS:X removed, codec replaced"  "$(audio_title_rewrite "DTS:X 7.1" opus 8)"                      "Opus 7.1"
eq "E-AC-3 re-encode drops Atmos"   "$(audio_title_rewrite "DDP 5.1 Atmos" eac3 6)"                  "DDP 5.1"
eq "bitrate removed"                "$(audio_title_rewrite "Dolby Digital Plus 5.1 Atmos @ 768 kbps" eac3 6)" "Dolby Digital Plus 5.1"
eq "glued DD5.1"                    "$(audio_title_rewrite "DD5.1" aac 6)"                           "AAC 5.1"
eq "Atmos only: nothing invented"   "$(audio_title_rewrite "English Atmos" aac 8)"                   "English"
eq "neutral title unchanged"        "$(audio_title_rewrite "Surround 5.1" aac 6)"                    "Surround 5.1"
eq "word containing codec letters"  "$(audio_title_rewrite "Added Scenes Commentary" aac 2)"         "Added Scenes Commentary"
eq "wrong layout removed"           "$(audio_title_rewrite "English 7.1" aac 6)"                     "English"
eq "check: accurate TrueHD Atmos"   "$(audio_title_false_claims "TrueHD Atmos 7.1" truehd 8 "Dolby TrueHD + Dolby Atmos")" ""
eq "check: stale on AAC"            "$(audio_title_false_claims "TrueHD Atmos 7.1" aac 8 "LC")"     "Atmos, TrueHD"
eq "check: DTS:X on AAC"            "$(audio_title_false_claims "DTS:X" aac 8 "LC")"                "DTS:X"
eq "check: rewritten title clean"   "$(audio_title_false_claims "$(audio_title_rewrite "Dolby TrueHD 7.1 Atmos 4000 kbps" aac 8)" aac 8 "LC")" ""

# ------------------------------------------------------------
# synthetic sources: video + 2 audio + 3 subtitles + chapters + font
make_extras() {
    ffmpeg -v error -y -f lavfi -i "sine=f=440:d=2:r=48000" \
        -af "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a ac3 -b:a 384k "$T/a51.mka"
    ffmpeg -v error -y -f lavfi -i "sine=f=880:d=2:r=48000" -ac 2 -c:a ac3 -b:a 96k "$T/a20.mka"
    printf '1\n00:00:00,100 --> 00:00:01,000\nForced\n' > "$T/s1.srt"
    printf '1\n00:00:00,200 --> 00:00:01,500\n[music]\n' > "$T/s2.srt"
    printf '1\n00:00:00,300 --> 00:00:01,800\nDeutsch\n' > "$T/s3.srt"
    printf ';FFMETADATA1\ntitle=Test Movie\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=700\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=700\nEND=1400\ntitle=Middle\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1400\nEND=2000\ntitle=End\n' > "$T/meta.txt"
    head -c 4096 /dev/urandom > "$T/font.ttf"
}

# Track titles deliberately name codecs: copied tracks must keep them,
# transcoded tracks must not.
A0_TITLE="English Dolby Digital 5.1 384 kbps"
A1_TITLE="Director Commentary - AC-3"

# mux_source VIDEO OUT
mux_source() {
    ffmpeg -v error -y -i "$1" -i "$T/a51.mka" -i "$T/a20.mka" \
        -i "$T/s1.srt" -i "$T/s2.srt" -i "$T/s3.srt" -i "$T/meta.txt" \
        -map 0:v -map 1:a -map 2:a -map 3 -map 4 -map 5 \
        -map_metadata 6 -map_chapters 6 -c copy \
        -attach "$T/font.ttf" -metadata:s:t mimetype=font/ttf -metadata:s:t filename=font.ttf \
        -metadata:s:v:0 language=eng -metadata:s:v:0 title=Main \
        -metadata:s:v:0 BPS=99999999 -metadata:s:v:0 NUMBER_OF_BYTES=1 \
        -metadata:s:a:0 language=eng -metadata:s:a:0 "title=$A0_TITLE" -disposition:a:0 default \
        -metadata:s:a:1 language=eng -metadata:s:a:1 "title=$A1_TITLE" -disposition:a:1 comment \
        -metadata:s:s:0 language=eng -metadata:s:s:0 title=Forced -disposition:s:0 default+forced \
        -metadata:s:s:1 language=eng -metadata:s:s:1 title=SDH -disposition:s:1 hearing_impaired \
        -metadata:s:s:2 language=ger -disposition:s:2 0 \
        "$2"
}

echo
echo "== building synthetic sources"
make_extras

ffmpeg -v error -y -f lavfi -i "testsrc2=s=1280x720:r=24000/1001:d=2,format=yuv420p" \
    -c:v libx264 -preset ultrafast -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    "$T/sdr.mkv"
mux_source "$T/sdr.mkv" "$T/in/SDR.mkv"

HDR_X265="colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:chromaloc=2:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400:repeat-headers=1:log-level=error"
ffmpeg -v error -y -f lavfi -i "testsrc2=s=1280x720:r=24000/1001:d=2,format=yuv420p10le" \
    -c:v libx265 -preset ultrafast -x265-params "$HDR_X265" "$T/hdr10.mkv"
mux_source "$T/hdr10.mkv" "$T/in/HDR10.mkv"

# ------------------------------------------------------------
# run_item NAME INPUT FILTER AUDIO_ARGS [OVERWRITE]  ->  job script + output + log
run_item() {
    local name="$1" in="$2" filter="$3" audio="$4" overwrite="${5:-0}"
    local job="$WORK_DIR/$name.sh"

    mkdir -p "$WORK_DIR/${name}_passes"
    {
        emit_job_header "$name" movie 1
        emit_encode_item 1 "$in" "$T/out/$name.mkv" Test 1500 "$filter" "$audio" \
            "$WORK_DIR/${name}_passes/pass_0" "$overwrite"
        emit_job_footer
    } > "$job"

    bash "$job" < /dev/null > "$T/$name.log" 2>&1
}

report() { sed -n '/^Metadata preservation:/,/^====/p' "$T/$1.log"; }
report_has() { report "$1" | grep -qE -- "$2"; }
out_title() { ffprobe -v error -select_streams "a:$2" -show_entries stream_tags=title -of default=nw=1:nk=1 "$T/out/$1.mkv"; }

common_checks() {
    local n="$1"

    check "$n: output written"                 "[[ -s '$T/out/$n.mkv' ]]"
    check "$n: no .part left"                  "[[ ! -e '$T/out/$n.mkv.part' ]]"
    check "$n: job reported success"           "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/$n.log'"
    check "$n: report printed"                 "grep -q '^Metadata preservation:' '$T/$n.log'"
    check "$n: audio tracks 2 -> 2"            "report_has $n 'Audio tracks: +2 -> 2'"
    check "$n: subtitle tracks 3 -> 3"         "report_has $n 'Subtitle tracks: +3 -> 3'"
    check "$n: attachments MATCH by name+MIME" "report_has $n 'Attachments: +MATCH \\(1 -> 1: file names \\+ MIME types\\)'"
    check "$n: chapters MATCH"                 "report_has $n 'Chapters: +MATCH \\(3: start times \\+ titles\\)'"
    if (( HAVE_MKV == 1 )); then
        check "$n: editions MATCH"             "report_has $n 'Editions: +MATCH \\(1 edition, 3 chapters'"
    else
        check "$n: editions NOT VERIFIED w/o mkvtoolnix" "report_has $n 'Editions: +NOT VERIFIED'"
    fi
    check "$n: default flags MATCH"            "report_has $n 'Default flags: +MATCH'"
    check "$n: forced flags MATCH"             "report_has $n 'Forced flags: +MATCH'"
    check "$n: commentary/HI flags MATCH"      "report_has $n 'Commentary/HI/VI: +MATCH'"
    check "$n: languages MATCH"                "report_has $n 'Languages: +MATCH'"
    check "$n: global title MATCH"             "report_has $n 'Global title: +MATCH'"
    check "$n: stream order MATCH"             "report_has $n 'Stream order: +MATCH'"
    check "$n: no RESULT failure"              "! report_has $n 'RESULT: FAILED'"
    check "$n: stale source video BPS not copied" \
        "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream_tags=BPS -of default=nw=1:nk=1 '$T/out/$n.mkv') != 99999999 ]]"
}

nondv_job_checks() {
    local n="$1" job="$WORK_DIR/$1.sh"

    check "$n: two libx265 passes"             "[[ \$(grep -c 'libx265' '$job') == 2 ]]"
    check "$n: pass 1 / pass 2 stats"          "grep -q 'pass=1:stats=' '$job' && grep -q 'pass=2:stats=' '$job'"
    check "$n: no Dolby Vision steps"          "! grep -qE 'item_dv_|item_step rpu|-copyts' '$job'"
    check "$n: no HDR10+ steps"                "! grep -q 'hdr10plus' '$job'"
    check "$n: metadata + chapters mapped"     "grep -q -- '-map_metadata 0 -map_chapters 0' '$job'"
    check "$n: chapter restore step"           "grep -q 'item_step chapters item_restore_mkv_chapters' '$job'"
    check "$n: video stats stripped"           "grep -q -- '-metadata:s:v:0 BPS=' '$job'"
    check "$n: final mux to .part"             "grep -q '\"\$ITEM_PART\"' '$job'"
}

# ------------------------------------------------------------
echo
echo "== SDR (audio copied)"
DV_POLICY=none; DV_MODE=""; HDR10P_POLICY=none
run_item sdr "$T/in/SDR.mkv" "" ""
nondv_job_checks sdr
common_checks sdr
check "sdr: HDR type SDR"                      "report_has sdr 'HDR type: +SDR\$'"
check "sdr: bt709 kept"                        "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream=color_space -of default=nw=1:nk=1 '$T/out/sdr.mkv') == bt709 ]]"
check "sdr: no audio title rewrite in job"     "! grep -q -- '-metadata:s:a:[0-9] title=' '$WORK_DIR/sdr.sh'"
eq    "sdr: copied audio 1 title unchanged"    "$(out_title sdr 0)" "$A0_TITLE"
eq    "sdr: copied audio 2 title unchanged"    "$(out_title sdr 1)" "$A1_TITLE"
check "sdr: track titles MATCH"                "report_has sdr 'Track titles: +MATCH'"

echo
echo "== encode onto an output symlink"
mkdir -p "$T/ostore/dir"
printf 'precious target\n' > "$T/ostore/target.mkv"
printf 'keep me\n' > "$T/ostore/dir/inside.txt"
OSUM=$(md5sum < "$T/ostore/target.mkv")

ln -s "$T/ostore/target.mkv" "$T/out/osv.mkv"           # valid  + overwrite
run_item osv "$T/in/SDR.mkv" "" "" 1
check "valid + overwrite: job ok"             "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/osv.log'"
check "valid + overwrite: link replaced"      "[[ -f '$T/out/osv.mkv' && ! -L '$T/out/osv.mkv' ]]"
check "valid + overwrite: says so"            "grep -q 'Replacing the symlink osv.mkv (its target is not modified)' '$T/osv.log'"
eq    "valid + overwrite: target unchanged"   "$(md5sum < "$T/ostore/target.mkv")" "$OSUM"

ln -s "$T/ostore/gone.mkv" "$T/out/osb.mkv"             # broken + overwrite
run_item osb "$T/in/SDR.mkv" "" "" 1
check "broken + overwrite: job ok"            "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/osb.log'"
check "broken + overwrite: link replaced"     "[[ -f '$T/out/osb.mkv' && ! -L '$T/out/osb.mkv' ]]"
check "broken + overwrite: nothing created at the old link target" "[[ ! -e '$T/ostore/gone.mkv' ]]"

ln -s "$T/ostore/target.mkv" "$T/out/osk.mkv"           # valid, no overwrite
run_item osk "$T/in/SDR.mkv" "" "" 0
check "valid, keep both: saved as (2)"        "[[ -f '$T/out/osk (2).mkv' && -L '$T/out/osk.mkv' ]]"
eq    "valid, keep both: target unchanged"    "$(md5sum < "$T/ostore/target.mkv")" "$OSUM"

ln -s "$T/ostore/dir" "$T/out/osd.mkv"                  # symlink to a directory
run_item osd "$T/in/SDR.mkv" "" "" 1
check "dir symlink + overwrite: link replaced, dir untouched" \
    "[[ -f '$T/out/osd.mkv' && ! -L '$T/out/osd.mkv' && \$(ls '$T/ostore/dir') == inside.txt ]]"

ln -s "$T/ostore/target.mkv" "$T/out/osp.mkv.part"      # .part is a symlink
run_item osp "$T/in/SDR.mkv" "" "" 0
check "part symlink: item refused"            "grep -q 'osp.mkv.part is a symlink; refusing to write through it' '$T/osp.log'"
eq    "part symlink: target unchanged"        "$(md5sum < "$T/ostore/target.mkv")" "$OSUM"

echo
echo "== symlinked source"
mkdir -p "$T/store"
cp "$T/in/SDR.mkv" "$T/store/Linked.mkv"
ln -s "$T/store/Linked.mkv" "$T/in/Linked.mkv"
sum_before=$(md5sum < "$T/store/Linked.mkv")
run_item lnk "$T/in/Linked.mkv" "" ""
check "lnk: job reported success"              "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/lnk.log'"
check "lnk: chapters + attachments MATCH"      "report_has lnk 'Chapters: +MATCH' && report_has lnk 'Attachments: +MATCH'"
check "lnk: source is still a symlink"         "[[ -L '$T/in/Linked.mkv' ]]"
eq    "lnk: link target unchanged"             "$(md5sum < "$T/store/Linked.mkv")" "$sum_before"
check "lnk: output is a regular file"          "[[ -f '$T/out/lnk.mkv' && ! -L '$T/out/lnk.mkv' ]]"

echo
echo "== verify.sh with symlinks"
VH="$T/vhome"
mkdir -p "$VH/compress/in" "$VH/compress/out" "$VH/store"
cp -r "$WORK_DIR" "$VH/compress/work"
cp "$ROOT/verify.sh" "$VH/compress/"
cp "$T/in/SDR.mkv" "$VH/compress/in/Real.mkv"
cp "$T/in/SDR.mkv" "$VH/store/Target.mkv"
ln -s "$VH/store/Target.mkv" "$VH/compress/in/Link.mkv"
ln -s Real.mkv "$VH/compress/in/Dup.mkv"
ln -s nowhere.mkv "$VH/compress/in/Broken.mkv"
sum_before=$(md5sum < "$VH/store/Target.mkv")
printf '1\n2\ny\n' | HOME="$VH" bash "$VH/compress/verify.sh" > "$T/verify.log" 2>&1
check "verify: regular file inspected"         "grep -q '^Real.mkv$' '$T/verify.log'"
check "verify: symlinked file inspected"       "grep -q '^Link.mkv$' '$T/verify.log'"
check "verify: symlink target shown"           "grep -q 'Symlink to .*store/Target.mkv' '$T/verify.log'"
check "verify: duplicate symlink skipped"      "! grep -q '^Dup.mkv$' '$T/verify.log'"
check "verify: broken symlink warned"          "grep -q 'WARNING: broken symlink skipped: .*Broken.mkv' '$T/verify.log'"
check "verify: 2 files checked"                "grep -q 'Files checked: *2' '$T/verify.log'"
# same content: the total bitrate (file size / duration) must match the
# regular copy; a link-sized value would be ~0
vrate() {
    awk -v n="$1" '$0 == n { f = 1; next }
        f && /^=====/ { if (++c == 2) exit; next }
        f && /Total bitrate/ { print $3 }' "$T/verify.log"
}
check "verify: size of the target, not link"   "[[ -n \"\$(vrate Link.mkv)\" && \"\$(vrate Link.mkv)\" == \"\$(vrate Real.mkv)\" && \"\$(vrate Link.mkv)\" != 0.00 ]]"
check "verify: symlink never updated"          "grep -q 'Symlink: statistics tags not updated' '$T/verify.log'"
eq    "verify: link target unchanged"          "$(md5sum < "$VH/store/Target.mkv")" "$sum_before"

echo
echo "== HDR10 (audio -> AAC)"
run_item hdr10 "$T/in/HDR10.mkv" "" "-c:a aac -b:a:0 384k -b:a:1 96k"
nondv_job_checks hdr10
common_checks hdr10
check "hdr10: x265 HDR10 params"               "grep -q 'transfer=smpte2084' '$WORK_DIR/hdr10.sh' && grep -q 'master-display=' '$WORK_DIR/hdr10.sh' && grep -q 'max-cll=1000' '$WORK_DIR/hdr10.sh'"
check "hdr10: transcoded audio stats stripped" "grep -q -- '-metadata:s:a:1 BPS=' '$WORK_DIR/hdr10.sh'"
check "hdr10: HDR type HDR10"                  "report_has hdr10 'HDR type: +HDR10\$'"
check "hdr10: colour MATCH"                    "report_has hdr10 'Colour signalling: +MATCH \\(bt2020/smpte2084/bt2020nc/tv\\)'"
check "hdr10: chroma location MATCH"           "report_has hdr10 'Chroma location: +MATCH \\(topleft\\)'"
check "hdr10: mastering VERIFIED"              "report_has hdr10 'HDR10 mastering: +VERIFIED'"
check "hdr10: MaxCLL VERIFIED"                 "report_has hdr10 'MaxCLL/MaxFALL: +VERIFIED'"
check "hdr10: audio 1 transcode reported"      "report_has hdr10 'Audio track 1: +AC-3 .* -> AAC'"
eq    "hdr10: audio 1 title rewritten"         "$(out_title hdr10 0)" "English AAC 5.1"
eq    "hdr10: audio 2 title rewritten"         "$(out_title hdr10 1)" "Director Commentary - AAC"
check "hdr10: title UPDATED in report"         "report_has hdr10 'Audio 1 title: +UPDATED \"$A0_TITLE\" -> \"English AAC 5.1\"'"
check "hdr10: track titles AS PLANNED"         "report_has hdr10 'Track titles: +AS PLANNED \\(2 audio title'"
check "hdr10: no stale title"                  "! report_has hdr10 'STALE'"

# ------------------------------------------------------------
echo
echo "== MP4 with styled mov_text"
cat > "$T/styled.ass" <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 384
PlayResY: 288

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,18,&H0000FFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.10,0:00:00.90,Default,,0,0,0,,plain {\b1}bold{\b0} {\i1}italic{\i0}
Dialogue: 0,0:00:01.60,0:00:01.90,Default,,0,0,0,,top {\1a&H80&}alpha
EOF
ffmpeg -v error -y -i "$T/sdr.mkv" -i "$T/a20.mka" -i "$T/styled.ass" \
    -map 0:v -map 1:a -map 2 -c:v copy -c:a aac -c:s mov_text \
    -metadata:s:s:0 language=eng -disposition:s:0 default "$T/in/MOVTEXT.mp4"
build_stream_map "$T/in/MOVTEXT.mp4" 0
printf '%s\n' "${MAP_NOTES[@]}" > "$T/mov_notes.txt"
check "mov: pre-encode note names the loss"    "grep -q 'mov_text subtitle -> SRT .*styling LOST: .*default font (Arial)' '$T/mov_notes.txt'"
run_item mov "$T/in/MOVTEXT.mp4" "" ""
check "mov: job reported success"              "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/mov.log'"
check "mov: report shows conversion"           "report_has mov 'Subtitle 1: +mov_text -> SRT'"
check "mov: report shows styling LOST"         "report_has mov 'Subtitle 1 styling: +styling LOST: .*(background box|transparency)'"
check "mov: report shows what is kept"         "report_has mov 'kept: .*bold/italic/underline'"
check "mov: subtitle language kept"            "[[ \$(ffprobe -v error -select_streams s:0 -show_entries stream_tags=language -of default=nw=1:nk=1 '$T/out/mov.mkv') == eng ]]"
check "mov: output subtitle is SRT"            "[[ \$(ffprobe -v error -select_streams s:0 -show_entries stream=codec_name -of default=nw=1:nk=1 '$T/out/mov.mkv') == subrip ]]"

# ------------------------------------------------------------
if (( HAVE_MKV == 1 )); then
    echo
    echo "== ordered chapters / editions"
    cat > "$T/editions.xml" <<'EOF'
<?xml version="1.0"?>
<Chapters>
  <EditionEntry>
    <EditionUID>1111</EditionUID>
    <EditionFlagDefault>1</EditionFlagDefault>
    <EditionFlagOrdered>1</EditionFlagOrdered>
    <ChapterAtom>
      <ChapterUID>11</ChapterUID>
      <ChapterTimeStart>00:00:00.000000000</ChapterTimeStart>
      <ChapterTimeEnd>00:00:00.700000000</ChapterTimeEnd>
      <ChapterDisplay><ChapterString>Teil eins</ChapterString><ChapterLanguage>ger</ChapterLanguage></ChapterDisplay>
      <ChapterDisplay><ChapterString>Part one</ChapterString><ChapterLanguage>eng</ChapterLanguage></ChapterDisplay>
      <ChapterAtom>
        <ChapterUID>111</ChapterUID>
        <ChapterTimeStart>00:00:00.200000000</ChapterTimeStart>
        <ChapterTimeEnd>00:00:00.500000000</ChapterTimeEnd>
        <ChapterDisplay><ChapterString>Nested</ChapterString><ChapterLanguage>eng</ChapterLanguage></ChapterDisplay>
      </ChapterAtom>
    </ChapterAtom>
    <ChapterAtom>
      <ChapterUID>12</ChapterUID>
      <ChapterSegmentUID format="hex">00112233445566778899aabbccddeeff</ChapterSegmentUID>
      <ChapterFlagHidden>1</ChapterFlagHidden>
      <ChapterTimeStart>00:00:01.400000000</ChapterTimeStart>
      <ChapterTimeEnd>00:00:02.000000000</ChapterTimeEnd>
      <ChapterDisplay><ChapterString>Hidden end</ChapterString><ChapterLanguage>eng</ChapterLanguage></ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
  <EditionEntry>
    <EditionUID>2222</EditionUID>
    <ChapterAtom>
      <ChapterUID>21</ChapterUID>
      <ChapterTimeStart>00:00:00.000000000</ChapterTimeStart>
      <ChapterDisplay><ChapterString>Theatrical</ChapterString><ChapterLanguage>eng</ChapterLanguage></ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
EOF
    mkvmerge -q -o "$T/in/EDITIONS.mkv" --segment-uid 0x00112233445566778899aabbccddeeff \
        --chapters "$T/editions.xml" --no-chapters "$T/in/SDR.mkv"
    check "ed: pre-encode note describes structure" \
        "chapter_notes '$T/in/EDITIONS.mkv' > '$T/ed_notes.txt'; grep -q '2 editions (1 ordered), 4 chapters (1 nested, 1 hidden)' '$T/ed_notes.txt'"
    check "ed: pre-encode note about segment UID" \
        "grep -q 'source segment UID is kept' '$T/ed_notes.txt'"

    run_item ed "$T/in/EDITIONS.mkv" "" ""
    check "ed: job reported success"           "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/ed.log'"
    check "ed: editions MATCH"                 "report_has ed 'Editions: +MATCH \\(2 editions \\(1 ordered\\), 4 chapters \\(1 nested, 1 hidden\\)'"
    check "ed: segment UID KEPT"               "report_has ed 'Segment UID: +KEPT'"
    check "ed: chapter XML identical"          "diff -q <(mkvextract '$T/in/EDITIONS.mkv' chapters - 2>/dev/null) <(mkvextract '$T/out/ed.mkv' chapters - 2>/dev/null)"
    check "ed: FFmpeg alone would flatten it"  "ffmpeg -v error -y -i '$T/in/EDITIONS.mkv' -map 0:v -c copy '$T/ff_only.mkv' && ! diff -q <(mkvextract '$T/in/EDITIONS.mkv' chapters - 2>/dev/null) <(mkvextract '$T/ff_only.mkv' chapters - 2>/dev/null) >/dev/null"

    # simple chapters have no end times: ffprobe derives the last end
    # from the file duration, which changes with re-encoding
    printf 'CHAPTER01=00:00:00.000\nCHAPTER01NAME=One\nCHAPTER02=00:00:01.000\nCHAPTER02NAME=Two\n' > "$T/simple.txt"
    mkvmerge -q -o "$T/in/OPENEND.mkv" --chapters "$T/simple.txt" --no-chapters "$T/in/SDR.mkv"
    run_item openend "$T/in/OPENEND.mkv" "" "-c:a aac -b:a:0 384k -b:a:1 96k"
    check "openend: job reported success"      "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/openend.log'"
    check "openend: chapters MATCH"            "report_has openend 'Chapters: +MATCH \\(2: start times'"
    check "openend: editions MATCH"            "report_has openend 'Editions: +MATCH'"
else
    SKIPPED+=("ordered chapters / editions (needs mkvtoolnix)")
fi

# ------------------------------------------------------------
hdr_tools_detect

if (( DOVI_TOOL_OK == 1 )) && [[ -n "$MKVMERGE" ]]; then
    echo
    echo "== Dolby Vision profile 8.1 (synthetic RPU), 1440p -> 1080p"

    ffmpeg -v error -y -f lavfi \
        -i "testsrc2=s=2560x1072:r=24000/1001:d=2,format=yuv420p10le,pad=2560:1440:0:184" \
        -c:v libx265 -preset ultrafast -x265-params "$HDR_X265" -f hevc "$T/base.hevc"
    printf '{"profile":"8.1","length":48,"level5":{"active_area_left_offset":0,"active_area_right_offset":0,"active_area_top_offset":184,"active_area_bottom_offset":184},"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400}}\n' > "$T/gen.json"
    "$DOVI_TOOL" generate -j "$T/gen.json" -o "$T/gen.rpu" > /dev/null
    "$DOVI_TOOL" inject-rpu -i "$T/base.hevc" --rpu-in "$T/gen.rpu" -o "$T/dv.hevc" > /dev/null
    "$MKVMERGE" -q -o "$T/dv.mkv" --default-duration 0:24000/1001p "$T/dv.hevc"
    mux_source "$T/dv.mkv" "$T/in/DV.mkv"

    probe_hdr "$T/in/DV.mkv" 0
    check "dv: source detected as P8.1"        "[[ '$HDR_DV_PROFILE.$HDR_DV_COMPAT' == 8.1 ]]"

    DV_POLICY=preserve; DV_MODE=""; HDR10P_POLICY=none
    run_item dv "$T/in/DV.mkv" \
        "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2" \
        "-c:a aac -b:a:0 384k -b:a:1 96k"
    common_checks dv
    check "dv: RPU steps in job"               "grep -q 'item_step rpu item_dv_extract' '$WORK_DIR/dv.sh' && grep -q 'item_dv_inject' '$WORK_DIR/dv.sh'"
    check "dv: still two-pass"                 "[[ \$(grep -c 'libx265' '$WORK_DIR/dv.sh') == 2 ]]"
    check "dv: HDR type DV 8.1 + HDR10"        "report_has dv 'HDR type: +DV Profile 8.1 \\+ HDR10\$'"
    check "dv: RPU VERIFIED"                   "report_has dv 'Dolby Vision RPU: +VERIFIED'"
    check "dv: HDR10 fallback VERIFIED"        "report_has dv 'HDR10 fallback: +VERIFIED'"
    check "dv: mastering VERIFIED"             "report_has dv 'HDR10 mastering: +VERIFIED'"
    eq    "dv: audio title rewritten (DV path)" "$(out_title dv 0)" "English AAC 5.1"

    ffmpeg -v error -i "$T/out/dv.mkv" -map 0:v:0 -c copy -f hevc - |
        "$DOVI_TOOL" extract-rpu - -o "$T/out.rpu" > /dev/null 2>&1
    "$DOVI_TOOL" info --summary -i "$T/out.rpu" > "$T/dv_summary.txt" 2>&1
    check "dv: dovi_tool summary profile 8"    "grep -q 'Profile: 8' '$T/dv_summary.txt'"
    check "dv: L5 rescaled 184 -> 138"         "grep -q 'L5 offsets: top=138, bottom=138' '$T/dv_summary.txt'"
    check "dv: 1080p output"                   "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 '$T/out/dv.mkv') == 1080 ]]"
    check "dv: temp files removed on success"  "! ls -d '$WORK_DIR'/logs/*/item-1.tmp >/dev/null 2>&1"
else
    SKIPPED+=("Dolby Vision (needs dovi_tool >= 2.1 and mkvmerge)")
fi

echo
echo "============================================================"
echo "passed: $PASS   failed: $FAIL"
for s in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do echo "skipped: $s"; done
echo "============================================================"

(( FAIL > 0 )) && { echo "Logs: $T"; KEEP=1; }
(( FAIL == 0 ))
