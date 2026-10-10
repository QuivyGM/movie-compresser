#!/usr/bin/env bash
# Series High / Base shared season CRF: every episode finishes at ONE
# CRF (job_runtime.sh job_crf_batch, batch_mode=season; policy.sh
# series_crf_shared / series_season_retry_spec).
#
#   bash ~/compress/work/tests/series_shared_crf_tests.sh
#
# Seconds, no ffmpeg: series jobs are generated with emit_encode_item
# (stand-in probes) and run with a stand-in encoder (video / audio
# bytes per episode and CRF); the season estimator runs with stand-in
# sample encodes.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${SHARED_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE SERIES_CRF_SHARED
G=1073741824
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }

W="$T/work"
mkdir -p "$W/logs" "$T/in/Show" "$T/out/Show" "$T/stub"
cp -r "$SRC_WORK/lib" "$W/"
WORK_DIR="$W"
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy naming job_runtime; do
    source "$W/lib/$l.sh" > /dev/null
done
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
export PATH="$T/stub:$PATH"

for e in 1 2 3 4 5 6; do echo "episode $e" > "$T/in/Show/Show.S01E0$e.mkv"; done

# ------------------------------------------------------------
echo "== tier ceilings (project config)"

COMPRESS_CONF="$SRC_WORK/lib/compress.conf" load_policy > /dev/null
crf_tier_load series High
eq    "High: 5 GiB video per episode"           "$CRF_CEILING_BYTES" "$(gib 5)"
HIGH_SPEC=$(series_season_retry_spec High "$CRF_CEILING_BYTES" "$CRF_MAX" "$CRF_MIN")
eq    "High retry spec: season batch, floor = SEARCH_MIN" "$HIGH_SPEC" "$(gib 5):$SERIES_HIGH_CRF_MAX:$SERIES_HIGH_CRF_SEARCH_MIN:::season"
crf_tier_load series Base
eq    "Base: 1.5 GiB video per episode"         "$CRF_CEILING_BYTES" "$(gib 1.5)"
eq    "Custom: no retry"                        "$(series_season_retry_spec Custom 0 '' '')" ""

# ------------------------------------------------------------
# Generator stand-ins (no ffprobe): one video stream, SDR, no covers
main_video_index()   { echo 0; }
probe_hdr()          { HDR_DV=0; HDR_HDR10PLUS=0; HDR_DV_PROFILE=""; }
build_stream_map()   { MAP_ARGS="-map 0:0"; MAP_CODEC_ARGS=""; MAP_META_ARGS=""; MAP_OTHER_ARGS=""; MAP_COVERS=(); MAP_NOTES=(); }
x265_color_params()  { :; }
color_output_args()  { :; }
libx265_has_option() { return 1; }
stale_stats_args()   { :; }
matroska_mux_args()  { :; }

# Job stand-ins: the "encoder" writes "VIDEO_BYTES AUDIO_BYTES CRF" into
# $ITEM_PART from SIZES[EPISODE:CRF] ("fail" = the encode fails); the
# verification records the CRF it was asked to verify.
STUBS='
get_duration() { echo 100; }
media_stream_totals() { local v a c; read -r v a c < "$1"; echo "$v $a"; }
item_verify_output() { echo "$ITEM_INDEX:${ITEM_EXP[crf]}" >> "'"$T"'/$JOB_SESSION.verified"; }
item_restore_mkv_chapters() { return 0; }
item_step() { shift; "$@"; }
refresh_mkv_stats() { return 0; }
item_run() {
    local c="${ITEM_EXP[crf]}" s
    s="${SIZES[$ITEM_INDEX:$c]:-}"
    echo "$ITEM_INDEX:$c" >> "'"$T"'/$JOB_SESSION.encoded"
    [[ -z "$s" || "$s" == fail ]] && return 1
    echo "$s $c" > "$ITEM_PART"
}
'

