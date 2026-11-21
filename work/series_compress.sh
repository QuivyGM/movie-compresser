#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/compress"
IN_DIR="$BASE/in"
OUT_DIR="$BASE/out"
WORK_DIR="$BASE/work"

# in / out / work: real directories or symlinks to directories, used as
# they are (never replaced); missing ones are created (lib/fs_guard.sh)
source "$WORK_DIR/lib/fs_guard.sh"
compress_dirs_init "$BASE" in out:rw work:rw || exit 1

source "$WORK_DIR/lib/ui.sh"
source "$WORK_DIR/lib/media_probe.sh"
source "$WORK_DIR/lib/media_stats.sh"
source "$WORK_DIR/lib/bitrate.sh"
source "$WORK_DIR/lib/encode_common.sh"
source "$WORK_DIR/lib/hdr_dovi.sh"
source "$WORK_DIR/lib/policy.sh"
source "$WORK_DIR/lib/naming.sh"
source "$WORK_DIR/lib/series_seasons.sh"

# ============================================================
# POLICY  (values: ~/compress/work/lib/compress.conf; math: policy.sh
# crf_select / series_crf_spread / series_batch_stats /
# series_episode_crf / series_crf_plan; sample encodes: encode_common.sh
# crf_series_estimate / crf_episode_estimate)
#
# Seasons:     a show folder may hold its episodes directly (flat) or in
#              season folders (Jellyfin layout: "Show/Season 01/...",
#              "Show/Season 00 - Specials/...", any depth; extras folders
#              ignored: media_probe.sh series_season_groups). Every
#              selected season group is an INDEPENDENT season: its own
#              analysis, compatibility check, shared season CRF, ceiling
#              checks, source-quality guard and season retry batch. One
#              CRF is never forced across seasons; Custom uses the
#              entered CRF for every season. Outputs mirror the layout:
#              out/<show>/<season folder>/<episode> HEVC <Tier>.mkv.
#
# Base / High: x265 CRF, ONE shared season CRF for every encoded
#              episode of a season: the lowest CRF of
#              SERIES_*_CRF_SEARCH_MIN..MAX at which every episode's video
#              estimate fits the per-episode
#              SERIES_*_VIDEO_SIZE_CEILING_GIB, searched from
#              SERIES_*_CRF_START up or down (the adjacent boundary:
#              CRF N too large, N + 1 fits). Strictly shared
#              (SERIES_CRF_SHARED=1): an outlier (an episode above
#              median + SERIES_CRF_OUTLIER_PCT) is reported but never
#              gets a CRF of its own; a harder episode raises the season
#              CRF for every episode of that season.
# Custom:      user-entered CRF, used exactly for every episode (no
#              High/Base range or ceiling)
#
# After the encode (job_runtime.sh job_crf_batch, batch_mode=season, one
# batch per season) every episode's ACTUAL video must fit the
# per-episode ceiling: one above it moves the WHOLE season to CRF + 1 (up
# to CRF_MAX); once the season fits, CRF - 1 is tested once for the
# whole season and kept only when every episode fits there. The final
# season is one CRF for every encoded episode. An episode whose estimate
# is not below its source video is only re-encoded when the user chooses
# so (or its source video is kept / it is skipped).
#
# Every audio track is copied unchanged (codec, bitrate, channels,
# Atmos / DTS:X, titles, flags) and comes on top of the video size;
# audio compression is only done by audio_compress_menu.sh. All
# subtitles are retained.
#
# Output is compact (several seasons: one line per season; the episodes
# of a season only when they need attention); COMPRESS_VERBOSE=1 shows
# the detailed policy, per-episode figures (grouped under season
# headers), per-file verification, HDR tool and sampling diagnostics
# (lib/ui.sh).
# ============================================================

if ! load_policy; then
    exit 1
fi

# one shared season CRF: no per-episode / isolated-outlier CRF (policy.sh
# series_crf_shared)
SERIES_CRF_SHARED=1

# runtime files of earlier jobs confirmed finished (encode_common.sh)
cleanup_finished_jobs "$WORK_DIR"

if ui_verbose; then
    echo "Policy: $(policy_conf_path)"
    for t in High Base Compact Custom; do
        echo
        crf_policy_lines series "$t"
    done
    echo
    audio_copy_policy_lines
fi

# ============================================================
# FIND SERIES FOLDERS
# ============================================================

