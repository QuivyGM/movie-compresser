#!/usr/bin/env bash
# Series "Custom size" tier (menu option 5): the user's video ceiling
# (GiB/episode) with High / Base behaviour.
#
#   1. input: ceiling (positive decimal, normalised) and CRF range
#      ("MIN-MAX" or Enter = SERIES_CUSTOMSIZE_CRF_*), config defaults and
#      validation
#   2. crf_tier_load / ceiling tier / retry spec (the ceiling travels into
#      the season batch), policy text
#   3. names and tags: "HEVC Size1.2G" round trip (output_tier,
#      output_source_stem, NAMING_TIER_RE), COMPRESSION_TIER "Custom size
#      1.2 GiB", job records, provenance preset, progress-check, results.sh,
#      validate.py, settings signature (another ceiling = other settings)
#   4. series menu with stand-ins: re-asked invalid input, CRF chosen
#      against the entered ceiling, default and entered CRF range, the job
#      (names, tier, ceiling, range, season batch); tiers 1-4 unchanged
#
#   bash ~/compress/work/tests/customsize_tier_tests.sh
#
# Seconds, no ffmpeg: every probe / encode in the menu is a stand-in.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${CUSTOMSIZE_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE SERIES_CRF_SHARED

for l in ui bitrate media_probe naming encode_common policy; do
    source "$SRC_WORK/lib/$l.sh"
done
export COMPRESS_CONF="$SRC_WORK/lib/compress.conf"
load_policy > /dev/null 2>&1 || { echo "compress.conf does not load"; exit 1; }

# ------------------------------------------------------------
echo "== 1 input"

for v in 1.2 1.20 .75 0.75 2 "  1.5 " 0.001; do
    printf -v got '%s' "$(size_gib_norm "$v")"
    case "$v" in
        1.2|1.20) want=1.2 ;; .75|0.75) want=0.75 ;; 2) want=2 ;; "  1.5 ") want=1.5 ;; 0.001) want=0.001 ;;
    esac
    eq "1 ceiling \"$v\" accepted" "$got" "$want"
done
for v in "" 0 0.0 -1 abc 1,2 1.2345 1e3 1001 "1.2 GiB" .; do
    check "1 ceiling \"$v\" refused" "! size_gib_norm '$v' > /dev/null"
done
eq    "1 token"                         "$(size_tier_token 1.20)|$(size_tier_token .75)" "Size1.2G|Size0.75G"

customsize_range_parse ""
eq    "1 CRF range Enter = config defaults" "$CUSTOMSIZE_CRF_MIN-$CUSTOMSIZE_CRF_MAX start $CUSTOMSIZE_CRF_START" \
      "$SERIES_CUSTOMSIZE_CRF_SEARCH_MIN-$SERIES_CUSTOMSIZE_CRF_MAX start $SERIES_CUSTOMSIZE_CRF_START"
eq    "1 shipped defaults 18 / 11 / 30" "$SERIES_CUSTOMSIZE_CRF_START/$SERIES_CUSTOMSIZE_CRF_SEARCH_MIN/$SERIES_CUSTOMSIZE_CRF_MAX" "18/11/30"
customsize_range_parse "14-26"
eq    "1 CRF range entered"             "$CUSTOMSIZE_CRF_MIN-$CUSTOMSIZE_CRF_MAX start $CUSTOMSIZE_CRF_START" "14-26 start 18"
customsize_range_parse " 20 - 28 "
eq    "1 start moved into a range above it" "$CUSTOMSIZE_CRF_MIN-$CUSTOMSIZE_CRF_MAX start $CUSTOMSIZE_CRF_START" "20-28 start 20"
customsize_range_parse "8-12"
eq    "1 start moved into a range below it" "$CUSTOMSIZE_CRF_START" "12"
customsize_range_parse "21-21"
eq    "1 one-CRF range"                 "$CUSTOMSIZE_CRF_MIN-$CUSTOMSIZE_CRF_MAX start $CUSTOMSIZE_CRF_START" "21-21 start 21"
for v in "26-14" "14" "14-" "-26" "a-b" "14-52" "14.5-20" "14,26"; do
    check "1 CRF range \"$v\" refused with a reason" "! customsize_range_parse '$v' && [[ -n \"\$CUSTOMSIZE_RANGE_ERR\" ]]"
