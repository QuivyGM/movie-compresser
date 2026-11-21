#!/usr/bin/env bash
# verify.sh report layout (real media, real ffprobe):
#
#   1. path scope: Location from the path (in/ or out/), no Location
#      prompt; Mode asked unless --verify / --update; invalid paths
#   2. season header, Common / Differs (with episode ranges), one line per
#      episode with a note only where it differs, total line
#   3. titles only: counted on the Titles line, status OK, no detail
#   4. detail block only for a real problem (missing statistics,
#      unpaired), every file with COMPRESS_VERBOSE=1; no whitespace-only
#      lines, no progress line in redirected output
#   5. --brief: one line per season
#   6. at most 120 columns (summary lines; long show / season names)
#   7. Validate + update: what was written per episode and per season
#
#   bash ~/compress/work/tests/verify_summary_tests.sh
#
# Needs ffmpeg with libx265 and MKVToolNix (mkvpropedit); skipped
# (reported) without them.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${VERIFY_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE NO_COLOR

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null ||
   [[ "$(ffmpeg -hide_banner -encoders 2>/dev/null)" != *libx265* ]] ||
   ! command -v mkvpropedit >/dev/null; then
    echo "skipped: verify_summary_tests.sh (needs ffmpeg with libx265 and mkvpropedit)"
    echo
    echo "passed: $PASS  failed: $FAIL"
    exit 0
fi

source "$SRC_WORK/lib/inspect.sh"

H="$T/home"
CB="$H/compress"
IN="$CB/in"
OUT="$CB/out"
mkdir -p "$IN" "$OUT" "$CB/work"
cp -r "$SRC_WORK/lib" "$CB/work/"
cp "$ROOT/verify.sh" "$CB/"

# ------------------------------------------------------------
# Fixtures (2 s): x264 sources, x265 CRF 21 outputs
# ------------------------------------------------------------

F="$T/fx"
mkdir -p "$F"
ffmpeg -v error -nostdin -y -f lavfi -i testsrc2=s=320x180:d=2:r=24 -c:v libx264 -qp 0 -pix_fmt yuv420p "$F/src.mkv"
enc() {   # NAME SIZE
    ffmpeg -v error -nostdin -y -i "$F/src.mkv" -vf "scale=$2" -c:v libx265 -crf 21 -preset ultrafast \
        -x265-params log-level=error -pix_fmt yuv420p10le \
        -metadata COMPRESSION_CRF=21 -metadata COMPRESSION_TIER=High "$F/$1.mkv"
    mkvpropedit -q "$F/$1.mkv" --edit track:v1 --set "name=$(video_std_title_of "$F/$1.mkv" 0 auto)"
}
enc full 320x180
enc small 256x144
cp "$F/full.mkv" "$F/nostats.mkv"
cp "$F/full.mkv" "$F/badtitle.mkv"
mkvpropedit -q "$F/badtitle.mkv" --edit track:v1 --set "name=Fixture.2160p.BluRay.REMUX-GRP"
for n in full small badtitle; do refresh_mkv_stats "$F/$n.mkv" > /dev/null 2>&1; done

put() { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; }
C="Columbo (1968)"
for e in 1 2 3 4; do put "$F/src.mkv" "$IN/$C/Season 01/Columbo S01E0$e.mkv"; done
put "$F/src.mkv" "$IN/$C/Season 02/Columbo S02E01.mkv"
O1="$OUT/$C/Season 01"
put "$F/full.mkv"     "$O1/Columbo S01E01 HEVC High.mkv"
put "$F/badtitle.mkv" "$O1/Columbo S01E02 HEVC High.mkv"       # titles only
put "$F/full.mkv"     "$O1/Columbo S01E03 HEVC High.mkv"
put "$F/small.mkv"    "$O1/Columbo S01E04 HEVC High.mkv"       # other resolution
put "$F/nostats.mkv"  "$OUT/$C/Season 02/Columbo S02E01 HEVC High.mkv"   # statistics missing
put "$F/full.mkv"     "$OUT/$C/Season 02/Columbo S02E07 HEVC High.mkv"   # no source
LONG="A Show With A Very Long Name That Goes On And On Well Past Any Reasonable Width For A Terminal Line Of Output In Any Shell (2001)"
LS="Season 01 - The Season With The Longest Folder Name Anyone Has Ever Given To A Season Folder"
put "$F/full.mkv" "$OUT/$LONG/$LS/Long S01E01 HEVC High.mkv"

# vr LOG [ARGS...]  ->  verify.sh run, stdin from VIN (exit code in LOG.rc)
vr() {
    local log="$1"
    shift
    printf "${VIN:-}" | (cd "$H" && HOME="$H" timeout 300 bash "$CB/verify.sh" "$@") > "$log" 2>&1
    echo $? > "$log.rc"
}
rc() { cat "$1.rc"; }
# summary lines: everything but the detail blocks (indented by 4+)
summ() { grep -v '^    ' "$1"; }