# folders and valid folder symlinks with episodes anywhere below them
# (see discover_paths / series_season_groups)
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
    mapfile -t _groups < <(DISCOVERY_QUIET=1 series_season_groups "${SERIES_DIRS[$i]}")
    COUNT=$(DISCOVERY_QUIET=1 series_episode_count "${SERIES_DIRS[$i]}")

    # flat folder (episodes only in the show folder): "[N episodes]"
    if (( ${#_groups[@]} == 1 )) && [[ "${_groups[0]%/}" == "${SERIES_DIRS[$i]%/}" ]]; then
        printf "%d) %s [%s]\n" "$((i+1))" "$(basename "${SERIES_DIRS[$i]}")" "$(ui_plural "$COUNT" episode)"
    else
        printf "%d) %s [%s, %s]\n" "$((i+1))" "$(basename "${SERIES_DIRS[$i]}")" \
            "$(ui_plural "${#_groups[@]}" season)" "$(ui_plural "$COUNT" episode)"
    fi
done
unset _groups

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

# ============================================================
# SEASONS
#
# Season groups of the show (series_season_groups: specials first, then
# natural order). One group: no question (flat folders as before).
# ============================================================

mapfile -t GROUP_DIRS < <(series_season_groups "$SERIES_DIR")

if (( ${#GROUP_DIRS[@]} == 0 )); then
    echo
    echo "No episodes found in: $SERIES_DIR"
    exit 1
fi

declare -a GROUP_NAMES GROUP_EPS
for g in "${!GROUP_DIRS[@]}"; do
    GROUP_NAMES[$g]=$(series_group_name "$SERIES_DIR" "${GROUP_DIRS[$g]}")
    GROUP_EPS[$g]=$(DISCOVERY_QUIET=1 video_files_in_dir "${GROUP_DIRS[$g]}" | grep -c .)
done

# SEASON_KEYS: the selected groups (indexes into GROUP_*), in season order
SEASON_KEYS=()

if (( ${#GROUP_DIRS[@]} == 1 )); then
    SEASON_KEYS=(0)
else
    echo
    echo "Seasons:"
    printf '1) All seasons  (%s, %s)\n' "$(ui_plural "${#GROUP_DIRS[@]}" season)" \
        "$(ui_plural "$(bytes_sum "${GROUP_EPS[@]}")" episode)"
    echo "2) Select seasons"

    while true; do
        read -rp "Select [1-2]: " sc
        case "$sc" in
            1|2) break ;;
            *) echo "Invalid selection." ;;
        esac
    done

    if [[ "$sc" == 1 ]]; then
        SEASON_KEYS=("${!GROUP_DIRS[@]}")
    else
        echo
        GW=6
        for g in "${!GROUP_NAMES[@]}"; do
            (( ${#GROUP_NAMES[$g]} > GW )) && GW=${#GROUP_NAMES[$g]}
        done
        for g in "${!GROUP_DIRS[@]}"; do
            printf '%2d) %-*s  %s\n' "$((g + 1))" "$GW" "${GROUP_NAMES[$g]}" "$(ui_plural "${GROUP_EPS[$g]}" episode)"
        done
        while true; do
            read -rp "Seasons (e.g. 1,3,5-7): " sel
            if mapfile -t _sel < <(season_parse_selection "$sel" "${#GROUP_DIRS[@]}") && (( ${#_sel[@]} )); then
                break
            fi
            echo "Invalid selection: enter season numbers 1-${#GROUP_DIRS[@]} and ranges, e.g. 1,3,5-7"
        done
        for g in "${_sel[@]}"; do
            SEASON_KEYS+=("$((g - 1))")
        done
        unset _sel
    fi
fi

# several seasons: one line per season (compact); verbose keeps the
# per-episode detail under season headers; one season: as before
MULTI=0
(( ${#SEASON_KEYS[@]} > 1 )) && MULTI=1
SUMMARY=0
(( MULTI == 1 )) && ! ui_verbose && SUMMARY=1

# season_name KEY  /  season_rel KEY  ->  "Season 01" / its out/ sub path
season_name() { printf '%s' "${GROUP_NAMES[$1]}"; }
season_rel()   { series_group_rel "${GROUP_NAMES[$1]}"; }

# season_header KEY  ->  "---- Season 01 ----" (several seasons only)
season_header() {
    (( MULTI == 1 )) || return 0
    echo
    echo "---- $(ui_bold "$(season_name "$1")") ----"
}

# ACTIVE: the seasons still in the selection (excluded ones are removed)
ACTIVE=("${SEASON_KEYS[@]}")
declare -A EXCLUDED=()

# season_exclude KEY REASON  ->  the season is left out (reported in the
# summary); single season: compression cancelled (exit 1)
season_exclude() {
    local k="$1" a keep=()
    if (( MULTI == 0 )); then
        echo "Compression cancelled."
        exit 1
    fi
    EXCLUDED[$k]="$2"
    for a in "${ACTIVE[@]}"; do
        [[ "$a" == "$k" ]] || keep+=("$a")
    done
    ACTIVE=("${keep[@]+"${keep[@]}"}")
}

# continue_or_cancel EXCLUDED_BEFORE  ->  after seasons were excluded in
# the step just done: continue with the remaining ones or cancel. Nothing
# left: cancelled.
continue_or_cancel() {
    local before="$1" c
    (( ${#EXCLUDED[@]} > before )) || return 0
    if (( ${#ACTIVE[@]} == 0 )); then
        echo
        echo "No season left to compress."
        echo "Compression cancelled."
        exit 1
    fi
    echo
    echo "1) Continue with the remaining $(ui_plural "${#ACTIVE[@]}" season) ($(season_list "${ACTIVE[@]}"))"
    echo "2) Cancel"
    while true; do
        read -rp "Select [1-2]: " c
        case "$c" in
            1) return 0 ;;
            2) echo "Compression cancelled."; exit 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# season_list KEY...  ->  "Season 01, Season 02, ..." (shortened)
season_list() {
    local k out=() n=0
    for k in "$@"; do
        ((n += 1))
        if (( n > 6 )); then
            out+=("... $(( $# - 6 )) more")
            break
        fi
        out+=("$(season_name "$k")")
    done
    local IFS=,
    local s="${out[*]}"
    printf '%s' "${s//,/, }"
}

# log of the hidden per-season output (compact multi-season mode: sample
# lines of the CRF search); shown when something fails
SEASON_LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/series-menu.XXXXXX")
trap 'rm -rf -- "$SEASON_LOG_DIR"' EXIT

# show_log_tail FILE  ->  the end of a hidden season log (after a failure)
show_log_tail() {
    [[ -s "$1" ]] || return 0
    echo "  (last lines of the season log:)"
    tail -n 12 -- "$1" | sed 's/\r.*\r//; s/^/    /'
}

# ============================================================
# ANALYZE EPISODES
#
# Per episode: duration, main video stream, source bitrates per
# stream (media_stats.sh stats_load: valid stored MKV statistics tags,
# stream bit rates for non-MKV, or a packet scan), dynamic range.
# One season at a time (season_analyze); its state is kept per season
# (series_seasons.sh season_state_save / season_state_load).
# ============================================================

# file name (verbose) or episode id (compact) of episode I
ep_name() {
    if ui_verbose; then basename "${FILES[$1]}"; else printf '%s' "${EP_LABEL[$1]}"; fi
}

# season_analyze KEY  ->  analysis + compatibility check of one season
# into the season globals (season_state_reset first). ANALYZE_FAIL: why
# the season cannot be used ("" = fine). Output: verbose / single season
# as before; compact multi-season: a progress line only.
season_analyze() {
    local k="$1" i file info vidx dur analyze_text

    season_state_reset
    SEASON_LOG="$SEASON_LOG_DIR/season-$k.log"

    mapfile -t FILES < <(video_files_in_dir "${GROUP_DIRS[$k]}")
    FILE_COUNT=${#FILES[@]}

    # short episode ids ("S01E03") for the compact output
    mapfile -t EP_LABEL < <(episode_labels "${FILES[@]}")
    CRF_SERIES_LABELS=("${EP_LABEL[@]}")
    LABEL_W=7
    for l in "${EP_LABEL[@]}"; do
        (( ${#l} > LABEL_W )) && LABEL_W=${#l}
    done

    if (( SUMMARY == 1 )); then
        analyze_text="Analyzing $(season_name "$k") ($(ui_plural "$FILE_COUNT" episode))... "
    else
        echo
        analyze_text="Analyzing $(ui_plural "$FILE_COUNT" episode)... "
        if ui_verbose; then
            echo "Analyzing ${FILE_COUNT} files..."
        elif (( UI_TTY == 0 )); then
            printf '%s' "$analyze_text"
        fi
    fi

    for i in "${!FILES[@]}"; do
        file="${FILES[$i]}"

        if ui_verbose; then
            printf "  %s\n" "$(basename "$file")"
        else
            ui_progress "$analyze_text$((i + 1))/$FILE_COUNT"
        fi

        info=$(stream_info "$file")
        vidx=$(awk -F'\t' '$2 == "video" && $4 == 0 { print $1; exit }' <<< "$info")

        if [[ -z "$vidx" ]]; then
            ANALYZE_FAIL="no video stream in $(basename "$file")"
            if (( MULTI == 0 )); then
                echo
                echo "No video stream in: $(basename "$file")"
                echo "Compression cancelled."
                exit 1
            fi
            return 0
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

    # VERIFY COMPATIBILITY (series_seasons.sh season_compat_check):
    # resolution, dynamic range and audio channels must match within the
    # season; other differences are only reported
    season_compat_check

    # COMMON SOURCE INFO of the season
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

    VIDEO_FILTER=""
    OUT_WIDTH="$WIDTH"
    OUT_HEIGHT="$HEIGHT"
    DOWNSCALED=0
    return 0
}

# season_analysis_report KEY  ->  verbose / single season: the analysis
# and compatibility output of before (compact: "Analyzing 6 episodes...
# OK    Source stats: cached    Compatibility: OK", the episodes that
# differ); incompatible: the cancel / exclusion message
season_analysis_report() {
    local k="$1" i

    if [[ -n "$ANALYZE_FAIL" ]]; then
        echo
        echo "$(ui_err "$(season_name "$k")"): ${ANALYZE_FAIL}: excluded."
        return 0
    fi

    if ui_verbose; then
        echo
        echo "Verifying ${FILE_COUNT} files against $(basename "${FILES[0]}")..."
        echo
        printf '%s\n' "${VERIFY_ALL[@]+"${VERIFY_ALL[@]}"}"
    else
        ui_progress "Analyzing $(ui_plural "$FILE_COUNT" episode)... "
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
        (( MULTI == 1 )) && echo "$(season_name "$k") is excluded."
        return 0
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
}

# season_range_short  ->  "SDR", "HDR10", "HDR10+DV8.1", "HDR10+" (the
# loaded season's reference; table column)
season_range_short() {
    local d="$HDR_KIND"
    (( HDR_HDR10PLUS == 1 )) && d+="+"
    (( HDR_DV == 1 )) && d+="+DV${HDR_DV_PROFILE:-?}${HDR_DV_COMPAT:+.$HDR_DV_COMPAT}"
    printf '%s' "$d"
}

# summary_analysis_table  ->  compact multi-season analysis: one line per
# season, then only the episodes that need attention, per season
summary_analysis_table() {
    local k w=16 any_diff=0 compat stats video
    local -a probs

    for k in "${SEASON_KEYS[@]}"; do
        (( ${#GROUP_NAMES[$k]} > w )) && w=${#GROUP_NAMES[$k]}
    done

    ui_progress ""
    echo
    printf '%-*s  %4s  %-15s %-12s %-14s %s\n' "$w" "Season" "Eps" "Video" "Range" "Stats" "Compat"
    for k in "${SEASON_KEYS[@]}"; do
        season_state_load "$k"
        if [[ -n "$ANALYZE_FAIL" ]]; then
            printf '%-*s  %4s  %-15s %-12s %-14s %s\n' "$w" "$(season_name "$k")" "$FILE_COUNT" "-" "-" "-" "$(ui_err "NO VIDEO")"
            continue
        fi
        if (( INCOMPATIBLE == 1 )); then
            compat=$(ui_err MISMATCH)
        elif (( DIFFERENT == 1 )); then
            compat=$(ui_warn "OK*")
            any_diff=1
        else
            compat=$(ui_ok OK)
        fi
        stats=$(UI_GREEN="" UI_RESET="" ui_stats_summary "${EP_KIND[@]}")
        video="${WIDTH}x${HEIGHT} ${EP_VCODEC[0]^^}"
        printf '%-*s  %4s  %-15s %-12s %-14s %s\n' "$w" "$(season_name "$k")" "$FILE_COUNT" \
            "$video" "$(season_range_short)" "$stats" "$compat"
    done

    # episodes that need attention
    for k in "${SEASON_KEYS[@]}"; do
        season_state_load "$k"
        probs=()
        if [[ -n "$ANALYZE_FAIL" ]]; then
            probs+=("$(ui_err "Excluded"): $ANALYZE_FAIL")
        else
            for i in "${!FILES[@]}"; do
                case "${EP_REFRESH[$i]}" in
                    ""|refreshed) ;;
                    *) probs+=("$(ui_warn "Stats not refreshed") ${EP_LABEL[$i]}: $(STATS_REFRESH="${EP_REFRESH[$i]}"; stats_refresh_note)") ;;
                esac
            done
            probs+=("${VERIFY_DETAILS[@]+"${VERIFY_DETAILS[@]}"}")
            (( INCOMPATIBLE == 1 )) &&
                probs+=("$(ui_err "Excluded"): resolution, dynamic range or audio layout differ (one shared season CRF cannot be used)")
        fi
        (( ${#probs[@]} )) || continue
        echo
        echo "$(season_name "$k"):"
        printf '  %s\n' "${probs[@]}"
    done

    if (( any_diff == 1 )); then
        echo
        echo "(OK*: differences that do not affect the shared encode settings;"
        echo " every stream of every episode is still kept)"
    fi
}

for k in "${SEASON_KEYS[@]}"; do
    if (( MULTI == 1 )) && ui_verbose; then
        season_header "$k"
    fi
    season_analyze "$k"
    season_state_save "$k"
    if (( SUMMARY == 0 )); then
        season_analysis_report "$k"
    fi
done

(( SUMMARY == 1 )) && summary_analysis_table

# ---- seasons that cannot be compressed: excluded (never the others)
EXCL_BEFORE=${#EXCLUDED[@]}
for k in "${SEASON_KEYS[@]}"; do
    season_state_load "$k"
    if [[ -n "$ANALYZE_FAIL" ]]; then
        season_exclude "$k" "$ANALYZE_FAIL"
    elif (( INCOMPATIBLE == 1 )); then
        season_exclude "$k" "resolution, dynamic range or audio layout differ"
    fi
done
continue_or_cancel "$EXCL_BEFORE"

# ---- episode labels unique across the selected seasons: when two
# seasons would show the same label (file-name fallbacks, "E01" in every
# season), every label gets its season ("S01/E01")
if (( ${#ACTIVE[@]} > 1 )); then
    LABEL_LISTS=()
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        LABEL_LISTS+=("$(printf '%s\n' "${EP_LABEL[@]}")")
    done
    if labels_collide "${LABEL_LISTS[@]}"; then
        for k in "${ACTIVE[@]}"; do
            season_state_load "$k"
            for i in "${!EP_LABEL[@]}"; do
                EP_LABEL[$i]="$(season_short_label "$(season_name "$k")")/${EP_LABEL[$i]}"
                (( ${#EP_LABEL[$i]} > LABEL_W )) && LABEL_W=${#EP_LABEL[$i]}
            done
            CRF_SERIES_LABELS=("${EP_LABEL[@]}")
            season_state_save "$k"
        done
    fi
    unset LABEL_LISTS
fi

# ---- common source info
echo
if (( SUMMARY == 1 )); then
    TOTAL_EPS=0
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        TOTAL_EPS=$(( TOTAL_EPS + FILE_COUNT ))
    done
    printf '%-16s%-18s %s\n' "Series:" "$SERIES_NAME" "Seasons: ${#ACTIVE[@]}   Episodes: $TOTAL_EPS"
    printf '%-16s%s, copied unchanged\n' "Audio:" "every track"
else
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        (( MULTI == 1 )) && season_header "$k"
        if ui_verbose; then
            echo "------------------------------------------------------------"
            echo "Series:        $SERIES_NAME$( (( MULTI == 1 )) && echo " / $(season_name "$k")")"
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
    done
fi

# ============================================================
# DYNAMIC RANGE  (hdr_dovi.sh confirm_dynamic_range)
#
# Asked once when every season has the same dynamic range (Dolby Vision
# profile, HDR10+), otherwise per season; a season whose source should
# be skipped is excluded.
# ============================================================

# season_range_sig  ->  what the Dolby Vision / HDR10+ decisions depend on
season_range_sig() {
    printf '%s|%s|%s|%s' "$HDR_KIND" "$HDR_HDR10PLUS" "$HDR_DV" "${HDR_DV_PROFILE:-}.${HDR_DV_COMPAT:-}"
}

RANGE_SIGS=()
for k in "${ACTIVE[@]}"; do
    season_state_load "$k"
    RANGE_SIGS+=("$(season_range_sig)")
done
RANGE_SHARED=0
[[ $(printf '%s\n' "${RANGE_SIGS[@]}" | sort -u | grep -c .) == 1 ]] && RANGE_SHARED=1

if (( RANGE_SHARED == 1 )); then
    season_state_load "${ACTIVE[0]}"
    if ! confirm_dynamic_range "this series" "$REFERENCE" "${EP_VIDX[0]}"; then
        echo "Compression cancelled."
        exit 0
    fi
    # one decision for every season (same dynamic range)
    RANGE_POLICY=$(declare -p DV_POLICY DV_MODE DV_EL_TYPE DV_EL_DISCARD HDR10P_POLICY \
        DV_SUPPORTED DV_OUT DV_BASE_OK DV_WHY 2>/dev/null | sed -E 's/^declare -- /declare -g /')
    season_state_save "${ACTIVE[0]}"
    for k in "${ACTIVE[@]:1}"; do
        season_state_load "$k"
        eval "$RANGE_POLICY"
        season_state_save "$k"
    done
else
    EXCL_BEFORE=${#EXCLUDED[@]}
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        (( HDR_DV == 1 || HDR_HDR10PLUS == 1 )) || ui_verbose || continue
        season_header "$k"
        if ! confirm_dynamic_range "$(season_name "$k")" "$REFERENCE" "${EP_VIDX[0]}"; then
            echo "$(season_name "$k") skipped."
            season_exclude "$k" "dynamic range: skipped"
            continue
        fi
        season_state_save "$k"
    done
    continue_or_cancel "$EXCL_BEFORE"
fi

# ============================================================
# RESOLUTION  (asked once; applies to the seasons above 1080p)
# ============================================================

UHD_KEYS=()
UHD_RES=()
for k in "${ACTIVE[@]}"; do
    season_state_load "$k"
    if (( WIDTH > 1920 || HEIGHT > 1080 )); then
        UHD_KEYS+=("$k")
        UHD_RES+=("${WIDTH}x${HEIGHT}")
    fi
done

if (( ${#UHD_KEYS[@]} )); then
    season_state_load "${UHD_KEYS[0]}"
    UHD_ONE=0
    [[ $(printf '%s\n' "${UHD_RES[@]}" | sort -u | grep -c .) == 1 ]] && UHD_ONE=1

    echo
    echo "Output resolution:"
    if (( UHD_ONE == 0 )); then
        printf '1) %-9s %s\n' "Original" "$(printf '%s\n' "${UHD_RES[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
        printf '2) %-9s %s\n' "1080p" "downscaled"
    elif ui_verbose; then
        echo "1) Keep original  [${WIDTH}x${HEIGHT}]"
        echo "2) Downscale to 1080p"
    else
        printf '1) %-9s %s\n' "Original" "${WIDTH}x${HEIGHT}"
        printf '2) %-9s %s\n' "1080p" "$(downscale_1080p_dims "$WIDTH" "$HEIGHT" | tr ' ' x)"
    fi
    if (( MULTI == 1 && ${#UHD_KEYS[@]} < ${#ACTIVE[@]} )); then
        echo "   (applies to $(season_list "${UHD_KEYS[@]}"); the other seasons are 1080p or less)"
    fi

    while true; do
        read -rp "Select [1-2]: " r

        case "$r" in
            1)
                break
                ;;
            2)
                for k in "${UHD_KEYS[@]}"; do
                    season_state_load "$k"
                    DOWNSCALED=1
                    VIDEO_FILTER="$DOWNSCALE_1080P_FILTER"
                    read -r OUT_WIDTH OUT_HEIGHT <<< "$(downscale_1080p_dims "$WIDTH" "$HEIGHT")"
                    season_state_save "$k"
                done
                break
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
fi

# ============================================================
# TIER  (asked once for every season)
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
    crf_tier_load series Compact
    echo "4) Compact     CRF ${CRF_MIN}-${CRF_MAX}, video ceiling ${CRF_GIB_PER_HOUR} GiB/hour of each episode's runtime (audio copied unchanged)"
else
    crf_tier_load series Base
    printf '1) %-7s CRF %-7s <=%s GiB/episode\n' Base "${CRF_MIN}-${CRF_MAX}" "$CRF_CEILING_GIB"
    crf_tier_load series High
    printf '2) %-7s CRF %-7s <=%s GiB/episode\n' High "${CRF_MIN}-${CRF_MAX}" "$CRF_CEILING_GIB"
    printf '3) %-7s exact CRF (0-%s)\n' Custom "$CRF_LIMIT"
    crf_tier_load series Compact
    printf '4) %-7s CRF %-7s <=%s GiB/h\n' Compact "${CRF_MIN}-${CRF_MAX}" "$CRF_GIB_PER_HOUR"
fi
(( MULTI == 1 )) && echo "   (every season gets its own shared season CRF)"

CUSTOM_CRF=""

# Compact is 4 (after Custom) so the existing selections 1-3 keep their
# meaning
while true; do
    ui_verbose && echo
    read -rp "Select [1-4]: " t

    case "$t" in
        1) TIER="Base"; break ;;
        2) TIER="High"; break ;;
        4) TIER="Compact"; break ;;
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

# Dolby Vision profile 7: the profile 8.1 conversion discards the
# enhancement layer; asked or not depending on the tier and its type in
# the first episode (hdr_dovi.sh dv_el_policy). Every episode is checked
# again by its job. Once for every season when they share the dynamic
# range, otherwise per season.
if (( RANGE_SHARED == 1 )); then
    season_state_load "${ACTIVE[0]}"
    if ! dv_el_policy "$TIER" "this series"; then
        echo "Compression cancelled."
        exit 0
    fi
    EL_DISCARD="$DV_EL_DISCARD"
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        DV_EL_DISCARD="$EL_DISCARD"
        season_state_save "$k"
    done
else
    EXCL_BEFORE=${#EXCLUDED[@]}
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        if ! dv_el_policy "$TIER" "$(season_name "$k")"; then
            echo "$(season_name "$k") skipped."
            season_exclude "$k" "Dolby Vision enhancement layer: skipped"
            continue
        fi
        season_state_save "$k"
    done
    continue_or_cancel "$EXCL_BEFORE"
fi

# ceil_phrase  ->  "the 5 GiB ceiling" | "the 0.40 GiB/h ceiling" (warnings)
ceil_phrase() {
    if (( ${#SERIES_EP_CEIL[@]} )); then
        printf 'the %s GiB/h ceiling' "$CRF_GIB_PER_HOUR"
    else
        printf 'the %s GiB ceiling' "$CRF_CEILING_GIB"
    fi
}

if ui_verbose; then
    echo
    crf_policy_lines series "$TIER" "$CUSTOM_CRF"
fi

# ============================================================
# CRF ANALYSIS  (policy.sh: crf_select, series_crf_spread,
# series_batch_stats, series_episode_crf; encode_common.sh:
# crf_series_estimate, crf_episode_estimate)
#
# Per season (season_crf): one shared season CRF for every episode of
# that season: the lowest CRF of CRF_MIN..CRF_MAX at which every
# episode's estimate fits the per-episode ceiling, searched from
# CRF_START (crf_select_boundary).
# CRF_START too large: upward (bracket-and-refine: +1 / +2 steps, a
# skipped CRF is sampled unless the own samples of sampled episodes at
# the next CRF prove it cannot fit, series_crf_certify_over); CRF_START
# fits: downward one CRF at a time until the CRF below is too large or
# CRF_MIN is reached. The CRF just below the season CRF is always
# sampled above the ceiling (unless the season CRF is CRF_MIN). An
# episode that was not sampled never makes a CRF too large on its
# estimate alone: when it decides, it is sampled itself at that CRF
# first (crf_series_estimate, series_decisive_inferred). Every episode
# decides, an outlier (above median + SERIES_CRF_OUTLIER_PCT) too: it
# raises the shared season CRF, it never gets a CRF of its own
# (SERIES_CRF_SHARED). Sampled episodes (spread over the batch, plus the
# longest) are encoded at the output resolution.
# ============================================================

# crf_series_estimate_shown CRF  (ESTIMATOR: crf_series_estimate, then
# in compact output the figures of this CRF right below its samples;
# its result line comes from crf_series_step_report)
crf_series_estimate_shown() {
    local c="$1" eb ef

    crf_series_estimate "$c" || return 1
    ui_verbose && return 0

    read -ra eb <<< "${CRF_SERIES_EP_BYTES[$c]}"
    read -ra ef <<< "${CRF_SERIES_EP_FROM[$c]}"
    series_batch_stats "$CRF_CEILING_BYTES" "${eb[@]}" || return 0

    echo
    printf '%-10s%s GiB\n' "Median:" "$(bytes_to_gib "$SB_MEDIAN")"
    if (( ${#SERIES_EP_CEIL[@]} )); then
        # Compact: the episode with the least room under its own ceiling
        printf '%-10s%s GiB / %s GiB (%s, %s)\n' "Decisive:" "$(bytes_to_gib "$SB_DECIDE_BYTES")" \
            "$(bytes_to_gib "$(series_ep_ceil "$SB_DECIDE_IDX")")" \
            "${EP_LABEL[$SB_DECIDE_IDX]}" "$(series_from_text "${ef[SB_DECIDE_IDX]}")"
    else
        printf '%-10s%s GiB (%s, %s)\n' "Largest:" "$(bytes_to_gib "$SB_DECIDE")" \
            "${EP_LABEL[$SB_DECIDE_IDX]}" "$(series_from_text "${ef[SB_DECIDE_IDX]}")"
    fi
    if (( CRF_CEILING_BYTES > 0 )); then
        if [[ -n "$SB_ISOLATED" ]]; then
            printf '%-10s%s ~%s GiB (above median +%s%%; must fit the shared season CRF)\n' "Outlier:" \
                "${EP_LABEL[$SB_ISOLATED]}" "$(bytes_to_gib "${eb[SB_ISOLATED]}")" "$SERIES_CRF_OUTLIER_PCT"
        elif (( ${#SB_OUTLIERS[@]} > 1 )); then
            printf '%-10s%d episodes above median +%s%% (season difficulty)\n' "Large:" \
                "${#SB_OUTLIERS[@]}" "$SERIES_CRF_OUTLIER_PCT"
        fi
        if (( ${#SERIES_EP_CEIL[@]} )); then
            printf '%-10s%s GiB/h x each episode'"'"'s runtime (%d above)\n' "Ceiling:" "$CRF_GIB_PER_HOUR" "${#SB_ABOVE[@]}"
        else
            printf '%-10s%s GiB\n' "Ceiling:" "$(bytes_to_gib "$CRF_CEILING_BYTES")"
        fi
    fi
}

# crf_series_step_report KIND CRF [ARG]  (REPORT for crf_select_boundary:
# policy.sh crf_search_boundary / crf_search_up)  ->  compact: the result
# of each season CRF right below its figures ("too large -> jumping to
# CRF 14", "fits -> checking CRF 13", "fits -> trying CRF 9"), then the
# verified boundary and "Selected: CRF 14"; verbose: only the steps that
# skip a CRF, check a skipped one or go below CRF_START
crf_series_step_report() {
    if ui_verbose; then
        crf_title_step_report "$@"
        return 0
    fi
    case "$1" in
        fits)
            printf '%-10s%s\n' "Selected:" "$(ui_bold "CRF $2")"
            ;;
        boundary)
            echo
            crf_boundary_lines "$2" "$3"
            printf '%-10s%s\n' "Selected:" "$(ui_bold "CRF $3")"
            ;;
        floor)
            printf '%-10s%s\n' "Result:" "$(crf_step_result "$@")"
            printf '%-10s%s\n' "Selected:" "$(ui_bold "CRF $2")"
            ;;
        *)
            printf '%-10s%s\n' "Result:" "$(crf_step_result "$@")"
            ;;
    esac
}

# hidden STEP...  ->  runs STEP; compact multi-season output: its lines
# (sample encodes, CRF steps) go to the season log instead (shown when
# something fails)
hidden() {
    if (( SUMMARY == 1 )); then
        "$@" >> "$SEASON_LOG"
    else
        "$@"
    fi
}

# episode_over_ceiling_prompt INDEX  ->  an episode whose own sample is
# still above the ceiling at CRF_MAX (series_late_ceiling): encode the
# season at CRF_MAX anyway / skip it (EP_CEIL_SKIP) / cancel
episode_over_ceiling_prompt() {
    local i="$1" oc

    echo
    echo "------------------------------------------------------------"
    if (( ${#SERIES_EP_CEIL[@]} )); then
        echo "$(ui_warn WARNING): $(ep_name "$i") cannot meet its $(bytes_to_gib "$(series_ep_ceil "$i")") GiB video ceiling (${CRF_GIB_PER_HOUR} GiB/h)"
    else
        echo "$(ui_warn WARNING): $(ep_name "$i") cannot meet the ${CRF_CEILING_GIB} GiB per-episode video ceiling"
    fi
    echo "within the allowed ${TIER} quality range: even CRF ${CRF_MAX} (the lowest quality ${TIER}"
    echo "allows) is estimated at ~$(bytes_to_gib "${EP_EST[$i]}") GiB video, ~$(crf_oversize_gib "${EP_EST[$i]}" "$(series_ep_ceil "$i")") GiB above the ceiling."
    echo "------------------------------------------------------------"
    echo "1) Encode it anyway (the whole season at CRF ${CRF_MAX})"
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

# final_figures  ->  ABOVE, EST_LARGEST at the shared season CRF
final_figures() {
    series_batch_stats "$CRF_CEILING_BYTES" "${EP_EST[@]}"
    ABOVE=("${SB_ABOVE[@]+"${SB_ABOVE[@]}"}")
    EST_LARGEST="$SB_LARGEST"
    return 0
}

# season_raise CRF  ->  the shared season CRF becomes CRF for every
# episode: their estimates at CRF from the season estimator (sampled now
# when CRF was not estimated yet), an episode's own sample at CRF
# (CRF_EP_EST) taking precedence. Returns 1 when a sample encode failed.
season_raise() {
    local c="$1" i
    local -a eb ef

    if [[ -z "${CRF_SERIES_EP_BYTES[$c]:-}" ]]; then
        crf_series_estimate_shown "$c" || return 1
        CRF_EST[$c]="$CRF_EST_RESULT"
        CRF_TRIED+=("$c")
    fi
    read -ra eb <<< "${CRF_SERIES_EP_BYTES[$c]}"
    read -ra ef <<< "${CRF_SERIES_EP_FROM[$c]}"

    CRF="$c"
    for i in "${!FILES[@]}"; do
        EP_CRF[$i]="$c"
        EP_EST[$i]="${eb[i]}"
        EP_FROM[$i]="${ef[i]}"
        if [[ "${CRF_EP_EST[$i:$c]:-}" =~ ^[0-9]+$ ]]; then
            EP_EST[$i]="${CRF_EP_EST[$i:$c]}"
            EP_FROM[$i]="sample"
        fi
        EP_OVER[$i]=0
        (( EP_EST[i] > $(series_ep_ceil "$i") )) && EP_OVER[$i]=1
        [[ "${EP_VIDEO[$i]}" == crf:* ]] && EP_VIDEO[$i]="crf:$c"
    done

    series_batch_stats "$CRF_CEILING_BYTES" "${EP_EST[@]}"
    EST_MEDIAN="$SB_MEDIAN"
}

# season_crf_failed KEY  ->  the CRF analysis of the season failed
# (sample encode error): single season cancelled, otherwise excluded
season_crf_failed() {
    ui_progress ""
    echo
    echo "$(ui_err "CRF analysis failed")$( (( MULTI == 1 )) && echo " for $(season_name "$1")") (sample encode error above)."
    (( SUMMARY == 1 )) && show_log_tail "$SEASON_LOG"
    (( MULTI == 1 )) && echo "$(season_name "$1") is excluded."
    season_exclude "$1" "CRF analysis failed"
}

# SEASON_HDR_SHOWN: the season header was printed in this step (prompts
# of a season appear under its name)
SEASON_HDR_SHOWN=""
season_prompt_header() {
    (( SUMMARY == 1 )) || return 0
    [[ "$SEASON_HDR_SHOWN" == "$1" ]] && return 0
    SEASON_HDR_SHOWN="$1"
    ui_progress ""
    season_header "$1"
}

# season_crf KEY  ->  CRF analysis, ceiling decisions and the source-
# quality guard of the loaded season. SEASON_FAILED=1 when the season
# failed (season_crf_failed: excluded). Always called as a plain command
# (never in a condition) so that set -e stays in force for its prompts.
season_crf() {
    local k="$1" i sg oc

    SEASON_HDR_SHOWN=""

    # Compact: every episode's own ceiling from its exact runtime
    # (SERIES_EP_CEIL; empty for High / Base / Custom)
    if ! series_ep_ceilings "$TIER"; then
        echo "$(ui_err "Episode runtime unknown")$( (( MULTI == 1 )) && echo " ($(season_name "$k"))"): no $TIER video ceiling can be calculated."
        (( MULTI == 1 )) && echo "$(season_name "$k") is excluded."
        season_exclude "$k" "episode runtime unknown"
        SEASON_FAILED=1
        return 0
    fi

    mapfile -t CRF_SERIES_SAMPLED < <(series_sample_episodes "$FILE_COUNT" "$SERIES_CRF_SAMPLE_EPISODES" "$(series_longest_episode)")
    CRF_SERIES_FILTER="$VIDEO_FILTER"
    declare -gA CRF_SERIES_EP_BYTES=() CRF_SERIES_EP_FROM=() CRF_SERIES_RATES=() CRF_EP_EST=()

    if (( SUMMARY == 1 )); then
        : > "$SEASON_LOG"
        ui_progress "Estimating $(season_name "$k") ($(ui_plural "$FILE_COUNT" episode), ${OUT_WIDTH}x${OUT_HEIGHT})..."
    else
        echo
        (( MULTI == 1 )) && echo "$(ui_bold "$(season_name "$k")")"
        if ui_verbose; then
            printf "Estimating video size from sample encodes (%d of %d episodes, %sx%s output%s):\n" \
                "${#CRF_SERIES_SAMPLED[@]}" "$FILE_COUNT" "$OUT_WIDTH" "$OUT_HEIGHT" \
                "$( (( DOWNSCALED == 1 )) && echo ", downscaled like the final encode")"
        else
            printf 'Estimating %s at %sx%s...\n' \
                "$( [[ "$TIER" == "Custom" ]] && echo "CRF $CUSTOM_CRF" || echo "$TIER")" "$OUT_WIDTH" "$OUT_HEIGHT"
        fi
    fi

    if [[ "$TIER" == "Custom" ]]; then
        if hidden crf_select_exact "$CUSTOM_CRF" crf_series_estimate_shown; then
            hidden crf_series_step_report fits "$CRF_SELECTED"
        else
            CRF_SELECTED=""
        fi
    else
        hidden crf_select_boundary "$CRF_START" "$CRF_MIN" "$CRF_MAX" "$CRF_CEILING_BYTES" crf_series_estimate_shown \
            crf_series_step_report series_crf_certify_over || CRF_SELECTED=""
    fi

    if [[ -z "$CRF_SELECTED" ]]; then
        season_crf_failed "$k"
        SEASON_FAILED=1
        return 0
    fi

    # season CRF; EP_CRF / EP_EST: each episode's CRF and its estimate there
    CRF="$CRF_SELECTED"
    read -ra EP_EST <<< "${CRF_SERIES_EP_BYTES[$CRF]}"
    read -ra EP_FROM <<< "${CRF_SERIES_EP_FROM[$CRF]}"
    for i in "${!FILES[@]}"; do
        EP_CRF[$i]="$CRF"
        EP_OVER[$i]=0
        EP_CEIL_SKIP[$i]=0
    done

    # season figures at the season CRF (audio is never part of them)
    series_batch_stats "$CRF_CEILING_BYTES" "${EP_EST[@]}"
    EST_MEDIAN="$SB_MEDIAN"
    # shared season CRF: an outlier (SB_ISOLATED) is only reported; it never
    # gets a CRF of its own, every episode above the ceiling counts
    if [[ "$TIER" != "Custom" ]]; then
        for i in "${!FILES[@]}"; do
            (( EP_EST[i] > $(series_ep_ceil "$i") )) && EP_OVER[$i]=1
        done
    fi

    # ---- season CRF_MAX still above the ceiling (every episode decides)
    if (( CRF_OVER_CEILING == 1 )); then
        season_prompt_header "$k"
        echo
        echo "------------------------------------------------------------"
        if (( ${#SERIES_EP_CEIL[@]} )); then
            # Compact: the episode with the least room under its own ceiling
            echo "$(ui_warn WARNING): the ${CRF_GIB_PER_HOUR} GiB/h per-episode video ceilings cannot be met"
            echo "within the allowed ${TIER} quality range: even CRF ${CRF_MAX} (the lowest quality ${TIER}"
            echo "allows) gives $(ep_name "$SB_DECIDE_IDX") ~$(bytes_to_gib "$SB_DECIDE_BYTES") GiB video, ~$(crf_oversize_gib "$SB_DECIDE_BYTES" "$(series_ep_ceil "$SB_DECIDE_IDX")") GiB above its $(bytes_to_gib "$(series_ep_ceil "$SB_DECIDE_IDX")") GiB ceiling."
        else
            echo "$(ui_warn WARNING): the ${CRF_CEILING_GIB} GiB per-episode video ceiling cannot be met"
            echo "within the allowed ${TIER} quality range: even CRF ${CRF_MAX} (the lowest quality ${TIER}"
            echo "allows) gives a largest episode of ~$(bytes_to_gib "${CRF_EST[$CRF]}") GiB video, ~$(crf_oversize_gib "${CRF_EST[$CRF]}" "$CRF_CEILING_BYTES") GiB above the ceiling."
        fi
        echo "------------------------------------------------------------"
        echo "1) Encode every episode$( (( MULTI == 1 )) && echo " of $(season_name "$k")") at CRF ${CRF_MAX} anyway"
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

    final_figures

    if ui_verbose; then
        echo
        echo "CRF analysis (video only; copied audio is not part of the choice):"
        series_crf_analysis_lines

        echo
        echo "Selected:"
        echo "  CRF $CRF for all ${FILE_COUNT} episodes (shared season CRF)"
        echo "  median episode video:  ~$(size_text "$EST_MEDIAN")"
        echo "  largest episode video: ~$(size_text "$EST_LARGEST")"
        if [[ "$TIER" != "Custom" ]]; then
            echo "  ceiling:               $(series_ceiling_text)"
        fi
    fi

    # Episodes still estimated above the ceiling at their CRF (the ceiling
    # cannot be met within the tier's range and encoding anyway was chosen).
    # Custom has no ceiling. Compact multi-season output lists them with
    # the expected sizes.
    if (( ${#ABOVE[@]} && SUMMARY == 0 )); then
        echo
        if (( ${#ABOVE[@]} == 1 )); then
            echo "$(ui_warn Warning): 1 episode is estimated above $(ceil_phrase) at CRF ${CRF_MAX}."
        else
            echo "$(ui_warn Warning): ${#ABOVE[@]} episodes are estimated above $(ceil_phrase) at CRF ${CRF_MAX}."
        fi
        for i in "${ABOVE[@]}"; do
            if ui_verbose; then
                printf "  %-40.40s ~%s GiB video, +%s GiB (%s)%s\n" "$(basename "${FILES[$i]}")" \
                    "$(bytes_to_gib "${EP_EST[$i]}")" \
                    "$(crf_oversize_gib "${EP_EST[$i]}" "$(series_ep_ceil "$i")")" \
                    "$(series_from_text "${EP_FROM[$i]}")" \
                    "$( (( EP_CEIL_SKIP[$i] == 1 )) && echo "; skipped")"
            else
                printf "  %-*s  ~%s GiB video, +%s GiB (%s)%s\n" "$LABEL_W" "${EP_LABEL[$i]}" \
                    "$(bytes_to_gib "${EP_EST[$i]}")" \
                    "$(crf_oversize_gib "${EP_EST[$i]}" "$(series_ep_ceil "$i")")" \
                    "$(series_from_text "${EP_FROM[$i]}")" \
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

    for i in "${!FILES[@]}"; do
        EP_VIDEO[$i]="crf:${EP_CRF[$i]}"
        EP_GUARD_SKIP[$i]=0
    done

    # GUARD: episodes not below their source; one that was not sampled is
    # sampled itself first (policy.sh series_guard_episodes), so the
    # conservative not-sampled estimate alone never asks
    if ! hidden series_guard_episodes crf_episode_estimate; then
        season_crf_failed "$k"
        SEASON_FAILED=1
        return 0
    fi

    # ---- an own sample taken by the guard above the ceiling at the season
    # CRF (policy.sh series_late_ceiling: the lowest CRF from the season CRF
    # up at which that episode's own estimate fits): the SHARED season CRF
    # rises to it for every episode (season_raise); no episode keeps a CRF
    # of its own. Then the guard is decided on the estimates at that CRF.
    if ! hidden series_late_ceiling crf_episode_estimate crf_episode_step_report; then
        season_crf_failed "$k"
        SEASON_FAILED=1
        return 0
    fi

    if (( ${#LATE[@]} )); then
        RAISE="$CRF"
        RAISED_BY=""
        for i in "${LATE[@]}"; do
            if (( EP_OVER[i] == 1 && CRF_OVER_CEILING == 0 )); then
                season_prompt_header "$k"
                episode_over_ceiling_prompt "$i"
                # a skipped episode is not encoded: it does not raise the season
                (( EP_CEIL_SKIP[i] == 1 )) && continue
            fi
            if (( EP_CRF[i] > RAISE )); then
                RAISE="${EP_CRF[$i]}"
                RAISED_BY="$i"
            fi
        done

        if (( RAISE != CRF )); then
            SEASON_RAISED="$CRF:$RAISED_BY"
            hidden printf '%-10s%s own sample above the ceiling at CRF %s -> season CRF %s for every episode\n' \
                "Season:" "$(ep_name "$RAISED_BY")" "$CRF" "$RAISE"
            if ! hidden season_raise "$RAISE"; then
                season_crf_failed "$k"
                SEASON_FAILED=1
        return 0
            fi
        else
            # nothing raised (skipped / already at the season CRF): every
            # episode stays at the season CRF
            for i in "${!FILES[@]}"; do
                EP_CRF[$i]="$CRF"
                [[ "${EP_VIDEO[$i]}" == crf:* ]] && EP_VIDEO[$i]="crf:$CRF"
            done
        fi

        # the guard on the estimates at the final CRF (a higher CRF can only
        # drop an episode from it); skipped episodes are not asked for
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

        season_prompt_header "$k"
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
    return 0
}

# season_crf_line KEY  ->  compact multi-season: "Season 01   CRF 20
# largest 1.42 GiB (S01E03) / ceiling 1.50" (the decisive episode of the
# season at its final CRF)
season_crf_line() {
    local k="$1" w="$2" what ceil extra=""

    series_batch_stats "$CRF_CEILING_BYTES" "${EP_EST[@]}"
    if (( ${#SERIES_EP_CEIL[@]} )); then
        what="decisive $(bytes_to_gib "$SB_DECIDE_BYTES") GiB (${EP_LABEL[$SB_DECIDE_IDX]})"
        ceil=" / ceiling $(bytes_to_gib "$(series_ep_ceil "$SB_DECIDE_IDX")")"
    else
        what="largest $(bytes_to_gib "$SB_LARGEST") GiB (${EP_LABEL[$SB_DECIDE_IDX]})"
        ceil=" / ceiling $(bytes_to_gib "$CRF_CEILING_BYTES")"
    fi
    [[ "$TIER" == "Custom" ]] && ceil=""
    if [[ -n "$SEASON_RAISED" ]]; then
        extra+="   raised from CRF ${SEASON_RAISED%%:*} (${EP_LABEL[${SEASON_RAISED#*:}]})"
    fi
    (( CRF_OVER_CEILING == 1 || ${#ABOVE[@]} > 0 )) && extra+="   $(ui_warn "ceiling not met")"
    printf '%-*s  CRF %-3s  %s%s%s\n' "$w" "$(season_name "$k")" "$CRF" "$what" "$ceil" "$extra"
}

NAME_W=16
for k in "${ACTIVE[@]}"; do
    (( ${#GROUP_NAMES[$k]} > NAME_W )) && NAME_W=${#GROUP_NAMES[$k]}
done

if (( SUMMARY == 1 )); then
    echo
    printf 'Estimating %s at the output resolution of each season...\n' \
        "$( [[ "$TIER" == "Custom" ]] && echo "CRF $CUSTOM_CRF" || echo "$TIER")"
fi

EXCL_BEFORE=${#EXCLUDED[@]}
for k in "${ACTIVE[@]}"; do
    season_state_load "$k"
    season_crf "$k"
    if (( SEASON_FAILED == 0 )); then
        season_state_save "$k"
        if (( SUMMARY == 1 )); then
            ui_progress ""
            [[ -n "$SEASON_HDR_SHOWN" ]] && echo
            season_crf_line "$k" "$NAME_W"
        fi
    fi
done
continue_or_cancel "$EXCL_BEFORE"


# ============================================================
# SIZE PREVIEW
# ============================================================

# season_preview  ->  the expected sizes of the loaded season, one row per
# episode (single season, or COMPRESS_VERBOSE=1 under season headers)
season_preview() {
    if ui_verbose; then
        echo
        echo "------------------------------------------------------------"
        echo "Tier:                 $TIER"
        if [[ "$TIER" == "Custom" ]]; then
            echo "Video encode:         x265 CRF ${CRF}, single pass, every episode (entered CRF)"
        else
            echo "Video encode:         x265 CRF ${CRF}, single pass, every episode"
            echo "                      (${TIER}: CRF ${CRF_MIN}-${CRF_MAX}, $(series_ceiling_text) video ceiling$( (( CRF_OVER_CEILING == 1 || ${#ABOVE[@]} > 0 )) && echo "; ceiling NOT met"))"
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
        echo "  - video: one shared season CRF for every encoded episode (sizes vary"
        echo "    with content); after the whole season is encoded, every episode's"
        echo "    actual video must fit the ceiling, otherwise the whole season is"
        echo "    re-encoded at CRF + 1; once it fits, CRF - 1 is tested once for the"
        echo "    whole season and kept only if every episode fits; an episode whose"
        echo "    estimate is not below its source is only re-encoded if you chose so"
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
                case "${EP_FROM[$i]}" in
                    sample)   ecol="sampled" ;;
                    promoted) ecol="promoted" ;;
                    *)        ecol="highest" ;;
                esac
                if [[ -n "${IS_ABOVE[$i]:-}" ]]; then
                    status="ABOVE CEILING"
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
        echo "  highest = not sampled (inferred); highest sampled video bitrate x its runtime"
        echo "  promoted = not in the sample set; sampled itself because it decided the season CRF"
        if [[ "$TIER" != "Custom" ]]; then
            echo "  ABOVE CEILING = video estimate above $(ceil_phrase | sed 's/^the //; s/ ceiling$//') even at CRF ${CRF_MAX}"
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
            printf "  Above ceiling:              n/a (Custom has no ceiling)\n"
        else
            printf "  Above ceiling:              %d of %d episode(s) (%s)\n" \
                "${#ABOVE[@]}" "$FILE_COUNT" "$(series_ceiling_text)"
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

        # no CRF column: one shared CRF (shown in the confirmation line)
        echo
        echo "Expected sizes:"
        printf "$ROW_FMT" "$LABEL_W" "Episode" "Runtime" "Video" "Audio" "Total" \
            "$( (( SHOW_STATUS == 1 )) && echo "  Status")"
        for i in "${!FILES[@]}"; do
            printf "$ROW_FMT" "$LABEL_W" "${EP_LABEL[$i]}" \
                "$(awk -v d="${EP_DUR[$i]}" 'BEGIN { printf "%d:%02d", int(d / 60), int(d % 60) }')" \
                "${P_EP_VGIB[$i]}" "${P_EP_AGIB[$i]}" "${P_EP_GIB[$i]}" \
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
}

# season_counts  ->  SC_ABOVE SC_COPY SC_SKIP of the loaded season:
# episodes estimated above the ceiling (encoded anyway), kept as source
# video, skipped (ceiling / source-quality guard)
season_counts() {
    local i
    local -A above=()
    for i in "${ABOVE[@]+"${ABOVE[@]}"}"; do above[$i]=1; done
    SC_ABOVE=0 SC_COPY=0 SC_SKIP=0
    for i in "${!FILES[@]}"; do
        if (( EP_CEIL_SKIP[i] == 1 || EP_GUARD_SKIP[i] == 1 )); then
            ((SC_SKIP += 1))
        elif [[ "${EP_VIDEO[$i]}" == copy ]]; then
            ((SC_COPY += 1))
        elif [[ -n "${above[$i]:-}" ]]; then
            ((SC_ABOVE += 1))
        fi
    done
}

# season_problem_lines  ->  the episodes of the loaded season that need
# attention (above the ceiling, source-quality guard, skipped) and the
# stream handling notes of its first episode that lose something
season_problem_lines() {
    local i note
    local -A above=() guard=()

    for i in "${ABOVE[@]+"${ABOVE[@]}"}"; do above[$i]=1; done
    for i in "${GUARD[@]+"${GUARD[@]}"}"; do guard[$i]=1; done

    for i in "${!FILES[@]}"; do
        if (( EP_CEIL_SKIP[i] == 1 )); then
            printf '%-*s  %s\n' "$LABEL_W" "${EP_LABEL[$i]}" "$(ui_warn "SKIPPED") (above the ceiling at CRF ${CRF_MAX})"
        elif (( EP_GUARD_SKIP[i] == 1 )); then
            printf '%-*s  %s\n' "$LABEL_W" "${EP_LABEL[$i]}" "$(ui_warn "SKIPPED") (source-quality guard)"
        elif [[ "${EP_VIDEO[$i]}" == copy ]]; then
            printf '%-*s  SOURCE VIDEO KEPT (source %s, CRF %s estimate ~%s)\n' "$LABEL_W" "${EP_LABEL[$i]}" \
                "$(size_text "${EP_VBYTES[$i]}")" "$CRF" "$(size_text "${EP_EST[$i]}")"
        elif [[ -n "${above[$i]:-}" ]]; then
            printf '%-*s  %s ~%s GiB video, +%s GiB (%s)%s\n' "$LABEL_W" "${EP_LABEL[$i]}" "$(ui_warn "ABOVE CEILING")" \
                "$(bytes_to_gib "${EP_EST[$i]}")" "$(crf_oversize_gib "${EP_EST[$i]}" "$(series_ep_ceil "$i")")" \
                "$(series_from_text "${EP_FROM[$i]}")" \
                "$( [[ -n "${guard[$i]:-}" ]] && echo "; not below source, encoded anyway")"
        elif [[ -n "${guard[$i]:-}" ]]; then
            printf '%-*s  not below source (%s), encoded anyway at CRF %s\n' "$LABEL_W" "${EP_LABEL[$i]}" \
                "$(size_text "${EP_VBYTES[$i]}")" "$CRF"
        fi
    done

    # stream handling: only what is lost or dropped
    build_stream_map "$REFERENCE" "${EP_VIDX[0]}"
    while IFS= read -r note; do
        [[ "$note" =~ LOST|DROPPED|WARNING|cannot|skipped|missing ]] &&
            printf '%s: %s\n' "$(ui_warn "Stream handling")" "$note"
    done < <(printf '%s\n' "${MAP_NOTES[@]+"${MAP_NOTES[@]}"}"; chapter_notes "$REFERENCE")
    return 0
}

# summary_sizes_table  ->  compact multi-season: one row per season and
# the total, then the episodes that need attention per season
summary_sizes_table() {
    local k w="$NAME_W" st eps=0 skipped=0 lines
    local -a v=() a=() t=() crfs=()

    echo
    echo "Expected sizes:"
    printf '%-*s  %4s  %3s  %7s  %7s  %7s  %6s  %s\n' "$w" "Season" "Eps" "CRF" "Video" "Audio" "Total" "Avg/ep" "Status"
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        season_counts
        st=$(season_status_text "$SC_ABOVE" "$SC_COPY" "$SC_SKIP")
        [[ "$st" == OK ]] && st=$(ui_ok OK) || st=$(ui_warn "$st")
        printf '%-*s  %4s  %3s  %7s  %7s  %7s  %6s  %s\n' "$w" "$(season_name "$k")" "$FILE_COUNT" "$CRF" \
            "$P_VIDEO_GIB" "$P_AUDIO_GIB" "$P_TOTAL_GIB" "$(per_file "$P_TOTAL_GIB")" "$st"
        eps=$(( eps + FILE_COUNT ))
        skipped=$(( skipped + SC_SKIP ))
        v+=("$P_VIDEO_GIB"); a+=("$P_AUDIO_GIB"); t+=("$P_TOTAL_GIB"); crfs+=("$CRF")
    done
    read -r TOT_V TOT_A TOT_T < <(printf '%s %s %s\n' "$(printf '%s+' "${v[@]}")0" "$(printf '%s+' "${a[@]}")0" "$(printf '%s+' "${t[@]}")0" |
        awk '{ for (i = 1; i <= 3; i++) { n = split($i, x, "+"); s = 0; for (j = 1; j <= n; j++) s += x[j]; printf "%.2f ", s } print "" }')
    printf '%-*s  %4s  %3s  %7s  %7s  %7s  %6s\n' "$w" "Total" "$eps" "" "$TOT_V" "$TOT_A" "$TOT_T" \
        "$(awk -v g="$TOT_T" -v n="$eps" 'BEGIN { printf "%.2f", (n > 0 ? g / n : 0) }')"
    echo "(sizes in GiB; audio = all source audio tracks, copied; total incl. ~${SERIES_CONTAINER_RESERVE_PCT}% container/subtitles)"
    (( skipped > 0 )) && echo "(totals include the $skipped skipped episode(s))"

    season_crf_range "${crfs[@]}" | sed '1s/^/\n/'

    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        lines=$(season_problem_lines)
        [[ -n "$lines" ]] || continue
        echo
        echo "$(season_name "$k"):"
        printf '%s\n' "$lines" | sed 's/^/  /'
    done
    echo
}

if (( SUMMARY == 1 )); then
    summary_sizes_table
else
    PREVIEW_CRFS=()
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        season_header "$k"
        season_preview
        PREVIEW_CRFS+=("$CRF")
    done
    if (( MULTI == 1 )); then
        season_crf_range "${PREVIEW_CRFS[@]}"
    fi
fi

# ============================================================
# OUTPUT
# ============================================================

# The output folder has exactly the source folder's name (no resolution /
# codec / tier); season folders below it mirror the source layout
# (out/<show>/Season 01/...; the show root for episodes directly in the
# show folder). The episode file names carry the encode information, so
# High, Base and Custom outputs of one series can share the folder.
OUT_SERIES=$(series_output_dir "$OUT_DIR" "$SERIES_DIR")

# path_not_folder PATH  ->  0 when PATH exists (or is a symlink) but is
# not a folder: the output folder name is taken
path_not_folder() {
    path_taken "$1" && [[ ! -d "$1" ]]
}

# out_folder_taken FOLDER  ->  stops when FOLDER or one of its parents
# below out/ is taken by something that is not a folder
out_folder_taken() {
    local p="$1"
    while [[ "$p" == "$OUT_SERIES" || "$p" == "$OUT_SERIES"/* ]]; do
        if path_not_folder "$p"; then
            echo "Output folder name is taken by something that is not a folder:"
            if [[ -L "$p" ]]; then
                echo "  $p -> $(readlink -- "$p")$( [[ -e "$p" ]] || echo " (broken symlink)")"
            else
                echo "  $p"
            fi
            echo "Move or rename it, then run the menu again."
            echo "Compression cancelled."
            exit 1
        fi
        [[ "$p" == "$OUT_SERIES" ]] && break
        p=$(dirname -- "$p")
    done
}

EXISTING=0
RENAMED=0

for k in "${ACTIVE[@]}"; do
    season_state_load "$k"

    OUT_SEASON=$(series_output_dir "$OUT_DIR" "$SERIES_DIR" "$(season_rel "$k")")
    out_folder_taken "$OUT_SEASON"

    for i in "${!FILES[@]}"; do
        EP_OUT[$i]=$(series_episode_output "$OUT_SEASON" "${FILES[$i]}" "$TIER" "$DOWNSCALED")

        EP_OVERWRITE[$i]=0
        EP_MATCH[$i]=""
        EP_SKIP[$i]=$(( EP_GUARD_SKIP[i] == 1 || EP_CEIL_SKIP[i] == 1 ))
        (( EP_SKIP[$i] == 1 )) && continue

        # A name another encode is writing or a running job will write
        # (output_busy) is always a conflict (its settings are not known yet).
        if output_busy "${EP_OUT[$i]}"; then
            ((EXISTING += 1))
            continue
        fi

        # Only a version made with the SAME settings (CRF, Dolby Vision /
        # HDR10+ kept) is a conflict; versions with other settings are kept
        # and this encode gets the next free " (N)" name without asking.
        path_taken "${EP_OUT[$i]}" || continue
        sig=$(output_plan_sig "${EP_VIDEO[$i]}" "" "${DV_POLICY:-none}" "${HDR10P_POLICY:-none}")
        if [[ -z "$sig" ]]; then
            EP_MATCH[$i]="${EP_OUT[$i]}"
        else
            while IFS= read -r f; do
                [[ -n "$f" && "$(output_file_sig "$f")" == "$sig" ]] && { EP_MATCH[$i]="$f"; break; }
            done < <(output_family "${EP_OUT[$i]}")
        fi

        if [[ -n "${EP_MATCH[$i]}" ]]; then
            ((EXISTING += 1))
        else
            EP_OUT[$i]=$(unique_output_path "${EP_OUT[$i]}")
            ((RENAMED += 1))
        fi
    done
    season_state_save "$k"
done

if (( RENAMED > 0 )); then
    echo "$RENAMED episode(s) already have versions with other settings (kept);"
    echo "the new encodes get the next free \" (N)\" name."
    echo
fi

if (( EXISTING > 0 )); then
    if (( MULTI == 0 )); then
        season_state_load "${ACTIVE[0]}"
        echo "$EXISTING of ${FILE_COUNT} episodes already have an output with the same settings in:"
        echo "  $OUT_SEASON"
    else
        # one question for every season; the conflicts listed per season
        echo "$EXISTING episode(s) already have an output with the same settings (or one a running job writes):"
        for k in "${ACTIVE[@]}"; do
            season_state_load "$k"
            CONFLICTS=()
            for i in "${!FILES[@]}"; do
                (( EP_SKIP[$i] == 1 )) && continue
                if [[ -n "${EP_MATCH[$i]}" ]] || output_busy "${EP_OUT[$i]}"; then
                    CONFLICTS+=("${EP_LABEL[$i]}")
                fi
            done
            (( ${#CONFLICTS[@]} )) || continue
            printf '  %-*s  %s: %s\n' "$NAME_W" "$(season_name "$k")" "$(ui_plural "${#CONFLICTS[@]}" episode)" \
                "$(printf '%s ' "${CONFLICTS[@]:0:12}")$( (( ${#CONFLICTS[@]} > 12 )) && echo "...")"
        done
        echo "  in $OUT_SERIES"
    fi

    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        for i in "${!FILES[@]}"; do
            if [[ -n "${EP_MATCH[$i]}" && -L "${EP_MATCH[$i]}" ]]; then
                echo
                output_symlink_notice "${EP_MATCH[$i]}"
            fi
        done
    done
    echo
    echo "1) Keep both (new files get a \" (N)\" suffix)"
    echo "2) Overwrite those outputs when the new encodes complete"
    echo "3) Skip those episodes"

    while true; do
        read -rp "Select [1-3]: " oc
        case "$oc" in
            1|2|3) break ;;
            *) echo "Invalid selection." ;;
        esac
    done

    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        for i in "${!FILES[@]}"; do
            (( EP_SKIP[$i] == 1 )) && continue
            if [[ -z "${EP_MATCH[$i]}" ]] && output_busy "${EP_OUT[$i]}"; then
                # Being written (or planned) by another job: never touch it.
                if [[ "$oc" == "3" ]]; then
                    EP_SKIP[$i]=1
                else
                    EP_OUT[$i]=$(unique_output_path "${EP_OUT[$i]}")
                fi
            elif [[ -n "${EP_MATCH[$i]}" ]]; then
                case "$oc" in
                    1) EP_OUT[$i]=$(unique_output_path "${EP_OUT[$i]}") ;;
                    2) EP_OUT[$i]="${EP_MATCH[$i]}"; EP_OVERWRITE[$i]=1 ;;
                    3) EP_SKIP[$i]=1 ;;
                esac
            fi
        done
        season_state_save "$k"
    done
    echo
fi

# ---- CRF attempt files an earlier, interrupted High / Base job left for
# these outputs (".retry-crf<N>.part" / ".accepted-crf<N>.part") would
# make the season retries of this job fail or be skipped (job_runtime.sh
# item_attempt_part / _keep_accepted never write over them). Never
# deleted here (one may be the only copy of a completed encode): the job
# is not started until they are moved or deleted. Every selected season
# is checked; one report.
if [[ "$TIER" != "Custom" ]]; then
    LEFTOVERS=()
    for k in "${ACTIVE[@]}"; do
        season_state_load "$k"
        for i in "${!FILES[@]}"; do
            (( EP_SKIP[$i] == 1 )) && continue
            mapfile -t -O "${#LEFTOVERS[@]}" LEFTOVERS < <(crf_attempt_leftovers "${EP_OUT[$i]}")
        done
    done
    if (( ${#LEFTOVERS[@]} )); then
        echo "$(ui_err "Leftover CRF attempt files") of an earlier, interrupted job for these outputs:"
        printf '  %s\n' "${LEFTOVERS[@]}"
        echo "They are not deleted automatically (one may be the only copy of an encode)."
        echo "Rename or delete them, then run the menu again."
        echo "Compression cancelled."
        exit 1
    fi
fi

# QUEUED per season; JOB_KEYS: the seasons with something to encode
TOTAL_QUEUED=0
JOB_KEYS=()
for k in "${ACTIVE[@]}"; do
    season_state_load "$k"
    QUEUED=0
    for i in "${!FILES[@]}"; do
        (( EP_SKIP[$i] == 1 )) || ((QUEUED += 1))
    done
    season_state_save "$k"
    TOTAL_QUEUED=$(( TOTAL_QUEUED + QUEUED ))
    (( QUEUED > 0 )) && JOB_KEYS+=("$k")
done

if (( TOTAL_QUEUED == 0 )); then
    echo "Nothing to encode."
    exit 0
fi

# season_confirm_text  ->  "High | CRF 20 | 1920x1080 | SDR | audio
# copied" of the loaded season (compact confirmation)
season_confirm_text() {
    printf '%s | %s | %sx%s | %s | audio copied%s' "$TIER" "$(ui_bold "CRF $CRF")" \
        "$OUT_WIDTH" "$OUT_HEIGHT" "$(hdr_policy_short)" \
        "$( (( CRF_OVER_CEILING == 1 || ${#ABOVE[@]} > 0 )) && echo " | $(ui_warn "ceiling not met")")"
}

if (( MULTI == 0 )); then
    season_state_load "${JOB_KEYS[0]}"
    if ui_verbose; then
        read -rp "Start compression of $QUEUED episode(s)? [y/N]: " confirm
    else
        # one-line confirmation of the encode settings
        printf '%s\n' "$(season_confirm_text)"
        read -rp "Start compression of $(ui_plural "$QUEUED" episode)? [y/N]: " confirm
    fi
else
    # one line per season (one line when every season is the same)
    CONFIRM_LINES=()
    for k in "${JOB_KEYS[@]}"; do
        season_state_load "$k"
        CONFIRM_LINES+=("$(season_confirm_text)")
    done
    echo
    if [[ $(printf '%s\n' "${CONFIRM_LINES[@]}" | sort -u | grep -c .) == 1 ]]; then
        printf '%-*s  %s\n' "$NAME_W" "All seasons:" "${CONFIRM_LINES[0]}"
    else
        for n in "${!JOB_KEYS[@]}"; do
            season_state_load "${JOB_KEYS[$n]}"
            printf '%-*s  %s  (%s)\n' "$NAME_W" "$(season_name "${JOB_KEYS[$n]}")" "${CONFIRM_LINES[$n]}" \
                "$(ui_plural "$QUEUED" episode)"
        done
    fi
    for k in "${SEASON_KEYS[@]}"; do
        [[ -n "${EXCLUDED[$k]+x}" ]] || continue
        printf '%-*s  %s\n' "$NAME_W" "$(season_name "$k")" "$(ui_warn "excluded"): ${EXCLUDED[$k]}"
    done
    read -rp "Start compression of $(ui_plural "${#JOB_KEYS[@]}" season) ($(ui_plural "$TOTAL_QUEUED" episode))? [y/N]: " confirm
fi
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

# ============================================================
# TMUX SESSION
# ============================================================

SESSION=$(next_tmux_session series)

JOB_FILE="$WORK_DIR/${SESSION}.sh"

# ============================================================
# BUILD ENCODE JOB
# ============================================================

# High / Base: every encoded episode of a season joins ONE shared-CRF
# season batch (policy.sh series_season_retry_spec; job_runtime.sh
# job_crf_batch, batch_mode=season): the season is encoded at CRF; any
# episode's ACTUAL video above the per-episode ceiling re-encodes the
# WHOLE season at CRF + 1 (up to CRF_MAX); once every episode fits,
# CRF - 1 is tested once for the whole season (not below CRF_MIN, the
# tier's SERIES_*_CRF_SEARCH_MIN) and kept only when every episode fits.
# No per-episode retry, headroom or own CRF. Custom: no retry. Several
# seasons: one batch per season (emit_job_season / emit_job_season_end),
# encoded one season after the other; a retry only re-encodes its season.
# ep_retry_spec INDEX  ->  RETRY of emit_encode_item ("" = none)
ep_retry_spec() {
    # its own ceiling (series Compact: runtime x rate; one value for High / Base)
    series_season_retry_spec "$TIER" "$(series_ep_ceil "$1")" "$CRF_MAX" "$CRF_MIN"
}

# one CRF for every encoded episode of a season (anything else is a bug:
# never start a job with mixed CRFs within a season)
for k in "${JOB_KEYS[@]}"; do
    season_state_load "$k"
    for i in "${!FILES[@]}"; do
        (( EP_SKIP[$i] == 1 )) && continue
        if [[ "${EP_VIDEO[$i]}" != copy && "${EP_VIDEO[$i]}" != "crf:$CRF" ]]; then
            echo "$(ui_err "Internal error"): $(ep_name "$i") is planned at ${EP_VIDEO[$i]}, season CRF $CRF."
            echo "Compression cancelled."
            exit 1
        fi
    done
done

# ============================================================
# DISK SPACE (before hours of encoding: outputs in out/, Dolby Vision
# intermediates in work/logs/). A season CRF retry re-encodes every
# episode of that season while its completed season attempt is kept: up
# to twice that season in out/ (seasons are encoded one after the other,
# the retry factor counts per season).
# ============================================================

SPACE_OUT=() SPACE_OUT_RETRY=() SPACE_WORK=()
for k in "${JOB_KEYS[@]}"; do
    season_state_load "$k"
    S_OUT=() S_RETRY=0
    for i in "${!FILES[@]}"; do
        (( EP_SKIP[$i] == 1 )) && continue
        S_OUT+=("$(item_output_estimate "$(file_bytes "${FILES[$i]}")" "${EP_VBYTES[$i]:-}" \
            "$( [[ "${EP_VIDEO[$i]}" == crf:* ]] && echo "${EP_EST[$i]:-}")")")
        SPACE_WORK+=("$(item_work_estimate \
            "$( [[ "${EP_VIDEO[$i]}" == crf:* && "${DV_POLICY:-none}" == preserve ]] && echo 1 || echo 0)" \
            "${EP_EST[$i]:-${EP_VBYTES[$i]:-0}}")")
        [[ -n "$(ep_retry_spec "$i")" ]] && S_RETRY=1
    done
    SPACE_OUT+=("$(bytes_sum "${S_OUT[@]}")")
    SPACE_OUT_RETRY+=("$(( $(bytes_sum "${S_OUT[@]}") * (1 + S_RETRY) ))")
done
# the largest extra of one season's retry on top of everything
SPACE_TOTAL=$(bytes_sum "${SPACE_OUT[@]}")
SPACE_PEAK=$(( SPACE_TOTAL + $(bytes_max "$(for n in "${!SPACE_OUT[@]}"; do echo $(( SPACE_OUT_RETRY[n] - SPACE_OUT[n] )); done)") ))
echo
compress_space_confirm \
    "$( [[ -d "$OUT_SERIES" ]] && echo "$OUT_SERIES" || echo "$OUT_DIR")" \
    "$SPACE_TOTAL" \
    "$SPACE_PEAK" \
    "$WORK_DIR" "$(bytes_max "${SPACE_WORK[@]}")" || exit 1

for k in "${JOB_KEYS[@]}"; do
    season_state_load "$k"
    mkdir -p "$OUT_SEASON"
done

{
    emit_job_header "$SESSION" series "$TOTAL_QUEUED"

    n=0
    sn=0
    for k in "${JOB_KEYS[@]}"; do
        season_state_load "$k"
        ((sn += 1))

        if (( MULTI == 1 )); then
            # one independent season: own batch, own CRF; items carry the
            # season and its CRF (progress-check.sh, provenance)
            emit_job_season "$(season_name "$k")" "$CRF" "$sn" "${#JOB_KEYS[@]}" "$QUEUED"
            EMIT_SEASON="$(season_name "$k")"
            EMIT_SEASON_CRF="$CRF"
        fi

        for i in "${!FILES[@]}"; do
            (( EP_SKIP[$i] == 1 )) && continue
            ((n += 1))
            (( MULTI == 1 )) && EMIT_EP_LABEL="${EP_LABEL[$i]}"

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

        (( MULTI == 1 )) && emit_job_season_end
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
