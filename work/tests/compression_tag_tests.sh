#!/usr/bin/env bash
# COMPRESSION_CRF / COMPRESSION_TIER output tags and the provenance tags
# COMPRESSION_TOOL / MOVIE_COMPRESSER_VERSION / COMPRESSION_DATE
# (encode_common.sh mkv_set_compression_tags, job_runtime.sh
# item_tag_compression, media_probe.sh compression_tags / compression_provenance /
# compression_tag_lines, verify.sh). Version detection itself:
# compresser_version_tests.sh.
#
#   bash ~/compress/work/tests/compression_tag_tests.sh
#
# Part 1 (no media tools): generated jobs (emit_encode_item, stand-in
# probes) run with a stand-in encoder and stand-in mkvextract /
# mkvpropedit that keep the "tags XML" inside the stand-in output file.
# The tags carry the FINAL CRF (after the CRF retries / season decision),
# are written before the verification and survive the rename to the
# final name; source tags stay; stream copies and two-pass encodes get
# none. A tag write that would lose other tags is undone. Every CRF
# output (movie Quality / High / Base / Compact / Custom, series High /
# Base / Compact / Custom, scaled or not) also gets the provenance tags:
# the version taken when the job was generated (not when an item ends),
# today's UTC date, each name once, earlier / source values replaced.
# Without a version (Validate + update) existing provenance is kept and
# none is added.
# Part 2 (no media tools): the verification report lines (ffprobe
# stand-in): values, "not recorded" for outputs of earlier versions.
# Part 3 (needs ffmpeg): verify.sh on an output without the tags (earlier
# versions) and on a tagged one.
# Part 4 (needs ffmpeg + mkvtoolnix): mkv_set_compression_tags on a real
# MKV keeps every global / track tag and the chapters, replaces earlier
# compression values, and the tags survive the statistics refresh.
# Jobs also record the final CRF in work/logs/compression_tags.tsv;
# compression_record_lookup (no media tools) only accepts records of the
# exact encode. Part 5 (needs ffmpeg + mkvtoolnix): verify.sh Verify
# writes nothing; Validate + update backfills / corrects from the records,
# leaves files without a record alone, and a repeat run changes nothing.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${TAG_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0
SKIPPED=()

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE SERIES_CRF_SHARED
G=1073741824
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }

W="$T/work"
mkdir -p "$W/logs" "$T/in/Show" "$T/out/Show" "$T/stub"
cp -r "$SRC_WORK/lib" "$W/"
WORK_DIR="$W"
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy naming job_runtime; do
    source "$W/lib/$l.sh" > /dev/null
done
# the version the generated jobs record (emit_job_header); the jobs
# themselves would detect something else (see STUBS)
TV="v1.4.2-5-ga3f8c21-dirty"
compresser_version() { echo "$TV"; }
TD=$(date -u +%Y-%m-%d)
PROV="COMPRESSION_TOOL=movie-compresser MOVIE_COMPRESSER_VERSION=$TV COMPRESSION_DATE=$TD "

# real tools (parts 3 / 4) are looked up before the stand-ins shadow them
HAVE_FFMPEG=0
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null && HAVE_FFMPEG=1
HAVE_MKV=0
command -v mkvpropedit >/dev/null && command -v mkvextract >/dev/null && HAVE_MKV=1
REAL_PATH="$PATH"

printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"

# Stand-in output file: line 1 "VIDEO_BYTES AUDIO_BYTES CRF", then
# "#TAGS" and the file's tags XML (what mkvextract would print).
cat > "$T/stub/mkvextract" <<'EOF'
#!/usr/bin/env bash
# mkvextract FILE tags OUT
[[ "$2" == tags ]] || exit 2
grep -qx '#TAGS' "$1" || exit 0
sed '1,/^#TAGS$/d' "$1" > "$3"
EOF
cat > "$T/stub/mkvpropedit" <<'EOF'
#!/usr/bin/env bash
# mkvpropedit FILE --tags all:XML  (all: alone removes every tag)
f="$1"; shift
echo "${f##*/} $*" >> "$STUB_LOG"
while (( $# )); do
    case "$1" in
        --tags)
            x="${2#all:}"; shift 2
            {
                sed '/^#TAGS$/,$d' "$f"
                if [[ -n "$x" ]]; then
                    echo '#TAGS'
                    # STUB_DROP=NAME: a lossy writer (drops that tag
                    # on its first write; the restore write is exact)
                    if [[ -n "${STUB_DROP:-}" && ! -e "$STUB_LOG.dropped" ]]; then
                        : > "$STUB_LOG.dropped"
                        awk -v n="${STUB_DROP}" '/<Simple>/ { b = $0 "\n"; ins = 1; next }
                            ins { b = b $0 "\n"; if (/<\/Simple>/) { ins = 0; if (b !~ "<Name>" n "</Name>") printf "%s", b }; next }
                            { print }' "$x"
                    else
                        cat "$x"
                    fi
                fi
            } > "$f.stubtmp" && cat "$f.stubtmp" > "$f" && rm -f "$f.stubtmp"
            ;;
        *) shift ;;
    esac
done
exit 0
EOF
chmod +x "$T/stub/"*
export PATH="$T/stub:$PATH"
export STUB_LOG="$T/propedit.log"

# tagval FILE NAME [global|track]  ->  values of simple tag NAME in the
# stand-in file's tags XML (one per line)
tagval() {
    sed '1,/^#TAGS$/d' "$1" 2>/dev/null | awk -v n="$2" -v want="${3:-global}" '
        /<Tag>/        { g = 1 }
        /UID>/         { g = 0 }
        $0 ~ "<Name>" n "</Name>" { hit = 1; next }
        hit && /<String>/ {
            v = $0; sub(/.*<String>/, "", v); sub(/<\/String>.*/, "", v)
            if ((want == "global") == g) print v
            hit = 0
        }'
}
# taglist FILE  ->  "NAME=VALUE" of every simple tag, in file order
taglist() {
    sed '1,/^#TAGS$/d' "$1" 2>/dev/null | awk '
        /<Name>/   { n = $0; sub(/.*<Name>/, "", n); sub(/<\/Name>.*/, "", n) }
        /<String>/ { v = $0; sub(/.*<String>/, "", v); sub(/<\/String>.*/, "", v); printf "%s=%s ", n, v }'
}

# source tags an encode copies (ffmpeg -map_metadata 0): global title +
# a custom global tag, an ENCODER tag, a track tag; source 2 also carries
# compression tags of an earlier encode (they must be replaced, once)
SRC_TAGS='<?xml version="1.0"?>
<!-- <!DOCTYPE Tags SYSTEM "matroskatags.dtd"> -->

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
      <Simple>
        <Name>NESTED</Name>
        <String>child</String>
      </Simple>
    </Simple>
    <Simple>
      <Name>ENCODER</Name>
      <String>Lavf61.7.100</String>
    </Simple>
  </Tag>
  <Tag>
    <Targets>
      <TrackUID>1234567</TrackUID>
    </Targets>
    <Simple>
      <Name>COMPRESSION_CRF</Name>
      <String>track-level stays</String>
    </Simple>
    <Simple>
      <Name>DURATION</Name>
      <String>00:01:40.000000000</String>
    </Simple>
  </Tag>
