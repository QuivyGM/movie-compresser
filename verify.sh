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
#                      Track titles that are wrong are corrected
#                      (check_track_titles; track names only).
#
# Both modes report the COMPRESSION_CRF / COMPRESSION_TIER tags ("not
# recorded" when absent, never a failure) and check the audio / video
# track titles against the actual streams (check_track_titles). Verify
# never modifies a file.
#
# Recursive, so series folders are included. Non-MKV files are only
# inspected; mkvpropedit is never run on them.
set -u

BASE="$HOME/compress"
IN="$BASE/in"
OUT="$BASE/out"
LIB="$BASE/work/lib"

source "$LIB/media_probe.sh"
source "$LIB/media_stats.sh"
source "$LIB/bitrate.sh"
source "$LIB/encode_common.sh"
source "$LIB/naming.sh"

command -v ffprobe >/dev/null || {
    echo "ffprobe not found"
    exit 1
}

is_mkv() {
    [[ "${1,,}" == *.mkv ]]
}

row() {
    printf '  %-20s %s\n' "$1" "$2"
}

# rate_size BYTES DURATION  ->  "6.93 Mb/s  (3.52 GiB)"
rate_size() {
    local bytes="$1"
    local dur="$2"
    local approx="${3:-}"

    if [[ "$bytes" == "N/A" ]]; then
        printf 'N/A'
        return
    fi

    printf '%s%s Mb/s  (%s%s GiB)' \
        "$approx" "$(bytes_to_mbps "$bytes" "$dur")" \
        "$approx" "$(bytes_to_gib "$bytes")"
}

compare_bytes() {
    if [[ "$2" == "N/A" ]]; then
        printf 'MISSING'
    elif [[ "$1" == "$2" ]]; then
        printf 'MATCH'
    else
        awk -v a="$1" -v s="$2" 'BEGIN {
            printf "DIFFERENT (tag %+.3f%%)", (a > 0 ? (s - a) / a * 100 : 0)
        }'
    fi
}

# ------------------------------------------------------------
# Per file
# ------------------------------------------------------------

CHECKED=0
SCANNED=0
UPDATED=0
VERIFIED=0
CHECK_REQUIRED=0
NO_SOURCE=0
TAGS_WRITTEN=0
TAGS_CURRENT=0
TAGS_UNRECOVERED=0
TITLES_OK=0
TITLES_FIX=0
TITLES_UPDATED=0

