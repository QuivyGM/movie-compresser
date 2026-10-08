#!/usr/bin/env bash
# Series CRF selection with outliers (season CRF for the regular
# episodes, own CRF for one isolated outlier, conservative estimates for
# episodes that were not sampled, new policy settings).
#
#   bash ~/compress/work/tests/series_outlier_tests.sh
#
# Part 1 (seconds, no ffmpeg): policy math and the selection through
# crf_series_estimate / crf_episode_estimate with stand-in sample
# encodes (sizes per episode and CRF, -12 % per CRF step).
# Part 2 (ffmpeg with libx265): the series menu on 2 s synthetic
# episodes, one of them noisy (an isolated outlier): per-episode CRFs in
# the generated job, outlier prompt, sample cache.
# The post-encode per-episode retry is covered by crf_retry_tests.sh.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${OUTLIER_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE
G=1073741824
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }

WORK_DIR="$T/work"
mkdir -p "$WORK_DIR"
cp -r "$SRC_WORK/lib" "$WORK_DIR/"
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do
    source "$WORK_DIR/lib/$l.sh" > /dev/null
done

# conf_with NAME KEY=VALUE...  ->  modified copy of the project config
conf_with() {
    local f="$T/conf_$1.conf" kv
    shift
    cp "$SRC_WORK/lib/compress.conf" "$f"
    for kv in "$@"; do
        sed -i "s|^${kv%%=*}=.*|${kv}|" "$f"
        grep -q "^${kv%%=*}=" "$f" || echo "$kv" >> "$f"
    done
    printf '%s' "$f"
}

# fixed tier values, independent of the project's current numbers
COMPRESS_CONF=$(conf_with base SERIES_HIGH_CRF_MIN=18 SERIES_HIGH_CRF_MAX=21 SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=5 \
    SERIES_CRF_OUTLIER_PCT=25 SERIES_CRF_DOWN_RETRY_MAX=1 CRF_DOWN_RETRY_FIT_MARGIN_PCT=5 SERIES_CRF_SAMPLE_EPISODES=4)
export COMPRESS_CONF
load_policy > /dev/null

# ------------------------------------------------------------
echo "== policy settings"

check "project config: outlier 25 %, series down max 1, fit margin 5 %" \
    "grep -qx 'SERIES_CRF_OUTLIER_PCT=25' '$SRC_WORK/lib/compress.conf' && grep -qx 'SERIES_CRF_DOWN_RETRY_MAX=1' '$SRC_WORK/lib/compress.conf' && grep -qx 'CRF_DOWN_RETRY_FIT_MARGIN_PCT=5' '$SRC_WORK/lib/compress.conf'"
check "project config loads"                "COMPRESS_CONF='$SRC_WORK/lib/compress.conf' load_policy 2>/dev/null"
for k in SERIES_CRF_OUTLIER_PCT SERIES_CRF_DOWN_RETRY_MAX CRF_DOWN_RETRY_FIT_MARGIN_PCT; do
    grep -v "^$k=" "$COMPRESS_CONF" > "$T/miss.conf"
    check "missing $k: named, menu stops"   "! COMPRESS_CONF='$T/miss.conf' load_policy 2>'$T/miss.err' && grep -q '$k is not set' '$T/miss.err'"
done
check "outlier pct 0 rejected"              "! COMPRESS_CONF='$(conf_with o0 SERIES_CRF_OUTLIER_PCT=0)' load_policy 2>/dev/null"
check "fit margin 100 rejected"             "! COMPRESS_CONF='$(conf_with f100 CRF_DOWN_RETRY_FIT_MARGIN_PCT=100)' load_policy 2>/dev/null"
check "series down max 1.5 rejected"        "! COMPRESS_CONF='$(conf_with d15 SERIES_CRF_DOWN_RETRY_MAX=1.5)' load_policy 2>/dev/null"
check "series down max 0 accepted"          "COMPRESS_CONF='$(conf_with d0 SERIES_CRF_DOWN_RETRY_MAX=0)' load_policy 2>/dev/null"
load_policy > /dev/null

# ------------------------------------------------------------
echo
echo "== outlier detection (series_batch_stats)"

series_batch_stats "$(gib 5)" $(gib 3.7) $(gib 4.2) $(gib 6.0) $(gib 3.9) $(gib 4.0) $(gib 4.1)
eq "one episode above median x 1.25: isolated"  "$SB_ISOLATED/${SB_OUTLIERS[*]}" "2/2"
eq "regular episodes decide (largest 4.2)"      "$SB_DECIDE/$SB_FITS" "$(gib 4.2)/1"
eq "threshold = median x 1.25"                  "$SB_LIMIT" "$(gib 5.0625)"
series_batch_stats "$(gib 5)" $(gib 5.4) $(gib 3.0) $(gib 5.9) $(gib 3.2) $(gib 4.0) $(gib 6.2)
eq "two above the threshold: none isolated"     "${SB_ISOLATED:-none}/${SB_OUTLIERS[*]}" "none/2 5"
eq "two above: the largest decides"             "$SB_DECIDE/$SB_FITS" "$(gib 6.2)/0"
series_batch_stats "$(gib 5)" $(gib 6.2) $(gib 3.6)
eq "two episodes: no outlier detection"         "${SB_ISOLATED:-none}/$SB_DECIDE" "none/$(gib 6.2)"
series_batch_stats "$(gib 5)" $(gib 4.0) $(gib 4.9) $(gib 4.5)
eq "slight variation: no outlier"               "${SB_ISOLATED:-none}/${#SB_OUTLIERS[@]}" "none/0"
series_batch_stats 0 $(gib 9) $(gib 2) $(gib 2)
eq "no ceiling (Custom): always fits"           "$SB_FITS/${#SB_ABOVE[@]}" "1/0"
eq "exactly at the threshold: not an outlier" \
    "$(SERIES_CRF_OUTLIER_PCT=25; series_batch_stats 0 400 400 500; echo "${SB_ISOLATED:-none}")" "none"

