#!/usr/bin/env bash
# Movie Quality policy tests (x265 CRF chosen for a VIDEO size band).
#
#   bash ~/compress/work/tests/quality_policy_tests.sh
#
# No ffmpeg needed except for the generated-job checks (skipped without
# ffmpeg / ffprobe). The post-encode Quality retry is covered by
# tests/crf_retry_tests.sh ("movie Quality"). Covers:
#   1. config: CRF min / start / max and band values, validation
#   2. CRF search from CRF_START (stand-in estimator): up when the start
#      is above the band, down otherwise; lowest CRF inside the band,
#      closest outside it, ties -> lower CRF, non-monotonic estimates,
#      CRF_MIN / CRF_MAX limits, every CRF estimated once
#   3. audio never part of the selection
#   4. source guard: estimates at or above the source are never chosen;
#      a source at or below the target is source-limited
#   5. report: selected CRF, estimated / actual video, target, band,
#      difference, result (ACCEPTABLE / OUTSIDE BAND / SOURCE-LIMITED /
#      SOURCE-PREFERRED)
#   6. High / Base / Custom and series unchanged
#   7. generated job: single-pass CRF, no two-pass rate control
#   8. real sample cache reused in both search directions (ffmpeg)
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
source "$SRC_WORK/lib/media_probe.sh"
source "$SRC_WORK/lib/media_stats.sh"
source "$SRC_WORK/lib/bitrate.sh"
source "$SRC_WORK/lib/encode_common.sh"
source "$SRC_WORK/lib/hdr_dovi.sh"
source "$SRC_WORK/lib/policy.sh"
source "$SRC_WORK/lib/job_runtime.sh"

gib_bytes() { awk -v g="$1" 'BEGIN { printf "%.0f", g * 1073741824 }'; }

conf_with() {   # NAME KEY=VALUE...  ->  modified copy of the default config
    local f="$T/conf_$1.conf" kv
    shift
    cp "$SRC_WORK/lib/compress.conf" "$f"
    for kv in "$@"; do
        sed -i "s|^${kv%%=*}=.*|${kv}|" "$f"
        grep -q "^${kv%%=*}=" "$f" || echo "$kv" >> "$f"
    done
    printf '%s' "$f"
}

export COMPRESS_CONF="$SRC_WORK/lib/compress.conf"
M="$SRC_WORK/movie_compress.sh"

# ------------------------------------------------------------
echo "== 1. config"
check "default compress.conf loads"        "load_policy 2>'$T/load.err'"
check "no notes for the default config"    "[[ ! -s '$T/load.err' ]]"
eq "Quality band in compress.conf" \
    "$MOVIE_QUALITY_TARGET_VIDEO_GIB $MOVIE_QUALITY_ACCEPT_MIN_GIB $MOVIE_QUALITY_ACCEPT_MAX_GIB" "20 18 22"
eq "Quality CRF min / start / max in compress.conf" \
    "$MOVIE_QUALITY_CRF_MIN $MOVIE_QUALITY_CRF_START $MOVIE_QUALITY_CRF_MAX" "0 8 23"
crf_tier_load movie Quality
eq "crf_tier_load movie Quality"           "$CRF_MIN $CRF_START $CRF_MAX $CRF_CEILING_GIB $CRF_CEILING_BYTES" "0 8 23 22 $(gib_bytes 22)"
check "Quality is a movie tier only"       "! crf_tier_load series Quality 2>/dev/null"
check "compress.conf: START is the first CRF sampled, not a minimum" \
    "grep -q '^# START is only the first CRF sampled' '$SRC_WORK/lib/compress.conf' && grep -q '^# MIN / MAX are the absolute lowest / highest CRF Quality may use' '$SRC_WORK/lib/compress.conf'"
check "no two-pass / GiB/hour Quality keys" \
    "! grep -qE '^MOVIE_QUALITY_VIDEO_(GIB_PER_HOUR|MIN_GIB|FLOOR_MBPS|MAX_MBPS)=' '$SRC_WORK/lib/compress.conf'"
