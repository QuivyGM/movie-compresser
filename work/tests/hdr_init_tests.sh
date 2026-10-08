#!/usr/bin/env bash
# HDR tool initialization regression tests (HDR10+ / Dolby Vision under
# set -u).
#
#   bash ~/compress/work/tests/hdr_init_tests.sh
#
# Regression: in the compact (default) menu output confirm_dynamic_range
# read HDR10PLUS_TOOL / DOVI_TOOL_OK / MKVMERGE before hdr_tools_detect
# had run (only the verbose tool report or a warning ran it), so any
# HDR10+ or Dolby Vision source stopped the movie / series menu with
#   hdr_dovi.sh: line N: HDR10PLUS_TOOL: unbound variable
#
# Needs ffmpeg / ffprobe with libx265; hdr10plus_tool for the HDR10+
# sources; dovi_tool + mkvmerge for the Dolby Vision source (each part is
# skipped, and listed, when its tool is missing). tmux is stubbed; no
# encode job is run. Covers:
#   1. confirm_dynamic_range in a set -euo pipefail shell, compact and
#      verbose, HDR10+ / DV / DV + HDR10+, tools detected on demand
#   2. HDR_TOOLS_DETECTED=1 without the tool globals: detected again
#   3. series menu, HDR10+ episodes: fresh analysis (packet scan) and
#      cached analysis (stored statistics), also via compress_menu.sh
#   4. movie menu, Dolby Vision 8.1 + HDR10 + HDR10+ source: both kept,
#      RPU and HDR10+ steps in the job
#   5. hdr10plus_tool missing: explicit warning and choice, never a
#      silent drop and never an unbound variable
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${HDR_INIT_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0
SKIPPED=()

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

unset COMPRESS_VERBOSE NO_COLOR HDR_TOOLS_DETECTED

for t in ffmpeg ffprobe; do
    command -v "$t" >/dev/null || { echo "$t not found: tests skipped"; exit 0; }
done
HAVE_H10P=0; command -v hdr10plus_tool >/dev/null && HAVE_H10P=1
HAVE_DV=0; command -v dovi_tool >/dev/null && command -v mkvmerge >/dev/null && HAVE_DV=1

LIBS=""
for l in ui media_probe media_stats bitrate encode_common hdr_dovi; do
    LIBS+="source '$SRC_WORK/lib/$l.sh' > /dev/null; "
done

# strict SCRIPT  ->  runs SCRIPT in a fresh "set -euo pipefail" bash
# with the libraries sourced (stdout + stderr)
strict() {
    bash -c "set -euo pipefail; WORK_DIR='$T/nowork'; $LIBS $1" < /dev/null 2>&1
}

# fake_hdr KIND H10P DV  ->  probe_hdr globals of a synthetic source
FAKE='HDR_CODEC=hevc HDR_KIND=HDR10 HDR_PRIMARIES=bt2020 HDR_TRANSFER=smpte2084 HDR_MATRIX=bt2020nc
HDR_MASTER="" HDR_CLL="" HDR_DV_PROFILE=8 HDR_DV_COMPAT=1 HDR_DV_EL="" HDR_DV_LEVEL="" HDR_DV_RPU="" HDR_DV_BL=""'

# ------------------------------------------------------------
echo "== 1. confirm_dynamic_range under set -euo pipefail (tools detected on demand)"

out=$(strict "$FAKE; HDR_HDR10PLUS=1 HDR_DV=0; if confirm_dynamic_range Show; then rc=0; else rc=1; fi; echo \"rc=\$rc h10p=\$HDR10P_POLICY\"")
check "compact HDR10+: no unbound variable"      "! grep -q 'unbound variable' <<< \"\$out\""
check "compact HDR10+: decision made"            "grep -qE '^rc=0 h10p=(preserve|drop)\$|HDR10\\+ dynamic metadata that cannot be preserved' <<< \"\$out\""
if (( HAVE_H10P == 1 )); then
    check "compact HDR10+, tool installed: PRESERVED" \
        "grep -q '^HDR10+:         PRESERVED\$' <<< \"\$out\" && grep -q '^rc=0 h10p=preserve\$' <<< \"\$out\""
fi

out=$(strict "$FAKE; HDR_HDR10PLUS=0 HDR_DV=1; if confirm_dynamic_range Show; then rc=0; else rc=1; fi; echo \"rc=\$rc dv=\$DV_POLICY\"")
check "compact DV: no unbound variable (DOVI_TOOL_OK / MKVMERGE)" "! grep -q 'unbound variable' <<< \"\$out\""
if (( HAVE_DV == 1 )); then
    check "compact DV, tools installed: PRESERVED" \
        "grep -q '^Dolby Vision:   PRESERVED\$' <<< \"\$out\" && grep -q '^rc=0 dv=preserve\$' <<< \"\$out\""
fi

out=$(strict "$FAKE; HDR_HDR10PLUS=1 HDR_DV=1; if confirm_dynamic_range Show; then rc=0; else rc=1; fi; echo \"rc=\$rc dv=\$DV_POLICY h10p=\$HDR10P_POLICY\"")
check "compact DV + HDR10+: no unbound variable" "! grep -q 'unbound variable' <<< \"\$out\""
if (( HAVE_DV == 1 && HAVE_H10P == 1 )); then
    check "compact DV + HDR10 + HDR10+: both PRESERVED" \
        "grep -q '^HDR10+:         PRESERVED\$' <<< \"\$out\" && grep -q '^Dolby Vision:   PRESERVED\$' <<< \"\$out\" && grep -q '^rc=0 dv=preserve h10p=preserve\$' <<< \"\$out\""
fi

out=$(strict "COMPRESS_VERBOSE=1; $FAKE; HDR_HDR10PLUS=1 HDR_DV=1; if confirm_dynamic_range Show; then rc=0; else rc=1; fi; echo \"rc=\$rc\"")
check "verbose DV + HDR10+: no unbound variable, tool report" \
    "! grep -q 'unbound variable' <<< \"\$out\" && grep -q '^HDR tools:' <<< \"\$out\""

out=$(strict "$FAKE; HDR_HDR10PLUS=0 HDR_DV=0 HDR_KIND=SDR; if confirm_dynamic_range Show; then rc=0; else rc=1; fi; echo \"rc=\$rc dv=\$DV_POLICY h10p=\$HDR10P_POLICY\"")
check "SDR: nothing to decide, SDR stays SDR"    "[[ \"\$out\" == 'rc=0 dv=none h10p=none' ]]"

out=$(strict "hdr_tools_detect; for v in DOVI_TOOL DOVI_TOOL_VERSION DOVI_TOOL_OK HDR10PLUS_TOOL MKVMERGE FFMPEG_DOVI_BSF FFMPEG_X265_DV; do echo \"\$v=\${!v}\"; done")
check "hdr_tools_detect sets every tool global under set -u" \
    "! grep -q 'unbound variable' <<< \"\$out\" && [[ \$(grep -c '^[A-Z0-9_]*=' <<< \"\$out\") == 7 ]]"
if (( HAVE_H10P == 1 )); then
    check "installed hdr10plus_tool found on PATH" "grep -q '^HDR10PLUS_TOOL=/' <<< \"\$out\""
fi

# ------------------------------------------------------------
echo
echo "== 2. stale detection flag"
out=$(strict "HDR_TOOLS_DETECTED=1; unset HDR10PLUS_TOOL DOVI_TOOL DOVI_TOOL_OK MKVMERGE; hdr_tools_detect; echo \"h10p=\${HDR10PLUS_TOOL+set} dovi=\${DOVI_TOOL_OK+set}\"")
check "flag without globals: tools detected again" "[[ \"\$out\" == 'h10p=set dovi=set' ]]"
out=$(strict "HDR_TOOLS_DETECTED=1; $FAKE; HDR_HDR10PLUS=1 HDR_DV=1; if confirm_dynamic_range Show; then rc=0; else rc=1; fi; echo rc=\$rc")
check "flag without globals: confirm_dynamic_range still safe" "! grep -q 'unbound variable' <<< \"\$out\""

# ------------------------------------------------------------
# menu environment (like ui_tests.sh)
H="$T/home"
mkdir -p "$H/compress/in/Show" "$H/compress/out" "$T/stub"
cp -r "$SRC_WORK" "$H/compress/work"
cp "$ROOT/compress_menu.sh" "$H/compress/"
rm -rf "$H/compress/work/tests" "$H/compress/work/logs" "$H/compress/work/cache" "$H/compress/work/bin"
rm -f "$H/compress/work"/[a-z]*[0-9].sh "$H/compress/work"/*.state "$H/compress/work"/*.progress
chmod +x "$H/compress/compress_menu.sh" "$H/compress/work/movie_compress.sh" "$H/compress/work/series_compress.sh"
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"

menu() {   # SCRIPT INPUT LOG [PATH]
    printf "$2" | HOME="$H" PATH="$T/stub:${4:-$PATH}" bash "$1" > "$3" 2>&1
    echo "exit=$?" >> "$3"
}

HDR_X265="colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400:repeat-headers=1:log-level=error"
awk 'BEGIN {
    printf "{\"JSONInfo\":{\"HDR10plusProfile\":\"A\",\"Version\":\"1.0\"},\"SceneInfo\":["
    for (i = 0; i < 24; i++)
        printf "%s{\"LuminanceParameters\":{\"AverageRGB\":1000,\"LuminanceDistributions\":{\"DistributionIndex\":[1,5,10,25,50,75,90,95,99],\"DistributionValues\":[10,50,100,500,1000,5000,10000,20000,40000]},\"MaxScl\":[40000,40000,40000]},\"NumberOfWindows\":1,\"TargetedSystemDisplayMaximumLuminance\":0,\"SceneFrameIndex\":%d,\"SceneId\":0,\"SequenceFrameIndex\":%d}", (i ? "," : ""), i, i
    printf "],\"SceneInfoSummary\":{\"SceneFirstFrameIndex\":[0],\"SceneFrameNumbers\":[24]}}\n"
}' > "$T/h10p.json"

# h10p_src OUT  ->  1 s 320x180 HDR10 + HDR10+ HEVC with AAC audio (MKV);
# CRF 8, so the High / Custom estimates stay below the source (no
# source-quality guard prompt)
h10p_src() {
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=1,format=yuv420p10le" \
        -f lavfi -i "sine=f=440:r=48000:d=1" \
        -c:v libx265 -preset ultrafast -x265-params "crf=8:$HDR_X265:dhdr10-info=$T/h10p.json" \
        -c:a aac -b:a 96k "$1"
}

# ------------------------------------------------------------
echo
echo "== 3. series menu, HDR10+ episodes (fresh, then cached analysis)"
if (( HAVE_H10P == 1 )) && x265_ok=$(strict "x265_hdr10plus_supported && echo yes") && [[ "$x265_ok" == yes ]]; then
    h10p_src "$H/compress/in/Show/Show.S01E01.mkv"
    h10p_src "$H/compress/in/Show/Show.S01E02.mkv"
    probe_out=$(strict "probe_hdr '$H/compress/in/Show/Show.S01E01.mkv' 0; echo \$HDR_KIND \$HDR_HDR10PLUS")
    check "episodes are HDR10 + HDR10+"          "[[ \"\$probe_out\" == 'HDR10 1' ]]"

    L="$T/series_fresh.log"
    menu "$H/compress/work/series_compress.sh" "1\n2\nn\n" "$L"
    sed -n '1,/^Compression tier/p' "$L" | sed 's/^/  | /'
    check "fresh: analysis by packet scan"       "grep -qE 'Source stats: scanned' '$L'"
    check "fresh: no unbound variable"           "! grep -q 'unbound variable' '$L'"
    check "fresh: HDR10+ PRESERVED, HDR10 kept"  "grep -q '^HDR10+:         PRESERVED\$' '$L' && grep -qE '^Dynamic range: +HDR10 \\+ HDR10\\+\$' '$L'"
    check "fresh: menu continued to the tiers"   "grep -q '^Compression tier:' '$L' && grep -q '^exit=0\$' '$L'"

    if command -v mkvpropedit >/dev/null; then
        L="$T/series_cached.log"
        menu "$H/compress/work/series_compress.sh" "1\n2\nn\n" "$L"
        check "cached: analysis from stored statistics" "grep -qE 'Source stats: cached' '$L'"
        check "cached: no unbound variable"      "! grep -q 'unbound variable' '$L'"
        check "cached: HDR10+ PRESERVED"         "grep -q '^HDR10+:         PRESERVED\$' '$L' && grep -q '^Compression tier:' '$L' && grep -q '^exit=0\$' '$L'"

        L="$T/series_menu.log"
        menu "$H/compress/compress_menu.sh" "2\n1\n2\ny\n" "$L"
        check "compress_menu.sh (set -euo pipefail) -> series: no unbound variable" \
            "! grep -q 'unbound variable' '$L' && grep -qE 'Source stats: cached' '$L' && grep -q '^HDR10+:         PRESERVED\$' '$L'"
        J=$(ls "$H/compress/work"/series[0-9]*.sh 2>/dev/null | head -n 1)
        check "series job: HDR10+ extracted per episode and passed to x265" \
            "[[ -n '$J' ]] && [[ \$(grep -c 'item_step hdr10+ item_hdr10plus_extract' '$J') == 2 ]] && grep -q 'dhdr10-info=\$ITEM_TMP/hdr10plus.json' '$J' && bash -n '$J'"
        rm -f "$H/compress/work"/series[0-9]*.sh "$H/compress/work"/*.state
    else
        SKIPPED+=("cached series analysis (needs mkvpropedit)")
    fi

    # ---- hdr10plus_tool missing: PATH without it (WORK_DIR/bin is empty)
    mkdir -p "$T/noh10p"
    for x in ffmpeg ffprobe mkvmerge mkvpropedit mkvextract dovi_tool; do
        p=$(command -v "$x" 2>/dev/null) && ln -sf "$p" "$T/noh10p/$x"
    done
    NOPATH="$T/noh10p:/usr/bin:/bin"
    if PATH="$NOPATH" command -v hdr10plus_tool >/dev/null; then
        SKIPPED+=("missing hdr10plus_tool (installed in /usr/bin or /bin)")
    else
        echo
        echo "== 5. hdr10plus_tool missing"
        L="$T/series_noh10p.log"
        menu "$H/compress/work/series_compress.sh" "1\nn\n" "$L" "$NOPATH"
        sed -n '/^Dynamic range/,$p' "$L" | sed 's/^/  | /'
        check "missing tool: explicit warning with the reason" \
            "grep -q 'WARNING: this series contains HDR10+ dynamic metadata that cannot be preserved:' '$L' && grep -q '^  hdr10plus_tool not found\$' '$L'"
        check "missing tool: tool report shown"  "grep -q '^HDR tools:' '$L' && grep -q 'hdr10plus_tool:  not found' '$L'"
        check "missing tool: not dropped silently (answer N cancels)" \
            "grep -q '^Compression cancelled.\$' '$L' && ! grep -q '^Compression tier:' '$L' && ! grep -q 'unbound variable' '$L'"
        L="$T/series_noh10p_y.log"
        menu "$H/compress/work/series_compress.sh" "1\ny\n2\nn\n" "$L" "$NOPATH"
        check "missing tool: drop only by explicit choice, reported" \
            "grep -q '^Compression tier:' '$L' && grep -q 'HDR10+ DROPPED' '$L' && ! grep -q 'unbound variable' '$L'"
    fi
else
    SKIPPED+=("HDR10+ series menu (needs hdr10plus_tool and an HDR10+ capable libx265)")
fi

# ------------------------------------------------------------
echo
echo "== 4. movie menu, Dolby Vision 8.1 + HDR10 + HDR10+"
if (( HAVE_DV == 1 && HAVE_H10P == 1 )); then
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=1,format=yuv420p10le" \
        -c:v libx265 -preset ultrafast -x265-params "crf=8:$HDR_X265:dhdr10-info=$T/h10p.json" -f hevc "$T/base.hevc"
    printf '{"profile":"8.1","length":24,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400}}\n' > "$T/gen.json"
    dovi_tool generate -j "$T/gen.json" -o "$T/gen.rpu" > /dev/null
    dovi_tool inject-rpu -i "$T/base.hevc" --rpu-in "$T/gen.rpu" -o "$T/dv.hevc" > /dev/null
    mkvmerge -q -o "$T/dv.mkv" --default-duration 0:24p "$T/dv.hevc"
    ffmpeg -v error -y -i "$T/dv.mkv" -f lavfi -i "sine=f=440:r=48000:d=1" -map 0:v -map 1:a \
        -c:v copy -c:a aac -b:a 96k "$H/compress/in/Film.mkv"
    probe_out=$(strict "probe_hdr '$H/compress/in/Film.mkv' 0; echo \$HDR_KIND \$HDR_HDR10PLUS \$HDR_DV \$HDR_DV_PROFILE.\$HDR_DV_COMPAT")
    check "source is DV 8.1 + HDR10 + HDR10+"    "[[ \"\$probe_out\" == 'HDR10 1 1 8.1' ]]"

    L="$T/movie_dv.log"
    menu "$H/compress/work/movie_compress.sh" "1\n4\n24\nn\n" "$L"
    sed -n '/^Dynamic range/,/^Compression tier/p' "$L" | sed 's/^/  | /'
    check "movie: no unbound variable"           "! grep -q 'unbound variable' '$L' && grep -q '^exit=0\$' '$L'"
    check "movie: header DV 8.1 + HDR10 + HDR10+" "grep -qE '^Dynamic range: +Dolby Vision 8.1 \\+ HDR10 \\+ HDR10\\+\$' '$L'"
    check "movie: HDR10+ and Dolby Vision PRESERVED" \
        "grep -q '^HDR10+:         PRESERVED\$' '$L' && grep -q '^Dolby Vision:   PRESERVED\$' '$L'"
    J=$(ls "$H/compress/work"/c[0-9]*.sh 2>/dev/null | head -n 1)
    check "movie job: RPU and HDR10+ steps, HDR10 signalling" \
        "[[ -n '$J' ]] && grep -q 'item_step rpu item_dv_extract' '$J' && grep -q 'item_dv_inject' '$J' && grep -q 'item_step hdr10+ item_hdr10plus_extract' '$J' && grep -q 'dhdr10-info' '$J' && grep -q 'transfer=smpte2084' '$J' && bash -n '$J'"
else
    SKIPPED+=("Dolby Vision + HDR10+ movie (needs dovi_tool, mkvmerge and hdr10plus_tool)")
fi

echo
for s in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do echo "  skipped: $s"; done
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