</Tags>'
OLD_TAGS="${SRC_TAGS%</Tags>}"'  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>COMPRESSION_TOOL</Name>
      <String>movie-compresser</String>
    </Simple>
    <Simple>
      <Name>MOVIE_COMPRESSER_VERSION</Name>
      <String>v0.9.0</String>
    </Simple>
    <Simple>
      <Name>COMPRESSION_DATE</Name>
      <String>2025-01-01</String>
    </Simple>
    <Simple>
      <Name>COMPRESSION_CRF</Name>
      <String>30</String>
    </Simple>
    <Simple>
      <Name>COMPRESSION_TIER</Name>
      <String>Base</String>
    </Simple>
  </Tag>
  <Tag>
    <Targets />
    <Simple>
      <Name>MOVIE_COMPRESSER_VERSION</Name>
      <String>v0.8.0</String>
    </Simple>
  </Tag>
</Tags>'
for m in High Base Q C Copy Abr New L N K; do echo "movie $m" > "$T/in/$m.mkv"; done
printf '%s\n' "$SRC_TAGS" > "$T/src_tags.xml"
printf '%s\n' "$OLD_TAGS" > "$T/old_tags.xml"
SRC_LIST="TITLE=Test Movie SOURCE_NOTE=keep me NESTED=child ENCODER=Lavf61.7.100 COMPRESSION_CRF=track-level stays DURATION=00:01:40.000000000 "

# ------------------------------------------------------------
# Generator stand-ins (no ffprobe): one video stream, SDR, no covers
main_video_index()   { echo 0; }
probe_hdr()          { HDR_DV=0; HDR_HDR10PLUS=0; HDR_DV_PROFILE=""; }
build_stream_map()   { MAP_ARGS="-map 0:0"; MAP_CODEC_ARGS=""; MAP_META_ARGS=""; MAP_OTHER_ARGS=""; MAP_COVERS=(); MAP_NOTES=(); }
x265_color_params()  { :; }
color_output_args()  { :; }
libx265_has_option() { return 1; }
stale_stats_args()   { :; }
matroska_mux_args()  { :; }

# Job stand-ins: the "encoder" writes "VIDEO AUDIO CRF" from
# SIZES[ITEM:CRF] (non-CRF items: SIZES[ITEM:-]) plus the source tags
# (SRCTAGS[ITEM], ffmpeg -map_metadata 0); the verification records the
# CRF it verified and the COMPRESSION_CRF tag the file had at that time.
STUBS='
# a checkout that changed after the job was generated: never asked again
compresser_version() { echo CHANGED-DURING-JOB; }
get_duration() { echo 100; }
media_stream_totals() { local v a c; read -r v a c < "$1"; echo "$v $a"; }
item_verify_output() {
    local t
    t=$(sed "1,/^#TAGS\$/d" "$ITEM_PART" | awk "/<Name>COMPRESSION_CRF<\\/Name>/ { h = 1; next } h && /<String>/ { gsub(/.*<String>|<\\/String>.*/, \"\"); v = \$0; h = 0 } END { print v }")
    echo "$ITEM_INDEX:${ITEM_EXP[crf]:-}:${t:--}" >> "'"$T"'/$JOB_SESSION.verified"
}
item_restore_mkv_chapters() { return 0; }
item_step() { shift; "$@"; }
refresh_mkv_stats() { return 0; }
# the measured final video bytes (job_runtime.sh report_output_stats)
report_output_stats() { local v a; read -r v a <<< "$(media_stream_totals "$1")"; ITEM_FINAL_VBYTES="$v"; }
item_run() {
    local c="${ITEM_EXP[crf]:-}" s
    [[ "$1" == 1/2 ]] && return 0
    [[ "${ITEM_EXP[mode]:-}" == crf ]] || c=-
    s="${SIZES[$ITEM_INDEX:$c]:-}"
    echo "$ITEM_INDEX:$c" >> "'"$T"'/$JOB_SESSION.encoded"
    [[ -z "$s" || "$s" == fail ]] && return 1
    { echo "$s $c"; if [[ -n "${SRCTAGS[$ITEM_INDEX]:-}" ]]; then echo "#TAGS"; cat "${SRCTAGS[$ITEM_INDEX]}"; fi; } > "$ITEM_PART"
}
'

# run_job SESSION TYPE N GENERATED_ITEMS SIZES SRCTAGS [EXTRA_STUBS]  ->  runs the job
run_job() {
    local s="$1" type="$2" n="$3" items="$4" sizes="$5" src="${6:-}" extra="${7:-}"
    rm -f "$T/$s.encoded" "$T/$s.verified" "$STUB_LOG" "$STUB_LOG.dropped"
    {
        emit_job_header "$s" "$type" "$n"
        printf '%s\n' "$STUBS" "declare -A SIZES=($sizes)" "declare -A SRCTAGS=($src)" "$extra"
        printf '%s\n' "$items"
        emit_job_footer
    } > "$W/$s.sh"
    bash -n "$W/$s.sh" || { bad "$s: generated job fails bash -n"; return; }
    cp "$W/$s.sh" "$T/$s.job"   # a finished job deletes its own script
    bash "$W/$s.sh" < /dev/null > "$T/$s.log" 2>&1
}
verified()  { tr '\n' ' ' < "$T/$1.verified" 2>/dev/null; }
logged()    { grep -qF -- "$2" "$T/$1.log"; }
first()     { awk '{ print $3; exit }' "$1"; }
# sz ITEM:CRF VIDEO_GIB  ->  one SIZES entry (0.5 GiB audio)
sz() { printf "[%s]='%s %s'" "$1" "$(gib "$2")" "$(gib 0.5)"; }

# ------------------------------------------------------------
echo "== movie High: tags carry the CRF the retry accepted"

# planned 20 is over the 5 GiB ceiling, 21 fits, 20 already over -> 21
spec="$(gib 5):24:18:0:1:::boundary"
items=$(emit_encode_item 1 "$T/in/High.mkv" "$T/out/High.mkv" High crf:20 "" "" 0 "$(gib 4.8)" "$spec")
run_job mh movie 1 "$items" "$(sz 1:20 5.4) $(sz 1:21 4.6)" "[1]='$T/src_tags.xml'"
eq    "High: final output CRF 21"                "$(first "$T/out/High.mkv")" 21
eq    "High: COMPRESSION_CRF=21 (not planned 20)" "$(tagval "$T/out/High.mkv" COMPRESSION_CRF)" 21
eq    "High: COMPRESSION_TIER=High"              "$(tagval "$T/out/High.mkv" COMPRESSION_TIER)" High
eq    "High: tagged before verification"         "$(verified mh)" "1:21:21 "
check "High: one tag write (accepted attempt only)" "[[ \$(grep -c -- '--tags' '$STUB_LOG') == 1 ]]"
eq    "High: source tags intact + compression tags" "$(taglist "$T/out/High.mkv")" "${SRC_LIST}${PROV}COMPRESSION_CRF=21 COMPRESSION_TIER=High "
eq    "High: track-level COMPRESSION_CRF untouched" "$(tagval "$T/out/High.mkv" COMPRESSION_CRF track)" "track-level stays"
check "High: pane shows the tags"                "logged mh 'Recording compression tags: COMPRESSION_CRF=21 COMPRESSION_TIER=High'"
check "High: job ok"                             "logged mh 'All encodes finished: 1 ok, 0 failed'"
# gcounts FILE  ->  how many global values each compression tag has
gcounts() { local n; for n in COMPRESSION_TOOL MOVIE_COMPRESSER_VERSION COMPRESSION_DATE COMPRESSION_CRF COMPRESSION_TIER; do printf '%s ' "$(tagval "$1" "$n" | grep -c '')"; done; }
eq    "High: each compression tag once after the retry" "$(gcounts "$T/out/High.mkv")" "1 1 1 1 1 "
eq    "High: COMPRESSION_TOOL"                   "$(tagval "$T/out/High.mkv" COMPRESSION_TOOL)" movie-compresser
eq    "High: version taken when the job was generated" "$(tagval "$T/out/High.mkv" MOVIE_COMPRESSER_VERSION)" "$TV"
eq    "High: COMPRESSION_DATE today (UTC)"       "$(tagval "$T/out/High.mkv" COMPRESSION_DATE)" "$TD"
check "High: job header holds the version"       "grep -qx 'JOB_COMPRESSER_VERSION=$TV' '$T/mh.job'"
check "High: encode drops provenance copied from the source" \
      "grep -q -- '-metadata COMPRESSION_TOOL= -metadata MOVIE_COMPRESSER_VERSION= -metadata COMPRESSION_DATE=' '$T/mh.job'"
