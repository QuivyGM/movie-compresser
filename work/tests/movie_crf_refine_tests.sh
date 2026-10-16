#!/usr/bin/env bash
# Movie High / Base post-encode CRF refinement (down_mode=boundary): once
# an attempt fits the video ceiling, High (and job scripts of earlier
# versions, down_max=1) encode CRF - 1 exactly once and keep it only when
# its ACTUAL video fits; Base (down_max=CRF_LIMIT) walks down one CRF at a
# time while each actual fits (cached actual results above the ceiling
# are not encoded again), with its video floor (floor_vbytes /
# floor_crf_min). Series and movie Quality keep their headroom-gated
# lower-CRF retry.
#
#   bash ~/compress/work/tests/movie_crf_refine_tests.sh
#
# Generated-style jobs with a stand-in encoder (sizes per CRF, no
# ffmpeg), as in crf_retry_tests.sh.
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
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }   # GiB -> bytes

W="$T/work"
mkdir -p "$W/logs" "$T/in" "$T/out" "$T/stub"
cp -r "$SRC_WORK/lib" "$W/"
WORK_DIR="$W"
for l in media_probe media_stats bitrate encode_common hdr_dovi job_runtime; do
    source "$W/lib/$l.sh" > /dev/null
done
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
export PATH="$T/stub:$PATH"
echo movie > "$T/in/M.mkv"

# the "encoder" writes "VIDEO_BYTES AUDIO_BYTES CRF" into $ITEM_PART
STUBS='
get_duration() { echo 100; }
media_stream_totals() { local v a c; read -r v a c < "$1"; echo "$v $a"; }
item_verify_output() { echo "${ITEM_EXP[crf]}" >> "'"$T"'/$JOB_SESSION.verified"; }
refresh_mkv_stats() { return 0; }
get_resolution() { echo 1920x1080; }
main_video_index() { echo 0; }
declare -A SIZES=()
fake_encode() {
    local c="${ITEM_EXP[crf]}"
    echo "$c" >> "'"$T"'/$JOB_SESSION.encoded"
    [[ "${SIZES[$c]}" == fail ]] && return 1
    echo "${SIZES[$c]} $c" > "$ITEM_PART"
}
'

# movie_job SESSION TIER CRF EXPECT_EXTRA SIZES...
movie_job() {
    local s="$1" tier="$2" crf="$3" extra="$4"
    shift 4
    rm -f "$T/out/M.mkv"
    {
        emit_job_header "$s" movie 1
        printf '%s\n' "$STUBS" "SIZES=($*)
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' $tier 0 '' &&
   item_expect vidx=0 mode=crf crf=$crf kbps= est_vbytes=$(gib 7.84) atrans= ahash=1 $extra &&
   item_crf_encode item_encode_1
then
    item_succeeded
else
    item_failed
fi"
        emit_job_footer
    } > "$W/$s.sh"
    bash "$W/$s.sh" < /dev/null > "$T/$s.log" 2>&1
}
encoded()   { tr '\n' ' ' < "$T/$1.encoded" 2>/dev/null; }
final()     { awk '{ print $3 }' "$T/out/M.mkv" 2>/dev/null; }
verified()  { tr '\n' ' ' < "$T/$1.verified" 2>/dev/null; }
leftovers() { find "$T/out" \( -name '*.part' -o -name '*.retry-crf*' \) | sort | tr '\n' ' '; }
logs()      { grep -qxF "$2" "$T/$1.log"; }

# the example: ceiling 8.35 GiB, estimates CRF 12 = 9.72 (over), 13 = 7.84
# -> CRF 13 selected. The menu's spec: "...:0:1:::boundary"; the CRF 12
# estimate must not block the actual test.
B="ceiling_vbytes=$(gib 8.35) crf_min=10 crf_max=20 down_headroom_pct=0 down_max=1 down_mode=boundary crf_est=12=$(gib 9.72):13=$(gib 7.84)"

echo "== movie High / Base: one CRF - 1 test"

