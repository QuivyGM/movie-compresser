#!/usr/bin/env bash
# Dolby Vision profile 7 -> 8.1: enhancement-layer (MEL / FEL / unknown)
# classification, tier policy and the job-time check.
#
#   bash ~/compress/work/tests/dv_el_policy_tests.sh
#
# No media tools needed: dovi_tool, ffmpeg and ffprobe are stand-ins
# (summaries in the format of dovi_tool >= 2.0 "info -s"), so nothing is
# encoded or scanned. Covers:
#   1. dv_el_classify on dovi_tool summaries (FEL, MEL, mixed, none)
#   2. confirm_dynamic_range: profile 7 probed (no prompt), profile 8.1
#      kept without a probe or conversion, labels never claim the EL
#   3. dv_el_policy: every tier x MEL / FEL / unknown (prompt or not,
#      DV_EL_DISCARD)
#   4. item_dv_extract: unconfirmed EL type fails before the conversion,
#      confirmed FEL converted with a warning, profile 8.1 unconverted,
#      conversion failures abort, jobs without the argument
#   5. emit_encode_item: profile 7 without an EL decision is not queued
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${DV_EL_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE NO_COLOR

# ---- stand-ins
# dovi_tool: an "RPU file" holds the profile text of its summary
# ("7 (FEL)", "8", ...); FAKE_EL is what extract-rpu finds, FAKE_FRAMES
# the RPU count, FAKE_EDITOR=fail / keep7 a failing / no-op conversion.
# Every call is logged to $T/calls.
mkdir -p "$T/bin"
cat > "$T/bin/dovi_tool" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
case "$1" in
    --version) echo "dovi_tool 2.3.4"; exit 0 ;;
    export)    echo "level5"; exit 0 ;;
    extract-rpu)
        cat > /dev/null
        [[ "$FAKE_EL" == none ]] && exit 1
        printf '%s\n' "$FAKE_EL" > "$4"
        ;;
    info)
        printf 'Parsing RPU file...\nSummary:\n  Frames: %s\n  Profile: %s\n  DM version: 2 (CM v4.0)\n' \
            "$FAKE_FRAMES" "$(cat "$4")"
        ;;
    editor)
        [[ "${FAKE_EDITOR:-}" == fail ]] && exit 1
        if [[ "${FAKE_EDITOR:-}" == keep7 ]]; then cp "$3" "$7"
        elif grep -q '"mode": 2' "$5"; then echo 8 > "$7"
        else cp "$3" "$7"; fi
        ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/ffmpeg"
cat > "$T/bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
for ((i = 0; i < FAKE_FRAMES; i++)); do echo "0.$i"; done
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_CALLS="$T/calls" FAKE_FRAMES=5 FAKE_EL="7 (FEL)"
WORK_DIR="$T/work"

for l in ui media_probe media_stats bitrate encode_common hdr_dovi; do
    source "$SRC_WORK/lib/$l.sh" > /dev/null
done

hdr_fake() {
    HDR_TOOLS_DETECTED=1 X265_HDR10PLUS=1 FFMPEG_DOVI_BSF=0 FFMPEG_X265_DV=0
    DOVI_TOOL="$T/bin/dovi_tool" DOVI_TOOL_VERSION=2.3.4 DOVI_TOOL_OK=1
    HDR10PLUS_TOOL="" MKVMERGE=/usr/bin/mkvmerge
    HDR_CODEC=hevc HDR_KIND=HDR10 HDR_HDR10PLUS=0 HDR_DV=1 HDR_DV_PROFILE=7 HDR_DV_COMPAT=6
    HDR_DV_EL=1 HDR_MASTER="" HDR_CLL="" HDR_PRIMARIES=bt2020 HDR_TRANSFER=smpte2084 HDR_MATRIX=bt2020nc
    : > "$FAKE_CALLS"
}

