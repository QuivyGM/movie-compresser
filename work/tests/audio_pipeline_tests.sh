#!/usr/bin/env bash
# Audio pipeline: layout planning (audio_plan.sh), stream / codec
# mapping (build_stream_map), the audio menu job and its verification.
#
#   bash ~/compress/work/tests/audio_pipeline_tests.sh
#
# Needs ffmpeg / ffprobe (with the experimental DTS encoder for the
# fixtures). Short synthetic files only.
#
#  1. planner: every standard layout for AC-3 (mono ... 5.1, back
#     surrounds stored as AC-3's side pair; 6.0 / hexagonal / 6.1 / 7.x /
#     >8 channels / no speaker order copied with a reason, never
#     downmixed), AC-3 bit rate steps (rounded down, never up; a rate
#     FFmpeg would round is refused), AC-3 sample rates, E-AC-3 and AAC;
#     never aformat / pan / -ac; per-channel tone identity through AC-3
#  2. build_stream_map: explicit source -> output audio index, one codec
#     option per stream, main video not the first stream, no video
#  3. The Raid 2 case: DTS 5.1(side) Compact -> AC-3 5.1(side); per-
#     channel tone identity; copied tracks payload-identical; language /
#     default / forced / commentary kept, standard titles (Language |
#     Codec | Channels | Bitrate | Type) on every track; no "Multiple -codec"
#  4. eight tracks, different codecs and layouts, video not first:
#     AC-3 2.1 / 5.0(side) / layout-less PCM stereo 44.1 kHz / FLAC
#     5.1(back) 96 kHz / PCM mono transcoded, Opus stereo High -> AC-3,
#     6.0 and 7.1 copied with the reason shown; tone identity; exactly
#     one codec configuration per output stream; bit rate as planned
#  5. nothing to transcode (7.1(wide), 8ch PCM) -> nothing started
#  6. verification: channel count / codec / planned layout / bit rate /
#     copied payload mismatch fail; jobs without a planned bit rate
#  7. job level: an AC-3 encoder failure leaves no output; a downmixed
#     or wrong-rate track fails the verification and is never finalized
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
has()   { grep -qF -- "$2" "$1"; }      # FILE TEXT: literal match

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
# mk_rate FILE AUDIO_INDEX  ->  " | N kbps": the measured rate a
# variable-rate track's title carries once the titles are finalized
# (statistics tags, MKVToolNix); "" without MKVToolNix
mk_rate() {
    local b
    (( HAVE_MKV == 1 )) || return 0
    b=$(probe_a "$1" "$2" stream_tags=BPS | head -n 1)
    [[ "$b" =~ ^[0-9]+$ ]] && printf ' | %d kbps' $(( (b + 500) / 1000 ))
}

# ------------------------------------------------------------
echo "== 1 layout planning (audio_plan.sh)"

# plan ENCODER LAYOUT CHANNELS [KBPS] [RATE]  ->  the audio_encode_plan
# line (status filter layout channels rate note, tab-separated)
plan() { audio_encode_plan "$1" "${4:-$((64 * $3))}" "$2" "$3" "${5:-48000}"; }
pl()   { cut -f"$1" <<< "$2"; }

# AC-3 takes every layout up to 5.1 as it is (no channelmap); FFmpeg's
# decoder names the surround pair SL/SR. Anything else would be
# downmixed by FFmpeg: copied.
declare -A AC3=(
    [mono]="ok|-|mono"                [stereo]="ok|-|stereo"
    [2.1]="ok|-|2.1"                  [3.0]="ok|-|3.0"
    [3.0(back)]="ok|-|3.0(back)"      [4.0]="ok|-|4.0"
    [quad]="ok|-|quad(side)"          [quad(side)]="ok|-|quad(side)"
    [3.1]="ok|-|3.1"                  [4.1]="ok|-|4.1"
    [5.0]="ok|-|5.0(side)"            [5.0(side)]="ok|-|5.0(side)"
    [5.1]="ok|-|5.1(side)"            [5.1(side)]="ok|-|5.1(side)"
    [6.0]="copy"                      [6.0(front)]="copy"
    [hexagonal]="copy"                [6.1]="copy"
    [6.1(back)]="copy"                [6.1(front)]="copy"
    [7.0]="copy"                      [7.0(front)]="copy"
    [7.1]="copy"                      [7.1(wide)]="copy"
    [7.1(wide-side)]="copy"           [octagonal]="copy"
    [5.1.2]="copy"                    [7.1.4]="copy"
)
for l in "${!AC3[@]}"; do
    n=$(ap_layout_channels "$l" "")
    n=$(awk -F+ '{ print NF }' <<< "$n")
    p=$(plan ac3 "$l" "$n")
    want="${AC3[$l]}"
    got="$(pl 1 "$p")"
    if [[ "$want" != copy ]]; then
        f=$(pl 2 "$p"); [[ "$f" == channelmap=* ]] && f=map
        got+="|$f|$(pl 3 "$p")"
        [[ "$got" == "$want" && "$(pl 4 "$p")" == "$n" && "$(pl 5 "$p")" == 48000 ]] || got+=" ($p)"
    else
        [[ -n "$(pl 6 "$p")" ]] || got+=" (no reason)"
    fi
    eq "ac3 $l -> $want" "$got" "$want"
