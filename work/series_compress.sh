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

# ============================================================
# POLICY
#
# Base:
#   ~1.5 GiB/hour total
#
# High:
#   ~4 GiB/hour total
#
# Custom:
#   user-entered GiB/hour, High audio rates
#
# The same fixed video/audio bitrates are used for every episode,
# with 1% reserved for container/subtitles/metadata, except:
#   - an episode whose source video bitrate is lower than the fixed
#     video bitrate is encoded at its source bitrate (never increased)
#   - an audio track whose source bitrate is already at or below the
#     fixed audio rate for its channel count is copied unchanged
#
# All audio tracks and subtitles are retained.
# ============================================================

audio_rate() {
    local tier="$1"
    local channels="$2"

    [[ "$channels" =~ ^[0-9]+$ ]] || channels=2

    if [[ "$tier" == "High" || "$tier" == "Custom" ]]; then
        if (( channels >= 7 )); then
            echo 768
        elif (( channels == 6 )); then
            echo 640
        elif (( channels >= 3 )); then
            echo 384
        elif (( channels == 2 )); then
            echo 192
        else
            echo 96
        fi
    else
        if (( channels >= 7 )); then
            echo 320
        elif (( channels == 6 )); then
            echo 256
        elif (( channels >= 3 )); then
            echo 192
        elif (( channels == 2 )); then
            echo 128
        else
            echo 64
        fi
    fi
}

# ============================================================
# FIND SERIES FOLDERS
# ============================================================

mapfile -t SERIES_DIRS < <(
    find "$IN_DIR" -mindepth 1 -maxdepth 1 -type d -print |
    while IFS= read -r dir; do
        if find "$dir" -maxdepth 1 -type f \
            \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) \
            -print -quit | grep -q .; then
            printf '%s\n' "$dir"
        fi
    done |
    sort
)

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

    COUNT=$(video_files_in_dir "${SERIES_DIRS[$i]}" | wc -l)

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
# stream (container bit_rate, MKV BPS tag, or a packet scan when
# neither exists), dynamic range.
# ============================================================

echo
echo "Analyzing ${FILE_COUNT} files..."

declare -a EP_DUR EP_VIDX EP_VKBPS EP_AKBPS EP_ACH EP_ACODEC EP_ASR
declare -a EP_RES EP_VCODEC EP_PIX EP_FPS EP_RANGE EP_SUBS EP_OTHER EP_HOW

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
    kbps=$(stream_kbps "$file" "$dur")

    EP_DUR[$i]="$dur"
    EP_VIDX[$i]="$vidx"
    EP_VKBPS[$i]=$(awk -v v="$vidx" '$1 == v { print $4 }' <<< "$kbps")
    EP_HOW[$i]=$(awk -v v="$vidx" '$1 == v { print $5 }' <<< "$kbps")
    EP_AKBPS[$i]=$(awk '$2 == "audio" { printf "%s ", $4 }' <<< "$kbps")

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

echo
echo "------------------------------------------------------------"
echo "Series:        $SERIES_NAME"
echo "Files:         ${FILE_COUNT}"
echo "Resolution:    ${WIDTH}x${HEIGHT}"
echo "Video:         ${EP_VCODEC[0]} / ${EP_PIX[0]}"
echo "Frame rate:    ${EP_FPS[0]}"
echo "Audio tracks:  ${#AUDIO_CHANNELS[@]}"
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
# PLAN
#
# plan_tier TIER GIB_PER_HOUR
#
# Sets:
#   P_TOTAL_KBPS P_MEDIA_KBPS P_AUDIO_KBPS P_VIDEO_KBPS  (fixed rates)
#   P_EP_VKBPS[i]  video kb/s per episode (fixed, or source if lower)
#   P_EP_AARGS[i]  shell-quoted audio args per episode
#   P_EP_ADESC[i]  short audio description per episode
#   P_EP_GIB[i]    expected size per episode
#   P_CAPPED       episodes capped at their source video bitrate
#   P_COPIED       audio tracks copied (all episodes)
#   P_VIDEO_GIB P_AUDIO_GIB P_TOTAL_GIB  totals
# ============================================================

