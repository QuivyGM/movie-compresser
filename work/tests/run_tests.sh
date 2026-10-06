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
exp_rate() {   # gib_per_hour max dur [source_gib]  ->  High/Base target Mb/s
    awk -v r="$1" -v m="$2" -v d="$3" -v s="${4:-0}" 'BEGIN {
        g = sprintf("%.3f", r * d / 3600) + 0   # the plan sizes in 0.001 GiB steps
        if (s > 0 && s < g) g = s
        t = g * 1073741824 * 8 / d / 1000000
        if (m > 0 && t > m) t = m
        printf "%.3f", t }'
}

# Quality: max(hours * GiB/hour, min GiB), min(source), cap at max Mb/s
exp_quality() {   # dur [source_gib]  ->  target Mb/s from the loaded config
    awk -v r="$MOVIE_QUALITY_VIDEO_GIB_PER_HOUR" -v n="$MOVIE_QUALITY_VIDEO_MIN_GIB" \
        -v m="$MOVIE_QUALITY_VIDEO_MAX_MBPS" -v d="$1" -v s="${2:-0}" 'BEGIN {
        g = r * d / 3600; if (g < n) g = n
        if (s > 0 && s < g) g = s
        t = g * 1073741824 * 8 / d / 1000000
        if (m > 0 && t > m) t = m
        printf "%.3f", t }'
}
gib_bytes() { awk -v g="$1" 'BEGIN { printf "%.0f", g * 1073741824 }'; }

