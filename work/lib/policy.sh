#!/usr/bin/env bash
# Compression policy: loads and validates compress.conf and holds the
# policy math that uses it (movie video targets, AAC rate tables, series
# / audio-menu rates). Sourced, not executed. Needs bitrate.sh.
#
# The config is ~/compress/work/lib/compress.conf; COMPRESS_CONF
# overrides the path (tests). There are no built-in fallback values:
# a missing file or setting stops the menu with a clear message, so
# compress.conf is the only place the numbers live.

POLICY_KEYS_POSITIVE=(
    MOVIE_QUALITY_VIDEO_GIB_PER_HOUR MOVIE_QUALITY_VIDEO_MIN_GIB
    MOVIE_HIGH_VIDEO_GIB_PER_HOUR
    MOVIE_BASE_VIDEO_GIB_PER_HOUR
    MOVIE_HIGH_AAC_KBPS_7PLUS MOVIE_HIGH_AAC_KBPS_6 MOVIE_HIGH_AAC_KBPS_3TO5
    MOVIE_HIGH_AAC_KBPS_2 MOVIE_HIGH_AAC_KBPS_1
    MOVIE_BASE_AAC_KBPS_7PLUS MOVIE_BASE_AAC_KBPS_6 MOVIE_BASE_AAC_KBPS_3TO5
    MOVIE_BASE_AAC_KBPS_2 MOVIE_BASE_AAC_KBPS_1
    MOVIE_AAC_MIN_KBPS
    SERIES_HIGH_VIDEO_GIB_PER_HOUR SERIES_BASE_VIDEO_GIB_PER_HOUR
    SERIES_HIGH_AAC_KBPS_7PLUS SERIES_HIGH_AAC_KBPS_6 SERIES_HIGH_AAC_KBPS_3TO5
    SERIES_HIGH_AAC_KBPS_2 SERIES_HIGH_AAC_KBPS_1
    SERIES_BASE_AAC_KBPS_7PLUS SERIES_BASE_AAC_KBPS_6 SERIES_BASE_AAC_KBPS_3TO5
    SERIES_BASE_AAC_KBPS_2 SERIES_BASE_AAC_KBPS_1
    AUDIO_HIGH_TRIGGER_KBPS AUDIO_COMPACT_TRIGGER_GIB AUDIO_COMPACT_LIMIT_GIB
    AUDIO_HIGH_KBPS_1 AUDIO_HIGH_KBPS_2 AUDIO_HIGH_KBPS_3TO4
    AUDIO_HIGH_KBPS_5TO6 AUDIO_HIGH_KBPS_7PLUS
    AUDIO_COMPACT_KBPS_1 AUDIO_COMPACT_KBPS_2 AUDIO_COMPACT_KBPS_3TO4
    AUDIO_COMPACT_KBPS_5TO6 AUDIO_COMPACT_KBPS_7PLUS
)

# 0 allowed (0 = "no ceiling" / "no limit")
POLICY_KEYS_NONNEG=(
    MOVIE_QUALITY_VIDEO_FLOOR_MBPS MOVIE_QUALITY_VIDEO_MAX_MBPS
    MOVIE_QUALITY_AUDIO_MAX_GIB
    MOVIE_HIGH_VIDEO_FLOOR_MBPS MOVIE_HIGH_VIDEO_MAX_MBPS MOVIE_HIGH_AUDIO_MAX_GIB
    MOVIE_BASE_VIDEO_FLOOR_MBPS MOVIE_BASE_VIDEO_MAX_MBPS
    SERIES_HIGH_VIDEO_FLOOR_MBPS SERIES_HIGH_VIDEO_MAX_MBPS
    SERIES_BASE_VIDEO_FLOOR_MBPS SERIES_BASE_VIDEO_MAX_MBPS
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

    # floor <= max (when a max is set)
    for f in MOVIE_QUALITY MOVIE_HIGH MOVIE_BASE SERIES_HIGH SERIES_BASE; do
        local fl="${f}_VIDEO_FLOOR_MBPS" mx="${f}_VIDEO_MAX_MBPS"
        if _policy_is_num "${!fl:-}" && _policy_is_num "${!mx:-}" &&
           awk -v a="${!fl}" -v b="${!mx}" 'BEGIN { exit !(b > 0 && a > b) }'; then
            errs+=("$fl (${!fl}) is greater than $mx (${!mx})")
        fi
    done

    m="${MOVIE_QUALITY_AUDIO_MODE-}"
    case "$m" in
        copy) ;;
        cap)
            if _policy_is_num "${MOVIE_QUALITY_AUDIO_MAX_GIB:-}" &&
               awk -v x="$MOVIE_QUALITY_AUDIO_MAX_GIB" 'BEGIN { exit !(x <= 0) }'; then
                errs+=("MOVIE_QUALITY_AUDIO_MODE=\"cap\" needs MOVIE_QUALITY_AUDIO_MAX_GIB greater than 0")
            fi
            ;;
        *)  errs+=("MOVIE_QUALITY_AUDIO_MODE=\"$m\": must be \"copy\" or \"cap\"") ;;
    esac

    if [[ -z "${MOVIE_BASE_AUDIO_MAX_GIB_CHOICES-}" ]]; then
        errs+=("MOVIE_BASE_AUDIO_MAX_GIB_CHOICES is not set")
    else
        for v in $MOVIE_BASE_AUDIO_MAX_GIB_CHOICES; do
            if ! _policy_is_num "$v" || awk -v x="$v" 'BEGIN { exit !(x <= 0) }'; then
                errs+=("MOVIE_BASE_AUDIO_MAX_GIB_CHOICES: \"$v\" is not a size greater than 0")
            fi
        done
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
        MOVIE_QUALITY_AUDIO_MODE MOVIE_BASE_AUDIO_MAX_GIB_CHOICES \
        SERIES_CONTAINER_RESERVE_PCT

    # shellcheck source=/dev/null
    if ! source "$conf"; then
        echo "Could not read $conf (bash syntax error?)." >&2
        return 1
    fi

    validate_policy
}