inspect_file() {
    local file="$1"
    local root="$2"
    local validate="$3"

    local rel dur bytes res codec vidx
    local vbytes abytes acount complete approx="" how
    local scan=0 update=0 totals

    rel="${file#"$root"/}"

    echo
    echo "============================================================"
    echo "$rel"
    echo "============================================================"

    # Symlinks are read through (sizes/metadata of the target) but never
    # written to: the target may belong to another library.
    if [[ -L "$file" ]]; then
        row "Symlink to" "$(readlink -f -- "$file")"
    fi

    dur=$(get_duration "$file" 2>/dev/null || true)
    bytes=$(file_bytes "$file")
    vidx=$(main_video_index "$file")

    if [[ -z "$vidx" ]]; then
        row "File size" "$(bytes_to_gib "$bytes") GiB"
        echo "  No video stream found."
        ((CHECKED++))
        return
    fi

    res=$(get_resolution "$file" "$vidx" 2>/dev/null || true)
    codec=$(ffprobe -v error -select_streams "$vidx" \
        -show_entries stream=codec_name,pix_fmt -of csv=p=0 "$file" 2>/dev/null |
        head -n 1 | sed 's/,/ \/ /')

    if (( validate == 1 )); then
        # Authoritative: always scan, whatever is stored.
        scan=1
        is_mkv "$file" && ! [[ -L "$file" ]] && update=1
        echo "  Scanning packets..."
        totals=$(media_stream_totals "$file")
        read -r vbytes abytes <<< "$totals"
        acount=$(stream_info "$file" | awk -F'\t' '$2 == "audio"' | wc -l)
        how="packet scan"
    else
        # Metadata first; stats_load scans only when it has to.
        STATS_PROGRESS=1 STATS_INDENT="  " stats_load "$file" "$dur" estimate
        read -r vbytes abytes acount complete <<< "$(stats_totals "$vidx")"
        how="$STATS_SOURCE"
        [[ "$STATS_KIND" == "meta" ]] && approx="~"

        # Verify is read-only: missing / rejected statistics are only
        # reported (values above come from the packet scan)
        if (( STATS_SCANNED == 1 )); then
            scan=1
            if is_mkv "$file"; then
                echo "  Statistics tags missing or rejected: values from a packet scan."
                echo "  Verify does not modify files; use Validate + update to store"
                echo "  correct statistics tags."
            fi
        fi
    fi

    (( scan == 1 )) && ((SCANNED++))

    local other
    other=$(awk -v t="$bytes" -v v="$vbytes" -v a="$abytes" 'BEGIN {
        x = t - v - a; if (x < 0) x = 0; printf "%.0f", x }')

    row "File size" "$(bytes_to_gib "$bytes") GiB"
    row "Duration" "$(format_hms "$dur")"
    row "Resolution" "${res:-N/A}"
    row "Video codec" "${codec:-N/A}"
    if [[ "$codec" == hevc* ]]; then
        # rate control from the x265 settings in the stream (current tiers:
        # single-pass CRF, every movie and series tier; two-pass: older outputs)
        local rc
        rc=$(x265_rate_control "$file" "$vidx")
        case "$rc" in
            "")        ;;
            "crf "*)   row "Video encode" "x265 CRF ${rc#crf } (single pass)" ;;
            "2pass "*) row "Video encode" "x265 two-pass, ${rc#2pass } kb/s" ;;
            *)         row "Video encode" "x265 ${rc}" ;;
        esac
    fi
    # COMPRESSION_CRF / COMPRESSION_TIER tags (report only; outputs of
    # earlier versions have none and still verify normally)
    local cname cval
    while IFS=$'\t' read -r cname cval; do
        row "$cname" "$cval"
    done < <(compression_tag_lines "$file")
    probe_hdr "$file" "$vidx"
    row "Dynamic range" "$(hdr_description)"
    row "Video" "$(rate_size "$vbytes" "$dur" "$approx")"
    row "Audio ($acount track$( ((acount == 1)) || echo s))" "$(rate_size "$abytes" "$dur" "$approx")"
    row "Other / container" "$approx$(bytes_to_gib "$other") GiB"
    row "Total bitrate" "$(bytes_to_mbps "$bytes" "$dur") Mb/s"
    row "Values from" "$how"
    [[ -n "${STATS_REJECTED:-}" ]] && (( validate == 0 )) &&
        row "" "(stored statistics rejected: $STATS_REJECTED)"

    if [[ "$root" == "$OUT" ]]; then
        show_source "$file" "$bytes"
    fi

    if (( update == 1 )); then
        update_and_check "$file" "$vidx" "$vbytes" "$abytes"
        # Validate + update only: Verify never writes compression tags
        (( validate == 1 )) && [[ "$root" == "$OUT" ]] &&
            backfill_compression_tags "$file" "$vbytes"
    elif (( scan == 1 )) && ! is_mkv "$file"; then
        echo "  Not MKV: statistics tags not updated."
    elif (( scan == 1 )) && [[ -L "$file" ]]; then
        echo "  Symlink: statistics tags not updated (the link target is never modified)."
    fi

    check_track_titles "$file" "$vidx" "$validate"

    ((CHECKED++))
}