# ------------------------------------------------------------
echo
echo "== conservative estimates for episodes that were not sampled"

EP_DUR=(2700 2700 2700 2700 2700)
series_crf_spread 500000 - 600000 - 700000
eq "unsampled: highest sampled rate, not the median" "$SC_FILL_RATE/$SC_MEDIAN_RATE" "700000.000/600000.000"
eq "unsampled episodes: highest rate x runtime"  "${SC_EP_BYTES[1]}/${SC_EP_BYTES[3]}" "1890000000/1890000000"
eq "sources"                                     "${SC_EP_FROM[*]}" "sample highest sample highest sample"
series_crf_spread 500000 - 600000 - 4000000
eq "one sampled outlier rate: not used as fill"   "$SC_FILL_RATE" "600000.000"
eq "... but it keeps its own estimate"           "${SC_EP_BYTES[4]}" "10800000000"
series_crf_spread 1000000 - 1000000 2000000 2000000
eq "two high sampled rates: season difficulty, used" "$SC_FILL_RATE" "2000000.000"
series_crf_spread 500000 - 4000000
eq "two samples: no outlier exclusion"           "$SC_FILL_RATE" "4000000.000"
EP_DUR=(2700 5400 2700)
series_crf_spread 500000 - 500000
eq "longer unsampled episode: rate x its runtime" "${SC_EP_BYTES[1]}" "2700000000"

eq "sample episodes: 10 -> 4 spread"             "$(series_sample_episodes 10 4 | tr '\n' ' ')" "0 3 6 9 "
eq "sample episodes: + the longest (5)"          "$(series_sample_episodes 10 4 5 | tr '\n' ' ')" "0 3 5 6 9 "
eq "sample episodes: longest already sampled"    "$(series_sample_episodes 10 4 3 | tr '\n' ' ')" "0 3 6 9 "
eq "sample episodes: all when few"               "$(series_sample_episodes 3 4 1 | tr '\n' ' ')" "0 1 2 "
EP_DUR=(2700 2650 3100 2700)
eq "longest episode index"                       "$(series_longest_episode)" 2

# ------------------------------------------------------------
echo
echo "== season / outlier CRF selection (stand-in sample encodes)"

# SEP[n]: video GiB of episode En per 45 min at CRF 18; -12 % per step.
# Records every sample encode as "CRF EPISODE".
declare -A SEP=()
crf_sample_title() {   # FILE VIDX FILTER CRF DURATION POINTS
    local n="${1##*/E}"
    n="${n%.mkv}"
    printf '%s %s\n' "$4" "$n" >> "$T/calls"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=$(awk -v g="${SEP[$n]}" -v c="$4" 'BEGIN { printf "%.0f", g * 1073741824 * 0.88 ^ (c - 18) / 27 }')
}

