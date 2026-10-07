#!/usr/bin/env bash
# Media probing helpers (ffprobe based). Sourced, not executed.
# Safe under `set -euo pipefail`: probes that may legitimately find
# nothing end with `|| true`.

# ------------------------------------------------------------
# File discovery (shared by every menu and verify.sh)
#
# Regular files and symbolic links are both accepted; symlinks are
# followed (find -L), never modified. Rules:
#   - one entry per real target: when a regular path and a symlink (or
#     several symlinks) lead to the same file/directory, the regular
#     path is kept; among symlinks only, the first in sort order
#   - broken symlinks are skipped with a warning
#   - circular directory symlinks are skipped with a warning (find -L
#     detects the loop, so recursion always ends)
# Warnings go to stderr; DISCOVERY_QUIET=1 silences them (used for
# repeated scans of the same directory).
# ------------------------------------------------------------

MOVIE_EXTS=(mkv mp4 m4v)
MEDIA_EXTS=(mkv mp4 m4v mov avi ts m2ts webm)

_discovery_warn() {
    [[ "${DISCOVERY_QUIET:-0}" == "1" ]] || echo "WARNING: $*" >&2
}

# _discovery_is_real PATH ROOT CANON_ROOT
# True when PATH below ROOT goes through no symlink (its resolved path
# is the canonical root plus the same relative path).
_discovery_is_real() {
    local rel="${1#"$2"/}"
    [[ "$(readlink -f -- "$1")" == "$3/$rel" ]]
}

