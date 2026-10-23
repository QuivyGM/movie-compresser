#!/usr/bin/env bash
# Give the audio tracks of MKV files their standard names
# ("Language | Codec | Channels | Bitrate[ | Description]", the same
# titles the compression jobs write: encode_common.sh audio_std_title).
#
#   bash ~/compress/audio_titles.sh [--dry-run] FILE.mkv...
#
# Metadata only:
#   - built from what the file already stores: codec / profile /
#     channels / layout / language / dispositions / the current title's
#     description, the constant rate the stream states, the average rate
#     of the stored statistics tags (BPS). Nothing is decoded, no packet
#     scan, no loudness analysis: a rate the file does not store is left
#     out of the name.
#   - track names only, written with mkvpropedit (mkv_write_track_titles:
#     no remux, no re-encode, FFmpeg -> Matroska track mapping certain
#     before any write, read back). Video, subtitles, attachments,
#     chapters, flags, languages and track order are never touched.
#   - the old -> new names are shown first; nothing is written without
#     confirmation (--dry-run: never).
#
# Descriptions are kept exactly as written (commentary credits too); a
# name whose description cannot be parsed with confidence is left
# unchanged and reported (audio_title_warning). Tracks the metadata
# cannot tell apart (two tracks that would get the same name, while
# their current names differ) keep their current names and are listed
# for manual identification. Whether a track is commentary is never
# guessed (not from its codec, rate, channels or position): only its
# commentary flag or the words of its name say so.
#
# Afterwards every track (count, order, codec, channels, sample rate,
# language, default / forced) is compared with the state before, and
# every audio name with the intended one.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/work/lib"
WORK_DIR="${WORK_DIR:-$HERE/work}"

source "$LIB/media_probe.sh"
source "$LIB/media_stats.sh"
source "$LIB/bitrate.sh"
source "$LIB/encode_common.sh"

DRY=0
FILES=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *)         FILES+=("$a") ;;
    esac