done
unset CUSTOMSIZE_CRF_MIN CUSTOMSIZE_CRF_MAX CUSTOMSIZE_CRF_START

# config: optional keys get defaults, set keys are validated like the others
conf_with() {   # NAME LINE...  ->  a copy of compress.conf with lines appended / keys removed
    local f="$T/$1.conf" l
    shift
    grep -v '^SERIES_CUSTOMSIZE_' "$SRC_WORK/lib/compress.conf" > "$f"
    for l; do printf '%s\n' "$l" >> "$f"; done
    printf '%s' "$f"
}
check "1 config without the keys: defaults"  "( unset SERIES_CUSTOMSIZE_CRF_START SERIES_CUSTOMSIZE_CRF_SEARCH_MIN SERIES_CUSTOMSIZE_CRF_MAX; COMPRESS_CONF='$(conf_with none)' load_policy >/dev/null 2>&1 && [[ \$SERIES_CUSTOMSIZE_CRF_START/\$SERIES_CUSTOMSIZE_CRF_SEARCH_MIN/\$SERIES_CUSTOMSIZE_CRF_MAX == 18/11/30 ]] )"
check "1 config: START below SEARCH_MIN refused" "! ( COMPRESS_CONF='$(conf_with lo SERIES_CUSTOMSIZE_CRF_SEARCH_MIN=20 SERIES_CUSTOMSIZE_CRF_START=18 SERIES_CUSTOMSIZE_CRF_MAX=30)' load_policy > '$T/lo.err' 2>&1 ) && grep -q 'SERIES_CUSTOMSIZE_CRF_START (18) is lower than SERIES_CUSTOMSIZE_CRF_SEARCH_MIN (20)' '$T/lo.err'"
check "1 config: not a whole CRF refused"  "! ( COMPRESS_CONF='$(conf_with nw SERIES_CUSTOMSIZE_CRF_MAX=30.5)' load_policy > '$T/nw.err' 2>&1 ) && grep -q 'SERIES_CUSTOMSIZE_CRF_MAX=\"30.5\": must be a whole number' '$T/nw.err'"
check "1 config: above 51 refused"         "! ( COMPRESS_CONF='$(conf_with big SERIES_CUSTOMSIZE_CRF_MAX=60)' load_policy > /dev/null 2>&1 )"
load_policy > /dev/null 2>&1

# ------------------------------------------------------------
echo
echo "== 2 tier loading, retry spec, policy text"

crf_tier_load series Size1.2G
eq    "2 default range, ceiling from the tier" "$CRF_MIN $CRF_START $CRF_MAX $CRF_CEILING_GIB $CRF_CEILING_BYTES" "11 18 30 1.2 1288490189"
CUSTOMSIZE_CRF_MIN=14 CUSTOMSIZE_CRF_MAX=26 CUSTOMSIZE_CRF_START=18
crf_tier_load series Size0.75G
eq    "2 entered range"                 "$CRF_MIN $CRF_START $CRF_MAX $CRF_CEILING_BYTES" "14 18 26 $(_gib_bytes 0.75)"
eq    "2 fixed ceiling (not per hour)"  "${CRF_GIB_PER_HOUR:-none}" "none"
unset CUSTOMSIZE_CRF_MIN CUSTOMSIZE_CRF_MAX CUSTOMSIZE_CRF_START
check "2 a ceiling tier (boundary search)" "crf_ceiling_tier Size1.2G && ! series_rate_tier Size1.2G"
check "2 not a movie tier"              "! crf_tier_load movie Size1.2G 2>/dev/null"
eq    "2 retry spec carries the ceiling" "$(series_season_retry_spec Size1.2G 1288490189 30 11)" "1288490189:30:11:::season"
crf_tier_load series Size1.2G
eq    "2 crf_select_boundary against the ceiling" "$(
        probe() { CRF_EST_RESULT=$(awk -v c="$1" 'BEGIN { printf "%.0f", 1620000000 * 0.88 ^ (c - 20) }'); return 0; }
        crf_select_boundary "$CRF_START" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" probe > /dev/null 2>&1; echo "$CRF_SELECTED")" "22"