# check_track_titles FILE VIDX VALIDATE
#
# Audio titles against the standard title of the ACTUAL track
# (audio_std_title: codec / profile / channels / layout / language /
# dispositions from the stream; the old title only keeps its description
# such as "Director's Commentary"), with the claims the stream disproves
# (audio_title_false_claims). The main video title against the stream
# (video_title_false_claims: codec, resolution, HDR / Dolby Vision /
# HDR10+, bit depth); video titles have no standard form, so only
# disproved claims are removed and a missing title stays missing.
#
# Verify only reports. Validate + update writes the corrected titles to
# an MKV (not a symlink) with mkvpropedit: track names only, no remux,
# no stream data touched; nothing is written when every title is already
# correct, so a repeated run changes nothing. The FFmpeg streams are
# mapped to Matroska track numbers by MKVToolNix identification first
# (mkv_track_map; FFmpeg and Matroska numbering are never assumed to
# match); when that mapping is not certain nothing is written. The
# titles are read back through MKVToolNix and FFmpeg.
check_track_titles() {
    local file="$1" vidx="$2" validate="$3"
    local -a edits=() f
    local -A want=()          # FFmpeg stream index -> new title ("-" = none)
    local vcodec="" vprof="" vpix="" res vbits vtitle="-" claims new h10p
    # HDR10+ is looked for in the first frames only: not finding it does
    # not prove a title claiming it wrong
    h10p=$( ((HDR_HDR10PLUS == 1)) && echo 1 || echo "?")
    local an=0 fixes=0 label obj note lang k v

    while IFS='=' read -r k v; do
        v="${v%$'\r'}"
        case "$k" in
            codec_name) vcodec="$v" ;;
            profile)    vprof="$v" ;;
            pix_fmt)    vpix="$v" ;;
        esac
    done < <(ffprobe -v error -select_streams "$vidx" -show_entries stream=codec_name,profile,pix_fmt \
        -of default=nw=1 "$file" 2>/dev/null)
    res=$(get_resolution "$file" "$vidx" 2>/dev/null || true)
    vbits=$(video_pix_bits "$vpix")

    # main video title
    while IFS=$'\t' read -r -a f; do
        if [[ "${f[0]}" == "$vidx" ]]; then
            vtitle="${f[13]}"
            break
        fi
    done < <(stream_meta "$file")

    row "Video stream" "$vcodec${vprof:+ $vprof}, ${res:-?}${vbits:+, $vbits-bit}, $HDR_KIND$( ((HDR_DV == 1)) && echo " + Dolby Vision")$( ((HDR_HDR10PLUS == 1)) && echo " + HDR10+")"
    if [[ "$vtitle" == "-" ]]; then
        row "Video title" "none (no video title is invented)"
    else
        claims=$(video_title_false_claims "$vtitle" "$vcodec" "$res" "$HDR_KIND" "$HDR_DV" "$h10p" "$vbits")
        if [[ -z "$claims" ]]; then
            row "Video title" "\"$vtitle\" - OK (nothing in it contradicts the stream)"
        else
            new=$(video_title_rewrite "$vtitle" "$vcodec" "$res" "$HDR_KIND" "$HDR_DV" "$h10p" "$vbits")
            row "Video title" "\"$vtitle\" - STALE (the stream is not: $claims)"
            row "" "-> $([[ -n "$new" ]] && echo "\"$new\"" || echo "title removed (nothing else in it)")"
            want[$vidx]="${new:--}"
            ((fixes += 1))
        fi
    fi

    # audio: every track against its standard title
    while IFS=$'\t' read -r -a f; do
        ((an += 1))
        new=$(audio_std_title "${f[12]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "${f[13]}" \
            "${f[8]}" "${f[9]}" "${f[10]}" 1)
        lang="${f[12]}"; [[ "$lang" == "-" ]] && lang="und"
        label="$(audio_track_label "${f[2]}" "${f[3]}" "${f[5]}" "${f[4]}"), $lang"
        (( f[6] == 1 )) && label+=", default"
        (( f[7] == 1 )) && label+=", forced"
        (( f[8] == 1 )) && label+=", commentary"
        (( f[10] == 1 )) && label+=", descriptive"
        note=""
        [[ "$lang" == und ]] && note+="; language not set (left unset)"
        obj=$(audio_object_kind "${f[2]}" "${f[3]}" "${f[13]}")
        [[ "$obj" == *"(per track title)"* ]] &&
            note+="; ${obj%% (*} named only in the title (the stream does not report it; kept, not confirmed)"

        if [[ "${f[13]}" == "$new" ]]; then
            row "Audio $an" "$label | \"${f[13]}\" - STANDARD${note}"
            continue
        fi
        if [[ "${f[13]}" == "-" ]]; then
            row "Audio $an" "$label | no title - MISSING${note}"
        else
            claims=$(audio_title_false_claims "${f[13]}" "${f[2]}" "${f[4]}" "${f[3]}")
            if [[ -n "$claims" ]]; then
                row "Audio $an" "$label | \"${f[13]}\" - STALE (the track is not: $claims)${note}"
            else
                row "Audio $an" "$label | \"${f[13]}\" - NOT STANDARD${note}"
            fi
        fi
        row "" "-> \"$new\""
        want[${f[0]}]="$new"
        ((fixes += 1))
    done < <(_audio_rows "$file")

    if (( fixes == 0 )); then
        row "Track titles" "OK (nothing to correct)"
        ((TITLES_OK++))
        return
    fi
    if (( validate == 0 )); then
        row "Track titles" "$fixes to correct (Verify does not modify files; Validate + update corrects them)"
        ((TITLES_FIX++))
        return
    fi
    if ! is_mkv "$file"; then
        row "Track titles" "$fixes to correct; not updated (not MKV)"
        ((TITLES_FIX++))
        return
    fi
    if [[ -L "$file" ]]; then
        row "Track titles" "$fixes to correct; not updated (symlink: the link target is never modified)"
        ((TITLES_FIX++))
        return
    fi
    if ! command -v mkvpropedit >/dev/null 2>&1 || ! command -v mkvmerge >/dev/null 2>&1; then
        row "Track titles" "$fixes to correct; MKVToolNix (mkvpropedit / mkvmerge) not found: not updated - CHECK REQUIRED"
        ((CHECK_REQUIRED++))
        return
    fi
    # FFmpeg stream -> Matroska track number(s), certain before any write.
    # Tracks that MKVToolNix and FFmpeg cannot tell apart (identical in
    # every compared property) must all get the same title, else nothing
    # is written.
    local map ffi nums x
    local -A gwant=() byno=()
    if ! map=$(mkv_track_map "$file"); then
        row "Track titles" "NOT UPDATED: track mapping not certain (${map#ERR$'\t'}) - CHECK REQUIRED"
        ((CHECK_REQUIRED++))
        return
    fi
    while IFS=$'\t' read -r ffi nums; do
        [[ -n "$ffi" ]] || continue
        x="${want[$ffi]-$'\001'}"
        if [[ -n "${gwant[$nums]+x}" && "${gwant[$nums]}" != "$x" ]]; then
            row "Track titles" "NOT UPDATED: tracks $nums look identical but need different titles - CHECK REQUIRED"
            ((CHECK_REQUIRED++))
            return
        fi
        gwant[$nums]="$x"
    done <<< "$map"
    for nums in "${!gwant[@]}"; do
        [[ "${gwant[$nums]}" != $'\001' ]] || continue
        IFS=, read -ra f <<< "$nums"
        for x in "${f[@]}"; do
            byno[$x]="${gwant[$nums]}"
            if [[ "${gwant[$nums]}" == "-" ]]; then
                edits+=(--edit "track:@$x" --delete name)
            else
                edits+=(--edit "track:@$x" --set "name=${gwant[$nums]}")
            fi
        done
    done
    for ffi in "${!want[@]}"; do
        grep -q "^$ffi"$'\t' <<< "$map" || {
            row "Track titles" "NOT UPDATED: FFmpeg stream $ffi has no Matroska track - CHECK REQUIRED"
            ((CHECK_REQUIRED++))
            return
        }
    done

    if ! mkvpropedit "$file" "${edits[@]}" > /dev/null 2>&1; then
        row "Track titles" "mkvpropedit FAILED: titles not updated - CHECK REQUIRED"
        ((CHECK_REQUIRED++))
        return
    fi

    # read back: every corrected title must now be the planned one, by
    # Matroska track number (MKVToolNix) and by FFmpeg stream
    local bad=0
    while IFS=$'\t' read -r -a f; do
        [[ -n "${byno[${f[2]}]+x}" && "${f[8]}" != "${byno[${f[2]}]}" ]] && bad=1
    done < <(mkv_identify_tracks "$file")
    while IFS=$'\t' read -r -a f; do
        [[ -n "${want[${f[0]}]+x}" && "${f[13]}" != "${want[${f[0]}]}" ]] && bad=1
    done < <(stream_meta "$file")

    if (( bad == 0 )); then
        row "Track titles" "UPDATED ($fixes title(s); track names only, streams untouched)"
        ((TITLES_UPDATED++))
    else
        row "Track titles" "written, but the read-back differs - CHECK REQUIRED"
        ((CHECK_REQUIRED++))
    fi
}