done
(( ${#FILES[@]} )) || { echo "Usage: $(basename "$0") [--dry-run] FILE.mkv..."; exit 2; }

for t in ffprobe mkvmerge mkvpropedit; do
    command -v "$t" >/dev/null 2>&1 || { echo "$t not found (needs FFmpeg and MKVToolNix)."; exit 3; }
done

N_DONE=0 N_SAME=0 N_SKIP=0 N_FAIL=0
UNRESOLVED=()

# track_state FILE  ->  every Matroska track without its name (mkvmerge)
track_state() {
    mkv_identify_tracks "$1" | awk -F'\t' -v OFS='\t' '{ $9 = ""; print }'
}

rename_file() {
    local file="$1" idx kind cur new lang codec ch dflt comm vi n=0 changes=0 k w
    local -a order=() f
    local -A cur_of=() new_of=() note=() key_n=() key_cur=() want=() info=()

    echo
    echo "============================================================"
    echo "$file"
    echo "============================================================"

    if [[ ! -f "$file" || -L "$file" || "${file,,}" != *.mkv ]]; then
        echo "  Skipped: not a regular MKV file (symlinks are never modified)."
        ((N_SKIP += 1)); return
    fi
    if [[ ! -w "$file" ]]; then
        echo "  Skipped: not writable."
        ((N_SKIP += 1)); return
    fi
    if source_in_active_job "$file"; then
        echo "  Skipped: ${ACTIVE_JOB_WHY:-in use by a running compression job}."
        ((N_SKIP += 1)); return
    fi

    # stored statistics only (stats_load "tags": never a packet scan)
    local measured=""
    if stats_load "$file" "" tags; then
        measured=$(audio_measured_kbps "$STATS_LINES")
    else
        echo "  Note: no usable statistics tags: variable-rate tracks are named without a bit rate."
    fi

    # stream facts for the report and the ambiguity rules
    while IFS=$'\t' read -r -a f; do
        [[ "${f[1]}" == audio ]] || continue
        info[${f[0]}]="${f[2]}"$'\t'"${f[4]}"$'\t'"${f[12]}"$'\t'"${f[6]}"$'\t'"${f[8]}"$'\t'"${f[10]}"
    done < <(stream_meta "$file")

    while IFS=$'\t' read -r idx kind cur new; do
        [[ "$kind" == audio ]] || continue
        order+=("$idx"); cur_of[$idx]="$cur"; new_of[$idx]="$new"
        IFS=$'\t' read -r codec ch lang dflt comm vi <<< "${info[$idx]}"
        k="${new,,}"
        key_n[$k]=$(( ${key_n[$k]:-0} + 1 ))
        # different current names under one new name: information lost
        [[ -z "${key_cur[$k]+x}" ]] && key_cur[$k]="$cur"
        [[ "${key_cur[$k]}" != "$cur" ]] && key_cur[$k]=$'\001'
    done < <(mkv_std_track_titles "$file" "" "" "$measured" audio)

    if (( ${#order[@]} == 0 )); then
        echo "  No audio tracks."
        ((N_SAME += 1)); return
    fi

    for idx in "${order[@]}"; do
        ((n += 1))
        IFS=$'\t' read -r codec ch lang dflt comm vi <<< "${info[$idx]}"
        k="${new_of[$idx],,}"
        w=$(audio_title_warning "${cur_of[$idx]}" "$lang")
        if [[ -n "$w" ]]; then
            # kept as it is (audio_std_title): never rewritten here
            note[$idx]="WARNING: $w"
            UNRESOLVED+=("$(basename "$file"): audio $n \"${cur_of[$idx]}\": $w")
        elif [[ -z "${new_of[$idx]}" ]]; then
            note[$idx]="SKIPPED: no stream properties to name it by - identify manually"
            UNRESOLVED+=("$(basename "$file"): audio $n: no stream properties")
        elif (( key_n[$k] > 1 )) && [[ "${key_cur[$k]}" == $'\001' ]]; then
            note[$idx]="SKIPPED: same name as another track, current names differ - identify manually"
            UNRESOLVED+=("$(basename "$file"): audio $n \"${cur_of[$idx]}\": cannot be told apart from another track")
        else
            if [[ "${cur_of[$idx]}" != "${new_of[$idx]}" ]]; then
                want[$idx]="${new_of[$idx]}"
                ((changes += 1))
            fi
            if (( key_n[$k] > 1 )); then
                note[$idx]="check: same name as another track (both unnamed before)"
                UNRESOLVED+=("$(basename "$file"): audio $n \"${new_of[$idx]}\": same name as another track")
            fi
        fi
        printf '  Audio %d (%s, %sch, %s%s)\n' "$n" "$codec" "$ch" "${lang/#-/und}" "$( [[ "$dflt" == 1 ]] && echo ", default")"
        printf '    %s -> %s\n' "$( [[ "${cur_of[$idx]}" == - ]] && echo "(none)" || echo "\"${cur_of[$idx]}\"")" \
            "$( [[ -n "${want[$idx]+x}" ]] && echo "\"${want[$idx]}\"" || echo "unchanged")"
        [[ -n "${note[$idx]:-}" ]] && printf '    %s\n' "${note[$idx]}"
    done

    if (( changes == 0 )); then
        echo "  Nothing to change."
        ((N_SAME += 1)); return
    fi
    if (( DRY == 1 )); then
        echo "  Dry run: $changes name(s) would change; nothing written."
        return
    fi

    local ans
    read -rp "  Rename $changes audio track(s) in this file? [y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "  Not changed."
        ((N_SKIP += 1)); return
    fi

    local before after rc
    before=$(track_state "$file")
    mkv_write_track_titles "$file" want
    rc=$?
    after=$(track_state "$file")

    # every track as before (names aside), every audio name as intended
    local bad=0 got
    [[ "$before" == "$after" ]] || { echo "  CHECK REQUIRED: the track list changed (it must not)."; bad=1; }
    while IFS=$'\t' read -r -a f; do
        [[ "${f[1]}" == audio && -n "${new_of[${f[0]}]+x}" ]] || continue
        got="${f[13]}"
        if [[ -n "${want[${f[0]}]+x}" && "$got" != "${want[${f[0]}]}" ]] ||
           [[ -z "${want[${f[0]}]+x}" && "$got" != "${cur_of[${f[0]}]}" ]]; then
            echo "  CHECK REQUIRED: stream ${f[0]} is named \"$got\"."
            bad=1
        fi
    done < <(stream_meta "$file")

    if (( rc != 0 )); then
        echo "  NOT RENAMED: $MKV_TITLES_MSG"
        ((N_FAIL += 1))
    elif (( bad == 1 )); then
        ((N_FAIL += 1))
    else
        echo "  Renamed $changes track(s); track count, order, codecs, languages and flags unchanged."
        ((N_DONE += 1))
    fi
}

for file in "${FILES[@]}"; do
    rename_file "$file"
done

echo
echo "============================================================"
echo "Renamed:          $N_DONE"
echo "Already standard: $N_SAME"
echo "Skipped:          $N_SKIP"
echo "Failed:           $N_FAIL"
if (( ${#UNRESOLVED[@]} )); then
    echo
    echo "Identify manually:"
    printf '  %s\n' "${UNRESOLVED[@]}"
fi
echo "============================================================"
(( N_FAIL == 0 ))