# ------------------------------------------------------------
# Movie
# ------------------------------------------------------------

# movie_video_plan TIER DURATION_SECONDS [SOURCE_VIDEO_BYTES]
#
# Every tier sizes the video from the runtime:
#   rate   = hours * MOVIE_<TIER>_VIDEO_GIB_PER_HOUR
#   target = rate                                  (High, Base)
#   target = max(rate, MOVIE_QUALITY_VIDEO_MIN_GIB) (Quality)
#   target = min(target, source video size)
#   bitrate from target and duration, capped at MOVIE_<TIER>_VIDEO_MAX_MBPS
#   (0 = no cap). Below the floor -> the menu asks floor vs target.
#
# The floor conflict is skipped when the source limits the target
# (encoding above the source is never done, so the floor could not be
# used).
#
# High / Base: when the source video bitrate itself is below the floor,
# the source bitrate is the target (no reduction, no floor conflict,
# PLAN_SOURCE_BELOW_FLOOR=1). Quality keeps the rules above.
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
#   PLAN_MIN_GIB          configured minimum size (Quality only, else "")
#   PLAN_TARGET_GIB       selected video size (after the source limit)
#   PLAN_SOURCE_GIB       source video size ("" when not known)
#   PLAN_SOURCE_MBPS      source video bitrate ("" when not known)
#   PLAN_SOURCE_LIMITED   1 when the source size lowered the target
#   PLAN_SOURCE_BELOW_FLOOR 1 when the source bitrate is below the floor
#                         (High / Base: target = source bitrate)
#   PLAN_MAX_LIMITED      1 when the bitrate max lowered the target
movie_video_plan() {
    local tier="$1" dur="$2" src_bytes="${3:-}"
    local gib floor max t u

    PLAN_BELOW_FLOOR=0
    PLAN_SIZE_MBPS=""
    PLAN_MIN_GIB=""
    PLAN_SOURCE_GIB=""
    PLAN_SOURCE_MBPS=""
    PLAN_SOURCE_LIMITED=0
    PLAN_SOURCE_BELOW_FLOOR=0
    PLAN_MAX_LIMITED=0

    case "$tier" in
        Quality|High|Base) u="${tier^^}" ;;
        *)
            echo "movie_video_plan: unknown tier $tier" >&2
            return 1
            ;;
    esac

    local rk="MOVIE_${u}_VIDEO_GIB_PER_HOUR" fk="MOVIE_${u}_VIDEO_FLOOR_MBPS" mk="MOVIE_${u}_VIDEO_MAX_MBPS"
    floor="${!fk}"
    max="${!mk}"
    PLAN_GIB_PER_HOUR="${!rk}"

    PLAN_RATE_GIB=$(awk -v r="$PLAN_GIB_PER_HOUR" -v d="$dur" \
        'BEGIN { printf "%.3f", r * d / 3600 }')
    gib="$PLAN_RATE_GIB"

    if [[ "$tier" == "Quality" ]]; then
        PLAN_MIN_GIB=$(awk -v m="$MOVIE_QUALITY_VIDEO_MIN_GIB" 'BEGIN { printf "%.3f", m }')
        gib=$(max_value "$PLAN_RATE_GIB" "$PLAN_MIN_GIB")
    fi

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
    PLAN_SIZE_MBPS=$(bitrate_for_gib "$gib" "$dur")
    t="$PLAN_SIZE_MBPS"

    if awk -v m="$max" -v x="$t" 'BEGIN { exit !(m > 0 && x > m) }'; then
        t=$(min_value "$max" "$t")
        PLAN_MAX_LIMITED=1
    fi

    if (( PLAN_SOURCE_LIMITED == 0 )) &&
       awk -v x="$t" -v f="$floor" 'BEGIN { exit !(x < f) }'; then
        PLAN_BELOW_FLOOR=1
    fi

    # High / Base: a source already below the floor is not reduced
    # further; its own bitrate is the target (and the lower bound).
    if [[ "$tier" != "Quality" ]] && (( PLAN_SOURCE_BELOW_FLOOR == 1 )); then
        t="$PLAN_SOURCE_MBPS"
        PLAN_TARGET_GIB="$PLAN_SOURCE_GIB"
        PLAN_SIZE_MBPS="$PLAN_SOURCE_MBPS"
        PLAN_SOURCE_LIMITED=0
        PLAN_MAX_LIMITED=0
        PLAN_BELOW_FLOOR=0
    fi

    PLAN_TARGET_MBPS="$t"
    PLAN_FLOOR_MBPS="$floor"
    PLAN_MAX_MBPS="$max"
}

