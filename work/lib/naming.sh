#!/usr/bin/env bash
# Output <-> source name pairing. Sourced, not executed.
#
# Output names produced by the menus:
#   movie:   "<name>[ 1080p] HEVC <Tier>[ EAC3][ (N)].mkv"
#   series:  "<series>[/<season>]/<episode>[ 1080p] HEVC <Tier>.mkv"
#            (folder = source folder name; <season> = the season group's
#            path below it, e.g. "Season 01", mirroring in/; older runs:
#            "<series>[ 1080p] HEVC <Tier>/...")
#   audio:   "<any of the above> AudioCompressed[ N].mkv"
# Tier: Quality | High | Base | Compact | Normal | Custom | CRF<nn> |
#       Size<GiB>G (series "Custom size": the video ceiling per episode,
#       e.g. "Size1.2G", "Size0.75G"; size_tier_token)

NAMING_SUFFIX_RE=' AudioCompressed( [0-9]+)?$'
NAMING_TIER_WORD='(Quality|High|Base|Compact|Normal|Custom|CRF[0-9]+|Size[0-9]+([.][0-9]+)?G)'
NAMING_TIER_RE="( 1080p)? HEVC $NAMING_TIER_WORD( EAC3)?( \\([0-9]+\\))?\$"

# ------------------------------------------------------------
# Custom size tier (series): TIER = "Size<GiB>G", the per-episode video
# ceiling the user entered, in the output name as it is. Shown as
# "Custom size 1.2 GiB/episode", recorded as COMPRESSION_TIER
# "Custom size 1.2 GiB" (encode_common.sh compression_tier_name).
# ------------------------------------------------------------

# size_gib_norm INPUT  ->  INPUT as a canonical positive GiB value
# ("1.20" -> "1.2", ".75" -> "0.75", "2" -> "2"); non-zero (nothing
# printed) for anything else: not a plain decimal number, zero, more
# than 3 decimals, above 1000
size_gib_norm() {
    local v="${1:-}"
    v="${v//[[:space:]]/}"
    [[ "$v" =~ ^([0-9]*)([.]([0-9]{1,3}))?$ && -n "${BASH_REMATCH[1]}${BASH_REMATCH[3]}" ]] || return 1
    awk -v v="$v" 'BEGIN {
        if (v + 0 <= 0 || v + 0 > 1000) exit 1
        s = sprintf("%.3f", v + 0); sub(/0+$/, "", s); sub(/[.]$/, "", s); print s }'
}

# size_tier_token GIB  ->  "Size1.2G" (GIB normalised by size_gib_norm)
size_tier_token() {
    local g
    g=$(size_gib_norm "$1") || return 1
    printf 'Size%sG' "$g"
}

