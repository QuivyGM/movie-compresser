#!/usr/bin/env bash
# Dolby Vision output choice, detection report, job generation and the
# post-encode Dolby Vision checks.
#
#   bash ~/compress/work/tests/dv_output_tests.sh
#
# Sections 1-4 need no media tools (dovi_tool / ffmpeg / ffprobe are
# stand-ins); section 5 uses the real ffmpeg / ffprobe to generate jobs
# from a tiny HEVC clip (skipped when they are missing). Covers:
#   1. dv_output_menu / confirm_dynamic_range: detection lines, default
#      preserve (Enter / EOF, also under set -euo pipefail), explicit
#      HDR10 only, labels per output profile (8.1 + HDR10, 8.4 + HLG),
#      MEL / FEL / unknown explanations, never "FEL preserved";
#      unsupported sources explained before any choice
#   2. dv_verify_rpu: verified, and every way it must fail (no record,
#      wrong profile / compat, EL / no BL claimed, RPU count, frame count,
#      content differs from the injected RPU, output does not decode,
#      dovi_tool missing)
#   3. item_dv_inject / item_dv_wrap: failed injection, frame-count
#      mismatch, L5 rescale, mkvmerge missing / no configuration record
#   4. failed items keep the small DV files (RPUs, summaries, logs) and
#      drop only the large video intermediates
#   5. emit_encode_item: preserve -> RPU workflow; HDR10 only (drop) and
#      non-DV sources -> the normal single encode, no DV steps
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${DV_OUTPUT_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE NO_COLOR HDR_TOOLS_DETECTED
REAL_PATH="$PATH"
REAL_FFMPEG=$(command -v ffmpeg || true)
REAL_FFPROBE=$(command -v ffprobe || true)

# ---- stand-ins
# An "RPU file" holds "PROFILE FRAMES TAG"; dovi_tool info prints it as a
# summary. FAKE_OUT_RPU: what extract-rpu finds in the output, FAKE_INJECT
# = fail / mismatch, FAKE_PACKETS: the output's video frame count,
# FAKE_DECODE: exit code of a decode (-f null), FAKE_RES: get_resolution.
mkdir -p "$T/bin"
cat > "$T/bin/dovi_tool" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
case "$1" in
    --version) echo "dovi_tool 2.3.4" ;;
    export)
        [[ "$2" == --help ]] && { echo "level5"; exit 0; }
        printf '{"active_area":{"presets":[{"id":0,"left":0,"right":0,"top":280,"bottom":280}]}}\n' > "${5#level5=}"
        ;;
    extract-rpu) cat > /dev/null; [[ -n "${FAKE_OUT_RPU:-}" ]] || exit 1; printf '%s\n' "$FAKE_OUT_RPU" > "$4" ;;
    info)
        read -r p f tag < "$4"
        printf 'Parsing RPU file...\nSummary:\n  Frames: %s\n  Profile: %s\n  Tag: %s\n' "$f" "$p" "$tag"
        ;;
    editor) cp "$5" "$7" ;;
    inject-rpu)
        [[ "${FAKE_INJECT:-}" == fail ]] && { echo "Error: invalid HEVC"; exit 1; }
        [[ "${FAKE_INJECT:-}" == mismatch ]] && echo "Warning: mismatched lengths. video 4, RPU 5"
        cp "$3" "$7"
        ;;
esac
EOF
cat > "$T/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" -f null "* ]] && exit "${FAKE_DECODE:-0}"
exit 0
EOF
cat > "$T/bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" -count_packets "* ]]; then [[ "$FAKE_PACKETS" == none ]] || echo "$FAKE_PACKETS"; exit 0; fi
if [[ " $* " == *"stream=width,height"* ]]; then echo "${FAKE_RES:-1920x1080}"; exit 0; fi
if [[ " $* " == *"-show_streams"* ]]; then [[ "${FAKE_RECORD:-1}" == 1 ]] && echo "dv_profile=8"; exit 0; fi
exit 0
EOF
cat > "$T/bin/mkvmerge" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --version ]] && { echo "mkvmerge v88.0 ('Fake') 64-bit"; exit 0; }
echo "$*" >> "$FAKE_CALLS"; : > "$2"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_CALLS="$T/calls"
export FAKE_OUT_RPU="" FAKE_INJECT="" FAKE_PACKETS=5 FAKE_DECODE=0 FAKE_RES=1920x1080 FAKE_RECORD=1
WORK_DIR="$T/work"

