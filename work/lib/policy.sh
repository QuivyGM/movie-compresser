#!/usr/bin/env bash
# Compression policy: loads and validates compress.conf and holds the
# policy math that uses it (movie Quality bitrate target, CRF tier
# selection for movie / series High, Base and Custom, audio-menu rates).
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
    MOVIE_QUALITY_VIDEO_GIB_PER_HOUR MOVIE_QUALITY_VIDEO_MIN_GIB
    MOVIE_HIGH_VIDEO_SIZE_CEILING_GIB MOVIE_BASE_VIDEO_SIZE_CEILING_GIB
    SERIES_HIGH_VIDEO_SIZE_CEILING_GIB SERIES_BASE_VIDEO_SIZE_CEILING_GIB
    CRF_SAMPLE_SECONDS
    AUDIO_HIGH_TRIGGER_KBPS AUDIO_COMPACT_TRIGGER_GIB AUDIO_COMPACT_LIMIT_GIB
    AUDIO_HIGH_KBPS_1 AUDIO_HIGH_KBPS_2 AUDIO_HIGH_KBPS_3TO4
    AUDIO_HIGH_KBPS_5TO6 AUDIO_HIGH_KBPS_7PLUS
    AUDIO_COMPACT_KBPS_1 AUDIO_COMPACT_KBPS_2 AUDIO_COMPACT_KBPS_3TO4
    AUDIO_COMPACT_KBPS_5TO6 AUDIO_COMPACT_KBPS_7PLUS
)

# 0 allowed (0 = "no ceiling" / "no limit")
POLICY_KEYS_NONNEG=(
    MOVIE_QUALITY_VIDEO_FLOOR_MBPS MOVIE_QUALITY_VIDEO_MAX_MBPS
)

# x265 CRF values: whole numbers 0..CRF_LIMIT
CRF_LIMIT=51
POLICY_KEYS_CRF=(
    MOVIE_HIGH_CRF_MIN MOVIE_HIGH_CRF_MAX MOVIE_BASE_CRF_MIN MOVIE_BASE_CRF_MAX
    SERIES_HIGH_CRF_MIN SERIES_HIGH_CRF_MAX SERIES_BASE_CRF_MIN SERIES_BASE_CRF_MAX
)

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

