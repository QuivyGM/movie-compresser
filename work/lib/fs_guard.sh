#!/usr/bin/env bash
# Directory layout and disk-space guards for the compress menus.
# Sourced, not executed. Safe under `set -euo pipefail`.
#
# ~/compress/{in,out,work} may be real directories or symlinks to
# directories on other disks. These helpers never remove, rename or
# replace any of them: a missing directory is created, a valid symlink
# is used as it is, anything else (broken symlink, symlink to a file,
# regular file) stops the menu with an explanation.
#
# Optional pin file ~/compress/paths.conf (not tracked by Git):
#
#     # name=directory it must resolve to
#     work=/dev/disk2/asimov/compress/work
#     out=/dev/disk2/asimov/compress/out
#
# With a pin, the menu refuses to start when ~/compress/NAME no longer
# resolves to that directory, e.g. after `git checkout -- work`,
# `git restore work` or `git reset --hard` in the ~/compress checkout
# replaced a symlinked work/ by a regular directory on the home disk.
#
# work/ holds tracked code: a symlinked work/ is replaced by any of the
# git commands above. To keep the large intermediates on another disk
# without that risk, keep work/ a regular directory and symlink only the
# gitignored work/logs/ (where the intermediates are written).
#
# Before a job is started, compress_space_preflight checks that out/
# and work/ are writable and have room for the planned outputs and the
# intermediates (Dolby Vision raw HEVC in work/logs/).

_fsg_err() { echo "ERROR: $*" >&2; }

# compress_paths_conf BASE  ->  path of the optional pin file
compress_paths_conf() {
    printf '%s\n' "${COMPRESS_PATHS_CONF:-$1/paths.conf}"
}

