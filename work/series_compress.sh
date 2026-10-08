#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/compress"
IN_DIR="$BASE/in"
OUT_DIR="$BASE/out"
WORK_DIR="$BASE/work"

source "$WORK_DIR/lib/ui.sh"
source "$WORK_DIR/lib/media_probe.sh"
source "$WORK_DIR/lib/media_stats.sh"
source "$WORK_DIR/lib/bitrate.sh"
source "$WORK_DIR/lib/encode_common.sh"
source "$WORK_DIR/lib/hdr_dovi.sh"
source "$WORK_DIR/lib/policy.sh"
source "$WORK_DIR/lib/naming.sh"

# ============================================================
# POLICY  (values: ~/compress/work/lib/compress.conf; math: policy.sh
# crf_select / series_crf_spread / series_batch_stats /
# series_episode_crf / series_crf_plan; sample encodes: encode_common.sh
# crf_series_estimate / crf_episode_estimate)
#
# Base / High: x265 CRF, ONE season CRF for every regular episode: the
#              lowest CRF of SERIES_*_CRF_MIN..MAX at which every
#              regular episode's video estimate fits the per-episode
#              SERIES_*_VIDEO_SIZE_CEILING_GIB. An isolated outlier (the
#              only episode above median + SERIES_CRF_OUTLIER_PCT) does
#              not set it; it gets its own higher CRF when it does not
#              fit at the season CRF. Two or more large episodes raise
#              the season CRF instead.
# Custom:      user-entered CRF, used exactly for every episode (no
#              High/Base range or ceiling)
#
# After the encode every episode's actual video is checked on its own
# and only that episode is retried (job_runtime.sh item_crf_encode). An
# episode whose estimate is not below its source video is only
# re-encoded when the user chooses so (or its source video is kept / it
# is skipped).
#
# Every audio track is copied unchanged (codec, bitrate, channels,
# Atmos / DTS:X, titles, flags) and comes on top of the video size;
# audio compression is only done by audio_compress_menu.sh. All
# subtitles are retained.
#
# Output is compact; COMPRESS_VERBOSE=1 shows the detailed policy,
# per-file verification, HDR tool and sampling diagnostics (lib/ui.sh).
# ============================================================

if ! load_policy; then
    exit 1
fi

# runtime files of earlier jobs confirmed finished (encode_common.sh)
cleanup_finished_jobs "$WORK_DIR"

if ui_verbose; then
    echo "Policy: $(policy_conf_path)"
    for t in High Base Custom; do
        echo
        crf_policy_lines series "$t"
    done
    echo
    audio_copy_policy_lines
fi

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

for i in "${!SERIES_DIRS[@]}"; do

    COUNT=$(DISCOVERY_QUIET=1 video_files_in_dir "${SERIES_DIRS[$i]}" | wc -l)

    printf "%d) %s [%s]\n" \
        "$((i+1))" \
        "$(basename "${SERIES_DIRS[$i]}")" \
        "$(ui_plural "$COUNT" episode)"
done

while true; do
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