done

p=$(plan ac3 5.1 6)
check "ac3 5.1(back): note says same channels (AC-3 naming)" "[[ '$(pl 6 "$p")' == '5.1 -> 5.1(side): same channels (AC-3 surround naming)' ]]"
eq    "ac3 5.1(side): kept, no filter"                       "$(pl 2 "$(plan ac3 "5.1(side)" 6)")|$(pl 6 "$(plan ac3 "5.1(side)" 6)")" "-|5.1(side) kept"
check "ac3 7.1: copied, at most 6 channels, never downmixed" "[[ '$(pl 6 "$(plan ac3 7.1 8)")' == '7.1: AC-3 stores at most 6 channels (5.1); the 8 channels are copied, never downmixed' ]]"
check "ac3 6.1(back): at most 6 channels"                    "[[ '$(pl 6 "$(plan ac3 "6.1(back)" 7)")' == *'at most 6 channels'* ]]"
check "ac3 7.1.4: at most 6 channels"                        "[[ '$(pl 6 "$(plan ac3 7.1.4 12)")' == *'at most 6 channels'* ]]"
check "ac3 6.0: reason says 6 -> 5 channels"                 "[[ '$(pl 6 "$(plan ac3 6.0 6)")' == *'AC-3 would turn it into 5.0(side) (6 -> 5 channels)'* ]]"
p=$(plan ac3 "6 channels (FL+FR+FC+LFE+SL+SR)" 6)
eq    "ac3 custom-order 6ch named channels -> 5.1(side)"     "$(pl 1 "$p")|$(pl 3 "$p")" "ok|5.1(side)"
p=$(plan ac3 "6 channels" 6)
check "ac3 6ch without speaker order: copy"                  "[[ '$(pl 1 "$p")' == copy && '$(pl 6 "$p")' == *'no known speaker order'* ]]"
p=$(plan ac3 - 2)
eq    "ac3 2ch without layout: stereo, index-mapped"         "$(pl 1 "$p")|$(pl 2 "$p")|$(pl 3 "$p")" "ok|channelmap=map=0-FL|1-FR:channel_layout=stereo|stereo"
p=$(plan ac3 - 1)
eq    "ac3 1ch without layout: mono, index-mapped"           "$(pl 1 "$p")|$(pl 2 "$p")|$(pl 3 "$p")" "ok|channelmap=map=0-FC:channel_layout=mono|mono"
p=$(plan ac3 "5.1(side)" 6 32)
check "ac3 5.1 at 32 kb/s: copy, encoder error shown"        "[[ '$(pl 1 "$p")' == copy && '$(pl 6 "$p")' == *'Bit allocation failed'* ]]"
p=$(plan ac3 "5.1(side)" 6 630)
check "ac3 630 kb/s (FFmpeg would use 640): copy, reason"    "[[ '$(pl 1 "$p")' == copy && '$(pl 6 "$p")' == *'AC-3 would encode at 640 kb/s instead of 630 kb/s'* ]]"
p=$(plan ac3 stereo 2 192 44100)
eq    "ac3 44.1 kHz: kept, no rate note"                     "$(pl 5 "$p")|$(pl 6 "$p")" "44100|stereo kept"
p=$(plan ac3 "5.1(side)" 6 448 96000)
check "ac3 96 kHz: planned 48000 Hz, noted"                  "[[ '$(pl 5 "$p")' == 48000 && '$(pl 6 "$p")' == *'96000 Hz -> 48000 Hz (AC-3 rate)'* ]]"
p=$(plan ac3 stereo 2 192 22050)
check "ac3 22.05 kHz: planned 32000 Hz, noted"               "[[ '$(pl 5 "$p")' == 32000 && '$(pl 6 "$p")' == *'22050 Hz -> 32000 Hz (AC-3 rate)'* ]]"

got=""
for k in 0 31 32 33 96 100 300 384 600 630 640 641 1024 x; do got+="$k:$(ac3_kbps "$k") "; done
eq    "ac3_kbps: AC-3 rate at or below the target"  "$got" "0: 31: 32:32 33:32 96:96 100:96 300:256 384:384 600:576 630:576 640:640 641:640 1024:640 x: "
check "ac3_kbps: below the minimum fails"            "! ac3_kbps 31 > /dev/null"

for c in "eac3 6.0 6 copy" "eac3 hexagonal 6 copy" "eac3 2.1 3 ok|2.1" "eac3 4.0 4 ok|4.0" \
         "eac3 5.1 6 ok|5.1(side)" "eac3 5.1(side) 6 ok|5.1(side)" \
         "aac 5.1(side) 6 ok|5.1" "aac 6.0 6 copy" "aac 7.1(wide) 8 copy" "libmp3lame 5.1 6 copy"; do
    read -r e l n want <<< "$c"
    p=$(plan "$e" "$l" "$n" 384)
    got="$(pl 1 "$p")"; [[ "$got" == ok ]] && got+="|$(pl 3 "$p")"
    eq "$e $l -> $want" "$got" "$want"
