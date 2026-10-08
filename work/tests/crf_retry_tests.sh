#!/usr/bin/env bash
# Post-encode CRF retry tests (High / Base video ceiling, movie Quality
# band; upward and lower-CRF retries, CRF log header).
#
#   bash ~/compress/work/tests/crf_retry_tests.sh
#
# Part 1 runs generated-style jobs with a stand-in encoder (sizes per
# CRF, no ffmpeg): movie retry rules, series episodes retried one by one
# (own CRF, predicted-fit check of a lower CRF), the season batch of job
# scripts from earlier versions (median episode), logging, temporary
# files, interruption, other sessions.
# Part 2 (ffmpeg with libx265 needed) generates real jobs for a 2 s
# synthetic source and checks that the output verification expects the
# ACCEPTED CRF after retries.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${RETRY_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
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
mkdir -p "$W/logs" "$T/in/Show" "$T/out/Show" "$T/stub"
cp -r "$SRC_WORK/lib" "$W/"
WORK_DIR="$W"
for l in media_probe media_stats bitrate encode_common hdr_dovi job_runtime; do
    source "$W/lib/$l.sh" > /dev/null
done
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
export PATH="$T/stub:$PATH"

echo movie > "$T/in/M.mkv"
for e in 1 2 3 4 5; do echo "episode $e" > "$T/in/Show/E0$e.mkv"; done

# Stand-ins: the "encoder" writes "VIDEO_BYTES AUDIO_BYTES CRF" into
# $ITEM_PART; the size of each attempt comes from SIZES[CRF] (movie) or
# SIZES[EPISODE:CRF] (series); "fail" = the encode fails, "sleep" = a
# long encode (interruption test). Verification records the CRF it was
# asked to verify.
STUBS='
get_duration() { echo 100; }
media_stream_totals() { local v a c; read -r v a c < "$1"; echo "$v $a"; }
item_verify_output() { echo "$ITEM_INDEX:${ITEM_EXP[crf]}" >> "'"$T"'/$JOB_SESSION.verified"; }
refresh_mkv_stats() { return 0; }
get_resolution() { echo 1920x1080; }
main_video_index() { echo 0; }
declare -A SIZES=()
fake_encode() {
    local c="${ITEM_EXP[crf]}" s
    s="${SIZES[$ITEM_INDEX:$c]:-${SIZES[$c]:-}}"
    echo "$ITEM_INDEX:$c" >> "'"$T"'/$JOB_SESSION.encoded"
    # accepted encodes kept aside while this attempt runs
    local a
    for a in "$ITEM_OUTPUT".accepted-crf*.part; do
        [[ -e "$a" ]] && echo "$ITEM_INDEX:$c:${a##*/}" >> "'"$T"'/$JOB_SESSION.seen"
    done
    case "$s" in
        fail)  return 1 ;;
        sleep) sleep 30 & ITEM_CHILD=$!; wait "$ITEM_CHILD"; return 1 ;;
    esac
    echo "$s $c" > "$ITEM_PART"
}
'

# job SESSION BODY  ->  work/<SESSION>.sh (generated header / footer)
job() {
    {
        emit_job_header "$1" "${3:-movie}" "${4:-1}"
        printf '%s\n' "$STUBS" "$2"
        emit_job_footer
    } > "$W/$1.sh"
}
run_job() { bash "$W/$1.sh" < /dev/null > "$T/$1.log" 2>&1; }
encoded()  { tr '\n' ' ' < "$T/$1.encoded" 2>/dev/null; }
verified() { tr '\n' ' ' < "$T/$1.verified" 2>/dev/null; }
leftovers() { find "$T/out" \( -name '*.part' -o -name '*.retry-crf*' \) | sort | tr '\n' ' '; }
rows() { awk -F'\t' -v s="$1" '$9 == s { print $3 "/" $6 "/" $12 }' "$W/logs/crf_estimates.tsv" | tr '\n' ' '; }

# movie_job SESSION TIER CRF EXPECT_EXTRA SIZES...  (High: ceiling 7 GiB, CRF 19-23)
movie_job() {
    local s="$1" tier="$2" crf="$3" extra="$4"
    shift 4
    rm -f "$T/out/M.mkv" "$T/$s.encoded" "$T/$s.verified"
    job "$s" "SIZES=($*)
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' $tier 0 '' &&
   item_expect vidx=0 mode=crf crf=$crf kbps= est_vbytes=$(gib 6.8) atrans= ahash=1 $extra &&
   item_crf_encode item_encode_1
then
    item_succeeded
else
    item_failed
fi"
    run_job "$s"
}
HIGH="ceiling_vbytes=$(gib 7) crf_min=19 crf_max=23"

# ------------------------------------------------------------
echo "== movie"

movie_job m1 High 19 "$HIGH" "[19]='$(gib 6.5) $(gib 1)'"
eq    "1 under ceiling: no retry"              "$(encoded m1)" "1:19 "
check "1 accepted, final output written"       "grep -q '^Result: accepted\$' '$T/m1.log' && [[ \$(awk '{print \$3}' '$T/out/M.mkv') == 19 ]]"
check "1 session not held open"                "! grep -q 'Above the video ceiling' '$T/m1.log'"

movie_job m2 High 19 "$HIGH" "[19]='$(gib 7) 0'"
eq    "2 exactly the ceiling: accepted"        "$(encoded m2)" "1:19 "
check "2 accepted line"                        "grep -q '^CRF 19 actual: 7.00 GiB / 7.00 GiB ceiling\$' '$T/m2.log' && grep -q '^Result: accepted\$' '$T/m2.log'"

movie_job m3 High 19 "$HIGH" "[19]='$(gib 7.4) $(gib 1)' [20]='$(gib 6.6) $(gib 1)'"
eq    "3 slightly above: retried at CRF 20"    "$(encoded m3)" "1:19 1:20 "
check "3 compact pane output" \
    "grep -q '^CRF 19 actual: 7.40 GiB / 7.00 GiB ceiling\$' '$T/m3.log' && grep -q '^Result: over ceiling -> retrying CRF 20\$' '$T/m3.log' && grep -q '^CRF 20 actual: 6.60 GiB / 7.00 GiB ceiling\$' '$T/m3.log' && grep -q '^Result: accepted\$' '$T/m3.log'"
check "4 retry accepted: output is CRF 20"     "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 20 ]]"
eq    "4/15 verification expects CRF 20"       "$(verified m3)" "1:20 "
check "4 report lists both attempts" \
    "grep -q 'Selected CRF: *20' '$T/m3.log' && grep -q 'High | CRF 19 | est 6.80 GiB | actual 7.40 GiB | ceiling 7.00 | REJECTED -> retry CRF 20' '$T/m3.log' && grep -q 'High | CRF 20 | est n/a | actual 6.60 GiB | ceiling 7.00 | ACCEPTED' '$T/m3.log'"
eq    "4 estimate log: both attempts"          "$(rows m3)" "19/$(gib 6.8)/REJECTED 20/-/ACCEPTED "
check "4 estimate log: error % and ceiling"    "awk -F'\\t' '\$9 == \"m3\" && \$3 == 19 { f = (\$8 ~ /%\$/ && \$11 == $(gib 7)) } END { exit !f }' '$W/logs/crf_estimates.tsv'"
eq    "16 rejected attempt removed"            "$(leftovers)" ""

