#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/compress"
IN_DIR="$BASE/in"
OUT_DIR="$BASE/out"
WORK_DIR="$BASE/work"

source "$WORK_DIR/lib/media_probe.sh"
source "$WORK_DIR/lib/media_stats.sh"
source "$WORK_DIR/lib/bitrate.sh"
source "$WORK_DIR/lib/encode_common.sh"
source "$WORK_DIR/lib/hdr_dovi.sh"
source "$WORK_DIR/lib/policy.sh"

# ============================================================
# POLICY  (values: ~/compress/work/lib/compress.conf; math: policy.sh
# crf_select / series_crf_spread / series_crf_plan; sample encodes:
# encode_common.sh crf_series_estimate)
#
# Base / High: x265 CRF, ONE CRF for every episode of the batch: the
#              lowest CRF of SERIES_*_CRF_MIN..MAX whose median episode
#              video estimate fits SERIES_*_VIDEO_SIZE_CEILING_GIB
#              (a nominal per-episode ceiling, not a target)
# Custom:      user-entered CRF, used exactly for every episode (no
#              High/Base range or ceiling)
#
# Episodes estimated above the nominal ceiling keep the batch CRF
# (consistent quality) and are listed as outliers. An episode whose
# estimate is not below its source video is only re-encoded when the
# user chooses so (or its source video is kept / it is skipped).
#
# Every audio track is copied unchanged (codec, bitrate, channels,
# Atmos / DTS:X, titles, flags) and comes on top of the video size;
# audio compression is only done by audio_compress_menu.sh. All
# subtitles are retained.
# ============================================================

if ! load_policy; then
    exit 1
fi

echo "Policy: $(policy_conf_path)"
for t in High Base Custom; do
    echo
    crf_policy_lines series "$t"
done
echo
audio_copy_policy_lines

# ============================================================
# FIND SERIES FOLDERS
# ============================================================

# folders and valid folder symlinks (see discover_paths)
mapfile -t SERIES_DIRS < <(series_dirs "$IN_DIR")