done
check "eac3 6.0: reason says 6 -> 5 channels"            "[[ '$(pl 6 "$(plan eac3 6.0 6 384)")' == *'(6 -> 5 channels)'* ]]"
check "aac 5.1(side): relabelled by channelmap"          "[[ '$(pl 2 "$(plan aac "5.1(side)" 6 384)")' == channelmap=*SL-BL* ]]"
check "no plan uses aformat / pan / -ac / -ch_layout"    "! grep -qE 'aformat|pan=|-ac|ch_layout' <<< \"\$(declare -f audio_encode_plan _ap_trial)\""
check "no Opus encoder left in the audio menu / planner" "! grep -q libopus '$ROOT/audio_compress_menu.sh' '$SRC_WORK/lib/audio_plan.sh'"

# every layout AC-3 takes, encoded exactly as the job does (planned
# filter, no other option), decoded and checked by tone: each source
# channel must come out on its own speaker (back surrounds on AC-3's
# surround pair). Mono / stereo / 5.1(side) / 5.1(back) always; the rest
# with AUDIO_TESTS_EXHAUSTIVE=1. End to end: 5.1(side) (section 3),
# 5.0(side), 5.1(back), mono, stereo, 2.1 (section 4).
ID_LAYOUTS=(mono stereo "5.1(side)" 5.1)
if [[ "${AUDIO_TESTS_EXHAUSTIVE:-0}" == 1 ]]; then
    ID_LAYOUTS+=(2.1 3.0 "3.0(back)" 4.0 quad "quad(side)" 3.1 4.1 5.0 "5.0(side)")
else
    echo "skipped: AC-3 channel identity of the other layouts (AUDIO_TESTS_EXHAUSTIVE=1 runs it)"
fi
for l in "${ID_LAYOUTS[@]}"; do
    IFS=+ read -ra sc <<< "$(ap_layout_channels "$l" "")"
    declare -A tone=()
    fs=(); k=0
    for c in "${sc[@]}"; do
        f=$((200 + k * 100)); [[ "$c" == LFE ]] && f=60
        tone[$c]=$f; fs+=("$f"); ((k += 1))
    done
    p=$(plan ac3 "$l" "${#sc[@]}" 448)
    filt=$(pl 2 "$p")
    IFS=+ read -ra oc <<< "$(ap_layout_channels "$(pl 3 "$p")" "")"
    want=""
    for c in "${oc[@]}"; do want+="${tone[$c]:-${tone[${AP_PAIR[$c]:-}]:-?}} "; done
    a=(-c:a ac3 -b:a 448k)
    [[ "$filt" != "-" ]] && a+=(-filter:a:0 "$filt")
    ffmpeg -v error -y -f lavfi -i "$(tones "$l" "${fs[@]}")" "${a[@]}" "$T/f/id.mka" 2>/dev/null
    eq "ac3 $l: channel identity through the planned command" "$(dominant_tones "$T/f/id.mka" 0 "${fs[@]}")" "$want"
    unset tone
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
check "MP4 handler name -> standard audio title"  "[[ \"\$MAP_ATITLE_ARGS\" == *'-metadata:s:a:1 '* && \"\$MAP_META_ARGS\" != *Director* ]]"
eq    "MP4 handler name kept as the description"  "$(audio_std_title_plan "$T/f/h.mp4" | cut -f3 | tr '\n' '/')" "AAC | 1.0/AAC | 1.0 | Director Commentary/"
MAP_AUDIO_OUT=([0]=0 [1]=3)
check "title args use the output audio index"     "[[ \"\$(audio_std_title_args '$T/f/order.mkv')\" == *'s:a:3 '* && \"\$(audio_std_title_args '$T/f/order.mkv')\" != *'s:a:1 '* ]]"
eq    "transcoded track named after its output"   "$(audio_std_title_plan "$T/f/order.mkv" $'1\tac3\t-\t2\tstereo' | cut -f3 | tr '\n' '/')" "AAC | 1.0/AC-3 | 2.0/"
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
# one_codec_each CMD N  ->  every output audio index 0..N-1 has exactly
# one -c:a:N, and no blanket -c / -c:a / -codec option exists
one_codec_each() {
    local o
    for ((o = 0; o < $2; o++)); do
        (( $(grep -oE -- "-c:a:$o " <<< "$1" | wc -l) == 1 )) || return 1
    done
    ! grep -qE -- '(^| )(-c|-c:a|-codec|-codec:a|-acodec) ' <<< "$1"
}