plan_tier() {
    local tier="$1"
    local gib_per_hour="$2"
    local i t rate src v a_kbps a_size_kb tokens desc
    local -a src_rates

    P_AUDIO_KBPS=0
    for t in "${!AUDIO_CHANNELS[@]}"; do
        rate=$(audio_rate "$tier" "${AUDIO_CHANNELS[$t]}")
        P_AUDIO_KBPS=$((P_AUDIO_KBPS + rate))
    done

    P_TOTAL_KBPS=$(gib_per_hour_to_kbps "$gib_per_hour")
    P_MEDIA_KBPS=$(awk -v x="$P_TOTAL_KBPS" 'BEGIN { printf "%.0f", x * 0.99 }')
    P_VIDEO_KBPS=$((P_MEDIA_KBPS - P_AUDIO_KBPS))

    P_CAPPED=0
    P_COPIED=0
    P_EP_VKBPS=()
    P_EP_AARGS=()
    P_EP_ADESC=()
    P_EP_GIB=()

    local video_kb_total=0
    local audio_kb_total=0

    for i in "${!FILES[@]}"; do
        v="$P_VIDEO_KBPS"
        src="${EP_VKBPS[$i]}"

        # Never above the source video bitrate.
        if [[ "$src" =~ ^[0-9]+$ ]] && (( src > 0 && src < v )); then
            v="$src"
            ((P_CAPPED += 1))
        fi

        P_EP_VKBPS[$i]="$v"

        read -ra src_rates <<< "${EP_AKBPS[$i]}"
        tokens=""
        desc=""
        a_kbps=0

        for t in "${!AUDIO_CHANNELS[@]}"; do
            rate=$(audio_rate "$tier" "${AUDIO_CHANNELS[$t]}")
            src="${src_rates[$t]:-N/A}"

            if [[ "$src" =~ ^[0-9]+$ ]] && (( src > 0 && src <= rate )); then
                # Already at or below the target: no lossy re-encode.
                a_kbps=$((a_kbps + src))
                desc+="copy "
                ((P_COPIED += 1))
            else
                tokens+=$(printf '%q ' "-c:a:$t" aac "-b:a:$t" "${rate}k")
                a_kbps=$((a_kbps + rate))
                desc+="${rate}k "
            fi
        done

        P_EP_AARGS[$i]="${tokens% }"
        P_EP_ADESC[$i]="${desc% }"

        P_EP_GIB[$i]=$(awk -v v="$v" -v a="$a_kbps" -v s="${EP_DUR[$i]}" 'BEGIN {
            printf "%.2f", (v + a) * 1000 * s / 8 / 0.99 / 1073741824 }')

        video_kb_total=$(awk -v t="$video_kb_total" -v k="$v" -v s="${EP_DUR[$i]}" \
            'BEGIN { printf "%.0f", t + k * s }')
        audio_kb_total=$(awk -v t="$audio_kb_total" -v k="$a_kbps" -v s="${EP_DUR[$i]}" \
            'BEGIN { printf "%.0f", t + k * s }')
    done

    P_VIDEO_GIB=$(awk -v k="$video_kb_total" 'BEGIN { printf "%.2f", k * 1000 / 8 / 1073741824 }')
    P_AUDIO_GIB=$(awk -v k="$audio_kb_total" 'BEGIN { printf "%.2f", k * 1000 / 8 / 1073741824 }')
    P_TOTAL_GIB=$(awk -v v="$video_kb_total" -v a="$audio_kb_total" \
        'BEGIN { printf "%.2f", (v + a) * 1000 / 8 / 0.99 / 1073741824 }')
}

TOTAL_SECONDS=$(printf '%s\n' "${EP_DUR[@]}" | awk '{ s += $1 } END { printf "%.3f", s }')
TOTAL_HOURS=$(awk -v s="$TOTAL_SECONDS" 'BEGIN { printf "%.2f", s / 3600 }')

per_file() {
    awk -v g="$1" -v n="$FILE_COUNT" 'BEGIN { printf "%.2f", g / n }'
}

show_preview() {
    local label="$1"
    local tier="$2"
    local gib="$3"

    plan_tier "$tier" "$gib"

    echo "$label"
    printf "   Total:   ~%s GiB | Video ~%s GiB (%s kb/s) | Audio ~%s GiB (%s kb/s)\n" \
        "$P_TOTAL_GIB" "$P_VIDEO_GIB" "$P_VIDEO_KBPS" "$P_AUDIO_GIB" "$P_AUDIO_KBPS"

    printf "   Average: ~%s GiB/file | Video ~%s GiB | Audio ~%s GiB\n" \
        "$(per_file "$P_TOTAL_GIB")" "$(per_file "$P_VIDEO_GIB")" "$(per_file "$P_AUDIO_GIB")"

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

show_preview "1) Base  [~1.5 GiB/hour]" "Base" "1.5"
echo

show_preview "2) High  [~4 GiB/hour]" "High" "4"
echo

echo "3) Custom GiB/hour"

while true; do
    echo
    read -rp "Select [1-3]: " t

    case "$t" in
        1)
            TIER="Base"
            GIB_PER_HOUR="1.5"
            break
            ;;

        2)
            TIER="High"
            GIB_PER_HOUR="4"
            break
            ;;

        3)
            while true; do
                read -rp "Custom GiB/hour: " CUSTOM_GIB

                if awk -v x="$CUSTOM_GIB" \
                    'BEGIN {exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x > 0)}'
                then
                    break
                fi

                echo "Enter a positive number, e.g. 2.5"
            done

            # Custom uses High audio rates.
            TIER="Custom"
            GIB_PER_HOUR="$CUSTOM_GIB"

            echo
            echo "Expected result:"
            show_preview "Custom [~${GIB_PER_HOUR} GiB/hour]" \
                "Custom" "$GIB_PER_HOUR"

            break
            ;;

        *)
            echo "Invalid selection."
            ;;
    esac