movie_job b1 High 13 "$B" "[13]='$(gib 6.7) $(gib 2)' [12]='$(gib 6.78) $(gib 2)' [11]='$(gib 6.9) 0'"
eq    "1 N fits, N-1 fits: CRF 12 tested once (no N-2)" "$(encoded b1)" "13 12 "
eq    "1 CRF 12 kept and verified"                "$(final)/$(verified b1)" "12/12 "
check "1 log" "logs b1 'CRF 13 actual: 6.70 GiB / 8.35 GiB ceiling' && logs b1 'Testing CRF 12 for better quality...' && logs b1 'CRF 12 actual: 6.78 GiB / 8.35 GiB ceiling -> fits' && logs b1 'Keeping CRF 12'"
eq    "1 CRF 13 discarded, no temp files"         "$(leftovers)" ""

movie_job b2 Base 13 "$B" "[13]='$(gib 6.7) 0' [12]='$(gib 8.9) 0'"
eq    "2 N fits, N-1 over: CRF 12 tested once"    "$(encoded b2)" "13 12 "
eq    "2 CRF 13 kept and verified"                "$(final)/$(verified b2)" "13/13 "
check "2 log" "logs b2 'CRF 12 actual: 8.90 GiB / 8.35 GiB ceiling -> over ceiling' && logs b2 'Keeping CRF 13'"
eq    "2 CRF 12 discarded, no temp files"         "$(leftovers)" ""

movie_job b2b High 13 "$B" "[13]='$(gib 8.3) 0' [12]='$(gib 8.2) 0'"
eq    "2b no headroom needed (8.30 of 8.35 GiB): CRF 12 still tested" "$(encoded b2b)/$(final)" "13 12 /12"

movie_job b2c High 13 "$B" "[13]='$(gib 6.7) 0' [12]=fail"
eq    "2c CRF 12 encode fails: CRF 13 kept"       "$(encoded b2c)/$(final)/$(leftovers)" "13 12 /13/"

movie_job b3 High 13 "$B" "[13]='$(gib 8.6) 0' [14]='$(gib 7.5) 0'"
eq    "3 N over: upward retry unchanged; 13 proven over, not retried" "$(encoded b3)/$(final)" "13 14 /14"
check "3 log" "logs b3 'Result: over ceiling -> retrying CRF 14' && logs b3 'CRF 13 was already over the ceiling; keeping CRF 14'"

movie_job b3b High 13 "$B" "[13]='$(gib 9) 0' [14]='$(gib 8.5) 0' [15]='$(gib 7) 0'"
eq    "3b two steps up: final 15, 14 proven over" "$(encoded b3b)/$(final)/$(leftovers)" "13 14 15 /15/"

movie_job b4 High 10 "$B" "[10]='$(gib 5) 0'"
eq    "4 N == SEARCH_MIN: no downward test"       "$(encoded b4)/$(final)" "10 /10"
check "4 log"                                     "logs b4 'CRF 10 is the High minimum; keeping CRF 10'"

check "4 menu floor is the search min: spec carries CRF_MIN" \
    "grep -qF '[[ \"\$TIER\" != \"Custom\" ]] && RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:0:1:::boundary\"' '$SRC_WORK/movie_compress.sh'"

echo "== movie Base: walk down while each actual fits (down_max=CRF_LIMIT), video floor"

# the menu's Base spec: "...:0:51:::boundary:FLOOR_BYTES:FLOOR_CRF_MIN"
BW="ceiling_vbytes=$(gib 8.35) crf_min=10 crf_max=20 down_headroom_pct=0 down_max=51 down_mode=boundary floor_vbytes=0 floor_crf_min=10 crf_est=12=$(gib 9.72):13=$(gib 7.84)"
below_floor() { grep -q '^Below the Base video floor' "$T/$1.log"; }

movie_job w1 Base 13 "$BW" "[13]='$(gib 6.7) 0' [12]='$(gib 7.2) 0' [11]='$(gib 7.9) 0' [10]='$(gib 8.6) 0'"
eq    "7 N fits, N-1 fits -> N-2 tested too, until one is over" "$(encoded w1)" "13 12 11 10 "
eq    "7 lowest fitting CRF 11 kept and verified" "$(final)/$(verified w1)/$(leftovers)" "11/11 /"
check "7 log" "logs w1 'CRF 10 actual: 8.60 GiB / 8.35 GiB ceiling -> over ceiling' && logs w1 'Keeping CRF 11'"
check "7 no floor flag without a floor" "! below_floor w1"