# season SESSION CRF CRF_MIN CRF_MAX N SIZES...  ->  a series job as
# series_compress.sh generates it (High, 5 GiB ceiling, every episode at
# CRF, retry field from series_season_retry_spec), run with SIZES
season() {
    local s="$1" crf="$2" min="$3" max="$4" n="$5" e spec
    shift 5
    rm -f "$T"/out/Show/* "$T/$s.encoded" "$T/$s.verified"
    spec=$(series_season_retry_spec High "$(gib 5)" "$max" "$min")
    {
        emit_job_header "$s" series "$n"
        printf '%s\n' "$STUBS" "declare -A SIZES=($*)"
        for ((e = 1; e <= n; e++)); do
            emit_encode_item "$e" "$T/in/Show/Show.S01E0$e.mkv" "$T/out/Show/E0$e.mkv" High "crf:$crf" "" "" 0 \
                "$(gib 4.5)" "$spec" "" "$((crf - 1))=$(gib 5):$crf=$(gib 4.5)"
        done
        emit_job_footer
    } > "$W/$s.sh"
    bash -n "$W/$s.sh" || { bad "$s: generated job fails bash -n"; return; }
    cp "$W/$s.sh" "$T/$s.job"   # a finished job deletes its own script
    bash "$W/$s.sh" < /dev/null > "$T/$s.log" 2>&1
}
encoded()    { tr '\n' ' ' < "$T/$1.encoded" 2>/dev/null; }
verified()   { tr '\n' ' ' < "$T/$1.verified" 2>/dev/null; }
final_crfs() { local f; for f in "$T"/out/Show/E0?.mkv; do awk '{ printf "%s ", $3 }' "$f"; done; }
leftovers()  { find "$T/out" \( -name '*.part' -o -name '*.retry-crf*' -o -name '*.accepted-crf*' \) | sort | tr '\n' ' '; }
logged()     { grep -qxF -- "$2" "$T/$1.log"; }
# sz EPISODE:CRF VIDEO_GIB [AUDIO_GIB]  ->  one SIZES entry
sz() { printf "[%s]='%s %s'" "$1" "$(gib "$2")" "$(gib "${3:-0.5}")"; }

# ------------------------------------------------------------
echo
echo "== generated series job (item 7: no per-episode retry)"

season g1 16 15 18 3 "$(sz 1:16 4) $(sz 2:16 4) $(sz 3:16 4) $(sz 1:15 6) $(sz 2:15 6) $(sz 3:15 6)"
check "7 every episode in the season batch"     "[[ \$(grep -c '^job_batch_add ' '$T/g1.job') == 3 ]] && grep -q '^job_crf_batch\$' '$T/g1.job'"
check "7 no per-episode CRF retry"              "! grep -q 'item_crf_encode' '$T/g1.job'"
check "7 no headroom / lower-CRF / fit settings" "[[ \$(grep -c \"down_headroom_pct='' down_max=''\" '$T/g1.job') == 3 ]] && ! grep -q 'down_fit_pct' '$T/g1.job' && ! grep -q 'down_mode' '$T/g1.job'"
check "7 season mode + episode labels"          "[[ \$(grep -c ' batch_mode=season ep_label=S01E0' '$T/g1.job') == 3 ]]"

# ------------------------------------------------------------
echo
echo "== season flow (High, ceiling 5 GiB)"

# 1: CRF 16 fits for every episode (audio not counted: 4.9 + 3 GiB
#    audio fits); the CRF 15 season does not fit -> all stay at 16
season s1 16 15 18 3 "$(sz 1:16 4.3 3) $(sz 2:16 3.93) $(sz 3:16 4.9 3) $(sz 1:15 5.2) $(sz 2:15 5.1) $(sz 3:15 5.6)"
eq    "1 N fits: final CRFs"                    "$(final_crfs)" "16 16 16 "
eq    "1 verified at N"                         "$(verified s1)" "1:16 2:16 3:16 "
check "1 audio not counted (4.90 + 3 GiB audio fits)" "logged s1 '  S01E03 4.90 GiB / 5.00 GiB -> fits'"
check "1 season log" \
    "logged s1 'Season CRF 16 actual results:' && logged s1 '  S01E01 4.30 GiB / 5.00 GiB -> fits' && logged s1 'All episodes fit at CRF 16.' && logged s1 'Testing season CRF 15 for better quality...'"
check "1 final summary"                          "logged s1 'Final season CRF: 16' && logged s1 'Episodes: 3/3 at CRF 16'"
eq    "1 no temporary files left"                "$(leftovers)" ""

# 2: CRF 16 and the whole CRF 15 season fit -> all at 15, never 14
season s2 16 13 18 3 "$(sz 1:16 4) $(sz 2:16 4) $(sz 3:16 4) $(sz 1:15 4.6) $(sz 2:15 4.7) $(sz 3:15 4.99) $(sz 1:14 4.8) $(sz 2:14 4.8) $(sz 3:14 4.8)"
eq    "2 N-1 fits: final CRFs"                  "$(final_crfs)" "15 15 15 "
eq    "2 encoded: N, then N-1 once, no N-2"     "$(encoded s2)" "1:16 2:16 3:16 1:15 2:15 3:15 "
check "2 season log"                            "logged s2 'All episodes fit at CRF 15.' && logged s2 'Keeping entire season at CRF 15.' && logged s2 'Final season CRF: 15' && logged s2 'Episodes: 3/3 at CRF 15'"
eq    "2 verified at N-1"                       "$(verified s2)" "1:15 2:15 3:15 "
eq    "2 no temporary files left"               "$(leftovers)" ""

# 3: CRF 16 fits, ONE episode above the ceiling at 15 -> whole season 16
season s3 16 15 18 6 "$(sz 1:16 4.3) $(sz 2:16 3.93) $(sz 3:16 4.5) $(sz 4:16 4.1) $(sz 5:16 4.6) $(sz 6:16 4.0)" \
    "$(sz 1:15 4.8) $(sz 2:15 4.4) $(sz 3:15 4.9) $(sz 4:15 4.6) $(sz 5:15 5.18) $(sz 6:15 4.5)"
eq    "3 one N-1 episode over: all stay at N"   "$(final_crfs)" "16 16 16 16 16 16 "
check "3 season log" \
    "logged s3 '  S01E05 5.18 GiB / 5.00 GiB -> over ceiling' && logged s3 'CRF 15 season does not fit.' && logged s3 'Keeping entire season at CRF 16.' && logged s3 'Episodes: 6/6 at CRF 16'"
eq    "3 rejected N-1 season removed, N kept"   "$(leftovers)" ""

# 4: one episode above the ceiling at 16 -> the whole season at 17;
#    16 is proven over, so no N-1 test afterwards
season s4 16 15 18 6 "$(sz 1:16 4.3) $(sz 2:16 3.9) $(sz 3:16 4.5) $(sz 4:16 4.1) $(sz 5:16 5.3) $(sz 6:16 4.0)" \
    "$(sz 1:17 3.8) $(sz 2:17 3.4) $(sz 3:17 4.0) $(sz 4:17 3.6) $(sz 5:17 4.7) $(sz 6:17 3.5)"
eq    "4 N over: whole season N+1, no mix"      "$(final_crfs)" "17 17 17 17 17 17 "
eq    "4 encoded: N, then N+1, no retest of N" "$(encoded s4)" "1:16 2:16 3:16 4:16 5:16 6:16 1:17 2:17 3:17 4:17 5:17 6:17 "
check "4 season log" \
    "logged s4 '  S01E05 5.30 GiB / 5.00 GiB -> over ceiling' && logged s4 'Retrying the entire season at CRF 17...' && logged s4 'CRF 16 was already over the ceiling for this season; keeping entire season at CRF 17.' && logged s4 'Episodes: 6/6 at CRF 17'"
eq    "4 verified at N+1"                       "$(verified s4)" "1:17 2:17 3:17 4:17 5:17 6:17 "
eq    "4 no temporary files left"               "$(leftovers)" ""

# 5: N = SEARCH_MIN -> no N-1 test
season s5 15 15 18 3 "$(sz 1:15 3) $(sz 2:15 3) $(sz 3:15 3) $(sz 1:14 3.5) $(sz 2:14 3.5) $(sz 3:14 3.5)"
eq    "5 SEARCH_MIN: no N-1 test"               "$(encoded s5)" "1:15 2:15 3:15 "
check "5 minimum reported"                      "logged s5 'CRF 15 is the High minimum; keeping entire season at CRF 15.' && [[ '$(final_crfs)' == '15 15 15 ' ]]"

# 6: CRF_MAX still above for one episode -> warning, every episode at
#    CRF_MAX, only that episode reported above the ceiling
season s6 17 15 18 3 "$(sz 1:17 4) $(sz 2:17 6) $(sz 3:17 4) $(sz 1:18 3.6) $(sz 2:18 5.5) $(sz 3:18 3.6)"
eq    "6 CRF_MAX: one CRF, never above it"      "$(final_crfs)/$(encoded s6)" "18 18 18 /1:17 2:17 3:17 1:18 2:18 3:18 "
check "6 warning + only the over episode listed" \
    "grep -q 'per-episode video ceiling cannot be met within the' '$T/s6.log' && [[ \$(sed -n '/^Above the video ceiling/,/^CRF attempts/p' '$T/s6.log' | grep -c 'Show.S01E0') == 1 ]] && sed -n '/^Above the video ceiling/,/^CRF attempts/p' '$T/s6.log' | grep -q 'Show.S01E02.mkv'"
check "6 no N-1 test after CRF_MAX over"        "! grep -q 'Testing season CRF' '$T/s6.log'"

# safety: the N-1 season fails half way -> accepted N season intact
season s7 16 15 18 3 "$(sz 1:16 4) $(sz 2:16 4) $(sz 3:16 4) $(sz 1:15 4.2) [2:15]=fail"
eq    "N-1 retry fails: season kept at N"       "$(final_crfs)/$(verified s7)" "16 16 16 /1:16 2:16 3:16 "
eq    "N-1 retry fails: partial attempt removed" "$(leftovers)" ""

# ------------------------------------------------------------
echo
echo "== estimator: isolated outlier raises the shared season CRF (item 8)"

# SEP[n]: video GiB of episode En per 45 min at CRF 18; -12 % per step
declare -A SEP=()
crf_sample_title() {   # FILE VIDX FILTER CRF DURATION POINTS
    local n="${1##*/E}"
    n="${n%.mkv}"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=$(awk -v g="${SEP[$n]}" -v c="$4" 'BEGIN { printf "%.0f", g * 1073741824 * 0.88 ^ (c - 18) / 27 }')
}
COMPRESS_CONF=$(mktemp -p "$T")
sed -e 's/^SERIES_HIGH_CRF_SEARCH_MIN=.*/SERIES_HIGH_CRF_SEARCH_MIN=18/' -e 's/^SERIES_HIGH_CRF_START=.*/SERIES_HIGH_CRF_START=18/' \
    -e 's/^SERIES_HIGH_CRF_MAX=.*/SERIES_HIGH_CRF_MAX=21/' "$SRC_WORK/lib/compress.conf" > "$COMPRESS_CONF"