# Settings of the former High / Base size-target (GiB/hour, two-pass)
# video policy, replaced by the CRF tiers; a config that still sets
# them gets a note.
POLICY_KEYS_RETIRED_VIDEO=(
    MOVIE_HIGH_VIDEO_GIB_PER_HOUR MOVIE_HIGH_VIDEO_FLOOR_MBPS MOVIE_HIGH_VIDEO_MAX_MBPS
    MOVIE_BASE_VIDEO_GIB_PER_HOUR MOVIE_BASE_VIDEO_FLOOR_MBPS MOVIE_BASE_VIDEO_MAX_MBPS
    SERIES_HIGH_VIDEO_GIB_PER_HOUR SERIES_HIGH_VIDEO_FLOOR_MBPS SERIES_HIGH_VIDEO_MAX_MBPS
    SERIES_BASE_VIDEO_GIB_PER_HOUR SERIES_BASE_VIDEO_FLOOR_MBPS SERIES_BASE_VIDEO_MAX_MBPS
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

    for k in "${POLICY_KEYS_POSITIVE[@]}" "${POLICY_KEYS_NONNEG[@]}"; do
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
    for f in MOVIE_HIGH MOVIE_BASE SERIES_HIGH SERIES_BASE; do
        local lo="${f}_CRF_MIN" hi="${f}_CRF_MAX"
        if [[ "${!lo:-}" =~ ^[0-9]+$ && "${!hi:-}" =~ ^[0-9]+$ ]] && (( 10#${!hi} < 10#${!lo} )); then
            errs+=("$hi (${!hi}) is lower than $lo (${!lo})")
        fi
    done

    # floor <= max (when a max is set)
    for f in MOVIE_QUALITY; do
        local fl="${f}_VIDEO_FLOOR_MBPS" mx="${f}_VIDEO_MAX_MBPS"
        if _policy_is_num "${!fl:-}" && _policy_is_num "${!mx:-}" &&
           awk -v a="${!fl}" -v b="${!mx}" 'BEGIN { exit !(b > 0 && a > b) }'; then
            errs+=("$fl (${!fl}) is greater than $mx (${!mx})")
        fi
    done

    if _policy_is_num "${SERIES_CONTAINER_RESERVE_PCT:-}"; then
        if awk -v x="$SERIES_CONTAINER_RESERVE_PCT" 'BEGIN { exit !(x >= 100) }'; then
            errs+=("SERIES_CONTAINER_RESERVE_PCT=\"$SERIES_CONTAINER_RESERVE_PCT\": must be below 100")
        fi
    elif [[ -z "${SERIES_CONTAINER_RESERVE_PCT+x}" ]]; then
        errs+=("SERIES_CONTAINER_RESERVE_PCT is not set")
    else
        errs+=("SERIES_CONTAINER_RESERVE_PCT=\"$SERIES_CONTAINER_RESERVE_PCT\": not a number 0-99")
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
    unset "${POLICY_KEYS_POSITIVE[@]}" "${POLICY_KEYS_NONNEG[@]}" \
        "${POLICY_KEYS_CRF[@]}" "${POLICY_KEYS_COUNT[@]}" \
        "${POLICY_KEYS_RETIRED[@]}" "${POLICY_KEYS_RETIRED_VIDEO[@]}" \
        SERIES_CONTAINER_RESERVE_PCT

    # shellcheck source=/dev/null
    if ! source "$conf"; then
        echo "Could not read $conf (bash syntax error?)." >&2
        return 1
    fi

    policy_retired_note
    validate_policy
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
        echo "      *_CRF_MIN / *_CRF_MAX / *_VIDEO_SIZE_CEILING_GIB):" >&2
        printf '        %s\n' "${set[@]}" >&2
    fi
    return 0
}

# ------------------------------------------------------------
# Movie Quality (two-pass bitrate target)
# ------------------------------------------------------------

# movie_video_plan Quality DURATION_SECONDS [SOURCE_VIDEO_BYTES]
#
# Quality sizes the video from the runtime:
#   rate   = hours * MOVIE_QUALITY_VIDEO_GIB_PER_HOUR
#   target = max(rate, MOVIE_QUALITY_VIDEO_MIN_GIB)
#   target = min(target, source video size)
#   bitrate from target and duration, capped at MOVIE_QUALITY_VIDEO_MAX_MBPS
#   (0 = no cap). Below the floor -> the menu asks floor vs target.
#
# The floor conflict is skipped when the source limits the target
# (encoding above the source is never done, so the floor could not be
# used). High / Base are CRF tiers (crf_tier_load / crf_select below).
#
# Sets:
#   PLAN_TARGET_MBPS      video target from the policy (the menu still
#                         applies the "never above source bitrate" cap)
#   PLAN_FLOOR_MBPS       floor of the tier
#   PLAN_MAX_MBPS         bitrate max of the tier (0 = none)
#   PLAN_GIB_PER_HOUR     GiB/hour of the tier
#   PLAN_SIZE_MBPS        bitrate of the selected size
#   PLAN_BELOW_FLOOR      1 when the target is below the floor: the menu
#                         asks floor vs target
#   PLAN_RATE_GIB         GiB/hour * runtime
#   PLAN_MIN_GIB          configured minimum size
#   PLAN_TARGET_GIB       selected video size (after the source limit)
#   PLAN_SOURCE_GIB       source video size ("" when not known)
#   PLAN_SOURCE_MBPS      source video bitrate ("" when not known)
#   PLAN_SOURCE_LIMITED   1 when the source size lowered the target
#   PLAN_SOURCE_BELOW_FLOOR 1 when the source bitrate is below the floor
#   PLAN_MAX_LIMITED      1 when the bitrate max lowered the target
movie_video_plan() {
    local tier="$1" dur="$2" src_bytes="${3:-}"
    local gib floor max t

    PLAN_BELOW_FLOOR=0
    PLAN_SIZE_MBPS=""
    PLAN_MIN_GIB=""
    PLAN_SOURCE_GIB=""
    PLAN_SOURCE_MBPS=""
    PLAN_SOURCE_LIMITED=0
    PLAN_SOURCE_BELOW_FLOOR=0
    PLAN_MAX_LIMITED=0

    if [[ "$tier" != "Quality" ]]; then
        echo "movie_video_plan: $tier is not a bitrate tier (High / Base / Custom use CRF)" >&2
        return 1
    fi

    floor="$MOVIE_QUALITY_VIDEO_FLOOR_MBPS"
    max="$MOVIE_QUALITY_VIDEO_MAX_MBPS"
    PLAN_GIB_PER_HOUR="$MOVIE_QUALITY_VIDEO_GIB_PER_HOUR"

    PLAN_RATE_GIB=$(awk -v r="$PLAN_GIB_PER_HOUR" -v d="$dur" \
        'BEGIN { printf "%.3f", r * d / 3600 }')
    PLAN_MIN_GIB=$(awk -v m="$MOVIE_QUALITY_VIDEO_MIN_GIB" 'BEGIN { printf "%.3f", m }')
    gib=$(max_value "$PLAN_RATE_GIB" "$PLAN_MIN_GIB")

    if [[ "$src_bytes" =~ ^[0-9]+$ ]] && (( src_bytes > 0 )); then
        PLAN_SOURCE_GIB=$(awk -v b="$src_bytes" 'BEGIN { printf "%.3f", b / 1073741824 }')
        PLAN_SOURCE_MBPS=$(awk -v b="$src_bytes" -v d="$dur" 'BEGIN { printf "%.3f", b * 8 / d / 1000000 }')
        if awk -v s="$PLAN_SOURCE_GIB" -v g="$gib" 'BEGIN { exit !(s < g) }'; then
            gib="$PLAN_SOURCE_GIB"
            PLAN_SOURCE_LIMITED=1
        fi
        awk -v s="$PLAN_SOURCE_MBPS" -v f="$floor" 'BEGIN { exit !(s < f) }' &&
            PLAN_SOURCE_BELOW_FLOOR=1
    fi

    PLAN_TARGET_GIB="$gib"
    if (( PLAN_SOURCE_LIMITED == 1 )); then
        # exact bytes, not the 0.001 GiB rounded size (small sources)
        PLAN_SIZE_MBPS="$PLAN_SOURCE_MBPS"
    else
        PLAN_SIZE_MBPS=$(bitrate_for_gib "$gib" "$dur")
    fi
    t="$PLAN_SIZE_MBPS"

    if awk -v m="$max" -v x="$t" 'BEGIN { exit !(m > 0 && x > m) }'; then
        t=$(min_value "$max" "$t")
        PLAN_MAX_LIMITED=1
    fi

    if (( PLAN_SOURCE_LIMITED == 0 )) &&
       awk -v x="$t" -v f="$floor" 'BEGIN { exit !(x < f) }'; then
        PLAN_BELOW_FLOOR=1
    fi

    PLAN_TARGET_MBPS="$t"
    PLAN_FLOOR_MBPS="$floor"
    PLAN_MAX_MBPS="$max"
}

# movie_policy_line TIER  ->  one-line description of the effective values
movie_policy_line() {
    case "$1" in
        Quality)
            printf 'quality-first [two-pass, %s GiB/hour video, at least %s GiB / %s Mb/s floor / %s]' \
                "$MOVIE_QUALITY_VIDEO_GIB_PER_HOUR" "$MOVIE_QUALITY_VIDEO_MIN_GIB" \
                "$MOVIE_QUALITY_VIDEO_FLOOR_MBPS" \
                "$(awk -v m="$MOVIE_QUALITY_VIDEO_MAX_MBPS" 'BEGIN { print (m > 0) ? m " Mb/s max" : "no bitrate max" }')"
            ;;
        High|Base)
            crf_tier_load movie "$1"
            printf 'CRF %s-%s [CRF %s preferred; raised only while the video estimate is above %s GiB]' \
                "$CRF_MIN" "$CRF_MAX" "$CRF_MIN" "$CRF_CEILING_GIB"
            ;;
        Custom)
            printf 'CRF entered in the menu, used exactly'
            ;;
    esac

    printf '; audio copied'
}