check "no Quality numbers in the movie menu" \
    "! grep -nE '(MOVIE_QUALITY_[A-Z_]*)=\"?[0-9]|\\b(18|20|22) GiB|CRF_(MIN|MAX|START)=\"?[0-9]' '$M'"
check "two-pass Quality math removed" \
    "! declare -F movie_video_plan quality_target_text >/dev/null && ! grep -q 'movie_video_plan\\|TARGET_KBPS\\|PASS_DIR' '$M'"

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
reject "CRF_MIN above CRF_MAX"  'MOVIE_QUALITY_CRF_MAX (10) is lower than MOVIE_QUALITY_CRF_MIN (12)' MOVIE_QUALITY_CRF_MIN=12 MOVIE_QUALITY_CRF_START=12 MOVIE_QUALITY_CRF_MAX=10
reject "CRF_START below CRF_MIN" 'MOVIE_QUALITY_CRF_START (3) is lower than MOVIE_QUALITY_CRF_MIN (5)' MOVIE_QUALITY_CRF_MIN=5 MOVIE_QUALITY_CRF_START=3
reject "CRF_START above CRF_MAX" 'MOVIE_QUALITY_CRF_START (25) is greater than MOVIE_QUALITY_CRF_MAX (23)' MOVIE_QUALITY_CRF_START=25
reject "CRF_START above 51"     'MOVIE_QUALITY_CRF_START="52": outside the x265 CRF range 0-51' MOVIE_QUALITY_CRF_START=52
reject "negative CRF_START"     'MOVIE_QUALITY_CRF_START="-1": must not be negative' MOVIE_QUALITY_CRF_START=-1
reject "decimal CRF_START"      'MOVIE_QUALITY_CRF_START="8.5": must be a whole number' MOVIE_QUALITY_CRF_START=8.5
reject "CRF_MAX above 51"       'MOVIE_QUALITY_CRF_MAX="52": outside the x265 CRF range 0-51' MOVIE_QUALITY_CRF_MAX=52
reject "negative CRF_MIN"       'MOVIE_QUALITY_CRF_MIN="-1": must not be negative' MOVIE_QUALITY_CRF_MIN=-1
reject "decimal CRF"            'MOVIE_QUALITY_CRF_MAX="23.5": must be a whole number' MOVIE_QUALITY_CRF_MAX=23.5
reject "non-numeric CRF"        'MOVIE_QUALITY_CRF_MIN="low": must be a whole number' MOVIE_QUALITY_CRF_MIN=low
reject "zero target"            'MOVIE_QUALITY_TARGET_VIDEO_GIB="0": must be greater than 0' MOVIE_QUALITY_TARGET_VIDEO_GIB=0 MOVIE_QUALITY_ACCEPT_MIN_GIB=0
reject "zero band min"          'MOVIE_QUALITY_ACCEPT_MIN_GIB="0": must be greater than 0' MOVIE_QUALITY_ACCEPT_MIN_GIB=0
reject "zero band max"          'MOVIE_QUALITY_ACCEPT_MAX_GIB="0": must be greater than 0' MOVIE_QUALITY_ACCEPT_MAX_GIB=0
reject "band min above target"  'MOVIE_QUALITY_ACCEPT_MIN_GIB (21) is greater than MOVIE_QUALITY_TARGET_VIDEO_GIB (20)' MOVIE_QUALITY_ACCEPT_MIN_GIB=21
reject "target above band max"  'MOVIE_QUALITY_TARGET_VIDEO_GIB (23) is greater than MOVIE_QUALITY_ACCEPT_MAX_GIB (22)' MOVIE_QUALITY_TARGET_VIDEO_GIB=23
for k in MOVIE_QUALITY_CRF_MIN MOVIE_QUALITY_CRF_START MOVIE_QUALITY_CRF_MAX MOVIE_QUALITY_TARGET_VIDEO_GIB MOVIE_QUALITY_ACCEPT_MIN_GIB MOVIE_QUALITY_ACCEPT_MAX_GIB; do
    f=$(conf_with "unset$k"); sed -i "/^$k=/d" "$f"
    if ( COMPRESS_CONF="$f" load_policy ) > "$T/rej.out" 2>&1; then
        bad "rejects missing $k (was accepted)"
    else
        check "rejects missing $k" "grep -q '$k is not set' '$T/rej.out'"
    fi
