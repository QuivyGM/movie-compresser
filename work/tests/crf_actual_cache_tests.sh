#!/usr/bin/env bash
# Actual CRF result cache (movie High / Base): completed attempts saved
# by the job (item_actual_save), reused for exactly their CRF by a later
# search (crf_title_estimate_actual), fingerprint checks, cache failures.
#
#   bash ~/compress/work/tests/crf_actual_cache_tests.sh
#
# Stand-in encoder and estimator (no ffmpeg / ffprobe needed).
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
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy job_runtime; do
    source "$W/lib/$l.sh" > /dev/null
done
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
export PATH="$T/stub:$PATH"
echo movie > "$T/in/M.mkv"

# no ffprobe / ffmpeg: SDR source, a fixed encoder build
HDR_STUB='probe_hdr() { HDR_KIND="${FAKE_HDR_KIND:-SDR}"; HDR_PRIMARIES=""; HDR_TRANSFER=""; HDR_MATRIX=""; HDR_RANGE=""; HDR_CLL=""; HDR_MASTER=""; }'
eval "$HDR_STUB"
export CRF_ACTUAL_ENCODER_ID="ffmpeg version test"

sig() {   # [FILE [W H [DV [PRESET]]]]
    X265_PRESET="${5:-slow}" crf_actual_sig "${1:-$T/in/M.mkv}" 0 "" "${2:-1920}" "${3:-1080}" 7200 "${4:-none}" "" none
}
SIG=$(sig)
check "fingerprint built" "[[ '$SIG' == v1\\|stat=*'|out=1920x1080|'*'|preset=slow|pix=yuv420p10le|range=SDR|'*'|dv=none/|hdr10p=none|src='* ]]"

