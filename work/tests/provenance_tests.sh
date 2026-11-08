#!/usr/bin/env bash
# Compression provenance (work/lib/provenance.sh, provenance.py, the
# PROVENANCE_* tags, the manifest, provenance.sh scan / tag / relink /
# compare). Documentation: PROVENANCE.md.
#
#   bash ~/compress/work/tests/provenance_tests.sh
#
# Part 1 (git + python3, no media tools): the Git version a job records
#   (full commit / branch / dirty, taken when the job is generated; jobs
#   of earlier versions resolve their describe string, never the current
#   HEAD; no Git -> unknown), IDs, the operations summary for the
#   HDR10 / HDR10+ / Dolby Vision / audio / commentary / subtitle cases,
#   the mux strip options.
# Part 2 (python3; stand-in encoder / mkvextract / mkvpropedit as in
#   compression_tag_tests.sh): movie Quality / High (CRF retry) / Base /
#   Compact / Custom and series episodes (season batch) each get one
#   record and the PROVENANCE_* tags (same ID), source tags kept; stream
#   copy and two-pass records; failed and interrupted items record
#   nothing; tracking changes neither the encodes nor the CRF decisions
#   nor the outputs; repeated processing keeps the old record (replaced),
#   no duplicates on re-ingest; missing Git; python3 missing (the event
#   waits in the spool); manifest recovery (.bak, journal, torn journal
#   line); concurrent ingests (lock, atomic replace).
# Part 3 (python3 + ffmpeg + mkvtoolnix): a real encode with two audio
#   tracks (one commentary), subtitles, chapters and an attachment; the
#   verified operations, media properties, tool versions and settings in
#   the record; the tags in the real file and after a statistics
#   refresh, a track-name edit and an ffmpeg remux; lineage through a
#   stream-copy job and an audio-compress job (history inherited); the
#   verifier's Dolby Vision (profile 7 -> 8.1, MEL), HDR10+ and HDR10
#   operation rows (probe stand-ins on the real files); scan (recorded /
#   legacy tags + ledger / unknown / moved), relink, tag (dry run, tags
#   only: streams and chapters unchanged, no commit claimed), compare
#   (current / older unaffected / potentially affected / manual review /
#   unknown).
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${PROV_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0
SKIPPED=()

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }
match() { if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1  (got \"$2\", want /$3/)"; fi; }

unset COMPRESS_VERBOSE SERIES_CRF_SHARED PROVENANCE_DIR PROVENANCE_PYTHON

PY=""
for p in python3 python; do
    command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null && { PY="$p"; break; }
done
if [[ -z "$PY" ]] || ! command -v git >/dev/null 2>&1; then
    echo "skipped: python3 and git are needed"
    echo "passed: 0  failed: 0"
    exit 0
fi
# win: native python needs native paths for the files it is given
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s' "$1"; fi; }
# jq-free JSON queries: J FILE EXPR  (EXPR: python, d = the JSON)
J() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); r=eval(sys.argv[2]); print(r if not isinstance(r,(dict,list)) else json.dumps(r, sort_keys=True))' "$(wp "$1")" "$2" | tr -d '\r'; }

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
g() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false \
          -c init.defaultBranch=main -c core.autocrlf=false -C "$@"; }

HAVE_FFMPEG=0
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null && HAVE_FFMPEG=1
HAVE_MKV=0
command -v mkvpropedit >/dev/null && command -v mkvextract >/dev/null && command -v mkvmerge >/dev/null && HAVE_MKV=1

# R: a checkout (Git repository) of the compressor: jobs generated from
# its library record its commit
R="$T/repo"
mkdir -p "$R/work/logs" "$R/in/Show" "$R/out/Show"
cp -r "$SRC_WORK/lib" "$R/work/"
cp "$ROOT/provenance.sh" "$R/" 2>/dev/null
printf 'work/logs/\nin/\nout/\n' > "$R/.gitignore"
echo "readme" > "$R/README.md"
g "$R" init -q
g "$R" add -A
g "$R" commit -qm base
C1=$(g "$R" rev-parse HEAD)
W="$R/work"
WORK_DIR="$W"
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy naming job_runtime; do
    source "$W/lib/$l.sh" > /dev/null
done
PDIR="$W/logs/provenance"
M="$PDIR/manifest.json"
prov() { PROV_BASH="$BASH" "$PY" "$(wp "$W/lib/provenance.py")" --work "$(wp "$W")" --out "$(wp "$R/out")" "$@"; }

# ============================================================
echo "== 1 Git version, IDs, operations summary"

IFS=$'\t' read -r gc gb gt <<< "$(compresser_git_info)"
eq    "full commit SHA of the checkout"           "$gc" "$C1"
eq    "branch"                                   "$gb" main
eq    "clean tree"                               "$gt" clean
echo "# local" >> "$R/work/lib/bitrate.sh"
eq    "tracked change: dirty"                    "$(compresser_git_info | cut -f3)" dirty
g "$R" checkout -q -- work/lib/bitrate.sh
echo "notes" > "$R/notes.txt"
eq    "untracked file: still clean"              "$(compresser_git_info | cut -f3)" clean
rm -f "$R/notes.txt"
g "$R" checkout -q --detach HEAD
eq    "detached HEAD"                            "$(compresser_git_info | cut -f2)" HEAD
g "$R" checkout -q main
mkdir -p "$T/nogit/work/lib"
cp "$SRC_WORK/lib/ui.sh" "$SRC_WORK/lib/encode_common.sh" "$T/nogit/work/lib/"
eq    "copy without .git: unknown, never fails"  "$(bash -c 'source "$1/work/lib/encode_common.sh" >/dev/null; compresser_git_info; echo rc=$?' _ "$T/nogit" | tr '\t\n' '  ')" "unknown unknown unknown rc=0 "
eq    "Git missing: unknown"                     "$(bash -c 'command() { [[ "$1 ${2:-}" == "-v git" ]] && return 1; builtin command "$@"; }; source "$1/work/lib/encode_common.sh" >/dev/null; compresser_git_info' _ "$R" | tr '\t' ' ')" "unknown unknown unknown"

hdr=$(emit_job_header s0 movie 1)
check "job header: full commit, branch, tree"    "grep -qx 'JOB_GIT_COMMIT=$C1' <<< \"\$hdr\" && grep -qx 'JOB_GIT_BRANCH=main' <<< \"\$hdr\" && grep -qx 'JOB_GIT_TREE=clean' <<< \"\$hdr\""
order=$(grep -n -e '^JOB_GIT_COMMIT=' -e '^job_init ' <<< "$hdr" | cut -d: -f1 | tr '\n' ' ')
match "job header: set before job_init"          "$order" '^[0-9]+ [0-9]+ $'

# _prov_git: the job's values; a job of an earlier version (describe
# only) resolves it in this checkout; never the current HEAD
eq    "recorded: the job's own values"           "$(JOB_GIT_COMMIT=abc JOB_GIT_BRANCH=b JOB_GIT_TREE=dirty _prov_git | tr '\t' ' ')" "abc b dirty job-generated"
g "$R" tag v9.0
echo "two" >> "$R/README.md"; g "$R" commit -qam two
C2=$(g "$R" rev-parse HEAD)
eq    "earlier job: describe resolved to its commit" "$(unset JOB_GIT_COMMIT; JOB_COMPRESSER_VERSION=v9.0 _prov_git | tr '\t' ' ')" "$C1 unknown clean resolved-from-describe"
eq    "earlier job, dirty describe"               "$(unset JOB_GIT_COMMIT; JOB_COMPRESSER_VERSION=v9.0-dirty _prov_git | cut -f1,3,4 | tr '\t' ' ')" "$C1 dirty resolved-from-describe"
eq    "earlier job, unknown version: unknown (not HEAD $C2)" "$(unset JOB_GIT_COMMIT; JOB_COMPRESSER_VERSION=unknown _prov_git | tr '\t' ' ')" "unknown unknown unknown unknown"
eq    "earlier job, describe not in this checkout" "$(unset JOB_GIT_COMMIT; JOB_COMPRESSER_VERSION=v0.1-3-gdeadbee _prov_git | cut -f1)" unknown