check "High: pane shows the version"             "logged mh 'MOVIE_COMPRESSER_VERSION=$TV COMPRESSION_DATE=$TD'"
LEDGER="$W/logs/compression_tags.tsv"
# ledger ROW_FILTER  ->  "file crf tier video_bytes" of matching ledger rows
ledger() { awk -F'\t' -v p="$1" 'NR > 1 && $2 ~ p { o = $2; sub(/.*\//, "", o); printf "%s %s %s %s|", o, $3, $4, $5 }' "$LEDGER"; }
eq    "High: ledger row (final CRF, measured bytes)" "$(ledger 'High[.]mkv$')" "High.mkv 21 High $(gib 4.6)|"

echo
echo "== movie Base: lower CRF test accepted"

# planned 26 fits the 2 GiB ceiling, the CRF 25 test fits too -> 25
spec="$(gib 2):28:22:0:1:::boundary"
items=$(emit_encode_item 1 "$T/in/Base.mkv" "$T/out/Base.mkv" Base crf:26 "" "" 0 "$(gib 1.8)" "$spec")
run_job mb movie 1 "$items" "$(sz 1:26 1.6) $(sz 1:25 1.9)" "[1]='$T/old_tags.xml'"
eq    "Base: final output CRF 25"                "$(first "$T/out/Base.mkv")" 25
eq    "Base: COMPRESSION_CRF=25"                 "$(tagval "$T/out/Base.mkv" COMPRESSION_CRF)" 25
eq    "Base: COMPRESSION_TIER=Base"              "$(tagval "$T/out/Base.mkv" COMPRESSION_TIER)" Base
eq    "Base: earlier compression values replaced, once" "$(taglist "$T/out/Base.mkv")" "${SRC_LIST}${PROV}COMPRESSION_CRF=25 COMPRESSION_TIER=Base "
check "Base: no attempt files left"              "[[ -z \$(find '$T/out' -name 'Base.mkv.*') ]]"
eq    "Base: the source's older versions not kept" "$(tagval "$T/out/Base.mkv" MOVIE_COMPRESSER_VERSION)" "$TV"
eq    "Base: each compression tag once"          "$(gcounts "$T/out/Base.mkv")" "1 1 1 1 1 "

echo
echo "== movie Quality (CRF search): band retry"

# the CRF search planned 20; the actual video is below the 6-8 GiB band
# -> CRF 19 lands in the band -> 19
spec="$(gib 8):24:16:0:2"
q="$(gib 7):$(gib 6):$(gib 8):band"
items=$(emit_encode_item 1 "$T/in/Q.mkv" "$T/out/Q.mkv" Quality crf:20 "" "" 0 "$(gib 7)" "$spec" "$q")
run_job mq movie 1 "$items" "$(sz 1:20 5.5) $(sz 1:19 6.5)" "[1]='$T/src_tags.xml'"
eq    "Quality: CRF 20 then 19 encoded"          "$(tr '\n' ' ' < "$T/mq.encoded")" "1:20 1:19 "
eq    "Quality: COMPRESSION_CRF=19"              "$(tagval "$T/out/Q.mkv" COMPRESSION_CRF)" 19
eq    "Quality: COMPRESSION_TIER=Quality"        "$(tagval "$T/out/Q.mkv" COMPRESSION_TIER)" Quality
eq    "Quality: tagged before verification"      "$(verified mq)" "1:19:19 "
eq    "Quality: provenance, once"                "$(taglist "$T/out/Q.mkv")" "${SRC_LIST}${PROV}COMPRESSION_CRF=19 COMPRESSION_TIER=Quality "

echo
echo "== series shared season CRF"

# CRF 16: episode 2 over the 5 GiB ceiling -> the season moves to 17
# (fits), 16 was over -> every episode at 17
for e in 1 2 3; do echo "episode $e" > "$T/in/Show/Show.S01E0$e.mkv"; done
spec=$(series_season_retry_spec High "$(gib 5)" 19 16)
items=""
for e in 1 2 3; do
    items+=$(emit_encode_item "$e" "$T/in/Show/Show.S01E0$e.mkv" "$T/out/Show/E0$e.mkv" High crf:16 "" "" 0 \
        "$(gib 4.5)" "$spec" "" "15=$(gib 5):16=$(gib 4.5)")$'\n'
done
run_job ss series 3 "$items" "$(sz 1:16 4) $(sz 2:16 5.5) $(sz 3:16 4) $(sz 1:17 3.5) $(sz 2:17 4.8) $(sz 3:17 3.5)" \
    "[1]='$T/src_tags.xml' [2]='$T/src_tags.xml' [3]='$T/src_tags.xml'"
check "series: season batch job"                 "grep -q '^job_crf_batch\$' '$T/ss.job' && grep -q ' batch_mode=season' '$T/ss.job'"
eq    "series: every episode tagged 17"          "$(for e in 1 2 3; do tagval "$T/out/Show/E0$e.mkv" COMPRESSION_CRF; done | tr '\n' ' ')" "17 17 17 "
eq    "series: every episode tier High"          "$(for e in 1 2 3; do tagval "$T/out/Show/E0$e.mkv" COMPRESSION_TIER; done | tr '\n' ' ')" "High High High "
eq    "series: tagged before verification"       "$(verified ss)" "1:17:17 2:17:17 3:17:17 "
eq    "series: source tags intact"               "$(taglist "$T/out/Show/E02.mkv")" "${SRC_LIST}${PROV}COMPRESSION_CRF=17 COMPRESSION_TIER=High "
eq    "series: ledger row per episode at 17"     "$(ledger '/Show/E0')" "E01.mkv 17 High $(gib 3.5)|E02.mkv 17 High $(gib 4.8)|E03.mkv 17 High $(gib 3.5)|"
eq    "series: same version on every episode"    "$(for e in 1 2 3; do tagval "$T/out/Show/E0$e.mkv" MOVIE_COMPRESSER_VERSION; done | tr '\n' ' ')" "$TV $TV $TV "
eq    "series: each tag once after the season retry" "$(for e in 1 2 3; do gcounts "$T/out/Show/E0$e.mkv"; done)" "1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 "

echo
echo "== Custom CRF"

items=$(emit_encode_item 1 "$T/in/C.mkv" "$T/out/C.mkv" Custom crf:23.5 "" "" 0 "$(gib 3)")
run_job mc movie 1 "$items" "$(sz 1:23.5 3)" "[1]='$T/src_tags.xml'"
eq    "Custom: COMPRESSION_CRF = user CRF"       "$(tagval "$T/out/C.mkv" COMPRESSION_CRF)" 23.5
eq    "Custom: COMPRESSION_TIER=Custom"          "$(tagval "$T/out/C.mkv" COMPRESSION_TIER)" Custom
eq    "Custom: no retry"                         "$(tr '\n' ' ' < "$T/mc.encoded")" "1:23.5 "
eq    "Custom: provenance"                       "$(taglist "$T/out/C.mkv")" "${SRC_LIST}${PROV}COMPRESSION_CRF=23.5 COMPRESSION_TIER=Custom "