crf_policy_lines series Size1.2G > "$T/pol.txt"
check "2 full policy (COMPRESS_VERBOSE)" "grep -qx 'Custom size video policy:' '$T/pol.txt' && grep -q 'CRF range: 11-30, search starts at 18' '$T/pol.txt' && grep -q 'video ceiling: 1.2 GiB/episode (entered in the menu)' '$T/pol.txt' && grep -q 'one shared season CRF' '$T/pol.txt'"
eq    "2 tiers 1-4: CRF ranges unchanged, High / Base / Compact per hour of runtime" \
      "$(for t in Base High Compact; do crf_tier_load series $t; printf '%s ' "$CRF_MIN/$CRF_START/$CRF_MAX/$CRF_GIB_PER_HOUR"; done; crf_tier_load series Custom 21; printf '%s' "$CRF_MIN/$CRF_START/$CRF_MAX/$CRF_CEILING_BYTES")" \
      "$SERIES_BASE_CRF_SEARCH_MIN/$SERIES_BASE_CRF_START/$SERIES_BASE_CRF_MAX/$SERIES_BASE_VIDEO_GIB_PER_HOUR $SERIES_HIGH_CRF_SEARCH_MIN/$SERIES_HIGH_CRF_START/$SERIES_HIGH_CRF_MAX/$SERIES_HIGH_VIDEO_GIB_PER_HOUR $SERIES_COMPACT_CRF_SEARCH_MIN/$SERIES_COMPACT_CRF_START/$SERIES_COMPACT_CRF_MAX/$SERIES_COMPACT_VIDEO_GIB_PER_HOUR 21/21/21/0"

# ------------------------------------------------------------
echo
echo "== 3 names, tags, records"

for case in "Columbo S01E01 HEVC Size1.2G.mkv|Columbo S01E01|Custom size 1.2 GiB" \
            "Columbo S01E01 HEVC Size0.75G.mkv|Columbo S01E01|Custom size 0.75 GiB" \
            "Columbo S01E01 1080p HEVC Size0.75G (2).mkv|Columbo S01E01|Custom size 0.75 GiB (1080p)" \
            "Columbo S01E01 HEVC Size1.2G AudioCompressed.mkv|Columbo S01E01|Custom size 1.2 GiB + AudioCompressed" \
            "Columbo S01E01 HEVC High.mkv|Columbo S01E01|High" \
            "Columbo S01E01 HEVC Compact (3).mkv|Columbo S01E01|Compact" \
            "Columbo S01E01 HEVC Size.mkv|Columbo S01E01 HEVC Size|Unknown"; do
    IFS='|' read -r n stem tier <<< "$case"
    eq "3 \"$n\": source stem / tier" "$(output_source_stem "$n")|$(output_tier "$n")" "$stem|$tier"
done
eq    "3 series name round trip"        "$(output_tier "$(basename "$(series_episode_output /o/Show "/i/Show/Show S01E02.mkv" "$(size_tier_token 1.20)" 0)")")" "Custom size 1.2 GiB"
eq    "3 display"                       "$(tier_display Size1.2G)|$(tier_display High)" "Custom size 1.2 GiB/episode|High"
eq    "3 COMPRESSION_TIER"              "$(compression_tier_name Size1.2G)|$(compression_tier_name Size0.75G)|$(compression_tier_name 'Custom size 1.2 GiB')|$(compression_tier_name High)|$(compression_tier_name Normal)" \
      "Custom size 1.2 GiB|Custom size 0.75 GiB|Custom size 1.2 GiB|High|"
# job records: a crf_estimates.tsv row of the job (tier as it ran) and a
# compression_tags.tsv row (tag name) both give the tag name
L="$T/logs"; mkdir -p "$L"
compression_ledger_add "$L" "/o/Show/E01 HEVC Size1.2G.mkv" 22 "$(compression_tier_name Size1.2G)" 1000 series1 /i/Show/E01.mkv
eq    "3 job record lookup (ledger)"    "$(compression_record_lookup "$L" "/x/E01 HEVC Size1.2G.mkv" 1000)" $'22\tCustom size 1.2 GiB\tcompression_tags.tsv'
# (job_runtime.sh CRF_LOG_HEADER: date tier crf resolution duration_s
# estimated actual error session input ceiling result reason)
{ printf 'date\ttier\tcrf\tresolution\tduration_s\testimated_video_bytes\tactual_video_bytes\terror_pct\tsession\tinput\tceiling_video_bytes\tresult\treason\n'
  printf '2026-11-22 10:00:00\tSize0.75G\t25\t1920x1080\t2700\t1900\t2000\t5\tseries2\t/i/E02.mkv\t3000\tACCEPTED\t-\n'; } > "$L/crf_estimates.tsv"
