#!/usr/bin/env bash
# Standard video / audio track titles of every output (encode_common.sh
# video_std_title / audio_std_title / mkv_std_track_titles /
# mkv_write_track_titles, job_runtime.sh item_finalize_titles,
# hdr_dovi.sh item_verify_output, verify.sh check_track_titles).
#
#   bash ~/compress/work/tests/track_title_tests.sh
#
#   Video: "Codec | Resolution | Bit Depth | HDR Format | CRF Value"
#   Audio: "Language | Codec | Channels | Bitrate[ | Description]"
#
#  1. unit (no media tools): both formats, parts left out when unknown /
#     inapplicable (SDR, no CRF, no language / layout / rate), release
#     text removed, descriptions kept verbatim (commentary credits too),
#     a title whose description is not understood verbatim kept unchanged
#     and warned about, commentary / descriptive / mixes / dubs kept, the
#     stated constant rate preferred to a measured one, a VBR stream's
#     bit_rate field (DTS-HD core) never used, no compression tier
# needs ffmpeg (parts 2-6) and MKVToolNix for the finalized titles:
#  2. movie video-only compression (CRF encode, audio copied): the final
#     CRF and the actual audio rates (constant / measured) in the titles
#     after the mux; release names replaced; copied audio titled too;
#     the verification checks the titles against the output streams;
#     ffprobe and mkvmerge -J agree; track order, languages, flags,
#     subtitles, chapters, attachments, HDR10 metadata kept
#  3. copied video (source-quality guard): x265 source -> CRF from the
#     stream's x265 settings; x264 source -> no CRF (not known)
#  4. audio-only compression (audio menu) of the movie output = the
#     combined workflow: transcoded AC-3 640 kbps, copied tracks keep
#     their rates, the copied video keeps "CRF N" from its stream
#  5. titles are written as track names only: stream payloads unchanged,
#     no re-encode; a repeat finalization changes nothing
#  6. verify.sh: Verify reports non-standard / stale / missing titles,
#     Validate + update corrects them to the standard titles, a repeat
#     run changes nothing; verify_titles.sh (window_tagger) agrees
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${TITLE_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0
SKIPPED=()

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE
WORK_DIR="$T/work"
mkdir -p "$WORK_DIR" "$T/f" "$T/stub"
cp -r "$SRC_WORK/lib" "$WORK_DIR/"
for l in ui media_probe media_stats bitrate encode_common hdr_dovi policy audio_plan; do
    source "$WORK_DIR/lib/$l.sh" > /dev/null
done

# ------------------------------------------------------------
echo "== 1 unit: title formats"
eq "video: HEVC HDR10 CRF"            "$(video_std_title hevc 1920x1080 10 HDR10 0 "" 0 22)" "HEVC | 1080p | 10-bit | HDR10 | CRF 22"
eq "video: scope 2160p, DV + HDR10+"  "$(video_std_title hevc 3840x1600 10 HDR10 1 8 1 18)" "HEVC | 2160p | 10-bit | Dolby Vision + HDR10+ | CRF 18"
eq "video: DV profile 5 has no HDR10" "$(video_std_title hevc 3840x2160 10 HDR10 1 5 0 "")" "HEVC | 2160p | 10-bit | Dolby Vision"
eq "video: HLG"                       "$(video_std_title hevc 3840x2160 10 HLG 0 "" 0 20)" "HEVC | 2160p | 10-bit | HLG | CRF 20"
eq "video: SDR has no HDR part"       "$(video_std_title hevc 1280x720 10 SDR 0 "" 0 24)" "HEVC | 720p | 10-bit | CRF 24"
eq "video: copied, CRF unknown"       "$(video_std_title h264 1920x1080 8 SDR 0 "" 0 "")" "AVC | 1080p | 8-bit"
eq "video: interlaced MPEG-2 SD"      "$(video_std_title mpeg2video 720x576 8 SDR 0 "" 0 "" tt)" "MPEG-2 | 576i | 8-bit"
eq "video: 1920x800 is 1080p"         "$(video_resolution_label 1920x800)" "1080p"
eq "video: unknown size / depth"      "$(video_std_title hevc "" "" SDR 0 "" 0 "")" "HEVC"
eq "video: nothing known"             "$(video_std_title "" "" "" "" 0 "" 0 "")" ""
eq "video: CRF 21.50 -> 21.5"         "$(video_crf_label 21.50)/$(video_crf_label 22.0)/$(video_crf_label x)" "CRF 21.5/CRF 22/"
eq "video: standard title disproves nothing" \
    "$(video_title_false_claims "HEVC | 2160p | 10-bit | Dolby Vision + HDR10 | CRF 18" hevc 3840x1600 HDR10 1 0 10)" ""
check "video: no tier in the title"   "[[ \"\$(video_std_title hevc 1920x1080 10 HDR10 0 '' 0 22)\" != *@(Quality|High|Base|Compact)* ]]"

eq "audio: AC-3 640 (stated rate)"    "$(audio_std_title jpn ac3 - 6 '5.1(side)' '' 0 0 0 1 "$(audio_title_kbps ac3 - 640000 '' 48000 6)")" "Japanese | AC-3 | 5.1 | 640 kbps"
eq "audio: TrueHD 7.1 measured"       "$(audio_std_title eng truehd - 8 7.1 '' 0 0 0 1 "$(audio_title_kbps truehd - '' 24 48000 8 4500)")" "English | TrueHD | 7.1 | 4500 kbps"
eq "audio: PCM 24-bit stereo"         "$(audio_std_title jpn pcm_s24le - 2 stereo '' 0 0 0 1 "$(audio_title_kbps pcm_s24le - '' '' 48000 2)")" "Japanese | PCM | 2.0 | 2304 kbps"
eq "audio: stated rate beats measured" "$(audio_title_kbps ac3 - 640000 '' 48000 6 637)" "640"
eq "audio: DTS-HD core rate not used" "$(audio_title_kbps dts 'DTS-HD MA' 1509000 24 48000 6)/$(audio_title_kbps dts 'DTS-HD MA' 1509000 24 48000 6 3017)" "/3017"
eq "audio: DTS core rate used"        "$(audio_title_kbps dts DTS 1509000 '' 48000 6)" "1509"
eq "audio: rate unknown -> left out"  "$(audio_std_title eng aac LC 2 stereo '' 0 0 0 1 "$(audio_title_kbps aac LC '' '' 48000 2)")" "English | AAC | 2.0"
eq "audio: no language / layout"      "$(audio_std_title und pcm_s16le - 6 - '' 0 0 0 1)" "PCM | 6ch"
eq "audio: release text removed"      "$(audio_std_title eng truehd - 8 7.1 'English TrueHD 7.1 2160p BluRay REMUX HEVC -FGT' 0 0 0 1 4500)" "English | TrueHD | 7.1 | 4500 kbps"
eq "audio: unparsed rest -> title kept" "$(audio_std_title eng ac3 - 6 '5.1(side)' '[FGT] Remux by XYZ' 0 0 0 1 640)" "[FGT] Remux by XYZ"
eq "audio: unparsed rest -> warning"  "$(audio_title_warning '[FGT] Remux by XYZ' eng)" 'description "by XYZ" not recognised: kept as written, check manually'
eq "audio: name only -> kept + warned" "$(audio_std_title eng ac3 - 2 stereo 'Nolan' 0 0 0 1 192)|$(audio_title_warning Nolan eng)" 'Nolan|description "Nolan" not recognised: kept as written, check manually'
eq "audio: transcode keeps the text"  "$(audio_std_title eng ac3 - 2 stereo 'Nolan DTS 5.1' 0 0 0 0 192)" "English | AC-3 | 2.0 | 192 kbps | Nolan"
eq "audio: kept text is idempotent"   "$(audio_std_title eng ac3 - 2 stereo 'English | AC-3 | 2.0 | 192 kbps | Nolan' 0 0 0 1 192)" "English | AC-3 | 2.0 | 192 kbps | Nolan"
eq "audio: commentary credit verbatim" "$(audio_std_title eng ac3 - 2 stereo 'Commentary by John Carpenter and Kurt Russell' 1 0 0 1 192)" "English | AC-3 | 2.0 | 192 kbps | Commentary by John Carpenter and Kurt Russell"
eq "audio: bracketed credit verbatim" "$(audio_std_title eng ac3 - 2 stereo 'Commentary [John Smith]' 1 0 0 1 192)" "English | AC-3 | 2.0 | 192 kbps | Commentary [John Smith]"
eq "audio: altered wording -> kept"   "$(audio_std_title eng ac3 - 2 stereo 'Commentary with D.V. DeVincentis (Complete)' 1 0 0 1 192)" "Commentary with D.V. DeVincentis (Complete)"
eq "audio: claim inside a credit -> kept" "$(audio_std_title eng ac3 - 2 stereo 'Commentary by John (DTS 2.0) Carpenter' 1 0 0 1)" "Commentary by John (DTS 2.0) Carpenter"
check "audio: understood title, no warning" "[[ -z \"\$(audio_title_warning \"Director's Commentary 1080p WEB-DL -GRP\" eng)\" ]]"
eq "audio: commentary kept, junk out" "$(audio_std_title eng ac3 - 2 stereo "Director's Commentary 1080p WEB-DL -GRP" 1 0 0 1 192)" "English | AC-3 | 2.0 | 192 kbps | Director's Commentary"
eq "audio: descriptive (flag)"        "$(audio_std_title eng eac3 - 6 '5.1(side)' '' 0 0 1 1 640)" "English | E-AC-3 | 5.1 | 640 kbps | Descriptive Audio"
eq "audio: original theatrical mix"   "$(audio_std_title eng dts DTS 6 '5.1(side)' 'Original Theatrical Mix DTS 5.1' 0 0 0 1 1509)" "English | DTS | 5.1 | 1509 kbps | Original Theatrical Mix"
eq "audio: alternate mix"             "$(audio_std_title eng flac - 2 stereo 'Alternate Mix' 0 0 0 1)" "English | FLAC | 2.0 | Alternate Mix"
eq "audio: 'Stereo' inside a description -> kept" "$(audio_std_title eng flac - 2 stereo 'Alternate Stereo Mix' 0 0 0 1)" "Alternate Stereo Mix"
eq "audio: regional variant"          "$(audio_std_title spa ac3 - 6 '5.1(side)' 'Spanish (Latin America) AC3 5.1' 0 0 0 1 640)" "Spanish | AC-3 | 5.1 | 640 kbps | (Latin America)"
eq "audio: Japanese commentary word"  "$(audio_std_title jpn aac LC 2 stereo '副音声' 0 0 0 1 128)" "Japanese | AAC | 2.0 | 128 kbps | 副音声"
eq "audio: idempotent with rate"      "$(audio_std_title eng ac3 - 2 stereo 'English | AC-3 | 2.0 | 192 kbps | Commentary' 1 0 0 1 192)" "English | AC-3 | 2.0 | 192 kbps | Commentary"
eq "audio: old rate never kept"       "$(audio_std_title eng truehd - 8 7.1 'English | TrueHD | 7.1 | 3999 kbps' 0 0 0 1 4512)" "English | TrueHD | 7.1 | 4512 kbps"
eq "audio: standard title not STALE"  "$(audio_title_false_claims 'Japanese | AC-3 | 5.1 | 640 kbps' ac3 6 - 640000 '' 48000)" ""
eq "plan: transcode rate titled (CBR only)" \
    "$(printf '0\tac3\t-\t6\t5.1(side)\t640\n' | while IFS=$'\t' read -r i c p ch l k; do
        [[ "$c" =~ ^(ac3|eac3|mp2)$ ]] && audio_title_kbps "$c" "$p" "$((k * 1000))" '' 48000 "$ch"; done)" "640"