echo
echo "== movie Compact (scaled to 1080p); series Base / Compact / Custom episodes"

items=$(emit_encode_item 1 "$T/in/K.mkv" "$T/out/K.mkv" Compact crf:27 "$DOWNSCALE_1080P_FILTER" "" 0 "$(gib 1)")
run_job mk movie 1 "$items" "$(sz 1:27 1)" "[1]='$T/src_tags.xml'"
check "Compact: scaled encode"                   "grep -q 'force_divisible_by=2' '$T/mk.job'"
eq    "Compact: tags"                            "$(taglist "$T/out/K.mkv")" "${SRC_LIST}${PROV}COMPRESSION_CRF=27 COMPRESSION_TIER=Compact "
mkdir -p "$T/in/Show2" "$T/out/Show2"
items=""
e=0
for t in Base:24 Compact:28 Custom:22.5; do
    ((e += 1))
    echo "episode $e" > "$T/in/Show2/Show2.S01E0$e.mkv"
    items+=$(emit_encode_item "$e" "$T/in/Show2/Show2.S01E0$e.mkv" "$T/out/Show2/E0$e.mkv" "${t%%:*}" "crf:${t#*:}" \
        "$( ((e == 2)) && printf '%s' "$DOWNSCALE_1080P_FILTER")" "" 0 "$(gib 1)")$'\n'
done
run_job sb series 3 "$items" "$(sz 1:24 1) $(sz 2:28 1) $(sz 3:22.5 1)" "[1]='$T/old_tags.xml' [2]='$T/src_tags.xml'"
eq    "series tiers: CRF / tier per episode"     "$(for e in 1 2 3; do printf '%s/%s ' "$(tagval "$T/out/Show2/E0$e.mkv" COMPRESSION_CRF)" "$(tagval "$T/out/Show2/E0$e.mkv" COMPRESSION_TIER)"; done)" \
      "24/Base 28/Compact 22.5/Custom "
eq    "series tiers: provenance on every episode" "$(for e in 1 2 3; do printf '%s|' "$(tagval "$T/out/Show2/E0$e.mkv" COMPRESSION_TOOL) $(tagval "$T/out/Show2/E0$e.mkv" MOVIE_COMPRESSER_VERSION) $(tagval "$T/out/Show2/E0$e.mkv" COMPRESSION_DATE)"; done)" \
      "movie-compresser $TV $TD|movie-compresser $TV $TD|movie-compresser $TV $TD|"
eq    "series tiers: each tag once (older provenance in a source replaced)" "$(for e in 1 2 3; do gcounts "$T/out/Show2/E0$e.mkv"; done)" "1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 "
eq    "series tiers: untagged source gets only the compression tags" "$(taglist "$T/out/Show2/E03.mkv")" "${PROV}COMPRESSION_CRF=22.5 COMPRESSION_TIER=Custom "

echo
echo "== no CRF: stream copy, two-pass, untagged source"

items=$(emit_encode_item 1 "$T/in/Copy.mkv" "$T/out/Copy.mkv" Quality copy "" "" 0)$'\n'
items+=$(emit_encode_item 2 "$T/in/Abr.mkv" "$T/out/Abr.mkv" High 1500 "" "$T/pass" 0)$'\n'
items+=$(emit_encode_item 3 "$T/in/New.mkv" "$T/out/New.mkv" High crf:19 "" "" 0)
run_job nc movie 3 "$items" "[1:-]='1 1' [2:-]='1 1' $(sz 3:19 3)" "[1]='$T/src_tags.xml' [2]='$T/src_tags.xml'"
check "copy: job ok (3 items)"                   "logged nc 'All encodes finished: 3 ok, 0 failed'"
eq    "copy: no COMPRESSION_CRF"                 "$(tagval "$T/out/Copy.mkv" COMPRESSION_CRF)" ""
eq    "copy: source tags unchanged"              "$(taglist "$T/out/Copy.mkv")" "$SRC_LIST"
eq    "two-pass: no COMPRESSION_CRF"             "$(tagval "$T/out/Abr.mkv" COMPRESSION_CRF)" ""
eq    "two-pass: source tags unchanged"          "$(taglist "$T/out/Abr.mkv")" "$SRC_LIST"
check "copy / two-pass: mkvpropedit not run on them" "! grep -qE '^(Copy|Abr)\\.mkv' '$STUB_LOG'"
eq    "copy / two-pass: no ledger row"           "$(ledger '(Copy|Abr)[.]mkv$')" ""
eq    "copy / two-pass: no provenance written"   "$(tagval "$T/out/Copy.mkv" MOVIE_COMPRESSER_VERSION)$(tagval "$T/out/Abr.mkv" MOVIE_COMPRESSER_VERSION)" ""
eq    "untagged source: only the compression tags" "$(taglist "$T/out/New.mkv")" "${PROV}COMPRESSION_CRF=19 COMPRESSION_TIER=High "

echo
echo "== failures are warnings, never lose tags"

# a writer that loses a source tag: the original tag set is restored
items=$(emit_encode_item 1 "$T/in/L.mkv" "$T/out/L.mkv" Custom crf:20 "" "" 0)
STUB_DROP=SOURCE_NOTE run_job lossy movie 1 "$items" "$(sz 1:20 3)" "[1]='$T/src_tags.xml'"
check "lossy writer: item still ok"              "logged lossy 'All encodes finished: 1 ok, 0 failed'"
check "lossy writer: warned"                     "logged lossy 'WARNING: compression tags not written (exit 7'"
eq    "lossy writer: original tags restored"     "$(taglist "$T/out/L.mkv")" "$SRC_LIST"

# no mkvtoolnix (mkv_set_compression_tags exit 3): a warning, the
# encode is kept unchanged
items=$(emit_encode_item 1 "$T/in/N.mkv" "$T/out/N.mkv" Custom crf:20 "" "" 0)
run_job nomkv movie 1 "$items" "$(sz 1:20 3)" "[1]='$T/src_tags.xml'" \
    'command() { [[ "$1 ${2:-}" == "-v mkvextract" ]] && return 1; builtin command "$@"; }'
check "no mkvtoolnix: item ok, warned"           "logged nomkv 'All encodes finished: 1 ok, 0 failed' && logged nomkv 'WARNING: compression tags not written (mkvtoolnix missing).'"
eq    "no mkvtoolnix: tags unchanged"            "$(taglist "$T/out/N.mkv")" "$SRC_LIST"

echo
echo "== writes without a version (Validate + update): provenance kept, none invented"

cp "$T/out/High.mkv" "$T/bf1.mkv"
mkv_set_compression_tags "$T/bf1.mkv" 22 High "$T/bft1"
eq    "backfill: written"                        "$?" 0
eq    "backfill: CRF corrected, provenance of the encode kept" \
      "$(taglist "$T/bf1.mkv")" "${SRC_LIST}${PROV}COMPRESSION_CRF=22 COMPRESSION_TIER=High "