# short episode ids ("S01E03") for the compact output
mapfile -t EP_LABEL < <(episode_labels "${FILES[@]}")
CRF_SERIES_LABELS=("${EP_LABEL[@]}")
LABEL_W=7
for l in "${EP_LABEL[@]}"; do
    (( ${#l} > LABEL_W )) && LABEL_W=${#l}
done

# file name (verbose) or episode id (compact) of episode I
ep_name() {
    if ui_verbose; then basename "${FILES[$1]}"; else printf '%s' "${EP_LABEL[$1]}"; fi
}

echo
ANALYZE_TEXT="Analyzing $(ui_plural "$FILE_COUNT" episode)... "
if ui_verbose; then
    echo "Analyzing ${FILE_COUNT} files..."
elif (( UI_TTY == 0 )); then
    printf '%s' "$ANALYZE_TEXT"
fi

declare -a EP_DUR EP_VIDX EP_VKBPS EP_VBYTES EP_AKBPS EP_ABYTES EP_ACH EP_ACODEC EP_ASR
declare -a EP_RES EP_VCODEC EP_PIX EP_FPS EP_RANGE EP_SUBS EP_OTHER EP_HOW EP_H10P EP_REFRESH EP_KIND

for i in "${!FILES[@]}"; do
    file="${FILES[$i]}"

    if ui_verbose; then
        printf "  %s\n" "$(basename "$file")"
    else
        ui_progress "$ANALYZE_TEXT$((i + 1))/$FILE_COUNT"
    fi

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
    STATS_PROGRESS=$(ui_verbose && echo 1 || echo 0) STATS_INDENT="      " \
        stats_load "$file" "$dur" estimate refresh

    EP_DUR[$i]="$dur"
    EP_VIDX[$i]="$vidx"
    EP_VKBPS[$i]=$(stats_field "$vidx" kbps)
    EP_HOW[$i]="$STATS_SOURCE"
    EP_KIND[$i]="$STATS_KIND"
    [[ "$STATS_REFRESH" == refreshed ]] && EP_KIND[$i]+=":refreshed"
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

if ui_verbose; then
    echo
    echo "Verifying ${FILE_COUNT} files against $(basename "${FILES[0]}")..."
    echo
fi

describe_list() {
    local s="${1% }"
    [[ -n "$s" ]] && printf '%s' "${s// /, }" || printf 'none'
}

INCOMPATIBLE=0
DIFFERENT=0
VERIFY_DETAILS=()   # compact output: only mismatches / differences

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

    lines=()
    if (( ${#hard[@]} )); then
        lines+=("$(ui_err MISMATCH)  $(basename "${FILES[$i]}")")
        for d in "${hard[@]}"; do lines+=("            - $d"); done
        for d in "${soft[@]+"${soft[@]}"}"; do lines+=("            (also: $d)"); done
        INCOMPATIBLE=1
    elif (( ${#soft[@]} )); then
        lines+=("$(ui_warn "OK*")       $(basename "${FILES[$i]}")")
        for d in "${soft[@]}"; do lines+=("            differs: $d"); done
        DIFFERENT=1
    elif ui_verbose; then
        lines+=("OK        $(basename "${FILES[$i]}")")
    fi

    if ui_verbose; then
        printf '%s\n' "${lines[@]+"${lines[@]}"}"
    else
        VERIFY_DETAILS+=("${lines[@]+"${lines[@]}"}")
    fi
done

# compact: "Analyzing 6 episodes... OK    Source stats: cached    Compatibility: OK"
if ! ui_verbose; then
    ui_progress "$ANALYZE_TEXT"
    printf '%s    Source stats: %s    Compatibility: %s\n' "$(ui_ok OK)" \
        "$(ui_stats_summary "${EP_KIND[@]}")" \
        "$( if (( INCOMPATIBLE == 1 )); then ui_err MISMATCH
            elif (( DIFFERENT == 1 )); then ui_warn "OK*"
            else ui_ok OK; fi)"

    # MKV statistics that could not be refreshed after a scan
    for i in "${!FILES[@]}"; do
        case "${EP_REFRESH[$i]}" in
            ""|refreshed) ;;
            *) printf '  %s %s: %s\n' "$(ui_warn "Stats not refreshed")" "${EP_LABEL[$i]}" \
                   "$(STATS_REFRESH="${EP_REFRESH[$i]}"; stats_refresh_note)" ;;
        esac
    done

    if (( ${#VERIFY_DETAILS[@]} )); then
        echo
        printf '%s\n' "${VERIFY_DETAILS[@]}"
    fi
fi

if (( INCOMPATIBLE == 1 )); then
    echo
    echo "Series settings do not match: resolution, dynamic range or audio"
    echo "layout differ, so one shared encode setting cannot be used."
    echo "Compression cancelled."
    exit 1
fi

if ui_verbose; then
    echo
    if (( DIFFERENT == 1 )); then
        echo "All files compatible. Differences marked OK* do not affect the shared"
        echo "encode settings; every stream of every episode is still kept."
    else
        echo "All files match."
    fi
elif (( DIFFERENT == 1 )); then
    echo "(OK*: differences that do not affect the shared encode settings;"
    echo " every stream of every episode is still kept)"
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
if ui_verbose; then
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
else
    # average source video from the loaded statistics (no rescan):
    # bytes per episode and the runtime-weighted bitrate
    AVG_VIDEO=$(
        for i in "${!FILES[@]}"; do
            printf '%s %s\n' "${EP_VBYTES[$i]:-N/A}" "${EP_DUR[$i]}"
        done | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { b += $1; s += $2; n++ }
            END { if (n && s > 0) printf "%.2f GiB/episode   %.1f Mb/s", b / n / 1073741824, b * 8 / s / 1000000 }'
    )

    printf '%-16s%-18s %s\n' "Series:" "$SERIES_NAME" "Episodes: $FILE_COUNT"
    printf '%-16s%s %s %s\n' "Video:" "${WIDTH}x${HEIGHT}" "${EP_VCODEC[0]^^}" "$(ui_bit_depth "${EP_PIX[0]}")"
    printf '%-16s%s\n' "Dynamic range:" "$(hdr_compact_label)"
    printf '%-16s%s, copied unchanged\n' "Audio:" "$(ui_plural "${#AUDIO_CHANNELS[@]}" track)"
    [[ -n "$AVG_VIDEO" ]] && printf '%-16s%s\n' "Avg video:" "$AVG_VIDEO"
fi

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
    if ui_verbose; then
        echo "1) Keep original  [${WIDTH}x${HEIGHT}]"
        echo "2) Downscale to 1080p"
    else
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
if ui_verbose; then
    crf_tier_load series Base
    echo "1) Base        CRF ${CRF_MIN}-${CRF_MAX}, video ceiling ${CRF_CEILING_GIB} GiB/episode (audio copied unchanged)"
    crf_tier_load series High
    echo "2) High        CRF ${CRF_MIN}-${CRF_MAX}, video ceiling ${CRF_CEILING_GIB} GiB/episode (audio copied unchanged)"
    echo "3) Custom CRF  exactly the CRF you enter, any 0-${CRF_LIMIT} (no range or ceiling; audio copied unchanged)"
else
    crf_tier_load series Base
    printf '1) %-7s CRF %-7s <=%s GiB/episode\n' Base "${CRF_MIN}-${CRF_MAX}" "$CRF_CEILING_GIB"
    crf_tier_load series High
    printf '2) %-7s CRF %-7s <=%s GiB/episode\n' High "${CRF_MIN}-${CRF_MAX}" "$CRF_CEILING_GIB"
    printf '3) %-7s exact CRF (0-%s)\n' Custom "$CRF_LIMIT"
fi

CUSTOM_CRF=""

while true; do
    ui_verbose && echo
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

if ui_verbose; then
    echo
    crf_policy_lines series "$TIER" "$CUSTOM_CRF"
fi

# ============================================================
# CRF ANALYSIS  (policy.sh: crf_select, series_crf_spread,
# series_batch_stats, series_episode_crf; encode_common.sh:
# crf_series_estimate, crf_episode_estimate)
#
# One season CRF for every regular episode: the first CRF (from CRF_MIN
# up) at which every regular episode's estimate fits the per-episode
# ceiling. An isolated outlier (the only episode above median +
# SERIES_CRF_OUTLIER_PCT) does not decide it; it gets its own CRF from
# the season CRF up, sampled itself, if it does not fit at the season
# CRF. Sampled episodes (spread over the batch, plus the longest) are
# encoded at the output resolution.
# ============================================================

mapfile -t CRF_SERIES_SAMPLED < <(series_sample_episodes "$FILE_COUNT" "$SERIES_CRF_SAMPLE_EPISODES" "$(series_longest_episode)")
CRF_SERIES_FILTER="$VIDEO_FILTER"
declare -A CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_EP_EST=()

# crf_series_estimate_shown CRF  (ESTIMATOR: crf_series_estimate, then
# in compact output the result of this CRF right below its samples;
# the same largest-regular-episode-vs-ceiling test crf_select applies)
crf_series_estimate_shown() {
    local c="$1" eb

    crf_series_estimate "$c" || return 1
    ui_verbose && return 0

    read -ra eb <<< "${CRF_SERIES_EP_BYTES[$c]}"
    series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}" || return 0

    echo
    printf '%-10s%s GiB\n' "Median:" "$(bytes_to_gib "$SB_MEDIAN")"
    printf '%-10s%s GiB\n' "Largest:" "$(bytes_to_gib "$SB_DECIDE")"
    if (( CRF_CEILING_BYTES > 0 )); then
        if [[ -n "$SB_ISOLATED" ]]; then
            printf '%-10s%s ~%s GiB (above median +%s%%; does not set the season CRF)\n' "Outlier:" \
                "${EP_LABEL[$SB_ISOLATED]}" "$(bytes_to_gib "${eb[SB_ISOLATED]}")" "$SERIES_CRF_OUTLIER_PCT"
        elif (( ${#SB_OUTLIERS[@]} > 1 )); then
            printf '%-10s%d episodes above median +%s%% (season difficulty)\n' "Large:" \
                "${#SB_OUTLIERS[@]}" "$SERIES_CRF_OUTLIER_PCT"
        fi
        printf '%-10s%s GiB\n' "Ceiling:" "$(bytes_to_gib "$CRF_CEILING_BYTES")"
    fi
    if (( CRF_CEILING_BYTES <= 0 || CRF_EST_RESULT <= CRF_CEILING_BYTES )); then
        printf '%-10s%s\n' "Selected:" "$(ui_bold "CRF $c")"
    elif (( 10#$c < 10#$CRF_MAX )); then
        printf '%-10s%s -> trying CRF %s\n' "Result:" "$(ui_warn "too large")" "$((10#$c + 1))"
    else
        printf '%-10s%s (CRF %s is the %s limit)\n' "Result:" "$(ui_warn "too large")" "$CRF_MAX" "$TIER"
    fi
}

echo
if ui_verbose; then
    printf "Estimating video size from sample encodes (%d of %d episodes, %sx%s output%s):\n" \
        "${#CRF_SERIES_SAMPLED[@]}" "$FILE_COUNT" "$OUT_WIDTH" "$OUT_HEIGHT" \
        "$( (( DOWNSCALED == 1 )) && echo ", downscaled like the final encode")"
else
    printf 'Estimating %s at %sx%s...\n' \
        "$( [[ "$TIER" == "Custom" ]] && echo "CRF $CUSTOM_CRF" || echo "$TIER")" "$OUT_WIDTH" "$OUT_HEIGHT"
fi

if [[ "$TIER" == "Custom" ]]; then
    crf_select_exact "$CUSTOM_CRF" crf_series_estimate_shown || CRF_SELECTED=""
else
    crf_select "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate_shown || CRF_SELECTED=""
fi

if [[ -z "$CRF_SELECTED" ]]; then
    echo
    echo "$(ui_err "CRF analysis failed") (sample encode error above)."
    echo "Compression cancelled."
    exit 1
fi

# season CRF; EP_CRF / EP_EST: each episode's CRF and its estimate there
CRF="$CRF_SELECTED"
read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[$CRF]}"
read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[$CRF]}"
declare -a EP_CRF EP_OVER EP_CEIL_SKIP
for i in "${!FILES[@]}"; do
    EP_CRF[$i]="$CRF"
    EP_OVER[$i]=0
    EP_CEIL_SKIP[$i]=0
done

# season figures at the season CRF (audio is never part of them)
series_batch_stats "$CRF_CEILING_BYTES" "${EP_EST[@]}"
EST_MEDIAN="$SB_MEDIAN"
OUTLIER=""
[[ "$TIER" != "Custom" ]] && OUTLIER="$SB_ISOLATED"

if [[ "$TIER" != "Custom" ]]; then
    for i in "${!FILES[@]}"; do
        [[ "$i" == "$OUTLIER" ]] && continue
        (( EP_EST[i] > CRF_CEILING_BYTES )) && EP_OVER[$i]=1
    done
fi

# ---- season CRF_MAX still above the ceiling (regular episodes)
if (( CRF_OVER_CEILING == 1 )); then
    echo
    echo "------------------------------------------------------------"
    echo "$(ui_warn WARNING): the ${CRF_CEILING_GIB} GiB per-episode video ceiling cannot be met"
    echo "within the allowed ${TIER} quality range: even CRF ${CRF_MAX} (the lowest quality ${TIER}"
    echo "allows) gives a largest regular episode of ~$(bytes_to_gib "${CRF_EST[$CRF]}") GiB video, ~$(crf_oversize_gib "${CRF_EST[$CRF]}" "$CRF_CEILING_BYTES") GiB above the ceiling."
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

# ---- isolated outlier above the ceiling at the season CRF: its own CRF
OUTLIER_SEASON_EST=""
if [[ -n "$OUTLIER" ]] && (( EP_EST[OUTLIER] > CRF_CEILING_BYTES )); then
    OUTLIER_SEASON_EST="${EP_EST[$OUTLIER]}"
    echo
    if ui_verbose; then
        printf 'Isolated outlier: %s (~%s video at CRF %s, above median +%s%%);\n' \
            "$(basename "${FILES[$OUTLIER]}")" "$(size_text "${EP_EST[$OUTLIER]}")" "$CRF" "$SERIES_CRF_OUTLIER_PCT"
        echo "its own CRF from $CRF up (sampled itself):"
    else
        printf 'Outlier %s: ~%s GiB at CRF %s, above the ceiling; own CRF:\n' \
            "${EP_LABEL[$OUTLIER]}" "$(bytes_to_gib "${EP_EST[$OUTLIER]}")" "$CRF"
    fi

    if ! series_episode_crf "$OUTLIER" "$CRF" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_episode_estimate; then
        echo
        echo "$(ui_err "CRF analysis failed") (sample encode error above)."
        echo "Compression cancelled."
        exit 1
    fi

    EP_CRF[$OUTLIER]="$EPC_CRF"
    EP_EST[$OUTLIER]="$EPC_BYTES"
    EP_FROM[$OUTLIER]="sample"
    EP_OVER[$OUTLIER]="$EPC_OVER"

    if (( EPC_OVER == 0 )); then
        printf '%-10s%s CRF %s (~%s GiB); every other episode CRF %s\n' "Outlier:" \
            "$(ep_name "$OUTLIER")" "$EPC_CRF" "$(bytes_to_gib "$EPC_BYTES")" "$CRF"
    fi
fi

# episode_over_ceiling_prompt INDEX  ->  an episode with its own CRF
# still above the ceiling at CRF_MAX: encode anyway / skip it
# (EP_CEIL_SKIP) / cancel
episode_over_ceiling_prompt() {
    local i="$1" oc

    echo
    echo "------------------------------------------------------------"
    echo "$(ui_warn WARNING): $(ep_name "$i") cannot meet the ${CRF_CEILING_GIB} GiB per-episode video ceiling"
    echo "within the allowed ${TIER} quality range: even CRF ${CRF_MAX} (the lowest quality ${TIER}"
    echo "allows) is estimated at ~$(bytes_to_gib "${EP_EST[$i]}") GiB video, ~$(crf_oversize_gib "${EP_EST[$i]}" "$CRF_CEILING_BYTES") GiB above the ceiling."
    echo "------------------------------------------------------------"
    echo "1) Encode it at CRF ${CRF_MAX} anyway"
    echo "2) Skip this episode"
    echo "3) Cancel"

    while true; do
        read -rp "Select [1-3]: " oc
        case "$oc" in
            1) break ;;
            2) EP_CEIL_SKIP[$i]=1; break ;;
            3) echo "Compression cancelled."; exit 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
    return 0
}

# ---- isolated outlier still above the ceiling at CRF_MAX
if [[ -n "$OUTLIER" ]] && (( EP_OVER[OUTLIER] == 1 && CRF_OVER_CEILING == 0 )); then
    episode_over_ceiling_prompt "$OUTLIER"
fi

# final_figures  ->  ABOVE, EST_LARGEST, OWN_CRF at each episode's own CRF
final_figures() {
    local i

    series_batch_stats "$CRF_CEILING_BYTES" "${EP_EST[@]}"
    ABOVE=("${SB_ABOVE[@]+"${SB_ABOVE[@]}"}")
    EST_LARGEST="$SB_LARGEST"

    OWN_CRF=()
    for i in "${!FILES[@]}"; do
        [[ "${EP_CRF[$i]}" != "$CRF" ]] && OWN_CRF+=("$i")
    done
    return 0
}
final_figures

# "S01E05 CRF 20" per episode with its own CRF
own_crf_text() {
    local i out=""
    for i in "${OWN_CRF[@]+"${OWN_CRF[@]}"}"; do
        out+="${out:+, }$(ep_name "$i") CRF ${EP_CRF[$i]}"
    done
    printf '%s' "$out"
}

if ui_verbose; then
    echo
    echo "CRF analysis (video only; copied audio is not part of the choice):"
    series_crf_analysis_lines

    echo
    echo "Selected:"
    if (( ${#OWN_CRF[@]} )); then
        echo "  CRF $CRF for $(( FILE_COUNT - ${#OWN_CRF[@]} )) of ${FILE_COUNT} episodes (season CRF)"
        for i in "${OWN_CRF[@]}"; do
            echo "  CRF ${EP_CRF[$i]} for $(basename "${FILES[$i]}") (isolated outlier, ~$(size_text "$OUTLIER_SEASON_EST") at CRF $CRF)"
        done
    else
        echo "  CRF $CRF for all ${FILE_COUNT} episodes"
    fi
    echo "  median episode video:  ~$(size_text "$EST_MEDIAN")"
    echo "  largest episode video: ~$(size_text "$EST_LARGEST")"
    if [[ "$TIER" != "Custom" ]]; then
        echo "  ceiling:               ${CRF_CEILING_GIB} GiB/episode"
    fi
fi

# Episodes still estimated above the ceiling at their CRF (the ceiling
# cannot be met within the tier's range and encoding anyway was chosen).
# Custom has no ceiling.
if (( ${#ABOVE[@]} )); then
    echo
    if (( ${#ABOVE[@]} == 1 )); then
        echo "$(ui_warn Warning): 1 episode is estimated above the ${CRF_CEILING_GIB} GiB ceiling at CRF ${CRF_MAX}."
    else
        echo "$(ui_warn Warning): ${#ABOVE[@]} episodes are estimated above the ${CRF_CEILING_GIB} GiB ceiling at CRF ${CRF_MAX}."
    fi
    for i in "${ABOVE[@]}"; do
        if ui_verbose; then
            printf "  %-40.40s ~%s GiB video, +%s GiB (%s)%s\n" "$(basename "${FILES[$i]}")" \
                "$(bytes_to_gib "${EP_EST[$i]}")" \
                "$(crf_oversize_gib "${EP_EST[$i]}" "$CRF_CEILING_BYTES")" \
                "$( [[ "${EP_FROM[$i]}" == sample ]] && echo "sampled" || echo "highest sampled bitrate")" \
                "$( (( EP_CEIL_SKIP[$i] == 1 )) && echo "; skipped")"
        else
            printf "  %-*s  ~%s GiB video, +%s GiB (%s)%s\n" "$LABEL_W" "${EP_LABEL[$i]}" \
                "$(bytes_to_gib "${EP_EST[$i]}")" \
                "$(crf_oversize_gib "${EP_EST[$i]}" "$CRF_CEILING_BYTES")" \
                "$( [[ "${EP_FROM[$i]}" == sample ]] && echo "sampled" || echo "highest sampled bitrate")" \
                "$( (( EP_CEIL_SKIP[$i] == 1 )) && echo "; skipped")"
        fi
    done
fi

# ============================================================
# SOURCE-QUALITY GUARD
#
# Episodes whose estimate at their CRF is not below their source
# video: a re-encode would only be lossier. The user keeps the source
# video (stream copy), encodes anyway, or skips those episodes.
# ============================================================

declare -a EP_VIDEO EP_GUARD_SKIP

for i in "${!FILES[@]}"; do
    EP_VIDEO[$i]="crf:${EP_CRF[$i]}"
    EP_GUARD_SKIP[$i]=0
done

# GUARD: episodes not below their source; one that was not sampled is
# sampled itself first (policy.sh series_guard_episodes), so the
# conservative not-sampled estimate alone never asks
if ! series_guard_episodes crf_episode_estimate; then
    echo
    echo "$(ui_err "CRF analysis failed") (sample encode error above)."
    echo "Compression cancelled."
    exit 1
fi

# ---- an own sample taken by the guard above the ceiling: that episode
# alone gets a higher CRF now, before the encode (policy.sh
# series_late_ceiling; the season CRF is not changed), then the guard
# is decided on its estimate at that CRF
if ! series_late_ceiling crf_episode_estimate; then
    echo
    echo "$(ui_err "CRF analysis failed") (sample encode error above)."
    echo "Compression cancelled."
    exit 1
fi

declare -A IS_LATE=()
if (( ${#LATE[@]} )); then
    for i in "${LATE[@]}"; do
        IS_LATE[$i]=1
        EP_VIDEO[$i]="crf:${EP_CRF[$i]}"
        if (( EP_OVER[i] == 0 )); then
            printf '%-10s%s CRF %s (~%s GiB); season CRF %s unchanged\n' "Own CRF:" \
                "$(ep_name "$i")" "${EP_CRF[$i]}" "$(bytes_to_gib "${EP_EST[$i]}")" "$CRF"
        elif (( CRF_OVER_CEILING == 0 )); then
            episode_over_ceiling_prompt "$i"
        fi
    done

    # the guard on the estimates at the final CRFs (a higher CRF can
    # only drop an episode from it); skipped episodes are not asked for
    KEEP=()
    for i in "${GUARD[@]+"${GUARD[@]}"}"; do
        (( EP_CEIL_SKIP[i] == 1 )) && continue
        crf_above_source "${EP_EST[$i]}" "${EP_VBYTES[$i]:-}" && KEEP+=("$i")
    done
    GUARD=("${KEEP[@]+"${KEEP[@]}"}")

    final_figures
fi

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
    echo "their ${TIER} CRF would need (a re-encode would not be smaller, only lossier):"
    for i in "${GUARD[@]}"; do
        printf "  %-40.40s source %s, CRF %s estimate ~%s\n" "$(ep_name "$i")" \
            "$(size_text "${EP_VBYTES[$i]}")" "${EP_CRF[$i]}" "$(size_text "${EP_EST[$i]}")"
    done
    echo "------------------------------------------------------------"

    if (( CAN_COPY == 1 )); then
        echo "1) Keep their source video unchanged (stream copy; audio, subtitles,"
        echo "   chapters and metadata handled as usual)"
    else
        echo "1) (not available: keeping the source video needs HEVC sources,"
        echo "   no downscaling and no dropped Dolby Vision / HDR10+)"
    fi
    echo "2) Encode them anyway at $( (( ${#OWN_CRF[@]} )) && echo "their CRF" || echo "CRF ${CRF}")"
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

if ui_verbose; then
    echo
    echo "------------------------------------------------------------"
    echo "Tier:                 $TIER"
    if [[ "$TIER" == "Custom" ]]; then
        echo "Video encode:         x265 CRF ${CRF}, single pass, every episode (entered CRF)"
    else
        if (( ${#OWN_CRF[@]} )); then
            echo "Video encode:         x265 CRF ${CRF}, single pass, every episode but $(own_crf_text) (own CRF)"
        else
            echo "Video encode:         x265 CRF ${CRF}, single pass, every episode"
        fi
        echo "                      (${TIER}: CRF ${CRF_MIN}-${CRF_MAX}, ${CRF_CEILING_GIB} GiB/episode video ceiling$( (( CRF_OVER_CEILING == 1 || ${#ABOVE[@]} > 0 )) && echo "; ceiling NOT met"))"
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
    echo "  - video: one season CRF (sizes vary with content); only an isolated"
    echo "    outlier above the ceiling gets its own higher CRF; each episode's"
    echo "    actual video is checked against the ceiling after its encode and"
    echo "    only that episode is retried; an episode whose estimate is not"
    echo "    below its source is only re-encoded if you chose so above"
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
        ccol="${EP_CRF[$i]}"
        if (( EP_CEIL_SKIP[$i] == 1 )); then
            ccol="-"; ecol="-"; status="SKIPPED (above the ceiling at CRF ${CRF_MAX})"
        elif (( EP_GUARD_SKIP[$i] == 1 )); then
            ccol="-"; ecol="-"; status="SKIPPED (source-quality guard)"
        elif [[ "${EP_VIDEO[$i]}" == "copy" ]]; then
            ccol="copy"; ecol="source"; status="SOURCE VIDEO KEPT"
        else
            [[ "${EP_FROM[$i]}" == "sample" ]] && ecol="sampled" || ecol="highest"
            if [[ -n "${IS_ABOVE[$i]:-}" ]]; then
                status="ABOVE CEILING"
            elif [[ "${EP_CRF[$i]}" != "$CRF" && -n "${IS_LATE[$i]:-}" ]]; then
                status="OWN CRF: OWN SAMPLE ABOVE CEILING"
            elif [[ "${EP_CRF[$i]}" != "$CRF" ]]; then
                status="OUTLIER: OWN CRF"
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
    echo "  highest = not sampled; highest sampled video bitrate x its runtime"
    if [[ "$TIER" != "Custom" ]]; then
        echo "  OUTLIER: OWN CRF = isolated outlier, above the ceiling at the season CRF ${CRF}"
        (( ${#LATE[@]} )) &&
            echo "  OWN CRF: OWN SAMPLE ABOVE CEILING = not sampled, its own sample (source check) above the ceiling"
        echo "  ABOVE CEILING = video estimate above ${CRF_CEILING_GIB} GiB even at CRF ${CRF_MAX}"
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
    if (( ${#OWN_CRF[@]} )); then
        printf "  Season CRF:                 %s (every episode but %s)\n" "$CRF" "$(own_crf_text)"
    else
        printf "  Shared CRF:                 %s (every episode)\n" "$CRF"
    fi
    printf "  Total runtime:              %s hours (%s min)\n" \
        "$(awk -v s="$P_TOTAL_SECONDS" 'BEGIN { printf "%.2f", s / 3600 }')" \
        "$(awk -v s="$P_TOTAL_SECONDS" 'BEGIN { printf "%.0f", s / 60 }')"
    printf "  Median episode video:       ~%s GiB\n" "$(bytes_to_gib "$EST_MEDIAN")"
    printf "  Largest episode video:      ~%s GiB\n" "$(bytes_to_gib "$EST_LARGEST")"
    if [[ "$TIER" == "Custom" ]]; then
        printf "  Above ceiling:              n/a (Custom has no ceiling)\n"
    else
        printf "  Above ceiling:              %d of %d episode(s) (%s GiB/episode)\n" \
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
    CEIL_SKIPPED=0
    for i in "${!FILES[@]}"; do
        (( EP_GUARD_SKIP[$i] == 1 )) && ((GUARD_SKIPPED += 1))
        (( EP_CEIL_SKIP[$i] == 1 )) && ((CEIL_SKIPPED += 1))
    done
    (( GUARD_SKIPPED > 0 )) &&
        echo "  (totals include the $GUARD_SKIPPED episode(s) skipped by the source-quality guard)"
    (( CEIL_SKIPPED > 0 )) &&
        echo "  (totals include the $CEIL_SKIPPED episode(s) skipped above the ceiling)"
    echo
else
    # ---------------- compact preview
    declare -A IS_ABOVE=() IS_GUARD=()
    for i in "${ABOVE[@]+"${ABOVE[@]}"}"; do IS_ABOVE[$i]=1; done
    for i in "${GUARD[@]+"${GUARD[@]}"}"; do IS_GUARD[$i]=1; done

    # Status column only when an episode is not a plain OK
    STATUS=()
    SHOW_STATUS=0
    for i in "${!FILES[@]}"; do
        if (( EP_CEIL_SKIP[$i] == 1 )); then
            STATUS[$i]=$(ui_warn "SKIPPED (above ceiling)")
        elif (( EP_GUARD_SKIP[$i] == 1 )); then
            STATUS[$i]=$(ui_warn "SKIPPED (source-quality guard)")
        elif [[ "${EP_VIDEO[$i]}" == "copy" ]]; then
            STATUS[$i]="SOURCE VIDEO KEPT"
        elif [[ -n "${IS_ABOVE[$i]:-}" ]]; then
            STATUS[$i]=$(ui_warn "ABOVE CEILING")
        elif [[ "${EP_CRF[$i]}" != "$CRF" && -n "${IS_LATE[$i]:-}" ]]; then
            STATUS[$i]="OWN CRF (own sample)"
        elif [[ "${EP_CRF[$i]}" != "$CRF" ]]; then
            STATUS[$i]="OUTLIER (own CRF)"
        else
            STATUS[$i]=$(ui_ok OK)
        fi
        [[ -n "${IS_GUARD[$i]:-}" && "${EP_VIDEO[$i]}" != "copy" ]] && (( EP_GUARD_SKIP[$i] == 0 )) &&
            STATUS[$i]+=" (not below source)"
        [[ "${STATUS[$i]}" == "$(ui_ok OK)" ]] || SHOW_STATUS=1
    done

    # sizes in GiB; Total padded only when a Status column follows
    ROW_FMT="%-*s   %-7s   %-6s  %-6s  %s%s\n"
    (( SHOW_STATUS == 1 )) && ROW_FMT="%-*s   %-7s   %-6s  %-6s  %-6s%s\n"

    # CRF column only when an episode has its own CRF (isolated outlier)
    vcol() {
        if (( ${#OWN_CRF[@]} )); then printf '%-4s  %-6s' "$1" "$2"; else printf '%s' "$2"; fi
    }

    echo
    echo "Expected sizes:"
    printf "$ROW_FMT" "$LABEL_W" "Episode" "Runtime" "$(vcol CRF Video)" "Audio" "Total" \
        "$( (( SHOW_STATUS == 1 )) && echo "  Status")"
    for i in "${!FILES[@]}"; do
        ccol="${EP_CRF[$i]}"
        (( EP_CEIL_SKIP[$i] == 1 || EP_GUARD_SKIP[$i] == 1 )) && ccol="-"
        [[ "${EP_VIDEO[$i]}" == "copy" ]] && ccol="copy"
        printf "$ROW_FMT" "$LABEL_W" "${EP_LABEL[$i]}" \
            "$(awk -v d="${EP_DUR[$i]}" 'BEGIN { printf "%d:%02d", int(d / 60), int(d % 60) }')" \
            "$(vcol "$ccol" "${P_EP_VGIB[$i]}")" "${P_EP_AGIB[$i]}" "${P_EP_GIB[$i]}" \
            "$( (( SHOW_STATUS == 1 )) && printf '  %s' "${STATUS[$i]}")"
    done

    # stream handling: only what is lost or dropped (COMPRESS_VERBOSE=1
    # lists every note)
    build_stream_map "$REFERENCE" "${EP_VIDX[0]}"
    REF_NOTES=()
    while IFS= read -r note; do
        [[ "$note" =~ LOST|DROPPED|WARNING|cannot|skipped|missing ]] && REF_NOTES+=("$note")
    done < <(printf '%s\n' "${MAP_NOTES[@]+"${MAP_NOTES[@]}"}"; chapter_notes "$REFERENCE")

    if (( ${#REF_NOTES[@]} )); then
        echo
        echo "$(ui_warn "Stream handling") ($(basename "$REFERENCE"); same rules for every episode):"
        printf '  %s\n' "${REF_NOTES[@]}"
    fi

    GUARD_SKIPPED=0
    CEIL_SKIPPED=0
    for i in "${!FILES[@]}"; do
        (( EP_GUARD_SKIP[$i] == 1 )) && ((GUARD_SKIPPED += 1))
        (( EP_CEIL_SKIP[$i] == 1 )) && ((CEIL_SKIPPED += 1))
    done

    echo
    echo "Season:"
    printf '  %-9s~%s GiB\n' "Video:" "$P_VIDEO_GIB" "Audio:" "$P_AUDIO_GIB" "Total:" "$P_TOTAL_GIB"
    printf '  %-9s~%s GiB/episode\n' "Average:" "$(per_file "$P_TOTAL_GIB")"
    (( GUARD_SKIPPED > 0 )) &&
        echo "  (totals include the $GUARD_SKIPPED episode(s) skipped by the source-quality guard)"
    (( CEIL_SKIPPED > 0 )) &&
        echo "  (totals include the $CEIL_SKIPPED episode(s) skipped above the ceiling)"
    echo
fi

# ============================================================
# OUTPUT
# ============================================================

# The output folder has exactly the source folder's name (no resolution /
# codec / tier); the episode file names carry the encode information, so
# High, Base and Custom outputs of one series can share the folder.
OUT_SERIES=$(series_output_dir "$OUT_DIR" "$SERIES_DIR")

if path_taken "$OUT_SERIES" && [[ ! -d "$OUT_SERIES" ]]; then
    echo "Output folder name is taken by something that is not a folder:"
    if [[ -L "$OUT_SERIES" ]]; then
        echo "  $OUT_SERIES -> $(readlink -- "$OUT_SERIES")$( [[ -e "$OUT_SERIES" ]] || echo " (broken symlink)")"
    else
        echo "  $OUT_SERIES"
    fi
    echo "Move or rename it, then run the menu again."
    echo "Compression cancelled."
    exit 1
fi

declare -a EP_OUT EP_OVERWRITE EP_SKIP
EXISTING=0

for i in "${!FILES[@]}"; do
    EP_OUT[$i]=$(series_episode_output "$OUT_SERIES" "${FILES[$i]}" "$TIER" "$DOWNSCALED")

    EP_OVERWRITE[$i]=0
    EP_SKIP[$i]=$(( EP_GUARD_SKIP[i] == 1 || EP_CEIL_SKIP[i] == 1 ))

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

if ui_verbose; then
    read -rp "Start compression of $QUEUED episode(s)? [y/N]: " confirm
else
    # one-line confirmation of the encode settings
    printf '%s | %s%s | %sx%s | %s | audio copied%s\n' "$TIER" "$(ui_bold "CRF $CRF")" \
        "$( (( ${#OWN_CRF[@]} )) && echo " ($(own_crf_text))")" \
        "$OUT_WIDTH" "$OUT_HEIGHT" "$(hdr_policy_short)" \
        "$( (( CRF_OVER_CEILING == 1 || ${#ABOVE[@]} > 0 )) && echo " | $(ui_warn "ceiling not met")")"
    read -rp "Start compression of $(ui_plural "$QUEUED" episode)? [y/N]: " confirm
fi
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

# High / Base: every episode is an item of its own (job_runtime.sh
# item_crf_encode): its ACTUAL video above the per-episode ceiling ->
# only that episode is re-encoded at CRF + 1 (up to CRF_MAX); with
# CRF_DOWN_RETRY_HEADROOM_PCT to spare and CRF - 1 predicted to fit
# (CRF_DOWN_RETRY_FIT_MARGIN_PCT, from its estimates per CRF) that
# episode alone tries CRF - 1, at most SERIES_CRF_DOWN_RETRY_MAX times,
# never below CRF_MIN (an isolated outlier: never below the season CRF).
# Not for Custom, and not for an episode whose estimate at CRF_MAX
# above the ceiling was already accepted.
# ep_retry_spec INDEX  ->  RETRY of emit_encode_item ("" = none)
ep_retry_spec() {
    local i="$1" min="$CRF_MIN"

    [[ "$TIER" == "Custom" ]] && return 0
    (( EP_OVER[i] == 1 )) && return 0
    (( 10#${EP_CRF[i]} > 10#$CRF )) && min="$CRF"
    printf '%s:%s:%s:%s:%s::%s' "$CRF_CEILING_BYTES" "$CRF_MAX" "$min" \
        "$CRF_DOWN_RETRY_HEADROOM_PCT" "$SERIES_CRF_DOWN_RETRY_MAX" "$CRF_DOWN_RETRY_FIT_MARGIN_PCT"
}

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
            "${EP_EST[$i]}" \
            "$(ep_retry_spec "$i")" \
            "" \
            "$(series_est_map "$i")"
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