done
check "MIN <= START <= MAX: START = MIN allowed" \
    "( COMPRESS_CONF=\$(conf_with smin MOVIE_QUALITY_CRF_MIN=8 MOVIE_QUALITY_CRF_START=8) load_policy )"
check "MIN <= START <= MAX: START = MAX allowed" \
    "( COMPRESS_CONF=\$(conf_with smax MOVIE_QUALITY_CRF_START=23) load_policy )"
check "CRF 51 and MIN = START = MAX allowed" \
    "( COMPRESS_CONF=\$(conf_with crfok MOVIE_QUALITY_CRF_MIN=51 MOVIE_QUALITY_CRF_START=51 MOVIE_QUALITY_CRF_MAX=51) load_policy )"
check "min = target = max allowed" \
    "( COMPRESS_CONF=\$(conf_with eq MOVIE_QUALITY_TARGET_VIDEO_GIB=20 MOVIE_QUALITY_ACCEPT_MIN_GIB=20 MOVIE_QUALITY_ACCEPT_MAX_GIB=20) load_policy )"
f=$(conf_with retired MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=8.4 MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12)
check "old two-pass keys: still loads, named as ignored" \
    "( COMPRESS_CONF='$f' load_policy ) 2>'$T/ret.err' && grep -q 'former Quality GiB/hour' '$T/ret.err' && grep -q MOVIE_QUALITY_VIDEO_FLOOR_MBPS '$T/ret.err'"
load_policy

# ------------------------------------------------------------
echo
echo "== 2. CRF search from CRF_START (stand-in estimator, GiB per CRF)"
declare -A EST=()
EST_CALLS=()
fake_est() {   # ESTIMATOR: EST[crf] GiB; "fail" = sample encode error
    EST_CALLS+=("$1")
    [[ "${EST[$1]:-}" == fail ]] && return 1
    CRF_EST_RESULT=$(gib_bytes "${EST[$1]:-0.1}")
}
T20=$(gib_bytes 20) L18=$(gib_bytes 18) H22=$(gib_bytes 22)
qsel() {   # MIN START MAX [SOURCE_GIB]  ->  crf_select_quality with EST
    local src=""
    [[ -n "${4:-}" ]] && src=$(gib_bytes "$4")
    EST_CALLS=()
    crf_select_quality "$1" "$2" "$3" "$T20" "$L18" "$H22" "$src" fake_est
}
est() { EST=(); local kv; for kv in "$@"; do EST[${kv%%=*}]="${kv#*=}"; done; }
calls() { printf '%s' "${EST_CALLS[*]}"; }

est 8=27.0 9=23.5 10=21.4 11=19.5
qsel 0 8 23
eq "A start above 22: searches upward"      "$(calls)" "8 9 10"
eq "A first in-band CRF upward (10, above START)" "$CRF_SELECTED $QUALITY_PICK" "10 band"

est 8=15.5 7=18.6 6=21.7 5=24.8 4=28
qsel 0 8 23
eq "B start below 18: searches downward"    "$(calls)" "8 7 6 5"
eq "B lowest CRF inside the band (6, below START)" "$CRF_SELECTED $QUALITY_PICK" "6 band"

est 8=19.1 7=21.5 6=24.0
qsel 0 8 23
eq "C start inside the band: still probes downward" "$(calls)" "8 7 6"
eq "C lowest CRF inside the band (7, not START)" "$CRF_SELECTED" 7

est 8=21.9 7=22.4
qsel 0 8 23
eq "C start inside, next lower above: START kept" "$CRF_SELECTED $(calls)" "8 8 7"