eq    "backfill: each compression tag once"      "$(gcounts "$T/bf1.mkv")" "1 1 1 1 1 "
{ echo "1 1 21"; echo "#TAGS"; cat "$T/old_tags.xml"; } > "$T/bf2.mkv"
mkv_set_compression_tags "$T/bf2.mkv" 21 High "$T/bft2"
eq    "backfill: historical versions left exactly as stored" "$(tagval "$T/bf2.mkv" MOVIE_COMPRESSER_VERSION | tr '\n' ' ')" "v0.9.0 v0.8.0 "
eq    "backfill: historical date kept"           "$(tagval "$T/bf2.mkv" COMPRESSION_DATE)" 2025-01-01
{ echo "1 1 21"; echo "#TAGS"; cat "$T/src_tags.xml"; } > "$T/bf3.mkv"
mkv_set_compression_tags "$T/bf3.mkv" 21 High "$T/bft3"
eq    "backfill: older output gets no version"   "$(taglist "$T/bf3.mkv")" "${SRC_LIST}COMPRESSION_CRF=21 COMPRESSION_TIER=High "

echo
echo "== provenance values: XML escaping, invalid values refused"

echo "1 1 20" > "$T/esc.mkv"
mkv_set_compression_tags "$T/esc.mkv" 20 Custom "$T/esct" 'v2.0-rc&<x>' "$TD"
eq    "special characters: written"              "$?" 0
eq    "special characters: read back unchanged"  "$(sed '1,/^#TAGS$/d' "$T/esc.mkv" > "$T/esc.xml"; mkv_global_tag_values "$T/esc.xml" MOVIE_COMPRESSER_VERSION)" 'v2.0-rc&<x>'
cp "$T/esc.mkv" "$T/esc0.mkv"
mkv_set_compression_tags "$T/esc.mkv" 20 Custom "$T/esct2" 'has space' "$TD"
eq    "version with a space refused"             "$?" 2
mkv_set_compression_tags "$T/esc.mkv" 20 Custom "$T/esct3" v1.0 "19/10/2026"
eq    "non-ISO date refused"                     "$?" 2
check "refused writes leave the file unchanged"  "cmp -s '$T/esc.mkv' '$T/esc0.mkv'"

echo
echo "== compression tags stored more than once (compression_tag_duplicates)"

eq    "conflicting values reported"              "$(compression_tag_duplicates "$T/bf2.mkv")" $'MOVIE_COMPRESSER_VERSION\tconflict\tv0.9.0, v0.8.0'
eq    "clean output: nothing reported"           "$(compression_tag_duplicates "$T/out/High.mkv")" ""
{ echo "1 1 21"; echo "#TAGS"; sed 's/v0\.8\.0/v0.9.0/' "$T/old_tags.xml"; } > "$T/dup.mkv"
eq    "same value twice: duplicate, not conflict" "$(compression_tag_duplicates "$T/dup.mkv")" $'MOVIE_COMPRESSER_VERSION\tduplicate\tv0.9.0, v0.9.0'

# ------------------------------------------------------------
echo
echo "== verification report lines (ffprobe stand-in)"

FAKE_TAGS=""
ffprobe() { [[ -n "$FAKE_TAGS" ]] && printf '%s\n' "$FAKE_TAGS"; return 0; }
NR3=$'Compression tool\tNot recorded\nCompressor version\tNot recorded\nCompression date\tNot recorded'
FAKE_TAGS=$'TAG:title=Test Movie\r\nTAG:COMPRESSION_TOOL=movie-compresser\r\nTAG:MOVIE_COMPRESSER_VERSION=v1.4.2-5-ga3f8c21-dirty\r\nTAG:COMPRESSION_DATE=2026-10-19\r\nTAG:COMPRESSION_CRF=23\r\nTAG:COMPRESSION_TIER=Base\r\nTAG:ENCODER=Lavf61.7.100\r'
eq    "current output: all five rows"            "$(compression_tag_lines x.mkv)" \
      $'Compression tool\tmovie-compresser\nCompressor version\tv1.4.2-5-ga3f8c21-dirty\nCompression date\t2026-10-19\nCompression tier\tBase\nCompression CRF\t23'
eq    "provenance values"                        "$(compression_provenance x.mkv)" $'movie-compresser\tv1.4.2-5-ga3f8c21-dirty\t2026-10-19'
FAKE_TAGS=$'TAG:title=Test Movie\r\nTAG:COMPRESSION_CRF=21\r\nTAG:COMPRESSION_TIER=High\r'
eq    "tagged before version tagging: Not recorded, nothing invented" "$(compression_tag_lines x.mkv)" "$NR3"$'\nCompression tier\tHigh\nCompression CRF\t21'
FAKE_TAGS=$'TAG:title=Old Output\nTAG:ENCODER=Lavf61.7.100'
eq    "earlier output: Not recorded (ENCODER is not the compressor version)" "$(compression_tag_lines x.mkv)" "$NR3"$'\nCompression tier\tNot recorded\nCompression CRF\tNot recorded'
FAKE_TAGS=""
eq    "no tags at all: Not recorded"             "$(compression_tag_lines x.mkv)" "$NR3"$'\nCompression tier\tNot recorded\nCompression CRF\tNot recorded'
FAKE_TAGS=$'TAG:MOVIE/COMPRESSION_CRF=18\nTAG:compression_tier=Quality'
eq    "target-prefixed / lower-case keys"        "$(compression_tags x.mkv)" $'18\tQuality'
FAKE_TAGS=$'TAG:MOVIE/MOVIE_COMPRESSER_VERSION=abc1234\nTAG:compression_tool=movie-compresser'
eq    "provenance: target-prefixed / lower-case keys" "$(compression_provenance x.mkv)" $'movie-compresser\tabc1234\t-'
FAKE_TAGS=$'TAG:COMPRESSION_CRF=22'
eq    "CRF without a tier"                       "$(compression_tag_lines x.mkv)" "$NR3"$'\nCompression tier\tNot recorded\nCompression CRF\t22'
unset -f ffprobe

# ------------------------------------------------------------
echo
echo "== job records: what Validate + update may use (compression_record_lookup)"

LK="$T/lookup"
mkdir -p "$LK"
H=$'date\toutput\tcrf\ttier\tvideo_bytes\tsession\tinput'
E=$'date\ttier\tcrf\tresolution\tduration_s\testimated_video_bytes\tactual_video_bytes\terror_pct\tsession\tinput\tceiling_video_bytes\tresult\treason'
{
    echo "$H"
    printf 'd\t/x/out/A HEVC High.mkv\t21\tHigh\t1000\ts\t/x/in/A.mkv\n'
    printf 'd\t/x/out/A HEVC High.mkv\t21\tHigh\t1000\ts2\t/x/in/A.mkv\n'          # re-recorded: same values
    printf 'd\t/x/out/Show/E01 HEVC Base.mkv\t25\tBase\t3000\ts\t/x/in/Show/E01.mkv\n'
    printf 'd\t/x/out/C HEVC Base.mkv\t24\tBase\t5000\ts\t/x/in/C.mkv\n'
    printf 'd\t/x/out/C HEVC Base.mkv\t26\tBase\t5000\ts\t/x/in/C.mkv\n'          # disagreeing records
    printf 'd\t/x/out/T.mkv\t22\t-\t6000\ts\t/x/in/T.mkv\n'                      # no menu tier
} > "$LK/compression_tags.tsv"
{
    echo "$E"
    printf 'd\tQuality\t20\t1920x1080\t100\t9\t2000\t1%%\ts\t/x/in/B.mkv\t-\tREJECTED\tx\n'       # B: rejected attempt
    printf 'd\tQuality\t19\t1920x1080\t100\t9\t2500\t1%%\ts\t/x/in/B.mkv\t-\tACCEPTED\t-\n'       # B: kept attempt
    printf 'd\tHigh\t18\t1920x1080\t100\t9\t4000\t1%%\ts\t/x/in/D.mkv\t-\tACCEPTED-CANDIDATE\t-\n' # D: replaced
    printf 'd\tCustom\t23.5\t1920x1080\t100\t9\t7000\t1%%\ts\t/x/in/Old.mkv\t-\t-\t-\n'          # no retry row
} > "$LK/crf_estimates.tsv"

