#!/usr/bin/env bash
# Metadata-only audio track naming (audio_titles.sh and the shared
# encode_common.sh naming: audio_std_title / audio_title_warning /
# mkv_std_track_titles / mkv_write_track_titles), used by audio_titles.sh,
# finished compression jobs (job_runtime.sh item_finalize_titles) and
# verify.sh (Verify read-only, Validate + update writing).
#
#   bash ~/compress/work/tests/audio_titles_tests.sh
#
# Short: one 1-second synthetic MKV (160x90, five small audio tracks,
# a subtitle, chapters); every variant is made by editing its metadata
# with mkvpropedit. Nothing is encoded, decoded or hashed after the
# fixture is built. Needs ffmpeg / ffprobe (fixture) and MKVToolNix.
#
#  1. format "Language | Codec | Channels | Bitrate | Description"
#  2. commentary credits / names kept verbatim, wherever they stand
#  3. a description that cannot be separated with confidence: title kept,
#     warning naming the file and the track
#  4. no stored rate for a variable-rate track: bitrate left out
#  5. several audio tracks named independently, in order
#  6. --dry-run and a declined confirmation write nothing
#  7. only track names change (tracks, codecs, languages, flags,
#     subtitles, chapters as before)
#  8. a repeated run changes nothing
#  9. verify.sh Verify mode does not modify the file
# 10. verify.sh Validate + update and a finished job's finalization give
#     the same names as audio_titles.sh (one naming function)
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${AT_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

for t in ffmpeg ffprobe mkvmerge mkvpropedit; do
    command -v "$t" >/dev/null || { echo "skipped: $t not found"; exit 0; }
done
unset COMPRESS_VERBOSE
for l in media_probe media_stats bitrate encode_common; do source "$SRC_WORK/lib/$l.sh" > /dev/null; done

atitles() { ffprobe -v error -select_streams a -show_entries stream_tags=title -of csv=p=0 "$1" | tr -d '\r' | tr '\n' '/'; }
# every track property mkvmerge reports, the names left out
props() { mkvmerge -J "$1" | tr -d '\r' | grep -v '"track_name"' | grep -vE '"(file_name|segment_uid|muxing_application|writing_application|date_utc)"'; }
others() { ffprobe -v error -show_chapters -show_entries stream=index,codec_type:stream_tags=language,title -select_streams s -of compact "$1" | tr -d '\r'; }
names() { printf 'y\n' | bash "$ROOT/audio_titles.sh" "$1" > "$2" 2>&1; }

# ------------------------------------------------------------
echo "== fixture"
F="$T/fixture.mkv"
printf '1\n00:00:00,100 --> 00:00:00,900\nHi\n' > "$T/s.srt"
printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=500\nEND=1000\ntitle=Two\n' > "$T/ch.txt"
ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x90:r=24:d=1" -f lavfi -i "sine=f=440:r=48000:d=1" -i "$T/s.srt" -i "$T/ch.txt" \
    -map 0:v -map 1:a -map 1:a -map 1:a -map 1:a -map 1:a -map 2 -map_chapters 3 \
    -c:v libx264 -preset ultrafast -c:s srt \
    -c:a:0 ac3 -ac:a:0 6 -b:a:0 640k -c:a:1 dca -strict -2 -ac:a:1 2 -b:a:1 768k -c:a:2 flac -ac:a:2 2 \
    -c:a:3 ac3 -ac:a:3 2 -b:a:3 192k -c:a:4 aac -ac:a:4 2 -b:a:4 96k \
    -metadata:s:a:0 language=jpn -metadata:s:a:0 "title=Japanese DD 5.1 640 kbps 1080p BluRay -FGT" -disposition:a:0 default \
    -metadata:s:a:1 language=eng -metadata:s:a:1 "title=DTS 2.0 Commentary by Director/Writer Paul King" -disposition:a:1 0 \
    -metadata:s:a:2 language=eng -metadata:s:a:2 "title=Nolan" -disposition:a:2 0 \
    -metadata:s:a:3 language=eng -metadata:s:a:3 "title=Commentary with Hugh Grant - AC3 2.0" -disposition:a:3 comment \
    -disposition:a:4 0 \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title=Subs -disposition:s:0 forced \
    "$F" 2> "$T/mk.err"
DTS=$(( $(ffprobe -v error -select_streams a:1 -show_entries stream=bit_rate -of default=nw=1:nk=1 "$F" | tr -d '\r') / 1000 ))
check "fixture written (5 audio, 1 subtitle, 2 chapters)" "[[ \$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 '$F' | wc -l) == 5 && \$(ffprobe -v error -show_chapters -of csv=p=0 '$F' | wc -l) == 2 ]]"
ORIG="Japanese DD 5.1 640 kbps 1080p BluRay -FGT/DTS 2.0 Commentary by Director/Writer Paul King/Nolan/Commentary with Hugh Grant - AC3 2.0//"
WANT="Japanese | AC-3 | 5.1 | 640 kbps/English | DTS | 2.0 | $DTS kbps | Commentary by Director/Writer Paul King/Nolan/English | AC-3 | 2.0 | 192 kbps | Commentary with Hugh Grant/AAC | 2.0/"

# ------------------------------------------------------------
echo
echo "== 6 dry run / declined: nothing written"
A="$T/a.mkv"; cp "$F" "$A"
bash "$ROOT/audio_titles.sh" --dry-run "$A" > "$T/dry.log" 2>&1
check "dry run: file unchanged"                "cmp -s '$F' '$A'"
check "dry run: old -> new previewed"          "grep -q '\"Japanese DD 5.1 640 kbps 1080p BluRay -FGT\" -> \"Japanese | AC-3 | 5.1 | 640 kbps\"' '$T/dry.log' && grep -q 'nothing written' '$T/dry.log'"
printf 'n\n' | bash "$ROOT/audio_titles.sh" "$A" > "$T/no.log" 2>&1
check "declined: file unchanged"               "cmp -s '$F' '$A' && grep -q 'Not changed' '$T/no.log'"

echo
echo "== 1-5 names"
P0=$(props "$A"); O0=$(others "$A")
names "$A" "$T/yes.log"
eq    "1-5: every track named / kept"          "$(atitles "$A")" "$WANT"
check "2: credit after technical text kept verbatim" "[[ \"\$(atitles '$A')\" == *'| Commentary by Director/Writer Paul King/'* ]]"
check "2: credit before technical text kept verbatim" "[[ \"\$(atitles '$A')\" == *'| Commentary with Hugh Grant/'* ]]"
check "3: unrecognised name kept, warning names file + track" "grep -q 'WARNING: description \"Nolan\" not recognised' '$T/yes.log' && grep -q 'a.mkv: audio 3 \"Nolan\"' '$T/yes.log'"
check "4: no stored rate (FLAC, AAC): bitrate left out" "[[ \"\$(atitles '$A')\" == *'/Nolan/'* && \"\$(atitles '$A')\" == *'/AAC | 2.0/' ]]"
check "5: release text dropped, stated rate kept" "[[ \"\$(atitles '$A')\" == 'Japanese | AC-3 | 5.1 | 640 kbps/'* ]]"
check "verified by the script itself"          "grep -q 'track count, order, codecs, languages and flags unchanged' '$T/yes.log'"

echo
echo "== 7 metadata only"
eq    "7: tracks, codecs, languages, flags, chapters as before (mkvmerge -J)" "$(props "$A")" "$P0"
eq    "7: subtitle / chapters as before (ffprobe)" "$(others "$A")" "$O0"
eq    "7: commentary flag untouched"           "$(ffprobe -v error -select_streams a -show_entries stream_disposition=default,comment -of csv=p=0 "$A" | tr -d '\r' | tr '\n' ' ')" \
                                               "$(ffprobe -v error -select_streams a -show_entries stream_disposition=default,comment -of csv=p=0 "$F" | tr -d '\r' | tr '\n' ' ')"

echo
echo "== 8 repeat"
cp "$A" "$T/a_once.mkv"
bash "$ROOT/audio_titles.sh" --dry-run "$A" > "$T/again.log" 2>&1
names "$A" "$T/again2.log"
check "8: nothing to change, file untouched"   "grep -q 'Nothing to change' '$T/again.log' && cmp -s '$A' '$T/a_once.mkv'"

echo
echo "== multiple files, one call"
cp "$F" "$T/m1.mkv"; cp "$F" "$T/m2.mkv"
printf 'y\ny\n' | bash "$ROOT/audio_titles.sh" "$T/m1.mkv" "$T/m2.mkv" > "$T/multi.log" 2>&1
eq    "both files named"                       "$(atitles "$T/m1.mkv")|$(atitles "$T/m2.mkv")" "$WANT|$WANT"
check "summary counts both"                    "grep -q 'Renamed:          2' '$T/multi.log'"

# ------------------------------------------------------------
echo
echo "== 9 / 10 verify.sh"
H="$T/home"
mkdir -p "$H/compress/in" "$H/compress/out"
cp -r "$SRC_WORK" "$H/compress/work"; rm -rf "$H/compress/work/tests"
cp "$ROOT/verify.sh" "$H/compress/"
cp "$F" "$H/compress/out/V.mkv"
printf '2\n1\n' | HOME="$H" bash "$H/compress/verify.sh" > "$T/verify.log" 2>&1
check "9: Verify leaves the file unchanged"     "cmp -s '$F' '$H/compress/out/V.mkv'"
check "9: Verify reports the planned names"     "grep -q -- '-> \"Japanese | AC-3 | 5.1 | 640 kbps\"' '$T/verify.log' && grep -q 'Verify does not modify files' '$T/verify.log'"
check "9: Verify shows the unparsed warning"    "grep -q 'WARNING: description \"Nolan\" not recognised' '$T/verify.log'"
printf '2\n2\n' | HOME="$H" bash "$H/compress/verify.sh" > "$T/validate.log" 2>&1
# Validate + update also refreshes the statistics (its own design): the
# variable-rate tracks then carry a measured rate, the rest is identical
VT=$(atitles "$H/compress/out/V.mkv")
check "10: Validate + update wrote the names"   "grep -q 'Track titles *UPDATED' '$T/validate.log'"
eq    "10: same names as audio_titles.sh (rates of VBR tracks aside)" "$(sed -E 's/ \| [0-9]+ kbps//g' <<< "$VT")" "$(sed -E 's/ \| [0-9]+ kbps//g' <<< "$WANT")"
check "10: unparsed title kept by Validate + update" "[[ '$VT' == */Nolan/* ]]"
# the same file through audio_titles.sh now (statistics stored): identical
cp "$H/compress/out/V.mkv" "$T/v2.mkv"
bash "$ROOT/audio_titles.sh" --dry-run "$T/v2.mkv" > "$T/v2.log" 2>&1
check "10: audio_titles.sh agrees with Validate + update" "grep -q 'Nothing to change' '$T/v2.log'"

echo
echo "== 10 finished compression job: item_finalize_titles (no encode: the fixture stands in for the job's output)"
source "$SRC_WORK/lib/hdr_dovi.sh" > /dev/null; source "$SRC_WORK/lib/job_runtime.sh" > /dev/null
declare -gA ITEM_EXP=([video]=copy [atrans]= [amap]=0:0,1:1,2:2,3:3,4:4)
ITEM_OUTPUT="$T/job.mkv"; ITEM_PART="$T/job.mkv.part"; ITEM_LOG="$T/job_item.log"; : > "$ITEM_LOG"
cp "$F" "$ITEM_PART"
item_finalize_titles > "$T/job.log" 2>&1
eq    "10: job titles = Validate + update titles (same streams, same rates)" "$(atitles "$ITEM_PART")" "$VT"
check "10: job warns about the unparsed title"  "grep -q 'WARNING: audio stream 3 \"Nolan\": description \"Nolan\" not recognised' '$T/job.log'"
eq    "10: job finalized"                       "$ITEM_TITLES_STATE" "final"

echo
echo "PASS $PASS  FAIL $FAIL"
exit $(( FAIL > 0 ))