for l in ui media_probe media_stats bitrate encode_common hdr_dovi; do
    source "$SRC_WORK/lib/$l.sh" > /dev/null
done

# hdr_fake PROFILE COMPAT KIND  ->  probe + tool globals of a synthetic source
hdr_fake() {
    HDR_TOOLS_DETECTED=1 X265_HDR10PLUS=1 FFMPEG_DOVI_BSF=0 FFMPEG_X265_DV=0
    DOVI_TOOL="$T/bin/dovi_tool" DOVI_TOOL_VERSION=2.3.4 DOVI_TOOL_OK=1
    HDR10PLUS_TOOL="" MKVMERGE="$T/bin/mkvmerge" MKVMERGE_VERSION=v88.0
    HDR_CODEC=hevc HDR_KIND="${3:-HDR10}" HDR_HDR10PLUS=0 HDR_DV=1
    HDR_DV_PROFILE="$1" HDR_DV_COMPAT="$2" HDR_DV_BL=1 HDR_DV_RPU=1 HDR_DV_LEVEL=6
    HDR_DV_EL=$( [[ "$1" == 7 ]] && echo 1 || echo 0)
    HDR_MASTER="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)" HDR_CLL="1000,400"
    HDR_PRIMARIES=bt2020 HDR_TRANSFER=smpte2084 HDR_MATRIX=bt2020nc
    [[ "$HDR_KIND" == HLG ]] && HDR_TRANSFER=arib-std-b67 HDR_MASTER="" HDR_CLL=""
    : > "$FAKE_CALLS"
}
# the EL probe reads the source: its result is set directly here
dv_el_probe() { echo "${FAKE_EL:-unknown}"; }

# crd INPUT [LABEL]  ->  confirm_dynamic_range with INPUT on stdin;
# output in $T/c.out, R="rc:DV_POLICY:DV_MODE:DV_EL_TYPE"
# (in this shell: R = the result, the policy globals stay set)
crd() {
    printf '%b' "$1" > "$T/in.txt"
    confirm_dynamic_range "${2:-Film}" "$T/src.mkv" 0 < "$T/in.txt" > "$T/c.out" 2>&1
    R="$?:$DV_POLICY:$DV_MODE:$DV_EL_TYPE"
}
echo src > "$T/src.mkv"

# ------------------------------------------------------------
echo "== 1. output choice"

hdr_fake 8 1
crd ''; eq    "P8.1 EOF: preserve (default)"     "$R" "0:preserve::"
check "  detection: profile, compat, layers" "grep -q '^DV detected:    profile 8, compatibility id 1 (HDR10 base layer), BL+RPU, level 6\$' '$T/c.out' && grep -q 'single layer (no enhancement layer)' '$T/c.out'"
check "  options as specified"           "grep -qx '1) Preserve Dolby Vision (Profile 8.1 + HDR10)  \[default\]' '$T/c.out' && grep -qx '2) HDR10 only' '$T/c.out'"
check "  compatibility explained"        "grep -q 'players without Dolby Vision show the HDR10 base layer' '$T/c.out' && grep -q 'not a disc format' '$T/c.out'"
check "  HDR10 metadata named in option 2" "grep -q 'kept: HDR10 signalling, mastering display, MaxCLL/MaxFALL' '$T/c.out'"
hdr_fake 8 1
crd '\n'; eq    "P8.1 Enter: preserve"             "$R" "0:preserve::"
hdr_fake 8 1
crd '1\n'; eq    "P8.1 1: preserve"                 "$R" "0:preserve::"
hdr_fake 8 1
crd '2\n'; eq    "P8.1 2: HDR10 only"               "$R" "0:drop::"
check "  drop stated, never PRESERVED"   "grep -q 'Dolby Vision:   DROPPED by choice: HDR10 only' '$T/c.out' && ! grep -q 'PRESERVED' '$T/c.out'"
eq    "  queue summary says DROPPED"     "$(hdr_policy_summary)" "Dolby Vision DROPPED (base layer only, by choice)"
hdr_fake 8 1
crd 'x\n2\n'; eq    "invalid, then 2"                  "$R" "0:drop::"
check "  invalid rejected"               "grep -q 'Invalid selection.' '$T/c.out'"