eq    "ledger: name + exact video bytes"         "$(compression_record_lookup "$LK" "/y/out/A HEVC High.mkv" 1000)" $'21\tHigh\tcompression_tags.tsv'
eq    "ledger: series episode"                   "$(compression_record_lookup "$LK" "/y/out/Show/E01 HEVC Base.mkv" 3000)" $'25\tBase\tcompression_tags.tsv'
compression_record_lookup "$LK" "/y/out/A HEVC High.mkv" 1001 > /dev/null
eq    "ledger: other video bytes (re-encoded / replaced file) -> no record" "$?" 1
compression_record_lookup "$LK" "/y/out/Z HEVC High.mkv" 1000 > /dev/null
eq    "ledger: other file name, same bytes -> no record" "$?" 1
compression_record_lookup "$LK" "/y/out/C HEVC Base.mkv" 5000 > /dev/null
eq    "disagreeing records -> not used"          "$?" 2
eq    "record without a menu tier: CRF only"     "$(compression_record_lookup "$LK" "/y/out/T.mkv" 6000)" $'22\t-\tcompression_tags.tsv'
eq    "estimate log: the kept attempt"           "$(compression_record_lookup "$LK" "/y/out/B HEVC Quality.mkv" 2500)" $'19\tQuality\tcrf_estimates.tsv'
compression_record_lookup "$LK" "/y/out/B HEVC Quality.mkv" 2000 > /dev/null
eq    "estimate log: a rejected attempt is never used" "$?" 1
compression_record_lookup "$LK" "/y/out/D HEVC High.mkv" 4000 > /dev/null
eq    "estimate log: a replaced candidate is never used" "$?" 1
eq    "estimate log: single CRF row (Custom)"    "$(compression_record_lookup "$LK" "/y/out/Old HEVC Custom.mkv" 7000)" $'23.5\tCustom\tcrf_estimates.tsv'
compression_record_lookup "$LK" "/y/out/Other HEVC Custom.mkv" 7000 > /dev/null
eq    "estimate log: other source name -> no record" "$?" 1
compression_record_lookup "$T/nologs" "/y/out/A HEVC High.mkv" 1000 > /dev/null
eq    "no job records at all -> no record"       "$?" 1
compression_record_lookup "$LK" "/y/out/A HEVC High.mkv" "" > /dev/null
eq    "unknown video bytes -> no record"         "$?" 1

# ------------------------------------------------------------
export PATH="$REAL_PATH"
echo
echo "== verify.sh: earlier output (no tags) and a tagged output"

if (( HAVE_FFMPEG == 1 )); then
    VH="$T/vhome"
    mkdir -p "$VH/compress/in" "$VH/compress/out"
    cp -r "$SRC_WORK" "$VH/compress/work"
    cp "$ROOT/verify.sh" "$VH/compress/"
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x240:r=24:d=2" -c:v mpeg4 \
        -metadata title=Old "$VH/compress/out/Old HEVC High.mkv"
    ffmpeg -v error -y -i "$VH/compress/out/Old HEVC High.mkv" -map 0 -c copy \
        -metadata COMPRESSION_CRF=21 -metadata COMPRESSION_TIER=High "$VH/compress/out/New HEVC High.mkv"
    ffmpeg -v error -y -i "$VH/compress/out/Old HEVC High.mkv" -map 0 -c copy \
        -metadata COMPRESSION_TOOL=movie-compresser -metadata MOVIE_COMPRESSER_VERSION=v1.4.2-5-ga3f8c21-dirty \
        -metadata COMPRESSION_DATE=2026-10-19 -metadata COMPRESSION_CRF=23 -metadata COMPRESSION_TIER=Base \
        "$VH/compress/out/Prov HEVC High.mkv"
    # what an encode command does with a source carrying provenance
    # (emit_encode_item: the -metadata NAME= line before -map_metadata 0)
    ffmpeg -v error -y -i "$VH/compress/out/Prov HEVC High.mkv" -map 0 -c copy \
        -metadata COMPRESSION_TOOL= -metadata MOVIE_COMPRESSER_VERSION= -metadata COMPRESSION_DATE= \
        -map_metadata 0 "$T/reencoded.mkv"
    eq    "ffmpeg: source provenance not carried into a new encode" "$(compression_provenance "$T/reencoded.mkv")" $'-\t-\t-'
    eq    "ffmpeg: other source tags still carried" "$(compression_tags "$T/reencoded.mkv")" $'23\tBase'
    printf '2\n1\n' | HOME="$VH" bash "$VH/compress/verify.sh" > "$T/verify.log" 2>&1
    tr -d '\r' < "$T/verify.log" > "$T/verify.txt"
    # vsec NAME  ->  the rows verify.sh printed for "NAME HEVC High.mkv"
    vsec() { awk -v n="$1 HEVC High.mkv" '/^[^ =]/ { cur = $0 } cur == n' "$T/verify.txt"; }
    check "verify.sh: all files checked"         "grep -q 'Files checked: *3' '$T/verify.txt'"
    check "verify.sh: old output CRF Not recorded" "vsec Old | grep -qE '^  Compression CRF +Not recorded\$'"
    check "verify.sh: old output tier Not recorded" "vsec Old | grep -qE '^  Compression tier +Not recorded\$'"
    check "verify.sh: old output version Not recorded" "vsec Old | grep -qE '^  Compressor version +Not recorded\$'"
    check "verify.sh: tagged output CRF"         "vsec New | grep -qE '^  Compression CRF +21\$'"
    check "verify.sh: tagged output tier"        "vsec New | grep -qE '^  Compression tier +High\$'"
    check "verify.sh: CRF-only output: version Not recorded" "vsec New | grep -qE '^  Compressor version +Not recorded\$'"
    check "verify.sh: compression tool"          "vsec Prov | grep -qE '^  Compression tool +movie-compresser\$'"
    check "verify.sh: compressor version"        "vsec Prov | grep -qE '^  Compressor version +v1\\.4\\.2-5-ga3f8c21-dirty\$'"
    check "verify.sh: compression date"          "vsec Prov | grep -qE '^  Compression date +2026-10-19\$'"
    eq    "verify.sh: row order" "$(vsec Prov | grep -oE '^  (Compression (tool|date|tier|CRF)|Compressor version)' | tr -s ' ' | tr '\n' '|')" \
          " Compression tool| Compressor version| Compression date| Compression tier| Compression CRF|"
    check "verify.sh: no errors"                 "! grep -qiE 'command not found|unbound variable|syntax error' '$T/verify.txt'"
else
    SKIPPED+=("verify.sh report (needs ffmpeg)")
fi

# ------------------------------------------------------------
echo
echo "== real MKV: tags added, everything else kept (mkvtoolnix)"