eq    "3 job record lookup (CRF log, tier as the job ran)" "$(compression_record_lookup "$L" "/x/E02 HEVC Size0.75G.mkv" 2000)" $'25\tCustom size 0.75 GiB\tcrf_estimates.tsv'
eq    "3 provenance preset"             "$(ITEM_TIER=Size1.2G; source "$SRC_WORK/lib/provenance.sh"; _prov_preset)" "Custom size 1.2 GiB"
eq    "3 progress-check tier"           "$(eval "$(sed -n '/^meta_text() {$/,/^}$/p' "$ROOT/progress-check.sh")"; meta_text Size1.2G 22 "" encoding)" "Custom size 1.2 GiB/episode | CRF 22 | encoding"
check "3 results.sh: a CRF tier (missing tags would be an issue)" "[[ 'Custom size 1.2 GiB' =~ \$COMPRESSION_TIER_RE ]] && grep -q 'CRF_TIERS_RE=\"\$COMPRESSION_TIER_RE\"' '$ROOT/results.sh'"
if command -v python3 > /dev/null; then
    eq "3 validate.py accepts the tag" "$(cd "$SRC_WORK/lib/mkv-property-handler" && python3 -I -c '
import re, sys
sys.path.insert(0, ".")
src = open("validate.py").read()
print("ok" if "Custom size" in src and re.fullmatch(r"Custom size \d+(\.\d+)? GiB", "Custom size 1.2 GiB") else "no")')" ok
fi
s12=$(output_plan_sig crf:22 "" none none Size1.2G)
s075=$(output_plan_sig crf:22 "" none none Size0.75G)
eq    "3 signature carries the ceiling" "$s12" "crf=22 tune=- dv=0 hdr10p=0 size=1.2"
check "3 another ceiling = other settings" "[[ '$s12' != '$s075' ]]"
eq    "3 other tiers' signature unchanged" "$(output_plan_sig crf:22 "" none none High)" "crf=22 tune=- dv=0 hdr10p=0"
eq    "3 signature text"                "$(output_sig_text "$s12")" "CRF 22, Custom size 1.2 GiB"

# ------------------------------------------------------------
echo
echo "== 4 series menu (stand-ins)"

STUB="$T/stub"
mkdir -p "$STUB"
# a source "file" is text: dur, vrate20 = sample bytes/s at CRF 20
cat > "$STUB/ffprobe" <<'EOF'
#!/usr/bin/env bash
f=""; for a; do f="$a"; done
[[ -f "$f" ]] && grep -q '^dur=' "$f" 2>/dev/null || exit 1
dur=$(sed -n 's/^dur=//p' "$f")
case "$*" in
    *format=format_name*)
        echo "format|format_name=mov,mp4,m4a|duration=$dur"
        echo "stream|index=0|codec_type=video|codec_name=h264|bit_rate=40000000|duration=$dur|disposition:attached_pic=0"
        echo "stream|index=1|codec_type=audio|codec_name=ac3|bit_rate=640000|duration=$dur|disposition:attached_pic=0" ;;
    *format=duration*) echo "$dur" ;;
    *stream=index,codec_type,codec_name,channels*)
        echo "index=0|codec_type=video|codec_name=h264|width=1920|height=1080|pix_fmt=yuv420p|r_frame_rate=24000/1001|color_primaries=bt709|color_transfer=bt709|color_space=bt709|disposition:attached_pic=0"
        echo "index=1|codec_type=audio|codec_name=ac3|channels=6|channel_layout=-|sample_rate=48000|disposition:attached_pic=0" ;;
    *stream=width,height*) echo "1920x1080" ;;
    *-show_streams*) printf '[STREAM]\ncodec_name=h264\ncolor_primaries=bt709\ncolor_transfer=bt709\n[/STREAM]\n' ;;
