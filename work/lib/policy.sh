#!/usr/bin/env bash
# Compression policy: loads and validates compress.conf and holds the
# policy math that uses it (CRF tier selection for movie Quality, High,
# Base and Custom and series High, Base and Custom; audio-menu rates).
# Sourced, not executed. Needs bitrate.sh.
#
# Movie and series compression copy every audio track unchanged; audio
# compression is only done by audio_compress_menu.sh (AUDIO_* settings).
#
# The config is ~/compress/work/lib/compress.conf; COMPRESS_CONF
# overrides the path (tests). There are no built-in fallback values:
# a missing file or setting stops the menu with a clear message, so
# compress.conf is the only place the numbers live.

POLICY_KEYS_POSITIVE=(
    MOVIE_QUALITY_TARGET_VIDEO_GIB MOVIE_QUALITY_ACCEPT_MIN_GIB MOVIE_QUALITY_ACCEPT_MAX_GIB
    MOVIE_HIGH_VIDEO_GIB_PER_HOUR MOVIE_BASE_VIDEO_GIB_PER_HOUR
    SERIES_HIGH_VIDEO_SIZE_CEILING_GIB SERIES_BASE_VIDEO_SIZE_CEILING_GIB
    SERIES_CRF_OUTLIER_PCT
    CRF_SAMPLE_SECONDS
    AUDIO_HIGH_TRIGGER_KBPS AUDIO_COMPACT_TRIGGER_GIB AUDIO_COMPACT_LIMIT_GIB
    AUDIO_HIGH_KBPS_1 AUDIO_HIGH_KBPS_2 AUDIO_HIGH_KBPS_3TO4
    AUDIO_HIGH_KBPS_5TO6 AUDIO_HIGH_KBPS_7PLUS
    AUDIO_COMPACT_KBPS_1 AUDIO_COMPACT_KBPS_2 AUDIO_COMPACT_KBPS_3TO4
    AUDIO_COMPACT_KBPS_5TO6 AUDIO_COMPACT_KBPS_7PLUS
)

# x265 CRF values: whole numbers 0..CRF_LIMIT
CRF_LIMIT=51
POLICY_KEYS_CRF=(
    MOVIE_QUALITY_CRF_MIN MOVIE_QUALITY_CRF_START MOVIE_QUALITY_CRF_MAX
    MOVIE_HIGH_CRF_SEARCH_MIN MOVIE_HIGH_CRF_START MOVIE_HIGH_CRF_MAX
    MOVIE_BASE_CRF_SEARCH_MIN MOVIE_BASE_CRF_START MOVIE_BASE_CRF_MAX
    SERIES_HIGH_CRF_SEARCH_MIN SERIES_HIGH_CRF_START SERIES_HIGH_CRF_MAX
    SERIES_BASE_CRF_SEARCH_MIN SERIES_BASE_CRF_START SERIES_BASE_CRF_MAX
)

# High / Base tiers (*_CRF_START / *_CRF_SEARCH_MIN / *_CRF_MAX)
POLICY_CRF_TIERS=(MOVIE_HIGH MOVIE_BASE SERIES_HIGH SERIES_BASE)

# Former High / Base *_CRF_MIN: search start and hard floor in one. A
# config that sets only it keeps the former behaviour (START = SEARCH_MIN
# = it, no search below it) with a note; set together with the new keys
# it is an error (_policy_legacy_crf_min).
POLICY_KEYS_LEGACY_CRF_MIN=(MOVIE_HIGH_CRF_MIN MOVIE_BASE_CRF_MIN SERIES_HIGH_CRF_MIN SERIES_BASE_CRF_MIN)

# whole numbers >= 1
POLICY_KEYS_COUNT=(
    MOVIE_CRF_SAMPLE_POINTS SERIES_CRF_SAMPLE_EPISODES SERIES_CRF_SAMPLE_POINTS
)

# Settings of the former movie / series audio policy. Audio is now always
# copied by those menus; a config that still sets them gets a note.
POLICY_KEYS_RETIRED=(
    MOVIE_QUALITY_AUDIO_MODE MOVIE_QUALITY_AUDIO_MAX_GIB MOVIE_HIGH_AUDIO_MAX_GIB
    MOVIE_BASE_AUDIO_MAX_GIB_CHOICES MOVIE_AAC_MIN_KBPS
    MOVIE_HIGH_AAC_KBPS_7PLUS MOVIE_HIGH_AAC_KBPS_6 MOVIE_HIGH_AAC_KBPS_3TO5
    MOVIE_HIGH_AAC_KBPS_2 MOVIE_HIGH_AAC_KBPS_1
    MOVIE_BASE_AAC_KBPS_7PLUS MOVIE_BASE_AAC_KBPS_6 MOVIE_BASE_AAC_KBPS_3TO5
    MOVIE_BASE_AAC_KBPS_2 MOVIE_BASE_AAC_KBPS_1
    SERIES_HIGH_AAC_KBPS_7PLUS SERIES_HIGH_AAC_KBPS_6 SERIES_HIGH_AAC_KBPS_3TO5
    SERIES_HIGH_AAC_KBPS_2 SERIES_HIGH_AAC_KBPS_1
    SERIES_BASE_AAC_KBPS_7PLUS SERIES_BASE_AAC_KBPS_6 SERIES_BASE_AAC_KBPS_3TO5
    SERIES_BASE_AAC_KBPS_2 SERIES_BASE_AAC_KBPS_1
    SERIES_TOTAL_GIB_PER_HOUR SERIES_HIGH_TOTAL_GIB_PER_HOUR SERIES_BASE_TOTAL_GIB_PER_HOUR
    SERIES_MIN_VIDEO_KBPS
)

# Settings of the former two-pass Quality policy (GiB/hour with a
# minimum size, bitrate floor / max), replaced by the Quality CRF tier
# (video size band); a config that still sets them gets a note.
POLICY_KEYS_RETIRED_QUALITY=(
    MOVIE_QUALITY_VIDEO_GIB_PER_HOUR MOVIE_QUALITY_VIDEO_MIN_GIB
    MOVIE_QUALITY_VIDEO_FLOOR_MBPS MOVIE_QUALITY_VIDEO_MAX_MBPS
)

# Settings of the former High / Base size-target (GiB/hour, two-pass)
# video policy, replaced by the CRF tiers; a config that still sets
# them gets a note. (MOVIE_HIGH / MOVIE_BASE_VIDEO_GIB_PER_HOUR are not
# among them: they are active again, as the rate of the movie High /
# Base video ceiling, POLICY_KEYS_POSITIVE.)
POLICY_KEYS_RETIRED_VIDEO=(
    MOVIE_HIGH_VIDEO_FLOOR_MBPS MOVIE_HIGH_VIDEO_MAX_MBPS
    MOVIE_BASE_VIDEO_FLOOR_MBPS MOVIE_BASE_VIDEO_MAX_MBPS
    SERIES_HIGH_VIDEO_GIB_PER_HOUR SERIES_HIGH_VIDEO_FLOOR_MBPS SERIES_HIGH_VIDEO_MAX_MBPS
    SERIES_BASE_VIDEO_GIB_PER_HOUR SERIES_BASE_VIDEO_FLOOR_MBPS SERIES_BASE_VIDEO_MAX_MBPS
)

# Former fixed per-movie High / Base video ceilings, replaced by the
# runtime-scaled MOVIE_*_VIDEO_GIB_PER_HOUR; a config that still sets
# them gets a note (series keep their fixed SERIES_*_VIDEO_SIZE_CEILING_GIB).
POLICY_KEYS_RETIRED_MOVIE_CEILING=(
    MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB MOVIE_BASE_VIDEO_SIZE_CEILING_GIB
)

policy_conf_path() {
    printf '%s' "${COMPRESS_CONF:-${WORK_DIR:-$HOME/compress/work}/lib/compress.conf}"
}

