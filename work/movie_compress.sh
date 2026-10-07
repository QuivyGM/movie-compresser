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

# VIDEOS: emit_encode_item video spec per queued movie ("crf:N", "copy"
# or Quality's two-pass kb/s); EST_VBYTES: pre-encode video estimate
# (assigned empty: "set -u" rejects ${#INPUTS[@]} of a never-assigned
# array when every movie was skipped)
declare -a INPUTS=() OUTPUTS=() VIDEOS=() EST_VBYTES=() FILTERS=() TIERS=() OVERWRITES=()
declare -a DV_POLICIES=() DV_MODES=() HDR10P_POLICIES=()

# Compression policy: ~/compress/work/lib/compress.conf (loaded and validated
# by work/lib/policy.sh). The policy math lives there as well
# (movie_video_plan for Quality, crf_select for the CRF tiers); the
# sample encodes behind the CRF estimates are in encode_common.sh.
# Audio is always copied unchanged; audio compression is only done by
# audio_compress_menu.sh.
if ! load_policy; then
    exit 1
fi

# runtime files of earlier jobs confirmed finished (encode_common.sh)
cleanup_finished_jobs "$WORK_DIR"

echo "Policy: $(policy_conf_path)"
for t in Quality High Base Custom; do
    printf "  %-8s %s\n" "$t" "$(movie_policy_line "$t")"
done
for t in Quality High Base; do
    echo
    movie_video_policy_lines "$t"
done
echo
audio_copy_policy_lines

