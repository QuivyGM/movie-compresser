#!/usr/bin/env bash
# Movie High / Base runtime-scaled video ceiling tests.
#
#   bash ~/compress/work/tests/movie_ceiling_tests.sh
#
# The movie High / Base ceiling is the movie's exact runtime x
# MOVIE_*_VIDEO_GIB_PER_HOUR (binary GiB); the CRF search and the
# post-encode retry use it like the former fixed ceiling. Series keep a
# fixed ceiling per episode and Quality its 18-22 GiB band. Covers:
#   1. config: the active GiB/hour keys of the project config, validation,
#      the former fixed movie ceilings (note), retired keys
#   2. formula: 90 min / 2 h / 3 h, exact bytes, fractional runtimes, no
#      rounding of the runtime, unusable runtimes
#   3. CRF search: crf_select_boundary with the calculated ceiling (stand-in
#      estimator); the menu passes its runtime and that ceiling on
#   4. Series and Quality unchanged
#   5. generated job: ceiling_vbytes = the calculated ceiling, and the
#      post-encode retry checks that same ceiling (ffmpeg with libx265)
# The menu output (menu line, runtime / rate / ceiling while estimating)
# is covered by tests/ui_tests.sh, a menu run by tests/run_tests.sh.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE
source "$SRC_WORK/lib/ui.sh" > /dev/null
for l in media_probe media_stats bitrate encode_common hdr_dovi policy; do
    source "$SRC_WORK/lib/$l.sh"
done

conf_with() {   # NAME KEY=VALUE...  ->  modified copy of the default config ("KEY=" alone: removed)
    local f="$T/conf_$1.conf" kv
    shift
    cp "$SRC_WORK/lib/compress.conf" "$f"
    for kv in "$@"; do
        if [[ "$kv" == *= ]]; then
            sed -i "/^${kv%%=*}=/d" "$f"
            continue
        fi
        sed -i "s|^${kv%%=*}=.*|${kv}|" "$f"
        grep -q "^${kv%%=*}=" "$f" || echo "$kv" >> "$f"
    done
    printf '%s' "$f"
}

export COMPRESS_CONF="$SRC_WORK/lib/compress.conf"
M="$SRC_WORK/movie_compress.sh"

# ------------------------------------------------------------
echo "== 1. config"
check "default compress.conf loads"             "load_policy 2>'$T/load.err'"
check "no notes for the default config"         "[[ ! -s '$T/load.err' ]]"
eq "movie High / Base GiB per hour"             "$MOVIE_HIGH_VIDEO_GIB_PER_HOUR $MOVIE_BASE_VIDEO_GIB_PER_HOUR" "3.5 1.25"
eq "movie High / Base CRF ranges unchanged"     "$MOVIE_HIGH_CRF_SEARCH_MIN $MOVIE_HIGH_CRF_START $MOVIE_HIGH_CRF_MAX / $MOVIE_BASE_CRF_SEARCH_MIN $MOVIE_BASE_CRF_START $MOVIE_BASE_CRF_MAX" \
                                                "10 12 23 / 18 20 29"
check "no fixed movie High / Base ceiling in the config" \
    "! grep -qE '^MOVIE_(HIGH|BASE)_VIDEO_SIZE_CEILING_GIB=' '$SRC_WORK/lib/compress.conf'"
check "movie GiB/hour keys are active (validated), not retired" \
    "[[ ' ${POLICY_KEYS_POSITIVE[*]} ' == *' MOVIE_HIGH_VIDEO_GIB_PER_HOUR '* && ' ${POLICY_KEYS_POSITIVE[*]} ' == *' MOVIE_BASE_VIDEO_GIB_PER_HOUR '* ]] && [[ ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ${POLICY_KEYS_RETIRED[*]} ${POLICY_KEYS_RETIRED_QUALITY[*]} ' != *' MOVIE_HIGH_VIDEO_GIB_PER_HOUR '* && ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ${POLICY_KEYS_RETIRED[*]} ${POLICY_KEYS_RETIRED_QUALITY[*]} ' != *' MOVIE_BASE_VIDEO_GIB_PER_HOUR '* ]]"
check "series GiB/hour keys still retired" \
    "[[ ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ' == *' SERIES_HIGH_VIDEO_GIB_PER_HOUR '* && ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ' == *' SERIES_BASE_VIDEO_GIB_PER_HOUR '* ]]"

f=$(conf_with rate MOVIE_HIGH_VIDEO_GIB_PER_HOUR=4.25 MOVIE_BASE_VIDEO_GIB_PER_HOUR=0.8 MOVIE_BASE_VIDEO_FLOOR_MBPS=1.5)
check "edited GiB/hour: loads without a note"   "( COMPRESS_CONF='$f' load_policy ) 2>'$T/rate.err' && [[ ! -s '$T/rate.err' ]]"
eq "edited GiB/hour used (2 h)" \
    "$( COMPRESS_CONF="$f" load_policy 2>/dev/null; crf_tier_load movie High "" 7200; echo -n "$CRF_CEILING_BYTES "; crf_tier_load movie Base "" 7200; echo "$CRF_CEILING_BYTES" )" \
    "9126805504 1717986918"