movie_job m5 High 19 "$HIGH" "[19]='$(gib 9) 0' [20]='$(gib 8) 0' [21]='$(gib 7.5) 0' [22]='$(gib 6.9) 0'"
eq    "5 retries until it fits"                "$(encoded m5)" "1:19 1:20 1:21 1:22 "
check "5 accepted CRF 22"                      "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 22 ]] && [[ '$(verified m5)' == '1:22 ' ]]"
eq    "16 no retry files left"                 "$(leftovers)" ""

movie_job m6 High 19 "$HIGH" "[19]='$(gib 9) 0' [20]='$(gib 9) 0' [21]='$(gib 9) 0' [22]='$(gib 8) 0' [23]='$(gib 7.5) 0'"
eq    "6 never beyond CRF_MAX"                 "$(encoded m6)" "1:19 1:20 1:21 1:22 1:23 "
check "6 warning: ceiling cannot be met" \
    "grep -q '^Result: over ceiling; CRF 23 is the High limit\$' '$T/m6.log' && grep -q 'WARNING: the 7.00 GiB video ceiling cannot be met within the High' '$T/m6.log' && grep -q 'CRF range (19-23); keeping CRF 23' '$T/m6.log'"
check "6 kept CRF 23, flagged at the end"      "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 23 ]] && grep -q '^Above the video ceiling' '$T/m6.log'"
check "6 logged OVER CEILING"                  "[[ '$(rows m6)' == *'23/-/OVER CEILING '* ]]"

movie_job m7 High 19 "$HIGH" "[19]='$(gib 6.9) $(gib 2)'"
eq    "7 total over only by audio: no retry"   "$(encoded m7)" "1:19 "
check "7 accepted on video bytes"              "grep -q '^CRF 19 actual: 6.90 GiB / 7.00 GiB ceiling\$' '$T/m7.log'"

movie_job m8 Custom 24 "ceiling_vbytes= crf_min= crf_max=" "[24]='$(gib 50) 0'"
eq    "8 Custom: never retried"                "$(encoded m8)" "1:24 "
check "8 Custom: no ceiling check output"      "! grep -q 'ceiling' '$T/m8.log' && [[ -f '$T/out/M.mkv' ]]"

declare -A ITEM_EXP=()
check "9 two-pass (abr) item: no CRF retry"   "ITEM_EXP=([mode]=abr [crf]= [ceiling_vbytes]=$(gib 7) [crf_max]=23); ! item_retry_enabled"
check "9 Custom: no CRF retry"                 "ITEM_EXP=([mode]=crf [crf]=24 [ceiling_vbytes]= [crf_max]=); ! item_retry_enabled"
check "9 High: CRF retry"                      "ITEM_EXP=([mode]=crf [crf]=19 [ceiling_vbytes]=$(gib 7) [crf_max]=23); item_retry_enabled"

movie_job m9 High 19 "$HIGH" "[19]='$(gib 7.4) 0' [20]=fail"
check "retry fails: completed CRF 19 kept"     "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 19 ]] && [[ '$(verified m9)' == '1:19 ' ]] && grep -q 'WARNING: retry at CRF 20 failed' '$T/m9.log'"
eq    "retry fails: no temp files left"        "$(leftovers)" ""

# ------------------------------------------------------------
echo
echo "== movie Quality (band 18-22 GiB around 20 GiB, CRF 0-23)"

# QBAND [CRF_MIN [CRF_MAX [DOWN_MAX]]]  ->  item_expect extras of a Quality item
qband() {
    printf 'ceiling_vbytes=%s crf_min=%s crf_max=%s down_headroom_pct=20 down_max=%s qtarget_vbytes=%s qmin_vbytes=%s qmax_vbytes=%s qstatus=band down_below_vbytes=%s' \
        "$(gib 22)" "${1:-0}" "${2:-23}" "${3:-2}" "$(gib 20)" "$(gib 18)" "$(gib 22)" "$(gib 18)"
}

movie_job q1 Quality 9 "$(qband)" "[9]='$(gib 21.5) $(gib 4)'"
eq    "Q1 21.5 GiB (inside band): no retry toward 20" "$(encoded q1)" "1:9 "
check "Q1 report: CRF, estimate, actual, target, band, difference, result" \
    "grep -q '^  Quality check:\$' '$T/q1.log' && grep -q '^    Selected CRF:       9\$' '$T/q1.log' && grep -q '^    Estimated video:    6.80 GiB\$' '$T/q1.log' && grep -q '^    Actual video:       21.50 GiB\$' '$T/q1.log' && grep -q '^    Target:             20.00 GiB\$' '$T/q1.log' && grep -q '^    Acceptable band:    18.00-22.00 GiB\$' '$T/q1.log' && grep -q '^    Difference:         +1.50 GiB\$' '$T/q1.log' && grep -q '^    Result:             ACCEPTABLE\$' '$T/q1.log'"
check "Q1 audio not counted (4 GiB audio, total 25.5)" "grep -q '^CRF 9 actual: 21.50 GiB / 22.00 GiB ceiling\$' '$T/q1.log'"

movie_job q2 Quality 9 "$(qband)" "[9]='$(gib 23) 0' [10]='$(gib 21) 0'"
eq    "Q2 23 GiB: retried at CRF + 1"          "$(encoded q2)" "1:9 1:10 "
check "Q2 accepted CRF 10, reported"           "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 10 ]] && [[ '$(verified q2)' == '1:10 ' ]] && grep -q 'Quality | CRF 9 | est 6.80 GiB | actual 23.00 GiB | band max 22.00 | REJECTED -> retry CRF 10' '$T/q2.log'"
check "Q2 report: estimate at the planned CRF" "grep -q '^    Estimated video:    n/a at CRF 10 (planned CRF 9: 6.80 GiB)\$' '$T/q2.log' && grep -q '^    Result:             ACCEPTABLE\$' '$T/q2.log'"

movie_job q3 Quality 9 "$(qband)" "[9]='$(gib 16) 0' [8]='$(gib 19) 0'"
eq    "Q3 16 GiB (below band): CRF - 1 tried"  "$(encoded q3)" "1:9 1:8 "
check "Q3 lower CRF 8 (19 GiB) kept"           "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 8 ]] && [[ '$(verified q3)' == '1:8 ' ]] && grep -q '^Below the acceptable band -> trying CRF 8\$' '$T/q3.log'"
eq    "Q3 no temp files left"                  "$(leftovers)" ""

movie_job q4 Quality 9 "$(qband)" "[9]='$(gib 17) 0' [8]='$(gib 23) 0'"
eq    "Q4 lower CRF above 22 GiB"              "$(encoded q4)" "1:9 1:8 "
check "Q4 previous accepted encode kept aside, then kept" \
    "grep -q '^1:8:M.mkv.accepted-crf9.part\$' '$T/q4.seen' && [[ \$(awk '{print \$3}' '$T/out/M.mkv') == 9 ]] && [[ '$(verified q4)' == '1:9 ' ]] && grep -q '^Result: over ceiling -> keeping CRF 9\$' '$T/q4.log'"
check "Q4 report: OUTSIDE BAND (17 GiB)"       "grep -q '^    Result:             OUTSIDE BAND\$' '$T/q4.log'"
eq    "Q4 no temp files left"                  "$(leftovers)" ""

