#!/usr/bin/env bash
# Adjacent CRF boundary search (policy.sh crf_search_boundary /
# crf_select_boundary) and decisive inferred series episodes
# (series_decisive_inferred, encode_common.sh crf_series_estimate):
#
#   CRF N      above the ceiling
#   CRF N + 1  fits             ->  High / Base choose N + 1
#
# searched from *_CRF_START upward (+1 / +2, bracket-and-refine) or
# downward (one CRF at a time) within *_CRF_SEARCH_MIN..*_CRF_MAX; an
# episode that was not sampled never makes a season CRF fail on its
# inferred estimate alone.
#
#   bash ~/compress/work/tests/crf_boundary_tests.sh
#
# No ffmpeg needed: stand-in estimators and sample encodes. Covers:
#   1. config: START / SEARCH_MIN / MAX, former *_CRF_MIN
#   2. High / Base search: up, down, the request's example, floor,
#      adjacent boundary, -1 steps down, each CRF once, movie High / Base,
#      series High / Base, = sequential search from SEARCH_MIN
#   3. movie compact output of a downward search
#   4. series season below CRF_START (stand-in sample encodes)
#   5. decisive inferred episodes: sampled before the season CRF rises,
#      real sample fits / still fails, becomes the isolated outlier,
#      several candidates, cache reuse, labels, Custom
#   6. Quality: adjacent boundary, same estimates / choice as the former
#      search
#   7. per-section diagnostics (verbose)
#   8. set -euo pipefail
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
    MOVIE_HIGH_CRF_SEARCH_MIN=10 MOVIE_HIGH_CRF_START=12 MOVIE_HIGH_CRF_MAX=23 MOVIE_HIGH_VIDEO_GIB_PER_HOUR=3.5 \
    MOVIE_BASE_CRF_SEARCH_MIN=18 MOVIE_BASE_CRF_START=20 MOVIE_BASE_CRF_MAX=29 MOVIE_BASE_VIDEO_GIB_PER_HOUR=1.0 \
    SERIES_HIGH_CRF_SEARCH_MIN=8 SERIES_HIGH_CRF_START=10 SERIES_HIGH_CRF_MAX=21 SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=5 \
    SERIES_BASE_CRF_SEARCH_MIN=11 SERIES_BASE_CRF_START=13 SERIES_BASE_CRF_MAX=27 SERIES_BASE_VIDEO_SIZE_CEILING_GIB=1.5 \
    SERIES_CRF_OUTLIER_PCT=25 CRF_ADAPTIVE_STEP_THRESHOLD_PCT=150)
export COMPRESS_CONF
load_policy > /dev/null

# ------------------------------------------------------------
echo "== 1. config"

for f in MOVIE_HIGH MOVIE_BASE SERIES_HIGH SERIES_BASE; do
    st=$(sed -n "s/^${f}_CRF_START=//p" "$SRC_WORK/lib/compress.conf")
    sm=$(sed -n "s/^${f}_CRF_SEARCH_MIN=//p" "$SRC_WORK/lib/compress.conf")
    eq "project config: $f search floor 2 below the start ($sm / $st)" "$(( st - sm ))" 2
done
check "project config: no former High/Base *_CRF_MIN" \
    "! grep -qE '^(MOVIE|SERIES)_(HIGH|BASE)_CRF_MIN=' '$SRC_WORK/lib/compress.conf'"
check "project config loads" "COMPRESS_CONF='$SRC_WORK/lib/compress.conf' load_policy 2>/dev/null"
crf_tier_load movie High "" 7200
eq "crf_tier_load: start / floor / max are separate" "$CRF_START $CRF_MIN $CRF_MAX" "12 10 23"
crf_tier_load series Base
eq "crf_tier_load series Base"            "$CRF_START $CRF_MIN $CRF_MAX" "13 11 27"
crf_tier_load series Custom 17
eq "Custom: start = floor = max = the entered CRF" "$CRF_START $CRF_MIN $CRF_MAX $CRF_CEILING_BYTES" "17 17 17 0"
check "START below SEARCH_MIN rejected" \
    "! ( COMPRESS_CONF=\$(conf_with r1 MOVIE_BASE_CRF_START=17) load_policy ) 2>'$T/r1.err' && grep -q 'MOVIE_BASE_CRF_START (17) is lower than MOVIE_BASE_CRF_SEARCH_MIN (18)' '$T/r1.err'"
check "START above MAX rejected" \
    "! ( COMPRESS_CONF=\$(conf_with r2 SERIES_HIGH_CRF_START=22) load_policy ) 2>'$T/r2.err' && grep -q 'SERIES_HIGH_CRF_START (22) is greater than SERIES_HIGH_CRF_MAX (21)' '$T/r2.err'"
check "missing SEARCH_MIN named" \
    "f=\$(conf_with r3); sed -i '/^SERIES_BASE_CRF_SEARCH_MIN=/d' \"\$f\"; ! ( COMPRESS_CONF=\"\$f\" load_policy ) 2>'$T/r3.err' && grep -q 'SERIES_BASE_CRF_SEARCH_MIN is not set' '$T/r3.err'"
f=$(conf_with legacy); sed -i '/^SERIES_HIGH_CRF_\(START\|SEARCH_MIN\)=/d' "$f"; echo "SERIES_HIGH_CRF_MIN=10" >> "$f"
check "former *_CRF_MIN alone: loads with a note" \
    "( COMPRESS_CONF='$f' load_policy ) 2>'$T/legacy.err' && grep -q 'SERIES_HIGH_CRF_MIN' '$T/legacy.err'"