reject() {   # LABEL PATTERN KEY=VALUE...
    local label="$1" pat="$2"
    shift 2
    if ( COMPRESS_CONF=$(conf_with "rej$RANDOM" "$@") load_policy ) > "$T/rej.out" 2>&1; then
        bad "rejects $label (was accepted)"
    elif grep -qF -- "$pat" "$T/rej.out"; then
        ok "rejects $label"
    else
        bad "rejects $label (message: $(tr '\n' ' ' < "$T/rej.out"))"
    fi
}
reject "zero High GiB/hour"      'MOVIE_HIGH_VIDEO_GIB_PER_HOUR="0": must be greater than 0' MOVIE_HIGH_VIDEO_GIB_PER_HOUR=0
reject "negative Base GiB/hour"  'MOVIE_BASE_VIDEO_GIB_PER_HOUR="-1": must not be negative' MOVIE_BASE_VIDEO_GIB_PER_HOUR=-1
reject "non-numeric GiB/hour"    'MOVIE_HIGH_VIDEO_GIB_PER_HOUR="3,5": not a number' MOVIE_HIGH_VIDEO_GIB_PER_HOUR=3,5
reject "missing High GiB/hour"   'MOVIE_HIGH_VIDEO_GIB_PER_HOUR is not set' MOVIE_HIGH_VIDEO_GIB_PER_HOUR=
reject "fixed ceiling only (no GiB/hour)" 'MOVIE_BASE_VIDEO_GIB_PER_HOUR is not set' \
    MOVIE_BASE_VIDEO_GIB_PER_HOUR= MOVIE_BASE_VIDEO_SIZE_CEILING_GIB=1.5

# movie Base video floor (CRF mode): active, validated against the ceiling
eq "movie Base floor 2.5 Mb/s, floor CRF limit 14" "$MOVIE_BASE_VIDEO_FLOOR_MBPS $MOVIE_BASE_FLOOR_CRF_MIN" "2.5 14"
check "Base floor key active, Base max key still retired" \
    "[[ ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ' != *' MOVIE_BASE_VIDEO_FLOOR_MBPS '* && ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ' == *' MOVIE_BASE_VIDEO_MAX_MBPS '* ]]"
check "no Base bitrate max in the config (the 1.25 GiB/h ceiling, ~2.98 Mb/s, is below 5)" \
    "! grep -qE '^MOVIE_BASE_VIDEO_MAX_MBPS=' '$SRC_WORK/lib/compress.conf'"
eq "Base ceiling rate in Mb/s (1.25 GiB/h)"      "$(gib_per_hour_mbps 1.25)" "2.983"
check "Base floor below the Base ceiling rate"   "awk -v f='$MOVIE_BASE_VIDEO_FLOOR_MBPS' -v c='$(gib_per_hour_mbps "$MOVIE_BASE_VIDEO_GIB_PER_HOUR")' 'BEGIN { exit !(f < c) }'"
# the former 0.65 / 0.4 GiB/h (~1.55 / ~0.95 Mb/s) cannot coexist with the floor
reject "Base rate 0.65 GiB/h below the 2.5 Mb/s floor" 'MOVIE_BASE_VIDEO_FLOOR_MBPS (2.5) is not below the Base ceiling rate (1.551 Mb/s' MOVIE_BASE_VIDEO_GIB_PER_HOUR=0.65
reject "Base rate 0.4 GiB/h below the 2.5 Mb/s floor"  'MOVIE_BASE_VIDEO_FLOOR_MBPS (2.5) is not below the Base ceiling rate (0.954 Mb/s' MOVIE_BASE_VIDEO_GIB_PER_HOUR=0.4
reject "negative Base floor"     'MOVIE_BASE_VIDEO_FLOOR_MBPS="-1": must not be negative' MOVIE_BASE_VIDEO_FLOOR_MBPS=-1
reject "non-numeric Base floor"  'MOVIE_BASE_VIDEO_FLOOR_MBPS="2,5": not a number' MOVIE_BASE_VIDEO_FLOOR_MBPS=2,5
reject "missing Base floor"      'MOVIE_BASE_VIDEO_FLOOR_MBPS is not set' MOVIE_BASE_VIDEO_FLOOR_MBPS=
reject "missing floor CRF limit" 'MOVIE_BASE_FLOOR_CRF_MIN is not set' MOVIE_BASE_FLOOR_CRF_MIN=
reject "floor CRF limit above SEARCH_MIN" 'MOVIE_BASE_FLOOR_CRF_MIN (19) is greater than MOVIE_BASE_CRF_SEARCH_MIN (18)' MOVIE_BASE_FLOOR_CRF_MIN=19
check "floor 0 (off) loads with any rate" \
    "( COMPRESS_CONF='$(conf_with floor0 MOVIE_BASE_VIDEO_FLOOR_MBPS=0 MOVIE_BASE_VIDEO_GIB_PER_HOUR=0.4)' load_policy ) 2>/dev/null"
