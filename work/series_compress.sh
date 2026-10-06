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
# series_video_plan / series_plan)
#
# Base / High: SERIES_*_VIDEO_GIB_PER_HOUR (video only), floor, max
# Custom:      user-entered video GiB/hour, no floor / max, High audio
#
# One fixed video bitrate for every episode; audio is added on top of
# the video size, never taken from it. Per episode:
#   - a source video bitrate below the fixed bitrate is kept (never
#     increased); one below the tier floor is kept as well (not reduced)
#   - an audio track whose source bitrate is already at or below the
#     fixed audio rate for its channel count is copied unchanged
#
# All audio tracks and subtitles are retained.
# ============================================================

if ! load_policy; then
    exit 1
fi

echo "Policy: $(policy_conf_path)"
for t in High Base; do
    echo
    series_video_policy_lines "$t"
done
echo
echo "Audio:"
echo "  separate from video size target"
echo "  (AAC per track by channel count; tracks already at or below it are copied)"

# audio_rate TIER CHANNELS  ->  AAC kb/s (compress.conf SERIES_*_AAC_KBPS_*)
audio_rate() {
    series_aac_kbps "$@"
}

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

declare -a EP_DUR EP_VIDX EP_VKBPS EP_AKBPS EP_ACH EP_ACODEC EP_ASR
declare -a EP_RES EP_VCODEC EP_PIX EP_FPS EP_RANGE EP_SUBS EP_OTHER EP_HOW EP_H10P

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
    STATS_PROGRESS=1 STATS_INDENT="      " stats_load "$file" "$dur" estimate

    EP_DUR[$i]="$dur"
    EP_VIDX[$i]="$vidx"
    EP_VKBPS[$i]=$(stats_field "$vidx" kbps)
    EP_HOW[$i]="$STATS_SOURCE"
    EP_AKBPS[$i]=$(stats_audio_kbps)

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
printf "%s\n" "${EP_HOW[@]}" | sort | uniq -c |
    awk '{ n = $1; $1 = ""; printf "%s%s%s (%d file%s)\n", (NR == 1 ? "Values from:   " : "               "), "", substr($0, 2), n, (n == 1 ? "" : "s") }'
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
                VIDEO_FILTER="scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"

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

# ============================================================
# PLAN  (policy.sh: series_video_plan, series_plan)
# ============================================================

per_file() {
    awk -v g="$1" -v n="$FILE_COUNT" 'BEGIN { printf "%.2f", g / n }'
}

kbps_mbps() {
    awk -v k="$1" 'BEGIN { printf "%.2f", k / 1000 }'
}

# show_preview LABEL TIER [CUSTOM_GIB_PER_HOUR]
show_preview() {
    local label="$1"
    local tier="$2"

    series_video_plan "$tier" "${3:-}"
    series_plan "$tier" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"

    echo "$label"
    printf "   Video:   %s kb/s fixed%s\n" "$SPLAN_TARGET_KBPS" \
        "$( (( SPLAN_MAX_LIMITED == 1 )) && echo " (limited by the $(kbps_mbps "$SPLAN_MAX_KBPS") Mb/s max)")"
    printf "   Total:   ~%s GiB | Video ~%s GiB | Audio ~%s GiB (%s kb/s, on top)\n" \
        "$P_TOTAL_GIB" "$P_VIDEO_GIB" "$P_AUDIO_GIB" "$P_AUDIO_KBPS"

    printf "   Average: ~%s GiB/file | Video ~%s GiB | Audio ~%s GiB\n" \
        "$(per_file "$P_TOTAL_GIB")" "$(per_file "$P_VIDEO_GIB")" "$(per_file "$P_AUDIO_GIB")"

    if (( SPLAN_BELOW_FLOOR == 1 )); then
        printf "   Below the %s Mb/s floor: you will be asked (floor or GiB/hour target)\n" \
            "$(kbps_mbps "$SPLAN_FLOOR_KBPS")"
    fi

    if (( P_SRC_BELOW_FLOOR > 0 )); then
        printf "   %d episode(s) below the floor at the source: kept at their source bitrate\n" "$P_SRC_BELOW_FLOOR"
    fi

    if (( P_CAPPED > 0 )); then
        printf "   %d episode(s) kept at their lower source video bitrate\n" "$P_CAPPED"
    fi

    if (( P_COPIED > 0 )); then
        printf "   %d audio track(s) copied: source already at or below target\n" "$P_COPIED"
    fi
}

