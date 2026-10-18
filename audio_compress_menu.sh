#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$HOME/compress/out"
WORK_DIR="$HOME/compress/work"

mkdir -p "$OUT_DIR" "$WORK_DIR"

source "$WORK_DIR/lib/media_probe.sh"
source "$WORK_DIR/lib/media_stats.sh"
source "$WORK_DIR/lib/bitrate.sh"
source "$WORK_DIR/lib/encode_common.sh"
source "$WORK_DIR/lib/hdr_dovi.sh"
source "$WORK_DIR/lib/policy.sh"
source "$WORK_DIR/lib/audio_plan.sh"

# Policy values: ~/compress/work/lib/compress.conf (AUDIO_* settings)
if ! load_policy; then
    exit 1
fi

# runtime files of earlier jobs confirmed finished (encode_common.sh)
cleanup_finished_jobs "$WORK_DIR"

echo "Policy: $(policy_conf_path)"
printf "  High above %s kb/s; Compact for tracks >= %s GiB, result < %s GiB\n" \
    "$AUDIO_HIGH_TRIGGER_KBPS" "$AUDIO_COMPACT_TRIGGER_GIB" "$AUDIO_COMPACT_LIMIT_GIB"

# ============================================================
# HELPERS
# ============================================================

size_from_kbps() {
    awk -v k="$1" -v d="$2" 'BEGIN {
        printf "%.2f", (k * 1000 * d / 8) / 1073741824
    }'
}

compact_ceiling_kbps() {
    awk -v d="$1" -v g="$AUDIO_COMPACT_LIMIT_GIB" 'BEGIN {
        printf "%.0f", (g * 1073741824 * 8) / d / 1000
    }'
}

high_target() {
    audio_menu_high_kbps "$1"
}

compact_target() {
    audio_menu_compact_kbps "$1"
}

codec_display() {
    local codec="$1"
    local profile="${2:-}"

    case "$codec" in
        truehd) echo "TrueHD" ;;
        eac3)   echo "E-AC3" ;;
        ac3)    echo "AC3" ;;
        aac)    echo "AAC" ;;
        opus)   echo "Opus" ;;
        flac)   echo "FLAC" ;;
        alac)   echo "ALAC" ;;
        mp3)    echo "MP3" ;;
        dts)
            if [[ "$profile" == *"MA"* ]]; then
                echo "DTS-HD MA"
            elif [[ "$profile" == *"DTS-HD"* ]]; then
                echo "DTS-HD"
            else
                echo "DTS"
            fi
            ;;
        pcm_*) echo "PCM" ;;
        *)     echo "$codec" ;;
    esac
}

quality_class() {
    local codec="$1"
    local profile="${2:-}"

    case "$codec" in
        truehd|flac|alac|pcm_*)
            echo "Lossless / source-quality"
            ;;
        dts)
            if [[ "$profile" == *"MA"* ]]; then
                echo "Lossless / source-quality"
            else
                echo "High-quality lossy"
            fi
            ;;
        eac3|ac3|aac|opus|mp3)
            echo "High-quality lossy"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# High keeps the codec family of the source where possible; AC-3 for
# Opus sources and for more than 6 channels (AC-3 stores at most 5.1, so
# such a track is copied: audio_encode_plan)
high_encoder() {
    local codec="$1"
    local channels="$2"

    if (( channels > 6 )); then
        echo "ac3"
        return
    fi

    case "$codec" in
        eac3)
            echo "eac3"
            ;;
        ac3|opus)
            echo "ac3"
            ;;
        aac)
            echo "aac"
            ;;
        mp3)
            echo "libmp3lame"
            ;;
        *)
            echo "eac3"
            ;;
    esac
}

display_encoder() {
    case "$1" in
        libmp3lame) echo "MP3" ;;
        eac3)       echo "E-AC3" ;;
        ac3)        echo "AC3" ;;
        aac)        echo "AAC" ;;
        *)          echo "$1" ;;
    esac
}

# ============================================================
# MOVIE SELECTION
# ============================================================