hdr_fake 8 4 HLG
crd ''
check "P8.4: labels follow output + base" "grep -qx '1) Preserve Dolby Vision (Profile 8.4 + HLG)  \[default\]' '$T/c.out' && grep -qx '2) HLG only' '$T/c.out' && grep -q '(HLG base layer)' '$T/c.out'"

hdr_fake 7 6; FAKE_EL=MEL
crd ''; eq    "P7 MEL default: preserve, MEL"    "$R" "0:preserve:2:MEL"
check "  EL type in the detection"       "grep -q 'enhancement layer: MEL' '$T/c.out' && grep -q 'compatibility id 6 (HDR10 base layer, Blu-ray dual layer), BL+EL+RPU' '$T/c.out'"
check "  MEL: nothing visible lost"      "grep -q 'MEL: carries no picture data beyond the base layer' '$T/c.out'"
hdr_fake 7 6; FAKE_EL=FEL
crd ''; eq    "P7 FEL default: preserve (RPU)"   "$R" "0:preserve:2:FEL"
check "  FEL loss explained before the choice" \
    "awk '/FEL: LOSSY CONVERSION/ { l = NR } /^Select|^Dolby Vision: / { if (!s) s = NR } END { exit !(l && (!s || l < s)) }' '$T/c.out' && grep -q 'is NOT in the output and cannot be restored' '$T/c.out'"
check "  never claims the FEL preserved" "! grep -qiE 'FEL[^.]*PRESERVED|PRESERVED[^;]*FEL' '$T/c.out' && grep -q 'RPU PRESERVED as profile 8.1; FEL DISCARDED' '$T/c.out'"
eq    "  short policy"                   "$(hdr_policy_short)" "DV RPU preserved, DV FEL DISCARDED"
hdr_fake 7 6; FAKE_EL=FEL
crd '2\n'; eq    "P7 FEL 2: HDR10 only, no EL type" "$R" "0:drop::"
dv_el_policy Quality Film < /dev/null > /dev/null
eq    "  no EL decision needed after a drop" "$?:$DV_EL_DISCARD" "0:"
hdr_fake 7 6; FAKE_EL=unknown
crd ''
check "P7 unknown: may be a FEL"         "grep -q 'type unknown' '$T/c.out' && grep -q 'it may be a FEL' '$T/c.out'"

# unsupported: the reason comes first, then an explicit choice (no default)
hdr_fake 7 6; DOVI_TOOL="" DOVI_TOOL_OK=0
crd '\n\n2\n'; eq    "no dovi_tool: Enter is no choice" "$R" "1:none:2:"
check "  reason before the choice"       "grep -q 'dovi_tool not found (needed to extract' '$T/c.out' && grep -q '^1) Encode the HDR10 base layer only (Dolby Vision dropped)' '$T/c.out' && ! grep -q 'Preserve Dolby Vision' '$T/c.out'"
check "  EL not classified, said so"     "grep -q 'enhancement layer: not classified' '$T/c.out'"
hdr_fake 8 1; DOVI_TOOL_OK=0
crd '2\n'
check "old dovi_tool: version named"     "grep -q 'dovi_tool 2.3.4 is too old (need >= 2.1)' '$T/c.out'"
hdr_fake 8 1; MKVMERGE=""
crd '1\n'; eq    "no mkvmerge: base layer by choice" "$R" "0:drop::"
check "  mkvmerge reason"                "grep -q 'mkvmerge not found (needed to write the DV configuration record)' '$T/c.out'"
hdr_fake 5 0 SDR
crd '1\n'; eq    "P5: skipped, never dropped"       "$R" "1:none::"
check "  P5 reason"                      "grep -q 'no backward-compatible base layer' '$T/c.out' && grep -q 'WRONG colours' '$T/c.out'"
hdr_fake 8 6
crd '2\n'; eq    "P8 compat 6: not supported"       "$R" "1:none::"