# ------------------------------------------------------------
echo "== 1 path scope"
VIN='1\n' vr "$T/p1.log" "out/$C"
check "1 Location from the path: no Location prompt" "! grep -q 'Location:' '$T/p1.log'"
check "1 Mode still asked without --verify / --update" "grep -qx '1) Verify' '$T/p1.log'"
check "1 scope header"                       "grep -qx 'Verify: out/$C' '$T/p1.log'"
vr "$T/p2.log" --verify "$O1"
check "1 --verify: no prompt at all"        "! grep -q 'Select' '$T/p2.log' && grep -qx 'Verify: out/$C/Season 01' '$T/p2.log'"
check "1 absolute season path: that season only" "grep -q '^-- Season 01: 4 episodes' '$T/p2.log' && ! grep -q '^-- Season 02' '$T/p2.log'"
vr "$T/p3.log" --verify "$C/Season 01/Columbo S01E03 HEVC High.mkv"
check "1 file relative to out/"             "grep -qx 'Verify: out/$C/Season 01/Columbo S01E03 HEVC High.mkv' '$T/p3.log' && grep -q '^-- Season 01: 1 episode' '$T/p3.log'"
vr "$T/p4.log" --verify "in/$C"
check "1 in/ path: Location IN"             "grep -qx 'Verify: in/$C' '$T/p4.log' && grep -q '^-- Season 01: 4 episodes' '$T/p4.log'"
vr "$T/e1.log" --verify "No Such Show"
eq    "1 missing path: exit 1"              "$(rc "$T/e1.log")" 1
check "1 missing path: clear error"         "grep -q '^verify.sh: No Such Show: not found' '$T/e1.log'"
vr "$T/e2.log" --verify "$C"
eq    "1 path in both in/ and out/: exit 1" "$(rc "$T/e2.log")" 1
check "1 path in both: clear error"         "grep -q 'found in both in/ and out/' '$T/e2.log'"
vr "$T/e3.log" --verify "$T/fx"
eq    "1 outside in/ and out/: exit 1"      "$(rc "$T/e3.log")" 1
check "1 outside: clear error"              "grep -q 'not inside' '$T/e3.log'"
vr "$T/e4.log" --verify --update "$O1"
eq    "1 --verify with --update: exit 1"    "$(rc "$T/e4.log")" 1
vr "$T/e5.log" --bogus
eq    "1 unknown option: exit 1"            "$(rc "$T/e5.log")" 1

# ------------------------------------------------------------
echo
echo "== 2 season header, Common / Differs, episode lines"
vr "$T/v.log" --verify "out/$C"
S="$T/v.sum"
summ "$T/v.log" > "$S"
check "2 season header: episodes, video, audio" "grep -qE '^-- Season 01: 4 episodes, video [0-9.]+ GiB, audio [0-9.]+ GiB\$' '$S'"
check "2 Common: shared values"             "grep -E '^   Common:  ' '$S' | head -n1 | grep -q 'video hevc Main 10, 10-bit; SDR.*; x265 CRF 21; audio none'"
check "2 Common: resolution left out when it differs" "! grep -A1 '^-- Season 01' '$S' | grep '^   Common' | grep -q '320x180'"
check "2 Differs: values with episode ranges" "grep -qx '   Differs: resolution 320x180 (E01-E03), 256x144 (E04)' '$S'"
check "2 episode line: label, duration, size, Mb/s, status" "grep -qE '^  S01E01  00:00:02 +[0-9.]+ GiB +[0-9.]+ Mb/s  OK\$' '$S'"
check "2 note only where an episode differs" "grep -qE '^  S01E04  .*  OK  resolution 256x144\$' '$S' && ! grep -E '^  S01E03 ' '$S' | grep -q resolution"
check "2 season with one resolution: no Differs" "! sed -n '/^-- Season 02/,\$p' '$S' | grep -q Differs"
check "2 total line"                         "grep -qx 'Total: 1 show, 2 seasons, 6 files; problems: 2 (1 CHECK REQUIRED, 1 UNPAIRED); titles to correct: 1' '$S'"

# ------------------------------------------------------------
echo
echo "== 3 titles only"
check "3 Titles line of the season"         "grep -qx '   Titles:  to correct on 1 of 4 episodes: video title stale (1)' '$S'"
check "3 titles only: status OK, not CHECK REQUIRED" "grep -qE '^  S01E02  .*  OK\$' '$S'"
check "3 titles only: no detail block"      "! grep -q '^    $C/Season 01/Columbo S01E02 HEVC High.mkv\$' '$T/v.log'"