eq "former *_CRF_MIN alone: start = floor (former behaviour)" \
    "$( COMPRESS_CONF="$f" load_policy 2>/dev/null; crf_tier_load series High; echo "$CRF_START $CRF_MIN" )" "10 10"
check "former *_CRF_MIN next to the new keys: rejected, not silently reinterpreted" \
    "! ( COMPRESS_CONF=\$(conf_with r4 MOVIE_HIGH_CRF_MIN=12) load_policy ) 2>'$T/r4.err' && grep -q 'MOVIE_HIGH_CRF_MIN is replaced by MOVIE_HIGH_CRF_START and MOVIE_HIGH_CRF_SEARCH_MIN' '$T/r4.err'"
load_policy > /dev/null

# ------------------------------------------------------------
echo
echo "== 2. High / Base boundary search (stand-in estimator, GiB per CRF)"

declare -A EST=()
CALLS=()
STEPS=()
fake_est() {   # ESTIMATOR: EST[crf] GiB (bytes when it has no dot and is large); "fail"
    CALLS+=("$1")
    [[ "${EST[$1]:-}" == fail ]] && return 1
    CRF_EST_RESULT=$(gib "${EST[$1]:-0.01}")
}
est() { EST=(); local kv; for kv in "$@"; do EST[${kv%%=*}]="${kv#*=}"; done; }
rec() { local s="$*"; STEPS+=("${s% }"); }
steps() { local IFS='|'; printf '%s' "${STEPS[*]}"; }
bsel() {   # START MIN MAX CEILING_GIB  ->  crf_select_boundary over EST
    CALLS=(); STEPS=()
    crf_select_boundary "$1" "$2" "$3" "$(gib "$4")" fake_est rec
}
res() { printf '%s' "$CRF_SELECTED/$CRF_BOUNDARY_LOW/$CRF_AT_FLOOR/$CRF_SEARCH_DIR/${CALLS[*]}"; }

# the request's example: ceiling 5, START 10, floor 8
est 10=4.60 9=4.90 8=5.35
bsel 10 8 21 5
eq "10 fits, 9 fits, 8 over -> 9 (not stopped at the start)" "$(res)" "9/8/0/down/10 9 8"
eq "... report: down, down, down-over, boundary 8 / 9" "$(steps)" "down 10 9|down 9 8|down-over 8|boundary 8 9"
check "... adjacent boundary verified: 8 over, 9 fits" "(( CRF_EST[8] > $(gib 5) && CRF_EST[9] <= $(gib 5) ))"

est 10=3.8 9=4.2 8=4.7
bsel 10 8 21 5
eq "lower bound reached and still fits -> the bound" "$(res)" "8//1/down/10 9 8"
eq "... report: floor"                     "$(steps)" "down 10 9|down 9 8|floor 8"

est 10=5.2 11=4.9
bsel 10 8 21 5
eq "START over -> upward (+1 near the ceiling)" "$(res)" "11/10/0/up/10 11"
est 10=13 11=10 12=8 13=5.4 14=4.8
bsel 10 8 21 5
eq "START far over -> adaptive +2 upward, boundary refined" "$(res)" "14/13/0/up/10 12 14 13"
check "... never below START when START is over" "[[ ' ${CALLS[*]} ' != *' 9 '* ]]"

est 10=4.0 9=5.1
bsel 10 8 21 5
eq "START fits, START - 1 over: START chosen, boundary 9 / 10" "$(res)" "10/9/0/down/10 9"
est 10=4.0
bsel 10 10 21 5
eq "START = SEARCH_MIN (former config) fits: START, no lower CRF" "$(res)/$(steps)" "10//1/down/10/fits 10"
est 10=4.0 9=fail
bsel 10 8 21 5
eq "estimate failure on the way down: nothing selected" "$?/${CRF_SELECTED:-none}" "1/none"
est 10=9
bsel 10 8 21 0
eq "no ceiling: START only"                "$CRF_SELECTED/${CALLS[*]}" "10/10"
est 21=6 20=7 19=8
bsel 21 8 21 5
eq "START = MAX over: over the ceiling"    "$CRF_SELECTED/$CRF_OVER_CEILING/${CALLS[*]}" "21/1/21"
bsel 25 8 21 5
eq "START clamped into MIN..MAX"           "${CALLS[0]}" 21

# every tier: START over / START under / floor, through crf_tier_load
for scope_tier in "movie High" "movie Base" "series High" "series Base"; do
    crf_tier_load $scope_tier "" 7200   # movie: 2 h (High 7 / Base 2 GiB); series: fixed
    s=$CRF_START m=$CRF_MIN x=$CRF_MAX c=$CRF_CEILING_GIB
    est "$s=$(awk -v c="$c" 'BEGIN { print c * 1.02 }')" "$((s + 1))=$(awk -v c="$c" 'BEGIN { print c * 0.95 }')"
    bsel "$s" "$m" "$x" "$c"
    eq "$scope_tier: START over -> up, START + 1 chosen" "$(res)" "$((s + 1))/$s/0/up/$s $((s + 1))"
    est "$s=$(awk -v c="$c" 'BEGIN { print c * 0.92 }')" "$((s - 1))=$(awk -v c="$c" 'BEGIN { print c * 0.98 }')" \
        "$((s - 2))=$(awk -v c="$c" 'BEGIN { print c * 1.07 }')"
    bsel "$s" "$m" "$x" "$c"
    eq "$scope_tier: START under -> down, adjacent boundary" "$(res)" "$((s - 1))/$((s - 2))/0/down/$s $((s - 1)) $((s - 2))"
    est "$s=$(awk -v c="$c" 'BEGIN { print c * 0.5 }')" "$((s - 1))=$(awk -v c="$c" 'BEGIN { print c * 0.6 }')" \
        "$((s - 2))=$(awk -v c="$c" 'BEGIN { print c * 0.7 }')" "$((s - 3))=$(awk -v c="$c" 'BEGIN { print c * 0.8 }')"
    bsel "$s" "$m" "$x" "$c"
    eq "$scope_tier: room left -> SEARCH_MIN ($m), never below it" "$(res)" "$m//1/down/$(seq -s ' ' "$s" -1 "$m")"