# ---- job side (stand-in encoder: "VIDEO_BYTES AUDIO_BYTES CRF")
STUBS='
get_duration() { echo 100; }
media_stream_totals() { local v a c; read -r v a c < "$1"; echo "$v $a"; }
item_verify_output() { :; }
refresh_mkv_stats() { return 0; }
get_resolution() { echo 1920x1080; }
main_video_index() { echo 0; }
declare -A SIZES=()
fake_encode() {
    local c="${ITEM_EXP[crf]}"
    [[ "${SIZES[$c]}" == fail ]] && return 1
    echo "${SIZES[$c]} $c" > "$ITEM_PART"
}
'
# movie_job SESSION CRF ACTUAL_SIG SIZES...  (High, ceiling 8.35 GiB, CRF 10-20, boundary)
movie_job() {
    local s="$1" crf="$2" sg="$3"
    shift 3
    rm -f "$T/out/M.mkv"
    {
        emit_job_header "$s" movie 1
        printf '%s\n' "$STUBS" "SIZES=($*)
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' High 0 '' &&
   item_expect vidx=0 mode=crf crf=$crf kbps= est_vbytes=1 atrans= ahash=1 ceiling_vbytes=$(gib 8.35) crf_min=10 crf_max=20 down_headroom_pct=0 down_max=1 down_mode=boundary $( [[ -n "$sg" ]] && printf 'actual_sig=%q' "$sg") &&
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
cached() { crf_actual_lookup "${2:-$SIG}" "$1" || echo none; }
cfile() { _crf_actual_file "$SIG"; }

echo "== 1 / 6 / 7: saving"

movie_job j1 13 "$SIG" "[13]='$(gib 6.7) $(gib 2)' [12]='$(gib 6.78) $(gib 2)'"
eq    "1 CRF 13 and boundary CRF 12 saved (video bytes only)" "$(cached 13)/$(cached 12)" "$(gib 6.7)/$(gib 6.78)"
check "1 job log line" "grep -q '^Saved actual CRF result: CRF 12 = 6.78 GiB$' '$T/j1.log'"
check "1 job succeeded, CRF 12 kept" "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 12 ]]"
check "1 cache file: signature line + one row per CRF" \
    "[[ \"\$(head -n 1 '$(cfile)')\" == '# $SIG' && \$(grep -c . '$(cfile)') == 3 ]]"

movie_job j2 12 "$SIG" "[12]='$(gib 6.9) 0' [11]='$(gib 9) 0'"
eq    "1 same CRF again: replaced by the newest measurement" "$(cached 12)" "$(gib 6.9)"
eq    "6 over-ceiling boundary attempt CRF 11 still saved" "$(cached 11)" "$(gib 9)"
eq    "1 no duplicate rows" "$(grep -c . "$(cfile)")" "4"

movie_job j3 15 "$SIG" "[15]='$(gib 9.5) 0' [16]='$(gib 8) 0'"
eq    "6 over-ceiling CRF 15 and upward retry CRF 16 saved" "$(cached 15)/$(cached 16)" "$(gib 9.5)/$(gib 8)"

movie_job j4 18 "$SIG" "[18]=fail"
eq    "7 failed encode: nothing saved" "$(cached 18)" "none"
movie_job j5 18 "$SIG" "[18]='$(gib 5) 0' [17]=fail"
eq    "7 failed boundary attempt: not saved (CRF 18 saved)" "$(cached 17)/$(cached 18)" "none/$(gib 5)"

movie_job j6 19 "" "[19]='$(gib 5) 0' [18]='$(gib 6) 0'"
eq    "no fingerprint (Quality / Series / Custom jobs): nothing saved" "$(cached 19)/$(cached 18)" "none/$(gib 5)"

echo "== 2 / 3: search reuse, exact CRF only"

declare -A FAKE_EST=([13]=$(gib 7.84) [12]=$(gib 9.72) [11]=$(gib 9.9) [10]=$(gib 10.5))
CALLS=""
crf_title_estimate() {   # stand-in sampler
    CALLS+="$1 "
    printf '  CRF %-4s ' "$1"
    CRF_EST_RESULT="${FAKE_EST[$1]}"
    echo "~$(bytes_to_gib "$CRF_EST_RESULT") GiB"
}
search() {   # START  ->  "SELECTED|sampled CRFs" (High, 10-20, 8.35 GiB)
    CALLS=""
    declare -gA CRF_ACTUAL_HIT=()
    crf_select_boundary "$1" 10 20 "$(gib 8.35)" crf_title_estimate_actual crf_title_step_report > "$T/search.out"
    echo "$CRF_SELECTED|$CALLS"
}

rm -f "$(cfile)"
crf_actual_save "$SIG" 12 "$(gib 6.78)"
CRF_ACTUAL_SIG="$SIG"
eq    "2 cached CRF 12 (6.78 actual vs 9.72 sampled) fits -> CRF 11 sampled; 12 selected" "$(search 12)" "12|11 "
check "2 output labelled" "grep -q '^  CRF 12   6.78 GiB actual (cached)\$' '$T/search.out' && grep -q 'fits -> trying CRF 11' '$T/search.out'"
search 12 > /dev/null
eq    "2 search map holds the actual bytes" "${CRF_EST[12]}" "$(gib 6.78)"
eq    "3 from 13: 13 sampled, 12 cached, 11 sampled" "$(search 13)" "12|13 11 "
check "3 CRF 11 uses the estimate (no extrapolation)" "grep -q '^  CRF 11   ~9.90 GiB' '$T/search.out'"
eq    "analysis lines mark the cached CRF" "$(crf_analysis_lines | grep 'CRF 12')" "  CRF 12 -> actual 6.78 GiB video (cached)"

echo "== 4 / 5: incompatible or changed -> ignored"

eq    "4 other resolution"      "$(cached 12 "$(sig "" 1280 720)")" "none"
eq    "4 other preset"          "$(cached 12 "$(sig "" 1920 1080 none medium)")" "none"
eq    "4 other DV processing"   "$(cached 12 "$(sig "" 1920 1080 preserve)")" "none"
eq    "4 other dynamic range"   "$(cached 12 "$(FAKE_HDR_KIND=HDR10 sig)")" "none"
eq    "4 other encoder build"   "$(cached 12 "$(CRF_ACTUAL_ENCODER_ID='ffmpeg version 2' sig)")" "none"
cp "$T/in/M.mkv" "$T/in/Other.mkv"
eq    "4 other source"          "$(cached 12 "$(sig "$T/in/Other.mkv")")" "none"
CRF_ACTUAL_SIG="$(sig "" 1280 720)"
eq    "4 search with another fingerprint samples CRF 12" "$(search 12)" "13|12 13 "
check "unknown part (no encoder build): no fingerprint" "! ( CRF_ACTUAL_ENCODER_ID=''; ffmpeg() { return 1; }; sig > /dev/null )"

echo extra >> "$T/in/M.mkv"
eq    "5 source size changed: ignored" "$(cached 12 "$(sig)")" "none"
touch -d '2001-01-01' "$T/in/M.mkv"
eq    "5 source mtime changed: ignored" "$(cached 12 "$(sig)")" "none"
movie_job j7 14 "$SIG" "[14]='$(gib 7) 0' [13]='$(gib 7.5) 0'"
eq    "5 source changed after the search: job does not save" "$(cached 14)" "none"
check "5 job says why" "grep -q 'source changed since the CRF search' '$T/j7.log'"
check "5 job still succeeded" "[[ \$(awk '{print \$3}' '$T/out/M.mkv') == 13 ]]"
SIG=$(sig)

echo "== 8: cache failures never break anything"

printf 'garbage\n12\tnot-a-number\n' > "$(cfile)"
CRF_ACTUAL_SIG="$SIG"
eq    "8 corrupt cache file: CRF 12 sampled" "$(search 12)" "13|12 13 "
rm -f "$(cfile)"
rm -rf "$W/cache/crf_actual"
mkdir -p "$W/cache"
echo blocked > "$W/cache/crf_actual"   # a file where the directory should be
movie_job j8 13 "$SIG" "[13]='$(gib 6.7) 0' [12]='$(gib 6.8) 0'"
check "8 save fails: warning only, job succeeded with CRF 12" \
    "grep -q 'WARNING: could not save the actual CRF 13 result' '$T/j8.log' && [[ \$(awk '{print \$3}' '$T/out/M.mkv') == 12 ]]"
eq    "8 search still works from estimates" "$(search 12)" "13|12 13 "
check "8 CRF_ACTUAL_CACHE=0: lookup off" "! CRF_ACTUAL_CACHE=0 crf_actual_lookup '$SIG' 12"
rm -f "$W/cache/crf_actual"

echo "== Series / Quality / Custom untouched"

M="$SRC_WORK/movie_compress.sh"
check "menu: only High / Base build a fingerprint" \
    "grep -qF 'if [[ ( \"\$TIER\" == High || \"\$TIER\" == Base ) && -z \"\$QUALITY_STATUS\" ]]; then' '$M'"
check "menu: Quality and Custom searches still sample (crf_title_estimate)"     "[[ \$(grep -c '\"\$SOURCE_VIDEO_BYTES\" crf_title_estimate crf_title_step_report' '$M') == 2 ]] && grep -qF 'crf_select_exact \"\$CUSTOM_CRF\" crf_title_estimate ||' '$M' && [[ \$(grep -c crf_title_estimate_actual '$M') == 1 ]]"
check "series menu does not use the actual cache" \
    "! grep -qE 'crf_actual|crf_title_estimate_actual|actual_sig' '$SRC_WORK/series_compress.sh'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
