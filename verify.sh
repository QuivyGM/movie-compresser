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

source "$LIB/ui.sh"
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
FILE_ISSUES=0       # problems of the current file not counted above
FILE_VBYTES=""      # main video bytes of the current file
FILE_RC=""          # x265 rate control of the current file ("crf 21.0")

inspect_file() {
    local file="$1"
    local root="$2"
    local validate="$3"

    local rel dur bytes res codec vidx
    local vbytes abytes acount complete approx="" how
    local scan=0 update=0 totals

    rel="${file#"$root"/}"
    FILE_VBYTES=""
    FILE_RC=""

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
        ((FILE_ISSUES++))
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
                ((FILE_ISSUES++))
                echo "  Statistics tags missing or rejected: values from a packet scan."
                echo "  Verify does not modify files; use Validate + update to store"
                echo "  correct statistics tags."
            fi
        fi
    fi

    (( scan == 1 )) && ((SCANNED++))
    FILE_VBYTES="$vbytes"

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
        FILE_RC="$rc"
        case "$rc" in
            "")        ;;
            "crf "*)   row "Video encode" "x265 CRF ${rc#crf } (single pass)" ;;
            "2pass "*) row "Video encode" "x265 two-pass, ${rc#2pass } kb/s" ;;
            *)         row "Video encode" "x265 ${rc}" ;;
        esac
    fi
    # compression tags (report only; outputs of earlier versions have
    # none or only some and still verify normally)
    local cname cval ckind
    while IFS=$'\t' read -r cname cval; do
        row "$cname" "$cval"
    done < <(compression_tag_lines "$file")
    # a compression tag stored more than once (needs MKVToolNix; ffprobe
    # shows only one value per name)
    if is_mkv "$file"; then
        while IFS=$'\t' read -r cname ckind cval; do
            [[ -n "$cname" ]] || continue
            if [[ "$ckind" == conflict ]]; then
                row "Tag conflict" "$cname stored with different values ($cval) - CHECK REQUIRED"
                ((CHECK_REQUIRED++))
            else
                row "Tag duplicate" "$cname stored more than once with the same value ($cval)"
            fi
        done < <(compression_tag_duplicates "$file")
    fi
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

    # measured audio rates for the titles: Verify has them from stats_load;
    # Validate + update reads the stored statistics (just refreshed for an
    # updated MKV; read only, never a second scan)
    local measured=""
    if (( validate == 0 )); then
        measured="$STATS_LINES"
    elif stats_load "$file" "$dur" tags; then
        measured="$STATS_LINES"
    fi
    check_track_titles "$file" "$vidx" "$validate" "$measured"

    ((CHECKED++))
}

