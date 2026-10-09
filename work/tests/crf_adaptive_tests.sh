#!/usr/bin/env bash
# Bracket-and-refine CRF search (policy.sh crf_search_up) for movie
# Quality (upward), movie High / Base, series High / Base, the isolated
# outlier's own CRF and the late guard-sample ceiling check: +2 while the
# estimate is far above the ceiling (CRF_ADAPTIVE_STEP_THRESHOLD_PCT),
# +1 otherwise, never above CRF_MAX; the CRF just below the chosen one is
# always estimated above the ceiling; a skipped CRF is left out only when
# the data of the next CRF proves it too large (series season: own
# samples of sampled episodes only, series_crf_certify_over), otherwise
# it is estimated. The CRF chosen is
# the one the sequential CRF_MIN, CRF_MIN + 1, ... search chooses.
#
#   bash ~/compress/work/tests/crf_adaptive_tests.sh
#
# No ffmpeg needed: stand-in estimators and sample encodes. Covers:
#   1. config: CRF_ADAPTIVE_STEP_THRESHOLD_PCT default and validation
#   2. step size (+2 far above, +1 near, threshold 0 = always +1)
#   3. search: jumps, CRF_MAX clamp, boundary refinement (skipped CRF
#      too large / fits), back-fill of unproven skips (CRF + 1 fits,
#      CRF + 2 too large), failures, Custom exact
#   4. randomized tables: monotonic (single title) and arbitrary
#      (unproven skips) -> same CRF as the sequential search
#   5. movie High / Base / Quality, compact output
#   6. series High / Base season CRF: certification, outlier
#      reclassification (non-monotonic season), randomized seasons,
#      isolated outlier, two or more difficult episodes, late ceiling
#      check, compact output
#   7. sample cache: nothing encoded twice, refinement reuses the cache
#   8. estimate rounds before / after
#   9. set -euo pipefail
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
G=1073741824
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }

WORK_DIR="$T/work"
mkdir -p "$WORK_DIR"
cp -r "$SRC_WORK/lib" "$WORK_DIR/"
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do
    source "$WORK_DIR/lib/$l.sh" > /dev/null
done