done

# ============================================================
# FIXED BITRATES
#
# 1.5 GiB/hour = ~3579 kb/s total
# 4 GiB/hour   = ~9544 kb/s total
# Custom       = calculated from requested GiB/hour
#
# Reserve 1% for container/subtitles/metadata.
# ============================================================

plan_tier "$TIER" "$GIB_PER_HOUR"

VIDEO_KBPS="$P_VIDEO_KBPS"
AUDIO_TOTAL_KBPS="$P_AUDIO_KBPS"

if (( VIDEO_KBPS < 500 )); then
    echo
    echo "Audio uses too much of the selected size budget."
    echo "Total target: ${P_TOTAL_KBPS} kb/s"
    echo "Audio:        ${AUDIO_TOTAL_KBPS} kb/s"
    echo "Video left:   ${VIDEO_KBPS} kb/s"
    exit 1
fi

echo
echo "------------------------------------------------------------"
echo "Tier:                 $TIER"
echo "Target:               ~${GIB_PER_HOUR} GiB/hour"
echo "Resolution:           ${WIDTH}x${HEIGHT} -> ${OUT_WIDTH}x${OUT_HEIGHT}"
echo "Dynamic range:        $(hdr_description)"
echo "Fixed video bitrate:  ${VIDEO_KBPS} kb/s"
echo "Fixed audio total:    ${AUDIO_TOTAL_KBPS} kb/s"

for i in "${!AUDIO_CHANNELS[@]}"; do
    RATE=$(audio_rate "$TIER" "${AUDIO_CHANNELS[$i]}")
    echo "  Audio $((i+1)):           ${RATE} kb/s AAC (${AUDIO_CHANNELS[$i]} ch)"
done

echo
echo "Per-episode rules (never increase quality settings above the source):"
echo "  - video: fixed bitrate, or the source video bitrate if that is lower"
echo "  - audio: re-encoded at the fixed rate, or copied unchanged if the"
echo "    source track is already at or below it"
echo "------------------------------------------------------------"

# ============================================================
# SIZE PREVIEW
# ============================================================

echo
echo "Expected sizes:"
echo
printf "  %-44s %7s  %13s  %-16s %s\n" "File" "Minutes" "Video kb/s" "Audio" "Size"

for i in "${!FILES[@]}"; do
    src="${EP_VKBPS[$i]}"
    [[ "$src" =~ ^[0-9]+$ ]] || src="?"

    if [[ "${P_EP_VKBPS[$i]}" != "$VIDEO_KBPS" ]]; then
        vcol="${P_EP_VKBPS[$i]} (src)"
    else
        vcol="${P_EP_VKBPS[$i]}"
    fi

    printf "  %-44.44s %7s  %13s  %-16.16s ~%s GiB\n" \
        "$(basename "${FILES[$i]}")" \
        "$(awk -v d="${EP_DUR[$i]}" 'BEGIN { printf "%.1f", d / 60 }')" \
        "$vcol" \
        "${P_EP_ADESC[$i]}" \
        "${P_EP_GIB[$i]}"
done

if (( P_CAPPED > 0 )); then
    echo
    echo "  (src) = source video bitrate is below ${VIDEO_KBPS} kb/s; encoded at the"
    echo "          source bitrate instead of raising it."
fi

for i in "${!FILES[@]}"; do
    if [[ ! "${EP_VKBPS[$i]}" =~ ^[0-9]+$ ]]; then
        echo
        echo "  Note: source video bitrate unknown for some episodes; fixed bitrate used."
        break
    fi
done

echo
echo "Total runtime:        $TOTAL_HOURS hours"
echo "Files:                ${FILE_COUNT}"
echo
echo "Expected result:"
printf "  Total:              ~%s GiB\n" "$P_TOTAL_GIB"
printf "    Video:            ~%s GiB\n" "$P_VIDEO_GIB"
printf "    Audio:            ~%s GiB\n" "$P_AUDIO_GIB"
echo
printf "  Average per file:   ~%s GiB\n" "$(per_file "$P_TOTAL_GIB")"
printf "    Video:            ~%s GiB\n" "$(per_file "$P_VIDEO_GIB")"
printf "    Audio:            ~%s GiB\n" "$(per_file "$P_AUDIO_GIB")"
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

    if [[ -e "${EP_OUT[$i]}" || -e "${EP_OUT[$i]}.part" ]]; then
        ((EXISTING += 1))
    fi
done

if (( EXISTING > 0 )); then
    echo "$EXISTING of ${FILE_COUNT} outputs already exist in:"
    echo "  $OUT_SERIES"
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
        if [[ -e "${EP_OUT[$i]}.part" ]]; then
            # Possibly being written by another job: never touch it.
            if [[ "$oc" == "3" ]]; then
                EP_SKIP[$i]=1
            else
                EP_OUT[$i]=$(unique_output_path "${EP_OUT[$i]}")
            fi
        elif [[ -e "${EP_OUT[$i]}" ]]; then
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