# regular files and valid symlinks (see discover_paths)
mapfile -t files < <(video_files_in_dir "$OUT_DIR")

if (( ${#files[@]} == 0 )); then
    echo "No movies found in:"
    echo "  $OUT_DIR"
    exit 1
fi

echo
echo "Select movie:"
echo

for i in "${!files[@]}"; do
    printf "%2d) %s\n" "$((i+1))" "$(basename "${files[$i]}")"
done

echo

while true; do
    read -rp "Choice: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] &&
       (( choice >= 1 && choice <= ${#files[@]} )); then
        break
    fi

    echo "Invalid selection."
done

IN="${files[$((choice-1))]}"
BASENAME="$(basename "$IN")"
NAME="${BASENAME%.*}"

DURATION=$(
    ffprobe -v error \
        -show_entries format=duration \
        -of default=nw=1:nk=1 "$IN"
)

# ============================================================
# AUDIO ANALYSIS
# ============================================================

AUDIO_COUNT=$(
    ffprobe -v error \
        -select_streams a \
        -show_entries stream=index \
        -of csv=p=0 "$IN" |
    wc -l
)

if (( AUDIO_COUNT == 0 )); then
    echo "No audio tracks found."
    exit 1
fi

declare -a \
    STREAM_INDEX \
    CODEC \
    PROFILE \
    CHANNELS \
    LAYOUT \
    LAYOUT_RAW \
    SAMPLE_RATE \
    LANGUAGE \
    TITLE \
    BITDEPTH \
    TRACK_BYTES \
    TRACK_GIB \
    TRACK_KBPS \
    DISPLAY_NAME \
    QUALITY

echo
echo "Analyzing audio tracks..."
echo

# Track sizes: stored MKV statistics when they pass the checks,
# otherwise one packet scan for all tracks, after which the MKV
# statistics are refreshed for the next run (media_stats.sh: stats_load).
STATS_PROGRESS=1 stats_load "$IN" "$DURATION" exact refresh
PACKET_BYTES=$(awk '$4 != "N/A" { print $1, $4 }' <<< "$STATS_LINES")
echo "Values from: $STATS_SOURCE"
[[ -n "$STATS_REJECTED" ]] && echo "  (stored statistics rejected: $STATS_REJECTED)"
[[ -n "$STATS_REFRESH" ]] && echo "  ($(stats_refresh_note))"
echo

for ((i=0; i<AUDIO_COUNT; i++)); do

    STREAM_INDEX[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=index \
            -of default=nw=1:nk=1 "$IN"
    )

    CODEC[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=codec_name \
            -of default=nw=1:nk=1 "$IN"
    )

    PROFILE[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=profile \
            -of default=nw=1:nk=1 "$IN" 2>/dev/null |
        head -1
    )

    CHANNELS[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=channels \
            -of default=nw=1:nk=1 "$IN"
    )

    LAYOUT[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=channel_layout \
            -of default=nw=1:nk=1 "$IN" 2>/dev/null |
        head -1
    )

    LANGUAGE[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream_tags=language \
            -of default=nw=1:nk=1 "$IN" 2>/dev/null |
        head -1
    )

    TITLE[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream_tags=title \
            -of default=nw=1:nk=1 "$IN" 2>/dev/null |
        head -1
    )

    SAMPLE_RATE[$i]=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=sample_rate \
            -of default=nw=1:nk=1 "$IN" 2>/dev/null |
        head -1
    )

    # the layout as ffprobe names it ("-" = none) for audio_encode_plan;
    # LAYOUT is the display text
    LAYOUT_RAW[$i]="${LAYOUT[$i]:--}"
    [[ "${LAYOUT_RAW[$i]}" == "unknown" ]] && LAYOUT_RAW[$i]="-"

    [[ -n "${LANGUAGE[$i]}" ]] || LANGUAGE[$i]="und"
    [[ -n "${LAYOUT[$i]}" ]] || LAYOUT[$i]="${CHANNELS[$i]}ch"

    raw_bits=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=bits_per_raw_sample \
            -of default=nw=1:nk=1 "$IN" 2>/dev/null |
        head -1
    )

    sample_bits=$(
        ffprobe -v error \
            -select_streams "a:$i" \
            -show_entries stream=bits_per_sample \
            -of default=nw=1:nk=1 "$IN" 2>/dev/null |
        head -1
    )

    if [[ "$raw_bits" =~ ^[1-9][0-9]*$ ]]; then
        BITDEPTH[$i]="${raw_bits}-bit"
    elif [[ "$sample_bits" =~ ^[1-9][0-9]*$ ]]; then
        BITDEPTH[$i]="${sample_bits}-bit"
    else
        BITDEPTH[$i]="-"
    fi

    TRACK_BYTES[$i]=$(
        awk -v s="${STREAM_INDEX[$i]}" '
            $1 == s { b = $2 }
            END { print b + 0 }' <<< "$PACKET_BYTES"
    )

    TRACK_GIB[$i]=$(
        bytes_to_gib "${TRACK_BYTES[$i]}"
    )

    TRACK_KBPS[$i]=$(
        awk \
            -v b="${TRACK_BYTES[$i]}" \
            -v d="$DURATION" \
            'BEGIN {printf "%.0f", b*8/d/1000}'
    )

    base_name="$(codec_display "${CODEC[$i]}" "${PROFILE[$i]}")"

    if [[ -n "${TITLE[$i]}" ]]; then
        DISPLAY_NAME[$i]="$base_name - ${TITLE[$i]}"
    else
        DISPLAY_NAME[$i]="$base_name ${LAYOUT[$i]}"
    fi

    QUALITY[$i]=$(
        quality_class "${CODEC[$i]}" "${PROFILE[$i]}"
    )
done

# ============================================================
# TRACK MENU
# ============================================================

declare -A SELECTED
declare -A ACTION
declare -A TARGET_CODEC
declare -A TARGET_KBPS
declare -A TARGET_TIER
# audio_encode_plan result of a transcoded track: -filter:a:N value
# ("-" = none), the encoded layout / channels / sample rate, and the
# layout note; COPY_REASON: why a compressing tier copies instead
declare -A TARGET_FILTER
declare -A TARGET_LAYOUT
declare -A TARGET_CH
declare -A TARGET_SR
declare -A TARGET_NOTE
declare -A COPY_REASON

show_tracks() {
    echo
    printf "%-4s %-5s %-32s %-28s %-9s %-10s %-12s\n" \
        "#" "Lang" "Name" "Quality" "Depth" "Size" "Bitrate"

    printf "%-4s %-5s %-32s %-28s %-9s %-10s %-12s\n" \
        "----" "-----" "--------------------------------" \
        "----------------------------" \
        "---------" "----------" "------------"

    for ((i=0; i<AUDIO_COUNT; i++)); do

        marker=""

        if [[ -n "${SELECTED[$i]+x}" ]]; then
            marker="*"
        fi

        printf "%-4s %-5s %-32.32s %-28.28s %-9s %-10s %-12s\n" \
            "$((i+1))$marker" \
            "${LANGUAGE[$i]}" \
            "${DISPLAY_NAME[$i]}" \
            "${QUALITY[$i]}" \
            "${BITDEPTH[$i]}" \
            "${TRACK_GIB[$i]} GiB" \
            "${TRACK_KBPS[$i]} kb/s"
    done

    echo
}

while true; do

    show_tracks

    while true; do
        read -rp "Select audio track: " track_choice

        if [[ "$track_choice" =~ ^[0-9]+$ ]] &&
           (( track_choice >= 1 && track_choice <= AUDIO_COUNT )); then
            break
        fi

        echo "Invalid selection."
    done

    idx=$((track_choice-1))

    echo
    echo "Selected:"
    echo "  ${LANGUAGE[$idx]} | ${DISPLAY_NAME[$idx]}"
    echo "  ${QUALITY[$idx]}"
    echo "  ${TRACK_GIB[$idx]} GiB | ${TRACK_KBPS[$idx]} kb/s"
    echo

    # ========================================================
    # HIGH
    # ========================================================

    H_KBPS=$(high_target "${CHANNELS[$idx]}")
    H_CODEC=$(high_encoder "${CODEC[$idx]}" "${CHANNELS[$idx]}")

    # AC-3 format limits (not policy values): the AC-3 bit rate at or
    # below the target (at most 640; FFmpeg would round any other rate
    # to the nearest one, possibly above the target)
    H_REQ_KBPS="$H_KBPS" H_RATE_ERR=""
    if [[ "$H_CODEC" == "ac3" ]]; then
        H_KBPS=$(ac3_kbps "$H_REQ_KBPS") ||
            H_KBPS="$H_REQ_KBPS" H_RATE_ERR="no AC-3 bit rate at or below $H_REQ_KBPS kb/s (AC-3 minimum: 32 kb/s)"
    fi

    H_SIZE=$(size_from_kbps "$H_KBPS" "$DURATION")
    H_CODEC_NAME=$(display_encoder "$H_CODEC")

    # ========================================================
    # COMPACT
    # ========================================================

    C_BASE=$(compact_target "${CHANNELS[$idx]}")
    C_MAX=$(compact_ceiling_kbps "$DURATION")

    C_KBPS=$(
        awk -v base="$C_BASE" -v max="$C_MAX" 'BEGIN {
            if (base < max)
                printf "%.0f", base
            else
                printf "%.0f", max
        }'
    )

    # the AC-3 bit rate at or below the target, so the result stays
    # within the limit
    C_CODEC="ac3"
    C_CODEC_NAME=$(display_encoder "$C_CODEC")
    C_REQ_KBPS="$C_KBPS" C_RATE_ERR=""
    C_KBPS=$(ac3_kbps "$C_REQ_KBPS") ||
        C_KBPS="$C_REQ_KBPS" C_RATE_ERR="the size limit needs $C_REQ_KBPS kb/s, below the AC-3 minimum of 32 kb/s"
    C_SIZE=$(size_from_kbps "$C_KBPS" "$DURATION")

    # ========================================================
    # SHOULD COMPRESS?
    # ========================================================

    HIGH_DOES_COMPRESS=0

    if (( ${TRACK_KBPS[$idx]} > AUDIO_HIGH_TRIGGER_KBPS )); then
        HIGH_DOES_COMPRESS=1
    fi

    # exact size (TRACK_GIB is rounded for display)
    COMPACT_DOES_COMPRESS=$(
        awk -v b="${TRACK_BYTES[$idx]}" -v t="$AUDIO_COMPACT_TRIGGER_GIB" 'BEGIN {
            print (b / 1073741824 >= t) ? 1 : 0
        }'
    )

    # ========================================================
    # LAYOUT PLAN (audio_plan.sh): a tier only transcodes when its
    # encoder keeps every channel; otherwise it copies (reason shown)
    # ========================================================

    H_STATUS="copy" H_FILTER="-" H_OLAYOUT="-" H_OCH="-" H_OSR="-" H_NOTE=""
    C_STATUS="copy" C_FILTER="-" C_OLAYOUT="-" C_OCH="-" C_OSR="-" C_NOTE=""

    if (( HIGH_DOES_COMPRESS == 1 )) && [[ -n "$H_RATE_ERR" ]]; then
        H_NOTE="$H_RATE_ERR"
    elif (( HIGH_DOES_COMPRESS == 1 )); then
        if ! IFS=$'\t' read -r H_STATUS H_FILTER H_OLAYOUT H_OCH H_OSR H_NOTE < <(
                audio_encode_plan "$H_CODEC" "$H_KBPS" "${LAYOUT_RAW[$idx]}" \
                    "${CHANNELS[$idx]}" "${SAMPLE_RATE[$idx]}"); then
            H_STATUS="copy" H_NOTE="the layout check could not run"
        fi
    fi

    if (( COMPACT_DOES_COMPRESS == 1 )) && [[ -n "$C_RATE_ERR" ]]; then
        C_NOTE="$C_RATE_ERR"
    elif (( COMPACT_DOES_COMPRESS == 1 )); then
        if ! IFS=$'\t' read -r C_STATUS C_FILTER C_OLAYOUT C_OCH C_OSR C_NOTE < <(
                audio_encode_plan "$C_CODEC" "$C_KBPS" "${LAYOUT_RAW[$idx]}" \
                    "${CHANNELS[$idx]}" "${SAMPLE_RATE[$idx]}"); then
            C_STATUS="copy" C_NOTE="the layout check could not run"
        fi
    fi

    # ========================================================
    # MENU
    # ========================================================

    echo "Compression:"
    echo

    echo "1) Quality"
    echo "   Copy unchanged"
    echo "   ${TRACK_KBPS[$idx]} kb/s -> ${TRACK_GIB[$idx]} GiB"
    echo

    echo "2) High"

    if (( HIGH_DOES_COMPRESS == 1 )) && [[ "$H_STATUS" == ok ]]; then
        echo "   $H_CODEC_NAME | ${H_KBPS} kb/s -> ~${H_SIZE} GiB"
        (( H_KBPS != H_REQ_KBPS )) && echo "   Rate: ${H_REQ_KBPS} kb/s target -> ${H_KBPS} kb/s ($H_CODEC_NAME bit rate at or below it)"
        echo "   Layout: $H_NOTE"
    elif (( HIGH_DOES_COMPRESS == 1 )); then
        echo "   $H_CODEC_NAME not possible ${H_RATE_ERR:+at this bit rate}${H_RATE_ERR:-without changing channels}; copy unchanged"
        echo "   Reason: $H_NOTE"
        echo "   ${TRACK_KBPS[$idx]} kb/s -> ${TRACK_GIB[$idx]} GiB"
    else
        echo "   Source is not oversized; copy unchanged"
        echo "   ${TRACK_KBPS[$idx]} kb/s -> ${TRACK_GIB[$idx]} GiB"
    fi

    echo
    echo "3) Compact"

    if (( COMPACT_DOES_COMPRESS == 1 )) && [[ "$C_STATUS" == ok ]]; then
        echo "   $C_CODEC_NAME | ${C_KBPS} kb/s -> ~${C_SIZE} GiB"
        echo "   Target: < ${AUDIO_COMPACT_LIMIT_GIB} GiB"
        (( C_KBPS != C_REQ_KBPS )) && echo "   Rate: ${C_REQ_KBPS} kb/s target -> ${C_KBPS} kb/s ($C_CODEC_NAME bit rate at or below it)"
        echo "   Layout: $C_NOTE"
    elif (( COMPACT_DOES_COMPRESS == 1 )); then
        echo "   $C_CODEC_NAME not possible ${C_RATE_ERR:+within the size limit}${C_RATE_ERR:-without changing channels}; copy unchanged"
        echo "   Reason: $C_NOTE"
        echo "   ${TRACK_KBPS[$idx]} kb/s -> ${TRACK_GIB[$idx]} GiB"
    else
        echo "   Below ${AUDIO_COMPACT_TRIGGER_GIB} GiB; copy unchanged"
        echo "   ${TRACK_KBPS[$idx]} kb/s -> ${TRACK_GIB[$idx]} GiB"
    fi

    echo

    while true; do
        read -rp "Select [1-3]: " preset

        case "$preset" in

            1)
                SELECTED[$idx]=1
                ACTION[$idx]="copy"
                TARGET_TIER[$idx]="Quality"
                TARGET_CODEC[$idx]="copy"
                TARGET_KBPS[$idx]="${TRACK_KBPS[$idx]}"
                COPY_REASON[$idx]=""
                break
                ;;

            2)
                SELECTED[$idx]=1
                TARGET_TIER[$idx]="High"
                COPY_REASON[$idx]=""

                if (( HIGH_DOES_COMPRESS == 1 )) && [[ "$H_STATUS" == ok ]]; then
                    ACTION[$idx]="encode"
                    TARGET_CODEC[$idx]="$H_CODEC"
                    TARGET_KBPS[$idx]="$H_KBPS"
                    TARGET_FILTER[$idx]="$H_FILTER"
                    TARGET_LAYOUT[$idx]="$H_OLAYOUT"
                    TARGET_CH[$idx]="$H_OCH"
                    TARGET_SR[$idx]="$H_OSR"
                    TARGET_NOTE[$idx]="$H_NOTE"
                else
                    ACTION[$idx]="copy"
                    TARGET_CODEC[$idx]="copy"
                    TARGET_KBPS[$idx]="${TRACK_KBPS[$idx]}"
                    (( HIGH_DOES_COMPRESS == 1 )) &&
                        COPY_REASON[$idx]="$H_CODEC_NAME not possible: $H_NOTE"
                fi

                break
                ;;

            3)
                SELECTED[$idx]=1
                TARGET_TIER[$idx]="Compact"
                COPY_REASON[$idx]=""

                if (( COMPACT_DOES_COMPRESS == 1 )) && [[ "$C_STATUS" == ok ]]; then
                    ACTION[$idx]="encode"
                    TARGET_CODEC[$idx]="$C_CODEC"
                    TARGET_KBPS[$idx]="$C_KBPS"
                    TARGET_FILTER[$idx]="$C_FILTER"
                    TARGET_LAYOUT[$idx]="$C_OLAYOUT"
                    TARGET_CH[$idx]="$C_OCH"
                    TARGET_SR[$idx]="$C_OSR"
                    TARGET_NOTE[$idx]="$C_NOTE"
                else
                    ACTION[$idx]="copy"
                    TARGET_CODEC[$idx]="copy"
                    TARGET_KBPS[$idx]="${TRACK_KBPS[$idx]}"
                    (( COMPACT_DOES_COMPRESS == 1 )) &&
                        COPY_REASON[$idx]="$C_CODEC_NAME not possible: $C_NOTE"
                fi

                break
                ;;

            *)
                echo "Invalid selection."
                ;;
        esac
    done

    echo
    echo "Planned:"

    if [[ "${ACTION[$idx]}" == "copy" ]]; then
        echo "  ${DISPLAY_NAME[$idx]}"
        echo "  -> copied unchanged"
        [[ -n "${COPY_REASON[$idx]:-}" ]] && echo "  Reason: ${COPY_REASON[$idx]}"
    else
        target_name=$(display_encoder "${TARGET_CODEC[$idx]}")

        echo "  ${DISPLAY_NAME[$idx]}"
        echo "  ${TRACK_KBPS[$idx]} kb/s / ${TRACK_GIB[$idx]} GiB"
        echo "  -> $target_name ${TARGET_KBPS[$idx]} kb/s / ~$(size_from_kbps "${TARGET_KBPS[$idx]}" "$DURATION") GiB"
        echo "  Layout: ${TARGET_NOTE[$idx]}"

        # ffmpeg reports object audio in the profile ("Dolby TrueHD +
        # Dolby Atmos", "Dolby Digital Plus + Dolby Atmos", "DTS-HD MA +
        # DTS:X"); the track title is a fallback for older ffmpeg.
        case "${CODEC[$idx]}" in
            truehd|eac3)
                if [[ "${PROFILE[$idx]}" == *"Atmos"* ]] ||
                   [[ "${DISPLAY_NAME[$idx],,}" == *"atmos"* ]]; then
                    echo "  WARNING: Dolby Atmos object metadata will be LOST (re-encoded as channel-based audio)."
                fi
                ;;
            dts)
                if [[ "${PROFILE[$idx]}" == *"DTS:X"* ]] ||
                   [[ "${DISPLAY_NAME[$idx],,}" == *"dts:x"* ]]; then
                    echo "  WARNING: DTS:X object metadata will be LOST (re-encoded as channel-based audio)."
                fi
                ;;
        esac

        if [[ -n "${TITLE[$idx]}" ]]; then
            new_title=$(audio_title_rewrite "${TITLE[$idx]}" \
                "$(encoder_codec "${TARGET_CODEC[$idx]}")" "${CHANNELS[$idx]}")
            if [[ "$new_title" != "${TITLE[$idx]}" ]]; then
                echo "  Title: \"${TITLE[$idx]}\" -> \"$new_title\" (codec/object-audio claims no longer true)"
            fi
        fi
    fi

    echo

    read -rp "Compress additional audio channel? [y/N]: " additional

    [[ "$additional" =~ ^[Yy]$ ]] || break