done

# randomized monotonic titles (bytes, no awk per probe): = sequential
# search from SEARCH_MIN; each CRF once; down only by 1; boundary verified
declare -A B=()
byte_est() { CALLS+=("$1"); CRF_EST_RESULT="${B[$1]}"; }
rsame=0 rn=0 ronce=0 rstep=0 rbound=0 rdown=0 rup=0 t0=$SECONDS
while read -r start min max ceil vals; do
    B=(); c=0
    for v in $vals; do B[$c]="$v"; ((c += 1)); done
    # sequential reference: lowest CRF from MIN up that fits
    want=""; for ((c = min; c <= max; c++)); do (( ${B[$c]} <= ceil )) && { want="$c/0"; break; }; done
    [[ -n "$want" ]] || want="$max/1"
    CALLS=()
    crf_select_boundary "$start" "$min" "$max" "$ceil" byte_est
    [[ "$CRF_SELECTED/$CRF_OVER_CEILING" == "$want" ]] && ((rsame += 1))
    once=1; unset seen; declare -A seen=()
    for x in "${CALLS[@]}"; do [[ -n "${seen[$x]:-}" ]] && once=0; seen[$x]=1; done
    (( once == 1 )) && ((ronce += 1))
    if [[ "$CRF_SEARCH_DIR" == down ]]; then
        ((rdown += 1))
        okstep=1
        for ((i = 1; i < ${#CALLS[@]}; i++)); do (( CALLS[i] == CALLS[i - 1] - 1 )) || okstep=0; done
        (( okstep == 1 )) && ((rstep += 1))
    else
        ((rup += 1)); ((rstep += 1))
    fi
    if (( CRF_OVER_CEILING == 1 || CRF_SELECTED == min )); then
        ((rbound += 1))
    elif [[ "$CRF_BOUNDARY_LOW" == $((CRF_SELECTED - 1)) && -n "${CRF_EST[$CRF_BOUNDARY_LOW]:-}" ]] &&
         (( ${CRF_EST[$CRF_BOUNDARY_LOW]} > ceil )); then
        ((rbound += 1))
    fi
    ((rn += 1))
done < <(awk 'BEGIN { srand(17)
    for (t = 1; t <= 300; t++) {
        min = int(rand() * 20); max = min + 3 + int(rand() * 15); start = min + int(rand() * (max - min + 1))
        ceil = 1000000; v = ceil * (0.3 + rand() * 8); out = ""
        for (c = 0; c <= max; c++) { out = out " " sprintf("%.0f", v); v = v * (0.6 + rand() * 0.38) }
        # values below min matter too: estimates rise as the CRF falls
        print start, min, max, ceil, out
    } }')
eq "randomized: same CRF as the sequential search from SEARCH_MIN" "$rsame" "$rn"
eq "randomized: each CRF estimated once"   "$ronce" "$rn"
eq "randomized: downward one CRF at a time" "$rstep" "$rn"
eq "randomized: CRF below the chosen one estimated above the ceiling (unless MIN / over)" "$rbound" "$rn"
check "randomized: both directions covered ($rdown down, $rup up)" "(( rdown > 30 && rup > 30 ))"
echo "  (randomized: $rn titles, $((SECONDS - t0)) s)"

check "menus: High / Base search from CRF_START within CRF_MIN..CRF_MAX" \
    "grep -qF 'crf_select_boundary \"\$CRF_START\" \"\$CRF_MIN\" \"\$CRF_MAX\" \"\$CRF_CEILING_BYTES\" crf_title_estimate' '$SRC_WORK/movie_compress.sh' && grep -qF 'crf_select_boundary \"\$CRF_START\" \"\$CRF_MIN\" \"\$CRF_MAX\" \"\$CRF_CEILING_BYTES\" crf_series_estimate_shown' '$SRC_WORK/series_compress.sh'"
check "menus: Custom still one exact estimate" \
    "grep -qF 'crf_select_exact \"\$CUSTOM_CRF\" crf_title_estimate' '$SRC_WORK/movie_compress.sh' && grep -qF 'crf_select_exact \"\$CUSTOM_CRF\" crf_series_estimate_shown' '$SRC_WORK/series_compress.sh'"
CALLS=()
crf_select_exact 17 fake_est
eq "Custom: exactly one estimate at the entered CRF" "$CRF_SELECTED/${CALLS[*]}/${CRF_TRIED[*]}" "17/17/17"

# ------------------------------------------------------------
echo
echo "== 3. movie compact output"

declare -A TGIB=()
crf_sample_title() {   # FILE VIDX FILTER CRF DURATION POINTS
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=$(gib "${TGIB[$4]}")
}
CRF_TITLE_FILE=/m/Film.mkv CRF_TITLE_VIDX=0 CRF_TITLE_FILTER="" CRF_TITLE_DURATION=100 CRF_TITLE_POINTS=5
crf_tier_load movie High "" 7200
TIER=High
TGIB=([12]=6.1 [11]=6.6 [10]=7.3)
crf_select_boundary "$CRF_START" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_title_estimate crf_title_step_report > "$T/m1.out"
sed 's/^/  | /' "$T/m1.out"
eq "movie compact: down to the boundary" "$(tr '\n' '|' < "$T/m1.out")" \
    "  CRF 12   ~6.10 GiB|           fits -> trying CRF 11|  CRF 11   ~6.60 GiB|           fits -> trying CRF 10|  CRF 10   ~7.30 GiB|           too large||Boundary:|  CRF 10  over|  CRF 11  fits|"
TGIB=([12]=3 [11]=3.5 [10]=4)
crf_select_boundary "$CRF_START" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_title_estimate crf_title_step_report > "$T/m2.out"
eq "movie compact: floor" "$(tr '\n' '|' < "$T/m2.out")" \
    "  CRF 12   ~3.00 GiB|           fits -> trying CRF 11|  CRF 11   ~3.50 GiB|           fits -> trying CRF 10|  CRF 10   ~4.00 GiB|           fits (lowest High CRF allowed)|"
unset -f crf_sample_title
source "$WORK_DIR/lib/encode_common.sh" > /dev/null

# ------------------------------------------------------------
echo
echo "== 4. series season below CRF_START (stand-in sample encodes)"

# Stand-in sample encodes: episode En has exactly EPG[n:crf] GiB video at
# its runtime. Records "CRF EPISODE".
declare -A EPG=()
crf_sample_title() {   # FILE VIDX FILTER CRF DURATION POINTS
    local n="${1##*/E}"
    n="${n%.mkv}"
    printf '%s %s\n' "$4" "$n" >> "$T/calls"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=$(awk -v g="${EPG[$n:$4]:-0}" -v d="$5" 'BEGIN { printf "%.0f", g * 1073741824 * 100 / d }')
}
epg() { local n="$1" c="$2"; shift 2; for g in "$@"; do EPG[$n:$c]="$g"; ((c -= 1)); done; }   # N CRF GIB... (CRF, CRF - 1, ...)
season() {   # K DUR...  ->  a batch of episodes E1.. with these runtimes, K sampled
    local k="$1" n
    shift
    FILES=(); EP_VIDX=(); EP_DUR=(); CRF_SERIES_LABELS=(); EP_LABEL=()
    for ((n = 1; n <= $#; n++)); do
        FILES+=("/s/E$n.mkv"); EP_VIDX+=(0); EP_DUR+=("${!n}"); CRF_SERIES_LABELS+=("E$n"); EP_LABEL+=("E$n")
    done
    mapfile -t CRF_SERIES_SAMPLED < <(series_sample_episodes "$#" "$k" "$(series_longest_episode)")
    CRF_SERIES_FILTER=""
    declare -gA CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
    : > "$T/calls"
}
pick() {   # TIER START MIN MAX  ->  the season search of the series menu
    crf_tier_load series "$1"
    crf_select_boundary "$2" "$3" "$4" "$CRF_CEILING_BYTES" crf_series_estimate rec series_crf_certify_over > "$T/sel.out"
}
ncalls() { grep -c "^$1 $2\$" "$T/calls"; }   # CRF EPISODE  ->  sample encodes of it

EPG=()
epg 1 10 4.6 4.9 5.35; epg 2 10 4.4 4.7 5.0; epg 3 10 4.2 4.5 4.8
season 3 2700 2700 2700
STEPS=()
pick High 10 8 21
eq "series High: request's example (10 / 9 fit, 8 over) -> 9" "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" "9/8/10 9 8"
eq "... report"                            "$(steps)" "down 10 9|down 9 8|down-over 8|boundary 8 9"
EPG=()
epg 1 13 1.0 1.1 1.2; epg 2 13 0.9 1.0 1.1; epg 3 13 1.1 1.2 1.3
season 3 2700 2700 2700
pick Base 13 11 27
eq "series Base: room left -> SEARCH_MIN 11, flagged" "$CRF_SELECTED/$CRF_AT_FLOOR/${CRF_TRIED[*]}" "11/1/13 12 11"
EPG=()
epg 1 13 1.6; epg 2 13 1.4; epg 3 13 1.3
epg 1 14 1.45; epg 2 14 1.3; epg 3 14 1.2
season 3 2700 2700 2700
pick Base 13 11 27
eq "series Base: START over -> upward"     "$CRF_SELECTED/$CRF_SEARCH_DIR/${CRF_TRIED[*]}" "14/up/13 14"

# ------------------------------------------------------------
echo
echo "== 5. decisive inferred episodes"

# 4 episodes, E1 / E4 sampled (E4 the longest), E2 / E3 inferred from the
# highest sampled bitrate (E1's). E2 runs 50 min: inferred 4.6 x 50/45 =
# 5.11 GiB at CRF 10, above the 5 GiB ceiling, the largest episode.
base_a() {
    EPG=()
    epg 1 10 4.6; epg 1 11 4.2
    epg 3 10 4.0; epg 3 11 3.7
    epg 4 10 3.0; epg 4 11 2.7
    season 2 2700 3000 2700 3300
}
base_a; epg 2 10 4.2; epg 2 11 3.9
eq "sampled E1 / E4, E2 / E3 inferred"     "${CRF_SERIES_SAMPLED[*]}" "0 3"
pick High 10 10 21
eq "inferred E2 largest + over: sampled before the season CRF rises; real 4.2 fits -> 10 stays" \
    "$CRF_SELECTED/${CRF_TRIED[*]}/$(ncalls 10 2)" "10/10/1"
eq "... E2 promoted, E3 still inferred"    "${CRF_SERIES_EP_FROM[10]}" "sample promoted highest sample"
eq "... E2 estimate replaced by its own sample" \
    "$(read -ra eb <<< "${CRF_SERIES_EP_BYTES[10]}"; bytes_to_gib "${eb[1]}")" "4.20"
eq "... decisive figure recomputed (largest regular E1 / E3: 4.6)" "$(bytes_to_gib "${CRF_EST[10]}")" "4.60"
eq "without the rule the inferred estimate alone would have raised it" \
    "$( series_decisive_inferred() { SD_INDEX=""; return 1; }; base_a; epg 2 10 4.2; epg 2 11 3.9; pick High 10 10 21; echo "$CRF_SELECTED" )" "11"
eq "... own sample stored for later steps (CRF_EP_EST)" "$(bytes_to_gib "${CRF_EP_EST[1:10]:-}")" "4.20"

# cache reuse: crf_episode_estimate (guard / outlier) at the same CRF
: > "$T/calls"
crf_episode_estimate 1 10 > "$T/ce.out"
eq "promoted sample reused by crf_episode_estimate (no new encode)" "$(wc -l < "$T/calls" | tr -d ' ')/$(grep -c 'already sampled' "$T/ce.out")" "0/1"
EP_EST=("${CRF_EP_EST[0:10]}" "${CRF_EP_EST[1:10]}" "$(gib 4.6)" "${CRF_EP_EST[3:10]}")
read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[10]}"
EP_CRF=(10 10 10 10); EP_CEIL_SKIP=(0 0 0 0); EP_VBYTES=("$(gib 1)" "$(gib 1)" "$(gib 100)" "$(gib 1)")
: > "$T/calls"
series_guard_episodes crf_episode_estimate > /dev/null
eq "source guard: a promoted episode counts as sampled (not sampled again)" "$(ncalls 10 2)/${GUARD_SAMPLED[*]}" "0/"
# an own sample already known (e.g. from an earlier step) is reused for the promotion
base_a; epg 2 10 4.2
CRF_EP_EST[1:10]=$(gib 4.2)
crf_tier_load series High
crf_series_estimate 10 > "$T/pre.out"
eq "promotion reuses a known own sample"   "$(ncalls 10 2)/${CRF_SERIES_EP_FROM[10]}" "0/sample promoted highest sample"
check "... shown as already sampled"       "grep -q '^  E2  ~4.20 GiB  sampled after inference (already sampled)\$' '$T/pre.out'"

# the real sample still too large: the season CRF rises (E2 not sampled
# again at 11, where its inferred estimate fits)
base_a; epg 2 10 5.3; epg 2 11 4.8
pick High 10 10 21
eq "real sample still above: season rises to 11" "$CRF_SELECTED/${CRF_TRIED[*]}" "11/10 11"
eq "... E2 sampled once at 10, not at 11 (not decisive there)" "$(ncalls 10 2)/$(ncalls 11 2)" "1/0"
# E2 alone above by its own sample could still be the isolated outlier:
# E3 is sampled as well (4.0) before 10 counts as too large
eq "... at 10 E2 and E3 sampled after inference" "${CRF_SERIES_EP_FROM[10]}" "sample promoted promoted sample"

# E2's own sample is far larger: it becomes the isolated outlier, the
# regular episodes decide (fit at 10); its own CRF from 10 reuses the sample
base_a; epg 2 10 8.0
EPG[2:11]=7.0; EPG[2:12]=6.0; EPG[2:13]=5.2; EPG[2:14]=4.6
pick High 10 10 21
read -ra eb <<< "${CRF_SERIES_EP_BYTES[10]}"
series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}"
eq "sampled E2 becomes the isolated outlier: season 10" "$CRF_SELECTED/$SB_ISOLATED/$SB_FITS" "10/1/1"
series_episode_crf 1 10 21 "$CRF_CEILING_BYTES" crf_episode_estimate > /dev/null
eq "... own CRF 14, the season-CRF sample reused" "$EPC_CRF/$(ncalls 10 2)/${EPC_TRIED[*]}" "14/1/10 12 13 14"

# downward with promotions: the request's example on the season
base_a; epg 1 9 4.9 5.35; epg 2 10 4.2 4.5 4.8; epg 3 9 4.3 4.7; epg 4 9 3.2 3.4
pick High 10 8 21
eq "down: 10, 9 fit (E2 promoted at both), 8 over by own samples -> 9" "$CRF_SELECTED/$CRF_BOUNDARY_LOW/${CRF_TRIED[*]}" "9/8/10 9 8"
eq "... at 8 the inferred E2 / E3 were sampled before 8 counted as too large" "${CRF_SERIES_EP_FROM[8]}" "sample promoted promoted sample"

# several inferred candidates: only as many as needed
#   6 episodes, E1 / E6 sampled; E2..E5 inferred
six() { EPG=(); season 2 2700 2900 2800 2760 2700 3300; }
six; epg 1 10 5.5; epg 6 10 6.2
crf_tier_load series High
crf_series_estimate 10 > /dev/null
eq "two sampled episodes above: proven, no inferred one sampled" \
    "$(wc -l < "$T/calls" | tr -d ' ')/${CRF_SERIES_EP_FROM[10]}" "2/sample highest highest highest highest sample"
check "... the CRF still counts as too large" "(( CRF_EST_RESULT > CRF_CEILING_BYTES ))"
six; epg 1 10 4.9; epg 6 10 3.0; epg 2 10 5.6; epg 3 10 5.5; epg 4 10 4.0; epg 5 10 4.0
crf_series_estimate 10 > /dev/null
eq "largest inferred first (E2), then E3; proven after two -> E4 / E5 never sampled" \
    "$(cut -d' ' -f2 "$T/calls" | tr '\n' ' ')/${CRF_SERIES_EP_FROM[10]}" "1 6 2 3 /sample promoted promoted highest highest sample"
six; epg 1 10 4.9; epg 6 10 3.0; epg 2 10 4.0; epg 3 10 4.1; epg 4 10 3.9; epg 5 10 4.0
crf_series_estimate 10 > /dev/null
# E2's real 4.0 makes E1 the only high sampled rate (an isolated sampled
# outlier): the others are refilled from E2's rate and fit
eq "one real sample settles it: E2 only, E3..E5 never sampled" \
    "$(cut -d' ' -f2 "$T/calls" | tr '\n' ' ')/${CRF_SERIES_EP_FROM[10]}/$(( CRF_EST_RESULT <= CRF_CEILING_BYTES ))" \
    "1 6 2 /sample promoted highest highest highest sample/1"

# every inferred episode is filled with the sampled E1's high rate (only
# two sampled), so they all look as large as E1; one real sample shows the
# season is easy and E1 is the isolated outlier
EPG=(); season 2 2700 2700 2700 2700 2700 2800
epg 1 10 5.6; epg 6 10 2.0; epg 2 10 2.1; epg 3 10 2.2; epg 4 10 2.0; epg 5 10 2.1
crf_series_estimate 10 > /dev/null
eq "inferred copies of a sampled outlier: one real sample, season fits, E1 isolated" \
    "$(( CRF_EST_RESULT <= CRF_CEILING_BYTES ))/${CRF_SERIES_EP_FROM[10]}/$SB_ISOLATED" "1/sample promoted highest highest highest sample/0"

# decision helper on its own
SC_EP_BYTES=(10 20 30 5); SC_EP_FROM=(sample highest highest sample)
series_batch_stats 15 "${SC_EP_BYTES[@]}"
series_decisive_inferred 15; eq "helper: largest decisive inferred (E3)" "$?/$SD_INDEX" "0/2"
SC_EP_FROM=(sample sample highest sample); SC_EP_BYTES=(16 17 30 5)
series_batch_stats 15 "${SC_EP_BYTES[@]}"
series_decisive_inferred 15; eq "helper: two sampled over -> nothing to sample" "$?/$SD_INDEX" "1/"
series_batch_stats 0 "${SC_EP_BYTES[@]}"
series_decisive_inferred 0; eq "helper: no ceiling (Custom) -> nothing" "$?" 1
# an inferred outlier below the ceiling keeps the sampled E1 (over) from
# being the isolated outlier: it is the one to sample
SC_EP_BYTES=(60 50 20 20 20); SC_EP_FROM=(sample highest sample sample sample)
series_batch_stats 55 "${SC_EP_BYTES[@]}"
series_decisive_inferred 55; eq "helper: inferred outlier (not over) decides -> sampled" "$?/$SD_INDEX/${SB_OUTLIERS[*]}" "0/1/0 1"
SC_EP_BYTES=(10 20 22 5 99); SC_EP_FROM=(sample sample sample sample highest)
series_batch_stats 21 "${SC_EP_BYTES[@]}"
series_decisive_inferred 21; eq "helper: an inferred isolated outlier never decides (sampled 22 fails alone)" "$?/$SB_ISOLATED/$SB_FITS" "1/4/0"

# Custom: exact CRF, no ceiling, nothing promoted
season 2 2700 3000 2700 3300
EPG=(); epg 1 16 9; epg 4 16 9
crf_tier_load series Custom 16
crf_select_exact 16 crf_series_estimate > /dev/null
eq "Custom: one estimate, inferred episodes stay inferred" "${CRF_TRIED[*]}/${CRF_SERIES_EP_FROM[16]}/$(wc -l < "$T/calls" | tr -d ' ')" "16/sample highest highest sample/2"

# labels
eq "labels"  "$(series_from_text sample)|$(series_from_text promoted)|$(series_from_text highest)" \
    "sampled|sampled after inference|inferred"
check "series_from_sampled: sample / promoted yes, highest no" \
    "series_from_sampled sample && series_from_sampled promoted && ! series_from_sampled highest"

# compact menu output (the menu's own functions)
eval "$(sed -n '/^crf_series_estimate_shown() {/,/^}/p; /^crf_series_step_report() {/,/^}/p' "$SRC_WORK/series_compress.sh")"
TIER=High
base_a; epg 2 10 4.2; epg 2 11 3.9
crf_tier_load series High
crf_select_boundary 10 10 21 "$CRF_CEILING_BYTES" crf_series_estimate_shown crf_series_step_report series_crf_certify_over > "$T/ui.out"
sed 's/^/  | /' "$T/ui.out"
eq "UI: inferred largest, promotion line, sampled largest" \
    "$(grep -E '^(Largest:|  E[0-9]  |Selected:)' "$T/ui.out" | tr '\n' '|')" \
    "  E1  ~4.60 GiB|  E4  ~3.00 GiB|Largest:  5.11 GiB (E2, inferred)|  E2  ~4.20 GiB  sampled after inference|Largest:  4.60 GiB (E1, sampled)|Selected: CRF 10|"
base_a; epg 2 10 5.3; epg 2 11 4.8
crf_select_boundary 10 10 21 "$CRF_CEILING_BYTES" crf_series_estimate_shown crf_series_step_report series_crf_certify_over > "$T/ui2.out"
check "UI: a promoted episode still the largest is labelled so" \
    "grep -q '^Largest:  5.30 GiB (E2, sampled after inference)\$' '$T/ui2.out'"
COMPRESS_VERBOSE=1 crf_series_estimate 10 > "$T/uiv.out"
check "UI verbose: promotion explained" \
    "grep -q 'E2.mkv not sampled, decides the season at CRF 10 (~5.11 GiB video, inferred); sampling it\\.\\.\\. ~5.30 GiB video' '$T/uiv.out'"
check "series table legend: promoted" "grep -q 'promoted = not in the sample set' '$SRC_WORK/series_compress.sh'"
unset -f crf_sample_title
source "$WORK_DIR/lib/encode_common.sh" > /dev/null

# ------------------------------------------------------------
echo
echo "== 6. Quality: adjacent boundary, choice unchanged"

qsel() {   # START MAX [SOURCE_GIB]  ->  crf_select_quality over EST (band 18-22, target 20)
    local src=""
    [[ -n "${3:-}" ]] && src=$(gib "$3")
    CALLS=(); STEPS=()
    crf_select_quality 0 "$1" "$2" "$(gib 20)" "$(gib 18)" "$(gib 22)" "$src" fake_est rec
}
est 8=40 9=30 10=21
qsel 8 23
eq "upward: boundary 9 over / 10 at or below the band's edge, 10 band" "$CRF_BOUNDARY_LOW/$CRF_BOUNDARY_HIGH/$CRF_SELECTED/$QUALITY_PICK" "9/10/10/band"
est 8=19 7=17.5 6=21 5=23
qsel 8 23
eq "downward: boundary 5 / 6, lowest CRF inside the band (6)" "$CRF_BOUNDARY_LOW/$CRF_BOUNDARY_HIGH/$CRF_SELECTED/$QUALITY_PICK" "5/6/6/band"
est 8=40 9=30 10=17
qsel 8 23
eq "nothing inside the band: boundary 9 / 10, closest to the target chosen" "$CRF_BOUNDARY_LOW/$CRF_BOUNDARY_HIGH/$CRF_SELECTED/$QUALITY_PICK" "9/10/10/closest"
est 8=23 9=17.5
qsel 8 23
eq "both sides estimated; the Quality rule picks the closer side (8: 3 vs 2.5 -> 9)" "$CRF_BOUNDARY_LOW/$CRF_BOUNDARY_HIGH/$CRF_SELECTED" "8/9/9"
est 3=15 2=16 1=17 0=17.5
qsel 3 23
eq "CRF_MIN still fits: no boundary"       "$CRF_BOUNDARY_LOW/$CRF_BOUNDARY_HIGH/$CRF_SELECTED" "//0"

# the former Quality search (before the shared boundary search), kept here
# as the reference: same estimates in the same order -> same choice
old_quality_tried() {   # MIN START MAX CAP  ->  REF_TRIED: CRFs estimated
    local min="$1" start="$2" max="$3" cap="$4" c
    declare -gA CRF_EST=()
    CRF_TRIED=()
    _CRF_SELECT_EST=byte_est
    (( start < min )) && start="$min"
    (( start > max )) && start="$max"
    _crfs_probe _crf_select_probe "$start"
    if (( CRF_EST_RESULT > cap )); then
        crf_search_up "$start" "$max" "$cap" _crf_select_probe
    else
        for ((c = start - 1; c >= min; c--)); do
            _crfs_probe _crf_select_probe "$c"
            (( CRF_EST_RESULT > cap )) && break
        done
    fi
    REF_TRIED="${CRF_TRIED[*]}"
}
qsame=0 qn=0 t0=$SECONDS
while read -r min start max src vals; do
    B=(); c=0
    for v in $vals; do B[$c]="$v"; ((c += 1)); done
    [[ "$src" == x ]] && src=""
    cap=22000; [[ -n "$src" ]] && (( src - 1 < cap )) && cap=$((src - 1))
    old_quality_tried "$min" "$start" "$max" "$cap"; ref="$REF_TRIED"
    crf_select_quality "$min" "$start" "$max" 20000 18000 22000 "$src" byte_est
    [[ "${CRF_TRIED[*]}" == "$ref" ]] && ((qsame += 1))
    ((qn += 1))
done < <(awk 'BEGIN { srand(23)
    for (t = 1; t <= 250; t++) {
        min = int(rand() * 6); max = min + 2 + int(rand() * 14); start = min + int(rand() * (max - min + 1))
        src = (rand() < 0.3) ? sprintf("%.0f", 15000 + rand() * 30000) : "x"
        v = 8000 + rand() * 60000; out = ""
        for (c = 0; c <= max; c++) {
            out = out " " sprintf("%.0f", v)
            v = (rand() < 0.15) ? v * (0.9 + rand() * 0.25) : v * (0.55 + rand() * 0.44)   # some non-monotonic
        }
        print min, start, max, src, out
    } }')
eq "Quality: same CRFs estimated (in order) as the former search -> same choice" "$qsame" "$qn"
echo "  (Quality randomized: $qn titles, $((SECONDS - t0)) s)"

# ------------------------------------------------------------
echo
echo "== 7. per-section diagnostics (sampling unchanged)"

CRF_SAMPLE_PARTS="270.000:20.000:25000000 1350.000:20.000:5000000 2430.000:20.000:24000000"
eq "section rates at their runtime positions" "$(crf_sample_parts_text 2700)" "10%: 10.0, 50%: 2.0, 90%: 9.6 Mb/s"
eq "sample points unchanged: 3 sections at 10 / 50 / 90 %" "$(crf_sample_points 2700 3 20 | tr '\n' '|')" "260.000 20.000|1340.000 20.000|2420.000 20.000|"
eq "aggregation unchanged: total bytes / total seconds x runtime" "$(crf_extrapolate 54000000 60 2700)" "2430000000"

# ------------------------------------------------------------
echo
echo "== 8. set -euo pipefail"

cat > "$T/setu.sh" <<EOF
set -euo pipefail
WORK_DIR='$WORK_DIR'
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do source "\$WORK_DIR/lib/\$l.sh" > /dev/null; done
COMPRESS_CONF='$COMPRESS_CONF' load_policy > /dev/null
declare -A E=([8]=535 [9]=490 [10]=460 [11]=420 [12]=380)
e() { CRF_EST_RESULT="\${E[\$1]}"; }
crf_select_boundary 10 8 21 500 e crf_title_step_report > /dev/null
[[ "\$CRF_SELECTED/\$CRF_BOUNDARY_LOW/\$CRF_SEARCH_DIR" == "9/8/down" ]]
E=([8]=400 [9]=420 [10]=460)
crf_select_boundary 10 8 21 500 e crf_title_step_report > /dev/null
[[ "\$CRF_SELECTED/\$CRF_AT_FLOOR" == "8/1" ]]
E=([10]=900 [11]=700 [12]=480 [13]=450)
crf_select_boundary 10 8 21 500 e crf_title_step_report > /dev/null
[[ "\$CRF_SELECTED/\$CRF_SEARCH_DIR" == "12/up" ]]
crf_select_boundary 10 8 21 0 e > /dev/null
crf_select 10 21 500 e > /dev/null
E=([8]=2100 [7]=1900 [6]=2300)
crf_select_quality 0 8 23 2000 1800 2200 "" e crf_title_step_report > /dev/null
[[ "\$CRF_SELECTED/\$CRF_BOUNDARY_LOW/\$CRF_BOUNDARY_HIGH" == "7/6/7" ]]
SC_EP_BYTES=(10 20 30 5); SC_EP_FROM=(sample highest highest sample)
series_batch_stats 15 "\${SC_EP_BYTES[@]}"
series_decisive_inferred 15 || true
SC_EP_FROM=(sample sample sample sample)
series_decisive_inferred 15 || true
series_decisive_inferred 0 || true
series_from_text promoted > /dev/null; series_from_text highest > /dev/null
series_from_sampled highest || true
for k in down down-over floor; do crf_step_result "\$k" 10 9 > /dev/null; done
crf_title_step_report down 10 9 > /dev/null
crf_title_step_report floor 8 > /dev/null
CRF_SAMPLE_PARTS=""; crf_sample_parts_text 100 > /dev/null
CRF_SAMPLE_PARTS="0:20:1000"; crf_sample_parts_text 100 > /dev/null
f=\$(mktemp); grep -v '^SERIES_HIGH_CRF_\(START\|SEARCH_MIN\)=' '$COMPRESS_CONF' > "\$f"; echo SERIES_HIGH_CRF_MIN=10 >> "\$f"
COMPRESS_CONF="\$f" load_policy 2> /dev/null
rm -f "\$f"
echo survived
EOF
eq "boundary search / decisive inference under set -euo pipefail" "$(bash "$T/setu.sh" 2>&1 | tail -1)" "survived"

# the season estimator with promotions under set -euo pipefail
cat > "$T/setu2.sh" <<EOF
set -euo pipefail
WORK_DIR='$WORK_DIR'
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do source "\$WORK_DIR/lib/\$l.sh" > /dev/null; done
COMPRESS_CONF='$COMPRESS_CONF' load_policy > /dev/null
declare -A EPG=([1:10]=4.6 [2:10]=4.2 [3:10]=4.0 [4:10]=3.0 [1:9]=4.9 [2:9]=4.5 [3:9]=4.3 [4:9]=3.2 [1:8]=5.35 [2:8]=4.8 [3:8]=4.7 [4:8]=3.4)
crf_sample_title() {
    local n="\${1##*/E}"; n="\${n%.mkv}"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=\$(awk -v g="\${EPG[\$n:\$4]}" -v d="\$5" 'BEGIN { printf "%.0f", g * 1073741824 * 100 / d }')
}
FILES=(/s/E1.mkv /s/E2.mkv /s/E3.mkv /s/E4.mkv); EP_VIDX=(0 0 0 0); EP_DUR=(2700 3000 2700 3300)
CRF_SERIES_LABELS=(E1 E2 E3 E4); CRF_SERIES_SAMPLED=(0 3); CRF_SERIES_FILTER=""
declare -A CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
crf_tier_load series High
crf_select_boundary 10 8 21 "\$CRF_CEILING_BYTES" crf_series_estimate crf_episode_step_report series_crf_certify_over > /dev/null
[[ "\$CRF_SELECTED" == 9 ]]
COMPRESS_VERBOSE=1 crf_series_estimate 10 > /dev/null
echo survived
EOF
eq "season estimator with promotions under set -euo pipefail" "$(bash "$T/setu2.sh" 2>&1 | tail -1)" "survived"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
