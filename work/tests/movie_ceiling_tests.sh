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
eq "movie High / Base GiB per hour"             "$MOVIE_HIGH_VIDEO_GIB_PER_HOUR $MOVIE_BASE_VIDEO_GIB_PER_HOUR" "3.5 1.0"
eq "movie High / Base CRF ranges unchanged"     "$MOVIE_HIGH_CRF_SEARCH_MIN $MOVIE_HIGH_CRF_START $MOVIE_HIGH_CRF_MAX / $MOVIE_BASE_CRF_SEARCH_MIN $MOVIE_BASE_CRF_START $MOVIE_BASE_CRF_MAX" \
                                                "10 12 23 / 18 20 29"
check "no fixed movie High / Base ceiling in the config" \
    "! grep -qE '^MOVIE_(HIGH|BASE)_VIDEO_SIZE_CEILING_GIB=' '$SRC_WORK/lib/compress.conf'"
check "movie GiB/hour keys are active (validated), not retired" \
    "[[ ' ${POLICY_KEYS_POSITIVE[*]} ' == *' MOVIE_HIGH_VIDEO_GIB_PER_HOUR '* && ' ${POLICY_KEYS_POSITIVE[*]} ' == *' MOVIE_BASE_VIDEO_GIB_PER_HOUR '* ]] && [[ ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ${POLICY_KEYS_RETIRED[*]} ${POLICY_KEYS_RETIRED_QUALITY[*]} ' != *' MOVIE_HIGH_VIDEO_GIB_PER_HOUR '* && ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ${POLICY_KEYS_RETIRED[*]} ${POLICY_KEYS_RETIRED_QUALITY[*]} ' != *' MOVIE_BASE_VIDEO_GIB_PER_HOUR '* ]]"
check "series GiB/hour keys still retired" \
    "[[ ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ' == *' SERIES_HIGH_VIDEO_GIB_PER_HOUR '* && ' ${POLICY_KEYS_RETIRED_VIDEO[*]} ' == *' SERIES_BASE_VIDEO_GIB_PER_HOUR '* ]]"

f=$(conf_with rate MOVIE_HIGH_VIDEO_GIB_PER_HOUR=4.25 MOVIE_BASE_VIDEO_GIB_PER_HOUR=0.8)
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
eq "Base  90 min -> 1.50 GiB"   "$(ceil_of Base 5400)"  "1610612736 1.50"
eq "Base 120 min -> 2.00 GiB"   "$(ceil_of Base 7200)"  "2147483648 2.00"
eq "Base 180 min -> 3.00 GiB"   "$(ceil_of Base 10800)" "3221225472 3.00"
eq "exact bytes: 7 x 1073741824" "$(movie_ceiling_bytes 3.5 7200)" "$((7 * 1073741824))"
# exact values (rational arithmetic, rounded to a whole byte at the end)
eq "fractional runtime High 7262.458 s"        "$(movie_ceiling_bytes 3.5 7262.458)" "7581393652"
eq "fractional runtime Base 5423.417 s"        "$(movie_ceiling_bytes 1.0 5423.417)" "1617597128"
eq "fractional runtime High 6543.21 s"         "$(movie_ceiling_bytes 3.5 6543.21)"  "6830559400"
eq "runtime not rounded: 7199 s < 7 GiB"        "$(movie_ceiling_bytes 3.5 7199)"     "7515148852"
eq "ffprobe-style duration (7200.000000)"       "$(ceil_of High 7200.000000)"         "7516192768 7.00"
eq "CRF_GIB_PER_HOUR set for the menu"          "$(crf_tier_load movie Base "" 7200; echo "$CRF_GIB_PER_HOUR")" "1.0"
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
    RETRY_SPEC="$CRF_CEILING_BYTES:$CRF_MAX:$CRF_MIN:$CRF_DOWN_RETRY_HEADROOM_PCT:$CRF_DOWN_RETRY_MAX::$CRF_DOWN_RETRY_FIT_MARGIN_PCT"
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
