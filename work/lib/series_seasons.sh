#!/usr/bin/env bash
# Multi-season series support for series_compress.sh. Sourced, not
# executed.
#
# A show folder holds one or more season groups (media_probe.sh
# series_season_groups: every folder that directly contains episodes).
# Each selected group is compressed as an independent season: its own
# analysis, compatibility check, shared season CRF, ceiling checks,
# source-quality guard and season retry batch. series_compress.sh keeps
# the state of the season being worked on in plain globals (FILES, EP_*,
# CRF, GUARD, ...); season_state_save / season_state_load move that state
# in and out of per-season storage so nothing leaks from one season into
# the next.

# ------------------------------------------------------------
# Season selection
# ------------------------------------------------------------

# season_parse_selection SPEC COUNT  ->  the selected numbers (1..COUNT),
# ascending, unique, one per line, from "1,3,5-7" (spaces allowed).
# Returns 1 (nothing printed) for an empty or invalid SPEC: anything but
# numbers / ranges, 0, a number above COUNT, a reversed range.
season_parse_selection() {
    local spec="${1//[[:space:]]/}" count="$2" part a b i
    local -A seen=()

    [[ -n "$spec" && "$count" =~ ^[0-9]+$ ]] || return 1
    [[ "$spec" =~ ^[0-9,-]+$ ]] || return 1

    IFS=, read -ra parts <<< "$spec"
    [[ "$spec" == *, || "$spec" == ,* || "$spec" == *,,* ]] && return 1
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$a
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        else
            return 1
        fi
        (( a >= 1 && b <= count && a <= b )) || return 1
        for ((i = a; i <= b; i++)); do
            seen[$i]=1
        done
    done

    printf '%s\n' "${!seen[@]}" | sort -n
}

# ------------------------------------------------------------
# Per-season state
#
# SEASON_VARS: every global the per-season steps of series_compress.sh
# (and the policy.sh / encode_common.sh functions they call) read or
# write for ONE season. season_state_reset gives each its empty start
# value, season_state_save stores the current values for a season,
# season_state_load restores them (after unsetting everything, so a
# value of the previous season can never be read).
# ------------------------------------------------------------

SEASON_VARS=(
    # episodes and source analysis
    FILES FILE_COUNT EP_LABEL LABEL_W
    EP_DUR EP_VIDX EP_VKBPS EP_VBYTES EP_AKBPS EP_ABYTES EP_ACH EP_ACODEC EP_ASR
    EP_RES EP_VCODEC EP_PIX EP_FPS EP_RANGE EP_SUBS EP_OTHER EP_HOW EP_H10P EP_REFRESH EP_KIND
    ANALYZE_FAIL INCOMPATIBLE DIFFERENT VERIFY_DETAILS VERIFY_ALL
    REFERENCE WIDTH HEIGHT AUDIO_TRACKS_TEXT
    # dynamic range of the reference episode and its policy
    HDR_CODEC HDR_PRIMARIES HDR_TRANSFER HDR_MATRIX HDR_RANGE HDR_CHROMALOC HDR_KIND HDR_MASTER
    HDR_CLL HDR_HDR10PLUS HDR_DV HDR_DV_PROFILE HDR_DV_COMPAT HDR_DV_LEVEL HDR_DV_RPU HDR_DV_EL HDR_DV_BL
    DV_POLICY DV_MODE DV_EL_TYPE DV_EL_DISCARD HDR10P_POLICY DV_SUPPORTED DV_OUT DV_BASE_OK DV_WHY
    # output resolution
    VIDEO_FILTER OUT_WIDTH OUT_HEIGHT DOWNSCALED
    # CRF analysis
    SERIES_EP_CEIL CRF_SERIES_SAMPLED CRF_SERIES_FILTER CRF_SERIES_EP_BYTES CRF_SERIES_EP_FROM
    CRF_SERIES_RATES CRF_EP_EST CRF_SERIES_LABELS CRF_EST CRF_TRIED CRF_SELECTED CRF_OVER_CEILING
    CRF_BOUNDARY_LOW CRF_AT_FLOOR CRF_SEARCH_DIR CRF_EST_RESULT
    CRF EP_EST EP_FROM EP_CRF EP_OVER EP_CEIL_SKIP EST_MEDIAN ABOVE EST_LARGEST
    GUARD GUARD_SAMPLED LATE EP_VIDEO EP_GUARD_SKIP SEASON_RAISED SEASON_OVER_TARGET
    PLAN_VIDEO P_EP_AKBPS P_EP_VGIB P_EP_AGIB P_EP_GIB P_TOTAL_SECONDS P_VIDEO_GIB P_AUDIO_GIB P_TOTAL_GIB
    # outputs
    OUT_SEASON EP_OUT EP_OVERWRITE EP_SKIP EP_MATCH QUEUED
    # season bookkeeping
    SEASON_LOG SEASON_FAILED
)