# ------------------------------------------------------------
echo
echo "== 3 The Raid 2: DTS 5.1(side) Compact -> AC-3 5.1(side)"
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
    # Compact limit 0.0002 GiB over 4 s: ~429 kb/s -> AC-3 384 kb/s
    CONF_A=$(conf_with raid AUDIO_COMPACT_TRIGGER_GIB=0.0002 AUDIO_COMPACT_LIMIT_GIB=0.0002)
    amenu "$HA" "$CONF_A" "1\n2\n3\nn\n" "$T/raid_menu.log"
    JA=$(job_of "$HA")
    # the job removes itself after success: section 7 needs a copy
    [[ -n "$JA" ]] && cp "$JA" "$T/raid_job.sh" && JA="$T/raid_job.sh"
    check "menu: Compact is AC3 384 kb/s"            "grep -q '   AC3 | 384 kb/s -> ' '$T/raid_menu.log'"
    check "menu: AC-3 rate rounded DOWN, shown"      "grep -q 'Rate: 429 kb/s target -> 384 kb/s (AC3 bit rate at or below it)' '$T/raid_menu.log'"
    check "menu: layout kept"                        "grep -q 'Layout: 5.1(side) kept' '$T/raid_menu.log'"
    check "menu: no rate change noted"               "! grep -q 'Hz -> ' '$T/raid_menu.log'"
    check "menu: no Opus anywhere"                   "! grep -qi opus '$T/raid_menu.log'"
    check "job written"                              "[[ -n '$JA' ]]"
    cmd=$(grep -A6 'item_run mux' "$JA")
    check "job: AC-3 on output a:1, no filter"       "grep -qE -- '-c:a:1 ac3 -b:a:1 384k -c:a:2 copy ' <<< \"\$cmd\" && ! grep -q -- '-filter:a' <<< \"\$cmd\""
    check "job: every stream has one codec option"   "grep -q -- '-c:v:0 copy -c:a:0 copy ' <<< \"\$cmd\" && grep -q -- '-c:a:2 copy -c:s:0 copy -c:s:1 copy' <<< \"\$cmd\" && one_codec_each \"\$cmd\" 3"
    check "job: no aformat / -ac / -ch_layout / -ar"  "! grep -qE -- 'aformat|-ac[: ]|-ch_layout|-ar[: ]|libopus|mapping_family' '$JA'"
    check "job: expected plan, hash, mapping"        "has '$JA' 'atrans=1 aplan=1:ac3:6:5.1\(side\):48000:384 ahash=1 amap=0:0\,1:1\,2:2'"

    bash "$JA" < /dev/null > "$T/raid_run.log" 2>&1
    OA="$HA/compress/out/The Raid 2 (2014) HEVC Base AudioCompressed.mkv"
    check "job succeeded"                            "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/raid_run.log'"
    check "no 'Multiple -codec' warning"             "! grep -q 'Multiple -codec' '$T/raid_run.log'"
    eq    "output: AC-3 5.1(side), 6 channels, 48 kHz, 384 kb/s" "$(probe_a "$OA" 1 stream=codec_name,channels,channel_layout,sample_rate,bit_rate)" "ac3,48000,6,5.1(side),384000"
    eq    "output: channel identity"                  "$(dominant_tones "$OA" 1 "${FREQS[@]}")" "200 300 400 60 600 700 "
    eq    "output: copied tracks payload-identical"   "$(_audio_payload_md5 "$OA" | sed -n '1p;3p' | tr '\n' ' ')" "$(_audio_payload_md5 "$RAID" | sed -n '1p;3p' | tr '\n' ' ')"
    check "verify: copied tracks hash-matched"       "grep -q 'Audio track 1: *COPIED (E-AC-3 5.1(side), 48000 Hz, payload MD5 MATCH)' '$T/raid_run.log' && grep -q 'Audio track 3: *COPIED (AAC stereo, 48000 Hz, payload MD5 MATCH)' '$T/raid_run.log'"
    check "verify: transcode reported"               "grep -q 'Audio track 2: *DTS (DTS) 5.1(side) -> AC-3 5.1(side) (transcoded)' '$T/raid_run.log'"
    check "verify: bit rate as planned"              "grep -q 'Audio 2 bit rate: *384 kb/s AS PLANNED' '$T/raid_run.log'"
    check "verify: no audio warning or failure"     "! grep -qE '^  Audio.*(CHANGED|UNEXPECTED|NOT AS PLANNED|MISMATCH|DOES NOT MATCH)' '$T/raid_run.log' && ! grep -q 'RESULT: FAILED' '$T/raid_run.log'"
    # without mkvtoolnix the editions are reported "NOT VERIFIED" (a warning)
    (( HAVE_MKV == 1 )) && check "verify: no warnings at all" "! grep -q 'RESULT:' '$T/raid_run.log'"
    for f in "Default flags" "Forced flags" "Commentary/HI/VI" "Languages"; do
        check "verify: $f MATCH"                     "grep -q '$f: *MATCH' '$T/raid_run.log'"
    done
    eq    "output: languages / dispositions"          "$(ffprobe -v error -select_streams a -show_entries stream_tags=language:stream_disposition=default,forced,comment -of csv=p=0 "$OA" | tr -d '\r' | tr '\n' ' ')" \
                                                      "$(ffprobe -v error -select_streams a -show_entries stream_tags=language:stream_disposition=default,forced,comment -of csv=p=0 "$RAID" | tr -d '\r' | tr '\n' ' ')"
    eq    "output: AC-3 track standard title"         "$(probe_a "$OA" 1 stream_tags=title)" "Indonesian | AC-3 | 5.1 | 384 kbps"
    eq    "output: copied tracks standard titles"     "$(probe_a "$OA" 0 stream_tags=title)/$(probe_a "$OA" 2 stream_tags=title)" "English | E-AC-3 | 5.1 | 384 kbps/English | AAC | 2.0$(mk_rate "$OA" 2) | Commentary"
    check "menu: planned title shown"                "grep -q 'Title: \"Indonesian DTS 5.1\" -> \"Indonesian | AC-3 | 5.1 | 384 kbps\"' '$T/raid_menu.log'"
    check "job: atitle=std, one title per audio track" "has '$JA' 'atitle=std' && (( \$(grep -oE -- '-metadata:s:a:[0-9]+ title=' '$JA' | sort -u | wc -l) == 3 ))"
    check "verify: titles as planned"                "grep -q 'Track titles: *AS PLANNED (3 audio title' '$T/raid_run.log'"
    eq    "output: subtitles kept"                    "$(ffprobe -v error -select_streams s -show_entries stream_tags=language:stream_disposition=default,forced -of csv=p=0 "$OA" | tr -d '\r' | tr '\n' ' ')" "1,0,eng 0,1,ind "
    eq    "output: video stream copied"               "$(ffmpeg -v error -i "$OA" -map 0:v -c copy -f streamhash -hash md5 - 2>/dev/null | awk -F, '{ print $3 }')" \
                                                      "$(ffmpeg -v error -i "$RAID" -map 0:v -c copy -f streamhash -hash md5 - 2>/dev/null | awk -F, '{ print $3 }')"
    if (( HAVE_MKV == 1 )); then
        check "statistics refreshed for the AC-3 track" "[[ -n \"\$(probe_a '$OA' 1 stream_tags=NUMBER_OF_BYTES)\" ]] && grep -q 'MKV statistics updated' '$T/raid_run.log'"
    else
        check "stale statistics of the DTS track removed" "[[ -z \"\$(probe_a '$OA' 1 stream_tags=BPS)\" ]]"
    fi