f=$(conf_with oldmax MOVIE_BASE_VIDEO_MAX_MBPS=5)
check "former Base 5 Mb/s max: loads, named as ignored" \
    "( COMPRESS_CONF='$f' load_policy ) 2>'$T/oldmax.err' && grep -q 'High/Base size-target' '$T/oldmax.err' && grep -q MOVIE_BASE_VIDEO_MAX_MBPS '$T/oldmax.err' && ! grep -q MOVIE_BASE_VIDEO_FLOOR_MBPS '$T/oldmax.err'"

f=$(conf_with oldceil MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB=7 MOVIE_BASE_VIDEO_SIZE_CEILING_GIB=2)
check "former fixed movie ceilings: still loads" "( COMPRESS_CONF='$f' load_policy ) 2>'$T/oldceil.err'"
check "former fixed movie ceilings: named as ignored" \
    "grep -q 'former fixed movie High/Base video' '$T/oldceil.err' && grep -q MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB '$T/oldceil.err' && grep -q MOVIE_BASE_VIDEO_SIZE_CEILING_GIB '$T/oldceil.err'"
eq "former fixed movie ceilings: no effect (90 min High = 5.25 GiB from 3.5 GiB/h)" \
    "$( COMPRESS_CONF=$(conf_with oldceil2 MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB=99) load_policy 2>/dev/null; crf_tier_load movie High "" 5400; echo "$CRF_CEILING_BYTES" )" "5637144576"
f=$(conf_with oldmbps MOVIE_HIGH_VIDEO_FLOOR_MBPS=6)
check "former movie two-pass floor: still a retired note" \
    "( COMPRESS_CONF='$f' load_policy ) 2>'$T/oldmbps.err' && grep -q 'High/Base size-target' '$T/oldmbps.err' && grep -q MOVIE_HIGH_VIDEO_FLOOR_MBPS '$T/oldmbps.err'"
check "active GiB/hour keys never listed as ignored" \
    "! grep -qE '^ +MOVIE_(HIGH|BASE)_VIDEO_GIB_PER_HOUR\$' '$T/oldmbps.err' '$T/oldceil.err' '$T/load.err'"
load_policy 2>/dev/null

