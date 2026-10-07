#!/usr/bin/env bash
# MKV statistics: metadata-first loading and the refresh after a scan.
#
#   bash ~/compress/work/tests/stats_refresh_tests.sh
#
# Needs ffmpeg / ffprobe and mkvtoolnix. Short synthetic files only.
# Covers the refresh loop seen on real remuxes: tracks stored with
# Matroska content compression (zlib: mkvmerge's default for PGS /
# VobSub subtitles) count their decompressed frames, in packet scans and
# in NUMBER_OF_BYTES alike, so correct statistics can add up to more
# than the file size. Such statistics must be accepted (and reused),
# while stale or wrong ones are still rejected.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${STATS_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

for t in ffmpeg ffprobe mkvmerge mkvpropedit; do
    command -v "$t" >/dev/null || { echo "$t not found: skipped"; exit 0; }
done
unset COMPRESS_VERBOSE

WORK_DIR="$T/work"
mkdir -p "$WORK_DIR" "$T/f"
for l in ui media_probe media_stats bitrate; do
    source "$SRC_WORK/lib/$l.sh" > /dev/null
done

# count packet scans and mkvpropedit runs
eval "$(declare -f stream_packet_bytes | sed '1s/stream_packet_bytes/_real_stream_packet_bytes/')"
stream_packet_bytes() { echo scan >> "$T/scans"; _real_stream_packet_bytes "$@"; }
printf '#!/usr/bin/env bash\necho x >> %q\nexec mkvpropedit "$@"\n' "$T/mpe" > "$T/mkvpe"
chmod +x "$T/mkvpe"
counts() { echo "$(wc -l < "$T/scans" 2>/dev/null || echo 0)/$(wc -l < "$T/mpe" 2>/dev/null || echo 0)" | tr -d ' '; }
load() {   # FILE [MODE]  ->  stats_load ... refresh, progress in $T/out
    : > "$T/scans"; : > "$T/mpe"
    STATS_MKVPROPEDIT="$T/mkvpe" STATS_PROGRESS=1 stats_load "$1" "" "${2:-exact}" refresh > "$T/out" 2>&1
}
pk() { _real_stream_packet_bytes "$1" | awk -v s="$2" '$1 == s { print $2 }'; }
tags() { ffprobe -v error -show_entries stream=index:stream_tags=NUMBER_OF_BYTES -of csv=p=0 "$1" | tr '\n' ' '; }

F="$T/f"
ffmpeg -v error -y -f lavfi -i "color=c=gray:s=640x360:r=24:d=4" -f lavfi -i "sine=f=440:r=48000:d=4" \
    -c:v libx264 -preset ultrafast -qp 0 -c:a ac3 -b:a 192k "$F/base.mkv"
awk 'BEGIN { for (i = 0; i < 40; i++) {
    printf "%d\n00:00:%02d,%03d --> 00:00:%02d,%03d\n", i + 1, int(i / 10), (i % 10) * 100, int(i / 10), (i % 10) * 100 + 90
    for (k = 0; k < 6; k++) printf "the same compressible subtitle line %d again and again\n", k
    print "" } }' > "$F/s.srt"
ZLIB=(--compression 0:zlib --compression 1:zlib "$F/base.mkv" --compression 0:zlib "$F/s.srt")
mkvmerge -q -o "$F/zlib_tagged.mkv" "${ZLIB[@]}"
mkvmerge -q -o "$F/zlib_fresh.mkv" --disable-track-statistics-tags "${ZLIB[@]}"
mkvmerge -q -o "$F/plain_tagged.mkv" "$F/base.mkv" "$F/s.srt"
cp "$F/base.mkv" "$F/plain_fresh.mkv"     # ffmpeg-made: no statistics tags

# ------------------------------------------------------------
echo "== the reproduced case: zlib-compressed tracks"

fsize=$(file_bytes "$F/zlib_tagged.mkv")
sum=$(_real_stream_packet_bytes "$F/zlib_tagged.mkv" | awk '{ s += $2 } END { print s }')
check "repro: correct statistics exceed the file size" "(( sum > fsize ))"
eq    "repro: tags = packet scan per stream"   "$(tags "$F/zlib_tagged.mkv")" "0,$(pk "$F/zlib_tagged.mkv" 0) 1,$(pk "$F/zlib_tagged.mkv" 1) 2,$(pk "$F/zlib_tagged.mkv" 2) "
eq    "compressed tracks found"                 "$(_stats_compressed_tracks "$F/zlib_tagged.mkv" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')" "0 1 2 "
eq    "uncompressed file: none"                 "$(_stats_compressed_tracks "$F/plain_tagged.mkv")" " "