est 7=23.8 8=17.6 9=15
qsel 0 7 23
eq "no in-band result: closest to 20 (CRF 8, 2.4 vs 3.8)" "$CRF_SELECTED $QUALITY_PICK $(calls)" "8 closest 7 8"

est 7=22.5 8=17.5
qsel 0 7 23
eq "exact distance tie: lower CRF"          "$CRF_SELECTED" 7

est 8=17.5 7=17.4 6=22.5
qsel 0 8 23
eq "tie found downward: lower CRF"          "$CRF_SELECTED $(calls)" "6 8 7 6"

est 3=15 2=16 1=17 0=17.5
qsel 0 3 23
eq "never below CRF_MIN (0)"                "$(calls) | $CRF_SELECTED" "3 2 1 0 | 0"
est 6=15 5=16 4=17 3=19
qsel 5 6 23
eq "never below CRF_MIN (5)"                "$(calls) | $CRF_SELECTED $QUALITY_PICK" "6 5 | 5 closest"

est 8=40 9=35 10=30 11=20
qsel 0 8 10
# 40 GiB = 1.8 x the band's upper edge: upward + 2 (the bracket search of
# High / Base, tests/crf_adaptive_tests.sh); 9 is above the edge as well
eq "never above CRF_MAX"                    "$(calls) | $CRF_SELECTED" "8 10 | 10"
eq "CRF_MAX still above the band: flagged"  "$CRF_OVER_CEILING" 1

est 8=19 7=17.5 6=21 5=23
qsel 0 8 23
eq "non-monotonic downward: lowest in-band of the tested set" "$CRF_SELECTED $(calls)" "6 8 7 6 5"
est 8=23 9=24 10=19
qsel 0 8 23
eq "non-monotonic upward: continues, ends"  "$CRF_SELECTED $(calls)" "10 8 9 10"
est 8=23 9=17.5 10=19
qsel 0 8 23
eq "no revisits: each CRF estimated once"   "$(calls)" "8 9"
check "tested map has no duplicates"        "[[ \$(printf '%s\n' \"\${CRF_TRIED[@]}\" | sort | uniq -d | wc -l) == 0 ]]"
est 8=15 7=16 6=17 5=17.2 4=17.4 3=17.6 2=17.8 1=17.9 0=17.95
qsel 0 8 23
eq "flat estimates: stops at CRF_MIN, no loop" "$(calls) | $CRF_SELECTED" "8 7 6 5 4 3 2 1 0 | 0"

est 8=fail
qsel 0 8 23
eq "sample failure: nothing selected"       "$? ${CRF_SELECTED:-none}" "1 none"
est 8=27 9=fail
qsel 0 8 23
eq "failure while searching: nothing selected" "$? ${CRF_SELECTED:-none}" "1 none"

# the same tested map is reused: an estimate already in CRF_EST is not
# taken again (one menu run never samples a CRF twice)
est 8=27 9=21
EST_CALLS=()
declare -gA CRF_EST=([8]=$(gib_bytes 27))
CRF_TRIED=(8)
_CRF_SELECT_EST=fake_est
_crf_select_probe 8
eq "tested map: known CRF not re-estimated" "$(calls) $CRF_EST_RESULT/${CRF_TRIED[*]}" " $(gib_bytes 27)/8"

# ------------------------------------------------------------
echo
echo "== 3. audio not part of the selection"
check "crf_select_quality has no audio input" \
    "! sed -n '/^crf_select_quality()/,/^}/p' '$SRC_WORK/lib/policy.sh' | grep -qi audio"
check "menu selects on the source VIDEO bytes" \
    "grep -A3 'crf_select_quality \"\$CRF_MIN\"' '$M' | grep -q '\"\$SOURCE_VIDEO_BYTES\" crf_title_estimate'"
check "menu total = video estimate + copied audio + other" \
    "grep -qF 'crf_total_bytes \"\$EST_VIDEO_BYTES\" \"\$SOURCE_AUDIO_BYTES\" \"\$OTHER_BYTES\"' '$M'"