show_source() {
    local file="$1"
    local bytes="$2"
    local result kind src sbytes p

    result=$(find_source_for_output "$file" "$IN" "$OUT")
    kind="${result%%$'\t'*}"

    case "$kind" in
        OK)
            src="${result#*$'\t'}"
            sbytes=$(file_bytes "$src")
            row "Source" "${src#"$IN"/}"
            row "" "$(bytes_to_gib "$sbytes") GiB -> $(bytes_to_gib "$bytes") GiB  ($(awk -v s="$sbytes" -v o="$bytes" 'BEGIN { printf "%+.1f%%", (s > 0 ? (o - s) / s * 100 : 0) }'))"
            row "Tier" "$(output_tier "$(basename "$file")")"
            ;;
        AMBIGUOUS)
            row "Source" "AMBIGUOUS - several candidates in IN, not paired:"
            IFS=$'\t' read -ra p <<< "${result#*$'\t'}"
            for src in "${p[@]}"; do
                row "" "${src#"$IN"/}"
            done
            ((NO_SOURCE++))
            ;;
        *)
            row "Source" "not found in IN"
            ((NO_SOURCE++))
            ;;
    esac
}

update_and_check() {
    local file="$1"
    local vidx="$2"
    local vbytes="$3"
    local abytes="$4"
    local tags tv ta cv ca

    echo
    echo "  Updating MKV statistics tags..."

    if ! refresh_mkv_stats "$file" >/dev/null 2>&1; then
        if ! command -v mkvpropedit >/dev/null 2>&1; then
            echo "  mkvpropedit not found: metadata not updated."
        else
            echo "  mkvpropedit FAILED: metadata not updated."
        fi
        echo "  Metadata: CHECK REQUIRED"
        ((CHECK_REQUIRED++))
        return
    fi

    ((UPDATED++))

    tags=$(stored_tag_totals "$file" "$vidx")
    read -r tv ta <<< "$tags"

    cv=$(compare_bytes "$vbytes" "$tv")
    ca=$(compare_bytes "$abytes" "$ta")

    printf '  %-20s %-14s %-14s %s\n' "" "PACKETS" "TAG" ""
    printf '  %-20s %-14s %-14s %s\n' "Video bytes" "$vbytes" "$tv" "$cv"
    printf '  %-20s %-14s %-14s %s\n' "Audio bytes" "$abytes" "$ta" "$ca"

    # A normal (menu) read must now use the tags, without a scan, and
    # return the scanned values.
    local mv ma
    stats_load "$file" "" exact
    read -r mv ma _ _ <<< "$(stats_totals "$vidx")"

    if [[ "$STATS_KIND" == "tags" && "$mv" == "$vbytes" && "$ma" == "$abytes" ]]; then
        row "Metadata-first read" "MATCH (stored MKV statistics tags, no packet scan needed)"
    elif [[ "$STATS_KIND" == "tags" ]]; then
        row "Metadata-first read" "DIFFERENT (video $mv, audio $ma bytes)"
        cv="DIFFERENT"
    else
        row "Metadata-first read" "still falls back to a packet scan${STATS_REJECTED:+ ($STATS_REJECTED)}"
        cv="DIFFERENT"
    fi

    if [[ "$cv" == "MATCH" && "$ca" == "MATCH" ]]; then
        echo "  Metadata: VERIFIED"
        ((VERIFIED++))
    else
        echo "  Metadata: CHECK REQUIRED"
        ((CHECK_REQUIRED++))
    fi
}

