#!/usr/bin/env bash

video_size_gib() {
    awk -v mbps="$1" -v sec="$2" 'BEGIN {
        printf "%.3f", (mbps * 1000000 * sec / 8) / 1073741824
    }'
}

bitrate_for_gib() {
    awk -v gib="$1" -v sec="$2" 'BEGIN {
        printf "%.3f", gib * 1073741824 * 8 / sec / 1000000
    }'
}

gib_per_hour_to_kbps() {
    awk -v gib="$1" 'BEGIN {
        printf "%.0f", gib * 1073741824 * 8 / 3600 / 1000
    }'
}

audio_kbps_for_gib() {
    awk -v gib="$1" -v sec="$2" 'BEGIN {
        printf "%.0f", gib * 1073741824 * 8 / sec / 1000 * 0.98
    }'
}

min_value() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (a < b) printf "%.3f", a
        else       printf "%.3f", b
    }'
}

max_value() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (a > b) printf "%.3f", a
        else       printf "%.3f", b
    }'
}

# ------------------------------------------------------------
# Formatting (plain numbers; callers add units)
# ------------------------------------------------------------

# bytes_to_gib BYTES  ->  "1.23" ("N/A" passes through)
bytes_to_gib() {
    if [[ ! "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf 'N/A'
        return
    fi

    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1073741824 }'
}

# bytes_to_mbps BYTES SECONDS  ->  "12.34"
bytes_to_mbps() {
    if [[ ! "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf 'N/A'
        return
    fi

    awk -v b="$1" -v d="${2:-0}" 'BEGIN {
        if (d > 0) printf "%.2f", b * 8 / d / 1000000
        else       printf "N/A"
    }'
}

# bps_to_mbps BITS_PER_SECOND  ->  "12.34"
bps_to_mbps() {
    if [[ ! "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf 'N/A'
        return
    fi

    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1000000 }'
}

# format_hms SECONDS  ->  HH:MM:SS
format_hms() {
    local sec="${1:-}"

    if [[ ! "$sec" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf 'N/A'
        return
    fi

    sec=$(awk -v s="$sec" 'BEGIN { printf "%.0f", s }')

    printf '%02d:%02d:%02d' \
        $((sec / 3600)) \
        $(((sec % 3600) / 60)) \
        $((sec % 60))
}