ids=$(for i in 1 2 3 4 5; do prov_new_id; done)
check "IDs: RFC 4122 v4, unique"                  "[[ \$(grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\$' <<< \"\$ids\") == 5 && \$(sort -u <<< \"\$ids\" | wc -l) == 5 ]]"
match "time: ISO 8601 UTC"                        "$(prov_now)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# ops ROWS...  ->  ops.tsv from "scope|subject|action|detail" rows
ops() { local r; : > "$T/ops.tsv"; for r in "$@"; do IFS='|' read -r a b c d <<< "$r"; printf '%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" >> "$T/ops.tsv"; done; }
ops "hdr|dynamic range|modified|DV Profile 7.6 + HDR10 -> DV Profile 8.1 + HDR10" \
    "dv|rpu|converted|profile 7.6 -> 8.1 (RPU kept, verified)" "dv|enhancement layer|removed|MEL discarded (single-layer output)" \
    "video|resolution|modified|3840x2160 -> 1920x1080 (downscaled)"
eq    "summary: DV profile 7 -> 8.1, MEL, downscale" "$(prov_ops_summary "$T/ops.tsv" crf 18 "")" \
      "video=reencoded x265 crf 18, 3840x2160->1920x1080; hdr=DV Profile 7.6 + HDR10 -> DV Profile 8.1 + HDR10; dv=profile 7.6 -> 8.1, EL (MEL) removed"
ops "hdr|dynamic range|modified|DV Profile 8.1 + HDR10 + HDR10+ -> HDR10" "dv|rpu|removed|profile 8.1 dropped" "hdr10plus|dynamic metadata|removed|dropped"
eq    "summary: DV + HDR10+ dropped"             "$(prov_ops_summary "$T/ops.tsv" crf 20 "")" "video=reencoded x265 crf 20; hdr=DV Profile 8.1 + HDR10 + HDR10+ -> HDR10; dv=removed; hdr10+=removed"
ops "hdr|dynamic range|preserved|HDR10 + HDR10+" "hdr10plus|dynamic metadata|preserved|x" "hdr10|mastering|preserved|x"
eq    "summary: HDR10 + HDR10+ kept"             "$(prov_ops_summary "$T/ops.tsv" crf 22 "")" "video=reencoded x265 crf 22; hdr=HDR10 + HDR10+ kept; hdr10+=kept"
ops "audio|track 1|preserved|x" "audio|track 2|converted|TrueHD 7.1 -> AC-3 5.1(side)" "audio|track 2 object audio|removed|Atmos" \
    "commentary|track 3|preserved|x" "audio|track 3|preserved|x" "subtitle|track 1|preserved|x" "subtitle|track 2|converted|mov_text -> subrip" \
    "subtitle|subtitle 4 (dvb_subtitle)|removed|not supported in MKV" "subtitle|track 1 forced|modified|0 -> 1" "metadata|audio 2 title|modified|x"
eq    "summary: audio conversion, commentary, subtitles" "$(prov_ops_summary "$T/ops.tsv" audio "" "")" \
      "video=copied; audio=2 copied, 1 converted; audio-objects=Atmos removed; commentary=1 kept; subs=1 kept, 1 converted, 1 removed, 1 modified; titles=1 modified"
eq    "summary: no verified rows -> the executed video only" "$(prov_ops_summary "$T/none.tsv" abr "" 1500)" "video=reencoded x265 2-pass 1500k"

check "encode mux drops a source's PROVENANCE_* tags" "[[ \"\$(provenance_strip_args)\" == '-metadata PROVENANCE_TOOL= -metadata PROVENANCE_ID= '* ]]"
check "audio menu mux drops them too"            "grep -q 'provenance_strip_args' '$ROOT/audio_compress_menu.sh'"
check "mkv_set_global_tags refuses other names"  "! mkv_set_global_tags /nonexistent '$T' '$PROVENANCE_TAG_NAMES' TITLE=x"

# ============================================================
echo
echo "== 2 stand-in jobs: one record per output, tags, no effect on the encode"

printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/tmux"
mkdir -p "$T/stub" && mv "$T/tmux" "$T/stub/"
cat > "$T/stub/mkvextract" <<'EOF'
#!/usr/bin/env bash
[[ "$2" == tags ]] || exit 2
grep -qx '#TAGS' "$1" || exit 0
sed '1,/^#TAGS$/d' "$1" > "$3"
EOF
cat > "$T/stub/mkvpropedit" <<'EOF'
#!/usr/bin/env bash
f="$1"; shift
echo "${f##*/} $*" >> "$STUB_LOG"
while (( $# )); do
    case "$1" in
        --tags)
            x="${2#all:}"; shift 2
            { sed '/^#TAGS$/,$d' "$f"; if [[ -n "$x" ]]; then echo '#TAGS'; cat "$x"; fi; } > "$f.stubtmp" &&
                cat "$f.stubtmp" > "$f" && rm -f "$f.stubtmp"
            ;;
        *) shift ;;
    esac
done
exit 0
EOF
chmod +x "$T/stub/"*
REAL_PATH="$PATH"
export STUB_LOG="$T/propedit.log"

tagval() {
    sed '1,/^#TAGS$/d' "$1" 2>/dev/null | awk -v n="$2" '
        /<Tag>/ { g = 1 } /UID>/ { g = 0 }
        $0 ~ "<Name>" n "</Name>" { hit = 1; next }
        hit && /<String>/ { v = $0; sub(/.*<String>/, "", v); sub(/<\/String>.*/, "", v); if (g) print v; hit = 0 }'
}
SRC_TAGS='<?xml version="1.0"?>
<Tags>
  <Tag>
    <Targets />
    <Simple>
      <Name>TITLE</Name>
      <String>Test Movie</String>
    </Simple>
    <Simple>
      <Name>SOURCE_NOTE</Name>
      <String>keep me</String>
    </Simple>
  </Tag>
  <Tag>
    <Targets>
      <TrackUID>1234567</TrackUID>
    </Targets>
    <Simple>
      <Name>DURATION</Name>
      <String>00:01:40.000000000</String>
    </Simple>
  </Tag>
</Tags>'
printf '%s\n' "$SRC_TAGS" > "$T/src_tags.xml"
G=1073741824
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }
sz() { printf "[%s]='%s %s'" "$1" "$(gib "$2")" "$(gib 0.5)"; }

# generator stand-ins (no ffprobe on the stand-in sources)
main_video_index()   { echo 0; }
probe_hdr()          { HDR_DV=0; HDR_HDR10PLUS=0; HDR_DV_PROFILE=""; HDR_KIND=SDR; }
build_stream_map()   { MAP_ARGS="-map 0:0"; MAP_CODEC_ARGS=""; MAP_META_ARGS=""; MAP_OTHER_ARGS=""; MAP_COVERS=(); MAP_NOTES=(); MAP_AMAP=""; }
x265_color_params()  { :; }
color_output_args()  { :; }
libx265_has_option() { return 1; }
stale_stats_args()   { :; }
matroska_mux_args()  { :; }