done

# ============================================================
# CHECK WHETHER ANYTHING NEEDS ENCODING
# ============================================================

ENCODE_COUNT=0

for idx in "${!SELECTED[@]}"; do
    if [[ "${ACTION[$idx]}" == "encode" ]]; then
        ((ENCODE_COUNT+=1))
    fi
done

echo
echo "============================================================"
echo "Audio compression plan"
echo "============================================================"
echo
echo "Source:"
echo "  $BASENAME"
echo

for ((i=0; i<AUDIO_COUNT; i++)); do

    if [[ -z "${SELECTED[$i]+x}" ]]; then
        continue
    fi

    printf "Track %d: %s\n" "$((i+1))" "${DISPLAY_NAME[$i]}"
    printf "  Tier:   %s\n" "${TARGET_TIER[$i]}"

    if [[ "${ACTION[$i]}" == "copy" ]]; then
        echo "  Result: copied unchanged"
        [[ -n "${COPY_REASON[$i]:-}" ]] && echo "  Reason: ${COPY_REASON[$i]}"
    else
        target_name=$(display_encoder "${TARGET_CODEC[$i]}")

        printf "  Before: %s kb/s | %s GiB\n" \
            "${TRACK_KBPS[$i]}" "${TRACK_GIB[$i]}"

        printf "  After:  %s | %s kb/s | ~%s GiB\n" \
            "$target_name" \
            "${TARGET_KBPS[$i]}" \
            "$(size_from_kbps "${TARGET_KBPS[$i]}" "$DURATION")"
        printf "  Layout: %s\n" "${TARGET_NOTE[$i]}"
    fi

    echo