# skip_movie  ->  0 when the user wants to add another movie
skip_movie() {
    echo "Skipped: $BASENAME"
    read -rp "Add another movie? [y/N]: " again
    [[ "$again" =~ ^[Yy]$ ]]
}

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

    # Stored MKV statistics when they pass the checks, otherwise one
    # packet scan, after which the MKV statistics are refreshed for the
    # next run (media_stats.sh: stats_load).
    STATS_PROGRESS=1 stats_load "$IN" "$DURATION" exact refresh
    read -r SOURCE_VIDEO_BYTES SOURCE_AUDIO_BYTES _ _ <<< "$(stats_totals "$VIDX")"
    SOURCE_AUDIO_KBPS=$(stats_audio_kbps)

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
    echo "Values from:  ${STATS_SOURCE}"
    [[ -n "$STATS_REJECTED" ]] &&
        echo "              (stored statistics rejected: ${STATS_REJECTED})"
    [[ -n "$STATS_REFRESH" ]] &&
        echo "              ($(stats_refresh_note))"

    probe_hdr "$IN" "$VIDX"

    if ! confirm_dynamic_range "$BASENAME"; then
        skip_movie && continue
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
                    FILTER="$DOWNSCALE_1080P_FILTER"
                    read -r OUT_WIDTH OUT_HEIGHT <<< "$(downscale_1080p_dims "$WIDTH" "$HEIGHT")"
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
    echo "1) Quality     two-pass, ~$(movie_video_plan Quality "$DURATION" "$SOURCE_VIDEO_BYTES"; echo "$PLAN_TARGET_GIB") GiB video"
    crf_tier_load movie High
    echo "2) High        CRF ${CRF_MIN}-${CRF_MAX}, video ceiling ${CRF_CEILING_GIB} GiB"
    crf_tier_load movie Base
    echo "3) Base        CRF ${CRF_MIN}-${CRF_MAX}, video ceiling ${CRF_CEILING_GIB} GiB"
    echo "4) Custom CRF  exactly the CRF you enter"

    CUSTOM_CRF=""

    while true; do
        read -rp "Select [1-4]: " t

        case "$t" in
            1) TIER="Quality"; break ;;
            2) TIER="High";    break ;;
            3) TIER="Base";    break ;;
            4)
                TIER="Custom"
                while true; do
                    read -rp "Custom CRF: " CUSTOM_CRF
                    crf_valid "$CUSTOM_CRF" && break
                    echo "Enter an x265 CRF from 0 to $CRF_LIMIT, e.g. 21 (lower = higher quality)"
                done
                break
                ;;
            *) echo "Invalid selection." ;;
        esac
    done

    if [[ "$TIER" == "Quality" ]]; then

        # ====================================================
        # QUALITY: two-pass video target (values: compress.conf,
        # math: movie_video_plan)
        # ====================================================

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

        VIDEO_SPEC="$TARGET_KBPS"
        EST_VIDEO_BYTES=""
    else

        # ====================================================
        # CRF TIERS: High / Base choose the lowest CRF of the tier whose
        # sampled video estimate fits the ceiling (crf_select); Custom
        # uses the entered CRF. Audio is not part of the decision.
        # ====================================================

        crf_tier_load movie "$TIER" "$CUSTOM_CRF"

        echo
        crf_policy_lines movie "$TIER" "$CUSTOM_CRF"

        CRF_TITLE_FILE="$IN"
        CRF_TITLE_VIDX="$VIDX"
        CRF_TITLE_FILTER="$FILTER"
        CRF_TITLE_DURATION="$DURATION"
        CRF_TITLE_POINTS="$MOVIE_CRF_SAMPLE_POINTS"

        echo
        printf "Estimating video size from sample encodes (%sx%s output%s):\n" \
            "$OUT_WIDTH" "$OUT_HEIGHT" "$( (( DOWNSCALED == 1 )) && echo ", downscaled like the final encode")"

        if [[ "$TIER" == "Custom" ]]; then
            crf_select_exact "$CUSTOM_CRF" crf_title_estimate || CRF_SELECTED=""
        else
            crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_title_estimate || CRF_SELECTED=""
        fi

        if [[ -z "$CRF_SELECTED" ]]; then
            echo
            echo "CRF analysis failed (sample encode error above); nothing queued for this movie."
            skip_movie && continue
            break
        fi

        CRF="$CRF_SELECTED"
        EST_VIDEO_BYTES="${CRF_EST[$CRF]}"
        EXPECTED_VIDEO_GIB=$(bytes_to_gib "$EST_VIDEO_BYTES")
        VIDEO_SPEC="crf:$CRF"

        echo
        echo "CRF analysis:"
        crf_analysis_lines

        echo
        echo "Selected:"
        echo "  CRF $CRF"
        echo "  estimated video:      ~$(size_text "$EST_VIDEO_BYTES")"
        echo "  copied source audio:  ~$(size_text "$SOURCE_AUDIO_BYTES")"
        echo "  estimated total:      ~$(size_text "$(crf_total_bytes "$EST_VIDEO_BYTES" "$SOURCE_AUDIO_BYTES" "$OTHER_BYTES")")"

        if (( CRF_OVER_CEILING == 1 )); then
            echo
            echo "------------------------------------------------------------"
            echo "WARNING: the ${CRF_CEILING_GIB} GiB video ceiling cannot be met within the"
            echo "${TIER} CRF range: even CRF ${CRF_MAX} (the lowest quality ${TIER} allows) is"
            echo "estimated at ~${EXPECTED_VIDEO_GIB} GiB video, ~$(crf_oversize_gib "$EST_VIDEO_BYTES" "$CRF_CEILING_BYTES") GiB above the ceiling."
            echo "------------------------------------------------------------"
            echo "1) Encode at CRF ${CRF_MAX} anyway (~${EXPECTED_VIDEO_GIB} GiB video)"
            echo "2) Skip this movie"

            while true; do
                read -rp "Select [1-2]: " oc
                case "$oc" in
                    1|2) break ;;
                    *) echo "Invalid selection." ;;
                esac
            done

            if [[ "$oc" == "2" ]]; then
                skip_movie && continue
                break
            fi
        fi

        # Source-quality guard: never make a lossy re-encode that is not
        # smaller than the source without asking.
        if crf_above_source "$EST_VIDEO_BYTES" "$SOURCE_VIDEO_BYTES"; then
            CAN_COPY=0
            if [[ "${HDR_CODEC:-}" == "hevc" ]] && (( DOWNSCALED == 0 )) &&
               [[ "${DV_POLICY:-none}" != "drop" && "${HDR10P_POLICY:-none}" != "drop" ]]; then
                CAN_COPY=1
            fi

            echo
            echo "------------------------------------------------------------"
            echo "Source-quality guard: the source video is already below what"
            echo "${TIER} CRF ${CRF} would need."
            printf "  source video:            %s (%s Mb/s)\n" "$(size_text "$SOURCE_VIDEO_BYTES")" "$SOURCE_VIDEO_MBPS"
            printf "  CRF %-3s estimate:        ~%s (%s Mb/s)\n" "$CRF" "$(size_text "$EST_VIDEO_BYTES")" \
                "$(bytes_to_mbps "$EST_VIDEO_BYTES" "$DURATION")"
            echo "A re-encode would not be smaller than the source, only lossier."
            echo "------------------------------------------------------------"

            if (( CAN_COPY == 1 )); then
                echo "1) Keep the source video unchanged (stream copy; audio, subtitles,"
                echo "   chapters and metadata handled as usual)"
            else
                echo "1) (not available: keeping the source video needs an HEVC source,"
                echo "   no downscaling and no dropped Dolby Vision / HDR10+)"
            fi
            echo "2) Encode anyway at CRF ${CRF} (~${EXPECTED_VIDEO_GIB} GiB video)"
            echo "3) Skip this movie"

            while true; do
                read -rp "Select [1-3]: " sg
                case "$sg" in
                    1) (( CAN_COPY == 1 )) && break; echo "Invalid selection." ;;
                    2|3) break ;;
                    *) echo "Invalid selection." ;;
                esac
            done

            case "$sg" in
                1)
                    VIDEO_SPEC="copy"
                    EST_VIDEO_BYTES=""
                    EXPECTED_VIDEO_GIB="$SOURCE_VIDEO_GIB"
                    ;;
                3)
                    skip_movie && continue
                    break
                    ;;
            esac
        fi
    fi

    # ========================================================
    # AUDIO: every track copied unchanged (size = actual source audio)
    # ========================================================

    EXPECTED_TOTAL_GIB=$(
        awk \
            -v v="$EXPECTED_VIDEO_GIB" \
            -v a="$SOURCE_AUDIO_BYTES" \
            -v o="$OTHER_BYTES" '
            BEGIN {
                printf "%.3f", v + (a + o) / 1073741824
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
        skip_movie && continue
        break
    fi

    OUT="$RESOLVED_OUT"
    PLANNED_OUTPUTS+=("$OUT")

    build_stream_map "$IN" "$VIDX"

    INPUTS+=("$IN")
    OUTPUTS+=("$OUT")
    VIDEOS+=("$VIDEO_SPEC")
    EST_VBYTES+=("$EST_VIDEO_BYTES")
    FILTERS+=("$FILTER")
    TIERS+=("$TIER")
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

    case "$VIDEO_SPEC" in
        crf:*)
            printf "  Video encode:      x265 CRF %s, single pass\n" "$CRF"
            if [[ "$TIER" == "Custom" ]]; then
                printf "                     (entered CRF, used exactly)\n"
            else
                printf "                     (%s: CRF %s-%s, %s GiB video ceiling%s)\n" \
                    "$TIER" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_GIB" \
                    "$( (( CRF_OVER_CEILING == 1 )) && echo "; ceiling NOT met" )"
            fi
            printf "  Video size:        ~%s -> ~%s GiB (estimated from %s sampled CRF%s)\n" \
                "$SOURCE_VIDEO_GIB" "$EXPECTED_VIDEO_GIB" \
                "${#CRF_TRIED[@]}" "$( (( ${#CRF_TRIED[@]} == 1 )) || echo s)"
            printf "  Video bitrate:     %s -> ~%s Mb/s\n" \
                "$SOURCE_VIDEO_MBPS" "$(bytes_to_mbps "$EST_VIDEO_BYTES" "$DURATION")"
            crf_above_source "$EST_VIDEO_BYTES" "$SOURCE_VIDEO_BYTES" &&
                printf "                     (encode anyway chosen: estimate is not below the source)\n"
            ;;
        copy)
            printf "  Video:             source video kept unchanged (stream copy), %s GiB\n" "$SOURCE_VIDEO_GIB"
            printf "                     (%s CRF %s estimate ~%s GiB was not below the source)\n" \
                "$TIER" "$CRF" "$(bytes_to_gib "${CRF_EST[$CRF]}")"
            ;;
        *)
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
            printf "                     selected     %s GiB%s\n" "$PLAN_TARGET_GIB" \
                "$( (( PLAN_SOURCE_LIMITED == 1 )) && echo "  (limited by the source video size)")"
            printf "                     bitrate      %s Mb/s%s\n" "$PLAN_TARGET_MBPS" \
                "$( (( PLAN_MAX_LIMITED == 1 )) && echo "  (limited by the ${PLAN_MAX_MBPS} Mb/s max)")"
            ;;
    esac

    printf "  Policy:            %s\n" "$(movie_policy_line "$TIER")"
    printf "                     (%s)\n" "$(policy_conf_path)"

    printf "  Audio size:        ~%s GiB copied unchanged (%s track(s), actual source audio)\n" \
        "$SOURCE_AUDIO_GIB" "$AUDIO_TRACKS"

    while IFS= read -r note; do
        [[ -n "$note" ]] && printf "                     %s\n" "$note"
    done < <(audio_copy_notes "$IN" "$SOURCE_AUDIO_KBPS")

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

# x265 pass stats exist only for two-pass (Quality) encodes
for v in "${VIDEOS[@]}"; do
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        mkdir -p "$PASS_DIR"
        break
    fi
done

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
            "${VIDEOS[$i]}" \
            "${FILTERS[$i]}" \
            "$PASS_DIR/pass_$i" \
            "${OVERWRITES[$i]}" \
            "${EST_VBYTES[$i]}"
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
