#!/usr/bin/env bash
# Series season CRF: exactly ONE sampled episode above the ceiling while
# the other episodes are only inferred (policy.sh series_decisive_inferred,
# encode_common.sh crf_series_estimate). Before the season CRF rises,
# inferred regular episodes are sampled (largest first, one at a time)
# until the high episode is proven to be the isolated outlier (season
# stays) or a second own sample proves the season too large (it rises).
#
#   bash ~/compress/work/tests/series_inference_edge_tests.sh
#
# Deterministic stand-in sample encodes only (no ffmpeg); seconds.
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
WORK_DIR="$T/work"
mkdir -p "$WORK_DIR"
cp -r "$SRC_WORK/lib" "$WORK_DIR/"
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do
    source "$WORK_DIR/lib/$l.sh" > /dev/null
done
COMPRESS_CONF="$T/c.conf"
cp "$SRC_WORK/lib/compress.conf" "$COMPRESS_CONF"
sed -i 's/^SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=.*/SERIES_HIGH_VIDEO_SIZE_CEILING_GIB=5/; s/^SERIES_CRF_OUTLIER_PCT=.*/SERIES_CRF_OUTLIER_PCT=25/' "$COMPRESS_CONF"
export COMPRESS_CONF
load_policy > /dev/null
crf_tier_load series High

# Stand-in sample encodes: episode En is exactly EPG[n:crf] GiB at its
# runtime. Every call is recorded as "CRF EPISODE".
declare -A EPG=()
crf_sample_title() {   # FILE VIDX FILTER CRF DURATION POINTS
    local n="${1##*/E}"
    n="${n%.mkv}"
    printf '%s %s\n' "$4" "$n" >> "$T/calls"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=$(awk -v g="${EPG[$n:$4]:-0}" -v d="$5" 'BEGIN { printf "%.0f", g * 1073741824 * 100 / d }')
}
season() {   # K DUR...  ->  episodes E1.. with these runtimes, K sampled
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
extra() { awk -v c="$1" '$1 == c' "$T/calls" | awk 'NR > s' s="${#CRF_SERIES_SAMPLED[@]}" | cut -d' ' -f2 | tr '\n' ' '; }
nodup() { [[ -z "$(sort "$T/calls" | uniq -d)" ]]; }
fits() { (( CRF_EST_RESULT <= CRF_CEILING_BYTES )) && echo fits || echo over; }

# The request's example: E1 sampled 5.2 GiB (> 5), E4 sampled 3.0 (the
# longest); E2 / E3 not sampled and shorter: inferred 4.60 / 4.51 GiB
# (E1's rate x their runtime) - neither above the ceiling nor an outlier.
example() { EPG=(); season 2 2700 2390 2340 2800; EPG[1:10]=5.2; EPG[4:10]=3.0; }

echo "== one sampled episode above, the others inferred"

example
eq "setup: E1 / E4 sampled"                "${CRF_SERIES_SAMPLED[*]}" "0 3"
EPG[2:10]=2.0; EPG[3:10]=2.0
crf_series_estimate 10 > "$T/o1.out"
eq "1 inferred E2 sampled before the season may fail (1 extra sample)" "$(extra 10)" "2 "
read -ra eb <<< "${CRF_SERIES_EP_BYTES[10]}"
series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}"
eq "2 real E2 low: E1 the isolated outlier, season fits at 10" "$SB_ISOLATED/$(fits)" "0/fits"
eq "  sources: E2 sampled after inference, E3 still inferred" "${CRF_SERIES_EP_FROM[10]}" "sample promoted highest sample"
check "  shown as sampled after inference" "grep -q '^  E2  ~2.00 GiB  sampled after inference\$' '$T/o1.out'"

# the same through the season search: CRF 10 stays (nothing at 11 sampled)
example; EPG[2:10]=2.0; EPG[3:10]=2.0
crf_select_boundary 10 10 21 "$CRF_CEILING_BYTES" crf_series_estimate > /dev/null
eq "2 season search: common CRF stays 10"  "$CRF_SELECTED/${CRF_TRIED[*]}" "10/10"

# 8 the existing isolated-outlier path: E1 gets its own CRF from 10 up,
# its season sample at 10 reused
EPG[1:11]=4.6
: > "$T/calls"
series_episode_crf 0 10 21 "$CRF_CEILING_BYTES" crf_episode_estimate > /dev/null
eq "8 isolated outlier: own CRF 11, sample at 10 reused" "$EPC_CRF/$(tr '\n' ' ' < "$T/calls")" "11/11 1 "

# 3 / 6 the promoted sample is above as well: two own samples prove it,
# E3 is never sampled, the common CRF rises
example; EPG[2:10]=5.1; EPG[3:10]=2.0
EPG[1:11]=4.7; EPG[4:11]=2.7
crf_select_boundary 10 10 21 "$CRF_CEILING_BYTES" crf_series_estimate > /dev/null
eq "3 real E2 also above: season rises to 11" "$CRF_SELECTED/${CRF_TRIED[*]}" "11/10 11"
eq "6 stops after two own samples: E2 sampled at 10 only, E3 never (1 extra sample)" "$(extra 10)|$(extra 11)" "2 |"
check "  no sample encoded twice"           "nodup"

