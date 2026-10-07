#!/usr/bin/env bash
# Terminal output helpers for the menus. Sourced, not executed.
#
# Normal output is compact; COMPRESS_VERBOSE=1 shows the detailed
# diagnostics (policy text, tool paths, per-file verification, HDR
# internals, per-sample progress). Colours only when stdout is a
# terminal (never in redirected / piped output; NO_COLOR disables them).

[[ -n "${UI_LOADED:-}" ]] && return 0
UI_LOADED=1

UI_TTY=0
UI_GREEN="" UI_YELLOW="" UI_RED="" UI_BOLD="" UI_RESET=""

if [[ -t 1 ]]; then
    UI_TTY=1
    if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
        UI_GREEN=$'\e[32m'
        UI_YELLOW=$'\e[33m'
        UI_RED=$'\e[31m'
        UI_BOLD=$'\e[1m'
        UI_RESET=$'\e[0m'
    fi
fi

# ui_verbose  ->  0 with COMPRESS_VERBOSE=1
ui_verbose() {
    [[ "${COMPRESS_VERBOSE:-0}" == 1 ]]
}

# ui_ok / ui_warn / ui_err / ui_bold TEXT  ->  TEXT in green / yellow /
# red / bold (plain when not a terminal); no newline
ui_ok()   { printf '%s%s%s' "$UI_GREEN" "$*" "${UI_GREEN:+$UI_RESET}"; }
ui_warn() { printf '%s%s%s' "$UI_YELLOW" "$*" "${UI_YELLOW:+$UI_RESET}"; }
ui_err()  { printf '%s%s%s' "$UI_RED" "$*" "${UI_RED:+$UI_RESET}"; }
ui_bold() { printf '%s%s%s' "$UI_BOLD" "$*" "${UI_BOLD:+$UI_RESET}"; }

# ui_progress TEXT  ->  rewrites the current terminal line with TEXT
# (nothing when stdout is not a terminal)
ui_progress() {
    (( UI_TTY == 1 )) && printf '\r%s\e[K' "$*"
    return 0
}

# ui_plural N WORD  ->  "1 track", "3 tracks"
ui_plural() {
    printf '%s %s%s' "$1" "$2" "$( [[ "$1" == 1 ]] || echo s)"
}

# ui_bit_depth PIX_FMT  ->  "10-bit" (yuv420p10le), "8-bit" (yuv420p)
ui_bit_depth() {
    if [[ "$1" =~ p([0-9]{2})(le|be)?$ ]]; then
        printf '%s-bit' "$((10#${BASH_REMATCH[1]}))"
    elif [[ -n "$1" && "$1" != "-" ]]; then
        printf '8-bit'
    fi
}

# ui_stats_summary KIND...  ->  "cached", "4 cached, 2 scanned",
# "scanned + refreshed". KIND per file: STATS_KIND (tags | meta |
# packets), with ":refreshed" appended when its MKV statistics were
# refreshed after the scan.
ui_stats_summary() {
    local n=$# tags=0 meta=0 scan=0 refreshed=0 k parts=()

    for k in "$@"; do
        case "${k%%:*}" in
            tags) ((tags += 1)) ;;
            meta) ((meta += 1)) ;;
            *)    ((scan += 1)) ;;
        esac
        [[ "$k" == *:refreshed ]] && ((refreshed += 1))
    done

    if (( tags == n )); then
        ui_ok cached
        return
    fi

    if (( meta == n )); then
        parts=("from metadata")
    elif (( scan == n )); then
        parts=("scanned")
    else
        (( tags )) && parts+=("$tags cached")
        (( meta )) && parts+=("$meta from metadata")
        (( scan )) && parts+=("$scan scanned")
    fi

    local IFS=,
    local s="${parts[*]}"
    s="${s//,/, }"
    (( scan > 0 && refreshed == scan )) && s+=" + refreshed"
    printf '%s' "$s"
}