movie_job w2 Base 13 "$BW" "[13]='$(gib 6.7) 0' [12]='$(gib 8.9) 0'"
eq    "8 N fits, N-1 over -> N"                   "$(encoded w2)/$(final)/$(leftovers)" "13 12 /13/"

movie_job w3 Base 13 "$BW" "[13]='$(gib 5) 0' [12]='$(gib 5.5) 0' [11]='$(gib 6) 0' [10]='$(gib 6.5) 0' [9]='$(gib 7) 0'"
eq    "9 every CRF fits: walk stops at crf_min 10" "$(encoded w3)/$(final)" "13 12 11 10 /10"
check "9 log" "logs w3 'CRF 10 is the Base minimum; keeping CRF 10'"

movie_job w4 Base 13 "$BW" "[13]='$(gib 8.6) 0' [14]='$(gib 7.5) 0'"
eq    "10 N over: up to 14; 13 proven over, no walk" "$(encoded w4)/$(final)" "13 14 /14"

movie_job w5 Base 13 "$BW" "[13]='$(gib 6.7) 0' [12]=fail"
eq    "11 N-1 encode fails: N kept"               "$(encoded w5)/$(final)/$(leftovers)" "13 12 /13/"

# cached actual results (same source + settings): an N-1 cached above the
# ceiling is not encoded again; a cached fitting one still is (its file
# is needed)
SIG="$CRF_ACTUAL_SCHEMA|stat=$(stat -L -c '%s %Y' -- "$T/in/M.mkv")|refine-test"
BWS="$BW actual_sig=$(printf '%q' "$SIG")"
movie_job c1 Base 13 "$BWS" "[13]='$(gib 6.7) 0' [12]='$(gib 8.9) 0'"
eq    "12 first job: 13 fits, 12 over (both saved)" "$(encoded c1)/$(final)" "13 12 /13"
movie_job c2 Base 13 "$BWS" "[13]='$(gib 6.7) 0' [12]='$(gib 8.9) 0'"
eq    "12 cached CRF 12 over the ceiling: not encoded again" "$(encoded c2)/$(final)" "13 /13"
check "12 log" "logs c2 'CRF 12 actual (cached): 8.90 GiB / 8.35 GiB ceiling -> over ceiling; keeping CRF 13'"
( WORK_DIR="$W" crf_actual_save "$SIG" 12 "$(gib 7.0)" )
movie_job c3 Base 13 "$BWS" "[13]='$(gib 6.7) 0' [12]='$(gib 7.0) 0' [11]='$(gib 8.8) 0'"
eq    "12 cached CRF 12 fitting: still encoded, walk continues to 11" "$(encoded c3)/$(final)" "13 12 11 /12"

# the floor (floor_vbytes; the stand-in runtime is 100 s)
BF="ceiling_vbytes=$(gib 8.35) crf_min=10 crf_max=20 down_headroom_pct=0 down_max=51 down_mode=boundary floor_vbytes=$(gib 7.5) floor_crf_min=8"
movie_job f1 Base 13 "$BF" "[13]='$(gib 6.7) 0' [12]='$(gib 7.2) 0' [11]='$(gib 8.6) 0'"
eq    "13 floor between two CRFs (12 below, 11 over): 12 kept" "$(encoded f1)/$(final)" "13 12 11 /12"
check "13 below the floor: flagged, never silent" "logs f1 '         (no lower CRF allowed fits the ceiling and reaches it); keeping CRF 12.' && below_floor f1"

movie_job f2 Base 10 "$BF" "[10]='$(gib 5) 0' [9]='$(gib 6.5) 0' [8]='$(gib 7.6) 0' [7]='$(gib 7.8) 0'"
eq    "14 below the floor at crf_min: below it down to the floor (8)" "$(encoded f2)/$(final)" "10 9 8 /8"
check "14 log, no flag" "grep -q '^Below the .* Mb/s video floor -> testing CRF 9...\$' '$T/f2.log' && grep -q '^CRF 8 reaches the .* Mb/s video floor; keeping CRF 8\$' '$T/f2.log' && ! below_floor f2"