for t in ffmpeg ffprobe; do
    command -v "$t" >/dev/null || { echo; echo "$t not found: media tests skipped"; echo "PASS $PASS  FAIL $FAIL"; exit $(( FAIL > 0 )); }
done
HAVE_MKV=0
command -v mkvmerge >/dev/null && command -v mkvpropedit >/dev/null && command -v mkvextract >/dev/null && HAVE_MKV=1
(( HAVE_MKV == 1 )) || SKIPPED+=("finalized titles / mkvmerge -J / verify.sh Validate + update (MKVToolNix not found)")
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
export PATH="$T/stub:$PATH"
X265_PRESET=ultrafast

# probe helpers
vtitle()  { ffprobe -v error -select_streams v:0 -show_entries stream_tags=title -of default=nw=1:nk=1 "$1" | tr -d '\r'; }
atitles() { ffprobe -v error -select_streams a -show_entries stream_tags=title -of csv=p=0 "$1" | tr -d '\r' | tr '\n' '/'; }
mkvnames() {   # FILE  ->  "type:name/" per track, mkvmerge -J
    mkv_identify_tracks "$1" | awk -F'\t' '$2 == "video" || $2 == "audio" { printf "%s:%s/", $2, $9 }'
}
ffnames() {    # FILE  ->  the same from ffprobe (main video first, as written)
    stream_meta "$1" | awk -F'\t' '($2 == "video" && $12 == 0) || $2 == "audio" { printf "%s:%s/", $2, $14 }'
}
# bps_kbps FILE AUDIO_N  ->  the statistics tag BPS of the track (as
# MKVToolNix measured it), whole kb/s
bps_kbps() {
    local b
    b=$(ffprobe -v error -select_streams "a:$2" -show_entries stream_tags=BPS -of default=nw=1:nk=1 "$1" | tr -d '\r' | head -n 1)
    [[ "$b" =~ ^[0-9]+$ ]] && echo $(( (b + 500) / 1000 ))
}
# scan_kbps FILE AUDIO_N  ->  packet scan of the track: bytes * 8 / duration
scan_kbps() {
    local d
    d=$(get_duration "$1")
    ffprobe -v error -select_streams "a:$2" -show_entries packet=size -of csv=p=0 "$1" |
        awk -v d="$d" '{ s += $1 } END { printf "%d", s * 8 / d / 1000 + 0.5 }'
}
within() { awk -v a="$1" -v b="$2" -v p="${3:-2}" 'BEGIN { exit !(a > 0 && b > 0 && (a - b) / b * 100 <= p && (b - a) / b * 100 <= p) }'; }
payload() { ffmpeg -v error -nostdin -i "$1" -map 0:v:0 -map 0:a -c copy -f streamhash -hash md5 - 2>/dev/null | awk -F, '{ print $3 }' | tr '\n' ' '; }

