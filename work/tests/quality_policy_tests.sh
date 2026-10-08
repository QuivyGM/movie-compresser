#!/usr/bin/env bash
# Movie Quality policy tests (x265 CRF chosen for a VIDEO size band).
#
#   bash ~/compress/work/tests/quality_policy_tests.sh
#
# No ffmpeg needed except for the generated-job checks (skipped without
# ffmpeg / ffprobe). The post-encode Quality retry is covered by
# tests/crf_retry_tests.sh ("movie Quality"). Covers:
#   1. config: CRF range and band values, validation
#   2. CRF selection (stand-in estimator): lowest CRF inside the band,
#      never a higher CRF just to get closer to the target, closest
#      outside the band, ties -> lower CRF, non-monotonic estimates,
#      CRF_MIN / CRF_MAX limits, early stop
#   3. audio never part of the selection
#   4. source guard: estimates at or above the source are never chosen;
#      a source at or below the target is source-limited
#   5. report: selected CRF, estimated / actual video, target, band,
#      difference, result (ACCEPTABLE / OUTSIDE BAND / SOURCE-LIMITED /
#      SOURCE-PREFERRED)
#   6. High / Base / Custom and series unchanged
#   7. generated job: single-pass CRF, no two-pass rate control
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
eq "Quality CRF range in compress.conf"    "$MOVIE_QUALITY_CRF_MIN $MOVIE_QUALITY_CRF_MAX" "0 23"
crf_tier_load movie Quality
eq "crf_tier_load movie Quality"           "$CRF_MIN $CRF_MAX $CRF_CEILING_GIB $CRF_CEILING_BYTES" "0 23 22 $(gib_bytes 22)"
check "Quality is a movie tier only"       "! crf_tier_load series Quality 2>/dev/null"
check "no two-pass / GiB/hour Quality keys" \
    "! grep -qE '^MOVIE_QUALITY_VIDEO_(GIB_PER_HOUR|MIN_GIB|FLOOR_MBPS|MAX_MBPS)=' '$SRC_WORK/lib/compress.conf'"
check "no Quality numbers in the movie menu" \
    "! grep -nE '(MOVIE_QUALITY_[A-Z_]*)=\"?[0-9]|\\b(18|20|22) GiB|CRF_(MIN|MAX)=\"?[0-9]' '$M'"
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
reject "CRF_MIN above CRF_MAX"  'MOVIE_QUALITY_CRF_MAX (10) is lower than MOVIE_QUALITY_CRF_MIN (12)' MOVIE_QUALITY_CRF_MIN=12 MOVIE_QUALITY_CRF_MAX=10
reject "CRF_MAX above 51"       'MOVIE_QUALITY_CRF_MAX="52": outside the x265 CRF range 0-51' MOVIE_QUALITY_CRF_MAX=52
reject "negative CRF_MIN"       'MOVIE_QUALITY_CRF_MIN="-1": must not be negative' MOVIE_QUALITY_CRF_MIN=-1
reject "decimal CRF"            'MOVIE_QUALITY_CRF_MAX="23.5": must be a whole number' MOVIE_QUALITY_CRF_MAX=23.5
reject "non-numeric CRF"        'MOVIE_QUALITY_CRF_MIN="low": must be a whole number' MOVIE_QUALITY_CRF_MIN=low
reject "zero target"            'MOVIE_QUALITY_TARGET_VIDEO_GIB="0": must be greater than 0' MOVIE_QUALITY_TARGET_VIDEO_GIB=0 MOVIE_QUALITY_ACCEPT_MIN_GIB=0
reject "zero band min"          'MOVIE_QUALITY_ACCEPT_MIN_GIB="0": must be greater than 0' MOVIE_QUALITY_ACCEPT_MIN_GIB=0
reject "zero band max"          'MOVIE_QUALITY_ACCEPT_MAX_GIB="0": must be greater than 0' MOVIE_QUALITY_ACCEPT_MAX_GIB=0
reject "band min above target"  'MOVIE_QUALITY_ACCEPT_MIN_GIB (21) is greater than MOVIE_QUALITY_TARGET_VIDEO_GIB (20)' MOVIE_QUALITY_ACCEPT_MIN_GIB=21
reject "target above band max"  'MOVIE_QUALITY_TARGET_VIDEO_GIB (23) is greater than MOVIE_QUALITY_ACCEPT_MAX_GIB (22)' MOVIE_QUALITY_TARGET_VIDEO_GIB=23
for k in MOVIE_QUALITY_CRF_MIN MOVIE_QUALITY_CRF_MAX MOVIE_QUALITY_TARGET_VIDEO_GIB MOVIE_QUALITY_ACCEPT_MIN_GIB MOVIE_QUALITY_ACCEPT_MAX_GIB; do
    f=$(conf_with "unset$k"); sed -i "/^$k=/d" "$f"
    if ( COMPRESS_CONF="$f" load_policy ) > "$T/rej.out" 2>&1; then
        bad "rejects missing $k (was accepted)"
    else
        check "rejects missing $k" "grep -q '$k is not set' '$T/rej.out'"
    fi
