#!/usr/bin/env bash
# results.sh: read-only summary of the outputs in out/.
#
#   1. last-job scope: compression ledger (earlier versions), provenance
#      journal / spool (one job per log folder, session names reused),
#      running / interrupted jobs skipped, failed jobs, recorded outputs
#      no longer in out/
#   2. no job record: all of out/
#   3. path scope: show / season / file, relative to out/, absolute, from
#      the current folder; --all
#   4. invalid arguments: missing path, outside out/, "..", file that is
#      not media, --all with a path, unknown option (exit 1, clear error)
#   5. summary numbers: saved %, season / show totals, GiB per episode,
#      CRF range, tiers; COMPRESS_VERBOSE=1 episode rows
#   6. issues: unpaired output (size shown, saved % "-"), missing
#      compression tags, missing statistics, CRF tag vs job record, kept
#      verify-failed encode; titles only: counted, not an issue
#   7. read-only: every file in in/ / out/ / work/ unchanged (content,
#      mtime), no file added or removed
#   8. over target: an output the job kept above its video ceiling
#      (provenance flag over_ceiling) shows "over target" in the status
#   0. (no media tools needed) the over-target job records
#      (_over_records: journal flags, spool events) and the status text
#
#   bash ~/compress/work/tests/results_tests.sh
#
# Needs ffmpeg with libx265 and MKVToolNix (mkvpropedit): real media
# files, real ffprobe. Skipped (reported) without them.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${RESULTS_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE NO_COLOR

# ------------------------------------------------------------
echo "== 0 over-target records and status (results.sh functions)"
(
    LOGS="$T/r0/logs"
    mkdir -p "$LOGS/provenance/spool/e1" "$LOGS/provenance/spool/e2"
    source "$SRC_WORK/lib/ui.sh"
    eval "$(sed -n '/^_over_records() {/,/^}/p; /^status_text() {/,/^}/p' "$ROOT/results.sh")"
    python3 -c 'import json
for o, fl, vb in (("/o/A.mkv", ["over_ceiling"], 123), ("/o/B.mkv", [], 5), ("/o/C.mkv", ["below_floor"], None)):
    op = {"flags": fl} if fl else {}
    if vb: op["output_video_bytes"] = vb
    print(json.dumps({"entry": "output", "op": op, "file": {"path": o}}))
print(json.dumps({"entry": "source", "file": {"path": "/i/x.mkv"}}))' > "$LOGS/provenance/journal.jsonl"
    printf '%s\t%s\n' output /o/D.mkv over_ceiling 1 final_video_bytes 77 > "$LOGS/provenance/spool/e1/event.tsv"
    printf '%s\t%s\n' output /o/B.mkv over_ceiling 1 > "$LOGS/provenance/spool/e2/event.tsv"
    eq "0 records: journal flag, spool event (no video bytes: -), later record of B" \
        "$(_over_records | tr '\t\n' ' |')" "/o/A.mkv 123 1|/o/B.mkv 5 0|/o/C.mkv - 0|/o/D.mkv 77 1|/o/B.mkv - 1|"
    eq "0 status: OK / issues / over target" \
        "$(status_text 0)|$(status_text 2)|$(status_text 0 2)|$(status_text 0 1 1)|$(status_text 1 3)" \
        "OK|2 issues|over target (2)|over target|1 issue, over target (3)"
    echo "$PASS $FAIL" > "$T/r0.counts"
)
read -r PASS FAIL < "$T/r0.counts"

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null ||
   [[ "$(ffmpeg -hide_banner -encoders 2>/dev/null)" != *libx265* ]] ||
   ! command -v mkvpropedit >/dev/null; then
    echo "skipped: results_tests.sh (needs ffmpeg with libx265 and mkvpropedit)"
    echo
    echo "passed: $PASS  failed: $FAIL"
    exit 0
fi

source "$SRC_WORK/lib/inspect.sh"

H="$T/home"
CB="$H/compress"
IN="$CB/in"
OUT="$CB/out"
LOGS="$CB/work/logs"
mkdir -p "$IN" "$OUT" "$LOGS"
cp -r "$SRC_WORK/lib" "$CB/work/"
cp "$ROOT/results.sh" "$CB/"

# ------------------------------------------------------------
# Fixtures: x264 sources, x265 CRF outputs (2 s, 320x180)
# ------------------------------------------------------------