# ------------------------------------------------------------
# fixtures: 720p x264 video (a release-name title), five audio tracks
#   a0 DTS 5.1 1536 kb/s (FFmpeg encoder) jpn default  "Japanese DTS 5.1 -FGT"
#   a1 TrueHD 5.1 eng                 "English Dolby TrueHD 5.1 2160p BluRay REMUX"
#   a2 PCM s24 stereo jpn             (no title)
#   a3 AAC stereo eng commentary      "Director's Commentary [FGT]"
#   a4 AC-3 stereo 192 kb/s           (no language, no title)
# two subtitles (forced eng / jpn), chapters, a font attachment, a global title
echo
echo "== building fixtures"
printf '1\n00:00:00,100 --> 00:00:01,000\nForced\n' > "$T/f/s1.srt"
printf '1\n00:00:00,200 --> 00:00:01,500\nJP\n' > "$T/f/s2.srt"
printf ';FFMETADATA1\ntitle=Fixture Movie\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=4000\ntitle=Two\n' > "$T/f/meta.txt"
head -c 2048 /dev/urandom > "$T/f/font.ttf"
REL="Fixture.Movie.2016.2160p.BluRay.REMUX.HEVC-FGT"

# mk_audio_source VIDEO_ARGS... -- OUT
mk_source() {
    local out="${*: -1}" va=("${@:1:$#-1}")
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=1280x720:r=24:d=4" \
        -f lavfi -i "sine=f=330:r=48000:d=4" -f lavfi -i "sine=f=550:r=48000:d=4" \
        -i "$T/f/s1.srt" -i "$T/f/s2.srt" -i "$T/f/meta.txt" \
        -map 0:v -map 1:a -map 1:a -map 2:a -map 2:a -map 2:a -map 3 -map 4 -map_metadata 5 -map_chapters 5 \
        "${va[@]}" \
        -c:a:0 dca -strict -2 -ac:a:0 6 -b:a:0 1509k -c:a:1 truehd -strict -2 -ac:a:1 6 \
        -c:a:2 pcm_s24le -ac:a:2 2 -c:a:3 aac -ac:a:3 2 -b:a:3 96k -c:a:4 ac3 -ac:a:4 2 -b:a:4 192k -c:s srt \
        -attach "$T/f/font.ttf" -metadata:s:t mimetype=font/ttf -metadata:s:t filename=font.ttf \
        -metadata:s:v:0 language=eng -metadata:s:v:0 "title=$REL" \
        -metadata:s:a:0 language=jpn -metadata:s:a:0 "title=Japanese DTS 5.1 -FGT" -disposition:a:0 default \
        -metadata:s:a:1 language=eng -metadata:s:a:1 "title=English Dolby TrueHD 5.1 2160p BluRay REMUX" -disposition:a:1 0 \
        -metadata:s:a:2 language=jpn -disposition:a:2 0 \
        -metadata:s:a:3 language=eng -metadata:s:a:3 "title=Director's Commentary [FGT]" -disposition:a:3 comment \
        -disposition:a:4 0 \
        -metadata:s:s:0 language=eng -metadata:s:s:0 title=Forced -disposition:s:0 default+forced \
        -metadata:s:s:1 language=jpn -disposition:s:1 0 \
        "$out" 2> "$T/mk.err"
}
mk_source -c:v libx264 -preset ultrafast -crf 30 "$T/f/SDR.mkv"
HDR_X265="colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400:repeat-headers=1:log-level=error"
mk_source -c:v libx265 -preset ultrafast -crf 31 -pix_fmt yuv420p10le -x265-params "$HDR_X265" "$T/f/HDR10.mkv"
eq "fixture: SDR source streams" "$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$T/f/SDR.mkv" | grep -v unknown | tr -d '\r' | tr '\n' ' ')" "h264 dts truehd pcm_s24le aac ac3 subrip subrip "
check "fixture: HDR10 source is x265 CRF 31" "[[ \"\$(x265_rate_control '$T/f/HDR10.mkv' 0)\" == 'crf 31.0' ]]"

