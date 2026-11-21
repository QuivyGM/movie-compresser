#!/usr/bin/env bash
# Inspect / validate media files under ~/compress/in or ~/compress/out.
#
#   Verify             fast: stored MKV statistics tags (BPS,
#                      NUMBER_OF_BYTES, DURATION) when they pass the
#                      sanity checks in media_stats.sh, or stream bit
#                      rates for non-MKV. Missing / rejected statistics
#                      are replaced by a packet scan of that file.
#   Validate + update  full packet scan of every file, refreshes MKV
#                      statistics with mkvpropedit, checks the stored
#                      NUMBER_OF_BYTES tags against the scan and that a
#                      normal metadata-first read now returns the same
#                      values without scanning. Outputs (OUT) also get
#                      COMPRESSION_CRF / COMPRESSION_TIER written or
#                      corrected from the job records in work/logs
#                      (never guessed; see backfill_compression_tags).
#                      The provenance tags (COMPRESSION_TOOL /
#                      MOVIE_COMPRESSER_VERSION / COMPRESSION_DATE) are
#                      never written or changed here: only an encode
#                      records them.
#                      Track titles that are not the standard titles of
#                      the actual streams are corrected
#                      (check_track_titles; track names only).
#
# Both modes report the compression tags (compression tool, compressor
# version, compression date, tier, CRF; "Not recorded" when absent, never
# a failure: outputs of earlier versions have none), flag compression
# tags stored more than once with different values (MKVToolNix), and
# check the audio / video track titles against the actual streams
# (check_track_titles). Verify never modifies a file.
#
# Recursive, so series folders are included. Non-MKV files are only
# inspected; mkvpropedit is never run on them.
#
# Scope (after Location and Mode): every file, one show (a top-level
# folder) or one season of a show (its season folders as the series
# menu finds them: media_probe.sh series_season_groups). The report is
# grouped by show and season: one line per file (name, tier / CRF, video
# size, VERIFIED / CORRECTED / UNPAIRED / CHECK REQUIRED); the full
# detail block only for a file that is not VERIFIED, or for every file
# with COMPRESS_VERBOSE=1. The end summary has the totals per season and
# the overall totals.
set -u

BASE="$HOME/compress"
IN="$BASE/in"
OUT="$BASE/out"
LIB="$BASE/work/lib"

# shared inspection (inspect_file, check_track_titles, show_source,
# update_and_check, backfill_compression_tags, grouping): work/lib/inspect.sh
source "$LIB/inspect.sh"

command -v ffprobe >/dev/null || {
    echo "ffprobe not found"
    exit 1
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

echo
echo "Location:"
echo "1) IN"
echo "2) OUT"

while true; do
    read -rp "Select [1-2]: " c
    case "$c" in
        1) ROOT="$IN";  break ;;
        2) ROOT="$OUT"; break ;;
        *) echo "Invalid selection." ;;
    esac
done

echo
echo "Mode:"
echo "1) Verify"
echo "2) Validate + update"

while true; do
    read -rp "Select [1-2]: " c
    case "$c" in
        1) VALIDATE=0; break ;;
        2) VALIDATE=1; break ;;
        *) echo "Invalid selection." ;;
    esac
done

if (( VALIDATE == 1 )) && [[ "$ROOT" == "$IN" ]]; then
    echo
    echo "Validate + update rewrites the statistics tags and corrects the track"
    echo "titles of source MKV files in IN (metadata only; audio/video data is"
    echo "not touched)."
    read -rp "Continue? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || exit 0
fi

if (( VALIDATE == 1 )); then
    echo
    echo "Full packet scan of every file. This can take a while."
fi

# ------------------------------------------------------------
# Scope: everything, one show (top-level folder) or one season of a show
# ------------------------------------------------------------

# pick_number PROMPT COUNT  ->  PICKED = 1..COUNT
pick_number() {
    local c
    while true; do
        read -rp "$1" c || exit 0
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= $2 )); then
            PICKED="$c"
            return 0
        fi
        echo "Invalid selection."
    done
}

echo
echo "Scope:"
echo "1) All"
echo "2) One show (folder)"
echo "3) One season of a show"

while true; do
    read -rp "Select [1-3]: " c || exit 0
    case "$c" in
        1|2|3) SCOPE="$c"; break ;;
        *) echo "Invalid selection." ;;
    esac
done

SCOPE_SHOW=""
SCOPE_GROUP=""

