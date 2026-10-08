#!/usr/bin/env bash
set -euo pipefail

IN_DIR="$HOME/compress/in"
OUT_DIR="$HOME/compress/out"
WORK_DIR="$HOME/compress/work"

mkdir -p "$IN_DIR" "$OUT_DIR" "$WORK_DIR"

source "$WORK_DIR/lib/ui.sh"
source "$WORK_DIR/lib/media_probe.sh"
source "$WORK_DIR/lib/media_stats.sh"
source "$WORK_DIR/lib/bitrate.sh"
source "$WORK_DIR/lib/encode_common.sh"
source "$WORK_DIR/lib/hdr_dovi.sh"
source "$WORK_DIR/lib/policy.sh"

# VIDEOS: emit_encode_item video spec per queued movie ("crf:N" or
# "copy"); EST_VBYTES: pre-encode video estimate; QUALITY_SPECS: the
# Quality target / band for the job (emit_encode_item QUALITY)
# (assigned empty: "set -u" rejects ${#INPUTS[@]} of a never-assigned
# array when every movie was skipped)
declare -a INPUTS=() OUTPUTS=() VIDEOS=() EST_VBYTES=() RETRIES=() FILTERS=() TIERS=() OVERWRITES=()
declare -a DV_POLICIES=() DV_MODES=() HDR10P_POLICIES=() QUALITY_SPECS=()

# Compression policy: ~/compress/work/lib/compress.conf (loaded and validated
# by work/lib/policy.sh). The policy math lives there as well
# (crf_select_quality for Quality, crf_select for High / Base); the
# sample encodes behind the CRF estimates are in encode_common.sh.
# Audio is always copied unchanged; audio compression is only done by
# audio_compress_menu.sh.
if ! load_policy; then
    exit 1
fi

# runtime files of earlier jobs confirmed finished (encode_common.sh)
cleanup_finished_jobs "$WORK_DIR"

# Output is compact; COMPRESS_VERBOSE=1 shows the detailed policy, HDR
# tool and sampling diagnostics (lib/ui.sh).
if ui_verbose; then
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
fi