# ============================================================
# TIER
# ============================================================

echo
echo "Compression tier:"

show_preview "1) Base  [${SERIES_BASE_VIDEO_GIB_PER_HOUR} GiB/hour video + audio]" "Base"
echo

show_preview "2) High  [${SERIES_HIGH_VIDEO_GIB_PER_HOUR} GiB/hour video + audio]" "High"
echo

echo "3) Custom video GiB/hour (no floor / max, High audio rates)"

CUSTOM_GIB=""

while true; do
    echo
    read -rp "Select [1-3]: " t

    case "$t" in
        1)
            TIER="Base"
            break
            ;;

        2)
            TIER="High"
            break
            ;;

        3)
            while true; do
                read -rp "Custom video GiB/hour: " CUSTOM_GIB

                if awk -v x="$CUSTOM_GIB" \
                    'BEGIN {exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x > 0)}'
                then
                    break
                fi

                echo "Enter a positive number, e.g. 2.5"
            done

            # Custom uses High audio rates.
            TIER="Custom"

            echo
            echo "Expected result:"
            show_preview "Custom [${CUSTOM_GIB} GiB/hour video + audio]" \
                "Custom" "$CUSTOM_GIB"

            break
            ;;

        *)
            echo "Invalid selection."
            ;;
    esac
done

# ============================================================
# FIXED VIDEO BITRATE
# ============================================================

series_video_plan "$TIER" "$CUSTOM_GIB"
GIB_PER_HOUR="$SPLAN_GIB_PER_HOUR"
VIDEO_KBPS="$SPLAN_TARGET_KBPS"

if (( SPLAN_BELOW_FLOOR == 1 )); then
    series_plan "$TIER" "$SPLAN_FLOOR_KBPS" "$SPLAN_FLOOR_KBPS"
    FLOOR_VIDEO_GIB="$P_VIDEO_GIB"
    series_plan "$TIER" "$SPLAN_TARGET_KBPS" "$SPLAN_FLOOR_KBPS"
    TARGET_VIDEO_GIB="$P_VIDEO_GIB"

    echo
    echo "------------------------------------------------------------"
    echo "${TIER} conflict: the GiB/hour target is below the floor."
    echo

    printf "%-18s | %-20s | %-20s\n" \
        "" \
        "1. ${TIER} floor" \
        "2. ${GIB_PER_HOUR} GiB/hour"

    printf "%-18s-+-%-20s-+-%-20s\n" \
        "------------------" \
        "--------------------" \
        "--------------------"

    printf "%-18s | %-20s | %-20s\n" \
        "Video bitrate" \
        "${SPLAN_FLOOR_KBPS} kb/s" \
        "${SPLAN_TARGET_KBPS} kb/s"

    printf "%-18s | %-20s | %-20s\n" \
        "Video, all files" \
        "~${FLOOR_VIDEO_GIB} GiB" \
        "~${TARGET_VIDEO_GIB} GiB"

    echo "------------------------------------------------------------"

    while true; do
        read -rp "Select [1-2]: " fc

        case "$fc" in
            1) VIDEO_KBPS="$SPLAN_FLOOR_KBPS"; break ;;
            2) VIDEO_KBPS="$SPLAN_TARGET_KBPS"; break ;;
            *) echo "Invalid selection." ;;
        esac
    done
fi

series_plan "$TIER" "$VIDEO_KBPS" "$SPLAN_FLOOR_KBPS"

AUDIO_TOTAL_KBPS="$P_AUDIO_KBPS"