# audio_copy_policy_lines  ->  the audio rule of the movie / series menus
audio_copy_policy_lines() {
    echo "Audio:"
    echo "  all tracks copied unchanged"
    echo "  use audio_compress_menu.sh for optional audio compression"
}

# movie_video_policy_lines TIER  ->  the tier's video settings, one per line
movie_video_policy_lines() {
    case "$1" in
        Quality)
            echo "Quality video policy:"
            echo "  two-pass bitrate encode"
            echo "  ${MOVIE_QUALITY_VIDEO_GIB_PER_HOUR} GiB/hour"
            echo "  minimum preferred video size: ${MOVIE_QUALITY_VIDEO_MIN_GIB} GiB"
            echo "  bitrate floor: ${MOVIE_QUALITY_VIDEO_FLOOR_MBPS} Mb/s"
            awk -v m="$MOVIE_QUALITY_VIDEO_MAX_MBPS" 'BEGIN { print "  bitrate max: " ((m > 0) ? m " Mb/s" : "none") }'
            ;;
        *)
            crf_policy_lines movie "$1" "${2:-}"
            ;;
    esac
}

# ------------------------------------------------------------
# CRF tiers (movie / series High, Base; Custom)
#
# Lower CRF = higher quality. CRF_MIN is the tier's preferred (highest)
# quality, CRF_MAX the lowest quality it allows. Per title:
#
#   crf = CRF_MIN
#   while estimated video size (crf) > ceiling and crf < CRF_MAX:
#       crf = crf + 1
#
# i.e. the lowest CRF whose estimate fits the VIDEO size ceiling, never
# below CRF_MIN (unused room is not filled) and never above CRF_MAX
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