# sel [-k SAMPLED] GIB...  ->  the series menu's selection: season CRF
# (crf_select over crf_series_estimate), then the isolated outlier's own
# CRF (series_episode_crf over crf_episode_estimate) when it does not
# fit at the season CRF. Sets SEL "CRF/tried/over", CRFS (per episode),
# OUT (outlier index or -), EPC_*.
sel() {
    local k=99 n eb
    [[ "$1" == -k ]] && { k="$2"; shift 2; }
    FILES=(); EP_VIDX=(); EP_DUR=(); SEP=(); CRF_SERIES_LABELS=()
    for ((n = 1; n <= $#; n++)); do
        FILES+=("/s/E$n.mkv"); EP_VIDX+=(0); EP_DUR+=("${DUR[$n]:-2700}"); SEP[$n]="${!n}"
        CRF_SERIES_LABELS+=("E$n")
    done
    mapfile -t CRF_SERIES_SAMPLED < <(series_sample_episodes "$#" "$k" "$(series_longest_episode)")
    CRF_SERIES_FILTER=""
    declare -gA CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_EP_EST=()
    : > "$T/calls"
    crf_tier_load series High
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate > "$T/sel.out"
    SEL="$CRF_SELECTED/${CRF_TRIED[*]}/$CRF_OVER_CEILING"
    read -ra eb <<< "${CRF_SERIES_EP_BYTES[$CRF_SELECTED]}"
    series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}"
    CRFS=(); for n in "${!eb[@]}"; do CRFS+=("$CRF_SELECTED"); done
    OUT="${SB_ISOLATED:--}"
    EPC_CRF="" EPC_OVER=0 EPC_TRIED=()
    if [[ -n "$SB_ISOLATED" ]] && (( eb[SB_ISOLATED] > CRF_CEILING_BYTES )); then
        series_episode_crf "$SB_ISOLATED" "$CRF_SELECTED" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_episode_estimate >> "$T/sel.out"
        CRFS[$SB_ISOLATED]="$EPC_CRF"
    fi
}
declare -A DUR=()

sel 3.0 3.5 4.2 4.4 3.8 4.0
eq    "all regular episodes fit: one season CRF 18" "$SEL/${CRFS[*]}" "18/18/0/18 18 18 18 18 18"
eq    "nothing above 18 sampled"                    "$(cut -d' ' -f1 "$T/calls" | sort -u)" 18

sel 3.7 4.2 6.0 3.9 4.0 4.1
eq    "isolated outlier: season stays at 18"        "$SEL/$OUT" "18/18/0/2"
eq    "isolated outlier gets its own CRF 20"        "${CRFS[*]}" "18 18 20 18 18 18"
eq    "outlier CRFs tried: 18 19 20"                "${EPC_TRIED[*]}/$EPC_OVER" "18 19 20/0"
eq    "only the outlier sampled above 18"           "$(awk '$1 != 18 { print }' "$T/calls" | tr '\n' ' ')" "19 3 20 3 "
eq    "cached: outlier at 18 not sampled again"     "$(grep -c '^18 3$' "$T/calls")" 1
check "outlier's own samples shown"                "grep -q '^  E3  CRF 19   ~5.28 GiB\$' '$T/sel.out' && grep -q '^  E3  CRF 20   ~4.65 GiB\$' '$T/sel.out'"
check "cached estimate shown as such"              "grep -q '^  E3  CRF 18   ~6.00 GiB (already sampled)\$' '$T/sel.out'"
eq    "estimate map of the outlier"                 "$(series_est_map 2)" "18=${CRF_EP_EST[2:18]}:19=${CRF_EP_EST[2:19]}:20=${CRF_EP_EST[2:20]}"
check "outlier map: about -12 % per CRF"            "awk -v a='${CRF_EP_EST[2:18]}' -v b='${CRF_EP_EST[2:19]}' 'BEGIN { exit !(b / a > 0.879 && b / a < 0.881) }'"
read -ra eb <<< "${CRF_SERIES_EP_BYTES[18]}"
eq    "estimate map of a regular episode"           "$(series_est_map 0)" "18=${eb[0]}"

sel 5.4 3.0 5.9 3.2 4.0 6.2
eq    "two large episodes: season CRF rises to 20"  "$SEL/${CRFS[*]}" "20/18 19 20/0/20 20 20 20 20 20"
eq    "two large episodes: no own CRF"              "$OUT" "-"

sel 3.7 4.2 9.0 3.9 4.0 4.1
eq    "outlier above at CRF_MAX: 21, flagged"       "${CRFS[2]}/$EPC_OVER/${EPC_TRIED[*]}" "21/1/18 19 20 21"
check "outlier: never above CRF_MAX"                "! grep -q '^22 ' '$T/calls'"
eq    "outlier above: season still 18"              "$SEL" "18/18/0"

sel 9 9 9
eq    "season above at CRF_MAX: 21 + over"          "$SEL" "21/18 19 20 21/1"

sel 6.2 3.6
eq    "two episodes: both must fit -> 20"           "$SEL/$OUT" "20/18 19 20/0/-"

# 8 episodes, 4 sampled (0 2 5 7): two hard sampled episodes (5.2, 5.1)
# -> the unsampled ones are assumed as hard as the hardest sample (the
# old median fill, 4.05 GiB, would have kept CRF 18 for all of them)
sel -k 4 3.0 3.0 5.2 3.0 3.0 5.1 3.0 3.0
eq    "4 of 8 sampled"                              "${CRF_SERIES_SAMPLED[*]}" "0 2 5 7"
read -ra eb <<< "${CRF_SERIES_EP_FROM[18]}"
eq    "unsampled: highest sampled rate"             "${eb[*]}" "sample highest sample highest highest sample highest sample"
eq    "hidden difficulty raises the season: 19"     "$SEL/$OUT" "19/18 19/0/-"

# a long unsampled episode (double length) becomes the sampled outlier
DUR=([4]=5400)
sel -k 2 3.0 3.0 3.0 3.0 3.0
eq    "longest episode always sampled"              "${CRF_SERIES_SAMPLED[*]}" "0 3 4"
eq    "double-length episode: own CRF, season 18"   "$SEL/$OUT/${CRFS[*]}" "18/18/0/3/18 18 18 20 18"
DUR=()

# Custom: no ceiling, no outlier CRF
FILES=(/s/E1.mkv /s/E2.mkv /s/E3.mkv); EP_VIDX=(0 0 0); EP_DUR=(2700 2700 2700)
SEP=([1]=3 [2]=3 [3]=9); CRF_SERIES_SAMPLED=(0 1 2); declare -A CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_EP_EST=()
crf_tier_load series Custom 16
crf_select_exact 16 crf_series_estimate > /dev/null
read -ra eb <<< "${CRF_SERIES_EP_BYTES[16]}"
series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}"
eq    "Custom: one CRF, fits without a ceiling"     "$CRF_SELECTED/$SB_FITS/${#SB_ABOVE[@]}" "16/1/0"

# ------------------------------------------------------------
echo
echo "== source-quality guard: not-sampled episodes checked with their own samples"