# ------------------------------------------------------------
echo
echo "== 4. source guard"
est 8=15 7=18.5 6=21.3 5=22.5
qsel 0 8 23 21
eq "downward search: estimate >= source never chosen (21 GiB source)" "$CRF_SELECTED $QUALITY_PICK $(calls)" "7 band 8 7 6"
est 8=27 9=21.5 10=20.5 11=18
qsel 0 8 23 21
eq "upward search: band capped below the source" "$CRF_SELECTED $(calls)" "10 8 9 10"
est 8=30 9=28 10=26
qsel 0 8 10 25
eq "nothing below the source: guard case"  "$CRF_SELECTED $QUALITY_PICK $CRF_OVER_CEILING" "10 none 1"
# source-limited (source at or below the target): band 0 .. source - 1,
# same search from CRF_START (lowest CRF below the source)
SRC16=$(gib_bytes 16)
est 8=14 7=15.5 6=16.5
EST_CALLS=()
crf_select_quality 0 8 23 $((SRC16 - 1)) 0 $((SRC16 - 1)) "$SRC16" fake_est
eq "source-limited, downward: lowest CRF below the source" "$CRF_SELECTED $(calls)" "7 8 7 6"
est 8=19 9=17 10=15
EST_CALLS=()
crf_select_quality 0 8 23 $((SRC16 - 1)) 0 $((SRC16 - 1)) "$SRC16" fake_est
eq "source-limited, upward: first CRF below the source" "$CRF_SELECTED $(calls)" "10 8 9 10"
check "15.8 GiB source: source-limited"    "quality_source_limited $(gib_bytes 15.8)"
check "20 GiB source: source-limited"      "quality_source_limited $(gib_bytes 20)"
check "20.5 GiB source: not source-limited" "! quality_source_limited $(gib_bytes 20.5)"
check "unknown source: not source-limited" "! quality_source_limited N/A"
check "menu: source guard before any sample encode, keep / encode / skip" \
    "grep -q 'Quality source guard: the source video' '$M' && grep -q '1) QUALITY_KEEP_SOURCE=1 ;;' '$M' && grep -q '2) QUALITY_STATUS=\"source-limited\" ;;' '$M'"
check "menu: source guard decided before CRF_START is used" \
    "[[ \$(grep -n 'Quality source guard: the source video' '$M' | cut -d: -f1) -lt \$(grep -n 'crf_select_quality \"\$CRF_MIN\" \"\$CRF_START\"' '$M' | head -n 1 | cut -d: -f1) ]]"
check "menu: existing CRF source-quality guard still applies" \
    "grep -q 'if crf_above_source \"\$EST_VIDEO_BYTES\" \"\$SOURCE_VIDEO_BYTES\"; then' '$M'"
eq "band classes" \
    "$(quality_band_class "$(gib_bytes 18.7)" "$L18" "$H22")/$(quality_band_class "$(gib_bytes 21.6)" "$L18" "$H22")/$(quality_band_class "$(gib_bytes 24)" "$L18" "$H22")/$(quality_band_class "$(gib_bytes 17.9)" "$L18" "$H22")" \
    "ACCEPTABLE/ACCEPTABLE/OUTSIDE BAND/OUTSIDE BAND"
check "no IDEAL class any more"            "[[ '$(quality_band_class "$(gib_bytes 20)" "$L18" "$H22")' == ACCEPTABLE ]] && ! grep -rq IDEAL '$SRC_WORK/lib'"