echo
echo "------------------------------------------------------------"
echo "Tier:                 $TIER"
echo "Video target:         ${GIB_PER_HOUR} GiB/hour (video only; audio on top)"
echo "Resolution:           ${WIDTH}x${HEIGHT} -> ${OUT_WIDTH}x${OUT_HEIGHT}"
echo "Dynamic range:        $(hdr_description)"

HDR_POLICY_LINE=$(hdr_policy_summary)
if [[ -n "$HDR_POLICY_LINE" ]]; then
    echo "HDR metadata:         $HDR_POLICY_LINE"
fi

if [[ "$DV_POLICY" == "preserve" ]] && (( DOWNSCALED == 1 )); then
    echo "Dolby Vision:         L5 active-area offsets rescaled to ${OUT_WIDTH}x${OUT_HEIGHT}"
fi
printf "Fixed video bitrate:  %s kb/s" "$VIDEO_KBPS"
if [[ "$VIDEO_KBPS" == "$SPLAN_FLOOR_KBPS" ]] && (( SPLAN_BELOW_FLOOR == 1 )); then
    printf "  (floor chosen; GiB/hour target was %s kb/s)" "$SPLAN_TARGET_KBPS"
elif (( SPLAN_MAX_LIMITED == 1 )); then
    printf "  (limited by the %s Mb/s max; GiB/hour gives %s kb/s)" "$(kbps_mbps "$SPLAN_MAX_KBPS")" "$SPLAN_RATE_KBPS"
fi
echo
if (( SPLAN_FLOOR_KBPS > 0 || SPLAN_MAX_KBPS > 0 )); then
    printf "  floor %s Mb/s, max %s\n" "$(kbps_mbps "$SPLAN_FLOOR_KBPS")" \
        "$( (( SPLAN_MAX_KBPS > 0 )) && echo "$(kbps_mbps "$SPLAN_MAX_KBPS") Mb/s" || echo none)"
fi
echo "Fixed audio total:    ${AUDIO_TOTAL_KBPS} kb/s (on top of the video size)"

for i in "${!AUDIO_CHANNELS[@]}"; do
    RATE=$(audio_rate "$TIER" "${AUDIO_CHANNELS[$i]}")
    echo "  Audio $((i+1)):           ${RATE} kb/s AAC (${AUDIO_CHANNELS[$i]} ch)"
done

echo
echo "Per-episode rules (never increase quality settings above the source):"
echo "  - video: fixed bitrate, or the source video bitrate if that is lower;"
echo "    a source below the tier floor is kept at its own bitrate"
echo "  - audio: re-encoded at the fixed rate, or copied unchanged if the"
echo "    source track is already at or below it"
echo "------------------------------------------------------------"

# ============================================================
# SIZE PREVIEW
# ============================================================

echo
echo "Expected sizes:"
echo
printf "  %-36s %7s  %-17s %-14s %9s %9s %9s\n" \
    "Episode" "Minutes" "Video kb/s" "Audio" "Video" "Audio" "Total"

for i in "${!FILES[@]}"; do
    case "${P_EP_VNOTE[$i]}" in
        src)   vcol="${P_EP_VKBPS[$i]} (src)" ;;
        floor) vcol="${P_EP_VKBPS[$i]} (src<floor)" ;;
        *)     vcol="${P_EP_VKBPS[$i]}" ;;
    esac

    printf "  %-36.36s %7s  %-17s %-14.14s %9s %9s %9s\n" \
        "$(basename "${FILES[$i]}")" \
        "$(awk -v d="${EP_DUR[$i]}" 'BEGIN { printf "%.1f", d / 60 }')" \
        "$vcol" \
        "${P_EP_ADESC[$i]}" \
        "~${P_EP_VGIB[$i]}" "~${P_EP_AGIB[$i]}" "~${P_EP_GIB[$i]}"
done
echo "  (sizes in GiB)"

if (( P_CAPPED > 0 )); then
    echo
    echo "  (src)       = source video bitrate is below ${VIDEO_KBPS} kb/s; encoded at the"
    echo "                source bitrate instead of raising it."