# movie_audio_cap_gib TIER  ->  audio limit of the tier (0 = copy).
# Base has a menu choice instead (MOVIE_BASE_AUDIO_MAX_GIB_CHOICES).
movie_audio_cap_gib() {
    case "$1" in
        Quality) [[ "$MOVIE_QUALITY_AUDIO_MODE" == "cap" ]] && echo "$MOVIE_QUALITY_AUDIO_MAX_GIB" || echo 0 ;;
        High)    echo "$MOVIE_HIGH_AUDIO_MAX_GIB" ;;
        *)       echo 0 ;;
    esac
}

# _aac_by_channels PREFIX CHANNELS  ->  PREFIX_{7PLUS,6,3TO5,2,1}
_aac_by_channels() {
    local ch="$2" k

    [[ "$ch" =~ ^[0-9]+$ ]] || ch=2

    if (( ch >= 7 )); then k="${1}_7PLUS"
    elif (( ch == 6 )); then k="${1}_6"
    elif (( ch >= 3 )); then k="${1}_3TO5"
    elif (( ch == 2 )); then k="${1}_2"
    else k="${1}_1"; fi

    echo "${!k}"
}

# movie_aac_kbps TIER CHANNELS  (High rates for High and Quality)
movie_aac_kbps() {
    case "$1" in
        Base) _aac_by_channels MOVIE_BASE_AAC_KBPS "$2" ;;
        *)    _aac_by_channels MOVIE_HIGH_AAC_KBPS "$2" ;;
    esac
}