esac
exit 0
EOF
cat > "$STUB/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# CRF sample encodes: vrate20 x 0.88^(CRF - 20) x length bytes
in="" len="" crf="" out="" prev=""
for a; do
    case "$prev" in -i) in="$a" ;; -t) len="$a" ;; -crf:v:0) crf="$a" ;; esac
    prev="$a"; out="$a"
done
[[ -n "$in" && -n "$crf" && -f "$in" ]] || exit 0
r=$(sed -n 's/^vrate20=//p' "$in" | head -n 1)
truncate -s "$(awk -v r="$r" -v c="$crf" -v l="$len" 'BEGIN { printf "%.0f", r * (0.88 ^ (c - 20)) * l }')" "$out"
EOF
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in has-session) exit 1 ;; esac
exit 0
EOF
chmod +x "$STUB/ffprobe" "$STUB/ffmpeg" "$STUB/tmux"

H="$T/home"
CB="$H/compress"
mkdir -p "$CB/in/Flat" "$CB/out" "$CB/work"
cp -r "$SRC_WORK/lib" "$CB/work/"
cp "$SRC_WORK/series_compress.sh" "$CB/work/"
# 45 min episodes, 1.51 GiB video at CRF 20 (x 0.88 per CRF)
for e in 1 2 3; do printf '%s\n' dur=2700 vrate20=600000 > "$CB/in/Flat/Flat S01E0$e.mkv"; done
GIB=1073741824
# expected CRF: the lowest of MIN..MAX whose estimate fits CEILING
want_crf() { awk -v g="$1" -v lo="$2" -v hi="$3" -v G=$GIB 'BEGIN {
    for (c = lo; c <= hi; c++) if (600000 * 2700 * 0.88 ^ (c - 20) <= g * G) { print c; exit } print "none" }'; }

menu() {   # INPUT LOG
    rm -f "$CB"/work/series[0-9]*.sh
    printf "$1" | env HOME="$H" PATH="$STUB:$PATH" timeout 120 bash "$CB/work/series_compress.sh" > "$2" 2>&1
    JOB=$(ls -t "$CB"/work/series[0-9]*.sh 2>/dev/null | head -n 1)
}

menu "1\n4\nabc\n0\n-1\n1,2\n1.20\n30-11\nx\n\ny\n" "$T/m1.log"
check "4 menu option 4; High / Base per hour of runtime" \
    "grep -qx '1) High         CRF 8-21    <=2.5 GiB/h video' '$T/m1.log' && grep -qx '2) Base         CRF 11-27   <=1.0 GiB/h video' '$T/m1.log' && grep -qE '^3\\) Compact +CRF ' '$T/m1.log' && grep -qx '4) Custom size  CRF 11-30   <=your GiB/episode video' '$T/m1.log' && grep -qx '5) Custom CRF   exact CRF 0-51, no size limit' '$T/m1.log'"
eq    "4 invalid ceilings re-asked"     "$(grep -c '^Enter a positive number of GiB per episode' "$T/m1.log")" 4
eq    "4 invalid CRF ranges re-asked"   "$(grep -c '^Invalid CRF range: ' "$T/m1.log")" 2
check "4 tier line (default range)"     "grep -qx 'Custom size 1.2 GiB/episode: CRF 11-30, search starts at 18' '$T/m1.log'"
C1=$(want_crf 1.2 11 30)
check "4 CRF chosen against the entered ceiling (CRF $C1)" "grep -qx 'Selected: CRF $C1' '$T/m1.log'"
check "4 confirmation line"             "grep -q '^Custom size 1.2 GiB/episode | CRF $C1 | 1920x1080 | SDR | audio copied' '$T/m1.log'"
check "4 job written"                   "[[ -n '$JOB' && -f '$JOB' ]]"
eq    "4 every output named HEVC Size1.2G" "$(grep -c 'out/Flat/Flat\\ S01E0[123]\\ HEVC\\ Size1.2G.mkv Size1.2G ' "$JOB")" 3
eq    "4 season batch: ceiling, CRF range, season mode" \
      "$(grep -c "mode=crf crf=$C1 .*ceiling_vbytes=$(_gib_bytes 1.2) crf_min=11 crf_max=30 .*batch_mode=season" "$JOB")" 3