# _fsg_pin BASE NAME  ->  the pinned directory of NAME ("" = none)
_fsg_pin() {
    local conf line key val
    conf=$(compress_paths_conf "$1")
    [[ -f "$conf" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key//[[:space:]]/}"
        if [[ "$key" == "$2" ]]; then
            printf '%s\n' "$val"
            return 0
        fi
    done < "$conf"
}

# compress_dir_ready DIR NAME [rw]
#
# 0 when DIR can be used as the NAME (in / out / work) directory: an
# existing directory or a symlink to one (kept as it is), or created when
# nothing exists at DIR. rw: DIR must also be writable (a probe file is
# created and removed). Never replaces or removes anything at DIR.
compress_dir_ready() {
    local dir="$1" name="$2" mode="${3:-}" pin real want probe

    if [[ -L "$dir" ]]; then
        if [[ ! -e "$dir" ]]; then
            _fsg_err "$dir is a broken symlink (-> $(readlink -- "$dir"))."
            _fsg_err "Is its disk mounted? It is left unchanged: no local '$name' directory is created in its place."
            return 1
        fi
        if [[ ! -d "$dir" ]]; then
            _fsg_err "$dir is a symlink to something that is not a directory (-> $(readlink -- "$dir"))."
            return 1
        fi
    elif [[ -e "$dir" ]]; then
        if [[ ! -d "$dir" ]]; then
            _fsg_err "$dir exists but is not a directory."
            return 1
        fi
    elif ! mkdir -p -- "$dir"; then
        _fsg_err "could not create $dir."
        return 1
    fi

    pin=$(_fsg_pin "$(dirname -- "$dir")" "$name")
    if [[ -n "$pin" ]]; then
        real=$(readlink -f -- "$dir")
        want=$(readlink -f -- "$pin" 2>/dev/null || printf '%s' "$pin")
        if [[ ! -d "$pin" ]]; then
            _fsg_err "$(compress_paths_conf "$(dirname -- "$dir")") pins '$name' to $pin, which is not an existing directory (disk not mounted?)."
            return 1
        fi
        if [[ "$real" != "$want" ]]; then
            _fsg_err "$dir resolves to $real,"
            _fsg_err "but $(compress_paths_conf "$(dirname -- "$dir")") pins '$name' to $want."
            if [[ ! -L "$dir" ]]; then
                _fsg_err "$dir is now a regular directory: a 'git checkout/restore/reset' of the"
                _fsg_err "checkout replaces a symlinked tracked directory this way. Move anything you"
                _fsg_err "need out of it, then recreate the link:  ln -sfn -- '$want' '$dir'"
            fi
            return 1
        fi
    fi

    if [[ "$mode" == rw ]]; then
        if ! probe=$(mktemp "$dir/.write-test.XXXXXX" 2>/dev/null); then
            _fsg_err "$dir is not writable."
            return 1
        fi
        rm -f -- "$probe"
    fi
    return 0
}

# compress_dirs_init BASE NAME[:rw]...  ->  compress_dir_ready for each
# BASE/NAME (all are checked, every problem is reported); 1 on any problem
compress_dirs_init() {
    local base="$1" spec rc=0
    shift
    for spec; do
        compress_dir_ready "$base/${spec%%:*}" "${spec%%:*}" \
            "$( [[ "$spec" == *:rw ]] && echo rw)" || rc=1
    done
    return "$rc"
}

# ------------------------------------------------------------
# Disk space
# ------------------------------------------------------------

# fs_info DIR  ->  "FILESYSTEM<TAB>MOUNT<TAB>AVAILABLE_BYTES" of the
# filesystem holding DIR (symlinks followed); 1 when df cannot tell
fs_info() {
    local line
    line=$(df -P -k -- "$1/." 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ {
        m = $6; for (i = 7; i <= NF; i++) m = m " " $i
        printf "%s\t%s\t%.0f\n", $1, m, $4 * 1024 }')
    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line"
}

# item_output_estimate FILE_BYTES SOURCE_VIDEO_BYTES [EST_VIDEO_BYTES]
#   ->  expected output size: the source minus its video plus the
#       estimated video (the source video when no estimate: stream copy)
item_output_estimate() {
    awk -v f="${1:-0}" -v sv="${2:-}" -v ev="${3:-}" 'BEGIN {
        if (f !~ /^[0-9]+$/) f = 0
        if (ev !~ /^[0-9]+$/) ev = ""
        if (sv !~ /^[0-9]+$/ || sv + 0 > f + 0) {
            # source video size unknown: never below the source
            printf "%.0f", (ev != "" && ev + 0 > f + 0) ? ev : f; exit
        }
        printf "%.0f", f - sv + (ev != "" ? ev : sv) }'
}

# item_work_estimate DV_PRESERVE VIDEO_BYTES  ->  peak work/ scratch of
# one item: a Dolby Vision encode keeps two raw copies of the video at
# once (video.hevc + video_dv.hevc, then video_dv.hevc + video_dv.mkv)
item_work_estimate() {
    awk -v d="${1:-0}" -v v="${2:-0}" 'BEGIN {
        if (v !~ /^[0-9]+$/) v = 0
        printf "%.0f", (d == 1) ? 2 * v : 0 }'
}

# _fsg_required BYTES  ->  BYTES + 5 % + the fixed margin
# (COMPRESS_SPACE_MARGIN_GIB, default 1: logs, samples, statistics)
_fsg_required() {
    awk -v b="${1:-0}" -v m="${COMPRESS_SPACE_MARGIN_GIB:-1}" 'BEGIN {
        if (m !~ /^[0-9.]+$/) m = 1
        printf "%.0f", b * 1.05 + m * 1073741824 }'
}

_fsg_gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

