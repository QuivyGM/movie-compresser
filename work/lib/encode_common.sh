#!/usr/bin/env bash
# Shared helpers for the encode menus (movie / series / audio) and the
# generated job scripts. Sourced, not executed. Needs media_probe.sh.

# ------------------------------------------------------------
# tmux / files
# ------------------------------------------------------------

next_tmux_session() {
    local prefix="${1:-c}"
    local n=1

    while tmux has-session -t "=${prefix}${n}" 2>/dev/null; do
        ((n++))
    done

    echo "${prefix}${n}"
}

# Refresh MKV track statistics tags (BPS, NUMBER_OF_BYTES, ...) from
# the actual file contents. Returns non-zero when not possible.
refresh_mkv_stats() {
    local file="$1"

    case "${file,,}" in
        *.mkv) ;;
        *) return 2 ;;
    esac

    command -v mkvpropedit >/dev/null 2>&1 || return 3

    mkvpropedit "$file" \
        --delete-track-statistics-tags \
        --add-track-statistics-tags
}

actual_file_gib() {
    stat -c %s "$1" |
        awk '{printf "%.2f",$1/1073741824}'
}

# unique_output_path PATH  ->  PATH, or "NAME (2).ext", "NAME (3).ext", ...
# Also avoids names that have an in-progress ".part" file.
unique_output_path() {
    local path="$1"
    local dir base ext cand
    local n=2

    dir=$(dirname "$path")
    base=$(basename "$path")
    ext="${base##*.}"
    base="${base%.*}"
    cand="$path"

    while [[ -e "$cand" || -e "$cand.part" ]] || output_is_planned "$cand"; do
        cand="$dir/$base ($n).$ext"
        ((n++))
    done

    printf '%s\n' "$cand"
}

# Outputs already claimed by the queue being built (movie menu queues
# several files; two entries must never write the same output).
PLANNED_OUTPUTS=()

output_is_planned() {
    local p

    for p in "${PLANNED_OUTPUTS[@]+"${PLANNED_OUTPUTS[@]}"}"; do
        [[ "$p" == "$1" ]] && return 0
    done

    return 1
}

# resolve_output_conflict PATH
#
# Interactive. Sets RESOLVED_OUT and RESOLVED_OVERWRITE (0/1).
# Returns 1 when the user chooses to skip the file.
resolve_output_conflict() {
    local path="$1"
    local alt c

    RESOLVED_OUT="$path"
    RESOLVED_OVERWRITE=0

    if [[ ! -e "$path" && ! -e "$path.part" ]] && ! output_is_planned "$path"; then
        return 0
    fi

    alt=$(unique_output_path "$path")

    echo
    echo "Output already exists:"
    echo "  $(basename "$path")"

    if [[ -e "$path.part" ]]; then
        echo "  (a .part file exists: another encode may be writing it)"
    fi

    echo "1) Keep both  [new file: $(basename "$alt")]"

    if [[ -e "$path" && ! -e "$path.part" ]] && ! output_is_planned "$path"; then
        echo "2) Overwrite the existing file when the new encode completes"
    fi

    echo "3) Skip this file"

    while true; do
        read -rp "Select: " c

        case "$c" in
            1)
                RESOLVED_OUT="$alt"
                return 0
                ;;
            2)
                if [[ -e "$path" && ! -e "$path.part" ]] && ! output_is_planned "$path"; then
                    RESOLVED_OVERWRITE=1
                    return 0
                fi
                echo "Invalid selection."
                ;;
            3)
                return 1
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}

# ------------------------------------------------------------
# libx265 capabilities
# ------------------------------------------------------------

LIBX265_HELP=""

libx265_has_option() {
    if [[ -z "$LIBX265_HELP" ]]; then
        LIBX265_HELP=$(ffmpeg -hide_banner -h encoder=libx265 2>/dev/null || true)
    fi

    grep -qE "^[[:space:]]+-$1[[:space:]]" <<< "$LIBX265_HELP"
}

# ------------------------------------------------------------
# HDR / colour signalling (needs probe_hdr globals)
# ------------------------------------------------------------