_policy_is_num() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# validate_policy  ->  prints every problem, returns 1 if any
validate_policy() {
    local k v errs=() f m

    for k in "${POLICY_KEYS_POSITIVE[@]}"; do
        if [[ -z "${!k+x}" ]]; then
            errs+=("$k is not set")
            continue
        fi
        v="${!k}"
        if [[ "$v" == -* ]]; then
            errs+=("$k=\"$v\": must not be negative")
        elif ! _policy_is_num "$v"; then
            errs+=("$k=\"$v\": not a number")
        elif [[ "$k" == *_KBPS* && ! "$v" =~ ^[0-9]+$ ]]; then
            # kb/s values feed integer arithmetic
            errs+=("$k=\"$v\": must be a whole number of kb/s")
        fi
    done

    for k in "${POLICY_KEYS_POSITIVE[@]}"; do
        v="${!k:-}"
        if _policy_is_num "$v" && awk -v x="$v" 'BEGIN { exit !(x <= 0) }'; then
            errs+=("$k=\"$v\": must be greater than 0")
        fi
    done

    for k in "${POLICY_KEYS_CRF[@]}" "${POLICY_KEYS_COUNT[@]}"; do
        if [[ -z "${!k+x}" ]]; then
            errs+=("$k is not set")
            continue
        fi
        v="${!k}"
        if [[ "$v" == -* ]]; then
            errs+=("$k=\"$v\": must not be negative")
        elif [[ ! "$v" =~ ^[0-9]+$ ]]; then
            errs+=("$k=\"$v\": must be a whole number")
        elif [[ " ${POLICY_KEYS_CRF[*]} " == *" $k "* ]] && (( 10#$v > CRF_LIMIT )); then
            errs+=("$k=\"$v\": outside the x265 CRF range 0-$CRF_LIMIT")
        elif [[ " ${POLICY_KEYS_COUNT[*]} " == *" $k "* ]] && (( 10#$v < 1 )); then
            errs+=("$k=\"$v\": must be at least 1")
        fi
    done

    # CRF_MIN (highest quality of the tier) <= CRF_MAX (lowest quality)
    for f in MOVIE_QUALITY; do
        local lo="${f}_CRF_MIN" hi="${f}_CRF_MAX"
        if [[ "${!lo:-}" =~ ^[0-9]+$ && "${!hi:-}" =~ ^[0-9]+$ ]] && (( 10#${!hi} < 10#${!lo} )); then
            errs+=("$hi (${!hi}) is lower than $lo (${!lo})")
        fi
    done

    # High / Base: CRF_SEARCH_MIN <= CRF_START <= CRF_MAX
    for k in ${POLICY_LEGACY_CONFLICT[@]+"${POLICY_LEGACY_CONFLICT[@]}"}; do
        errs+=("$k is replaced by ${k%_MIN}_START and ${k%_MIN}_SEARCH_MIN (set both, remove $k)")
    done
    for f in "${POLICY_CRF_TIERS[@]}"; do
        local sm="${f}_CRF_SEARCH_MIN" st="${f}_CRF_START" mx="${f}_CRF_MAX"
        if [[ "${!sm:-}" =~ ^[0-9]+$ && "${!st:-}" =~ ^[0-9]+$ ]] && (( 10#${!st} < 10#${!sm} )); then
            errs+=("$st (${!st}) is lower than $sm (${!sm})")
        fi
        if [[ "${!st:-}" =~ ^[0-9]+$ && "${!mx:-}" =~ ^[0-9]+$ ]] && (( 10#${!st} > 10#${!mx} )); then
            errs+=("$st (${!st}) is greater than $mx (${!mx})")
        fi
    done

    # Quality search start: CRF_MIN <= CRF_START <= CRF_MAX
    local qs="${MOVIE_QUALITY_CRF_START:-}" qlo="${MOVIE_QUALITY_CRF_MIN:-}" qhi="${MOVIE_QUALITY_CRF_MAX:-}"
    if [[ "$qs" =~ ^[0-9]+$ && "$qlo" =~ ^[0-9]+$ ]] && (( 10#$qs < 10#$qlo )); then
        errs+=("MOVIE_QUALITY_CRF_START ($qs) is lower than MOVIE_QUALITY_CRF_MIN ($qlo)")
    fi
    if [[ "$qs" =~ ^[0-9]+$ && "$qhi" =~ ^[0-9]+$ ]] && (( 10#$qs > 10#$qhi )); then
        errs+=("MOVIE_QUALITY_CRF_START ($qs) is greater than MOVIE_QUALITY_CRF_MAX ($qhi)")
    fi

    # Quality band: ACCEPT_MIN <= TARGET <= ACCEPT_MAX
    local qmin="${MOVIE_QUALITY_ACCEPT_MIN_GIB:-}" qt="${MOVIE_QUALITY_TARGET_VIDEO_GIB:-}" qmax="${MOVIE_QUALITY_ACCEPT_MAX_GIB:-}"
    if _policy_is_num "$qmin" && _policy_is_num "$qt" &&
       awk -v a="$qmin" -v b="$qt" 'BEGIN { exit !(a > b) }'; then
        errs+=("MOVIE_QUALITY_ACCEPT_MIN_GIB ($qmin) is greater than MOVIE_QUALITY_TARGET_VIDEO_GIB ($qt)")
    fi
    if _policy_is_num "$qt" && _policy_is_num "$qmax" &&
       awk -v a="$qt" -v b="$qmax" 'BEGIN { exit !(a > b) }'; then
        errs+=("MOVIE_QUALITY_TARGET_VIDEO_GIB ($qt) is greater than MOVIE_QUALITY_ACCEPT_MAX_GIB ($qmax)")
    fi

    if _policy_is_num "${SERIES_CONTAINER_RESERVE_PCT:-}"; then
        if awk -v x="$SERIES_CONTAINER_RESERVE_PCT" 'BEGIN { exit !(x >= 100) }'; then
            errs+=("SERIES_CONTAINER_RESERVE_PCT=\"$SERIES_CONTAINER_RESERVE_PCT\": must be below 100")
        fi
    elif [[ -z "${SERIES_CONTAINER_RESERVE_PCT+x}" ]]; then
        errs+=("SERIES_CONTAINER_RESERVE_PCT is not set")
    else
        errs+=("SERIES_CONTAINER_RESERVE_PCT=\"$SERIES_CONTAINER_RESERVE_PCT\": not a number 0-99")
    fi

    # post-encode lower-CRF retry: headroom 0-99 %, retries a whole number
    if [[ -z "${CRF_DOWN_RETRY_HEADROOM_PCT+x}" ]]; then
        errs+=("CRF_DOWN_RETRY_HEADROOM_PCT is not set")
    elif ! _policy_is_num "$CRF_DOWN_RETRY_HEADROOM_PCT" ||
         awk -v x="$CRF_DOWN_RETRY_HEADROOM_PCT" 'BEGIN { exit !(x >= 100) }'; then
        errs+=("CRF_DOWN_RETRY_HEADROOM_PCT=\"$CRF_DOWN_RETRY_HEADROOM_PCT\": not a number 0-99")
    fi
    if [[ -z "${CRF_DOWN_RETRY_FIT_MARGIN_PCT+x}" ]]; then
        errs+=("CRF_DOWN_RETRY_FIT_MARGIN_PCT is not set")
    elif ! _policy_is_num "$CRF_DOWN_RETRY_FIT_MARGIN_PCT" ||
         awk -v x="$CRF_DOWN_RETRY_FIT_MARGIN_PCT" 'BEGIN { exit !(x >= 100) }'; then
        errs+=("CRF_DOWN_RETRY_FIT_MARGIN_PCT=\"$CRF_DOWN_RETRY_FIT_MARGIN_PCT\": not a number 0-99")
    fi
    for k in CRF_DOWN_RETRY_MAX SERIES_CRF_DOWN_RETRY_MAX; do
        if [[ -z "${!k+x}" ]]; then
            errs+=("$k is not set")
        elif [[ ! "${!k}" =~ ^[0-9]+$ ]]; then
            errs+=("$k=\"${!k}\": must be a whole number (0 = off)")
        fi
    done

    # adaptive CRF search step: 0 (off) or a whole percentage >= 100
    k=CRF_ADAPTIVE_STEP_THRESHOLD_PCT
    if [[ -z "${!k+x}" ]]; then
        errs+=("$k is not set")
    elif [[ ! "${!k}" =~ ^[0-9]+$ ]] || (( 10#${!k} != 0 && 10#${!k} < 100 )); then
        errs+=("$k=\"${!k}\": must be 0 (off) or a whole number of at least 100")
    fi

    if _policy_is_num "${AUDIO_COMPACT_LIMIT_GIB:-}" && _policy_is_num "${AUDIO_COMPACT_TRIGGER_GIB:-}" &&
       awk -v l="$AUDIO_COMPACT_LIMIT_GIB" -v t="$AUDIO_COMPACT_TRIGGER_GIB" 'BEGIN { exit !(l > t) }'; then
        errs+=("AUDIO_COMPACT_LIMIT_GIB ($AUDIO_COMPACT_LIMIT_GIB) is greater than AUDIO_COMPACT_TRIGGER_GIB ($AUDIO_COMPACT_TRIGGER_GIB)")
    fi

    if (( ${#errs[@]} )); then
        echo "Invalid compression policy in $(policy_conf_path):" >&2
        printf '  - %s\n' "${errs[@]}" >&2
        return 1
    fi

    return 0
}

# load_policy  ->  sources and validates compress.conf; returns 1 (with
# a message) when it is missing or invalid
load_policy() {
    local conf
    conf=$(policy_conf_path)

    if [[ ! -f "$conf" ]]; then
        echo "Compression policy file not found: $conf" >&2
        echo "Copy the default compress.conf from the project to that path" >&2
        echo "(it documents every setting), then adjust it as needed." >&2
        return 1
    fi

    # Start clean: a setting missing from the file must not survive from
    # an earlier load (or from the environment).
    unset "${POLICY_KEYS_POSITIVE[@]}" \
        "${POLICY_KEYS_CRF[@]}" "${POLICY_KEYS_COUNT[@]}" \
        "${POLICY_KEYS_RETIRED[@]}" "${POLICY_KEYS_RETIRED_VIDEO[@]}" \
        "${POLICY_KEYS_RETIRED_QUALITY[@]}" "${POLICY_KEYS_LEGACY_CRF_MIN[@]}" \
        "${POLICY_KEYS_RETIRED_MOVIE_CEILING[@]}" \
        SERIES_CONTAINER_RESERVE_PCT CRF_DOWN_RETRY_HEADROOM_PCT CRF_DOWN_RETRY_MAX \
        CRF_DOWN_RETRY_FIT_MARGIN_PCT SERIES_CRF_DOWN_RETRY_MAX \
        CRF_ADAPTIVE_STEP_THRESHOLD_PCT

    # shellcheck source=/dev/null
    if ! source "$conf"; then
        echo "Could not read $conf (bash syntax error?)." >&2
        return 1
    fi

    policy_retired_note
    _policy_legacy_crf_min
    validate_policy
}

# _policy_legacy_crf_min  ->  a High / Base tier set only with the former
# *_CRF_MIN (start and hard floor in one) gets *_CRF_START and
# *_CRF_SEARCH_MIN = that value (the former behaviour: no search below
# it), with a note. Set together with either new key: listed in
# POLICY_LEGACY_CONFLICT (an error in validate_policy).
_policy_legacy_crf_min() {
    local f old st sm mapped=()

    POLICY_LEGACY_CONFLICT=()
    for f in "${POLICY_CRF_TIERS[@]}"; do
        old="${f}_CRF_MIN" st="${f}_CRF_START" sm="${f}_CRF_SEARCH_MIN"
        [[ -n "${!old+x}" ]] || continue
        if [[ -n "${!st+x}" || -n "${!sm+x}" ]]; then
            POLICY_LEGACY_CONFLICT+=("$old")
            continue
        fi
        printf -v "$st" '%s' "${!old}"
        printf -v "$sm" '%s' "${!old}"
        mapped+=("$old")
    done

    if (( ${#mapped[@]} )); then
        echo "Note: $(policy_conf_path) still sets the former High/Base *_CRF_MIN" >&2
        echo "      (search start and hard floor in one); used as *_CRF_START and" >&2
        echo "      *_CRF_SEARCH_MIN, so no CRF below it is searched. Set *_CRF_START /" >&2
        echo "      *_CRF_SEARCH_MIN instead to allow it:" >&2
        printf '        %s\n' "${mapped[@]}" >&2
    fi
    return 0
}

# policy_retired_note  ->  note on stderr when the config still sets
# former movie / series audio or High/Base size-target settings (they
# have no effect any more)
policy_retired_note() {
    local k set=()

    for k in "${POLICY_KEYS_RETIRED[@]}"; do
        [[ -n "${!k+x}" ]] && set+=("$k")
    done

    if (( ${#set[@]} )); then
        echo "Note: $(policy_conf_path) still sets former movie/series audio settings," >&2
        echo "      which are ignored (movie/series audio is always copied; audio" >&2
        echo "      compression uses the AUDIO_* settings of audio_compress_menu.sh):" >&2
        printf '        %s\n' "${set[@]}" >&2
    fi

    set=()
    for k in "${POLICY_KEYS_RETIRED_VIDEO[@]}"; do
        [[ -n "${!k+x}" ]] && set+=("$k")
    done

    if (( ${#set[@]} )); then
        echo "Note: $(policy_conf_path) still sets former High/Base size-target" >&2
        echo "      settings, which are ignored (High and Base are CRF tiers now:" >&2
        echo "      *_CRF_START / *_CRF_SEARCH_MIN / *_CRF_MAX, MOVIE_*_VIDEO_GIB_PER_HOUR," >&2
        echo "      SERIES_*_VIDEO_SIZE_CEILING_GIB):" >&2
        printf '        %s\n' "${set[@]}" >&2
    fi

    set=()
    for k in "${POLICY_KEYS_RETIRED_MOVIE_CEILING[@]}"; do
        [[ -n "${!k+x}" ]] && set+=("$k")
    done

    if (( ${#set[@]} )); then
        echo "Note: $(policy_conf_path) still sets former fixed movie High/Base video" >&2
        echo "      ceilings, which are ignored (the movie ceiling is the runtime x" >&2
        echo "      MOVIE_HIGH_VIDEO_GIB_PER_HOUR / MOVIE_BASE_VIDEO_GIB_PER_HOUR):" >&2
        printf '        %s\n' "${set[@]}" >&2
    fi

    set=()
    for k in "${POLICY_KEYS_RETIRED_QUALITY[@]}"; do
        [[ -n "${!k+x}" ]] && set+=("$k")
    done

    if (( ${#set[@]} )); then
        echo "Note: $(policy_conf_path) still sets former Quality GiB/hour settings," >&2
        echo "      which are ignored (Quality is a CRF tier: MOVIE_QUALITY_CRF_MIN / _START / _MAX," >&2
        echo "      TARGET_VIDEO_GIB and the ACCEPT_MIN_GIB / _MAX_GIB band):" >&2
        printf '        %s\n' "${set[@]}" >&2
    fi
    return 0
}

# ------------------------------------------------------------
# Movie Quality (CRF chosen for a video size band)
# ------------------------------------------------------------

# quality_band_text  ->  "~20 GiB (18-22)"
quality_band_text() {
    printf '~%s GiB (%s-%s)' "$MOVIE_QUALITY_TARGET_VIDEO_GIB" \
        "$MOVIE_QUALITY_ACCEPT_MIN_GIB" "$MOVIE_QUALITY_ACCEPT_MAX_GIB"
}

# quality_source_limited SOURCE_VIDEO_BYTES  ->  0 when the source video
# is known and at or below the Quality target (the band cannot be
# reached without inflating the source; the menu asks first)
quality_source_limited() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 <= $(_gib_bytes "$MOVIE_QUALITY_TARGET_VIDEO_GIB") ))
}

# quality_pick_text  ->  why crf_select_quality chose its CRF (QUALITY_PICK)
quality_pick_text() {
    case "${QUALITY_PICK:-}" in
        band)    printf 'lowest CRF inside the %s-%s GiB band' "$MOVIE_QUALITY_ACCEPT_MIN_GIB" "$MOVIE_QUALITY_ACCEPT_MAX_GIB" ;;
        closest) printf 'no CRF inside the band; closest to %s GiB' "$MOVIE_QUALITY_TARGET_VIDEO_GIB" ;;
        none)    printf 'no CRF estimated below the source video' ;;
    esac
}

# movie_policy_line TIER [DURATION]  ->  one-line description of the
# effective values (High / Base: with DURATION, the movie's ceiling too).
# Output only: runs in a subshell like crf_policy_lines, so the caller's
# tier / search state is never changed.
movie_policy_line() (
    case "$1" in
        Quality)
            printf 'CRF %s-%s, search starts at %s [lowest CRF with the video estimate in %s-%s GiB, else closest to %s GiB]' \
                "$MOVIE_QUALITY_CRF_MIN" "$MOVIE_QUALITY_CRF_MAX" "$MOVIE_QUALITY_CRF_START" \
                "$MOVIE_QUALITY_ACCEPT_MIN_GIB" "$MOVIE_QUALITY_ACCEPT_MAX_GIB" "$MOVIE_QUALITY_TARGET_VIDEO_GIB"
            ;;
        High|Base)
            crf_tier_load movie "$1" "" "${2:-}" || return 1
            printf 'CRF %s-%s, search starts at %s [lowest CRF with the video estimate at or below %s GiB per hour of runtime%s]' \
                "$CRF_MIN" "$CRF_MAX" "$CRF_START" "$CRF_GIB_PER_HOUR" \
                "${CRF_CEILING_GIB:+: $CRF_CEILING_GIB GiB for this movie}"
            ;;
        Custom)
            printf 'CRF entered in the menu, used exactly'
            ;;
    esac

    printf '; audio copied'
)

# audio_copy_policy_lines  ->  the audio rule of the movie / series menus
audio_copy_policy_lines() {
    echo "Audio:"
    echo "  all tracks copied unchanged"
    echo "  use audio_compress_menu.sh for optional audio compression"
}

# movie_video_policy_lines TIER [CUSTOM_CRF [DURATION]]  ->  the tier's
# video settings, one per line
movie_video_policy_lines() {
    crf_policy_lines movie "$1" "${2:-}" "${3:-}"
}

# ------------------------------------------------------------
# CRF tiers (movie / series High, Base; Custom)
#
# Lower CRF = higher quality. Three separate bounds per tier:
#   CRF_START  the first CRF estimated (*_CRF_START); not a bound
#   CRF_MIN    the lowest CRF the search may choose (*_CRF_SEARCH_MIN),
#              also the floor of the post-encode lower-CRF retry
#   CRF_MAX    the lowest quality allowed; never exceeded automatically
# The VIDEO size ceiling: movie High / Base the movie's exact runtime x
# MOVIE_*_VIDEO_GIB_PER_HOUR (movie_ceiling_bytes, computed once the
# runtime is known); series High / Base a fixed SERIES_*_VIDEO_SIZE_CEILING_GIB
# per episode. Either way it is one number of bytes for the search and
# the post-encode retry. Per title the adjacent boundary around it is
# found (crf_search_boundary):
#
#   CRF N over the ceiling, CRF N + 1 fits  ->  N + 1
#
# START above the ceiling: upward (+1 / +2 steps, bracket-and-refine,
# crf_search_up); START fits: downward one CRF at a time until the CRF
# below is above the ceiling, or CRF_MIN is reached and still fits.
# The result is the lowest CRF of CRF_MIN..CRF_MAX that fits (for one
# title, whose estimates shrink as the CRF rises: the CRF the sequential
# CRF_MIN, CRF_MIN + 1, ... search chooses), never above CRF_MAX
# (CRF_OVER_CEILING=1 when CRF_MAX still does not fit: the menu warns
# and asks). Audio is copied and never part of the decision.
#
# Estimates come from sample encodes of the actual source (encode_common.sh
# crf_sample_title); the math on them lives here.
# ------------------------------------------------------------

# _gib_bytes GIB  ->  whole bytes
_gib_bytes() {
    awk -v g="$1" 'BEGIN { printf "%.0f", g * 1073741824 }'
}

# crf_valid VALUE  ->  0 when VALUE is a usable x265 CRF (0-51, decimals ok)
crf_valid() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
        awk -v c="$1" -v l="$CRF_LIMIT" 'BEGIN { exit !(c >= 0 && c <= l) }'
}

# movie_ceiling_bytes GIB_PER_HOUR DURATION_SECONDS  ->  whole bytes
#
# The movie High / Base video ceiling:
#   DURATION_SECONDS / 3600 x GIB_PER_HOUR x 1073741824
# from the exact runtime (not rounded hours / minutes); rounded to a
# whole byte only at the end, and never below 1 byte (a ceiling of 0
# would mean "no ceiling"). Video only (audio, subtitles, attachments
# and container overhead are not part of it). Returns 1 (nothing
# printed) when either value is not a positive number.
movie_ceiling_bytes() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ && "${2:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v r="$1" -v d="$2" 'BEGIN {
        if (r <= 0 || d <= 0) exit 1
        b = r * 1073741824 * d / 3600
        printf "%.0f", (b < 1 ? 1 : b) }'
}

# crf_tier_load SCOPE TIER [CUSTOM_CRF [DURATION]]
#
# SCOPE: movie | series. TIER: High | Base | Custom (| Quality, movie).
# Sets CRF_START (first CRF estimated) CRF_MIN (absolute lowest CRF:
# search and post-encode retry floor) CRF_MAX CRF_CEILING_GIB
# CRF_CEILING_BYTES CRF_GIB_PER_HOUR.
# Movie High / Base: the ceiling scales with the runtime:
# CRF_GIB_PER_HOUR = MOVIE_*_VIDEO_GIB_PER_HOUR and, with DURATION (the
# movie's runtime in seconds), CRF_CEILING_BYTES = movie_ceiling_bytes
# and CRF_CEILING_GIB its GiB ("7.00"). Without DURATION (menu text)
# both ceiling values are empty; an unusable DURATION returns 1.
# Series High / Base: the fixed SERIES_*_VIDEO_SIZE_CEILING_GIB per
# episode (CRF_GIB_PER_HOUR empty).
# Custom: CRF_START = CRF_MIN = CRF_MAX = CUSTOM_CRF, no ceiling
# (CRF_CEILING_BYTES=0).
crf_tier_load() {
    local scope="${1^^}" tier="$2" u

    CRF_GIB_PER_HOUR=""

    case "$tier" in
        High|Base)
            u="${tier^^}"
            local a="${scope}_${u}_CRF_SEARCH_MIN" s="${scope}_${u}_CRF_START"
            local b="${scope}_${u}_CRF_MAX"
            CRF_MIN="${!a}"
            CRF_START="${!s}"
            CRF_MAX="${!b}"
            if [[ "$scope" == MOVIE ]]; then
                local r="MOVIE_${u}_VIDEO_GIB_PER_HOUR"
                CRF_GIB_PER_HOUR="${!r}"
                CRF_CEILING_GIB=""
                CRF_CEILING_BYTES=""
                if [[ -n "${4:-}" ]]; then
                    if ! CRF_CEILING_BYTES=$(movie_ceiling_bytes "$CRF_GIB_PER_HOUR" "$4"); then
                        CRF_CEILING_BYTES=""
                        echo "crf_tier_load: runtime \"$4\" cannot give the movie $tier video ceiling" >&2
                        return 1
                    fi
                    CRF_CEILING_GIB=$(bytes_to_gib "$CRF_CEILING_BYTES")
                fi
            else
                local c="${scope}_${u}_VIDEO_SIZE_CEILING_GIB"
                CRF_CEILING_GIB="${!c}"
                CRF_CEILING_BYTES=$(_gib_bytes "$CRF_CEILING_GIB")
            fi
            ;;
        Custom)
            CRF_MIN="${3:-}"
            CRF_START="${3:-}"
            CRF_MAX="${3:-}"
            CRF_CEILING_GIB=""
            CRF_CEILING_BYTES=0
            ;;
        Quality)
            # movie only; the "ceiling" is the upper edge of the band
            # (what the post-encode retry checks the actual video against)
            if [[ "$scope" != MOVIE ]]; then
                echo "crf_tier_load: Quality is a movie tier" >&2
                return 1
            fi
            # CRF_MIN / CRF_MAX: absolute bounds; CRF_START: first CRF
            # sampled (not a minimum)
            CRF_MIN="$MOVIE_QUALITY_CRF_MIN"
            CRF_START="$MOVIE_QUALITY_CRF_START"
            CRF_MAX="$MOVIE_QUALITY_CRF_MAX"
            CRF_CEILING_GIB="$MOVIE_QUALITY_ACCEPT_MAX_GIB"
            CRF_CEILING_BYTES=$(_gib_bytes "$CRF_CEILING_GIB")
            ;;
        *)
            echo "crf_tier_load: unknown tier $tier" >&2
            return 1
            ;;
    esac
}

# crf_policy_lines SCOPE TIER [CUSTOM_CRF [DURATION]]  ->  the tier's
# video policy (movie High / Base with DURATION: the movie's ceiling)
#
# Output only: the body runs in a subshell, so the crf_tier_load below
# never touches the caller's tier / search state (CRF_MIN, CRF_START,
# CRF_MAX, CRF_CEILING_BYTES, CRF_CEILING_GIB, CRF_GIB_PER_HOUR). The
# menus call it (COMPRESS_VERBOSE=1) after they loaded and adjusted that
# state, e.g. the source-limited Quality ceiling (source video - 1).
crf_policy_lines() (
    local scope="$1" tier="$2"

    if [[ "$tier" == "Quality" ]]; then
        if [[ "${scope^^}" != MOVIE ]]; then
            echo "crf_policy_lines: Quality is a movie tier" >&2
            return 1
        fi
        echo "Quality CRF search:"
        echo "  Range: ${MOVIE_QUALITY_CRF_MIN}-${MOVIE_QUALITY_CRF_MAX}"
        echo "  Start: ${MOVIE_QUALITY_CRF_START} (first CRF sampled; the search may go below or above it)"
        echo "  Target: ${MOVIE_QUALITY_TARGET_VIDEO_GIB} GiB"
        echo "  Band: ${MOVIE_QUALITY_ACCEPT_MIN_GIB}-${MOVIE_QUALITY_ACCEPT_MAX_GIB} GiB (copied audio not counted)"
        echo "  lowest CRF estimated inside the band; none inside: closest to the target"
        echo "  never a CRF estimated at or above the source video size"
        echo "  encode: x265 CRF, single pass, preset slow, 10-bit"
        echo "  audio: copied unchanged"
        return 0
    fi

    crf_tier_load "$scope" "$tier" "${3:-}" "${4:-}" || return 1

    echo "$tier video policy:"
    if [[ "$tier" == "Custom" ]]; then
        if [[ "$scope" == series ]]; then
            echo "  CRF: exact user CRF${CRF_MIN:+ ($CRF_MIN)}; no High/Base CRF range or size ceiling"
            echo "  one CRF for every episode of the batch"
        else
            echo "  CRF: ${CRF_MIN:-entered in the menu} (used exactly; no size ceiling)"
        fi
    elif [[ "$scope" == series ]]; then
        echo "  CRF range: ${CRF_MIN}-${CRF_MAX}, search starts at ${CRF_START} (lowest CRF at which every regular episode fits)"
        echo "  video ceiling: ${CRF_CEILING_GIB} GiB/episode"
        echo "  one season CRF; only an isolated outlier (> median +${SERIES_CRF_OUTLIER_PCT}%) gets its own higher CRF"
    else
        echo "  CRF range: ${CRF_MIN}-${CRF_MAX}, search starts at ${CRF_START} (lowest CRF that fits the ceiling)"
        echo "  video size ceiling: ${CRF_GIB_PER_HOUR} GiB per hour of runtime (runtime hours x ${CRF_GIB_PER_HOUR} GiB)"
        [[ -n "$CRF_CEILING_GIB" ]] &&
            echo "  this movie: $(format_hms "$4") -> ${CRF_CEILING_GIB} GiB video ceiling"
    fi
    echo "  encode: x265 CRF, single pass, preset slow, 10-bit"
    echo "  audio: copied unchanged"
)

# crf_adaptive_step EST_BYTES CEILING_BYTES  ->  1 or 2: how far the
# ascending search moves past a CRF estimated above the ceiling. 2 when
# the estimate is more than CRF_ADAPTIVE_STEP_THRESHOLD_PCT % of the
# ceiling (0 / unset = always 1). Never more than 2.
crf_adaptive_step() {
    local pct="${CRF_ADAPTIVE_STEP_THRESHOLD_PCT:-0}"

    if [[ "$pct" =~ ^[0-9]+$ ]] && (( 10#$pct > 0 && $2 > 0 && $1 * 100 > $2 * 10#$pct )); then
        echo 2
    else
        echo 1
    fi
}

# crf_search_up MIN MAX CEILING_BYTES PROBE [REPORT] [CERTIFY]
#
# Bracket-and-refine search for the lowest CRF from MIN up whose estimate
# fits CEILING_BYTES (0 = no ceiling), never above MAX: the CRF the
# sequential MIN, MIN + 1, ... search chooses, with fewer estimates when
# the title is far above the ceiling. PROBE CRF leaves the estimated
# video bytes in CRF_EST_RESULT (non-zero = failed) and is expected to
# cache, so a CRF probed again is never estimated again.
#
#   forward   from MIN: +2 while the estimate is above
#             CRF_ADAPTIVE_STEP_THRESHOLD_PCT % of the ceiling, else +1
#             (crf_adaptive_step); the last step is clamped to MAX
#   skipped   a CRF K jumped over (K = previous CRF + 1) is
#             - probed when the CRF after it fits: the final boundary is
#               always verified, never inferred
#             - left out when the CRF after it is too large only if
#               CERTIFY K NEXT CEILING proves from the data at NEXT
#               (= K + 1) that K cannot fit either; otherwise it is
#               probed right away (back-fill), and chosen if it fits
#   result    the lowest fitting CRF: every CRF below it was probed too
#             large or proven too large, and the CRF just below it (when
#             in range) was probed too large. MAX too large: over ceiling.
#
# CERTIFY empty: a single-title estimator (one movie, one episode). The
# sample encodes of one title shrink as the CRF rises, so NEXT too large
# proves K too large. An aggregate estimator whose fit may change
# non-monotonically with the CRF (series season: outlier classification,
# largest regular episode, fill rate of episodes not sampled) passes a
# CERTIFY that checks this (series_crf_certify_over).
#
# REPORT KIND CRF [ARG] after each probe (UI only):
#   over C NEXT      C too large; NEXT probed next (NEXT > C + 1: a jump)
#   check C K        C too large; the skipped K is not proven too large
#                    and is probed now
#   resume K NEXT    the skipped K too large as well; forward at NEXT
#   limit C          MAX (C) too large, nothing left: over ceiling
#   fits C           C fits and is chosen (MIN, or reached by + 1)
#   refine C K       C fits; the skipped K below it is probed first
#   refine-over K    the skipped K is too large
#   refine-fits K    the skipped K fits
#   boundary LO HI   LO probed too large, HI fits: HI chosen (after a
#                    skipped CRF was probed)
#
# Sets CRFS_CRF (chosen CRF; MAX when none fits), CRFS_BYTES (its
# estimate), CRFS_OVER (1 when even MAX is above the ceiling) and CRFS_LOW
# (the CRF just below CRFS_CRF, probed above the ceiling; "" when CRFS_CRF
# is MIN or nothing fits). Returns 1 when a probe failed (CRFS_CRF empty).
crf_search_up() {
    local min=$((10#$1)) max=$((10#$2)) ceil="$3" probe="$4" report="${5:-}" certify="${6:-}"
    local c e k="" next back

    CRFS_CRF=""
    CRFS_BYTES=""
    CRFS_OVER=0
    CRFS_LOW=""
    c="$min"

    while true; do
        _crfs_probe "$probe" "$c" || return 1
        e="$CRF_EST_RESULT"

        if (( ceil <= 0 || e <= ceil )); then
            if [[ -n "$k" ]]; then
                _crfs_report "$report" refine "$c" "$k"
                _crfs_probe "$probe" "$k" || return 1
                if (( CRF_EST_RESULT <= ceil )); then
                    _crfs_report "$report" refine-fits "$k"
                    _crfs_pick "$report" "$k" "$CRF_EST_RESULT" "$((k - 1))"
                else
                    _crfs_report "$report" refine-over "$k"
                    _crfs_pick "$report" "$c" "$e" "$k"
                fi
                return 0
            fi
            CRFS_CRF="$c"
            CRFS_BYTES="$e"
            (( c > min )) && CRFS_LOW=$((c - 1))
            _crfs_report "$report" fits "$c"
            return 0
        fi

        # too large: a CRF skipped on the way here must be proven too
        # large as well, or it is probed now
        back=""
        if [[ -n "$k" && -n "$certify" ]] && ! "$certify" "$k" "$c" "$ceil"; then
            _crfs_report "$report" check "$c" "$k"
            _crfs_probe "$probe" "$k" || return 1
            if (( CRF_EST_RESULT <= ceil )); then
                _crfs_report "$report" refine-fits "$k"
                _crfs_pick "$report" "$k" "$CRF_EST_RESULT" "$((k - 1))"
                return 0
            fi
            back="$k"
        fi

        if (( c >= max )); then
            _crfs_report "$report" limit "$c"
            CRFS_CRF="$c"
            CRFS_BYTES="$e"
            CRFS_OVER=1
            return 0
        fi

        next=$((c + $(crf_adaptive_step "$e" "$ceil")))
        (( next > max )) && next="$max"
        if [[ -n "$back" ]]; then
            _crfs_report "$report" resume "$back" "$next"
        else
            _crfs_report "$report" over "$c" "$next"
        fi
        k=""
        (( next > c + 1 )) && k=$((c + 1))
        c="$next"
    done
}

# crf_search_boundary START MIN MAX CEILING_BYTES PROBE [REPORT] [CERTIFY]
#
# The adjacent CRF boundary around CEILING_BYTES within MIN..MAX,
# searched from START (MIN <= START <= MAX; clamped):
#
#   CRF N      above the ceiling
#   CRF N + 1  fits             ->  N + 1 chosen
#
#   START above the ceiling: upward, crf_search_up START..MAX (+1 / +2
#     steps, skipped CRFs probed or certified, CERTIFY; START is probed
#     once, PROBE caches)
#   START fits: downward one CRF at a time (no jumps: a skipped CRF could
#     not be certified on the way down), START - 1, START - 2, ... until
#     a CRF is above the ceiling (it and the CRF above it are the
#     boundary) or MIN is reached and still fits (no boundary: MIN is
#     the lowest CRF allowed)
# CEILING_BYTES 0 = no ceiling: START.
#
# REPORT kinds besides crf_search_up's:
#   fits C           START (C) fits and is MIN: chosen
#   down C NEXT      C fits; NEXT (= C - 1) probed next
#   down-over C      C (probed on the way down) too large
#   floor C          C fits and is MIN: chosen (reached on the way down)
#   boundary LO HI   LO too large, HI fits: HI chosen (as crf_search_up)
#
# Sets crf_search_up's CRFS_CRF / CRFS_BYTES / CRFS_OVER / CRFS_LOW
# (the adjacent CRF above the ceiling, "" when none was reached) plus
# CRFS_DIR (up | down) and CRFS_FLOOR (1 when CRFS_CRF is MIN and fits).
# Returns 1 when a probe failed (CRFS_CRF empty).
crf_search_boundary() {
    local start=$((10#$1)) min=$((10#$2)) max=$((10#$3)) ceil="$4" probe="$5" report="${6:-}" certify="${7:-}"
    local c e

    CRFS_CRF=""
    CRFS_BYTES=""
    CRFS_OVER=0
    CRFS_LOW=""
    CRFS_DIR=up
    CRFS_FLOOR=0
    (( start < min )) && start="$min"
    (( start > max )) && start="$max"

    _crfs_probe "$probe" "$start" || return 1
    c="$start"
    e="$CRF_EST_RESULT"

    if (( ceil > 0 && e > ceil )); then
        crf_search_up "$start" "$max" "$ceil" "$probe" "$report" "$certify" || return 1
        CRFS_DIR=up
        return 0
    fi

    CRFS_DIR=down
    if (( ceil > 0 )); then
        while (( c > min )); do
            _crfs_report "$report" down "$c" "$((c - 1))"
            _crfs_probe "$probe" "$((c - 1))" || { CRFS_CRF=""; return 1; }
            if (( CRF_EST_RESULT > ceil )); then
                _crfs_report "$report" down-over "$((c - 1))"
                _crfs_pick "$report" "$c" "$e" "$((c - 1))"
                return 0
            fi
            c=$((c - 1))
            e="$CRF_EST_RESULT"
        done
    fi

    CRFS_CRF="$c"
    CRFS_BYTES="$e"
    if (( c == min )); then
        CRFS_FLOOR=1
    fi
    if (( c < start )); then
        _crfs_report "$report" floor "$c"
    else
        _crfs_report "$report" fits "$c"
    fi
    return 0
}

# _crfs_probe PROBE CRF  ->  CRF_EST_RESULT (whole bytes); 1 = failed
_crfs_probe() {
    CRF_EST_RESULT=""
    "$1" "$2" && [[ "$CRF_EST_RESULT" =~ ^[0-9]+$ ]]
}

# _crfs_report REPORT KIND ARG...  ->  REPORT KIND ARG... (none: nothing)
_crfs_report() {
    local r="$1"
    shift
    [[ -z "$r" ]] || "$r" "$@"
    return 0
}

# _crfs_pick REPORT CRF BYTES LOW  ->  CRF chosen after a skipped CRF was
# probed; LOW (CRF - 1) is the CRF probed above the ceiling below it
_crfs_pick() {
    CRFS_CRF="$2"
    CRFS_BYTES="$3"
    CRFS_LOW="$4"
    _crfs_report "$1" boundary "$4" "$2"
}

# crf_select_boundary CRF_START CRF_MIN CRF_MAX CEILING_BYTES ESTIMATOR [REPORT] [CERTIFY]
#
# High / Base. ESTIMATOR CRF: a function that estimates the VIDEO size
# at CRF and leaves it in CRF_EST_RESULT (whole bytes); non-zero =
# failed. The adjacent boundary around the ceiling is searched from
# CRF_START in either direction (crf_search_boundary: upward with
# adaptive steps, downward one CRF at a time) and the lowest CRF of
# CRF_MIN..CRF_MAX that fits is chosen: CRF_START is not a floor.
# CEILING_BYTES 0 = no ceiling (CRF_START). REPORT / CERTIFY: see
# crf_search_boundary / crf_search_up (CERTIFY empty: ESTIMATOR
# estimates one title). Every CRF is estimated at most once.
#
# Sets:
#   CRF_SELECTED      chosen CRF
#   CRF_TRIED         CRFs estimated, in estimation order
#   CRF_EST[crf]      estimated video bytes per tried CRF
#   CRF_OVER_CEILING  1 when CRF_MAX was reached and still does not fit
#   CRF_BOUNDARY_LOW  the CRF just below CRF_SELECTED, estimated above
#                     the ceiling ("" when none: CRF_SELECTED is CRF_MIN
#                     or over the ceiling)
#   CRF_AT_FLOOR      1 when CRF_SELECTED is CRF_MIN and fits (nothing
#                     lower allowed; no boundary below it)
#   CRF_SEARCH_DIR    up (CRF_START above the ceiling) | down
# Returns 1 when an estimate failed (CRF_SELECTED is then empty).
crf_select_boundary() {
    local start="$1" min="$2" max="$3" ceil="$4" est="$5" report="${6:-}" certify="${7:-}"

    declare -gA CRF_EST=()
    CRF_TRIED=()
    CRF_SELECTED=""
    CRF_OVER_CEILING=0
    CRF_BOUNDARY_LOW=""
    CRF_AT_FLOOR=0
    CRF_SEARCH_DIR=""
    _CRF_SELECT_EST="$est"

    if ! crf_search_boundary "$start" "$min" "$max" "$ceil" _crf_select_probe "$report" "$certify"; then
        CRF_SELECTED=""
        return 1
    fi

    CRF_SELECTED="$CRFS_CRF"
    CRF_OVER_CEILING="$CRFS_OVER"
    CRF_BOUNDARY_LOW="$CRFS_LOW"
    CRF_AT_FLOOR="$CRFS_FLOOR"
    CRF_SEARCH_DIR="$CRFS_DIR"
    return 0
}

# crf_select CRF_MIN CRF_MAX CEILING_BYTES ESTIMATOR [REPORT] [CERTIFY]
#
# crf_select_boundary with the search starting at CRF_MIN: the lowest CRF
# from CRF_MIN up whose estimate fits (upward only; same globals).
crf_select() {
    crf_select_boundary "$1" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}"
}

# _crf_select_probe CRF  (PROBE for crf_select)  ->  _CRF_SELECT_EST at
# CRF, recorded in CRF_TRIED / CRF_EST; a CRF already in CRF_EST is not
# estimated again
_crf_select_probe() {
    if [[ -n "${CRF_EST[$1]+x}" ]]; then
        CRF_EST_RESULT="${CRF_EST[$1]}"
        return 0
    fi

    CRF_EST_RESULT=""
    if ! "$_CRF_SELECT_EST" "$1" || [[ ! "$CRF_EST_RESULT" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    CRF_TRIED+=("$1")
    CRF_EST[$1]="$CRF_EST_RESULT"
}

# crf_select_quality CRF_MIN CRF_START CRF_MAX TARGET_BYTES LO_BYTES HI_BYTES SOURCE_BYTES ESTIMATOR [REPORT]
#
# Movie Quality: the CRF for a VIDEO size band (audio never involved).
# CRF_MIN / CRF_MAX are absolute bounds; CRF_START is only the first CRF
# estimated (not a minimum). A CRF is "usable" when its estimate is below
# SOURCE_BYTES (unknown source: always), so the band's upper edge is
# min(HI, source - 1).
#
# Search: the High / Base boundary search (crf_search_boundary, the upper
# edge as its ceiling, REPORT; every CRF estimated at most once, CRF_EST
# is the tested map):
#   1. estimate CRF_START
#   2. above the upper edge: upward from CRF_START (+ 1 / + 2 steps,
#      bracket-and-refine): stop at the first estimate at or below the
#      edge with the CRF just below it estimated above it, or at CRF_MAX.
#      A CRF left out by a + 2 step is above the edge (one title's
#      estimates shrink as the CRF rises), so it is never inside the
#      band and never closer to TARGET than the next CRF estimated
#   3. otherwise (inside the band or below it): CRF - 1, - 2, ... while
#      the estimate stays at or below the edge (stop at the first
#      estimate above it, or at CRF_MIN), so the lowest CRF still inside
#      the band is found even when CRF_START already is inside
# Both sides of the adjacent boundary at the upper edge are estimated
# (CRF_BOUNDARY_LOW above it, CRF_BOUNDARY_HIGH at or below it; "" when
# CRF_MIN still fits or CRF_MAX is still above). The CHOICE below is
# Quality's own (band / closest), not the High / Base "lowest that fits".
# Selection over every CRF estimated (noisy, non-monotonic estimates
# included):
#   - the LOWEST CRF whose estimate is inside LO..upper edge
#   - none: the usable CRF closest to TARGET (equal distance: lower CRF)
#   - nothing usable (every estimate at or above the source): the
#     highest CRF estimated (QUALITY_PICK=none); the menu's source guard
#     asks
#
# Sets the crf_select globals (CRF_SELECTED, CRF_TRIED in estimation
# order, CRF_EST, CRF_OVER_CEILING: 1 when no estimate reached the upper
# edge), CRF_BOUNDARY_LOW / CRF_BOUNDARY_HIGH and QUALITY_PICK: band |
# closest | none. Returns 1 when an estimate failed (CRF_SELECTED empty).
crf_select_quality() {
    local min="$1" start="$2" max="$3" t="$4" lo="$5" hi="$6" src="$7" est="$8" report="${9:-}"
    local c e cap best="" bd d any_fit=0 low_in=""

    declare -gA CRF_EST=()
    CRF_TRIED=()
    CRF_SELECTED=""
    CRF_OVER_CEILING=0
    CRF_BOUNDARY_LOW=""
    CRF_BOUNDARY_HIGH=""
    QUALITY_PICK=""

    cap="$hi"
    if [[ "$src" =~ ^[0-9]+$ ]] && (( src > 0 && src - 1 < cap )); then
        cap=$((src - 1))
    fi

    _CRF_SELECT_EST="$est"
    if ! crf_search_boundary "$start" "$min" "$max" "$cap" _crf_select_probe "$report"; then
        CRF_SELECTED=""
        return 1
    fi
    if [[ -n "$CRFS_LOW" ]] && (( CRFS_OVER == 0 )); then
        CRF_BOUNDARY_LOW="$CRFS_LOW"
        CRF_BOUNDARY_HIGH="$CRFS_CRF"
    fi

    for c in $(printf '%s\n' "${CRF_TRIED[@]}" | sort -n); do
        e="${CRF_EST[$c]}"
        if (( e <= cap )); then
            any_fit=1
            if [[ -z "$low_in" ]] && (( e >= lo )); then
                low_in="$c"
            fi
        fi
    done

    if [[ -n "$low_in" ]]; then
        CRF_SELECTED="$low_in"
        QUALITY_PICK=band
        return 0
    fi

    (( any_fit == 1 )) || CRF_OVER_CEILING=1

    for c in $(printf '%s\n' "${CRF_TRIED[@]}" | sort -n); do
        e="${CRF_EST[$c]}"
        if [[ "$src" =~ ^[0-9]+$ ]] && (( src > 0 && e >= src )); then
            continue
        fi
        d=$(( e > t ? e - t : t - e ))
        if [[ -z "$best" ]] || (( d < bd )); then
            best="$c"
            bd="$d"
        fi
    done

    if [[ -n "$best" ]]; then
        CRF_SELECTED="$best"
        QUALITY_PICK=closest
    else
        CRF_SELECTED=$(printf '%s\n' "${CRF_TRIED[@]}" | sort -n | tail -n 1)
        QUALITY_PICK=none
    fi
    return 0
}

# crf_select_exact CRF ESTIMATOR  ->  Custom: one estimate at exactly CRF
# (same globals as crf_select; never over a ceiling)
crf_select_exact() {
    declare -gA CRF_EST=()
    CRF_TRIED=()
    CRF_SELECTED=""
    CRF_OVER_CEILING=0
    CRF_EST_RESULT=""

    if ! "$2" "$1" || [[ ! "$CRF_EST_RESULT" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    CRF_TRIED=("$1")
    CRF_EST[$1]="$CRF_EST_RESULT"
    CRF_SELECTED="$1"
}

# crf_sample_points DURATION POINTS SECONDS  ->  "START LENGTH" per section
#
# POINTS sections of SECONDS each, centred on positions spread from 10%
# to 90% of the runtime (one point: 50%), so opening logos and end
# credits are avoided and no single scene dominates. A title shorter
# than 2 * POINTS * SECONDS is one section covering all of it (exact).
crf_sample_points() {
    awk -v d="$1" -v n="$2" -v s="$3" 'BEGIN {
        if (d !~ /^[0-9.]+$/ || d <= 0 || n < 1 || s <= 0) exit 1
        if (d <= 2 * n * s) { printf "0.000 %.3f\n", d; exit }
        for (i = 0; i < n; i++) {
            p = (n == 1) ? 0.5 : 0.1 + 0.8 * i / (n - 1)
            st = d * p - s / 2
            if (st < 0) st = 0
            if (st + s > d) st = d - s
            printf "%.3f %.3f\n", st, s
        }
    }'
}

# crf_extrapolate SAMPLE_BYTES SAMPLE_SECONDS DURATION  ->  whole bytes
# (the sampled video bitrate over the whole runtime)
crf_extrapolate() {
    awk -v b="$1" -v s="$2" -v d="$3" 'BEGIN {
        if (s <= 0) exit 1
        printf "%.0f", b / s * d }'
}

# crf_total_bytes VIDEO_BYTES AUDIO_BYTES OTHER_BYTES  ->  whole bytes
# (estimated video + copied audio + subtitles / attachments / container)
crf_total_bytes() {
    awk -v v="$1" -v a="${2:-0}" -v o="${3:-0}" 'BEGIN {
        if (a !~ /^[0-9.]+$/) a = 0
        if (o !~ /^[0-9.]+$/) o = 0
        printf "%.0f", v + a + o }'
}

# crf_oversize_gib EST_BYTES CEILING_BYTES  ->  "1.23" GiB above the ceiling
crf_oversize_gib() {
    awk -v e="$1" -v c="$2" 'BEGIN { printf "%.2f", (e - c) / 1073741824 }'
}

# crf_above_source EST_VIDEO_BYTES SOURCE_VIDEO_BYTES
#   ->  0 when the estimated encode would not be smaller than the source
#       video (source-quality guard: never make a lossy re-encode larger
#       than its source without asking). Unknown source size -> 1.
crf_above_source() {
    [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 && $1 >= $2 ))
}

# crf_analysis_lines  ->  "CRF n -> estimated X GiB video" per tried CRF
crf_analysis_lines() {
    local c

    for c in "${CRF_TRIED[@]}"; do
        if [[ -n "${CRF_ACTUAL_HIT[$c]:-}" ]]; then
            printf '  CRF %s -> actual %s video (cached)\n' "$c" "$(size_text "${CRF_EST[$c]}")"
        else
            printf '  CRF %s -> estimated %s video\n' "$c" "$(size_text "${CRF_EST[$c]}")"
        fi
    done
}

# crf_est_map  ->  "CRF=BYTES:..." of every CRF estimated (CRF_TRIED /
# CRF_EST); the job uses it to predict a lower CRF's size (item_expect
# crf_est=)
crf_est_map() {
    local c out=""

    for c in "${CRF_TRIED[@]}"; do
        out+="${out:+:}$c=${CRF_EST[$c]}"
    done
    printf '%s' "$out"
}

# ------------------------------------------------------------
# Series CRF
#
# One SEASON CRF for the batch (season / folder), so episodes look the
# same; only an isolated outlier episode gets its own, higher CRF.
# Episodes are sampled (SERIES_CRF_SAMPLE_EPISODES of them spread over
# the batch, plus the longest episode; SERIES_CRF_SAMPLE_POINTS sections
# each); an episode that is not sampled is estimated conservatively from
# the highest sampled bitrate (series_crf_spread: inferred). An inferred
# estimate never makes a CRF fail on its own: a decisive inferred
# episode is sampled itself at that CRF first (series_decisive_inferred,
# crf_series_estimate). For each candidate CRF (crf_search_boundary from
# CRF_START, up or down within CRF_MIN..CRF_MAX) every episode's video
# size is estimated and series_batch_stats sorts the episodes:
#   outlier   estimate above median episode x (1 + SERIES_CRF_OUTLIER_PCT/100)
#   isolated  the ONLY outlier of a batch of 3+ episodes; two or more
#             outliers are the season's difficulty and count as regular
#   regular   every other episode: ALL of them must fit the ceiling
# The season CRF is the first CRF whose largest regular episode fits;
# the isolated outlier then gets the lowest CRF from the season CRF up
# whose own estimate fits (series_episode_crf). Never above CRF_MAX.
# ------------------------------------------------------------

# series_sample_episodes COUNT WANTED [ALSO]  ->  episode indexes to
# sample, spread over the batch (first and last included), ascending,
# one per line; ALSO (the longest episode) is added when it is not
# among them
series_sample_episodes() {
    awk -v n="$1" -v k="$2" -v x="${3:-}" 'BEGIN {
        if (k >= n) { for (i = 0; i < n; i++) print i; exit }
        if (k <= 1) pick[int((n - 1) / 2)] = 1
        else for (j = 0; j < k; j++) pick[int(j * (n - 1) / (k - 1) + 0.5)] = 1
        if (x ~ /^[0-9]+$/ && x + 0 < n) pick[x + 0] = 1
        for (i = 0; i < n; i++) if (i in pick) print i
    }'
}

# series_longest_episode  ->  index of the longest episode (EP_DUR; the
# first one on a tie)
series_longest_episode() {
    printf '%s\n' "${EP_DUR[@]}" | awk '$1 + 0 > m || NR == 1 { m = $1 + 0; i = NR - 1 } END { if (NR) print i }'
}

# _median VALUE...  ->  median (mean of the two middle values for an
# even count), whole number
_median() {
    printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) exit 1
        if (NR % 2) printf "%.0f", v[(NR + 1) / 2]
        else printf "%.0f", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

# series_crf_spread RATE...
#
# RATE: per episode (EP_DUR order) the sampled video bytes per second,
# or "-" when that episode was not sampled. Reads EP_DUR and
# SERIES_CRF_OUTLIER_PCT.
#
# An episode that was not sampled may be as difficult as any sampled
# one, so it gets the HIGHEST sampled bitrate (the median would hide a
# difficult episode). Only with 3+ sampled episodes, a SINGLE sampled
# rate more than SERIES_CRF_OUTLIER_PCT above the median sampled rate is
# an isolated outlier: that episode keeps its own estimate, and the next
# highest rate fills the others. Two or more such rates are the season's
# difficulty and the highest is used.
#
# Sets:
#   SC_EP_BYTES[i]    estimated video bytes of episode i
#   SC_EP_FROM[i]     "sample", or "highest" (not sampled: SC_FILL_RATE);
#                     crf_series_estimate marks an episode sampled because
#                     it was decisive "promoted"
#   SC_MEDIAN_RATE    median sampled bytes/s
#   SC_FILL_RATE      bytes/s given to the episodes that were not sampled
#   SC_MEDIAN_BYTES   median of the episode estimates
series_crf_spread() {
    local rates=("$@") i sampled=()

    SC_EP_BYTES=()
    SC_EP_FROM=()

    for i in "${!rates[@]}"; do
        [[ "${rates[$i]}" =~ ^[0-9.]+$ ]] && sampled+=("${rates[$i]}")
    done
    (( ${#sampled[@]} )) || return 1

    read -r SC_MEDIAN_RATE SC_FILL_RATE < <(printf '%s\n' "${sampled[@]}" | sort -g |
        awk -v p="$SERIES_CRF_OUTLIER_PCT" '{ v[NR] = $1 } END {
            med = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
            hi = 0
            for (i = 1; i <= NR; i++) if (v[i] > med * (1 + p / 100)) hi++
            fill = (NR >= 3 && hi == 1) ? v[NR - 1] : v[NR]
            printf "%.3f %.3f\n", med, fill }')

    for i in "${!EP_DUR[@]}"; do
        if [[ "${rates[$i]:-}" =~ ^[0-9.]+$ ]]; then
            SC_EP_BYTES[$i]=$(awk -v r="${rates[$i]}" -v d="${EP_DUR[$i]}" 'BEGIN { printf "%.0f", r * d }')
            SC_EP_FROM[$i]="sample"
        else
            SC_EP_BYTES[$i]=$(awk -v r="$SC_FILL_RATE" -v d="${EP_DUR[$i]}" 'BEGIN { printf "%.0f", r * d }')
            SC_EP_FROM[$i]="highest"
        fi
    done

    SC_MEDIAN_BYTES=$(_median "${SC_EP_BYTES[@]}")
}

# series_batch_stats CEILING_BYTES VIDEO_BYTES...
#
# Season figures for one CRF. VIDEO_BYTES: estimated video bytes per
# episode (EP_DUR order). CEILING_BYTES 0 = no ceiling (Custom). Reads
# SERIES_CRF_OUTLIER_PCT.
#
# Sets:
#   SB_MEDIAN     median episode video bytes
#   SB_LARGEST    largest episode video bytes
#   SB_TOTAL      sum of the episode video bytes
#   SB_LIMIT      outlier threshold: SB_MEDIAN x (1 + SERIES_CRF_OUTLIER_PCT/100)
#   SB_OUTLIERS   indexes of the episodes above SB_LIMIT
#   SB_ISOLATED   index of the isolated outlier: the only outlier of a
#                 batch of 3+ episodes ("" = none)
#   SB_DECIDE     largest REGULAR episode (all but SB_ISOLATED): what the
#                 season CRF is checked on (crf_series_estimate)
#   SB_DECIDE_IDX index of that episode (the first one on a tie)
#   SB_ABOVE      indexes of the episodes above the ceiling
#   SB_FITS       1 when SB_DECIDE fits the ceiling (always 1 without one)
series_batch_stats() {
    local ceil="$1" i
    shift
    local vb=("$@")

    SB_ABOVE=()
    SB_OUTLIERS=()
    SB_ISOLATED=""
    SB_DECIDE_IDX=""
    SB_MEDIAN=$(_median "${vb[@]}") || return 1
    read -r SB_LARGEST SB_TOTAL < <(printf '%s\n' "${vb[@]}" |
        awk '{ t += $1; if (NR == 1 || $1 > m) m = $1 } END { printf "%.0f %.0f\n", m, t }')
    SB_LIMIT=$(awk -v m="$SB_MEDIAN" -v p="$SERIES_CRF_OUTLIER_PCT" 'BEGIN { printf "%.0f", m * (1 + p / 100) }')

    for i in "${!vb[@]}"; do
        (( vb[i] > SB_LIMIT )) && SB_OUTLIERS+=("$i")
        (( ceil > 0 && vb[i] > ceil )) && SB_ABOVE+=("$i")
    done
    if (( ${#vb[@]} >= 3 && ${#SB_OUTLIERS[@]} == 1 )); then
        SB_ISOLATED="${SB_OUTLIERS[0]}"
    fi

    SB_DECIDE=0
    for i in "${!vb[@]}"; do
        [[ "$i" == "$SB_ISOLATED" ]] && continue
        if [[ -z "$SB_DECIDE_IDX" ]] || (( vb[i] > SB_DECIDE )); then
            SB_DECIDE="${vb[i]}"
            SB_DECIDE_IDX="$i"
        fi
    done

    SB_FITS=0
    (( ceil <= 0 || SB_DECIDE <= ceil )) && SB_FITS=1
    return 0
}

# series_from_sampled FROM  ->  0 when an episode estimate (SC_EP_FROM /
# EP_FROM) comes from the episode's own samples: "sample" (in the sample
# set) or "promoted" (not in it, sampled itself because it was decisive,
# series_decisive_inferred); "highest" (inferred) -> 1
series_from_sampled() {
    [[ "$1" == sample || "$1" == promoted ]]
}

# series_from_text FROM  ->  "sampled" | "sampled after inference" | "inferred"
series_from_text() {
    case "$1" in
        sample)   printf 'sampled' ;;
        promoted) printf 'sampled after inference' ;;
        *)        printf 'inferred' ;;
    esac
}

# series_decisive_inferred CEILING_BYTES
#
# Inferred estimates (episodes not sampled: SC_EP_FROM "highest", the
# highest sampled bitrate x their runtime) may screen a season CRF but
# never make it fail on their own. After series_crf_spread and
# series_batch_stats of one CRF (reads SC_EP_BYTES, SC_EP_FROM, SB_FITS,
# SB_OUTLIERS, SB_ISOLATED):
#   - the season fits, or no ceiling (Custom): nothing to sample (1)
#   - the failure is proven by own samples alone: at least two sampled
#     episodes above the ceiling (only ONE can be the isolated outlier,
#     so a regular one is above it whatever the inferred episodes turn
#     out to be), or one in a batch of 1-2 episodes (no isolated outlier
#     there): nothing to sample (1), no sample is wasted
#   - otherwise every inferred REGULAR episode can still change the
#     decision: one above the ceiling makes the largest regular episode
#     too large; one that is an outlier keeps a sampled episode above the
#     ceiling from being the isolated outlier; and any of them, sampled
#     lower, can lower the median until the ONE sampled episode above the
#     ceiling becomes the isolated outlier. SD_INDEX = the largest
#     inferred regular episode (0); it is sampled itself at this CRF and
#     everything recomputed before the season may fail
#     (crf_series_estimate), one episode at a time, until the season
#     fits, the failure is proven as above, or none is left
#   - no inferred regular episode left: the failure stands (1)
# An inferred isolated outlier never decides the season (it is sampled
# itself before it gets its own CRF).
series_decisive_inferred() {
    local ceil="$1" i n over=0 best=""

    SD_INDEX=""
    (( ceil > 0 && SB_FITS == 0 )) || return 1

    n=${#SC_EP_BYTES[@]}
    for i in "${!SC_EP_BYTES[@]}"; do
        series_from_sampled "${SC_EP_FROM[$i]:-}" || continue
        (( SC_EP_BYTES[i] > ceil )) && ((over += 1))
    done
    (( over >= 2 || (over >= 1 && n < 3) )) && return 1

    for i in "${!SC_EP_BYTES[@]}"; do
        series_from_sampled "${SC_EP_FROM[$i]:-}" && continue
        [[ "$i" == "$SB_ISOLATED" ]] && continue
        if [[ -z "$best" ]] || (( SC_EP_BYTES[i] > SC_EP_BYTES[best] )); then
            best="$i"
        fi
    done

    [[ -n "$best" ]] || return 1
    SD_INDEX="$best"
    return 0
}

# series_crf_certify_over SKIPPED NEXT CEILING_BYTES  (CERTIFY for the
# season search: crf_select over crf_series_estimate)
#
# 0 when the samples at NEXT (= SKIPPED + 1, too large) prove that the
# season cannot fit at SKIPPED either, without sampling SKIPPED. The
# season fit is not monotonic in the CRF (which episode is the isolated
# outlier, which one is the largest regular episode and which sampled
# rate fills the episodes not sampled may all change), so the only
# evidence used is an episode's OWN sample: it does not shrink when the
# CRF is lowered, so a sampled episode above the ceiling at NEXT is above
# it at SKIPPED as well. Episodes not sampled (estimated from the other
# episodes' rates, series_crf_spread) are never evidence, however large
# their estimate. SKIPPED is proven too large when
#   - 3+ episodes: at least two sampled episodes are above the ceiling at
#     NEXT (only ONE episode can be the isolated outlier, so a regular
#     one is above it at SKIPPED)
#   - 1-2 episodes (no isolated outlier there): at least one sampled
#     episode is above the ceiling at NEXT
# Otherwise 1: SKIPPED is sampled. Reads CRF_SERIES_RATES[NEXT]
# (crf_series_estimate; "-" = not sampled) and EP_DUR.
series_crf_certify_over() {
    local next="$2" ceil="$3"

    [[ -n "${CRF_SERIES_RATES[$next]:-}" ]] || return 1
    awk -v r="${CRF_SERIES_RATES[$next]}" -v d="${EP_DUR[*]}" -v c="$ceil" 'BEGIN {
        n = split(r, rate, " ")
        if (n == 0 || split(d, dur, " ") != n) exit 1
        over = 0
        for (i = 1; i <= n; i++)
            if (rate[i] != "-" && sprintf("%.0f", rate[i] * dur[i]) + 0 > c) over++
        exit !(over >= 2 || (over >= 1 && n < 3))
    }'
}

# series_episode_crf INDEX FROM_CRF CRF_MAX CEILING_BYTES ESTIMATOR [REPORT]
#
# Own CRF of the isolated outlier: from FROM_CRF (the season CRF) up,
# the lowest CRF whose estimate for episode INDEX fits the ceiling, never
# above CRF_MAX (crf_search_up: +1 / +2 steps, the CRF just below the
# chosen one sampled above the ceiling; one episode's samples shrink as
# the CRF rises, so a CRF skipped before a too-large one is too large).
# ESTIMATOR INDEX CRF leaves that episode's video bytes in
# CRF_EST_RESULT (non-zero = failed). REPORT: see crf_search_up.
#
# Sets EPC_CRF (chosen CRF), EPC_BYTES (its estimate), EPC_TRIED (CRFs
# estimated, in order) and EPC_OVER (1 when even CRF_MAX does not fit).
# Returns 1 when an estimate failed (EPC_CRF empty).
series_episode_crf() {
    local from="$2" max="$3" ceil="$4" report="${6:-}"

    EPC_CRF=""
    EPC_BYTES=""
    EPC_OVER=0
    EPC_TRIED=()
    _EPC_INDEX="$1"
    _EPC_EST="$5"

    crf_search_up "$from" "$max" "$ceil" _series_episode_probe "$report" || return 1

    EPC_CRF="$CRFS_CRF"
    EPC_BYTES="$CRFS_BYTES"
    EPC_OVER="$CRFS_OVER"
    return 0
}

# _series_episode_probe CRF  (PROBE for series_episode_crf)
_series_episode_probe() {
    CRF_EST_RESULT=""
    "$_EPC_EST" "$_EPC_INDEX" "$1" || return 1
    EPC_TRIED+=("$1")
}

# series_est_map INDEX  ->  "CRF=BYTES:..." of episode INDEX for the job's
# lower-CRF prediction: its season estimates (CRF_SERIES_EP_BYTES over
# CRF_TRIED), its own sampled estimates (CRF_EP_EST "INDEX:CRF") taking
# precedence
series_est_map() {
    local i="$1" c k out=""
    local -a eb
    local -A m=()

    for c in "${CRF_TRIED[@]}"; do
        read -ra eb <<< "${CRF_SERIES_EP_BYTES[$c]:-}"
        [[ -n "${eb[i]:-}" ]] && m[$c]="${eb[i]}"
    done
    for k in ${CRF_EP_EST[@]+"${!CRF_EP_EST[@]}"}; do
        [[ "${k%%:*}" == "$i" ]] && m[${k#*:}]="${CRF_EP_EST[$k]}"
    done
    for c in $(printf '%s\n' ${m[@]+"${!m[@]}"} | sort -n); do
        out+="${out:+:}$c=${m[$c]}"
    done
    printf '%s' "$out"
}

# series_guard_episodes ESTIMATOR
#
# Source-quality guard of the series menu: GUARD = indexes of the
# episodes whose estimate at their CRF (EP_CRF / EP_EST) is not below
# their source video (EP_VBYTES). An episode flagged only from the
# conservative not-sampled estimate (EP_FROM not "sample": highest
# sampled bitrate x runtime) is first estimated itself at its CRF
# (ESTIMATOR INDEX CRF, e.g. crf_episode_estimate, cached) and only kept
# when its own estimate still is not below the source; EP_EST / EP_FROM
# take the own estimate. Episodes skipped at the ceiling (EP_CEIL_SKIP)
# are left out. GUARD_SAMPLED = the episodes sampled here. Prints a
# header line before the first such sample. Returns 1 when an estimate
# failed.
series_guard_episodes() {
    local est="$1" i

    GUARD=()
    GUARD_SAMPLED=()

    for i in "${!EP_EST[@]}"; do
        (( ${EP_CEIL_SKIP[i]:-0} == 1 )) && continue
        crf_above_source "${EP_EST[$i]}" "${EP_VBYTES[$i]:-}" || continue

        if ! series_from_sampled "${EP_FROM[$i]:-}"; then
            if (( ${#GUARD_SAMPLED[@]} == 0 )); then
                echo
                echo "Source check (not sampled; estimated at or above the source video):"
            fi
            CRF_EST_RESULT=""
            if ! "$est" "$i" "${EP_CRF[$i]}" || [[ ! "$CRF_EST_RESULT" =~ ^[0-9]+$ ]]; then
                return 1
            fi
            EP_EST[$i]="$CRF_EST_RESULT"
            EP_FROM[$i]="sample"
            GUARD_SAMPLED+=("$i")
            crf_above_source "${EP_EST[$i]}" "${EP_VBYTES[$i]:-}" || continue
        fi

        GUARD+=("$i")
    done
    return 0
}

# series_late_ceiling ESTIMATOR [REPORT]
#
# After series_guard_episodes: an episode whose not-sampled estimate was
# replaced by its own sample there (GUARD_SAMPLED) and is now above the
# per-episode ceiling gets its own CRF before the encode: from its
# current CRF up (series_episode_crf with ESTIMATOR, e.g.
# crf_episode_estimate, and REPORT; its own sample at the current CRF is
# reused from the cache), never above CRF_MAX. The season CRF and every other
# episode stay as they are. Updates EP_CRF / EP_EST / EP_OVER (1: still
# above the ceiling at CRF_MAX). LATE = the episodes changed. Reads
# CRF_CEILING_BYTES (0, Custom: nothing to do) and CRF_MAX. Prints a
# header line before the first one. Returns 1 when an estimate failed.
series_late_ceiling() {
    local est="$1" report="${2:-}" i

    LATE=()
    (( ${CRF_CEILING_BYTES:-0} > 0 )) || return 0

    for i in ${GUARD_SAMPLED[@]+"${GUARD_SAMPLED[@]}"}; do
        (( EP_EST[i] > CRF_CEILING_BYTES )) || continue
        if (( ${#LATE[@]} == 0 )); then
            echo
            echo "Ceiling check (own sample above the ceiling at its CRF):"
        fi
        series_episode_crf "$i" "${EP_CRF[$i]}" "$CRF_MAX" "$CRF_CEILING_BYTES" "$est" "$report" || return 1
        EP_CRF[$i]="$EPC_CRF"
        EP_EST[$i]="$EPC_BYTES"
        EP_OVER[$i]="$EPC_OVER"
        LATE+=("$i")
    done
    return 0
}

# series_crf_analysis_lines  ->  per tried CRF: median / largest episode,
# outliers, episodes above the ceiling, fits or not. Reads CRF_TRIED,
# CRF_SERIES_EP_BYTES, CRF_CEILING_BYTES, CRF_CEILING_GIB, FILES.
series_crf_analysis_lines() {
    local c eb ef d

    for c in "${CRF_TRIED[@]}"; do
        read -ra eb <<< "${CRF_SERIES_EP_BYTES[$c]}"
        read -ra ef <<< "${CRF_SERIES_EP_FROM[$c]:-}"
        series_batch_stats "${CRF_CEILING_BYTES:-0}" "${eb[@]}" || continue
        echo "  CRF $c:"
        echo "    median episode:  $(size_text "$SB_MEDIAN") video"
        # the largest REGULAR episode decides; its estimate sampled / inferred
        d="$(basename "${FILES[$SB_DECIDE_IDX]:-episode $((SB_DECIDE_IDX + 1))}"), $(series_from_text "${ef[SB_DECIDE_IDX]:-}")"
        if [[ -n "$SB_ISOLATED" ]]; then
            echo "    largest episode: $(size_text "$SB_LARGEST") video"
            echo "    largest regular: $(size_text "$SB_DECIDE") video ($d)"
        else
            echo "    largest episode: $(size_text "$SB_LARGEST") video ($d)"
        fi
        if [[ -n "$SB_ISOLATED" ]]; then
            echo "    isolated outlier: $(basename "${FILES[$SB_ISOLATED]:-episode $((SB_ISOLATED + 1))}") ($(size_text "${eb[SB_ISOLATED]}"), above median +${SERIES_CRF_OUTLIER_PCT}%)"
        elif (( ${#SB_OUTLIERS[@]} > 1 )); then
            echo "    ${#SB_OUTLIERS[@]} episodes above median +${SERIES_CRF_OUTLIER_PCT}% (season difficulty, not outliers)"
        fi
        if (( ${CRF_CEILING_BYTES:-0} > 0 )); then
            echo "    ceiling:         ${CRF_CEILING_GIB} GiB/episode"
            printf '    -> %s; %d of %d episode(s) above the ceiling\n' \
                "$( (( SB_FITS == 1 )) && echo "regular episodes fit" || echo "regular episode above the ceiling")" \
                "${#SB_ABOVE[@]}" "${#eb[@]}"
        fi
    done
}

# series_size_factor  ->  1 - reserve, for size estimates
series_size_factor() {
    awk -v r="$SERIES_CONTAINER_RESERVE_PCT" 'BEGIN { printf "%.6f", (100 - r) / 100 }'
}

# series_crf_plan VIDEO_BYTES...
#
# Expected sizes for the chosen CRF. VIDEO_BYTES: estimated video bytes
# per episode (EP_DUR order; "copy" = the source video is kept, its
# size from EP_VKBPS). Reads EP_DUR, EP_VKBPS, EP_ABYTES (bytes of all
# source audio of the episode, copied unchanged; "N/A" -> estimated from
# EP_AKBPS, the source audio kb/s per track).
#
# Sets:
#   P_EP_AKBPS[i]       copied audio kb/s of the episode (all tracks)
#   P_EP_VGIB[i] P_EP_AGIB[i] P_EP_GIB[i]   expected video / audio / total
#   P_TOTAL_SECONDS
#   P_VIDEO_GIB P_AUDIO_GIB P_TOTAL_GIB     totals
# Audio is on top of the video size; total sizes add
# SERIES_CONTAINER_RESERVE_PCT for container/subtitles.
series_crf_plan() {
    local vb=("$@") i v ab f

    f=$(series_size_factor)

    P_EP_AKBPS=()
    P_EP_VGIB=()
    P_EP_AGIB=()
    P_EP_GIB=()

    local video_bytes=0 audio_bytes=0 seconds=0

    for i in "${!EP_DUR[@]}"; do
        v="${vb[$i]:-0}"
        if [[ "$v" == "copy" ]]; then
            v=$(awk -v k="${EP_VKBPS[$i]:-0}" -v s="${EP_DUR[$i]}" 'BEGIN {
                if (k !~ /^[0-9]+$/) k = 0; printf "%.0f", k * 1000 / 8 * s }')
        fi

        ab="${EP_ABYTES[$i]:-N/A}"
        if [[ ! "$ab" =~ ^[0-9]+$ ]]; then
            ab=$(awk -v l="${EP_AKBPS[$i]:-}" -v s="${EP_DUR[$i]}" 'BEGIN {
                n = split(l, k, " "); for (j = 1; j <= n; j++) if (k[j] ~ /^[0-9]+$/) t += k[j]
                printf "%.0f", t * 1000 / 8 * s }')
        fi

        read -r P_EP_AKBPS[$i] P_EP_VGIB[$i] P_EP_AGIB[$i] P_EP_GIB[$i] < <(
            awk -v v="$v" -v a="$ab" -v s="${EP_DUR[$i]}" -v f="$f" 'BEGIN {
                G = 1073741824
                printf "%.0f %.2f %.2f %.2f\n", (s > 0 ? a * 8 / s / 1000 : 0), v / G, a / G, (v + a) / G / f }')

        read -r video_bytes audio_bytes seconds < <(
            awk -v vt="$video_bytes" -v at="$audio_bytes" -v st="$seconds" \
                -v v="$v" -v a="$ab" -v s="${EP_DUR[$i]}" \
                'BEGIN { printf "%.0f %.0f %.3f\n", vt + v, at + a, st + s }')
    done

    P_TOTAL_SECONDS="$seconds"
    read -r P_VIDEO_GIB P_AUDIO_GIB P_TOTAL_GIB < <(
        awk -v v="$video_bytes" -v a="$audio_bytes" -v f="$f" 'BEGIN {
            G = 1073741824
            printf "%.2f %.2f %.2f\n", v / G, a / G, (v + a) / G / f }')
}

# ------------------------------------------------------------
# Audio-only menu
# ------------------------------------------------------------

# _audio_menu_by_channels PREFIX CHANNELS  ->  PREFIX_{1,2,3TO4,5TO6,7PLUS}
_audio_menu_by_channels() {
    local ch="$2" k

    [[ "$ch" =~ ^[0-9]+$ ]] || ch=2

    if (( ch <= 1 )); then k="${1}_1"
    elif (( ch == 2 )); then k="${1}_2"
    elif (( ch <= 4 )); then k="${1}_3TO4"
    elif (( ch <= 6 )); then k="${1}_5TO6"
    else k="${1}_7PLUS"; fi

    echo "${!k}"
}

audio_menu_high_kbps()    { _audio_menu_by_channels AUDIO_HIGH_KBPS "$1"; }
audio_menu_compact_kbps() { _audio_menu_by_channels AUDIO_COMPACT_KBPS "$1"; }