# 8 episodes, 4 sampled (0 2 5 7); season CRF 19 (see above): the
# not-sampled episodes are estimated at the highest sampled rate (E3 5.2
# GiB at 18 -> 4.58 GiB at 19), their own content is 3.0 (2.64 at 19)
sel -k 4 3.0 3.0 5.2 3.0 3.0 5.1 3.0 3.0
read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[19]}"
read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[19]}"
EP_CRF=(19 19 19 19 19 19 19 19); EP_CEIL_SKIP=(0 0 0 0 0 0 0 0)
EP_VBYTES=($(gib 100) $(gib 4.0) $(gib 1) $(gib 2.5) $(gib 100) $(gib 100) $(gib 100) $(gib 100))
EP_CEIL_SKIP[2]=1                                  # E3: skipped at the ceiling
: > "$T/calls"
series_guard_episodes crf_episode_estimate > "$T/guard.out"
eq    "E2: conservative estimate flags it"          "$(crf_above_source "$(awk -v G=$G 'BEGIN { printf "%.0f", 5.2 * G * 0.88 }')" "$(gib 4.0)" && echo flagged)" "flagged"
eq    "E2 / E4 sampled themselves at their CRF"     "${GUARD_SAMPLED[*]}/$(tr '\n' ' ' < "$T/calls")" "1 3/19 2 19 4 "
eq    "E2 own sample fits below the source: no guard; E4 still not below" "${GUARD[*]}" "3"
eq    "own estimates replace the conservative ones" "${EP_FROM[1]}/${EP_FROM[3]}/${EP_EST[1]}" "sample/sample/${CRF_EP_EST[1:19]}"
check "skipped at the ceiling: never guarded or sampled" "! grep -q '^19 3\$' '$T/calls' && [[ ' ${GUARD[*]} ' != *' 2 '* ]]"
check "header + own sample lines shown"             "grep -q '^Source check (not sampled; estimated at or above the source video):\$' '$T/guard.out' && grep -q '^  E2  CRF 19   ~2.64 GiB\$' '$T/guard.out'"
: > "$T/calls"
EP_FROM=("${EP_FROM[@]}")
series_guard_episodes crf_episode_estimate > "$T/guard2.out"
eq    "second check: nothing sampled again"         "$(wc -l < "$T/calls")/${#GUARD_SAMPLED[@]}/${GUARD[*]}" "0/0/3"
read -ra pe <<< "${CRF_SERIES_EP_BYTES[19]}"
EP_EST[1]="${pe[1]}"; EP_FROM[1]=highest           # conservative again
series_guard_episodes crf_episode_estimate > "$T/guard3.out"
eq    "cached own estimate reused (no encode)"      "$(wc -l < "$T/calls")" 0
check "cached estimate shown as such"               "grep -q '^  E2  CRF 19   ~2.64 GiB (already sampled)\$' '$T/guard3.out'"

# a sampled episode at or above its source: guarded as before, no new sample
read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[19]}"
read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[19]}"
EP_CEIL_SKIP=(0 0 0 0 0 0 0 0)
EP_VBYTES=($(gib 1) $(gib 100) $(gib 100) $(gib 100) $(gib 100) $(gib 100) $(gib 100) $(gib 100))
: > "$T/calls"
series_guard_episodes crf_episode_estimate > "$T/guard4.out"
eq    "sampled episode: guarded, not sampled again" "${GUARD[*]}/${#GUARD_SAMPLED[@]}/$(wc -l < "$T/calls")" "0/0/0"
check "no header without a not-sampled check"       "! grep -q 'Source check' '$T/guard4.out'"
EP_VBYTES=()
eq    "unknown source sizes: no guard"              "$(series_guard_episodes crf_episode_estimate > /dev/null; echo "${#GUARD[@]}")" 0

# ------------------------------------------------------------
echo
echo "== ceiling re-check after the guard's own samples (series_late_ceiling)"

# late E2CONTENT  ->  8 episodes, 4 sampled (0 2 5 7) all 3.0 GiB, so the
# not-sampled E2 is guessed at 3.0 (fits 5 GiB, season CRF 18); its
# source (2 GiB) is below the guess -> the guard samples E2 itself
late() {
    sel -k 4 3.0 "$1" 3.0 3.0 3.0 3.0 3.0 3.0
    read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[18]}"
    read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[18]}"
    EP_CRF=(18 18 18 18 18 18 18 18); EP_CEIL_SKIP=(0 0 0 0 0 0 0 0); EP_OVER=(0 0 0 0 0 0 0 0)
    EP_VBYTES=($(gib 100) $(gib 2) $(gib 100) $(gib 100) $(gib 100) $(gib 100) $(gib 100) $(gib 100))
    : > "$T/calls"
    series_guard_episodes crf_episode_estimate > "$T/late.out"
    series_late_ceiling crf_episode_estimate >> "$T/late.out"
}

late 4.0
eq    "real sample fits: no CRF change"             "$SEL/${EP_CRF[*]}/${#LATE[@]}" "18/18/0/18 18 18 18 18 18 18 18/0"
eq    "real sample fits: one sample (guard), no more" "$(tr '\n' ' ' < "$T/calls")" "18 2 "
check "real sample fits: no ceiling check header"   "! grep -q 'Ceiling check' '$T/late.out'"

late 6.0
eq    "real sample above: guessed fit, season 18"   "$SEL/${GUARD_SAMPLED[*]}" "18/18/0/1"
eq    "only E2 raised to CRF 20 before the encode"  "${EP_CRF[*]}/${LATE[*]}/${EP_OVER[1]}" "18 20 18 18 18 18 18 18/1/0"
eq    "E2 estimate at its new CRF"                  "${EP_EST[1]}" "${CRF_EP_EST[1:20]}"
eq    "cache: CRF 18 sample reused, 19 / 20 once"   "$(tr '\n' ' ' < "$T/calls")" "18 2 19 2 20 2 "
check "ceiling check shown, cached sample marked"   "grep -q '^Ceiling check (own sample above the ceiling at its CRF):\$' '$T/late.out' && grep -q '^  E2  CRF 18   ~6.00 GiB (already sampled)\$' '$T/late.out'"
eq    "season CRF and other estimates unchanged"    "$CRF_SELECTED/${EP_EST[0]}/${EP_FROM[2]}" "18/$(read -ra x <<< "${CRF_SERIES_EP_BYTES[18]}"; echo "${x[0]}")/sample"
eq    "E2 estimate map: its own samples 18-20"      "$(series_est_map 1 | tr ':' '\n' | cut -d= -f1 | tr '\n' ' ')" "18 19 20 "

