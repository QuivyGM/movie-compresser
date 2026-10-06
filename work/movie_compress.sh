#!/usr/bin/env bash
set -euo pipefail

IN_DIR="$HOME/compress/in"
OUT_DIR="$HOME/compress/out"
WORK_DIR="$HOME/compress/work"

mkdir -p "$IN_DIR" "$OUT_DIR" "$WORK_DIR"

source "$WORK_DIR/lib/media_probe.sh"
source "$WORK_DIR/lib/media_stats.sh"
source "$WORK_DIR/lib/bitrate.sh"
source "$WORK_DIR/lib/encode_common.sh"

declare -a INPUTS OUTPUTS BITRATES FILTERS TIERS AUDIO_ARGS OVERWRITES

# ============================================================
# POLICY
#
# QUALITY = QUALITY-FIRST
#   Video:
#     preferred: 20 Mb/s
#     floor:     12 Mb/s
#     max:       20 GiB video
#
#   Target = as high as possible up to:
#       min(20 Mb/s, bitrate required for 20 GiB video)
#
#   Audio:
#     copied unchanged
#
# HIGH = EFFICIENCY-FIRST
#   Video:
#     target:    ~7 GiB
#     floor:      6 Mb/s
#     upper cap: 12 Mb/s
#
#   Audio:
#     target <= 2 GiB
#
# BASE = SIZE/EFFICIENCY-FIRST
#   Video:
#     target:    ~2 GiB
#     floor:     2.5 Mb/s
#     upper cap: 5 Mb/s
#
#   Audio:
#     choose <=1 GiB or <=0.5 GiB
#
# High/Base size targets are soft targets:
# bitrate floors take priority for long movies.
# ============================================================