fi

# ------------------------------------------------------------
echo
echo "== 4 eight tracks: codecs / layouts mixed, video not the first stream"
HB=$(new_home mixed)
MIX="$HB/compress/out/Mixed.mkv"
ffmpeg -v error -y -f lavfi -i "$(tones 2.1 200 300 60)" -f lavfi -i "testsrc2=s=320x180:r=24:d=4" \
    -f lavfi -i "$(TONE_NOISE=1 tones 6.0 200 300 400 500 600 700)" -f lavfi -i "$(TONE_NOISE=1 tones "5.0(side)" 200 300 400 600 700)" \
    -f lavfi -i "$(TONE_RATE=44100 tones stereo 300 900)" \
    -f lavfi -i "$(TONE_NOISE=1 TONE_RATE=96000 tones 5.1 200 300 400 60 600 700)" \
    -f lavfi -i "$(TONE_NOISE=1 tones 7.1 200 300 400 60 500 600 700 800)" \
    -f lavfi -i "$(tones mono 440)" -f lavfi -i "$(tones stereo 500 700)" \
    -map 0:a -map 1:v -map 2:a -map 3:a -map 4:a -map 5:a -map 6:a -map 7:a -map 8:a \
    -c:v libx264 -preset ultrafast -crf 30 -c:a:0 ac3 -b:a:0 448k -c:a:1 flac -c:a:2 flac -c:a:3 pcm_s16le \
    -c:a:4 flac -c:a:5 flac -c:a:6 pcm_s16le -c:a:7 libopus -b:a:7 256k -vbr:a:7 off \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=fre -metadata:s:a:2 language=ger -metadata:s:a:3 language=spa \
    -metadata:s:a:4 language=ita -metadata:s:a:5 language=jpn -metadata:s:a:6 language=kor -metadata:s:a:7 language=por \
    -metadata:s:a:4 "title=Italian FLAC 5.1 96kHz" -metadata:s:a:7 "title=Opus Stereo" -disposition:a:0 default -disposition:a:6 comment \
    "$MIX" 2> "$T/mix_mk.err"
eq "fixture: AC-3 2.1 / FLAC 6.0 / FLAC 5.0(side) / PCM stereo 44.1k (MKV: no layout) / FLAC 5.1 96k / FLAC 7.1 / PCM mono / Opus stereo, video second" \
    "$(ffprobe -v error -show_entries stream=codec_type,codec_name,channel_layout,sample_rate -of csv=p=0 "$MIX" | tr -d '\r' | tr '\n' ' ')" \
    "ac3,audio,48000,2.1 h264,video flac,audio,48000,6.0 flac,audio,48000,5.0(side) pcm_s16le,audio,44100,unknown flac,audio,96000,5.1 flac,audio,48000,7.1 pcm_s16le,audio,48000,unknown opus,audio,48000,stereo "