# source_video_can_copy  ->  0 when the source video can be kept unchanged
# (stream copy): HEVC, no downscaling, no dropped Dolby Vision / HDR10+
source_video_can_copy() {
    [[ "${HDR_CODEC:-}" == "hevc" ]] && (( DOWNSCALED == 0 )) &&
        [[ "${DV_POLICY:-none}" != "drop" && "${HDR10P_POLICY:-none}" != "drop" ]]
}

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
    if ui_verbose; then
        echo "Analyzing source..."
    else
        printf 'Analyzing source... '
    fi

    # Main video stream (cover art / attached pictures are skipped).
    VIDX=$(main_video_index "$IN")

    if [[ -z "$VIDX" ]]; then
        ui_verbose || echo
        echo "No video stream found in $BASENAME"
        exit 1
    fi

    IFS=x read -r WIDTH HEIGHT <<< "$(get_resolution "$IN" "$VIDX")"

    DURATION=$(get_duration "$IN")

    SOURCE_TOTAL_BYTES=$(file_bytes "$IN")

    # Stored MKV statistics when they pass the checks, otherwise one
    # packet scan, after which the MKV statistics are refreshed for the
    # next run (media_stats.sh: stats_load).
    STATS_PROGRESS=$(ui_verbose && echo 1 || echo 0) stats_load "$IN" "$DURATION" exact refresh
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

    probe_hdr "$IN" "$VIDX"

    if ui_verbose; then
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
    else
        # "Analyzing source... OK    Source stats: cached"
        printf '%s    Source stats: %s\n' "$(ui_ok OK)" \
            "$(ui_stats_summary "$STATS_KIND$( [[ "$STATS_REFRESH" == refreshed ]] && echo :refreshed)")"
        [[ -n "$STATS_REFRESH" && "$STATS_REFRESH" != refreshed ]] &&
            echo "  $(ui_warn "Stats not refreshed"): $(stats_refresh_note)"

        read -r VCODEC VPIX < <(stream_info "$IN" |
            awk -F'\t' -v v="$VIDX" '$1 == v { print $3, $10; exit }')

        echo
        printf '%-16s%s\n' "Source:" "$BASENAME"
        printf '%-16s%s\n' "Runtime:" "$(format_hms "$DURATION")"
        printf '%-16s%-24s %s Mb/s   %s GiB\n' "Video:" \
            "${WIDTH}x${HEIGHT} ${VCODEC^^} $(ui_bit_depth "$VPIX")" "$SOURCE_VIDEO_MBPS" "$SOURCE_VIDEO_GIB"
        printf '%-16s%s\n' "Dynamic range:" "$(hdr_compact_label)"
        printf '%-16s%s, %s GiB, copied unchanged\n' "Audio:" "$(ui_plural "$AUDIO_TRACKS" track)" "$SOURCE_AUDIO_GIB"
        printf '%-16s%s GiB\n' "File size:" "$SOURCE_TOTAL_GIB"
    fi

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
        if ui_verbose; then
            echo "Source is higher than 1080p."
            echo "1) Keep original resolution (${WIDTH}x${HEIGHT})"
            echo "2) Downscale to 1080p"
        else
            echo "Output resolution:"
            printf '1) %-9s %s\n' "Original" "${WIDTH}x${HEIGHT}"
            printf '2) %-9s %s\n' "1080p" "$(downscale_1080p_dims "$WIDTH" "$HEIGHT" | tr ' ' x)"
        fi

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

    # Quality: CRF searched for the video size band; source-limited when
    # the source video is already at or below the target
    if quality_source_limited "$SOURCE_VIDEO_BYTES"; then
        QUALITY_MENU_TEXT="<=${SOURCE_VIDEO_GIB} GiB (source-limited)"
    else
        QUALITY_MENU_TEXT=$(quality_band_text)
    fi

    echo
    echo "Compression tier:"
    if ui_verbose; then
        echo "1) Quality     CRF ${MOVIE_QUALITY_CRF_MIN}-${MOVIE_QUALITY_CRF_MAX} search, video $QUALITY_MENU_TEXT"
        crf_tier_load movie High
        echo "2) High        CRF ${CRF_MIN}-${CRF_MAX}, video ceiling ${CRF_CEILING_GIB} GiB"
        crf_tier_load movie Base
        echo "3) Base        CRF ${CRF_MIN}-${CRF_MAX}, video ceiling ${CRF_CEILING_GIB} GiB"
        echo "4) Custom CRF  exactly the CRF you enter"
    else
        printf '1) %-8s %-11s %s\n' Quality "CRF search" "$QUALITY_MENU_TEXT"
        crf_tier_load movie High
        printf '2) %-8s %-11s <=%s GiB\n' High "CRF ${CRF_MIN}-${CRF_MAX}" "$CRF_CEILING_GIB"
        crf_tier_load movie Base
        printf '3) %-8s %-11s <=%s GiB\n' Base "CRF ${CRF_MIN}-${CRF_MAX}" "$CRF_CEILING_GIB"
        printf '4) %-8s exact CRF (0-%s)\n' Custom "$CRF_LIMIT"
    fi

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

    # ========================================================
    # QUALITY SOURCE GUARD: a source video at or below the Quality
    # target cannot reach the band without being inflated; ask before
    # any sample encode (keep the source video / encode below the
    # source size / skip).
    # ========================================================

    QUALITY_STATUS=""
    QUALITY_SPEC=""
    QUALITY_KEEP_SOURCE=0
    QUALITY_PICK=""

    if [[ "$TIER" == "Quality" ]]; then
        QUALITY_STATUS="band"

        if quality_source_limited "$SOURCE_VIDEO_BYTES"; then
            CAN_COPY=0
            source_video_can_copy && CAN_COPY=1

            echo
            echo "------------------------------------------------------------"
            echo "Quality source guard: the source video (${SOURCE_VIDEO_GIB} GiB) is already at or"
            echo "below the ${MOVIE_QUALITY_TARGET_VIDEO_GIB} GiB Quality target; the ${MOVIE_QUALITY_ACCEPT_MIN_GIB}-${MOVIE_QUALITY_ACCEPT_MAX_GIB} GiB band cannot be"
            echo "reached without making the video larger than the source."
            echo "------------------------------------------------------------"
            if (( CAN_COPY == 1 )); then
                echo "1) Keep the source video unchanged (stream copy; audio, subtitles,"
                echo "   chapters and metadata handled as usual)"
            else
                echo "1) (not available: keeping the source video needs an HEVC source,"
                echo "   no downscaling and no dropped Dolby Vision / HDR10+)"
            fi
            echo "2) Encode anyway at the lowest Quality CRF estimated below the source size"
            echo "3) Skip this movie"

            while true; do
                read -rp "Select [1-3]: " qg
                case "$qg" in
                    1) (( CAN_COPY == 1 )) && break; echo "Invalid selection." ;;
                    2|3) break ;;
                    *) echo "Invalid selection." ;;
                esac
            done

            case "$qg" in
                1) QUALITY_KEEP_SOURCE=1 ;;
                2) QUALITY_STATUS="source-limited" ;;
                3)
                    skip_movie && continue
                    break
                    ;;
            esac
        fi
    fi

    if (( QUALITY_KEEP_SOURCE == 1 )); then

        # Quality, source preferred: the source video is kept unchanged
        VIDEO_SPEC="copy"
        CRF=""
        EST_VIDEO_BYTES=""
        EXPECTED_VIDEO_GIB="$SOURCE_VIDEO_GIB"
        RETRY_SPEC=""

        if ! ui_verbose; then
            echo
            printf '%-10s%s GiB (source video kept)\n' "Video:" "$SOURCE_VIDEO_GIB"
            printf '%-10s~%s GiB copied\n' "Audio:" "$SOURCE_AUDIO_GIB"
            printf '%-10s~%s GiB\n' "Total:" \
                "$(bytes_to_gib "$(crf_total_bytes "$SOURCE_VIDEO_BYTES" "$SOURCE_AUDIO_BYTES" "$OTHER_BYTES")")"
        fi
    else

        # ====================================================
        # CRF TIERS: High / Base choose the lowest CRF of the tier whose
        # sampled video estimate fits the ceiling (crf_select); Quality
        # the lowest CRF whose estimate is inside the acceptable band,
        # else the one closest to the target (crf_select_quality);
        # Custom uses the entered CRF. Audio is not part of the decision.
        # ====================================================

        crf_tier_load movie "$TIER" "$CUSTOM_CRF"

        if [[ "$QUALITY_STATUS" == "source-limited" ]]; then
            # lowest CRF estimated below the source video size
            CRF_CEILING_BYTES=$(( SOURCE_VIDEO_BYTES - 1 ))
            CRF_CEILING_GIB="$SOURCE_VIDEO_GIB"
        fi

        if ui_verbose; then
            echo
            crf_policy_lines movie "$TIER" "$CUSTOM_CRF"
        fi

        CRF_TITLE_FILE="$IN"
        CRF_TITLE_VIDX="$VIDX"
        CRF_TITLE_FILTER="$FILTER"
        CRF_TITLE_DURATION="$DURATION"
        CRF_TITLE_POINTS="$MOVIE_CRF_SAMPLE_POINTS"

        echo
        if ui_verbose; then
            printf "Estimating video size from sample encodes (%sx%s output%s):\n" \
                "$OUT_WIDTH" "$OUT_HEIGHT" "$( (( DOWNSCALED == 1 )) && echo ", downscaled like the final encode")"
        else
            printf 'Estimating %s at %sx%s...\n' \
                "$( [[ "$TIER" == "Custom" ]] && echo "CRF $CUSTOM_CRF" || echo "$TIER")" "$OUT_WIDTH" "$OUT_HEIGHT"
        fi

        if [[ "$TIER" == "Custom" ]]; then
            crf_select_exact "$CUSTOM_CRF" crf_title_estimate || CRF_SELECTED=""
        elif [[ "$QUALITY_STATUS" == "band" ]]; then
            crf_select_quality "$CRF_MIN" "$CRF_MAX" \
                "$(_gib_bytes "$MOVIE_QUALITY_TARGET_VIDEO_GIB")" \
                "$(_gib_bytes "$MOVIE_QUALITY_ACCEPT_MIN_GIB")" "$(_gib_bytes "$MOVIE_QUALITY_ACCEPT_MAX_GIB")" \
                "$SOURCE_VIDEO_BYTES" crf_title_estimate || CRF_SELECTED=""
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

        # High / Base: re-encoded at CRF + 1 when the actual video is above
        # the ceiling, at CRF - 1 when it fits with CRF_DOWN_RETRY_HEADROOM_PCT
        # to spare (up to CRF_DOWN_RETRY_MAX times, not below CRF_MIN)
        # (job_runtime.sh item_crf_encode). Not for Custom, and
        # not when CRF_MAX above the ceiling was already accepted below.
        # Quality: the same retry with the band's upper edge (never at or
        # above the source video) as the ceiling, and CRF - 1 only while
        # the actual video is below the band (QUALITY_SPEC); source-limited:
        # the source video size as the ceiling, no lower CRF.
        RETRY_SPEC=""
        case "$QUALITY_STATUS" in
            band)
                if [[ "$SOURCE_VIDEO_BYTES" =~ ^[0-9]+$ ]] && (( SOURCE_VIDEO_BYTES > 0 && SOURCE_VIDEO_BYTES - 1 < CRF_CEILING_BYTES )); then
                    CRF_CEILING_BYTES=$(( SOURCE_VIDEO_BYTES - 1 ))
                fi
                RETRY_SPEC="$CRF_CEILING_BYTES:$CRF_MAX:$CRF_MIN:$CRF_DOWN_RETRY_HEADROOM_PCT:$CRF_DOWN_RETRY_MAX"
                QUALITY_SPEC="$(_gib_bytes "$MOVIE_QUALITY_TARGET_VIDEO_GIB"):$(_gib_bytes "$MOVIE_QUALITY_ACCEPT_MIN_GIB"):$(_gib_bytes "$MOVIE_QUALITY_ACCEPT_MAX_GIB"):band"
                ;;
            source-limited)
                RETRY_SPEC="$CRF_CEILING_BYTES:$CRF_MAX:$CRF_MIN:$CRF_DOWN_RETRY_HEADROOM_PCT:0"
                QUALITY_SPEC="$SOURCE_VIDEO_BYTES:0:$CRF_CEILING_BYTES:source-limited"
                ;;
            *)
                [[ "$TIER" != "Custom" ]] && RETRY_SPEC="$CRF_CEILING_BYTES:$CRF_MAX:$CRF_MIN:$CRF_DOWN_RETRY_HEADROOM_PCT:$CRF_DOWN_RETRY_MAX"
                ;;
        esac

        if ui_verbose; then
            echo
            echo "CRF analysis:"
            crf_analysis_lines

            echo
            echo "Selected:"
            echo "  CRF $CRF"
            echo "  estimated video:      ~$(size_text "$EST_VIDEO_BYTES")"
            if [[ "$QUALITY_STATUS" == "band" ]]; then
                echo "  Quality target:       ${MOVIE_QUALITY_TARGET_VIDEO_GIB} GiB video, band ${MOVIE_QUALITY_ACCEPT_MIN_GIB}-${MOVIE_QUALITY_ACCEPT_MAX_GIB} GiB"
                echo "  chosen as:            $(quality_pick_text)"
            elif [[ "$QUALITY_STATUS" == "source-limited" ]]; then
                echo "  Quality target:       below the source video (${SOURCE_VIDEO_GIB} GiB; source-limited)"
            fi
            echo "  copied source audio:  ~$(size_text "$SOURCE_AUDIO_BYTES")"
            echo "  estimated total:      ~$(size_text "$(crf_total_bytes "$EST_VIDEO_BYTES" "$SOURCE_AUDIO_BYTES" "$OTHER_BYTES")")"
        else
            echo
            printf '%-10s~%s GiB\n' "Video:" "$EXPECTED_VIDEO_GIB"
            if [[ "$QUALITY_STATUS" == "band" ]]; then
                printf '%-10s%s GiB\n' "Target:" "$(gib_text "$MOVIE_QUALITY_TARGET_VIDEO_GIB")"
                printf '%-10s%s-%s GiB\n' "Band:" "$(gib_text "$MOVIE_QUALITY_ACCEPT_MIN_GIB")" "$(gib_text "$MOVIE_QUALITY_ACCEPT_MAX_GIB")"
            elif [[ "$QUALITY_STATUS" == "source-limited" ]]; then
                printf '%-10s%s\n' "Target:" "below the source video (${SOURCE_VIDEO_GIB} GiB)"
                printf '%-10s%s\n' "Band:" "not applied (source-limited)"
            elif [[ "$TIER" != "Custom" ]]; then
                printf '%-10s%s GiB\n' "Ceiling:" "$(bytes_to_gib "$CRF_CEILING_BYTES")"
            fi
            if (( CRF_OVER_CEILING == 1 )); then
                printf '%-10s%s (CRF %s is the %s limit)\n' "Result:" "$(ui_warn "too large")" "$CRF_MAX" "$TIER"
            elif [[ "$QUALITY_PICK" == "closest" ]]; then
                printf '%-10s%s (%s)\n' "Selected:" "$(ui_bold "CRF $CRF")" "$(quality_pick_text)"
            else
                printf '%-10s%s\n' "Selected:" "$(ui_bold "CRF $CRF")"
            fi
            printf '%-10s~%s GiB copied\n' "Audio:" "$SOURCE_AUDIO_GIB"
            printf '%-10s~%s GiB\n' "Total:" \
                "$(bytes_to_gib "$(crf_total_bytes "$EST_VIDEO_BYTES" "$SOURCE_AUDIO_BYTES" "$OTHER_BYTES")")"
        fi

        if (( CRF_OVER_CEILING == 1 )); then
            echo
            echo "------------------------------------------------------------"
            echo "$(ui_warn WARNING): the ${CRF_CEILING_GIB} GiB video ceiling cannot be met within the"
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

            # CRF_MAX above the ceiling accepted: nothing left to retry
            RETRY_SPEC=""
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
    RETRIES+=("$RETRY_SPEC")
    QUALITY_SPECS+=("$QUALITY_SPEC")
    FILTERS+=("$FILTER")
    TIERS+=("$TIER")
    OVERWRITES+=("$RESOLVED_OVERWRITE")
    DV_POLICIES+=("$DV_POLICY")
    DV_MODES+=("$DV_MODE")
    HDR10P_POLICIES+=("$HDR10P_POLICY")

    # ========================================================
    # SUMMARY
    # ========================================================

    if ui_verbose; then
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
                elif [[ "$QUALITY_STATUS" == "band" ]]; then
                    printf "                     (Quality: CRF %s-%s, %s GiB video target, band %s-%s GiB; %s)\n" \
                        "$CRF_MIN" "$CRF_MAX" "$MOVIE_QUALITY_TARGET_VIDEO_GIB" \
                        "$MOVIE_QUALITY_ACCEPT_MIN_GIB" "$MOVIE_QUALITY_ACCEPT_MAX_GIB" "$(quality_pick_text)"
                elif [[ "$QUALITY_STATUS" == "source-limited" ]]; then
                    printf "                     (Quality: CRF %s-%s, source-limited: below the %s GiB source video)\n" \
                        "$CRF_MIN" "$CRF_MAX" "$SOURCE_VIDEO_GIB"
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
                if (( QUALITY_KEEP_SOURCE == 1 )); then
                    printf "                     (Quality: source video at or below the %s GiB target; source preferred)\n" \
                        "$MOVIE_QUALITY_TARGET_VIDEO_GIB"
                else
                    printf "                     (%s CRF %s estimate ~%s GiB was not below the source)\n" \
                        "$TIER" "$CRF" "$(bytes_to_gib "${CRF_EST[$CRF]}")"
                fi
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
    else
        case "$VIDEO_SPEC" in
            crf:*) VIDEO_TEXT=$(ui_bold "CRF $CRF") ;;
            copy)  VIDEO_TEXT="source video kept" ;;
        esac

        echo
        echo "Added: $BASENAME"
        printf '  %s | %s | %sx%s | %s | audio copied%s\n' "$TIER" "$VIDEO_TEXT" \
            "$OUT_WIDTH" "$OUT_HEIGHT" "$(hdr_policy_short)" \
            "$( [[ "$VIDEO_SPEC" == crf:* ]] && (( ${CRF_OVER_CEILING:-0} == 1 )) && echo " | $(ui_warn "ceiling not met")")"
        printf '  %-8s%s -> ~%s GiB  (video ~%s, audio %s)\n' "Size:" "$SOURCE_TOTAL_GIB" \
            "$(awk -v t="$EXPECTED_TOTAL_GIB" 'BEGIN { printf "%.2f", t }')" "$EXPECTED_VIDEO_GIB" "$SOURCE_AUDIO_GIB"

        # only what is lost or dropped (COMPRESS_VERBOSE=1 lists every note)
        while IFS= read -r note; do
            [[ "$note" =~ LOST|DROPPED|WARNING|cannot|skipped|missing ]] &&
                printf '  %s %s\n' "$(ui_warn "Note:")" "$note"
        done < <(printf '%s\n' "${MAP_NOTES[@]+"${MAP_NOTES[@]}"}"; chapter_notes "$IN")

        printf '  %-8s%s%s\n' "Output:" "$(basename "$OUT")" \
            "$( (( RESOLVED_OVERWRITE == 1 )) && echo "  [overwrites existing]")"
        echo
    fi

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
            "" \
            "${OVERWRITES[$i]}" \
            "${EST_VBYTES[$i]}" \
            "${RETRIES[$i]}" \
            "${QUALITY_SPECS[$i]}"
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