check "4 one season batch run"          "grep -qx 'job_crf_batch' '$JOB'"

menu "1\n4\n0.75\n14-26\ny\n" "$T/m2.log"
C2=$(want_crf 0.75 14 26)
check "4 entered CRF range shown"       "grep -qx 'Custom size 0.75 GiB/episode: CRF 14-26, search starts at 18' '$T/m2.log'"
check "4 CRF chosen against 0.75 GiB (CRF $C2)" "grep -qx 'Selected: CRF $C2' '$T/m2.log'"
eq    "4 job: HEVC Size0.75G, ceiling 0.75 GiB, range 14-26" \
      "$(grep -c "HEVC\\\\ Size0.75G.mkv Size0.75G .*" "$JOB")/$(grep -c "crf=$C2 .*ceiling_vbytes=$(_gib_bytes 0.75) crf_min=14 crf_max=26 .*batch_mode=season" "$JOB")" "3/3"

# a range whose CRF_MAX cannot reach the ceiling: Custom size still asks
# (High / Base do not: over target, section 5)
menu "1\n4\n0.75\n14-18\n2\n" "$T/m3.log"
check "4 ceiling not reachable within the range: asked at CRF_MAX" \
    "grep -q 'within the allowed Custom size 0.75 GiB/episode quality range: even CRF 18' '$T/m3.log' && grep -qx '1) Encode every episode at CRF 18 anyway' '$T/m3.log' && grep -qx 'Compression cancelled.' '$T/m3.log' && [[ -z '$JOB' ]] && ! grep -qi 'over target' '$T/m3.log'"

COMPRESS_VERBOSE=1 menu "1\n4\n1.2\n\nn\n" "$T/m4.log"
check "4 COMPRESS_VERBOSE: full policy"  "grep -qx 'Custom size video policy:' '$T/m4.log' && grep -q 'video ceiling: 1.2 GiB/episode (entered in the menu)' '$T/m4.log' && grep -qE '^4\\) Custom size +the video ceiling you enter' '$T/m4.log' && grep -qE '^5\\) Custom CRF +exactly the CRF you enter' '$T/m4.log'"

menu "1\n1\ny\n" "$T/m5.log"
check "4 tier 2 (High): HEVC High, 45 min x 2.5 GiB/h ceiling" \
    "grep -q 'HEVC\\\\ High.mkv High ' '$JOB' && grep -q 'ceiling_vbytes=$(movie_ceiling_bytes 2.5 2700) crf_min=$SERIES_HIGH_CRF_SEARCH_MIN crf_max=$SERIES_HIGH_CRF_MAX' '$JOB' && ! grep -q Size '$JOB'"
check "4 no errors"                      "! cat '$T'/m[1-5].log | grep -qiE 'unbound variable|command not found|syntax error'"

# ------------------------------------------------------------
echo
echo "== 5 series High / Base: per-episode ceilings from the runtime (stand-ins)"

# Mixed: 22 / 45 / 95 min. The ceiling is runtime x 2.5 GiB/h, so an
# episode fits when its bytes per second do: the dense 22 min E01 (the
# smallest file) decides, not the 95 min E03 (the largest):
#   E01 700000 B/s at CRF 20 -> fits from CRF 20 (ceiling 745654 B/s)
#   E02 600000                -> from 19;  E03 500000 -> from 17
printf '%s\n' dur=1320 vrate20=700000 > "$CB/in/Mixed/Mixed S01E01.mkv" 2>/dev/null ||
    { mkdir -p "$CB/in/Mixed"; printf '%s\n' dur=1320 vrate20=700000 > "$CB/in/Mixed/Mixed S01E01.mkv"; }
printf '%s\n' dur=2700 vrate20=600000 > "$CB/in/Mixed/Mixed S01E02.mkv"
printf '%s\n' dur=5700 vrate20=500000 > "$CB/in/Mixed/Mixed S01E03.mkv"
# Over: Base 1.0 GiB/h; the dense 22 min E01 cannot fit even at CRF 27
mkdir -p "$CB/in/Over"
printf '%s\n' dur=1320 vrate20=3000000 > "$CB/in/Over/Over S01E01.mkv"
printf '%s\n' dur=2700 vrate20=500000 > "$CB/in/Over/Over S01E02.mkv"