export COMPRESS_CONF
check "test policy loads (High CRF 18-21)"      "load_policy > /dev/null"

select_season() {   # GIB...  ->  SEL "CRF/OUTLIER"
    local n eb
    FILES=(); EP_VIDX=(); EP_DUR=(); CRF_SERIES_LABELS=()
    for ((n = 1; n <= $#; n++)); do
        FILES+=("/s/E$n.mkv"); EP_VIDX+=(0); EP_DUR+=(2700); SEP[$n]="${!n}"; CRF_SERIES_LABELS+=("E$n")
    done
    CRF_SERIES_SAMPLED=($(seq 0 $(($# - 1))))
    CRF_SERIES_FILTER=""
    declare -gA CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
    crf_tier_load series High
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate "" series_crf_certify_over > /dev/null
    read -ra eb <<< "${CRF_SERIES_EP_BYTES[$CRF_SELECTED]}"
    series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}"
    SEL="$CRF_SELECTED/${SB_ISOLATED:--}/$SB_FITS"
}

# E3 6.0 GiB at 18 (-> 5.28 at 19, 4.65 at 20) is the only outlier
SERIES_CRF_SHARED=1 select_season 3.7 4.2 6.0 3.9 4.0 4.1
eq    "8 shared: outlier raises the season to CRF 20" "$SEL" "20/2/1"
SERIES_CRF_SHARED=0 select_season 3.7 4.2 6.0 3.9 4.0 4.1
eq    "8 (earlier rules, old-job compatibility: season 18 without the outlier)" "$SEL" "18/2/1"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