F="$T/fx"
mkdir -p "$F"
ffmpeg -v error -nostdin -y -f lavfi -i testsrc2=s=320x180:d=2:r=24 \
    -c:v libx264 -qp 0 -pix_fmt yuv420p "$F/src.mkv"
# enc NAME [extra ffmpeg args]  ->  x265 CRF 21 encode of the source
enc() {
    local n="$1"
    shift
    ffmpeg -v error -nostdin -y -i "$F/src.mkv" -c:v libx265 -crf 21 -preset ultrafast \
        -x265-params log-level=error -pix_fmt yuv420p10le "$@" "$F/$n.mkv"
}
enc tagged -metadata COMPRESSION_CRF=21 -metadata COMPRESSION_TIER=High
enc untagged
# standard video title (what Validate + update would write), statistics tags
for n in tagged untagged; do
    mkvpropedit -q "$F/$n.mkv" --edit track:v1 --set "name=$(video_std_title_of "$F/$n.mkv" 0 auto)"
done
cp "$F/tagged.mkv" "$F/nostats.mkv"
cp "$F/tagged.mkv" "$F/badtitle.mkv"
mkvpropedit -q "$F/badtitle.mkv" --edit track:v1 --set "name=Fixture.2160p.BluRay.REMUX-GRP"
for n in tagged untagged badtitle; do
    refresh_mkv_stats "$F/$n.mkv" > /dev/null 2>&1
done

put()  { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; }
C="Columbo (1968)"
put "$F/src.mkv" "$IN/$C/Season 01/Columbo S01E01.mkv"
put "$F/src.mkv" "$IN/$C/Season 01/Columbo S01E02.mkv"
put "$F/src.mkv" "$IN/$C/Season 02/Columbo S02E01.mkv"
put "$F/src.mkv" "$IN/Other Show/Season 01/Other S01E01.mkv"
put "$F/src.mkv" "$IN/Movie A (2001).mkv"
put "$F/src.mkv" "$IN/Movie B (2002).mkv"

O1="$OUT/$C/Season 01"
put "$F/tagged.mkv"   "$O1/Columbo S01E01 HEVC High.mkv"          # clean
put "$F/badtitle.mkv" "$O1/Columbo S01E02 HEVC High.mkv"          # titles only
put "$F/tagged.mkv"   "$O1/Columbo S01E09 HEVC High.mkv"          # no source
put "$F/untagged.mkv" "$OUT/$C/Season 02/Columbo S02E01 HEVC High.mkv"   # tags missing
put "$F/tagged.mkv"   "$OUT/Other Show/Season 01/Other S01E01 HEVC High.mkv"
put "$F/tagged.mkv"   "$OUT/Movie A (2001) HEVC High.mkv"
put "$F/nostats.mkv"  "$OUT/Movie B (2002) HEVC High.mkv"         # statistics missing
printf 'x' > "$OUT/Other Show/Season 01/Other S01E02 HEVC High.mkv.verify-failed"

SRC=$(stat -c %s "$F/src.mkv")
TAGGED=$(stat -c %s "$F/tagged.mkv")
UNTAGGED=$(stat -c %s "$F/untagged.mkv")
BADT=$(stat -c %s "$F/badtitle.mkv")
gibs() { awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }
pct()  { awk -v s="$1" -v o="$2" 'BEGIN { printf "%.1f%%", (s - o) / s * 100 }'; }
VB=$(read -r v _ <<< "$(stored_tag_totals "$F/tagged.mkv" 0)"; echo "$v")

# rs LOG ARGS...  ->  results.sh run (exit code in LOG.rc)
rs() {
    local log="$1"
    shift
    (cd "${RS_CWD:-$H}" && HOME="$H" timeout 300 bash "$CB/results.sh" "$@" > "$log" 2>&1)
    echo $? > "$log.rc"
}
rc() { cat "$1.rc"; }

# snapshot [DIR...]  ->  path, size, mtime (ns), md5 of every file below
# compress/ (or below DIR... of it); the job records the test writes
# itself are compared per phase
snapshot() {
    (cd "$CB" && find "${@:-.}" -print0 | sort -z |
        xargs -0 stat -c '%n %F %s %.9Y' && find "${@:-.}" -type f -print0 | sort -z | xargs -0 md5sum)
}
snapshot in out results.sh work/lib > "$T/media.before"