done

if (( ENCODE_COUNT == 0 )); then
    echo "No selected track requires compression."
    echo "Nothing started."
    exit 0
fi

# ============================================================
# OUTPUT NAME
# ============================================================

OUT="$OUT_DIR/${NAME} AudioCompressed.mkv"

counter=2

# a symlink (valid or broken) at a name counts as taken
while path_taken "$OUT" || path_taken "$OUT.part"; do
    OUT="$OUT_DIR/${NAME} AudioCompressed ${counter}.mkv"
    ((counter++))
done

# ============================================================
# TMUX SESSION
# ============================================================

SESSION=$(next_tmux_session a)
JOB_FILE="$WORK_DIR/$SESSION.sh"

# Tier label for progress-check: the tiers of the re-encoded tracks.
JOB_TIER=$(
    for ((i=0; i<AUDIO_COUNT; i++)); do
        if [[ "${ACTION[$i]:-}" == "encode" ]]; then
            echo "${TARGET_TIER[$i]}"
        fi
    done | sort -u | paste -sd/ -
)

# Streams: everything kept; cover art is re-added as an MKV attachment
# (see build_stream_map). The output audio index of source audio track
# i is MAP_AUDIO_OUT[i]: every per-track option uses that index.
VIDX=$(main_video_index "$IN")
build_stream_map "$IN" "$VIDX"
STREAM_MAP_ARGS="$MAP_ARGS"