# ------------------------------------------------------------
echo
echo "== 5. post-encode report"
mkdir -p "$T/logs"
JOB_WORK="$T" JOB_SESSION=qtest ITEM_INPUT="$T/in.mkv" ITEM_DURATION=7200
get_duration() { echo 7200; }
file_bytes() { echo "$(( RPT_V + 3 * 1073741824 ))"; }
media_stream_totals() { echo "$RPT_V $(( 3 * 1073741824 ))"; }
report() {   # ACTUAL_GIB CRF PLANNED_CRF [STATUS [MODE]]
    RPT_V=$(gib_bytes "$1")
    declare -gA ITEM_EXP=()
    ITEM_ATTEMPT_ROWS=()
    ITEM_TIER=Quality
    if [[ "${5:-crf}" == copy ]]; then
        item_expect vidx=0 video=copy mode=copy
    elif [[ "${4:-band}" == band ]]; then
        item_expect mode=crf "crf=$2" "crf_planned=$3" "est_vbytes=$(gib_bytes 20.8)" \
            "qtarget_vbytes=$T20" "qmin_vbytes=$L18" "qmax_vbytes=$H22" qstatus=band
    else
        item_expect mode=crf "crf=$2" "crf_planned=$3" "est_vbytes=$(gib_bytes 15.2)" \
            "qtarget_vbytes=$(gib_bytes 15.8)" qmin_vbytes=0 "qmax_vbytes=$(( $(gib_bytes 15.8) - 1 ))" qstatus=source-limited
    fi
    report_output_stats "$T/out.mkv"
}
R=$(report 21.1 9 9)
check "report: selected CRF"         "grep -q '^    Selected CRF:       9\$' <<< \"\$R\""
check "report: estimated video"      "grep -q '^    Estimated video:    20.80 GiB\$' <<< \"\$R\""
check "report: actual video only"    "grep -q '^    Actual video:       21.10 GiB\$' <<< \"\$R\""
check "report: target + band"        "grep -q '^    Target:             20.00 GiB\$' <<< \"\$R\" && grep -q '^    Acceptable band:    18.00-22.00 GiB\$' <<< \"\$R\""
check "report: difference + result"  "grep -q '^    Difference:         +1.10 GiB\$' <<< \"\$R\" && grep -q '^    Result:             ACCEPTABLE\$' <<< \"\$R\""
check "report: CRF mode"             "grep -q 'Video encode mode:    CRF (single pass)' <<< \"\$R\" && ! grep -q two-pass <<< \"\$R\""
R=$(report 24.0 10 9)
check "report: OUTSIDE BAND"         "grep -q '^    Result:             OUTSIDE BAND\$' <<< \"\$R\" && grep -q 'Difference:         +4.00 GiB' <<< \"\$R\""
check "report: retried CRF estimate" "grep -q '^    Estimated video:    n/a at CRF 10 (planned CRF 9: 20.80 GiB)\$' <<< \"\$R\""
R=$(report 15.1 4 4 source-limited)
check "report: SOURCE-LIMITED"       "grep -q '^    Result:             SOURCE-LIMITED\$' <<< \"\$R\" && grep -q 'Target:             below the source video (15.80 GiB)' <<< \"\$R\""
R=$(report 15.8 "" "" "" copy)
check "report: SOURCE-PREFERRED"     "grep -q 'Quality result:       SOURCE-PREFERRED (source video kept)' <<< \"\$R\""
unset -f get_duration file_bytes media_stream_totals
source "$SRC_WORK/lib/media_probe.sh"
source "$SRC_WORK/lib/media_stats.sh"

# ------------------------------------------------------------
echo
echo "== 6. High / Base / Custom / series unchanged"
crf_tier_load movie High
eq "movie High from config"   "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB" "$MOVIE_HIGH_CRF_MIN $MOVIE_HIGH_CRF_MAX $MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB"
eq "movie High policy line"   "$(movie_policy_line High)" \
    "CRF $MOVIE_HIGH_CRF_MIN-$MOVIE_HIGH_CRF_MAX [CRF $MOVIE_HIGH_CRF_MIN preferred; raised only while the video estimate is above $MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB GiB]; audio copied"