# ------------------------------------------------------------
echo
echo "== 2. formula: ceiling = runtime hours x GiB/hour (1 GiB = 1073741824 bytes)"
ceil_of() {   # TIER SECONDS  ->  "BYTES GIB"
    crf_tier_load movie "$1" "" "$2" || { echo fail; return; }
    echo "$CRF_CEILING_BYTES $CRF_CEILING_GIB"
}
eq "High  90 min -> 5.25 GiB"   "$(ceil_of High 5400)"  "5637144576 5.25"
eq "High 120 min -> 7.00 GiB"   "$(ceil_of High 7200)"  "7516192768 7.00"
eq "High 180 min -> 10.50 GiB"  "$(ceil_of High 10800)" "11274289152 10.50"
eq "Base  90 min -> 1.875 GiB"  "$(ceil_of Base 5400)"  "2013265920 1.88"
eq "Base 1h40m -> ~2.083 GiB"   "$(ceil_of Base 6000)"  "2236962133 2.08"
eq "Base 120 min -> 2.50 GiB"   "$(ceil_of Base 7200)"  "2684354560 2.50"
eq "Base 2h30m -> 3.125 GiB (exact bytes)" "$(ceil_of Base 9000)" "3355443200 3.12"
eq "Base 180 min -> 3.75 GiB"   "$(ceil_of Base 10800)" "4026531840 3.75"
eq "Base 3h30m (long runtime) -> 4.375 GiB" "$(ceil_of Base 12600)" "4697620480 4.38"
check "Base ceiling bytes exact: 2 h = 2.5 x 1073741824" "[[ $(ceil_of Base 7200 | cut -d' ' -f1) == $((5 * 1073741824 / 2)) ]]"
# the video floor: decimal Mb/s x runtime (video only)
floor_of() { crf_tier_load movie "$1" "" "$2" || { echo fail; return; }; echo "$CRF_FLOOR_BYTES [$CRF_FLOOR_MBPS] [$CRF_FLOOR_CRF_MIN]"; }
eq "Base floor 1h40m: 2.5 Mb/s -> 1875000000 bytes" "$(floor_of Base 6000)"  "1875000000 [2.5] [14]"
eq "Base floor 2 h"                               "$(floor_of Base 7200)"  "2250000000 [2.5] [14]"
eq "Base floor 2h30m"                             "$(floor_of Base 9000)"  "2812500000 [2.5] [14]"
eq "Base floor 3h30m (scales with the runtime)"   "$(floor_of Base 12600)" "3937500000 [2.5] [14]"
eq "Base floor is below the ceiling (2 h, Mb/s)"  "$(bytes_to_mbps 2250000000 7200) < $(bytes_to_mbps 2684354560 7200)" "2.50 < 2.98"
eq "High: no floor"                               "$(floor_of High 7200)"  "0 [] []"
eq "series Base: no floor"                        "$(crf_tier_load series Base "" 7200; echo "$CRF_FLOOR_BYTES [$CRF_FLOOR_MBPS]")" "0 []"
eq "Quality / Custom: no floor"                   "$(crf_tier_load movie Quality; echo -n "$CRF_FLOOR_BYTES "; crf_tier_load movie Custom 21 7200; echo "$CRF_FLOOR_BYTES")" "0 0"
eq "Base without runtime: no floor bytes yet"     "$(floor_of Base '')" "0 [2.5] [14]"
eq "movie_floor_bytes 0 = off"                    "$(movie_floor_bytes 0 7200)" "0"
check "movie_floor_bytes refuses a bad runtime"   "! movie_floor_bytes 2.5 0 && ! movie_floor_bytes 2.5 N/A && ! movie_floor_bytes x 7200"
eq "exact bytes: 7 x 1073741824" "$(movie_ceiling_bytes 3.5 7200)" "$((7 * 1073741824))"
# exact values (rational arithmetic, rounded to a whole byte at the end)
eq "fractional runtime High 7262.458 s"        "$(movie_ceiling_bytes 3.5 7262.458)" "7581393652"
eq "fractional runtime Base 5423.417 s"        "$(movie_ceiling_bytes 1.0 5423.417)" "1617597128"
eq "fractional runtime High 6543.21 s"         "$(movie_ceiling_bytes 3.5 6543.21)"  "6830559400"
eq "runtime not rounded: 7199 s < 7 GiB"        "$(movie_ceiling_bytes 3.5 7199)"     "7515148852"
eq "ffprobe-style duration (7200.000000)"       "$(ceil_of High 7200.000000)"         "7516192768 7.00"
eq "CRF_GIB_PER_HOUR set for the menu"          "$(crf_tier_load movie Base "" 7200; echo "$CRF_GIB_PER_HOUR")" "1.25"
eq "no runtime: rate only, no ceiling"          "$(crf_tier_load movie High; echo "[$CRF_GIB_PER_HOUR][$CRF_CEILING_BYTES][$CRF_CEILING_GIB]")" "[3.5][][]"
for d in N/A 0 -5 abc; do
    check "unusable runtime \"$d\": refused"     "! ( crf_tier_load movie High '' '$d' ) 2>/dev/null"
done
check "unusable runtime: no ceiling left set" "( crf_tier_load movie High '' N/A 2>/dev/null; [[ -z \$CRF_CEILING_BYTES ]] )"
eq "tiny ceiling: at least 1 byte (0 would mean no ceiling)" "$(movie_ceiling_bytes 0.000000001 2)" "1"
check "movie_ceiling_bytes refuses a bad rate"  "! movie_ceiling_bytes 0 7200 && ! movie_ceiling_bytes x 7200"

# ------------------------------------------------------------
echo
echo "== 3. CRF search with the calculated ceiling"
# stand-in estimator: video bytes per CRF = a bitrate per CRF x runtime
declare -A RATE=([10]=3.8 [11]=3.2 [12]=2.6 [13]=2.2 [14]=1.9 [15]=1.6)   # GiB per hour
EST_DUR=0
CALLS=()
rate_est() {
    CALLS+=("$1")
    CRF_EST_RESULT=$(awk -v r="${RATE[$1]:-0.5}" -v d="$EST_DUR" 'BEGIN { printf "%.0f", r * 1073741824 * d / 3600 }')
}
sel() {   # TIER SECONDS  ->  crf_select_boundary as the menu runs it
    EST_DUR="$2"
    CALLS=()
    crf_tier_load movie "$1" "" "$2"
    crf_select_boundary "$CRF_START" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" rate_est
    echo "$CRF_SELECTED/${CRF_BOUNDARY_LOW:-none}/${CALLS[*]}"
}
# RATE in GiB/hour vs the High ceiling of 3.5 GiB/hour: the same CRF
# (11, CRF 10 above it) at every runtime, since both scale with it
eq "High 90 min: CRF 11 (10 over)"   "$(sel High 5400)"  "11/10/12 11 10"
eq "High 2 h: same CRF 11"           "$(sel High 7200)"  "11/10/12 11 10"
eq "High 3 h: same CRF 11"           "$(sel High 10800)" "11/10/12 11 10"
# a FIXED estimate (6 GiB at CRF 12): fits the 2 h ceiling (7 GiB) but
# not the 90 min ceiling (5.25 GiB)
fixed_est() { CALLS+=("$1"); CRF_EST_RESULT=$(( (13 - $1) * 1073741824 + 5 * 1073741824 )); }
fsel() {
    CALLS=()
    crf_tier_load movie High "" "$1"
    crf_select_boundary "$CRF_START" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" fixed_est
    echo "$CRF_SELECTED/${CRF_BOUNDARY_LOW:-none}/$CRF_SEARCH_DIR"
}
eq "fixed 6 GiB at CRF 12: 2 h ceiling 7 GiB -> down to 11 (7 GiB fits, 10 over)" "$(fsel 7200)" "11/10/down"
eq "fixed 6 GiB at CRF 12: 90 min ceiling 5.25 GiB -> up to 13"                   "$(fsel 5400)" "13/12/up"
eq "fixed 6 GiB at CRF 12: 3 h ceiling 10.5 GiB -> SEARCH_MIN 10"                 "$(fsel 10800)" "10/none/down"
# adaptive +2 step: relative to the calculated ceiling (150 %)
declare -A RATE=([12]=6 [13]=5.5 [14]=3.4 [15]=3.0)
eq "+2 step above 150 % of the calculated ceiling (12 -> 14, 13 checked)" "$(sel High 5400)" "14/13/12 14 13"