# x265 VUI names match the ffmpeg names for the values below; anything
# else is left for x265/ffmpeg to decide.
x265_color_params() {
    local p=()

    case "$HDR_PRIMARIES" in
        bt709|bt470m|bt470bg|smpte170m|smpte240m|film|bt2020|smpte428|smpte431|smpte432)
            p+=("colorprim=$HDR_PRIMARIES") ;;
    esac

    case "$HDR_TRANSFER" in
        bt709|bt470m|bt470bg|smpte170m|smpte240m|linear|iec61966-2-4|bt1361e|iec61966-2-1|bt2020-10|bt2020-12|smpte2084|smpte428|arib-std-b67)
            p+=("transfer=$HDR_TRANSFER") ;;
    esac

    case "$HDR_MATRIX" in
        gbr|bt709|fcc|bt470bg|smpte170m|smpte240m|ycgco|bt2020nc|bt2020c|smpte2085|chroma-derived-nc|chroma-derived-c|ictcp)
            p+=("colormatrix=$HDR_MATRIX") ;;
    esac

    case "$HDR_RANGE" in
        tv) p+=("range=limited") ;;
        pc) p+=("range=full") ;;
    esac

    # HDR10 static metadata. x265 emits the SEI messages (and enables
    # HDR10 signalling) when these are given.
    if [[ "$HDR_KIND" != "SDR" ]]; then
        [[ -n "$HDR_MASTER" ]] && p+=("master-display=$HDR_MASTER")
        [[ -n "$HDR_CLL" ]] && p+=("max-cll=$HDR_CLL")
    fi

    local IFS=':'
    printf '%s' "${p[*]-}"
}