# run_job NAME INPUT VIDEO  ->  movie job (emit_encode_item) + its log
run_job() {
    local name="$1" job="$WORK_DIR/$1.sh"
    {
        emit_job_header "$name" movie 1
        emit_encode_item 1 "$2" "$T/out/$name.mkv" Custom "$3" "" "" 0
        emit_job_footer
    } > "$job"
    mkdir -p "$T/out"
    cp "$job" "$T/$name.job.sh"      # the job removes itself after success
    bash "$job" < /dev/null > "$T/$name.log" 2>&1
}
report_has() { sed -n '/^Metadata preservation:/,/^====/p' "$T/$1.log" | grep -qE -- "$2"; }
DV_POLICY=none; DV_MODE=""; HDR10P_POLICY=none

# ------------------------------------------------------------
echo
echo "== 2 movie: video-only compression (CRF 30, audio copied)"
run_job sdr "$T/f/SDR.mkv" crf:30
O="$T/out/sdr.mkv"
check "job succeeded"                          "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/sdr.log'"
vmux=$(grep -o -- '-metadata:s:v:0 title=[^ ]*\( [^-][^ ]*\)*' "$T/sdr.job.sh")
check "mux: standard video title, no CRF yet"   "[[ '$vmux' == *HEVC*720p*10-bit* && '$vmux' != *CRF* ]]"
check "mux: no tier, no release text in job titles" "! grep -E -- '-metadata:s:[av]:[0-9]+ title=' '$T/sdr.job.sh' | grep -qiE 'Custom|FGT|BluRay|REMUX|2160p'"
if (( HAVE_MKV == 1 )); then
    eq    "video title: final CRF"             "$(vtitle "$O")" "HEVC | 720p | 10-bit | CRF 30"
    tk=$(bps_kbps "$O" 1); ak=$(bps_kbps "$O" 3)
    eq    "audio titles: actual rates, release text gone, commentary kept" "$(atitles "$O")" \
          "Japanese | DTS | 5.1 | 1536 kbps/English | TrueHD | 5.1 | $tk kbps/Japanese | PCM | 2.0 | 2304 kbps/English | AAC | 2.0 | $ak kbps | Director's Commentary/AC-3 | 2.0 | 192 kbps/"
    check "TrueHD rate = measured packets (+-2%)" "within '$tk' '$(scan_kbps "$O" 1)'"
    check "AAC rate = measured packets (+-2%)"    "within '$ak' '$(scan_kbps "$O" 3)'"
    check "finalization reported"              "grep -q 'Track titles finalized' '$T/sdr.log' && report_has sdr 'Title finalization: +DONE'"
    check "verify: video title AS PLANNED"     "report_has sdr 'Video title: +AS PLANNED \"HEVC \\| 720p \\| 10-bit \\| CRF 30\"'"
    check "verify: audio titles AS PLANNED"    "report_has sdr 'Track titles: +AS PLANNED \\(5 audio title'"
    check "verify: no warnings / failures"     "! report_has sdr 'RESULT:'"
    eq    "mkvmerge -J names = ffprobe titles" "$(mkvnames "$O")" "$(ffnames "$O")"
    # (Git Bash on Windows: the native mkvpropedit cannot read the POSIX
    # path inside "--tags all:PATH", so the tags are not written there)
    if grep -q 'compression tags not written' "$T/sdr.log"; then
        SKIPPED+=("COMPRESSION_CRF tag = title CRF (compression tags could not be written here)")
    else
        eq    "COMPRESSION_CRF tag = title CRF"    "$(compression_tags "$O" | cut -f1)" "30"
    fi
    check "statistics refreshed once (before the verification)" "[[ \$(grep -c 'MKV statistics updated from actual output' '$T/sdr.log') == 1 ]]"