crf_tier_load movie Base
eq "movie Base from config"   "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB" "$MOVIE_BASE_CRF_MIN $MOVIE_BASE_CRF_MAX $MOVIE_BASE_VIDEO_SIZE_CEILING_GIB"
crf_tier_load movie Custom 21.5
eq "Custom exact, no ceiling" "$CRF_MIN $CRF_MAX $CRF_CEILING_BYTES" "21.5 21.5 0"
eq "Custom policy line"       "$(movie_policy_line Custom)" "CRF entered in the menu, used exactly; audio copied"
crf_tier_load series High
eq "series High from config"  "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB" "$SERIES_HIGH_CRF_MIN $SERIES_HIGH_CRF_MAX $SERIES_HIGH_VIDEO_SIZE_CEILING_GIB"
crf_tier_load series Base
eq "series Base from config"  "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB" "$SERIES_BASE_CRF_MIN $SERIES_BASE_CRF_MAX $SERIES_BASE_VIDEO_SIZE_CEILING_GIB"
est 19=9 20=7.5 21=6.9 22=5
EST_CALLS=()
crf_select 19 23 "$(gib_bytes 7)" fake_est
eq "High/Base crf_select: first CRF under the ceiling" "$CRF_SELECTED ${CRF_TRIED[*]}" "21 19 20 21"
check "High/Base retry spec in the menu (+ predicted-fit margin)" \
    "grep -qF '[[ \"\$TIER\" != \"Custom\" ]] && RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:\$CRF_DOWN_RETRY_HEADROOM_PCT:\$CRF_DOWN_RETRY_MAX::\$CRF_DOWN_RETRY_FIT_MARGIN_PCT\"' '$M'"
check "Quality retry spec: no predicted-fit margin" \
    "grep -qF 'RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:\$CRF_DOWN_RETRY_HEADROOM_PCT:\$CRF_DOWN_RETRY_MAX\"' '$M' && ! grep -q 'band).*FIT_MARGIN' '$M'"
check "series menu does not use the Quality tier" "! grep -q 'Quality' '$SRC_WORK/series_compress.sh'"
est 20=3 21=2.5 22=1.9
EST_CALLS=()
crf_select 20 29 "$(gib_bytes 2)" fake_est
eq "Base crf_select: upward from CRF_MIN, CRF_MIN a hard floor" "$CRF_SELECTED $(calls)" "22 20 21 22"
est 20=1
EST_CALLS=()
crf_select 20 29 "$(gib_bytes 2)" fake_est
eq "Base crf_select: CRF_MIN already fits, never lower" "$CRF_SELECTED $(calls)" "20 20"
eq "Quality policy line"      "$(movie_policy_line Quality)" \
    "CRF 0-23, search starts at 8 [lowest CRF with the video estimate in 18-22 GiB, else closest to 20 GiB]; audio copied"
pl=$(crf_policy_lines movie Quality)
check "verbose Quality CRF search block" \
    "grep -q '^Quality CRF search:\$' <<< \"\$pl\" && grep -q '^  Range: 0-23\$' <<< \"\$pl\" && grep -q '^  Start: 8 (first CRF sampled' <<< \"\$pl\" && grep -q '^  Target: 20 GiB\$' <<< \"\$pl\" && grep -q '^  Band: 18-22 GiB' <<< \"\$pl\""
check "START never called a minimum" \
    "! { crf_policy_lines movie Quality; movie_policy_line Quality; grep -i 'START' '$M' '$SRC_WORK/lib/policy.sh'; } | grep -iE 'start.*minim|minim.*start' | grep -v 'not a minimum'"
check "High/Base CRF_MIN semantics unchanged" \
    "[[ \"\$(crf_policy_lines movie High | sed -n 2p)\" == '  CRF range: '$MOVIE_HIGH_CRF_MIN-$MOVIE_HIGH_CRF_MAX' ('$MOVIE_HIGH_CRF_MIN' preferred, raised only to fit the ceiling)' ]]"
eq "menu band text"           "$(quality_band_text)" "~20 GiB (18-22)"
check "movie menu: no two-pass wording" "! grep -qi 'two-pass' '$M'"