check "menu: crf_tier_load gets the movie's runtime" \
    "grep -qF 'crf_tier_load movie \"\$TIER\" \"\$CUSTOM_CRF\" \"\$DURATION\"' '$M'"
check "menu: High / Base search uses CRF_CEILING_BYTES" \
    "grep -qF 'crf_select_boundary \"\$CRF_START\" \"\$CRF_MIN\" \"\$CRF_MAX\" \"\$CRF_CEILING_BYTES\" crf_title_estimate' '$M'"
check "menu: High / Base retry spec carries CRF_CEILING_BYTES" \
    "grep -qF '[[ \"\$TIER\" != \"Custom\" ]] && RETRY_SPEC=\"\$CRF_CEILING_BYTES:' '$M'"
check "menu: verbose policy reload keeps the runtime" \
    "grep -qF 'crf_policy_lines movie \"\$TIER\" \"\$CUSTOM_CRF\" \"\$DURATION\"' '$M'"
check "menu: no runtime -> movie not queued" \
    "grep -q 'no \$TIER video ceiling; nothing queued for this movie' '$M'"
check "no two-pass bitrate from the GiB/hour rate" \
    "! grep -qE 'gib_per_hour_to_kbps|bitrate_for_gib|-b:v' '$M' && ! grep -qE 'gib_per_hour_to_kbps|bitrate_for_gib' '$SRC_WORK/lib/policy.sh'"