# ------------------------------------------------------------
echo "== 2 no job record: all of out/"
rs "$T/nojob.log"
eq    "2 exit 0"                         "$(rc "$T/nojob.log")" 0
check "2 header names the fallback"      "head -n1 '$T/nojob.log' | grep -qx 'No finished job recorded: all of out/'"
check "2 every show and the movies"      "grep -qx 'Columbo (1968)' '$T/nojob.log' && grep -qx 'Other Show' '$T/nojob.log' && grep -qx 'Movies' '$T/nojob.log'"
check "2 no prompt, no errors"           "! grep -qiE 'select|\\[y/N\\]|command not found|unbound variable|syntax error' '$T/nojob.log'"

# ------------------------------------------------------------
echo
echo "== 1 last job"
L="$LOGS/compression_tags.tsv"
# Every record time is one instant (UTC below), written the way the job
# writes it: the ledger in local time (date '+%F %T'), the provenance
# journal / spool in UTC, job.state as an epoch. The order of the jobs is
# then the same in every timezone (TZ=UTC, TZ=Asia/Seoul, ...).
lt()  { date -d "$1" '+%F %T'; }       # ledger time of an instant
hm()  { date -d "$1" '+%F %H:%M'; }    # header time of an instant
snapshot > "$T/snap.nojob"
check "2 the run itself changed nothing"   "diff -q <(snapshot) '$T/snap.nojob' > /dev/null"
printf '%s\n' "$COMPRESSION_LEDGER_HEADER" > "$L"
printf '%s\t%s\t21\tHigh\t%s\tseries1\t%s\n' \
    "$(lt 2026-11-20T01:00:00Z)" "$O1/Columbo S01E01 HEVC High.mkv" "$VB" "$IN/$C/Season 01/Columbo S01E01.mkv" >> "$L"
printf '%s\t%s\t21\tHigh\t%s\tseries1\t%s\n' \
    "$(lt 2026-11-20T01:05:00Z)" "$O1/Columbo S01E02 HEVC High.mkv" "$VB" "$IN/$C/Season 01/Columbo S01E02.mkv" >> "$L"
printf '%s\t%s\t21\tHigh\t%s\tc1\t%s\n' \
    "$(lt 2026-11-21T00:30:00Z)" "$OUT/Movie A (2001) HEVC High.mkv" "$VB" "$IN/Movie A (2001).mkv" >> "$L"
rs "$T/job1.log"
check "1 ledger: header of the latest job"  "head -n1 '$T/job1.log' | grep -qx \"Last job: c1, finished \$(hm 2026-11-21T00:30:00Z)\""
check "1 ledger: only that job's output"    "grep -q '^  Movie A (2001) HEVC High.mkv ' '$T/job1.log' && ! grep -q 'Movie B' '$T/job1.log' && ! grep -q 'Columbo' '$T/job1.log'"

# provenance journal: series1 again (session name reused), a later job
J="$LOGS/provenance/journal.jsonl"
mkdir -p "$LOGS/provenance/spool"
jrec() {   # TIME SESSION LOG_DIR OUTPUT
    python3 -c 'import json, sys
t, s, l, o = sys.argv[1:5]
print(json.dumps({"entry": "output", "id": "x", "op": {"time": t, "recorded": t,
      "job": {"session": s, "type": "series", "log_dir": l}}, "file": {"path": o}}))' "$@" >> "$J"
}
jrec 2026-11-21T03:00:00Z series1 "$LOGS/series1-20261121-115500" "$OUT/$C/Season 02/Columbo S02E01 HEVC High.mkv"
jrec 2026-11-21T03:01:00Z series1 "$LOGS/series1-20261121-115500" "$OUT/$C/Season 02/Columbo S02E99 HEVC High.mkv"
rs "$T/job2.log"
check "1 journal: later job wins"           "head -n1 '$T/job2.log' | grep -qx \"Last job: series1, finished \$(hm 2026-11-21T03:01:00Z)\""
check "1 journal: same session name, only this run" "grep -qE '^  Season 02 ' '$T/job2.log' && ! grep -qE '^  Season 01 ' '$T/job2.log'"
check "1 recorded output no longer in out/ noted" "sed -n 2p '$T/job2.log' | grep -qx '(1 recorded output of this job no longer in out/)'"