# build_audio_args BUDGET_KBPS "CH CH ..." TIER  ->  ffmpeg audio args
# (all tracks AAC; scaled down proportionally when over the budget)
build_audio_args() {
    local budget="$1"
    local channels_string="$2"
    local tier="$3"
    local -a channels recommendations=()
    local ch kbps total=0 i

    read -ra channels <<< "$channels_string"

    if (( ${#channels[@]} == 0 )); then
        echo "-c:a copy"
        return
    fi

    for ch in "${channels[@]}"; do
        kbps=$(movie_aac_kbps "$tier" "$ch")
        recommendations+=("$kbps")
        total=$((total + kbps))
    done

    local args="-c:a aac"

    if (( total <= budget )); then
        for i in "${!recommendations[@]}"; do
            args+=" -b:a:${i} ${recommendations[$i]}k"
        done
    else
        for i in "${!recommendations[@]}"; do
            kbps=$(awk -v r="${recommendations[$i]}" -v t="$total" -v b="$budget" \
                -v m="$MOVIE_AAC_MIN_KBPS" 'BEGIN {
                    x = int(r / t * b)
                    if (x < m) x = m
                    printf "%d", x
                }')
            args+=" -b:a:${i} ${kbps}k"
        done
    fi

    echo "$args"
}

# movie_policy_line TIER  ->  one-line description of the effective values
movie_policy_line() {
    local cap

    case "$1" in
        Quality)
            printf 'quality-first [%s GiB/hour video, at least %s GiB / %s Mb/s floor / %s]' \
                "$MOVIE_QUALITY_VIDEO_GIB_PER_HOUR" "$MOVIE_QUALITY_VIDEO_MIN_GIB" \
                "$MOVIE_QUALITY_VIDEO_FLOOR_MBPS" \
                "$(awk -v m="$MOVIE_QUALITY_VIDEO_MAX_MBPS" 'BEGIN { print (m > 0) ? m " Mb/s max" : "no bitrate max" }')"
            cap=$(movie_audio_cap_gib Quality)
            ;;
        High|Base)
            local u="${1^^}"
            local gk="MOVIE_${u}_VIDEO_GIB_PER_HOUR" fk="MOVIE_${u}_VIDEO_FLOOR_MBPS" mk="MOVIE_${u}_VIDEO_MAX_MBPS"
            printf '%s [%s GiB/hour video / %s Mb/s floor / %s]' \
                "$( [[ "$1" == High ]] && echo efficiency-first || echo size-first)" \
                "${!gk}" "${!fk}" \
                "$(awk -v m="${!mk}" 'BEGIN { print (m > 0) ? m " Mb/s max" : "no bitrate max" }')"
            cap=$(movie_audio_cap_gib "$1")
            ;;
    esac

    if [[ "$1" == "Base" ]]; then
        printf '; audio <= one of: %s GiB' "${MOVIE_BASE_AUDIO_MAX_GIB_CHOICES// / \/ }"
    elif awk -v c="$cap" 'BEGIN { exit !(c > 0) }'; then
        printf '; audio <= %s GiB' "$cap"
    else
        printf '; audio copied'
    fi
}

# movie_video_policy_lines TIER  ->  the tier's video settings, one per line
movie_video_policy_lines() {
    local u="${1^^}"
    local rk="MOVIE_${u}_VIDEO_GIB_PER_HOUR" fk="MOVIE_${u}_VIDEO_FLOOR_MBPS" mk="MOVIE_${u}_VIDEO_MAX_MBPS"

    echo "$1 video policy:"
    echo "  ${!rk} GiB/hour"
    [[ "$1" == "Quality" ]] &&
        echo "  minimum preferred video size: ${MOVIE_QUALITY_VIDEO_MIN_GIB} GiB"
    echo "  bitrate floor: ${!fk} Mb/s"
    awk -v m="${!mk}" 'BEGIN { print "  bitrate max: " ((m > 0) ? m " Mb/s" : "none") }'
}

# ------------------------------------------------------------
# Series
#
# One fixed video bitrate for every episode, from a video-only size per
# hour of runtime (audio is added on top, never taken from it):
#   fixed = kb/s of SERIES_<TIER>_VIDEO_GIB_PER_HOUR
#   fixed = min(fixed, SERIES_<TIER>_VIDEO_MAX_MBPS)   (0 = no max)
# Per episode (never above the source):
#   source below the floor   -> source bitrate (not reduced further)
#   source below fixed       -> source bitrate
#   otherwise                -> fixed
# Episode runtime changes only the expected size, not the bitrate.
# ------------------------------------------------------------

# _mbps_to_kbps MBPS  ->  whole kb/s
_mbps_to_kbps() {
    awk -v x="$1" 'BEGIN { printf "%.0f", x * 1000 }'
}

# series_gib_per_hour TIER  ->  configured video GiB/hour (Base / High)
series_gib_per_hour() {
    case "$1" in
        Base) echo "$SERIES_BASE_VIDEO_GIB_PER_HOUR" ;;
        High) echo "$SERIES_HIGH_VIDEO_GIB_PER_HOUR" ;;
    esac
}

# series_video_policy_lines TIER  ->  the tier's video settings, one per line
series_video_policy_lines() {
    local u="${1^^}"
    local rk="SERIES_${u}_VIDEO_GIB_PER_HOUR" fk="SERIES_${u}_VIDEO_FLOOR_MBPS" mk="SERIES_${u}_VIDEO_MAX_MBPS"

    echo "$1 video policy:"
    echo "  ${!rk} GiB/hour"
    echo "  bitrate floor: ${!fk} Mb/s"
    awk -v m="${!mk}" 'BEGIN { print "  bitrate max: " ((m > 0) ? m " Mb/s" : "none") }'
}

