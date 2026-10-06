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
source "$WORK_DIR/lib/hdr_dovi.sh"
source "$WORK_DIR/lib/policy.sh"

declare -a INPUTS OUTPUTS BITRATES FILTERS TIERS AUDIO_ARGS OVERWRITES
declare -a DV_POLICIES DV_MODES HDR10P_POLICIES

# Compression policy: ~/compress/work/lib/compress.conf (loaded and validated
# by work/lib/policy.sh). The policy math lives there as well
# (movie_video_plan, build_audio_args).
if ! load_policy; then
    exit 1
fi

echo "Policy: $(policy_conf_path)"
for t in Quality High Base; do
    printf "  %-8s %s
" "$t" "$(movie_policy_line "$t")"
done
for t in Quality High Base; do
    echo
    movie_video_policy_lines "$t"
done

while true; do

    # regular files and valid symlinks (see discover_paths)
    mapfile -t files < <(video_files_in_dir "$IN_DIR")

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

    SOURCE_TOTAL_BYTES=$(file_bytes "$IN")

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
    # VIDEO TARGET  (values: compress.conf, math: movie_video_plan)
    # ========================================================

    movie_video_plan "$TIER" "$DURATION" "$SOURCE_VIDEO_BYTES"
    TARGET_MBPS="$PLAN_TARGET_MBPS"

    if (( PLAN_BELOW_FLOOR == 1 )); then

        FLOOR_SIZE=$(video_size_gib "$PLAN_FLOOR_MBPS" "$DURATION")

        echo
        echo "------------------------------------------------------------"
        echo "${TIER} conflict:"
        echo

        printf "%-18s | %-18s | %-18s\n" \
            "" \
            "1. ${TIER} floor" \
            "2. ${PLAN_TARGET_GIB} GiB target"

        printf "%-18s-+-%-18s-+-%-18s\n" \
            "------------------" \
            "------------------" \
            "------------------"

        printf "%-18s | %-18s | %-18s\n" \
            "Video bitrate" \
            "${PLAN_FLOOR_MBPS} Mb/s" \
            "${PLAN_TARGET_MBPS} Mb/s"

        printf "%-18s | %-18s | %-18s\n" \
            "Video size" \
            "~${FLOOR_SIZE} GiB" \
            "~$(video_size_gib "$PLAN_TARGET_MBPS" "$DURATION") GiB"

        echo "------------------------------------------------------------"

        while true; do
            read -rp "Select [1-2]: " qc

            case "$qc" in
                1)
                    TARGET_MBPS="$PLAN_FLOOR_MBPS"
                    break
                    ;;
                2)
                    TARGET_MBPS="$PLAN_TARGET_MBPS"
                    break
                    ;;
                *)
                    echo "Invalid selection."
                    ;;
            esac
        done
    fi

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
    AUDIO_CAP_GIB=$(movie_audio_cap_gib "$TIER")
    AUDIO_FFMPEG_ARGS="-c:a copy"
    EXPECTED_AUDIO_GIB="$SOURCE_AUDIO_GIB"

    if [[ "$TIER" == "Base" ]]; then
        read -ra BASE_CHOICES <<< "$MOVIE_BASE_AUDIO_MAX_GIB_CHOICES"

        echo
        echo "Base audio target:"
        for i in "${!BASE_CHOICES[@]}"; do
            echo "$((i + 1))) ${BASE_CHOICES[$i]} GiB"
        done

        while true; do
            read -rp "Select [1-${#BASE_CHOICES[@]}]: " ac

            if [[ "$ac" =~ ^[0-9]+$ ]] && (( ac >= 1 && ac <= ${#BASE_CHOICES[@]} )); then
                AUDIO_CAP_GIB="${BASE_CHOICES[$((ac - 1))]}"
                break
            fi

            echo "Invalid selection."
        done
    fi

    # 0 = no audio limit: copied unchanged
    TOO_BIG=$(
        awk -v s="$SOURCE_AUDIO_GIB" -v c="$AUDIO_CAP_GIB" \
            'BEGIN {print (c > 0 && s > c) ? 1 : 0}'
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
    DV_POLICIES+=("$DV_POLICY")
    DV_MODES+=("$DV_MODE")
    HDR10P_POLICIES+=("$HDR10P_POLICY")

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

    printf "  Video target:      rate-based   %s GiB  (%s GiB/hour x %s h)\n" \
        "$PLAN_RATE_GIB" "$PLAN_GIB_PER_HOUR" \
        "$(awk -v d="$DURATION" 'BEGIN { printf "%.2f", d / 3600 }')"
    [[ -n "$PLAN_MIN_GIB" ]] &&
        printf "                     minimum      %s GiB\n" "$PLAN_MIN_GIB"
    printf "                     source video %s GiB\n" "${PLAN_SOURCE_GIB:-N/A}"
    if (( PLAN_SOURCE_BELOW_FLOOR == 1 )) && [[ "$TIER" != "Quality" ]]; then
        printf "                     Source bitrate (%.2f Mb/s) is below the %s floor (%s Mb/s).\n" \
            "$PLAN_SOURCE_MBPS" "$TIER" "$PLAN_FLOOR_MBPS"
        printf "                     Using source bitrate as target: %.2f Mb/s (~%s GiB)\n" \
            "$PLAN_TARGET_MBPS" "$PLAN_TARGET_GIB"
    else
        printf "                     selected     %s GiB%s\n" "$PLAN_TARGET_GIB" \
            "$( (( PLAN_SOURCE_LIMITED == 1 )) && echo "  (limited by the source video size)")"
        printf "                     bitrate      %s Mb/s%s\n" "$PLAN_TARGET_MBPS" \
            "$( (( PLAN_MAX_LIMITED == 1 )) && echo "  (limited by the ${PLAN_MAX_MBPS} Mb/s max)")"
    fi

    printf "  Policy:           %s
" "$(movie_policy_line "$TIER")"
    printf "                     (%s)
" "$(policy_conf_path)"

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

    HDR_POLICY_LINE=$(hdr_policy_summary)
    [[ -n "$HDR_POLICY_LINE" ]] &&
        printf "  HDR metadata:      %s\n" "$HDR_POLICY_LINE"

    if [[ "$DV_POLICY" == "preserve" ]] && (( DOWNSCALED == 1 )); then
        echo "  Dolby Vision:      L5 active-area offsets rescaled to ${OUT_WIDTH}x${OUT_HEIGHT}"
    fi

    while IFS= read -r note; do
        [[ -n "$note" ]] && printf "  WARNING:           %s\n" "$note"
    done < <(audio_loss_notes "$IN" "$AUDIO_FFMPEG_ARGS")

    while IFS= read -r note; do
        [[ -n "$note" ]] && printf "  Audio title:       %s\n" "$note"
    done < <(audio_title_notes "$IN" "$AUDIO_FFMPEG_ARGS")

    while IFS= read -r note; do
        [[ -n "$note" ]] && printf "  Chapters:          %s\n" "${note#chapters: }"
    done < <(chapter_notes "$IN")

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
        DV_POLICY="${DV_POLICIES[$i]}"
        DV_MODE="${DV_MODES[$i]}"
        HDR10P_POLICY="${HDR10P_POLICIES[$i]}"

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