build_audio_args() {
    local budget="$1"
    local channels_string="$2"
    local tier="$3"

    read -ra CHANNELS <<< "$channels_string"

    if (( ${#CHANNELS[@]} == 0 )); then
        echo "-c:a copy"
        return
    fi

    local recommendations=()
    local total=0

    for ch in "${CHANNELS[@]}"; do
        [[ "$ch" =~ ^[0-9]+$ ]] || ch=2

        local kbps

        if [[ "$tier" == "High" ]]; then
            if (( ch >= 7 )); then
                kbps=768
            elif (( ch == 6 )); then
                kbps=640
            elif (( ch >= 3 )); then
                kbps=448
            elif (( ch == 2 )); then
                kbps=256
            else
                kbps=128
            fi
        else
            if (( ch >= 7 )); then
                kbps=512
            elif (( ch == 6 )); then
                kbps=448
            elif (( ch >= 3 )); then
                kbps=320
            elif (( ch == 2 )); then
                kbps=192
            else
                kbps=96
            fi
        fi

        recommendations+=("$kbps")
        total=$((total + kbps))
    done

    local args="-c:a aac"

    if (( total <= budget )); then
        for i in "${!recommendations[@]}"; do
            args+=" -b:a:${i} ${recommendations[$i]}k"
        done
    else
        for i in "${!recommendations[@]}"; do
            local kbps

            kbps=$(
                awk \
                    -v r="${recommendations[$i]}" \
                    -v t="$total" \
                    -v b="$budget" '
                    BEGIN {
                        x=int(r/t*b)
                        if (x < 64) x=64
                        printf "%d",x
                    }'
            )

            args+=" -b:a:${i} ${kbps}k"
        done
    fi

    echo "$args"
}

while true; do

    mapfile -t files < <(
        find "$IN_DIR" -maxdepth 1 -type f \
        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) |
        sort
    )

    if (( ${#files[@]} == 0 )); then
        echo "No movies found in $IN_DIR"
        exit 1
    fi

    echo
    echo "Select movie:"

    for i in "${!files[@]}"; do
        printf "%2d) %s\n" \
            "$((i+1))" \
            "$(basename "${files[$i]}")"
    done

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

    echo
    echo "Analyzing source..."

    # Main video stream (cover art / attached pictures are skipped).
    VIDX=$(main_video_index "$IN")

    if [[ -z "$VIDX" ]]; then
        echo "No video stream found in $BASENAME"
        exit 1
    fi

    IFS=x read -r WIDTH HEIGHT <<< "$(get_resolution "$IN" "$VIDX")"

    DURATION=$(get_duration "$IN")

    SOURCE_TOTAL_BYTES=$(stat -c %s "$IN")

    # One packet scan for both video and audio sizes.
    read -r SOURCE_VIDEO_BYTES SOURCE_AUDIO_BYTES \
        <<< "$(media_stream_totals "$IN")"

    SOURCE_VIDEO_MBPS=$(bytes_to_mbps "$SOURCE_VIDEO_BYTES" "$DURATION")
    SOURCE_VIDEO_GIB=$(bytes_to_gib "$SOURCE_VIDEO_BYTES")
    SOURCE_AUDIO_GIB=$(bytes_to_gib "$SOURCE_AUDIO_BYTES")
    SOURCE_TOTAL_GIB=$(bytes_to_gib "$SOURCE_TOTAL_BYTES")

    OTHER_BYTES=$(
        awk \
            -v total="$SOURCE_TOTAL_BYTES" \
            -v video="$SOURCE_VIDEO_BYTES" \
            -v audio="$SOURCE_AUDIO_BYTES" '
            BEGIN {
                x=total-video-audio
                if (x<0) x=0
                printf "%.0f",x
            }'
    )

    OTHER_GIB=$(bytes_to_gib "$OTHER_BYTES")

    AUDIO_CHANNELS=$(get_audio_channels "$IN" | tr '\n' ' ')
    AUDIO_TRACKS=$(wc -w <<< "$AUDIO_CHANNELS")

    DURATION_MIN=$(
        awk -v d="$DURATION" \
            'BEGIN {printf "%.1f",d/60}'
    )

    echo
    echo "Source:       $BASENAME"
    echo "Resolution:   ${WIDTH}x${HEIGHT}"
    echo "Runtime:      ${DURATION_MIN} min"
    echo "Video:        ${SOURCE_VIDEO_MBPS} Mb/s / ${SOURCE_VIDEO_GIB} GiB"
    echo "Audio:        ${SOURCE_AUDIO_GIB} GiB / ${AUDIO_TRACKS} track(s)"
    echo "File size:    ${SOURCE_TOTAL_GIB} GiB"

    probe_hdr "$IN" "$VIDX"

    if ! confirm_dynamic_range "$BASENAME"; then
        echo "Skipped: $BASENAME"
        read -rp "Add another movie? [y/N]: " again
        [[ "$again" =~ ^[Yy]$ ]] && continue
        break
    fi

    # ========================================================
    # RESOLUTION
    # ========================================================

    FILTER=""
    OUT_WIDTH="$WIDTH"
    OUT_HEIGHT="$HEIGHT"
    DOWNSCALED=0

    if (( WIDTH > 1920 || HEIGHT > 1080 )); then

        echo
        echo "Source is higher than 1080p."
        echo "1) Keep original resolution (${WIDTH}x${HEIGHT})"
        echo "2) Downscale to 1080p"

        while true; do
            read -rp "Select [1-2]: " r

            case "$r" in
                1)
                    break
                    ;;
                2)
                    DOWNSCALED=1

                    FILTER="scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"

                    read -r OUT_WIDTH OUT_HEIGHT < <(
                        awk -v w="$WIDTH" -v h="$HEIGHT" 'BEGIN {
                            sx=1920/w
                            sy=1080/h
                            s=(sx<sy?sx:sy)
                            ow=int((w*s)/2)*2
                            oh=int((h*s)/2)*2
                            print ow,oh
                        }'
                    )

                    break
                    ;;
                *)
                    echo "Invalid selection."
                    ;;
            esac
        done
    fi

    # ========================================================
    # TIER
    # ========================================================

    echo
    echo "Compression tier:"
    echo "1) Quality"
    echo "2) High"
    echo "3) Base"

    while true; do
        read -rp "Select [1-3]: " t

        case "$t" in
            1) TIER="Quality"; break ;;
            2) TIER="High";    break ;;
            3) TIER="Base";    break ;;
            *) echo "Invalid selection." ;;
        esac
    done

    # ========================================================
    # VIDEO TARGET
    # ========================================================

    case "$TIER" in

        Quality)

            VIDEO_MAX_GIB=20
            VIDEO_FLOOR=12.0
            VIDEO_PREFERRED=20.0

            SIZE_LIMIT_MBPS=$(
                bitrate_for_gib \
                    "$VIDEO_MAX_GIB" \
                    "$DURATION"
            )

            TARGET_MBPS=$(
                min_value \
                    "$VIDEO_PREFERRED" \
                    "$SIZE_LIMIT_MBPS"
            )

            BELOW_FLOOR=$(
                awk -v x="$TARGET_MBPS" -v f="$VIDEO_FLOOR" \
                    'BEGIN {print (x<f)?1:0}'
            )

            if (( BELOW_FLOOR == 1 )); then

                FLOOR_SIZE=$(
                    video_size_gib \
                        "$VIDEO_FLOOR" \
                        "$DURATION"
                )

                echo
                echo "------------------------------------------------------------"
                echo "Quality conflict:"
                echo

                printf "%-18s | %-18s | %-18s\n" \
                    "" \
                    "1. Quality floor" \
                    "2. 20 GiB max"

                printf "%-18s-+-%-18s-+-%-18s\n" \
                    "------------------" \
                    "------------------" \
                    "------------------"

                printf "%-18s | %-18s | %-18s\n" \
                    "Video bitrate" \
                    "${VIDEO_FLOOR} Mb/s" \
                    "${SIZE_LIMIT_MBPS} Mb/s"

                printf "%-18s | %-18s | %-18s\n" \
                    "Video size" \
                    "~${FLOOR_SIZE} GiB" \
                    "~20.000 GiB"

                echo "------------------------------------------------------------"

                while true; do
                    read -rp "Select [1-2]: " qc

                    case "$qc" in
                        1)
                            TARGET_MBPS="$VIDEO_FLOOR"
                            break
                            ;;
                        2)
                            TARGET_MBPS="$SIZE_LIMIT_MBPS"
                            break
                            ;;
                        *)
                            echo "Invalid selection."
                            ;;
                    esac
                done
            fi
            ;;

        High)

            VIDEO_TARGET_GIB=7
            VIDEO_FLOOR=6.0
            VIDEO_UPPER=12.0

            SIZE_TARGET_MBPS=$(
                bitrate_for_gib \
                    "$VIDEO_TARGET_GIB" \
                    "$DURATION"
            )

            TARGET_MBPS=$(
                min_value \
                    "$VIDEO_UPPER" \
                    "$SIZE_TARGET_MBPS"
            )

            TARGET_MBPS=$(
                max_value \
                    "$VIDEO_FLOOR" \
                    "$TARGET_MBPS"
            )
            ;;

        Base)

            VIDEO_TARGET_GIB=2
            VIDEO_FLOOR=2.5
            VIDEO_UPPER=5.0

            SIZE_TARGET_MBPS=$(
                bitrate_for_gib \
                    "$VIDEO_TARGET_GIB" \
                    "$DURATION"
            )

            TARGET_MBPS=$(
                min_value \
                    "$VIDEO_UPPER" \
                    "$SIZE_TARGET_MBPS"
            )

            TARGET_MBPS=$(
                max_value \
                    "$VIDEO_FLOOR" \
                    "$TARGET_MBPS"
            )
            ;;
    esac

    # Never intentionally encode above source bitrate.
    TARGET_MBPS=$(
        awk -v target="$TARGET_MBPS" \
            -v source="$SOURCE_VIDEO_MBPS" '
            BEGIN {
                if (source < target)
                    printf "%.3f",source
                else
                    printf "%.3f",target
            }'
    )

    TARGET_KBPS=$(
        awk -v x="$TARGET_MBPS" \
            'BEGIN {printf "%.0f",x*1000}'
    )

    EXPECTED_VIDEO_GIB=$(
        video_size_gib \
            "$TARGET_MBPS" \
            "$DURATION"
    )

    # ========================================================
    # AUDIO
    # ========================================================

    AUDIO_MODE="copy"
    AUDIO_CAP_GIB=0
    AUDIO_FFMPEG_ARGS="-c:a copy"
    EXPECTED_AUDIO_GIB="$SOURCE_AUDIO_GIB"

    case "$TIER" in

        Quality)
            ;;

        High)

            AUDIO_CAP_GIB=2

            TOO_BIG=$(
                awk -v s="$SOURCE_AUDIO_GIB" -v c="$AUDIO_CAP_GIB" \
                    'BEGIN {print (s>c)?1:0}'
            )

            if (( TOO_BIG == 1 )); then

                AUDIO_MODE="aac"

                AUDIO_BUDGET=$(
                    audio_kbps_for_gib \
                        "$AUDIO_CAP_GIB" \
                        "$DURATION"
                )

                AUDIO_FFMPEG_ARGS=$(
                    build_audio_args \
                        "$AUDIO_BUDGET" \
                        "$AUDIO_CHANNELS" \
                        "$TIER"
                )

                EXPECTED_AUDIO_GIB="$AUDIO_CAP_GIB"
            fi
            ;;

        Base)

            echo
            echo "Base audio target:"
            echo "1) 1.0 GiB"
            echo "2) 0.5 GiB"

            while true; do
                read -rp "Select [1-2]: " ac

                case "$ac" in
                    1)
                        AUDIO_CAP_GIB=1
                        break
                        ;;
                    2)
                        AUDIO_CAP_GIB=0.5
                        break
                        ;;
                    *)
                        echo "Invalid selection."
                        ;;
                esac
            done

            TOO_BIG=$(
                awk -v s="$SOURCE_AUDIO_GIB" -v c="$AUDIO_CAP_GIB" \
                    'BEGIN {print (s>c)?1:0}'
            )

            if (( TOO_BIG == 1 )); then

                AUDIO_MODE="aac"

                AUDIO_BUDGET=$(
                    audio_kbps_for_gib \
                        "$AUDIO_CAP_GIB" \
                        "$DURATION"
                )

                AUDIO_FFMPEG_ARGS=$(
                    build_audio_args \
                        "$AUDIO_BUDGET" \
                        "$AUDIO_CHANNELS" \
                        "$TIER"
                )

                EXPECTED_AUDIO_GIB="$AUDIO_CAP_GIB"
            fi
            ;;
    esac

    EXPECTED_TOTAL_GIB=$(
        awk \
            -v v="$EXPECTED_VIDEO_GIB" \
            -v a="$EXPECTED_AUDIO_GIB" \
            -v o="$OTHER_GIB" '
            BEGIN {
                printf "%.3f",v+a+o
            }'
    )

    # ========================================================
    # OUTPUT NAME
    # ========================================================

    if (( DOWNSCALED == 1 )); then
        OUT="$OUT_DIR/${NAME} 1080p HEVC ${TIER}.mkv"
    else
        OUT="$OUT_DIR/${NAME} HEVC ${TIER}.mkv"
    fi

    if ! resolve_output_conflict "$OUT"; then
        echo "Skipped: $BASENAME"
        read -rp "Add another movie? [y/N]: " again
        [[ "$again" =~ ^[Yy]$ ]] && continue
        break
    fi

    OUT="$RESOLVED_OUT"
    PLANNED_OUTPUTS+=("$OUT")

    build_stream_map "$IN" "$VIDX"

    INPUTS+=("$IN")
    OUTPUTS+=("$OUT")
    BITRATES+=("$TARGET_KBPS")
    FILTERS+=("$FILTER")
    TIERS+=("$TIER")
    AUDIO_ARGS+=("$AUDIO_FFMPEG_ARGS")
    OVERWRITES+=("$RESOLVED_OVERWRITE")

    # ========================================================
    # SUMMARY
    # ========================================================

    echo
    echo "------------------------------------------------------------"
    echo "Added:"
    printf "  File:              %s\n" "$BASENAME"
    printf "  Compression tier:  %s\n" "$TIER"
    echo

    printf "  Resolution:        %sx%s -> %sx%s\n" \
        "$WIDTH" "$HEIGHT" \
        "$OUT_WIDTH" "$OUT_HEIGHT"

    printf "  Video bitrate:     %s -> %.2f Mb/s\n" \
        "$SOURCE_VIDEO_MBPS" \
        "$TARGET_MBPS"

    printf "  Video size:        ~%s -> ~%s GiB\n" \
        "$SOURCE_VIDEO_GIB" \
        "$EXPECTED_VIDEO_GIB"

    case "$TIER" in
        Quality)
            echo "  Video policy:      quality-first [12 Mb/s floor / 20 Mb/s preferred / 20 GiB max]"
            ;;
        High)
            echo "  Video policy:      efficiency-first [~7 GiB target / 6 Mb/s floor]"
            ;;
        Base)
            echo "  Video policy:      size-first [~2 GiB target / 2.5 Mb/s floor]"
            ;;
    esac

    if [[ "$AUDIO_MODE" == "copy" ]]; then
        printf "  Audio size:        ~%s GiB -> copied unchanged\n" \
            "$SOURCE_AUDIO_GIB"
    else
        printf "  Audio size:        ~%s -> <=%s GiB\n" \
            "$SOURCE_AUDIO_GIB" \
            "$AUDIO_CAP_GIB"
        echo "  Audio codec:       AAC (all tracks retained)"
    fi

    printf "  Other streams:     ~%s GiB copied\n" \
        "$OTHER_GIB"

    printf "  File size:         %s -> ~%s GiB\n" \
        "$SOURCE_TOTAL_GIB" \
        "$EXPECTED_TOTAL_GIB"

    printf "  Dynamic range:     %s\n" "$(hdr_description)"

    for note in "${MAP_NOTES[@]+"${MAP_NOTES[@]}"}"; do
        printf "  Streams:           %s\n" "$note"
    done

    printf "  Output:            %s%s\n" \
        "$(basename "$OUT")" \
        "$( (( RESOLVED_OVERWRITE == 1 )) && echo "  [overwrites existing]")"

    echo "------------------------------------------------------------"

    read -rp "Add another movie? [y/N]: " again
    [[ "$again" =~ ^[Yy]$ ]] || break