if (( SCOPE > 1 )); then
    mapfile -t SHOWS < <(top_dirs "$ROOT")
    if (( ${#SHOWS[@]} == 0 )); then
        echo "No show folders found in: $ROOT"
        exit 1
    fi
    echo
    echo "Show:"
    for i in "${!SHOWS[@]}"; do
        printf '%2d) %s\n' "$((i + 1))" "$(basename "${SHOWS[$i]}")"
    done
    pick_number "Select [1-${#SHOWS[@]}]: " "${#SHOWS[@]}"
    SCOPE_SHOW="${SHOWS[$((PICKED - 1))]}"
fi

if (( SCOPE == 3 )); then
    mapfile -t GROUPS_ < <(DISCOVERY_QUIET=1 series_season_groups "$SCOPE_SHOW")
    if (( ${#GROUPS_[@]} == 0 )); then
        echo "No season folders with episodes in: $SCOPE_SHOW"
        exit 1
    fi
    echo
    echo "Season:"
    for i in "${!GROUPS_[@]}"; do
        printf '%2d) %s  (%s)\n' "$((i + 1))" "$(series_group_name "$SCOPE_SHOW" "${GROUPS_[$i]}")" \
            "$(ui_plural "$(DISCOVERY_QUIET=1 video_files_in_dir "${GROUPS_[$i]}" | grep -c .)" file)"
    done
    pick_number "Select [1-${#GROUPS_[@]}]: " "${#GROUPS_[@]}"
    SCOPE_GROUP="${GROUPS_[$((PICKED - 1))]}"
fi

[[ "$ROOT" == "$OUT" ]] && build_source_index "$IN"

# ------------------------------------------------------------
# Files, grouped by show and season
#
# Group key: "SHOW<TAB>SEASON"; SHOW "" for files directly in ROOT,
# SEASON the folder below the show ("(root)" for files in the show
# folder itself; series_group_name).
# ------------------------------------------------------------

if [[ -n "$SCOPE_GROUP" ]]; then
    mapfile -d '' -t FILES < <(discover_paths "$SCOPE_GROUP" 1 f "${MEDIA_EXTS[@]}")
elif [[ -n "$SCOPE_SHOW" ]]; then
    mapfile -d '' -t FILES < <(media_files_recursive "$SCOPE_SHOW")
else
    mapfile -d '' -t FILES < <(media_files_recursive "$ROOT")
fi

inspect_group_files "$ROOT" "${FILES[@]+"${FILES[@]}"}"

DETAIL=$(mktemp)
trap 'rm -f -- "$DETAIL"' EXIT
NAME_W=40
declare -A G_FILES=() G_OK=() G_ISSUES=()
G_ORDER=()

for show in "${SHOW_ORDER[@]+"${SHOW_ORDER[@]}"}"; do
    echo
    echo "############################################################"
    if [[ -z "$show" ]]; then
        echo "$(ui_bold "(files in $(basename "$ROOT")/)")"
    else
        echo "$(ui_bold "$show")"
    fi
    echo "############################################################"

    while IFS= read -r season; do
        key="$show"$'\t'"$season"
        G_ORDER+=("$key")
        G_FILES[$key]=0 G_OK[$key]=0 G_ISSUES[$key]=0
        if [[ -n "$show" ]]; then
            echo
            echo "-- $season"
        fi
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            ui_progress "Checking $(basename "$file")..."
            b_cr=$CHECK_REQUIRED b_tf=$TITLES_FIX b_ns=$NO_SOURCE b_tu=$TITLES_UPDATED b_tw=$TAGS_WRITTEN b_fi=$FILE_ISSUES
            inspect_file "$file" "$ROOT" "$VALIDATE" > "$DETAIL" 2>&1
            st=$(file_status "$b_cr" "$b_tf" "$b_ns" "$b_tu" "$b_tw" "$b_fi")
            ui_progress ""
            G_FILES[$key]=$(( G_FILES[$key] + 1 ))
            case "$st" in
                VERIFIED|CORRECTED) G_OK[$key]=$(( G_OK[$key] + 1 )) ;;
                *) G_ISSUES[$key]=$(( G_ISSUES[$key] + 1 )) ;;
            esac
            case "$st" in
                VERIFIED)  stc=$(ui_ok "$st") ;;
                CORRECTED) stc=$(ui_ok "$st") ;;
                UNPAIRED)  stc=$(ui_warn "$st") ;;
                *)         stc=$(ui_err "$st") ;;
            esac
            name=$(basename "$file")
            (( ${#name} > NAME_W )) && name="${name:0:$((NAME_W - 1))}~"
            printf '  %-*s  %-16s %10s  %s\n' "$NAME_W" "$name" "$(file_tier_crf "$file")" \
                "$( [[ "$FILE_VBYTES" =~ ^[0-9]+$ ]] && echo "$(bytes_to_gib "$FILE_VBYTES") GiB" || echo "-")" "$stc"
            if [[ "$st" != VERIFIED ]] || ui_verbose; then
                sed 's/^/    /' "$DETAIL"
            fi
        done <<< "${GROUP_FILES[$key]}"
    done < <(if [[ -z "$show" ]]; then echo ""; else show_seasons "$show"; fi)
done

if (( ${#G_ORDER[@]} )); then
    echo
    echo "============================================================"
    echo "Per season:"
    GW=10
    for key in "${G_ORDER[@]}"; do
        g="${key%%$'\t'*}"; s="${key#*$'\t'}"
        label="${g:-(top level)}${s:+ / $s}"
        (( ${#label} > GW )) && GW=${#label}
    done
    for key in "${G_ORDER[@]}"; do
        g="${key%%$'\t'*}"; s="${key#*$'\t'}"
        label="${g:-(top level)}${s:+ / $s}"
        printf '  %-*s  %4s files  %4s verified  %4s issues\n' "$GW" "$label" \
            "${G_FILES[$key]}" "${G_OK[$key]}" "${G_ISSUES[$key]}"
    done
fi

echo
echo "============================================================"
echo "Files checked:     $CHECKED"
echo "Packet scanned:    $SCANNED"
echo "Tags updated:      $UPDATED"

if (( UPDATED + CHECK_REQUIRED > 0 )); then
    echo "Verified:          $VERIFIED"
    echo "Check required:    $CHECK_REQUIRED"
fi

if [[ "$ROOT" == "$OUT" ]]; then
    echo "Unpaired outputs:  $NO_SOURCE"
fi

echo "Titles correct:    $TITLES_OK"
if (( VALIDATE == 1 )); then
    echo "Titles updated:    $TITLES_UPDATED"
fi
echo "Titles to correct: $TITLES_FIX"

if (( TAGS_WRITTEN + TAGS_CURRENT + TAGS_UNRECOVERED > 0 )); then
    echo "CRF tags written:  $TAGS_WRITTEN"
    echo "CRF tags current:  $TAGS_CURRENT"
    echo "CRF not recovered: $TAGS_UNRECOVERED"
fi

echo "============================================================"