done
check "CRF 0-51 and CRF_MIN = CRF_MAX allowed" \
    "( COMPRESS_CONF=\$(conf_with crfok MOVIE_QUALITY_CRF_MIN=51 MOVIE_QUALITY_CRF_MAX=51) load_policy )"
check "min = target = max allowed" \
    "( COMPRESS_CONF=\$(conf_with eq MOVIE_QUALITY_TARGET_VIDEO_GIB=20 MOVIE_QUALITY_ACCEPT_MIN_GIB=20 MOVIE_QUALITY_ACCEPT_MAX_GIB=20) load_policy )"
f=$(conf_with retired MOVIE_QUALITY_VIDEO_GIB_PER_HOUR=8.4 MOVIE_QUALITY_VIDEO_FLOOR_MBPS=12)
check "old two-pass keys: still loads, named as ignored" \
    "( COMPRESS_CONF='$f' load_policy ) 2>'$T/ret.err' && grep -q 'former Quality GiB/hour' '$T/ret.err' && grep -q MOVIE_QUALITY_VIDEO_FLOOR_MBPS '$T/ret.err'"
load_policy

# ------------------------------------------------------------
echo
echo "== 2. CRF selection (stand-in estimator, GiB per CRF)"
declare -A EST=()
EST_CALLS=()
fake_est() {   # ESTIMATOR: EST[crf] GiB; "fail" = sample encode error
    EST_CALLS+=("$1")
    [[ "${EST[$1]:-}" == fail ]] && return 1
    CRF_EST_RESULT=$(gib_bytes "${EST[$1]:-0.1}")
}
T20=$(gib_bytes 20) L18=$(gib_bytes 18) H22=$(gib_bytes 22)
qsel() {   # MIN MAX [SOURCE_GIB]  ->  crf_select_quality with EST
    local src=""
    [[ -n "${3:-}" ]] && src=$(gib_bytes "$3")
    EST_CALLS=()
    crf_select_quality "$1" "$2" "$T20" "$L18" "$H22" "$src" fake_est
}
est() { EST=(); local kv; for kv in "$@"; do EST[${kv%%=*}]="${kv#*=}"; done; }

est 8=23.4 9=21.2 10=18.7
qsel 8 23
eq "lowest CRF inside 18-22 (9, not 10)"   "$CRF_SELECTED $QUALITY_PICK" "9 band"
eq "stops at the first CRF inside the band" "${CRF_TRIED[*]}" "8 9"

est 8=21.9 9=20.0 10=18.5
qsel 8 23
eq "not the one closest to 20 when a lower CRF is inside" "$CRF_SELECTED" 8

