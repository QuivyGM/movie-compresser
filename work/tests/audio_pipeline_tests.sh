#!/usr/bin/env bash
# Audio pipeline: layout planning (audio_plan.sh), stream / codec
# mapping (build_stream_map), the audio menu job and its verification.
#
#   bash ~/compress/work/tests/audio_pipeline_tests.sh
#
# Needs ffmpeg / ffprobe (with the experimental DTS encoder for the
# fixtures). Short synthetic files only.
#
#  1. planner: every standard layout for Opus (incl. 5.1(side) -> 5.1,
#     5.0(side) -> 5.0, quad(side) -> quad, 6.1(back) -> 6.1 by explicit
#     channelmap; 2.1 / 4.0 / 6.0 / 7.0 / 7.1(wide) / >8 channels / no
#     speaker order copied with a reason), E-AC-3 (6.0 / hexagonal would
#     lose a channel: copied) and AAC; never aformat / pan / -ac
#  2. build_stream_map: explicit source -> output audio index, one codec
#     option per stream, main video not the first stream, no video
#  3. The Raid 2 case: DTS 5.1(side) Compact -> Opus 5.1; per-channel
#     tone identity; copied tracks payload-identical; language / title /
#     default / forced / commentary kept; no "Multiple -codec" warning
#  4. mixed copied / transcoded tracks, video not first: unsupported
#     layouts copied with the reason shown, 44.1 kHz -> Opus 48 kHz
#     without a warning, every option on the right output track
#  5. nothing to transcode -> nothing started
#  6. verification: channel count / codec / planned layout / copied
#     payload mismatch fail
#  7. job level: the old libopus failure leaves no output; a downmixed
#     track fails the verification and is never finalized
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
if [[ "${AUDIO_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

for t in ffmpeg ffprobe; do
    command -v "$t" >/dev/null || { echo "$t not found: skipped"; exit 0; }
done
unset COMPRESS_VERBOSE

WORK_DIR="$T/work"
mkdir -p "$WORK_DIR" "$T/f"
for l in media_probe media_stats bitrate encode_common hdr_dovi policy audio_plan; do
    source "$SRC_WORK/lib/$l.sh" > /dev/null
done
HAVE_MKV=0
command -v mkvpropedit >/dev/null && HAVE_MKV=1

# tones LAYOUT FREQ...  ->  aevalsrc source: one sine per channel, in
# the layout's channel order (channel identity is checked by frequency)
tones() {
    local l="$1" e=() f
    shift
    for f in "$@"; do e+=("0.3*sin(2*PI*$f*t)${TONE_NOISE:+ + 0.05*random(${#e[@]})}"); done
    printf 'aevalsrc=%s:c=%s:s=%s:d=4' "$(IFS='|'; echo "${e[*]}")" "$l" "${TONE_RATE:-48000}"
}

# dominant_tones FILE AUDIO_INDEX FREQ...  ->  for every channel (in
# stream order) the FREQ with the most energy, space separated
dominant_tones() {
    local file="$1" a="$2" f k v
    local -A best=() bestf=()
    shift 2
    for f in "$@"; do
        while IFS='=' read -r k v; do
            v="${v%$'\r'}"
            k="${k#lavfi.astats.}"; k="${k%%.*}"
            [[ "$v" =~ ^-?[0-9.]+$ ]] || v=-999
            if [[ -z "${best[$k]:-}" ]] || awk -v a="$v" -v b="${best[$k]}" 'BEGIN { exit !(a > b) }'; then
                best[$k]="$v"; bestf[$k]="$f"
            fi
        done < <(ffmpeg -v error -nostdin -i "$file" -map "0:a:$a" \
            -af "bandpass=f=$f:w=15,astats=metadata=1:reset=0,ametadata=print:file=-" -f null - 2>/dev/null |
            grep -E '^lavfi\.astats\.[0-9]+\.RMS_level=' | tail -n 64 | awk -F= '{ last[$1] = $0 } END { for (k in last) print last[k] }')
    done
    for ((k = 1; k <= ${#bestf[@]}; k++)); do printf '%s ' "${bestf[$k]}"; done
}

probe_a() {   # FILE AUDIO_INDEX ENTRIES  ->  csv
    ffprobe -v error -select_streams "a:$2" -show_entries "$3" -of csv=p=0 "$1" 2>/dev/null | tr -d '\r'
}

# ------------------------------------------------------------
echo "== 1 layout planning (audio_plan.sh)"

# plan ENCODER LAYOUT CHANNELS [KBPS] [RATE]  ->  the audio_encode_plan
# line (status filter layout channels rate note, tab-separated)
plan() { audio_encode_plan "$1" "${4:-$((64 * $3))}" "$2" "$3" "${5:-48000}"; }
pl()   { cut -f"$1" <<< "$2"; }

declare -A OPUS=(
    [mono]="ok|-|mono"                [stereo]="ok|-|stereo"
    [2.1]="copy"                      [3.0]="ok|-|3.0"
    [4.0]="copy"                      [quad]="ok|-|quad"
    [quad(side)]="ok|map|quad"        [5.0]="ok|-|5.0"
    [5.0(side)]="ok|map|5.0"          [5.1]="ok|-|5.1"
    [5.1(side)]="ok|map|5.1"          [6.0]="copy"
    [hexagonal]="copy"                [6.1]="ok|-|6.1"
    [6.1(back)]="ok|map|6.1"          [7.0]="copy"
    [7.1]="ok|-|7.1"                  [7.1(wide)]="copy"
    [7.1(wide-side)]="copy"           [octagonal]="copy"
    [5.1.2]="copy"                    [7.1.4]="copy"
)
for l in "${!OPUS[@]}"; do
    n=$(ap_layout_channels "$l" "")
    n=$(awk -F+ '{ print NF }' <<< "$n")
    p=$(plan libopus "$l" "$n")
    want="${OPUS[$l]}"
    got="$(pl 1 "$p")"
    if [[ "$want" != copy ]]; then
        f=$(pl 2 "$p"); [[ "$f" == channelmap=* ]] && f=map
        got+="|$f|$(pl 3 "$p")"
        [[ "$got" == "$want" && "$(pl 4 "$p")" == "$n" && "$(pl 5 "$p")" == 48000 ]] || got+=" ($p)"
    else
        [[ -n "$(pl 6 "$p")" ]] || got+=" (no reason)"
    fi
    eq "opus $l -> $want" "$got" "$want"
done

p=$(plan libopus "5.1(side)" 6)
eq    "opus 5.1(side): explicit channelmap, SL->BL SR->BR" "$(pl 2 "$p")" "channelmap=map=FL-FL|FR-FR|FC-FC|LFE-LFE|SL-BL|SR-BR:channel_layout=5.1"
check "opus 5.1(side): note says relabel, no remix"       "[[ '$(pl 6 "$p")' == *'SL->BL, SR->BR; same channels, no remix'* ]]"
eq    "opus 6.1(back): BL->SL BR->SR, BC kept"            "$(pl 2 "$(plan libopus "6.1(back)" 7)")" "channelmap=map=FL-FL|FR-FR|FC-FC|LFE-LFE|BC-BC|BL-SL|BR-SR:channel_layout=6.1"
p=$(plan libopus 2.1 3)
check "opus 2.1: copy, reason names the Opus layouts"    "[[ '$(pl 1 "$p")' == copy && '$(pl 6 "$p")' == *'Opus has no 3-channel layout'* ]]"
check "opus 7.1.4: at most 8 channels"                   "[[ '$(pl 6 "$(plan libopus 7.1.4 12)")' == *'at most 8 positioned channels'* ]]"
p=$(plan libopus "6 channels (FL+FR+FC+LFE+SL+SR)" 6)
eq    "opus custom-order 6ch named channels -> 5.1"       "$(pl 1 "$p")|$(pl 3 "$p")" "ok|5.1"
p=$(plan libopus "6 channels" 6)
check "opus 6ch without speaker order: copy"             "[[ '$(pl 1 "$p")' == copy && '$(pl 6 "$p")' == *'no known speaker order'* ]]"
p=$(plan libopus - 2)
eq    "opus 2ch without layout: stereo, index-mapped"     "$(pl 1 "$p")|$(pl 2 "$p")|$(pl 3 "$p")" "ok|channelmap=map=0-FL|1-FR:channel_layout=stereo|stereo"
p=$(plan libopus mono 1 640)
check "opus bit rate out of range: copy, encoder error shown" "[[ '$(pl 1 "$p")' == copy && '$(pl 6 "$p")' == *'bit rate'* ]]"
p=$(plan libopus stereo 2 192 44100)
check "opus 44.1 kHz: planned 48000 Hz, noted"           "[[ '$(pl 5 "$p")' == 48000 && '$(pl 6 "$p")' == *'44100 Hz -> 48000 Hz'* ]]"

for c in "eac3 6.0 6 copy" "eac3 hexagonal 6 copy" "eac3 2.1 3 ok|2.1" "eac3 4.0 4 ok|4.0" \
         "eac3 5.1 6 ok|5.1(side)" "eac3 5.1(side) 6 ok|5.1(side)" "ac3 5.0 5 ok|5.0(side)" \
         "aac 5.1(side) 6 ok|5.1" "aac 6.0 6 copy" "aac 7.1(wide) 8 copy" "libmp3lame 5.1 6 copy"; do
    read -r e l n want <<< "$c"
    p=$(plan "$e" "$l" "$n" 384)
    got="$(pl 1 "$p")"; [[ "$got" == ok ]] && got+="|$(pl 3 "$p")"
    eq "$e $l -> $want" "$got" "$want"
done
check "eac3 6.0: reason says 6 -> 5 channels"            "[[ '$(pl 6 "$(plan eac3 6.0 6 384)")' == *'(6 -> 5 channels)'* ]]"
check "aac 5.1(side): relabelled by channelmap"          "[[ '$(pl 2 "$(plan aac "5.1(side)" 6 384)")' == channelmap=*SL-BL* ]]"
check "no plan uses aformat / pan / -ac / -ch_layout"    "! grep -qE 'aformat|pan=|-ac|ch_layout' <<< \"\$(declare -f audio_encode_plan _ap_trial)\""

eq    "libopus > 2 channels: mapping family 1"      "$(audio_encoder_opts libopus 6 3 | tr '\n' ' ')" "-mapping_family:a:3 1 "
eq    "libopus stereo / E-AC-3: no extra options"   "$(audio_encoder_opts libopus 2 0; audio_encoder_opts eac3 6 0)" ""

# every layout Opus can take, encoded exactly as the job does (planned
# channelmap + encoder options), decoded and checked by tone: each
# source channel must come out on its own (or relabelled) speaker.
# FFmpeg's default mapping family scrambles 5.0 and 6.1.
# Expensive (an encode + decode per layout): AUDIO_TESTS_EXHAUSTIVE=1.
# Always covered end to end: 5.1(side) -> 5.1 (section 3) and
# 5.0(side) -> 5.0 (section 4, the mapping-family case).
ID_LAYOUTS=()
if [[ "${AUDIO_TESTS_EXHAUSTIVE:-0}" == 1 ]]; then
    ID_LAYOUTS=(3.0 quad "quad(side)" 5.0 "5.0(side)" 5.1 "5.1(side)" 6.1 "6.1(back)" 7.1)
else
    echo "skipped: per-layout Opus channel identity (AUDIO_TESTS_EXHAUSTIVE=1 runs it)"
fi
for l in "${ID_LAYOUTS[@]+"${ID_LAYOUTS[@]}"}"; do
    IFS=+ read -ra sc <<< "$(ap_layout_channels "$l" "")"
    declare -A tone=() moved=()
    fs=(); k=0
    for c in "${sc[@]}"; do
        f=$((200 + k * 100)); [[ "$c" == LFE ]] && f=60
        tone[$c]=$f; fs+=("$f"); ((k += 1))
    done
    p=$(plan libopus "$l" "${#sc[@]}")
    filt=$(pl 2 "$p")
    if [[ "$filt" != "-" ]]; then
        for m in $(tr '|' ' ' <<< "${filt#channelmap=map=}"); do m="${m%%:*}"; moved[${m#*-}]="${m%-*}"; done
    fi
    IFS=+ read -ra oc <<< "$(ap_layout_channels "$(pl 3 "$p")" "")"
    want=""
    for c in "${oc[@]}"; do want+="${tone[${moved[$c]:-$c}]} "; done
    a=(-c:a libopus -b:a "$((96 * ${#sc[@]}))k")
    mapfile -t eo < <(audio_encoder_opts libopus "${#sc[@]}" 0)
    [[ "$filt" != "-" ]] && a+=(-filter:a:0 "$filt")
    ffmpeg -v error -y -f lavfi -i "$(tones "$l" "${fs[@]}")" "${a[@]}" "${eo[@]+"${eo[@]}"}" "$T/f/id.mka" 2>/dev/null
    eq "opus $l: channel identity through the planned command" "$(dominant_tones "$T/f/id.mka" 0 "${fs[@]}")" "$want"
    unset tone moved
done

eq    "relabel: side surrounds -> back"                  "$(ap_relabel FL+FR+FC+LFE+SL+SR FL+FR+FC+LFE+BL+BR)" "FL-FL|FR-FR|FC-FC|LFE-LFE|SL-BL|SR-BR"
check "relabel: BC never becomes LFE (hexagonal -> 5.1)" "! ap_relabel FL+FR+FC+BL+BR+BC FL+FR+FC+LFE+BL+BR > /dev/null"
check "relabel: wide channels never become surrounds"    "! ap_relabel FL+FR+FC+LFE+BL+BR+FLC+FRC FL+FR+FC+LFE+BL+BR+SL+SR > /dev/null"
check "relabel: channel count must match"                "! ap_relabel FL+FR+LFE FL+FR > /dev/null"

# ------------------------------------------------------------
echo
echo "== 2 stream mapping (build_stream_map)"
printf '1\n00:00:00,000 --> 00:00:01,000\nhello\n' > "$T/f/s.srt"
printf 'font' > "$T/f/font.ttf"
ffmpeg -v error -y -f lavfi -i "sine=f=300:d=2" -f lavfi -i "testsrc2=s=160x90:r=24:d=2" -i "$T/f/s.srt" -f lavfi -i "sine=f=500:d=2" \
    -map 0:a -map 1:v -map 2:s -map 3:a -c:a aac -b:a 64k -c:v libx264 -preset ultrafast -c:s srt \
    -attach "$T/f/font.ttf" -metadata:s:t mimetype=font/ttf "$T/f/order.mkv"
build_stream_map "$T/f/order.mkv" "$(main_video_index "$T/f/order.mkv")"
eq "video not first: main video mapped first"     "$MAP_ARGS" "-map 0:1 -map 0:0 -map 0:2 -map 0:3 -map 0:4 "
eq "source audio -> output audio index"           "${MAP_AUDIO_OUT[0]}/${MAP_AUDIO_OUT[1]} $MAP_AMAP" "0/1 0:0,1:1"
eq "one codec option per non-audio stream"        "$MAP_CODEC_ARGS" "-c:s:0 copy -c:t:0 copy "
build_stream_map "$T/f/order.mkv" ""
eq "no main video: nothing mapped as video #0"    "$MAP_ARGS|$MAP_CODEC_ARGS" "-map 0:0 -map 0:1 -map 0:2 -map 0:3 -map 0:4 |-c:v:0 copy -c:s:0 copy -c:t:0 copy "
ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x90:r=24:d=2" -f lavfi -i "sine=f=300:d=2" -f lavfi -i "sine=f=500:d=2" \
    -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -c:a aac -b:a 64k \
    -metadata:s:a:1 handler_name="Director Commentary" "$T/f/h.mp4"
build_stream_map "$T/f/h.mp4" 0
check "MP4 handler title on the right output stream" "[[ \"\$MAP_META_ARGS\" == *'-metadata:s:2 title=Director\\ Commentary'* ]]"
MAP_AUDIO_OUT=([0]=0 [1]=3)
check "title args use the output audio index"     "[[ \"\$(audio_title_args '$T/f/order.mkv' '-c:a:1 libopus ')\" != *'s:a:1 '* ]]"
MAP_AUDIO_OUT=()

# ------------------------------------------------------------
# audio menu sandbox: HOME/compress/{out,work}, tmux stubbed (start_job)
mkdir -p "$T/stub"
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
new_home() {   # NAME  ->  HOME with compress/{out,work}
    local h="$T/homes/$1"
    mkdir -p "$h/compress/out"
    cp -r "$SRC_WORK" "$h/compress/work"
    rm -rf "$h/compress/work/tests" "$h/compress/work/logs" "$h/compress/work/cache"
    rm -f "$h/compress/work"/[a-z]*[0-9].sh "$h/compress/work"/*.state "$h/compress/work"/*.progress
    cp "$ROOT/audio_compress_menu.sh" "$h/compress/"
    printf '%s' "$h"
}
conf_with() {   # NAME KEY=VALUE...  ->  compress.conf copy
    local f="$T/$1.conf" kv
    shift
    cp "$SRC_WORK/lib/compress.conf" "$f"
    for kv in "$@"; do sed -i "s|^${kv%%=*}=.*|${kv}|" "$f"; done
    printf '%s' "$f"
}
amenu() {   # HOME CONF INPUT LOG
    printf "$3" | HOME="$1" PATH="$T/stub:$PATH" COMPRESS_CONF="$2" \
        bash "$1/compress/audio_compress_menu.sh" > "$4" 2>&1
}
job_of() { ls -t "$1/compress/work"/a[0-9]*.sh 2>/dev/null | head -1; }

# ------------------------------------------------------------
echo
echo "== 3 The Raid 2: DTS 5.1(side) Compact -> Opus 5.1"
HA=$(new_home raid)
RAID="$HA/compress/out/The Raid 2 (2014) HEVC Base.mkv"
FREQS=(200 300 400 60 600 700)      # FL FR FC LFE SL SR
ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=4" \
    -f lavfi -i "$(tones "5.1(side)" 220 330 440 80 660 770)" \
    -f lavfi -i "$(tones "5.1(side)" "${FREQS[@]}")" \
    -f lavfi -i "$(tones stereo 900 1000)" -i "$T/f/s.srt" \
    -map 0:v -map 1:a -map 2:a -map 3:a -map 4:s -map 4:s \
    -c:v libx264 -preset ultrafast -crf 30 \
    -c:a:0 eac3 -b:a:0 384k -c:a:1 dca -strict -2 -b:a:1 1509k -c:a:2 aac -b:a:2 96k -c:s srt \
    -metadata:s:a:0 language=eng -metadata:s:a:0 "title=English E-AC-3 5.1" -disposition:a:0 default \
    -metadata:s:a:1 language=ind -metadata:s:a:1 "title=Indonesian DTS 5.1" -disposition:a:1 forced \
    -metadata:s:a:2 language=eng -metadata:s:a:2 "title=Commentary" -disposition:a:2 comment \
    -metadata:s:s:0 language=eng -metadata:s:s:1 language=ind -disposition:s:0 default -disposition:s:1 forced \
    "$RAID" 2> "$T/raid_mk.err"

if [[ "$(probe_a "$RAID" 1 stream=codec_name,channel_layout)" != "dts,5.1(side)" ]]; then
    bad "fixture: DTS 5.1(side) track ($(head -1 "$T/raid_mk.err"))"
else
    eq "fixture: source DTS channels carry their own tone" "$(dominant_tones "$RAID" 1 "${FREQS[@]}")" "200 300 400 60 600 700 "
    CONF_A=$(conf_with raid AUDIO_COMPACT_TRIGGER_GIB=0.0002 AUDIO_COMPACT_LIMIT_GIB=0.0002)
    amenu "$HA" "$CONF_A" "1\n2\n3\nn\n" "$T/raid_menu.log"
    JA=$(job_of "$HA")
    # the job removes itself after success: section 7 needs a copy
    [[ -n "$JA" ]] && cp "$JA" "$T/raid_job.sh" && JA="$T/raid_job.sh"
    check "menu: Compact plan shows the relabel"     "grep -q 'Layout: 5.1(side) -> 5.1: surround channels relabelled (SL->BL, SR->BR; same channels, no remix)' '$T/raid_menu.log'"
    check "menu: Opus 48 kHz, no rate change noted"  "! grep -q 'Hz -> 48000 Hz' '$T/raid_menu.log'"
    check "job written"                              "[[ -n '$JA' ]]"
    cmd=$(grep -A6 'item_run mux' "$JA")
    check "job: Opus on output a:1 with its channelmap" "grep -qE -- '-c:a:1 libopus -b:a:1 [0-9]+k -mapping_family:a:1 1 -filter:a:1 channelmap=map=FL-FL\\\\\\|FR-FR\\\\\\|FC-FC\\\\\\|LFE-LFE\\\\\\|SL-BL\\\\\\|SR-BR:channel_layout=5.1' <<< \"\$cmd\""
    check "job: every stream has one codec option"   "grep -q -- '-c:v:0 copy -c:a:0 copy ' <<< \"\$cmd\" && grep -q -- '-c:a:2 copy -c:s:0 copy -c:s:1 copy' <<< \"\$cmd\" && ! grep -qE -- '-c copy|-c:a copy' <<< \"\$cmd\""
    check "job: no aformat / -ac / -ch_layout"       "! grep -qE -- 'aformat|-ac[: ]|-ch_layout' '$JA'"
    check "job: expected plan, hash, mapping"        "grep -q 'atrans=1 aplan=1:opus:6:5.1:48000 ahash=1 amap=0:0\\\\,1:1\\\\,2:2' '$JA'"

    bash "$JA" < /dev/null > "$T/raid_run.log" 2>&1
    OA="$HA/compress/out/The Raid 2 (2014) HEVC Base AudioCompressed.mkv"
    check "job succeeded"                            "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/raid_run.log'"
    check "no 'Multiple -codec' warning"             "! grep -q 'Multiple -codec' '$T/raid_run.log'"
    eq    "output: Opus 5.1, 6 channels, 48 kHz"      "$(probe_a "$OA" 1 stream=codec_name,channels,channel_layout,sample_rate)" "opus,48000,6,5.1"
    eq    "output: channel identity (SL->BL, SR->BR)" "$(dominant_tones "$OA" 1 "${FREQS[@]}")" "200 300 400 60 600 700 "
    eq    "output: copied tracks payload-identical"   "$(_audio_payload_md5 "$OA" | sed -n '1p;3p' | tr '\n' ' ')" "$(_audio_payload_md5 "$RAID" | sed -n '1p;3p' | tr '\n' ' ')"
    check "verify: copied tracks hash-matched"       "grep -q 'Audio track 1: *COPIED (E-AC-3 5.1(side), 48000 Hz, payload MD5 MATCH)' '$T/raid_run.log' && grep -q 'Audio track 3: *COPIED (AAC stereo, 48000 Hz, payload MD5 MATCH)' '$T/raid_run.log'"
    check "verify: relabel reported as planned"      "grep -q 'Audio 2 layout: *5.1(side) -> 5.1 AS PLANNED (same channels' '$T/raid_run.log'"
    check "verify: no audio warning or failure"     "! grep -qE '^  Audio.*(CHANGED|UNEXPECTED|NOT AS PLANNED|MISMATCH|DOES NOT MATCH)' '$T/raid_run.log' && ! grep -q 'RESULT: FAILED' '$T/raid_run.log'"
    # without mkvtoolnix the editions are reported "NOT VERIFIED" (a warning)
    (( HAVE_MKV == 1 )) && check "verify: no warnings at all" "! grep -q 'RESULT:' '$T/raid_run.log'"
    for f in "Default flags" "Forced flags" "Commentary/HI/VI" "Languages"; do
        check "verify: $f MATCH"                     "grep -q '$f: *MATCH' '$T/raid_run.log'"
    done
    eq    "output: languages / dispositions"          "$(ffprobe -v error -select_streams a -show_entries stream_tags=language:stream_disposition=default,forced,comment -of csv=p=0 "$OA" | tr -d '\r' | tr '\n' ' ')" \
                                                      "$(ffprobe -v error -select_streams a -show_entries stream_tags=language:stream_disposition=default,forced,comment -of csv=p=0 "$RAID" | tr -d '\r' | tr '\n' ' ')"
    eq    "output: Opus title rewritten"              "$(probe_a "$OA" 1 stream_tags=title)" "$(audio_title_rewrite "Indonesian DTS 5.1" opus 6)"
    eq    "output: copied titles kept"                "$(probe_a "$OA" 0 stream_tags=title)|$(probe_a "$OA" 2 stream_tags=title)" "English E-AC-3 5.1|Commentary"
    eq    "output: subtitles kept"                    "$(ffprobe -v error -select_streams s -show_entries stream_tags=language:stream_disposition=default,forced -of csv=p=0 "$OA" | tr -d '\r' | tr '\n' ' ')" "1,0,eng 0,1,ind "
    if (( HAVE_MKV == 1 )); then
        check "statistics refreshed for the Opus track" "[[ -n \"\$(probe_a '$OA' 1 stream_tags=NUMBER_OF_BYTES)\" ]] && grep -q 'MKV statistics updated' '$T/raid_run.log'"
    else
        check "stale statistics of the DTS track removed" "[[ -z \"\$(probe_a '$OA' 1 stream_tags=BPS)\" ]]"
    fi
fi

# ------------------------------------------------------------
echo
echo "== 4 mixed copied / transcoded tracks, video not the first stream"
HB=$(new_home mixed)
MIX="$HB/compress/out/Mixed.mkv"
ffmpeg -v error -y -f lavfi -i "$(tones 2.1 200 300 60)" -f lavfi -i "testsrc2=s=320x180:r=24:d=4" \
    -f lavfi -i "$(TONE_NOISE=1 tones 6.0 200 300 400 500 600 700)" -f lavfi -i "$(TONE_NOISE=1 tones "5.0(side)" 200 300 400 600 700)" \
    -f lavfi -i "$(TONE_RATE=44100 tones stereo 300 900)" \
    -map 0:a -map 1:v -map 2:a -map 3:a -map 4:a \
    -c:v libx264 -preset ultrafast -crf 30 -c:a:0 ac3 -b:a:0 448k -c:a:1 flac -c:a:2 flac -c:a:3 pcm_s16le \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=fre -metadata:s:a:2 language=ger -metadata:s:a:3 language=spa \
    "$MIX" 2> "$T/mix_mk.err"
eq "fixture: 2.1 / 6.0 / 5.0(side) / PCM stereo 44.1k (MKV: no layout), video second" \
    "$(ffprobe -v error -show_entries stream=codec_type,channel_layout,sample_rate -of csv=p=0 "$MIX" | tr -d '\r' | tr '\n' ' ')" \
    "audio,48000,2.1 video audio,48000,6.0 audio,48000,5.0(side) audio,44100,unknown "
# Compact for tracks >= 0.00012 GiB (~126 KB), at most ~257 kb/s here
# (realistic Opus rates: channel identity is measured on the result)
CONF_B=$(conf_with mixed AUDIO_HIGH_TRIGGER_KBPS=100 AUDIO_COMPACT_TRIGGER_GIB=0.00012 AUDIO_COMPACT_LIMIT_GIB=0.00012)
# track 1 Compact, track 2 High, track 3 Compact, track 4 Compact
amenu "$HB" "$CONF_B" "1\n1\n3\ny\n2\n2\ny\n3\n3\ny\n4\n3\nn\n" "$T/mix_menu.log"
JB=$(job_of "$HB")
[[ -n "$JB" ]] && cp "$JB" "$T/mixed_job.sh" && JB="$T/mixed_job.sh"
check "menu: 2.1 Opus impossible -> copy, reason"  "grep -q 'Opus not possible without changing channels; copy unchanged' '$T/mix_menu.log' && grep -q 'Reason: 2.1: Opus has no 3-channel layout' '$T/mix_menu.log'"
check "menu: 6.0 E-AC-3 would drop a channel -> copy" "grep -q 'Reason: 6.0: E-AC-3 would turn it into 5.0(side) (6 -> 5 channels)' '$T/mix_menu.log'"
check "plan summary lists the copy reasons"        "[[ \$(grep -c '^  Reason: ' '$T/mix_menu.log') -ge 2 ]] && grep -A3 '^Track 2: ' '$T/mix_menu.log' | grep -q 'Result: copied unchanged'"
check "menu: 44.1 kHz -> 48 kHz noted"             "grep -q '44100 Hz -> 48000 Hz (Opus rate)' '$T/mix_menu.log'"
cmd=$(grep -A6 'item_run mux' "$JB")
check "job: copied tracks a:0 a:1, Opus a:2 a:3"   "grep -qE -- '-c:v:0 copy -c:a:0 copy -c:a:1 copy -c:a:2 libopus -b:a:2 [0-9]+k -mapping_family:a:2 1 -filter:a:2 channelmap=[^ ]*:channel_layout=5.0 -c:a:3 libopus -b:a:3 [0-9]+k -filter:a:3 channelmap=map=0-FL\\\|1-FR:channel_layout=stereo ' <<< \"\$cmd\""
check "job: no mapping family for stereo Opus"   "! grep -q -- '-mapping_family:a:3' <<< \"\$cmd\""
check "menu: layout-less PCM stereo index-mapped"  "grep -q 'unspecified 2-channel layout stored as stereo (channel order kept)' '$T/mix_menu.log'"
check "job: plan for tracks 3 and 4 only"          "grep -q 'atrans=2\\\\,3 aplan=2:opus:5:5.0:48000\\\\,3:opus:2:stereo:48000 ahash=1 amap=0:0\\\\,1:1\\\\,2:2\\\\,3:3' '$JB'"
bash "$JB" < /dev/null > "$T/mix_run.log" 2>&1
OB="$HB/compress/out/Mixed AudioCompressed.mkv"
check "job succeeded"                              "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/mix_run.log'"
check "no 'Multiple -codec' warning"               "! grep -q 'Multiple -codec' '$T/mix_run.log'"
eq    "output tracks in source order"              "$(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,channel_layout,sample_rate:stream_tags=language -of csv=p=0 "$OB" | tr -d '\r' | tr '\n' ' ')" \
      "ac3,48000,3,2.1,eng flac,48000,6,6.0,fre opus,48000,5,5.0,ger opus,48000,2,stereo,spa "
eq    "copied 2.1 / 6.0 payload-identical"         "$(_audio_payload_md5 "$OB" | head -2 | tr '\n' ' ')" "$(_audio_payload_md5 "$MIX" | head -2 | tr '\n' ' ')"
eq    "5.0(side) -> Opus 5.0: channel identity"     "$(dominant_tones "$OB" 2 200 300 400 600 700)" "200 300 400 600 700 "
check "verify: 44.1 -> 48 kHz as planned, no warning" "grep -q 'Audio 4 sample rate: *44100 -> 48000 Hz AS PLANNED' '$T/mix_run.log' && ! grep -qiE 'UNEXPECTED|layout changed|sample rate .* planned' '$T/mix_run.log'"
check "verify: 2.1 / 6.0 hash-matched"             "grep -q 'Audio track 1: *COPIED (AC-3 2.1, 48000 Hz, payload MD5 MATCH)' '$T/mix_run.log' && grep -q 'Audio track 2: *COPIED (FLAC 6.0, 48000 Hz, payload MD5 MATCH)' '$T/mix_run.log'"

# ------------------------------------------------------------
echo
echo "== 5 nothing to transcode"
HC=$(new_home wide)
ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x90:r=24:d=4" -f lavfi -i "$(TONE_NOISE=1 tones "7.1(wide)" 1 2 3 4 5 6 7 8)" \
    -map 0:v -map 1:a -map 1:a -c:v libx264 -preset ultrafast -c:a:0 flac -c:a:1 pcm_s16le "$HC/compress/out/Wide.mkv" 2>/dev/null
# FLAC 7.1(wide): named, but no Opus layout; PCM 8ch: MKV stores no layout
amenu "$HC" "$CONF_B" "1\n1\n3\ny\n2\n3\nn\n" "$T/wide_menu.log"
check "7.1(wide) Compact: Opus impossible, copy"   "grep -q 'Reason: 7.1(wide): Opus has no 8-channel layout' '$T/wide_menu.log'"
check "PCM 8ch without layout: copy, no guessing"  "grep -q 'the 8 channels have no known speaker order' '$T/wide_menu.log'"
check "nothing started"                            "grep -q 'No selected track requires compression.' '$T/wide_menu.log' && [[ -z \"\$(job_of '$HC')\" ]]"

# ------------------------------------------------------------
echo
echo "== 6 verification of transcoded / copied tracks"
if [[ -s "${OA:-}" ]]; then
    vrun() {   # NAME PART [aplan]  ->  report in $T/v_NAME/report.txt
        ITEM_INPUT="$RAID"; ITEM_PART="$2"; ITEM_TMP="$T/v_$1"
        mkdir -p "$ITEM_TMP"
        unset ITEM_EXP; declare -gA ITEM_EXP=([vidx]=0 [video]=copy [atrans]=1 [aplan]="${3:-1:opus:6:5.1:48000}" [ahash]=1 [amap]="0:0,1:1,2:2")
        item_verify_output > /dev/null 2>&1
    }
    rep() { cat "$T/v_$1/report.txt"; }
    vrun good "$OA"
    check "the real output passes"                   "rep good | grep -q 'Audio 2 layout: *5.1(side) -> 5.1 AS PLANNED' && ! rep good | grep -q 'RESULT: FAILED'"
    ffmpeg -v error -y -i "$OA" -map 0 -c copy -c:a:1 libopus -ac:a:1 2 -b:a:1 128k "$T/f/stereo.mkv" 2>/dev/null
    vrun chan "$T/f/stereo.mkv"
    check "channel count change FAILS"               "rep chan | grep -q 'Audio 2 channels: *CHANGED: 6 -> 2' && rep chan | grep -q 'RESULT: FAILED'"
    ffmpeg -v error -y -i "$OA" -map 0 -c copy -c:a:1 aac -b:a:1 384k "$T/f/aac.mkv" 2>/dev/null
    vrun codec "$T/f/aac.mkv"
    check "codec mismatch FAILS"                     "rep codec | grep -q 'Audio 2 codec: *NOT AS PLANNED: aac (planned opus)' && rep codec | grep -q 'RESULT: FAILED'"
    vrun layout "$OA" "1:opus:6:5.1(side):48000"
    check "planned layout mismatch FAILS"            "rep layout | grep -q 'Audio 2 layout: *NOT AS PLANNED: 5.1 (planned 5.1(side)' && rep layout | grep -q 'RESULT: FAILED'"
    ffmpeg -v error -y -i "$OA" -map 0 -c copy -c:a:0 eac3 -b:a:0 384k "$T/f/reenc.mkv" 2>/dev/null
    vrun hash "$T/f/reenc.mkv"
    check "copied payload mismatch FAILS"            "rep hash | grep -q 'Audio track 1: .*payload MD5 MISMATCH' && rep hash | grep -q 'RESULT: FAILED - audio 1 payload differs'"
    vrun sr "$OA" "1:opus:6:5.1:44100"
    check "unexpected sample rate warns"             "rep sr | grep -q 'Audio 2 sample rate: *UNEXPECTED: 48000 Hz (planned 44100 Hz)'"
else
    bad "verification tests need the section 3 output"
fi

# ------------------------------------------------------------
echo
echo "== 7 job-level failures never finalize a broken file"
if [[ -n "${JA:-}" && -s "${OA:-}" ]]; then
    mv "$OA" "$T/f/raid_ok.mkv"

    # the original bug: libopus given 5.1(side) (no channelmap)
    sed 's/ -filter:a:1 [^ ]*//' "$JA" > "$T/raid_nomap.sh"
    bash "$T/raid_nomap.sh" < /dev/null > "$T/nomap_run.log" 2>&1
    check "encoder failure: item FAILED (pass mux)"  "grep -q 'Reason: pass mux failed (ffmpeg exit' '$T/nomap_run.log' && grep -q 'Invalid channel layout 5.1(side)' '$T/nomap_run.log'"
    check "encoder failure: no output, no .part"     "[[ ! -e '$OA' && ! -e '$OA.part' && -z \"\$(ls '$HA/compress/out' | grep -i audiocompressed)\" ]]"
    check "encoder failure: recorded in failed.tsv"  "grep -rq 'The Raid 2 (2014) HEVC Base.mkv' '$HA/compress/work/logs'/*/failed.tsv"

    # a downmix sneaking into the command fails the verification
    sed 's/-b:a:1 \([0-9]*k\)/-b:a:1 \1 -ac:a:1 2/' "$JA" > "$T/raid_downmix.sh"
    bash "$T/raid_downmix.sh" < /dev/null > "$T/downmix_run.log" 2>&1
    check "downmix: verification FAILS the item"     "grep -q 'audio 2 channel count changed (6 -> 2)' '$T/downmix_run.log' && grep -q 'All encodes finished: 0 ok, 1 failed' '$T/downmix_run.log'"
    check "downmix: never finalized, kept for inspection" "[[ ! -e '$OA' && -s '$OA.verify-failed' ]]"
else
    bad "job-level tests need the section 3 job and output"
fi

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