load "$F/zlib_tagged.mkv"
eq    "5 per-stream match, sum > file: accepted, no scan" "$(counts) $STATS_KIND" "0/0 tags"
eq    "5 values = packet scan"                  "$(stats_field 0 bytes) $(stats_field 2 bytes)" "$(pk "$F/zlib_tagged.mkv" 0) $(pk "$F/zlib_tagged.mkv" 2)"

# ------------------------------------------------------------
echo
echo "== 1 / 6 fresh files: one scan + refresh, then cached"

for f in zlib_fresh plain_fresh; do
    load "$F/$f.mkv"
    eq    "1 $f: run 1 scans once, refreshes once" "$(counts) $STATS_KIND $STATS_REFRESH" "1/1 packets refreshed"
    check "1 $f: re-read MATCH"                    "grep -q 'Metadata-first re-read: MATCH' '$T/out'"
    eq    "1 $f: written tags = scan"              "$(tags "$F/$f.mkv")" "0,$(pk "$F/$f.mkv" 0) 1,$(pk "$F/$f.mkv" 1)$( [[ $f == zlib_fresh ]] && echo " 2,$(pk "$F/$f.mkv" 2)") "
    load "$F/$f.mkv"
    eq    "6 $f: run 2 from tags"                  "$(counts) $STATS_KIND" "0/0 tags"
    load "$F/$f.mkv"
    eq    "6 $f: run 3 from tags"                  "$(counts) $STATS_KIND" "0/0 tags"
done

# ------------------------------------------------------------
echo
echo "== 2 / 3 / 4 valid, stale and wrong statistics"

load "$F/plain_tagged.mkv"
eq    "2 valid mkvmerge statistics: no scan"   "$(counts) $STATS_KIND" "0/0 tags"

# 3 statistics copied onto a re-encoded (smaller) video stream
ffmpeg -v error -y -i "$F/plain_tagged.mkv" -map 0 -c copy -c:v:0 libx264 -crf 40 "$F/stale.mkv"
check "3 re-encode kept the old tags"          "[[ \$(ffprobe -v error -select_streams 0 -show_entries stream_tags=NUMBER_OF_BYTES -of csv=p=0 '$F/stale.mkv') == $(pk "$F/plain_tagged.mkv" 0) ]]"
load "$F/stale.mkv"
check "3 stale: rejected, scanned, refreshed"  "[[ '$(counts)' == 1/1 && '$STATS_REJECTED' == *stale* && '$STATS_REFRESH' == refreshed ]]"
eq    "3 scan value used"                      "$(stats_field 0 bytes)" "$(pk "$F/stale.mkv" 0)"
load "$F/stale.mkv"
eq    "3 next run from the refreshed tags"     "$(counts) $STATS_KIND" "0/0 tags"

# 4 one stream's NUMBER_OF_BYTES wrong (BPS made consistent with it)
v=$(pk "$F/plain_tagged.mkv" 0)
ffmpeg -v error -y -i "$F/plain_tagged.mkv" -map 0 -c copy \
    -metadata:s:0 "NUMBER_OF_BYTES=$((v * 2))" -metadata:s:0 "BPS=$((v * 2 * 8 / 4))" \
    -metadata:s:0 "DURATION=00:00:04.000000000" "$F/wrong.mkv"
cp "$F/wrong.mkv" "$F/wrong_diag.mkv"     # (wrong.mkv gets refreshed below)
load "$F/wrong.mkv"
check "4 wrong stream: rejected, scanned"      "[[ '$(counts)' == 1/1 && -n '$STATS_REJECTED' ]]"
eq    "4 scan value used"                      "$(stats_field 0 bytes)" "$(pk "$F/wrong.mkv" 0)"

# 4 after a refresh, a stream that does not equal the scan is refused
STATS_LINES=$(_stats_from_packets "$(_stats_probe "$F/plain_tagged.mkv")" "$(_real_stream_packet_bytes "$F/plain_tagged.mkv")" 4)
eq    "4 re-read = scan: accepted"             "$(_stats_match_scan "$(_stats_probe "$F/plain_tagged.mkv")" 4)" ""
STATS_LINES=$(sed '2s/^\(1 [a-z]* [0-9]\) [0-9]*/\1 12345/' <<< "$STATS_LINES")
eq    "4 re-read != scan for one stream: refused" "$(_stats_match_scan "$(_stats_probe "$F/plain_tagged.mkv")" 4)" \
    "stream 1 (audio): NUMBER_OF_BYTES $(pk "$F/plain_tagged.mkv" 1), scan 12345 bytes"

# ------------------------------------------------------------
echo
echo "== verbose diagnostics"