# ------------------------------------------------------------
echo
echo "== 3b. Base video floor in the CRF search (2 h: ceiling 2.98 Mb/s, floor 2.5 Mb/s)"
# stand-in estimator in Mb/s per CRF (video only)
declare -A MB=()
mb_est() {
    CALLS+=("$1")
    CRF_EST_RESULT=$(awk -v r="${MB[$1]:-0.5}" -v d="$EST_DUR" 'BEGIN { printf "%.0f", r * 1000000 / 8 * d }')
}
mbps_bytes() { awk -v r="$1" 'BEGIN { printf "%.0f", r * 1000000 / 8 * 7200 }'; }
# base_sel SOURCE_VIDEO_BYTES [ESTIMATOR]  ->  as the menu runs Base:
# tier load, source exemption, boundary search, floor
base_sel() {
    EST_DUR=7200
    CALLS=()
    crf_tier_load movie Base "" 7200
    movie_floor_source_exempt "$CRF_FLOOR_BYTES" "$1" && CRF_FLOOR_BYTES=0
    crf_select_boundary "$CRF_START" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" "${2:-mb_est}"
    crf_floor_extend "$CRF_FLOOR_BYTES" "$CRF_FLOOR_CRF_MIN" "$CRF_CEILING_BYTES"
    echo "$CRF_SELECTED/$CRF_FLOOR_STATUS/$(bytes_to_mbps "${CRF_EST[$CRF_SELECTED]}" 7200)/${CALLS[*]}"
}
SRC20=$(mbps_bytes 20)
MB=([20]=2.7 [19]=3.1)
eq "normal: lowest CRF that fits, above the floor (19 over)" "$(base_sel "$SRC20")" "20/ok/2.70/20 19"
MB=([20]=3.5 [21]=2.9 [22]=2.4)
eq "start above the ceiling: upward, lowest fitting CRF 21" "$(base_sel "$SRC20")" "21/ok/2.90/20 21"
# the observed regression: a 20 Mb/s source that compresses very easily
EASY=([20]=1.1 [19]=1.2 [18]=1.4 [17]=1.65 [16]=1.95 [15]=2.3 [14]=2.7)
MB=(); for k in "${!EASY[@]}"; do MB[$k]=${EASY[$k]}; done
r=$(base_sel "$SRC20")
check "easy 20 Mb/s source: CRF 18 at 1.4 Mb/s is NOT accepted" "[[ '$r' != 18/ok/* && '$r' != 18/off/* ]]"
eq "easy source: below SEARCH_MIN one CRF at a time until the floor (14, 2.7 Mb/s)" "$r" "14/extended/2.70/20 19 18 17 16 15 14"
MB[14]=2.4
eq "easy source: FLOOR_CRF_MIN 14 still below -> limit (menu asks)" "$(base_sel "$SRC20")" "14/limit/2.40/20 19 18 17 16 15 14"
MB=([20]=1.1 [19]=1.2 [18]=1.4 [17]=2.2 [16]=3.2)
eq "extension stops at the ceiling: 16 over -> 17 kept below the floor (gap)" "$(base_sel "$SRC20")" "17/gap/2.20/20 19 18 17 16"
eq "  gap: CRF_BOUNDARY_LOW is the CRF above the ceiling" "$(base_sel "$SRC20" > /dev/null; echo "$CRF_BOUNDARY_LOW")" "16"
MB=([20]=2.4 [19]=3.1)
eq "gap inside the range: 20 below the floor, 19 over the ceiling" "$(base_sel "$SRC20")" "20/gap/2.40/20 19"
MB=([20]=4 [21]=3.8 [22]=3.6 [23]=3.5 [24]=3.4 [25]=3.3 [26]=3.2 [27]=3.1 [28]=3.05 [29]=3.0)
eq "over the ceiling at CRF_MAX: floor not involved" "$(base_sel "$SRC20")" "29/ok/3.00/20 21 22 23 24 25 26 27 28 29"
# source-below-floor exception: the SOURCE VIDEO bitrate decides
MB=(); for k in "${!EASY[@]}"; do MB[$k]=${EASY[$k]}; done
eq "source video 2.0 Mb/s: exempt, never pushed toward 2.5" "$(base_sel "$(mbps_bytes 2.0)")" "18/off/1.40/20 19 18"
eq "source video exactly 2.5 Mb/s: floor enforced" "$(base_sel "$(mbps_bytes 2.5)" | cut -d/ -f1-2)" "14/extended"
eq "source video unknown: floor enforced"          "$(base_sel "" | cut -d/ -f1-2)" "14/extended"
check "exempt compares VIDEO bytes: 2.0 Mb/s video + 1.5 Mb/s audio (3.5 total) is exempt" \
    "movie_floor_source_exempt $(mbps_bytes 2.5) $(mbps_bytes 2.0) && ! movie_floor_source_exempt $(mbps_bytes 2.5) $(mbps_bytes 3.5)"
check "menu: exemption uses SOURCE_VIDEO_BYTES (main video stream), not total / audio" \
    "grep -qF 'movie_floor_source_exempt \"\$CRF_FLOOR_BYTES\" \"\$SOURCE_VIDEO_BYTES\"' '$M' && grep -qF 'read -r SOURCE_VIDEO_BYTES SOURCE_AUDIO_BYTES _ _ <<< \"\$(stats_totals \"\$VIDX\")\"' '$M'"
# cached actual results replace the estimate of exactly their CRF
mkdir -p "$T/cw"
CRF_ACTUAL_SIG="v1|stat=1 1|test-floor"
declare -gA CRF_ACTUAL_HIT=()
( WORK_DIR="$T/cw" crf_actual_save "$CRF_ACTUAL_SIG" 17 "$(mbps_bytes 2.6)" )
r=$( crf_title_estimate() { mb_est "$1"; }; WORK_DIR="$T/cw" base_sel "$SRC20" crf_title_estimate_actual | tail -n 1 )
eq "cached actual CRF 17 (2.6 Mb/s) reaches the floor; 17 not sampled" "$r" "17/extended/2.60/20 19 18"
unset CRF_ACTUAL_SIG
# menu wiring
check "menu: Base runs crf_floor_extend after the boundary search" \
    "grep -qF 'crf_floor_extend \"\$CRF_FLOOR_BYTES\" \"\$CRF_FLOOR_CRF_MIN\" \"\$CRF_CEILING_BYTES\"' '$M'"
check "menu: gap / limit asks (never accepted silently)" \
    "grep -qF 'if [[ \"\$CRF_FLOOR_STATUS\" == gap || \"\$CRF_FLOOR_STATUS\" == limit ]]; then' '$M' && grep -qF 'Base video floor' '$M'"
check "menu: Base retry spec walks down (CRF_LIMIT) and carries the floor" \
    "grep -qF 'RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:0:\$CRF_LIMIT:::boundary:\$CRF_FLOOR_BYTES:\$CRF_FLOOR_CRF_MIN\"' '$M'"
check "menu: High retry spec unchanged (one CRF - 1 test, no floor)" \
    "grep -qF '[[ \"\$TIER\" != \"Custom\" ]] && RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:0:1:::boundary\"' '$M'"