# compress_space_preflight OUT_DIR OUT_FINAL OUT_PEAK WORK_DIR WORK_PEAK
#
# OUT_FINAL: bytes of all planned outputs; OUT_PEAK: with the CRF retry
# attempts kept next to them; WORK_PEAK: largest intermediate set of one
# item in WORK_DIR (logs/). When OUT_DIR and WORK_DIR share a filesystem
# their needs are added. Prints one line per filesystem (where it is,
# free, needed) and returns
#   0  enough room for the peak
#   2  room for the outputs but maybe not for the CRF retry attempts
#   1  not enough room even for the outputs and intermediates (or a
#      directory is not writable / df failed)
# COMPRESS_SPACE_CHECK=warn reports a shortage without failing (0).
compress_space_preflight() {
    local out="$1" ofin="$2" opeak="$3" work="$4" wpeak="$5"
    local oi wi ofs omnt oavail wfs wmnt wavail need peak rc=0 r

    compress_dir_ready "$out" out rw || return 1
    compress_dir_ready "$work" work rw || return 1

    # the intermediates live in work/logs/, which may itself be a symlink
    # (gitignored, so a git checkout of work/ never replaces it)
    if [[ -e "$work/logs" || -L "$work/logs" ]]; then
        compress_dir_ready "$work/logs" logs rw || return 1
        work="$work/logs"
    fi

    if ! oi=$(fs_info "$out") || ! wi=$(fs_info "$work"); then
        _fsg_err "could not read the free space of $out / $work (df)."
        [[ "${COMPRESS_SPACE_CHECK:-}" == warn ]] && return 0
        return 1
    fi
    IFS=$'\t' read -r ofs omnt oavail <<< "$oi"
    IFS=$'\t' read -r wfs wmnt wavail <<< "$wi"

    echo "Disk space:"
    if [[ "$ofs" == "$wfs" && "$omnt" == "$wmnt" ]]; then
        need=$(_fsg_required "$((ofin + wpeak))")
        peak=$(_fsg_required "$((opeak + wpeak))")
        printf '  out   %s\n' "$(readlink -f -- "$out")"
        printf '  work  %s\n' "$(readlink -f -- "$work")"
        printf '  same filesystem %s: %s GiB free, needs ~%s GiB%s\n' \
            "$omnt" "$(_fsg_gib "$oavail")" \
            "$(_fsg_gib "$need")" "$( (( peak > need )) && echo " (~$(_fsg_gib "$peak") GiB with CRF retries)")"
        r=$(_fsg_check "$oavail" "$need" "$peak") || rc=$?
        _fsg_report "$r" "$omnt"
    else
        need=$(_fsg_required "$ofin")
        peak=$(_fsg_required "$opeak")
        printf '  out   %s (filesystem %s): %s GiB free, needs ~%s GiB%s\n' \
            "$(readlink -f -- "$out")" "$omnt" "$(_fsg_gib "$oavail")" \
            "$(_fsg_gib "$need")" "$( (( peak > need )) && echo " (~$(_fsg_gib "$peak") GiB with CRF retries)")"
        r=$(_fsg_check "$oavail" "$need" "$peak") || rc=$?
        _fsg_report "$r" "$omnt"

        need=$(_fsg_required "$wpeak")
        printf '  work  %s (filesystem %s): %s GiB free, needs ~%s GiB\n' \
            "$(readlink -f -- "$work")" "$wmnt" "$(_fsg_gib "$wavail")" "$(_fsg_gib "$need")"
        r=$(_fsg_check "$wavail" "$need" "$need") || { (( $? == 1 )) && rc=1; }
        _fsg_report "$r" "$wmnt"
    fi

    if (( rc != 0 )) && [[ "${COMPRESS_SPACE_CHECK:-}" == warn ]]; then
        echo "  (COMPRESS_SPACE_CHECK=warn: continuing anyway)"
        return 0
    fi
    return "$rc"
}

# _fsg_check AVAIL NEED PEAK  ->  prints ok | tight | short; 0 / 2 / 1
_fsg_check() {
    if (( $1 < $2 )); then echo short; return 1; fi
    if (( $1 < $3 )); then echo tight; return 2; fi
    echo ok
}

_fsg_report() {
    case "$1" in
        short) echo "  NOT ENOUGH SPACE on $2: the encode would fail when the disk fills up." ;;
        tight) echo "  WARNING: $2 may run out of space if CRF retry attempts are needed." ;;
    esac
    return 0
}

# compress_space_confirm OUT_DIR OUT_FINAL OUT_PEAK WORK_DIR WORK_PEAK
#   ->  compress_space_preflight; a shortage cancels (1), a possible
#       shortage of the CRF retry attempts asks for confirmation
compress_space_confirm() {
    local rc=0 ans

    compress_space_preflight "$@" || rc=$?
    case "$rc" in
        0) return 0 ;;
        2)
            read -rp "Start anyway? [y/N]: " ans || ans=""
            [[ "$ans" =~ ^[Yy]$ ]] && return 0
            echo "Compression cancelled."
            return 1
            ;;
        *)
            echo "Free some space or point the directory to a larger disk (symlink), then run the menu again."
            echo "Compression cancelled."
            return 1
            ;;
    esac
}

# bytes_sum N...  /  bytes_max N...  (non-numbers count as 0)
bytes_sum() { printf '%s\n' "$@" | awk '$1 ~ /^[0-9]+$/ { s += $1 } END { printf "%.0f", s }'; }
bytes_max() { printf '%s\n' "$@" | awk '$1 ~ /^[0-9]+$/ && $1 + 0 > m { m = $1 + 0 } END { printf "%.0f", m }'; }