# discover_paths ROOT MAXDEPTH TYPE EXT...
#
# NUL-separated, sorted, de-duplicated paths below ROOT. MAXDEPTH ""
# means unlimited. TYPE f (files, EXT filter) or d (directories). Paths
# keep the names they were found under (ROOT/... , symlink names
# included); content is always read through them.
discover_paths() {
    local root="${1%/}" depth="$2" type="$3"
    shift 3

    local canon_root err line p kind canon cur
    local names=() opts=()
    local -A pick=() real=()

    [[ -d "$root" ]] || return 0
    canon_root=$(readlink -f -- "$root")

    if (( $# )); then
        local e first=1
        names+=("(")
        for e; do
            (( first )) || names+=(-o)
            names+=(-iname "*.$e")
            first=0
        done
        names+=(")")
    fi

    [[ -n "$depth" ]] && opts+=(-maxdepth "$depth")

    err=$(mktemp)

    while IFS= read -r -d '' line; do
        kind="${line%% *}"
        p="${line#* }"

        if [[ "$kind" == "l" ]]; then
            _discovery_warn "broken symlink skipped: $p -> $(readlink -- "$p")"
            continue
        fi

        [[ "$kind" == "$type" ]] || continue

        canon=$(readlink -f -- "$p") || continue

        if [[ "$type" == "d" ]]; then
            # a directory symlink leading to the root or one of its
            # parents is a loop, not a separate folder
            if [[ "$canon_root" == "$canon" || "$canon_root" == "$canon"/* ]]; then
                _discovery_warn "circular directory symlink skipped: $p -> $(readlink -- "$p")"
                continue
            fi
        fi

        cur="${pick[$canon]:-}"

        if [[ -z "$cur" ]]; then
            pick[$canon]="$p"
            _discovery_is_real "$p" "$root" "$canon_root" && real[$canon]=1
        elif [[ -z "${real[$canon]:-}" ]] && _discovery_is_real "$p" "$root" "$canon_root"; then
            # prefer the regular entry over a symlink to the same target
            pick[$canon]="$p"
            real[$canon]=1
        elif [[ -z "${real[$canon]:-}" && "$p" < "$cur" ]]; then
            pick[$canon]="$p"
        fi
    done < <(
        find -L "$root" -mindepth 1 "${opts[@]+"${opts[@]}"}" \
            \( -type "$type" -o -type l \) "${names[@]+"${names[@]}"}" \
            -printf '%y %p\0' 2> "$err"
    )

    while IFS= read -r line; do
        case "$line" in
            *"File system loop detected"*)
                # "find: File system loop detected; 'X' is part of ..."
                p=$(sed -E "s/^.*detected; [‘'\`]([^’']*)[’'].*$/\1/" <<< "$line")
                _discovery_warn "circular directory symlink skipped: $p"
                ;;
            *)
                [[ -n "$line" ]] && _discovery_warn "${line#find: }"
                ;;
        esac
    done < "$err"
    rm -f -- "$err"

    for p in "${pick[@]+"${pick[@]}"}"; do
        printf '%s\0' "$p"
    done | sort -z
}

# video_files_in_dir DIR  ->  movie/episode files directly in DIR,
# one per line, sorted
video_files_in_dir() {
    discover_paths "$1" 1 f "${MOVIE_EXTS[@]}" | tr '\0' '\n'
}

# All media files below a root, recursively, NUL separated and sorted.
media_files_recursive() {
    discover_paths "$1" "" f "${MEDIA_EXTS[@]}"
}

# series_dirs ROOT  ->  folders (or folder symlinks) directly in ROOT
# that contain movie/episode files, one per line, sorted
series_dirs() {
    local d

    while IFS= read -r -d '' d; do
        if [[ -n "$(DISCOVERY_QUIET=1 video_files_in_dir "$d" | head -n 1)" ]]; then
            printf '%s\n' "$d"
        fi
    done < <(discover_paths "$1" 1 d)
}

# file_bytes FILE  ->  size of the file (of the target for a symlink)
file_bytes() {
    stat -L -c %s -- "$1"
}

media_signature() {
    ffprobe -v error \
        -show_entries \
'stream=index,codec_type,codec_name,width,height,pix_fmt,r_frame_rate,color_space,color_transfer,color_primaries,channels,channel_layout,sample_rate' \
        -of compact=p=0:nk=0 \
        "$1"
}

# x265_rate_control FILE STREAM_INDEX  ->  how x265 encoded the stream,
# from the settings SEI x265 writes into the first access unit:
#   "crf 21.0"     single-pass CRF
#   "2pass 15000"  two-pass bitrate (kb/s)
#   "abr 15000"    one-pass bitrate (kb/s)
#   ""             not x265, or no settings SEI
x265_rate_control() {
    ffmpeg -v error -nostdin -i "$1" -map "0:$2" -c copy -frames:v 1 -f hevc - 2>/dev/null |
        head -c 4000000 | tr -c '[:print:]' '\n' | grep -m1 -o 'rc=[a-z]*.*' |
        tr ' ' '\n' | awk -F= '
            $1 == "rc" { rc = $2 }
            $1 == "crf" { crf = $2 }
            $1 == "bitrate" { br = $2 }
            $1 == "stats-read" { sr = $2 }
            END {
                if (rc == "crf") print "crf " crf
                else if (rc == "abr" && sr >= 2) print "2pass " br
                else if (rc != "") print rc " " br
            }'
    return 0
}

get_duration() {
    ffprobe -v error \
        -show_entries format=duration \
        -of default=nw=1:nk=1 \
        "$1"
}

# get_resolution FILE [STREAM_INDEX]  ->  WIDTHxHEIGHT
get_resolution() {
    ffprobe -v error \
        -select_streams "${2:-v:0}" \
        -show_entries stream=width,height \
        -of csv=s=x:p=0 \
        "$1" |
    # newer ffprobe appends an empty field for streams with side data
    head -n 1 | sed 's/x*$//'
}

get_audio_channels() {
    ffprobe -v error \
        -select_streams a \
        -show_entries stream=channels \
        -of csv=p=0 \
        "$1"
}

# stream_info FILE
#
# One TSV line per stream, in file order:
#   index type codec attached_pic channels channel_layout sample_rate
#   width height pix_fmt r_frame_rate color_primaries color_transfer
#   color_space
# Missing values are "-".
stream_info() {
    ffprobe -v error \
        -show_entries \
'stream=index,codec_type,codec_name,channels,channel_layout,sample_rate,width,height,pix_fmt,r_frame_rate,color_primaries,color_transfer,color_space:stream_disposition=attached_pic' \
        -of compact=p=0:nk=0 \
        "$1" |
    awk -F'|' '
        function g(k) { return (k in f && f[k] != "" && f[k] != "unknown") ? f[k] : "-" }
        {
            split("", f)
            for (i = 1; i <= NF; i++) {
                p = index($i, "=")
                if (p) f[substr($i, 1, p - 1)] = substr($i, p + 1)
            }
            att = ("disposition:attached_pic" in f) ? f["disposition:attached_pic"] + 0 : 0
            printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                g("index"), g("codec_type"), g("codec_name"), att,
                g("channels"), g("channel_layout"), g("sample_rate"),
                g("width"), g("height"), g("pix_fmt"), g("r_frame_rate"),
                g("color_primaries"), g("color_transfer"), g("color_space")
        }'
}

# main_video_index FILE  ->  absolute index of the first real video stream
# (cover art / attached pictures are skipped). Empty if none.
main_video_index() {
    stream_info "$1" |
    awk -F'\t' '$2 == "video" && $4 == 0 { print $1; exit }' || true
}

# probe_hdr FILE STREAM_INDEX
#
# Sets globals describing the dynamic range of one video stream:
#   HDR_CODEC       codec name of the stream
#   HDR_PRIMARIES HDR_TRANSFER HDR_MATRIX HDR_RANGE  (ffmpeg names or "")
#   HDR_CHROMALOC   chroma sample location (ffmpeg name or "")
#   HDR_KIND        SDR | HDR10 | HLG
#   HDR_MASTER      x265 master-display string, or ""
#   HDR_CLL         x265 max-cll "MaxCLL,MaxFALL", or ""
#   HDR_HDR10PLUS   1 if HDR10+ (SMPTE ST 2094-40) frame metadata exists
#   HDR_DV          1 if a Dolby Vision configuration record exists
#   HDR_DV_PROFILE  DV profile, HDR_DV_COMPAT  base-layer compatibility id
#   HDR_DV_LEVEL    DV level
#   HDR_DV_RPU HDR_DV_EL HDR_DV_BL  rpu/el/bl present flags ("" if unknown)
#
# Stream-level side data is preferred; the first decoded frames are used
# as a fallback (HEVC SEI). HDR10+ only exists per frame.
probe_hdr() {
    local file="$1"
    local idx="$2"
    local k v

    HDR_CODEC=""
    HDR_PRIMARIES=""
    HDR_TRANSFER=""
    HDR_MATRIX=""
    HDR_RANGE=""
    HDR_CHROMALOC=""
    HDR_KIND="SDR"
    HDR_MASTER=""
    HDR_CLL=""
    HDR_HDR10PLUS=0
    HDR_DV=0
    HDR_DV_PROFILE=""
    HDR_DV_COMPAT=""
    HDR_DV_LEVEL=""
    HDR_DV_RPU=""
    HDR_DV_EL=""
    HDR_DV_BL=""

    while IFS='=' read -r k v; do
        case "$k" in
            codec)      HDR_CODEC="$v" ;;
            primaries)  HDR_PRIMARIES="$v" ;;
            transfer)   HDR_TRANSFER="$v" ;;
            matrix)     HDR_MATRIX="$v" ;;
            range)      HDR_RANGE="$v" ;;
            chromaloc)  HDR_CHROMALOC="$v" ;;
            master)     HDR_MASTER="$v" ;;
            cll)        HDR_CLL="$v" ;;
            hdr10plus)  HDR_HDR10PLUS="$v" ;;
            dv)         HDR_DV="$v" ;;
            dv_profile) HDR_DV_PROFILE="$v" ;;
            dv_compat)  HDR_DV_COMPAT="$v" ;;
            dv_level)   HDR_DV_LEVEL="$v" ;;
            dv_rpu)     HDR_DV_RPU="$v" ;;
            dv_el)      HDR_DV_EL="$v" ;;
            dv_bl)      HDR_DV_BL="$v" ;;
        esac
    done < <(
        {
            ffprobe -v error -select_streams "$idx" \
                -show_streams -of default=nw=0 "$file" 2>/dev/null || true
            echo "[FRAME_SECTION]"
            ffprobe -v error -select_streams "$idx" \
                -read_intervals '%+#5' \
                -show_frames -of default=nw=0 "$file" 2>/dev/null || true
        } |
        awk '
            function frac(s,   a) {
                if (split(s, a, "/") == 2) return (a[2] + 0 > 0) ? a[1] / a[2] : -1
                return (s ~ /^[0-9.]+$/) ? s + 0 : -1
            }
            function keep(arr, key, val) { if (!(key in arr) && val != "") arr[key] = val }
            function good(s) { return s != "" && s != "unknown" && s != "unspecified" && s != "reserved" }

            /^\[FRAME_SECTION\]/ { frame = 1; next }
            /^\[SIDE_DATA\]/     { sd = "-"; next }
            /^\[\/SIDE_DATA\]/   { sd = ""; next }
            /^\[/                { next }

            {
                p = index($0, "=")
                if (!p) next
                k = substr($0, 1, p - 1)
                v = substr($0, p + 1)
            }

            sd != "" && k == "side_data_type" {
                sd = v
                if (v ~ /DOVI/) dv = 1
                if (v ~ /2094-40|HDR10\+/) h10p = 1
                next
            }
            sd ~ /Mastering display/ { keep(md, k, v); next }
            sd ~ /Content light/     { keep(cl, k, v); next }
            sd ~ /DOVI/              { keep(dvk, k, v); next }
            sd != ""                 { next }

            !frame && k == "codec_name" { codec = v }
            !frame && k == "color_primaries" && good(v) { col["p"] = v }
            !frame && k == "color_transfer"  && good(v) { col["t"] = v }
            !frame && k == "color_space"     && good(v) { col["m"] = v }
            !frame && k == "color_range"     && good(v) { col["r"] = v }
            !frame && k == "chroma_location" && good(v) { col["c"] = v }
            frame && k == "color_primaries" && good(v) { keep(col, "p", v) }
            frame && k == "color_transfer"  && good(v) { keep(col, "t", v) }
            frame && k == "color_space"     && good(v) { keep(col, "m", v) }
            frame && k == "color_range"     && good(v) { keep(col, "r", v) }
            frame && k == "chroma_location" && good(v) { keep(col, "c", v) }

            END {
                print "codec=" codec
                print "primaries=" col["p"]
                print "transfer=" col["t"]
                print "matrix=" col["m"]
                print "range=" col["r"]
                print "chromaloc=" col["c"]
                print "hdr10plus=" (h10p ? 1 : 0)

                gx = frac(md["green_x"]); gy = frac(md["green_y"])
                bx = frac(md["blue_x"]);  by = frac(md["blue_y"])
                rx = frac(md["red_x"]);   ry = frac(md["red_y"])
                wx = frac(md["white_point_x"]); wy = frac(md["white_point_y"])
                lmax = frac(md["max_luminance"]); lmin = frac(md["min_luminance"])

                if (gx > 0 && gy > 0 && bx > 0 && by > 0 && rx > 0 && ry > 0 &&
                    wx > 0 && wy > 0 && lmax > 0 && lmin >= 0) {
                    printf "master=G(%d,%d)B(%d,%d)R(%d,%d)WP(%d,%d)L(%d,%d)\n",
                        gx * 50000 + 0.5, gy * 50000 + 0.5,
                        bx * 50000 + 0.5, by * 50000 + 0.5,
                        rx * 50000 + 0.5, ry * 50000 + 0.5,
                        wx * 50000 + 0.5, wy * 50000 + 0.5,
                        lmax * 10000 + 0.5, lmin * 10000 + 0.5
                }

                if (cl["max_content"] ~ /^[0-9]+$/ && cl["max_average"] ~ /^[0-9]+$/ &&
                    cl["max_content"] + cl["max_average"] > 0)
                    printf "cll=%d,%d\n", cl["max_content"], cl["max_average"]

                print "dv=" (dv ? 1 : 0)
                print "dv_profile=" dvk["dv_profile"]
                print "dv_compat=" dvk["dv_bl_signal_compatibility_id"]
                print "dv_level=" dvk["dv_level"]
                print "dv_rpu=" dvk["rpu_present_flag"]
                print "dv_el=" dvk["el_present_flag"]
                print "dv_bl=" dvk["bl_present_flag"]
            }'
    )

    case "$HDR_TRANSFER" in
        smpte2084)    HDR_KIND="HDR10" ;;
        arib-std-b67) HDR_KIND="HLG" ;;
        *)            HDR_KIND="SDR" ;;
    esac
}

# hdr_type_label  ->  "DV Profile 8.1 + HDR10 + HDR10+", "HLG", "SDR", ...
# (from the probe_hdr globals)
hdr_type_label() {
    local d="$HDR_KIND"

    (( HDR_HDR10PLUS == 1 )) && d+=" + HDR10+"

    if (( HDR_DV == 1 )); then
        d="DV Profile ${HDR_DV_PROFILE:-?}${HDR_DV_COMPAT:+.$HDR_DV_COMPAT} + $d"
    fi

    printf '%s' "$d"
}

# hdr_compact_label  ->  "Dolby Vision 8.1 + HDR10 + HDR10+", "HDR10",
# "SDR", ... (menu header; from the probe_hdr globals)
hdr_compact_label() {
    local d="$HDR_KIND"

    (( HDR_HDR10PLUS == 1 )) && d+=" + HDR10+"
    if (( HDR_DV == 1 )); then
        d="Dolby Vision ${HDR_DV_PROFILE:-?}${HDR_DV_COMPAT:+.$HDR_DV_COMPAT} + $d"
    fi

    printf '%s' "$d"
}

# Human readable one-liner for the probe_hdr globals.
hdr_description() {
    local d="$HDR_KIND"

    (( HDR_HDR10PLUS == 1 )) && d+=" + HDR10+ dynamic metadata"

    if (( HDR_DV == 1 )); then
        d="Dolby Vision profile ${HDR_DV_PROFILE:-?}${HDR_DV_COMPAT:+.$HDR_DV_COMPAT} (base layer: $d)"
    fi

    if [[ -z "$HDR_PRIMARIES$HDR_TRANSFER$HDR_MATRIX" ]]; then
        printf '%s (no colour tags)' "$d"
        return
    fi

    printf '%s [%s/%s/%s]' \
        "$d" \
        "${HDR_PRIMARIES:-?}" \
        "${HDR_TRANSFER:-?}" \
        "${HDR_MATRIX:-?}"
}

# stream_meta FILE
#
# One TSV line per stream, in file order:
#   index type codec profile channels channel_layout default forced
#   comment hearing_impaired visual_impaired attached_pic language
#   title filename handler_name mimetype sample_rate
# Missing values are "-". Tabs/newlines inside tags become spaces.
stream_meta() {
    ffprobe -v error \
        -show_entries \
'stream=index,codec_type,codec_name,profile,channels,channel_layout,sample_rate:stream_disposition=default,forced,comment,hearing_impaired,visual_impaired,attached_pic:stream_tags=language,title,filename,handler_name,mimetype' \
        -of flat=s=_ \
        "$1" 2>/dev/null |
    awk '
        function unq(s) {
            sub(/^"/, "", s); sub(/"$/, "", s)
            gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s)
            gsub(/[\t\r\n]/, " ", s)
            return s
        }
        function g(n, k) { return ((n SUBSEP k) in f && f[n, k] != "") ? f[n, k] : "-" }
        {
            if (!match($0, /^streams_stream_[0-9]+_/)) next
            pre = substr($0, 1, RLENGTH)
            n = pre; gsub(/[^0-9]/, "", n)
            rest = substr($0, RLENGTH + 1)
            p = index(rest, "=")
            key = substr(rest, 1, p - 1)
            f[n, key] = unq(substr(rest, p + 1))
            if (!(n in seen)) { seen[n] = 1; order[++cnt] = n }
        }
        END {
            for (i = 1; i <= cnt; i++) {
                n = order[i]
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
                    g(n, "index"), g(n, "codec_type"), g(n, "codec_name"),
                    g(n, "profile"), g(n, "channels"), g(n, "channel_layout"),
                    g(n, "disposition_default"), g(n, "disposition_forced"),
                    g(n, "disposition_comment"), g(n, "disposition_hearing_impaired"),
                    g(n, "disposition_visual_impaired"), g(n, "disposition_attached_pic"),
                    g(n, "tags_language"), g(n, "tags_title"),
                    g(n, "tags_filename"), g(n, "tags_handler_name"),
                    g(n, "tags_mimetype"), g(n, "sample_rate")
            }
        }'
}

# chapter_meta FILE  ->  "start_ms<TAB>end_ms<TAB>title" per chapter
chapter_meta() {
    ffprobe -v error -show_chapters -of flat=s=_ "$1" 2>/dev/null |
    awk '
        function unq(s) {
            sub(/^"/, "", s); sub(/"$/, "", s)
            gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s)
            gsub(/[\t\r\n]/, " ", s)
            return s
        }
        match($0, /^chapters_chapter_[0-9]+_/) {
            n = substr($0, 1, RLENGTH); gsub(/[^0-9]/, "", n)
            rest = substr($0, RLENGTH + 1)
            p = index(rest, "=")
            f[n, substr(rest, 1, p - 1)] = unq(substr(rest, p + 1))
            if (n + 1 > cnt) cnt = n + 1
        }
        END {
            for (n = 0; n < cnt; n++)
                printf "%.0f\t%.0f\t%s\n", f[n, "start_time"] * 1000,
                    f[n, "end_time"] * 1000, f[n, "tags_title"]
        }'
}

# is_matroska FILE  ->  0 for MKV/MKA/MK3D (also "*.mkv.part")
is_matroska() {
    case "${1,,}" in
        *.mkv|*.mka|*.mk3d|*.mkv.part) return 0 ;;
    esac
    return 1
}

# mkv_chapters_xml FILE OUT_XML
#
# Full Matroska chapter structure (every edition, nesting, flags, UIDs,
# all display names/languages) via mkvextract. FFmpeg only reads a flat
# list from one edition. Returns 1 when FILE is not Matroska, mkvextract
# is missing, or there are no chapters.
mkv_chapters_xml() {
    is_matroska "$1" || return 1
    command -v mkvextract >/dev/null 2>&1 || return 1

    rm -f -- "$2"
    mkvextract "$1" chapters "$2" >/dev/null 2>&1 || return 1
    [[ -s "$2" ]] && grep -q '<ChapterAtom>' "$2"
}

# chapter_xml_summary XML
#
# Prints "key=value" lines describing the chapter structure:
#   editions ordered hidden_editions atoms nested hidden disabled
#   names languages segrefs complex (1 when FFmpeg would lose something)
chapter_xml_summary() {
    awk '
        function val(s) { sub(/^[^>]*>/, "", s); sub(/<.*$/, "", s); return s }
        /<EditionEntry>/          { ed++ }
        /<EditionFlagOrdered>1</  { ord++ }
        /<EditionFlagHidden>1</   { hed++ }
        /<ChapterAtom>/           { depth++; atoms++; if (depth > 1) nested++ }
        /<\/ChapterAtom>/         { depth-- }
        /<ChapterFlagHidden>1</   { hid++ }
        /<ChapterFlagEnabled>0</  { dis++ }
        /<ChapterDisplay>/        { names++ }
        /<ChapterLanguage>|<ChapLanguageIETF>/ {
            l = val($0); if (!(l in seen)) { seen[l] = 1; langs = langs (langs ? "," : "") l }
        }
        /<ChapterSegmentUID/      { seg++ }
        /<ChapterSegmentEditionUID/ { seg++ }
        END {
            printf "editions=%d\nordered=%d\nhidden_editions=%d\natoms=%d\nnested=%d\n", ed, ord, hed, atoms, nested
            printf "hidden=%d\ndisabled=%d\nnames=%d\nlanguages=%s\nsegrefs=%d\n", hid, dis, names, langs, seg
            # FFmpeg writes every chapter name back as language "und"
            complex = (ed > 1 || ord || hed || nested || hid || dis || names > atoms || seg ||
                       (langs != "" && langs != "und"))
            printf "complex=%d\n", complex
        }' "$1"
}

# chapter_xml_canon XML REFERENCE_XML
#
# Canonical form for comparing chapter structures: one line per
# element, prefixed with its position (edition / chapter path), flags at
# their default value dropped. Elements that mkvtoolnix generates when
# they are missing (EditionUID, ChapLanguageIETF mirrored from the
# legacy language) are only compared when REFERENCE_XML has them.
chapter_xml_canon() {
    local euid=0 ietf=0

    grep -q '<EditionUID>' "$2" && euid=1
    grep -q '<ChapLanguageIETF>' "$2" && ietf=1

    awk -v euid="$euid" -v ietf="$ietf" '
        function val(s) { sub(/^[^>]*>/, "", s); sub(/<[^<]*$/, "", s); return s }
        function path(   p, i) { p = "E" ed; for (i = 1; i <= depth; i++) p = p "/" cnt[i]; return p }
        /<EditionEntry>/ { ed++; depth = 0; delete cnt; next }
        /<ChapterAtom>/  { depth++; cnt[depth]++; cnt[depth + 1] = 0; next }
        /<\/ChapterAtom>/ { depth--; next }
        /<ChapterDisplay>/ { disp++; next }
        match($0, /<[A-Za-z]+/) {
            tag = substr($0, RSTART + 1, RLENGTH - 1)
            if (tag ~ /^(Chapters|EditionEntry|ChapterAtom|ChapterDisplay)$/) next
            v = val($0)
            if (tag == "EditionUID" && !euid) next
            if (tag == "ChapLanguageIETF" && !ietf) next
            if (tag ~ /^(EditionFlagOrdered|EditionFlagHidden|EditionFlagDefault|ChapterFlagHidden)$/ && v == "0") next
            if (tag == "ChapterFlagEnabled" && v == "1") next
            print path() "\t" tag "\t" v
        }' "$1"
}

# chapter_xml_describe XML  ->  "2 editions (1 ordered), 4 chapters (1 nested, 1 hidden), ..."
chapter_xml_describe() {
    local k v
    local -A c=()

    while IFS='=' read -r k v; do c[$k]="$v"; done < <(chapter_xml_summary "$1")

    printf '%s edition%s' "${c[editions]}" "$( (( c[editions] == 1 )) || echo s)"
    (( c[ordered] > 0 )) && printf ' (%s ordered)' "${c[ordered]}"
    printf ', %s chapter%s' "${c[atoms]}" "$( (( c[atoms] == 1 )) || echo s)"

    local x=()
    (( c[nested] > 0 ))   && x+=("${c[nested]} nested")
    (( c[hidden] > 0 ))   && x+=("${c[hidden]} hidden")
    (( c[disabled] > 0 )) && x+=("${c[disabled]} disabled")
    (( ${#x[@]} )) && printf ' (%s)' "$(IFS=,; echo "${x[*]}" | sed 's/,/, /g')"

    printf ', %s name%s' "${c[names]}" "$( (( c[names] == 1 )) || echo s)"
    [[ -n "${c[languages]}" ]] && printf ' [%s]' "${c[languages]}"
    (( c[segrefs] > 0 )) && printf ', %s segment reference%s' "${c[segrefs]}" "$( (( c[segrefs] == 1 )) || echo s)"
    return 0
}

# mkv_segment_uids FILE  ->  "segment_uid prev_uid next_uid" (hex, "-" if none)
mkv_segment_uids() {
    command -v mkvmerge >/dev/null 2>&1 || { echo "- - -"; return 0; }

    mkvmerge -J "$1" 2>/dev/null |
    awk '
        function grab(k,   r) {
            if (match($0, "\"" k "\"[ \t]*:[ \t]*\"[0-9a-fA-F]+\"")) {
                r = substr($0, RSTART, RLENGTH); sub(/.*:[ \t]*"/, "", r); sub(/"$/, "", r); return r
            }
            return ""
        }
        { if ((v = grab("segment_uid")) != "") s = v
          if ((v = grab("previous_segment_uid")) != "") p = v
          if ((v = grab("next_segment_uid")) != "") n = v }
        END { printf "%s %s %s\n", (s ? s : "-"), (p ? p : "-"), (n ? n : "-") }'
}

# format_start_time FILE  ->  container start time in seconds ("0" if unknown)
format_start_time() {
    local s
    s=$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1)
    [[ "$s" =~ ^-?[0-9.]+$ ]] || s=0
    printf '%s' "$s"
}

# format_title FILE  ->  global title tag (empty if none)
format_title() {
    ffprobe -v error -show_entries format_tags=title \
        -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

# stream_tag FILE STREAM_INDEX TAG  ->  tag value (empty if missing)
stream_tag() {
    ffprobe -v error \
        -select_streams "$2" \
        -show_entries "stream_tags=$3" \
        -of default=nw=1:nk=1 \
        "$1" 2>/dev/null |
    head -n 1 || true
}