# tier isolation: only movie Base has a floor / the Base rate
for t in High Quality Custom Compact; do
    if ( crf_tier_load movie "$t" 21 7200 ) 2>/dev/null; then
        eq "movie $t: no Base floor, own size policy" \
            "$(crf_tier_load movie "$t" 21 7200; echo "[$CRF_FLOOR_BYTES][$CRF_FLOOR_MBPS][$CRF_FLOOR_CRF_MIN] $( [[ "$CRF_GIB_PER_HOUR" == "$MOVIE_BASE_VIDEO_GIB_PER_HOUR" ]] && echo base-rate || echo own-rate)")" \
            "[0][][] own-rate"
    else
        ok "movie $t: not a movie CRF tier here (rejected), so no Base floor"
    fi
done
eq "loading Base first does not leak into High" \
    "$(crf_tier_load movie Base "" 7200; crf_tier_load movie High "" 7200; echo "$CRF_GIB_PER_HOUR [$CRF_FLOOR_BYTES][$CRF_FLOOR_MBPS][$CRF_FLOOR_CRF_MIN]")" "3.5 [0][][]"
eq "loading High first does not change Base" \
    "$(crf_tier_load movie High "" 7200; crf_tier_load movie Base "" 7200; echo "$CRF_GIB_PER_HOUR $CRF_FLOOR_BYTES")" "1.25 2250000000"