late 9.0
eq    "still above at CRF_MAX: 21, flagged"         "${EP_CRF[1]}/${EP_OVER[1]}/$(cut -d' ' -f1 "$T/calls" | tr '\n' ' ')" "21/1/18 19 20 21 "
check "never above CRF_MAX"                         "! grep -q '^22 ' '$T/calls'"

# Custom (no ceiling): never re-checked
CRF_CEILING_BYTES_SAVE="$CRF_CEILING_BYTES"; CRF_CEILING_BYTES=0
GUARD_SAMPLED=(1); EP_EST[1]=$(gib 50)
series_late_ceiling crf_episode_estimate > /dev/null
eq    "no ceiling (Custom): nothing re-checked"     "${#LATE[@]}" 0
CRF_CEILING_BYTES="$CRF_CEILING_BYTES_SAVE"

# ------------------------------------------------------------
echo
echo "== set -u"

cat > "$T/setu.sh" <<EOF
set -euo pipefail
WORK_DIR='$WORK_DIR'
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do source "\$WORK_DIR/lib/\$l.sh" > /dev/null; done
COMPRESS_CONF='$COMPRESS_CONF' load_policy > /dev/null
EP_DUR=(2700 2700 2700)
series_crf_spread 500000 - 600000
series_batch_stats 0 1 2 3
series_batch_stats 100 1 2 300
CRF_TRIED=(18); declare -A CRF_SERIES_EP_BYTES=([18]="1 2 3")
series_est_map 1 > /dev/null
CRF_EST=([18]=5); crf_est_map > /dev/null
FILES=(/a /b /c); CRF_CEILING_BYTES=100; CRF_CEILING_GIB=1
series_crf_analysis_lines > /dev/null
echo survived
EOF
eq    "policy functions under set -euo pipefail"    "$(bash "$T/setu.sh" 2>&1 | tail -1)" "survived"

# ------------------------------------------------------------
unset -f crf_sample_title
source "$WORK_DIR/lib/encode_common.sh" > /dev/null

for t in ffmpeg ffprobe; do
    command -v "$t" >/dev/null || { echo; echo "$t not found: menu tests skipped"; echo; echo "passed: $PASS  failed: $FAIL"; exit $(( FAIL > 0 )); }
done
[[ "$(ffmpeg -hide_banner -encoders 2>/dev/null)" == *libx265* ]] ||
    { echo; echo "libx265 not found: menu tests skipped"; echo; echo "passed: $PASS  failed: $FAIL"; exit $(( FAIL > 0 )); }

echo
echo "== series menu: isolated outlier (real 2 s samples)"

