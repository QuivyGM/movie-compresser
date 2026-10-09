#!/usr/bin/env bash
# Verbose policy output never changes the tier / search state.
#
#   bash ~/compress/work/tests/quality_verbose_tests.sh
#
# Regression: with COMPRESS_VERBOSE=1 the movie menu printed the tier's
# policy (crf_policy_lines) AFTER it had set the source-limited Quality
# ceiling (source video - 1), and that print reloaded the tier, putting
# the 22 GiB band maximum back. No ffmpeg needed. Covers:
#   1. the movie menu's Quality sequence (load, source-limited
#      adjustment, verbose print) gives the same state with and without
#      the verbose print: source 19 GiB (source-limited), 21 GiB (band,
#      capped below the source later), 30 GiB (22 GiB band maximum)
#   2. crf_policy_lines / movie_policy_line leave every tier variable
#      alone (Quality, movie High / Base, series High / Base, Custom)
#   3. the printed Quality policy text is unchanged
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

source "$SRC_WORK/lib/ui.sh" > /dev/null
source "$SRC_WORK/lib/bitrate.sh"
source "$SRC_WORK/lib/policy.sh"
export COMPRESS_CONF="$SRC_WORK/lib/compress.conf"
load_policy 2>/dev/null
M="$SRC_WORK/movie_compress.sh"

gib_bytes() { awk -v g="$1" 'BEGIN { printf "%.0f", g * 1073741824 }'; }
state() { echo "$CRF_MIN|$CRF_START|$CRF_MAX|$CRF_CEILING_BYTES|$CRF_CEILING_GIB|$CRF_GIB_PER_HOUR"; }

# quality_state SOURCE_GIB VERBOSE  ->  "STATUS|state|retry ceiling" as
# movie_compress.sh reaches the Quality search (crf_tier_load, the
# source-limited adjustment, the verbose policy print) and the retry
# ceiling it then builds (band: never at or above the source video)
quality_state() {
    local DURATION=7200 TIER=Quality CUSTOM_CRF="" QUALITY_STATUS=band rc
    SOURCE_VIDEO_BYTES=$(gib_bytes "$1")
    SOURCE_VIDEO_GIB=$(bytes_to_gib "$SOURCE_VIDEO_BYTES")
    quality_source_limited "$SOURCE_VIDEO_BYTES" && QUALITY_STATUS=source-limited

    crf_tier_load movie "$TIER" "$CUSTOM_CRF" "$DURATION"
    if [[ "$QUALITY_STATUS" == "source-limited" ]]; then
        CRF_CEILING_BYTES=$(( SOURCE_VIDEO_BYTES - 1 ))
        CRF_CEILING_GIB="$SOURCE_VIDEO_GIB"
    fi
    if (( $2 == 1 )); then
        crf_policy_lines movie "$TIER" "$CUSTOM_CRF" "$DURATION" > /dev/null
    fi

    rc="$CRF_CEILING_BYTES"
    if [[ "$QUALITY_STATUS" == band ]] && (( SOURCE_VIDEO_BYTES - 1 < rc )); then
        rc=$(( SOURCE_VIDEO_BYTES - 1 ))
    fi
    echo "$QUALITY_STATUS|$(state)|$rc"
}

# ------------------------------------------------------------
echo "== 1. movie Quality: verbose off == verbose on"
la=$(grep -nF 'CRF_CEILING_BYTES=$(( SOURCE_VIDEO_BYTES - 1 ))' "$M" | head -n 1 | cut -d: -f1)
lb=$(grep -nF 'crf_policy_lines movie "$TIER"' "$M" | head -n 1 | cut -d: -f1)
lc=$(grep -nF 'crf_select_quality "$CRF_MIN"' "$M" | head -n 1 | cut -d: -f1)
check "menu: source-limited adjustment, then the verbose print, then the search" \
    "[[ -n '$la' && -n '$lb' && -n '$lc' ]] && (( la < lb && lb < lc ))"

s19=$(gib_bytes 19); s21=$(gib_bytes 21); c22=$(gib_bytes 22)
off=$(quality_state 19 0); on=$(quality_state 19 1)
eq "19 GiB source: verbose on == off"            "$on" "$off"
eq "19 GiB source: source-limited, ceiling source - 1" "$on" "source-limited|0|8|23|$((s19 - 1))|19.00||$((s19 - 1))"
off=$(quality_state 21 0); on=$(quality_state 21 1)
eq "21 GiB source: verbose on == off"            "$on" "$off"
eq "21 GiB source: band, retry ceiling source - 1" "$on" "band|0|8|23|$c22|22||$((s21 - 1))"
off=$(quality_state 30 0); on=$(quality_state 30 1)
eq "30 GiB source: verbose on == off"            "$on" "$off"
eq "30 GiB source: band, 22 GiB ceiling"          "$on" "band|0|8|23|$c22|22||$c22"

# ------------------------------------------------------------
echo
echo "== 2. policy output leaves the tier state alone"
crf_tier_load movie Quality
CRF_CEILING_BYTES=123; CRF_CEILING_GIB=0.00
before=$(state)
crf_policy_lines movie Quality > /dev/null
eq "crf_policy_lines movie Quality: no change"   "$(state)" "$before"
movie_policy_line Quality > /dev/null
eq "movie_policy_line Quality: no change"        "$(state)" "$before"
for t in High Base; do
    crf_tier_load movie "$t" "" 7200
    before=$(state)
    crf_policy_lines movie "$t" "" 5400 > /dev/null
    movie_policy_line "$t" 10800 > /dev/null
    crf_policy_lines movie Quality > /dev/null
    eq "movie $t (2 h ceiling) unchanged by other prints" "$(state)" "$before"
done
for t in High Base; do
    crf_tier_load series "$t"
    before=$(state)
    crf_policy_lines series "$t" > /dev/null
    crf_policy_lines movie High "" 7200 > /dev/null
    eq "series $t unchanged by policy prints"     "$(state)" "$before"
done
crf_tier_load movie Custom 21
before=$(state)
crf_policy_lines movie Custom 21 > /dev/null
eq "Custom unchanged"                           "$(state)" "$before"
check "series Quality still refused"            "! crf_policy_lines series Quality 2>/dev/null"

# ------------------------------------------------------------
echo
echo "== 3. printed Quality policy unchanged"
pl=$(crf_policy_lines movie Quality)
eq "Quality policy block" "$(tr '\n' '|' <<< "$pl")" \
    "Quality CRF search:|  Range: 0-23|  Start: 8 (first CRF sampled; the search may go below or above it)|  Target: 20 GiB|  Band: 18-22 GiB (copied audio not counted)|  lowest CRF estimated inside the band; none inside: closest to the target|  never a CRF estimated at or above the source video size|  encode: x265 CRF, single pass, preset slow, 10-bit|  audio: copied unchanged|"
eq "Quality policy line" "$(movie_policy_line Quality)" \
    "CRF 0-23, search starts at 8 [lowest CRF with the video estimate in 18-22 GiB, else closest to 20 GiB]; audio copied"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