MB=(); for k in "${!EASY[@]}"; do MB[$k]=${EASY[$k]}; done
eq "no floor (any tier but Base): crf_floor_extend estimates nothing" \
    "$(CALLS=(); EST_DUR=7200; crf_tier_load movie High "" 7200; crf_select_boundary 20 18 29 "$(movie_ceiling_bytes 1.25 7200)" mb_est; n=${#CALLS[@]}; crf_floor_extend "$CRF_FLOOR_BYTES" "$CRF_FLOOR_CRF_MIN" 1; echo "$CRF_SELECTED/$CRF_FLOOR_STATUS/$(( ${#CALLS[@]} - n ))")" "18/off/0"
check "menu: floor step only for TIER == Base (one call site)" \
    "grep -qF 'if [[ -n \"\$CRF_SELECTED\" && \"\$TIER\" == Base ]]; then' '$M' && [[ \$(grep -c 'crf_floor_extend ' '$M') == 1 ]]"
eq "audio Compact settings independent of the Base floor / rate" \
    "$( COMPRESS_CONF=$(conf_with iso MOVIE_BASE_VIDEO_FLOOR_MBPS=0 MOVIE_BASE_VIDEO_GIB_PER_HOUR=2) load_policy 2>/dev/null; echo "$AUDIO_COMPACT_TRIGGER_GIB $AUDIO_COMPACT_LIMIT_GIB $(audio_menu_compact_kbps 6)" )" \
    "$AUDIO_COMPACT_TRIGGER_GIB $AUDIO_COMPACT_LIMIT_GIB $(audio_menu_compact_kbps 6)"
PB=$(crf_policy_lines movie Base '' 7200; movie_policy_line Base 7200)
PH=$(crf_policy_lines movie High '' 7200; movie_policy_line High 7200)
check "Base policy text names the floor; High's does not" \
    "grep -q '^  video floor: 2.5 Mb/s average' <<< \"\$PB\" && grep -q -- '-> 2.10 GiB video floor\$' <<< \"\$PB\" && grep -q 'video floor 2.5 Mb/s (CRF down to 14' <<< \"\$PB\" && ! grep -q floor <<< \"\$PH\""
load_policy 2>/dev/null

# ------------------------------------------------------------
echo
echo "== 4. series and Quality unchanged"
eq "series values in the config" \
    "$SERIES_HIGH_CRF_SEARCH_MIN $SERIES_HIGH_CRF_START $SERIES_HIGH_CRF_MAX $SERIES_HIGH_VIDEO_SIZE_CEILING_GIB / $SERIES_BASE_CRF_SEARCH_MIN $SERIES_BASE_CRF_START $SERIES_BASE_CRF_MAX $SERIES_BASE_VIDEO_SIZE_CEILING_GIB" \
    "8 15 21 5 / 11 18 27 1.5"
for d in "" 1200 5400; do
    eq "series High fixed 5 GiB/episode (runtime \"$d\" ignored)" \
        "$(crf_tier_load series High "" "$d"; echo "$CRF_CEILING_GIB $CRF_CEILING_BYTES [$CRF_GIB_PER_HOUR]")" "5 5368709120 []"
    eq "series Base fixed 1.5 GiB/episode (runtime \"$d\" ignored)" \
        "$(crf_tier_load series Base "" "$d"; echo "$CRF_CEILING_GIB $CRF_CEILING_BYTES [$CRF_GIB_PER_HOUR]")" "1.5 1610612736 []"
done
check "series policy lines: fixed per-episode ceiling, no GiB/hour" \
    "crf_policy_lines series High | grep -q '^  video ceiling: 5 GiB/episode\$' && ! { crf_policy_lines series High; crf_policy_lines series Base; } | grep -qi 'per hour'"
check "series menu does not pass a runtime to crf_tier_load" \
    "! grep -E 'crf_tier_load series' '$SRC_WORK/series_compress.sh' | grep -q DUR"
eq "Quality band / CRF in the config" \
    "$MOVIE_QUALITY_TARGET_VIDEO_GIB $MOVIE_QUALITY_ACCEPT_MIN_GIB $MOVIE_QUALITY_ACCEPT_MAX_GIB / $MOVIE_QUALITY_CRF_MIN $MOVIE_QUALITY_CRF_START $MOVIE_QUALITY_CRF_MAX" \
    "20 18 22 / 0 8 23"
for d in "" 5400 10800; do
    eq "Quality ceiling = band max 22 GiB (runtime \"$d\" ignored)" \
        "$(crf_tier_load movie Quality "" "$d"; echo "$CRF_MIN $CRF_START $CRF_MAX $CRF_CEILING_GIB $CRF_CEILING_BYTES [$CRF_GIB_PER_HOUR]")" "0 8 23 22 23622320128 []"
done
check "Quality policy text has no GiB/hour" \
    "! { crf_policy_lines movie Quality; movie_policy_line Quality; } | grep -qi 'per hour\\|GiB/h'"
eq "Custom: no ceiling, no rate" \
    "$(crf_tier_load movie Custom 21 7200; echo "$CRF_MIN $CRF_MAX [$CRF_CEILING_BYTES] [$CRF_GIB_PER_HOUR]")" "21 21 [0] []"

# ------------------------------------------------------------
echo
echo "== 5. generated job and post-encode retry use the calculated ceiling"
if ! command -v ffmpeg >/dev/null || [[ "$(ffmpeg -hide_banner -encoders 2>/dev/null)" != *libx265* ]]; then
    echo "  (ffmpeg with libx265 not found: skipped)"
else
    W="$T/work"
    mkdir -p "$W/logs" "$T/in" "$T/out" "$T/stub"
    cp -r "$SRC_WORK/lib" "$W/"
    printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
    chmod +x "$T/stub/tmux"
    export PATH="$T/stub:$PATH"
    WORK_DIR="$W"
    source "$W/lib/job_runtime.sh"
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=2" -f lavfi -i "sine=f=440:r=48000:d=2" \
        -c:v libx264 -preset ultrafast -qp 0 -c:a aac -b:a 96k "$T/in/M.mkv"
    DUR=$(get_duration "$T/in/M.mkv" | tr -d '\r')

    # a tiny rate: every CRF of a short tier range is above the ceiling,
    # so the retry walks up to CRF_MAX against that ceiling
    COMPRESS_CONF=$(conf_with job MOVIE_HIGH_VIDEO_GIB_PER_HOUR=0.0001 MOVIE_HIGH_CRF_SEARCH_MIN=21 \
        MOVIE_HIGH_CRF_START=21 MOVIE_HIGH_CRF_MAX=22)
    load_policy 2>/dev/null
    crf_tier_load movie High "" "$DUR"
    CB="$CRF_CEILING_BYTES"
    eq "job ceiling = runtime x rate" "$CB" "$(awk -v d="$DUR" 'BEGIN { printf "%.0f", 0.0001 * 1073741824 * d / 3600 }')"
    # the RETRY spec as movie_compress.sh builds it for High / Base
    RETRY_SPEC="$CRF_CEILING_BYTES:$CRF_MAX:$CRF_MIN:0:1:::boundary"
    DV_POLICY=none HDR10P_POLICY=none
    { emit_job_header j1 movie 1
      emit_encode_item 1 "$T/in/M.mkv" "$T/out/M.mkv" High crf:21 "" "" 0 1000 "$RETRY_SPEC"
      emit_job_footer; } > "$W/j1.sh"
    check "generated job: ceiling_vbytes = calculated ceiling" \
        "grep -q 'mode=crf crf=21 .*ceiling_vbytes=$CB crf_min=21 crf_max=22 ' '$W/j1.sh'"
    check "generated job: single-pass CRF, no two-pass" \
        "grep -q -- '-crf:v:0 21 ' '$W/j1.sh' && ! grep -qE -- '-b:v|pass=[12]|stats=' '$W/j1.sh'"
    bash "$W/j1.sh" < /dev/null > "$T/j1.log" 2>&1
    check "retry: CRF 21 over the calculated ceiling -> CRF 22" \
        "grep -q '^Result: over ceiling -> retrying CRF 22\$' '$T/j1.log' && grep -q 'Result: over ceiling; CRF 22 is the High limit' '$T/j1.log'"
    eq "retry: every attempt checked against that ceiling (estimate log)" \
        "$(awk -F'\t' '$9 == "j1" { print $3 ":" $11 }' "$W/logs/crf_estimates.tsv" | tr '\n' ' ')" "21:$CB 22:$CB "
    load_policy 2>/dev/null
fi

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