# ------------------------------------------------------------
echo "== 1. dv_el_classify (dovi_tool info -s summaries)"
cls() { printf 'Summary:\n  Frames: 10\n  %s\n' "$1" > "$T/s.txt"; dv_el_classify "$T/s.txt"; }
eq "7 (FEL)"                  "$(cls 'Profile: 7 (FEL)')" FEL
eq "7 (MEL)"                  "$(cls 'Profile: 7 (MEL)')" MEL
eq "7 (FEL, MEL): FEL wins"   "$(cls 'Profile: 7 (FEL, MEL)')" FEL
eq "Profiles: 7 (MEL), 8"     "$(cls 'Profiles: 7 (MEL), 8')" MEL
eq "7 () -> unknown"          "$(cls 'Profile: 7 ()')" unknown
eq "7 without subprofile"     "$(cls 'Profile: 7')" unknown
eq "profile 8 -> unknown"     "$(cls 'Profile: 8')" unknown
printf 'Summary:\r\n  Profile: 7 (MEL)\r\n' > "$T/crlf.txt"
eq "CRLF summary"             "$(dv_el_classify "$T/crlf.txt")" MEL
eq "missing summary"          "$(dv_el_classify "$T/nope.txt")" unknown

# ------------------------------------------------------------
echo
echo "== 2. confirm_dynamic_range"
echo src > "$T/src.mkv"

hdr_fake; FAKE_EL="7 (MEL)"
confirm_dynamic_range Film "$T/src.mkv" 0 < /dev/null > "$T/c1.out" 2>&1
eq    "P7 MEL: no prompt, preserve"     "$?:$DV_POLICY:$DV_MODE:$DV_EL_TYPE" "0:preserve:2:MEL"
check "P7 MEL: probe without conversion" "grep -q '^extract-rpu - ' '$FAKE_CALLS' && ! grep -qE -- '(^| )-m |editor' '$FAKE_CALLS'"
check "P7 MEL: RPU line, EL discarded"  "grep -q '^Dolby Vision:   RPU PRESERVED as profile 8.1; MEL enhancement layer discarded\$' '$T/c1.out'"
eq    "P7 MEL: short policy"            "$(hdr_policy_short)" "DV RPU preserved, DV MEL discarded"
check "P7 MEL: summary names the EL"    "[[ \"\$(hdr_policy_summary)\" == 'Dolby Vision RPU preserved as profile 8.1 (from profile 7; MEL DISCARDED)' ]]"

hdr_fake; FAKE_EL="7 (FEL)"
confirm_dynamic_range Film "$T/src.mkv" 0 < /dev/null > "$T/c2.out" 2>&1
eq    "P7 FEL: decision deferred"       "$?:$DV_EL_TYPE:$DV_EL_DISCARD" "0:FEL:"
check "P7 FEL: FEL DISCARDED shown"     "grep -q 'RPU PRESERVED as profile 8.1; FEL DISCARDED' '$T/c2.out'"
check "P7 FEL: never plain PRESERVED"   "! grep -qE 'Dolby Vision: +PRESERVED' '$T/c2.out' && [[ \"\$(hdr_policy_short)\" != 'DV preserved'* ]]"

hdr_fake; FAKE_EL=none
confirm_dynamic_range Film "$T/src.mkv" 0 < /dev/null > "$T/c3.out" 2>&1
eq    "P7 extraction fails: unknown"    "$DV_EL_TYPE" unknown
hdr_fake
confirm_dynamic_range Film < /dev/null > /dev/null 2>&1
eq    "P7 no file: unknown (not MEL)"   "$DV_EL_TYPE" unknown

hdr_fake; FAKE_EL="7 (FEL)"
COMPRESS_VERBOSE=1 confirm_dynamic_range Film "$T/src.mkv" 0 < /dev/null > "$T/c4.out" 2>&1
check "verbose: EL type + sample note"  "grep -q 'Enhancement layer: FEL (first 1000 frames; the job checks every frame), NOT kept' '$T/c4.out'"

hdr_fake; HDR_DV_PROFILE=8 HDR_DV_COMPAT=1 HDR_DV_EL=""
confirm_dynamic_range Film "$T/src.mkv" 0 < /dev/null > "$T/c5.out" 2>&1
eq    "P8.1: preserved, no conversion"  "$?:$DV_POLICY:$DV_MODE:$DV_EL_TYPE" "0:preserve::"
check "P8.1: no dovi_tool probe"        "! grep -q extract-rpu '$FAKE_CALLS'"
eq    "P8.1: compact line unchanged"    "$(cat "$T/c5.out")" $'\nDolby Vision:   PRESERVED'
eq    "P8.1: short policy unchanged"    "$(hdr_policy_short)" "DV preserved"
dv_el_policy Quality Film < /dev/null > /dev/null
eq    "P8.1: EL policy not involved"    "$?:$DV_EL_DISCARD" "0:"