else
    eq    "no MKVToolNix: mux video title (no CRF)" "$(vtitle "$O")" "HEVC | 720p | 10-bit"
    eq    "no MKVToolNix: mux audio titles (stated rates only)" "$(atitles "$O")" \
          "Japanese | DTS | 5.1 | 1536 kbps/English | TrueHD | 5.1/Japanese | PCM | 2.0 | 2304 kbps/English | AAC | 2.0 | Director's Commentary/AC-3 | 2.0 | 192 kbps/"
    check "no MKVToolNix: reported, not failed" "report_has sdr 'Title finalization: +NOT DONE' && ! report_has sdr 'RESULT: FAILED'"
fi
# preservation: everything but the names exactly as the source
for f in "Audio tracks: +5 -> 5" "Subtitle tracks: +2 -> 2" "Default flags: +MATCH" "Forced flags: +MATCH" \
         "Commentary/HI/VI: +MATCH" "Languages: +MATCH" "Stream order: +MATCH" "Global title: +MATCH" \
         "Chapters: +MATCH" "Attachments: +MATCH"; do
    check "kept: ${f%%:*}"                     "report_has sdr '$f'"
done
eq    "kept: subtitle titles / languages"      "$(ffprobe -v error -select_streams s -show_entries stream_tags=language,title -of csv=p=0 "$O" | tr -d '\r' | tr '\n' ' ')" "eng,Forced jpn "
eq    "kept: copied audio payload"             "$(ffmpeg -v error -i "$O" -map 0:a -c copy -f streamhash -hash md5 - 2>/dev/null | awk -F, '{ print $3 }' | tr '\n' ' ')" \
                                               "$(ffmpeg -v error -i "$T/f/SDR.mkv" -map 0:a -c copy -f streamhash -hash md5 - 2>/dev/null | awk -F, '{ print $3 }' | tr '\n' ' ')"