movie_job q5 Quality 9 "$(qband)" "[9]='$(gib 17) 0' [8]=fail"
check "Q5 failed lower-CRF trial: CRF 9 output preserved" \
    "[[ '$(encoded q5)' == '1:9 1:8 ' ]] && [[ \$(awk '{print \$3}' '$T/out/M.mkv') == 9 ]] && [[ '$(verified q5)' == '1:9 ' ]] && grep -q 'Result: CRF 8 failed' '$T/q5.log'"
eq    "Q5 no temp files left"                  "$(leftovers)" ""

movie_job q6 Quality 9 "$(qband 9)" "[9]='$(gib 10) 0'"
eq    "Q6 never below CRF_MIN"                 "$(encoded q6)" "1:9 "
check "Q6 CRF_MIN message"                     "grep -q '^Below the acceptable band, but CRF 9 is the Quality minimum\$' '$T/q6.log'"

movie_job q7 Quality 9 "$(qband 0 10)" "[9]='$(gib 30) 0' [10]='$(gib 29) 0' [11]='$(gib 21) 0'"
eq    "Q7 never above CRF_MAX"                 "$(encoded q7)" "1:9 1:10 "
check "Q7 CRF_MAX kept with a warning"         "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 10 ]] && grep -q '^Result: over ceiling; CRF 10 is the Quality limit\$' '$T/q7.log'"

movie_job q8 Quality 9 "$(qband)" "[9]='$(gib 12) 0' [8]='$(gib 14) 0' [7]='$(gib 16) 0' [6]='$(gib 19) 0'"
eq    "Q8 lower CRFs limited by CRF_DOWN_RETRY_MAX (2)" "$(encoded q8)" "1:9 1:8 1:7 "
check "Q8 CRF 7 kept"                          "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 7 ]]"

movie_job q9 Quality 9 "$(qband)" "[9]='$(gib 18) 0'"
eq    "Q9 exactly 18 GiB: inside band, no retry" "$(encoded q9)" "1:9 "

movie_job q10 Quality 9 "$(qband)" "[9]='$(gib 23) 0' [10]='$(gib 17) 0'"
eq    "Q10 up then below band: no CRF already over the band retried" "$(encoded q10)" "1:9 1:10 "
check "Q10 CRF 10 kept"                        "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 10 ]]"

# CRF_START (8) is only where the pre-encode search begins: the job only
# knows the absolute CRF_MIN / CRF_MAX
movie_job q11 Quality 7 "$(qband 0)" "[7]='$(gib 16.9) 0' [6]='$(gib 19) 0'"
eq    "Q11 selected 7 (below START 8), 16.9 GiB: CRF 6 tried" "$(encoded q11)" "1:7 1:6 "
check "Q11 CRF 6 kept (START does not block it)" "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 6 ]]"
check "Q11 runtime has no start setting"       "! grep -qi 'start' <(sed -n '/^item_crf_encode() {/,/^}/p' '$W/lib/job_runtime.sh')"

movie_job q12 Quality 7 "$(qband 6)" "[7]='$(gib 16) 0' [6]='$(gib 17) 0' [5]='$(gib 19) 0'"
eq    "Q12 never below the absolute CRF_MIN (6)" "$(encoded q12)" "1:7 1:6 "
check "Q12 CRF 6 kept, minimum reached"        "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 6 ]] && grep -q '^Below the acceptable band, but CRF 6 is the Quality minimum\$' '$T/q12.log'"

movie_job q13 Quality 22 "$(qband 0 23)" "[22]='$(gib 25) 0' [23]='$(gib 24) 0' [24]='$(gib 20) 0'"
eq    "Q13 upward retry never exceeds CRF_MAX (23)" "$(encoded q13)" "1:22 1:23 "

check "Quality: CRF retry enabled"            "ITEM_EXP=([mode]=crf [crf]=9 [ceiling_vbytes]=$(gib 22) [crf_max]=23); item_retry_enabled"

# ------------------------------------------------------------
echo
echo "== series season batch of earlier job scripts (one CRF per season, median episode decides)"