conf_with() {   # NAME KEY=VALUE...  ->  modified copy of the project config
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
COMPRESS_CONF=$(conf_with base \
    MOVIE_QUALITY_TARGET_VIDEO_GIB=20 MOVIE_QUALITY_ACCEPT_MIN_GIB=18 MOVIE_QUALITY_ACCEPT_MAX_GIB=22 \
    MOVIE_QUALITY_CRF_MIN=0 MOVIE_QUALITY_CRF_START=8 MOVIE_QUALITY_CRF_MAX=23 \
    MOVIE_HIGH_CRF_SEARCH_MIN=12 MOVIE_HIGH_CRF_START=12 MOVIE_HIGH_CRF_MAX=23 MOVIE_HIGH_VIDEO_GIB_PER_HOUR=3.5 \
    MOVIE_BASE_CRF_SEARCH_MIN=20 MOVIE_BASE_CRF_START=20 MOVIE_BASE_CRF_MAX=29 MOVIE_BASE_VIDEO_GIB_PER_HOUR=1.0 \
    SERIES_HIGH_CRF_SEARCH_MIN=10 SERIES_HIGH_CRF_START=10 SERIES_HIGH_CRF_MAX=21 SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=5 \
    SERIES_BASE_CRF_SEARCH_MIN=13 SERIES_BASE_CRF_START=13 SERIES_BASE_CRF_MAX=27 SERIES_BASE_VIDEO_SIZE_CEILING_GIB=1.5 \
    SERIES_CRF_OUTLIER_PCT=25 SERIES_CRF_SAMPLE_EPISODES=4 CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150)
export COMPRESS_CONF
load_policy > /dev/null

# ------------------------------------------------------------
echo "== 1. config"

check "project config: CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150" \
    "grep -qx 'CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150' '$SRC_WORK/lib/compress.conf'"
check "project config loads"            "COMPRESS_CONF='$SRC_WORK/lib/compress.conf' load_policy 2>/dev/null"
grep -v '^CRF_ADAPTIVE_STEP_THRESHOLD_PCT=' "$COMPRESS_CONF" > "$T/miss.conf"
check "missing: named, menu stops"      "! COMPRESS_CONF='$T/miss.conf' load_policy 2>'$T/miss.err' && grep -q 'CRF_ADAPTIVE_STEP_THRESHOLD_PCT is not set' '$T/miss.err'"
for v in 99 1 1.5 -150 abc ""; do
    check "\"$v\" rejected"             "! COMPRESS_CONF='$(conf_with "r$RANDOM" "CRF_ADAPTIVE_STEP_THRESHOLD_PCT=$v")' load_policy 2>'$T/rej.err' && grep -q 'CRF_ADAPTIVE_STEP_THRESHOLD_PCT=' '$T/rej.err'"
done
for v in 0 100 150 300; do
    check "$v accepted"                 "COMPRESS_CONF='$(conf_with "a$v" "CRF_ADAPTIVE_STEP_THRESHOLD_PCT=$v")' load_policy 2>/dev/null"
done
load_policy > /dev/null
eq "test config: threshold 150"         "$CRF_ADAPTIVE_STEP_THRESHOLD_PCT" 150

# ------------------------------------------------------------
echo
echo "== 2. step size"

eq "2.5 x ceiling: +2"                  "$(crf_adaptive_step 250 100)" 2
eq "1.51 x ceiling: +2"                 "$(crf_adaptive_step 151 100)" 2
eq "exactly 1.5 x ceiling: +1"          "$(crf_adaptive_step 150 100)" 1
eq "1.2 x ceiling: +1"                  "$(crf_adaptive_step 120 100)" 1
eq "real sizes: 13.05 vs 5 GiB: +2"     "$(crf_adaptive_step "$(gib 13.05)" "$(gib 5)")" 2
eq "never more than +2 (10 x)"          "$(crf_adaptive_step 1000 100)" 2
eq "threshold 0: always +1"             "$(CRF_ADAPTIVE_STEP_THRESHOLD_PCT=0 crf_adaptive_step 900 100)" 1
eq "threshold unset: +1"                "$(unset CRF_ADAPTIVE_STEP_THRESHOLD_PCT; crf_adaptive_step 900 100)" 1
eq "threshold 200: 1.8 x -> +1"         "$(CRF_ADAPTIVE_STEP_THRESHOLD_PCT=200 crf_adaptive_step 180 100)" 1

# ------------------------------------------------------------
echo
echo "== 3. search (stand-in estimator, GiB per CRF)"

declare -A EST=()
CALLS=()
STEPS=()
fake_est() {   # ESTIMATOR: EST[crf] GiB; "fail" = sample encode error
    CALLS+=("$1")
    [[ "${EST[$1]:-}" == fail ]] && return 1
    CRF_EST_RESULT=$(gib "${EST[$1]:-0.01}")
}
est() { EST=(); local kv; for kv in "$@"; do EST[${kv%%=*}]="${kv#*=}"; done; }
rec() { local s="$*"; STEPS+=("${s% }"); }   # REPORT recorder
steps() { local IFS='|'; printf '%s' "${STEPS[*]}"; }
unproven() { return 1; }                      # CERTIFY: never proves a skip
run() {   # MIN MAX CEILING_GIB [CERTIFY]  ->  crf_select over EST
    CALLS=(); STEPS=()
    crf_select "$1" "$2" "$(gib "$3")" fake_est rec "${4:-}"
}
# seq_ref MIN MAX CEILING_GIB  ->  "CRF/OVER/ROUNDS" of the sequential
# CRF + 1 search over EST (the behaviour before the adaptive search)
seq_ref() {
    local c n=0 ceil
    ceil=$(gib "$3")
    for ((c = $1; c <= $2; c++)); do
        ((n += 1))
        if (( $(gib "${EST[$c]:-0.01}") <= ceil )); then
            echo "$c/0/$n"
            return
        fi
    done
    echo "$2/1/$n"
}
# low_ok  ->  0 when the boundary below CRF_SELECTED was estimated above
# the ceiling (CRF_BOUNDARY_LOW = CRF_SELECTED - 1, in CRF_TRIED)
low_ok() {
    [[ "$CRF_BOUNDARY_LOW" == "$((CRF_SELECTED - 1))" && -n "${CRF_EST[$CRF_BOUNDARY_LOW]+x}" ]] &&
        (( CRF_EST[$CRF_BOUNDARY_LOW] > $1 ))
}

# the example from the request: 13.05 / 8.90 / 4.80 GiB, skipped 13 too large
est 10=13.05 11=10.9 12=8.90 13=5.40 14=4.80 15=4.2
run 10 21 5
eq "+2 jumps 10 -> 12 -> 14, boundary CRF 13 checked" "$CRF_SELECTED/$CRF_OVER_CEILING/${CRF_TRIED[*]}" "14/0/10 12 14 13"
eq "report: jumps, refinement, boundary" "$(steps)" "over 10 12|over 12 14|refine 14 13|refine-over 13|boundary 13 14"
check "boundary: CRF 13 estimated over, CRF 14 fits" "low_ok $(gib 5) && (( CRF_EST[14] <= $(gib 5) ))"
eq "= sequential"                       "$CRF_SELECTED/$CRF_OVER_CEILING" "$(seq_ref 10 21 5 | cut -d/ -f1-2)"
check "11 never estimated (12 too large: one title)" "[[ ' ${CALLS[*]} ' != *' 11 '* ]]"

est 10=13.05 11=10.9 12=8.90 13=4.95 14=4.80
run 10 21 5
eq "skipped 13 fits: 13 chosen"         "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" "13/12/10 12 14 13"
eq "report: skipped CRF is the result"  "$(steps)" "over 10 12|over 12 14|refine 14 13|refine-fits 13|boundary 12 13"
eq "= sequential"                       "$CRF_SELECTED/$CRF_OVER_CEILING" "$(seq_ref 10 21 5 | cut -d/ -f1-2)"

est 10=6.0 11=5.3 12=4.7
run 10 21 5
eq "near ceiling (1.2 x): +1 steps"     "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" "12/11/10 11 12"
eq "report: no skips"                   "$(steps)" "over 10 11|over 11 12|fits 12"

est 10=7.5 11=6.0 12=4.9
run 10 21 5
eq "exactly 1.5 x: +1 (not a jump)"     "${CRF_TRIED[*]}" "10 11 12"

est 10=8.0 11=7.0 12=5.5 13=4.9
run 10 21 5
eq "1.6 x then 1.1 x: +2 then +1"       "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" "13/12/10 12 13"

est 12=4.0
run 12 23 7
eq "CRF_MIN already fits: chosen, nothing else" "$CRF_SELECTED/${CRF_BOUNDARY_LOW:-none}/${CRF_TRIED[*]}/$(steps)" "12/none/12/fits 12"

est 20=20 21=15
run 20 21 5
eq "CRF_MAX clamp: 20 + 2 -> 21, over"  "$CRF_SELECTED/$CRF_OVER_CEILING/${CRF_TRIED[*]}/$(steps)" "21/1/20 21/over 20 21|limit 21"
check "never above CRF_MAX"             "[[ \$(printf '%s\n' \"\${CALLS[@]}\" | sort -n | tail -n 1) == 21 ]]"

est 19=20 20=15 21=12
run 19 21 5
eq "jump onto CRF_MAX, still above: over" "$CRF_SELECTED/$CRF_OVER_CEILING/${CRF_TRIED[*]}" "21/1/19 21"
eq "... = sequential"                   "$CRF_SELECTED/$CRF_OVER_CEILING" "$(seq_ref 19 21 5 | cut -d/ -f1-2)"

est 19=20 20=4.9 21=4.0
run 19 21 5
eq "jump onto CRF_MAX fits: 20 checked, chosen" "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" "20/19/19 21 20"

# non-monotonic: CRF + 1 fits, CRF + 2 too large. A skip the data cannot
# prove (CERTIFY) is estimated at once, so the sequential CRF is found.
est 10=9 11=4 12=6 13=4.5 14=4
run 10 21 5 unproven
eq "CRF+1 fits, CRF+2 over: 11 found"   "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" "11/10/10 12 11"
eq "report: back-fill"                  "$(steps)" "over 10 12|check 12 11|refine-fits 11|boundary 10 11"
eq "= sequential"                       "$CRF_SELECTED/$CRF_OVER_CEILING" "$(seq_ref 10 21 5 | cut -d/ -f1-2)"
run 10 21 5
eq "one title (no CERTIFY): 12 too large proves 11 too large" "$CRF_SELECTED/${CRF_TRIED[*]}" "13/10 12 13"
est 10=9 11=7 12=6 13=4.5
run 10 21 5 unproven
eq "back-filled 11 too large: forward again" "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}/$(steps)" "13/12/10 12 11 13/over 10 12|check 12 11|resume 11 13|fits 13"
est 19=20 20=4 21=6
run 19 21 5 unproven
eq "back-fill below CRF_MAX: 20 fits"   "$CRF_SELECTED/$CRF_OVER_CEILING/${CRF_TRIED[*]}" "20/0/19 21 20"
est 19=20 20=7 21=6
run 19 21 5 unproven
eq "back-fill below CRF_MAX too large: over" "$CRF_SELECTED/$CRF_OVER_CEILING/$(steps)" "21/1/over 19 21|check 21 20|limit 21"

est 10=13 12=fail
run 10 21 5
eq "estimate failure: no CRF"           "$?/${CRF_SELECTED:-empty}" "1/empty"
est 10=13 11=fail 12=4
run 10 21 5
eq "failure on the boundary CRF: no CRF" "$?/${CRF_SELECTED:-empty}/${CALLS[*]}" "1/empty/10 12 11"
est 10=13 11=fail 12=6
run 10 21 5 unproven
eq "failure while back-filling: no CRF" "$?/${CRF_SELECTED:-empty}" "1/empty"

est 10=13.05 11=10.9 12=8.90 13=5.40 14=4.80
CRF_ADAPTIVE_STEP_THRESHOLD_PCT=0
run 10 21 5
eq "threshold 0: the sequential search" "$CRF_SELECTED/${CRF_TRIED[*]}" "14/10 11 12 13 14"
CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150

est 16=99
CALLS=()
crf_select_exact 16 fake_est
eq "Custom: exactly the entered CRF, one estimate" "$CRF_SELECTED/${CALLS[*]}/$CRF_OVER_CEILING" "16/16/0"
check "Custom untouched (crf_select_exact: no search)" \
    "! sed -n '/^crf_select_exact()/,/^}/p' '$SRC_WORK/lib/policy.sh' | grep -q 'crf_search_up\|crf_adaptive_step'"

# ------------------------------------------------------------
echo
echo "== 4. randomized tables"

declare -A B=()
BCALLS=()
byte_est() { BCALLS+=("$1"); CRF_EST_RESULT="${B[$1]}"; }
# calls_once_in_range  ->  0 when no CRF in BCALLS was estimated twice;
# CALLS_LO / CALLS_HI = lowest / highest CRF estimated (no subshells)
calls_once_in_range() {
    local c dup=0
    local -A seen=()
    CALLS_LO="" CALLS_HI=""
    for c in "${BCALLS[@]}"; do
        [[ -n "${seen[$c]:-}" ]] && dup=1
        seen[$c]=1
        [[ -z "$CALLS_LO" ]] || (( c < CALLS_LO )) && CALLS_LO="$c"
        [[ -z "$CALLS_HI" ]] || (( c > CALLS_HI )) && CALLS_HI="$c"
    done
    (( dup == 0 ))
}
# steps_var  ->  STEPS_S ("a|b|..." like steps) and STEPS_CHECKS (number
# of "check" steps), without a subshell
steps_var() {
    local s IFS='|'
    STEPS_S="${STEPS[*]}"
    STEPS_CHECKS=0
    for s in "${STEPS[@]}"; do
        [[ "$s" == check* ]] && ((STEPS_CHECKS += 1))
    done
    return 0
}
# rand_tables MODE TRIALS  ->  per trial "MIN MAX CEIL v..." (MODE mono:
# non-increasing, steps -1 % .. -45 % and flat; any: arbitrary)
rand_tables() {
    awk -v mode="$1" -v n="$2" 'BEGIN { srand(7)
        for (t = 1; t <= n; t++) {
            min = int(rand() * 30); max = min + int(rand() * 16); ceil = 1000000000
            v = ceil * (0.2 + rand() * 4.5); out = ""
            for (c = min; c <= max; c++) {
                out = out " " int(v)
                if (mode == "mono") v = v * ((rand() < 0.1) ? 1 : 0.55 + rand() * 0.44)
                else v = ceil * (0.3 + rand() * 2.5)
            }
            print min, max, ceil, out
        } }'
}
# rand_run MODE TRIALS [CERTIFY]  ->  RS "same/once/inrange/low/bound"
# counts, RSEQ / RAD estimates, RJUMP / RCHECK / RREFINE coverage
rand_run() {
    local min max ceil vals c v ref n same=0 once=0 inrange=0 low=0 bound=0
    RSEQ=0 RAD=0 RJUMP=0 RCHECK=0 RREFINE=0
    while read -r min max ceil vals; do
        B=()
        c="$min"
        for v in $vals; do B[$c]="$v"; ((c += 1)); done
        ref="" n=0
        for ((c = min; c <= max; c++)); do
            ((n += 1))
            if (( ${B[$c]} <= ceil )); then ref="$c/0"; break; fi
        done
        [[ -n "$ref" ]] || ref="$max/1"

        BCALLS=(); STEPS=()
        crf_select "$min" "$max" "$ceil" byte_est rec "${3:-}"
        ((RSEQ += n, RAD += ${#BCALLS[@]}))
        [[ "$CRF_SELECTED/$CRF_OVER_CEILING" == "$ref" ]] && ((same += 1))
        # checks in the shell itself (no subshells: a process per check
        # made these loops take minutes on slow-fork systems)
        calls_once_in_range "$min" "$max" && ((once += 1))
        (( CALLS_LO >= min && CALLS_HI <= max )) && ((inrange += 1))
        if (( CRF_OVER_CEILING == 1 || CRF_SELECTED == min )) || low_ok "$ceil"; then
            ((low += 1))
        fi
        steps_var
        # at most one estimate more than sequential per CRF left out and
        # back-filled; one in total without back-fill (the boundary CRF)
        (( ${#BCALLS[@]} <= n + 1 + STEPS_CHECKS )) && ((bound += 1))
        [[ "$STEPS_S" =~ over\ ([0-9]+)\ ([0-9]+) ]] && (( BASH_REMATCH[2] - BASH_REMATCH[1] == 2 )) && ((RJUMP += 1))
        [[ "$STEPS_S" == *check* ]] && ((RCHECK += 1))
        [[ "$STEPS_S" == *refine* ]] && ((RREFINE += 1))
    done < <(rand_tables "$1" "$2")
    RS="$same/$once/$inrange/$low/$bound"
}

t0=$SECONDS; rand_run mono 400
eq "monotonic (one title): same CRF / once / in range / boundary / bound" "$RS" "400/400/400/400/400"
check "... jumps ($RJUMP) and boundary refinements ($RREFINE) covered" "(( RJUMP > 50 && RREFINE > 20 ))"
echo "  (monotonic: sequential $RSEQ estimates, adaptive $RAD; $((SECONDS - t0)) s)"
t0=$SECONDS; rand_run any 400 unproven
eq "arbitrary non-monotonic, skips unproven: same CRF / once / in range / boundary / bound" "$RS" "400/400/400/400/400"
check "... back-fills covered ($RCHECK)" "(( RCHECK > 50 ))"
echo "  (arbitrary: sequential $RSEQ estimates, adaptive $RAD; $((SECONDS - t0)) s)"

# ------------------------------------------------------------
echo
echo "== 5. movie High / Base / Quality"

for tier in High Base; do
    crf_tier_load movie "$tier" "" 7200   # 2 h: High 7 / Base 2 GiB
    g=$(awk -v c="$CRF_CEILING_GIB" 'BEGIN { print c * 2.5 }')
    EST=()
    for ((c = CRF_MIN; c <= CRF_MAX; c++)); do
        EST[$c]=$(awk -v g="$g" -v k=$((c - CRF_MIN)) 'BEGIN { printf "%.4f", g * 0.88 ^ k }')
    done
    want=$(seq_ref "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_GIB")
    run "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_GIB"
    eq "movie $tier 2.5 x: same CRF as sequential (${want%/*})" "$CRF_SELECTED/$CRF_OVER_CEILING" "${want%/*}"
    eq "movie $tier 2.5 x: starts with a jump" "${CRF_TRIED[0]} ${CRF_TRIED[1]}" "$CRF_MIN $((CRF_MIN + 2))"
    check "movie $tier: boundary below the chosen CRF estimated over" "low_ok $CRF_CEILING_BYTES"
    # a jump that lands on a fit: the boundary CRF is checked
    EST=([$CRF_MIN]="$g" [$((CRF_MIN + 1))]="$(awk -v x="$CRF_CEILING_GIB" 'BEGIN { print x + 0.5 }')" [$((CRF_MIN + 2))]="$CRF_CEILING_GIB")
    run "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_GIB"
    eq "movie $tier boundary: $((CRF_MIN + 1)) over, $((CRF_MIN + 2)) fits" "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" \
        "$((CRF_MIN + 2))/$((CRF_MIN + 1))/$CRF_MIN $((CRF_MIN + 2)) $((CRF_MIN + 1))"
    EST=([$CRF_MIN]="$g")
    for ((c = CRF_MIN + 1; c <= CRF_MAX; c++)); do EST[$c]=$(awk -v x="$CRF_CEILING_GIB" 'BEGIN { print x * 1.6 }'); done
    run "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_GIB"
    eq "movie $tier: CRF_MAX still over -> over ceiling" "$CRF_SELECTED/$CRF_OVER_CEILING" "$CRF_MAX/1"
done

# compact output through crf_title_estimate (stand-in sample encodes):
# High 12-23, ceiling 7: 12 = 17.5 GiB, 14 = 6.9 (fits), 13 = 7.4
declare -A TGIB=()
crf_sample_title() {   # FILE VIDX FILTER CRF DURATION POINTS
    printf '%s\n' "$4" >> "$T/tcalls"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=$(gib "${TGIB[$4]}")
}
CRF_TITLE_FILE=/m/Film.mkv CRF_TITLE_VIDX=0 CRF_TITLE_FILTER="" CRF_TITLE_DURATION=100 CRF_TITLE_POINTS=5
TGIB=([12]=17.5 [13]=7.4 [14]=6.9 [15]=6.0)
crf_tier_load movie High "" 7200
TIER=High
crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_title_estimate crf_title_step_report > "$T/movie.out"
sed 's/^/  | /' "$T/movie.out"
eq "movie compact: jump, boundary check, boundary block" "$(tr '\n' '|' < "$T/movie.out")" \
    "  CRF 12   ~17.50 GiB|           too large -> jumping to CRF 14|  CRF 14   ~6.90 GiB|           fits -> checking CRF 13|  CRF 13   ~7.40 GiB|           too large||Boundary:|  CRF 13  over|  CRF 14  fits|"
TGIB=([12]=8.4 [13]=7.4 [14]=6.5)
crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_title_estimate crf_title_step_report > "$T/movie3.out"
eq "movie: no skip -> sample lines only, as before" "$(tr '\n' '|' < "$T/movie3.out")" \
    "  CRF 12   ~8.40 GiB|  CRF 13   ~7.40 GiB|  CRF 14   ~6.50 GiB|"
TGIB=([12]=17.5 [13]=7.4 [14]=6.9)
COMPRESS_VERBOSE=1 crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_title_estimate crf_title_step_report > "$T/movie5.out"
check "movie verbose: jump shown below the sample line" \
    "grep -q '^  sampling CRF 12 (1 section)\\.\\.\\. ~' '$T/movie5.out' && grep -q '^           too large -> jumping to CRF 14\$' '$T/movie5.out' && grep -q '^Boundary:\$' '$T/movie5.out'"
check "movie menu passes the reporter (High / Base and both Quality searches)" \
    "[[ \$(grep -c 'crf_title_step_report' '$SRC_WORK/movie_compress.sh') == 3 ]]"
unset -f crf_sample_title
source "$WORK_DIR/lib/encode_common.sh" > /dev/null

# Quality (band 18-22 GiB, target 20, CRF 0-8-23): upward with the same
# search, downward unchanged; the band / closest choice is unchanged
qsel() {   # START MAX [SOURCE_GIB]  ->  crf_select_quality over EST
    local src=""
    [[ -n "${3:-}" ]] && src=$(gib "$3")
    CALLS=(); STEPS=()
    crf_select_quality 0 "$1" "$2" "$(gib 20)" "$(gib 18)" "$(gib 22)" "$src" fake_est rec
}
est 8=40 9=30 10=21
qsel 8 23
eq "Quality 1.8 x: 8 -> 10 fits, boundary 9 over" "$CRF_SELECTED/$QUALITY_PICK/${CRF_TRIED[*]}" "10/band/8 10 9"
eq "Quality report: boundary 9 / 10"    "$(steps)" "over 8 10|refine 10 9|refine-over 9|boundary 9 10"
est 8=40 9=21.5 10=19
qsel 8 23
eq "Quality: skipped 9 inside the band -> 9" "$CRF_SELECTED/$QUALITY_PICK/${CRF_TRIED[*]}" "9/band/8 10 9"
est 8=40 9=30 10=17
qsel 8 23
eq "Quality: below the band after the jump -> closest (10)" "$CRF_SELECTED/$QUALITY_PICK" "10/closest"
est 8=40 9=35 10=30
qsel 8 10
eq "Quality: CRF_MAX still above the band" "$CRF_SELECTED/$CRF_OVER_CEILING/${CRF_TRIED[*]}" "10/1/8 10"
est 8=23 9=21
qsel 8 23
eq "Quality 1.05 x: +1, START from the tested map" "$CRF_SELECTED/$(printf '%s ' "${CALLS[@]}")" "9/8 9 "
est 8=15.5 7=18.6 6=21.7 5=24.8
qsel 8 23
eq "Quality downward unchanged"          "$CRF_SELECTED/${CALLS[*]}" "6/8 7 6 5"
est 8=19 7=17.5 6=21 5=23
qsel 8 23
eq "Quality start inside the band: downward one CRF at a time, boundary 5 / 6" "$CRF_SELECTED/${CALLS[*]}/$(steps)" "6/8 7 6 5/down 8 7|down 7 6|down 6 5|down-over 5|boundary 5 6"
est 8=40 9=fail
qsel 8 23
eq "Quality failure while searching"     "$?/${CRF_SELECTED:-none}" "1/none"

# randomized Quality: adaptive (150) = sequential (0) for monotonic titles
# (estimates generated in bytes once: byte_est, no process per probe)
qsame=0 qn=0 t0=$SECONDS
Q20=$(gib 20) Q18=$(gib 18) Q22=$(gib 22)
while read -r start max src vals; do
    [[ "$src" == x ]] && src=""
    B=()
    c=0
    for v in $vals; do B[$c]="$v"; ((c += 1)); done
    CRF_ADAPTIVE_STEP_THRESHOLD_PCT=0
    BCALLS=(); crf_select_quality 0 "$start" "$max" "$Q20" "$Q18" "$Q22" "$src" byte_est
    q0="$CRF_SELECTED/$QUALITY_PICK/$CRF_OVER_CEILING"
    CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150
    BCALLS=(); crf_select_quality 0 "$start" "$max" "$Q20" "$Q18" "$Q22" "$src" byte_est
    [[ "$CRF_SELECTED/$QUALITY_PICK/$CRF_OVER_CEILING" == "$q0" ]] && ((qsame += 1))
    ((qn += 1))
done < <(awk -v G=$G 'BEGIN { srand(11)
    for (t = 1; t <= 200; t++) {
        start = int(rand() * 12); max = start + int(rand() * 12)
        src = (rand() < 0.3) ? sprintf("%.0f", (15 + rand() * 30) * G) : ""
        v = 10 + rand() * 90; out = ""
        for (c = 0; c <= max; c++) { out = out " " sprintf("%.0f", v * G); v = v * (0.55 + rand() * 0.44) }
        print start, max, (src == "" ? "x" : src), out
    } }')
eq "Quality randomized: CRF / pick / over = sequential" "$qsame" "$qn"
echo "  (Quality randomized: $qn titles, $((SECONDS - t0)) s)"

# ------------------------------------------------------------
echo
echo "== 6. series High / Base"

# Stand-in sample encodes: episode En has SEP[n] GiB video at the tier's
# CRF_MIN, x F[crf] (default 0.88 per CRF step), or exactly EPG[n:crf]
# GiB when set. Records "CRF EPISODE".
declare -A SEP=() F=() DUR=() EPG=()
crf_sample_title() {   # FILE VIDX FILTER CRF DURATION POINTS
    local n="${1##*/E}"
    n="${n%.mkv}"
    printf '%s %s\n' "$4" "$n" >> "$T/calls"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=$(awk -v g="${SEP[$n]}" -v f="${F[$4]:-}" -v x="${EPG[$n:$4]:-}" -v c="$4" -v m="$CRF_MIN" \
        'BEGIN { if (x != "") { g = x; f = 1 } else if (f == "") f = 0.88 ^ (c - m); printf "%.0f", g * 1073741824 * f / 27 }')
}

# sel TIER [-k SAMPLED] GIB...  ->  the series menu's selection (season
# CRF with series_crf_certify_over, then the isolated outlier's own CRF)
# with the current threshold. CERT="" (title assumption) for comparison.
# Sets SEL "CRF/tried/over", CRFS (per episode), OUT, EPC_*, ROUNDS and
# RES "CRF/OVER|CRFS|OUT|EPC_CRF/EPC_OVER".
CERT=series_crf_certify_over
sel() {
    local tier="$1" k=99 n eb
    shift
    [[ "$1" == -k ]] && { k="$2"; shift 2; }
    FILES=(); EP_VIDX=(); EP_DUR=(); SEP=(); CRF_SERIES_LABELS=(); EP_LABEL=()
    for ((n = 1; n <= $#; n++)); do
        FILES+=("/s/E$n.mkv"); EP_VIDX+=(0); EP_DUR+=("${DUR[$n]:-2700}"); SEP[$n]="${!n}"
        CRF_SERIES_LABELS+=("E$n"); EP_LABEL+=("E$n")
    done
    mapfile -t CRF_SERIES_SAMPLED < <(series_sample_episodes "$#" "$k" "$(series_longest_episode)")
    CRF_SERIES_FILTER=""
    declare -gA CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
    : > "$T/calls"
    crf_tier_load series "$tier"
    STEPS=()
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate rec "$CERT" > "$T/sel.out"
    SEL="$CRF_SELECTED/${CRF_TRIED[*]}/$CRF_OVER_CEILING"
    ROUNDS="${#CRF_TRIED[@]}"
    read -ra eb <<< "${CRF_SERIES_EP_BYTES[$CRF_SELECTED]}"
    series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}"
    CRFS=(); for n in "${!eb[@]}"; do CRFS+=("$CRF_SELECTED"); done
    OUT="${SB_ISOLATED:--}"
    EPC_CRF="" EPC_OVER=0 EPC_TRIED=()
    if [[ -n "$SB_ISOLATED" ]] && (( eb[SB_ISOLATED] > CRF_CEILING_BYTES )); then
        series_episode_crf "$SB_ISOLATED" "$CRF_SELECTED" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_episode_estimate \
            crf_episode_step_report >> "$T/sel.out"
        CRFS[$SB_ISOLATED]="$EPC_CRF"
    fi
    RES="$CRF_SELECTED/$CRF_OVER_CEILING|${CRFS[*]}|$OUT|$EPC_CRF/$EPC_OVER"
}
# both TIER ARGS...  ->  sel with the sequential search (threshold 0:
# RES0, ROUNDS0, EPC_TRIED0), then the adaptive one (RES, ROUNDS, ...)
both() {
    CRF_ADAPTIVE_STEP_THRESHOLD_PCT=0
    sel "$@"
    RES0="$RES" ROUNDS0="$ROUNDS" EPC_TRIED0="${EPC_TRIED[*]}"
    CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150
    sel "$@"
}

# certification (CRF_SERIES_RATES at NEXT, EP_DUR, ceiling 100 bytes):
# only a sampled episode's own estimate counts; "-" (not sampled) never
EP_DUR=(10 10 10 10)
declare -gA CRF_SERIES_RATES=([12]="20 20 5 5")
check "two sampled episodes over at NEXT: proven"            "series_crf_certify_over 11 12 100"
CRF_SERIES_RATES[12]="20 5 5 5"
check "one sampled episode over (may be the isolated outlier): not proven" "! series_crf_certify_over 11 12 100"
CRF_SERIES_RATES[12]="20 - 15 5"
check "two sampled over, one not sampled: proven"            "series_crf_certify_over 11 12 100"
CRF_SERIES_RATES[12]="20 - - 5"
check "one sampled over + not-sampled (filled at 20): not proven" "! series_crf_certify_over 11 12 100"
CRF_SERIES_RATES[12]="20 - - -"
check "one sampled, three not sampled: not proven"           "! series_crf_certify_over 11 12 100"
EP_DUR=(10 10)
CRF_SERIES_RATES[12]="20 5"
check "2 episodes (no isolated outlier): one sampled over proves" "series_crf_certify_over 11 12 100"
CRF_SERIES_RATES[12]="5 -"
check "2 episodes: only the not-sampled one could be over: not proven" "! series_crf_certify_over 11 12 100"
EP_DUR=(10)
CRF_SERIES_RATES[12]="20"
check "1 episode over: proven"                               "series_crf_certify_over 11 12 100"
CRF_SERIES_RATES=()
check "no data at NEXT: not proven"                          "! series_crf_certify_over 11 12 100"
check "certification never reads the fill estimates" \
    "! sed -n '/^series_crf_certify_over() {/,/^}/p' '$SRC_WORK/lib/policy.sh' | grep -qiE 'fill|SC_EP_BYTES|CRF_SERIES_EP_BYTES'"

# epg N CRF GIB...  ->  episode N's own sample estimates from CRF on (the
# values given, then -12 % per CRF up to 21)
epg() {
    local n="$1" c="$2" g=""
    shift 2
    for g in "$@"; do EPG[$n:$c]="$g"; ((c += 1)); done
    for (( ; c <= 21; c++)); do
        g=$(awk -v g="$g" 'BEGIN { printf "%.4f", g * 0.88 }')
        EPG[$n:$c]="$g"
    done
}
nocalls_dup() { [[ -z "$(sort "$T/calls" | uniq -d)" ]]; }

# 4 episodes, 2 sampled (E1, E4): E2 / E3 are filled with E1's rate
# (the highest sampled). Only E1 is over by its own sample at 12, so the
# inferred E2 decides: it is sampled itself at 12 (decisive inference)
# and, over by its own sample too, proves 11 too large (two own samples)
both High -k 2 9 9 9 3
eq "sampled E1 / E4, E2 / E3 filled"        "${CRF_SERIES_SAMPLED[*]}" "0 3"
eq "one sampled over + filled ones over: decisive E2 sampled at 12, 11 proven" \
    "$(steps | grep -c 'check 12 11')/$(grep -c '^12 2$' "$T/calls")/$(grep -c '^12 3$' "$T/calls")/$(grep -c '^11 ' "$T/calls")" "0/1/0/0"
eq "... = sequential"                       "$RES" "$RES0"
check "... no sample encoded twice (cache)" "nocalls_dup"
both High -k 2 9 3 3 9
eq "two sampled episodes over at 12: 11 proven, not sampled" "$(steps | grep -c check)/$(grep -c '^11 ' "$T/calls")" "0/0"
eq "... = sequential"                       "$RES" "$RES0"

# isolated sampled outlier E1 + a longer episode E2 that is not sampled
# (filled with E3's rate x its runtime, above the ceiling). Formerly its
# inferred estimate alone kept 12 too large (13 chosen); now it is sampled
# itself at 12 (decisive inference, 1 GiB): 12 fits, 11 is too large by
# own samples (E5 5.5 GiB) -> 12
EPG=()
DUR=([2]=3300 [5]=5400)
epg 1 10 40 35 30
epg 3 10 6.5 5.0 4.5
epg 5 10 3.3 2.75 2.3      # 90 min: 6.6 / 5.5 / 4.6 GiB (sizes are per 45 min)
epg 2 10 1
epg 4 10 1
both High -k 3 1 1 1 1 1
eq "sampled E1 / E3 / E5"                   "${CRF_SERIES_SAMPLED[*]}" "0 2 4"
eq "inferred E2 sampled before it may keep 12 too large: 12 chosen" "$SEL/$OUT" "12/10 12 11/0/0"
eq "... report"                             "$(steps)" "over 10 12|refine 12 11|refine-over 11|boundary 11 12"
eq "... E2 sampled after inference at 12"   "$(grep -c '^12 2$' "$T/calls")/$(read -ra ef <<< "${CRF_SERIES_EP_FROM[12]}"; echo "${ef[1]}")" "1/promoted"
eq "... = sequential (season and outlier CRF)" "$RES" "$RES0"
DUR=()
EPG=()

# not-sampled episodes much easier / much harder than the sampled ones:
# the season uses the conservative fill either way; the source guard and
# late ceiling check sample them. Whole flow = sequential.
full() {   # sel ARGS..., then source guard + late ceiling  ->  FRES
    local i
    sel "$@"
    read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[$CRF_SELECTED]}"
    read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[$CRF_SELECTED]}"
    EP_CRF=(); EP_CEIL_SKIP=(); EP_OVER=(); EP_VBYTES=()
    for i in "${!FILES[@]}"; do EP_CRF+=("${CRFS[$i]}"); EP_CEIL_SKIP+=(0); EP_OVER+=(0); EP_VBYTES+=("$(gib 2)"); done
    series_guard_episodes crf_episode_estimate > /dev/null
    series_late_ceiling crf_episode_estimate > /dev/null
    FRES="$RES|${EP_CRF[*]}|${GUARD[*]}|${LATE[*]}"
}
fboth() {
    CRF_ADAPTIVE_STEP_THRESHOLD_PCT=0
    full "$@"
    FRES0="$FRES"
    CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150
    full "$@"
}
epg 1 10 9; epg 4 10 8.5; epg 2 10 0.5; epg 3 10 0.6
fboth High -k 2 1 1 1 1
eq "not sampled much easier: = sequential"  "$FRES" "$FRES0"
eq "... easier ones sampled by the guard, fit below their source" "${GUARD_SAMPLED[*]}/${GUARD[*]}" "1 2/0 3"
epg 2 10 20; epg 3 10 18
fboth High -k 2 1 1 1 1
eq "not sampled much harder: = sequential"  "$FRES" "$FRES0"
check "... harder ones sampled by the guard, own higher CRFs" "[[ '${GUARD_SAMPLED[*]}' == '1 2' && '${LATE[*]}' == '1 2' ]] && (( EP_CRF[1] > EP_CRF[0] ))"
EPG=()

# 1- and 2-episode batches
both High 9
eq "1 episode, 1.8 x: = sequential"         "$RES" "$RES0"
both High 9 3
eq "2 episodes: = sequential"               "$RES" "$RES0"
EPG=(); epg 1 10 9; epg 2 10 3
both High -k 1 1 1
eq "2 episodes, 1 sampled: = sequential"    "${CRF_SERIES_SAMPLED[*]}|$RES" "0|$RES0"
EPG=()

both High 12.0 12.5 13.05 12.8 11.9
eq "series High 2.6 x: = sequential (18)"  "$RES" "$RES0"
eq "series High 2.6 x: 10 12 14 16 17 18"  "$SEL" "18/10 12 14 16 17 18/0"
eq "series High: boundary 17 over / 18 fits" "$CRF_BOUNDARY_LOW" 17
eq "series High: rounds 9 -> 6"            "$ROUNDS0/$ROUNDS" "9/6"

both Base 4.0 4.2 4.1 3.9
eq "series Base 2.8 x: = sequential"       "$RES" "$RES0"
check "series Base: jumps, fewer rounds ($ROUNDS0 -> $ROUNDS)" "(( ROUNDS < ROUNDS0 )) && [[ \"\${CRF_TRIED[0]} \${CRF_TRIED[1]}\" == '13 15' ]]"
check "series Base: boundary estimated"    "low_ok $CRF_CEILING_BYTES"

both High 6.0 6.2 5.9
eq "series High 1.24 x: +1 steps, same rounds" "$RES/$ROUNDS" "$RES0/$ROUNDS0"

both High 3.0 3.5 4.2
eq "series: CRF_MIN fits -> CRF_MIN"       "$SEL/$(steps)" "10/10/0/fits 10"

both High 40 40 40
eq "series: CRF_MAX still over -> over, = sequential" "${SEL##*/}/$RES" "1/$RES0"

# a jump that lands on a fit: steep drop 10 -> 12 (F); boundary 11 checked
F=([10]=1 [11]=0.75 [12]=0.55)
both High 8.0 7.9 8.0
eq "series High boundary: 11 over, 12 fits" "$SEL/$CRF_BOUNDARY_LOW" "12/10 12 11/0/11"
eq "... = sequential"                      "$RES" "$RES0"
F=([10]=1 [11]=0.6 [12]=0.55)
both High 8.0 7.9 8.0
eq "series: skipped 11 fits -> 11"         "$SEL/$CRF_BOUNDARY_LOW" "11/10 12 11/0/10"
eq "... = sequential"                      "$RES" "$RES0"
F=()
crf_tier_load series Base
F=([13]=1 [14]=0.8 [15]=0.55)
both Base 2.6 2.5 2.6
eq "series Base boundary: 14 over, 15 fits" "$SEL/$CRF_BOUNDARY_LOW" "15/13 15 14/0/14"
F=()

# non-monotonic season: outlier reclassification. Every episode shrinks
# with the CRF, but the season fits at 11 (E1 the only outlier: isolated)
# and not at 12 (E2 an outlier too: E1 regular again, 7.9 GiB):
#   CRF 10  9.0 9.0 4.0 4.0   two outliers, largest regular 9.0 (1.8 x)
#   CRF 11  8.0 4.6 3.9 3.9   E1 isolated, largest regular 4.6: fits
#   CRF 12  7.9 4.5 2.0 2.0   two outliers, largest regular 7.9
EPG=([1:10]=9 [2:10]=9 [3:10]=4 [4:10]=4 [1:11]=8 [2:11]=4.6 [3:11]=3.9 [4:11]=3.9
     [1:12]=7.9 [2:12]=4.5 [3:12]=2 [4:12]=2 [1:13]=7.8 [2:13]=4.4 [3:13]=1.9 [4:13]=1.9)
both High 1 1 1 1
eq "reclassification: sequential finds 11"  "${RES0%%|*}" "11/0"
eq "reclassification: 12 not proven, 11 sampled -> 11" "$SEL/$CRF_BOUNDARY_LOW" "11/10 12 11/0/10"
eq "... report"                             "$(steps)" "over 10 12|check 12 11|refine-fits 11|boundary 10 11"
eq "... = sequential (outlier own CRF too)" "$RES" "$RES0"
CERT=""
sel High 1 1 1 1
check "without the season certification 11 would be missed ($CRF_SELECTED)" "[[ '$CRF_SELECTED' != 11 ]]"
CERT=series_crf_certify_over
EPG=()

# randomized seasons: every episode shrinks with the CRF (-1 % .. -40 %
# per step, each its own), outliers come and go; 1-6 episodes, some not
# sampled. The season CRF / over flag / outlier CRF must equal the
# sequential search.
# Each season trial runs the real season math (series_crf_spread /
# series_batch_stats, several awk calls per CRF) twice; CRF_TEST_SEASONS
# trials (default 12, about 9 s each on slow-fork systems; 120 for the
# long run). The back-fill of unproven skips is covered by the fixed
# cases above (reclassification, isolated outlier).
ssame=0 sn=0 scheck=0 sjump=0 sseq=0 sad=0 t0=$SECONDS
while read -r ne k rest; do
    EPG=()
    read -ra vv <<< "$rest"
    i=0
    for ((n = 1; n <= ne; n++)); do
        for ((c = 10; c <= 21; c++)); do EPG[$n:$c]="${vv[i]}"; ((i += 1)); done
    done
    args=()
    for ((n = 1; n <= ne; n++)); do args+=(1); done
    both High -k "$k" "${args[@]}"
    [[ "$RES" == "$RES0" ]] && ((ssame += 1))
    steps_var
    [[ "$STEPS_S" == *check* ]] && ((scheck += 1))
    [[ "$STEPS_S" =~ over\ ([0-9]+)\ ([0-9]+) ]] && (( BASH_REMATCH[2] - BASH_REMATCH[1] == 2 )) && ((sjump += 1))
    ((sn += 1, sseq += ROUNDS0, sad += ROUNDS))
done < <(awk -v trials="${CRF_TEST_SEASONS:-12}" 'BEGIN { srand(5)
    for (t = 1; t <= trials; t++) {
        ne = 1 + int(rand() * 6); k = 1 + int(rand() * ne); out = ne " " k
        for (n = 1; n <= ne; n++) {
            v = 5 * (0.4 + rand() * 2.6); if (rand() < 0.3) v = v * (1.3 + rand() * 1.5)
            for (c = 10; c <= 21; c++) { out = out " " sprintf("%.3f", v); v = v * (0.6 + rand() * 0.39) }
        }
        print out
    } }')
EPG=()
eq "randomized seasons: = sequential"      "$ssame" "$sn"
check "... jumps covered ($sjump; unproven skips sampled: $scheck)" "(( sjump > 0 ))"
echo "  (seasons: $sn trials, sequential $sseq rounds, adaptive $sad; $((SECONDS - t0)) s)"

# isolated outlier: the season CRF ignores it, it gets its own CRF
both High 3.7 4.2 6.0 3.9 4.0 4.1
eq "isolated outlier (1.2 x): season 10, own CRF 12, as before" "$RES" "10/0|10 10 12 10 10 10|2|12/0"
eq "... = sequential"                      "$RES" "$RES0"
eq "outlier near ceiling: +1 steps"        "${EPC_TRIED[*]}" "10 11 12"
both High 3.7 4.2 12.0 3.9 4.0 4.1
eq "isolated outlier (2.4 x): season still 10" "${RES%%|*}/$OUT" "10/0/2"
eq "outlier own CRF = sequential"          "$RES" "$RES0"
eq "outlier own search jumps"              "${EPC_TRIED[*]}" "10 12 14 15 16 17"
eq "cached: outlier at season CRF 10 sampled once" "$(grep -c '^10 3$' "$T/calls")" 1
check "outlier jump shown"                 "grep -q '^    too large -> jumping to CRF 12\$' '$T/sel.out' && grep -q '^  E3  CRF 10   ~12.00 GiB (already sampled)\$' '$T/sel.out'"
F=([10]=1 [11]=0.75 [12]=0.55)
both High 3.7 4.2 8.0 3.9 4.0 4.1
eq "outlier boundary: 11 checked, = sequential" "${EPC_TRIED[*]}/$RES" "10 12 11/$RES0"
check "outlier boundary shown"             "grep -q '^    boundary: CRF 11 over, CRF 12 fits\$' '$T/sel.out'"
F=()
both High 3.7 4.2 30 3.9 4.0 4.1
eq "outlier above at CRF_MAX: flagged, = sequential" "${RES##*|}/$RES" "21/1/$RES0"

# two or more difficult episodes: season difficulty, the season CRF rises
both High 5.4 3.0 5.9 3.2 4.0 6.2
eq "two large episodes (1.24 x): season 12, no own CRF" "$RES" "12/0|12 12 12 12 12 12|-|/0"
eq "... = sequential"                      "$RES" "$RES0"
both High 11 3.0 12 3.2 4.0 12.5
eq "two large episodes (2.5 x): no outlier, = sequential" "$OUT/$RES" "-/$RES0"
check "... season raised by jumps"         "[[ \"\${CRF_TRIED[0]} \${CRF_TRIED[1]}\" == '10 12' ]] && (( ROUNDS < ROUNDS0 ))"

# late ceiling check after the source guard's own sample (E2 not sampled,
# guessed at 3.0 GiB, its own content 12 GiB = 2.4 x the ceiling)
late() {
    sel High -k 4 3.0 "$1" 3.0 3.0 3.0 3.0 3.0 3.0
    read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[$CRF_SELECTED]}"
    read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[$CRF_SELECTED]}"
    EP_CRF=(); EP_CEIL_SKIP=(); EP_OVER=()
    for i in 0 1 2 3 4 5 6 7; do EP_CRF+=("$CRF_SELECTED"); EP_CEIL_SKIP+=(0); EP_OVER+=(0); done
    EP_VBYTES=($(gib 100) $(gib 2) $(gib 100) $(gib 100) $(gib 100) $(gib 100) $(gib 100) $(gib 100))
    : > "$T/calls"
    series_guard_episodes crf_episode_estimate > "$T/late.out"
    series_late_ceiling crf_episode_estimate crf_episode_step_report >> "$T/late.out"
    LRES="${EP_CRF[*]}/${EP_OVER[*]}/${LATE[*]}"
}
CRF_ADAPTIVE_STEP_THRESHOLD_PCT=0
late 12.0
LRES0="$LRES" LCALLS0=$(wc -l < "$T/calls")
CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150
late 12.0
eq "late ceiling: only E2 raised, = sequential" "$LRES" "$LRES0"
eq "late ceiling: E2 at 17, season 10"     "${EP_CRF[1]}/${EP_CRF[0]}" "17/10"
eq "late ceiling: 10 (reused) 12 14 15 16 17" "$(cut -d' ' -f1 "$T/calls" | tr '\n' ' ')" "10 12 14 15 16 17 "
check "late ceiling: fewer samples ($LCALLS0 -> $(wc -l < "$T/calls"))" "(( \$(wc -l < '$T/calls') < LCALLS0 ))"
F=([10]=1 [11]=0.3 [12]=0.25)
late 12.0
eq "late ceiling boundary: 11 fits after the jump -> 11" "${EP_CRF[1]}/$(cut -d' ' -f1 "$T/calls" | tr '\n' ' ')" "11/10 12 11 "
check "late ceiling boundary shown"        "grep -q '^    boundary: CRF 10 over, CRF 11 fits\$' '$T/late.out'"
F=()
check "series menu passes the reporters and the certification" \
    "grep -qF 'crf_series_step_report series_crf_certify_over || CRF_SELECTED=\"\"' '$SRC_WORK/series_compress.sh' && grep -qF 'series_late_ceiling crf_episode_estimate crf_episode_step_report' '$SRC_WORK/series_compress.sh' && grep -qF 'crf_episode_step_report; then' '$SRC_WORK/series_compress.sh'"
check "series has no Quality tier"         "! grep -q 'Quality' '$SRC_WORK/series_compress.sh'"

# compact season output: the menu's own functions
eval "$(sed -n '/^crf_series_estimate_shown() {/,/^}/p; /^crf_series_step_report() {/,/^}/p' "$SRC_WORK/series_compress.sh")"
TIER=High
show() {   # the request's example through the menu output
    FILES=(/s/E1.mkv /s/E2.mkv /s/E3.mkv); EP_VIDX=(0 0 0); EP_DUR=(2700 2700 2700)
    SEP=([1]=13.05 [2]=13.05 [3]=13.05); CRF_SERIES_SAMPLED=(0 1 2)
    CRF_SERIES_LABELS=(E1 E2 E3); EP_LABEL=(E1 E2 E3)
    declare -gA CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
    crf_tier_load series High
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate_shown \
        crf_series_step_report series_crf_certify_over
}
F=([10]=1 [11]=0.8352 [12]=0.6820 [13]=0.4138 [14]=0.3678)
show > "$T/show.out"
sed 's/^/  | /' "$T/show.out"
eq "series compact: example from the request" \
    "$(grep -E '^(CRF [0-9]+$|Largest:|Result:|Selected:|Boundary:|  CRF [0-9]+  |$)' "$T/show.out" | tr '\n' '|')" \
    "|CRF 10||Largest:  13.05 GiB (E1, sampled)|Result:   too large -> jumping to CRF 12||CRF 12||Largest:  8.90 GiB (E1, sampled)|Result:   too large -> jumping to CRF 14||CRF 14||Largest:  4.80 GiB (E1, sampled)|Result:   fits -> checking CRF 13||CRF 13||Largest:  5.40 GiB (E1, sampled)|Result:   too large||Boundary:|  CRF 13  over|  CRF 14  fits|Selected: CRF 14|"
F=([10]=0.4 [11]=0.383)
show > "$T/show2.out"
check "series compact: no skip -> as before" \
    "[[ \"\$(grep -E '^(Result|Selected|Boundary):' '$T/show2.out' | tr '\n' '|')\" == 'Result:   too large -> trying CRF 11|Selected: CRF 11|' ]]"
F=([10]=0.3)
show > "$T/show4.out"
check "series compact: CRF_MIN fits -> Selected only" \
    "[[ \"\$(grep -E '^(Result|Selected|Boundary):' '$T/show4.out' | tr '\n' '|')\" == 'Selected: CRF 10|' ]]"
F=([10]=1 [11]=0.8352 [12]=0.6820 [13]=0.4138 [14]=0.3678)
COMPRESS_VERBOSE=1 show > "$T/show3.out"
check "series verbose: only the skip steps + boundary" \
    "[[ \"\$(grep -E '^ {11}|^Boundary:' '$T/show3.out' | tr '\n' '|')\" == '           too large -> jumping to CRF 12|           too large -> jumping to CRF 14|           fits -> checking CRF 13|           too large|Boundary:|' ]]"
F=()
unset -f crf_sample_title
source "$WORK_DIR/lib/encode_common.sh" > /dev/null

# ------------------------------------------------------------
echo
echo "== 7. sample cache (stand-in x265, real cache files)"

crf_x265_params() { printf ''; }
declare -A SBYTES=([10]=900000 [11]=700000 [12]=560000 [13]=330000 [14]=290000 [15]=250000)
crf_sample_encode() {   # FILE VIDX FILTER X265 CRF START LENGTH OUT
    printf '%s %s\n' "$5" "$6" >> "$T/enc"
    head -c "${SBYTES[$5]}" /dev/zero > "$8"
}
head -c 1000 /dev/zero > "$T/film.mkv"
CRF_SAMPLE_SECONDS=20
CRF_TITLE_FILE="$T/film.mkv" CRF_TITLE_VIDX=0 CRF_TITLE_FILTER="" CRF_TITLE_DURATION=1000 CRF_TITLE_POINTS=2
# estimate = 2 x SBYTES / 40 s x 1000 s = 50 x SBYTES; ceiling 16 MB
CEIL=16000000
: > "$T/enc"
crf_select 10 21 "$CEIL" crf_title_estimate > /dev/null
eq "first search: 10 12 14, boundary 13 -> 14" "$CRF_SELECTED/${CRF_TRIED[*]}" "14/10 12 14 13"
eq "each CRF / section encoded once"        "$(sort "$T/enc" | uniq -d | wc -l)/$(wc -l < "$T/enc")" "0/8"
: > "$T/enc"
crf_select 10 21 "$CEIL" crf_title_estimate > /dev/null
eq "same search again: all from the cache"  "$CRF_SELECTED/$(wc -l < "$T/enc")" "14/0"
rm -rf "$WORK_DIR/cache"
crf_title_estimate 13 > /dev/null
: > "$T/enc"
crf_select 10 21 "$CEIL" crf_title_estimate > /dev/null
eq "boundary check reuses the cached CRF 13" "$CRF_SELECTED/$(cut -d' ' -f1 "$T/enc" | sort -u | tr '\n' ' ')" "14/10 12 14 "
: > "$T/enc"
crf_select 10 21 "$CEIL" crf_title_estimate "" unproven > /dev/null
eq "back-fill (11) only encodes what is new" "$CRF_SELECTED/$(cut -d' ' -f1 "$T/enc" | sort -u | tr '\n' ' ')" "14/11 "
CRF_SAMPLE_CACHE=0
: > "$T/enc"
crf_select 10 21 "$CEIL" crf_title_estimate > /dev/null
eq "cache off: each probed CRF encoded once" "$(sort "$T/enc" | uniq -d | wc -l)/$(wc -l < "$T/enc")" "0/8"
unset CRF_SAMPLE_CACHE
unset -f crf_x265_params crf_sample_encode
source "$WORK_DIR/lib/encode_common.sh" > /dev/null

# ------------------------------------------------------------
echo
echo "== 8. estimate rounds before / after (-12 % per CRF)"

# rounds LABEL MIN MAX CEILING_GIB START_GIB  ->  sequential vs adaptive
rounds() {
    local c s a
    EST=()
    for ((c = $2; c <= $3; c++)); do
        EST[$c]=$(awk -v g="$5" -v k=$((c - $2)) 'BEGIN { printf "%.4f", g * 0.88 ^ k }')
    done
    s=$(seq_ref "$2" "$3" "$4")
    run "$2" "$3" "$4"
    a="$CRF_SELECTED/$CRF_OVER_CEILING/${#CALLS[@]}"
    printf '  %-34s CRF %-3s sequential %2s rounds, adaptive %2s rounds  (%s)\n' \
        "$1" "${a%%/*}" "${s##*/}" "${#CALLS[@]}" "${CRF_TRIED[*]}"
    eq "$1: same CRF" "${a%/*}" "${s%/*}"
    PERF="${s##*/}/${#CALLS[@]}"
}
rounds "movie High 2.5 x (17.5 GiB / 7)"   12 23 7 17.5
eq "movie High 2.5 x: 9 -> 7 rounds" "$PERF" "9/7"
rounds "movie High 1.2 x (8.4 GiB / 7)"    12 23 7 8.4
eq "movie High 1.2 x: 3 -> 3 rounds" "$PERF" "3/3"
rounds "movie Base 2.5 x (5.0 GiB / 2)"    20 29 2 5.0
eq "movie Base 2.5 x: 9 -> 7 rounds" "$PERF" "9/7"
rounds "series High 2.5 x (12.5 GiB / 5)"  10 21 5 12.5
eq "series High 2.5 x: 9 -> 7 rounds" "$PERF" "9/7"
rounds "series High 1.2 x (6.0 GiB / 5)"   10 21 5 6.0
eq "series High 1.2 x: 3 -> 3 rounds" "$PERF" "3/3"
rounds "series Base 4 x (6.0 GiB / 1.5)"   13 27 1.5 6.0
eq "series Base 4 x: 12 -> 8 rounds" "$PERF" "12/8"

# ------------------------------------------------------------
echo
echo "== 9. set -euo pipefail"

cat > "$T/setu.sh" <<EOF
set -euo pipefail
WORK_DIR='$WORK_DIR'
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do source "\$WORK_DIR/lib/\$l.sh" > /dev/null; done
COMPRESS_CONF='$COMPRESS_CONF' load_policy > /dev/null
declare -A E=([10]=1300 [11]=1090 [12]=890 [13]=540 [14]=480 [20]=2000 [21]=1500)
e() { CRF_EST_RESULT="\${E[\$1]}"; }
ee() { CRF_EST_RESULT="\${E[\$2]}"; }
no() { return 1; }
crf_select 10 21 500 e crf_title_step_report > /dev/null
[[ "\$CRF_SELECTED/\$CRF_BOUNDARY_LOW/\${CRF_TRIED[*]}" == "14/13/10 12 14 13" ]]
crf_select 10 21 500 e crf_title_step_report no > /dev/null
[[ "\$CRF_SELECTED/\${CRF_TRIED[*]}" == "14/10 12 11 14 13" ]]
crf_select 10 14 500 e > /dev/null
crf_select 20 21 500 e crf_title_step_report > /dev/null
[[ "\$CRF_SELECTED/\$CRF_OVER_CEILING/\$CRF_BOUNDARY_LOW" == "21/1/" ]]
crf_select 10 21 0 e > /dev/null
series_episode_crf 0 10 21 500 ee crf_episode_step_report > /dev/null
[[ "\$EPC_CRF/\${EPC_TRIED[*]}" == "14/10 12 14 13" ]]
series_episode_crf 0 20 21 500 ee > /dev/null
E=([8]=4000 [9]=2500 [10]=2100)
crf_select_quality 0 8 23 2000 1800 2200 "" e crf_title_step_report > /dev/null
[[ "\$CRF_SELECTED/\$QUALITY_PICK" == "10/band" ]]
crf_select_quality 0 8 23 2000 1800 2200 "" e > /dev/null
EP_DUR=(10 10 10)
declare -A CRF_SERIES_RATES=([12]="20 - 5")
series_crf_certify_over 11 12 100 || true
series_crf_certify_over 11 13 100 || true
unset CRF_ADAPTIVE_STEP_THRESHOLD_PCT
crf_adaptive_step 900 100 > /dev/null
E=([10]=1300 [11]=1090 [12]=890 [13]=540 [14]=480)
crf_select 10 21 500 e > /dev/null
[[ "\${CRF_TRIED[*]}" == "10 11 12 13 14" ]]
for k in over check resume limit refine refine-over refine-fits; do crf_step_result "\$k" 12 14 > /dev/null; done
crf_step_result limit 21 > /dev/null
crf_step_result refine-over 13 > /dev/null
crf_boundary_lines 13 14 > /dev/null
crf_title_step_report fits 12 > /dev/null
crf_title_step_report boundary 13 14 > /dev/null
crf_episode_step_report boundary 13 14 > /dev/null
crf_episode_step_report over 10 12 > /dev/null
echo survived
EOF
eq "bracket search under set -euo pipefail" "$(bash "$T/setu.sh" 2>&1 | tail -1)" "survived"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