movie_job f3 Base 10 "$BF" "[10]='$(gib 5) 0' [9]='$(gib 5.5) 0' [8]='$(gib 6) 0' [7]='$(gib 7.6) 0'"
eq    "15 floor_crf_min 8 still below: stop there, flagged" "$(encoded f3)/$(final)" "10 9 8 /8"
check "15 log" "logs f3 'CRF 8 is the lowest CRF the Base video floor allows; keeping CRF 8' && below_floor f3"

movie_job f4 Base 10 "$BF" "[10]='$(gib 5) 0' [9]='$(gib 9) 0'"
eq    "16 below the floor, CRF - 1 over the ceiling: kept, flagged" "$(encoded f4)/$(final)" "10 9 /10"
check "16 flag" "below_floor f4"

movie_job f5 Base 8 "$BF" "[8]='$(gib 7.6) 0' [7]='$(gib 7.8) 0'"
eq    "17 planned below crf_min (search reached the floor): no lower CRF" "$(encoded f5)/$(final)" "8 /8"

movie_job f6 Base 13 "$BF" "[13]='$(gib 8.0) 0' [12]='$(gib 8.9) 0'"
eq    "18 above the floor: walk as without a floor" "$(encoded f6)/$(final)" "13 12 /13"
check "18 no flag" "! below_floor f6"

movie_job f7 Base 10 "${BF/floor_vbytes=$(gib 7.5)/floor_vbytes=0}" "[10]='$(gib 5) 0' [9]='$(gib 6) 0'"
eq    "19 floor 0 (source exempt): never below crf_min" "$(encoded f7)/$(final)" "10 /10"
check "19 no flag" "! below_floor f7"

echo "== per-episode headroom retry unchanged (no down_mode: headroom + predicted-fit gate;"
echo "   the series items of earlier job scripts, compatibility)"

S="ceiling_vbytes=$(gib 5) crf_min=16 crf_max=21 down_headroom_pct=20 down_max=1 down_fit_pct=5"
movie_job s1 High 18 "$S" "[18]='$(gib 4.5) 0' [17]='$(gib 4.6) 0'"
eq    "5 fits without 20 % headroom: no lower CRF" "$(encoded s1)/$(final)" "18 /18"
movie_job s2 High 18 "$S" "[18]='$(gib 3) 0' [17]='$(gib 3.4) 0' [16]='$(gib 3.8) 0'"
eq    "5 headroom: one lower CRF (down_max 1)"    "$(encoded s2)/$(final)" "18 17 /17"
check "5 old log wording"                         "logs s2 'Headroom large -> trying CRF 17' && logs s2 'Result: accepted'"
check "5 series menu spec: shared season batch, no boundary mode" \
    "grep -qF 'series_season_retry_spec \"\$TIER\" \"\$(series_ep_ceil \"\$1\")\" \"\$CRF_MAX\" \"\$CRF_MIN\"' '$SRC_WORK/series_compress.sh' && ! grep -q boundary <(sed -n '/^ep_retry_spec() {/,/^}/p' '$SRC_WORK/series_compress.sh') && ! grep -q boundary <(sed -n '/^series_season_retry_spec() {/,/^}/p' '$SRC_WORK/lib/policy.sh')"

echo "== movie Quality unchanged (band)"

Q="ceiling_vbytes=$(gib 22) crf_min=0 crf_max=23 down_headroom_pct=20 down_max=2 qtarget_vbytes=$(gib 20) qmin_vbytes=$(gib 18) qmax_vbytes=$(gib 22) qstatus=band down_below_vbytes=$(gib 18)"
movie_job q1 Quality 9 "$Q" "[9]='$(gib 21.5) 0' [8]='$(gib 21.8) 0'"
eq    "6 inside the band: no lower CRF"           "$(encoded q1)/$(final)" "9 /9"
movie_job q2 Quality 9 "$Q" "[9]='$(gib 12) 0' [8]='$(gib 14) 0' [7]='$(gib 16) 0' [6]='$(gib 19) 0'"
eq    "6 below the band: up to down_max (2) lower CRFs" "$(encoded q2)/$(final)" "9 8 7 /7"
check "6 Quality menu spec unchanged" \
    "grep -qF 'RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:\$CRF_DOWN_RETRY_HEADROOM_PCT:\$CRF_DOWN_RETRY_MAX\"' '$SRC_WORK/movie_compress.sh'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