hdr_fake; HDR_DV=0 HDR_DV_PROFILE="" HDR_DV_COMPAT=""
confirm_dynamic_range Film "$T/src.mkv" 0 < /dev/null > /dev/null 2>&1
eq    "no DV: nothing to convert"       "$DV_POLICY:$DV_MODE:$DV_EL_TYPE" "none::"
dv_el_policy Quality Film < /dev/null > /dev/null
eq    "no DV: EL policy not involved"   "$?:$DV_EL_DISCARD" "0:"

hdr_fake; DOVI_TOOL="" DOVI_TOOL_OK=0
printf '2\n' | confirm_dynamic_range Film "$T/src.mkv" 0 > "$T/c6.out" 2>&1
eq    "P7, no dovi_tool: explicit choice, skip" "$?" 1
check "P7, no dovi_tool: EL named in the drop" "grep -q 'the enhancement layer is dropped too' '$T/c6.out'"

# ------------------------------------------------------------
echo
echo "== 3. dv_el_policy (tier x EL type)"

# pol TIER TYPE ANSWER  ->  "rc:DV_EL_DISCARD:prompted" (prompted = the
# answer line was read)
pol() {
    hdr_fake; DV_POLICY=preserve DV_MODE=2 DV_OUT=8.1 DV_EL_TYPE="$2"
    printf '%s\nREST\n' "$3" > "$T/in.txt"
    { dv_el_policy "$1" Film > "$T/pol.out" 2>&1; rc=$?; read -r rest || rest=""; } < "$T/in.txt"
    printf '%s:%s:%s' "$rc" "$DV_EL_DISCARD" "$( [[ "$rest" == REST ]] && echo yes || echo no)"
}

eq "Quality MEL: automatic"            "$(pol Quality MEL n)"   "0:MEL:no"
eq "Quality FEL: confirm, no"          "$(pol Quality FEL n)"   "1::yes"
eq "Quality FEL: confirm, Enter = no"  "$(pol Quality FEL '')"  "1::yes"
eq "Quality FEL: confirm, yes"         "$(pol Quality FEL y)"   "0:MEL,FEL:yes"
pol Quality FEL y > /dev/null
check "Quality FEL: warning text"      "grep -q '^WARNING: Film is Dolby Vision profile 7 with a FEL' '$T/pol.out'"
for t in High Base Compact; do
    eq "$t MEL: automatic"             "$(pol "$t" MEL n)"      "0:MEL,FEL:no"
    eq "$t FEL: automatic + warning"   "$(pol "$t" FEL n)"      "0:MEL,FEL:no"
    pol "$t" FEL n > /dev/null
    check "$t FEL: warning printed"    "grep -q '^WARNING: Film: Dolby Vision profile 7 with a FEL' '$T/pol.out' && grep -q '$t discards it automatically' '$T/pol.out'"
    eq "$t unknown: confirm, no"       "$(pol "$t" unknown n)"  "1::yes"
    eq "$t unknown: confirm, yes"      "$(pol "$t" unknown y)"  "0:MEL,FEL,unknown:yes"
done
eq "Custom MEL: automatic"             "$(pol Custom MEL n)"    "0:MEL:no"
eq "Custom FEL: confirm, no"           "$(pol Custom FEL n)"    "1::yes"
eq "Custom FEL: confirm, yes"          "$(pol Custom FEL y)"    "0:MEL,FEL:yes"
eq "Quality unknown: confirm, yes"     "$(pol Quality unknown y)" "0:MEL,FEL,unknown:yes"
eq "Custom unknown: confirm, no"       "$(pol Custom unknown n)" "1::yes"
pol Custom unknown n > /dev/null
check "unknown: may be a FEL"          "grep -q 'could not be determined' '$T/pol.out' && grep -q 'may be a FEL' '$T/pol.out'"

# ------------------------------------------------------------
echo
echo "== 4. item_dv_extract (job time)"