# ------------------------------------------------------------
echo
echo "== 4 detail blocks"
check "4 missing statistics: CHECK REQUIRED + detail" \
    "grep -qE '^  S02E01  .*  CHECK REQUIRED\$' '$S' && grep -q '^    $C/Season 02/Columbo S02E01 HEVC High.mkv\$' '$T/v.log' && grep -q '^      Statistics tags missing or rejected' '$T/v.log'"
check "4 unpaired: UNPAIRED + detail"        "grep -qE '^  S02E07  .*  UNPAIRED\$' '$S' && grep -q '^      Source               not found in IN' '$T/v.log'"
check "4 no detail for a file without problems" "! grep -q '^    $C/Season 01/Columbo S01E01 HEVC High.mkv\$' '$T/v.log'"
eq    "4 detail blocks: exactly the 2 problems" "$(grep -c '^    ======' "$T/v.log")" 4
check "4 no whitespace-only lines"           "! grep -qE '^[[:space:]]+\$' '$T/v.log'"
check "4 no progress line when redirected"   "! grep -q \$'\\r' '$T/v.log' && ! grep -q 'Checking ' '$T/v.log'"
COMPRESS_VERBOSE=1 vr "$T/vv.log" --verify "out/$C"
check "4 COMPRESS_VERBOSE=1: detail for every file" "[[ \$(grep -c '^    ======' '$T/vv.log') == 12 ]] && grep -q '^    $C/Season 01/Columbo S01E01 HEVC High.mkv\$' '$T/vv.log'"

# ------------------------------------------------------------
echo
echo "== 5 --brief"
vr "$T/b.log" --verify --brief "out/$C"
check "5 one line per season"               "[[ \$(grep -c '^  $C / ' '$T/b.log') == 2 ]] && ! grep -qE '^  S0[12]E' '$T/b.log' && ! grep -q 'Common:' '$T/b.log'"
check "5 counts, titles, differs keywords"  "grep -qx '  $C / Season 01: 4 eps, video [0-9.]* GiB, 4 OK, titles 1, differs: resolution' '$T/b.log'"
check "5 problem counts"                    "grep -qx '  $C / Season 02: 2 eps, video [0-9.]* GiB, 0 OK, 1 UNPAIRED, 1 CHECK REQUIRED' '$T/b.log'"
check "5 no detail blocks"                  "! grep -q '^    ' '$T/b.log'"
check "5 total line"                        "grep -q '^Total: 1 show, 2 seasons, 6 files;' '$T/b.log'"

# ------------------------------------------------------------
echo
echo "== 6 at most 120 columns"
vr "$T/all.log" --verify out
vr "$T/allb.log" --verify --brief out
eq    "6 default view"                      "$(summ "$T/all.log" | awk 'length > 120' | wc -l)" 0
eq    "6 --brief"                           "$(awk 'length > 120' "$T/allb.log" | wc -l)" 0
check "6 long names shortened, counts kept"  "grep -qE '^-- Season 01 - The Season With The Longest.*~: 1 episode, video [0-9.]+ GiB, audio [0-9.]+ GiB\$' '$T/all.log' && grep -qE '^== A Show With A Very Long Name.*~\$' '$T/all.log'"
check "6 --brief: long name shortened, counts kept" "grep -qE '^  A Show With A Very Long Name.*~: 1 ep, video [0-9.]+ GiB, 0 OK, 1 UNPAIRED\$' '$T/allb.log'"

# ------------------------------------------------------------
echo
echo "== 7 Validate + update"
vr "$T/u.log" --update "out/$C"
U="$T/u.sum"
summ "$T/u.log" > "$U"
check "7 header"                            "grep -qx 'Validate + update: out/$C' '$U'"
check "7 per episode: what was written"     "grep -qE '^  S01E02  .*  OK \\(wrote: stats, 1 title\\)\$' '$U' && grep -qE '^  S01E01  .*  OK \\(wrote: stats\\)\$' '$U'"
check "7 missing statistics written: now OK" "grep -qE '^  S02E01  .*  OK \\(wrote: stats\\)\$' '$U'"
check "7 Titles line: corrected"            "grep -qx '   Titles:  corrected on 1 of 4 episodes (1 title)' '$U'"
check "7 Written line per season"           "grep -q '^   Written: statistics 4 of 4, titles 1, CRF tags 0' '$U'"
check "7 total Written line"                "grep -q '^Written: statistics 6, titles 1 file (1 title), CRF tags 0;' '$U'"
eq    "7 at most 120 columns"               "$(awk 'length > 120' "$U" | wc -l)" 0
vr "$T/v2.log" --verify "out/$C"
check "7 Verify afterwards: titles and statistics fixed" \
    "grep -qx 'Total: 1 show, 2 seasons, 6 files; problems: 1 (0 CHECK REQUIRED, 1 UNPAIRED); titles to correct: 0' '$T/v2.log'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