# job stand-ins: the "encoder" writes "VIDEO AUDIO CRF" + the source
# tags; the "verification" writes the operation rows a real one would
STUBS='
get_duration() { echo 100; }
media_stream_totals() { local v a c; read -r v a c < "$1"; echo "$v $a"; }
item_verify_output() {
    printf "video\tstream\treencoded\tstand-in\naudio\ttrack 1\tpreserved\taac\nsubtitle\ttrack 1\tpreserved\tsubrip\n" > "$ITEM_TMP/ops.tsv"
    [[ "${ITEM_EXP[mode]:-}" == copy ]] && printf "video\tstream\tpreserved\tstream copy\naudio\ttrack 1\tpreserved\taac\n" > "$ITEM_TMP/ops.tsv"
    echo "$ITEM_INDEX:${ITEM_EXP[crf]:-}" >> "'"$T"'/$JOB_SESSION.verified"
}
item_restore_mkv_chapters() { return 0; }
item_step() { shift; "$@"; }
refresh_mkv_stats() { return 0; }
report_output_stats() { local v a; read -r v a <<< "$(media_stream_totals "$1")"; ITEM_FINAL_VBYTES="$v"; }
item_run() {
    local c="${ITEM_EXP[crf]:-}" s
    [[ "$1" == 1/2 ]] && return 0
    [[ "${ITEM_EXP[mode]:-}" == crf ]] || c=-
    s="${SIZES[$ITEM_INDEX:$c]:-}"
    echo "$ITEM_INDEX:$c" >> "'"$T"'/$JOB_SESSION.encoded"
    [[ -n "${KILL_AT:-}" && "$ITEM_INDEX" == "$KILL_AT" ]] && kill -TERM $$
    [[ -z "$s" || "$s" == fail ]] && return 1
    { echo "$s $c"; if [[ -n "${SRCTAGS[$ITEM_INDEX]:-}" ]]; then echo "#TAGS"; cat "${SRCTAGS[$ITEM_INDEX]}"; fi; } > "$ITEM_PART"
}
'
# run_job SESSION TYPE N ITEMS SIZES SRCTAGS [EXTRA]
run_job() {
    local s="$1" type="$2" n="$3" items="$4" sizes="$5" src="${6:-}" extra="${7:-}"
    rm -f "$T/$s.encoded" "$T/$s.verified" "$STUB_LOG"
    {
        emit_job_header "$s" "$type" "$n"
        printf '%s\n' "$STUBS" "declare -A SIZES=($sizes)" "declare -A SRCTAGS=($src)" "$extra"
        printf '%s\n' "$items"
        emit_job_footer
    } > "$W/$s.sh"
    bash -n "$W/$s.sh" || { bad "$s: generated job fails bash -n"; return; }
    cp "$W/$s.sh" "$T/$s.job"
    PATH="$T/stub:$REAL_PATH" bash "$W/$s.sh" < /dev/null > "$T/$s.log" 2>&1
}
logged() { grep -qF -- "$2" "$T/$1.log"; }
# rec PATH EXPR  ->  EXPR on the active record of output PATH (r = record)
rec() {
    "$PY" -c '
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
want = sys.argv[2]
hits = [r for r in d["records"].values() if r["status"] == "active" and
        os.path.basename(r["current"]["path"]) == os.path.basename(want) and
        os.path.basename(os.path.dirname(r["current"]["path"])) == os.path.basename(os.path.dirname(want))]
if len(hits) != 1:
    print("RECORDS=%d" % len(hits)); sys.exit(0)
r = hits[0]; o = r["original"]
v = eval(sys.argv[3])
print(v if not isinstance(v, (dict, list)) else json.dumps(v, sort_keys=True))' "$(wp "$M")" "$1" "$2" | tr -d '\r'
}
nrec() { J "$M" 'len(d["records"])'; }

for m in Q H B K C Copy Abr F X; do printf 'movie %s\n' "$m" > "$R/in/$m.mkv"; done
g "$R" add -A >/dev/null 2>&1; g "$R" commit -qm "test sources" >/dev/null 2>&1
C3=$(g "$R" rev-parse HEAD)

items=$(emit_encode_item 1 "$R/in/Q.mkv" "$R/out/Q.mkv" Quality crf:19 "" "" 0 "$(gib 7)")$'\n'
items+=$(emit_encode_item 2 "$R/in/H.mkv" "$R/out/H.mkv" High crf:20 "" "" 0 "$(gib 4.8)" "$(gib 5):24:18:0:1:::boundary")$'\n'
items+=$(emit_encode_item 3 "$R/in/B.mkv" "$R/out/B.mkv" Base crf:26 "" "" 0 "$(gib 1.8)")$'\n'
items+=$(emit_encode_item 4 "$R/in/K.mkv" "$R/out/K.mkv" Compact crf:27 "$DOWNSCALE_1080P_FILTER" "" 0 "$(gib 1)")$'\n'
items+=$(emit_encode_item 5 "$R/in/C.mkv" "$R/out/C.mkv" Custom crf:23.5 "" "" 0 "$(gib 3)")
SIZES1="$(sz 1:19 7) $(sz 2:20 5.4) $(sz 2:21 4.6) $(sz 3:26 1.6) $(sz 4:27 1) $(sz 5:23.5 3)"
run_job pm movie 5 "$items" "$SIZES1" "[2]='$T/src_tags.xml' [5]='$T/src_tags.xml'"
check "movie presets: job ok"                     "logged pm 'All encodes finished: 5 ok, 0 failed'"
eq    "one record per output"                     "$(nrec)" 5
for p in Q:Quality H:High B:Base K:Compact C:Custom; do
    f="$R/out/${p%%:*}.mkv"
    eq "${p#*:}: preset, kind, commit, tree"     "$(rec "$f" '"%s %s %s %s %s" % (o["preset"], r["kind"], o["git"]["commit"], o["git"]["dirty"], o["git"]["captured"])')" \
       "${p#*:} movie $C3 False job-generated"
    eq "${p#*:}: PROVENANCE_ID tag = record ID" "$(tagval "$f" PROVENANCE_ID)" "$(rec "$f" 'r["id"]')"
    eq "${p#*:}: PROVENANCE_COMMIT / PRESET / STATUS / TOOL" \
       "$(tagval "$f" PROVENANCE_COMMIT) $(tagval "$f" PROVENANCE_PRESET) $(tagval "$f" PROVENANCE_STATUS) $(tagval "$f" PROVENANCE_TOOL)" \
       "$C3 ${p#*:} recorded movie-compresser"
done
eq    "High: final CRF after the retry recorded"  "$(rec "$R/out/H.mkv" 'o["settings"]["crf"]') $(rec "$R/out/H.mkv" 'o["settings"]["crf_planned"]') $(tagval "$R/out/H.mkv" COMPRESSION_CRF)" "21.0 20.0 21"
eq    "High: CRF attempts recorded"               "$(rec "$R/out/H.mkv" '"%s %s" % ([a["crf"] for a in o["crf_attempts"]], o["crf_attempts"][-1]["result"])')" "[20.0, 21.0] ACCEPTED"
eq    "High: the job's tags summary"              "$(tagval "$R/out/H.mkv" PROVENANCE_OPS)" "video=reencoded x265 crf 21; audio=1 copied; subs=1 kept"
# (the stand-in item_run executes nothing: the executed options are
# checked with real ffmpeg in part 3)
eq    "Compact: downscale recorded, other presets not scaled" "$(for m in K H; do rec "$R/out/$m.mkv" 'o["settings"]["scaled"]'; done | tr '\n' ' ')" "True False "
eq    "High: verified changes recorded"           "$(rec "$R/out/H.mkv" '[(c["scope"], c["action"], c["basis"]) for c in o["changes"]]')" \
      '[["video", "reencoded", "verified"], ["audio", "preserved", "verified"], ["subtitle", "preserved", "verified"]]'