out=$(COMPRESS_VERBOSE=1 STATS_PROGRESS=1 STATS_MKVPROPEDIT=/nonexistent stats_load "$F/wrong_diag.mkv" "" exact refresh 2>&1)
check "diag: reason, file size, per-stream, sum" \
    "grep -q 'MKV statistics check: stored statistics rejected:' <<< \"\$out\" && grep -q 'file size:  $(file_bytes "$F/wrong_diag.mkv") bytes' <<< \"\$out\" && grep -qE '^  0 +video +$v +$((v * 2))' <<< \"\$out\" && grep -q 'stored sum: ' <<< \"\$out\""
out=$(STATS_PROGRESS=1 STATS_MKVPROPEDIT=/nonexistent stats_load "$F/wrong_diag.mkv" "" exact refresh 2>&1)
check "diag: not shown without COMPRESS_VERBOSE" "! grep -q 'MKV statistics check' <<< \"\$out\""

# ------------------------------------------------------------
echo
echo "== 8 safeguards unchanged"

cp "$F/zlib_fresh.mkv" "$F/ro.mkv"   # (zlib_fresh now has tags: strip them)
mkvpropedit -q "$F/ro.mkv" --delete-track-statistics-tags
chmod 444 "$F/ro.mkv"; m=$(md5sum < "$F/ro.mkv")
load "$F/ro.mkv"
check "8 read-only: scan, not refreshed, untouched" "[[ '$(counts)' == 1/0 && '$STATS_REFRESH' == 'skipped: source is not writable' && \$(md5sum < '$F/ro.mkv') == '$m' ]]"
cp "$F/ro.mkv" "$F/target.mkv"; chmod 644 "$F/target.mkv"; ln -s target.mkv "$F/link.mkv"; m=$(md5sum < "$F/target.mkv")
load "$F/link.mkv"
check "8 symlink: scan, not refreshed, untouched"   "[[ '$(counts)' == 1/0 && '$STATS_REFRESH' == 'skipped: source is a symlink' && \$(md5sum < '$F/target.mkv') == '$m' ]]"
printf 'version=1\nsession=ajx1\nstatus=running\ninput=%s\n' "$F/target.mkv" > "$WORK_DIR/ajx1.state"
mkdir -p "$T/live"   # tmux: the job's session exists
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/live/tmux"; chmod +x "$T/live/tmux"
PATH="$T/live:$PATH" load "$F/target.mkv"
check "8 active job: not refreshed"                "[[ '$STATS_REFRESH' == 'skipped: source is in use by an active compression job (ajx1)' && \$(md5sum < '$F/target.mkv') == '$m' ]]"
rm -f "$WORK_DIR/ajx1.state"

# ------------------------------------------------------------
echo
echo "== 6 / 7 repeated menu runs (movie and series)"

H="$T/home"
mkdir -p "$H/compress/in/Show" "$H/compress/out" "$T/stub"
cp -r "$SRC_WORK" "$H/compress/work"
rm -rf "$H/compress/work/tests" "$H/compress/work/logs" "$H/compress/work/cache"
rm -f "$H/compress/work"/[a-z]*[0-9].sh "$H/compress/work"/*.state
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
mkvmerge -q -o "$H/compress/in/Film.mkv" --disable-track-statistics-tags "${ZLIB[@]}"
for e in 1 2; do
    mkvmerge -q -o "$H/compress/in/Show/Show.S01E0$e.mkv" --disable-track-statistics-tags "${ZLIB[@]}"
done
menu() {   # SCRIPT INPUT LOG
    printf "$2" | HOME="$H" PATH="$T/stub:$PATH" COMPRESS_CONF="$H/compress/work/lib/compress.conf" \
        bash "$H/compress/work/$1" > "$3" 2>&1
    rm -f "$H/compress/work"/c[0-9]*.sh
}
for r in 1 2 3; do
    menu movie_compress.sh "1\n2\nn\n" "$T/movie$r.log"
    menu series_compress.sh "1\n2\nn\n" "$T/series$r.log"
done
check "7 movie run 1: scanned + refreshed"   "grep -q '^Analyzing source... OK    Source stats: scanned + refreshed\$' '$T/movie1.log'"
check "7 movie runs 2, 3: cached"            "grep -q 'Source stats: cached\$' '$T/movie2.log' && grep -q 'Source stats: cached\$' '$T/movie3.log'"
check "7 series run 1: scanned + refreshed"  "grep -q '^Analyzing 2 episodes... OK    Source stats: scanned + refreshed    Compatibility: OK\$' '$T/series1.log'"
check "7 series runs 2, 3: cached"           "grep -q 'Source stats: cached    Compatibility' '$T/series2.log' && grep -q 'Source stats: cached    Compatibility' '$T/series3.log'"
check "no 'Stats not refreshed' warning"     "! grep -q 'Stats not refreshed' '$T'/movie?.log '$T'/series?.log"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