if (( MAP_AUDIO_COUNT != AUDIO_COUNT )); then
    echo "Internal error: $AUDIO_COUNT audio track(s) found, $MAP_AUDIO_COUNT mapped."
    echo "Nothing started."
    exit 1
fi

# One codec option per output stream (no blanket -c copy): the main
# video, every audio track (copy or its encoder), MAP_CODEC_ARGS for the
# rest. A transcoded track gets its bitrate and, when its layout needs
# the surround relabel, its channelmap (-filter:a:N) on the same index.
# Stale statistics of the re-encoded tracks (refreshed after the mux)
# and their titles (codec / object-audio claims that are no longer true).
# AUDIO_SPEC: "-c:a:<source index> encoder" for audio_title_args;
# ATRANS / APLAN: source indexes (item_verify_output).
CODEC_ARGS=()
[[ -n "$VIDX" ]] && CODEC_ARGS+=(-c:v:0 copy)
STALE_ARGS=""
AUDIO_SPEC=""
ATRANS=""
APLAN=""
for ((i=0; i<AUDIO_COUNT; i++)); do
    o="${MAP_AUDIO_OUT[$i]}"
    if [[ "${ACTION[$i]:-}" == "encode" ]]; then
        CODEC_ARGS+=("-c:a:$o" "${TARGET_CODEC[$i]}" "-b:a:$o" "${TARGET_KBPS[$i]}k")
        [[ "${TARGET_FILTER[$i]}" != "-" ]] && CODEC_ARGS+=("-filter:a:$o" "${TARGET_FILTER[$i]}")
        STALE_ARGS+=$(stale_stats_args "a:$o")
        AUDIO_SPEC+="-c:a:$i ${TARGET_CODEC[$i]} "
        ATRANS+="${ATRANS:+,}$i"
        APLAN+="${APLAN:+,}$i:$(encoder_codec "${TARGET_CODEC[$i]}"):${TARGET_CH[$i]}:${TARGET_LAYOUT[$i]}:${TARGET_SR[$i]}:${TARGET_KBPS[$i]}"
    else
        CODEC_ARGS+=("-c:a:$o" copy)
    fi
