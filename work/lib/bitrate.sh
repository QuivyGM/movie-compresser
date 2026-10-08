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

# size_text BYTES  ->  "6.40 GiB", or "0.02 GiB (21.4 MiB)" below 0.1 GiB
size_text() {
    if [[ ! "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf 'N/A'
        return
    fi

    awk -v b="$1" 'BEGIN {
        g = b / 1073741824
        if (g >= 0.1) printf "%.2f GiB", g
        else          printf "%.2f GiB (%.1f MiB)", g, b / 1048576
    }'
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

# estimate_error_pct ESTIMATE ACTUAL  ->  "+6.3%" (actual vs estimate;
# "N/A" when either is unknown)
estimate_error_pct() {
    if [[ ! "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ || ! "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf 'N/A'
        return
    fi

    awk -v e="$1" -v a="$2" 'BEGIN {
        if (e > 0) printf "%+.1f%%", (a - e) / e * 100
        else       printf "N/A"
    }'
}

# gib_text GIB  ->  "20.00"
gib_text() {
    awk -v g="${1:-0}" 'BEGIN { printf "%.2f", g }'
}

# gib_distance ACTUAL_BYTES TARGET_BYTES  ->  "+0.40" / "-1.30" (GiB;
# "N/A" when either is unknown)
gib_distance() {
    if [[ ! "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ || ! "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf 'N/A'
        return
    fi

    awk -v a="$1" -v t="$2" 'BEGIN { printf "%+.2f", (a - t) / 1073741824 }'
}

# quality_band_class ACTUAL_BYTES MIN_BYTES MAX_BYTES
#
# Movie Quality result against its acceptable band:
#   ACCEPTABLE    MIN..MAX
#   OUTSIDE BAND  anything else
# Prints "N/A" when a value is unknown.
quality_band_class() {
    local v
    for v in "${1:-}" "${2:-}" "${3:-}"; do
        if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            printf 'N/A'
            return
        fi
    done

    awk -v a="$1" -v lo="$2" -v hi="$3" 'BEGIN {
        if (a < lo || a > hi) printf "OUTSIDE BAND"
        else                  printf "ACCEPTABLE"
    }'
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