# series_video_plan TIER [CUSTOM_GIB_PER_HOUR]
#
# Reads EP_VKBPS (source video kb/s per episode; "N/A" when unknown).
# Custom: the entered GiB/hour, no floor and no max.
#
# Sets:
#   SPLAN_GIB_PER_HOUR    video GiB/hour of the tier
#   SPLAN_RATE_KBPS       that GiB/hour as kb/s
#   SPLAN_TARGET_KBPS     fixed video bitrate after the max
#   SPLAN_FLOOR_KBPS      floor (0 = none)
#   SPLAN_MAX_KBPS        max (0 = none)
#   SPLAN_MAX_LIMITED     1 when the max lowered the fixed bitrate
#   SPLAN_BELOW_FLOOR     1 when the fixed bitrate is below the floor
#                         and an episode's source is at or above it
#                         (or unknown): the menu asks floor vs target.
#                         Episodes whose source is below the floor keep
#                         their source bitrate and cause no conflict.
series_video_plan() {
    local tier="$1" u s

    SPLAN_MAX_LIMITED=0
    SPLAN_BELOW_FLOOR=0

    case "$tier" in
        High|Base)
            u="${tier^^}"
            local rk="SERIES_${u}_VIDEO_GIB_PER_HOUR" fk="SERIES_${u}_VIDEO_FLOOR_MBPS" mk="SERIES_${u}_VIDEO_MAX_MBPS"
            SPLAN_GIB_PER_HOUR="${!rk}"
            SPLAN_FLOOR_KBPS=$(_mbps_to_kbps "${!fk}")
            SPLAN_MAX_KBPS=$(_mbps_to_kbps "${!mk}")
            ;;
        Custom)
            SPLAN_GIB_PER_HOUR="$2"
            SPLAN_FLOOR_KBPS=0
            SPLAN_MAX_KBPS=0
            ;;
        *)
            echo "series_video_plan: unknown tier $tier" >&2
            return 1
            ;;
    esac

    SPLAN_RATE_KBPS=$(gib_per_hour_to_kbps "$SPLAN_GIB_PER_HOUR")
    SPLAN_TARGET_KBPS="$SPLAN_RATE_KBPS"

    if (( SPLAN_MAX_KBPS > 0 && SPLAN_TARGET_KBPS > SPLAN_MAX_KBPS )); then
        SPLAN_TARGET_KBPS="$SPLAN_MAX_KBPS"
        SPLAN_MAX_LIMITED=1
    fi

    if (( SPLAN_TARGET_KBPS < SPLAN_FLOOR_KBPS )); then
        for s in "${EP_VKBPS[@]+"${EP_VKBPS[@]}"}"; do
            if [[ ! "$s" =~ ^[0-9]+$ ]] || (( s == 0 || s >= SPLAN_FLOOR_KBPS )); then
                SPLAN_BELOW_FLOOR=1
                break
            fi
        done
    fi
}

# series_episode_video_kbps FIXED_KBPS SOURCE_KBPS FLOOR_KBPS  ->  "KBPS NOTE"
# NOTE: "-" (fixed), "src" (source below fixed), "floor" (source below
# the floor: kept at the source bitrate)
series_episode_video_kbps() {
    local fixed="$1" src="$2" floor="$3"

    if [[ "$src" =~ ^[0-9]+$ ]] && (( src > 0 )); then
        if (( floor > 0 && src < floor )); then
            echo "$src floor"
            return
        elif (( src < fixed )); then
            echo "$src src"
            return
        fi
    fi

    echo "$fixed -"
}

# series_aac_kbps TIER CHANNELS  (High rates for High and Custom)
series_aac_kbps() {
    case "$1" in
        High|Custom) _aac_by_channels SERIES_HIGH_AAC_KBPS "$2" ;;
        *)           _aac_by_channels SERIES_BASE_AAC_KBPS "$2" ;;
    esac
}

# series_size_factor  ->  1 - reserve, for size estimates
series_size_factor() {
    awk -v r="$SERIES_CONTAINER_RESERVE_PCT" 'BEGIN { printf "%.6f", (100 - r) / 100 }'
}