# check_track_titles FILE VIDX VALIDATE [MEASURED]
#
# Audio titles against the standard title of the ACTUAL track
# (audio_std_title: codec / profile / channels / layout / bit rate /
# language / dispositions from the stream; the old title only keeps its
# description such as "Director's Commentary"), with the claims the
# stream disproves (audio_title_false_claims). The bit rate is the
# stream's constant rate, else the measured average of MEASURED
# (stats_load STATS_LINES; "" = unknown, left out). The main video title
# against its standard title (video_std_title_of: codec, resolution, bit
# depth, HDR format, the CRF the stream records); a title the stream
# disproves (video_title_false_claims) is reported STALE.
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
    local file="$1" vidx="$2" validate="$3" measured="${4:-}"
    local -a f
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
    # main video against its standard title (codec / resolution / bit
    # depth / HDR format of the stream; the CRF only from the x265
    # settings in the stream or this tool's COMPRESSION_CRF tag)
    new=$(video_std_title_of "$file" "$vidx" auto)
    if [[ -z "$new" ]]; then
        row "Video title" "$([[ "$vtitle" == "-" ]] && echo "none" || echo "\"$vtitle\"") (stream properties unknown: no standard title)"
    elif [[ "$vtitle" == "$new" ]]; then
        row "Video title" "\"$vtitle\" - STANDARD"
    else
        if [[ "$vtitle" == "-" ]]; then
            row "Video title" "no title - MISSING"
        else
            claims=$(video_title_false_claims "$vtitle" "$vcodec" "$res" "$HDR_KIND" "$HDR_DV" "$h10p" "$vbits")
            if [[ -n "$claims" ]]; then
                row "Video title" "\"$vtitle\" - STALE (the stream is not: $claims)"
            else
                row "Video title" "\"$vtitle\" - NOT STANDARD"
            fi
        fi
        row "" "-> \"$new\""
        want[$vidx]="$new"
        ((fixes += 1))
    fi

    # audio stream facts a title's bit rate / bit depth / sample rate can
    # be checked against (audio_title_stream_facts; unknown = ""), and
    # the measured average rate of the actual packets (MEASURED:
    # statistics tags / packet scan) for tracks without a constant rate
    local -A afact=() ameas=()
    local ai="" abr="" araw="" asr="" kb
    while IFS=$'\t' read -r ai abr araw asr; do
        [[ -n "$ai" ]] && afact[$ai]="$abr|$araw|$asr"
    done < <(audio_title_facts "$file")
    while IFS=$'\t' read -r ai kb; do
        [[ -n "$ai" ]] && ameas[$ai]="$kb"
    done < <(audio_measured_kbps "$measured")

    # audio: every track against its standard title
    local fn fb fr unk
    while IFS=$'\t' read -r -a f; do
        IFS='|' read -r abr araw asr <<< "${afact[${f[0]}]:-||}"
        read -r fn fb fr <<< "$(audio_title_stream_facts "${f[2]}" "${f[3]}" "$abr" "$araw" "$asr" "${f[4]}")"
        [[ "$fn" == - ]] && fn=""
        [[ "$fb" == - ]] && fb=""
        [[ "$fr" == - ]] && fr=""
        ((an += 1))
        kb=$(audio_title_kbps "${f[2]}" "${f[3]}" "$abr" "$araw" "$asr" "${f[4]}" "${ameas[${f[0]}]:-}")
        new=$(audio_std_title "${f[12]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "${f[13]}" \
            "${f[8]}" "${f[9]}" "${f[10]}" 1 "$kb")
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
        [[ "${f[2]}" =~ ^(ac3|eac3)$ ]] && audio_title_ex "${f[13]}" &&
            note+="; Dolby Digital EX named only in the title (the stream flag is not read; kept, not confirmed)"
        # a rate is checked against the measured average when there is
        # no constant rate
        unk=$(audio_title_unverified "${f[13]}" "${f[2]}" "${f[4]}" "${f[3]}" \
            "${fn:-${ameas[${f[0]}]:+$(( ameas[${f[0]}] * 1000 ))}}" "$fb" "$fr")
        [[ -n "$unk" ]] && note+="; UNKNOWN (cannot be checked against the stream): $unk"
        unk=$(audio_title_warning "${f[13]}" "${f[12]}")
        [[ -n "$unk" ]] && note+="; WARNING: $unk"

        if [[ "${f[13]}" == "$new" ]]; then
            row "Audio $an" "$label | \"${f[13]}\" - STANDARD${note}"
            continue
        fi
        if [[ "${f[13]}" == "-" ]]; then
            row "Audio $an" "$label | no title - MISSING${note}"
        else
            claims=$(audio_title_false_claims "${f[13]}" "${f[2]}" "${f[4]}" "${f[3]}" "$fn" "$fb" "$fr")
            if [[ -n "$claims" ]]; then
                row "Audio $an" "$label | \"${f[13]}\" - STALE (INCORRECT per the stream: $claims)${note}"
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
    # mapped to Matroska track numbers first, written only when that is
    # certain, read back (mkv_write_track_titles)
    local rc
    mkv_write_track_titles "$file" want
    rc=$?
    case "$rc" in
        0)
            row "Track titles" "UPDATED ($fixes title(s); track names only, streams untouched)"
            ((TITLES_UPDATED++))
            ;;
        3)  row "Track titles" "$fixes to correct; $MKV_TITLES_MSG: not updated - CHECK REQUIRED" ;;
        7)  row "Track titles" "mkvpropedit FAILED: titles not updated - CHECK REQUIRED" ;;
        8)  row "Track titles" "$MKV_TITLES_MSG - CHECK REQUIRED" ;;
        *)  row "Track titles" "NOT UPDATED: $MKV_TITLES_MSG - CHECK REQUIRED" ;;
    esac
    (( rc == 0 )) || ((CHECK_REQUIRED++))
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
# hold the recorded values are not rewritten. The provenance tags
# (MOVIE_COMPRESSER_VERSION etc.) are left exactly as they are
# (mkv_set_compression_tags without VERSION): the version of the encode
# is history, not the version running this check, and none is invented
# for an output of an earlier version.
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