# High above 100 kb/s; Compact for tracks >= 0.00012 GiB (~126 KB), at
# most ~258 kb/s here -> AC-3 256 kb/s (192 / 96 for stereo / mono)
CONF_B=$(conf_with mixed AUDIO_HIGH_TRIGGER_KBPS=100 AUDIO_COMPACT_TRIGGER_GIB=0.00012 AUDIO_COMPACT_LIMIT_GIB=0.00012)
# 1 Compact, 2 High, 3-7 Compact, 8 High
amenu "$HB" "$CONF_B" "1\n1\n3\ny\n2\n2\ny\n3\n3\ny\n4\n3\ny\n5\n3\ny\n6\n3\ny\n7\n3\ny\n8\n2\nn\n" "$T/mix_menu.log"
JB=$(job_of "$HB")
[[ -n "$JB" ]] && cp "$JB" "$T/mixed_job.sh" && JB="$T/mixed_job.sh"
check "menu: 6.0 E-AC-3 would drop a channel -> copy" "grep -q 'Reason: 6.0: E-AC-3 would turn it into 5.0(side) (6 -> 5 channels)' '$T/mix_menu.log'"
check "menu: 7.1 AC-3 impossible -> copy, reason"  "grep -q 'AC3 not possible without changing channels; copy unchanged' '$T/mix_menu.log' && grep -q 'Reason: 7.1: AC-3 stores at most 6 channels (5.1); the 8 channels are copied, never downmixed' '$T/mix_menu.log'"
check "plan summary lists the copy reasons"        "[[ \$(grep -c '^  Reason: ' '$T/mix_menu.log') -ge 2 ]] && grep -A3 '^Track 2: ' '$T/mix_menu.log' | grep -q 'Result: copied unchanged' && grep -A3 '^Track 6: ' '$T/mix_menu.log' | grep -q 'Result: copied unchanged'"
check "menu: 2.1 AC-3 -> AC-3 2.1 kept"            "grep -q 'Layout: 2.1 kept' '$T/mix_menu.log'"
check "menu: 5.1(back) 96 kHz -> 5.1(side) 48 kHz noted" "grep -q 'Layout: 5.1 -> 5.1(side): same channels (AC-3 surround naming); 96000 Hz -> 48000 Hz (AC-3 rate)' '$T/mix_menu.log'"
check "menu: layout-less PCM stereo / mono index-mapped" "grep -q 'unspecified 2-channel layout stored as stereo (channel order kept)' '$T/mix_menu.log' && grep -q 'unspecified 1-channel layout stored as mono (channel order kept)' '$T/mix_menu.log'"
check "menu: 44.1 kHz kept (AC-3 has it)"          "! grep -q '44100 Hz -> ' '$T/mix_menu.log'"
check "menu: Opus source High -> AC3 320 kb/s"     "grep -A4 '^Track 8: ' '$T/mix_menu.log' | grep -q 'After:  AC3 | 320 kb/s'"
check "menu: no Opus encoder offered"              "! grep -qE 'Opus \\| |-> Opus|Opus not possible' '$T/mix_menu.log'"
cmd=$(grep -A6 'item_run mux' "$JB")
check "job: copy / AC-3 on the right output tracks" "grep -qE -- '-c:v:0 copy -c:a:0 ac3 -b:a:0 256k -c:a:1 copy -c:a:2 ac3 -b:a:2 256k -c:a:3 ac3 -b:a:3 192k -filter:a:3 channelmap=map=0-FL\\\\\\|1-FR:channel_layout=stereo -c:a:4 ac3 -b:a:4 256k -c:a:5 copy -c:a:6 ac3 -b:a:6 96k -filter:a:6 channelmap=map=0-FC:channel_layout=mono -c:a:7 ac3 -b:a:7 320k ' <<< \"\$cmd\""
check "job: exactly one codec option per audio track" "one_codec_each \"\$cmd\" 8 && (( \$(grep -oE -- '-b:a:[0-9]+ ' <<< \"\$cmd\" | wc -l) == 6 ))"
check "job: plan for the six transcoded tracks"    "has '$JB' 'atrans=0\,2\,3\,4\,6\,7 aplan=0:ac3:3:2.1:48000:256\,2:ac3:5:5.0\(side\):48000:256\,3:ac3:2:stereo:44100:192\,4:ac3:6:5.1\(side\):48000:256\,6:ac3:1:mono:48000:96\,7:ac3:2:stereo:48000:320 ahash=1 amap=0:0\,1:1\,2:2\,3:3\,4:4\,5:5\,6:6\,7:7'"
bash "$JB" < /dev/null > "$T/mix_run.log" 2>&1
OB="$HB/compress/out/Mixed AudioCompressed.mkv"
check "job succeeded"                              "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/mix_run.log'"
check "no 'Multiple -codec' warning"               "! grep -q 'Multiple -codec' '$T/mix_run.log'"
eq    "output tracks in source order"              "$(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,channel_layout,sample_rate,bit_rate:stream_tags=language -of csv=p=0 "$OB" | tr -d '\r' | tr '\n' ' ')" \
      "ac3,48000,3,2.1,256000,eng flac,48000,6,6.0,N/A,fre ac3,48000,5,5.0(side),256000,ger ac3,44100,2,stereo,192000,spa ac3,48000,6,5.1(side),256000,ita flac,48000,8,7.1,N/A,jpn ac3,48000,1,mono,96000,kor ac3,48000,2,stereo,320000,por "