done

if (( ${#INPUTS[@]} == 0 )); then
    echo
    echo "Nothing queued."
    exit 0
fi

# ============================================================
# TMUX
# ============================================================

SESSION=$(next_tmux_session c)
JOB_FILE="$WORK_DIR/$SESSION.sh"
PASS_DIR="$WORK_DIR/${SESSION}_passes"

mkdir -p "$PASS_DIR"

# ============================================================
# GENERATE JOB
# ============================================================

{
    emit_job_header "$SESSION" movie "${#INPUTS[@]}"

    for i in "${!INPUTS[@]}"; do
        emit_encode_item \
            "$((i + 1))" \
            "${INPUTS[$i]}" \
            "${OUTPUTS[$i]}" \
            "${TIERS[$i]}" \
            "${BITRATES[$i]}" \
            "${FILTERS[$i]}" \
            "${AUDIO_ARGS[$i]}" \
            "$PASS_DIR/pass_$i" \
            "${OVERWRITES[$i]}"
    done

    emit_job_footer
} > "$JOB_FILE"

start_job "$SESSION" "$JOB_FILE"

echo
echo "Started tmux session: $SESSION"
echo "Attach:"
echo "  tmux attach -t $SESSION"
echo
echo "A failed movie is reported and skipped; the rest of the queue continues."
echo "Session closes automatically when all encodes finish"
echo "(it stays open if any encode failed)."
