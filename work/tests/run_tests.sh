#!/usr/bin/env bash
# Regression tests for the encode pipeline (Linux, no sudo).
#
#   bash ~/compress/work/tests/run_tests.sh [--keep]
#
#  1. bash -n on every script
#  2. unit: audio title rewriting / false-claim detection (Atmos, DTS:X,
#     codec names, bitrates, commentary text kept)
#  3. SDR source, audio copied: two-pass job (Quality path, no DV
#     steps) and single-pass CRF job (High / Base / Custom path); tracks,
#     flags, languages, titles (unchanged), chapters, attachments kept
#  4. HDR10 source: HDR10 metadata kept; all audio copied unchanged and
#     verified (codec / layout / payload hash)
#  5. MP4 source with styled mov_text: conversion + styling loss reported
#  6. needs mkvtoolnix: ordered chapters / 2 editions / nesting / hidden
#     / multi-language names / segment reference restored and verified
#  7. needs dovi_tool + mkvtoolnix: synthetic Dolby Vision profile 8.1,
#     DV preserved and downscaled, L5 offsets rescaled
#  8. stream statistics: stored MKV tags used when valid, rejected when
#     missing / incomplete / inconsistent / stale, packet scan fallback;
#     verify.sh Validate + update (needs mkvtoolnix)
#  9. refresh after a fallback scan: one scan, MKV statistics rewritten
#     for the next run (never for symlinks, read-only or non-MKV files,
#     or sources a running compression job is reading)
# 10. movie / series menus copy every audio track (all tiers, Custom);
#     only audio_compress_menu.sh converts audio
# 11. CRF tiers: High / Base start at CRF_MIN and step up only while the
#     sampled video estimate is above the ceiling (stand-in estimator and
#     real sample encodes); Custom CRF; series use one CRF per batch;
#     samples follow the output resolution / HDR signalling; ceiling
#     warning; source-quality guard (keep source video / encode / skip);
#     estimate vs actual reported; progress-check shows one encode step
# 12. HDR10 / HDR10+ (needs hdr10plus_tool) / Dolby Vision on the CRF path
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
    for dur in 3600 6000 10800 20000; do
        movie_video_plan Quality "$dur"
        eq "movie Quality ${dur}s target from config" "$PLAN_TARGET_MBPS" "$(exp_quality "$dur")"
    done
    movie_video_plan Quality 5400
    eq "movie Quality 90 min not below floor" "$PLAN_BELOW_FLOOR" 0
    check "movie_video_plan is Quality-only"  "! movie_video_plan High 7200 2>/dev/null"

    for tier in Quality High Base Custom; do
        check "movie $tier policy: audio copied" "[[ \"\$(movie_policy_line $tier)\" == *'; audio copied' ]]"
    done
    check "no movie/series audio policy functions left" \
        "! declare -F movie_aac_kbps movie_audio_cap_gib build_audio_args series_aac_kbps >/dev/null"
    check "no High/Base size-target functions left" \
        "! declare -F series_video_plan series_plan series_episode_video_kbps series_gib_per_hour >/dev/null"
    check "no movie/series AAC settings in the config" \
        "! grep -qE '^(MOVIE|SERIES)_[A-Z_]*(AAC|AUDIO)' '$SRC_WORK/lib/compress.conf'"
    check "no High/Base GiB/hour settings in the config" \
        "! grep -qE '^(MOVIE|SERIES)_(HIGH|BASE)_VIDEO_(GIB_PER_HOUR|FLOOR_MBPS|MAX_MBPS)=' '$SRC_WORK/lib/compress.conf'"
    check "audio menu settings still in the config" \
        "grep -q '^AUDIO_HIGH_KBPS_5TO6=' '$SRC_WORK/lib/compress.conf' && grep -q '^AUDIO_COMPACT_LIMIT_GIB=' '$SRC_WORK/lib/compress.conf'"
    eq "series reserve from config"       "$(series_size_factor)" \
        "$(awk -v r="$SERIES_CONTAINER_RESERVE_PCT" 'BEGIN { printf "%.6f", (100 - r) / 100 }')"
    eq "audio menu High 5.1 from config"  "$(audio_menu_high_kbps 6)" "$AUDIO_HIGH_KBPS_5TO6"

    # the CRF tier values come from compress.conf
    eq "config: movie High 19-23 / 7 GiB"   "$MOVIE_HIGH_CRF_MIN $MOVIE_HIGH_CRF_MAX $MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB" "19 23 7"
    eq "config: movie Base 25-29 / 2 GiB"   "$MOVIE_BASE_CRF_MIN $MOVIE_BASE_CRF_MAX $MOVIE_BASE_VIDEO_SIZE_CEILING_GIB" "25 29 2"
    eq "config: series High 19-23 / 7 GiB"  "$SERIES_HIGH_CRF_MIN $SERIES_HIGH_CRF_MAX $SERIES_HIGH_VIDEO_SIZE_CEILING_GIB" "19 23 7"
    eq "config: series Base 25-29 / 2 GiB"  "$SERIES_BASE_CRF_MIN $SERIES_BASE_CRF_MAX $SERIES_BASE_VIDEO_SIZE_CEILING_GIB" "25 29 2"
    crf_tier_load movie High
    eq "crf_tier_load movie High"         "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB $CRF_CEILING_BYTES" "19 23 7 $(gib_bytes 7)"
    crf_tier_load series Base
    eq "crf_tier_load series Base"        "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB $CRF_CEILING_BYTES" "25 29 2 $(gib_bytes 2)"
    crf_tier_load movie Custom 21.5
    eq "crf_tier_load Custom: exact, no ceiling" "$CRF_MIN $CRF_MAX $CRF_CEILING_BYTES" "21.5 21.5 0"
    pl=$(crf_policy_lines movie High)
    check "policy lines: CRF range + ceiling" \
        "grep -q 'CRF range: 19-23 (19 preferred' <<< \"\$pl\" && grep -q 'video size ceiling: 7 GiB' <<< \"\$pl\" && grep -q 'audio: copied unchanged' <<< \"\$pl\""
    check "policy lines: no 'minimum quality' wording" \
        "! { crf_policy_lines movie High; crf_policy_lines series Base; movie_policy_line High; } | grep -qi 'minimum quality'"
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
    # Quality: two-pass GiB/hour with a minimum size (unchanged policy;
    # fixed values, not the defaults)
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

    # Quality: a source below its floor still gets the size target
    mbps_bytes() { awk -v x="$1" 'BEGIN { printf "%.0f", x * 1000000 / 8 * 7200 }'; }
    COMPRESS_CONF=$(conf_with qsrc MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=0.1 MOVIE_QUALITY_VIDEO_MIN_GIB=0.1 \
        MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=0)
    load_policy 2>/dev/null
    movie_video_plan Quality 7200 "$(mbps_bytes 6)"
    eq "Quality src<floor: size target kept" "$PLAN_TARGET_MBPS" "$(bitrate_for_gib 0.2 7200)"
    eq "Quality src<floor: conflict as before" "$PLAN_BELOW_FLOOR" 1

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

    # edited CRF settings are used
    COMPRESS_CONF=$(conf_with crfedit MOVIE_HIGH_CRF_MIN=18 MOVIE_HIGH_CRF_MAX=22 MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB=9.5)
    load_policy 2>/dev/null
    crf_tier_load movie High
    eq "edited High CRF settings"         "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB" "18 22 9.5"

    # a config still setting the former audio policy loads, with a note
    COMPRESS_CONF=$(conf_with retired MOVIE_HIGH_AUDIO_MAX_GIB=2 SERIES_HIGH_AAC_KBPS_6=640)
    check "retired audio settings: still loads"   "load_policy 2>'$T/retired.err'"
    check "retired audio settings: named as ignored" \
        "grep -q 'ignored' '$T/retired.err' && grep -q MOVIE_HIGH_AUDIO_MAX_GIB '$T/retired.err' && grep -q SERIES_HIGH_AAC_KBPS_6 '$T/retired.err'"

    # ... and the former High/Base GiB/hour settings, with a note
    COMPRESS_CONF=$(conf_with retiredv MOVIE_HIGH_VIDEO_GIB_PER_HOUR=3.0 SERIES_BASE_VIDEO_FLOOR_MBPS=2.5)
    check "retired GiB/hour settings: still loads" "load_policy 2>'$T/retiredv.err'"
    check "retired GiB/hour settings: named as ignored" \
        "grep -q 'High/Base size-target' '$T/retiredv.err' && grep -q MOVIE_HIGH_VIDEO_GIB_PER_HOUR '$T/retiredv.err' && grep -q SERIES_BASE_VIDEO_FLOOR_MBPS '$T/retiredv.err'"
}
COMPRESS_CONF="$T/compress.conf"
load_policy 2>/dev/null

# ------------------------------------------------------------
echo
echo "== CRF selection (estimates from a stand-in estimator)"
{
    # fake_est CRF: estimated video GiB per CRF from FAKE[crf]; records calls
    declare -A FAKE=()
    CALLS=()
    fake_est() { CALLS+=("$1"); CRF_EST_RESULT=$(gib_bytes "${FAKE[$1]:-999}"); }
    run_sel() {   # SCOPE TIER "crf=GiB ..."  ->  crf_select with that table
        local kv
        FAKE=(); CALLS=()
        for kv in $3; do FAKE[${kv%%=*}]="${kv#*=}"; done
        crf_tier_load "$1" "$2"
        crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" fake_est
    }

    # 1 / 2 High starts at CRF 19; 19 fits under 7 GiB -> 19, nothing else tried
    run_sel movie High "19=4.5 20=4.0"
    eq "1 High starts at CRF 19"                 "${CALLS[0]}" 19
    eq "2 High 19 fits (4.5 GiB) -> CRF 19"      "$CRF_SELECTED/${CRF_TRIED[*]}/$CRF_OVER_CEILING" "19/19/0"
    eq "10 High never tries below 19 (no 18)"    "$(printf '%s\n' "${CALLS[@]}" | sort -n | head -1)" 19
    run_sel movie High "19=7 20=6"
    eq "High: exactly at the ceiling fits"       "$CRF_SELECTED" 19

    # 3 19 too large, 20 fits -> 20
    run_sel movie High "19=8.6 20=6.9 21=6.0"
    eq "3 High 19 too large, 20 fits -> 20"      "$CRF_SELECTED/${CRF_TRIED[*]}" "20/19 20"
    # spec example: 8.6 / 7.4 / 6.5 -> 21
    run_sel movie High "19=8.6 20=7.4 21=6.5 22=5.9"
    eq "High 8.6/7.4/6.5 -> lowest fitting 21"   "$CRF_SELECTED/${CRF_TRIED[*]}" "21/19 20 21"
    eq "High: estimates kept per CRF"            "$(crf_analysis_lines | tr -s ' ' | tr '\n' ';')" \
        " CRF 19 -> estimated 8.60 GiB video; CRF 20 -> estimated 7.40 GiB video; CRF 21 -> estimated 6.50 GiB video;"

    # 4 continues through 23
    run_sel movie High "19=12 20=11 21=10 22=9 23=6.9"
    eq "4 High continues through 23"             "$CRF_SELECTED/${CRF_TRIED[*]}/$CRF_OVER_CEILING" "23/19 20 21 22 23/0"

    # 5 / 12 23 still too large -> 23, warned, never 24
    run_sel movie High "19=12 20=11 21=10 22=9 23=8.1 24=1"
    eq "5 High 23 too large -> 23 + over ceiling" "$CRF_SELECTED/$CRF_OVER_CEILING" "23/1"
    eq "12 High never exceeds 23"                "$(printf '%s\n' "${CALLS[@]}" | sort -n | tail -1)" 23
    eq "5 oversize reported"                     "$(crf_oversize_gib "${CRF_EST[23]}" "$CRF_CEILING_BYTES")" "1.10"

    # 6 / 7 Base starts at 25; 25 fits under 2 GiB -> 25
    run_sel movie Base "25=1.5 26=1.2"
    eq "6 Base starts at CRF 25"                 "${CALLS[0]}" 25
    eq "7 Base 25 fits -> 25, no 26+"            "$CRF_SELECTED/${CRF_TRIED[*]}" "25/25"
    eq "11 Base never tries below 25"            "$(printf '%s\n' "${CALLS[@]}" | sort -n | head -1)" 25

    # 8 Base increases up through 29 as needed
    for want in 26 27 28 29; do
        tbl=""
        for c in 25 26 27 28 29; do
            if (( c < want )); then tbl+="$c=3 "; else tbl+="$c=1.9 "; fi
        done
        run_sel movie Base "$tbl"
        eq "8 Base first fit at $want -> $want"  "$CRF_SELECTED/$CRF_OVER_CEILING" "$want/0"
    done

    # 9 / 12 29 still too large -> 29, warned, never 30
    run_sel movie Base "25=5 26=4.5 27=4 28=3.5 29=3 30=1"
    eq "9 Base 29 too large -> 29 + over ceiling" "$CRF_SELECTED/$CRF_OVER_CEILING" "29/1"
    eq "12 Base never exceeds 29"                "$(printf '%s\n' "${CALLS[@]}" | sort -n | tail -1)" 29

    # 13 audio is not part of the selection: 6.5 GiB video fits 7 GiB even
    # when copied audio makes the file far larger
    run_sel movie High "19=6.5"
    eq "13 audio ignored: CRF 19 kept"           "$CRF_SELECTED" 19
    total=$(crf_total_bytes "${CRF_EST[19]}" "$(gib_bytes 4)" "$(gib_bytes 0.1)")
    check "13 total above the ceiling, CRF unchanged" "(( $total > CRF_CEILING_BYTES )) && [[ $CRF_SELECTED == 19 ]]"
    # 14 copied audio + other streams added to the total preview
    eq "14 total = video + audio + other"        "$total" "$(( $(gib_bytes 6.5) + $(gib_bytes 4) + $(gib_bytes 0.1) ))"
    eq "14 unknown audio counts as 0"            "$(crf_total_bytes 100 N/A 5)" 105

    # 18 Custom: exactly the entered CRF, one estimate
    FAKE=([24]=50); CALLS=()
    crf_select_exact 24 fake_est
    eq "18 Custom exact CRF 24, one estimate"    "$CRF_SELECTED/${CALLS[*]}/$CRF_OVER_CEILING" "24/24/0"
    check "Custom CRF validation"                "crf_valid 0 && crf_valid 21 && crf_valid 20.5 && crf_valid 51 && ! crf_valid 52 && ! crf_valid -1 && ! crf_valid abc && ! crf_valid ''"

    # an estimator failure stops the selection
    bad_est() { return 1; }
    check "estimate failure -> no CRF"           "! crf_select 19 23 1 bad_est && [[ -z \$CRF_SELECTED ]]"

    # source-quality guard
    check "guard: estimate >= source"            "crf_above_source 100 100 && crf_above_source 101 100"
    check "guard: estimate < source"             "! crf_above_source 99 100"
    check "guard: unknown source -> no guard"    "! crf_above_source 99 N/A && ! crf_above_source 99 0"

    # sample sections: spread 10..90 %, never past the end; short titles whole
    eq "sample points: 2 h, 5 x 20 s"            "$(crf_sample_points 7200 5 20 | tr '\n' ';')" \
        "710.000 20.000;2150.000 20.000;3590.000 20.000;5030.000 20.000;6470.000 20.000;"
    eq "sample points: one point at 50 %"        "$(crf_sample_points 1000 1 20)" "490.000 20.000"
    eq "sample points: short title sampled whole" "$(crf_sample_points 150 5 20)" "0.000 150.000"
    eq "extrapolation: bitrate x runtime"        "$(crf_extrapolate 1000000 100 7200)" 72000000
    eq "estimate error +6.3%"                    "$(estimate_error_pct 6871947674 7301444403)" "+6.2%"
    eq "estimate error -10.0%"                   "$(estimate_error_pct 1000 900)" "-10.0%"
    eq "size_text MiB below 0.1 GiB"             "$(size_text 2097152)" "0.00 GiB (2.0 MiB)"
    unset -f fake_est bad_est run_sel
}

