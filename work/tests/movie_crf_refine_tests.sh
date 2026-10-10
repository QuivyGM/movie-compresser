#!/usr/bin/env bash
# Movie High / Base post-encode CRF refinement (down_mode=boundary): once
# an attempt fits the video ceiling, CRF - 1 is encoded exactly once and
# kept only when its ACTUAL video fits. Series and movie Quality keep
# their headroom-gated lower-CRF retry.
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

echo "== per-episode headroom retry unchanged (no down_mode: headroom + predicted-fit gate;"
echo "   the series items of earlier job scripts, compatibility)"

S="ceiling_vbytes=$(gib 5) crf_min=16 crf_max=21 down_headroom_pct=20 down_max=1 down_fit_pct=5"
movie_job s1 High 18 "$S" "[18]='$(gib 4.5) 0' [17]='$(gib 4.6) 0'"
eq    "5 fits without 20 % headroom: no lower CRF" "$(encoded s1)/$(final)" "18 /18"
movie_job s2 High 18 "$S" "[18]='$(gib 3) 0' [17]='$(gib 3.4) 0' [16]='$(gib 3.8) 0'"
eq    "5 headroom: one lower CRF (down_max 1)"    "$(encoded s2)/$(final)" "18 17 /17"
check "5 old log wording"                         "logs s2 'Headroom large -> trying CRF 17' && logs s2 'Result: accepted'"
check "5 series menu spec: shared season batch, no boundary mode" \
    "grep -qF 'series_season_retry_spec \"\$TIER\" \"\$CRF_CEILING_BYTES\" \"\$CRF_MAX\" \"\$CRF_MIN\"' '$SRC_WORK/series_compress.sh' && ! grep -q boundary <(sed -n '/^ep_retry_spec() {/,/^}/p' '$SRC_WORK/series_compress.sh') && ! grep -q boundary <(sed -n '/^series_season_retry_spec() {/,/^}/p' '$SRC_WORK/lib/policy.sh')"

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