# season_state_reset  ->  every SEASON_VARS global set to its empty start
# value (arrays empty, CRF_* maps empty, scalars "", flags 0)
season_state_reset() {
    local v
    unset "${SEASON_VARS[@]}"
    for v in "${SEASON_VARS[@]}"; do
        case "$v" in
            CRF_SERIES_EP_BYTES|CRF_SERIES_EP_FROM|CRF_SERIES_RATES|CRF_EP_EST|CRF_EST)
                declare -gA "$v=()" ;;
            FILES|EP_*|VERIFY_DETAILS|VERIFY_ALL|SERIES_EP_CEIL|CRF_SERIES_SAMPLED|\
            CRF_SERIES_LABELS|CRF_TRIED|ABOVE|GUARD|GUARD_SAMPLED|LATE|PLAN_VIDEO|P_EP_*)
                declare -ga "$v=()" ;;
            FILE_COUNT|LABEL_W|INCOMPATIBLE|DIFFERENT|HDR_HDR10PLUS|HDR_DV|DV_SUPPORTED|\
            DV_BASE_OK|DOWNSCALED|CRF_OVER_CEILING|CRF_AT_FLOOR|QUEUED|SEASON_FAILED|SEASON_OVER_TARGET)
                declare -g "$v=0" ;;
            *)
                declare -g "$v=" ;;
        esac
    done
    HDR_KIND="SDR"
    DV_POLICY="none"
    HDR10P_POLICY="none"
}

# season_state_save KEY  ->  SEASON_STATE[KEY] = the current values
season_state_save() {
    declare -gA SEASON_STATE
    SEASON_STATE[$1]=$(declare -p "${SEASON_VARS[@]}" 2>/dev/null |
        sed -E 's/^declare -- /declare -g /; s/^declare -([A-Za-z]+) /declare -g\1 /')
}

# season_state_load KEY  ->  the values stored by season_state_save KEY
# (every SEASON_VARS global is unset first: nothing of the season loaded
# before survives). Returns 1 when nothing is stored for KEY.
season_state_load() {
    [[ -n "${SEASON_STATE[$1]+x}" ]] || return 1
    season_state_reset
    eval "${SEASON_STATE[$1]}"
}

# ------------------------------------------------------------
# Compatibility (one season)
# ------------------------------------------------------------

# describe_list "a a b "  ->  "a x2, b" (repeats folded; "none" when empty)
describe_list() {
    local s="${1% }"
    [[ -n "$s" ]] || { printf 'none'; return 0; }
    awk '{ for (i = 1; i <= NF; i++) {
               if (i > 1 && $i == p) { n++; continue }
               if (i > 1) out = out (out == "" ? "" : ", ") p (n > 1 ? " x" n : "")
               p = $i; n = 1 }
           printf "%s%s%s%s", out, (out == "" ? "" : ", "), p, (n > 1 ? " x" n : "") }' <<< "$s"
}

# word_count "a b c "  ->  3
word_count() {
    local -a w
    read -ra w <<< "$1"
    printf '%s' "${#w[@]}"
}