eq    "source tags kept, provenance appended"      "$(tagval "$R/out/C.mkv" SOURCE_NOTE) $(tagval "$R/out/C.mkv" TITLE) $(tagval "$R/out/C.mkv" COMPRESSION_TIER)" "keep me Test Movie Custom"
eq    "each PROVENANCE tag once"                   "$(for n in ${PROVENANCE_TAG_NAMES//|/ }; do tagval "$R/out/H.mkv" "$n" | grep -c ''; done | tr -d '\n')" "111111110"
check "spool emptied, no temp files"             "[[ -z \"\$(ls -A '$PDIR/spool')\" && -z \"\$(ls '$PDIR' | grep -E 'tmp')\" ]]"
check "journal: one line per record"              "[[ \$(grep -c '' '$PDIR/journal.jsonl') == 5 ]]"
check "work dirs cleaned (no prov leftovers)"    "[[ -z \"\$(find '$W/logs' -path '*item-*' 2>/dev/null)\" ]]"

# the same job without provenance tracking: identical encodes, CRF
# decisions and outputs (the tags appended by the tracking aside)
NOPROV='item_provenance_tag() { :; }; item_provenance_record() { :; }'
for m in Q H B K C; do mv "$R/out/$m.mkv" "$T/with_$m.mkv"; done
cp "$T/pm.encoded" "$T/with.encoded"
run_job pn movie 5 "$items" "$SIZES1" "[2]='$T/src_tags.xml' [5]='$T/src_tags.xml'" "$NOPROV"
eq    "tracking off: same encode sequence"         "$(tr '\n' ' ' < "$T/pn.encoded")" "$(tr '\n' ' ' < "$T/with.encoded")"
same=1
for m in Q H B K C; do
    [[ "$(head -n 1 "$R/out/$m.mkv")" == "$(head -n 1 "$T/with_$m.mkv")" ]] || same=0
    [[ "$(sed '1,/^#TAGS$/d' "$R/out/$m.mkv" | grep -c PROVENANCE)" == 0 ]] || same=0
done
eq    "tracking off: same outputs (media line), no PROVENANCE tags" "$same" 1
eq    "tracking off: no records added"            "$(nrec)" 5
eq    "generated job identical"                    "$(diff <(sed 's/^job_init pn /job_init pm /' "$T/pn.job" | grep -v 'item_provenance') <(grep -v 'item_provenance' "$T/pm.job") | grep -v '^[<>] *$' | grep -c '^[<>]')" 0
for m in Q H B K C; do mv "$T/with_$m.mkv" "$R/out/$m.mkv"; done
rm -f "$R/out/"*.mkv.*

echo
echo "== 2b series episodes, stream copy, two-pass"
for e in 1 2 3; do echo "episode $e" > "$R/in/Show/Show.S01E0$e.mkv"; done
spec=$(series_season_retry_spec High "$(gib 5)" 19 16)
items=""
for e in 1 2 3; do
    items+=$(emit_encode_item "$e" "$R/in/Show/Show.S01E0$e.mkv" "$R/out/Show/Show.S01E0$e.mkv" High crf:16 "" "" 0 \
        "$(gib 4.5)" "$spec" "" "15=$(gib 5):16=$(gib 4.5)")$'\n'
done
run_job ss series 3 "$items" "$(sz 1:16 4) $(sz 2:16 5.5) $(sz 3:16 4) $(sz 1:17 3.5) $(sz 2:17 4.8) $(sz 3:17 3.5)" ""
check "series: job ok"                            "logged ss 'All encodes finished: 3 ok, 0 failed'"
eq    "series: episode records"                   "$(for e in 1 2 3; do rec "$R/out/Show/Show.S01E0$e.mkv" '"%s/%s/%s/%s" % (r["kind"], r["series"]["show"], r["series"]["episode"], o["settings"]["crf"])'; done | tr '\n' ' ')" \
      "episode/Show/S01E01/17.0 episode/Show/S01E02/17.0 episode/Show/S01E03/17.0 "
eq    "series: tags carry the season CRF episode"  "$(tagval "$R/out/Show/Show.S01E02.mkv" PROVENANCE_OPS)" "video=reencoded x265 crf 17; audio=1 copied; subs=1 kept"
items=$(emit_encode_item 1 "$R/in/Copy.mkv" "$R/out/Copy.mkv" Quality copy "" "" 0)$'\n'
items+=$(emit_encode_item 2 "$R/in/Abr.mkv" "$R/out/Abr.mkv" High 1500 "" "$T/pass" 0)
run_job nc movie 2 "$items" "[1:-]='1 1' [2:-]='1 1'" "[1]='$T/src_tags.xml'"
eq    "stream copy: record, inherited history unknown" "$(rec "$R/out/Copy.mkv" '"%s %s %s %s" % (r["provenance"], o["status"], r["operations"][0]["type"], r["operations"][0]["settings"]["video"])')" \
      "partial unknown stream-copy stream copy (not re-encoded)"
eq    "stream copy: tags, no CRF claimed"          "$(tagval "$R/out/Copy.mkv" PROVENANCE_OPS)|$(tagval "$R/out/Copy.mkv" COMPRESSION_CRF)" "video=copied; audio=1 copied|"
eq    "two-pass: compress record"                  "$(rec "$R/out/Abr.mkv" '"%s %s %s" % (o["type"], o["settings"]["video"], o["settings"]["bitrate_kbps"])')" "compress x265 two-pass bitrate 1500"

echo
echo "== 2c failed and interrupted items record nothing"
n0=$(nrec)
items=$(emit_encode_item 1 "$R/in/F.mkv" "$R/out/F.mkv" Custom crf:20 "" "" 0)
run_job fl movie 1 "$items" "[1:20]=fail" ""
check "failed: job reports the failure"          "logged fl 'All encodes finished: 0 ok, 1 failed'"
eq    "failed: no record, nothing spooled"         "$(nrec) $(ls -A "$PDIR/spool" | wc -l)" "$n0 0"
check "failed: no output, no prov leftovers"     "[[ ! -e '$R/out/F.mkv' && -z \"\$(find '$W/logs' -path '*item-1.tmp/prov*' 2>/dev/null)\" ]]"
items=$(emit_encode_item 1 "$R/in/X.mkv" "$R/out/X.mkv" Custom crf:20 "" "" 0)
run_job ki movie 1 "$items" "$(sz 1:20 3)" "" "KILL_AT=1"
check "interrupted: job interrupted"             "logged ki 'Job interrupted'"
eq    "interrupted: no record, nothing spooled"    "$(nrec) $(ls -A "$PDIR/spool" | wc -l)" "$n0 0"
check "interrupted: no output, no prov leftovers" "[[ ! -e '$R/out/X.mkv' && -z \"\$(find '$W/logs' -path '*/prov/*' 2>/dev/null)\" ]]"
rm -f "$W"/ki.sh "$W"/ki.state "$W"/ki.progress

echo
echo "== 2d repeated processing, missing Git, python missing"
old=$(rec "$R/out/C.mkv" 'r["id"]')
items=$(emit_encode_item 1 "$R/in/C.mkv" "$R/out/C.mkv" Custom crf:22 "" "" 1 "$(gib 3)")
run_job rp movie 1 "$items" "$(sz 1:22 3)" ""
new=$(rec "$R/out/C.mkv" 'r["id"]')
check "repeat: new ID for the new output"         "[[ -n '$new' && '$new' != '$old' && '$new' != RECORDS* ]]"
eq    "repeat: the earlier record kept, replaced"  "$(J "$M" "'%s %s' % (d['records']['$old']['status'], d['records']['$old']['replaced_by'])")" "replaced $new"
eq    "repeat: earlier record's settings intact"   "$(J "$M" "d['records']['$old']['original']['settings']['crf']")" 23.5
eq    "repeat: one active record at that path"     "$(rec "$R/out/C.mkv" 'o["settings"]["crf"]')" 22.0
n1=$(nrec)
cp -r "$PDIR" "$T/pdir_before"
# the same events again: no duplicates
mkdir -p "$PDIR/spool/dup"
"$PY" - "$(wp "$PDIR/journal.jsonl")" "$(wp "$PDIR/spool/dup/event.tsv")" <<'PYEOF'
import json, sys
last = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for k, v in (("id", last["id"]), ("op_id", last["op"]["op_id"]), ("time", last["op"]["time"]),
                 ("output", last["file"]["path"]), ("op_type", "compress"), ("job_type", "movie")):
        f.write("%s\t%s\n" % (k, v))