if (( HAVE_FFMPEG == 1 && HAVE_MKV == 1 )); then
    R="$T/real"
    mkdir -p "$R"
    # Git Bash + Windows mkvtoolnix: MSYS does not convert the path in
    # "all:/tmp/..." for a native program (not needed on Linux)
    if [[ "$(uname -o 2>/dev/null)" == Msys ]] && command -v cygpath >/dev/null; then
        mkdir -p "$T/msys"
        printf '#!/usr/bin/env bash\na=()\nfor x in "$@"; do [[ "$x" == all:/* ]] && x="all:$(cygpath -w "${x#all:}")"; a+=("$x"); done\nexec %q "${a[@]}"\n' \
            "$(command -v mkvpropedit)" > "$T/msys/mkvpropedit"
        chmod +x "$T/msys/mkvpropedit"
        export PATH="$T/msys:$PATH"
    fi
    printf ';FFMETADATA1\ntitle=Real Movie\nSOURCE_NOTE=keep me\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Two\n' > "$R/meta.txt"
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x240:r=24:d=2" -f lavfi -i "sine=d=2" -i "$R/meta.txt" \
        -map 0 -map 1 -map_metadata 2 -map_chapters 2 -c:v mpeg4 -c:a ac3 \
        -metadata:s:v:0 TRACK_NOTE=video-tag -metadata:s:a:0 language=ger -metadata:s:a:0 TRACK_NOTE=audio-tag \
        "$R/a.mkv"
    gtags() { ffprobe -v error -show_entries format_tags -of default=nw=1 "$1" | tr -d '\r' | grep -vE '^TAG:(COMPRESSION_|MOVIE_COMPRESSER_VERSION)' | sort; }
    stags() { ffprobe -v error -show_entries stream_tags -of default=nw=1 "$1" | tr -d '\r' | grep -vE '^TAG:(BPS|DURATION|NUMBER_OF|_STATISTICS)' ; }
    chaps() { ffprobe -v error -show_chapters -of csv=p=0 "$1" | tr -d '\r'; }
    G0=$(gtags "$R/a.mkv"); S0=$(stags "$R/a.mkv"); C0=$(chaps "$R/a.mkv")

    mkv_set_compression_tags "$R/a.mkv" 21 High "$R/t1"
    eq    "real: written"                        "$?" 0
    eq    "real: read back"                      "$(compression_tags "$R/a.mkv")" $'21\tHigh'
    eq    "real: global tags kept"               "$(gtags "$R/a.mkv")" "$G0"
    eq    "real: track tags kept"                "$(stags "$R/a.mkv")" "$S0"
    eq    "real: chapters kept"                  "$(chaps "$R/a.mkv")" "$C0"
    check "real: title kept"                     "[[ \"\$(format_title '$R/a.mkv' | tr -d '\\r')\" == 'Real Movie' ]]"

    mkv_set_compression_tags "$R/a.mkv" 19 Quality "$R/t2"
    eq    "real: rewrite replaces the values"    "$(compression_tags "$R/a.mkv")" $'19\tQuality'
    mkvextract "$R/a.mkv" tags "$R/after.xml" > /dev/null 2>&1
    eq    "real: one COMPRESSION_CRF only"       "$(grep -c '<Name>COMPRESSION_CRF</Name>' "$R/after.xml")" 1
    eq    "real: global tags still kept"         "$(gtags "$R/a.mkv")" "$G0"

    mkv_set_compression_tags "$R/a.mkv" 23 Base "$R/t4" v1.4.2-5-ga3f8c21-dirty 2026-10-19
    eq    "real: provenance written"             "$?" 0
    eq    "real: provenance read back"           "$(compression_provenance "$R/a.mkv")" $'movie-compresser\tv1.4.2-5-ga3f8c21-dirty\t2026-10-19'
    mkv_set_compression_tags "$R/a.mkv" 24 Base "$R/t5" v1.5.0 2026-10-20
    mkvextract "$R/a.mkv" tags "$R/after2.xml" > /dev/null 2>&1
    eq    "real: a new encode's provenance replaces, once each" \
          "$(for n in COMPRESSION_TOOL MOVIE_COMPRESSER_VERSION COMPRESSION_DATE COMPRESSION_CRF COMPRESSION_TIER; do mkv_global_tag_values "$R/after2.xml" "$n"; done | tr '\n' ' ')" \
          "movie-compresser v1.5.0 2026-10-20 24 Base "
    eq    "real: no duplicates reported"         "$(compression_tag_duplicates "$R/a.mkv")" ""
    mkv_set_compression_tags "$R/a.mkv" 19 Quality "$R/t6"
    eq    "real: a write without a version keeps it" "$(compression_provenance "$R/a.mkv")" $'movie-compresser\tv1.5.0\t2026-10-20'
    eq    "real: global tags still kept (2)"     "$(gtags "$R/a.mkv")" "$G0"

    refresh_mkv_stats "$R/a.mkv" > /dev/null 2>&1
    eq    "real: tags survive the statistics refresh" "$(compression_tags "$R/a.mkv")" $'19\tQuality'
    eq    "real: provenance survives the statistics refresh" "$(compression_provenance "$R/a.mkv")" $'movie-compresser\tv1.5.0\t2026-10-20'
    eq    "real: track tags after refresh"       "$(stags "$R/a.mkv")" "$S0"

    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x240:r=24:d=1" -c:v mpeg4 -fflags +bitexact "$R/bare.mkv"
    mkvpropedit "$R/bare.mkv" --tags all: > /dev/null 2>&1
    mkv_set_compression_tags "$R/bare.mkv" 24 Base "$R/t3"
    eq    "real: file without any tags"          "$(compression_tags "$R/bare.mkv")" $'24\tBase'
else
    SKIPPED+=("real MKV tag write (needs ffmpeg + mkvtoolnix)")
fi

# ------------------------------------------------------------
echo
echo "== verify.sh: Verify is read-only, Validate + update backfills (mkvtoolnix)"