if (( ${#SERIES_DIRS[@]} == 0 )); then
    echo
    echo "No series folders found in:"
    echo "  $IN_DIR"
    exit 1
fi

echo
echo "Select series:"
echo

for i in "${!SERIES_DIRS[@]}"; do

    COUNT=$(DISCOVERY_QUIET=1 video_files_in_dir "${SERIES_DIRS[$i]}" | wc -l)

    printf "%2d) %s [%d files]\n" \
        "$((i+1))" \
        "$(basename "${SERIES_DIRS[$i]}")" \
        "$COUNT"
done

while true; do
    echo
    read -rp "Choice: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] &&
       (( choice >= 1 && choice <= ${#SERIES_DIRS[@]} )); then
        break
    fi

    echo "Invalid selection."
done

SERIES_DIR="${SERIES_DIRS[$((choice-1))]}"
SERIES_NAME="$(basename "$SERIES_DIR")"

mapfile -t FILES < <(video_files_in_dir "$SERIES_DIR")

FILE_COUNT=${#FILES[@]}

# ============================================================
# ANALYZE EPISODES
#
# Per episode: duration, main video stream, source bitrates per
# stream (media_stats.sh stats_load: valid stored MKV statistics tags,
# stream bit rates for non-MKV, or a packet scan), dynamic range.
# ============================================================

echo
echo "Analyzing ${FILE_COUNT} files..."

declare -a EP_DUR EP_VIDX EP_VKBPS EP_VBYTES EP_AKBPS EP_ABYTES EP_ACH EP_ACODEC EP_ASR
declare -a EP_RES EP_VCODEC EP_PIX EP_FPS EP_RANGE EP_SUBS EP_OTHER EP_HOW EP_H10P EP_REFRESH

for i in "${!FILES[@]}"; do
    file="${FILES[$i]}"

    printf "  %s\n" "$(basename "$file")"

    info=$(stream_info "$file")
    vidx=$(awk -F'\t' '$2 == "video" && $4 == 0 { print $1; exit }' <<< "$info")

    if [[ -z "$vidx" ]]; then
        echo
        echo "No video stream in: $(basename "$file")"
        echo "Compression cancelled."
        exit 1
    fi

    dur=$(get_duration "$file")
    # Only episodes that needed a packet scan get their MKV statistics
    # refreshed; valid ones are read and left untouched.
    STATS_PROGRESS=1 STATS_INDENT="      " stats_load "$file" "$dur" estimate refresh

    EP_DUR[$i]="$dur"
    EP_VIDX[$i]="$vidx"
    EP_VKBPS[$i]=$(stats_field "$vidx" kbps)
    EP_HOW[$i]="$STATS_SOURCE"
    EP_REFRESH[$i]="$STATS_REFRESH"
    EP_AKBPS[$i]=$(stats_audio_kbps)
    # source video (source-quality guard) and copied source audio (all
    # tracks; its actual size goes on top of the video estimate)
    read -r EP_VBYTES[$i] EP_ABYTES[$i] _ _ <<< "$(stats_totals "$vidx")"

    EP_ACH[$i]=$(awk -F'\t' '$2 == "audio" { printf "%s ", $5 }' <<< "$info")
    EP_ACODEC[$i]=$(awk -F'\t' '$2 == "audio" { printf "%s ", $3 }' <<< "$info")
    EP_ASR[$i]=$(awk -F'\t' '$2 == "audio" { printf "%s ", $7 }' <<< "$info")
    EP_SUBS[$i]=$(awk -F'\t' '$2 == "subtitle" { printf "%s ", $3 }' <<< "$info")
    EP_OTHER[$i]=$(awk -F'\t' '$2 == "attachment" || $2 == "data" || ($2 == "video" && $4 == 1) { n++ } END { print n + 0 }' <<< "$info")

    read -r EP_RES[$i] EP_VCODEC[$i] EP_PIX[$i] EP_FPS[$i] < <(
        awk -F'\t' -v v="$vidx" '$1 == v { printf "%sx%s %s %s %s\n", $8, $9, $3, $10, $11 }' <<< "$info"
    )

    probe_hdr "$file" "$vidx"
    EP_RANGE[$i]="$HDR_KIND"
    EP_H10P[$i]="$HDR_HDR10PLUS"
    if (( HDR_DV == 1 )); then
        EP_RANGE[$i]="$HDR_KIND+DV${HDR_DV_PROFILE}"
    fi
done

# ============================================================
# VERIFY COMPATIBILITY
#
# Must match (they set the shared encode parameters):
#   resolution, dynamic range (SDR/HDR10/HLG/Dolby Vision),
#   audio track count and channels per track
# Reported only (handled per episode):
#   video codec, pixel format, frame rate, audio codecs and sample
#   rates, subtitle tracks, attachments
# ============================================================

echo
echo "Verifying ${FILE_COUNT} files against $(basename "${FILES[0]}")..."
echo

describe_list() {
    local s="${1% }"
    [[ -n "$s" ]] && printf '%s' "${s// /, }" || printf 'none'
}

INCOMPATIBLE=0
DIFFERENT=0

for i in "${!FILES[@]}"; do
    hard=()
    soft=()

    [[ "${EP_RES[$i]}" == "${EP_RES[0]}" ]] ||
        hard+=("resolution ${EP_RES[$i]} vs ${EP_RES[0]}")
    [[ "${EP_RANGE[$i]}" == "${EP_RANGE[0]}" ]] ||
        hard+=("dynamic range ${EP_RANGE[$i]} vs ${EP_RANGE[0]}")
    [[ "${EP_ACH[$i]}" == "${EP_ACH[0]}" ]] ||
        hard+=("audio channels [$(describe_list "${EP_ACH[$i]}")] vs [$(describe_list "${EP_ACH[0]}")]")

    [[ "${EP_VCODEC[$i]}" == "${EP_VCODEC[0]}" ]] ||
        soft+=("video codec ${EP_VCODEC[$i]}")
    [[ "${EP_PIX[$i]}" == "${EP_PIX[0]}" ]] ||
        soft+=("pixel format ${EP_PIX[$i]}")
    [[ "${EP_FPS[$i]}" == "${EP_FPS[0]}" ]] ||
        soft+=("frame rate ${EP_FPS[$i]}")
    [[ "${EP_ACODEC[$i]}" == "${EP_ACODEC[0]}" ]] ||
        soft+=("audio codecs [$(describe_list "${EP_ACODEC[$i]}")]")
    [[ "${EP_ASR[$i]}" == "${EP_ASR[0]}" ]] ||
        soft+=("sample rates [$(describe_list "${EP_ASR[$i]}")]")
    [[ "${EP_SUBS[$i]}" == "${EP_SUBS[0]}" ]] ||
        soft+=("subtitles [$(describe_list "${EP_SUBS[$i]}")] vs [$(describe_list "${EP_SUBS[0]}")]")
    [[ "${EP_OTHER[$i]}" == "${EP_OTHER[0]}" ]] ||
        soft+=("${EP_OTHER[$i]} attachment/cover/data stream(s) vs ${EP_OTHER[0]}")
    [[ "${EP_H10P[$i]}" == "${EP_H10P[0]}" ]] ||
        soft+=("HDR10+ $( (( EP_H10P[$i] == 1 )) && echo present || echo absent)")

    if (( ${#hard[@]} )); then
        printf "MISMATCH  %s\n" "$(basename "${FILES[$i]}")"
        for d in "${hard[@]}"; do printf "            - %s\n" "$d"; done
        for d in "${soft[@]+"${soft[@]}"}"; do printf "            (also: %s)\n" "$d"; done
        INCOMPATIBLE=1
    elif (( ${#soft[@]} )); then
        printf "OK*       %s\n" "$(basename "${FILES[$i]}")"
        for d in "${soft[@]}"; do printf "            differs: %s\n" "$d"; done
        DIFFERENT=1
    else
        printf "OK        %s\n" "$(basename "${FILES[$i]}")"
    fi
done

if (( INCOMPATIBLE == 1 )); then
    echo
    echo "Series settings do not match: resolution, dynamic range or audio"
    echo "layout differ, so one shared encode setting cannot be used."
    echo "Compression cancelled."
    exit 1
fi

echo
if (( DIFFERENT == 1 )); then
    echo "All files compatible. Differences marked OK* do not affect the shared"
    echo "encode settings; every stream of every episode is still kept."
else
    echo "All files match."
fi

# ============================================================
# COMMON SOURCE INFO
# ============================================================

REFERENCE="${FILES[0]}"
IFS=x read -r WIDTH HEIGHT <<< "${EP_RES[0]}"
read -ra AUDIO_CHANNELS <<< "${EP_ACH[0]}"

probe_hdr "$REFERENCE" "${EP_VIDX[0]}"

# HDR10+ may differ per episode: decide once if any episode has it.
for i in "${!FILES[@]}"; do
    if (( EP_H10P[$i] == 1 )); then
        HDR_HDR10PLUS=1
    fi
done

echo
echo "------------------------------------------------------------"
echo "Series:        $SERIES_NAME"
echo "Files:         ${FILE_COUNT}"
echo "Resolution:    ${WIDTH}x${HEIGHT}"
echo "Video:         ${EP_VCODEC[0]} / ${EP_PIX[0]}"
echo "Frame rate:    ${EP_FPS[0]}"
echo "Audio tracks:  ${#AUDIO_CHANNELS[@]}"
echo "Values from:"
{
    printf "%s\n" "${EP_HOW[@]}"
    for r in "${EP_REFRESH[@]+"${EP_REFRESH[@]}"}"; do
        case "$r" in
            refreshed)       echo "refreshed statistics" ;;
            skipped:*)       echo "statistics not refreshed (${r#skipped: })" ;;
            failed:*)        echo "statistics refresh failed" ;;
            verify-failed:*) echo "statistics refreshed, re-read did not match" ;;
        esac
    done
} | awk '{ n[$0]++; if (!($0 in seen)) { seen[$0] = 1; order[++k] = $0 } }
    END { for (i = 1; i <= k; i++) printf "  %s: %d file%s\n", order[i], n[order[i]], (n[order[i]] == 1 ? "" : "s") }'
echo "------------------------------------------------------------"

if ! confirm_dynamic_range "this series"; then
    echo "Compression cancelled."
    exit 0
fi

# ============================================================
# RESOLUTION
# ============================================================

VIDEO_FILTER=""
OUT_WIDTH="$WIDTH"
OUT_HEIGHT="$HEIGHT"
DOWNSCALED=0

if (( WIDTH > 1920 || HEIGHT > 1080 )); then
    echo
    echo "Output resolution:"
    echo "1) Keep original  [${WIDTH}x${HEIGHT}]"
    echo "2) Downscale to 1080p"

    while true; do
        read -rp "Select [1-2]: " r

        case "$r" in
            1)
                break
                ;;
            2)
                DOWNSCALED=1
                VIDEO_FILTER="$DOWNSCALE_1080P_FILTER"
                read -r OUT_WIDTH OUT_HEIGHT <<< "$(downscale_1080p_dims "$WIDTH" "$HEIGHT")"
                break
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
fi

# ============================================================
# TIER
# ============================================================

per_file() {
    awk -v g="$1" -v n="$FILE_COUNT" 'BEGIN { printf "%.2f", g / n }'
}

echo
echo "Compression tier:"
crf_tier_load series Base
echo "1) Base        CRF ${CRF_MIN}-${CRF_MAX}, nominal video ceiling ${CRF_CEILING_GIB} GiB/episode (audio copied unchanged)"
crf_tier_load series High
echo "2) High        CRF ${CRF_MIN}-${CRF_MAX}, nominal video ceiling ${CRF_CEILING_GIB} GiB/episode (audio copied unchanged)"
echo "3) Custom CRF  exactly the CRF you enter, any 0-${CRF_LIMIT} (no range or ceiling; audio copied unchanged)"

CUSTOM_CRF=""

while true; do
    echo
    read -rp "Select [1-3]: " t

    case "$t" in
        1) TIER="Base"; break ;;
        2) TIER="High"; break ;;
        3)
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

crf_tier_load series "$TIER" "$CUSTOM_CRF"

echo
crf_policy_lines series "$TIER" "$CUSTOM_CRF"

# ============================================================
# CRF ANALYSIS  (policy.sh: crf_select, series_crf_spread;
# encode_common.sh: crf_series_estimate)
#
# One CRF for every episode. Sampled episodes (spread over the batch)
# are encoded at the output resolution; the median episode estimate
# decides whether a CRF fits the per-episode ceiling.
# ============================================================

mapfile -t CRF_SERIES_SAMPLED < <(series_sample_episodes "$FILE_COUNT" "$SERIES_CRF_SAMPLE_EPISODES")
CRF_SERIES_FILTER="$VIDEO_FILTER"
declare -A CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=()

echo
printf "Estimating video size from sample encodes (%d of %d episodes, %sx%s output%s):\n" \
    "${#CRF_SERIES_SAMPLED[@]}" "$FILE_COUNT" "$OUT_WIDTH" "$OUT_HEIGHT" \
    "$( (( DOWNSCALED == 1 )) && echo ", downscaled like the final encode")"

if [[ "$TIER" == "Custom" ]]; then
    crf_select_exact "$CUSTOM_CRF" crf_series_estimate || CRF_SELECTED=""
else
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate || CRF_SELECTED=""
fi

if [[ -z "$CRF_SELECTED" ]]; then
    echo
    echo "CRF analysis failed (sample encode error above)."
    echo "Compression cancelled."
    exit 1
fi

CRF="$CRF_SELECTED"
read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[$CRF]}"
read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[$CRF]}"

# season figures at the batch CRF (audio is never part of them)
series_batch_stats "$CRF_CEILING_BYTES" "${EP_EST[@]}"
ABOVE=("${SB_ABOVE[@]+"${SB_ABOVE[@]}"}")
EST_MEDIAN="$SB_MEDIAN"
EST_LARGEST="$SB_LARGEST"

echo
echo "CRF analysis (video only; copied audio is not part of the choice):"
series_crf_analysis_lines

echo
echo "Selected:"
echo "  CRF $CRF for all ${FILE_COUNT} episodes"
echo "  median episode video:  ~$(size_text "$EST_MEDIAN")"
echo "  largest episode video: ~$(size_text "$EST_LARGEST")"
if [[ "$TIER" != "Custom" ]]; then
    echo "  nominal ceiling:       ${CRF_CEILING_GIB} GiB/episode"
fi

if (( CRF_OVER_CEILING == 1 )); then
    echo
    echo "------------------------------------------------------------"
    echo "WARNING: the nominal ${CRF_CEILING_GIB} GiB per-episode video ceiling cannot be met"
    echo "within the allowed ${TIER} quality range: even CRF ${CRF_MAX} (the lowest quality ${TIER}"
    echo "allows) gives a median episode of ~$(bytes_to_gib "$EST_MEDIAN") GiB video, ~$(crf_oversize_gib "$EST_MEDIAN" "$CRF_CEILING_BYTES") GiB above the ceiling."
    echo "------------------------------------------------------------"
    echo "1) Encode every episode at CRF ${CRF_MAX} anyway"
    echo "2) Cancel"

    while true; do
        read -rp "Select [1-2]: " oc
        case "$oc" in
            1) break ;;
            2) echo "Compression cancelled."; exit 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