# still unresolved after one: the next largest inferred episode follows
example; EPG[2:10]=4.0; EPG[3:10]=2.0
crf_series_estimate 10 > /dev/null
eq "E2 4.0 leaves it open -> E3 sampled too (2.0): E1 isolated, fits (2 extra samples)" \
    "$(extra 10)/$(fits)" "2 3 /fits"
example; EPG[2:10]=4.0; EPG[3:10]=4.5
crf_series_estimate 10 > /dev/null
eq "every inferred episode sampled, E1 still regular: season too large (2 extra samples)" \
    "$(extra 10)/$(fits)/${CRF_SERIES_EP_FROM[10]}" "2 3 /over/sample promoted promoted sample"

# 7 the failure already proven by own samples: nothing promoted
example; EPG[4:10]=5.5; EPG[2:10]=2.0; EPG[3:10]=2.0
crf_series_estimate 10 > /dev/null
eq "7 two sampled episodes above: no inferred episode sampled (0 extra samples)" \
    "$(extra 10)/$(fits)/${CRF_SERIES_EP_FROM[10]}" "/over/sample highest highest sample"

# 4 two episodes: no isolated outlier exists below 3 episodes, so one
# sampled episode above the ceiling decides on its own; the other is not
# sampled (its sample could not change the decision)
EPG=(); season 1 2700 2400; EPG[1:10]=5.2; EPG[2:10]=1.0
eq "4 setup: 2 episodes, E1 sampled"       "${CRF_SERIES_SAMPLED[*]}" "0"
crf_series_estimate 10 > /dev/null
eq "4 two episodes, sampled E1 above: proven, E2 not sampled (0 extra samples)" \
    "$(extra 10)/$(fits)/${CRF_SERIES_EP_FROM[10]}" "/over/sample highest"

# 5 cache hit: E2's own estimate at 10 already known -> no sample encode
example; EPG[2:10]=2.0; EPG[3:10]=2.0
CRF_EP_EST[1:10]=$((2 * 1073741824))
crf_series_estimate 10 > "$T/o5.out"
eq "5 cache hit: promoted E2 not encoded again (0 extra encodes)" "$(extra 10)/$(fits)" "/fits"
check "  shown as already sampled"          "grep -q '^  E2  ~2.00 GiB  sampled after inference (already sampled)\$' '$T/o5.out'"
: > "$T/calls"
crf_episode_estimate 1 10 > /dev/null
eq "5 promoted estimate reused later (crf_episode_estimate)" "$(wc -l < "$T/calls" | tr -d ' ')" 0

echo
echo "== set -euo pipefail"
cat > "$T/setu.sh" <<EOF
set -euo pipefail
WORK_DIR='$WORK_DIR'
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do source "\$WORK_DIR/lib/\$l.sh" > /dev/null; done
COMPRESS_CONF='$COMPRESS_CONF' load_policy > /dev/null
crf_tier_load series High
declare -A EPG=([1:10]=5.2 [4:10]=3.0 [2:10]=4.0 [3:10]=2.0 [1:11]=4.7 [4:11]=2.7)
crf_sample_title() {
    local n="\${1##*/E}"; n="\${n%.mkv}"
    CRF_SAMPLE_SECS=100
    CRF_SAMPLE_BYTES=\$(awk -v g="\${EPG[\$n:\$4]:-0}" -v d="\$5" 'BEGIN { printf "%.0f", g * 1073741824 * 100 / d }')
}
FILES=(/s/E1.mkv /s/E2.mkv /s/E3.mkv /s/E4.mkv); EP_VIDX=(0 0 0 0); EP_DUR=(2700 2390 2340 2800)
CRF_SERIES_LABELS=(E1 E2 E3 E4); CRF_SERIES_SAMPLED=(0 3); CRF_SERIES_FILTER=""
declare -A CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
crf_select_boundary 10 10 21 "\$CRF_CEILING_BYTES" crf_series_estimate > /dev/null
[[ "\$CRF_SELECTED" == 10 && "\${CRF_SERIES_EP_FROM[10]}" == "sample promoted promoted sample" ]]
EPG[2:10]=5.1
CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
crf_select_boundary 10 10 21 "\$CRF_CEILING_BYTES" crf_series_estimate > /dev/null
[[ "\$CRF_SELECTED" == 11 ]]
FILES=(/s/E1.mkv /s/E2.mkv); EP_VIDX=(0 0); EP_DUR=(2700 2400); CRF_SERIES_LABELS=(E1 E2); CRF_SERIES_SAMPLED=(0)
CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()
crf_series_estimate 10 > /dev/null
echo survived
EOF
eq "9 edge case under set -euo pipefail"    "$(bash "$T/setu.sh" 2>&1 | tail -1)" "survived"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