# ------------------------------------------------------------
# Scope: everything, one show (top-level folder) or one season of a show
# ------------------------------------------------------------

# top_dirs ROOT  ->  the top-level folders of ROOT that hold media files
top_dirs() {
    local d
    while IFS= read -r -d '' d; do
        [[ -n "$(DISCOVERY_QUIET=1 media_files_recursive "$d" | head -c 1)" ]] && printf '%s\n' "$d"
    done < <(DISCOVERY_QUIET=1 discover_paths "$1" 1 d)
}

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

declare -A GROUP_FILES=() SHOW_SEEN=()
SHOW_ORDER=()
for file in "${FILES[@]+"${FILES[@]}"}"; do
    rel="${file#"$ROOT"/}"
    if [[ "$rel" == */* ]]; then
        show="${rel%%/*}"
        season=$(series_group_name "$ROOT/$show" "$(dirname -- "$file")")
    else
        show=""
        season=""
    fi
    if [[ -z "${SHOW_SEEN["k$show"]+x}" ]]; then
        SHOW_SEEN["k$show"]=1
        SHOW_ORDER+=("$show")
    fi
    GROUP_FILES["$show"$'\t'"$season"]+="$file"$'\n'
done

# show_seasons SHOW  ->  its season keys in season order
show_seasons() {
    local key
    for key in "${!GROUP_FILES[@]}"; do
        [[ "${key%%$'\t'*}" == "$1" ]] && printf '%s\n' "${key#*$'\t'}"
    done | series_groups_sort
}

# file_status BEFORE...  ->  VERIFIED / CORRECTED / UNPAIRED / CHECK
# REQUIRED of the file just inspected, from the counters before it
file_status() {
    local cr="$1" tf="$2" ns="$3" tu="$4" tw="$5" fi_="$6"
    if (( CHECK_REQUIRED > cr || TITLES_FIX > tf || FILE_ISSUES > fi_ )); then
        echo "CHECK REQUIRED"
    elif (( NO_SOURCE > ns )); then
        echo "UNPAIRED"
    elif (( TITLES_UPDATED > tu || TAGS_WRITTEN > tw )); then
        echo "CORRECTED"
    else
        echo "VERIFIED"
    fi
}

# file_tier_crf FILE  ->  "High CRF 20", "CRF 21", "source", "-"
file_tier_crf() {
    local tier="" crf=""
    if [[ "$ROOT" == "$OUT" ]]; then
        tier=$(output_tier "$(basename "$1")")
        [[ "$tier" == Unknown ]] && tier=""
    else
        tier="source"
    fi
    IFS=$'\t' read -r crf _ <<< "$(compression_tags "$1" 2>/dev/null)"
    [[ "$crf" == "-" ]] && crf=""
    [[ -z "$crf" && "$FILE_RC" == "crf "* ]] && crf="${FILE_RC#crf }"
    crf="${crf%.0}"
    printf '%s' "${tier}${tier:+${crf:+ }}${crf:+CRF $crf}"
    [[ -n "$tier$crf" ]] || printf -- '-'
}

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