fi

if (( P_SRC_BELOW_FLOOR > 0 )); then
    echo
    echo "  (src<floor) = source video bitrate is below the ${TIER} floor"
    echo "                ($(kbps_mbps "$SPLAN_FLOOR_KBPS") Mb/s); kept at the source bitrate, not reduced."
fi

for i in "${!FILES[@]}"; do
    if [[ ! "${EP_VKBPS[$i]}" =~ ^[0-9]+$ ]]; then
        echo
        echo "  Note: source video bitrate unknown for some episodes; fixed bitrate used."
        break
    fi
done

LOSS_SHOWN=0

for i in "${!FILES[@]}"; do
    while IFS= read -r note; do
        [[ -n "$note" ]] || continue

        if (( LOSS_SHOWN == 0 )); then
            echo
            echo "WARNING: object audio metadata is lost by re-encoding:"
            LOSS_SHOWN=1
        fi

        printf "  %s: %s\n" "$(basename "${FILES[$i]}")" "$note"
    done < <(audio_loss_notes "${FILES[$i]}" "${P_EP_AARGS[$i]}")
done

# Stream / title / chapter handling, shown for the first episode (the
# same rules apply to every episode; each output is verified).
build_stream_map "$REFERENCE" "${EP_VIDX[0]}"
REF_NOTES=("${MAP_NOTES[@]+"${MAP_NOTES[@]}"}")

while IFS= read -r note; do
    [[ -n "$note" ]] && REF_NOTES+=("$note")
done < <(audio_title_notes "$REFERENCE" "${P_EP_AARGS[0]}"; chapter_notes "$REFERENCE")

if (( ${#REF_NOTES[@]} )); then
    echo
    echo "Stream handling ($(basename "$REFERENCE"); same rules for every episode):"
    for note in "${REF_NOTES[@]}"; do
        printf "  %s\n" "$note"
    done
fi

echo
echo "Season totals (${FILE_COUNT} files):"
printf "  Total runtime:              %s hours (%s min)\n" \
    "$(awk -v s="$P_TOTAL_SECONDS" 'BEGIN { printf "%.2f", s / 3600 }')" \
    "$(awk -v s="$P_TOTAL_SECONDS" 'BEGIN { printf "%.0f", s / 60 }')"
printf "  Expected total video size:  ~%s GiB\n" "$P_VIDEO_GIB"
printf "  Expected total audio size:  ~%s GiB\n" "$P_AUDIO_GIB"
printf "  Expected total output size: ~%s GiB  (incl. ~%s%% container/subtitles)\n" \
    "$P_TOTAL_GIB" "$SERIES_CONTAINER_RESERVE_PCT"
echo
printf "  Average per file:           ~%s GiB (video ~%s, audio ~%s)\n" \
    "$(per_file "$P_TOTAL_GIB")" "$(per_file "$P_VIDEO_GIB")" "$(per_file "$P_AUDIO_GIB")"
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
    EP_SKIP[$i]=0

    # a symlink (valid or broken) at the output name counts as existing
    if path_taken "${EP_OUT[$i]}" || path_taken "${EP_OUT[$i]}.part"; then
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
PASS_DIR="$WORK_DIR/${SESSION}_passes"

mkdir -p "$PASS_DIR"

# ============================================================
# BUILD ENCODE JOB
# ============================================================

{
    emit_job_header "$SESSION" series "$QUEUED"

    n=0
    for i in "${!FILES[@]}"; do
        (( EP_SKIP[$i] == 1 )) && continue
        ((n += 1))

        emit_encode_item \
            "$n" \
            "${FILES[$i]}" \
            "${EP_OUT[$i]}" \
            "$TIER" \
            "${P_EP_VKBPS[$i]}" \
            "$VIDEO_FILTER" \
            "${P_EP_AARGS[$i]}" \
            "$PASS_DIR/pass_$i" \
            "${EP_OVERWRITE[$i]}"
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