check "default compress.conf loads"           "load_policy 2>'$T/pol.err'"
{
    load_policy 2>/dev/null
    for tier in High Base; do
        u=${tier^^}; g="MOVIE_${u}_VIDEO_GIB_PER_HOUR"; m="MOVIE_${u}_VIDEO_MAX_MBPS"
        for dur in 1800 5400 9000 20000; do
            movie_video_plan "$tier" "$dur"
            eq "movie $tier ${dur}s target from config" "$PLAN_TARGET_MBPS" "$(exp_rate "${!g}" "${!m}" "$dur")"
        done
    done

    for dur in 3600 6000 10800 20000; do
        movie_video_plan Quality "$dur"
        eq "movie Quality ${dur}s target from config" "$PLAN_TARGET_MBPS" "$(exp_quality "$dur")"
    done
    movie_video_plan Quality 5400
    eq "movie Quality 90 min not below floor" "$PLAN_BELOW_FLOOR" 0

    eq "movie High AAC 5.1 from config"   "$(movie_aac_kbps High 6)" "$MOVIE_HIGH_AAC_KBPS_6"
    eq "movie Base AAC stereo from config" "$(movie_aac_kbps Base 2)" "$MOVIE_BASE_AAC_KBPS_2"
    eq "movie High audio cap from config" "$(movie_audio_cap_gib High)" "$MOVIE_HIGH_AUDIO_MAX_GIB"
    eq "movie Quality audio copied"       "$(movie_audio_cap_gib Quality)" 0
    eq "series Base AAC 5.1 from config"  "$(series_aac_kbps Base 6)" "$SERIES_BASE_AAC_KBPS_6"
    eq "series Custom uses High AAC"      "$(series_aac_kbps Custom 2)" "$SERIES_HIGH_AAC_KBPS_2"
    eq "series reserve from config"       "$(series_size_factor)" \
        "$(awk -v r="$SERIES_CONTAINER_RESERVE_PCT" 'BEGIN { printf "%.6f", (100 - r) / 100 }')"
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
    # High / Base: GiB/hour, no minimum size (fixed values, not the defaults)
    for tier in High Base; do
        u=${tier^^}
        if [[ $tier == High ]]; then r=3.0 f=6 m=10 r2=4 big=10; else r=1.25 f=2.5 m=5 r2=2 big=4; fi
        COMPRESS_CONF=$(conf_with "hb$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=$r \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=0)
        load_policy 2>/dev/null

        # 1 / 7 / 8: normal GiB/hour calculation (no max, large source)
        for h in 1.5 2 2.5 3; do
            dur=$(awk -v h="$h" 'BEGIN { printf "%.0f", h * 3600 }')
            want=$(awk -v r="$r" -v h="$h" 'BEGIN { printf "%.3f", r * h }')
            movie_video_plan "$tier" "$dur" "$(gib_bytes 60)"
            eq "$tier ${h} h: $want GiB video"     "$PLAN_TARGET_GIB" "$want"
            eq "$tier ${h} h: bitrate from size"   "$PLAN_TARGET_MBPS" "$(bitrate_for_gib "$want" "$dur")"
        done
        movie_video_plan "$tier" 7200
        eq "$tier 2 h: no minimum size"         "$PLAN_MIN_GIB" ""
        eq "$tier 2 h: not limited"             "$PLAN_SOURCE_LIMITED/$PLAN_MAX_LIMITED/$PLAN_BELOW_FLOOR" "0/0/0"

        # 2 source video smaller than the rate-based target (bitrate above the floor)
        if [[ $tier == High ]]; then small=5.500; else small=2.300; fi
        movie_video_plan "$tier" 7200 "$(gib_bytes "$small")"
        eq "$tier source: source size wins"     "$PLAN_TARGET_GIB" "$small"
        eq "$tier source: flagged as limited"   "$PLAN_SOURCE_LIMITED/$PLAN_SOURCE_BELOW_FLOOR" "1/0"
        eq "$tier source: bitrate from source"  "$PLAN_TARGET_MBPS" "$(bitrate_for_gib "$small" 7200)"

        # source bitrate vs floor (2 h; bytes for an exact Mb/s over 7200 s)
        mbps_bytes() { awk -v x="$1" 'BEGIN { printf "%.0f", x * 1000000 / 8 * 7200 }'; }
        half=$(awk -v f="$f" 'BEGIN { printf "%.3f", f / 2 }')
        fl=$(awk -v f="$f" 'BEGIN { printf "%.3f", f }')

        # S1 source below floor, GiB/hour target below the source -> source wins
        COMPRESS_CONF=$(conf_with "hbsrc$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=0.1 \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null
        movie_video_plan "$tier" 7200 "$(mbps_bytes "$half")"
        eq "$tier S1 src<floor, rate<src: source bitrate" "$PLAN_TARGET_MBPS" "$half"
        eq "$tier S1 src<floor, rate<src: flagged" "$PLAN_SOURCE_BELOW_FLOOR" 1
        # S5 no floor conflict when the source itself is below the floor
        eq "$tier S5 src<floor: no conflict"    "$PLAN_BELOW_FLOOR" 0

        # S2 source below floor, GiB/hour target above the source -> source wins
        COMPRESS_CONF=$(conf_with "hbsrc2$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=$big \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=0)
        load_policy 2>/dev/null
        movie_video_plan "$tier" 7200 "$(mbps_bytes "$half")"
        eq "$tier S2 src<floor, rate>src: source bitrate" "$PLAN_TARGET_MBPS" "$half"
        eq "$tier S2 src<floor, rate>src: no conflict" "$PLAN_SOURCE_BELOW_FLOOR/$PLAN_BELOW_FLOOR" "1/0"

        # S3 source equal to the floor -> normal path (low rate -> conflict)
        COMPRESS_CONF=$(conf_with "hbsrc3$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=0.1 \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null
        movie_video_plan "$tier" 7200 "$(mbps_bytes "$fl")"
        eq "$tier S3 src=floor: not below floor" "$PLAN_SOURCE_BELOW_FLOOR" 0
        eq "$tier S3 src=floor: GiB/hour target" "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 0.2 7200)"
        eq "$tier S3 src=floor: floor conflict"  "$PLAN_BELOW_FLOOR" 1

        # S4 source above the floor -> GiB/hour logic unchanged
        COMPRESS_CONF=$(conf_with "hbsrc4$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=$r \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null
        movie_video_plan "$tier" 7200 "$(mbps_bytes "$(awk -v f="$f" 'BEGIN { print f * 2 }')")"
        want=$(awk -v r="$r" 'BEGIN { printf "%.3f", r * 2 }')
        eq "$tier S4 src>floor: GiB/hour size"   "$PLAN_TARGET_GIB" "$want"
        eq "$tier S4 src>floor: bitrate"         "$PLAN_TARGET_MBPS" "$(bitrate_for_gib "$want" 7200)"
        eq "$tier S4 src>floor: no flags"        "$PLAN_SOURCE_BELOW_FLOOR/$PLAN_SOURCE_LIMITED/$PLAN_BELOW_FLOOR" "0/0/0"

        # Quality is unchanged: a source below its floor still gets the size target
        COMPRESS_CONF=$(conf_with "qsrc$tier" MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=0.1 MOVIE_QUALITY_VIDEO_MIN_GIB=0.1 \
            MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=0)
        load_policy 2>/dev/null
        movie_video_plan Quality 7200 "$(mbps_bytes 6)"
        eq "Quality src<floor: size target kept" "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 0.2 7200)"
        eq "Quality src<floor: conflict as before" "$PLAN_BELOW_FLOOR" 1

        # 3 nonzero bitrate max limits the result
        COMPRESS_CONF=$(conf_with "hbmax$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=$big \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null
        movie_video_plan "$tier" 7200 "$(gib_bytes 60)"
        eq "$tier max: capped at $m Mb/s"        "$PLAN_TARGET_MBPS" "$(awk -v m="$m" 'BEGIN { printf "%.3f", m }')"
        eq "$tier max: flagged as limited"      "$PLAN_MAX_LIMITED" 1

        # 4 calculated bitrate below the floor -> conflict, floor not forced
        COMPRESS_CONF=$(conf_with "hbfloor$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=0.5 \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null
        movie_video_plan "$tier" 7200 "$(gib_bytes 60)"
        eq "$tier floor: below floor -> asks"   "$PLAN_BELOW_FLOOR" 1
        eq "$tier floor: target not raised"     "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 1 7200)"
        eq "$tier floor: floor offered"         "$PLAN_FLOOR_MBPS" "$f"

        # 6 changing GiB/hour changes the target
        COMPRESS_CONF=$(conf_with "hbrate$tier" MOVIE_${u}_VIDEO_GIB_PER_HOUR=$r2 \
            MOVIE_${u}_VIDEO_FLOOR_MBPS=$f MOVIE_${u}_VIDEO_MAX_MBPS=0)
        load_policy 2>/dev/null
        movie_video_plan "$tier" 7200 "$(gib_bytes 60)"
        eq "$tier edited GiB/hour: $r2 * 2 h"   "$PLAN_TARGET_GIB" "$(awk -v r="$r2" 'BEGIN { printf "%.3f", r * 2 }')"
    done

    # default config: High 2 h -> 6 GiB, Base 2 h -> 2.5 GiB before caps
    COMPRESS_CONF="$T/compress.conf"
    load_policy 2>/dev/null
    movie_video_plan High 7200;  eq "default High 2 h rate-based 6 GiB"   "$PLAN_RATE_GIB" 6.000
    movie_video_plan Base 7200;  eq "default Base 2 h rate-based 2.5 GiB" "$PLAN_RATE_GIB" 2.500

    COMPRESS_CONF=$(conf_with nomax MOVIE_HIGH_VIDEO_MAX_MBPS=0 MOVIE_HIGH_VIDEO_GIB_PER_HOUR=40)
    load_policy 2>/dev/null
    movie_video_plan High 5400
    eq "MAX_MBPS=0: size decides"         "$PLAN_TARGET_MBPS" "$(exp_rate 40 0 5400)"

    # Quality: GiB/hour with a minimum size (fixed values, not the defaults)
    COMPRESS_CONF=$(conf_with q MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=8.4 MOVIE_QUALITY_VIDEO_MIN_GIB=20 \
        MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=0)
    load_policy 2>/dev/null

    # 1 short movie: 8.4 * 1.5 = 12.6 GiB < 20 -> the minimum wins
    movie_video_plan Quality 5400 "$(gib_bytes 60)"
    eq "Q1 short: rate-based size"        "$PLAN_RATE_GIB" 12.600
    eq "Q1 short: minimum size wins"      "$PLAN_TARGET_GIB" 20.000
    eq "Q1 short: bitrate from 20 GiB"    "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 20 5400)"
    eq "Q1 short: not source limited"     "$PLAN_SOURCE_LIMITED" 0

    # 2 long movie: 8.4 * 3 = 25.2 GiB > 20 -> GiB/hour wins
    movie_video_plan Quality 10800 "$(gib_bytes 60)"
    eq "Q2 long: GiB/hour size wins"      "$PLAN_TARGET_GIB" 25.200
    eq "Q2 long: bitrate from 25.2 GiB"   "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 25.2 10800)"

    # 3 source video smaller than the target -> source size wins
    movie_video_plan Quality 10800 "$(gib_bytes 15)"
    eq "Q3 source: source size wins"      "$PLAN_TARGET_GIB" 15.000
    eq "Q3 source: flagged as limited"    "$PLAN_SOURCE_LIMITED" 1
    eq "Q3 source: bitrate from source"   "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 15 10800)"
    movie_video_plan Quality 10800 "$(gib_bytes 2)"
    eq "Q3 source below floor: no conflict" "$PLAN_BELOW_FLOOR" 0

    # 7 Grand Budapest-style: 1h40m, 24.38 GiB source video
    movie_video_plan Quality 6000 "$(gib_bytes 24.38)"
    eq "Q7 GBH: rate-based ~14 GiB"       "$PLAN_RATE_GIB" 14.000
    eq "Q7 GBH: minimum 20 GiB"           "$PLAN_MIN_GIB" 20.000
    eq "Q7 GBH: source 24.38 GiB"         "$PLAN_SOURCE_GIB" 24.380
    eq "Q7 GBH: target 20 GiB video"      "$PLAN_TARGET_GIB" 20.000
    eq "Q7 GBH: not limited by source"    "$PLAN_SOURCE_LIMITED" 0
    eq "Q7 GBH: not capped at 20 Mb/s"    "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 20 6000)"
    check "Q7 GBH: ~28.6 Mb/s"            "awk -v x='$PLAN_TARGET_MBPS' 'BEGIN { exit !(x > 28.5 && x < 28.7) }'"
    eq "Q7 GBH: expected size ~20 GiB"    "$(video_size_gib "$PLAN_TARGET_MBPS" 6000)" 20.000

    # 4 nonzero bitrate max limits the calculated bitrate
    COMPRESS_CONF=$(conf_with qmax MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=8.4 MOVIE_QUALITY_VIDEO_MIN_GIB=20 \
        MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=25)
    load_policy 2>/dev/null
    movie_video_plan Quality 6000 "$(gib_bytes 24.38)"
    eq "Q4 max: capped at 25 Mb/s"        "$PLAN_TARGET_MBPS" 25.000
    eq "Q4 max: flagged as limited"       "$PLAN_MAX_LIMITED" 1
    movie_video_plan Quality 10800
    eq "Q4 max: below max untouched"      "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 25.2 10800)"
    eq "Q4 max: not flagged"              "$PLAN_MAX_LIMITED" 0

    # 5 floor conflict: 2 GiB/hour ~ 4.8 Mb/s < 12 Mb/s floor -> menu asks
    COMPRESS_CONF=$(conf_with qfloor MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=2 MOVIE_QUALITY_VIDEO_MIN_GIB=1 \
        MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=0)
    load_policy 2>/dev/null
    movie_video_plan Quality 7200 "$(gib_bytes 60)"
    eq "Q5 floor: below floor -> asks"    "$PLAN_BELOW_FLOOR" 1
    eq "Q5 floor: target not raised"      "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 4 7200)"
    eq "Q5 floor: floor offered"          "$PLAN_FLOOR_MBPS" 12
    COMPRESS_CONF=$(conf_with qfloor2 MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=2 MOVIE_QUALITY_VIDEO_MIN_GIB=20 \
        MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=0)
    load_policy 2>/dev/null
    movie_video_plan Quality 3600 "$(gib_bytes 60)"
    eq "Q5 floor: minimum size lifts above floor" "$PLAN_BELOW_FLOOR" 0

    # 6 changing GiB/hour changes the target
    COMPRESS_CONF=$(conf_with qrate MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=12 MOVIE_QUALITY_VIDEO_MIN_GIB=20)
    load_policy 2>/dev/null
    movie_video_plan Quality 10800
    eq "Q6 edited GiB/hour: 12 * 3 h"     "$PLAN_TARGET_GIB" 36.000
    eq "Q6 edited GiB/hour: bitrate"      "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 36 10800)"

    COMPRESS_CONF=$(conf_with aac MOVIE_HIGH_AAC_KBPS_6=500 MOVIE_HIGH_AAC_KBPS_2=100)
    load_policy 2>/dev/null
    eq "edited AAC rates in audio args"   "$(build_audio_args 10000 "6 2" High)" "-c:a aac -b:a:0 500k -b:a:1 100k"

    COMPRESS_CONF=$(conf_with series SERIES_BASE_VIDEO_GIB_PER_HOUR=2.5 SERIES_BASE_AAC_KBPS_6=300)
    load_policy 2>/dev/null
    eq "edited series GiB/hour"           "$(series_gib_per_hour Base)" 2.5
    eq "edited series AAC rate"           "$(series_aac_kbps Base 6)" 300

    COMPRESS_CONF=$(conf_with qaudio MOVIE_QUALITY_AUDIO_MODE=cap MOVIE_QUALITY_AUDIO_MAX_GIB=3)
    load_policy 2>/dev/null
    eq "Quality audio mode cap"           "$(movie_audio_cap_gib Quality)" 3
}

# ------------------------------------------------------------
echo
echo "== series policy: video GiB/hour, audio on top"
{
    # series_plan inputs (normally filled by series_compress.sh)
    set_eps() {   # SOURCE_VIDEO_KBPS DURATION...
        local src="$1" i=0 d
        shift
        EP_DUR=(); EP_VKBPS=(); EP_AKBPS=()
        for d in "$@"; do
            EP_DUR[$i]="$d"; EP_VKBPS[$i]="$src"; EP_AKBPS[$i]="5000 5000"
            ((i += 1))
        done
    }
    AUDIO_CHANNELS=(6 2)

    for tier in High Base; do
        u=${tier^^}
        if [[ $tier == High ]]; then r=3.0 f=6 m=10 kb=7158 big=10 r2=4 fk=6000
        else                         r=1.25 f=2.5 m=5 kb=2983 big=4 r2=2 fk=2500; fi
        COMPRESS_CONF=$(conf_with "s$tier" SERIES_${u}_VIDEO_GIB_PER_HOUR=$r \
            SERIES_${u}_VIDEO_FLOOR_MBPS=$f SERIES_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null

        # 1 GiB/hour -> fixed bitrate
        set_eps 50000 3600
        series_video_plan "$tier"
        eq "series $tier: $r GiB/hour = $kb kb/s"   "$SPLAN_TARGET_KBPS" "$kb"
        eq "series $tier: = gib_per_hour_to_kbps"   "$SPLAN_TARGET_KBPS" "$(gib_per_hour_to_kbps "$r")"
        eq "series $tier: floor / max in kb/s"      "$SPLAN_FLOOR_KBPS/$SPLAN_MAX_KBPS" "$fk/$(_mbps_to_kbps "$m")"
        eq "series $tier: no conflict, no max"      "$SPLAN_BELOW_FLOOR/$SPLAN_MAX_LIMITED" "0/0"

        # 2 expected video sizes per runtime; bitrate does not depend on runtime
        if [[ $tier == High ]]; then
            mins=(30 45 60 90);             want=(1.50 2.25 3.00 4.50)
        else
            mins=(30 40 45 50 60 75 90);    want=(0.63 0.83 0.94 1.04 1.25 1.56 1.88)
        fi
        set_eps 50000 $(for x in "${mins[@]}"; do echo $((x * 60)); done)
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        for i in "${!mins[@]}"; do
            eq "series $tier ${mins[$i]} min: ~${want[$i]} GiB video" "${P_EP_VGIB[$i]}" "${want[$i]}"
        done
        eq "series $tier: same bitrate every runtime" \
            "$(printf '%s\n' "${P_EP_VKBPS[@]}" | sort -u)" "$kb"

        # 3 audio does not reduce the video bitrate
        AUDIO_CHANNELS=(8 6 2); EP_AKBPS[0]="5000 5000 5000"
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        many="${P_EP_VKBPS[0]}/$P_VIDEO_KBPS"
        AUDIO_CHANNELS=(2); EP_AKBPS[0]="5000"
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        eq "series $tier: 3 audio tracks, same video" "$many" "${P_EP_VKBPS[0]}/$P_VIDEO_KBPS"
        eq "series $tier: video kb/s ignores audio"   "$many" "$kb/$kb"

        # 4 audio is added on top of the video size
        AUDIO_CHANNELS=(6 2)
        set_eps 50000 3600
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        a=$(( $(series_aac_kbps "$tier" 6) + $(series_aac_kbps "$tier" 2) ))
        eq "series $tier: audio kb/s from tables"     "$P_AUDIO_KBPS" "$a"
        eq "series $tier: audio size"                 "${P_EP_AGIB[0]}" \
            "$(awk -v a="$a" 'BEGIN { printf "%.2f", a * 1000 * 3600 / 8 / 1073741824 }')"
        eq "series $tier: video size unchanged"       "${P_EP_VGIB[0]}" "${want[$(( ${#want[@]} > 4 ? 4 : 2 ))]}"
        eq "series $tier: total = video + audio (+reserve)" "${P_EP_GIB[0]}" \
            "$(awk -v v="$kb" -v a="$a" -v f="$(series_size_factor)" 'BEGIN { printf "%.2f", (v + a) * 1000 * 3600 / 8 / 1073741824 / f }')"
        eq "series $tier: season totals"              "$P_VIDEO_GIB/$P_AUDIO_GIB/$P_TOTAL_SECONDS" \
            "${P_EP_VGIB[0]}/${P_EP_AGIB[0]}/3600.000"

        # 5 source below the floor -> source bitrate, no conflict
        half=$(( fk / 2 ))
        set_eps "$half" 3600 3600
        series_video_plan "$tier"
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        eq "series $tier src<floor: source bitrate"   "${P_EP_VKBPS[0]}/${P_EP_VNOTE[0]}" "$half/floor"
        eq "series $tier src<floor: counted"          "$P_SRC_BELOW_FLOOR" 2
        COMPRESS_CONF=$(conf_with "slow$tier" SERIES_${u}_VIDEO_GIB_PER_HOUR=0.1 \
            SERIES_${u}_VIDEO_FLOOR_MBPS=$f SERIES_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null
        series_video_plan "$tier"
        eq "series $tier src<floor, target<src: no conflict" "$SPLAN_BELOW_FLOOR" 0
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        eq "series $tier src<floor, target<src: source wins" "${P_EP_VKBPS[1]}" "$half"

        # 6 source at/above the floor, GiB/hour bitrate below it -> conflict
        set_eps "$fk" 3600
        series_video_plan "$tier"
        eq "series $tier src=floor, target<floor: conflict" "$SPLAN_BELOW_FLOOR" 1
        set_eps 50000 3600
        series_video_plan "$tier"
        eq "series $tier src>floor, target<floor: conflict" "$SPLAN_BELOW_FLOOR" 1
        eq "series $tier conflict: target not raised" "$SPLAN_TARGET_KBPS" "$(gib_per_hour_to_kbps 0.1)"
        set_eps 50000 3600 3600; EP_VKBPS[1]="$half"
        series_video_plan "$tier"
        series_plan "$tier" "$SPLAN_FLOOR_KBPS" "$SPLAN_FLOOR_KBPS"
        eq "series $tier mixed: floor chosen / low source kept" \
            "$SPLAN_BELOW_FLOOR ${P_EP_VKBPS[0]} ${P_EP_VKBPS[1]}" "1 $fk $half"

        # 7 max limits the fixed bitrate
        COMPRESS_CONF=$(conf_with "smax$tier" SERIES_${u}_VIDEO_GIB_PER_HOUR=$big \
            SERIES_${u}_VIDEO_FLOOR_MBPS=$f SERIES_${u}_VIDEO_MAX_MBPS=$m)
        load_policy 2>/dev/null
        set_eps 50000 3600
        series_video_plan "$tier"
        eq "series $tier max: capped"                "$SPLAN_TARGET_KBPS/$SPLAN_MAX_LIMITED" "$(_mbps_to_kbps "$m")/1"
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        eq "series $tier max: episodes at max"       "${P_EP_VKBPS[0]}" "$(_mbps_to_kbps "$m")"

        # 8 changing the config changes bitrate and sizes
        COMPRESS_CONF=$(conf_with "srate$tier" SERIES_${u}_VIDEO_GIB_PER_HOUR=$r2 \
            SERIES_${u}_VIDEO_FLOOR_MBPS=$f SERIES_${u}_VIDEO_MAX_MBPS=0)
        load_policy 2>/dev/null
        series_video_plan "$tier"
        series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
        eq "series $tier edited: bitrate"            "$SPLAN_TARGET_KBPS" "$(gib_per_hour_to_kbps "$r2")"
        eq "series $tier edited: 60 min = $r2 GiB"   "${P_EP_VGIB[0]}" "$(awk -v r="$r2" 'BEGIN { printf "%.2f", r }')"
    done

    # 9 / 10 defaults: 60 min episode
    COMPRESS_CONF="$T/compress.conf"
    load_policy 2>/dev/null
    AUDIO_CHANNELS=(6 2)
    set_eps 50000 3600
    series_video_plan High; series_plan High "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
    eq "series default High 60 min: ~3.00 GiB video" "${P_EP_VGIB[0]}" 3.00
    series_video_plan Base; series_plan Base "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
    eq "series default Base 60 min: ~1.25 GiB video" "${P_EP_VGIB[0]}" 1.25

    # Custom: entered GiB/hour, no floor / max, High audio
    series_video_plan Custom 2
    eq "series Custom 2 GiB/hour"                "$SPLAN_TARGET_KBPS/$SPLAN_FLOOR_KBPS/$SPLAN_MAX_KBPS" "$(gib_per_hour_to_kbps 2)/0/0"
    unset -f set_eps
    unset EP_DUR EP_VKBPS EP_AKBPS AUDIO_CHANNELS
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
reject "negative size"            "must not be negative"     MOVIE_HIGH_VIDEO_GIB_PER_HOUR=-3
reject "negative bitrate"         "must not be negative"     MOVIE_BASE_VIDEO_FLOOR_MBPS=-1
reject "non-numeric value"        "not a number"             MOVIE_HIGH_VIDEO_MAX_MBPS=twelve
reject "floor above nonzero max"  "is greater than MOVIE_HIGH_VIDEO_MAX_MBPS" MOVIE_HIGH_VIDEO_FLOOR_MBPS=15
reject "zero High GiB/hour"       'MOVIE_HIGH_VIDEO_GIB_PER_HOUR="0": must be greater than 0' MOVIE_HIGH_VIDEO_GIB_PER_HOUR=0
reject "zero Base GiB/hour"       'MOVIE_BASE_VIDEO_GIB_PER_HOUR="0": must be greater than 0' MOVIE_BASE_VIDEO_GIB_PER_HOUR=0
reject "negative High floor"      'MOVIE_HIGH_VIDEO_FLOOR_MBPS="-1": must not be negative' MOVIE_HIGH_VIDEO_FLOOR_MBPS=-1
reject "negative Base max"        'MOVIE_BASE_VIDEO_MAX_MBPS="-5": must not be negative' MOVIE_BASE_VIDEO_MAX_MBPS=-5
reject "Base floor above max"     'MOVIE_BASE_VIDEO_FLOOR_MBPS (6) is greater than MOVIE_BASE_VIDEO_MAX_MBPS (5)' MOVIE_BASE_VIDEO_FLOOR_MBPS=6
for k in MOVIE_HIGH_VIDEO_GIB_PER_HOUR MOVIE_BASE_VIDEO_GIB_PER_HOUR MOVIE_HIGH_VIDEO_FLOOR_MBPS MOVIE_BASE_VIDEO_MAX_MBPS; do
    f=$(conf_with "unset$k"); sed -i "/^$k=/d" "$f"
    reject_file "missing $k" "$k is not set" "$f"
done
reject "decimal kb/s"             "whole number of kb/s"     SERIES_HIGH_AAC_KBPS_6=640.5
reject "bad audio mode"           "must be \"copy\" or \"cap\"" MOVIE_QUALITY_AUDIO_MODE=lossless
reject "zero Quality GiB/hour"    'MOVIE_QUALITY_VIDEO_GIB_PER_HOUR="0": must be greater than 0' MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=0
reject "zero Quality minimum"     'MOVIE_QUALITY_VIDEO_MIN_GIB="0": must be greater than 0' MOVIE_QUALITY_VIDEO_MIN_GIB=0
reject "negative Quality floor"   'MOVIE_QUALITY_VIDEO_FLOOR_MBPS="-1": must not be negative' MOVIE_QUALITY_VIDEO_FLOOR_MBPS=-1
reject "negative Quality max"     'MOVIE_QUALITY_VIDEO_MAX_MBPS="-5": must not be negative' MOVIE_QUALITY_VIDEO_MAX_MBPS=-5
reject "Quality floor above max"  'MOVIE_QUALITY_VIDEO_FLOOR_MBPS (12) is greater than MOVIE_QUALITY_VIDEO_MAX_MBPS (10)' MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=10
f=$(conf_with qunset); sed -i '/^MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=/d' "$f"
reject_file "missing Quality GiB/hour" "MOVIE_QUALITY_VIDEO_GIB_PER_HOUR is not set" "$f"
check "Quality floor 12 max 0 allowed" "( COMPRESS_CONF=\$(conf_with qok MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=0) load_policy )"
reject "bad Base audio choice"    "is not a size greater than 0" 'MOVIE_BASE_AUDIO_MAX_GIB_CHOICES="1 none"'
f=$(conf_with unset); sed -i '/^SERIES_CONTAINER_RESERVE_PCT=/d' "$f"
reject_file "missing setting"     "SERIES_CONTAINER_RESERVE_PCT is not set" "$f"
reject "zero series High GiB/hour" 'SERIES_HIGH_VIDEO_GIB_PER_HOUR="0": must be greater than 0' SERIES_HIGH_VIDEO_GIB_PER_HOUR=0
reject "zero series Base GiB/hour" 'SERIES_BASE_VIDEO_GIB_PER_HOUR="0": must be greater than 0' SERIES_BASE_VIDEO_GIB_PER_HOUR=0
reject "negative series floor"    'SERIES_HIGH_VIDEO_FLOOR_MBPS="-1": must not be negative' SERIES_HIGH_VIDEO_FLOOR_MBPS=-1
reject "negative series max"      'SERIES_BASE_VIDEO_MAX_MBPS="-2": must not be negative' SERIES_BASE_VIDEO_MAX_MBPS=-2
reject "series floor above max"   'SERIES_BASE_VIDEO_FLOOR_MBPS (6) is greater than SERIES_BASE_VIDEO_MAX_MBPS (5)' SERIES_BASE_VIDEO_FLOOR_MBPS=6
check "series floor 6 max 0 allowed" "( COMPRESS_CONF=\$(conf_with sok SERIES_BASE_VIDEO_FLOOR_MBPS=6 SERIES_BASE_VIDEO_MAX_MBPS=0) load_policy )"
for k in SERIES_HIGH_VIDEO_GIB_PER_HOUR SERIES_BASE_VIDEO_GIB_PER_HOUR SERIES_HIGH_VIDEO_FLOOR_MBPS SERIES_BASE_VIDEO_MAX_MBPS; do
    f=$(conf_with "unset$k"); sed -i "/^$k=/d" "$f"
    reject_file "missing $k" "$k is not set" "$f"
done
reject_file "missing file"        "Compression policy file not found" "$T/nope.conf"
check "floor = 0 max = 0 allowed" "( COMPRESS_CONF=\$(conf_with zero MOVIE_HIGH_VIDEO_FLOOR_MBPS=0 MOVIE_HIGH_VIDEO_MAX_MBPS=0) load_policy )"
check "no policy numbers left in movie menu" \
    "! grep -nE '(VIDEO_(FLOOR|PREFERRED|UPPER|MAX_GIB|TARGET_GIB))=[0-9]|AUDIO_CAP_GIB=[0-9]|echo (768|640|512|448|320|256|192|128|96|64)\$' '$SRC_WORK/movie_compress.sh'"
check "no policy numbers left in series menu" \
    "! grep -nE 'echo (768|640|384|320|256|192|128|96|64)\$|GIB_PER_HOUR=\"?[0-9]|_KBPS=[0-9]|0\\.99|< 500|gib_per_hour_to_kbps' '$SRC_WORK/series_compress.sh'"
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