echo
echo "== 2b movie: HDR10 encode"
run_job hdr "$T/f/HDR10.mkv" crf:28
O="$T/out/hdr.mkv"
check "job succeeded"                          "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/hdr.log'"
if (( HAVE_MKV == 1 )); then
    eq    "video title: HDR10, final CRF"      "$(vtitle "$O")" "HEVC | 720p | 10-bit | HDR10 | CRF 28"
    check "verify: no warnings / failures"     "! report_has hdr 'RESULT:'"
fi
check "kept: HDR10 mastering / MaxCLL"         "report_has hdr 'HDR10 mastering: +VERIFIED' && report_has hdr 'MaxCLL/MaxFALL: +VERIFIED'"

# ------------------------------------------------------------
echo
echo "== 3 copied video (source-quality guard)"
run_job copyx265 "$T/f/HDR10.mkv" copy
run_job copyx264 "$T/f/SDR.mkv" copy
check "jobs succeeded"                         "grep -q '1 ok, 0 failed' '$T/copyx265.log' && grep -q '1 ok, 0 failed' '$T/copyx264.log'"
eq    "x265 copy: CRF from the stream's x265 settings" "$(vtitle "$T/out/copyx265.mkv")" "HEVC | 720p | 10-bit | HDR10 | CRF 31"
eq    "x264 copy: CRF not known, left out"     "$(vtitle "$T/out/copyx264.mkv")" "AVC | 720p | 8-bit"
check "copies: COMPRESSION_CRF not invented"   "[[ \$(compression_tags '$T/out/copyx264.mkv' | cut -f1) == - ]]"
if (( HAVE_MKV == 1 )); then
    check "copies: verification clean"         "! report_has copyx265 'RESULT:' && ! report_has copyx264 'RESULT:'"
    eq    "copies: payload unchanged"          "$(payload "$T/out/copyx264.mkv")" "$(payload "$T/f/SDR.mkv")"
fi