# crf_tier_load SCOPE TIER [CUSTOM_CRF]
#
# SCOPE: movie | series. TIER: High | Base | Custom.
# Sets CRF_MIN CRF_MAX CRF_CEILING_GIB CRF_CEILING_BYTES.
# Custom: CRF_MIN = CRF_MAX = CUSTOM_CRF, no ceiling (CRF_CEILING_BYTES=0).
crf_tier_load() {
    local scope="${1^^}" tier="$2" u

    case "$tier" in
        High|Base)
            u="${tier^^}"
            local a="${scope}_${u}_CRF_MIN" b="${scope}_${u}_CRF_MAX" c="${scope}_${u}_VIDEO_SIZE_CEILING_GIB"
            CRF_MIN="${!a}"
            CRF_MAX="${!b}"
            CRF_CEILING_GIB="${!c}"
            CRF_CEILING_BYTES=$(_gib_bytes "$CRF_CEILING_GIB")
            ;;
        Custom)
            CRF_MIN="${3:-}"
            CRF_MAX="${3:-}"
            CRF_CEILING_GIB=""
            CRF_CEILING_BYTES=0
            ;;
        *)
            echo "crf_tier_load: unknown tier $tier" >&2
            return 1
            ;;
    esac
}

# crf_policy_lines SCOPE TIER [CUSTOM_CRF]  ->  the tier's video policy
crf_policy_lines() {
    local scope="$1" tier="$2"

    crf_tier_load "$scope" "$tier" "${3:-}" || return 1

    echo "$tier video policy:"
    if [[ "$tier" == "Custom" ]]; then
        if [[ "$scope" == series ]]; then
            echo "  CRF: exact user CRF${CRF_MIN:+ ($CRF_MIN)}; no High/Base CRF range or size ceiling"
            echo "  one CRF for every episode of the batch"
        else
            echo "  CRF: ${CRF_MIN:-entered in the menu} (used exactly; no size ceiling)"
        fi
    elif [[ "$scope" == series ]]; then
        echo "  CRF range: ${CRF_MIN}-${CRF_MAX} (${CRF_MIN} preferred; raised only while the median episode is above the ceiling)"
        echo "  nominal video ceiling: ${CRF_CEILING_GIB} GiB/episode (episodes above it are listed, same CRF)"
        echo "  one CRF for every episode of the batch"
    else
        echo "  CRF range: ${CRF_MIN}-${CRF_MAX} (${CRF_MIN} preferred, raised only to fit the ceiling)"
        echo "  video size ceiling: ${CRF_CEILING_GIB} GiB"
    fi
    echo "  encode: x265 CRF, single pass, preset slow, 10-bit"
    echo "  audio: copied unchanged"
}