hdr_fake 8 1; HDR_DV=0 HDR_DV_PROFILE="" HDR_DV_COMPAT=""
crd ''; eq    "HDR10 source: no DV output, no menu" "$R" "0:none::"
check "  nothing printed"                "[[ ! -s '$T/c.out' ]]"
hdr_fake 8 1; HDR_DV=0 HDR_KIND=SDR HDR_MASTER="" HDR_CLL="" HDR_TRANSFER=bt709 HDR_PRIMARIES=bt709
crd ''; eq    "SDR source: nothing to decide"    "$R" "0:none::"

# strict shell: the default at EOF must not abort a set -e script
LIBS=""
for l in ui media_probe media_stats bitrate encode_common hdr_dovi; do LIBS+="source '$SRC_WORK/lib/$l.sh' > /dev/null; "; done
out=$(bash -c "set -euo pipefail; WORK_DIR='$T/nowork'; $LIBS $(declare -f hdr_fake dv_el_probe); T='$T' FAKE_CALLS='$T/calls'; hdr_fake 8 1
    if confirm_dynamic_range Show '$T/src.mkv' 0; then echo rc=0 dv=\$DV_POLICY; else echo rc=1; fi" < /dev/null 2>&1)
check "set -euo pipefail, EOF: preserve" "grep -q 'rc=0 dv=preserve' <<< \"\$out\" && ! grep -q 'unbound variable' <<< \"\$out\""

hdr_fake 8 1
eq    "tool report: mkvmerge version"    "$(hdr_tools_report | grep 'mkvmerge:')" "  mkvmerge:        v88.0 ($T/bin/mkvmerge)"

# ------------------------------------------------------------
echo
echo "== 2. dv_verify_rpu"

ITEM_TMP="$T/item"
# ver [EXPECTED_FRAMES]  ->  dv_verify_rpu output (record: profile 8.1)
ver() {
    dv_verify_rpu "$T/out.mkv" 0 8 1 "${1-5}"
}
vreset() {
    rm -rf -- "$ITEM_TMP"; mkdir -p "$ITEM_TMP"
    hdr_fake 8 1
    O_DV=1 O_DV_PROFILE=8 O_DV_COMPAT=1 O_DV_RPU=1 O_DV_EL=0 O_DV_BL=1
    echo "8 5 A" > "$ITEM_TMP/inject.rpu"
    FAKE_OUT_RPU="8 5 A" FAKE_PACKETS=5 FAKE_DECODE=0
}

vreset
v=$(ver)
eq    "all checks pass"                  "$v" "VERIFIED (profile 8.1, RPU in all 5 frames, identical to the injected RPU)"
check "  output RPU removed after success" "[[ ! -e '$ITEM_TMP/output.rpu' ]]"
vreset; echo "8 5 A extra" > "$ITEM_TMP/inject.rpu"; FAKE_OUT_RPU="8 5 A extra"
FAKE_OUT_RPU="8 5 A" ; printf '8 5 A\n\n' > "$ITEM_TMP/inject.rpu"
eq    "bytes differ, same summary"       "$(ver)" "VERIFIED (profile 8.1, RPU in all 5 frames, same metadata as the injected RPU)"
vreset; FAKE_OUT_RPU="8 5 B"
v=$(ver)
check "RPU content differs: fails"       "[[ '$v' == 'output RPU metadata differs from the injected RPU'* ]] && [[ -e '$ITEM_TMP/output.rpu' ]]"
vreset; FAKE_OUT_RPU="8 4 A"
eq    "RPU count differs"                "$(ver)" "output has 4 RPUs, source had 5"
vreset; FAKE_PACKETS=6
eq    "frame count differs from RPUs"    "$(ver)" "output has 6 video frames but 5 RPUs (frames and RPUs not aligned)"
vreset; FAKE_PACKETS=none
eq    "frame count unreadable"           "$(ver)" "output video frame count could not be read"
vreset; FAKE_DECODE=1
eq    "does not decode"                  "$(ver)" "output video does not decode (decode_check.log)"
vreset; FAKE_OUT_RPU=""
eq    "no RPU in the stream"             "$(ver)" "no RPU found in the output stream"
vreset; FAKE_OUT_RPU="7 5 A"
eq    "RPU profile 7"                    "$(ver)" "RPU profile 7, expected 8"
vreset; O_DV=0
eq    "no configuration record"          "$(ver)" "no Dolby Vision configuration record in the output"
vreset; O_DV_PROFILE=7
eq    "record profile"                   "$(ver)" "configuration record profile 7, expected 8"
vreset; O_DV_COMPAT=4
eq    "record compat"                    "$(ver)" "compatibility id 4, expected 1"
vreset; O_DV_RPU=0
eq    "record: no RPU"                   "$(ver)" "configuration record says no RPU"
vreset; O_DV_EL=1
eq    "record claims an EL"              "$(ver)" "configuration record claims an enhancement layer"
vreset; O_DV_BL=0
eq    "record: no BL"                    "$(ver)" "configuration record says no base layer"
vreset; DOVI_TOOL=""
eq    "dovi_tool missing: not verified"  "$(ver)" "dovi_tool not available to check the RPU"

# ------------------------------------------------------------
echo
echo "== 3. injection / wrap"

ireset() {
    rm -rf -- "$ITEM_TMP"; mkdir -p "$ITEM_TMP"; hdr_fake 8 1
    echo "8 5 A" > "$ITEM_TMP/source.rpu"; cp "$ITEM_TMP/source.rpu" "$ITEM_TMP/inject.rpu"
    printf 'Summary:\n  Frames: 5\n' > "$ITEM_TMP/source_rpu_summary.txt"
    echo hevc > "$ITEM_TMP/video.hevc"
    FAKE_INJECT="" FAKE_RES=1920x1080
}

ireset
item_dv_inject 1920 1080 > "$T/i.out" 2>&1
eq    "inject ok"                        "$?:$( [[ -e $ITEM_TMP/video_dv.hevc ]] && echo dv):$( [[ -e $ITEM_TMP/video.hevc ]] && echo raw)" "0:dv:"
ireset; FAKE_INJECT=fail
item_dv_inject 1920 1080 > "$T/i.out" 2>&1
eq    "inject-rpu fails: item fails"     "$?" 1
check "  reason + log kept, raw HEVC kept for the step" "grep -q 'RPU injection failed' '$ITEM_TMP/reason' && grep -q 'invalid HEVC' '$ITEM_TMP/dovi_tool.log' && [[ -e '$ITEM_TMP/video.hevc' ]]"
ireset; FAKE_INJECT=mismatch
item_dv_inject 1920 1080 > "$T/i.out" 2>&1
eq    "frame-count mismatch: item fails" "$?" 1
check "  reason names the mismatch"      "grep -q 'encoded frame count does not match the RPU count' '$ITEM_TMP/reason'"

ireset; printf 'Summary:\n  Frames: 5\n  L5 offsets: top 280 bottom 280\n' > "$ITEM_TMP/source_rpu_summary.txt"
item_dv_inject 3840 2160 > "$T/i.out" 2>&1
eq    "4K -> 1080p: L5 rescaled"         "$?:$(grep -o '"top": [0-9]*' "$ITEM_TMP/l5_scaled.json"):$(grep -o '"bottom": [0-9]*' "$ITEM_TMP/l5_scaled.json")" '0:"top": 140:"bottom": 140'
ireset; printf 'Summary:\n  Frames: 5\n  L5 offsets: top 280 bottom 280\n' > "$ITEM_TMP/source_rpu_summary.txt"; FAKE_RES=3840x2160
item_dv_inject 3840 2160 > "$T/i.out" 2>&1
check "4K kept: no rescale"              "[[ ! -e '$ITEM_TMP/l5_scaled.json' ]] && ! grep -q '^export ' '$FAKE_CALLS'"

wreset() { rm -rf -- "$ITEM_TMP"; mkdir -p "$ITEM_TMP"; hdr_fake 8 1; echo h > "$ITEM_TMP/video_dv.hevc"; echo '# timestamp format v2' > "$ITEM_TMP/timestamps.txt"; FAKE_RECORD=1; }
wreset
item_dv_wrap > "$T/w.out" 2>&1
eq    "wrap ok"                          "$?:$( [[ -e $ITEM_TMP/video_dv.hevc ]] && echo kept || echo removed)" "0:removed"
check "  source timestamps used"         "grep -q -- '--timestamps 0:$ITEM_TMP/timestamps.txt' '$FAKE_CALLS'"
wreset; FAKE_RECORD=0
item_dv_wrap > "$T/w.out" 2>&1
eq    "no DV record after the wrap: fails" "$?" 1
check "  reason names mkvmerge version"  "grep -q 'mkvmerge v88.0 did not write a Dolby Vision configuration record' '$ITEM_TMP/reason'"
wreset; MKVMERGE=""
item_dv_wrap > "$T/w.out" 2>&1
eq    "mkvmerge missing at job time: fails" "$?" 1
check "  reason"                         "grep -q 'mkvmerge not found' '$ITEM_TMP/reason'"

# ------------------------------------------------------------
echo
echo "== 4. failed item keeps the DV diagnosis files"
JOB_LOG_DIR="$T/logs/job"
ITEM_TMP="$JOB_LOG_DIR/item-3.tmp"
mkdir -p "$ITEM_TMP"
for f in video.hevc video_dv.hevc video_dv.mkv source.rpu inject.rpu output.rpu source_rpu_summary.txt \
         output_rpu_summary.txt timestamps.txt dovi_tool.log mkvmerge.log reason; do
    echo x > "$ITEM_TMP/$f"
done
source "$SRC_WORK/lib/job_runtime.sh" > /dev/null 2>&1
item_tmp_drop_intermediates
check "large video intermediates removed" "[[ ! -e '$ITEM_TMP/video.hevc' && ! -e '$ITEM_TMP/video_dv.hevc' && ! -e '$ITEM_TMP/video_dv.mkv' ]]"
check "RPUs, summaries, timestamps, logs kept" \
    "for f in source.rpu inject.rpu output.rpu source_rpu_summary.txt output_rpu_summary.txt timestamps.txt dovi_tool.log mkvmerge.log reason; do [[ -e '$ITEM_TMP'/\$f ]] || exit 1; done"

# ------------------------------------------------------------
echo
echo "== 5. job generation (real ffmpeg)"
if [[ -z "$REAL_FFMPEG" || -z "$REAL_FFPROBE" ]]; then
    echo "  (ffmpeg / ffprobe not found: skipped)"
else
    PATH="$REAL_PATH"
    "$REAL_FFMPEG" -v error -nostdin -f lavfi -i 'testsrc2=s=320x180:r=24:d=1' -f lavfi -i 'sine=d=1' \
        -c:v libx265 -pix_fmt yuv420p10le -x265-params log-level=error \
        -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -c:a aac -shortest \
        "$T/clip.mkv" > /dev/null 2>&1
    if [[ ! -s "$T/clip.mkv" ]]; then
        echo "  (could not make a test clip: skipped)"
    else
        # gen PROFILE COMPAT POLICY [MODE DISCARD]  ->  job text; probe_hdr
        # reads the real clip, then the DV globals are laid over it
        gen() {
            (
                eval "orig_$(declare -f probe_hdr)"
                probe_hdr() {
                    orig_probe_hdr "$@"
                    # full HDR10 signalling + static metadata on the clip
                    HDR_PRIMARIES=bt2020 HDR_TRANSFER=smpte2084 HDR_MATRIX=bt2020nc HDR_KIND=HDR10
                    HDR_MASTER="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
                    HDR_CLL="1000,400"
                    if [[ "$G_DV" == 1 ]]; then
                        HDR_DV=1 HDR_DV_PROFILE="$G_P" HDR_DV_COMPAT="$G_C" HDR_DV_BL=1 HDR_DV_RPU=1
                    fi
                }
                emit_failed_item() { echo "FAILED_ITEM: $6"; }
                HDR_TOOLS_DETECTED=0
                hdr_tools_detect
                DV_POLICY="$3" DV_MODE="${4:-}" DV_EL_DISCARD="${5:-}" DV_OUT=8.1 HDR10P_POLICY=none
                G_DV="$G_DV" G_P="$1" G_C="$2"
                emit_encode_item 1 "$T/clip.mkv" "$T/out.mkv" High crf:20 "" "" 0
            ) 2>&1
        }
        G_DV=0; base=$(gen "" "" none)
        check "HDR10 source: single ffmpeg encode, no DV steps" \
            "grep -q 'libx265' <<< \"\$base\" && ! grep -qE 'item_dv_|-f hevc|FAILED_ITEM' <<< \"\$base\" && grep -q 'dv=none' <<< \"\$base\""
        G_DV=1; drop=$(gen 8 1 drop)
        check "HDR10 only (drop): same single encode, dv=drop expected" \
            "! grep -qE 'item_dv_|-f hevc|FAILED_ITEM' <<< \"\$drop\" && grep -q 'dv=drop' <<< \"\$drop\""
        check "  identical to the HDR10 job apart from the dv expectation" \
            "[[ \"\$(sed 's/dv=drop/dv=none/' <<< \"\$drop\")\" == \"\$base\" ]]"
        check "  libx265 never writes an RPU" "! libx265_has_option dolbyvision || grep -q -- '-dolbyvision:v:0 0' <<< \"\$drop\""
        G_DV=1; keep=$(gen 8 1 preserve)
        [[ -n "${DV_OUTPUT_TESTS_SHOW:-}" ]] && printf "%s
" "$keep"
        check "P8.1 preserve: extract, raw HEVC, inject, wrap" \
            "grep -q 'item_dv_extract' <<< \"\$keep\" && grep -q -- '-f hevc \"\$ITEM_TMP/video.hevc\"' <<< \"\$keep\" && grep -q 'item_dv_inject 320 180' <<< \"\$keep\" && grep -q 'item_dv_wrap' <<< \"\$keep\""
        check "  frames pinned (fps_mode passthrough), profile 8.1 expected" \
            "grep -q 'fps_mode:v:0 passthrough' <<< \"\$keep\" && grep -q 'dv=preserve dv_profile=8 dv_compat=1' <<< \"\$keep\""
        keepu="${keep//\\/}"      # without the shell quoting
        check "  HDR10 SEIs in the bitstream (x265)" \
            "grep -q 'colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc' <<< \"\$keepu\" && grep -qF 'master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)' <<< \"\$keepu\" && grep -q 'max-cll=1000,400' <<< \"\$keepu\""
        check "  HDR10 static metadata in the container (mkvmerge)" \
            "grep -q 'item_dv_wrap .*--max-content-light 0:1000 --max-frame-light 0:400 .*--max-luminance 0:1000.0000 --min-luminance 0:0.0001' <<< \"\$keep\""
        check "  same HDR10 parameters as the HDR10-only job" \
            "[[ \"\$(grep -o 'x265-params:v:0 [^ ]*' <<< \"\$keep\")\" == \"\$(grep -o 'x265-params:v:0 [^ ]*' <<< \"\$drop\")\" ]]"
        G_DV=1; p7=$(gen 7 6 preserve 2 "MEL,FEL")
        check "P7 preserve: mode 2 + confirmed EL types passed to the job" \
            "grep -q 'item_dv_extract .* 0 2 MEL\\\\,FEL' <<< \"\$p7\" && grep -q 'profile 7 -> 8.1: RPU kept, enhancement layer discarded' <<< \"\$p7\""
        G_DV=1; nop=$(gen 8 1 none)
        check "DV without a policy: never queued" "grep -q 'FAILED_ITEM: Dolby Vision profile 8 found but no preservation policy was chosen' <<< \"\$nop\""
    fi
fi

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
