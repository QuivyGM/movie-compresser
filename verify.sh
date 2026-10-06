#!/usr/bin/env bash
# Inspect / validate media files under ~/compress/in or ~/compress/out.
#
#   Verify             fast: reads stored MKV statistics tags (BPS,
#                      NUMBER_OF_BYTES) or container bit rates. An MKV
#                      without them is packet-scanned automatically.
#   Validate + update  full packet scan of every file, refreshes MKV
#                      statistics with mkvpropedit and checks the stored
#                      NUMBER_OF_BYTES tags against the scan.
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

inspect_file() {
    local file="$1"
    local root="$2"
    local validate="$3"

    local rel dur bytes res codec vidx
    local vbytes abytes acount complete est approx="" how
    local scan=0 update=0 totals

    rel="${file#"$root"/}"

    echo
    echo "============================================================"
    echo "$rel"
    echo "============================================================"

    dur=$(get_duration "$file" 2>/dev/null || true)
    bytes=$(stat -c %s "$file")
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

    read -r vbytes abytes acount complete est <<< "$(stored_totals "$file" "$vidx" "$dur")"

    if (( validate == 1 )); then
        scan=1
        is_mkv "$file" && update=1
    elif (( complete == 0 )); then
        # Required metadata missing: validate only this file.
        scan=1

        if is_mkv "$file"; then
            if [[ "$root" == "$OUT" ]]; then
                update=1
                echo "  Statistics tags missing: validating this file."
            else
                echo "  Statistics tags missing: packet scan (source files are not modified;"
                echo "  use Validate + update to store the tags)."
            fi
        fi
    fi

    if (( scan == 1 )); then
        echo "  Scanning packets..."
        totals=$(media_stream_totals "$file")
        read -r vbytes abytes <<< "$totals"
        acount=$(stream_info "$file" | awk -F'\t' '$2 == "audio"' | wc -l)
        how="packet scan"
        ((SCANNED++))
    elif (( est == 1 )); then
        approx="~"
        how="stored bit rates (sizes estimated)"
    else
        how="stored MKV statistics tags"
    fi

    local other
    other=$(awk -v t="$bytes" -v v="$vbytes" -v a="$abytes" 'BEGIN {
        x = t - v - a; if (x < 0) x = 0; printf "%.0f", x }')

    row "File size" "$(bytes_to_gib "$bytes") GiB"
    row "Duration" "$(format_hms "$dur")"
    row "Resolution" "${res:-N/A}"
    row "Video codec" "${codec:-N/A}"
    row "Video" "$(rate_size "$vbytes" "$dur" "$approx")"
    row "Audio ($acount track$( ((acount == 1)) || echo s))" "$(rate_size "$abytes" "$dur" "$approx")"
    row "Other / container" "$approx$(bytes_to_gib "$other") GiB"
    row "Total bitrate" "$(bytes_to_mbps "$bytes" "$dur") Mb/s"
    row "Values from" "$how"

    if [[ "$root" == "$OUT" ]]; then
        show_source "$file" "$bytes"
    fi

    if (( update == 1 )); then
        update_and_check "$file" "$vidx" "$vbytes" "$abytes"
    elif (( scan == 1 )) && ! is_mkv "$file"; then
        echo "  Not MKV: statistics tags not updated."
    fi

    ((CHECKED++))
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
            sbytes=$(stat -c %s "$src")
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

    if [[ "$cv" == "MATCH" && "$ca" == "MATCH" ]]; then
        echo "  Metadata: VERIFIED"
        ((VERIFIED++))
    else
        echo "  Metadata: CHECK REQUIRED"
        ((CHECK_REQUIRED++))
    fi
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
    echo "Validate + update rewrites the statistics tags of source MKV files"
    echo "in IN (tags only; audio/video data is not touched)."
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

echo "============================================================"
