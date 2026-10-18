#!/usr/bin/env bash
# Audio transcode planning (audio_compress_menu.sh): can the chosen
# encoder carry every channel of a source track, and what will the
# encoded track look like (codec, channels, layout, sample rate)?
#
# Policy: a track is only transcoded when every source channel stays the
# same speaker. Nothing is downmixed, mixed, dropped or invented; when
# the encoder cannot do that, the track is copied unchanged (the plan
# says why).
#
# The only relabel allowed is the surround pair moving between side
# (SL/SR) and back (BL/BR) when the target layout has no other place for
# it. AC-3 has a single surround pair, which FFmpeg's AC-3 / E-AC-3 / DTS
# / TrueHD decoders name SL/SR ("5.1(side)"): a 5.1 (BL/BR) source comes
# back as 5.1(side), the same speakers. Encoders that need the relabel
# done before encoding (AAC: back surrounds only) get an explicit
# channelmap with named channels (a channel that is not there is an
# error, never a remix). aformat / -ac / -ch_layout are never used for
# it: swresample would remix to whatever layout it picks.
#
# AC-3 stores at most 5.1 (6 channels); anything larger (6.1, 7.1, ...)
# is copied, never downmixed. Its bit rates are fixed steps (32 ... 640
# kb/s) and FFmpeg silently rounds any other rate to the NEAREST step,
# which can be above a size limit: ac3_kbps picks the step at or below a
# target.
#
# Every plan is confirmed by a trial encode of a fraction of a second of
# silence with the real encoder, layout, sample rate and bitrate. The
# decoded result must have the source's channel count and a layout made
# of the source's channels (same names, or the surround relabel), and an
# AC-3 trial the requested bit rate. That catches encoder rejections
# (AC-3 "Bit allocation failed" at too low a rate), FFmpeg's automatic
# layout conversion (AC-3 / E-AC-3 turn 6.0 into 5.0(side) and 7.1 into
# 5.1(side)) and layouts a decoder cannot name (AAC PCE: "unknown").
#
# Needs encode_common.sh (encoder_codec) and ffmpeg / ffprobe.

declare -gA AP_LAYOUT=()          # FFmpeg layout name -> "FL+FR+..."
declare -gA AP_TRIAL_CACHE=()     # trial arguments -> _ap_trial result
declare -gA AP_PAIR=([SL]=BL [SR]=BR [BL]=SL [BR]=SR)

# AC-3 bit rates (kb/s), the only ones the format has
AP_AC3_KBPS="32 40 48 56 64 80 96 112 128 160 192 224 256 320 384 448 512 576 640"

# _ap_targets ENCODER  ->  layouts (besides the source's own) the encoder
# stores with a named layout, tried with a surround relabel (AC-3 takes
# side and back surrounds as they are: nothing to relabel first)
_ap_targets() {
    case "$1" in
        aac|libfdk_aac)  echo "mono stereo 3.0 4.0 quad 5.0 5.1 7.1" ;;
        *)               echo "" ;;
    esac
}

# _ap_max_channels ENCODER  ->  most channels the format stores ("" = no
# fixed limit; the trial encode decides)
_ap_max_channels() {
    case "$1" in
        ac3)  echo 6 ;;
        *)    echo "" ;;
    esac
}

# audio_encoder_label ENCODER  ->  "AC-3", "E-AC-3", ...
audio_encoder_label() {
    case "$1" in
        eac3)               echo "E-AC-3" ;;
        ac3)                echo "AC-3" ;;
        aac|libfdk_aac)     echo "AAC" ;;
        libmp3lame)         echo "MP3" ;;
        *)                  echo "$1" ;;
    esac
}

