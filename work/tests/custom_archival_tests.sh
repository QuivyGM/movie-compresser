#!/usr/bin/env bash
# Movie Custom as the archival choice: default CRF, optional x265 film
# grain tuning, "copy" (keep the source video), and the verification of
# the tune in the output.
#
#   bash ~/compress/work/tests/custom_archival_tests.sh
#
# Part 1 needs nothing: policy default / validation, the generated
# x265 command lines with and without the tune (unchanged without it),
# the sample encode arguments. Part 2 (ffmpeg / ffprobe with libx265):
# the movie menu on tiny 1 s 320x180 sources (tmux stubbed): Enter takes
# the default CRF, grain is asked and carried into the job, "copy"
# keeps an HEVC source video and is refused for H.264. Part 3 runs two
# tiny jobs: the grain encode is verified from the x265 settings SEI,
# and a job whose encode lost the tune fails its verification.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${ARCHIVAL_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0
SKIPPED=()

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE NO_COLOR

finish() {
    echo
    (( ${#SKIPPED[@]} )) && printf 'skipped: %s\n' "${SKIPPED[@]}"
    echo "passed: $PASS  failed: $FAIL"
    exit $(( FAIL > 0 ))
}

# ------------------------------------------------------------
echo "== 1. policy + command construction"
(
    WORK_DIR="$T/w1"
    for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy; do
        source "$SRC_WORK/lib/$l.sh" > /dev/null
    done

    unset MOVIE_CUSTOM_CRF_DEFAULT
    eq "default CRF without the setting"     "$(movie_custom_crf_default)" 14
    MOVIE_CUSTOM_CRF_DEFAULT=12
    eq "default CRF from the config"         "$(movie_custom_crf_default)" 12

    cp "$SRC_WORK/lib/compress.conf" "$T/ok.conf"
    check "project config loads"             "COMPRESS_CONF='$T/ok.conf' load_policy 2>/dev/null && [[ \$MOVIE_CUSTOM_CRF_DEFAULT == 14 ]]"
    sed 's/^MOVIE_CUSTOM_CRF_DEFAULT=.*/MOVIE_CUSTOM_CRF_DEFAULT=60/' "$SRC_WORK/lib/compress.conf" > "$T/bad.conf"
    check "invalid default rejected"         "! COMPRESS_CONF='$T/bad.conf' load_policy 2>'$T/bad.err' && grep -q 'MOVIE_CUSTOM_CRF_DEFAULT=\"60\"' '$T/bad.err'"
    grep -v '^MOVIE_CUSTOM_CRF_DEFAULT=' "$SRC_WORK/lib/compress.conf" > "$T/old.conf"
    check "config without it still loads"    "unset MOVIE_CUSTOM_CRF_DEFAULT; COMPRESS_CONF='$T/old.conf' load_policy 2>/dev/null && [[ \$(movie_custom_crf_default) == 14 ]]"

    X265_TUNE=""
    eq "x265 line without tune unchanged"    "$(_emit_x265_lines '-crf:v:0 14' '' '' '')" \
        "      -c:v:0 libx265 -preset slow -crf:v:0 14 -pix_fmt:v:0 yuv420p10le \\"
    X265_TUNE=grain
    check "x265 line with -tune:v:0 grain"   "[[ \"\$(_emit_x265_lines '-crf:v:0 14' '' '' '')\" == *'-preset slow -tune:v:0 grain -crf:v:0 14 -pix_fmt:v:0 yuv420p10le'* ]]"

    # sample encode arguments (ffmpeg replaced by a function)
    ffmpeg() { printf '%s\n' "$@" > "$T/args"; }
    X265_TUNE=""
    crf_sample_encode in.mkv 0 "" "" 14 0 5 "$T/o.hevc"
    check "sample encode: no tune"           "! grep -qx -- '-tune:v:0' '$T/args'"
    X265_TUNE=grain
    crf_sample_encode in.mkv 0 "" "" 14 0 5 "$T/o.hevc"
    check "sample encode: same tune as the job" "grep -A1 -x -- '-tune:v:0' '$T/args' | grep -qx grain"
    exit $(( FAIL > 0 ))
) | tee "$T/part1.out"
PASS=$(( PASS + $(grep -c '^  ok ' "$T/part1.out") ))
FAIL=$(( FAIL + $(grep -c '^  FAIL ' "$T/part1.out") ))

# ------------------------------------------------------------
for t in ffmpeg ffprobe; do
    command -v "$t" >/dev/null || { SKIPPED+=("parts 2-3 ($t not found)"); finish; }
done

echo
echo "== 2. movie menu (Custom)"
H="$T/home"
mkdir -p "$H/compress/in" "$H/compress/out" "$T/stub"
cp -r "$SRC_WORK" "$H/compress/work"
rm -rf "$H/compress/work/tests" "$H/compress/work/logs" "$H/compress/work/cache"
rm -f "$H/compress/work"/[a-z]*[0-9].sh "$H/compress/work"/*.state "$H/compress/work"/*.progress
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"

ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=1" -f lavfi -i "sine=f=440:r=48000:d=1" \
    -c:v libx264 -preset ultrafast -qp 0 -pix_fmt yuv420p -c:a aac -b:a 96k "$H/compress/in/A.mkv"
ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=1" -f lavfi -i "sine=f=440:r=48000:d=1" \
    -c:v libx265 -preset ultrafast -x265-params log-level=error:lossless=1 -pix_fmt yuv420p10le \
    -c:a aac -b:a 96k "$H/compress/in/B.mkv"

# menu INPUT NAME  ->  log $T/NAME.log, job $T/NAME.sh ("" when none)
menu() {
    local j
    printf "$1" | HOME="$H" PATH="$T/stub:$PATH" COMPRESS_CONF="$H/compress/work/lib/compress.conf" \
        timeout 60 bash "$H/compress/work/movie_compress.sh" > "$T/$2.log" 2>&1
    j=$(ls -t "$H/compress/work"/c*.sh 2>/dev/null | head -n 1)
    if [[ -n "$j" ]]; then mv -- "$j" "$T/$2.sh"; else : > "$T/$2.sh"; fi
}

menu "1\n5\n\ny\nn\n" grain
check "Enter: default CRF 14 used"       "grep -q -- '-crf:v:0 14' '$T/grain.sh' && grep -q 'CRF 14 tune grain' '$T/grain.log'"
check "grain: tune in the final encode"  "grep -q -- '-preset slow -tune:v:0 grain -crf:v:0 14' '$T/grain.sh'"
check "grain: planned tune checked"      "grep -q 'tune=grain' '$T/grain.sh'"

menu "1\n5\n12\n\nn\n" plain
check "CRF 12 entered, no tune"          "grep -q -- '-crf:v:0 12' '$T/plain.sh' && ! grep -qE -- '-tune|tune=' '$T/plain.sh'"
check "no retry / ceiling for Custom"    "grep -q 'item_crf_encode' '$T/plain.sh' && grep -qE \"ceiling_vbytes='?'? crf_min='?'? \" '$T/plain.sh'"

menu "1\n5\ncopy\n13\n\nn\n" avc
check "copy refused for H.264, CRF asked again" "grep -q 'Keeping the source video needs an HEVC source' '$T/avc.log' && grep -q -- '-crf:v:0 13' '$T/avc.sh'"

menu "2\n5\ncopy\nn\n" copy
check "copy: HEVC source video kept"     "grep -q 'source video kept' '$T/copy.log' && [[ -s '$T/copy.sh' ]] && ! grep -q 'libx265' '$T/copy.sh'"

# ------------------------------------------------------------
echo
echo "== 3. jobs: tune verified, a lost tune fails"
if [[ ! -s "$T/grain.sh" ]]; then
    SKIPPED+=("part 3 (no grain job generated)")
    finish
fi
cp "$T/grain.sh" "$T/run_grain.sh"
HOME="$H" PATH="$T/stub:$PATH" timeout 60 bash "$T/run_grain.sh" < /dev/null > "$T/run_grain.log" 2>&1
O=$(ls "$H/compress/out"/A*.mkv 2>/dev/null | head -n 1)
check "grain job succeeded"              "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/run_grain.log'"
check "report: tune grain AS PLANNED"    "grep -qE 'Video stream: +AS PLANNED \\(hevc 320x180 yuv420p10le, CRF 14\\.0 \\(single pass\\), tune grain\\)' '$T/run_grain.log'"
check "output SEI: rc-grain, no SAO"     "source '$SRC_WORK/lib/media_probe.sh'; x265_sei_options '$O' 0 | grep -qx rc-grain && x265_sei_options '$O' 0 | grep -qx no-sao"
check "audio copied, verified"           "grep -qE 'Audio track 1: +COPIED .*payload MD5 MATCH' '$T/run_grain.log'"

# the encode loses the tune (as with a "tune=" inside -x265-params,
# which x265 ignores): the verification must fail the item
sed 's/ -tune:v:0 grain//' "$T/grain.sh" > "$T/run_lost.sh"
rm -f -- "$H/compress/out"/*.mkv
HOME="$H" PATH="$T/stub:$PATH" timeout 60 bash "$T/run_lost.sh" < /dev/null > "$T/run_lost.log" 2>&1
check "lost tune: item failed"           "grep -q 'x265 --tune grain not found in the stream settings' '$T/run_lost.log' && grep -qE '0 ok, 1 failed' '$T/run_lost.log'"
check "lost tune: no final output"       "! ls '$H/compress/out'/A*HEVC\\ Custom.mkv >/dev/null 2>&1"

finish