PYEOF
prov ingest > "$T/dup.log" 2>&1
eq    "re-ingesting an applied event: no duplicate" "$(nrec) $(grep -o '0 event(s) applied, 1 already' "$T/dup.log")" "$n1 0 event(s) applied, 1 already"

# no Git metadata at generation time
items=$(emit_encode_item 1 "$R/in/B.mkv" "$R/out/B2.mkv" Base crf:26 "" "" 0)
run_job ng movie 1 "$items" "$(sz 1:26 1)" "" 'JOB_GIT_COMMIT=unknown JOB_GIT_BRANCH=unknown JOB_GIT_TREE=unknown'
eq    "no Git: record commit null, tag unknown"    "$(rec "$R/out/B2.mkv" 'o["git"]["commit"]') $(tagval "$R/out/B2.mkv" PROVENANCE_COMMIT)" "None unknown"

# python missing: the event waits in the spool, a later ingest applies it
items=$(emit_encode_item 1 "$R/in/B.mkv" "$R/out/B3.mkv" Base crf:26 "" "" 0)
run_job np movie 1 "$items" "$(sz 1:26 1)" "" 'prov_python() { return 1; }'
check "no python: warned, item ok"               "logged np 'python3 not found: run provenance.sh ingest' && logged np 'All encodes finished: 1 ok, 0 failed'"
eq    "no python: event spooled, no record yet"     "$(ls "$PDIR/spool" | wc -l) $(rec "$R/out/B3.mkv" 'r["id"]')" "1 RECORDS=0"
prov ingest --quiet > /dev/null 2>&1
eq    "later ingest: recorded, spool empty"         "$(rec "$R/out/B3.mkv" 'r["id"]') $(ls "$PDIR/spool" | wc -l)" "$(tagval "$R/out/B3.mkv" PROVENANCE_ID) 0"

echo
echo "== 2e manifest recovery and concurrent updates"
n=$(nrec)
cp "$M" "$T/good_manifest.json"
echo '{"schema": "movie-compresser/provenance-manifest/1", "records": {' > "$M"     # torn write
eq    "corrupt manifest: recovered (backup + journal)" "$(prov show "$new" 2>&1 | head -c 1) $(prov scan "$R/out/C.mkv" 2>&1 | grep -c 'manifest: manifest recovered from manifest.json.bak')" "{ 1"
prov ingest --quiet > /dev/null 2>&1
eq    "repaired manifest written back"             "$(J "$M" 'len(d["records"])')" "$n"
rm -f "$M" "$M.bak"
eq    "manifest + backup lost: rebuilt from the journal" "$(prov rebuild | grep -o '[0-9]* records')" "$n records"
eq    "rebuild = the same records"                 "$(J "$M" 'sorted((k, r["status"]) for k, r in d["records"].items())')" "$(J "$T/good_manifest.json" 'sorted((k, r["status"]) for k, r in d["records"].items())')"
printf '{"entry": "output", "id": "trunc' >> "$PDIR/journal.jsonl"   # torn journal append
eq    "torn journal line: skipped on rebuild"      "$(prov rebuild 2>&1 | grep -o '[0-9]* records')" "$n records"
# concurrent ingests: 4 writers x 3 events, one lock
for w in 1 2 3 4; do
    for i in 1 2 3; do
        id=$(prov_new_id); d="$PDIR/spool/c$w-$i"
        mkdir -p "$d"
        printf 'id\t%s\nop_id\tconc-%s-%s\ntime\t%s\noutput\t%s\nop_type\tcompress\njob_type\tmovie\n' "$id" "$w" "$i" "$(prov_now)" "$R/out/conc-$w-$i.mkv" > "$d/event.tsv"
    done
done
for w in 1 2 3 4; do prov ingest --quiet > "$T/conc$w.log" 2>&1 & done
wait
eq    "concurrent: every event applied once"       "$(J "$M" 'len([r for r in d["records"].values() if "/conc-" in r["current"]["path"]])')" 12
check "concurrent: valid JSON, lock released, no temp files" "J '$M' 'd[\"schema\"]' >/dev/null && [[ ! -e '$PDIR/.lock' && -z \"\$(ls '$PDIR' | grep tmp)\" && -z \"\$(ls -A '$PDIR/spool')\" ]]"
check "stale lock is broken"                     "mkdir '$PDIR/.lock' && touch -d '2 hours ago' '$PDIR/.lock' && prov ingest --quiet 2>&1 | grep -q 'stale manifest lock' && [[ ! -e '$PDIR/.lock' ]]"

# ============================================================
echo
echo "== 3 real media: encode, verified operations, embedded tags, lineage"
if (( HAVE_FFMPEG == 0 || HAVE_MKV == 0 )); then
    SKIPPED+=("part 3 (needs ffmpeg + mkvtoolnix)")
    echo "  skipped: needs ffmpeg + mkvtoolnix"
