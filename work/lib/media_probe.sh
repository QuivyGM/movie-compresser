#!/usr/bin/env bash
# Media probing helpers (ffprobe based). Sourced, not executed.
# Safe under `set -euo pipefail`: probes that may legitimately find
# nothing end with `|| true`.

video_files_in_dir() {
    find "$1" -maxdepth 1 -type f \
        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) \
        -print | sort
}

# All media files below a root, recursively, NUL separated and sorted.
media_files_recursive() {
    find "$1" -type f \
        \( -iname '*.mkv' \
        -o -iname '*.mp4' \
        -o -iname '*.m4v' \
        -o -iname '*.mov' \
        -o -iname '*.avi' \
        -o -iname '*.ts' \
        -o -iname '*.m2ts' \
        -o -iname '*.webm' \) \
        -print0 |
    sort -z
}

media_signature() {
    ffprobe -v error \
        -show_entries \
'stream=index,codec_type,codec_name,width,height,pix_fmt,r_frame_rate,color_space,color_transfer,color_primaries,channels,channel_layout,sample_rate' \
        -of compact=p=0:nk=0 \
        "$1"
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
        "$1"
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
#   HDR_PRIMARIES HDR_TRANSFER HDR_MATRIX HDR_RANGE  (ffmpeg names or "")
#   HDR_KIND        SDR | HDR10 | HLG
#   HDR_MASTER      x265 master-display string, or ""
#   HDR_CLL         x265 max-cll "MaxCLL,MaxFALL", or ""
#   HDR_DV          1 if a Dolby Vision configuration record exists
#   HDR_DV_PROFILE  DV profile, HDR_DV_COMPAT  base-layer compatibility id
#
# Stream-level side data is preferred; the first decoded frame is used
# as a fallback (HEVC SEI).
probe_hdr() {
    local file="$1"
    local idx="$2"
    local k v

    HDR_PRIMARIES=""
    HDR_TRANSFER=""
    HDR_MATRIX=""
    HDR_RANGE=""
    HDR_KIND="SDR"
    HDR_MASTER=""
    HDR_CLL=""
    HDR_DV=0
    HDR_DV_PROFILE=""
    HDR_DV_COMPAT=""

    while IFS='=' read -r k v; do
        case "$k" in
            primaries)  HDR_PRIMARIES="$v" ;;
            transfer)   HDR_TRANSFER="$v" ;;
            matrix)     HDR_MATRIX="$v" ;;
            range)      HDR_RANGE="$v" ;;
            master)     HDR_MASTER="$v" ;;
            cll)        HDR_CLL="$v" ;;
            dv)         HDR_DV="$v" ;;
            dv_profile) HDR_DV_PROFILE="$v" ;;
            dv_compat)  HDR_DV_COMPAT="$v" ;;
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

            sd != "" && k == "side_data_type" { sd = v; if (v ~ /DOVI/) dv = 1; next }
            sd ~ /Mastering display/ { keep(md, k, v); next }
            sd ~ /Content light/     { keep(cl, k, v); next }
            sd ~ /DOVI/              { keep(dvk, k, v); next }
            sd != ""                 { next }

            !frame && k == "color_primaries" && good(v) { col["p"] = v }
            !frame && k == "color_transfer"  && good(v) { col["t"] = v }
            !frame && k == "color_space"     && good(v) { col["m"] = v }
            !frame && k == "color_range"     && good(v) { col["r"] = v }
            frame && k == "color_primaries" && good(v) { keep(col, "p", v) }
            frame && k == "color_transfer"  && good(v) { keep(col, "t", v) }
            frame && k == "color_space"     && good(v) { keep(col, "m", v) }
            frame && k == "color_range"     && good(v) { keep(col, "r", v) }

            END {
                print "primaries=" col["p"]
                print "transfer=" col["t"]
                print "matrix=" col["m"]
                print "range=" col["r"]

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
            }'
    )

    case "$HDR_TRANSFER" in
        smpte2084)    HDR_KIND="HDR10" ;;
        arib-std-b67) HDR_KIND="HLG" ;;
        *)            HDR_KIND="SDR" ;;
    esac
}

# Human readable one-liner for the probe_hdr globals.
hdr_description() {
    local d="$HDR_KIND"

    if (( HDR_DV == 1 )); then
        d="Dolby Vision profile ${HDR_DV_PROFILE:-?} (base layer: $HDR_KIND)"
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

# stream_tag FILE STREAM_INDEX TAG  ->  tag value (empty if missing)
stream_tag() {
    ffprobe -v error \
        -select_streams "$2" \
        -show_entries "stream_tags=$3" \
        -of default=nw=1:nk=1 \
        "$1" 2>/dev/null |
    head -n 1 || true
}