# ac3_kbps KBPS  ->  the largest AC-3 bit rate at or below KBPS; "" (and
# non-zero) when KBPS is below the AC-3 minimum or not a number
ac3_kbps() {
    local r best=""

    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    for r in $AP_AC3_KBPS; do
        (( r <= $1 )) && best="$r"
    done
    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

# the standard layout table of the installed FFmpeg (the names ffprobe
# prints), loaded once
_ap_layouts_load() {
    local name dec

    (( ${#AP_LAYOUT[@]} )) && return 0

    while read -r name dec; do
        [[ "$dec" =~ ^[A-Z0-9]+(\+[A-Z0-9]+)*$ ]] && AP_LAYOUT[$name]="$dec"
    done < <(ffmpeg -hide_banner -layouts 2>/dev/null |
        sed -n '/^Standard channel layouts:/,$p' | tail -n +3)
    return 0
}

# ap_layout_channels LAYOUT CHANNELS  ->  "FL+FR+..." in stream order, or
# "" when the speaker order is unknown ("-", "unknown", "6 channels") or
# does not have CHANNELS channels
ap_layout_channels() {
    local l="$1" n="${2:-}" d="" c=()

    _ap_layouts_load

    if [[ -n "${AP_LAYOUT[$l]:-}" ]]; then
        d="${AP_LAYOUT[$l]}"
    elif [[ "$l" =~ ^[0-9]+\ channels\ \(([A-Z0-9+]+)\)$ ]]; then
        d="${BASH_REMATCH[1]}"
    elif [[ "$l" =~ ^[A-Z0-9]+(\+[A-Z0-9]+)+$ ]]; then
        d="$l"
    fi

    if [[ -n "$d" && "$n" =~ ^[0-9]+$ ]]; then
        IFS=+ read -ra c <<< "$d"
        (( ${#c[@]} == n )) || d=""
    fi

    printf '%s' "$d"
}

# ap_relabel SRC DST  ->  channelmap map ("FL-FL|...|SL-BL|SR-BR") when
# DST ("FL+FR+...") holds exactly the channels of SRC, the surround pair
# allowed to move between side and back; non-zero otherwise
ap_relabel() {
    local -a s d m=() rest=()
    local -A left=()
    local x p

    IFS=+ read -ra s <<< "$1"
    IFS=+ read -ra d <<< "$2"
    (( ${#s[@]} > 0 && ${#s[@]} == ${#d[@]} )) || return 1

    for x in "${d[@]}"; do
        [[ -z "${left[$x]:-}" ]] || return 1
        left[$x]=1
    done

    for x in "${s[@]}"; do
        if [[ -n "${left[$x]:-}" ]]; then
            m+=("$x-$x")
            unset 'left[$x]'
        else
            rest+=("$x")
        fi
    done

    for x in "${rest[@]+"${rest[@]}"}"; do
        p="${AP_PAIR[$x]:-}"
        [[ -n "$p" && -n "${left[$p]:-}" ]] || return 1
        m+=("$x-$p")
        unset 'left[$p]'
    done

    (IFS='|'; printf '%s' "${m[*]}")
}

# _ap_trial ENCODER KBPS INPUT_LAYOUT SAMPLE_RATE FILTER
#   ->  "channels<TAB>layout<TAB>sample_rate<TAB>bit_rate" of a decoded
#       trial encode of silence (layout / bit_rate "-" = none / unknown),
#       or "ERR<TAB>message"; FILTER "-" = none
_ap_trial() {
    local key="$1|$2|$3|$4|$5" tmp err res ch="" lay="" sr="" br="" k v
    local -a a

    if [[ -n "${AP_TRIAL_CACHE[$key]+x}" ]]; then
        printf '%s\n' "${AP_TRIAL_CACHE[$key]}"
        return 0
    fi

    tmp=$(mktemp "${TMPDIR:-/tmp}/audio_plan.XXXXXX") || return 1
    a=(-v error -nostdin -y -f lavfi -i "anullsrc=cl=$3:r=$4" -t 0.25 -map 0:a)
    [[ "$5" != "-" ]] && a+=(-filter:a:0 "$5")
    a+=(-c:a:0 "$1")
    [[ "$2" =~ ^[0-9]+$ ]] && a+=(-b:a:0 "${2}k")

    if err=$(ffmpeg "${a[@]}" -f matroska "$tmp" 2>&1 > /dev/null) && [[ -s "$tmp" ]]; then
        while IFS='=' read -r k v; do
            v="${v%$'\r'}"
            case "$k" in
                channels)       ch="$v" ;;
                channel_layout) lay="$v" ;;
                sample_rate)    sr="$v" ;;
                bit_rate)       br="$v" ;;
            esac
        done < <(ffprobe -v error -select_streams a:0 \
            -show_entries stream=channels,channel_layout,sample_rate,bit_rate -of default=nw=1 "$tmp" 2>/dev/null)
        [[ -z "$lay" || "$lay" == unknown ]] && lay="-"
        [[ "$br" =~ ^[0-9]+$ ]] || br="-"
        res="${ch:-0}"$'\t'"$lay"$'\t'"${sr:--}"$'\t'"$br"
    else
        err=$(printf '%s\n' "$err" | grep -m1 . | sed 's/^\[[^]]*\] *//')
        res="ERR"$'\t'"${err:-encoder failed}"
    fi

    rm -f -- "$tmp"
    AP_TRIAL_CACHE[$key]="$res"
    printf '%s\n' "$res"
}

# audio_encode_plan ENCODER KBPS LAYOUT CHANNELS SAMPLE_RATE
#
# LAYOUT / CHANNELS / SAMPLE_RATE: the source track as ffprobe reports
# it (LAYOUT "-" or "" when ffprobe names none). One tab-separated line:
#   ok    FILTER  LAYOUT  CHANNELS  SAMPLE_RATE  NOTE
#         the encoded track (decoded layout as ffprobe will report it);
#         FILTER "-" = none, else the channelmap for -filter:a:N
#   copy  -       -       -         -            REASON
audio_encode_plan() {
    local enc="$1" kbps="$2" layout="${3:--}" ch="$4" sr="$5"
    local label src cl t dec map filter och ol osr obr odec max why="" first="" unspec=0
    local -a cands=()

    label=$(audio_encoder_label "$enc")
    [[ -n "$layout" ]] || layout="-"
    [[ "$sr" =~ ^[0-9]+$ ]] || sr=48000

    if ! [[ "$ch" =~ ^[1-9][0-9]*$ ]]; then
        printf 'copy\t-\t-\t-\t-\t%s\n' "channel count unknown"
        return 0
    fi

    max=$(_ap_max_channels "$enc")
    if [[ -n "$max" ]] && (( ch > max )); then
        printf 'copy\t-\t-\t-\t-\t%s %s\n' "${layout/#-/${ch}ch}:" \
            "$label stores at most $max channels (5.1); the $ch channels are copied, never downmixed"
        return 0
    fi

    src=$(ap_layout_channels "$layout" "$ch")

    if [[ -z "$src" ]]; then
        # no speaker order: mono / stereo are the only reading that does
        # not guess a speaker (index mapped, nothing reordered)
        case "$ch" in
            1) src=FC;    cl=mono;   cands=("channelmap=map=0-FC:channel_layout=mono") ;;
            2) src=FL+FR; cl=stereo; cands=("channelmap=map=0-FL|1-FR:channel_layout=stereo") ;;
            *)
                printf 'copy\t-\t-\t-\t-\t%s\n' \
                    "the $ch channels have no known speaker order (layout ${layout/#-/unknown}); a transcode could put them on the wrong speakers"
                return 0
                ;;
        esac
        unspec=1
    else
        cl="$src"
        cands=("-")
        for t in $(_ap_targets "$enc"); do
            dec=$(ap_layout_channels "$t" "$ch")
            [[ -n "$dec" && "$dec" != "$src" ]] || continue
            map=$(ap_relabel "$src" "$dec") || continue
            cands+=("channelmap=map=$map:channel_layout=$t")
        done
    fi

    for filter in "${cands[@]}"; do
        IFS=$'\t' read -r och ol osr obr < <(_ap_trial "$enc" "$kbps" "$cl" "$sr" "$filter")

        why=""
        if [[ "$och" == ERR ]]; then
            why="the $label encoder refuses it: $ol"
        elif [[ "$och" != "$ch" ]]; then
            why="$label would turn it into ${ol/#-/unknown} ($ch -> $och channels)"
        else
            odec=$(ap_layout_channels "$ol" "$och")
            if [[ -z "$odec" ]]; then
                why="$label stores it without a named speaker layout; channel identity cannot be confirmed"
            elif ! ap_relabel "$src" "$odec" > /dev/null; then
                why="$label would move channels ($src -> $odec)"
            elif [[ "$enc" == ac3 && "$obr" != "$(( ${kbps:-0} * 1000 ))" ]]; then
                # FFmpeg rounds a rate AC-3 does not have to the nearest one
                [[ "$obr" =~ ^[0-9]+$ ]] && obr="$(( obr / 1000 )) kb/s" || obr="an unknown bit rate"
                why="$label would encode at $obr instead of ${kbps:-?} kb/s (AC-3 bit rates: ${AP_AC3_KBPS// /, })"
            fi
        fi

        if [[ -z "$why" ]]; then
            local note
            if (( unspec == 1 )); then
                note="unspecified $ch-channel layout stored as $ol (channel order kept)"
            elif [[ "$filter" != "-" ]]; then
                note="$layout -> $ol: surround channels relabelled ($(_ap_moves "${filter#channelmap=map=}"); same channels, no remix)"
            elif [[ "$ol" != "$layout" ]]; then
                note="$layout -> $ol: same channels ($label surround naming)"
            else
                note="$layout kept"
            fi
            [[ "$osr" != "$sr" ]] && note+="; $sr Hz -> $osr Hz ($label rate)"
            printf 'ok\t%s\t%s\t%s\t%s\t%s\n' "$filter" "$ol" "$och" "$osr" "$note"
            return 0
        fi

        [[ -n "$first" ]] || first="$why"
    done

    printf 'copy\t-\t-\t-\t-\t%s %s\n' "${layout/#-/${ch}ch}:" "$first"
}

# _ap_moves MAP  ->  "SL->BL, SR->BR" (the channels a channelmap moves)
_ap_moves() {
    local m out=() IFS='|'

    for m in $1; do
        m="${m%%:*}"
        [[ "${m%-*}" != "${m#*-}" ]] && out+=("${m%-*}->${m#*-}")
    done

    IFS=','
    printf '%s' "${out[*]}" | sed 's/,/, /g'
}
