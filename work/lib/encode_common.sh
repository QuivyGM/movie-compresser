#!/usr/bin/env bash
# Shared helpers for the encode menus (movie / series / audio) and the
# generated job scripts. Sourced, not executed. Needs media_probe.sh.

# shellcheck source=ui.sh
[[ -n "${UI_LOADED:-}" ]] || source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

# ------------------------------------------------------------
# tmux / files
# ------------------------------------------------------------

next_tmux_session() {
    local prefix="${1:-c}"
    local n=1

    while tmux has-session -t "=${prefix}${n}" 2>/dev/null; do
        ((n++))
    done

    echo "${prefix}${n}"
}

# cleanup_finished_jobs [WORK]  ->  menu start: remove the runtime files
# (<session>.sh / .state / .progress, empty <session>_passes) of jobs left
# by older versions or interrupted cleanups, but only when every check
# confirms the job is over and fully successful:
#   - the name is a job session (c<N>, series<N>, a<N>)
#   - its state says status=finished and session=<name>
#   - tmux works and has no session of that name
#   - the script is a regular file not newer than the state (a newer
#     script was written for a new job reusing the name)
# Failed, interrupted, running or unknown jobs, scripts without a state
# (old job format) and anything when tmux is missing are left alone.
cleanup_finished_jobs() {
    local work="${1:-$WORK_DIR}" st s script n=0

    command -v tmux >/dev/null 2>&1 || return 0

    for st in "$work"/*.state; do
        [[ -f "$st" && ! -L "$st" ]] || continue
        s=$(basename "$st" .state)
        [[ "$s" =~ ^(c|a|series)[0-9]+$ ]] || continue
        [[ "$(sed -n 's/^status=//p' "$st" 2>/dev/null)" == "finished" ]] || continue
        [[ "$(sed -n 's/^session=//p' "$st" 2>/dev/null)" == "$s" ]] || continue
        tmux has-session -t "=$s" 2>/dev/null && continue

        script="$work/$s.sh"
        if [[ -e "$script" || -L "$script" ]]; then
            [[ -f "$script" && ! -L "$script" && ! "$script" -nt "$st" ]] || continue
            rm -f -- "$script"
        fi
        rm -f -- "$st" "$work/$s.progress"
        rmdir -- "$work/${s}_passes" 2>/dev/null || true
        n=$((n + 1))
    done

    if (( n > 0 )); then
        echo "Removed the runtime files of $n finished job(s) from $work."
    fi
    return 0
}

# Refresh MKV track statistics tags (BPS, NUMBER_OF_BYTES, ...) from
# the actual file contents. Returns non-zero when not possible.
refresh_mkv_stats() {
    local file="$1"

    case "${file,,}" in
        *.mkv) ;;
        *) return 2 ;;
    esac

    command -v mkvpropedit >/dev/null 2>&1 || return 3

    mkvpropedit "$file" \
        --delete-track-statistics-tags \
        --add-track-statistics-tags
}

actual_file_gib() {
    stat -L -c %s -- "$1" |
        awk '{printf "%.2f",$1/1073741824}'
}

# path_taken PATH  ->  0 when anything exists at PATH, including a
# symlink (valid or broken). A broken symlink is never "free".
path_taken() {
    [[ -e "$1" || -L "$1" ]]
}

# output_symlink_notice PATH  ->  explanation when PATH is a symlink
# (prints nothing otherwise). Outputs are only ever renamed onto such a
# path, which replaces the link itself; nothing is written through it.
output_symlink_notice() {
    local path="$1"

    [[ -L "$path" ]] || return 0

    if [[ -e "$path" ]]; then
        echo "Existing output is a symlink:"
        echo "  $path -> $(readlink -f -- "$path")"
        echo
        echo "Overwrite will replace the symlink itself."
        echo "The target file will NOT be modified."
    else
        echo "Existing output is a broken symlink:"
        echo "  $path -> $(readlink -- "$path")"
        echo
        echo "Overwrite will remove/replace the broken symlink."
    fi
}

# unique_output_path PATH  ->  PATH, or "NAME (2).ext", "NAME (3).ext", ...
# Also avoids names that have an in-progress ".part" file, and names
# taken by a symlink (valid or broken).
unique_output_path() {
    local path="$1"
    local dir base ext cand
    local n=2

    dir=$(dirname "$path")
    base=$(basename "$path")
    ext="${base##*.}"
    base="${base%.*}"
    cand="$path"

    while path_taken "$cand" || path_taken "$cand.part" || output_is_planned "$cand"; do
        cand="$dir/$base ($n).$ext"
        ((n++))
    done

    printf '%s\n' "$cand"
}

# Outputs already claimed by the queue being built (movie menu queues
# several files; two entries must never write the same output).
PLANNED_OUTPUTS=()

output_is_planned() {
    local p

    for p in "${PLANNED_OUTPUTS[@]+"${PLANNED_OUTPUTS[@]}"}"; do
        [[ "$p" == "$1" ]] && return 0
    done

    return 1
}

# resolve_output_conflict PATH
#
# Interactive. Sets RESOLVED_OUT and RESOLVED_OVERWRITE (0/1).
# Returns 1 when the user chooses to skip the file.
resolve_output_conflict() {
    local path="$1"
    local alt c

    RESOLVED_OUT="$path"
    RESOLVED_OVERWRITE=0

    if ! path_taken "$path" && ! path_taken "$path.part" && ! output_is_planned "$path"; then
        return 0
    fi

    alt=$(unique_output_path "$path")

    echo
    echo "Output already exists:"
    echo "  $(basename "$path")"

    if path_taken "$path.part"; then
        echo "  (a .part file exists: another encode may be writing it)"
    fi

    if [[ -L "$path" ]]; then
        echo
        output_symlink_notice "$path"
        echo
    fi

    echo "1) Keep both  [new file: $(basename "$alt")]"

    if path_taken "$path" && ! path_taken "$path.part" && ! output_is_planned "$path"; then
        if [[ -L "$path" && -e "$path" ]]; then
            echo "2) Overwrite: replace the symlink itself when the new encode completes"
        elif [[ -L "$path" ]]; then
            echo "2) Overwrite: replace the broken symlink when the new encode completes"
        else
            echo "2) Overwrite the existing file when the new encode completes"
        fi
    fi

    echo "3) Skip this file"

    while true; do
        read -rp "Select: " c

        case "$c" in
            1)
                RESOLVED_OUT="$alt"
                return 0
                ;;
            2)
                if path_taken "$path" && ! path_taken "$path.part" && ! output_is_planned "$path"; then
                    RESOLVED_OVERWRITE=1
                    return 0
                fi
                echo "Invalid selection."
                ;;
            3)
                return 1
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}

# ------------------------------------------------------------
# libx265 capabilities
# ------------------------------------------------------------

LIBX265_HELP=""

libx265_has_option() {
    if [[ -z "$LIBX265_HELP" ]]; then
        LIBX265_HELP=$(ffmpeg -hide_banner -h encoder=libx265 2>/dev/null || true)
    fi

    grep -qE "^[[:space:]]+-$1[[:space:]]" <<< "$LIBX265_HELP"
}

# ------------------------------------------------------------
# HDR / colour signalling (needs probe_hdr globals)
# ------------------------------------------------------------

# x265 VUI names match the ffmpeg names for the values below; anything
# else is left for x265/ffmpeg to decide.
x265_color_params() {
    local p=()

    case "$HDR_PRIMARIES" in
        bt709|bt470m|bt470bg|smpte170m|smpte240m|film|bt2020|smpte428|smpte431|smpte432)
            p+=("colorprim=$HDR_PRIMARIES") ;;
    esac

    case "$HDR_TRANSFER" in
        bt709|bt470m|bt470bg|smpte170m|smpte240m|linear|iec61966-2-4|bt1361e|iec61966-2-1|bt2020-10|bt2020-12|smpte2084|smpte428|arib-std-b67)
            p+=("transfer=$HDR_TRANSFER") ;;
    esac

    case "$HDR_MATRIX" in
        gbr|bt709|fcc|bt470bg|smpte170m|smpte240m|ycgco|bt2020nc|bt2020c|smpte2085|chroma-derived-nc|chroma-derived-c|ictcp)
            p+=("colormatrix=$HDR_MATRIX") ;;
    esac

    case "$HDR_RANGE" in
        tv) p+=("range=limited") ;;
        pc) p+=("range=full") ;;
    esac

    # HDR10 static metadata. x265 emits the SEI messages (and enables
    # HDR10 signalling) when these are given.
    if [[ "$HDR_KIND" != "SDR" ]]; then
        [[ -n "$HDR_MASTER" ]] && p+=("master-display=$HDR_MASTER")
        [[ -n "$HDR_CLL" ]] && p+=("max-cll=$HDR_CLL")
    fi

    local IFS=':'
    printf '%s' "${p[*]-}"
}

# Container-level colour tags for the encoded stream (shell-quoted).
color_output_args() {
    local a=()

    [[ -n "$HDR_PRIMARIES" ]] && a+=(-color_primaries:v:0 "$HDR_PRIMARIES")
    [[ -n "$HDR_TRANSFER" ]] && a+=(-color_trc:v:0 "$HDR_TRANSFER")
    [[ -n "$HDR_MATRIX" ]] && a+=(-colorspace:v:0 "$HDR_MATRIX")
    [[ -n "$HDR_RANGE" ]] && a+=(-color_range:v:0 "$HDR_RANGE")

    (( ${#a[@]} )) && printf '%q ' "${a[@]}"
    return 0
}

# (confirm_dynamic_range, the Dolby Vision / HDR10+ policy, lives in
# hdr_dovi.sh)

# ------------------------------------------------------------
# Shared video encode settings
# ------------------------------------------------------------

# x265 preset of every movie / series video encode (final encodes and
# the CRF sample encodes, so samples behave like the real encode)
X265_PRESET="slow"

# 1080p downscale of the movie / series menus (aspect kept, even sizes)
DOWNSCALE_1080P_FILTER="scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"

# downscale_1080p_dims WIDTH HEIGHT  ->  "WIDTH HEIGHT" after
# DOWNSCALE_1080P_FILTER
downscale_1080p_dims() {
    awk -v w="$1" -v h="$2" 'BEGIN {
        sx = 1920 / w
        sy = 1080 / h
        s = (sx < sy ? sx : sy)
        if (s > 1) s = 1
        ow = int((w * s) / 2) * 2
        oh = int((h * s) / 2) * 2
        print ow, oh
    }'
}

# ------------------------------------------------------------
# CRF size estimation (sample encodes; the selection math is in
# policy.sh: crf_select_boundary, crf_sample_points, series_crf_spread)
# ------------------------------------------------------------

# crf_x265_params FILE VIDX  ->  the x265 colour / HDR10 parameters the
# final encode of FILE uses (probe_hdr in a subshell, so the caller's
# HDR_* globals are left alone)
crf_x265_params() {
    (
        probe_hdr "$1" "$2" > /dev/null 2>&1
        x265_color_params
    )
}

# crf_sample_encode FILE VIDX FILTER X265_PARAMS CRF START LENGTH OUT
#
# Encodes one section of the main video stream the way the final CRF
# encode does (emit_encode_item): same scaling filter (the selected
# output resolution), preset, CRF, 10-bit pixel format and x265 colour /
# HDR10 parameters. Dolby Vision RPUs and HDR10+ dynamic metadata are
# not added: they are a few bytes per frame and do not change how x265
# codes the picture. Raw HEVC output, so the file size is the video
# payload.
crf_sample_encode() {
    local file="$1" vidx="$2" filter="$3" x265="$4" crf="$5" start="$6" len="$7" out="$8"
    local a=()

    [[ -n "$filter" ]] && a+=(-filter:v:0 "$filter")
    libx265_has_option dolbyvision && a+=(-dolbyvision:v:0 0)

    ffmpeg -nostdin -v error -y -ss "$start" -i "$file" -t "$len" \
        -map "0:$vidx" "${a[@]+"${a[@]}"}" \
        -c:v:0 libx265 -preset "$X265_PRESET" -crf:v:0 "$crf" -pix_fmt:v:0 yuv420p10le \
        -x265-params:v:0 "${x265:+$x265:}log-level=error" \
        -an -sn -dn -f hevc "$out"
}

# _crf_cache_dir  ->  sample result cache ("" = caching off:
# CRF_SAMPLE_CACHE=0)
_crf_cache_dir() {
    [[ "${CRF_SAMPLE_CACHE:-1}" == "0" ]] && return 0
    printf '%s' "${WORK_DIR:-$HOME/compress/work}/cache/crf_samples"
}

# crf_sample_title FILE VIDX FILTER CRF DURATION POINTS
#
# Encodes the sample sections of FILE (crf_sample_points: POINTS
# sections of CRF_SAMPLE_SECONDS) at CRF. The same sections are used for
# every CRF. Sets CRF_SAMPLE_BYTES (all sections), CRF_SAMPLE_SECS
# (their length) and CRF_SAMPLE_PARTS ("START:LENGTH:BYTES" per section;
# diagnostics only: crf_sample_parts_text). Each section result is cached under
# WORK_DIR/cache/crf_samples, keyed by the resolved file, its size and
# mtime, the section and every encode setting, so running the menu
# again does not re-encode it. Returns 1 when a sample encode fails.
crf_sample_title() {
    local file="$1" vidx="$2" filter="$3" crf="$4" dur="$5" points="$6"
    local x265 cache key start len b line tmp err sig
    local -a sections

    CRF_SAMPLE_BYTES=0
    CRF_SAMPLE_SECS=0
    CRF_SAMPLE_PARTS=""

    mapfile -t sections < <(crf_sample_points "$dur" "$points" "$CRF_SAMPLE_SECONDS")
    (( ${#sections[@]} )) || return 1

    x265=$(crf_x265_params "$file" "$vidx")
    cache=$(_crf_cache_dir)
    sig="$(readlink -f -- "$file")|$(stat -L -c '%s %Y' -- "$file")|$vidx|$filter|$x265|$X265_PRESET|$crf"
    [[ -n "$cache" ]] && mkdir -p "$cache" 2>/dev/null

    tmp=$(mktemp "${TMPDIR:-/tmp}/crf-sample.XXXXXX") || return 1
    err="$tmp.err"

    for line in "${sections[@]}"; do
        read -r start len <<< "$line"
        b=""

        if [[ -n "$cache" ]]; then
            key=$(printf '%s|%s|%s' "$sig" "$start" "$len" | md5sum | cut -c1-32)
            [[ -s "$cache/$key" ]] && b=$(< "$cache/$key")
        fi

        if [[ ! "$b" =~ ^[0-9]+$ ]]; then
            if ! crf_sample_encode "$file" "$vidx" "$filter" "$x265" "$crf" "$start" "$len" "$tmp" 2> "$err" ||
               [[ ! -s "$tmp" ]]; then
                echo "    sample encode failed (CRF $crf at ${start}s): $(head -n 3 "$err" | tr '\n' ' ')" >&2
                rm -f -- "$tmp" "$err"
                return 1
            fi
            b=$(file_bytes "$tmp")
            [[ -n "$cache" ]] && printf '%s\n' "$b" > "$cache/$key" 2>/dev/null
        fi
        CRF_SAMPLE_PARTS+="${CRF_SAMPLE_PARTS:+ }$start:$len:$b"

        read -r CRF_SAMPLE_BYTES CRF_SAMPLE_SECS < <(
            awk -v t="$CRF_SAMPLE_BYTES" -v s="$CRF_SAMPLE_SECS" -v b="$b" -v l="$len" \
                'BEGIN { printf "%.0f %.3f\n", t + b, s + l }')
    done

    rm -f -- "$tmp" "$err"
    return 0
}

# crf_sample_parts_text DURATION  ->  "10%: 14.1, 50%: 3.2, 90%: 12.8 Mb/s"
# (the video bitrate of each section of the last crf_sample_title, at
# its position in the runtime; verbose diagnostics: does one easy or
# hard section dominate the estimate?)
crf_sample_parts_text() {
    awk -v p="${CRF_SAMPLE_PARTS:-}" -v d="$1" 'BEGIN {
        n = split(p, s, " ")
        for (i = 1; i <= n; i++) {
            split(s[i], f, ":")
            if (f[2] <= 0) continue
            pos = (d > 0) ? (f[1] + f[2] / 2) / d * 100 : 0
            out = out (out == "" ? "" : ", ") sprintf("%.0f%%: %.1f", pos, f[3] * 8 / f[2] / 1000000)
        }
        if (out != "") printf "%s Mb/s", out }'
}

# crf_title_estimate CRF  (ESTIMATOR for crf_select / crf_select_exact)
#
# One title: reads CRF_TITLE_FILE CRF_TITLE_VIDX CRF_TITLE_FILTER
# CRF_TITLE_DURATION CRF_TITLE_POINTS. Leaves the whole-title video
# estimate (bytes) in CRF_EST_RESULT.
crf_title_estimate() {
    local crf="$1" n

    if ui_verbose; then
        n=$(crf_sample_points "$CRF_TITLE_DURATION" "$CRF_TITLE_POINTS" "$CRF_SAMPLE_SECONDS" | grep -c .)
        printf '  sampling CRF %s (%s section%s)... ' "$crf" "$n" "$( (( n == 1 )) || echo s)"
    else
        printf '  CRF %-4s ' "$crf"
    fi

    if ! crf_sample_title "$CRF_TITLE_FILE" "$CRF_TITLE_VIDX" "$CRF_TITLE_FILTER" "$crf" \
            "$CRF_TITLE_DURATION" "$CRF_TITLE_POINTS"; then
        ui_err FAILED; echo
        return 1
    fi

    CRF_EST_RESULT=$(crf_extrapolate "$CRF_SAMPLE_BYTES" "$CRF_SAMPLE_SECS" "$CRF_TITLE_DURATION")
    if ui_verbose; then
        echo "~$(size_text "$CRF_EST_RESULT") video"
    else
        echo "~$(bytes_to_gib "$CRF_EST_RESULT") GiB"
    fi
}

# crf_series_estimate CRF  (ESTIMATOR for crf_select / crf_select_exact)
#
# A series batch: samples the episodes in CRF_SERIES_SAMPLED (indexes
# into FILES / EP_VIDX / EP_DUR) with CRF_SERIES_FILTER, spreads the
# result over every episode (series_crf_spread) and leaves the LARGEST
# REGULAR episode estimate in CRF_EST_RESULT (series_batch_stats
# SB_DECIDE against CRF_CEILING_BYTES: an isolated outlier does not
# decide the season CRF). Per-episode estimates are kept in
# CRF_SERIES_EP_BYTES[crf] ("b0 b1 ...") and CRF_SERIES_EP_FROM[crf],
# the sampled bytes/s per episode in CRF_SERIES_RATES[crf] ("r0 - r2 ...",
# "-" = not sampled; policy.sh series_crf_certify_over); those of the
# sampled episodes also in CRF_EP_EST ("INDEX:CRF"), so
# crf_episode_estimate does not encode them again.
#
# Decisive inference: when the season does not fit at CRF and an episode
# that was not sampled decides that (policy.sh series_decisive_inferred),
# that episode is sampled itself at CRF (CRF_EP_EST / the sample cache
# reused), its inferred estimate replaced (SC_EP_FROM "promoted") and the
# figures recomputed (median, largest, outliers, isolated outlier, fit),
# one episode at a time, before the CRF counts as too large.
crf_series_estimate() {
    local crf="$1" i rates=() k=0 w=0 label

    declare -gA CRF_EP_EST CRF_SERIES_RATES
    for i in "${!EP_DUR[@]}"; do
        rates[$i]="-"
    done

    # compact output: "CRF 18", then one "  S01E01  ~0.88 GiB" line per
    # sampled episode (CRF_SERIES_LABELS: episode ids, else file names)
    if ! ui_verbose; then
        for i in "${CRF_SERIES_SAMPLED[@]}"; do
            label="${CRF_SERIES_LABELS[$i]:-$(basename "${FILES[$i]}")}"
            (( ${#label} > w )) && w=${#label}
        done
        echo
        echo "CRF $crf"
    fi

    for i in "${CRF_SERIES_SAMPLED[@]}"; do
        ((k += 1))
        if ui_verbose; then
            printf '  sampling CRF %s, episode %d/%d (%s)... ' "$crf" "$k" "${#CRF_SERIES_SAMPLED[@]}" "$(basename "${FILES[$i]}")"
        else
            printf '  %-*s  ' "$w" "${CRF_SERIES_LABELS[$i]:-$(basename "${FILES[$i]}")}"
        fi
        if ! crf_sample_title "${FILES[$i]}" "${EP_VIDX[$i]}" "$CRF_SERIES_FILTER" "$crf" \
                "${EP_DUR[$i]}" "$SERIES_CRF_SAMPLE_POINTS"; then
            ui_err FAILED; echo
            return 1
        fi
        rates[$i]=$(awk -v b="$CRF_SAMPLE_BYTES" -v s="$CRF_SAMPLE_SECS" 'BEGIN { printf "%.3f", b / s }')
        if ui_verbose; then
            echo "~$(size_text "$(crf_extrapolate "$CRF_SAMPLE_BYTES" "$CRF_SAMPLE_SECS" "${EP_DUR[$i]}")") video ($(crf_sample_parts_text "${EP_DUR[$i]}"))"
        else
            echo "~$(bytes_to_gib "$(crf_extrapolate "$CRF_SAMPLE_BYTES" "$CRF_SAMPLE_SECS" "${EP_DUR[$i]}")") GiB"
        fi
    done

    series_crf_spread "${rates[@]}" || return 1
    series_batch_stats "${CRF_CEILING_BYTES:-0}" "${SC_EP_BYTES[@]}" || return 1

    local -A promoted=()
    while series_decisive_inferred "${CRF_CEILING_BYTES:-0}"; do
        i="$SD_INDEX"
        _crf_series_promote "$crf" "$i" "$w" || return 1
        rates[$i]="$CRF_PROMOTE_RATE"
        promoted[$i]=1
        series_crf_spread "${rates[@]}" || return 1
        for i in ${promoted[@]+"${!promoted[@]}"}; do
            SC_EP_FROM[$i]=promoted
        done
        series_batch_stats "${CRF_CEILING_BYTES:-0}" "${SC_EP_BYTES[@]}" || return 1
    done

    CRF_EST_RESULT="$SB_DECIDE"
    CRF_SERIES_EP_BYTES[$crf]="${SC_EP_BYTES[*]}"
    CRF_SERIES_EP_FROM[$crf]="${SC_EP_FROM[*]}"
    CRF_SERIES_RATES[$crf]="${rates[*]}"
    for i in "${CRF_SERIES_SAMPLED[@]}" ${promoted[@]+"${!promoted[@]}"}; do
        CRF_EP_EST[$i:$crf]="${SC_EP_BYTES[$i]}"
    done
}

# _crf_series_promote CRF INDEX LABEL_WIDTH  (crf_series_estimate)
#
# Episode INDEX was not sampled and decides the season at CRF (policy.sh
# series_decisive_inferred): shows its inferred estimate, samples it
# itself at CRF (an estimate already in CRF_EP_EST "INDEX:CRF" is reused;
# the sections are cached on disk as well, crf_sample_title) and leaves
# its sampled bytes/s in CRF_PROMOTE_RATE. Reads SC_EP_BYTES and
# SB_DECIDE_IDX. Returns 1 when the sample encode failed.
_crf_series_promote() {
    local crf="$1" i="$2" w="$3" label est cached=0 what

    label="${CRF_SERIES_LABELS[$i]:-$(basename "${FILES[$i]}")}"
    (( ${#label} > w )) && w=${#label}
    what="Decisive:"
    [[ "$i" == "${SB_DECIDE_IDX:-}" ]] && what="Largest:"

    if ui_verbose; then
        printf '  %s not sampled, decides the season at CRF %s (~%s video, inferred); sampling it... ' \
            "$(basename "${FILES[$i]}")" "$crf" "$(size_text "${SC_EP_BYTES[$i]}")"
    else
        echo
        printf '%-10s%s GiB (%s, inferred)\n' "$what" "$(bytes_to_gib "${SC_EP_BYTES[$i]}")" "$label"
        printf '  %-*s  ' "$w" "$label"
    fi

    if [[ "${CRF_EP_EST[$i:$crf]:-}" =~ ^[0-9]+$ ]]; then
        est="${CRF_EP_EST[$i:$crf]}"
        CRF_PROMOTE_RATE=$(awk -v b="$est" -v d="${EP_DUR[$i]}" 'BEGIN { printf "%.3f", (d > 0 ? b / d : 0) }')
        cached=1
    else
        if ! crf_sample_title "${FILES[$i]}" "${EP_VIDX[$i]}" "${CRF_SERIES_FILTER:-}" "$crf" \
                "${EP_DUR[$i]}" "$SERIES_CRF_SAMPLE_POINTS"; then
            ui_err FAILED; echo
            return 1
        fi
        CRF_PROMOTE_RATE=$(awk -v b="$CRF_SAMPLE_BYTES" -v s="$CRF_SAMPLE_SECS" 'BEGIN { printf "%.3f", b / s }')
        est=$(crf_extrapolate "$CRF_SAMPLE_BYTES" "$CRF_SAMPLE_SECS" "${EP_DUR[$i]}")
    fi

    if ui_verbose; then
        echo "~$(size_text "$est") video$( (( cached == 1 )) && echo " (already sampled)")"
    else
        echo "~$(bytes_to_gib "$est") GiB  sampled after inference$( (( cached == 1 )) && echo " (already sampled)")"
    fi
}

# crf_episode_estimate INDEX CRF  (ESTIMATOR for series_episode_crf)
#
# One episode of the series batch (FILES / EP_VIDX / EP_DUR,
# CRF_SERIES_FILTER, SERIES_CRF_SAMPLE_POINTS), sampled itself at CRF,
# also when the batch estimate did not sample it. Leaves its video
# estimate in CRF_EST_RESULT and remembers it in CRF_EP_EST
# ("INDEX:CRF"); a remembered estimate is not encoded again (the
# sections themselves are cached on disk as well, crf_sample_title).
crf_episode_estimate() {
    local i="$1" crf="$2" label cached=0

    declare -gA CRF_EP_EST
    label="${CRF_SERIES_LABELS[$i]:-$(basename "${FILES[$i]}")}"

    if ui_verbose; then
        printf '  sampling CRF %s, episode %s (%s)... ' "$crf" "$((i + 1))" "$(basename "${FILES[$i]}")"
    else
        printf '  %s  CRF %-4s ' "$label" "$crf"
    fi

    if [[ "${CRF_EP_EST[$i:$crf]:-}" =~ ^[0-9]+$ ]]; then
        CRF_EST_RESULT="${CRF_EP_EST[$i:$crf]}"
        cached=1
    else
        if ! crf_sample_title "${FILES[$i]}" "${EP_VIDX[$i]}" "${CRF_SERIES_FILTER:-}" "$crf" \
                "${EP_DUR[$i]}" "$SERIES_CRF_SAMPLE_POINTS"; then
            ui_err FAILED; echo
            return 1
        fi
        CRF_EST_RESULT=$(crf_extrapolate "$CRF_SAMPLE_BYTES" "$CRF_SAMPLE_SECS" "${EP_DUR[$i]}")
        CRF_EP_EST[$i:$crf]="$CRF_EST_RESULT"
    fi

    if ui_verbose; then
        echo "~$(size_text "$CRF_EST_RESULT") video$( (( cached == 1 )) && echo " (already sampled)")"
    else
        echo "~$(bytes_to_gib "$CRF_EST_RESULT") GiB$( (( cached == 1 )) && echo " (already sampled)")"
    fi
}

# crf_step_result KIND CRF [ARG]  ->  the result text of one step of the
# bracket-and-refine CRF search (policy.sh crf_search_up REPORT kinds
# other than fits / boundary), e.g. "too large -> jumping to CRF 14"
crf_step_result() {
    case "$1" in
        over)
            if (( 10#$3 > 10#$2 + 1 )); then
                printf '%s -> jumping to CRF %s' "$(ui_warn "too large")" "$3"
            else
                printf '%s -> trying CRF %s' "$(ui_warn "too large")" "$3"
            fi
            ;;
        check)       printf '%s -> checking CRF %s' "$(ui_warn "too large")" "$3" ;;
        resume)      printf '%s -> continuing at CRF %s' "$(ui_warn "too large")" "$3" ;;
        limit)       printf '%s (CRF %s is the %s limit)' "$(ui_warn "too large")" "$2" "${TIER:-tier}" ;;
        refine)      printf 'fits -> checking CRF %s' "$3" ;;
        refine-over) printf '%s' "$(ui_warn "too large")" ;;
        refine-fits) printf 'fits' ;;
        down)        printf 'fits -> trying CRF %s' "$3" ;;
        down-over)   printf '%s' "$(ui_warn "too large")" ;;
        floor)       printf 'fits (lowest %s CRF allowed)' "${TIER:-tier}" ;;
    esac
}

# crf_boundary_lines LO HI  ->  the verified boundary of the CRF search:
# LO estimated above the ceiling, HI fits
crf_boundary_lines() {
    echo "Boundary:"
    printf '  CRF %-2s  over\n' "$1"
    printf '  CRF %-2s  fits\n' "$2"
}

# crf_step_skips KIND CRF [ARG]  ->  0 for a step that skips a CRF, checks
# a skipped one, searches below the start CRF or reports the boundary
# found that way
crf_step_skips() {
    case "$1" in
        over) (( 10#$3 > 10#$2 + 1 )) ;;
        check|resume|refine|refine-over|refine-fits|boundary) return 0 ;;
        down|down-over|floor) return 0 ;;
        *)    return 1 ;;
    esac
}

# crf_title_step_report KIND CRF [ARG]  (REPORT for crf_select_boundary /
# crf_select_quality, movie): only the steps that skip or check a skipped
# CRF or go below the start CRF get a line below the sample line, plus the
# boundary block; an upward search without skips looks as before
crf_title_step_report() {
    crf_step_skips "$@" || return 0
    if [[ "$1" == boundary ]]; then
        echo
        crf_boundary_lines "$2" "$3"
    else
        printf '           %s\n' "$(crf_step_result "$@")"
    fi
}

# crf_episode_step_report KIND CRF [ARG]  (REPORT for series_episode_crf)
crf_episode_step_report() {
    crf_step_skips "$@" || return 0
    if [[ "$1" == boundary ]]; then
        printf '    boundary: CRF %s over, CRF %s fits\n' "$2" "$3"
    else
        printf '    %s\n' "$(crf_step_result "$@")"
    fi
}

# ------------------------------------------------------------
# Metadata helpers
# ------------------------------------------------------------

# mkv_subtitle_action CODEC  ->  copy | srt | drop
mkv_subtitle_action() {
    case "$1" in
        subrip|srt|ass|ssa|webvtt|hdmv_pgs_subtitle|dvd_subtitle|dvb_subtitle|text)
            echo copy ;;
        mov_text)
            echo srt ;;
        *)
            echo drop ;;
    esac
}

# mp4_handler_is_name NAME  ->  0 when an MP4/MOV handler_name is a real
# track name (not a muxer default like "SoundHandler").
mp4_handler_is_name() {
    case "$1" in
        ""|-|*Handler|*handler|"Core Media"*|*"Media Handler"|"ISO Media"*|"Mainconcept"*|"GPAC"*|"L-SMASH"*|"Apple "*)
            return 1 ;;
    esac
    return 0
}

# MKV statistics tags describe the encoded bitstream of the source. On a
# re-encoded stream they are stale, so they are removed at mux time
# (refresh_mkv_stats regenerates them for every track afterwards).
STALE_STATS_TAGS=(BPS NUMBER_OF_BYTES NUMBER_OF_FRAMES DURATION
    _STATISTICS_TAGS _STATISTICS_WRITING_APP _STATISTICS_WRITING_DATE_UTC
    ENCODER ENCODER_SETTINGS)

# stale_stats_args SPEC  ->  shell-quoted "-metadata:s:SPEC TAG=" tokens
stale_stats_args() {
    local a=() t

    for t in "${STALE_STATS_TAGS[@]}"; do
        a+=("-metadata:s:$1" "$t=" "-metadata:s:$1" "$t-eng=")
    done

    printf '%q ' "${a[@]}"
}

# audio_transcoded_codecs AUDIO_ARGS AUDIO_COUNT
#   ->  "index encoder" per audio track re-encoded by AUDIO_ARGS
#       (audio-relative index), one per line
audio_transcoded_codecs() {
    local -a w
    local i j n="$2"
    local -A enc=()

    read -ra w <<< "$1"

    for ((i = 0; i < ${#w[@]}; i++)); do
        if [[ "${w[$i]}" == "-c:a" ]]; then
            for ((j = 0; j < n; j++)); do enc[$j]="${w[$i + 1]:-copy}"; done
        elif [[ "${w[$i]}" =~ ^-c:a:([0-9]+)$ ]]; then
            enc[${BASH_REMATCH[1]}]="${w[$i + 1]:-copy}"
        fi
    done

    for ((j = 0; j < n; j++)); do
        [[ -n "${enc[$j]:-}" && "${enc[$j]}" != "copy" ]] && echo "$j ${enc[$j]}"
    done

    return 0
}

# encoder_codec ENCODER  ->  ffprobe codec name the encoder produces
encoder_codec() {
    case "$1" in
        libopus)            echo opus ;;
        libmp3lame)         echo mp3 ;;
        libfdk_aac)         echo aac ;;
        libvorbis)          echo vorbis ;;
        *)                  echo "$1" ;;
    esac
}

# codec_title_label CODEC  ->  label used in track titles ("AAC", ...)
codec_title_label() {
    case "$1" in
        aac)    echo AAC ;;
        opus)   echo Opus ;;
        eac3)   echo E-AC-3 ;;
        ac3)    echo AC-3 ;;
        mp3)    echo MP3 ;;
        vorbis) echo Vorbis ;;
        flac)   echo FLAC ;;
        truehd) echo TrueHD ;;
        dts)    echo DTS ;;
        pcm*)   echo PCM ;;
        *)      echo "${1^^}" ;;
    esac
}

# _audio_title_awk MODE TITLE CODEC LABEL CHANNELS PROFILE
#
# MODE rewrite: TITLE with every codec / object-audio / bitrate /
#   bit-depth / sample-rate claim removed; the first codec mention is
#   replaced by LABEL (the new codec). Channel layouts that do not match
#   CHANNELS are removed. Neutral text ("English", "Director's
#   Commentary") is kept. Nothing is invented: Atmos/DTS:X are never
#   added.
# MODE check: prints the claims in TITLE that are false for a track of
#   CODEC with PROFILE and CHANNELS (empty = accurate).
# Case-insensitive; plain POSIX awk (mawk compatible).
_audio_title_awk() {
    awk -v mode="$1" -v t="$2" -v codec="$3" -v label="$4" -v ch="$5" -v prof="$6" '
        BEGIN {
            # pattern, class (order matters: longest / most specific first)
            n = 0
            P[++n] = "dolby atmos";                       C[n] = "atmos"
            P[++n] = "atmos";                             C[n] = "atmos"
            P[++n] = "dts[:-]? ?x";                       C[n] = "dtsx"
            P[++n] = "dolby truehd";                      C[n] = "truehd"
            P[++n] = "true[- ]?hd";                       C[n] = "truehd"
            P[++n] = "dolby digital plus";                C[n] = "eac3"
            P[++n] = "dolby digital";                     C[n] = "ac3"
            P[++n] = "dd\\+";                             C[n] = "eac3"
            P[++n] = "ddp";                               C[n] = "eac3"
            P[++n] = "e-?ac-?3";                          C[n] = "eac3"
            P[++n] = "ac-?3";                             C[n] = "ac3"
            P[++n] = "dd";                                C[n] = "ac3"
            P[++n] = "dts-?hd master audio";              C[n] = "dts"
            P[++n] = "dts-?hd high resolution( audio)?";  C[n] = "dts"
            P[++n] = "dts-?hd ?(ma|hra|hr)";              C[n] = "dts"
            P[++n] = "dts-?hd";                           C[n] = "dts"
            P[++n] = "dts-?es";                           C[n] = "dts"
            P[++n] = "master audio";                      C[n] = "dts"
            P[++n] = "dts";                               C[n] = "dts"
            P[++n] = "l?pcm";                             C[n] = "pcm"
            P[++n] = "flac";                              C[n] = "flac"
            P[++n] = "alac";                              C[n] = "alac"
            P[++n] = "he-?aac( ?v2)?";                    C[n] = "aac"
            P[++n] = "aac( ?-?lc)?";                      C[n] = "aac"
            P[++n] = "opus";                              C[n] = "opus"
            P[++n] = "mp3";                               C[n] = "mp3"
            P[++n] = "vorbis";                            C[n] = "vorbis"
            P[++n] = "dolby";                             C[n] = "dolby"
            P[++n] = "lossless";                          C[n] = "lossless"
            P[++n] = "[0-9]+([.,][0-9]+)? ?(kbps|kb/s|kbit/s|kbits/s|mbps|mb/s|mbit/s|k)"; C[n] = "bitrate"
            P[++n] = "(16|20|24|32)[- ]?bits?";           C[n] = "bitdepth"
            P[++n] = "[0-9]+([.,][0-9]+)? ?khz";          C[n] = "samplerate"
            P[++n] = "7\\.1";                             C[n] = "ch8"
            P[++n] = "6\\.1";                             C[n] = "ch7"
            P[++n] = "5\\.1";                             C[n] = "ch6"
            P[++n] = "5\\.0";                             C[n] = "ch5"
            P[++n] = "4\\.0|quad";                        C[n] = "ch4"
            P[++n] = "2\\.0|stereo";                      C[n] = "ch2"
            P[++n] = "1\\.0|mono";                        C[n] = "ch1"

            lc = tolower(t); out = t; first = 1; stale = ""

            for (i = 1; i <= n; i++) {
                # codec names may be glued to a layout ("DD5.1")
                if (C[i] ~ /^ch/)
                    re = "(^|[^a-z0-9.])(" P[i] ")($|[^a-z0-9.])"
                else if (is_codec(C[i]) || C[i] ~ /^(atmos|dtsx|dolby)$/)
                    re = "(^|[^a-z0-9.])(" P[i] ")($|[^a-z])"
                else
                    re = "(^|[^a-z0-9.])(" P[i] ")($|[^a-z0-9])"

                pos = 1
                while (pos <= length(lc) && match(substr(lc, pos), re)) {
                    s = pos + RSTART - 1
                    if (substr(lc, s, 1) ~ /[^a-z0-9.]/) s++
                    match(substr(lc, s), "^(" P[i] ")")
                    l = RLENGTH

                    # blank: same length, never matches again
                    blank = sprintf("%" l "s", ""); gsub(/./, "\002", blank)

                    if (!is_false(C[i]) || mode == "check") {
                        if (mode == "check" && is_false(C[i]))
                            stale = stale (stale ? ", " : "") substr(t, s, l)
                        lc = substr(lc, 1, s - 1) blank substr(lc, s + l)
                        pos = s + l
                        continue
                    }

                    rep = ""
                    # DTS:X also names the codec (DTS); Atmos alone does not
                    if ((is_codec(C[i]) || C[i] == "dtsx") && first) { rep = "\001"; first = 0 }
                    lc  = substr(lc, 1, s - 1) rep substr(lc, s + l)
                    out = substr(out, 1, s - 1) rep substr(out, s + l)
                    pos = s + length(rep)
                }
            }

            if (mode == "check") { print stale; exit }

            while (match(out, /\001[0-9A-Za-z]/)) out = substr(out, 1, RSTART) " " substr(out, RSTART + 1)
            while (match(out, /[0-9A-Za-z]\001/)) out = substr(out, 1, RSTART) " " substr(out, RSTART + 1)
            gsub(/[ \t]+/, " ", out)
            gsub(/\( *[-|\/,;:+@ ]*\)|\[ *[-|\/,;:+@ ]*\]|\{ *[-|\/,;:+@ ]*\}/, "", out)
            while (match(out, /[-|\/,;:+@] *[-|\/,;:+@]/))
                out = substr(out, 1, RSTART) substr(out, RSTART + RLENGTH)
            gsub(/\( +/, "(", out); gsub(/ +\)/, ")", out)
            gsub(/\[ +/, "[", out); gsub(/ +\]/, "]", out)
            gsub(/ +/, " ", out)
            sub(/^[ |\/,;:+@-]+/, "", out); sub(/[ |\/,;:+@-]+$/, "", out)

            if (out == "" || out == "\001") out = label
            sub(/\001/, label, out)
            gsub(/\001/, "", out)
            print out
        }
        function is_codec(c) { return c ~ /^(truehd|eac3|ac3|dts|pcm|flac|alac|aac|opus|mp3|vorbis)$/ }
        function is_false(c) {
            if (is_codec(c)) return c != codec
            if (c == "dolby")    return codec !~ /^(ac3|eac3|truehd)$/
            if (c == "lossless") return codec !~ /^(flac|alac|pcm|truehd)$/
            if (c == "atmos")    return prof !~ /Atmos/
            if (c == "dtsx")     return prof !~ /DTS:X/
            if (c ~ /^ch/)       return (ch != "" && substr(c, 3) + 0 != ch + 0)
            return 1   # bitrate / bit depth / sample rate of the old stream
        }'
}

# audio_title_rewrite TITLE CODEC CHANNELS  ->  title for the re-encoded track
audio_title_rewrite() {
    _audio_title_awk rewrite "$1" "$2" "$(codec_title_label "$2")" "$3" ""
}

# audio_title_false_claims TITLE CODEC CHANNELS PROFILE  ->  "" if accurate
audio_title_false_claims() {
    _audio_title_awk check "$1" "$2" "" "$3" "$4"
}

# _audio_rows FILE  ->  audio stream_meta rows with the effective title
# (MP4 handler_name when there is no title)
_audio_rows() {
    local mp4=0
    case "${1,,}" in *.mp4|*.m4v|*.mov) mp4=1 ;; esac

    stream_meta "$1" |
    awk -F'\t' -v OFS='\t' -v mp4="$mp4" '$2 == "audio" { print }' |
    while IFS=$'\t' read -r -a f; do
        if [[ "${f[13]}" == "-" ]] && (( mp4 == 1 )) && mp4_handler_is_name "${f[15]}"; then
            f[13]="${f[15]}"
        fi
        (IFS=$'\t'; printf '%s\n' "${f[*]}")
    done
}

# audio_title_plan FILE AUDIO_ARGS
#   ->  "index<TAB>old title<TAB>new title" for every re-encoded track
#       that has a title (new == old when it is still accurate)
audio_title_plan() {
    local file="$1"
    local -a rows f
    local i enc codec

    mapfile -t rows < <(_audio_rows "$file")

    while read -r i enc; do
        [[ -n "$i" && -n "${rows[$i]:-}" ]] || continue
        IFS=$'\t' read -r -a f <<< "${rows[$i]}"
        [[ "${f[13]}" != "-" ]] || continue
        codec=$(encoder_codec "$enc")
        printf '%s\t%s\t%s\n' "$i" "${f[13]}" "$(audio_title_rewrite "${f[13]}" "$codec" "${f[4]}")"
    done < <(audio_transcoded_codecs "$2" "${#rows[@]}")
}

# audio_title_args FILE AUDIO_ARGS  ->  shell-quoted -metadata:s:a:N
# title=... for re-encoded tracks whose title would become false.
audio_title_args() {
    local i old new a=()

    while IFS=$'\t' read -r i old new; do
        [[ "$old" != "$new" ]] && a+=("-metadata:s:a:$i" "title=$new")
    done < <(audio_title_plan "$1" "$2")

    (( ${#a[@]} )) && printf '%q ' "${a[@]}"
    return 0
}

# audio_object_kind CODEC PROFILE TITLE  ->  "Dolby Atmos" / "DTS:X" /
# "" (object audio). ffmpeg names it in the profile; the track title is
# a fallback for older ffmpeg (then " (per track title)" is appended).
audio_object_kind() {
    local codec="$1" profile="$2" title="${3,,}"

    if [[ "$profile" == *Atmos* ]]; then
        echo "Dolby Atmos"
    elif [[ "$profile" == *DTS:X* ]]; then
        echo "DTS:X"
    elif [[ "$codec" =~ ^(truehd|eac3)$ && "$title" == *atmos* ]]; then
        echo "Dolby Atmos (per track title)"
    elif [[ "$codec" == dts && "$title" == *dts:x* ]]; then
        echo "DTS:X (per track title)"
    fi
}

# audio_track_label CODEC PROFILE LAYOUT CHANNELS  ->  "E-AC-3 5.1(side)"
audio_track_label() {
    local codec="$1" profile="$2" layout="$3" ch="$4" l

    l=$(codec_title_label "$codec")
    [[ "$codec" == dts && "$profile" == DTS-HD* ]] && l="${profile%% + *}"
    if [[ -n "$layout" && "$layout" != "-" && "$layout" != "unknown" ]]; then
        l+=" $layout"
    elif [[ "$ch" =~ ^[0-9]+$ ]]; then
        l+=" ${ch}ch"
    fi
    printf '%s' "$l"
}

# audio_copy_notes FILE [KBPS_LIST]  ->  one line per audio track of a
# movie / series encode (all copied unchanged), e.g.
#   Audio 1: E-AC-3 5.1(side) + Dolby Atmos, 768 kb/s, eng "English" - copied unchanged
# then "Object audio: Dolby Atmos PRESERVED by stream copy" when present.
# KBPS_LIST: source kb/s per audio track (stats_audio_kbps), optional.
audio_copy_notes() {
    local file="$1" i=0 codec profile ch layout lang title obj line
    local -a kbps objs=()

    read -ra kbps <<< "${2:-}"

    while IFS=$'\t' read -r _ _ codec profile ch layout _ _ _ _ _ _ lang title _; do
        line="Audio $((i + 1)): $(audio_track_label "$codec" "$profile" "$layout" "$ch")"
        obj=$(audio_object_kind "$codec" "$profile" "$title")
        [[ -n "$obj" ]] && { line+=" + $obj"; objs+=("${obj%% (*}"); }
        [[ "${kbps[$i]:-}" =~ ^[0-9]+$ ]] && line+=", $(awk -v k="${kbps[$i]}" 'BEGIN { if (k >= 1000) printf "%.1f Mb/s", k / 1000; else printf "%d kb/s", k }')"
        [[ "$lang" != "-" ]] && line+=", $lang"
        [[ "$title" != "-" ]] && line+=" \"$title\""
        echo "$line - copied unchanged"
        ((i += 1))
    done < <(stream_meta "$file" | awk -F'\t' '$2 == "audio"')

    if (( ${#objs[@]} )); then
        echo "Object audio: $(printf '%s\n' "${objs[@]}" | sort -u | paste -sd/ -) PRESERVED by stream copy"
    fi
    return 0
}

# movtext_styling FILE STREAM_INDEX
#
# What a mov_text -> SRT conversion keeps and loses for this track.
# The track is decoded the way FFmpeg sees it (as ASS) and compared with
# what FFmpeg's SRT encoder can write (<b> <i> <u> and <font color/size>).
# Prints two lines: "kept=..." and "lost=..." (comma lists, may be
# empty). SRT was kept over ASS on purpose: ASS would carry the rest but
# is much less widely supported by hardware players.
movtext_styling() {
    ffmpeg -v error -nostdin -i "$1" -map "0:$2" -c:s ass -f ass - 2>/dev/null |
    awk -F',' '
        /^Style:/ {
            font = $2; size = $3; prim = $4; back = $7; align = $19
            # ASS alpha 00 = opaque; mov_text draws a box behind the text
            if (back ~ /^&H/ && length(back) >= 10 && toupper(substr(back, 3, 2)) != "FF") box = 1
            if (align + 0 != 2) lost["default text position"] = 1
            if (font != "") lost["default font (" font ")"] = 1
            kept["text colour/size (as SRT font tags; player support varies)"] = 1
            next
        }
        /^Dialogue:/ {
            txt = $0; sub(/^([^,]*,){9}/, "", txt)
            while (match(txt, /\{[^}]*\}/)) {
                tags = substr(txt, RSTART + 1, RLENGTH - 2)
                txt = substr(txt, RSTART + RLENGTH)
                n = split(tags, tg, /\\/)
                for (i = 2; i <= n; i++) {
                    x = tg[i]
                    if (x ~ /^(b|i|u)[01]?$/)          kept["bold/italic/underline"] = 1
                    else if (x ~ /^(c|1c)/)            kept["inline colour"] = 1
                    else if (x ~ /^fs/)                kept["inline font size"] = 1
                    else if (x ~ /^r/)                 continue
                    else if (x ~ /^(1a|2a|3a|4a|alpha)/) lost["transparency"] = 1
                    else if (x ~ /^(an|a[0-9]|pos|move)/) lost["positioning"] = 1
                    else if (x ~ /^fn/)                lost["inline font name"] = 1
                    else if (x ~ /^(k|K|kf|ko)/)       lost["karaoke/highlight"] = 1
                    else if (x ~ /^(2c|3c|4c)/)        lost["highlight/outline colour"] = 1
                    else if (x != "")                  lost["\\" x] = 1
                }
            }
        }
        END {
            if (box) lost["background box"] = 1
            k = ""; for (x in kept) k = k (k ? ", " : "") x
            l = ""; for (x in lost) l = l (l ? ", " : "") x
            print "kept=" k
            print "lost=" l
        }'
}

# movtext_note FILE STREAM_INDEX  ->  one-line description of the loss
movtext_note() {
    local kept="" lost="" k v

    while IFS='=' read -r k v; do
        case "$k" in kept) kept="$v" ;; lost) lost="$v" ;; esac
    done < <(movtext_styling "$1" "$2")

    if [[ -n "$lost" ]]; then
        printf 'styling LOST: %s%s' "$lost" "${kept:+; kept: $kept}"
    else
        printf 'no styling lost%s' "${kept:+ (kept: $kept)}"
    fi
}

# chapter_notes FILE  ->  pre-encode notes about chapters / editions
chapter_notes() {
    local file="$1"
    local xml n uids prev next k v
    local -A c=()

    n=$(ffprobe -v error -show_chapters -of csv=p=0 "$file" 2>/dev/null | grep -c . || true)

    if ! is_matroska "$file"; then
        return 0
    fi

    if ! command -v mkvextract >/dev/null 2>&1 || ! command -v mkvpropedit >/dev/null 2>&1; then
        (( n > 0 )) &&
            echo "chapters: mkvtoolnix missing - only FFmpeg's flat chapter list is kept; editions, ordered/hidden flags, nesting and chapter languages may be LOST and cannot be verified"
        return 0
    fi

    xml=$(mktemp)
    if mkv_chapters_xml "$file" "$xml"; then
        while IFS='=' read -r k v; do c[$k]="$v"; done < <(chapter_xml_summary "$xml")
        echo "chapters: $(chapter_xml_describe "$xml") - restored exactly from the source (mkvpropedit)"

        read -r uids prev next <<< "$(mkv_segment_uids "$file")"
        if [[ "$prev" != "-" || "$next" != "-" ]]; then
            echo "chapters: segment is linked to other files (previous/next segment UID) - segment UIDs are kept on the output"
        fi
        if (( c[segrefs] > 0 )); then
            echo "chapters: ordered chapters reference segment UIDs - the source segment UID is kept on the output"
            if grep -o '<ChapterSegmentUID[^>]*>[^<]*' "$xml" | sed 's/.*>//' | grep -viq "^$uids\$"; then
                echo "chapters: WARNING some ordered chapters point to OTHER files (linked segments); those files are not part of this output"
            fi
        fi
    fi
    rm -f -- "$xml"
}

MATROSKA_DEFAULT_MODE=""

# Extra matroska muxer options: keep FlagDefault exactly as the source
# disposition (passthrough is the default since FFmpeg 5; older
# versions guessed defaults).
matroska_mux_args() {
    if [[ -z "$MATROSKA_DEFAULT_MODE" ]]; then
        if ffmpeg -hide_banner -h muxer=matroska 2>/dev/null | grep -q 'passthrough'; then
            MATROSKA_DEFAULT_MODE="-default_mode passthrough"
        else
            MATROSKA_DEFAULT_MODE="-"
        fi
    fi

    [[ "$MATROSKA_DEFAULT_MODE" != "-" ]] && printf '%s ' "$MATROSKA_DEFAULT_MODE"
    return 0
}

# ------------------------------------------------------------
# Stream mapping for the final mux
# ------------------------------------------------------------

# build_stream_map FILE MAIN_VIDEO_INDEX
#
# The main video stream becomes output video #0 (the only stream given
# to libx265). Every other stream is mapped explicitly in file order and
# stream-copied, except:
#   - cover art (attached pictures) -> not muxed by ffmpeg (its MKV muxer
#     would turn them into extra video tracks); re-added afterwards as
#     real MKV attachments by item_add_cover (MAP_COVERS)
#   - mov_text subtitles  -> converted to SRT (MKV cannot store mov_text)
#   - data streams / unsupported subtitles -> not mapped (MKV cannot
#     store them); listed in MAP_NOTES
# MP4/MOV track names stored only as handler_name are copied into the
# MKV track title.
#
# Sets:
#   MAP_ARGS        shell-quoted "-map ..." tokens
#   MAP_OTHER_ARGS  the same without the main video map
#   MAP_CODEC_ARGS  shell-quoted per-stream codec overrides
#   MAP_META_ARGS   shell-quoted per-stream metadata (titles)
#   MAP_COVERS      array of "index<TAB>filename<TAB>mimetype"
#   MAP_NOTES       array of human-readable notes
#   MAP_AUDIO_COUNT number of mapped audio streams
build_stream_map() {
    local file="$1"
    local vidx="$2"
    local idx type codec att rest name mime
    local sub_n=0
    local out_n=1
    local maps=(-map "0:$vidx")
    local codecs=()
    local metas=()
    local -A handler=()
    local h_idx h_type h_title h_handler

    MAP_NOTES=()
    MAP_COVERS=()
    MAP_AUDIO_COUNT=0

    case "${file,,}" in
        *.mp4|*.m4v|*.mov)
            while IFS=$'\t' read -r h_idx h_type _ _ _ _ _ _ _ _ _ _ _ h_title _ h_handler _; do
                if [[ "$h_title" == "-" ]] && mp4_handler_is_name "$h_handler"; then
                    handler[$h_idx]="$h_handler"
                fi
            done < <(stream_meta "$file")
            ;;
    esac

    while IFS=$'\t' read -r idx type codec att rest; do
        [[ "$idx" == "$vidx" ]] && continue

        if [[ -n "${handler[$idx]:-}" && ( "$type" == "audio" || "$type" == "subtitle" ) ]] &&
           [[ "$type" != "subtitle" || "$(mkv_subtitle_action "$codec")" != "drop" ]]; then
            metas+=("-metadata:s:$out_n" "title=${handler[$idx]}")
            MAP_NOTES+=("stream $idx: MP4 track name \"${handler[$idx]}\" kept as MKV title")
        fi

        case "$type" in
            video)
                if (( att == 1 )); then
                    name=$(stream_tag "$file" "$idx" filename)
                    mime=$(stream_tag "$file" "$idx" mimetype)

                    case "$codec" in
                        mjpeg) [[ -n "$name" ]] || name="cover.jpg"; [[ -n "$mime" ]] || mime="image/jpeg" ;;
                        png)   [[ -n "$name" ]] || name="cover.png"; [[ -n "$mime" ]] || mime="image/png" ;;
                        bmp)   [[ -n "$name" ]] || name="cover.bmp"; [[ -n "$mime" ]] || mime="image/bmp" ;;
                        gif)   [[ -n "$name" ]] || name="cover.gif"; [[ -n "$mime" ]] || mime="image/gif" ;;
                        webp)  [[ -n "$name" ]] || name="cover.webp"; [[ -n "$mime" ]] || mime="image/webp" ;;
                    esac

                    if [[ -n "$name" && -n "$mime" ]]; then
                        MAP_COVERS+=("$idx"$'\t'"$name"$'\t'"$mime")
                        MAP_NOTES+=("stream $idx: cover art ($codec) kept as MKV attachment \"$name\"")
                    else
                        MAP_NOTES+=("stream $idx: attached picture ($codec) cannot be stored, dropped")
                    fi
                else
                    maps+=(-map "0:$idx")
                    ((out_n += 1))
                    MAP_NOTES+=("stream $idx: extra video ($codec) copied, not re-encoded")
                fi
                ;;
            audio)
                maps+=(-map "0:$idx")
                ((out_n += 1))
                ((MAP_AUDIO_COUNT += 1))
                ;;
            subtitle)
                case "$(mkv_subtitle_action "$codec")" in
                    copy)
                        maps+=(-map "0:$idx")
                        ((out_n += 1))
                        ((sub_n += 1))
                        ;;
                    srt)
                        maps+=(-map "0:$idx")
                        ((out_n += 1))
                        codecs+=("-c:s:$sub_n" srt)
                        MAP_NOTES+=("stream $idx: mov_text subtitle -> SRT (MKV cannot store mov_text; language/title/flags kept; $(movtext_note "$file" "$idx"))")
                        ((sub_n += 1))
                        ;;
                    *)
                        MAP_NOTES+=("stream $idx: $codec subtitle not supported in MKV, DROPPED")
                        ;;
                esac
                ;;
            attachment)
                maps+=(-map "0:$idx")
                ((out_n += 1))
                ;;
            data)
                MAP_NOTES+=("stream $idx: data stream ($codec) cannot be stored in MKV, DROPPED")
                ;;
            *)
                MAP_NOTES+=("stream $idx: $type ($codec) skipped")
                ;;
        esac
    done < <(stream_info "$file")

    MAP_ARGS=$(printf '%q ' "${maps[@]}")
    MAP_OTHER_ARGS=""
    (( ${#maps[@]} > 2 )) && MAP_OTHER_ARGS=$(printf '%q ' "${maps[@]:2}")
    MAP_CODEC_ARGS=""
    (( ${#codecs[@]} )) && MAP_CODEC_ARGS=$(printf '%q ' "${codecs[@]}")
    MAP_META_ARGS=""
    (( ${#metas[@]} )) && MAP_META_ARGS=$(printf '%q ' "${metas[@]}")
    return 0
}

# ------------------------------------------------------------
# Job script generation
# ------------------------------------------------------------

# emit_job_header SESSION TYPE ITEM_COUNT
emit_job_header() {
    echo '#!/usr/bin/env bash'
    echo '# Generated by the compress menus. Runs inside tmux.'
    echo 'set -uo pipefail'
    echo
    printf 'WORK_DIR=%q\n' "$WORK_DIR"
    echo 'source "$WORK_DIR/lib/media_probe.sh"'
    echo 'source "$WORK_DIR/lib/media_stats.sh"'
    echo 'source "$WORK_DIR/lib/bitrate.sh"'
    echo 'source "$WORK_DIR/lib/encode_common.sh"'
    echo 'source "$WORK_DIR/lib/hdr_dovi.sh"'
    echo 'source "$WORK_DIR/lib/job_runtime.sh"'
    echo
    printf 'job_init %q %q %q "$WORK_DIR"\n' "$1" "$2" "$3"
    echo
}

emit_job_footer() {
    echo 'job_crf_batch'
    echo 'job_finish'
}

# Ends a generated pass-2 ffmpeg command (output = "$ITEM_PART"),
# appends one item_add_cover step per MAP_COVERS entry and, for MKV
# sources, restores the full chapter structure (FFmpeg flattens it).
emit_part_and_covers() {
    local in="$1"
    local c idx name mime

    printf '      -f matroska "$ITEM_PART" &&\n'

    for ((c = 0; c < ${#MAP_COVERS[@]}; c++)); do
        IFS=$'\t' read -r idx name mime <<< "${MAP_COVERS[$c]}"
        printf '   item_add_cover %q %q %q %q &&\n' "$in" "$idx" "$name" "$mime"
    done

    printf '   item_step chapters item_restore_mkv_chapters %q\n' "$in"
}

# Shell-quoted ffmpeg options that give the main output video stream
# (v:0) the language, title and dispositions of source stream VIDX.
# Used when the video comes from a second input (Dolby Vision path).
source_video_tag_args() {
    local file="$1" vidx="$2"
    local idx type def forced comment hi vi lang title a=() d=()

    while IFS=$'\t' read -r idx type _ _ _ _ def forced comment hi vi _ lang title _ _; do
        [[ "$idx" == "$vidx" ]] || continue
        [[ "$lang" != "-" ]] && a+=(-metadata:s:v:0 "language=$lang")
        [[ "$title" != "-" ]] && a+=(-metadata:s:v:0 "title=$title")
        (( def == 1 )) && d+=(default)
        (( forced == 1 )) && d+=(forced)
        (( comment == 1 )) && d+=(comment)
        (( hi == 1 )) && d+=(hearing_impaired)
        (( vi == 1 )) && d+=(visual_impaired)
    done < <(stream_meta "$file")

    if (( ${#d[@]} )); then
        local IFS='+'
        a+=(-disposition:v:0 "${d[*]}")
    else
        a+=(-disposition:v:0 0)
    fi

    printf '%q ' "${a[@]}"
}

# emit_failed_item INDEX IN OUT TIER OVERWRITE REASON
emit_failed_item() {
    printf '# ---- item %s (not encoded)\n' "$1"
    printf 'if item_begin %q %q %q %q %q ""; then\n' "$1" "$2" "$3" "$4" "$5"
    printf '    item_failed %q\n' "$6"
    printf 'else\n'
    printf '    item_failed\n'
    printf 'fi\n\n'
}

# emit_encode_item INDEX IN OUT TIER VIDEO FILTER PASSLOG OVERWRITE [EST_VIDEO_BYTES [RETRY [QUALITY [CRF_EST]]]]
#
# VIDEO selects the video encode of the main video stream:
#   crf:N   single-pass libx265 CRF encode (movie Quality, High, Base, Custom;
#           series High, Base, Custom). No -b:v, no pass logs (PASSLOG is ignored).
#           EST_VIDEO_BYTES, the pre-encode estimate, is reported against
#           the actual size afterwards (never a failure).
#           RETRY "CEILING_BYTES:CRF_MAX:CRF_MIN:HEADROOM_PCT:DOWN_MAX[:batch[:FIT_PCT[:DOWN_MODE]]]"
#           (High / Base / Quality): an attempt whose actual VIDEO bytes are above
#           the ceiling is re-encoded at CRF + 1 up to CRF_MAX; one that
#           fits at least HEADROOM_PCT below the ceiling tries CRF - 1
#           (not below CRF_MIN, at most DOWN_MAX times; job_runtime.sh
#           item_crf_encode). FIT_PCT (High / Base): CRF - 1 only when
#           its predicted size (actual x CRF_EST ratio) stays FIT_PCT
#           below the ceiling. ":batch" (job scripts of earlier
#           versions): the episode joins a one-CRF season batch
#           (job_crf_batch); series episodes are now items of their own
#           (field empty). DOWN_MODE "boundary" (movie High / Base):
#           the first attempt that fits tests CRF - 1 exactly once, with
#           no headroom / FIT_PCT gate (job_runtime.sh). "" = no retry
#           (Custom).
#           CRF_EST "CRF=BYTES:..." the pre-encode estimates per CRF (for
#           the FIT_PCT prediction).
#           The encode commands are a function (item_encode_INDEX) so a
#           retry can run them again; they carry the planned CRF, which
#           item_run replaces for a retry attempt.
#           QUALITY "TARGET_BYTES:MIN_BYTES:MAX_BYTES:STATUS" (movie
#           Quality): the video target and acceptable band for the
#           report; STATUS band | source-limited. With "band" the
#           downward retry runs while the actual video is below
#           MIN_BYTES (instead of HEADROOM_PCT below the ceiling).
#   copy    the source video stream is kept unchanged (source-quality
#           guard: a CRF encode would not be smaller than the source).
#           FILTER must be empty.
#   KBPS    two-pass libx265 at KBPS kb/s (not used by the menus any more;
#           movie Quality is a CRF tier); PASSLOG is the
#           x265 stats file prefix. Pass 1 reads video only (-an -sn -dn).
#
# Every other stream is mapped explicitly (see build_stream_map). Every
# audio stream is copied unchanged (-c:a copy; no tier-dependent audio
# arguments) and verified afterwards (codec / layout / payload hash, see
# item_verify_output).
#
# Dolby Vision / HDR10+ follow DV_POLICY / HDR10P_POLICY (set by
# confirm_dynamic_range; see hdr_dovi.sh). Sources with Dolby Vision
# preserved use the RPU workflow; everything else uses a single ffmpeg
# encode + mux.
emit_encode_item() {
    local index="$1"
    local in="$2"
    local out="$3"
    local tier="$4"
    local video="$5"
    local filter="$6"
    local passlog="$7"
    local overwrite="$8"
    local est="${9:-}"
    local retry="${10:-}"
    local quality="${11:-}"
    local crf_est="${12:-}"

    local mode kbps="" crf="" rceil="" rmax="" rmin="" rdpct="" rdmax="" rbatch="" rfit="" rdmode=""
    local qtarget="" qmin="" qmax="" qstatus=""

    case "$video" in
        crf:*) mode="crf"; crf="${video#crf:}" ;;
        copy)  mode="copy" ;;
        *)     mode="abr"; kbps="$video" ;;
    esac

    # only two-pass encodes write x265 stats files
    [[ "$mode" == "abr" ]] || passlog=""
    [[ "$est" =~ ^[0-9]+$ ]] || est=""
    if [[ "$mode" == "crf" && -n "$retry" ]]; then
        IFS=: read -r rceil rmax rmin rdpct rdmax rbatch rfit rdmode <<< "$retry"
    fi
    if [[ "$mode" == "crf" && -n "$quality" ]]; then
        IFS=: read -r qtarget qmin qmax qstatus <<< "$quality"
    fi

    local vidx x265 color dv="" stale=""
    local dv_policy="none" h10p_policy="none" dv_out_profile="" dv_out_compat=""

    vidx=$(main_video_index "$in")
    probe_hdr "$in" "$vidx"
    build_stream_map "$in" "$vidx"

    if [[ "$mode" == "copy" ]]; then
        if [[ -n "$filter" ]]; then
            emit_failed_item "$index" "$in" "$out" "$tier" "$overwrite" \
                "the source video cannot be kept (stream copy) when it is scaled"
            return 0
        fi
        emit_copy_item "$index" "$in" "$out" "$tier" "$overwrite" "$vidx"
        return 0
    fi

    # ---- Dolby Vision / HDR10+ policy for this file
    if (( HDR_DV == 1 )); then
        dv_plan_source
        dv_policy="${DV_POLICY:-none}"

        if [[ "$dv_policy" == "preserve" && "$DV_SUPPORTED" != "1" ]]; then
            dv_policy="none"
        fi

        if [[ "$dv_policy" != "preserve" && "$dv_policy" != "drop" ]]; then
            emit_failed_item "$index" "$in" "$out" "$tier" "$overwrite" \
                "Dolby Vision profile ${HDR_DV_PROFILE:-?} found but no preservation policy was chosen"
            return 0
        fi

        if [[ "$dv_policy" == "preserve" ]]; then
            dv_out_profile="${DV_OUT%%.*}"
            dv_out_compat="${DV_OUT#*.}"
        fi
    fi

    if (( HDR_HDR10PLUS == 1 )); then
        h10p_policy="${HDR10P_POLICY:-none}"

        if [[ "$h10p_policy" != "preserve" && "$h10p_policy" != "drop" ]]; then
            emit_failed_item "$index" "$in" "$out" "$tier" "$overwrite" \
                "HDR10+ found but no preservation policy was chosen"
            return 0
        fi
    fi

    x265=$(x265_color_params)
    color=$(color_output_args)

    # Never let libx265 write a Dolby Vision RPU itself (FFmpeg >= 7.1
    # defaults this to auto): RPUs are re-injected by dovi_tool and
    # verified, or intentionally dropped.
    if libx265_has_option dolbyvision; then
        dv="-dolbyvision:v:0 0 "
    fi

    # rate:   rate-control options of the video encode
    # p1q/pq: shell-quoted -x265-params value of pass 1 / the final encode
    #         ("" = no -x265-params)
    local rate p1q="" pq="" vf="" label
    local h10p_arg='dhdr10-info=$ITEM_TMP/hdr10plus.json'

    if [[ "$mode" == "abr" ]]; then
        rate="-b:v:0 ${kbps}k"
        label="2/2"
        p1q=$(printf '%q' "pass=1:stats=$passlog${x265:+:$x265}")
        pq=$(printf '%q' "pass=2:stats=$passlog${x265:+:$x265}")
        if [[ "$h10p_policy" == "preserve" ]]; then
            p1q+="\":$h10p_arg\""
            pq+="\":$h10p_arg\""
        fi
    else
        rate="-crf:v:0 $(printf '%q' "$crf")"
        label="encode"
        [[ -n "$x265" ]] && pq=$(printf '%q' "$x265")
        if [[ "$h10p_policy" == "preserve" ]]; then
            pq+="\"${x265:+:}$h10p_arg\""
        fi
    fi

    [[ -n "$filter" ]] && vf="-filter:v:0 $(printf '%q' "$filter") "

    # Stale statistics of the re-encoded video (refreshed after the mux;
    # copied audio keeps correct statistics).
    stale=$(stale_stats_args v:0)

    local scaled=0
    [[ -n "$filter" ]] && scaled=1

    local begin expect steps=()

    begin=$(printf 'item_begin %q %q %q %q %q %q' \
        "$index" "$in" "$out" "$tier" "$overwrite" "$passlog")
    # atrans= (empty): no audio track is transcoded; ahash=1: the copied
    # audio payload is hash-compared with the source. ceiling_vbytes /
    # crf_min / crf_max: the CRF retry (High / Base; empty = none).
    expect=$(printf 'item_expect vidx=%q mode=%q crf=%q kbps=%q est_vbytes=%q dv=%q dv_profile=%q dv_compat=%q hdr10p=%q scaled=%q copyts=%q atrans= ahash=1' \
        "$vidx" "$mode" "$crf" "$kbps" "$est" \
        "$( (( HDR_DV == 1 )) && echo "$dv_policy" || echo none)" \
        "$dv_out_profile" "$dv_out_compat" "$h10p_policy" "$scaled" \
        "$( [[ "$dv_policy" == "preserve" ]] && echo 1 || echo 0)")
    [[ "$mode" == "crf" ]] &&
        expect+=$(printf ' ceiling_vbytes=%q crf_min=%q crf_max=%q down_headroom_pct=%q down_max=%q' "$rceil" "$rmin" "$rmax" "$rdpct" "$rdmax")
    [[ "$mode" == "crf" && -n "$qtarget" ]] &&
        expect+=$(printf ' qtarget_vbytes=%q qmin_vbytes=%q qmax_vbytes=%q qstatus=%q' "$qtarget" "$qmin" "$qmax" "${qstatus:-band}")
    [[ "$mode" == "crf" && -n "$qtarget" && "${qstatus:-band}" == band ]] &&
        expect+=$(printf ' down_below_vbytes=%q' "$qmin")
    # High / Base: lower CRF only when predicted to fit (job_runtime.sh)
    [[ "$mode" == "crf" && -n "$rfit" ]] &&
        expect+=$(printf ' down_fit_pct=%q' "$rfit")
    # movie High / Base: one CRF - 1 test after the first fit (job_runtime.sh)
    [[ "$mode" == "crf" && "$rdmode" == boundary ]] &&
        expect+=' down_mode=boundary'
    [[ "$mode" == "crf" && "$crf_est" =~ ^[0-9.]+=[0-9]+(:[0-9.]+=[0-9]+)*$ ]] &&
        expect+=$(printf ' crf_est=%q' "$crf_est")

    # CRF-independent preparation (run once, not per CRF attempt)
    [[ "$dv_policy" == "preserve" ]] &&
        steps+=("$(printf 'item_step rpu item_dv_extract %q %q %q' "$in" "$vidx" "$DV_MODE")")
    [[ "$h10p_policy" == "preserve" ]] &&
        steps+=("$(printf 'item_step hdr10+ item_hdr10plus_extract %q %q' "$in" "$vidx")")

    printf '# ---- item %s%s\n' "$index" \
        "$( [[ "$dv_policy" == "preserve" ]] && echo "  (Dolby Vision profile ${HDR_DV_PROFILE} -> $DV_OUT preserved)")$( [[ "$rbatch" == batch ]] && echo "  (season CRF batch: job_crf_batch)")"

    if [[ "$mode" == "crf" ]]; then
        # the final encode as a function: a CRF retry runs it again
        printf 'item_encode_%s() {\n' "$index"
        _emit_final_encode
        printf '}\n'
    fi

    if [[ "$rbatch" == batch ]]; then
        printf 'item_ctx_%s() {\n' "$index"
        printf '   %s &&\n' "$begin"
        printf '   %s\n' "$expect"
        printf '}\n'
        printf 'item_prep_%s() {\n' "$index"
        if (( ${#steps[@]} )); then
            local i
            for ((i = 0; i < ${#steps[@]}; i++)); do
                printf '   %s%s\n' "${steps[$i]}" "$( (( i + 1 < ${#steps[@]} )) && echo ' &&')"
            done
        else
            printf '   :\n'
        fi
        printf '}\n'
        printf 'job_batch_add %s\n\n' "$index"
        return 0
    fi

    printf 'if %s &&\n' "$begin"
    printf '   %s &&\n' "$expect"
    local s
    for s in "${steps[@]+"${steps[@]}"}"; do
        printf '   %s &&\n' "$s"
    done

    if [[ "$mode" == "abr" ]]; then
        # Pass 1 is the same for every path (the DV path only pins the
        # frame sequence so that frames and RPUs stay 1:1).
        printf '   item_run 1/2 ffmpeg -y -i %q \\\n' "$in"
        printf '      -map 0:%s %s\\\n' "$vidx" "$vf"
        _emit_x265_lines "$rate" "$dv" "$p1q" "$color"
        [[ "$dv_policy" == "preserve" ]] && printf '      -fps_mode:v:0 passthrough \\\n'
        printf '      -an -sn -dn -f null /dev/null &&\n'
        _emit_final_encode
    else
        printf '   item_crf_encode item_encode_%s\n' "$index"
    fi

    printf 'then\n'
    printf '    item_succeeded\n'
    printf 'else\n'
    printf '    item_failed\n'
    printf 'fi\n\n'
}

# _emit_final_encode  ->  the final encode + mux of emit_encode_item
# into "$ITEM_PART" (covers, chapters); reads emit_encode_item's locals
_emit_final_encode() {
    if [[ "$dv_policy" == "preserve" ]]; then
        # Final encode -> raw HEVC, RPU injected, wrapped by mkvmerge (DV
        # configuration record + source timestamps), then the same mux
        # as the normal path with the video taken from the wrapped file.
        printf '   item_run %s ffmpeg -y -i %q \\\n' "$label" "$in"
        printf '      -map 0:%s %s\\\n' "$vidx" "$vf"
        _emit_x265_lines "$rate" "$dv" "$pq" "$color"
        printf '      -fps_mode:v:0 passthrough -an -sn -dn -f hevc "$ITEM_TMP/video.hevc" &&\n'

        printf '   item_step dv-inject item_dv_inject %s &&\n' "$(get_resolution "$in" "$vidx" | tr x ' ')"
        printf '   item_step dv-wrap item_dv_wrap %s&&\n' "$(dv_mkvmerge_hdr_args)"

        printf '   item_run mux ffmpeg -y -copyts -i %q -i "$ITEM_TMP/video_dv.mkv" \\\n' "$in"
        printf '      -map 1:0 %s\\\n' "$MAP_OTHER_ARGS"
        printf '      -c copy %s-c:a copy \\\n' "$MAP_CODEC_ARGS"
        printf '      %s\\\n' "$(source_video_tag_args "$in" "$vidx")"
    else
        printf '   item_run %s ffmpeg -y -i %q \\\n' "$label" "$in"
        printf '      %s\\\n' "$MAP_ARGS"
        printf '      -c copy %s-c:a copy \\\n' "$MAP_CODEC_ARGS"
        [[ -n "$vf" ]] && printf '      %s\\\n' "$vf"
        _emit_x265_lines "$rate" "$dv" "$pq" "$color"
    fi

    [[ -n "$MAP_META_ARGS" ]] && printf '      %s\\\n' "$MAP_META_ARGS"
    printf '      %s\\\n' "$stale"
    printf '      -map_metadata 0 -map_chapters 0 -max_muxing_queue_size 4096 %s\\\n' "$(matroska_mux_args)"
    emit_part_and_covers "$in"
}

# _emit_x265_lines RATE DV X265_PARAMS_QUOTED COLOR  ->  the libx265
# option lines of a generated ffmpeg command
_emit_x265_lines() {
    printf '      -c:v:0 libx265 -preset %s %s -pix_fmt:v:0 yuv420p10le %s\\\n' "$X265_PRESET" "$1" "$2"
    if [[ -n "$3" ]]; then
        printf '      -x265-params:v:0 %s %s\\\n' "$3" "$4"
    elif [[ -n "$4" ]]; then
        printf '      %s\\\n' "$4"
    fi
}

# emit_copy_item INDEX IN OUT TIER OVERWRITE VIDX
#
# Source-quality guard: the main video stream is copied unchanged (no
# lossy re-encode that would not be smaller than the source). Everything
# else is handled exactly like an encode item: all audio copied and
# hash-verified, subtitles / attachments / covers / chapters / metadata
# kept. Dolby Vision and HDR10+ stay in the copied stream (verified).
emit_copy_item() {
    local index="$1" in="$2" out="$3" tier="$4" overwrite="$5" vidx="$6"

    printf '# ---- item %s  (source video kept: stream copy)\n' "$index"
    printf 'if item_begin %q %q %q %q %q "" &&\n' "$index" "$in" "$out" "$tier" "$overwrite"
    printf '   item_expect vidx=%q video=copy mode=copy dv=none hdr10p=none scaled=0 copyts=0 atrans= ahash=1 &&\n' "$vidx"
    printf '   item_run mux ffmpeg -y -i %q \\\n' "$in"
    printf '      %s\\\n' "$MAP_ARGS"
    printf '      -c copy %s-c:a copy \\\n' "$MAP_CODEC_ARGS"
    [[ -n "$MAP_META_ARGS" ]] && printf '      %s\\\n' "$MAP_META_ARGS"
    printf '      -map_metadata 0 -map_chapters 0 -max_muxing_queue_size 4096 %s\\\n' "$(matroska_mux_args)"
    emit_part_and_covers "$in"
    printf 'then\n'
    printf '    item_succeeded\n'
    printf 'else\n'
    printf '    item_failed\n'
    printf 'fi\n\n'
}

# start_job SESSION JOB_FILE  ->  syntax-check and launch in tmux
start_job() {
    local session="$1"
    local job="$2"

    chmod +x "$job"

    if ! bash -n "$job"; then
        echo "Generated job failed the syntax check: $job"
        return 1
    fi

    tmux new-session -d -s "$session" "bash $(printf '%q' "$job")"
}