eq    "copied 6.0 / 7.1 payload-identical"         "$(_audio_payload_md5 "$OB" | sed -n '2p;6p' | tr '\n' ' ')" "$(_audio_payload_md5 "$MIX" | sed -n '2p;6p' | tr '\n' ' ')"
eq    "2.1 -> AC-3 2.1: channel identity"          "$(dominant_tones "$OB" 0 200 300 60)" "200 300 60 "
eq    "5.0(side) -> AC-3 5.0(side): channel identity" "$(dominant_tones "$OB" 2 200 300 400 600 700)" "200 300 400 600 700 "
eq    "stereo 44.1k -> AC-3 stereo: channel identity" "$(dominant_tones "$OB" 3 300 900)" "300 900 "
eq    "5.1(back) -> AC-3 5.1(side): BL/BR on SL/SR" "$(dominant_tones "$OB" 4 200 300 400 60 600 700)" "200 300 400 60 600 700 "
eq    "mono -> AC-3 mono"                          "$(dominant_tones "$OB" 6 440 1000)" "440 "
eq    "Opus stereo -> AC-3 stereo: channel identity" "$(dominant_tones "$OB" 7 500 700)" "500 700 "
check "verify: 96 -> 48 kHz as planned, no warning" "grep -q 'Audio 5 sample rate: *96000 -> 48000 Hz AS PLANNED' '$T/mix_run.log' && ! grep -qiE 'UNEXPECTED|NOT AS PLANNED|layout changed|sample rate .* planned' '$T/mix_run.log'"
check "verify: every bit rate as planned"          "[[ \$(grep -cE 'Audio [0-9]+ bit rate: *[0-9]+ kb/s AS PLANNED' '$T/mix_run.log') == 6 ]]"
check "verify: 6.0 / 7.1 hash-matched"             "grep -q 'Audio track 2: *COPIED (FLAC 6.0, 48000 Hz, payload MD5 MATCH)' '$T/mix_run.log' && grep -q 'Audio track 6: *COPIED (FLAC 7.1, 48000 Hz, payload MD5 MATCH)' '$T/mix_run.log'"
check "verify: no failure"                         "! grep -q 'RESULT: FAILED' '$T/mix_run.log'"
eq    "output: every track its standard title"     "$(ffprobe -v error -select_streams a -show_entries stream_tags=title -of csv=p=0 "$OB" | tr -d '\r' | tr '\n' '/')" \
      "English | AC-3 | 2.1 | 256 kbps/French | FLAC | 6.0$(mk_rate "$OB" 1)/German | AC-3 | 5.0 | 256 kbps/Spanish | AC-3 | 2.0 | 192 kbps/Italian | AC-3 | 5.1 | 256 kbps/Japanese | FLAC | 7.1$(mk_rate "$OB" 5)/Korean | AC-3 | 1.0 | 96 kbps | Commentary/Portuguese | AC-3 | 2.0 | 320 kbps/"
eq    "output: titles / dispositions"              "$(probe_a "$OB" 4 stream_tags=title)|$(probe_a "$OB" 7 stream_tags=title)|$(ffprobe -v error -select_streams a -show_entries stream_disposition=default,comment -of csv=p=0 "$OB" | tr -d '\r' | tr '\n' ' ')" \
      "Italian | AC-3 | 5.1 | 256 kbps|Portuguese | AC-3 | 2.0 | 320 kbps|$(ffprobe -v error -select_streams a -show_entries stream_disposition=default,comment -of csv=p=0 "$MIX" | tr -d '\r' | tr '\n' ' ')"

# ------------------------------------------------------------
echo
echo "== 5 nothing to transcode"
HC=$(new_home wide)
ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x90:r=24:d=4" -f lavfi -i "$(TONE_NOISE=1 tones "7.1(wide)" 1 2 3 4 5 6 7 8)" \
    -map 0:v -map 1:a -map 1:a -c:v libx264 -preset ultrafast -c:a:0 flac -c:a:1 pcm_s16le "$HC/compress/out/Wide.mkv" 2>/dev/null
# FLAC 7.1(wide) and PCM 8ch (MKV stores no layout): more than AC-3 has
amenu "$HC" "$CONF_B" "1\n1\n3\ny\n2\n3\nn\n" "$T/wide_menu.log"
check "7.1(wide) Compact: AC-3 impossible, copy"   "grep -q 'Reason: 7.1(wide): AC-3 stores at most 6 channels' '$T/wide_menu.log'"
check "PCM 8ch without layout: copy"               "grep -q 'Reason: 8ch: AC-3 stores at most 6 channels' '$T/wide_menu.log'"
check "nothing started"                            "grep -q 'No selected track requires compression.' '$T/wide_menu.log' && [[ -z \"\$(job_of '$HC')\" ]]"