# spool event (not merged yet) of a job that is still running: skipped
mkdir -p "$LOGS/provenance/spool/series2-x"
printf '%s\t%s\n' recorded 2026-11-21T05:00:00Z job_session series2 job_log_dir "$LOGS/series2-20261121-135900" \
    output "$OUT/Other Show/Season 01/Other S01E01 HEVC High.mkv" > "$LOGS/provenance/spool/series2-x/event.tsv"
printf '%s\n' version=1 session=series2 status=encoding started=1 updated=2 "log_dir=$LOGS/series2-20261121-135900" \
    > "$CB/work/series2.state"
rs "$T/job3.log"
check "1 running job skipped"               "head -n1 '$T/job3.log' | grep -q '^Last job: series1, '"
printf '%s\n' version=1 session=series2 status=interrupted started=1 updated=2 "log_dir=$LOGS/series2-20261121-135900" \
    > "$CB/work/series2.state"
rs "$T/job4.log"
check "1 interrupted job skipped"           "head -n1 '$T/job4.log' | grep -q '^Last job: series1, '"
rm -f "$CB/work/series2.state"
mkdir -p "$LOGS/series2-20261121-135900"
printf '%s\n' version=1 session=series2 status=failed ok=1 failed=1 started=1 \
    "updated=$(date -d 2026-11-21T05:10:00Z +%s)" "log_dir=$LOGS/series2-20261121-135900" \
    > "$LOGS/series2-20261121-135900/job.state"
rs "$T/job5.log"
check "1 spool event + failed job state"    "head -n1 '$T/job5.log' | grep -qx \"Last job: series2, finished \$(hm 2026-11-21T05:10:00Z) with 1 failed item\""
check "1 its output, kept verify-failed encode next to it" \
    "grep -qx 'Other Show' '$T/job5.log' && grep -q 'Other S01E02 HEVC High.mkv.verify-failed: verification mismatch' '$T/job5.log' && ! grep -q Columbo '$T/job5.log'"

# ------------------------------------------------------------
echo
echo "== 3 path scope, --all"
rs "$T/show.log" "$C"
check "3 show: header"                     "head -n1 '$T/show.log' | grep -qx 'out/Columbo (1968)'"
check "3 show: its seasons only"           "grep -qE '^  Season 01 ' '$T/show.log' && grep -qE '^  Season 02 ' '$T/show.log' && ! grep -q 'Other Show' '$T/show.log' && ! grep -qx Movies '$T/show.log'"
rs "$T/season.log" "$C/Season 01"
check "3 season: header"                   "head -n1 '$T/season.log' | grep -qx 'out/Columbo (1968)/Season 01'"
check "3 season: one season row + total"   "grep -qE '^  Season 01 +3 ' '$T/season.log' && ! grep -qE '^  Season 02 ' '$T/season.log' && grep -qE '^  Total +3 ' '$T/season.log'"
rs "$T/file.log" "$O1/Columbo S01E01 HEVC High.mkv"
check "3 file (absolute): header"          "head -n1 '$T/file.log' | grep -qx 'out/Columbo (1968)/Season 01/Columbo S01E01 HEVC High.mkv'"
check "3 file: one episode"                "grep -qE '^  Season 01 +1 +21 +High ' '$T/file.log'"
RS_CWD="$CB" rs "$T/cwd.log" "out/Movie A (2001) HEVC High.mkv"
check "3 relative to the current folder"   "head -n1 '$T/cwd.log' | grep -qx 'out/Movie A (2001) HEVC High.mkv' && grep -q '^  Movie A (2001) HEVC High.mkv ' '$T/cwd.log'"
rs "$T/all.log" --all
check "3 --all: header"                    "head -n1 '$T/all.log' | grep -qx 'All of out/'"
check "3 --all: shows and movies"          "grep -qx 'Columbo (1968)' '$T/all.log' && grep -qx 'Other Show' '$T/all.log' && grep -q '^  Movie B (2002) HEVC High.mkv ' '$T/all.log'"
check "3 --all: overall line"              "grep -qE '^Outputs: 7, ' '$T/all.log'"