# size_tier_gib TIER  ->  the GiB of a "Size<GiB>G" tier ("1.2");
# non-zero for every other tier
size_tier_gib() {
    [[ "${1:-}" =~ ^Size([0-9]+([.][0-9]+)?)G$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# tier_display TIER  ->  how a tier is shown: "Custom size 1.2 GiB/episode"
# for a Size tier, every other tier as it is
tier_display() {
    local g
    if g=$(size_tier_gib "${1:-}"); then
        printf 'Custom size %s GiB/episode' "$g"
    else
        printf '%s' "${1:-}"
    fi
}

# series_output_dir OUT_ROOT SERIES_DIR [GROUP_REL]
#   ->  OUT_ROOT/<SERIES_DIR basename>[/GROUP_REL]
# The source folder name exactly (spaces, hyphens, punctuation, case);
# no resolution / codec / tier / CRF: the episode names carry those.
# GROUP_REL: the season group's path below the series folder
# (media_probe.sh series_group_rel: "Season 01", "Season 01/Disc 2"; ""
# or "(root)" = files in the series folder itself), mirrored in out/.
series_output_dir() {
    local name rel="${3:-}"
    name=$(basename -- "$2")
    [[ "$rel" == "(root)" || "$rel" == "." ]] && rel=""
    rel="${rel#/}"
    rel="${rel%/}"
    printf '%s/%s%s' "${1%/}" "$name" "${rel:+/$rel}"
}

# series_episode_output OUT_SERIES EPISODE_FILE TIER DOWNSCALED
#   ->  OUT_SERIES/<episode>[ 1080p] HEVC <TIER>.mkv
series_episode_output() {
    local name res=""
    name=$(basename -- "$2")
    name="${name%.*}"
    [[ "$4" == "1" ]] && res=" 1080p"
    printf '%s/%s%s HEVC %s.mkv' "$1" "$name" "$res" "$3"
}

# output_source_stem NAME  ->  source name without extension
# (NAME may include the extension; unknown names are returned as-is).
output_source_stem() {
    local n="$1"

    case "${n,,}" in
        *.mkv|*.mp4|*.m4v|*.mov|*.avi|*.ts|*.m2ts|*.webm) n="${n%.*}" ;;
    esac

    sed -E \
        -e "s/$NAMING_SUFFIX_RE//" \
        -e "s/$NAMING_TIER_RE//" <<< "$n"
}

# output_tier NAME  ->  Quality / High / ... / CRF20 / Custom size 1.2 GiB (+ " + EAC3",
# " + AudioCompressed"), or "Unknown"
output_tier() {
    local n="$1"
    local stem tier extra=""

    n="${n%.*}"

    if [[ "$n" =~ $NAMING_SUFFIX_RE ]]; then
        extra=" + AudioCompressed"
        n=$(sed -E "s/$NAMING_SUFFIX_RE//" <<< "$n")
    fi

    stem=$(sed -E "s/$NAMING_TIER_RE//" <<< "$n")

    if [[ "$stem" == "$n" ]]; then
        if [[ -n "$extra" ]]; then
            echo "Original${extra}"
        else
            echo "Unknown"
        fi
        return
    fi

    tier=$(grep -oE "HEVC $NAMING_TIER_WORD( EAC3)?" <<< "$n" |
        tail -n 1 | sed -E 's/^HEVC //; s/ EAC3$/ + EAC3/')
    # Custom size: "Custom size 1.2 GiB" (as the COMPRESSION_TIER tag)
    [[ "$tier" =~ ^Size([0-9]+([.][0-9]+)?)G(.*)$ ]] &&
        tier="Custom size ${BASH_REMATCH[1]} GiB${BASH_REMATCH[3]}"

    [[ "$n" =~ \ 1080p\ HEVC\  ]] && tier="$tier (1080p)"

    echo "${tier}${extra}"
}

# build_source_index IN_ROOT  ->  fills SOURCE_INDEX (all media files)
build_source_index() {
    local f

    SOURCE_INDEX=()

    while IFS= read -r -d '' f; do
        SOURCE_INDEX+=("$f")
    done < <(media_files_recursive "$1")
}

# find_source_for_output OUT_FILE IN_ROOT OUT_ROOT
#
# Needs build_source_index. Prints one of:
#   OK<TAB>path
#   NONE
#   AMBIGUOUS<TAB>path<TAB>path...
#
# Series outputs (OUT_ROOT/<series dir>[/<sub path>]/<episode>) first
# look in the mirrored IN_ROOT/<series>/<sub path> folder (season folders,
# media_probe.sh series_season_groups), then anywhere in IN_ROOT/<series>;
# otherwise all of IN_ROOT is searched. Matching ignores case and the
# source extension. Several matches at the same level are reported,
# never guessed.
find_source_for_output() {
    local out="$1"
    local in_root="${2%/}"
    local out_root="${3%/}"
    local stem rel series_dir="" sub="" f cand fdir
    local matches=()
    local exact=()
    local in_series=()

    stem=$(output_source_stem "$(basename "$out")")
    stem="${stem,,}"

    rel="${out#"$out_root"/}"

    if [[ "$rel" == */* ]]; then
        series_dir=$(output_source_stem "${rel%%/*}")
        rel="${rel#*/}"
        [[ "$rel" == */* ]] && sub="${rel%/*}"
    fi

    for f in "${SOURCE_INDEX[@]+"${SOURCE_INDEX[@]}"}"; do
        cand=$(basename "$f")
        cand="${cand%.*}"

        [[ "${cand,,}" == "$stem" ]] || continue

        matches+=("$f")
        [[ -n "$series_dir" ]] || continue

        fdir=$(dirname "$f")
        if [[ "$fdir" == "$in_root/$series_dir${sub:+/$sub}" ]]; then
            exact+=("$f")
        fi
        if [[ "$fdir" == "$in_root/$series_dir" || "$fdir" == "$in_root/$series_dir"/* ]]; then
            in_series+=("$f")
        fi
    done

    _fso_print() {
        if (( $# == 1 )); then
            printf 'OK\t%s\n' "$1"
        else
            printf 'AMBIGUOUS'
            printf '\t%s' "$@"
            printf '\n'
        fi
    }

    if (( ${#exact[@]} )); then
        _fso_print "${exact[@]}"
    elif (( ${#in_series[@]} )); then
        _fso_print "${in_series[@]}"
    elif (( ${#matches[@]} )); then
        _fso_print "${matches[@]}"
    else
        printf 'NONE\n'
    fi
}

# episode_label FILE  ->  short episode id for the menus: "S01E03" (also
# from "1x03"), "E03", else the file name without extension, shortened
# to 20 characters
episode_label() {
    local n
    n=$(basename -- "$1")
    n="${n%.*}"

    if [[ "$n" =~ [Ss]([0-9]{1,2})[\ ._-]?[Ee]([0-9]{1,3})([^0-9]|$) ]]; then
        printf 'S%02dE%02d' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
    elif [[ "$n" =~ (^|[^0-9A-Za-z])([0-9]{1,2})[xX]([0-9]{2,3})([^0-9]|$) ]]; then
        printf 'S%02dE%02d' "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
    elif [[ "$n" =~ (^|[^0-9A-Za-z])[Ee][Pp]?\ ?([0-9]{1,3})([^0-9]|$) ]]; then
        printf 'E%02d' "$((10#${BASH_REMATCH[2]}))"
    elif (( ${#n} > 20 )); then
        printf '%s~' "${n:0:19}"
    else
        printf '%s' "$n"
    fi
}

# episode_labels FILE...  ->  one episode_label per line; when two files
# would get the same label, every file is listed by its (shortened) name
episode_labels() {
    local f labels=()

    for f in "$@"; do
        labels+=("$(episode_label "$f")")
    done

    if [[ -n "$(printf '%s\n' "${labels[@]}" | sort | uniq -d)" ]]; then
        labels=()
        for f in "$@"; do
            f=$(basename -- "$f")
            f="${f%.*}"
            (( ${#f} > 24 )) && f="${f:0:23}~"
            labels+=("$f")
        done
    fi

    printf '%s\n' "${labels[@]}"
}

# season_short_label GROUP_NAME  ->  short season id for episode labels
# and narrow columns: "Season 01" / "Season 1" / "S01" / "Series 3" ->
# "S01" / "S03", "Season 00 - Specials" / "Specials" -> "S00" / "SP",
# "(root)" -> "root", anything else: its last path component, shortened
# to 12 characters
season_short_label() {
    local n="$1" last

    last="${n##*/}"
    if [[ "$n" == "(root)" ]]; then
        printf 'root'
    elif [[ "${n%%/*}" =~ ^[Ss](eason|eries)?[\ ._-]*([0-9]{1,3})([^0-9]|$) ]]; then
        printf 'S%02d' "$((10#${BASH_REMATCH[2]}))"
        [[ "$n" == */* ]] && printf '/%.8s' "$last"
    elif [[ "${n%%/*}" =~ ^[Ss][Pp][Ee][Cc][Ii][Aa][Ll][Ss]?$ ]]; then
        printf 'SP'
    elif (( ${#last} > 12 )); then
        printf '%s~' "${last:0:11}"
    else
        printf '%s' "$last"
    fi
    return 0
}

# labels_collide LABEL_LIST...  ->  0 when the same label appears in more
# than one of the lists (each argument: one season's labels, one per line)
labels_collide() {
    local l
    for l in "$@"; do
        printf '%s\n' "$l" | sort -u
    done | grep -v '^$' | sort | uniq -d | grep -q .
}