# fit_line TEXT  ->  TEXT cut to 120 columns (compact output rule;
# COMPRESS_VERBOSE=1 keeps it whole)
fit_line() {
    local t="$1"
    if ! ui_verbose && (( ${#t} > 120 )); then
        t="${t:0:117}..."
    fi
    printf '%s' "$t"
}

# season_audio_tracks  ->  AUDIO_TRACKS_TEXT of the loaded season: the
# audio track count per episode, "7" when every episode has the same,
# otherwise "1-9" (each episode's own tracks are copied as they are)
season_audio_tracks() {
    local i
    AUDIO_TRACKS_TEXT=$(
        for i in "${!FILES[@]}"; do
            word_count "${EP_ACH[$i]:-}"
            echo
        done | sort -n | awk 'NR == 1 { lo = $1 } { hi = $1 } END { print (lo == hi ? lo : lo "-" hi) }'
    )
}

# season_audio_text  ->  "2 tracks, copied unchanged" / "1-2 tracks per
# episode, copied unchanged" (compact header)
season_audio_text() {
    if [[ "$AUDIO_TRACKS_TEXT" == *-* ]]; then
        printf '%s tracks per episode, copied unchanged' "$AUDIO_TRACKS_TEXT"
    else
        printf '%s, copied unchanged' "$(ui_plural "$AUDIO_TRACKS_TEXT" track)"
    fi
}

# season_compat_check  ->  compares every episode of the loaded season
# (EP_* arrays, FILES) with its first episode.
#
# Must match (they set the shared encode parameters):
#   resolution, dynamic range (SDR/HDR10/HLG/Dolby Vision)
# Reported only (handled per episode: every episode gets its own stream
# map and all its audio is copied unchanged, see emit_encode_item):
#   video codec, pixel format, frame rate, audio track count, channels,
#   codecs and sample rates, subtitle tracks, attachments, HDR10+
#
# Sets INCOMPATIBLE / DIFFERENT (0|1), VERIFY_DETAILS (the lines of
# episodes that differ: MISMATCH / OK*) and VERIFY_ALL (every episode,
# "OK" lines included; verbose output).
season_compat_check() {
    local i d na na0
    local -a hard soft lines

    INCOMPATIBLE=0
    DIFFERENT=0
    VERIFY_DETAILS=()
    VERIFY_ALL=()

    for i in "${!FILES[@]}"; do
        hard=()
        soft=()

        [[ "${EP_RES[$i]}" == "${EP_RES[0]}" ]] ||
            hard+=("resolution ${EP_RES[$i]} vs ${EP_RES[0]}")
        [[ "${EP_RANGE[$i]}" == "${EP_RANGE[0]}" ]] ||
            hard+=("dynamic range ${EP_RANGE[$i]} vs ${EP_RANGE[0]}")

        [[ "${EP_VCODEC[$i]}" == "${EP_VCODEC[0]}" ]] ||
            soft+=("video codec ${EP_VCODEC[$i]}")
        [[ "${EP_PIX[$i]}" == "${EP_PIX[0]}" ]] ||
            soft+=("pixel format ${EP_PIX[$i]}")
        [[ "${EP_FPS[$i]}" == "${EP_FPS[0]}" ]] ||
            soft+=("frame rate ${EP_FPS[$i]}")
        # audio: a different track count makes every per-track list differ;
        # compact shows one line for it, verbose keeps the lists
        na=$(word_count "${EP_ACH[$i]}")
        na0=$(word_count "${EP_ACH[0]}")
        if (( na != na0 )); then
            soft+=("audio tracks $na vs $na0 (each episode's tracks copied as they are)")
        fi
        if (( na == na0 )) || ui_verbose; then
            [[ "${EP_ACH[$i]}" == "${EP_ACH[0]}" ]] ||
                soft+=("audio channels [$(describe_list "${EP_ACH[$i]}")] vs [$(describe_list "${EP_ACH[0]}")]")
            [[ "${EP_ACODEC[$i]}" == "${EP_ACODEC[0]}" ]] ||
                soft+=("audio codecs [$(describe_list "${EP_ACODEC[$i]}")] vs [$(describe_list "${EP_ACODEC[0]}")]")
            [[ "${EP_ASR[$i]}" == "${EP_ASR[0]}" ]] ||
                soft+=("sample rates [$(describe_list "${EP_ASR[$i]}")] vs [$(describe_list "${EP_ASR[0]}")]")
        fi
        [[ "${EP_SUBS[$i]}" == "${EP_SUBS[0]}" ]] ||
            soft+=("subtitles [$(describe_list "${EP_SUBS[$i]}")] vs [$(describe_list "${EP_SUBS[0]}")]")
        [[ "${EP_OTHER[$i]}" == "${EP_OTHER[0]}" ]] ||
            soft+=("${EP_OTHER[$i]} attachment/cover/data stream(s) vs ${EP_OTHER[0]}")
        [[ "${EP_H10P[$i]}" == "${EP_H10P[0]}" ]] ||
            soft+=("HDR10+ $( (( EP_H10P[$i] == 1 )) && echo present || echo absent)")

        lines=()
        if (( ${#hard[@]} )); then
            lines+=("$(ui_err MISMATCH)  $(basename "${FILES[$i]}")")
            for d in "${hard[@]}"; do lines+=("$(fit_line "            - $d")"); done
            for d in "${soft[@]+"${soft[@]}"}"; do lines+=("$(fit_line "            (also: $d)")"); done
            INCOMPATIBLE=1
        elif (( ${#soft[@]} )); then
            lines+=("$(ui_warn "OK*")       $(basename "${FILES[$i]}")")
            for d in "${soft[@]}"; do lines+=("$(fit_line "            differs: $d")"); done
            DIFFERENT=1
        fi

        VERIFY_DETAILS+=("${lines[@]+"${lines[@]}"}")
        if (( ${#lines[@]} )); then
            VERIFY_ALL+=("${lines[@]}")
        else
            VERIFY_ALL+=("OK        $(basename "${FILES[$i]}")")
        fi
    done
}

# ------------------------------------------------------------
# Summary helpers
# ------------------------------------------------------------

# season_crf_range CRF...  ->  "CRF range: 19-22 across 11 seasons
# (per-season shared CRF)" when the season CRFs differ, nothing otherwise
season_crf_range() {
    local lo hi
    (( $# > 1 )) || return 0
    read -r lo hi < <(printf '%s\n' "$@" | sort -n | awk 'NR == 1 { l = $1 } { h = $1 } END { print l, h }')
    [[ "$lo" != "$hi" ]] || return 0
    printf 'CRF range: %s-%s across %s seasons (per-season shared CRF)\n' "$lo" "$hi" "$#"
}

# season_status_text ABOVE COPIED SKIPPED [OTHER...]  ->  "OK" or a short
# summary: "1 above ceiling", "2 source kept, 1 skipped"
season_status_text() {
    local parts=() x
    (( $1 > 0 )) && parts+=("$1 above ceiling")
    (( $2 > 0 )) && parts+=("$2 source kept")
    (( $3 > 0 )) && parts+=("$3 skipped")
    shift 3
    for x in "$@"; do
        [[ -n "$x" ]] && parts+=("$x")
    done
    if (( ${#parts[@]} == 0 )); then
        printf 'OK'
    else
        local IFS=,
        x="${parts[*]}"
        printf '%s' "${x//,/, }"
    fi
}