# ------------------------------------------------------------
echo
echo "== 4 invalid arguments"
rs "$T/bad1.log" "No Such Show"
eq    "4 missing path: exit 1"             "$(rc "$T/bad1.log")" 1
check "4 missing path: clear error"        "grep -q '^results.sh: No Such Show: not found' '$T/bad1.log'"
rs "$T/bad2.log" "$IN/$C"
eq    "4 outside out/: exit 1"             "$(rc "$T/bad2.log")" 1
check "4 outside out/: clear error"        "grep -q 'not inside $OUT' '$T/bad2.log'"
rs "$T/bad3.log" "../in"
eq    "4 ../in: exit 1"                    "$(rc "$T/bad3.log")" 1
check "4 ../in: clear error"               "grep -q 'not inside' '$T/bad3.log'"
rs "$T/bad4.log" "Other Show/Season 01/Other S01E02 HEVC High.mkv.verify-failed"
eq    "4 not a media file: exit 1"         "$(rc "$T/bad4.log")" 1
rs "$T/bad5.log" --all "$C"
eq    "4 --all with a path: exit 1"        "$(rc "$T/bad5.log")" 1
rs "$T/bad6.log" --bogus
eq    "4 unknown option: exit 1"           "$(rc "$T/bad6.log")" 1
check "4 no summary printed on error"      "! grep -q 'Season' '$T/bad1.log' '$T/bad2.log' '$T/bad5.log'"

# ------------------------------------------------------------
echo
echo "== 5 summary numbers"
# Season 01: E01 + E02 paired, E09 unpaired
S1_OUT=$(( TAGGED + BADT + TAGGED ))
S1_SRC=$(( 2 * SRC ))
S1_SAVED=$(pct "$S1_SRC" $(( TAGGED + BADT )))
S1_AVG=$(awk -v b=$(( S1_OUT / 3 )) 'BEGIN { printf "%.2f", b / 1073741824 }')
check "5 season row: eps, CRF, tier, sizes, saved %, GiB/ep" \
    "grep -qE '^  Season 01 +3 +21 +High +$(gibs $S1_OUT) +$(gibs $S1_SRC) +${S1_SAVED//./\\.} +$S1_AVG +1 of 3 +1 issue\$' '$T/show.log'"
SH_OUT=$(( S1_OUT + UNTAGGED ))
SH_SRC=$(( 3 * SRC ))
SH_SAVED=$(pct "$SH_SRC" $(( TAGGED + BADT + UNTAGGED )))
check "5 show total row" \
    "grep -qE '^  Total +4 +21 +High +$(gibs $SH_OUT) +$(gibs $SH_SRC) +${SH_SAVED//./\\.} .* 2 issues\$' '$T/show.log'"
check "5 saved % is positive (lossless source)" "[[ '$S1_SAVED' != -* ]]"
check "5 movie row: tier, CRF, size, source, saved %" \
    "grep -qE '^  Movie A \\(2001\\) HEVC High\\.mkv +High +21 +$(gibs $TAGGED) +$(gibs $SRC) +$(pct $SRC $TAGGED | sed 's/\\./\\\\./') +OK\$' '$T/all.log'"
COMPRESS_VERBOSE=1 rs "$T/verbose.log" "$C"
check "5 COMPRESS_VERBOSE=1: episode rows under the season" \
    "grep -A3 -E '^  Season 01 ' '$T/verbose.log' | grep -qE '^    Columbo S01E01 HEVC High\\.mkv +21 +High +$(gibs $TAGGED) +$(gibs $SRC) '"
check "5 no episode rows by default"       "! grep -q '^    Columbo S01E01 HEVC High.mkv ' '$T/show.log'"

# ------------------------------------------------------------
echo
echo "== 6 issues"
check "6 unpaired output: size shown, saved % '-'" \
    "grep -qE '^    Columbo S01E09 HEVC High\\.mkv +21 +High +$(gibs $TAGGED) +- +- ' '$T/verbose.log'"