# series_job SESSION N SIZES...  (High: ceiling 5 GiB/episode, CRF 18-21)
series_job() {
    local s="$1" n="$2" body="" e
    shift 2
    rm -f "$T"/out/Show/* "$T/$s.encoded" "$T/$s.verified"
    for ((e = 1; e <= n; e++)); do
        body+="item_encode_$e() { fake_encode; }
item_ctx_$e() {
   item_begin $e '$T/in/Show/E0$e.mkv' '$T/out/Show/E0$e.mkv' High 0 '' &&
   item_expect vidx=0 mode=crf crf=${SERIES_CRF:-18} kbps= est_vbytes=$(gib 4.8) atrans= ahash=1 ${SERIES_EXTRA:-ceiling_vbytes=$(gib 5) crf_min=18 crf_max=21}
}
item_prep_$e() {
   :
}
job_batch_add $e
"
    done
    job "$s" "SIZES=($*)
$body" series "$n"
    run_job "$s"
}
final_crfs() { for f in "$T"/out/Show/E0?.mkv; do awk '{ printf "%s ", $3 }' "$f"; done; }

series_job s10 3 "[1:18]='$(gib 4.2) 1' [2:18]='$(gib 4.6) 1' [3:18]='$(gib 4.9) 1'"
eq    "10 median under: no retry"              "$(encoded s10)" "1:18 2:18 3:18 "
check "10 accepted, all final at CRF 18"       "grep -q '^CRF 18 actual median: 4.60 GiB / 5.00 GiB ceiling\$' '$T/s10.log' && grep -q '^Result: accepted\$' '$T/s10.log' && [[ '$(final_crfs)' == '18 18 18 ' ]]"

series_job s11 5 "[1:18]='$(gib 5.0) 1' [2:18]='$(gib 5.2) 1' [3:18]='$(gib 5.3) 1' [4:18]='$(gib 6.1) 1' [5:18]='$(gib 4.0) 1'" \
    "[1:19]='$(gib 4.3) 1' [2:19]='$(gib 4.5) 1' [3:19]='$(gib 4.6) 1' [4:19]='$(gib 5.4) 1' [5:19]='$(gib 3.5) 1'"
eq    "11 median over: whole season retried"   "$(encoded s11)" "1:18 2:18 3:18 4:18 5:18 1:19 2:19 3:19 4:19 5:19 "
check "11 pane output" \
    "grep -q '^CRF 18 actual median: 5.20 GiB / 5.00 GiB ceiling\$' '$T/s11.log' && grep -q '^Result: over ceiling -> retrying season at CRF 19\$' '$T/s11.log' && grep -q '^CRF 19 actual median: 4.50 GiB / 5.00 GiB ceiling\$' '$T/s11.log' && grep -q '^Warning: 1 episode remains above nominal ceiling\$' '$T/s11.log'"
eq    "14 one CRF for every episode"           "$(final_crfs)" "19 19 19 19 19 "
eq    "15 verification expects the accepted CRF" "$(verified s11)" "1:19 2:19 3:19 4:19 5:19 "
check "11 outlier noted, not re-encoded alone" "grep -q 'High | CRF 19 | est n/a | actual 5.40 GiB | ceiling 5.00 | ACCEPTED -> above the nominal ceiling' '$T/s11.log' && [[ \$(grep -c '^4:' '$T/s11.encoded') == 2 ]]"
check "11 logs: both season attempts"          "[[ '$(rows s11)' == *'18/$(gib 4.8)/REJECTED'*'19/-/ACCEPTED'* && \$(awk -F'\\t' '\$9 == \"s11\"' '$W/logs/crf_estimates.tsv' | grep -c .) == 10 ]]"
eq    "16 series: rejected attempts removed"   "$(leftovers)" ""

series_job s12 3 "[1:18]='$(gib 4.0) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 7.0) 1'"
eq    "12 one outlier, median fits: no retry"  "$(encoded s12)" "1:18 2:18 3:18 "
check "12 outlier warned"                      "grep -q '^Warning: 1 episode remains above nominal ceiling\$' '$T/s12.log' && [[ '$(final_crfs)' == '18 18 18 ' ]]"

series_job s13 5 "[1:18]='$(gib 4.0) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 4.8) 1' [4:18]='$(gib 6.0) 1' [5:18]='$(gib 7.0) 1'"
eq    "13 two outliers, median fits: no retry" "$(encoded s13)" "1:18 2:18 3:18 4:18 5:18 "
check "13 outliers warned"                     "grep -q '^Warning: 2 episodes remain above nominal ceiling\$' '$T/s13.log'"

series_job s14 3 "[1:18]='$(gib 6) 1' [2:18]='$(gib 6) 1' [3:18]='$(gib 6) 1' [1:19]='$(gib 4) 1' [2:19]=fail"
check "14 retry fails: season kept at CRF 18"  "[[ '$(final_crfs)' == '18 18 18 ' && '$(verified s14)' == '1:18 2:18 3:18 ' ]] && grep -q 'WARNING: season retry at CRF 19 failed (episode 2' '$T/s14.log'"
eq    "14 retry fails: partial retry removed"  "$(leftovers)" ""

series_job s15 2 "[1:18]='$(gib 6) 1' [2:18]='$(gib 6) 1' [1:19]='$(gib 6) 1' [2:19]='$(gib 6) 1' [1:20]='$(gib 6) 1' [2:20]='$(gib 6) 1' [1:21]='$(gib 5.5) 1' [2:21]='$(gib 5.5) 1'"
check "season CRF_MAX still over: warned, kept 21" \
    "[[ '$(final_crfs)' == '21 21 ' ]] && grep -q 'per-episode video ceiling cannot be met within the' '$T/s15.log' && grep -q '^Above the video ceiling' '$T/s15.log' && ! grep -q 'CRF 22' '$T/s15.log'"

# ------------------------------------------------------------
echo
echo "== movie: lower-CRF retry (ceiling 5 GiB, 20 % headroom -> <= 4 GiB, CRF 15-21)"

DOWN="ceiling_vbytes=$(gib 5) crf_min=15 crf_max=21 down_headroom_pct=20 down_max=2"
seen() { tr '\n' ' ' < "$T/$1.seen" 2>/dev/null; }

movie_job d1 High 18 "$DOWN" "[18]='$(gib 4.4) $(gib 1)'"
eq    "d1 near the ceiling: no lower CRF"     "$(encoded d1)" "1:18 "
check "d1 accepted CRF 18, no headroom line"  "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 18 ]] && ! grep -q 'Headroom' '$T/d1.log'"

movie_job d2 High 18 "$DOWN" "[18]='$(gib 3.1) $(gib 1)' [17]='$(gib 4.6) $(gib 1)'"
eq    "d2 far below: CRF 17 tried"            "$(encoded d2)" "1:18 1:17 "
check "d2 compact output" \
    "grep -q '^CRF 18 actual: 3.10 GiB / 5.00 GiB ceiling\$' '$T/d2.log' && grep -q '^Headroom large -> trying CRF 17\$' '$T/d2.log' && grep -q '^CRF 17 actual: 4.60 GiB / 5.00 GiB ceiling\$' '$T/d2.log'"
check "d3 lower CRF fits: CRF 17 accepted"    "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 17 ]] && grep -q 'Selected CRF: *17' '$T/d2.log'"
eq    "d24 verification expects CRF 17"       "$(verified d2)" "1:17 "
eq    "d19 accepted CRF 18 kept aside during the trial" "$(seen d2)" "1:17:M.mkv.accepted-crf18.part "
eq    "d21 only the final output is left"     "$(leftovers)" ""
eq    "d23 logs: candidate + accepted"        "$(rows d2)" "18/$(gib 6.8)/ACCEPTED-CANDIDATE 17/-/ACCEPTED "

movie_job d4 High 18 "$DOWN" "[18]='$(gib 3.0) 0' [17]='$(gib 3.5) 0' [16]='$(gib 4.5) 0'"
eq    "d4 second lower CRF within the limit"  "$(encoded d4)" "1:18 1:17 1:16 "
check "d4 CRF 16 accepted"                    "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 16 && '$(verified d4)' == '1:16 ' ]]"

movie_job d5 High 18 "$DOWN" "[18]='$(gib 3.2) 0' [17]='$(gib 3.9) 0' [16]='$(gib 5.3) 0'"
eq    "d5 lower CRF over the ceiling: stop"   "$(encoded d5)" "1:18 1:17 1:16 "
check "d5 completed CRF 17 kept"              "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 17 && '$(verified d5)' == '1:17 ' ]] && grep -q '^Result: over ceiling -> keeping CRF 17\$' '$T/d5.log'"
eq    "d20 rejected lower trial removed"      "$(leftovers)" ""
check "d23 report: every attempt" \
    "grep -q 'High | CRF 18 | est 6.80 GiB | actual 3.20 GiB | ceiling 5.00 | ACCEPTED-CANDIDATE' '$T/d5.log' && grep -q 'High | CRF 17 | est n/a | actual 3.90 GiB | ceiling 5.00 | ACCEPTED\$' '$T/d5.log' && grep -q 'High | CRF 16 | est n/a | actual 5.30 GiB | ceiling 5.00 | REJECTED -> over ceiling; keep CRF 17' '$T/d5.log'"
eq    "d23 estimate log: every attempt"       "$(rows d5)" "18/$(gib 6.8)/ACCEPTED-CANDIDATE 17/-/ACCEPTED 16/-/REJECTED "

movie_job d6 High 15 "$DOWN" "[15]='$(gib 2) 0'"
eq    "d6 CRF_MIN: no lower CRF"              "$(encoded d6)" "1:15 "
check "d6 says why"                           "grep -q '^Headroom large, but CRF 15 is the High minimum\$' '$T/d6.log'"

movie_job d7 High 18 "${DOWN/down_max=2/down_max=1}" "[18]='$(gib 2) 0' [17]='$(gib 2.5) 0'"
eq    "d7 retry limit respected"              "$(encoded d7)" "1:18 1:17 "
check "d7 says why, CRF 17 kept"              "grep -q 'lower-CRF retry limit (1) is reached' '$T/d7.log' && [[ \$(awk '{print \$3}' '$T/out/M.mkv') == 17 ]]"

movie_job d7b High 18 "${DOWN/down_max=2/down_max=0}" "[18]='$(gib 2) 0'"
eq    "d7 limit 0: never lower"               "$(encoded d7b)" "1:18 "

# CRF chosen below the tier's CRF_START (10) by the boundary search: the
# retry floor is the search floor (crf_min=8, CRF_SEARCH_MIN), never the
# start, so the selected CRF is not pushed back up and may still go lower
# (estimates: 8 = 5.35 over, 9 = 4.9 fits, 10 = 4.6)
FLOOR="ceiling_vbytes=$(gib 5) crf_min=8 crf_max=21 down_headroom_pct=20 down_max=2 down_fit_pct=5 crf_est=8=$(gib 5.35):9=$(gib 4.9):10=$(gib 4.6)"
movie_job f1 High 9 "$FLOOR" "[9]='$(gib 4.7) 0'"
eq    "f1 below CRF_START, fits: kept at 9 (not raised to the start)" "$(encoded f1)/$(awk '{print $3}' "$T/out/M.mkv")" "1:9 /9"
movie_job f2 High 9 "$FLOOR" "[9]='$(gib 3.0) 0' [8]='$(gib 3.4) 0'"
eq    "f2 below CRF_START, headroom: lower CRF 8 tried (floor = search min)" "$(encoded f2)/$(awk '{print $3}' "$T/out/M.mkv")" "1:9 1:8 /8"
movie_job f3 High 8 "$FLOOR" "[8]='$(gib 3.0) 0'"
eq    "f3 at the search floor: no lower CRF"  "$(encoded f3)" "1:8 "
check "f3 says why"                           "grep -q '^Headroom large, but CRF 8 is the High minimum\$' '$T/f3.log'"
movie_job f4 High 9 "$FLOOR" "[9]='$(gib 5.2) 0' [10]='$(gib 4.8) 0'"
eq    "f4 below CRF_START, over: up to 10 as usual" "$(encoded f4)/$(awk '{print $3}' "$T/out/M.mkv")" "1:9 1:10 /10"
check "menus pass CRF_MIN (the search floor), not CRF_START, as the retry floor" \
    "grep -qF 'RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:' '$SRC_WORK/movie_compress.sh' && grep -qF 'local i=\"\$1\" min=\"\$CRF_MIN\"' '$SRC_WORK/series_compress.sh' && ! grep -q 'RETRY_SPEC=.*CRF_START' '$SRC_WORK/movie_compress.sh'"
check "crf_tier_load: CRF_MIN is the search floor" \
    "( for l in ui bitrate policy; do source '$W/lib/'\$l.sh; done; COMPRESS_CONF='$SRC_WORK/lib/compress.conf' load_policy 2>/dev/null; crf_tier_load movie High; [[ \$CRF_MIN == \$MOVIE_HIGH_CRF_SEARCH_MIN && \$CRF_START == \$MOVIE_HIGH_CRF_START ]] && (( CRF_MIN < CRF_START )) )"

movie_job d8 High 18 "$DOWN" "[18]='$(gib 3) 0' [17]=fail"
check "d8 lower trial fails: CRF 18 kept"     "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 18 && '$(verified d8)' == '1:18 ' ]] && grep -q 'Result: CRF 17 failed' '$T/d8.log'"
eq    "d8 no temp files"                      "$(leftovers)" ""

movie_job d8b High 18 "$DOWN" "[18]='$(gib 5.5) 0' [19]='$(gib 2) 0'"
eq    "no oscillation: CRF 18 known over"     "$(encoded d8b)" "1:18 1:19 "
check "no oscillation: CRF 19 final"          "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 19 && '$(verified d8b)' == '1:19 ' ]]"

movie_job d10 Custom 24 "ceiling_vbytes= crf_min= crf_max= down_headroom_pct=20 down_max=2" "[24]='$(gib 1) 0'"
eq    "d10 Custom: never a lower CRF"         "$(encoded d10)" "1:24 "
check "d11 Quality: no CRF retry at all"      "ITEM_EXP=([mode]=abr [crf]= [ceiling_vbytes]=$(gib 5) [crf_max]=21 [down_headroom_pct]=20 [down_max]=2); ! item_retry_enabled"

# d9: interrupted during the lower trial
echo "old final" > "$T/out/M.mkv"
rm -f "$T/d9.encoded"
job d9 "SIZES=([18]='$(gib 3) 0' [17]=sleep)
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' High 1 '' &&
   item_expect vidx=0 mode=crf crf=18 kbps= est_vbytes=$(gib 4) atrans= ahash=1 $DOWN &&
   item_crf_encode item_encode_1
then item_succeeded; else item_failed; fi"
bash "$W/d9.sh" < /dev/null > "$T/d9.log" 2>&1 &
pid=$!
for _ in $(seq 100); do grep -q '1:17' "$T/d9.encoded" 2>/dev/null && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid"; wait "$pid" 2>/dev/null
check "d9 interrupted: accepted CRF 18 recoverable" "[[ \$(awk '{print \$3}' '$T/out/M.mkv.accepted-crf18.part') == 18 ]] && grep -q 'M.mkv.accepted-crf18.part' '$T/d9.log'"
check "d9 unfinished CRF 17 trial removed"    "[[ ! -e '$T/out/M.mkv.retry-crf17.part' ]]"
check "d9 final output untouched"             "[[ \$(cat '$T/out/M.mkv') == 'old final' ]]"
rm -f "$T"/out/M.mkv*

# ------------------------------------------------------------
echo
echo "== series season batch of earlier job scripts: lower-CRF retry (median decides)"

SERIES_EXTRA="$DOWN"
series_job e12 3 "[1:18]='$(gib 3.0) 1' [2:18]='$(gib 3.2) 1' [3:18]='$(gib 3.4) 1'" \
    "[1:17]='$(gib 4.3) 1' [2:17]='$(gib 4.5) 1' [3:17]='$(gib 4.8) 1'"
eq    "e12 median far below: season at CRF 17" "$(encoded e12)" "1:18 2:18 3:18 1:17 2:17 3:17 "
check "e13 lower season accepted" \
    "grep -q '^CRF 18 actual median: 3.20 GiB / 5.00 GiB ceiling\$' '$T/e12.log' && grep -q '^Headroom large -> trying season at CRF 17\$' '$T/e12.log' && grep -q '^CRF 17 actual median: 4.50 GiB / 5.00 GiB ceiling\$' '$T/e12.log' && grep -q '^Season CRF: 17\$' '$T/e12.log'"
eq    "e16 one CRF for every episode"         "$(final_crfs)" "17 17 17 "
eq    "e24 verified at the season CRF"        "$(verified e12)" "1:17 2:17 3:17 "
check "e19 accepted season kept aside"        "[[ \$(grep -c ':17:E0[123].mkv.accepted-crf18.part' '$T/e12.seen') == 3 ]]"
eq    "e21 only final outputs left"           "$(leftovers)" ""

series_job e14 3 "[1:18]='$(gib 3.0) 1' [2:18]='$(gib 3.2) 1' [3:18]='$(gib 3.4) 1'" \
    "[1:17]='$(gib 3.7) 1' [2:17]='$(gib 3.9) 1' [3:17]='$(gib 4.0) 1'" \
    "[1:16]='$(gib 5.0) 1' [2:16]='$(gib 5.3) 1' [3:16]='$(gib 5.6) 1'"
eq    "e14 lower season over: stop"           "$(encoded e14)" "1:18 2:18 3:18 1:17 2:17 3:17 1:16 2:16 3:16 "
check "e14 completed CRF 17 season kept"      "[[ '$(final_crfs)' == '17 17 17 ' ]] && grep -q '^CRF 16 actual median: 5.30 GiB / 5.00 GiB ceiling\$' '$T/e14.log' && grep -q '^Result: over ceiling -> keeping CRF 17\$' '$T/e14.log'"
eq    "e20 rejected season trial removed"     "$(leftovers)" ""
check "e23 logs: all three season attempts"   "[[ \$(awk -F'\\t' '\$9 == \"e14\"' '$W/logs/crf_estimates.tsv' | grep -c .) == 9 ]] && [[ '$(rows e14)' == *'16/-/REJECTED'* ]]"

SERIES_EXTRA="${DOWN/down_max=2/down_max=1}"
series_job e15 3 "[1:18]='$(gib 2.0) 1' [2:18]='$(gib 2.5) 1' [3:18]='$(gib 5.5) 1'" \
    "[1:17]='$(gib 3.0) 1' [2:17]='$(gib 3.5) 1' [3:17]='$(gib 6.5) 1'"
check "e15 outlier above, median fits: CRF 17" "[[ '$(final_crfs)' == '17 17 17 ' ]] && grep -q '^Warning: 1 episode remains above nominal ceiling\$' '$T/e15.log'"
check "e17 retry limit respected"             "[[ '$(encoded e15)' == '1:18 2:18 3:18 1:17 2:17 3:17 ' ]] && grep -q 'lower-CRF retry limit (1) is reached' '$T/e15.log'"

SERIES_EXTRA="$DOWN" SERIES_CRF=15
series_job e18 2 "[1:15]='$(gib 2) 1' [2:15]='$(gib 2) 1'"
check "e18 CRF_MIN respected"                 "[[ '$(encoded e18)' == '1:15 2:15 ' ]] && grep -q 'CRF 15 is the High minimum' '$T/e18.log'"
SERIES_CRF=18

series_job e8 3 "[1:18]='$(gib 3) 1' [2:18]='$(gib 3) 1' [3:18]='$(gib 3) 1' [1:17]='$(gib 4) 1' [2:17]=fail"
check "season trial fails: CRF 18 kept"       "[[ '$(final_crfs)' == '18 18 18 ' && '$(verified e8)' == '1:18 2:18 3:18 ' ]] && grep -q 'season at CRF 17 failed (episode 2' '$T/e8.log'"
eq    "season trial fails: no temp files"     "$(leftovers)" ""
unset SERIES_EXTRA

# ------------------------------------------------------------
echo
echo "== series: one item per episode (season CRF 18, ceiling 5 GiB, CRF 16-21,"
echo "   20 % headroom, 1 lower CRF per episode, 5 % predicted-fit margin)"

# ep_job SESSION SIZES...  ->  one item per episode as series_compress.sh
# emits it: EP_CRFS[i] its CRF, EP_EXTRA[i] its retry settings (default EPX)
EPX="ceiling_vbytes=$(gib 5) crf_min=16 crf_max=21 down_headroom_pct=20 down_max=1 down_fit_pct=5"
ep_job() {
    local s="$1" body="" e n
    shift
    rm -f "$T"/out/Show/* "$T/$s.encoded" "$T/$s.verified" "$T/$s.seen"
    for e in "${!EP_CRFS[@]}"; do
        n=$((e + 1))
        body+="item_encode_$n() { fake_encode; }
if item_begin $n '$T/in/Show/E0$n.mkv' '$T/out/Show/E0$n.mkv' High 0 '' &&
   item_expect vidx=0 mode=crf crf=${EP_CRFS[$e]} kbps= est_vbytes=$(gib 4.5) atrans= ahash=1 ${EP_EXTRA[$e]:-$EPX} &&
   item_crf_encode item_encode_$n
then
    item_succeeded
else
    item_failed
fi
"
    done
    job "$s" "SIZES=($*)
$body" series "${#EP_CRFS[@]}"
    run_job "$s"
}
EP_EXTRA=()

EP_CRFS=(18 18 20)
ep_job p1 "[1:18]='$(gib 4.5) 1' [2:18]='$(gib 4.6) 1' [3:20]='$(gib 4.7) 1'"
eq    "p1 all fit: each episode once"         "$(encoded p1)" "1:18 2:18 3:20 "
eq    "p1 outlier keeps its own CRF 20"       "$(final_crfs)" "18 18 20 "

ep_job p2 "[1:18]='$(gib 4.5) 1' [2:18]='$(gib 5.3) 1' [2:19]='$(gib 4.7) 1' [3:20]='$(gib 4.6) 1'"
eq    "p2 regular episode over: only it is retried" "$(encoded p2)" "1:18 2:18 2:19 3:20 "
check "p2 E02 at 19, the season untouched"    "[[ '$(final_crfs)' == '18 19 20 ' && '$(verified p2)' == '1:18 2:19 3:20 ' ]] && grep -q '^CRF 18 actual: 5.30 GiB / 5.00 GiB ceiling\$' '$T/p2.log' && ! grep -q 'season' '$T/p2.log'"
eq    "p2 no temp files"                      "$(leftovers)" ""

ep_job p3 "[1:18]='$(gib 4.5) 1' [2:18]='$(gib 4.5) 1' [3:20]='$(gib 5.2) 1' [3:21]='$(gib 4.8) 1'"
eq    "p3 outlier over: only the outlier retried" "$(encoded p3)" "1:18 2:18 3:20 3:21 "
eq    "p3 outlier at 21"                      "$(final_crfs)" "18 18 21 "

EP_CRFS=(18 18 21)
ep_job p4 "[1:18]='$(gib 4.5) 1' [2:18]='$(gib 4.5) 1' [3:21]='$(gib 5.5) 1'"
check "p4 outlier over at CRF_MAX: kept, warned, flagged" \
    "[[ '$(encoded p4)' == '1:18 2:18 3:21 ' && '$(final_crfs)' == '18 18 21 ' ]] && grep -q '^Result: over ceiling; CRF 21 is the High limit\$' '$T/p4.log' && grep -A1 '^Above the video ceiling' '$T/p4.log' | grep -q 'E03'"

# undershoot: E01 3.0 GiB (<= 4 GiB), estimates 17 / 18 = 1.10 -> CRF 17
# predicted 3.30 GiB <= 4.75 GiB -> tried for E01 only, once
EP_CRFS=(18 18 18)
EP_EXTRA=("$EPX crf_est=17=$(gib 5.5):18=$(gib 5.0)")
ep_job p5 "[1:18]='$(gib 3.0) 1' [1:17]='$(gib 3.4) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 4.6) 1'"
eq    "p5 undershoot: only E01 tries CRF 17"  "$(encoded p5)" "1:18 1:17 2:18 3:18 "
check "p5 prediction shown, E01 at 17, limit 1" \
    "[[ '$(final_crfs)' == '17 18 18 ' ]] && grep -q '^CRF 17 predicted: 3.30 GiB / 4.75 GiB limit\$' '$T/p5.log' && grep -q 'lower-CRF retry limit (1) is reached' '$T/p5.log'"

# estimates 17 / 18 = 1.30: 3.9 GiB -> 5.07 GiB predicted > 4.75 -> no trial
EP_EXTRA=("$EPX crf_est=17=$(gib 6.5):18=$(gib 5.0)")
ep_job p6 "[1:18]='$(gib 3.9) 1' [1:17]='$(gib 4.4) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 4.6) 1'"
eq    "p6 predicted above the limit: no lower trial" "$(encoded p6)" "1:18 2:18 3:18 "
check "p6 says why"                           "grep -q '^Headroom large, but CRF 17 is predicted at 5.07 GiB, above the 4.75 GiB limit (5% below the ceiling); keeping CRF 18\$' '$T/p6.log'"

# noisy estimates (17 = 18) never look free: ratio at least 1.08
EP_EXTRA=("$EPX crf_est=17=$(gib 5.0):18=$(gib 5.0)")
ep_job p7 "[1:18]='$(gib 4.0) 1' [1:17]='$(gib 4.3) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 4.6) 1'"
check "p7 ratio floor 1.08 (4.32 GiB predicted)" "grep -q '^CRF 17 predicted: 4.32 GiB / 4.75 GiB limit\$' '$T/p7.log' && [[ '$(final_crfs)' == '17 18 18 ' ]]"

# no estimate at CRF 17: default ratio 1.15 (4.60 GiB predicted)
EP_EXTRA=()
ep_job p8 "[1:18]='$(gib 4.0) 1' [1:17]='$(gib 4.4) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 4.6) 1'"
check "p8 default ratio 1.15"                 "grep -q '^CRF 17 predicted: 4.60 GiB / 4.75 GiB limit\$' '$T/p8.log' && [[ '$(encoded p8)' == '1:18 1:17 2:18 3:18 ' ]]"

# the lower trial lands above the ceiling: discarded, CRF 18 kept
EP_EXTRA=("$EPX crf_est=17=$(gib 5.5):18=$(gib 5.0)")
ep_job p9 "[1:18]='$(gib 3.0) 1' [1:17]='$(gib 5.2) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 4.6) 1'"
check "p9 lower over: E01 keeps CRF 18"       "[[ '$(final_crfs)' == '18 18 18 ' && '$(verified p9)' == '1:18 2:18 3:18 ' ]] && grep -q '^Result: over ceiling -> keeping CRF 18\$' '$T/p9.log'"
eq    "p9 no temp files"                      "$(leftovers)" ""

# a CRF already found above the ceiling is never tried again
EP_EXTRA=("$EPX crf_est=18=$(gib 5.5):19=$(gib 5.0)")
EP_CRFS=(18 18 18)
ep_job p10 "[1:18]='$(gib 5.5) 1' [1:19]='$(gib 3.0) 1' [2:18]='$(gib 4.5) 1' [3:18]='$(gib 4.6) 1'"
eq    "p10 up to 19, never back to 18"        "$(encoded p10)" "1:18 1:19 2:18 3:18 "

# an outlier (CRF 20) never goes below the season CRF 18 (its crf_min),
# even with retries left
EP_CRFS=(18 18 20)
EP_EXTRA=("" "" "ceiling_vbytes=$(gib 5) crf_min=18 crf_max=21 down_headroom_pct=20 down_max=3 down_fit_pct=5")
ep_job p11 "[1:18]='$(gib 4.5) 1' [2:18]='$(gib 4.5) 1' [3:20]='$(gib 2.0) 1' [3:19]='$(gib 2.3) 1' [3:18]='$(gib 2.6) 1'"
check "p11 outlier stops at the season CRF"   "[[ '$(encoded p11)' == '1:18 2:18 3:20 3:19 3:18 ' && '$(final_crfs)' == '18 18 18 ' ]] && grep -q 'CRF 18 is the High minimum' '$T/p11.log' && ! grep -q '3:17' '$T/p11.encoded'"
EP_EXTRA=()

# ------------------------------------------------------------
echo
echo "== CRF log header"

L="$T/logtest"
mkdir -p "$L"
printf '%s\n' "$CRF_LOG_HEADER_V1" > "$L/a.tsv"
printf 'd\tHigh\t19\t1920x1080\t100\t5\t6\t20%%\ts\tin\n' >> "$L/a.tsv"
printf 'd\tHigh\t20\t1920x1080\t100\t5\t6\t20%%\ts\tin\t7\tACCEPTED\t-\n' >> "$L/a.tsv"
crf_log_prepare "$L/a.tsv"
eq    "old header migrated"                   "$(head -1 "$L/a.tsv")" "$CRF_LOG_HEADER"
eq    "old rows padded to 13 columns"         "$(awk -F'\t' '{ print NF }' "$L/a.tsv" | sort -u | tr '\n' ' ')" "13 "
check "old row values kept"                   "sed -n 2p '$L/a.tsv' | grep -q \$'\\t19\\t1920x1080\\t100\\t5\\t6\\t20%\\ts\\tin\\t-\\t-\\t-\$'"
echo "permanent result" > "$L/b.tsv"
crf_log_prepare "$L/b.tsv"
check "unknown file moved aside, not lost"    "grep -qx 'permanent result' '$L'/b.tsv.unknown-* && [[ \$(cat '$L/b.tsv') == \"\$CRF_LOG_HEADER\" ]]"
eq    "job log: one header, all rows 13 columns" "$(awk -F'\t' '{ print NF }' "$W/logs/crf_estimates.tsv" | sort -u | tr '\n' ' ')/$(grep -c '^date' "$W/logs/crf_estimates.tsv")" "13 /1"

# ------------------------------------------------------------
echo
echo "== interruption / other sessions / cleanup"

echo "other job" > "$W/c80.sh"
printf 'version=1\nsession=c80\nstatus=running\nstarted=1234\n' > "$W/c80.state"
echo "other output" > "$T/out/Other.mkv.part"
echo "old final" > "$T/out/M.mkv"

rm -f "$T/i1.encoded"
job i1 "SIZES=([19]='$(gib 7.4) 0' [20]=sleep)
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' High 1 '' &&
   item_expect vidx=0 mode=crf crf=19 kbps= est_vbytes=$(gib 6.8) atrans= ahash=1 $HIGH &&
   item_crf_encode item_encode_1
then item_succeeded; else item_failed; fi"
bash "$W/i1.sh" < /dev/null > "$T/i1.log" 2>&1 &
pid=$!
for _ in $(seq 100); do grep -q '1:20' "$T/i1.encoded" 2>/dev/null && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid"; wait "$pid" 2>/dev/null
check "18 interrupted: final output untouched" "[[ \$(cat '$T/out/M.mkv') == 'old final' ]]"
check "18 completed CRF 19 attempt kept"       "[[ \$(awk '{print \$3}' '$T/out/M.mkv.part') == 19 ]] && grep -q 'Completed CRF attempts kept' '$T/i1.log'"
check "18 unfinished retry removed"            "[[ ! -e '$T/out/M.mkv.retry-crf20.part' ]]"
check "18 state says interrupted"              "grep -qx 'status=interrupted' '$W/i1.state'"
rm -f "$T/out/M.mkv.part" "$T/out/M.mkv"

movie_job c81 High 19 "$HIGH" "[19]='$(gib 7.4) 0' [20]='$(gib 6) 0'"
check "19 another session's files untouched"   "[[ \$(cat '$W/c80.sh') == 'other job' ]] && grep -qx 'started=1234' '$W/c80.state' && [[ \$(cat '$T/out/Other.mkv.part') == 'other output' ]]"
check "20 finished retry job removed its runtime files" "[[ ! -e '$W/c81.sh' && ! -e '$W/c81.state' && ! -e '$W/c81.progress' ]]"
check "17 accepted output preserved"           "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 20 ]]"
rm -f "$T/out/Other.mkv.part"

if bash "$SRC_WORK/tests/job_cleanup_tests.sh" > "$T/cleanup.log" 2>&1; then
    ok "20 job_cleanup_tests.sh passes"
else
    bad "20 job_cleanup_tests.sh passes"; tail -20 "$T/cleanup.log"
fi

# ------------------------------------------------------------
echo
echo "== generated jobs, real 2 s encodes"

if ! command -v ffmpeg >/dev/null || [[ "$(ffmpeg -hide_banner -encoders 2>/dev/null)" != *libx265* ]]; then
    echo "  (ffmpeg with libx265 not found: skipped)"
else
    source "$W/lib/policy.sh"
    COMPRESS_CONF="$W/lib/compress.conf" load_policy > /dev/null
    R="$T/real"
    mkdir -p "$R/in" "$R/out"
    for e in 1 2; do
        ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=2" -f lavfi -i "sine=f=440:r=48000:d=2" \
            -c:v libx264 -preset ultrafast -qp 0 -c:a aac -b:a 96k "$R/in/E0$e.mkv"
    done
    DV_POLICY=none HDR10P_POLICY=none

    # movie High, ceiling 1 byte: CRF 19, 20, 21 all above -> CRF 21 kept
    { emit_job_header r1 movie 1
      emit_encode_item 1 "$R/in/E01.mkv" "$R/out/M.mkv" High crf:19 "" "" 0 1000 "1:21:19"
      emit_job_footer; } > "$W/r1.sh"
    check "generated: encode is a function + retry" "grep -q '^item_encode_1() {' '$W/r1.sh' && grep -q '^   item_crf_encode item_encode_1\$' '$W/r1.sh' && grep -q 'ceiling_vbytes=1 crf_min=19 crf_max=21' '$W/r1.sh' && grep -q -- '-crf:v:0 19 ' '$W/r1.sh'"
    bash -n "$W/r1.sh" && run_job r1
    check "real movie: verified at accepted CRF 21" "grep -q 'Selected CRF: *21' '$T/r1.log' && grep -qE 'AS PLANNED .*CRF 21(\.0)? \(single pass\)' '$T/r1.log' && [[ -f '$R/out/M.mkv' ]]"
    check "real movie: three attempts encoded"  "grep -q 'ENCODING (single pass, CRF 20)' '$T/r1.log' && grep -q 'ENCODING (single pass, CRF 21)' '$T/r1.log' && grep -q 'Result: over ceiling; CRF 21 is the High limit' '$T/r1.log'"
    check "real movie: no temp files"           "[[ -z \$(find '$R/out' -name '*.part') ]]"

    # movie High, huge ceiling: planned 21, lower CRFs 20 and 19 (limit 2)
    { emit_job_header r4 movie 1
      emit_encode_item 1 "$R/in/E01.mkv" "$R/out/D.mkv" High crf:21 "" "" 0 1000 "$(gib 100):23:19:20:2"
      emit_job_footer; } > "$W/r4.sh"
    check "generated: lower-CRF settings"       "grep -q 'crf_min=19 crf_max=23 down_headroom_pct=20 down_max=2' '$W/r4.sh'"
    bash -n "$W/r4.sh" && run_job r4
    check "real movie: lower CRF 19 verified"   "grep -q 'Selected CRF: *19' '$T/r4.log' && grep -qE 'AS PLANNED .*CRF 19(\\.0)? \\(single pass\\)' '$T/r4.log' && grep -q 'ENCODING (single pass, CRF 20)' '$T/r4.log' && [[ -f '$R/out/D.mkv' && -z \$(find '$R/out' -name '*.part') ]]"

    # series High, ceiling 1 byte: season 18 -> 19 (CRF_MAX), both verified at 19
    { emit_job_header r2 series 2
      for e in 1 2; do
          emit_encode_item "$e" "$R/in/E0$e.mkv" "$R/out/E0$e.mkv" High crf:18 "" "" 0 1000 "1:19:18:::batch"
      done
      emit_job_footer; } > "$W/r2.sh"
    check "generated: season batch functions"   "grep -q '^item_ctx_2() {' '$W/r2.sh' && grep -q '^item_prep_2() {' '$W/r2.sh' && grep -q '^job_batch_add 2\$' '$W/r2.sh' && grep -q '^job_crf_batch\$' '$W/r2.sh'"
    bash -n "$W/r2.sh" && run_job r2
    check "real series: both verified at CRF 19" "[[ \$(grep -cE 'AS PLANNED .*CRF 19(\\.0)? \\(single pass\\)' '$T/r2.log') == 2 ]] && [[ -f '$R/out/E01.mkv' && -f '$R/out/E02.mkv' ]] && grep -q 'retrying season at CRF 19' '$T/r2.log'"
    check "real series: no temp files"          "[[ -z \$(find '$R/out' -name '*.part') ]]"

    # series per episode (as series_compress.sh emits it now): ceiling 1
    # byte, E01 at the season CRF 18, E02 (outlier) at 19: each retried
    # alone up to CRF_MAX 19
    rm -f "$R"/out/E0?.mkv
    { emit_job_header r5 series 2
      emit_encode_item 1 "$R/in/E01.mkv" "$R/out/E01.mkv" High crf:18 "" "" 0 1000 "1:19:16:20:1::5" "" "17=1100:18=1000"
      emit_encode_item 2 "$R/in/E02.mkv" "$R/out/E02.mkv" High crf:19 "" "" 0 1000 "1:19:18:20:1::5" "" "18=1100:19=1000"
      emit_job_footer; } > "$W/r5.sh"
    check "generated: series episodes are items of their own" \
        "! grep -q '^job_batch_add' '$W/r5.sh' && [[ \$(grep -c '^   item_crf_encode item_encode_' '$W/r5.sh') == 2 ]] && grep -q 'crf_min=16 crf_max=19 down_headroom_pct=20 down_max=1 down_fit_pct=5 crf_est=17=1100:18=1000' '$W/r5.sh'"
    bash -n "$W/r5.sh" && run_job r5
    check "real series per episode: E01 18 -> 19, E02 19 kept" \
        "[[ \$(grep -cE 'AS PLANNED .*CRF 19(\\.0)? \\(single pass\\)' '$T/r5.log') == 2 ]] && [[ \$(grep -c 'ENCODING (single pass, CRF 19)' '$T/r5.log') == 2 ]] && ! grep -q 'season' '$T/r5.log' && [[ -f '$R/out/E01.mkv' && -f '$R/out/E02.mkv' ]]"
    check "real series per episode: no temp files" "[[ -z \$(find '$R/out' -name '*.part') ]]"

    # Quality: single-pass CRF with the band retry; Custom: no retry
    { emit_job_header r3 movie 2
      emit_encode_item 1 "$R/in/E01.mkv" "$R/out/Q.mkv" Quality crf:9 "" "" 0 1000 \
          "$(gib 22):23:0:20:2" "$(gib 20):$(gib 18):$(gib 22):band"
      emit_encode_item 2 "$R/in/E01.mkv" "$R/out/C.mkv" Custom crf:24 "" "" 0 1000 ""
      emit_job_footer; } > "$W/r3.sh"
    check "generated: Quality is CRF with the band retry" \
        "sed -n '/item 1/,/item 2/p' '$W/r3.sh' | grep -q 'item_crf_encode item_encode_1' && grep -q 'mode=crf crf=9 .*ceiling_vbytes=$(gib 22) crf_min=0 crf_max=23 .*down_below_vbytes=$(gib 18)' '$W/r3.sh' && ! grep -qE 'pass=1|pass=2|-b:v' '$W/r3.sh'"
    check "generated: Custom has no ceiling"    "grep -qF \"ceiling_vbytes='' crf_min='' crf_max=''\" '$W/r3.sh'"
fi

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