done
TITLE_ARGS=$(audio_title_args "$IN" "$AUDIO_SPEC")

# ============================================================
# GENERATE JOB
# ============================================================

{
    emit_job_header "$SESSION" audio 1

    printf 'if item_begin 1 %q %q %q 0 "" &&\n' "$IN" "$OUT" "Audio ${JOB_TIER}"
    # atrans / aplan: what is transcoded and its planned result; ahash=1:
    # the copied tracks are payload-hashed; amap: source -> output index
    printf '   item_expect vidx=%q video=copy atrans=%q aplan=%q ahash=1 amap=%q &&\n' \
        "$VIDX" "$ATRANS" "$APLAN" "$MAP_AMAP"
    printf '   item_run mux ffmpeg -y -i %q \\\n' "$IN"
    printf '      %s\\\n' "$STREAM_MAP_ARGS"
    printf '      %s%s\\\n' "$(printf '%q ' "${CODEC_ARGS[@]}")" "$MAP_CODEC_ARGS"

    [[ -n "$MAP_META_ARGS" ]] && printf '      %s\\\n' "$MAP_META_ARGS"
    [[ -n "$TITLE_ARGS" ]] && printf '      %s\\\n' "$TITLE_ARGS"
    [[ -n "$STALE_ARGS" ]] && printf '      %s\\\n' "$STALE_ARGS"
    printf '      -map_metadata 0 -map_chapters 0 \\\n'
    printf '      -max_muxing_queue_size 4096 %s\\\n' "$(matroska_mux_args)"
    emit_part_and_covers "$IN"
    printf 'then\n'
    printf '    if item_succeeded; then\n'
    printf '        echo\n'
    printf '        echo "Audio tracks:"\n'
    printf '        ffprobe -v error -select_streams a \\\n'
    printf '            -show_entries stream=index,codec_name,profile,channels,channel_layout,bit_rate:stream_tags=language,title \\\n'
    printf '            -of compact=p=0:nk=0 "$ITEM_FINAL"\n'
    printf '    fi\n'
    printf 'else\n'
    printf '    item_failed\n'
    printf 'fi\n\n'

    emit_job_footer
} > "$JOB_FILE"

start_job "$SESSION" "$JOB_FILE"

echo
echo "Started tmux session: $SESSION"
echo
echo "Output:"
echo "  $(basename "$OUT")"
echo
echo "Attach:"
echo "  tmux attach -t $SESSION"
echo
