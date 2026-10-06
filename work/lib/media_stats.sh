#!/usr/bin/env bash
# Per-stream size / bitrate statistics (ffprobe based): packet scans and
# stored MKV statistics tags. Sourced, not executed. Needs media_probe.sh
# (stream_info) to be sourced as well.

# stream_packet_bytes FILE  ->  "index bytes" per stream, from a full
# packet scan. Slow on large files, but exact.
stream_packet_bytes() {
    ffprobe -v error \
        -show_entries packet=stream_index,size \
        -of csv=p=0 \
        "$1" |
    awk -F',' '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { s[$1] += $2 }
        END { for (i in s) printf "%d %.0f\n", i, s[i] }' |
    sort -n
}

# stream_stored_stats FILE
#
# One line per stream: "index type attached bit_rate bps bytes", using
# the stream bit_rate field and the MKV statistics tags (BPS /
# NUMBER_OF_BYTES, also the older "-eng" suffixed variants).
# Missing values are "N/A". Fast: no packet scan.
stream_stored_stats() {
    ffprobe -v error \
        -show_entries \
'stream=index,codec_type,bit_rate:stream_disposition=attached_pic:stream_tags=BPS,BPS-eng,NUMBER_OF_BYTES,NUMBER_OF_BYTES-eng' \
        -of compact=p=0:nk=0 \
        "$1" |
    awk -F'|' '
        function num(k) { return (k in f && f[k] ~ /^[0-9]+$/) ? f[k] : "" }
        {
            split("", f)
            for (i = 1; i <= NF; i++) {
                p = index($i, "=")
                if (p) f[substr($i, 1, p - 1)] = substr($i, p + 1)
            }
            br  = num("bit_rate")
            bps = num("tag:BPS");             if (bps == "") bps = num("tag:BPS-eng")
            nb  = num("tag:NUMBER_OF_BYTES"); if (nb == "")  nb  = num("tag:NUMBER_OF_BYTES-eng")
            att = ("disposition:attached_pic" in f) ? f["disposition:attached_pic"] + 0 : 0
            printf "%s %s %d %s %s %s\n", f["index"], f["codec_type"], att,
                (br  == "" ? "N/A" : br),
                (bps == "" ? "N/A" : bps),
                (nb  == "" ? "N/A" : nb)
        }'
}

# stream_kbps FILE DURATION
#
# Source bitrate per stream: "index type attached kbps method".
# Uses the stream bit_rate, then the MKV BPS tag, then (only if
# something is still missing) one full packet scan.
stream_kbps() {
    local file="$1"
    local duration="$2"
    local stored packets=""

    stored=$(stream_stored_stats "$file")

    if awk '$4 == "N/A" && $5 == "N/A" && $2 != "attachment" { m = 1 }
            END { exit !m }' <<< "$stored"; then
        packets=$(stream_packet_bytes "$file")
    fi

    awk -v d="$duration" -v packets="$packets" '
        BEGIN {
            n = split(packets, l, "\n")
            for (i = 1; i <= n; i++) {
                split(l[i], p, " ")
                if (p[1] != "") pk[p[1]] = p[2]
            }
        }
        {
            kbps = "N/A"; how = "-"
            if ($4 != "N/A")      { kbps = sprintf("%.0f", $4 / 1000); how = "meta" }
            else if ($5 != "N/A") { kbps = sprintf("%.0f", $5 / 1000); how = "tag" }
            else if (($1 in pk) && d > 0) {
                kbps = sprintf("%.0f", pk[$1] * 8 / d / 1000); how = "packets"
            }
            print $1, $2, $3, kbps, how
        }' <<< "$stored"
}

# media_stream_totals FILE  ->  "main_video_bytes audio_bytes"
#
# One packet scan. Video = the main video stream only (cover art is not
# counted); audio = all audio streams combined.
media_stream_totals() {
    local file="$1"
    local info

    info=$(stream_info "$file")

    stream_packet_bytes "$file" |
    awk -v info="$info" '
        BEGIN {
            n = split(info, l, "\n")
            for (i = 1; i <= n; i++) {
                split(l[i], f, "\t")
                if (f[1] == "") continue
                type[f[1]] = f[2]
                if (main == "" && f[2] == "video" && f[4] == 0) main = f[1]
            }
        }
        $1 == main          { v += $2 }
        type[$1] == "audio" { a += $2 }
        END { printf "%.0f %.0f\n", v, a }'
}

# stored_totals FILE MAIN_VIDEO_INDEX DURATION
#
# From stored metadata only. Prints:
#   "video_bytes audio_bytes audio_count complete estimated"
# Bytes come from NUMBER_OF_BYTES, or are estimated from BPS / bit_rate
# (estimated=1). complete=0 when the main video or any audio stream has
# no usable value.
stored_totals() {
    local file="$1"
    local vidx="$2"
    local dur="$3"

    stream_stored_stats "$file" |
    awk -v v="$vidx" -v d="$dur" '
        function bytes_of(   b) {
            if ($6 != "N/A") return $6
            est = 1
            if ($5 != "N/A" && d > 0) return $5 * d / 8
            if ($4 != "N/A" && d > 0) return $4 * d / 8
            return -1
        }
        $1 == v {
            b = bytes_of()
            if (b < 0) missing = 1; else vb = b
            seen = 1
        }
        $2 == "audio" {
            ac++
            b = bytes_of()
            if (b < 0) missing = 1; else ab += b
        }
        END {
            if (!seen) missing = 1
            printf "%.0f %.0f %d %d %d\n", vb, ab, ac, !missing, est
        }'
}

# stored_tag_totals FILE MAIN_VIDEO_INDEX  ->  "video_bytes audio_bytes"
# NUMBER_OF_BYTES tags only ("N/A" when a tag is missing).
stored_tag_totals() {
    stream_stored_stats "$1" |
    awk -v v="$2" '
        $1 == v { vb = $6; seen = 1 }
        $2 == "audio" { if ($6 == "N/A") am = 1; else ab += $6; ac++ }
        END {
            printf "%s %s\n",
                (seen && vb != "N/A") ? vb : "N/A",
                (am || !ac) ? (ac ? "N/A" : 0) : sprintf("%.0f", ab)
        }'
}