else
    # back to the real tools and probes
    for f in main_video_index probe_hdr build_stream_map x265_color_params color_output_args libx265_has_option stale_stats_args matroska_mux_args; do unset -f "$f"; done
    for l in media_probe encode_common hdr_dovi; do source "$W/lib/$l.sh" > /dev/null; done
    X265_PRESET=ultrafast
    M3="$T/m3"; mkdir -p "$M3"
    printf '1\n00:00:00,000 --> 00:00:01,000\nhello\n' > "$M3/sub.srt"
    printf ';FFMETADATA1\ntitle=Real Movie\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Two\n' > "$M3/meta.txt"
    echo fontdata > "$M3/font.ttf"
    SRC="$R/in/Real Movie (2020).mkv"
    ffmpeg -v error -y -f lavfi -i testsrc2=s=160x90:r=24:d=2 -f lavfi -i sine=f=440:d=2 -f lavfi -i sine=f=880:d=2 -i "$M3/sub.srt" -i "$M3/meta.txt" \
        -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 -c:v libx264 -preset ultrafast -c:a:0 aac -c:a:1 ac3 -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=eng -metadata:s:a:1 "title=Director Commentary" -disposition:a:1 comment \
        -metadata:s:s:0 language=eng -disposition:s:0 forced -attach "$M3/font.ttf" -metadata:s:t mimetype=font/ttf "$SRC"
    OUT1="$R/out/Real Movie (2020) HEVC Custom.mkv"
    { emit_job_header r1 movie 1; emit_encode_item 1 "$SRC" "$OUT1" Custom crf:30 "" "" 0; emit_job_footer; } > "$W/r1.sh"
    cp "$W/r1.sh" "$T/r1.job"
    bash "$W/r1.sh" < /dev/null > "$T/r1.log" 2>&1
    check "real encode ok"                        "logged r1 'All encodes finished: 1 ok, 0 failed'"
    ID1=$(prov_file_tag "$OUT1" PROVENANCE_ID)
    eq    "record ID = embedded ID"               "$(rec "$OUT1" 'r["id"]')" "$ID1"
    eq    "verified operations"                   "$(rec "$OUT1" '" / ".join("%s:%s:%s" % (c["scope"], c["subject"], c["action"]) for c in o["changes"] if c["scope"] in ("video","audio","commentary","subtitle","attachments","chapters"))')" \
          "video:colour signalling:preserved / video:stream:reencoded / video:resolution:preserved / video:pixel format:modified / audio:track 1:preserved / audio:track 2:preserved / commentary:track 2:preserved / subtitle:track 1:preserved / attachments:all:preserved / chapters:all:preserved / chapters:editions:preserved"
    eq    "commentary track recorded in the output properties" "$(rec "$OUT1" '[a["commentary"] for a in o["output"]["audio"]]')" "[false, true]"
    eq    "source / output video properties"      "$(rec "$OUT1" '"%s %sx%s %s-bit -> %s %sx%s %s-bit %s fps" % (o["source"]["video"][0]["codec"], o["source"]["video"][0]["width"], o["source"]["video"][0]["height"], o["source"]["video"][0]["bit_depth"], o["output"]["video"][0]["codec"], o["output"]["video"][0]["width"], o["output"]["video"][0]["height"], o["output"]["video"][0]["bit_depth"], o["output"]["video"][0]["fps"])')" \
          "h264 160x90 8-bit -> hevc 160x90 10-bit 24.0 fps"
    eq    "subtitle flags, chapters, attachments"  "$(rec "$OUT1" '"%s %s %s %s" % (o["output"]["subtitles"][0]["forced"], o["output"]["subtitles"][0]["language"], o["output"]["chapters"]["count"], [a["filename"] for a in o["output"]["attachments"]])')" "True eng 2 ['font.ttf']"
    eq    "actual x265 settings from the stream"   "$(rec "$OUT1" '"%s %s %s" % (o["settings"]["x265_preset"], o["settings"]["x265_rate_control_in_stream"], "crf=30.0" in o["settings"]["x265_settings"])')" "ultrafast crf 30.0 True"
    eq    "tool versions recorded (used tools only)" "$(rec "$OUT1" '" ".join(sorted(o["tools"]))')" "ffmpeg ffprobe mkvtoolnix x265"
    eq    "dynamic range of source + output"        "$(rec "$OUT1" 'o["source"]["video"][0]["dynamic_range"]["label"] + " " + o["output"]["video"][0]["dynamic_range"]["label"]')" "SDR SDR"
    mkvextract "$OUT1" tags "$T/t1.xml" > /dev/null 2>&1
    eq    "real file: PROVENANCE_* + legacy tags + title" "$(for n in PROVENANCE_ID PROVENANCE_PRESET COMPRESSION_CRF; do mkv_global_tag_values "$T/t1.xml" "$n"; done | tr '\n' ' ')$(format_title "$OUT1")" "$ID1 Custom 30 Real Movie"
    eq    "real file: chapters / attachment kept"  "$(chapter_meta "$OUT1" | wc -l | tr -d ' ') $(mkvmerge -J "$OUT1" | grep -c '"file_name": "font.ttf"')" "2 1"
    # tags survive the normal metadata stages
    refresh_mkv_stats "$OUT1" > /dev/null 2>&1
    eq    "after a statistics refresh"             "$(prov_file_tag "$OUT1" PROVENANCE_ID)" "$ID1"
    mkvpropedit "$OUT1" --edit track:a1 --set name=Renamed > /dev/null 2>&1
    eq    "after a track-name edit"                "$(prov_file_tag "$OUT1" PROVENANCE_ID)" "$ID1"
    ffmpeg -v error -y -i "$OUT1" -map 0 -c copy -map_metadata 0 "$T/remux.mkv"
    eq    "after an ffmpeg remux (-map_metadata 0)" "$(prov_file_tag "$T/remux.mkv" PROVENANCE_ID) $(prov_file_tag "$T/remux.mkv" PROVENANCE_OPS | cut -d';' -f1)" "$ID1 video=reencoded x265 crf 30"
    mkvpropedit "$OUT1" --edit track:a1 --set "name=English | AAC | 1.0 | 70 kbps" > /dev/null 2>&1

    # lineage 1: a stream-copy job on the compressed output
    OUT2="$R/out/Real Movie (2020) copy.mkv"
    { emit_job_header r2 movie 1; emit_encode_item 1 "$OUT1" "$OUT2" Quality copy "" "" 0; emit_job_footer; } > "$W/r2.sh"
    cp "$W/r2.sh" "$T/r2.job"
    bash "$W/r2.sh" < /dev/null > "$T/r2.log" 2>&1
    ID2=$(prov_file_tag "$OUT2" PROVENANCE_ID)
    check "stream copy of a recorded file: ok, new ID" "logged r2 'All encodes finished: 1 ok, 0 failed' && [[ -n '$ID2' && '$ID2' != '$ID1' ]]"
    eq    "parent recorded (tag + record)"          "$(prov_file_tag "$OUT2" PROVENANCE_PARENT) $(rec "$OUT2" 'r["lineage"]["parent_id"]')" "$ID1 $ID1"
    eq    "video history inherited, copy appended"   "$(rec "$OUT2" '"%s %s %s %s" % (r["provenance"], o["inherited_from"] == r["lineage"]["parent_id"], o["settings"]["crf"], [x["type"] for x in r["operations"]])')" \
          "recorded True 30.0 ['stream-copy']"
    eq    "the parent record is unchanged"          "$(J "$M" "'%s %d' % (d['records']['$ID1']['status'], len(d['records']['$ID1']['operations']))")" "active 0"
    check "only one PROVENANCE_ID in the copy"       "mkvextract '$OUT2' tags '$T/t2.xml' >/dev/null 2>&1 && [[ \$(mkv_global_tag_values '$T/t2.xml' PROVENANCE_ID | grep -c '') == 1 ]]"

    # lineage 2: an audio-compress job (as audio_compress_menu.sh writes it)
    OUT3="$R/out/Real Movie (2020) AudioCompressed.mkv"
    VIDX=$(main_video_index "$OUT1"); build_stream_map "$OUT1" "$VIDX"
    {
        emit_job_header a1 audio 1
        printf 'if item_begin 1 %q %q %q 0 "" &&\n' "$OUT1" "$OUT3" "Audio Compact"
        printf '   item_expect vidx=%q video=copy atrans=0 aplan=%q ahash=1 amap=%q atitle=std &&\n' "$VIDX" "0:ac3:1:mono:44100:96" "$MAP_AMAP"
        printf '   item_run mux ffmpeg -y -i %q %s -c:v:0 copy -c:a:0 ac3 -b:a:0 96k -c:a:1 copy %s %s -map_metadata 0 -map_chapters 0 %s -f matroska "$ITEM_PART" &&\n' \
            "$OUT1" "$MAP_ARGS" "$MAP_CODEC_ARGS" "$(provenance_strip_args)" "$(matroska_mux_args)"
        printf '   item_step chapters item_restore_mkv_chapters %q\n' "$OUT1"
        printf 'then\n    item_succeeded\nelse\n    item_failed\nfi\n'
        emit_job_footer
    } > "$W/a1.sh"
    cp "$W/a1.sh" "$T/a1.job"
    bash "$W/a1.sh" < /dev/null > "$T/a1.log" 2>&1
    check "audio job ok"                           "logged a1 'All encodes finished: 1 ok, 0 failed'"
    eq    "audio job: conversion verified, commentary kept" "$(rec "$OUT3" '[(c["subject"], c["action"]) for c in r["operations"][-1]["changes"] if c["scope"] in ("audio","commentary")]')" \
          '[["track 1", "converted"], ["track 2", "preserved"], ["track 2", "preserved"]]'
    eq    "audio job: history = original encode + audio op" "$(rec "$OUT3" '"%s %s %s %s" % (r["kind"], o["settings"]["crf"], r["operations"][-1]["type"], r["operations"][-1]["preset"])')" "movie 30.0 audio-compress Audio Compact"
    s3=$(prov_file_tag "$OUT3" PROVENANCE_OPS)
    check "audio job: tags summary"                "[[ '$s3' == 'video=copied; '*'audio=1 copied, 1 converted;'*'commentary=1 kept'* ]]"
    eq    "audio job: planned conversion recorded" "$(rec "$OUT3" 'r["operations"][-1]["settings"]["audio_transcode"]')" '[{"channels": 1, "codec": "ac3", "kbps": 96, "layout": "mono", "sample_rate": 44100, "track": 1}]'

    # subtitle format conversion: an MP4 source with mov_text (stream copy job)
    MP4="$R/in/Clip (2021).mp4"
    ffmpeg -v error -y -f lavfi -i testsrc2=s=160x90:r=24:d=2 -f lavfi -i sine=f=440:d=2 -i "$M3/sub.srt" \
        -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -c:a aac -c:s mov_text -metadata:s:s:0 language=eng "$MP4"
    OUT4="$R/out/Clip (2021).mkv"
    { emit_job_header r4 movie 1; emit_encode_item 1 "$MP4" "$OUT4" Quality copy "" "" 0; emit_job_footer; } > "$W/r4.sh"
    bash "$W/r4.sh" < /dev/null > "$T/r4.log" 2>&1
    check "mp4 stream-copy job ok"                 "logged r4 'All encodes finished: 1 ok, 0 failed'"
    eq    "mov_text -> SRT conversion recorded"     "$(rec "$OUT4" '[(c["subject"], c["action"], c["detail"]) for c in r["operations"][-1]["changes"] if c["scope"] == "subtitle"]')" \
          '[["track 1", "converted", "mov_text -> subrip, lang eng"]]'
    s4=$(prov_file_tag "$OUT4" PROVENANCE_OPS)
    check "mov_text: tags summary"                 "[[ '$s4' == *'subs=1 converted'* ]]"

    echo
    echo "== 3b verifier rows for Dolby Vision / HDR10+ / HDR10 (probe stand-ins on real files)"
    # the real HEVC output vs its source; probe_hdr / dv_verify_rpu stand-ins
    # give them the dynamic range under test
    vrun() {   # NAME SRC_SPEC OUT_SPEC EXP...   SPEC: kind,h10p,dv,profile,compat
        local name="$1" s="$2" o="$3"; shift 3
        ITEM_INPUT="$SRC"; ITEM_PART="$OUT1"; ITEM_TMP="$T/v_$name"; mkdir -p "$ITEM_TMP"
        ITEM_TITLES_STATE=final
        unset ITEM_EXP; declare -gA ITEM_EXP=([vidx]=0 [video]=encode [mode]=crf [crf]=30 [scaled]=0 [atrans]= [ahash]=0 [amap]="0:0,1:1")
        local kv; for kv in "$@"; do ITEM_EXP[${kv%%=*}]="${kv#*=}"; done
        echo MEL > "$ITEM_TMP/dv_el"
        PSPEC_S="$s" PSPEC_O="$o"
        item_verify_output > /dev/null 2>&1
        tr '\t' '|' < "$ITEM_TMP/ops.tsv" | grep -E '^(hdr|hdr10|hdr10plus|dv)\|'
    }
    probe_hdr() {
        local spec="$PSPEC_O"; [[ "$1" == "$SRC" ]] && spec="$PSPEC_S"
        IFS=, read -r HDR_KIND HDR_HDR10PLUS HDR_DV HDR_DV_PROFILE HDR_DV_COMPAT <<< "$spec"
        HDR_PRIMARIES=bt2020 HDR_TRANSFER=smpte2084 HDR_MATRIX=bt2020nc HDR_RANGE=tv HDR_CHROMALOC=""
        HDR_MASTER="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)" HDR_CLL="1000,400"
        HDR_DV_RPU=1 HDR_DV_EL=0 HDR_DV_BL=1 HDR_DV_LEVEL=6 HDR_CODEC=hevc
        [[ "$1" == "$SRC" && "$HDR_DV_PROFILE" == 7 ]] && HDR_DV_EL=1
        return 0
    }
    dv_verify_rpu() { echo "VERIFIED (profile $3.$4, stand-in)"; }
    rows=$(vrun dv7 "HDR10,1,1,7,6" "HDR10,1,1,8,1" dv=preserve dv_profile=8 dv_compat=1 hdr10p=preserve)
    eq    "DV 7 -> 8.1 + MEL + HDR10+ + HDR10 rows" "$(tr '\n' '/' <<< "$rows")" \
          "hdr|dynamic range|modified|DV Profile 7.6 + HDR10 + HDR10+ -> DV Profile 8.1 + HDR10 + HDR10+/dv|rpu|converted|profile 7.6 -> 8.1 (RPU kept, verified)/dv|enhancement layer|removed|MEL discarded (single-layer output)/hdr10plus|dynamic metadata|preserved|re-inserted into the re-encode, verified/hdr10|mastering|preserved|G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)/hdr10|MaxCLL/MaxFALL|preserved|1000,400/"
    eq    "DV 7 -> 8.1: summary"                   "$(prov_ops_summary "$T/v_dv7/ops.tsv" crf 30 "" | cut -d';' -f1-4)" \
          "video=reencoded x265 crf 30; hdr=DV Profile 7.6 + HDR10 + HDR10+ -> DV Profile 8.1 + HDR10 + HDR10+; dv=profile 7.6 -> 8.1, EL (MEL) removed; hdr10+=kept"
    rows=$(vrun drop "HDR10,1,1,8,1" "HDR10,0,0,," dv=drop hdr10p=drop)
    eq    "DV + HDR10+ dropped by choice"          "$(grep -E '^(dv|hdr10plus)' <<< "$rows" | tr '\n' '/')" \
          "dv|rpu|removed|profile 8.1 dropped (base layer only, chosen before encoding)/hdr10plus|dynamic metadata|removed|dropped (chosen before encoding)/"
    rows=$(vrun hdr10 "HDR10,0,0,," "HDR10,0,0,,")
    eq    "HDR10 kept"                              "$(tr '\n' '/' <<< "$rows")" \
          "hdr|dynamic range|preserved|HDR10/hdr10|mastering|preserved|G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)/hdr10|MaxCLL/MaxFALL|preserved|1000,400/"
    unset -f probe_hdr dv_verify_rpu
    source "$W/lib/media_probe.sh" > /dev/null; source "$W/lib/hdr_dovi.sh" > /dev/null

    echo
    echo "== 3c existing files: scan, relink, tag"
    # legacy: an output of an earlier version (COMPRESSION_* tags + a ledger row)
    LEG="$R/out/Legacy (2019).mkv"
    ffmpeg -v error -y -i "$SRC" -map 0 -c copy -metadata COMPRESSION_TOOL=movie-compresser \
        -metadata MOVIE_COMPRESSER_VERSION=v9.0 -metadata COMPRESSION_DATE=2025-03-01 -metadata COMPRESSION_CRF=21 \
        -metadata COMPRESSION_TIER=High "$LEG"
    compression_ledger_add "$W/logs" "$LEG" 21 High 123456 c7 "$R/in/Legacy (2019).mkv"
    PLAIN="$R/out/Plain.mkv"
    ffmpeg -v error -y -i "$SRC" -map 0 -c copy "$PLAIN"
    MOVED="$R/out/Renamed Real Movie.mkv"
    mv "$OUT2" "$MOVED"
    prov scan > "$T/scan.txt" 2>&1
    check "scan: recorded file"                    "grep -A1 -F 'Real Movie (2020) HEVC Custom.mkv' '$T/scan.txt' | grep -q 'provenance recorded (record $ID1, matched by embedded PROVENANCE_ID)'"
    check "scan: legacy file, history recovered with sources" "grep -A12 -F 'Legacy (2019).mkv' '$T/scan.txt' | grep -q 'git_commit = $C1  \[MOVIE_COMPRESSER_VERSION tag, resolved in this checkout\]' && grep -A12 -F 'Legacy (2019).mkv' '$T/scan.txt' | grep -q 'job_session = c7  \[work/logs/compression_tags.tsv (same path)\]'"
    check "scan: plain file unknown, unknowns listed" "grep -A3 -F 'Plain.mkv' '$T/scan.txt' | grep -q 'NO provenance: encoding history unknown' && grep -A12 -F 'Plain.mkv' '$T/scan.txt' | grep -q 'Unknown:    git_commit'"
    check "scan: renamed file found by its ID"       "grep -A3 -F 'Renamed Real Movie.mkv' '$T/scan.txt' | grep -q 'moved/renamed'"
    check "scan: media properties of every file"     "[[ \$(grep -c 'Media now:  hevc 160x90 10-bit\\|Media now:  h264 160x90 8-bit' '$T/scan.txt') -ge 4 ]]"
    check "scan --json is valid"                    "prov scan --json > '$T/scan.json' && J '$T/scan.json' 'len(d[\"files\"])' > /dev/null"
    md5() { "$PY" -c 'import hashlib,sys; print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$(wp "$1")"; }
    mbefore=$(md5 "$M")
    prov relink --dry-run > "$T/relink_dry.txt"
    eq    "relink --dry-run: manifest untouched"     "$(md5 "$M") $(grep -c 'would relink' "$T/relink_dry.txt")" "$mbefore 1"
    prov relink > /dev/null
    eq    "relink: new location recorded, old kept in history" "$(J "$M" "'%s|%s' % (d['records']['$ID2']['current']['name'], [l['reason'] for l in d['records']['$ID2']['locations']])")" "Renamed Real Movie.mkv|['created', 'renamed']"
    lbefore=$(md5 "$LEG"); pbefore=$(md5 "$PLAIN"); mbefore=$(md5 "$M")
    prov tag --dry-run "$LEG" "$PLAIN" > "$T/tag_dry.txt"
    eq    "tag --dry-run: files + manifest untouched" "$(md5 "$LEG") $(md5 "$PLAIN") $(md5 "$M")" "$lbefore $pbefore $mbefore"
    check "tag requires explicit files"             "! prov tag > /dev/null 2>&1"
    hash_streams() { ffmpeg -v error -i "$1" -map 0 -c copy -f streamhash -hash md5 - 2>/dev/null | tr -d '\r'; }
    sb=$(hash_streams "$LEG"); cb=$(chapter_meta "$LEG")
    prov tag "$LEG" "$PLAIN" > "$T/tag.txt" 2>&1
    IDL=$(prov_file_tag "$LEG" PROVENANCE_ID)
    eq    "tag: streams + chapters unchanged"        "$(hash_streams "$LEG" | md5sum | cut -c1-8) $(chapter_meta "$LEG" | md5sum | cut -c1-8)" "$(md5sum <<< "$sb" | cut -c1-8) $(md5sum <<< "$cb" | cut -c1-8)"
    eq    "tag: legacy tags kept, no commit claimed" "$(prov_file_tag "$LEG" MOVIE_COMPRESSER_VERSION) $(prov_file_tag "$LEG" PROVENANCE_STATUS) [$(prov_file_tag "$LEG" PROVENANCE_COMMIT)] [$(prov_file_tag "$PLAIN" PROVENANCE_COMMIT)] $(prov_file_tag "$PLAIN" PROVENANCE_STATUS)" \
          "v9.0 recovered [] [] unknown"
    eq    "tag: record = recovered / unknown; tagging op is not the producer" \
          "$(J "$M" "'%s %s %s' % (d['records']['$IDL']['provenance'], d['records']['$IDL']['operations'][0]['type'], d['records']['$IDL']['original']['recovered']['fields']['crf']['value'])")" "recovered provenance-tag 21.0"
    check "tag: a second run skips tagged files"    "prov tag '$LEG' | grep -q '^skip '"

    echo
    echo "== 3d compare with the current checkout"
    # unknown / current
    prov compare > "$T/cmp0.txt" 2>&1
    check "compare: unchanged checkout -> Current"  "grep -A1 -F 'Real Movie (2020) HEVC Custom.mkv' '$T/cmp0.txt' | grep -q '^  Current'"
    check "compare: adopted file -> Unknown provenance" "grep -A1 -F 'Plain.mkv' '$T/cmp0.txt' | grep -q 'Unknown provenance'"
    # a docs / tests only change -> older, unaffected
    echo "more" >> "$R/README.md"; mkdir -p "$R/work/tests"; echo "# t" > "$R/work/tests/x_tests.sh"
    g "$R" add -A >/dev/null 2>&1; g "$R" commit -qm docs >/dev/null 2>&1
    # comment-only change in the encoder: still unaffected
    sed -i '0,/^# Global tags of a CRF encode/s//# Global tags of a CRF encode (comment edited)/' "$R/work/lib/encode_common.sh"
    g "$R" commit -qam comment >/dev/null 2>&1
    prov compare > "$T/cmp1.txt" 2>&1
    check "compare: docs/tests/comments -> older, unaffected" "grep -A1 -F 'Real Movie (2020) HEVC Custom.mkv' '$T/cmp1.txt' | grep -q 'Older version, no relevant processing changes'"
    # an HDR-only change: irrelevant for this SDR file
    sed -i 's/^dv_compat_name() {/dv_compat_name() {\n    : changed/' "$R/work/lib/hdr_dovi.sh"
    g "$R" commit -qam hdr >/dev/null 2>&1
    prov compare --json > "$T/cmp2.json" 2>&1
    eq    "compare: HDR change, SDR file -> unaffected" "$(J "$T/cmp2.json" "[f['class'] for f in d['files'] if f['id'] == '$ID1'][0]")" older-unaffected
    # a title-only change: a note, not a re-encode reason
    sed -i 's/^video_std_title() {/video_std_title() {\n    : changed/' "$R/work/lib/encode_common.sh"
    g "$R" commit -qam titles >/dev/null 2>&1
    prov compare --json > "$T/cmp3.json" 2>&1
    eq    "compare: title logic -> unaffected + metadata note" "$(J "$T/cmp3.json" "[[f['class'], 'video_std_title' in ' '.join(f['notes'])] for f in d['files'] if f['id'] == '$ID1'][0]")" '["older-unaffected", true]'
    # an encoder change -> potentially affected; unclassified -> manual review
    sed -i 's/^crf_x265_params() {/crf_x265_params() {\n    : changed/' "$R/work/lib/encode_common.sh"
    g "$R" commit -qam encoder >/dev/null 2>&1
    prov compare > "$T/cmp4.txt" 2>&1
    check "compare: encoder change -> potentially affected (function named)" "grep -A2 -F 'Real Movie (2020) HEVC Custom.mkv' '$T/cmp4.txt' | grep -q 'Potentially affected' && grep -A3 -F 'Real Movie (2020) HEVC Custom.mkv' '$T/cmp4.txt' | grep -q 'crf_x265_params \[encoder\]'"
    check "compare: never recommends re-encoding"   "grep -q 'Nothing is re-encoded or recommended for re-encoding automatically' '$T/cmp4.txt'"
    g "$R" revert --no-edit HEAD >/dev/null 2>&1
    echo 'x=1' > "$R/work/lib/new_helper.sh"; g "$R" add -A >/dev/null; g "$R" commit -qm unknown >/dev/null 2>&1
    prov compare --json > "$T/cmp5.json" 2>&1
    eq    "compare: unclassified change -> manual review" "$(J "$T/cmp5.json" "[f['class'] for f in d['files'] if f['id'] == '$ID1'][0]")" manual-review
    "$PY" - "$(wp "$M")" "$ID1" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["records"][sys.argv[2]]["original"]["git"]["commit"] = "0" * 40
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"))
PYEOF
    prov compare --json > "$T/cmp6.json" 2>&1
    eq    "compare: commit not in the repository -> manual review" "$(J "$T/cmp6.json" "[f['class'] for f in d['files'] if f['id'] == '$ID1'][0]")" manual-review
    eq    "compare: read-only (no file changed)"      "$(prov_file_tag "$OUT1" PROVENANCE_COMMIT)" "$C3"
fi

echo
(( ${#SKIPPED[@]} )) && printf 'skipped: %s\n' "${SKIPPED[@]}"
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