# crf_select CRF_MIN CRF_MAX CEILING_BYTES ESTIMATOR
#
# ESTIMATOR CRF: a function that estimates the VIDEO size at CRF and
# leaves it in CRF_EST_RESULT (whole bytes); non-zero = failed.
# CRFs are tried from CRF_MIN upwards; the first one that fits is
# chosen and no higher CRF is estimated. CEILING_BYTES 0 = no ceiling.
#
# Sets:
#   CRF_SELECTED      chosen CRF
#   CRF_TRIED         CRFs estimated, in order
#   CRF_EST[crf]      estimated video bytes per tried CRF
#   CRF_OVER_CEILING  1 when CRF_MAX was reached and still does not fit
# Returns 1 when an estimate failed (CRF_SELECTED is then empty).
crf_select() {
    local min="$1" max="$2" ceil="$3" est="$4" c

    declare -gA CRF_EST=()
    CRF_TRIED=()
    CRF_SELECTED=""
    CRF_OVER_CEILING=0

    for ((c = 10#$min; c <= 10#$max; c++)); do
        CRF_EST_RESULT=""
        if ! "$est" "$c" || [[ ! "$CRF_EST_RESULT" =~ ^[0-9]+$ ]]; then
            CRF_SELECTED=""
            return 1
        fi

        CRF_TRIED+=("$c")
        CRF_EST[$c]="$CRF_EST_RESULT"
        CRF_SELECTED="$c"

        if (( ceil <= 0 || CRF_EST_RESULT <= ceil )); then
            return 0
        fi
    done

    CRF_OVER_CEILING=1
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
        printf '  CRF %s -> estimated %s video\n' "$c" "$(size_text "${CRF_EST[$c]}")"
    done
}

# ------------------------------------------------------------
# Series CRF
#
# One CRF for the whole batch (season / folder), so episodes look the
# same. Episodes are sampled (SERIES_CRF_SAMPLE_EPISODES of them, spread
# over the batch, SERIES_CRF_SAMPLE_POINTS sections each); an episode
# that is not sampled gets the median sampled video bitrate. For each
# candidate CRF (from CRF_MIN up) every episode's video size is
# estimated, and the batch counts as fitting when the MEDIAN episode
# estimate is within the per-episode ceiling. One unusually complex
# episode therefore does not push every episode to a worse CRF; it is
# listed as above the ceiling instead. The CRF never varies per episode.
# ------------------------------------------------------------

# series_sample_episodes COUNT WANTED  ->  episode indexes to sample,
# spread over the batch (first and last included), one per line
series_sample_episodes() {
    awk -v n="$1" -v k="$2" 'BEGIN {
        if (k >= n) { for (i = 0; i < n; i++) print i; exit }
        if (k <= 1) { print int((n - 1) / 2); exit }
        last = -1
        for (j = 0; j < k; j++) {
            i = int(j * (n - 1) / (k - 1) + 0.5)
            if (i != last) print i
            last = i
        }
    }'
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
# or "-" when that episode was not sampled. Reads EP_DUR.
#
# Sets:
#   SC_EP_BYTES[i]    estimated video bytes of episode i
#   SC_EP_FROM[i]     "sample" or "median" (median sampled bitrate)
#   SC_MEDIAN_RATE    median sampled bytes/s
#   SC_MEDIAN_BYTES   median of the episode estimates (the batch value
#                     crf_select compares with the per-episode ceiling)
series_crf_spread() {
    local rates=("$@") i sampled=()

    SC_EP_BYTES=()
    SC_EP_FROM=()

    for i in "${!rates[@]}"; do
        [[ "${rates[$i]}" =~ ^[0-9.]+$ ]] && sampled+=("${rates[$i]}")
    done
    (( ${#sampled[@]} )) || return 1

    SC_MEDIAN_RATE=$(printf '%s\n' "${sampled[@]}" | sort -g | awk '{ v[NR] = $1 } END {
        if (NR % 2) printf "%.3f", v[(NR + 1) / 2]
        else printf "%.3f", (v[NR / 2] + v[NR / 2 + 1]) / 2 }')

    for i in "${!EP_DUR[@]}"; do
        if [[ "${rates[$i]:-}" =~ ^[0-9.]+$ ]]; then
            SC_EP_BYTES[$i]=$(awk -v r="${rates[$i]}" -v d="${EP_DUR[$i]}" 'BEGIN { printf "%.0f", r * d }')
            SC_EP_FROM[$i]="sample"
        else
            SC_EP_BYTES[$i]=$(awk -v r="$SC_MEDIAN_RATE" -v d="${EP_DUR[$i]}" 'BEGIN { printf "%.0f", r * d }')
            SC_EP_FROM[$i]="median"
        fi
    done

    SC_MEDIAN_BYTES=$(_median "${SC_EP_BYTES[@]}")
}

# series_batch_stats CEILING_BYTES VIDEO_BYTES...
#
# Season figures for one CRF. VIDEO_BYTES: estimated video bytes per
# episode (EP_DUR order). CEILING_BYTES 0 = no ceiling (Custom).
#
# Sets:
#   SB_MEDIAN    median episode video bytes (what the ceiling is checked on)
#   SB_LARGEST   largest episode video bytes
#   SB_TOTAL     sum of the episode video bytes
#   SB_ABOVE     indexes of the episodes above the nominal ceiling
#   SB_FITS      1 when the median episode fits the ceiling (always 1
#                without a ceiling)
series_batch_stats() {
    local ceil="$1" i
    shift
    local vb=("$@")

    SB_ABOVE=()
    SB_MEDIAN=$(_median "${vb[@]}") || return 1
    read -r SB_LARGEST SB_TOTAL < <(printf '%s\n' "${vb[@]}" |
        awk '{ t += $1; if (NR == 1 || $1 > m) m = $1 } END { printf "%.0f %.0f\n", m, t }')

    if (( ceil > 0 )); then
        for i in "${!vb[@]}"; do
            (( vb[i] > ceil )) && SB_ABOVE+=("$i")
        done
    fi

    SB_FITS=0
    (( ceil <= 0 || SB_MEDIAN <= ceil )) && SB_FITS=1
    return 0
}

# series_crf_analysis_lines  ->  per tried CRF: median / largest episode,
# episodes above the nominal ceiling, fits or not. Reads CRF_TRIED,
# CRF_SERIES_EP_BYTES, CRF_CEILING_BYTES, CRF_CEILING_GIB.
series_crf_analysis_lines() {
    local c eb

    for c in "${CRF_TRIED[@]}"; do
        read -ra eb <<< "${CRF_SERIES_EP_BYTES[$c]}"
        series_batch_stats "${CRF_CEILING_BYTES:-0}" "${eb[@]}" || continue
        echo "  CRF $c:"
        echo "    median episode:  $(size_text "$SB_MEDIAN") video"
        echo "    largest episode: $(size_text "$SB_LARGEST") video"
        if (( ${CRF_CEILING_BYTES:-0} > 0 )); then
            echo "    ceiling:         ${CRF_CEILING_GIB} GiB/episode (nominal)"
            printf '    -> %s; %d of %d episode(s) above the ceiling\n' \
                "$( (( SB_FITS == 1 )) && echo "median fits" || echo "median above the ceiling")" \
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