menu "2\n1\ny\n" "$T/m6.log"
check "5 series list: Flat, Mixed, Over"   "grep -qE '^2\\) Mixed' '$T/m6.log' && grep -qE '^3\\) Over' '$T/m6.log'"
check "5 mixed lengths: the 22 min episode decides (CRF 20)" \
    "grep -qx 'Selected: CRF 20' '$T/m6.log' && grep -qE '^Decisive: [0-9.]+ GiB / 0\\.92 GiB \\(S01E01, sampled\\)' '$T/m6.log'"
check "5 job: every episode at CRF 20, each its own ceiling" \
    "[[ \$(grep -c 'mode=crf crf=20 .*batch_mode=season' '$JOB') == 3 ]] && grep -q 'ceiling_vbytes=984263339 crf_min=8 crf_max=21' '$JOB' && grep -q 'ceiling_vbytes=2013265920 crf_min=8 crf_max=21' '$JOB' && grep -q 'ceiling_vbytes=4250228053 crf_min=8 crf_max=21' '$JOB'"
check "5 not over target"                  "! grep -qi 'over target' '$T/m6.log'"

COMPRESS_VERBOSE=1 menu "2\n1\nn\n" "$T/m7.log"
check "5 verbose: menu + policy per hour of runtime" \
    "grep -q '^1) High         CRF 8-21, video ceiling 2.5 GiB/hour of each episode.s runtime' '$T/m7.log' && grep -q 'video ceiling: 2.5 GiB per hour of runtime (each episode: its exact runtime x 2.5 GiB' '$T/m7.log'"
check "5 verbose: expected sizes show each episode's ceiling" \
    "grep -qE '^  Episode +Runtime +CRF +Video +Ceiling ' '$T/m7.log' && grep -qE '^  Mixed S01E01.mkv +22:00 +20 +[0-9.]+ +0\\.92 ' '$T/m7.log' && grep -qE '^  Mixed S01E03.mkv +95:00 +20 +[0-9.]+ +3\\.96 ' '$T/m7.log'"

menu "3\n2\ny\n" "$T/m8.log"
sed -n '/^Expected sizes/,/^Start/p' "$T/m8.log" | sed 's/^/  | /'
check "5 Base unreachable: no prompt, CRF_MAX 27" \
    "! grep -q 'Encode every episode at CRF' '$T/m8.log' && ! grep -q 'WARNING' '$T/m8.log' && ! grep -q 'Compression cancelled' '$T/m8.log' && grep -qx 'Selected: CRF 27 (ceilings not reachable within CRF 11-27: over target)' '$T/m8.log'"
check "5 marked over target in the expected sizes" \
    "grep -qE '^S01E01 .*OVER TARGET' '$T/m8.log' && ! grep -qE '^S01E02 .*OVER TARGET' '$T/m8.log' && grep -q '^Over target: the Base ceilings (1.0 GiB/h of each episode.s runtime)' '$T/m8.log'"
check "5 the episode with estimate vs ceiling, again before the confirmation" \
    "[[ \$(grep -cE '^  S01E01 +~[0-9.]+ GiB video / 0\\.37 GiB ceiling \\(\\+[0-9.]+, sampled\\)\$' '$T/m8.log') == 2 ]] && grep -B3 '^Base | CRF 27 | 1920x1080 | SDR | audio copied | over target\$' '$T/m8.log' | grep -qE '^Over target \\(Base ceilings cannot be met within CRF 11-27; encoded at CRF 27\\):|^  S01E01 +~'"
check "5 job: every episode at CRF 27, each its own ceiling" \
    "[[ \$(grep -c 'mode=crf crf=27 .*batch_mode=season' '$JOB') == 2 ]] && grep -q 'ceiling_vbytes=393705335 crf_min=11 crf_max=27' '$JOB' && grep -q 'ceiling_vbytes=805306368 crf_min=11 crf_max=27' '$JOB'"
check "5 no errors"                        "! cat '$T'/m[6-8].log | grep -qiE 'unbound variable|command not found|syntax error'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