# Container-level colour tags for the encoded stream (shell-quoted).
color_output_args() {
    local a=()

    [[ -n "$HDR_PRIMARIES" ]] && a+=(-color_primaries:v:0 "$HDR_PRIMARIES")
    [[ -n "$HDR_TRANSFER" ]] && a+=(-color_trc:v:0 "$HDR_TRANSFER")
    [[ -n "$HDR_MATRIX" ]] && a+=(-colorspace:v:0 "$HDR_MATRIX")
    [[ -n "$HDR_RANGE" ]] && a+=(-color_range:v:0 "$HDR_RANGE")

    (( ${#a[@]} )) && printf '%q ' "${a[@]}"
    return 0
}

# confirm_dynamic_range LABEL  (after probe_hdr)
#
# Prints the dynamic range summary and Dolby Vision warnings. Returns 1
# when the user declines to continue with a Dolby Vision source.
confirm_dynamic_range() {
    local label="$1"
    local ans

    echo "Dynamic range:  $(hdr_description)"

    case "$HDR_KIND" in
        HDR10)
            if [[ -n "$HDR_MASTER" || -n "$HDR_CLL" ]]; then
                echo "                HDR10 kept: PQ/BT.2020 signalling + mastering display${HDR_CLL:+ + MaxCLL/MaxFALL ($HDR_CLL)}"
            else
                echo "                HDR10 kept: PQ/BT.2020 signalling (source has no mastering metadata)"
            fi
            ;;
        HLG)
            echo "                HLG kept: BT.2020/HLG signalling"
            ;;
    esac

    (( HDR_DV == 1 )) || return 0

    echo
    echo "WARNING: $label contains Dolby Vision (profile ${HDR_DV_PROFILE:-?})."
    echo "  Dolby Vision metadata will NOT be preserved. The output is plain $HDR_KIND."

    if [[ "${HDR_DV_COMPAT:-}" == "0" ]]; then
        echo "  This profile has no HDR10/SDR compatible base layer:"
        echo "  colours of the re-encoded video will be WRONG on every player."
        read -rp "Encode anyway? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]]
        return
    fi

    read -rp "Continue without Dolby Vision? [Y/n]: " ans
    [[ ! "$ans" =~ ^[Nn]$ ]]
}

# ------------------------------------------------------------
# Stream mapping for the final (pass 2) mux
# ------------------------------------------------------------

# build_stream_map FILE MAIN_VIDEO_INDEX
#
# The main video stream becomes output video #0 (the only stream given
# to libx265). Every other stream is mapped explicitly in file order and
# stream-copied, except:
#   - cover art (attached pictures) -> not muxed by ffmpeg (its MKV muxer
#     would turn them into extra video tracks); re-added afterwards as
#     real MKV attachments by item_add_cover (MAP_COVERS)
#   - mov_text subtitles  -> converted to SRT (MKV cannot store mov_text)
#   - data streams / unsupported subtitles -> not mapped (MKV cannot
#     store them); listed in MAP_NOTES
#
# Sets:
#   MAP_ARGS        shell-quoted "-map ..." tokens
#   MAP_CODEC_ARGS  shell-quoted per-stream codec overrides
#   MAP_COVERS      array of "index<TAB>filename<TAB>mimetype"
#   MAP_NOTES       array of human-readable notes
#   MAP_AUDIO_COUNT number of mapped audio streams
build_stream_map() {
    local file="$1"
    local vidx="$2"
    local idx type codec att rest name mime
    local sub_n=0
    local maps=(-map "0:$vidx")
    local codecs=()

    MAP_NOTES=()
    MAP_COVERS=()
    MAP_AUDIO_COUNT=0

    while IFS=$'\t' read -r idx type codec att rest; do
        [[ "$idx" == "$vidx" ]] && continue

        case "$type" in
            video)
                if (( att == 1 )); then
                    name=$(stream_tag "$file" "$idx" filename)
                    mime=$(stream_tag "$file" "$idx" mimetype)

                    case "$codec" in
                        mjpeg) [[ -n "$name" ]] || name="cover.jpg"; [[ -n "$mime" ]] || mime="image/jpeg" ;;
                        png)   [[ -n "$name" ]] || name="cover.png"; [[ -n "$mime" ]] || mime="image/png" ;;
                        bmp)   [[ -n "$name" ]] || name="cover.bmp"; [[ -n "$mime" ]] || mime="image/bmp" ;;
                        gif)   [[ -n "$name" ]] || name="cover.gif"; [[ -n "$mime" ]] || mime="image/gif" ;;
                        webp)  [[ -n "$name" ]] || name="cover.webp"; [[ -n "$mime" ]] || mime="image/webp" ;;
                    esac

                    if [[ -n "$name" && -n "$mime" ]]; then
                        MAP_COVERS+=("$idx"$'\t'"$name"$'\t'"$mime")
                        MAP_NOTES+=("stream $idx: cover art ($codec) kept as MKV attachment \"$name\"")
                    else
                        MAP_NOTES+=("stream $idx: attached picture ($codec) cannot be stored, dropped")
                    fi
                else
                    maps+=(-map "0:$idx")
                    MAP_NOTES+=("stream $idx: extra video ($codec) copied, not re-encoded")
                fi
                ;;
            audio)
                maps+=(-map "0:$idx")
                ((MAP_AUDIO_COUNT += 1))
                ;;
            subtitle)
                case "$codec" in
                    subrip|srt|ass|ssa|webvtt|hdmv_pgs_subtitle|dvd_subtitle|dvb_subtitle|text)
                        maps+=(-map "0:$idx")
                        ((sub_n += 1))
                        ;;
                    mov_text)
                        maps+=(-map "0:$idx")
                        codecs+=("-c:s:$sub_n" srt)
                        MAP_NOTES+=("stream $idx: mov_text subtitle converted to SRT")
                        ((sub_n += 1))
                        ;;
                    *)
                        MAP_NOTES+=("stream $idx: $codec subtitle not supported in MKV, dropped")
                        ;;
                esac
                ;;
            attachment)
                maps+=(-map "0:$idx")
                ;;
            data)
                MAP_NOTES+=("stream $idx: data stream ($codec) cannot be stored in MKV, dropped")
                ;;
            *)
                MAP_NOTES+=("stream $idx: $type ($codec) skipped")
                ;;
        esac
    done < <(stream_info "$file")

    MAP_ARGS=$(printf '%q ' "${maps[@]}")
    MAP_CODEC_ARGS=""
    (( ${#codecs[@]} )) && MAP_CODEC_ARGS=$(printf '%q ' "${codecs[@]}")
    return 0
}

# ------------------------------------------------------------
# Job script generation
# ------------------------------------------------------------

# emit_job_header SESSION TYPE ITEM_COUNT
emit_job_header() {
    echo '#!/usr/bin/env bash'
    echo '# Generated by the compress menus. Runs inside tmux.'
    echo 'set -uo pipefail'
    echo
    printf 'WORK_DIR=%q\n' "$WORK_DIR"
    echo 'source "$WORK_DIR/lib/media_probe.sh"'
    echo 'source "$WORK_DIR/lib/media_stats.sh"'
    echo 'source "$WORK_DIR/lib/bitrate.sh"'
    echo 'source "$WORK_DIR/lib/encode_common.sh"'
    echo 'source "$WORK_DIR/lib/job_runtime.sh"'
    echo
    printf 'job_init %q %q %q "$WORK_DIR"\n' "$1" "$2" "$3"
    echo
}

emit_job_footer() {
    echo 'job_finish'
}

# Ends a generated pass-2 ffmpeg command (output = "$ITEM_PART") and
# appends one item_add_cover step per MAP_COVERS entry.
emit_part_and_covers() {
    local in="$1"
    local c idx name mime

    if (( ${#MAP_COVERS[@]} == 0 )); then
        printf '      -f matroska "$ITEM_PART"\n'
        return
    fi

    printf '      -f matroska "$ITEM_PART" &&\n'

    for ((c = 0; c < ${#MAP_COVERS[@]}; c++)); do
        IFS=$'\t' read -r idx name mime <<< "${MAP_COVERS[$c]}"
        printf '   item_add_cover %q %q %q %q' "$in" "$idx" "$name" "$mime"
        (( c + 1 < ${#MAP_COVERS[@]} )) && printf ' &&'
        printf '\n'
    done
}

# emit_encode_item INDEX IN OUT TIER VIDEO_KBPS FILTER AUDIO_ARGS PASSLOG OVERWRITE
#
# Two-pass libx265 encode of the main video stream; every other stream
# is mapped explicitly (see build_stream_map). AUDIO_ARGS is a string
# of shell-quoted ffmpeg tokens using audio-relative specifiers
# (-c:a:N / -b:a:N); empty means all audio is copied.
emit_encode_item() {
    local index="$1"
    local in="$2"
    local out="$3"
    local tier="$4"
    local kbps="$5"
    local filter="$6"
    local audio_args="$7"
    local passlog="$8"
    local overwrite="$9"

    local vidx x265 color dv=""

    vidx=$(main_video_index "$in")
    probe_hdr "$in" "$vidx"
    build_stream_map "$in" "$vidx"

    x265=$(x265_color_params)
    color=$(color_output_args)

    # Never let libx265 write a Dolby Vision RPU: the re-encoded stream
    # is not a valid DV stream (FFmpeg >= 7.1 defaults this to auto).
    if libx265_has_option dolbyvision; then
        dv="-dolbyvision:v:0 0 "
    fi

    local p1="pass=1:stats=$passlog${x265:+:$x265}"
    local p2="pass=2:stats=$passlog${x265:+:$x265}"
    local vf=""

    [[ -n "$filter" ]] && vf="-filter:v:0 $(printf '%q' "$filter") "

    printf '# ---- item %s\n' "$index"
    printf 'if item_begin %q %q %q %q %q %q &&\n' \
        "$index" "$in" "$out" "$tier" "$overwrite" "$passlog"

    printf '   item_run 1/2 ffmpeg -y -i %q \\\n' "$in"
    printf '      -map 0:%s %s\\\n' "$vidx" "$vf"
    printf '      -c:v:0 libx265 -preset slow -b:v:0 %sk -pix_fmt:v:0 yuv420p10le %s\\\n' "$kbps" "$dv"
    printf '      -x265-params:v:0 %q %s\\\n' "$p1" "$color"
    printf '      -an -sn -dn -f null /dev/null &&\n'

    printf '   item_run 2/2 ffmpeg -y -i %q \\\n' "$in"
    printf '      %s\\\n' "$MAP_ARGS"
    printf '      -c copy %s\\\n' "$MAP_CODEC_ARGS"
    [[ -n "$vf" ]] && printf '      %s\\\n' "$vf"
    printf '      -c:v:0 libx265 -preset slow -b:v:0 %sk -pix_fmt:v:0 yuv420p10le %s\\\n' "$kbps" "$dv"
    printf '      -x265-params:v:0 %q %s\\\n' "$p2" "$color"
    [[ -n "$audio_args" ]] && printf '      %s \\\n' "$audio_args"
    printf '      -map_metadata 0 -map_chapters 0 -max_muxing_queue_size 4096 \\\n'
    emit_part_and_covers "$in"
    printf 'then\n'
    printf '    item_succeeded\n'
    printf 'else\n'
    printf '    item_failed\n'
    printf 'fi\n\n'
}

# start_job SESSION JOB_FILE  ->  syntax-check and launch in tmux
start_job() {
    local session="$1"
    local job="$2"

    chmod +x "$job"

    if ! bash -n "$job"; then
        echo "Generated job failed the syntax check: $job"
        return 1
    fi

    tmux new-session -d -s "$session" "bash $(printf '%q' "$job")"
}