# series_plan TIER FIXED_VIDEO_KBPS FLOOR_KBPS
#
# Reads EP_DUR, EP_VKBPS, EP_AKBPS (source audio kb/s per track,
# space separated) and AUDIO_CHANNELS.
#
# Sets:
#   P_VIDEO_KBPS        the fixed video bitrate
#   P_AUDIO_KBPS        fixed audio total (all tracks re-encoded)
#   P_EP_VKBPS[i]       video kb/s per episode
#   P_EP_VNOTE[i]       "-", "src" or "floor" (see series_episode_video_kbps)
#   P_EP_AARGS[i]       shell-quoted audio args per episode
#   P_EP_ADESC[i]       short audio description per episode
#   P_EP_VGIB[i] P_EP_AGIB[i] P_EP_GIB[i]   expected video / audio / total
#   P_CAPPED            episodes at their source bitrate (below fixed)
#   P_SRC_BELOW_FLOOR   episodes kept at a source bitrate below the floor
#   P_COPIED            audio tracks copied (all episodes)
#   P_TOTAL_SECONDS
#   P_VIDEO_GIB P_AUDIO_GIB P_TOTAL_GIB     totals
# Total sizes add SERIES_CONTAINER_RESERVE_PCT for container/subtitles.
series_plan() {
    local tier="$1" fixed="$2" floor="$3"
    local i t rate src v note a_kbps tokens desc f
    local -a src_rates

    f=$(series_size_factor)

    P_VIDEO_KBPS="$fixed"
    P_AUDIO_KBPS=0
    for t in "${!AUDIO_CHANNELS[@]}"; do
        rate=$(series_aac_kbps "$tier" "${AUDIO_CHANNELS[$t]}")
        P_AUDIO_KBPS=$((P_AUDIO_KBPS + rate))
    done

    P_CAPPED=0
    P_SRC_BELOW_FLOOR=0
    P_COPIED=0
    P_EP_VKBPS=()
    P_EP_VNOTE=()
    P_EP_AARGS=()
    P_EP_ADESC=()
    P_EP_VGIB=()
    P_EP_AGIB=()
    P_EP_GIB=()

    local video_kb_total=0 audio_kb_total=0 seconds=0

    for i in "${!EP_DUR[@]}"; do
        read -r v note <<< "$(series_episode_video_kbps "$fixed" "${EP_VKBPS[$i]:-N/A}" "$floor")"
        case "$note" in
            src)   ((P_CAPPED += 1)) ;;
            floor) ((P_SRC_BELOW_FLOOR += 1)) ;;
        esac

        P_EP_VKBPS[$i]="$v"
        P_EP_VNOTE[$i]="$note"

        read -ra src_rates <<< "${EP_AKBPS[$i]:-}"
        tokens=""
        desc=""
        a_kbps=0

        for t in "${!AUDIO_CHANNELS[@]}"; do
            rate=$(series_aac_kbps "$tier" "${AUDIO_CHANNELS[$t]}")
            src="${src_rates[$t]:-N/A}"

            if [[ "$src" =~ ^[0-9]+$ ]] && (( src > 0 && src <= rate )); then
                # Already at or below the target: no lossy re-encode.
                a_kbps=$((a_kbps + src))
                desc+="copy "
                ((P_COPIED += 1))
            else
                tokens+=$(printf '%q ' "-c:a:$t" aac "-b:a:$t" "${rate}k")
                a_kbps=$((a_kbps + rate))
                desc+="${rate}k "
            fi
        done

        P_EP_AARGS[$i]="${tokens% }"
        P_EP_ADESC[$i]="${desc% }"

        read -r P_EP_VGIB[$i] P_EP_AGIB[$i] P_EP_GIB[$i] < <(
            awk -v v="$v" -v a="$a_kbps" -v s="${EP_DUR[$i]}" -v f="$f" 'BEGIN {
                g = 1000 * s / 8 / 1073741824
                printf "%.2f %.2f %.2f\n", v * g, a * g, (v + a) * g / f }')

        read -r video_kb_total audio_kb_total seconds < <(
            awk -v vt="$video_kb_total" -v at="$audio_kb_total" -v st="$seconds" \
                -v v="$v" -v a="$a_kbps" -v s="${EP_DUR[$i]}" \
                'BEGIN { printf "%.0f %.0f %.3f\n", vt + v * s, at + a * s, st + s }')
    done

    P_TOTAL_SECONDS="$seconds"
    read -r P_VIDEO_GIB P_AUDIO_GIB P_TOTAL_GIB < <(
        awk -v v="$video_kb_total" -v a="$audio_kb_total" -v f="$f" 'BEGIN {
            g = 1000 / 8 / 1073741824
            printf "%.2f %.2f %.2f\n", v * g, a * g, (v + a) * g / f }')
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