est 8=23.8 9=17.6 10=15.9
qsel 8 23
eq "none inside: closest to 20 (CRF 9, 2.4 vs 3.8)" "$CRF_SELECTED $QUALITY_PICK" "9 closest"
eq "one CRF past the crossing, then stop" "${CRF_TRIED[*]}" "8 9 10"
eq "not above the band"                    "$CRF_OVER_CEILING" 0

est 8=22.5 9=17.5 10=16
qsel 8 23
eq "equal distance: lower CRF"             "$CRF_SELECTED" 8

est 8=22.3 9=16 10=15
qsel 8 23
eq "closest may be just above the band"    "$CRF_SELECTED $QUALITY_PICK" "8 closest"

est 8=23 9=17.5 10=19
qsel 8 23
eq "non-monotonic: CRF inside the band after the crossing" "$CRF_SELECTED $QUALITY_PICK" "10 band"

est 0=60 1=55 2=50 3=45 4=40 5=36 6=32 7=29 8=26 9=23.5 10=21
qsel 0 23
eq "search from CRF_MIN upward"            "${EST_CALLS[*]}" "0 1 2 3 4 5 6 7 8 9 10"
eq "default range: CRF 10"                 "$CRF_SELECTED" 10

est 8=40 9=35 10=30
qsel 8 10
eq "never above CRF_MAX"                   "${CRF_TRIED[*]} | $CRF_SELECTED" "8 9 10 | 10"
eq "CRF_MAX still above the band: flagged" "$CRF_OVER_CEILING" 1

est 5=17 6=15 7=14
qsel 5 23
eq "never below CRF_MIN (CRF_MIN already below the band)" "${CRF_TRIED[*]} | $CRF_SELECTED" "5 6 | 5"

est 8=23 9=fail
qsel 8 23
eq "sample failure: nothing selected"      "$? ${CRF_SELECTED:-none}" "1 none"

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
est 8=21.5 9=19 10=17
qsel 8 23 21
eq "estimate >= source never chosen (21 GiB source)" "$CRF_SELECTED $QUALITY_PICK" "9 band"
est 8=23 9=21.5 10=20.5
qsel 8 23 21
eq "band capped below the source"          "$CRF_SELECTED" 10
est 8=30 9=28 10=26
qsel 8 10 25
eq "nothing below the source: guard case"  "$CRF_SELECTED $QUALITY_PICK $CRF_OVER_CEILING" "10 none 1"
check "15.8 GiB source: source-limited"    "quality_source_limited $(gib_bytes 15.8)"
check "20 GiB source: source-limited"      "quality_source_limited $(gib_bytes 20)"
check "20.5 GiB source: not source-limited" "! quality_source_limited $(gib_bytes 20.5)"
check "unknown source: not source-limited" "! quality_source_limited N/A"
check "menu: source guard before any sample encode, keep / encode / skip" \
    "grep -q 'Quality source guard: the source video' '$M' && grep -q '1) QUALITY_KEEP_SOURCE=1 ;;' '$M' && grep -q '2) QUALITY_STATUS=\"source-limited\" ;;' '$M'"
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
check "High/Base retry spec unchanged in the menu" \
    "grep -qF '[[ \"\$TIER\" != \"Custom\" ]] && RETRY_SPEC=\"\$CRF_CEILING_BYTES:\$CRF_MAX:\$CRF_MIN:\$CRF_DOWN_RETRY_HEADROOM_PCT:\$CRF_DOWN_RETRY_MAX\"' '$M'"
check "series menu does not use the Quality tier" "! grep -q 'Quality' '$SRC_WORK/series_compress.sh'"
eq "Quality policy line"      "$(movie_policy_line Quality)" \
    "CRF 0-23 [lowest CRF with the video estimate in 18-22 GiB, else closest to 20 GiB]; audio copied"
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
else
    echo "  (ffmpeg / ffprobe not found: generated-job checks skipped)"
fi

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