# ------------------------------------------------------------
echo
echo "== 7. generated job: Quality is single-pass CRF"
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=1" -f lavfi -i "sine=f=440:r=48000:d=1" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 96k "$T/in.mkv"
    emit_encode_item 1 "$T/in.mkv" "$T/Q.mkv" Quality crf:9 "" "" 0 "$(gib_bytes 20.8)" \
        "$H22:23:0:20:2" "$T20:$L18:$H22:band" > "$T/q.sh"
    check "job: bash -n"                 "bash -n '$T/q.sh'"
    check "job: -crf 9, preset, 10-bit"  "grep -q -- '-crf:v:0 9 ' '$T/q.sh' && grep -q -- '-preset' '$T/q.sh' && grep -q 'yuv420p10le' '$T/q.sh'"
    check "job: no two-pass rate control" "! grep -qE 'pass=1|pass=2|stats=|-b:v|_passes' '$T/q.sh'"
    check "job: copied audio"            "grep -q -- '-c:a copy' '$T/q.sh'"
    check "job: band retry"              "grep -q '^   item_crf_encode item_encode_1\$' '$T/q.sh' && grep -q \"mode=crf crf=9 .*ceiling_vbytes=$H22 crf_min=0 crf_max=23 down_headroom_pct=20 down_max=2 qtarget_vbytes=$T20 qmin_vbytes=$L18 qmax_vbytes=$H22 qstatus=band down_below_vbytes=$L18\" '$T/q.sh'"
    emit_encode_item 1 "$T/in.mkv" "$T/S.mkv" Quality crf:4 "" "" 0 "" \
        "$(gib_bytes 15):23:0:20:0" "$(gib_bytes 15.8):0:$(gib_bytes 15):source-limited" > "$T/s.sh"
    check "job: source-limited, no lower CRF" "grep -q 'qstatus=source-limited' '$T/s.sh' && grep -q 'down_max=0' '$T/s.sh' && ! grep -q down_below_vbytes '$T/s.sh'"
    emit_encode_item 2 "$T/in.mkv" "$T/H.mkv" High crf:20 "" "" 0 1000 "1:23:19:20:2" > "$T/h.sh"
    check "High job: CRF retry as before, no Quality keys" "grep -q 'ceiling_vbytes=1 crf_min=19 crf_max=23 down_headroom_pct=20 down_max=2' '$T/h.sh' && ! grep -qE 'qtarget_vbytes|down_below' '$T/h.sh'"
    check "job: CRF_START plays no part in the retry (absolute MIN only)" "! grep -qi 'start' <(grep 'item_expect' '$T/q.sh')"

    # real sample encodes: the cache is keyed by CRF, so estimates found
    # while searching up are reused when a later search goes down (and
    # the other way round); one search never encodes a CRF twice
    echo
    echo "== 8. sample cache in both directions (real sample encodes)"
    WORK_DIR="$T/w"
    mkdir -p "$WORK_DIR"
    CRF_SAMPLE_SECONDS=1
    CRF_TITLE_FILE="$T/in.mkv" CRF_TITLE_VIDX=0 CRF_TITLE_FILTER="" CRF_TITLE_DURATION=1 CRF_TITLE_POINTS=1
    eval "_real_$(declare -f crf_sample_encode)"
    ENCODES=()
    crf_sample_encode() { ENCODES+=("$5"); _real_crf_sample_encode "$@"; }
    # upward from 30 (huge band: 30 is above it, 31 at or below it)
    crf_title_estimate 30 > /dev/null
    B30="$CRF_EST_RESULT"
    crf_select_quality 20 30 40 1 1 $((B30 - 1)) "" crf_title_estimate > /dev/null
    eq "upward search: CRF 30, 31 sampled once each" "${ENCODES[*]}" "30 31"
    ENCODES=()
    crf_select_quality 20 31 40 1 1 "$B30" "" crf_title_estimate > /dev/null
    eq "downward search: 31 and 30 from the cache, only 29 encoded" "${ENCODES[*]}" "29"
    ENCODES=()
    crf_select_quality 20 29 31 1 1 1 "" crf_title_estimate > /dev/null
    eq "upward again: everything cached up to 31"  "${ENCODES[*]}" ""
    unset -f crf_sample_encode
    eval "$(declare -f _real_crf_sample_encode | sed '1s/^_real_//')"
else
    echo "  (ffmpeg / ffprobe not found: generated-job checks skipped)"
fi

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
