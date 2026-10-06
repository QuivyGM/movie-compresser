#!/usr/bin/env bash
# Output <-> source name pairing. Sourced, not executed.
#
# Output names produced by the menus:
#   movie:   "<name>[ 1080p] HEVC <Tier>[ EAC3][ (N)].mkv"
#   series:  "<series>[ 1080p] HEVC <Tier>/<episode>[ 1080p] HEVC <Tier>.mkv"
#   audio:   "<any of the above> AudioCompressed[ N].mkv"
# Tier: Quality | High | Base | Normal | Custom | CRF<nn>

NAMING_SUFFIX_RE=' AudioCompressed( [0-9]+)?$'
NAMING_TIER_RE='( 1080p)? HEVC (Quality|High|Base|Normal|Custom|CRF[0-9]+)( EAC3)?( \([0-9]+\))?$'

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

# output_tier NAME  ->  Quality / High / ... / CRF20 (+ " + EAC3",
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

    tier=$(grep -oE 'HEVC (Quality|High|Base|Normal|Custom|CRF[0-9]+)( EAC3)?' <<< "$n" |
        tail -n 1 | sed -E 's/^HEVC //; s/ EAC3$/ + EAC3/')

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
# Series outputs (OUT_ROOT/<series dir>/<episode>) first look in the
# matching IN_ROOT/<series> folder; otherwise all of IN_ROOT is searched.
# Matching ignores case and the source extension. Several matches are
# reported, never guessed.
find_source_for_output() {
    local out="$1"
    local in_root="$2"
    local out_root="$3"
    local stem rel series_dir="" f cand
    local matches=()
    local preferred=()

    stem=$(output_source_stem "$(basename "$out")")
    stem="${stem,,}"

    rel="${out#"$out_root"/}"

    if [[ "$rel" == */* ]]; then
        series_dir=$(output_source_stem "${rel%%/*}")
    fi

    for f in "${SOURCE_INDEX[@]+"${SOURCE_INDEX[@]}"}"; do
        cand=$(basename "$f")
        cand="${cand%.*}"

        [[ "${cand,,}" == "$stem" ]] || continue

        matches+=("$f")

        if [[ -n "$series_dir" && "$(dirname "$f")" == "$in_root/$series_dir" ]]; then
            preferred+=("$f")
        fi
    done

    if (( ${#preferred[@]} == 1 )); then
        printf 'OK\t%s\n' "${preferred[0]}"
    elif (( ${#preferred[@]} > 1 )); then
        printf 'AMBIGUOUS'
        printf '\t%s' "${preferred[@]}"
        printf '\n'
    elif (( ${#matches[@]} == 1 )); then
        printf 'OK\t%s\n' "${matches[0]}"
    elif (( ${#matches[@]} == 0 )); then
        printf 'NONE\n'
    else
        printf 'AMBIGUOUS'
        printf '\t%s' "${matches[@]}"
        printf '\n'
    fi
}