fi

# Episodes above the nominal per-episode ceiling at the batch CRF:
# listed as outliers, not given a different CRF (consistent quality
# across the season). Custom has no ceiling.
if (( ${#ABOVE[@]} )); then
    echo
    if (( ${#ABOVE[@]} == 1 )); then
        echo "Warning: 1 episode is estimated above the nominal ${CRF_CEILING_GIB} GiB ceiling."
    else
        echo "Warning: ${#ABOVE[@]} episodes are estimated above the nominal ${CRF_CEILING_GIB} GiB ceiling."
    fi
    echo "They keep CRF ${CRF} like the rest of the season (consistent quality):"
    for i in "${ABOVE[@]}"; do
        printf "  %-40.40s ~%s GiB video, +%s GiB (%s)\n" "$(basename "${FILES[$i]}")" \
            "$(bytes_to_gib "${EP_EST[$i]}")" \
            "$(crf_oversize_gib "${EP_EST[$i]}" "$CRF_CEILING_BYTES")" \
            "$( [[ "${EP_FROM[$i]}" == sample ]] && echo "sampled" || echo "median bitrate")"
    done
fi

# ============================================================
# SOURCE-QUALITY GUARD
#
# Episodes whose estimate at the batch CRF is not below their source
# video: a re-encode would only be lossier. The user keeps the source
# video (stream copy), encodes anyway, or skips those episodes.
# ============================================================

declare -a EP_VIDEO EP_GUARD_SKIP
GUARD=()

for i in "${!FILES[@]}"; do
    EP_VIDEO[$i]="crf:$CRF"
    EP_GUARD_SKIP[$i]=0
    crf_above_source "${EP_EST[$i]}" "${EP_VBYTES[$i]:-}" && GUARD+=("$i")
done

if (( ${#GUARD[@]} )); then
    CAN_COPY=1
    for i in "${GUARD[@]}"; do
        [[ "${EP_VCODEC[$i]}" == "hevc" ]] || CAN_COPY=0
    done
    (( DOWNSCALED == 1 )) && CAN_COPY=0
    [[ "${DV_POLICY:-none}" == "drop" || "${HDR10P_POLICY:-none}" == "drop" ]] && CAN_COPY=0

    echo
    echo "------------------------------------------------------------"
    echo "Source-quality guard: ${#GUARD[@]} episode(s) are already below what"
    echo "${TIER} CRF ${CRF} would need (a re-encode would not be smaller, only lossier):"
    for i in "${GUARD[@]}"; do
        printf "  %-40.40s source %s, CRF %s estimate ~%s\n" "$(basename "${FILES[$i]}")" \
            "$(size_text "${EP_VBYTES[$i]}")" "$CRF" "$(size_text "${EP_EST[$i]}")"
    done
    echo "------------------------------------------------------------"

    if (( CAN_COPY == 1 )); then
        echo "1) Keep their source video unchanged (stream copy; audio, subtitles,"
        echo "   chapters and metadata handled as usual)"
    else
        echo "1) (not available: keeping the source video needs HEVC sources,"
        echo "   no downscaling and no dropped Dolby Vision / HDR10+)"
    fi
    echo "2) Encode them anyway at CRF ${CRF}"
    echo "3) Skip these episodes"

    while true; do
        read -rp "Select [1-3]: " sg
        case "$sg" in
            1) (( CAN_COPY == 1 )) && break; echo "Invalid selection." ;;
            2|3) break ;;
            *) echo "Invalid selection." ;;
        esac
    done

    for i in "${GUARD[@]}"; do
        case "$sg" in
            1) EP_VIDEO[$i]="copy" ;;
            3) EP_GUARD_SKIP[$i]=1 ;;
        esac
    done
fi

# expected sizes (estimated video, or the source video when copied)
PLAN_VIDEO=()
for i in "${!FILES[@]}"; do
    if [[ "${EP_VIDEO[$i]}" == "copy" ]]; then
        PLAN_VIDEO[$i]="${EP_VBYTES[$i]:-copy}"
    else
        PLAN_VIDEO[$i]="${EP_EST[$i]}"
    fi
done
series_crf_plan "${PLAN_VIDEO[@]}"

echo
echo "------------------------------------------------------------"
echo "Tier:                 $TIER"
if [[ "$TIER" == "Custom" ]]; then
    echo "Video encode:         x265 CRF ${CRF}, single pass, every episode (entered CRF)"
else
    echo "Video encode:         x265 CRF ${CRF}, single pass, every episode"
    echo "                      (${TIER}: CRF ${CRF_MIN}-${CRF_MAX}, ${CRF_CEILING_GIB} GiB/episode nominal video ceiling$( (( CRF_OVER_CEILING == 1 )) && echo "; ceiling NOT met"))"
fi
echo "Resolution:           ${WIDTH}x${HEIGHT} -> ${OUT_WIDTH}x${OUT_HEIGHT}"
echo "Dynamic range:        $(hdr_description)"

HDR_POLICY_LINE=$(hdr_policy_summary)
if [[ -n "$HDR_POLICY_LINE" ]]; then
    echo "HDR metadata:         $HDR_POLICY_LINE"
fi

if [[ "$DV_POLICY" == "preserve" ]] && (( DOWNSCALED == 1 )); then
    echo "Dolby Vision:         L5 active-area offsets rescaled to ${OUT_WIDTH}x${OUT_HEIGHT}"
fi
echo "Audio:                all tracks copied unchanged (on top of the video size)"

# same audio layout in every episode (verified above); details of the first
while IFS= read -r note; do
    [[ -n "$note" ]] && echo "  $note"
done < <(audio_copy_notes "$REFERENCE" "${EP_AKBPS[0]}")

echo
echo "Per-episode rules:"
echo "  - video: the same CRF for every episode (sizes vary with content);"
echo "    an episode whose estimate is not below its source is only re-encoded"
echo "    if you chose so above"
echo "  - audio: every track copied unchanged (optional audio compression"
echo "    afterwards with audio_compress_menu.sh)"
echo "------------------------------------------------------------"

# ============================================================
# SIZE PREVIEW
# ============================================================

declare -A IS_ABOVE=() IS_GUARD=()
for i in "${ABOVE[@]+"${ABOVE[@]}"}"; do IS_ABOVE[$i]=1; done
for i in "${GUARD[@]+"${GUARD[@]}"}"; do IS_GUARD[$i]=1; done

echo
echo "Expected sizes:"
echo
printf "  %-32s %7s %5s %7s %7s %7s  %-8s %s\n" \
    "Episode" "Runtime" "CRF" "Video" "Audio" "Total" "Estimate" "Status"

for i in "${!FILES[@]}"; do
    ccol="$CRF"
    if (( EP_GUARD_SKIP[$i] == 1 )); then
        ccol="-"; ecol="-"; status="SKIPPED (source-quality guard)"
    elif [[ "${EP_VIDEO[$i]}" == "copy" ]]; then
        ccol="copy"; ecol="source"; status="SOURCE VIDEO KEPT"
    else
        [[ "${EP_FROM[$i]}" == "sample" ]] && ecol="sampled" || ecol="median"
        if [[ -n "${IS_ABOVE[$i]:-}" ]]; then
            status="ABOVE NOMINAL CEILING"
        else
            status="OK"
        fi
        [[ -n "${IS_GUARD[$i]:-}" ]] && status+=" (not below source; encode anyway)"
    fi

    printf "  %-32.32s %7s %5s %7s %7s %7s  %-8s %s\n" \
        "$(basename "${FILES[$i]}")" \
        "$(awk -v d="${EP_DUR[$i]}" 'BEGIN { printf "%d:%02d", int(d / 60), int(d % 60) }')" \
        "$ccol" "${P_EP_VGIB[$i]}" "${P_EP_AGIB[$i]}" "${P_EP_GIB[$i]}" "$ecol" "$status"
done
echo "  (runtime m:ss; sizes in GiB; video = estimate from sample encodes;"
echo "   audio = actual size of all copied source audio tracks;"
echo "   total = video + audio + ~${SERIES_CONTAINER_RESERVE_PCT}% container/subtitles)"
echo "  sampled = this episode was sample-encoded"
echo "  median  = not sampled; median sampled video bitrate x its runtime"
if [[ "$TIER" != "Custom" ]]; then
    echo "  ABOVE NOMINAL CEILING = video estimate above ${CRF_CEILING_GIB} GiB; still CRF ${CRF}"
fi

# Stream / title / chapter handling, shown for the first episode (the
# same rules apply to every episode; each output is verified).
build_stream_map "$REFERENCE" "${EP_VIDX[0]}"
REF_NOTES=("${MAP_NOTES[@]+"${MAP_NOTES[@]}"}")

while IFS= read -r note; do
    [[ -n "$note" ]] && REF_NOTES+=("$note")
done < <(chapter_notes "$REFERENCE")

if (( ${#REF_NOTES[@]} )); then
    echo
    echo "Stream handling ($(basename "$REFERENCE"); same rules for every episode):"
    for note in "${REF_NOTES[@]}"; do
        printf "  %s\n" "$note"
    done
fi

echo
echo "Season totals (${FILE_COUNT} files):"
printf "  Shared CRF:                 %s (every episode)\n" "$CRF"
printf "  Total runtime:              %s hours (%s min)\n" \
    "$(awk -v s="$P_TOTAL_SECONDS" 'BEGIN { printf "%.2f", s / 3600 }')" \
    "$(awk -v s="$P_TOTAL_SECONDS" 'BEGIN { printf "%.0f", s / 60 }')"
printf "  Median episode video:       ~%s GiB\n" "$(bytes_to_gib "$EST_MEDIAN")"
printf "  Largest episode video:      ~%s GiB\n" "$(bytes_to_gib "$EST_LARGEST")"
if [[ "$TIER" == "Custom" ]]; then
    printf "  Above nominal ceiling:      n/a (Custom has no ceiling)\n"
else
    printf "  Above nominal ceiling:      %d of %d episode(s) (%s GiB/episode)\n" \
        "${#ABOVE[@]}" "$FILE_COUNT" "$CRF_CEILING_GIB"
fi
printf "  Expected total video size:  ~%s GiB\n" "$P_VIDEO_GIB"
printf "  Copied source audio size:   ~%s GiB\n" "$P_AUDIO_GIB"
printf "  Expected total output size: ~%s GiB  (incl. ~%s%% container/subtitles)\n" \
    "$P_TOTAL_GIB" "$SERIES_CONTAINER_RESERVE_PCT"
echo
printf "  Average per file:           ~%s GiB (video ~%s, audio ~%s)\n" \
    "$(per_file "$P_TOTAL_GIB")" "$(per_file "$P_VIDEO_GIB")" "$(per_file "$P_AUDIO_GIB")"
GUARD_SKIPPED=0
for i in "${!FILES[@]}"; do
    (( EP_GUARD_SKIP[$i] == 1 )) && ((GUARD_SKIPPED += 1))
done
(( GUARD_SKIPPED > 0 )) &&
    echo "  (totals include the $GUARD_SKIPPED episode(s) skipped by the source-quality guard)"
echo

# ============================================================
# OUTPUT
# ============================================================

if (( DOWNSCALED == 1 )); then
    OUT_SERIES="$OUT_DIR/${SERIES_NAME} 1080p HEVC ${TIER}"
else
    OUT_SERIES="$OUT_DIR/${SERIES_NAME} HEVC ${TIER}"
fi

declare -a EP_OUT EP_OVERWRITE EP_SKIP
EXISTING=0

for i in "${!FILES[@]}"; do
    NAME="$(basename "${FILES[$i]}")"
    NAME="${NAME%.*}"

    if (( DOWNSCALED == 1 )); then
        EP_OUT[$i]="$OUT_SERIES/${NAME} 1080p HEVC ${TIER}.mkv"
    else
        EP_OUT[$i]="$OUT_SERIES/${NAME} HEVC ${TIER}.mkv"
    fi

    EP_OVERWRITE[$i]=0
    EP_SKIP[$i]="${EP_GUARD_SKIP[$i]}"

    # a symlink (valid or broken) at the output name counts as existing
    if (( EP_SKIP[$i] == 0 )) &&
       { path_taken "${EP_OUT[$i]}" || path_taken "${EP_OUT[$i]}.part"; }; then
        ((EXISTING += 1))
    fi
done

if (( EXISTING > 0 )); then
    echo "$EXISTING of ${FILE_COUNT} outputs already exist in:"
    echo "  $OUT_SERIES"

    for i in "${!FILES[@]}"; do
        if [[ -L "${EP_OUT[$i]}" ]] && ! path_taken "${EP_OUT[$i]}.part"; then
            echo
            output_symlink_notice "${EP_OUT[$i]}"
        fi
    done
    echo
    echo "1) Keep both (new files get a \" (2)\" suffix)"
    echo "2) Overwrite existing files when the new encodes complete"
    echo "3) Skip episodes that already have an output"

    while true; do
        read -rp "Select [1-3]: " oc
        case "$oc" in
            1|2|3) break ;;
            *) echo "Invalid selection." ;;
        esac
    done

    for i in "${!FILES[@]}"; do
        (( EP_SKIP[$i] == 1 )) && continue
        if path_taken "${EP_OUT[$i]}.part"; then
            # Possibly being written by another job: never touch it.
            if [[ "$oc" == "3" ]]; then
                EP_SKIP[$i]=1
            else
                EP_OUT[$i]=$(unique_output_path "${EP_OUT[$i]}")
            fi
        elif path_taken "${EP_OUT[$i]}"; then
            case "$oc" in
                1) EP_OUT[$i]=$(unique_output_path "${EP_OUT[$i]}") ;;
                2) EP_OVERWRITE[$i]=1 ;;
                3) EP_SKIP[$i]=1 ;;
            esac
        fi
    done
    echo
fi

QUEUED=0
for i in "${!FILES[@]}"; do
    (( EP_SKIP[$i] == 1 )) || ((QUEUED += 1))
done

if (( QUEUED == 0 )); then
    echo "Nothing to encode."
    exit 0
fi

read -rp "Start compression of $QUEUED episode(s)? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

mkdir -p "$OUT_SERIES"

# ============================================================
# TMUX SESSION
# ============================================================

SESSION=$(next_tmux_session series)

JOB_FILE="$WORK_DIR/${SESSION}.sh"

# ============================================================
# BUILD ENCODE JOB
# ============================================================

{
    emit_job_header "$SESSION" series "$QUEUED"

    n=0
    for i in "${!FILES[@]}"; do
        (( EP_SKIP[$i] == 1 )) && continue
        ((n += 1))

        # single-pass CRF (or source video copy): no x265 pass logs
        emit_encode_item \
            "$n" \
            "${FILES[$i]}" \
            "${EP_OUT[$i]}" \
            "$TIER" \
            "${EP_VIDEO[$i]}" \
            "$VIDEO_FILTER" \
            "" \
            "${EP_OVERWRITE[$i]}" \
            "${EP_EST[$i]}"
    done

    emit_job_footer
} > "$JOB_FILE"

start_job "$SESSION" "$JOB_FILE"

echo
echo "Started: $SESSION"
echo
echo "Output:"
echo "  $OUT_SERIES"
echo
echo "Attach:"
echo "  tmux attach -t $SESSION"
echo
echo "A failed episode is reported and skipped; the rest of the series continues."