if (( HAVE_FFMPEG == 1 && HAVE_MKV == 1 )); then
    BH="$T/bhome"
    BO="$BH/compress/out"
    mkdir -p "$BH/compress/in" "$BO" "$BH/compress/work/logs"
    cp -r "$SRC_WORK/lib" "$BH/compress/work/"
    cp "$ROOT/verify.sh" "$BH/compress/"
    # small synthetic outputs with unrelated global + track tags
    mkb() {
        ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x120:r=24:d=1" -f lavfi -i "sine=d=1" \
            -map 0 -map 1 -c:v mpeg4 -q:v "$2" -c:a ac3 -metadata title="$1" -metadata SOURCE_NOTE=keep \
            -metadata:s:v:0 TRACK_NOTE=video -metadata:s:a:0 language=ger "$BO/$1 HEVC High.mkv"
        refresh_mkv_stats "$BO/$1 HEVC High.mkv" > /dev/null 2>&1
    }
    mkb Missing 3; mkb Stale 5; mkb NoRecord 7; mkb Kept 9
    # Stale: encoded by an earlier version of the scripts (its provenance
    # must survive the CRF correction unchanged)
    mkv_set_compression_tags "$BO/Stale HEVC High.mkv" 30 Base "$T/bt1" v1.0.0-3-gdeadbee 2026-01-02 > /dev/null
    mkv_set_compression_tags "$BO/Kept HEVC High.mkv" 18 High "$T/bt2" > /dev/null
    provs() { local n; for n in Missing Stale NoRecord Kept; do printf '%s=%s ' "$n" "$(compression_provenance "$BO/$n HEVC High.mkv" | tr '\t' /)"; done; }
    PV0="Missing=-/-/- Stale=movie-compresser/v1.0.0-3-gdeadbee/2026-01-02 NoRecord=-/-/- Kept=-/-/- "
    vb() { media_stream_totals "$BO/$1 HEVC High.mkv" | awk '{ print $1 }'; }
    compression_ledger_add "$BH/compress/work/logs" "/old/out/Missing HEVC High.mkv" 21 High "$(vb Missing)" s1 /old/in/Missing.mkv
    compression_ledger_add "$BH/compress/work/logs" "/old/out/Stale HEVC High.mkv" 20 High "$(vb Stale)" s1 /old/in/Stale.mkv
    # a record for NoRecord, but of a different encode (other video bytes)
    compression_ledger_add "$BH/compress/work/logs" "/old/out/NoRecord HEVC High.mkv" 19 High 12345 s1 /old/in/NoRecord.mkv

    # unrelated metadata, compared before / after (compression tags excluded)
    meta() {
        local f="$BO/$1 HEVC High.mkv"
        # track titles excluded: Validate + update corrects them (checked below)
        { ffprobe -v error -show_entries format_tags -of default=nw=1 "$f"
          ffprobe -v error -show_entries stream_tags -of default=nw=1 "$f" | grep -v '^TAG:title='; } | tr -d '\r' |
            grep -vE '^TAG:(COMPRESSION_|BPS|DURATION|NUMBER_OF|_STATISTICS)'
        # the full tag structure, without the statistics Validate + update
        # always refreshes (their values include the writing date)
        mkvextract "$f" tags "$T/m.xml" > /dev/null 2>&1
        _compression_tags_canon < "$T/m.xml" | awk '
            /^<Simple>$/ { b = $0 "\n"; ins = 1; next }
            ins { b = b $0 "\n"; if ($0 == "</Simple>") { ins = 0; if (b !~ /<Name>(BPS|DURATION|NUMBER_OF_[A-Z]+|_STATISTICS_[A-Z_]+)</) printf "%s", b }; next }
            { print }'
    }
    sums()  { (cd "$BO" && md5sum -- *.mkv); }
    crfs()  { local n; for n in Missing Stale NoRecord Kept; do printf '%s=%s ' "$n" "$(compression_tags "$BO/$n HEVC High.mkv" | tr '\t' /)"; done; }
    ncrf()  { local n; for n in Missing Stale NoRecord Kept; do mkvextract "$BO/$n HEVC High.mkv" tags "$T/n.xml" > /dev/null 2>&1; printf '%s ' "$(grep -c '<Name>COMPRESSION_CRF</Name>' "$T/n.xml")"; done; }
    rows()  { tr -d '\r' < "$T/$1.log" | awk -v n="$2 HEVC High.mkv" '/^[^ =]/ { cur = $0 } cur == n && /Compress/'; }
    M0=$(for n in Missing Stale NoRecord Kept; do meta "$n"; done)
    S0=$(sums)

    printf '2\n1\n' | HOME="$BH" bash "$BH/compress/verify.sh" > "$T/bv.log" 2>&1
    eq    "Verify: no file modified"             "$(sums)" "$S0"
    check "Verify: missing tags reported, not failed" "rows bv Missing | grep -qE '^  Compression CRF +Not recorded\$'"
    check "Verify: missing version reported, not failed" "rows bv Missing | grep -qE '^  Compressor version +Not recorded\$'"
    check "Verify: stale value reported as stored" "rows bv Stale | grep -qE '^  Compression CRF +30\$'"
    check "Verify: historical version reported"  "rows bv Stale | grep -qE '^  Compressor version +v1\\.0\\.0-3-gdeadbee\$'"
    check "Verify: no backfill"                  "! grep -q 'Compression tags' '$T/bv.log'"
    check "Verify: missing audio title reported" "grep -q 'no title - MISSING' '$T/bv.log' && grep -q 'Titles to correct: 4' '$T/bv.log'"
    atitles() { local n; for n in Missing Stale NoRecord Kept; do printf '%s ' "$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=title -of default=nw=1:nk=1 "$BO/$n HEVC High.mkv" | tr -d '\r')"; done; }
    pay() { local n; for n in Missing Stale NoRecord Kept; do ffmpeg -v error -i "$BO/$n HEVC High.mkv" -map 0 -c copy -f streamhash -hash md5 - 2>/dev/null; done; }
    P0=$(pay)

    printf '2\n2\n' | HOME="$BH" bash "$BH/compress/verify.sh" > "$T/bu1.log" 2>&1
    eq    "Validate + update: backfilled / corrected / not guessed / kept" "$(crfs)" \
          "Missing=21/High Stale=20/High NoRecord=-/- Kept=18/High "
    check "Validate + update: WRITTEN reported"  "rows bu1 Missing | grep -q 'Compression tags *WRITTEN (CRF 21, High; from compression_tags.tsv)'"
    check "Validate + update: CORRECTED reported" "rows bu1 Stale | grep -q 'Compression tags *CORRECTED (CRF 30, Base -> CRF 20, High; from compression_tags.tsv)'"
    check "Validate + update: not recovered reported" "rows bu1 NoRecord | grep -q 'Compression tags *not recovered (no job record of this encode); left missing'"
    check "Validate + update: existing tags without a record left unchanged" "rows bu1 Kept | grep -q 'not recovered (no job record of this encode); existing tags left unchanged'"
    check "Validate + update: summary"           "grep -q 'CRF tags written:  2' '$T/bu1.log' && grep -q 'CRF not recovered: 2' '$T/bu1.log'"
    eq    "Validate + update: unrelated metadata unchanged" "$(for n in Missing Stale NoRecord Kept; do meta "$n"; done)" "$M0"
    eq    "Validate + update: historical version kept, none invented" "$(provs)" "$PV0"
    eq    "Validate + update: no duplicate tags"     "$(for n in Missing Stale NoRecord Kept; do compression_tag_duplicates "$BO/$n HEVC High.mkv"; done)" ""
    eq    "Validate + update: standard audio titles" "$(atitles)" "German | AC-3 | 1.0 | 96 kbps German | AC-3 | 1.0 | 96 kbps German | AC-3 | 1.0 | 96 kbps German | AC-3 | 1.0 | 96 kbps "
    eq    "Validate + update: stream data unchanged" "$(pay)" "$P0"

    printf '2\n2\n' | HOME="$BH" bash "$BH/compress/verify.sh" > "$T/bu2.log" 2>&1
    eq    "repeat: same values"                  "$(crfs)" "Missing=21/High Stale=20/High NoRecord=-/- Kept=18/High "
    eq    "repeat: one COMPRESSION_CRF per file" "$(ncrf)" "1 1 0 1 "
    check "repeat: reported UNCHANGED, nothing written" "rows bu2 Missing | grep -q 'UNCHANGED (CRF 21, High' && rows bu2 Stale | grep -q 'UNCHANGED (CRF 20, High' && ! grep -q 'CRF tags written:  [1-9]' '$T/bu2.log'"
    eq    "repeat: unrelated metadata unchanged" "$(for n in Missing Stale NoRecord Kept; do meta "$n"; done)" "$M0"
    eq    "repeat: historical version still kept" "$(provs)" "$PV0"
    check "repeat: titles already correct, none rewritten" "grep -q 'Titles correct:    4' '$T/bu2.log' && grep -q 'Titles updated:    0' '$T/bu2.log'"
    S2=$(sums)
    printf '2\n1\n' | HOME="$BH" bash "$BH/compress/verify.sh" > "$T/bv2.log" 2>&1
    eq    "Verify after update: no file modified" "$(sums)" "$S2"
    check "Verify after update: values reported" "rows bv2 Missing | grep -qE '^  Compression CRF +21\$' && rows bv2 Missing | grep -qE '^  Compression tier +High\$'"
    check "no errors in verify.sh runs"          "! cat '$T'/bv.log '$T'/bu1.log '$T'/bu2.log | grep -qiE 'command not found|unbound variable|syntax error'"
else
    SKIPPED+=("verify.sh Validate + update backfill (needs ffmpeg + mkvtoolnix)")
fi

echo
for s in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do echo "skipped: $s"; done
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