# ------------------------------------------------------------
echo
echo "== 6 verification of transcoded / copied tracks"
if [[ -s "${OA:-}" ]]; then
    vrun() {   # NAME PART [aplan]  ->  report in $T/v_NAME/report.txt
        ITEM_INPUT="$RAID"; ITEM_PART="$2"; ITEM_TMP="$T/v_$1"
        mkdir -p "$ITEM_TMP"
        unset ITEM_EXP; declare -gA ITEM_EXP=([vidx]=0 [video]=copy [atrans]=1 [aplan]="${3:-1:ac3:6:5.1(side):48000:384}" [ahash]=1 [amap]="0:0,1:1,2:2")
        item_verify_output > /dev/null 2>&1
    }
    rep() { cat "$T/v_$1/report.txt"; }
    vrun good "$OA"
    check "the real output passes"                   "rep good | grep -q 'Audio 2 bit rate: *384 kb/s AS PLANNED' && ! rep good | grep -q 'RESULT: FAILED'"
    vrun old "$OA" "1:ac3:6:5.1(side):48000"
    check "a job without a planned bit rate passes"  "! rep old | grep -q 'bit rate' && ! rep old | grep -q 'RESULT: FAILED'"
    ffmpeg -v error -y -i "$OA" -map 0 -c copy -c:a:1 ac3 -ac:a:1 2 -b:a:1 192k "$T/f/stereo.mkv" 2>/dev/null
    vrun chan "$T/f/stereo.mkv"
    check "channel count change FAILS"               "rep chan | grep -q 'Audio 2 channels: *CHANGED: 6 -> 2' && rep chan | grep -q 'RESULT: FAILED'"
    ffmpeg -v error -y -i "$OA" -map 0 -c copy -c:a:1 aac -b:a:1 384k "$T/f/aac.mkv" 2>/dev/null
    vrun codec "$T/f/aac.mkv"
    check "codec mismatch FAILS"                     "rep codec | grep -q 'Audio 2 codec: *NOT AS PLANNED: aac (planned ac3)' && rep codec | grep -q 'RESULT: FAILED'"
    vrun layout "$OA" "1:ac3:6:5.1:48000:384"
    check "planned layout mismatch FAILS"            "rep layout | grep -q 'Audio 2 layout: *NOT AS PLANNED: 5.1(side) (planned 5.1' && rep layout | grep -q 'RESULT: FAILED'"
    ffmpeg -v error -y -i "$OA" -map 0 -c copy -c:a:1 ac3 -b:a:1 448k "$T/f/rate.mkv" 2>/dev/null
    vrun rate "$T/f/rate.mkv"
    check "bit rate mismatch FAILS"                  "rep rate | grep -q 'Audio 2 bit rate: *NOT AS PLANNED: 448000 b/s (planned 384 kb/s)' && rep rate | grep -q 'RESULT: FAILED'"
    ffmpeg -v error -y -i "$OA" -map 0 -c copy -c:a:0 eac3 -b:a:0 384k "$T/f/reenc.mkv" 2>/dev/null
    vrun hash "$T/f/reenc.mkv"
    check "copied payload mismatch FAILS"            "rep hash | grep -q 'Audio track 1: .*payload MD5 MISMATCH' && rep hash | grep -q 'RESULT: FAILED - audio 1 payload differs'"
    vrun sr "$OA" "1:ac3:6:5.1(side):44100:384"
    check "unexpected sample rate warns"             "rep sr | grep -q 'Audio 2 sample rate: *UNEXPECTED: 48000 Hz (planned 44100 Hz)'"
else
    bad "verification tests need the section 3 output"
fi

# ------------------------------------------------------------
echo
echo "== 7 job-level failures never finalize a broken file"
if [[ -n "${JA:-}" && -s "${OA:-}" ]]; then
    mv "$OA" "$T/f/raid_ok.mkv"

    # the AC-3 encoder failing mid-job (too low a rate for 5.1)
    sed 's/-b:a:1 384k/-b:a:1 32k/' "$JA" > "$T/raid_fail.sh"
    bash "$T/raid_fail.sh" < /dev/null > "$T/fail_run.log" 2>&1
    check "encoder failure: item FAILED (pass mux)"  "grep -q 'Reason: pass mux failed (ffmpeg exit' '$T/fail_run.log' && grep -q 'Bit allocation failed' '$T/fail_run.log'"
    check "encoder failure: no output, no .part"     "[[ ! -e '$OA' && ! -e '$OA.part' && -z \"\$(ls '$HA/compress/out' | grep -i audiocompressed)\" ]]"
    check "encoder failure: recorded in failed.tsv"  "grep -rq 'The Raid 2 (2014) HEVC Base.mkv' '$HA/compress/work/logs'/*/failed.tsv"

    # a downmix sneaking into the command fails the verification
    sed 's/-b:a:1 \([0-9]*k\)/-b:a:1 \1 -ac:a:1 2/' "$JA" > "$T/raid_downmix.sh"
    bash "$T/raid_downmix.sh" < /dev/null > "$T/downmix_run.log" 2>&1
    check "downmix: verification FAILS the item"     "grep -q 'audio 2 channel count changed (6 -> 2)' '$T/downmix_run.log' && grep -q 'All encodes finished: 0 ok, 1 failed' '$T/downmix_run.log'"
    check "downmix: never finalized, kept for inspection" "[[ ! -e '$OA' && -s '$OA.verify-failed' ]]"
    rm -f -- "$OA.verify-failed"

    # a rate other than the planned one fails the verification
    sed 's/-b:a:1 384k/-b:a:1 448k/' "$JA" > "$T/raid_rate.sh"
    bash "$T/raid_rate.sh" < /dev/null > "$T/rate_run.log" 2>&1
    check "wrong bit rate: verification FAILS the item" "grep -q 'audio 2 bit rate is 448000 b/s, planned 384 kb/s' '$T/rate_run.log' && grep -q 'All encodes finished: 0 ok, 1 failed' '$T/rate_run.log'"
    check "wrong bit rate: never finalized"          "[[ ! -e '$OA' && -s '$OA.verify-failed' ]]"
else
    bad "job-level tests need the section 3 job and output"
fi

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