H="$T/home"
mkdir -p "$H/compress/in/Show" "$H/compress/out" "$T/stub"
cp -r "$SRC_WORK" "$H/compress/work"
rm -rf "$H/compress/work/tests" "$H/compress/work/logs" "$H/compress/work/cache"
rm -f "$H/compress/work"/[a-z]*[0-9].sh "$H/compress/work"/*.state "$H/compress/work"/*.progress
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"

src() {   # OUT [NOISE]  ->  2 s lossless H.264 + AAC
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=2${2:+,noise=alls=60:allf=t+u}" \
        -f lavfi -i "sine=f=440:r=48000:d=2" -c:v libx264 -preset ultrafast -qp 0 -pix_fmt yuv420p \
        -c:a aac -b:a 96k "$1"
}
src "$H/compress/in/Show/Show.S01E01.mkv"
src "$H/compress/in/Show/Show.S01E02.mkv"
src "$H/compress/in/Show/Show.S01E03.mkv" noise

menu() {   # INPUT LOG CONF
    printf "$1" | HOME="$H" PATH="$T/stub:$PATH" COMPRESS_CONF="$3" \
        bash "$H/compress/work/series_compress.sh" > "$2" 2>&1
}

# whole-episode estimates (2 s episodes are sampled whole), counted
est() {   # FILE CRF
    WORK_DIR="$H/compress/work" CRF_SAMPLE_CACHE=0 crf_sample_title "$1" 0 "" "$2" 2 3 && echo "$CRF_SAMPLE_BYTES"
}
s10=$(est "$H/compress/in/Show/Show.S01E01.mkv" 10)
n10=$(est "$H/compress/in/Show/Show.S01E03.mkv" 10)
n11=$(est "$H/compress/in/Show/Show.S01E03.mkv" 11)
n12=$(est "$H/compress/in/Show/Show.S01E03.mkv" 12)
check "noisy E03 is an outlier at CRF 10, still larger at 12" "(( n10 * 4 > s10 * 5 && n12 > s10 && n10 > n11 && n11 > n12 ))"

# ceiling between E03 at CRF 11 and 12: regulars fit at 10, E03 -> 12
ceil=$(awk -v a="$n11" -v b="$n12" 'BEGIN { printf "%.12f", (a + b) / 2 / 1073741824 }')
C1=$(conf_with m1 SERIES_HIGH_CRF_MIN=10 SERIES_HIGH_CRF_MAX=14 "SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=$ceil")
L="$T/m1.log"
menu "1\n2\ny\n" "$L" "$C1"
sed -n '/^Estimating/,$p' "$L" | sed 's/^/  | /'
J=$(ls "$H/compress/work"/series[0-9]*.sh 2>/dev/null | head -n 1)
check "season CRF 10 selected from the regular episodes" "grep -q '^Selected: CRF 10\$' '$L' && grep -q '^Outlier:  S01E03 ' '$L'"
check "outlier sampled at 11, 12 only"       "grep -qE '^  S01E03  CRF 11 +~' '$L' && grep -qE '^  S01E03  CRF 12 +~' '$L' && ! grep -qE '^  S01E0[12]  CRF 1[12]' '$L' && ! grep -q '^CRF 11\$' '$L'"
check "outlier result line"                  "grep -qE '^Outlier:  S01E03 CRF 12 \\(~[0-9.]+ GiB\\); every other episode CRF 10\$' '$L'"
check "table shows the CRF column"           "grep -qE '^Episode +Runtime +CRF +Video' '$L' && grep -qE '^S01E03 +0:02 +12 ' '$L' && grep -qE '^S01E01 +0:02 +10 ' '$L' && grep -q 'OUTLIER (own CRF)' '$L'"
check "confirmation names the own CRF"       "grep -q '^High | CRF 10 (S01E03 CRF 12) | 320x180 | SDR | audio copied\$' '$L'"
check "job: per-episode CRFs"                "[[ -n '$J' ]] && [[ \$(grep -c -- '-crf:v:0 10 ' '$J') == 2 && \$(grep -c -- '-crf:v:0 12 ' '$J') == 1 ]]"
check "job: episodes are items of their own" "! grep -q '^job_batch_add' '$J' && [[ \$(grep -c '^   item_crf_encode item_encode_' '$J') == 3 ]]"
check "job: retry per episode, fit margin, estimates" \
    "[[ \$(grep -c 'crf_min=10 crf_max=14 down_headroom_pct=20 down_max=1 down_fit_pct=5 crf_est=10=[0-9]*' '$J') == 3 ]] && grep -q 'crf=12 .*crf_min=10 crf_max=14 down_headroom_pct=20 down_max=1 down_fit_pct=5 crf_est=10=[0-9]*:11=[0-9]*:12=[0-9]* &&\$' '$J'"
check "menu output compact"                  "! grep -qP '\\t' '$L' && [[ \$(awk 'length > 120' '$L' | grep -c .) == 0 ]]"

# verbose output with the outlier
rm -f "$H/compress/work"/series[0-9]*.sh; rm -rf "$H/compress/out/Show"
L="$T/m1v.log"
COMPRESS_VERBOSE=1 menu "1\n2\nn\n" "$L" "$C1"
check "verbose: season / outlier CRF lines" \
    "grep -q '^  CRF 10 for 2 of 3 episodes (season CRF)\$' '$L' && grep -q '^  CRF 12 for Show.S01E03.mkv (isolated outlier, ~' '$L' && grep -q 'sampling CRF 11, episode 3 (Show.S01E03.mkv)' '$L'"
check "verbose: analysis names the isolated outlier" "grep -q '^    isolated outlier: Show.S01E03.mkv (' '$L' && grep -q -- '-> regular episodes fit; 1 of 3 episode(s) above the ceiling' '$L'"
check "verbose: table and season totals"    "grep -qE '^  Show.S01E03.mkv +0:02 +12 .* OUTLIER: OWN CRF\$' '$L' && grep -q '^  Season CRF: *10 (every episode but Show.S01E03.mkv CRF 12)\$' '$L' && grep -q 'Above ceiling: *0 of 3 episode(s)' '$L'"

# CRF_MAX 11: E03 still above at 11 -> warning, skip this episode
rm -f "$H/compress/work"/series[0-9]*.sh; rm -rf "$H/compress/out/Show"
C2=$(conf_with m2 SERIES_HIGH_CRF_MIN=10 SERIES_HIGH_CRF_MAX=11 "SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=$ceil")
L="$T/m2.log"
menu "1\n2\n2\ny\n" "$L" "$C2"
sed -n '/^------/,/^Select/p' "$L" | sed 's/^/  | /'
J=$(ls "$H/compress/work"/series[0-9]*.sh 2>/dev/null | head -n 1)
check "outlier above at CRF_MAX: warning + prompt" \
    "grep -q 'WARNING: S01E03 cannot meet the .* GiB per-episode video ceiling' '$L' && grep -q 'even CRF 11 (the lowest quality High' '$L' && grep -q '^2) Skip this episode\$' '$L'"
check "skipped: 2 episodes queued at CRF 10" "[[ -n '$J' ]] && [[ \$(grep -c -- '-crf:v:0 10 ' '$J') == 2 ]] && ! grep -q 'Show.S01E03' '$J' && grep -q 'SKIPPED (above ceiling)' '$L'"

# encode anyway: E03 at CRF 11 without a retry (CRF_MAX accepted above)
rm -f "$H/compress/work"/series[0-9]*.sh; rm -rf "$H/compress/out/Show"
L="$T/m3.log"
menu "1\n2\n1\ny\n" "$L" "$C2"
J=$(ls "$H/compress/work"/series[0-9]*.sh 2>/dev/null | head -n 1)
check "encode anyway: E03 at 11, no retry for it" \
    "[[ -n '$J' ]] && grep -q \"crf=11 .*ceiling_vbytes=''\" '$J' && [[ \$(grep -c 'crf=10 .*ceiling_vbytes=[0-9]' '$J') == 2 ]] && grep -q 'ceiling not met' '$L'"

# sample cache: a second run encodes no sample again
rm -f "$H/compress/work"/series[0-9]*.sh; rm -rf "$H/compress/out/Show"
n_cache=$(find "$H/compress/work/cache/crf_samples" -type f | wc -l)
L="$T/m4.log"
menu "1\n2\nn\n" "$L" "$C1"
check "sample cache filled"                  "(( n_cache >= 5 ))"
eq    "second run: no new cached sections"   "$(find "$H/compress/work/cache/crf_samples" -type f | wc -l)" "$n_cache"
check "second run: same choice"              "grep -qE '^Outlier:  S01E03 CRF 12 ' '$L'"

echo
echo "== series menu: source-quality guard of a not-sampled episode (real samples)"

# 4 episodes, 2 sampled (E01 noisy, 3 s = the longest; E04 noisy), so
# E02 / E03 get the noisy (highest) sampled rate. E03 is lossless (far
# above any estimate). E02 is simple content encoded at a bitrate between
# its own estimate and the noisy one: the conservative estimate is not
# below its source, its own sample is.
H2="$T/home2"
mkdir -p "$H2/compress/in/Guard" "$H2/compress/out"
cp -r "$H/compress/work" "$H2/compress/work"
rm -rf "$H2/compress/work/cache"; rm -f "$H2/compress/work"/series[0-9]*.sh
G2="$H2/compress/in/Guard"
gsrc() {   # OUT SECONDS NOISE(0/1) VIDEO_ARGS...
    local out="$1" d="$2" nz="$3"
    shift 3
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=$d$( (( nz )) && echo ',noise=alls=60:allf=t+u')" \
        -f lavfi -i "sine=f=440:r=48000:d=$d" -c:v libx264 -preset ultrafast "$@" -pix_fmt yuv420p \
        -c:a aac -b:a 96k "$out"
}
vbytes() { ffprobe -v error -select_streams v:0 -show_entries packet=size -of csv=p=0 "$1" | awk '{ s += $1 } END { print s + 0 }'; }
gsrc "$G2/Guard.S01E01.mkv" 3 1 -qp 0
gsrc "$G2/Guard.S01E03.mkv" 2 0 -qp 0
gsrc "$G2/Guard.S01E04.mkv" 2 1 -qp 0
s_own=$(est "$G2/Guard.S01E03.mkv" 10)
n_fill=$(est "$G2/Guard.S01E04.mkv" 10)
kbps=$(awk -v a="$s_own" -v b="$n_fill" 'BEGIN { printf "%.0f", sqrt(a * b) * 8 / 2 / 1000 }')
gsrc "$G2/Guard.S01E02.mkv" 2 0 -b:v "${kbps}k" -maxrate "${kbps}k" -bufsize "$((kbps / 2))k"
e2_src=$(vbytes "$G2/Guard.S01E02.mkv")
e2_own=$(est "$G2/Guard.S01E02.mkv" 10)
check "setup: own estimate < E02 source < conservative estimate" "(( e2_own < e2_src && e2_src < n_fill ))"

GC=$(conf_with guard SERIES_HIGH_CRF_MIN=10 SERIES_HIGH_CRF_MAX=14 SERIES_CRF_SAMPLE_EPISODES=2)
gmenu() {   # INPUT LOG
    printf "$1" | HOME="$H2" PATH="$T/stub:$PATH" COMPRESS_CONF="$GC" \
        bash "$H2/compress/work/series_compress.sh" > "$2" 2>&1
}
L="$T/g1.log"
gmenu "1\n2\nn\n" "$L"
sed -n '/^Estimating/,/^Expected sizes/p' "$L" | sed 's/^/  | /'
check "E01 / E04 sampled, E02 not in the batch samples" "grep -qE '^  S01E01  ~' '$L' && grep -qE '^  S01E04  ~' '$L' && ! grep -qE '^  S01E02  ~' '$L'"
check "conservative estimate flagged E02: own sample taken" \
    "grep -q '^Source check (not sampled; estimated at or above the source video):\$' '$L' && [[ \$(grep -cE '^  S01E02  CRF 10 +~' '$L') == 1 ]]"
check "own sample fits: no guard prompt"     "! grep -q 'Source-quality guard' '$L' && ! grep -q 'Select \\[1-3\\]' '$L'"
n_cache=$(find "$H2/compress/work/cache/crf_samples" -type f | wc -l)
L="$T/g2.log"
gmenu "1\n2\nn\n" "$L"
eq    "second run: E02's sample reused from the cache" "$(find "$H2/compress/work/cache/crf_samples" -type f | wc -l)" "$n_cache"
check "second run: still no guard prompt"     "! grep -q 'Source-quality guard' '$L'"

# E02 far below even its own estimate: the guard still asks
gsrc "$G2/Guard.S01E02.mkv" 2 0 -b:v 2k -maxrate 2k -bufsize 1k
e2_src=$(vbytes "$G2/Guard.S01E02.mkv")
e2_own=$(est "$G2/Guard.S01E02.mkv" 10)
check "setup: E02 source below its own estimate" "(( e2_own >= e2_src ))"
L="$T/g3.log"
gmenu "1\n2\n2\nn\n" "$L"
sed -n '/^Source check/,/^Select/p' "$L" | sed 's/^/  | /'
check "own sample still not below: guard asks" \
    "grep -q '^Source check (' '$L' && grep -q '^Source-quality guard: 1 episode(s) are already below what\$' '$L' && grep -qE '^  S01E02 +source .*CRF 10 estimate' '$L'"
check "guessed fit, own sample fits: no ceiling re-check" "! grep -q 'Ceiling check' '$T/g1.log' && ! grep -q 'Ceiling check' '$T/g3.log' && grep -q '^High | CRF 10 | 320x180' '$T/g1.log'"

echo
echo "== series menu: the guard's own sample above the ceiling (real samples)"

# E01 (3 s, longest) / E04 simple lossless: sampled; E03 simple lossless.
# E02: noisy content stored as small x265 CRF 35 HEVC: guessed at the
# simple rate (fits, season CRF 10), its source is below the guess (the
# guard samples it), its own CRF 10 sample is far above the ceiling.
H3="$T/home3"
mkdir -p "$H3/compress/in/Late" "$H3/compress/out"
cp -r "$H/compress/work" "$H3/compress/work"
rm -rf "$H3/compress/work/cache"; rm -f "$H3/compress/work"/series[0-9]*.sh
G3="$H3/compress/in/Late"
gsrc "$G3/Late.S01E01.mkv" 3 0 -qp 0
gsrc "$G3/Late.S01E03.mkv" 2 0 -qp 0
gsrc "$G3/Late.S01E04.mkv" 2 0 -qp 0
ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=2,noise=alls=60:allf=t+u" \
    -f lavfi -i "sine=f=440:r=48000:d=2" -c:v libx265 -preset ultrafast -crf 35 -x265-params log-level=error \
    -pix_fmt yuv420p -c:a aac -b:a 96k "$G3/Late.S01E02.mkv"
g=$(est "$G3/Late.S01E04.mkv" 10)
e2_src=$(vbytes "$G3/Late.S01E02.mkv")
r10=$(est "$G3/Late.S01E02.mkv" 10)
r11=$(est "$G3/Late.S01E02.mkv" 11)
r12=$(est "$G3/Late.S01E02.mkv" 12)
check "setup: E02 source <= guess, own CRF 12 sample > 1.6 x guess" "(( e2_src <= g && r12 * 10 > g * 16 && r10 > r11 && r11 > r12 ))"

# ceiling between E02's own CRF 11 and 12 estimates -> E02 alone to 12
ceil=$(awk -v a="$r11" -v b="$r12" 'BEGIN { printf "%.12f", (a + b) / 2 / 1073741824 }')
LC=$(conf_with late SERIES_HIGH_CRF_MIN=10 SERIES_HIGH_CRF_MAX=14 SERIES_CRF_SAMPLE_EPISODES=2 "SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=$ceil")
lmenu() {   # INPUT LOG CONF
    printf "$1" | HOME="$H3" PATH="$T/stub:$PATH" COMPRESS_CONF="$3" \
        bash "$H3/compress/work/series_compress.sh" > "$2" 2>&1
}
L="$T/l1.log"
lmenu "1\n2\n2\ny\n" "$L" "$LC"
sed -n '/^Selected/,/^Expected sizes/p' "$L" | sed 's/^/  | /'
J=$(ls "$H3/compress/work"/series[0-9]*.sh 2>/dev/null | head -n 1)
check "season CRF 10 from the guessed estimates" "grep -q '^Selected: CRF 10\$' '$L' && ! grep -qE '^  S01E02  ~' '$L'"
check "guard sample, then ceiling re-check of E02" \
    "grep -q '^Source check (' '$L' && grep -q '^Ceiling check (own sample above the ceiling at its CRF):\$' '$L' && grep -qE '^Own CRF:  S01E02 CRF 12 \\(~[0-9.]+ GiB\\); season CRF 10 unchanged\$' '$L'"
check "cache: E02 at CRF 10 encoded once (reused), 11 / 12 once" \
    "[[ \$(grep -cE '^  S01E02  CRF 10 +~[0-9.]+ GiB\$' '$L') == 1 && \$(grep -cE '^  S01E02  CRF 10 +~[0-9.]+ GiB \\(already sampled\\)\$' '$L') == 1 && \$(grep -cE '^  S01E02  CRF 1[12] ' '$L') == 2 ]]"
check "table + confirmation show E02's own CRF" \
    "grep -qE '^S01E02 +0:02 +12 .*OWN CRF \\(own sample\\)' '$L' && grep -q '^High | CRF 10 (S01E02 CRF 12) | 320x180' '$L'"
check "guard decided at CRF 12"              "grep -qE '^  S01E02 +source .*CRF 12 estimate' '$L'"
check "job: E02 at 12 (retry floor = season CRF), the others at 10" \
    "[[ -n '$J' ]] && [[ \$(grep -c -- '-crf:v:0 10 ' '$J') == 3 && \$(grep -c -- '-crf:v:0 12 ' '$J') == 1 ]] && grep -q 'crf=12 .*crf_min=10 crf_max=14 ' '$J'"

# CRF_MAX 11: E02 still above at 11 -> the per-episode prompt; skip it
rm -f "$H3/compress/work"/series[0-9]*.sh; rm -rf "$H3/compress/out/Late"
L="$T/l2.log"
lmenu "1\n2\n2\nn\n" "$L" "$(conf_with late2 SERIES_HIGH_CRF_MIN=10 SERIES_HIGH_CRF_MAX=11 SERIES_CRF_SAMPLE_EPISODES=2 "SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=$ceil")"
sed -n '/^Ceiling check/,/^Expected sizes/p' "$L" | sed 's/^/  | /'
check "CRF_MAX reached: the per-episode over-ceiling prompt" \
    "grep -q 'WARNING: S01E02 cannot meet the .* GiB per-episode video ceiling' '$L' && grep -q 'even CRF 11 (the lowest quality High' '$L' && grep -q '^2) Skip this episode\$' '$L'"
check "skipped: no guard prompt for it, season 10" \
    "! grep -q 'Source-quality guard' '$L' && grep -q 'SKIPPED (above ceiling)' '$L' && grep -q '^Selected: CRF 10\$' '$L' && ! grep -qE '^  S01E02  CRF 12' '$L'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