# backfill_compression_tags FILE VIDEO_BYTES
#
# Validate + update: writes / corrects COMPRESSION_CRF / COMPRESSION_TIER
# from the job records in work/logs (compression_record_lookup; the
# packet-scanned VIDEO_BYTES identify the encode). Without a matching
# record nothing is written (no value is guessed). Tags that already
# hold the recorded values are not rewritten.
backfill_compression_tags() {
    local file="$1" vbytes="$2" rec rc crf tier from ccrf ctier what

    rec=$(compression_record_lookup "$BASE/work/logs" "$file" "$vbytes")
    rc=$?
    IFS=$'\t' read -r ccrf ctier <<< "$(compression_tags "$file")"

    if (( rc != 0 )); then
        if (( rc == 2 )); then
            what="not recovered (job records disagree)"
        else
            what="not recovered (no job record of this encode)"
        fi
        [[ "$ccrf" != "-" ]] && what+="; existing tags left unchanged" || what+="; left missing"
        row "Compression tags" "$what"
        ((TAGS_UNRECOVERED++))
        return
    fi

    IFS=$'\t' read -r crf tier from <<< "$rec"
    # a record without a menu tier leaves an existing tier tag as it is
    [[ "$tier" == "-" ]] && tier=""
    [[ -z "$tier" && "$ctier" != "-" ]] && tier="$ctier"

    if [[ "$ccrf" == "$crf" && "$ctier" == "${tier:--}" ]]; then
        row "Compression tags" "UNCHANGED (CRF $crf${tier:+, $tier}; matches $from)"
        ((TAGS_CURRENT++))
        return
    fi

    local tmp ok=1
    tmp=$(mktemp -d)
    mkv_set_compression_tags "$file" "$crf" "$tier" "$tmp" || ok=0
    rm -rf -- "$tmp"
    if (( ok == 0 )); then
        row "Compression tags" "write FAILED (mkvtoolnix); left unchanged"
        ((CHECK_REQUIRED++))
        return
    fi

    if [[ "$ccrf" == "-" ]]; then
        row "Compression tags" "WRITTEN (CRF $crf${tier:+, $tier}; from $from)"
    else
        row "Compression tags" "CORRECTED (CRF $ccrf$([[ "$ctier" != "-" ]] && echo ", $ctier") -> CRF $crf${tier:+, $tier}; from $from)"
    fi
    ((TAGS_WRITTEN++))
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

[[ "$ROOT" == "$OUT" ]] && build_source_index "$IN"

while IFS= read -r -d '' file; do
    inspect_file "$file" "$ROOT" "$VALIDATE"
done < <(media_files_recursive "$ROOT")

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