check "6 unpaired output listed"           "grep -qx '    Season 01/Columbo S01E09 HEVC High.mkv: unpaired output (no source found in in/)' '$T/show.log'"
check "6 missing compression tags listed"  "grep -qx '    Season 02/Columbo S02E01 HEVC High.mkv: compression tags missing: COMPRESSION_CRF, COMPRESSION_TIER' '$T/show.log'"
check "6 missing statistics listed"        "grep -q '^    Movie B (2002) HEVC High.mkv: verification mismatch: stored MKV statistics missing' '$T/all.log'"
check "6 kept verify-failed encode listed" "grep -q '^    Season 01/Other S01E02 HEVC High.mkv.verify-failed: verification mismatch' '$T/all.log'"
check "6 titles only: not an issue"        "! grep -q 'S01E02' <(sed -n '/Issues:/,\$p' '$T/show.log')"
rs "$T/titles.log" "$O1/Columbo S01E02 HEVC High.mkv"
check "6 titles only: counted, status OK"  "grep -qE '^  Season 01 +1 .* 1 of 1 +OK\$' '$T/titles.log' && ! grep -q 'Issues:' '$T/titles.log'"
check "6 clean episode: OK, titles OK"     "grep -qE '^  Season 01 +1 .* OK +OK\$' '$T/file.log'"
# a job record of this encode with another CRF: tag vs record mismatch
printf '%s\t%s\t25\tBase\t%s\tseries9\t%s\n' \
    "$(lt 2026-11-18T23:00:00Z)" "$OUT/Other Show/Season 01/Other S01E01 HEVC High.mkv" "$VB" "$IN/Other Show/Season 01/Other S01E01.mkv" >> "$L"
snapshot > "$T/snap.before"
rs "$T/rec.log" "Other Show"
rs "$T/rec_all.log" --all
rs "$T/rec_job.log"
check "6 CRF tag vs job record"            "grep -q 'Other S01E01 HEVC High.mkv: verification mismatch: COMPRESSION_CRF 21, job record CRF 25' '$T/rec.log'"
check "6 tier tag vs job record"           "grep -q 'Other S01E01 HEVC High.mkv: verification mismatch: COMPRESSION_TIER High, job record Base' '$T/rec.log'"

# ------------------------------------------------------------
echo
echo "== 7 read-only"
# every run of this test: packet scan (Movie B), title / tag problems,
# job records
check "7 in/ out/ unchanged by every run (content, size, mtime, nothing added)" \
    "diff '$T/media.before' <(snapshot in out results.sh work/lib) > /dev/null"
check "7 whole compress/ unchanged by the last runs (work/ included)" \
    "diff '$T/snap.before' <(snapshot) > /dev/null"
check "7 statistics of Movie B still missing" "[[ \"\$(stored_tag_totals '$OUT/Movie B (2002) HEVC High.mkv' 0)\" == 'N/A '* ]]"
check "7 non-standard title kept"          "[[ \"\$(ffprobe -v error -show_entries stream_tags=title -of default=nw=1:nk=1 '$O1/Columbo S01E02 HEVC High.mkv')\" == 'Fixture.2160p.BluRay.REMUX-GRP' ]]"
check "7 no compression tags written"      "[[ \"\$(compression_tags '$OUT/$C/Season 02/Columbo S02E01 HEVC High.mkv')\" == \$'-\\t-' ]]"

# ------------------------------------------------------------
echo
echo "== 8 over target"
# the job kept Other S01E01 above its video ceiling at the tier's CRF
# limit: its latest record (same video bytes) carries over_ceiling
python3 -c 'import json, sys
print(json.dumps({"entry": "output", "id": "y", "op": {"time": "2026-11-21T06:00:00Z", "recorded": "2026-11-21T06:00:00Z",
      "job": {"session": "series3", "type": "series", "log_dir": sys.argv[2]},
      "flags": ["over_ceiling"], "output_video_bytes": int(sys.argv[3])}, "file": {"path": sys.argv[1]}}))' \
    "$OUT/Other Show/Season 01/Other S01E01 HEVC High.mkv" "$LOGS/series3-20261121-150000" "$VB" >> "$J"
rs "$T/over.log" "Other Show"
check "8 season row: over target"          "grep -qE '^  Season 01 +1 .*over target \\(1\\)\$' '$T/over.log'"
check "8 overall line names it"            "grep -q '^Over target: 1 of 1 outputs kept above their video ceiling' '$T/over.log'"
check "8 not an issue"                     "! sed -n '/Issues:/,/^------/p' '$T/over.log' | grep -qi 'over target'"
COMPRESS_VERBOSE=1 rs "$T/over_v.log" "Other Show"
check "8 episode row: over target"         "grep -qE '^    Other S01E01 HEVC High\\.mkv .*over target\$' '$T/over_v.log'"
rs "$T/over_c.log" "$C"
check "8 other shows: no over target"      "! grep -qi 'over target' '$T/over_c.log'"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