# ------------------------------------------------------------
echo
echo "== series CRF: one CRF per batch, median episode"
{
    eq "sample episodes: 10 -> 4 spread"         "$(series_sample_episodes 10 4 | tr '\n' ' ')" "0 3 6 9 "
    eq "sample episodes: 3 of 4 -> all"          "$(series_sample_episodes 3 4 | tr '\n' ' ')" "0 1 2 "
    eq "sample episodes: 1 wanted -> middle"     "$(series_sample_episodes 9 1)" 4

    # spread: unsampled episodes get the median sampled bitrate
    EP_DUR=(2700 2700 2700 2700 2700)
    series_crf_spread 500000 - 600000 - 4000000
    eq "spread: median sampled rate"             "$SC_MEDIAN_RATE" 600000.000
    eq "spread: per-episode bytes"               "${SC_EP_BYTES[*]}" "1350000000 1620000000 1620000000 1620000000 10800000000"
    eq "spread: sources"                         "${SC_EP_FROM[*]}" "sample median sample median sample"
    eq "spread: median episode"                  "$SC_MEDIAN_BYTES" 1620000000

    # 17 crf_series_estimate with stand-in sample encodes: one complex
    # episode (E3) does not pull the batch to a worse CRF
    FILES=(/s/E1.mkv /s/E2.mkv /s/E3.mkv /s/E4.mkv /s/E5.mkv); EP_VIDX=(0 0 0 0 0)
    EP_DUR=(2700 2700 2700 2700 2700)
    CRF_SERIES_SAMPLED=(0 1 2 3 4); CRF_SERIES_FILTER=""
    declare -A CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=()
    eval "$(declare -f crf_sample_title | sed '1s/crf_sample_title/_real_crf_sample_title/')"
    crf_sample_title() {   # E3: 3x the bitrate of the others; -15 % per CRF step
        local f="$1" crf="$4" base=1.5
        [[ "$f" == */E3.mkv ]] && base=4.5
        CRF_SAMPLE_SECS=100
        CRF_SAMPLE_BYTES=$(awk -v b="$base" -v c="$crf" 'BEGIN { printf "%.0f", b * 1073741824 * 0.85 ^ (c - 25) / 27 }')
    }
    crf_tier_load series Base
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate > "$T/series_sel.out"
    read -ra eb <<< "${CRF_SERIES_EP_BYTES[$CRF_SELECTED]}"
    eq "17 series: one CRF for the batch (median fits at 25)" "$CRF_SELECTED/${CRF_TRIED[*]}" "25/25"
    check "17 series: complex episode above the ceiling, same CRF" "(( ${eb[2]} > CRF_CEILING_BYTES && ${eb[0]} <= CRF_CEILING_BYTES ))"
    check "17 series: progress per sampled episode" "grep -q 'sampling CRF 25, episode 3/5 (E3.mkv)' '$T/series_sel.out'"

    # median above the ceiling -> the whole batch moves up together
    crf_sample_title() {
        CRF_SAMPLE_SECS=100
        CRF_SAMPLE_BYTES=$(awk -v c="$4" 'BEGIN { printf "%.0f", 3 * 1073741824 * 0.85 ^ (c - 25) / 27 }')
    }
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate > /dev/null
    eq "series: median too large -> next CRF for all" "$CRF_SELECTED/${CRF_TRIED[*]}" "28/25 26 27 28"
    eval "$(declare -f _real_crf_sample_title | sed '1s/_real_crf_sample_title/crf_sample_title/')"

    # expected series sizes: copied audio on top, reserve added
    EP_DUR=(3600 1800); EP_VKBPS=(8000 8000); EP_AKBPS=("768 192" "768 192")
    EP_ABYTES=($(awk 'BEGIN { printf "%.0f %.0f", 960 * 1000 / 8 * 3600, 960 * 1000 / 8 * 1800 }'))
    series_crf_plan "$(gib_bytes 2)" "$(gib_bytes 1)"
    eq "series plan: video per episode"          "${P_EP_VGIB[*]}" "2.00 1.00"
    eq "series plan: copied audio kb/s"          "${P_EP_AKBPS[0]}" 960
    eq "series plan: total = (video + audio) / reserve" "${P_EP_GIB[0]}" \
        "$(awk -v a="${EP_ABYTES[0]}" -v f="$(series_size_factor)" 'BEGIN { printf "%.2f", (2 * 1073741824 + a) / 1073741824 / f }')"
    eq "series plan: totals"                     "$P_VIDEO_GIB/$P_TOTAL_SECONDS" "3.00/5400.000"
    series_crf_plan copy "$(gib_bytes 1)"
    eq "series plan: kept source video size"     "${P_EP_VGIB[0]}" "$(awk 'BEGIN { printf "%.2f", 8000 * 1000 / 8 * 3600 / 1073741824 }')"
    unset FILES EP_VIDX EP_DUR EP_VKBPS EP_AKBPS EP_ABYTES CRF_SERIES_SAMPLED CRF_SERIES_EP_BYTES CRF_SERIES_EP_FROM
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
reject "negative CRF"             'MOVIE_HIGH_CRF_MIN="-1": must not be negative' MOVIE_HIGH_CRF_MIN=-1
reject "CRF above 51"             'SERIES_BASE_CRF_MAX="52": outside the x265 CRF range 0-51' SERIES_BASE_CRF_MAX=52
reject "decimal CRF in config"    'MOVIE_BASE_CRF_MIN="25.5": must be a whole number' MOVIE_BASE_CRF_MIN=25.5
reject "non-numeric CRF"          'MOVIE_HIGH_CRF_MAX="high": must be a whole number' MOVIE_HIGH_CRF_MAX=high
reject "High CRF_MAX < CRF_MIN"   'MOVIE_HIGH_CRF_MAX (18) is lower than MOVIE_HIGH_CRF_MIN (19)' MOVIE_HIGH_CRF_MAX=18
reject "Base CRF_MAX < CRF_MIN"   'MOVIE_BASE_CRF_MAX (24) is lower than MOVIE_BASE_CRF_MIN (25)' MOVIE_BASE_CRF_MAX=24
reject "series CRF_MAX < CRF_MIN" 'SERIES_HIGH_CRF_MAX (20) is lower than SERIES_HIGH_CRF_MIN (21)' SERIES_HIGH_CRF_MIN=21 SERIES_HIGH_CRF_MAX=20
reject "zero High ceiling"        'MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB="0": must be greater than 0' MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB=0
reject "negative Base ceiling"    'SERIES_BASE_VIDEO_SIZE_CEILING_GIB="-2": must not be negative' SERIES_BASE_VIDEO_SIZE_CEILING_GIB=-2
reject "zero sample seconds"      'CRF_SAMPLE_SECONDS="0": must be greater than 0' CRF_SAMPLE_SECONDS=0
reject "zero sample points"       'MOVIE_CRF_SAMPLE_POINTS="0": must be at least 1' MOVIE_CRF_SAMPLE_POINTS=0
check "CRF_MIN = CRF_MAX allowed" "( COMPRESS_CONF=\$(conf_with crfeq MOVIE_HIGH_CRF_MIN=21 MOVIE_HIGH_CRF_MAX=21) load_policy )"
check "CRF 0 allowed"             "( COMPRESS_CONF=\$(conf_with crf0 MOVIE_HIGH_CRF_MIN=0) load_policy )"
for k in MOVIE_HIGH_CRF_MIN MOVIE_HIGH_CRF_MAX MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB \
         MOVIE_BASE_CRF_MIN MOVIE_BASE_CRF_MAX MOVIE_BASE_VIDEO_SIZE_CEILING_GIB \
         SERIES_HIGH_CRF_MIN SERIES_HIGH_CRF_MAX SERIES_HIGH_VIDEO_SIZE_CEILING_GIB \
         SERIES_BASE_CRF_MIN SERIES_BASE_CRF_MAX SERIES_BASE_VIDEO_SIZE_CEILING_GIB \
         CRF_SAMPLE_SECONDS MOVIE_CRF_SAMPLE_POINTS SERIES_CRF_SAMPLE_EPISODES SERIES_CRF_SAMPLE_POINTS; do
    f=$(conf_with "unset$k"); sed -i "/^$k=/d" "$f"
    reject_file "missing $k" "$k is not set" "$f"
done
reject "decimal kb/s"             "whole number of kb/s"     AUDIO_HIGH_KBPS_5TO6=640.5
reject "zero Quality GiB/hour"    'MOVIE_QUALITY_VIDEO_GIB_PER_HOUR="0": must be greater than 0' MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=0
reject "zero Quality minimum"     'MOVIE_QUALITY_VIDEO_MIN_GIB="0": must be greater than 0' MOVIE_QUALITY_VIDEO_MIN_GIB=0
reject "negative Quality floor"   'MOVIE_QUALITY_VIDEO_FLOOR_MBPS="-1": must not be negative' MOVIE_QUALITY_VIDEO_FLOOR_MBPS=-1
reject "negative Quality max"     'MOVIE_QUALITY_VIDEO_MAX_MBPS="-5": must not be negative' MOVIE_QUALITY_VIDEO_MAX_MBPS=-5
reject "non-numeric Quality max"  "not a number"             MOVIE_QUALITY_VIDEO_MAX_MBPS=twelve
reject "Quality floor above max"  'MOVIE_QUALITY_VIDEO_FLOOR_MBPS (12) is greater than MOVIE_QUALITY_VIDEO_MAX_MBPS (10)' MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=10
f=$(conf_with qunset); sed -i '/^MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=/d' "$f"
reject_file "missing Quality GiB/hour" "MOVIE_QUALITY_VIDEO_GIB_PER_HOUR is not set" "$f"
check "Quality floor 12 max 0 allowed" "( COMPRESS_CONF=\$(conf_with qok MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12 MOVIE_QUALITY_VIDEO_MAX_MBPS=0) load_policy )"
f=$(conf_with unset); sed -i '/^SERIES_CONTAINER_RESERVE_PCT=/d' "$f"
reject_file "missing setting"     "SERIES_CONTAINER_RESERVE_PCT is not set" "$f"
reject_file "missing file"        "Compression policy file not found" "$T/nope.conf"
check "no policy numbers left in movie menu" \
    "! grep -nE '(VIDEO_(FLOOR|PREFERRED|UPPER|MAX_GIB|TARGET_GIB))=[0-9]|AUDIO_CAP_GIB=[0-9]|echo (768|640|512|448|320|256|192|128|96|64)\$|CRF_(MIN|MAX)=\"?[0-9]|CEILING(_GIB|_BYTES)?=\"?[0-9]|crf:[0-9]|crf_select \"?[0-9]|SAMPLE_(SECONDS|POINTS)=[0-9]' '$SRC_WORK/movie_compress.sh'"
check "no policy numbers left in series menu" \
    "! grep -nE 'echo (768|640|384|320|256|192|128|96|64)\$|GIB_PER_HOUR=\"?[0-9]|_KBPS=[0-9]|0\\.99|< 500|gib_per_hour_to_kbps|CRF_(MIN|MAX)=\"?[0-9]|CEILING(_GIB|_BYTES)?=\"?[0-9]|crf:[0-9]|crf_select \"?[0-9]|SAMPLE_(SECONDS|POINTS|EPISODES)=[0-9]' '$SRC_WORK/series_compress.sh'"
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
# run_item NAME INPUT FILTER [OVERWRITE] [VIDEO] [EST_VIDEO_BYTES]
#   ->  job script + output + log. VIDEO: two-pass kb/s (default 1500,
#   the Quality path), crf:N (High / Base / Custom) or copy
run_item() {
    local name="$1" in="$2" filter="$3" overwrite="${4:-0}" video="${5:-1500}" est="${6:-}"
    local job="$WORK_DIR/$name.sh"

    [[ "$video" =~ ^[0-9]+$ ]] && mkdir -p "$WORK_DIR/${name}_passes"
    {
        emit_job_header "$name" movie 1
        emit_encode_item 1 "$in" "$T/out/$name.mkv" Test "$video" "$filter" \
            "$WORK_DIR/${name}_passes/pass_0" "$overwrite" "$est"
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
    check "$n: audio 1 COPIED, payload MATCH"  "report_has $n 'Audio track 1: +COPIED \\(AC-3 5.1.* 48000 Hz, payload MD5 MATCH\\)'"
    check "$n: audio 2 COPIED, payload MATCH"  "report_has $n 'Audio track 2: +COPIED \\(AC-3 stereo, 48000 Hz, payload MD5 MATCH\\)'"
    check "$n: commentary track kept"          "[[ \$(ffprobe -v error -select_streams a:1 -show_entries stream_disposition=comment -of default=nw=1:nk=1 '$T/out/$n.mkv') == 1 ]]"
    check "$n: stale source video BPS not copied" \
        "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream_tags=BPS -of default=nw=1:nk=1 '$T/out/$n.mkv') != 99999999 ]]"
}

nondv_job_checks() {   # two-pass (Quality) job
    local n="$1" job="$WORK_DIR/$1.sh"

    check "$n: two libx265 passes"             "[[ \$(grep -c 'libx265' '$job') == 2 ]]"
    check "$n: two-pass bitrate (-b:v)"        "grep -q -- '-b:v:0 1500k' '$job' && ! grep -q -- '-crf' '$job'"
    check "$n: pass 1 / pass 2 stats"          "grep -q 'pass=1:stats=' '$job' && grep -q 'pass=2:stats=' '$job'"
    check "$n: no Dolby Vision steps"          "! grep -qE 'item_dv_|item_step rpu|-copyts' '$job'"
    check "$n: no HDR10+ steps"                "! grep -q 'hdr10plus' '$job'"
    check "$n: metadata + chapters mapped"     "grep -q -- '-map_metadata 0 -map_chapters 0' '$job'"
    check "$n: chapter restore step"           "grep -q 'item_step chapters item_restore_mkv_chapters' '$job'"
    check "$n: video stats stripped"           "grep -q -- '-metadata:s:v:0 BPS=' '$job'"
    check "$n: audio copied (-c:a copy)"       "grep -q -- '-c:a copy' '$job'"
    check "$n: no audio encoder arguments"     "! grep -qE -- '-c:a:[0-9]|-b:a|aac|eac3|libopus|-ac |-ar ' '$job'"
    check "$n: pass 1 without audio"           "grep -q -- '-an -sn -dn -f null' '$job'"
    check "$n: final mux to .part"             "grep -q '\"\$ITEM_PART\"' '$job'"
}

# ------------------------------------------------------------
echo
echo "== SDR (audio copied)"
DV_POLICY=none; DV_MODE=""; HDR10P_POLICY=none
run_item sdr "$T/in/SDR.mkv" ""
nondv_job_checks sdr
common_checks sdr
check "sdr: HDR type SDR"                      "report_has sdr 'HDR type: +SDR\$'"
check "sdr: bt709 kept"                        "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream=color_space -of default=nw=1:nk=1 '$T/out/sdr.mkv') == bt709 ]]"
check "sdr: no audio title rewrite in job"     "! grep -q -- '-metadata:s:a:[0-9] title=' '$WORK_DIR/sdr.sh'"
eq    "sdr: copied audio 1 title unchanged"    "$(out_title sdr 0)" "$A0_TITLE"
eq    "sdr: copied audio 2 title unchanged"    "$(out_title sdr 1)" "$A1_TITLE"
check "sdr: track titles MATCH"                "report_has sdr 'Track titles: +MATCH'"
check "sdr: report: two-pass mode"             "grep -q 'Video encode mode: *two-pass bitrate (1500 kb/s)' '$T/sdr.log'"
check "sdr: stream is x265 two-pass"           "report_has sdr 'Video stream: +AS PLANNED \\(hevc 1280x720 yuv420p10le, two-pass 1500 kb/s\\)'"
check "verify.sh: x265 rate control read"      "[[ \"\$(x265_rate_control '$T/out/sdr.mkv' 0)\" == '2pass 1500' ]]"
check "sdr: pane shows pass 1/2 and 2/2"       "grep -q 'PASS 1/2' '$T/sdr.log' && grep -q 'PASS 2/2' '$T/sdr.log'"

# crf_job_checks NAME CRF  ->  single-pass CRF job: no -b:v, no passes
crf_job_checks() {
    local n="$1" crf="$2" job="$WORK_DIR/$1.sh"

    check "$n: one libx265 encode (single pass)" "[[ \$(grep -c 'libx265' '$job') == 1 ]]"
    check "$n: -crf $crf, preset slow, 10-bit"   "grep -q -- '-preset slow -crf:v:0 $crf -pix_fmt:v:0 yuv420p10le' '$job'"
    check "$n: no -b:v / pass / stats"           "! grep -qE -- '-b:v|pass=[12]|stats=|-pass ' '$job'"
    check "$n: no pass log for the item"         "grep -q \"^if item_begin .* ''\" '$job'"
    check "$n: one encode step, no pass 1/2"     "grep -q 'item_run encode ffmpeg' '$job' && ! grep -qE 'item_run [12]/2' '$job'"
    check "$n: mode / CRF in the item plan"      "grep -q 'item_expect .*mode=crf crf=$crf ' '$job'"
    check "$n: metadata + chapters mapped"       "grep -q -- '-map_metadata 0 -map_chapters 0' '$job'"
    check "$n: chapter restore step"             "grep -q 'item_step chapters item_restore_mkv_chapters' '$job'"
    check "$n: video stats stripped"             "grep -q -- '-metadata:s:v:0 BPS=' '$job'"
    check "$n: audio copied (-c:a copy)"         "grep -q -- '-c:a copy' '$job'"
    check "$n: no audio encoder arguments"       "! grep -qE -- '-c:a:[0-9]|-b:a|aac|eac3|libopus|-ac |-ar ' '$job'"
    check "$n: final mux to .part"               "grep -q '\"\$ITEM_PART\"' '$job'"
    check "$n: pane shows one CRF encode"        "grep -q 'ENCODING (single pass, CRF $crf)' '$T/$n.log' && ! grep -qE 'PASS [12]/2' '$T/$n.log'"
    check "$n: no x265 pass logs left"           "[[ -z \$(find '$WORK_DIR' \\( -name '*pass_0*' -o -name '*2pass*' -o -name '*.cutree' \\) 2>/dev/null) ]]"
    check "$n: video stream AS PLANNED (x265 CRF)" "report_has $n 'Video stream: +AS PLANNED \\(hevc .* yuv420p10le.*, CRF $crf(\\.0)? \\(single pass\\)\\)'"
    check "$n: report: CRF, single pass"         "grep -q 'Selected CRF: *$crf' '$T/$n.log' && grep -q 'Video encode mode: *CRF (single pass)' '$T/$n.log'"
    check "$n: report: audio copied unchanged"   "grep -q '^  Audio: *copied unchanged' '$T/$n.log'"
}

# whole_title_estimate FILE CRF [FILTER]  ->  video bytes of the sample-based
# estimate (the menus' estimator; a 2 s title is sampled whole)
whole_title_estimate() {
    CRF_TITLE_FILE="$1" CRF_TITLE_VIDX=0 CRF_TITLE_FILTER="${3:-}" \
    CRF_TITLE_DURATION=$(get_duration "$1") CRF_TITLE_POINTS="$MOVIE_CRF_SAMPLE_POINTS"
    crf_title_estimate "$2" > /dev/null && printf '%s' "$CRF_EST_RESULT"
}

echo
echo "== SDR, x265 CRF (High / Base / Custom path; audio copied)"
SDR_EST=$(whole_title_estimate "$T/in/SDR.mkv" 24)
check "sdrcrf: sample estimate available"      "[[ '$SDR_EST' =~ ^[0-9]+\$ ]]"
run_item sdrcrf "$T/in/SDR.mkv" "" 0 crf:24 "$SDR_EST"
crf_job_checks sdrcrf 24
common_checks sdrcrf
check "sdrcrf: HDR type SDR"                   "report_has sdrcrf 'HDR type: +SDR\$'"
eq    "sdrcrf: copied audio 1 title unchanged" "$(out_title sdrcrf 0)" "$A0_TITLE"
check "25 sdrcrf: estimated size reported"     "grep -q 'Estimated video size: ' '$T/sdrcrf.log'"
check "25 sdrcrf: estimate error reported"     "grep -qE 'Estimate error: +[-+][0-9]+\\.[0-9]%' '$T/sdrcrf.log'"
err=$(grep -oE 'Estimate error: +[-+][0-9.]+' "$T/sdrcrf.log" | grep -oE '[-+][0-9.]+$')
check "25 sdrcrf: whole-title sample within 5% ($err%)" "awk -v e='$err' 'BEGIN { exit !(e > -5 && e < 5) }'"
check "25 sdrcrf: accuracy logged"             "awk -F'\\t' -v e='$SDR_EST' '\$9 == \"sdrcrf\" && \$2 == \"Test\" && \$3 == \"24\" && \$4 == \"1280x720\" && \$6 == e && \$7 ~ /^[0-9]+\$/ && \$8 ~ /%\$/ { f = 1 } END { exit !f }' '$WORK_DIR/logs/crf_estimates.tsv'"
check "25 sdrcrf: accuracy log header"         "head -1 '$WORK_DIR/logs/crf_estimates.tsv' | awk -F'\\t' '{ exit !(\$6 == \"estimated_video_bytes\" && \$7 == \"actual_video_bytes\" && \$8 == \"error_pct\") }'"

# a miss is reported, never a failure (the ceiling is a selection goal)
run_item sdrmiss "$T/in/SDR.mkv" "" 0 crf:24 1000
check "sdrmiss: far-off estimate still succeeds" "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/sdrmiss.log' && grep -qE 'Estimate error: +\\+[0-9]+' '$T/sdrmiss.log'"
check "sdrmiss: no re-encode"                  "[[ \$(grep -c 'ENCODING (single pass' '$T/sdrmiss.log') == 1 ]]"

echo
echo "== encode onto an output symlink"
mkdir -p "$T/ostore/dir"
printf 'precious target\n' > "$T/ostore/target.mkv"
printf 'keep me\n' > "$T/ostore/dir/inside.txt"
OSUM=$(md5sum < "$T/ostore/target.mkv")

ln -s "$T/ostore/target.mkv" "$T/out/osv.mkv"           # valid  + overwrite
run_item osv "$T/in/SDR.mkv" "" 1
check "valid + overwrite: job ok"             "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/osv.log'"
check "valid + overwrite: link replaced"      "[[ -f '$T/out/osv.mkv' && ! -L '$T/out/osv.mkv' ]]"
check "valid + overwrite: says so"            "grep -q 'Replacing the symlink osv.mkv (its target is not modified)' '$T/osv.log'"
eq    "valid + overwrite: target unchanged"   "$(md5sum < "$T/ostore/target.mkv")" "$OSUM"

ln -s "$T/ostore/gone.mkv" "$T/out/osb.mkv"             # broken + overwrite
run_item osb "$T/in/SDR.mkv" "" 1
check "broken + overwrite: job ok"            "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/osb.log'"
check "broken + overwrite: link replaced"     "[[ -f '$T/out/osb.mkv' && ! -L '$T/out/osb.mkv' ]]"
check "broken + overwrite: nothing created at the old link target" "[[ ! -e '$T/ostore/gone.mkv' ]]"

ln -s "$T/ostore/target.mkv" "$T/out/osk.mkv"           # valid, no overwrite
run_item osk "$T/in/SDR.mkv" "" 0
check "valid, keep both: saved as (2)"        "[[ -f '$T/out/osk (2).mkv' && -L '$T/out/osk.mkv' ]]"
eq    "valid, keep both: target unchanged"    "$(md5sum < "$T/ostore/target.mkv")" "$OSUM"

ln -s "$T/ostore/dir" "$T/out/osd.mkv"                  # symlink to a directory
run_item osd "$T/in/SDR.mkv" "" 1
check "dir symlink + overwrite: link replaced, dir untouched" \
    "[[ -f '$T/out/osd.mkv' && ! -L '$T/out/osd.mkv' && \$(ls '$T/ostore/dir') == inside.txt ]]"

ln -s "$T/ostore/target.mkv" "$T/out/osp.mkv.part"      # .part is a symlink
run_item osp "$T/in/SDR.mkv" "" 0
check "part symlink: item refused"            "grep -q 'osp.mkv.part is a symlink; refusing to write through it' '$T/osp.log'"
eq    "part symlink: target unchanged"        "$(md5sum < "$T/ostore/target.mkv")" "$OSUM"

echo
echo "== symlinked source"
mkdir -p "$T/store"
cp "$T/in/SDR.mkv" "$T/store/Linked.mkv"
ln -s "$T/store/Linked.mkv" "$T/in/Linked.mkv"
sum_before=$(md5sum < "$T/store/Linked.mkv")
run_item lnk "$T/in/Linked.mkv" ""
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
echo "== stream statistics: stored MKV tags first, packet scan as fallback"
ST="$T/stats"
mkdir -p "$ST"

# count packet scans: stats_load calls stream_packet_bytes for every scan
eval "$(declare -f stream_packet_bytes | sed '1s/stream_packet_bytes/_real_stream_packet_bytes/')"
stream_packet_bytes() { echo scan >> "$ST/scans"; _real_stream_packet_bytes "$@"; }
scans_during() {   # CMD...  ->  number of packet scans the command did
    : > "$ST/scans"
    "$@" >/dev/null
    wc -l < "$ST/scans" | tr -d ' '
}
# exact per-stream bytes, for comparison
pk() { _real_stream_packet_bytes "$1" | awk -v s="$2" '$1 == s { print $2 }'; }

# with_stats IN OUT  ->  OUT = IN with statistics tags matching its streams
# (mkvpropedit when available, otherwise the same values written by ffmpeg)
with_stats() {
    cp "$1" "$2"
    if (( HAVE_MKV == 1 )); then
        mkvpropedit -q "$2" --add-track-statistics-tags >/dev/null
        return
    fi
    local d args=() line i b
    d=$(get_duration "$1")
    while read -r i b; do
        args+=(-metadata:s:$i "NUMBER_OF_BYTES=$b"
               -metadata:s:$i "BPS=$(awk -v b="$b" -v d="$d" 'BEGIN { printf "%.0f", b * 8 / d }')")
    done < <(_real_stream_packet_bytes "$1")
    ffmpeg -v error -y -i "$1" -map 0 -c copy "${args[@]}" "$2"
}
# remux IN OUT FFMPEG_ARGS...  ->  stream copy with metadata edits
remux() { local i="$1" o="$2"; shift 2; ffmpeg -v error -y -i "$i" -map 0 -c copy "$@" "$o"; }

# 2 video (main + a second, smaller one) + 2 AC-3 audio (640k / 192k) + subtitles
printf '1\n00:00:01,000 --> 00:00:03,000\nHello\n' > "$ST/sub.srt"
ffmpeg -v error -y -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i testsrc=size=320x180:rate=24 \
    -f lavfi -i sine=f=440:sample_rate=48000 -i "$ST/sub.srt" -t 12 \
    -map 0:v -map 1:v -map 2:a -map 2:a -map 3:s \
    -c:v:0 libx264 -b:v:0 2M -c:v:1 libx264 -b:v:1 300k \
    -c:a ac3 -ac:a:0 6 -b:a:0 640k -ac:a:1 2 -b:a:1 192k -c:s srt "$ST/raw.mkv"
with_stats "$ST/raw.mkv" "$ST/valid.mkv"

# 1 valid statistics: used directly, no scan
eq    "stats 1: valid tags, no packet scan"     "$(scans_during stats_load "$ST/valid.mkv" "" exact)" 0
stats_load "$ST/valid.mkv" "" exact
eq    "stats 1: source = stored tags"            "$STATS_KIND/$STATS_REJECTED" "tags/"
eq    "stats 1: video bytes = packets"           "$(stats_field 0 bytes)" "$(pk "$ST/valid.mkv" 0)"
eq    "stats 1: totals = packets"                "$(stats_totals 0)" \
    "$(pk "$ST/valid.mkv" 0) $(( $(pk "$ST/valid.mkv" 2) + $(pk "$ST/valid.mkv" 3) )) 2 1"

# 2 missing statistics: packet scan
eq    "stats 2: no tags -> packet scan"          "$(scans_during stats_load "$ST/raw.mkv" "" exact)" 1
stats_load "$ST/raw.mkv" "" exact
eq    "stats 2: source = packet scan, no reject" "$STATS_KIND/$STATS_REJECTED" "packets/"
eq    "stats 2: scanned bytes exact"             "$(stats_field 2 bytes)" "$(pk "$ST/raw.mkv" 2)"

# 3 incomplete statistics (one stream lost NUMBER_OF_BYTES)
remux "$ST/valid.mkv" "$ST/incomplete.mkv" -metadata:s:3 NUMBER_OF_BYTES= -metadata:s:3 NUMBER_OF_BYTES-eng=
eq    "stats 3: incomplete -> packet scan"       "$(scans_during stats_load "$ST/incomplete.mkv" "" exact)" 1
stats_load "$ST/incomplete.mkv" "" exact
check "stats 3: reason names the stream"         "[[ '$STATS_REJECTED' == 'statistics incomplete for stream 3 (audio)' ]]"

# 4 BPS inconsistent with NUMBER_OF_BYTES / duration
remux "$ST/valid.mkv" "$ST/badbps.mkv" -metadata:s:0 "BPS=$(( $(stats_field 0 kbps) * 2000 + 5 ))"
eq    "stats 4: bad BPS -> packet scan"          "$(scans_during stats_load "$ST/badbps.mkv" "" exact)" 1
stats_load "$ST/badbps.mkv" "" exact
check "stats 4: rejected: BPS mismatch"          "[[ '$STATS_REJECTED' == 'BPS does not match NUMBER_OF_BYTES/duration for stream 0 (video)' ]]"
eq    "stats 4: fallback value exact"            "$(stats_field 0 bytes)" "$(pk "$ST/badbps.mkv" 0)"

# 5 statistics copied from the source onto a re-encoded stream
ffmpeg -v error -y -i "$ST/valid.mkv" -map 0 -c copy -c:v:0 libx264 -b:v:0 400k "$ST/reenc.mkv"
check "stats 5: re-encode kept the old tags"     "[[ \$(ffprobe -v error -select_streams 0 -show_entries stream_tags=NUMBER_OF_BYTES -of default=nw=1:nk=1 '$ST/reenc.mkv') == \$(pk '$ST/valid.mkv' 0) ]]"
eq    "stats 5: stale tags -> packet scan"       "$(scans_during stats_load "$ST/reenc.mkv" "" exact)" 1
stats_load "$ST/reenc.mkv" "" exact
check "stats 5: rejected as stale"               "[[ '$STATS_REJECTED' == *stale* ]]"
eq    "stats 5: real (re-encoded) size used"     "$(stats_field 0 bytes)" "$(pk "$ST/reenc.mkv" 0)"
# stale stats with an older date than the file
remux "$ST/valid.mkv" "$ST/olddate.mkv" -metadata creation_time=2030-01-01T00:00:00Z \
    -metadata:s:0 _STATISTICS_WRITING_DATE_UTC="2020-01-01 00:00:00"
stats_load "$ST/olddate.mkv" "" exact
check "stats 5: statistics older than the file"  "[[ '$STATS_REJECTED' == 'statistics are older than the file for stream 0 (video) (copied from the source?)' ]]"

# 7 several video / audio streams: each value belongs to its stream
stats_load "$ST/valid.mkv" "" exact
for s in 0 1 2 3 4; do
    eq "stats 7: stream $s bytes = its packets"  "$(stats_field "$s" bytes)" "$(pk "$ST/valid.mkv" "$s")"
done
check "stats 7: audio kb/s per stream"         "awk -v s=\"\$(stats_audio_kbps)\" 'BEGIN { split(s, k, \" \"); exit !(k[1] >= 634 && k[1] <= 646 && k[2] >= 190 && k[2] <= 194) }'"
b2=$(stats_field 2 bytes); b3=$(stats_field 3 bytes)
remux "$ST/valid.mkv" "$ST/swapped.mkv" \
    -metadata:s:2 "NUMBER_OF_BYTES=$b3" -metadata:s:2 "BPS=192000" \
    -metadata:s:3 "NUMBER_OF_BYTES=$b2" -metadata:s:3 "BPS=640000"
stats_load "$ST/swapped.mkv" "" exact
check "stats 7: swapped audio stats rejected"    "[[ '$STATS_REJECTED' == 'BPS does not match the ac3 bit rate for stream 2 (audio) (statistics of another stream?)' ]]"

# 8 symlink input: read through the link
ln -s "$ST/valid.mkv" "$ST/link.mkv"
eq    "stats 8: symlink, no packet scan"         "$(scans_during stats_load "$ST/link.mkv" "" exact)" 0
stats_load "$ST/link.mkv" "" exact
eq    "stats 8: symlink values = target"         "$STATS_KIND $(stats_totals 0)" \
    "tags $(stats_load "$ST/valid.mkv" "" exact; stats_totals 0)"

# 9 MP4: exact mode scans (as before); estimate mode uses ffprobe bit rates
ffmpeg -v error -y -i "$ST/raw.mkv" -map 0:v:0 -map 0:a -c copy "$ST/clip.mp4"
eq    "stats 9: mp4 exact -> packet scan"        "$(scans_during stats_load "$ST/clip.mp4" "" exact)" 1
eq    "stats 9: mp4 estimate -> no scan"         "$(scans_during stats_load "$ST/clip.mp4" "" estimate)" 0
stats_load "$ST/clip.mp4" "" estimate
eq    "stats 9: mp4 estimate source"             "$STATS_KIND" meta
check "stats 9: mp4 video estimate within 1%"    "awk -v a=\$(stats_field 0 bytes) -v b=\$(pk '$ST/clip.mp4' 0) 'BEGIN { exit !(a > b * 0.99 && a < b * 1.01) }'"

# 10 good mkvmerge statistics: same values as the exact scan / old stream_kbps
if (( HAVE_MKV == 1 )); then
    mkvmerge -q -o "$ST/mkvmerge.mkv" "$ST/raw.mkv"
    eq    "stats 10: mkvmerge file, no packet scan"  "$(scans_during stats_load "$ST/mkvmerge.mkv" "" estimate)" 0
    stats_load "$ST/mkvmerge.mkv" "" exact
    exact=$(_real_stream_packet_bytes "$ST/mkvmerge.mkv" | tr '\n' ' ')
    eq    "stats 10: bytes = packet scan"            "$(awk '$4 != "N/A" { printf "%s %s ", $1, $4 }' <<< "$STATS_LINES")" "$exact"
    # stream_kbps used to report the stream bit_rate (AC-3 header) or BPS / 1000
    eq    "stats 10: kb/s as before"                 "$(stats_field 0 kbps) $(stats_audio_kbps)" \
        "$(ffprobe -v error -select_streams 0 -show_entries stream_tags=BPS -of default=nw=1:nk=1 "$ST/mkvmerge.mkv" | awk '{ printf "%.0f", $1 / 1000 }') 640 192 "
else
    SKIPPED+=("stats 10: mkvmerge-written statistics (needs mkvtoolnix)")
fi

# 6 / 8 verify.sh Validate + update writes the tags; later reads skip the scan
if (( HAVE_MKV == 1 )); then
    SH="$T/shome"
    mkdir -p "$SH/compress/in" "$SH/compress/out" "$SH/store"
    cp -r "$WORK_DIR" "$SH/compress/work"
    cp "$ROOT/verify.sh" "$SH/compress/"
    cp "$ST/raw.mkv" "$SH/compress/in/Plain.mkv"
    cp "$ST/reenc.mkv" "$SH/compress/in/Stale.mkv"
    cp "$ST/raw.mkv" "$SH/store/Target.mkv"
    ln -s "$SH/store/Target.mkv" "$SH/compress/in/Linked.mkv"
    tsum=$(md5sum < "$SH/store/Target.mkv")

    printf '1\n1\n' | HOME="$SH" bash "$SH/compress/verify.sh" > "$T/sverify1.log" 2>&1
    check "stats 6: Verify scans files without tags" "grep -q 'Packet scanned: *3' '$T/sverify1.log'"
    check "stats 6: Verify shows the stale reason"   "grep -q 'Stored statistics rejected: .*stale' '$T/sverify1.log'"

    printf '1\n2\ny\n' | HOME="$SH" bash "$SH/compress/verify.sh" > "$T/sverify2.log" 2>&1
    check "stats 6: Validate + update wrote tags"    "grep -q 'Tags updated: *2' '$T/sverify2.log'"
    check "stats 6: metadata-first read matches"     "[[ \$(grep -c 'Metadata-first read *MATCH' '$T/sverify2.log') == 2 ]]"
    check "stats 6: both VERIFIED"                   "grep -q 'Verified: *2' '$T/sverify2.log'"
    for f in Plain Stale; do
        eq "stats 6: $f.mkv now read without a scan" "$(scans_during stats_load "$SH/compress/in/$f.mkv" "" exact)" 0
    done
    stats_load "$SH/compress/in/Stale.mkv" "" exact
    eq    "stats 6: Stale.mkv tags now correct"      "$(stats_field 0 bytes)" "$(pk "$SH/compress/in/Stale.mkv" 0)"

    printf '1\n1\n' | HOME="$SH" bash "$SH/compress/verify.sh" > "$T/sverify3.log" 2>&1
    check "stats 6: Verify afterwards: 1 scan (link)" "grep -q 'Packet scanned: *1' '$T/sverify3.log'"
    check "stats 6: values from stored tags"          "grep -q 'Values from *stored MKV statistics tags' '$T/sverify3.log'"
    check "stats 8: Validate never wrote the link"    "grep -q 'Symlink: statistics tags not updated' '$T/sverify2.log'"
    eq    "stats 8: link target unchanged"            "$(md5sum < "$SH/store/Target.mkv")" "$tsum"
else
    SKIPPED+=("stats 6: verify.sh Validate + update (needs mkvtoolnix)")
fi

stream_packet_bytes() { _real_stream_packet_bytes "$@"; }

echo
echo "== stream statistics: refresh after a fallback scan"
RF="$T/refresh"
mkdir -p "$RF/store" "$RF/bdir" "$RF/series"
stream_packet_bytes() { echo scan >> "$ST/scans"; _real_stream_packet_bytes "$@"; }

# mkvpropedit stand-ins: count calls, then run the real one / fail
cat > "$RF/mkvpe" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$(dirname "$0")/calls"
exec mkvpropedit "$@"
EOF
cat > "$RF/mkvpe_fail" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$(dirname "$0")/calls"
exit 1
EOF
# refreshes correctly, then rewrites the first audio track's statistics
# with a self-consistent but wrong byte count
cat > "$RF/mkvpe_wrong" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$(dirname "$0")/calls"
mkvpropedit "$@" || exit 1
f="$1"
get() { ffprobe -v error -select_streams a:0 -show_entries "stream_tags=$1" -of default=nw=1:nk=1 "$f"; }
b=$(( $(get NUMBER_OF_BYTES) + 4000 )); dt=$(get DURATION)
bps=$(awk -v b="$b" -v t="$dt" 'BEGIN { split(t, a, ":"); printf "%.0f", b * 8 / (a[1] * 3600 + a[2] * 60 + a[3]) }')
x="$(dirname "$0")/wrong.xml"
printf '<?xml version="1.0"?><Tags><Tag><Targets><TargetTypeValue>50</TargetTypeValue></Targets>%s%s%s</Tag></Tags>\n' \
    "<Simple><Name>BPS</Name><String>$bps</String></Simple>" \
    "<Simple><Name>DURATION</Name><String>$dt</String></Simple>" \
    "<Simple><Name>NUMBER_OF_BYTES</Name><String>$b</String></Simple>" > "$x"
mkvpropedit -q "$f" --tags "track:a1:$x"
EOF
chmod +x "$RF"/mkvpe*

counts() { echo "$(grep -c . "$ST/scans" 2>/dev/null || true)/$(grep -c . "$RF/calls" 2>/dev/null || true)"; }
# run_load FILE [MODE] [MKVPROPEDIT]  ->  stats_load ... refresh; progress in $RF/out
run_load() {
    : > "$ST/scans"; : > "$RF/calls"
    STATS_MKVPROPEDIT="${3:-$RF/mkvpe}" STATS_PROGRESS=1 \
        stats_load "$1" "" "${2:-exact}" refresh > "$RF/out" 2>&1
}
said() { grep -qF -- "$1" "$RF/out"; }
streams_md5() { ffmpeg -v error -i "$1" -map 0 -c copy -f streamhash -hash md5 - 2>/dev/null; }

# R1 valid statistics: no scan, no mkvpropedit, file untouched
cp "$ST/valid.mkv" "$RF/r1.mkv"; m=$(md5sum < "$RF/r1.mkv")
run_load "$RF/r1.mkv"
eq    "refresh 1: valid -> 0 scans / 0 mkvpropedit"  "$(counts)" "0/0"
eq    "refresh 1: tags used, nothing attempted"       "$STATS_KIND/$STATS_REFRESH" "tags/"
eq    "refresh 1: file untouched"                     "$(md5sum < "$RF/r1.mkv")" "$m"

if (( HAVE_MKV == 1 )); then
    # R2 missing statistics: one scan, refreshed, re-read matches; next run reads tags
    remux "$ST/raw.mkv" "$RF/r2.mkv" -metadata title=Movie -metadata:s:2 title=Main -metadata:s:2 language=eng
    before_streams=$(streams_md5 "$RF/r2.mkv")
    before_meta=$(ffprobe -v error -show_entries stream=index,codec_type,codec_name:stream_tags=title,language:format_tags=title -show_chapters -of compact "$RF/r2.mkv")
    run_load "$RF/r2.mkv"
    scan_totals=$(stats_totals 0)
    eq    "refresh 2: missing -> 1 scan / 1 mkvpropedit"  "$(counts)" "1/1"
    eq    "refresh 2: this run uses the scan"             "$STATS_KIND/$STATS_REFRESH" "packets/refreshed"
    check "refresh 2: progress lines"                     "said 'Packet scan complete.' && said 'Refreshing MKV statistics...' && said 'MKV statistics updated.' && said 'Metadata-first re-read: MATCH'"
    eq    "refresh 2: audio/video data unchanged"         "$(streams_md5 "$RF/r2.mkv")" "$before_streams"
    eq    "refresh 2: titles/languages/chapters unchanged" \
        "$(ffprobe -v error -show_entries stream=index,codec_type,codec_name:stream_tags=title,language:format_tags=title -show_chapters -of compact "$RF/r2.mkv")" "$before_meta"
    run_load "$RF/r2.mkv"
    eq    "refresh 2: second run 0 scans / 0 mkvpropedit" "$(counts)" "0/0"
    eq    "refresh 2: second run from tags, same values"  "$STATS_KIND $(stats_totals 0)" "tags $scan_totals"

    # R3 stale statistics: rejected, one scan, refreshed; next run reads tags
    cp "$ST/reenc.mkv" "$RF/r3.mkv"
    run_load "$RF/r3.mkv"
    eq    "refresh 3: stale -> 1 scan / 1 mkvpropedit"    "$(counts)" "1/1"
    check "refresh 3: rejected as stale, refreshed"       "[[ '$STATS_REJECTED' == *stale* && '$STATS_REFRESH' == refreshed ]]"
    eq    "refresh 3: this run uses the scan"             "$(stats_field 0 bytes)" "$(pk "$RF/r3.mkv" 0)"
    run_load "$RF/r3.mkv"
    eq    "refresh 3: second run 0 scans, tags"           "$(counts) $STATS_KIND" "0/0 tags"
    eq    "refresh 3: tags now = real stream size"        "$(stats_field 0 bytes)" "$(pk "$RF/r3.mkv" 0)"
else
    SKIPPED+=("refresh 2/3/10/11: real MKV statistics refresh (needs mkvtoolnix)")
fi

# R4 mkvpropedit missing: scan used, refresh skipped, file untouched
cp "$ST/raw.mkv" "$RF/r4.mkv"; m=$(md5sum < "$RF/r4.mkv")
run_load "$RF/r4.mkv" exact "no-such-mkvpropedit-$$"
eq    "refresh 4: no mkvpropedit -> scan ok"          "$STATS_KIND $(stats_field 0 bytes)" "packets $(pk "$RF/r4.mkv" 0)"
eq    "refresh 4: skipped cleanly"                    "$STATS_REFRESH" "skipped: mkvpropedit not found"
check "refresh 4: message"                            "said 'Packet scan complete.' && said 'MKV statistics not refreshed: mkvpropedit not found'"
eq    "refresh 4: file untouched"                     "$(md5sum < "$RF/r4.mkv")" "$m"

# R5 read-only MKV: scan ok, refresh skipped
if [[ $(id -u) != 0 ]]; then
    cp "$ST/raw.mkv" "$RF/r5.mkv"; chmod 444 "$RF/r5.mkv"; m=$(md5sum < "$RF/r5.mkv")
    run_load "$RF/r5.mkv"
    eq    "refresh 5: read-only -> skipped, 0 calls"  "$STATS_REFRESH $(counts)" "skipped: source is not writable 1/0"
    eq    "refresh 5: file untouched"                 "$(md5sum < "$RF/r5.mkv")" "$m"
    chmod 644 "$RF/r5.mkv"
else
    SKIPPED+=("refresh 5: read-only file (running as root)")
fi

# R6 symlink: read through, never refreshed, target unchanged
cp "$ST/raw.mkv" "$RF/store/target.mkv"; m=$(md5sum < "$RF/store/target.mkv")
ln -s "$RF/store/target.mkv" "$RF/link.mkv"
run_load "$RF/link.mkv"
eq    "refresh 6: symlink -> values of the target"    "$STATS_KIND $(stats_field 0 bytes)" "packets $(pk "$RF/store/target.mkv" 0)"
eq    "refresh 6: never refreshed through the link"   "$STATS_REFRESH $(counts)" "skipped: source is a symlink 1/0"
check "refresh 6: message"                            "said 'MKV statistics not refreshed: source is a symlink'"
eq    "refresh 6: target unchanged"                   "$(md5sum < "$RF/store/target.mkv")" "$m"
check "refresh 6: link still a link"                  "[[ -L '$RF/link.mkv' ]]"

# R7 broken symlink: still skipped by discovery, nothing written
ln -s missing.mkv "$RF/bdir/Broken.mkv"
eq    "refresh 7: broken link not listed"             "$(video_files_in_dir "$RF/bdir" 2>/dev/null)" ""
run_load "$RF/bdir/Broken.mkv"
eq    "refresh 7: no refresh attempt"                 "$STATS_REFRESH/$(grep -c . "$RF/calls" || true)" "/0"
check "refresh 7: nothing created at the target"      "[[ -L '$RF/bdir/Broken.mkv' && ! -e '$RF/bdir/missing.mkv' ]]"

# R8 non-MKV: never refreshed
cp "$ST/clip.mp4" "$RF/r8.mp4"; m=$(md5sum < "$RF/r8.mp4")
run_load "$RF/r8.mp4"
eq    "refresh 8: mp4 -> scan, no refresh attempt"    "$(counts) $STATS_KIND/$STATS_REFRESH" "1/0 packets/"
eq    "refresh 8: mp4 untouched"                      "$(md5sum < "$RF/r8.mp4")" "$m"

# R9 mkvpropedit fails: warning, scan values used
cp "$ST/raw.mkv" "$RF/r9.mkv"
run_load "$RF/r9.mkv" exact "$RF/mkvpe_fail"
eq    "refresh 9: failure reported"                   "$STATS_REFRESH $(counts)" "failed: mkvpropedit failed 1/1"
check "refresh 9: warning shown"                      "said 'WARNING: MKV statistics refresh failed'"
eq    "refresh 9: scan values used"                   "$STATS_KIND $(stats_field 0 bytes)" "packets $(pk "$RF/r9.mkv" 0)"

if (( HAVE_MKV == 1 )); then
    # R10 refresh ok but the re-read disagrees: reported, scan kept, no 2nd scan
    cp "$ST/raw.mkv" "$RF/r10.mkv"
    run_load "$RF/r10.mkv" exact "$RF/mkvpe_wrong"
    check "refresh 10: verification failure reported"   "[[ '$STATS_REFRESH' == verify-failed:* ]] && said 'Metadata-first re-read: DIFFERENT'"
    eq    "refresh 10: one scan only"                   "$(counts)" "1/1"
    eq    "refresh 10: scan values used"                "$STATS_KIND $(stats_field 2 bytes)" "packets $(pk "$RF/r10.mkv" 2)"

    # R11 / R12 series with mixed metadata: only the bad files scan / refresh
    cp "$ST/valid.mkv" "$RF/series/E01.mkv"
    cp "$ST/raw.mkv"   "$RF/series/E02.mkv"
    cp "$ST/reenc.mkv" "$RF/series/E03.mkv"
    m1=$(md5sum < "$RF/series/E01.mkv")
    : > "$ST/scans"; : > "$RF/calls"
    for f in "$RF"/series/E0*.mkv; do
        STATS_MKVPROPEDIT="$RF/mkvpe" stats_load "$f" "" estimate refresh > /dev/null
        echo "$(basename "$f") $STATS_KIND $STATS_REFRESH"
    done > "$RF/series.out"
    eq    "refresh 11: 2 scans / 2 refreshes for 3 files" "$(counts)" "2/2"
    eq    "refresh 11: refreshed only E02, E03"           "$(sort "$RF/calls" | xargs -n1 basename | tr '\n' ' ')" "E02.mkv E03.mkv "
    eq    "refresh 11: per-file sources"                  "$(tr '\n' ';' < "$RF/series.out")" \
        "E01.mkv tags ;E02.mkv packets refreshed;E03.mkv packets refreshed;"
    eq    "refresh 11: valid episode untouched"           "$(md5sum < "$RF/series/E01.mkv")" "$m1"
    : > "$ST/scans"; : > "$RF/calls"
    for f in "$RF"/series/E0*.mkv; do
        STATS_MKVPROPEDIT="$RF/mkvpe" stats_load "$f" "" estimate refresh > /dev/null
    done
    eq    "refresh 12: second series run 0 scans / 0 calls" "$(counts)" "0/0"
fi

stream_packet_bytes() { _real_stream_packet_bytes "$@"; }


echo
echo "== statistics refresh never touches a source an active job is reading"
AJ="$T/activejob"
mkdir -p "$AJ/movies" "$AJ/other" "$AJ/show"
stream_packet_bytes() { echo scan >> "$ST/scans"; _real_stream_packet_bytes "$@"; }
# stand-in mkvpropedit: only counts calls (the guard decides before it runs)
cat > "$AJ/mpe" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$(dirname "$0")/calls"
EOF
chmod +x "$AJ/mpe"
cp "$ST/raw.mkv" "$AJ/movies/Movie.mkv"
cp "$ST/raw.mkv" "$AJ/other/Movie.mkv"
cp "$ST/raw.mkv" "$AJ/show/E01.mkv"
ln -s "$AJ/movies/Movie.mkv" "$AJ/alias.mkv"
# fake_job SESSION STATUS INPUT TYPE  ->  job state as job_runtime.sh writes it
fake_job() {
    printf 'version=1\nsession=%s\ntype=%s\nstatus=%s\nitem=1\nitems=2\ninput=%s\n' \
        "$1" "${4:-movie}" "$2" "$3" > "$WORK_DIR/$1.state"
}
tmux() { [[ "$1" == has-session ]] && [[ " ${LIVE_SESSIONS:-} " == *" ${3#=} "* ]]; }
aj_load() {   # FILE  ->  stats_load ... refresh, counting scans / calls
    : > "$ST/scans"; : > "$AJ/calls"
    STATS_MKVPROPEDIT="$AJ/mpe" STATS_PROGRESS=1 stats_load "$1" "" exact refresh > "$AJ/out" 2>&1
    AJ_COUNTS="$(grep -c . "$ST/scans" || true)/$(grep -c . "$AJ/calls" || true)"
}

aj_load "$AJ/movies/Movie.mkv"
eq    "active 17: no job -> refresh allowed"         "$AJ_COUNTS" "1/1"

LIVE_SESSIONS="ajm1"; fake_job ajm1 running "$AJ/movies/Movie.mkv" movie
aj_load "$AJ/movies/Movie.mkv"
eq    "active 16: movie job -> refresh skipped"      "$STATS_REFRESH" "skipped: source is in use by an active compression job (ajm1)"
eq    "active 18: one scan, no mkvpropedit"          "$AJ_COUNTS" "1/0"
check "active: message"                               "grep -q 'MKV statistics not refreshed: source is in use by an active compression job' '$AJ/out'"
eq    "active: this run uses the scan"               "$STATS_KIND $(stats_field 0 bytes)" "packets $(pk "$AJ/movies/Movie.mkv" 0)"

aj_load "$AJ/other/Movie.mkv"
eq    "active: same name, other dir -> allowed"      "$AJ_COUNTS $STATS_REFRESH" "1/1 verify-failed: re-read MISSING"

ln -sf "$AJ/movies/Movie.mkv" "$AJ/joblink.mkv"
fake_job ajm1 running "$AJ/joblink.mkv" movie
aj_load "$AJ/movies/Movie.mkv"
eq    "active: job reads it via a symlink -> skipped" "$AJ_COUNTS" "1/0"
aj_load "$AJ/alias.mkv"
eq    "active: symlink alias -> never modified"       "$AJ_COUNTS $STATS_REFRESH" "1/0 skipped: source is a symlink"

LIVE_SESSIONS="ajm1 ajs1"; fake_job ajs1 running "$AJ/show/E01.mkv" series
aj_load "$AJ/show/E01.mkv"
eq    "active: series episode -> skipped"             "$STATS_REFRESH $AJ_COUNTS" "skipped: source is in use by an active compression job (ajs1) 1/0"

fake_job ajm1 finished "$AJ/movies/Movie.mkv" movie
aj_load "$AJ/movies/Movie.mkv"
eq    "active: job finished -> refresh allowed"       "$AJ_COUNTS" "1/1"

fake_job ajm1 running "$AJ/movies/Movie.mkv" movie; LIVE_SESSIONS="ajs1"
aj_load "$AJ/movies/Movie.mkv"
eq    "active: stale 'running' (session gone) -> allowed" "$AJ_COUNTS" "1/1"

fake_job ajm1 starting "" movie; LIVE_SESSIONS="ajm1 ajs1"
aj_load "$AJ/movies/Movie.mkv"
eq    "active: job not started yet -> allowed"        "$AJ_COUNTS" "1/1"

exec 9< "$AJ/movies/Movie.mkv"
aj_load "$AJ/movies/Movie.mkv"
exec 9<&-
eq    "active: file open in a process -> skipped"     "$STATS_REFRESH $AJ_COUNTS" "skipped: source is open in another process 1/0"

if [[ $(id -u) != 0 ]]; then
    fake_job ajx1 running "$AJ/other/Movie.mkv" movie; chmod 000 "$WORK_DIR/ajx1.state"
    aj_load "$AJ/movies/Movie.mkv"
    eq    "active: unreadable job state -> skipped (safe)" "$STATS_REFRESH $AJ_COUNTS" "skipped: cannot read job state ajx1.state 1/0"
    chmod 644 "$WORK_DIR/ajx1.state"
fi
rm -f "$WORK_DIR"/aj*.state
unset -f tmux
stream_packet_bytes() { _real_stream_packet_bytes "$@"; }

# ------------------------------------------------------------
echo
echo "== movie / series menus copy all audio; only the audio menu converts"
AC="$T/acopy"
MH="$AC/home"
mkdir -p "$MH/compress/in/Show" "$MH/compress/out" "$AC/stub"
cp -r "$SRC_WORK" "$MH/compress/work"
cp "$ROOT/audio_compress_menu.sh" "$MH/compress/"
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$AC/stub/tmux"
chmod +x "$AC/stub/tmux"
menu() {   # SCRIPT INPUT LOG
    printf "$2" | HOME="$MH" PATH="$AC/stub:$PATH" COMPRESS_CONF="${MENU_CONF:-$T/compress.conf}" \
        bash "$1" > "$3" 2>&1
}
newest_job() { ls -t "$MH/compress/work"/*.sh 2>/dev/null | head -1; }
no_audio_encoding() {   # JOB  ->  0 when the job converts no audio
    grep -q -- '-c:a copy' "$1" && grep -q 'atrans= ahash=1' "$1" &&
        ! grep -qE -- '-c:a:[0-9]|-b:a|[ :](aac|eac3|ac3|libopus|dca|truehd)( |$)|-ac[ :]|-ar ' "$1"
}

# E-AC-3 5.1 "Atmos" (object audio named in the title: ffmpeg cannot
# write real Atmos/JOC), TrueHD 5.1, DTS 5.1, AAC commentary
# (lossless video: every CRF estimate is far below the source, so the
# source-quality guard does not ask here; it is tested separately)
ffmpeg -v error -y -f lavfi -i "testsrc2=s=640x360:r=24:d=2" -f lavfi -i "sine=f=440:r=48000:d=2" \
    -map 0:v -map 1:a -map 1:a -map 1:a -map 1:a -c:v libx264 -preset ultrafast -qp 0 \
    -c:a:0 eac3 -ac:a:0 6 -b:a:0 640k -c:a:1 truehd -ac:a:1 6 -strict -2 \
    -c:a:2 dca -ac:a:2 6 -b:a:2 768k -c:a:3 aac -ac:a:3 2 -b:a:3 96k \
    -metadata:s:a:0 language=eng -metadata:s:a:0 "title=English DDP 5.1 Atmos" -disposition:a:0 default \
    -metadata:s:a:1 language=eng -metadata:s:a:1 "title=TrueHD 5.1" \
    -metadata:s:a:2 language=ger -metadata:s:a:2 "title=DTS 5.1" \
    -metadata:s:a:3 language=eng -metadata:s:a:3 "title=Director Commentary" -disposition:a:3 comment \
    "$MH/compress/in/Multi.mkv" 2>"$AC/mk.err"

if [[ -s "$MH/compress/in/Multi.mkv" ]]; then
    src_audio=$(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,sample_rate -of csv=p=0 "$MH/compress/in/Multi.mkv" | tr '\n' ' ')
    check "acopy: source has E-AC-3, TrueHD, DTS, AAC" "[[ '$src_audio' == 'eac3,48000,6 truehd,48000,6 dts,48000,6 aac,48000,2 ' ]]"

    n=0
    for t in Quality High Base Custom; do
        ((n += 1))
        rm -rf "$MH/compress/work"/c[0-9]*.sh "$MH/compress/work"/c[0-9]*_passes
        in="1\n$n\nn\n"; [[ $t == Custom ]] && in="1\n4\n24\nn\n"
        menu "$MH/compress/work/movie_compress.sh" "$in" "$AC/movie_$t.log"
        job=$(ls "$MH/compress/work"/c[0-9]*.sh 2>/dev/null | head -1)
        check "acopy $n: movie $t job written"          "[[ -n '$job' ]]"
        check "acopy $n: movie $t copies all audio"     "no_audio_encoding '$job'"
        check "acopy $n: movie $t summary says copied"  "grep -q 'Audio size: .*copied unchanged (4 track(s), actual source audio)' '$AC/movie_$t.log'"
        cp "$job" "$AC/movie_${t}_job.sh"
        if [[ -d "${job%.sh}_passes" ]]; then echo 1 > "$AC/movie_${t}_passdir"; else : > "$AC/movie_${t}_passdir"; fi
    done

    # 19 / 20 job shape per tier: Quality two-pass, the others single-pass CRF
    qj="$AC/movie_Quality_job.sh"
    check "20 movie Quality: still two-pass bitrate" "[[ \$(grep -c libx265 '$qj') == 2 ]] && grep -q -- '-b:v:0 [0-9]*k' '$qj' && grep -q 'pass=1:stats=' '$qj' && grep -q 'pass=2:stats=' '$qj' && ! grep -q -- '-crf' '$qj'"
    check "20 movie Quality: pass log dir created"   "[[ -s '$AC/movie_Quality_passdir' ]]"
    check "20 movie Quality: GiB/hour target summary" "grep -q 'Video target:      rate-based' '$AC/movie_Quality.log' && grep -q 'quality-first \[two-pass' '$AC/movie_Quality.log'"
    for tc in High:19 Base:25 Custom:24; do
        tt=${tc%%:*}; c=${tc#*:}; j="$AC/movie_${tt}_job.sh"
        check "19 movie $tt: -crf $c, no -b:v / passes" "grep -q -- '-crf:v:0 $c ' '$j' && ! grep -qE -- '-b:v|pass=[12]|stats=' '$j' && [[ \$(grep -c libx265 '$j') == 1 ]]"
        check "movie $tt: no pass log dir"               "[[ ! -s '$AC/movie_${tt}_passdir' ]]"
    done
    check "1 movie High: analysis starts at CRF 19"  "grep -q 'sampling CRF 19 ' '$AC/movie_High.log' && ! grep -qE 'sampling CRF (1[0-8]|2[0-9]) ' '$AC/movie_High.log'"
    check "movie High: policy + analysis shown"      "grep -q 'CRF range: 19-23' '$AC/movie_High.log' && grep -q '^  CRF 19 -> estimated ' '$AC/movie_High.log' && grep -A1 '^Selected:' '$AC/movie_High.log' | grep -q 'CRF 19'"
    check "7 movie Base: CRF 25 fits, no 26+ samples" "grep -q 'sampling CRF 25 ' '$AC/movie_Base.log' && ! grep -qE 'sampling CRF (2[6-9]) ' '$AC/movie_Base.log'"
    check "18 movie Custom: exactly CRF 24"          "grep -q 'sampling CRF 24 ' '$AC/movie_Custom.log' && [[ \$(grep -c 'sampling CRF' '$AC/movie_Custom.log') == 1 ]]"
    check "18 movie Custom: menu entry"              "grep -q '4) Custom CRF  exactly the CRF you enter' '$AC/movie_Custom.log' && grep -q 'CRF: 24 (used exactly; no size ceiling)' '$AC/movie_Custom.log'"
    # 14 total preview = estimated video + copied audio + other streams
    hest=$(grep -o 'est_vbytes=[0-9]*' "$AC/movie_High_job.sh" | cut -d= -f2)
    stats_load "$MH/compress/in/Multi.mkv" "" exact
    read -r srcvb srcab _ _ <<< "$(stats_totals 0)"
    other=$(awk -v t="$(file_bytes "$MH/compress/in/Multi.mkv")" -v v="$srcvb" -v a="$srcab" 'BEGIN { x = t - v - a; if (x < 0) x = 0; printf "%.0f", x }')
    check "14 movie: copied audio in the preview"    "grep -qF 'copied source audio:  ~$(size_text "$srcab")' '$AC/movie_High.log'"
    check "14 movie: total = video + audio + other"  "grep -qF 'estimated total:      ~$(size_text "$(crf_total_bytes "$hest" "$srcab" "$other")")' '$AC/movie_High.log'"
    check "acopy: movie header: audio copied"          "grep -q '^  all tracks copied unchanged' '$AC/movie_Quality.log' && grep -q 'use audio_compress_menu.sh for optional audio compression' '$AC/movie_Quality.log'"
    check "acopy: movie lists tracks as copied"        "grep -q 'Audio 1: E-AC-3 5.1(side) + Dolby Atmos (per track title).*copied unchanged' '$AC/movie_Quality.log' && grep -q 'Audio 4: AAC stereo.*\"Director Commentary\" - copied unchanged' '$AC/movie_Quality.log'"
    check "acopy: Atmos PRESERVED, no LOST warning"    "grep -q 'Object audio: Dolby Atmos PRESERVED by stream copy' '$AC/movie_Quality.log' && ! grep -qi 'LOST' '$AC/movie_Quality.log'"
    check "acopy: no Base audio question"              "! grep -q 'Base audio target' '$AC/movie_Base.log'"
    check "acopy: tier menu lists CRF tiers"           "grep -q '2) High        CRF 19-23, video ceiling 7 GiB' '$AC/movie_Base.log' && grep -q '3) Base        CRF 25-29, video ceiling 2 GiB' '$AC/movie_Base.log'"
    # 12 expected size uses the actual source audio bytes
    stats_load "$MH/compress/in/Multi.mkv" "" exact
    read -r _ srcab _ _ <<< "$(stats_totals 0)"
    check "acopy 12: movie audio size = source bytes"  "grep -q \"Audio size: *~$(bytes_to_gib "$srcab") GiB copied\" '$AC/movie_Quality.log'"

    # run the Quality job: every track identical in the output
    # (the menu created this; the per-tier loop above removed it again)
    mkdir -p "$MH/compress/work/c1_passes"
    bash "$AC/movie_Quality_job.sh" < /dev/null > "$AC/movie_run.log" 2>&1
    mout="$MH/compress/out/Multi HEVC Quality.mkv"
    check "acopy 7: movie output written"             "[[ -s '$mout' ]]"
    eq    "acopy 7: all 4 audio tracks, same codecs"  "$(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,sample_rate -of csv=p=0 "$mout" | tr '\n' ' ')" "$src_audio"
    eq    "acopy 9-11: payload identical (all tracks)" "$(_audio_payload_md5 "$mout" | tr '\n' ' ')" "$(_audio_payload_md5 "$MH/compress/in/Multi.mkv" | tr '\n' ' ')"
    check "acopy 9: E-AC-3 copied, Atmos PRESERVED"   "grep -q 'Audio track 1: *COPIED (E-AC-3 5.1(side), 48000 Hz, payload MD5 MATCH)' '$AC/movie_run.log' && grep -q 'Audio 1 object: *Dolby Atmos PRESERVED (stream copy)' '$AC/movie_run.log'"
    check "acopy 10: TrueHD copied"                   "grep -q 'Audio track 2: *COPIED (TrueHD 5.1(side), 48000 Hz, payload MD5 MATCH)' '$AC/movie_run.log'"
    check "acopy 11: DTS copied"                      "grep -q 'Audio track 3: *COPIED (DTS 5.1(side), 48000 Hz, payload MD5 MATCH)' '$AC/movie_run.log'"
    check "acopy 8: commentary kept"                  "[[ \$(ffprobe -v error -select_streams a:3 -show_entries stream_disposition=comment -of default=nw=1:nk=1 '$mout') == 1 ]] && grep -q 'Audio track 4: *COPIED (AAC stereo' '$AC/movie_run.log'"
    check "acopy: titles / languages kept"            "grep -q 'Languages: *MATCH' '$AC/movie_run.log' && grep -q 'Track titles: *MATCH' '$AC/movie_run.log'"
    check "acopy: job succeeded"                      "grep -q 'All encodes finished: 1 ok, 0 failed' '$AC/movie_run.log'"

    # 23 the High (CRF) job: all tracks identical, estimate reported
    bash "$AC/movie_High_job.sh" < /dev/null > "$AC/movie_high_run.log" 2>&1
    hout="$MH/compress/out/Multi HEVC High.mkv"
    check "23 movie High job succeeded"              "grep -q 'All encodes finished: 1 ok, 0 failed' '$AC/movie_high_run.log'"
    eq    "23 movie High: payload identical (all tracks)" "$(_audio_payload_md5 "$hout" | tr '\n' ' ')" "$(_audio_payload_md5 "$MH/compress/in/Multi.mkv" | tr '\n' ' ')"
    check "23 movie High: Atmos PRESERVED"           "grep -q 'Audio 1 object: *Dolby Atmos PRESERVED (stream copy)' '$AC/movie_high_run.log'"
    check "25 movie High: estimate vs actual"        "grep -q 'Selected CRF: *19' '$AC/movie_high_run.log' && grep -q 'Estimated video size: ' '$AC/movie_high_run.log' && grep -qE 'Estimate error: +[-+][0-9.]+%' '$AC/movie_high_run.log'"
    check "movie High: single pass in the pane"      "grep -q 'ENCODING (single pass, CRF 19)' '$AC/movie_high_run.log' && ! grep -qE 'PASS [12]/2' '$AC/movie_high_run.log'"
    rm -f "$hout"

    # verification catches a transcode that was not planned
    ffmpeg -v error -y -i "$mout" -map 0 -c copy -c:a:3 libopus -b:a:3 64k "$AC/tampered.mkv"
    ITEM_INPUT="$MH/compress/in/Multi.mkv"; ITEM_PART="$AC/tampered.mkv"; ITEM_TMP="$AC/vtmp"
    mkdir -p "$ITEM_TMP"; declare -A ITEM_EXP=([vidx]=0 [video]=copy [atrans]= [ahash]=1)
    item_verify_output > /dev/null 2>&1
    check "acopy: unexpected transcode FAILS verify"  "grep -q 'Audio track 4: *CHANGED although it was to be copied: codec aac -> opus' '$ITEM_TMP/report.txt' && grep -q 'RESULT: FAILED' '$ITEM_TMP/report.txt'"

    # series: Base / High / Custom
    cp "$MH/compress/in/Multi.mkv" "$MH/compress/in/Show/E01.mkv"
    cp "$MH/compress/in/Multi.mkv" "$MH/compress/in/Show/E02.mkv"
    mv "$MH/compress/in/Multi.mkv" "$AC/Multi.mkv"
    for sel in "1:Base:25" "2:High:19" "3:Custom:24"; do
        k="${sel%%:*}"; t="${sel#*:}"; c="${t#*:}"; t="${t%%:*}"
        rm -f "$MH/compress/work"/series[0-9]*.sh; rm -rf "$MH/compress/out/Show"*
        in="1\n$k\ny\n"; [[ $t == Custom ]] && in="1\n3\n$c\ny\n"
        menu "$MH/compress/work/series_compress.sh" "$in" "$AC/series_$t.log"
        job=$(ls "$MH/compress/work"/series[0-9]*.sh 2>/dev/null | head -1)
        check "acopy $((k + 4)): series $t job written"       "[[ -n '$job' ]]"
        check "acopy $((k + 4)): series $t copies all audio"  "no_audio_encoding '$job'"
        check "acopy: series $t table shows copied audio"     "grep -qE 'E0[12].mkv .* copy [0-9]+k' '$AC/series_$t.log'"
        check "17 series $t: one CRF ($c) for every episode"  "[[ \$(grep -o -- '-crf:v:0 [0-9.]*' '$job' | sort -u) == '-crf:v:0 $c' && \$(grep -c -- '-crf:v:0 $c ' '$job') == 2 ]]"
        check "19 series $t: no -b:v / passes"                "! grep -qE -- '-b:v|pass=[12]|stats=' '$job' && ! ls -d '$MH/compress/work'/series[0-9]*_passes >/dev/null 2>&1"
    done
    check "acopy: series header: audio copied"         "grep -q '^  audio: copied unchanged' '$AC/series_Base.log' && grep -q '^  all tracks copied unchanged' '$AC/series_Base.log'"
    check "acopy: series Custom label"                 "grep -q '3) Custom CRF  exactly the CRF you enter' '$AC/series_Custom.log'"
    check "series Base: batch sampled at 25 only"      "grep -q 'sampling CRF 25, episode 1/2 (E01.mkv)' '$AC/series_Base.log' && grep -q 'sampling CRF 25, episode 2/2 (E02.mkv)' '$AC/series_Base.log' && ! grep -q 'sampling CRF 26' '$AC/series_Base.log'"
    check "series: one CRF for every episode shown"    "grep -q 'CRF 25 for every episode' '$AC/series_Base.log' && grep -q 'one CRF for every episode of the batch' '$AC/series_Base.log'"
    check "acopy: series lists tracks, Atmos PRESERVED" "grep -q 'Audio 1: E-AC-3 5.1(side) + Dolby Atmos' '$AC/series_Custom.log' && grep -q 'Object audio: Dolby Atmos PRESERVED by stream copy' '$AC/series_Custom.log'"
    check "acopy: series no AAC rates / LOST warning"  "! grep -qiE 'kb/s AAC|LOST|Fixed audio total|GiB/hour' '$AC/series_Custom.log'"
    check "acopy: series season totals"                "grep -q 'Copied source audio size: *~' '$AC/series_Custom.log'"

    # 15 the audio menu still converts audio (High: E-AC-3 640k -> 256k)
    rm -f "$mout"
    mv "$AC/Multi.mkv" "$MH/compress/out/Multi.mkv"
    MENU_CONF=$(conf_with amenu AUDIO_HIGH_TRIGGER_KBPS=100 AUDIO_HIGH_KBPS_5TO6=256)
    rm -f "$MH/compress/work"/[a-z][0-9]*.sh "$MH/compress/work"/[a-z]*[0-9].sh
    menu "$MH/compress/audio_compress_menu.sh" "1\n1\n2\nn\ny\ny\n" "$AC/amenu.log"
    MENU_CONF=""
    ajob=$(newest_job)
    check "acopy 15: audio menu warns Atmos LOST"      "grep -q 'WARNING: Dolby Atmos object metadata will be LOST' '$AC/amenu.log'"
    check "acopy 15: audio menu job converts track 1"  "[[ -n '$ajob' ]] && grep -q -- '-c:a:0 eac3 -b:a:0 256k' '$ajob'"
    bash "$ajob" < /dev/null > "$AC/arun.log" 2>&1
    aout=$(ls -t "$MH/compress/out"/*.mkv | grep -v '/Multi.mkv$' | head -1)
    check "acopy 15: converted output written"         "[[ -s '$aout' ]]"
    eq    "acopy 15: track 1 re-encoded at 256k"      "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,bit_rate -of csv=p=0 "$aout")" "eac3,256000"
    eq    "acopy 15: other tracks copied"             "$(_audio_payload_md5 "$aout" | tail -n +2 | tr '\n' ' ')" "$(_audio_payload_md5 "$MH/compress/out/Multi.mkv" | tail -n +2 | tr '\n' ' ')"
    check "acopy 15: audio job succeeded"             "grep -q 'All encodes finished: 1 ok, 0 failed' '$AC/arun.log'"
else
    SKIPPED+=("audio copy end-to-end (ffmpeg cannot write the E-AC-3/TrueHD/DTS fixture: $(head -1 "$AC/mk.err"))")
fi

# object-audio detection (real ffprobe profile strings)
eq "object: E-AC-3 Atmos profile"   "$(audio_object_kind eac3 'Dolby Digital Plus + Dolby Atmos' -)" "Dolby Atmos"
eq "object: TrueHD Atmos profile"   "$(audio_object_kind truehd 'Dolby TrueHD + Dolby Atmos' -)" "Dolby Atmos"
eq "object: DTS:X profile"          "$(audio_object_kind dts 'DTS-HD MA + DTS:X' -)" "DTS:X"
eq "object: plain DTS-HD MA"        "$(audio_object_kind dts 'DTS-HD MA' 'DTS-HD MA 7.1')" ""
eq "object: label DTS-HD MA"        "$(audio_track_label dts 'DTS-HD MA + DTS:X' 7.1 8)" "DTS-HD MA 7.1"

echo
echo "== HDR10 (audio copied)"
run_item hdr10 "$T/in/HDR10.mkv" ""
nondv_job_checks hdr10
common_checks hdr10
check "hdr10: x265 HDR10 params"               "grep -q 'transfer=smpte2084' '$WORK_DIR/hdr10.sh' && grep -q 'master-display=' '$WORK_DIR/hdr10.sh' && grep -q 'max-cll=1000' '$WORK_DIR/hdr10.sh'"
check "hdr10: copied audio keeps its stats"    "! grep -q -- '-metadata:s:a:[0-9] BPS=' '$WORK_DIR/hdr10.sh'"
check "hdr10: HDR type HDR10"                  "report_has hdr10 'HDR type: +HDR10\$'"
check "hdr10: colour MATCH"                    "report_has hdr10 'Colour signalling: +MATCH \\(bt2020/smpte2084/bt2020nc/tv\\)'"
check "hdr10: chroma location MATCH"           "report_has hdr10 'Chroma location: +MATCH \\(topleft\\)'"
check "hdr10: mastering VERIFIED"              "report_has hdr10 'HDR10 mastering: +VERIFIED'"
check "hdr10: MaxCLL VERIFIED"                 "report_has hdr10 'MaxCLL/MaxFALL: +VERIFIED'"
eq    "hdr10: audio 1 title unchanged"         "$(out_title hdr10 0)" "$A0_TITLE"
eq    "hdr10: audio 2 title unchanged"         "$(out_title hdr10 1)" "$A1_TITLE"
eq    "hdr10: audio codecs unchanged"          "$(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,sample_rate -of csv=p=0 "$T/out/hdr10.mkv" | tr '\n' ' ')" \
    "$(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,sample_rate -of csv=p=0 "$T/in/HDR10.mkv" | tr '\n' ' ')"
check "hdr10: track titles MATCH"              "report_has hdr10 'Track titles: +MATCH'"

echo
echo "== HDR10, x265 CRF (audio copied)"
run_item hdr10crf "$T/in/HDR10.mkv" "" 0 crf:21 "$(whole_title_estimate "$T/in/HDR10.mkv" 21)"
crf_job_checks hdr10crf 21
common_checks hdr10crf
check "hdr10crf: x265 HDR10 params"            "grep -q 'transfer=smpte2084' '$WORK_DIR/hdr10crf.sh' && grep -q 'master-display=' '$WORK_DIR/hdr10crf.sh' && grep -q 'max-cll=1000' '$WORK_DIR/hdr10crf.sh'"
check "hdr10crf: HDR type HDR10"               "report_has hdr10crf 'HDR type: +HDR10\$'"
check "hdr10crf: colour MATCH"                 "report_has hdr10crf 'Colour signalling: +MATCH \\(bt2020/smpte2084/bt2020nc/tv\\)'"
check "hdr10crf: mastering VERIFIED"           "report_has hdr10crf 'HDR10 mastering: +VERIFIED'"
check "hdr10crf: MaxCLL VERIFIED"              "report_has hdr10crf 'MaxCLL/MaxFALL: +VERIFIED'"

echo
echo "== source video kept (stream copy, source-quality guard)"
run_item hdr10copy "$T/in/HDR10.mkv" "" 0 copy
common_checks hdr10copy
check "hdr10copy: no libx265, no passes"       "! grep -qE 'libx265|pass=|-b:v|-crf' '$WORK_DIR/hdr10copy.sh'"
check "hdr10copy: video copy planned"          "grep -q 'item_expect .*video=copy mode=copy' '$WORK_DIR/hdr10copy.sh'"
check "hdr10copy: video stream COPIED"         "report_has hdr10copy 'Video stream: +COPIED \\(hevc 1280x720 yuv420p10le, as the source\\)'"
check "hdr10copy: HDR10 still VERIFIED"        "report_has hdr10copy 'HDR10 mastering: +VERIFIED' && report_has hdr10copy 'Colour signalling: +MATCH'"
eq    "hdr10copy: video payload identical"     "$(ffmpeg -v error -i "$T/out/hdr10copy.mkv" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | cut -d, -f3)" \
    "$(ffmpeg -v error -i "$T/in/HDR10.mkv" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | cut -d, -f3)"
check "hdr10copy: report says copied"          "grep -q 'Video encode mode: *source video copied' '$T/hdr10copy.log'"
emit_encode_item 1 "$T/in/HDR10.mkv" "$T/out/x.mkv" Test copy "$DOWNSCALE_1080P_FILTER" "" 0 > "$T/copyscale.sh"
check "copy + scaling refused"                 "grep -q 'item_failed .*when.*is.*scaled' '$T/copyscale.sh' && ! grep -q 'item_run' '$T/copyscale.sh'"

hdr_tools_detect
if [[ -n "$HDR10PLUS_TOOL" ]]; then
    echo
    echo "== HDR10+ (synthetic metadata), x265 CRF"
    awk 'BEGIN {
        printf "{\"JSONInfo\":{\"HDR10plusProfile\":\"A\",\"Version\":\"1.0\"},\"SceneInfo\":["
        for (i = 0; i < 48; i++)
            printf "%s{\"LuminanceParameters\":{\"AverageRGB\":1000,\"LuminanceDistributions\":{\"DistributionIndex\":[1,5,10,25,50,75,90,95,99],\"DistributionValues\":[10,50,100,500,1000,5000,10000,20000,40000]},\"MaxScl\":[40000,40000,40000]},\"NumberOfWindows\":1,\"TargetedSystemDisplayMaximumLuminance\":0,\"SceneFrameIndex\":%d,\"SceneId\":0,\"SequenceFrameIndex\":%d}", (i ? "," : ""), i, i
        printf "],\"SceneInfoSummary\":{\"SceneFirstFrameIndex\":[0],\"SceneFrameNumbers\":[48]}}\n"
    }' > "$T/h10p.json"
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=1280x720:r=24000/1001:d=2,format=yuv420p10le" \
        -c:v libx265 -preset ultrafast -x265-params "$HDR_X265:dhdr10-info=$T/h10p.json" "$T/h10p.mkv"
    mux_source "$T/h10p.mkv" "$T/in/HDR10P.mkv"
    probe_hdr "$T/in/HDR10P.mkv" 0
    check "h10p: source has HDR10+"            "[[ '$HDR_HDR10PLUS' == 1 ]]"

    DV_POLICY=none; DV_MODE=""; HDR10P_POLICY=preserve
    run_item h10pcrf "$T/in/HDR10P.mkv" "" 0 crf:22 "$(whole_title_estimate "$T/in/HDR10P.mkv" 22)"
    crf_job_checks h10pcrf 22
    common_checks h10pcrf
    check "h10pcrf: HDR10+ extracted + passed to x265" "grep -q 'item_step hdr10+ item_hdr10plus_extract' '$WORK_DIR/h10pcrf.sh' && grep -q 'dhdr10-info=\$ITEM_TMP/hdr10plus.json' '$WORK_DIR/h10pcrf.sh'"
    check "h10pcrf: HDR10+ VERIFIED"           "report_has h10pcrf 'HDR10\\+: +VERIFIED'"
    check "h10pcrf: HDR10 mastering VERIFIED"  "report_has h10pcrf 'HDR10 mastering: +VERIFIED'"

    HDR10P_POLICY=drop
    run_item h10pdrop "$T/in/HDR10P.mkv" "" 0 crf:22
    check "h10pdrop: HDR10+ DROPPED by choice" "report_has h10pdrop 'HDR10\\+: +DROPPED' && grep -q 'All encodes finished: 1 ok, 0 failed' '$T/h10pdrop.log'"

    HDR10P_POLICY=preserve
    run_item h10pcopy "$T/in/HDR10P.mkv" "" 0 copy
    check "h10pcopy: HDR10+ kept by stream copy" "report_has h10pcopy 'HDR10\\+: +VERIFIED' && report_has h10pcopy 'Video stream: +COPIED'"
    DV_POLICY=none; DV_MODE=""; HDR10P_POLICY=none
else
    SKIPPED+=("HDR10+ (needs hdr10plus_tool)")
fi

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
run_item mov "$T/in/MOVTEXT.mp4" ""
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

    run_item ed "$T/in/EDITIONS.mkv" ""
    check "ed: job reported success"           "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/ed.log'"
    check "ed: editions MATCH"                 "report_has ed 'Editions: +MATCH \\(2 editions \\(1 ordered\\), 4 chapters \\(1 nested, 1 hidden\\)'"
    check "ed: segment UID KEPT"               "report_has ed 'Segment UID: +KEPT'"
    check "ed: chapter XML identical"          "diff -q <(mkvextract '$T/in/EDITIONS.mkv' chapters - 2>/dev/null) <(mkvextract '$T/out/ed.mkv' chapters - 2>/dev/null)"
    check "ed: FFmpeg alone would flatten it"  "ffmpeg -v error -y -i '$T/in/EDITIONS.mkv' -map 0:v -c copy '$T/ff_only.mkv' && ! diff -q <(mkvextract '$T/in/EDITIONS.mkv' chapters - 2>/dev/null) <(mkvextract '$T/ff_only.mkv' chapters - 2>/dev/null) >/dev/null"

    # simple chapters have no end times: ffprobe derives the last end
    # from the file duration, which changes with re-encoding
    printf 'CHAPTER01=00:00:00.000\nCHAPTER01NAME=One\nCHAPTER02=00:00:01.000\nCHAPTER02NAME=Two\n' > "$T/simple.txt"
    mkvmerge -q -o "$T/in/OPENEND.mkv" --chapters "$T/simple.txt" --no-chapters "$T/in/SDR.mkv"
    run_item openend "$T/in/OPENEND.mkv" ""
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
        "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
    common_checks dv
    check "dv: RPU steps in job"               "grep -q 'item_step rpu item_dv_extract' '$WORK_DIR/dv.sh' && grep -q 'item_dv_inject' '$WORK_DIR/dv.sh'"
    check "dv: still two-pass"                 "[[ \$(grep -c 'libx265' '$WORK_DIR/dv.sh') == 2 ]]"
    check "dv: HDR type DV 8.1 + HDR10"        "report_has dv 'HDR type: +DV Profile 8.1 \\+ HDR10\$'"
    check "dv: RPU VERIFIED"                   "report_has dv 'Dolby Vision RPU: +VERIFIED'"
    check "dv: HDR10 fallback VERIFIED"        "report_has dv 'HDR10 fallback: +VERIFIED'"
    check "dv: mastering VERIFIED"             "report_has dv 'HDR10 mastering: +VERIFIED'"
    eq    "dv: audio copied, title kept (DV path)" "$(out_title dv 0)" "$A0_TITLE"
    check "dv: audio payload MATCH (DV path)"  "report_has dv 'Audio track 1: +COPIED .*payload MD5 MATCH'"

    ffmpeg -v error -i "$T/out/dv.mkv" -map 0:v:0 -c copy -f hevc - |
        "$DOVI_TOOL" extract-rpu - -o "$T/out.rpu" > /dev/null 2>&1
    "$DOVI_TOOL" info --summary -i "$T/out.rpu" > "$T/dv_summary.txt" 2>&1
    check "dv: dovi_tool summary profile 8"    "grep -q 'Profile: 8' '$T/dv_summary.txt'"
    check "dv: L5 rescaled 184 -> 138"         "grep -q 'L5 offsets: top=138, bottom=138' '$T/dv_summary.txt'"
    check "dv: 1080p output"                   "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 '$T/out/dv.mkv') == 1080 ]]"
    check "dv: temp files removed on success"  "! ls -d '$WORK_DIR'/logs/*/item-1.tmp >/dev/null 2>&1"

    echo
    echo "== Dolby Vision profile 8.1, x265 CRF, 1440p -> 1080p"
    DV_POLICY=preserve; DV_MODE=""; HDR10P_POLICY=none
    run_item dvcrf "$T/in/DV.mkv" "$DOWNSCALE_1080P_FILTER" 0 crf:23
    crf_job_checks dvcrf 23
    common_checks dvcrf
    check "dvcrf: RPU steps in job"            "grep -q 'item_step rpu item_dv_extract' '$WORK_DIR/dvcrf.sh' && grep -q 'item_dv_inject' '$WORK_DIR/dvcrf.sh'"
    check "dvcrf: raw HEVC, frames pinned"     "grep -q -- '-fps_mode:v:0 passthrough -an -sn -dn -f hevc' '$WORK_DIR/dvcrf.sh'"
    check "dvcrf: RPU VERIFIED"                "report_has dvcrf 'Dolby Vision RPU: +VERIFIED'"
    check "dvcrf: HDR10 fallback VERIFIED"     "report_has dvcrf 'HDR10 fallback: +VERIFIED'"
    check "dvcrf: 1080p output"                "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 '$T/out/dvcrf.mkv') == 1080 ]]"
    run_item dvcopy "$T/in/DV.mkv" "" 0 copy
    check "dvcopy: DV kept by stream copy"     "report_has dvcopy 'Dolby Vision: +COPIED \(video stream copy, profile 8\)' && grep -q 'All encodes finished: 1 ok, 0 failed' '$T/dvcopy.log'"
    DV_POLICY=none
else
    SKIPPED+=("Dolby Vision (needs dovi_tool >= 2.1 and mkvmerge)")
fi


# ------------------------------------------------------------
# run_menu HOME SCRIPT INPUT LOG [CONF]  ->  menu run in its own HOME
run_menu() {
    printf "$3" | HOME="$1" PATH="$AC/stub:$PATH" COMPRESS_CONF="${5:-$T/compress.conf}" \
        bash "$2" > "$4" 2>&1
}
# new_home NAME  ->  a HOME with compress/{in,out,work} (work = the code under test)
new_home() {
    local h="$T/homes/$1"
    mkdir -p "$h/compress/in" "$h/compress/out"
    cp -r "$SRC_WORK" "$h/compress/work"
    # no tests, and no job scripts / state / logs of real runs on this machine
    rm -rf "$h/compress/work/tests" "$h/compress/work/logs" "$h/compress/work/cache" \
        "$h/compress/work"/[a-z]*[0-9]_passes
    rm -f "$h/compress/work"/[a-z]*[0-9].sh "$h/compress/work"/*.state "$h/compress/work"/*.progress
    printf '%s' "$h"
}
# av_source VIDEO_ARGS... OUT  ->  2 s 640x360 video + E-AC-3 5.1 + AAC stereo
av_source() {
    local out="${*: -1}"
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=640x360:r=24:d=2" -f lavfi -i "sine=f=440:r=48000:d=2" \
        -map 0:v -map 1:a -map 1:a "${@:1:$#-1}" \
        -c:a:0 eac3 -ac:a:0 6 -b:a:0 640k -c:a:1 aac -ac:a:1 2 -b:a:1 128k \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=eng "$out"
}
first_job() { ls "$1/compress/work"/$2[0-9]*.sh 2>/dev/null | head -1; }

echo
echo "== CRF samples use the selected output resolution and HDR signalling"
eval "$(declare -f crf_sample_encode | sed '1s/crf_sample_encode/_real_crf_sample_encode/')"
crf_sample_encode() {   # records FILTER X265 CRF START LENGTH, keeps the last sample
    printf '%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$6" "$7" >> "$T/sample_calls"
    _real_crf_sample_encode "$@" && cp "$8" "$T/last_sample.hevc"
}
dims() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt -of csv=p=0 "$1" | head -1; }
ffmpeg -v error -y -f lavfi -i "testsrc2=s=3840x1920:r=24:d=1,format=yuv420p" -c:v libx264 -preset ultrafast -crf 16 "$T/uhd.mkv"
CRF_SAMPLE_CACHE=0

: > "$T/sample_calls"
whole_title_estimate "$T/uhd.mkv" 25 "$DOWNSCALE_1080P_FILTER" > /dev/null
eq    "15 downscaled: sample has the output scale filter" "$(cut -f1 "$T/sample_calls")" "$DOWNSCALE_1080P_FILTER"
eq    "15 downscaled: sample encoded at 1920x960, 10-bit" "$(dims "$T/last_sample.hevc")" "1920,960,yuv420p10le"
: > "$T/sample_calls"
whole_title_estimate "$T/uhd.mkv" 25 "" > /dev/null
eq    "16 4K kept: no scale filter"              "$(cut -f1 "$T/sample_calls")" ""
eq    "16 4K kept: sample encoded at 3840x1920"  "$(dims "$T/last_sample.hevc")" "3840,1920,yuv420p10le"
: > "$T/sample_calls"
whole_title_estimate "$T/in/HDR10.mkv" 21 > /dev/null
check "HDR10 sample: x265 HDR10 parameters"      "cut -f2 '$T/sample_calls' | grep -q 'transfer=smpte2084' && cut -f2 '$T/sample_calls' | grep -q 'master-display=' && cut -f2 '$T/sample_calls' | grep -q 'max-cll=1000,400'"
eq    "HDR10 sample: PQ / BT.2020 in the sample" "$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer,color_primaries -of csv=p=0 "$T/last_sample.hevc")" "smpte2084,bt2020"
eq    "HDR10 sample: same x265 params as the job" "$(cut -f2 "$T/sample_calls" | sed 's/:log-level=error$//')" \
    "$(probe_hdr "$T/in/HDR10.mkv" 0; x265_color_params)"

# sections: 5 spread over the title, the same ones for every CRF
ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=12" -c:v libx264 -preset ultrafast "$T/long.mkv"
: > "$T/sample_calls"
(
    CRF_SAMPLE_SECONDS=1
    CRF_TITLE_FILE="$T/long.mkv" CRF_TITLE_VIDX=0 CRF_TITLE_FILTER="" CRF_TITLE_DURATION=$(get_duration "$T/long.mkv") CRF_TITLE_POINTS=5
    crf_select 25 26 1 crf_title_estimate > /dev/null
)
eq    "sampling: 5 sections x 2 CRFs"            "$(grep -c . "$T/sample_calls")" 10
eq    "sampling: same sections for every CRF"    "$(awk -F'\t' '$3 == 25 { print $4 }' "$T/sample_calls" | tr '\n' ' ')" \
                                                  "$(awk -F'\t' '$3 == 26 { print $4 }' "$T/sample_calls" | tr '\n' ' ')"
check "sampling: spread 10..90 %, not the opening" "awk -F'\t' '\$3 == 25 { s[++n] = \$4 } END { exit !(n == 5 && s[1] > 0.5 && s[1] < 1.5 && s[5] > 10 && s[5] < 11) }' '$T/sample_calls'"
CRF_SAMPLE_CACHE=1
: > "$T/sample_calls"
( CRF_SAMPLE_SECONDS=1; whole_title_estimate "$T/long.mkv" 30 > /dev/null; whole_title_estimate "$T/long.mkv" 30 > /dev/null )
eq    "sampling: second run from the cache"      "$(grep -c . "$T/sample_calls")" 5

# movie menu: 3840x1920 -> 1080p downscale is sampled at 1920x960
RH=$(new_home res)
cp "$T/uhd.mkv" "$RH/compress/in/UHD.mkv"
run_menu "$RH" "$RH/compress/work/movie_compress.sh" "1\n2\n2\nn\n" "$T/menu_uhd_down.log"
check "15 menu downscale: estimate at 1920x960" "grep -q 'Estimating video size from sample encodes (1920x960 output, downscaled like the final encode)' '$T/menu_uhd_down.log'"
check "15 menu downscale: job scales + CRF"     "grep -q -- \"-filter:v:0 scale\" '$(first_job "$RH" c)' && grep -q -- '-crf:v:0 19 ' '$(first_job "$RH" c)'"
rm -f "$RH/compress/work"/c[0-9]*.sh
run_menu "$RH" "$RH/compress/work/movie_compress.sh" "1\n1\n2\nn\n" "$T/menu_uhd_keep.log"
check "16 menu 4K kept: estimate at 3840x1920"  "grep -q 'Estimating video size from sample encodes (3840x1920 output)' '$T/menu_uhd_keep.log'"
check "16 menu 4K kept: job does not scale"     "! grep -q -- '-filter:v:0' '$(first_job "$RH" c)'"
eval "$(declare -f _real_crf_sample_encode | sed '1s/_real_crf_sample_encode/crf_sample_encode/')"

echo
echo "== smoke: High CRF 19 too large, CRF 20 fits (real samples)"
DH=$(new_home demo)
av_source -c:v libx264 -preset ultrafast -qp 0 "$DH/compress/in/Demo.mkv"
e19=$(WORK_DIR="$DH/compress/work" whole_title_estimate "$DH/compress/in/Demo.mkv" 19)
e20=$(WORK_DIR="$DH/compress/work" whole_title_estimate "$DH/compress/in/Demo.mkv" 20)
check "demo: CRF 20 estimate below CRF 19"      "(( e20 < e19 ))"
ceil=$(awk -v a="$e19" -v b="$e20" 'BEGIN { printf "%.12f", (a + b) / 2 / 1073741824 }')
DEMO_CONF=$(conf_with demo "MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB=$ceil")
run_menu "$DH" "$DH/compress/work/movie_compress.sh" "1\n2\nn\n" "$T/demo_high.log" "$DEMO_CONF"
djob=$(first_job "$DH" c)
echo "  ---- menu excerpt (ceiling $ceil GiB = midway between the CRF 19 and 20 estimates)"
sed -n '/^CRF analysis:/,/estimated total/p' "$T/demo_high.log" | sed 's/^/  | /'
check "demo: CRF 19 estimated too large"        "grep -q '^  CRF 19 -> estimated ' '$T/demo_high.log'"
check "demo: CRF 20 estimated, fits"            "grep -q '^  CRF 20 -> estimated ' '$T/demo_high.log'"
check "demo: nothing above CRF 20 sampled"      "! grep -qE 'sampling CRF (2[1-9])' '$T/demo_high.log'"
check "demo: selected CRF 20"                   "grep -A1 '^Selected:' '$T/demo_high.log' | grep -q 'CRF 20'"
check "demo: job is single-pass CRF 20"         "grep -q -- '-crf:v:0 20 ' '$djob' && [[ \$(grep -c libx265 '$djob') == 1 ]] && ! grep -qE -- '-b:v|pass=' '$djob'"
eq    "demo: job carries the CRF 20 estimate"   "$(grep -o 'est_vbytes=[0-9]*' "$djob" | cut -d= -f2)" "$e20"
bash "$djob" < /dev/null > "$T/demo_run.log" 2>&1
echo "  ---- job excerpt"
sed -n '/^Finished:/,/Audio: *copied/p' "$T/demo_run.log" | sed 's/^/  | /'
check "demo: encoded once, CRF 20"              "grep -q 'ENCODING (single pass, CRF 20)' '$T/demo_run.log' && ! grep -qE 'PASS [12]/2' '$T/demo_run.log'"
check "demo: audio copied (payload MATCH)"      "grep -q 'Audio track 1: *COPIED (E-AC-3 .*payload MD5 MATCH)' '$T/demo_run.log' && grep -q 'Audio track 2: *COPIED (AAC .*payload MD5 MATCH)' '$T/demo_run.log'"
check "demo: actual vs estimate reported"       "grep -q 'Estimated video size: ' '$T/demo_run.log' && grep -qE 'Estimate error: +[-+][0-9.]+%' '$T/demo_run.log'"
check "demo: job succeeded"                     "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/demo_run.log'"
check "demo: accuracy recorded"                 "awk -F'\\t' '\$2 == \"High\" && \$3 == \"20\" { f = 1 } END { exit !f }' '$DH/compress/work/logs/crf_estimates.tsv'"
cp "$ROOT/verify.sh" "$DH/compress/"
printf '2\n1\n' | HOME="$DH" bash "$DH/compress/verify.sh" > "$T/demo_verify.log" 2>&1
check "demo: verify.sh shows x265 CRF 20"       "grep -q 'Video encode *x265 CRF 20.0 (single pass)' '$T/demo_verify.log' && grep -q 'Tier *High' '$T/demo_verify.log'"

echo
echo "== smoke: Base CRF 25 fits, selected immediately"
rm -f "$DH/compress/work"/c[0-9]*.sh "$DH/compress/out"/*.mkv
run_menu "$DH" "$DH/compress/work/movie_compress.sh" "1\n3\nn\n" "$T/demo_base.log"
sed -n '/^CRF analysis:/,/estimated total/p' "$T/demo_base.log" | sed 's/^/  | /'
check "demo Base: only CRF 25 sampled"          "grep -q 'sampling CRF 25' '$T/demo_base.log' && ! grep -qE 'sampling CRF (2[6-9])' '$T/demo_base.log'"
check "demo Base: selected CRF 25"              "grep -A1 '^Selected:' '$T/demo_base.log' | grep -q 'CRF 25' && grep -q -- '-crf:v:0 25 ' '$(first_job "$DH" c)'"

echo
echo "== ceiling not reachable within the CRF range"
rm -f "$DH/compress/work"/c[0-9]*.sh
TINY_CONF=$(conf_with tiny MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB=0.000000001 MOVIE_BASE_VIDEO_SIZE_CEILING_GIB=0.000000001)
run_menu "$DH" "$DH/compress/work/movie_compress.sh" "1\n2\n1\nn\n" "$T/over_high.log" "$TINY_CONF"
check "5 High: every CRF 19..23 sampled"        "[[ \$(grep -cE 'sampling CRF (19|2[0-3]) ' '$T/over_high.log') == 5 ]] && ! grep -q 'sampling CRF 24' '$T/over_high.log'"
check "5 High: warning names the range"         "grep -q 'cannot be met within the' '$T/over_high.log' && grep -q 'High CRF range: even CRF 23' '$T/over_high.log'"
check "5 High: oversize shown"                  "grep -qE 'GiB above the ceiling' '$T/over_high.log'"
check "5 High: confirmation asked"              "grep -q '1) Encode at CRF 23 anyway' '$T/over_high.log'"
check "5 High: confirmed -> CRF 23 job"         "grep -q -- '-crf:v:0 23 ' '$(first_job "$DH" c)'"
check "5 High: summary says ceiling not met"    "grep -q 'ceiling NOT met' '$T/over_high.log'"
rm -f "$DH/compress/work"/c[0-9]*.sh
run_menu "$DH" "$DH/compress/work/movie_compress.sh" "1\n3\n2\nn\n" "$T/over_base.log" "$TINY_CONF"
check "9 Base: CRF 29 warned, skip -> nothing" "grep -q 'Base CRF range: even CRF 29' '$T/over_base.log' && grep -q 'Nothing queued' '$T/over_base.log' && [[ -z '$(first_job "$DH" c)' ]]"

echo
echo "== source-quality guard (source already below the CRF demand)"
GH=$(new_home guard)
av_source -c:v libx265 -preset ultrafast -crf 45 -x265-params log-level=error "$GH/compress/in/Low.mkv"
run_menu "$GH" "$GH/compress/work/movie_compress.sh" "1\n2\n1\nn\n" "$T/guard_copy.log"
gjob=$(first_job "$GH" c)
check "guard: reported before encoding"         "grep -q 'Source-quality guard: the source video is already below what' '$T/guard_copy.log' && grep -q 'High CRF 19 would need' '$T/guard_copy.log'"
check "guard: keep source -> video copy job"    "grep -q 'item_expect .*video=copy' '$gjob' && ! grep -q libx265 '$gjob'"
check "guard: summary says source kept"         "grep -q 'source video kept unchanged (stream copy)' '$T/guard_copy.log'"
bash "$gjob" < /dev/null > "$T/guard_run.log" 2>&1
check "guard: copy job ok, video COPIED"        "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/guard_run.log' && grep -q 'Video stream: *COPIED' '$T/guard_run.log'"
check "guard: audio still copied + verified"    "grep -q 'Audio track 1: *COPIED (E-AC-3 .*payload MD5 MATCH)' '$T/guard_run.log'"
rm -f "$GH/compress/work"/c[0-9]*.sh "$GH/compress/out"/*.mkv
run_menu "$GH" "$GH/compress/work/movie_compress.sh" "1\n2\n2\nn\n" "$T/guard_enc.log"
check "guard: encode anyway -> CRF 19 job"      "grep -q -- '-crf:v:0 19 ' '$(first_job "$GH" c)' && grep -q 'encode anyway chosen' '$T/guard_enc.log'"
rm -f "$GH/compress/work"/c[0-9]*.sh
run_menu "$GH" "$GH/compress/work/movie_compress.sh" "1\n2\n3\nn\n" "$T/guard_skip.log"
check "guard: skip -> nothing queued"           "grep -q 'Nothing queued' '$T/guard_skip.log' && [[ -z '$(first_job "$GH" c)' ]]"
GA=$(new_home guardavc)
av_source -c:v libx264 -preset ultrafast -crf 45 "$GA/compress/in/LowAvc.mkv"
run_menu "$GA" "$GA/compress/work/movie_compress.sh" "1\n2\n1\n2\nn\n" "$T/guard_avc.log"
check "guard: non-HEVC source cannot be kept"   "grep -q '1) (not available: keeping the source video needs an HEVC source' '$T/guard_avc.log' && grep -q -- '-crf:v:0 19 ' '$(first_job "$GA" c)'"
mkdir -p "$GH/compress/in/LowShow"
cp "$GH/compress/in/Low.mkv" "$GH/compress/in/LowShow/E01.mkv"
cp "$GH/compress/in/Low.mkv" "$GH/compress/in/LowShow/E02.mkv"
mv "$GH/compress/in/Low.mkv" "$T/Low.mkv"
run_menu "$GH" "$GH/compress/work/series_compress.sh" "1\n2\n1\ny\n" "$T/guard_series.log"
sjob=$(first_job "$GH" series)
check "guard series: episodes listed"           "grep -q 'Source-quality guard: 2 episode(s) are already below' '$T/guard_series.log'"
check "guard series: both kept (video copy)"    "[[ \$(grep -c 'video=copy' '$sjob') == 2 ]] && ! grep -q libx265 '$sjob'"

echo
echo "== progress-check: CRF jobs show one encode step"
PH="$T/phome"
mkdir -p "$PH/compress/work" "$PH/stub"
cp -r "$WORK_DIR/lib" "$PH/compress/work/"
cp "$ROOT/progress-check.sh" "$PH/compress/"
now=$(date +%s)
cat > "$PH/stub/tmux" <<EOF
#!/usr/bin/env bash
[[ "\$1" == list-sessions ]] && { echo "c7 $now"; echo "c8 $now"; }
exit 0
EOF
chmod +x "$PH/stub/tmux"
for s in c7 c8; do
    if [[ $s == c7 ]]; then m=crf c=21 p=encode tier=High; else m=abr c="" p=1/2 tier=Quality; fi
    printf 'version=1\nsession=%s\ntype=movie\nstatus=running\nitem=1\nitems=1\nok=0\nfailed=0\nname=%s.mkv\ninput=/x/%s.mkv\noutput=/y/%s.mkv\ntier=%s\npass=%s\nmode=%s\ncrf=%s\nduration=3600\nstarted=%s\nupdated=%s\nprogress=%s\nlog_dir=/z\n' \
        "$s" "$s" "$s" "$s" "$tier" "$p" "$m" "$c" "$now" "$now" "$PH/compress/work/$s.progress" > "$PH/compress/work/$s.state"
    printf 'out_time_us=1800000000\nspeed=2.0x\nprogress=continue\n' > "$PH/compress/work/$s.progress"
done
HOME="$PH" PATH="$PH/stub:$PATH" bash "$PH/compress/progress-check.sh" > "$T/progress.out" 2>&1
c7=$(sed -n '/^c7 /,/^$/p' "$T/progress.out"); c8=$(sed -n '/^c8 /,/^$/p' "$T/progress.out")
check "21 CRF job: one encode step with its CRF" "grep -q 'Tier: High .*Encoding, CRF: 21' <<< \"\$c7\""
check "21 CRF job: no pass 1/2 or 2/2"           "! grep -q 'Pass' <<< \"\$c7\""
check "21 CRF job: progress and ETA"             "grep -q '50.0%.*ETA 00:15:00' <<< \"\$c7\""
check "20 Quality job: still Pass 1/2"           "grep -q 'Tier: Quality .*Pass: 1/2' <<< \"\$c8\""
check "21 job state records mode / CRF"          "grep -qx 'mode=crf' '$WORK_DIR/sdrcrf.state' && grep -qx 'crf=24' '$WORK_DIR/sdrcrf.state'"

echo
echo "============================================================"
echo "passed: $PASS   failed: $FAIL"
for s in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do echo "skipped: $s"; done
echo "============================================================"

(( FAIL > 0 )) && { echo "Logs: $T"; KEEP=1; }
(( FAIL == 0 ))