# ------------------------------------------------------------
echo
echo "== 4 audio-only compression of the movie output (combined workflow)"
H="$T/home"
mkdir -p "$H/compress/out"
cp -r "$SRC_WORK" "$H/compress/work"
rm -rf "$H/compress/work/tests" "$H/compress/work/logs" "$H/compress/work/cache"
rm -f "$H/compress/work"/[a-z]*[0-9].sh "$H/compress/work"/*.state "$H/compress/work"/*.progress
cp "$ROOT/audio_compress_menu.sh" "$H/compress/"
cp "$T/out/sdr.mkv" "$H/compress/out/Fixture HEVC Custom.mkv"
CONF="$T/audio.conf"
cp "$SRC_WORK/lib/compress.conf" "$CONF"
# Compact limit: ~690 kb/s over 4 s -> AC-3 640 kb/s
sed -i 's|^AUDIO_COMPACT_TRIGGER_GIB=.*|AUDIO_COMPACT_TRIGGER_GIB=0.00032|; s|^AUDIO_COMPACT_LIMIT_GIB=.*|AUDIO_COMPACT_LIMIT_GIB=0.00032|' "$CONF"
printf '1\n1\n3\nn\n' | HOME="$H" COMPRESS_CONF="$CONF" bash "$H/compress/audio_compress_menu.sh" > "$T/amenu.log" 2>&1
AJ=$(ls -t "$H/compress/work"/a[0-9]*.sh 2>/dev/null | head -1)
check "audio job written"                      "[[ -n '$AJ' ]]"
check "menu: DTS -> AC-3 640 kb/s, planned title" "grep -q 'AC3 | 640 kb/s' '$T/amenu.log' && grep -q 'Title: .* -> \"Japanese | AC-3 | 5.1 | 640 kbps\"' '$T/amenu.log'"
if [[ -n "$AJ" ]]; then
    check "job: video copied, titled from its stream" "grep -q -- '-c:v:0 copy' '$AJ' && grep -q -- '-metadata:s:v:0 title=' '$AJ'"
    bash "$AJ" < /dev/null > "$T/arun.log" 2>&1
    OA="$H/compress/out/Fixture HEVC Custom AudioCompressed.mkv"
    check "audio job succeeded"                "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/arun.log'"
    eq    "combined: video keeps its CRF (x265 settings of the copied stream)" "$(vtitle "$OA")" "HEVC | 720p | 10-bit | CRF 30"
    if (( HAVE_MKV == 1 )); then
        eq    "audio titles: transcoded AC-3 at its actual rate, copies keep theirs" "$(atitles "$OA")" \
              "Japanese | AC-3 | 5.1 | 640 kbps/English | TrueHD | 5.1 | $(bps_kbps "$OA" 1) kbps/Japanese | PCM | 2.0 | 2304 kbps/English | AAC | 2.0 | $(bps_kbps "$OA" 3) kbps | Director's Commentary/AC-3 | 2.0 | 192 kbps/"
        eq    "AC-3 title rate = stream bit_rate" "$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 "$OA" | tr -d '\r')" "640000"
        check "verify: titles AS PLANNED, no warnings" "grep -q 'Video title: *AS PLANNED' '$T/arun.log' && grep -q 'Track titles: *AS PLANNED' '$T/arun.log' && ! grep -q 'RESULT:' '$T/arun.log'"
        eq    "mkvmerge -J names = ffprobe titles" "$(mkvnames "$OA")" "$(ffnames "$OA")"
    fi
    eq    "kept: languages / dispositions"     "$(ffprobe -v error -select_streams a -show_entries stream_tags=language:stream_disposition=default,comment -of csv=p=0 "$OA" | tr -d '\r' | tr '\n' ' ')" \
                                               "$(ffprobe -v error -select_streams a -show_entries stream_tags=language:stream_disposition=default,comment -of csv=p=0 "$H/compress/out/Fixture HEVC Custom.mkv" | tr -d '\r' | tr '\n' ' ')"
    eq    "kept: chapters"                     "$(ffprobe -v error -show_chapters -of csv=p=0 "$OA" | tr -d '\r' | cut -d, -f5- | tr '\n' ' ')" \
                                               "$(ffprobe -v error -show_chapters -of csv=p=0 "$T/f/SDR.mkv" | tr -d '\r' | cut -d, -f5- | tr '\n' ' ')"
fi

# ------------------------------------------------------------
echo
echo "== 5 names only: no re-encode, repeat finalization is a no-op"
if (( HAVE_MKV == 1 )); then
    cp "$T/f/SDR.mkv" "$T/f/names.mkv"
    before=$(payload "$T/f/names.mkv")
    declare -A W1=()
    while IFS=$'\t' read -r idx _ cur new; do
        [[ -n "$new" && "$cur" != "$new" ]] && W1[$idx]="$new"
    done < <(mkv_std_track_titles "$T/f/names.mkv" auto)
    mkv_write_track_titles "$T/f/names.mkv" W1
    eq    "write: success"                     "$?" 0
    eq    "write: streams untouched"           "$(payload "$T/f/names.mkv")" "$before"
    eq    "write: missing title created, release title replaced" "$(vtitle "$T/f/names.mkv")" "AVC | 720p | 8-bit"
    eq    "write: subtitles / chapters / attachment kept" \
          "$(ffprobe -v error -show_entries stream=codec_type:stream_tags=language,title,filename -show_chapters -of csv=p=0 "$T/f/names.mkv" | tr -d '\r' | grep -v '^video\|^audio' | tr '\n' ' ')" \
          "$(ffprobe -v error -show_entries stream=codec_type:stream_tags=language,title,filename -show_chapters -of csv=p=0 "$T/f/SDR.mkv" | tr -d '\r' | grep -v '^video\|^audio' | tr '\n' ' ')"
    n=0
    while IFS=$'\t' read -r idx _ cur new; do
        [[ -n "$new" && "$cur" != "$new" ]] && ((n += 1))
    done < <(mkv_std_track_titles "$T/f/names.mkv" auto)
    # TrueHD / AAC without statistics: no measured rate here (left out),
    # so the plan is the same as written
    eq    "repeat: nothing left to change"     "$n" 0
fi

# ------------------------------------------------------------
echo
echo "== 6 verify.sh: titles against the actual streams"
VH="$T/vhome"
mkdir -p "$VH/compress/in" "$VH/compress/out"
cp -r "$SRC_WORK" "$VH/compress/work"
rm -rf "$VH/compress/work/tests" "$VH/compress/work/logs"
cp "$ROOT/verify.sh" "$VH/compress/"
cp "$T/f/SDR.mkv" "$VH/compress/out/Bad HEVC High.mkv"           # release / stale / missing titles
cp "$T/out/sdr.mkv" "$VH/compress/out/Good HEVC Custom.mkv"       # a finalized output
printf '2\n1\n' | HOME="$VH" bash "$VH/compress/verify.sh" > "$T/v1.log" 2>&1
check "Verify: release video title STALE"       "grep 'Video title *\"$REL\" - STALE (the stream is not: ' '$T/v1.log' | grep -q 'HEVC' && grep 'Video title *\"$REL\" - STALE' '$T/v1.log' | grep -q '2160p'"
check "Verify: proposes the standard title"     "grep -A1 'Video title *\"$REL\"' '$T/v1.log' | grep -q -- '-> \"AVC | 720p | 8-bit\"'"
check "Verify: missing audio title reported"     "grep -q 'no title - MISSING' '$T/v1.log'"
if (( HAVE_MKV == 1 )); then
    check "Verify: finalized output fully standard" "awk '/Good HEVC Custom/,/Track titles/' '$T/v1.log' | grep -q 'Track titles *OK (nothing to correct)'"
    check "verify_titles.sh agrees (window_tagger)" "bash '$VH/compress/work/lib/mkv-property-handler/verify_titles.sh' '$VH/compress/out/Good HEVC Custom.mkv' | grep -q \$'^Track titles\\tOK'"
    before=$(payload "$VH/compress/out/Bad HEVC High.mkv")
    printf '2\n2\n' | HOME="$VH" bash "$VH/compress/verify.sh" > "$T/v2.log" 2>&1
    check "Validate + update: titles corrected"   "grep -q 'Track titles *UPDATED' '$T/v2.log'"
    eq    "Validate + update: standard video title" "$(vtitle "$VH/compress/out/Bad HEVC High.mkv")" "AVC | 720p | 8-bit"
    B="$VH/compress/out/Bad HEVC High.mkv"
    eq    "Validate + update: standard audio titles (measured rates)" "$(atitles "$B")" \
          "Japanese | DTS | 5.1 | 1536 kbps/English | TrueHD | 5.1 | $(bps_kbps "$B" 1) kbps/Japanese | PCM | 2.0 | 2304 kbps/English | AAC | 2.0 | $(bps_kbps "$B" 3) kbps | Director's Commentary/AC-3 | 2.0 | 192 kbps/"
    eq    "Validate + update: streams untouched"  "$(payload "$B")" "$before"
    eq    "Validate + update: mkvmerge -J agrees" "$(mkvnames "$B")" "$(ffnames "$B")"
    printf '2\n2\n' | HOME="$VH" bash "$VH/compress/verify.sh" > "$T/v3.log" 2>&1
    check "repeat: nothing rewritten"             "grep -q 'Titles updated:    0' '$T/v3.log' && grep -q 'Titles to correct: 0' '$T/v3.log'"
fi

# ------------------------------------------------------------
echo
echo "== 7 audio_titles.sh: preview, confirmation, names only, warnings"
if (( HAVE_MKV == 1 )); then
    A="$T/f/at.mkv"
    cp "$T/f/SDR.mkv" "$A"
    # a1: a name that is no recognised description; a3: a commentary credit
    mkvpropedit "$A" --edit track:a2 --set "name=Nolan" --edit track:a4 --set "name=Commentary by John Carpenter" > /dev/null
    before=$(payload "$A"); tracks=$(mkv_identify_tracks "$A" | cut -f1-8,10,11)
    bash "$ROOT/audio_titles.sh" --dry-run "$A" > "$T/at1.log" 2>&1
    eq    "dry run: nothing written"           "$(payload "$A")|$(atitles "$A")" "$before|Japanese DTS 5.1 -FGT/Nolan//Commentary by John Carpenter//"
    check "dry run: old -> new shown"          "grep -q -- '-> \"Japanese | DTS | 5.1 | 1536 kbps\"' '$T/at1.log'"
    check "dry run: unparsed name warned, unchanged" "grep -A2 '\"Nolan\" -> unchanged' '$T/at1.log' | grep -q 'WARNING: description \"Nolan\" not recognised'"
    printf 'n\n' | bash "$ROOT/audio_titles.sh" "$A" > "$T/at2.log" 2>&1
    eq    "declined: nothing written"          "$(atitles "$A")" "Japanese DTS 5.1 -FGT/Nolan//Commentary by John Carpenter//"
    printf 'y\n' | bash "$ROOT/audio_titles.sh" "$A" > "$T/at3.log" 2>&1
    eq    "applied: standard names, credit verbatim, unparsed kept" "$(atitles "$A")" \
          "Japanese | DTS | 5.1 | 1536 kbps/Nolan/Japanese | PCM | 2.0 | 2304 kbps/English | AAC | 2.0 | Commentary by John Carpenter/AC-3 | 2.0 | 192 kbps/"
    eq    "applied: stream payloads unchanged" "$(payload "$A")" "$before"
    eq    "applied: tracks / languages / flags unchanged" "$(mkv_identify_tracks "$A" | cut -f1-8,10,11)" "$tracks"
    check "applied: verified, warning listed"  "grep -q 'track count, order, codecs, languages and flags unchanged' '$T/at3.log' && grep -A3 'Identify manually' '$T/at3.log' | grep -q 'Nolan'"
    bash "$ROOT/audio_titles.sh" --dry-run "$A" > "$T/at4.log" 2>&1
    check "repeat: nothing to change"          "grep -q 'Nothing to change' '$T/at4.log'"
fi

echo
for s in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do echo "skipped: $s"; done
echo "PASS $PASS  FAIL $FAIL"
exit $(( FAIL > 0 ))