# ext MODE [ALLOW]  ->  return code; fresh ITEM_TMP
ext() {
    ITEM_TMP="$T/item"; rm -rf -- "$ITEM_TMP"; mkdir -p "$ITEM_TMP"; : > "$FAKE_CALLS"
    item_dv_extract "$T/src.mkv" 0 "$@" > "$T/ext.out" 2>&1
}

hdr_fake; FAKE_EL="7 (FEL)"
ext 2 MEL
eq    "FEL, only MEL confirmed: fails"   "$?" 1
check "  reason names the FEL"           "grep -q 'profile 7 FEL: discarding it was not confirmed' '$ITEM_TMP/reason'"
check "  nothing converted / injected"   "! grep -q editor '$FAKE_CALLS' && [[ ! -e '$ITEM_TMP/source.rpu' && ! -e '$ITEM_TMP/inject.rpu' ]]"
check "  extracted unconverted"          "grep -q '^extract-rpu - ' '$FAKE_CALLS' && ! grep -qE -- '(^| )-m ' '$FAKE_CALLS'"

ext 2 "MEL,FEL"
eq    "FEL confirmed: converted"         "$?:$(cat "$ITEM_TMP/dv_el"):$(cat "$ITEM_TMP/source.rpu"):$(cat "$ITEM_TMP/rpu_frames")" "0:FEL:8:5"
check "  editor mode 2, warning logged"  "grep -q '^editor ' '$FAKE_CALLS' && grep -q '\"mode\": 2' '$ITEM_TMP/dv_convert.json' && grep -q '^WARNING: the FEL is discarded' '$T/ext.out'"
check "  inject.rpu is the 8.1 RPU"      "[[ \$(cat '$ITEM_TMP/inject.rpu') == 8 ]]"

FAKE_EL="7 (MEL)"
ext 2 MEL
eq    "MEL confirmed: converted, no warning" "$?:$(cat "$ITEM_TMP/dv_el")" "0:MEL"
check "  no WARNING for MEL"             "! grep -q WARNING '$T/ext.out'"

FAKE_EL="7 ()"
ext 2 "MEL,FEL"
eq    "unknown, not confirmed: fails"    "$?" 1
ext 2 "MEL,FEL,unknown"
eq    "unknown, confirmed: converted"    "$?:$(cat "$ITEM_TMP/dv_el")" "0:unknown"

FAKE_EL="7 (FEL)"
ext 2 ""
eq    "empty decision: fails"            "$?" 1
ext 2
eq    "job without the argument (old menu asked): converted" "$?:$(cat "$ITEM_TMP/dv_el")" "0:FEL"

FAKE_EDITOR=fail ext 2 "MEL,FEL"
eq    "conversion error: aborts"         "$?" 1
check "  reason: conversion failed"      "grep -q 'RPU conversion (dovi_tool mode 2) failed' '$ITEM_TMP/reason' && [[ ! -e '$ITEM_TMP/inject.rpu' ]]"
FAKE_EDITOR=keep7 ext 2 "MEL,FEL"
eq    "conversion without profile 8: aborts" "$?" 1
check "  reason: not profile 8"          "grep -q 'did not give profile 8' '$ITEM_TMP/reason'"

FAKE_EL=none
ext 2 "MEL,FEL"
eq    "extraction error: aborts"         "$?" 1

FAKE_EL="8"
ext ""
eq    "profile 8.1: kept unconverted"    "$?:$(cat "$ITEM_TMP/source.rpu")" "0:8"
check "  no classification / editor"     "! grep -q editor '$FAKE_CALLS' && [[ ! -e '$ITEM_TMP/dv_el' ]]"

# ------------------------------------------------------------
echo
echo "== 5. emit_encode_item: profile 7 needs an EL decision"
(
    main_video_index() { echo 0; }
    probe_hdr() { hdr_fake; }
    build_stream_map() { :; }
    emit_failed_item() { echo "FAILED_ITEM: $6"; }
    DV_POLICY=preserve DV_MODE=2 DV_EL_DISCARD=""
    emit_encode_item 1 "$T/src.mkv" "$T/out.mkv" High crf:20 "" "" 0
) > "$T/emit.out" 2>&1
check "no decision: item not queued"    "grep -q 'FAILED_ITEM: Dolby Vision profile 7 found but discarding its enhancement layer was not decided' '$T/emit.out'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
