#!/usr/bin/env bash
# Per-stream size / bitrate statistics (ffprobe based): stored MKV
# statistics tags first (stats_load), packet scans as the exact
# fallback. Sourced, not executed. Needs media_probe.sh (stream_info,
# get_duration, file_bytes) to be sourced as well.

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

# media_stream_totals FILE  ->  "main_video_bytes audio_bytes"
#
# Always one packet scan (authoritative: verify.sh Validate + update,
# finished-encode reports). Menus use stats_load instead. Video = the main video stream only (cover art is not
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

# ------------------------------------------------------------
# Metadata-first stream statistics
#
#   stats_load FILE [DURATION] [MODE]
#
# 1. Matroska: stored statistics tags (BPS, NUMBER_OF_BYTES, DURATION,
#    as written by mkvmerge / mkvpropedit), used only when every
#    stream passes the sanity checks in _stats_from_tags.
# 2. MODE "estimate", non-Matroska only: stream bit rates reported by
#    ffprobe (sizes estimated from bit rate x duration).
# 3. Otherwise one full packet scan (exact, slow).
#
# MODE "exact" (default) never uses estimated bit rates: callers that
# need byte-accurate sizes (movie / audio menus) get tags or packets.
#
# Sets:
#   STATS_LINES     one line per stream: "index type attached bytes kbps"
#                   (bytes / kbps "N/A" when unknown; kbps is whole kb/s)
#   STATS_SOURCE    "stored MKV statistics tags" | "ffprobe metadata ..."
#                   | "packet scan"
#   STATS_KIND      tags | meta | packets
#   STATS_REJECTED  why stored statistics were not used ("" when they
#                   were used or there were none)
#   STATS_SCANNED   1 when a packet scan was done
#
# STATS_PROGRESS=1 prints the rejection reason and "Scanning packets..."
# before a scan (menus); STATS_INDENT is put in front of those lines.
# ------------------------------------------------------------

# Unexplained bytes allowed between the stream statistics and the file
# size (container overhead, cover art): this share of the file, but at
# least STATS_SLACK_MIN_BYTES.
STATS_SLACK_PCT=3
STATS_SLACK_MIN_BYTES=1048576

# _stats_probe FILE  ->  ffprobe compact lines ("format|..." / "stream|...")
_stats_probe() {
    ffprobe -v error \
        -show_entries \
'format=format_name,duration:format_tags=creation_time:stream=index,codec_type,codec_name,bit_rate,duration,extradata_size:stream_disposition=attached_pic:stream_tags=BPS,BPS-eng,NUMBER_OF_BYTES,NUMBER_OF_BYTES-eng,DURATION,DURATION-eng,_STATISTICS_WRITING_DATE_UTC,_STATISTICS_WRITING_DATE_UTC-eng' \
        -of compact=p=1:nk=0 \
        "$1"
}

# Shared awk parser: fills idx/typ/cod/att/br/sdur/ext/nb/bps/dt/sd per
# stream (1..n) and fmt/cdate for the file.
_STATS_AWK_PARSE='
    function field(k) { return (k in f) ? f[k] : "" }
    function tag(k,   v) { v = field("tag:" k); if (v == "") v = field("tag:" k "-eng"); return v }
    BEGIN { FS = "|" }
    {
        split("", f)
        for (i = 2; i <= NF; i++) {
            p = index($i, "=")
            if (p) f[substr($i, 1, p - 1)] = substr($i, p + 1)
        }
        if ($1 == "format") { fmt = field("format_name"); cdate = field("tag:creation_time"); next }
        if ($1 != "stream") next
        n++
        idx[n] = field("index"); typ[n] = field("codec_type"); cod[n] = field("codec_name")
        att[n] = field("disposition:attached_pic") + 0
        br[n] = field("bit_rate"); sdur[n] = field("duration"); ext[n] = field("extradata_size")
        nb[n] = tag("NUMBER_OF_BYTES"); bps[n] = tag("BPS"); dt[n] = tag("DURATION")
        sd[n] = tag("_STATISTICS_WRITING_DATE_UTC")
    }
    function skip(i) { return typ[i] == "attachment" || att[i] }
'

# _stats_is_matroska PROBE  ->  0 when the container is Matroska / WebM
_stats_is_matroska() {
    awk -F'|' '$1 == "format" && /format_name=matroska/ { m = 1 } END { exit !m }' <<< "$1"
}

# _stats_from_tags PROBE FILE_BYTES DURATION
#   ->  "OK" + stream lines | "MISSING" | "REJECT reason"
_stats_from_tags() {
    awk -v fsize="$2" -v D="$3" \
        -v slack_pct="$STATS_SLACK_PCT" -v slack_min="$STATS_SLACK_MIN_BYTES" \
        "$_STATS_AWK_PARSE"'
        function R(m) { if (reason == "") reason = m }
        function abs(x) { return x < 0 ? -x : x }
        function hms(s,   a) {
            if (split(s, a, ":") != 3) return -1
            if (a[1] !~ /^[0-9]+$/ || a[2] !~ /^[0-9]+$/ || a[3] !~ /^[0-9]+([.][0-9]+)?$/) return -1
            return a[1] * 3600 + a[2] * 60 + a[3]
        }
        # comparable seconds (31-day months; only used for "later than")
        function when(s,   d) {
            gsub(/[^0-9]/, " ", s)
            if (split(s, d, " ") < 6) return -1
            return ((d[1] * 12 + d[2]) * 31 + d[3]) * 86400 + d[4] * 3600 + d[5] * 60 + d[6]
        }
        END {
            reason = ""; present = 0; sum = 0; attach = 0
            for (i = 1; i <= n; i++) {
                if (typ[i] == "attachment" && ext[i] ~ /^[0-9]+$/) attach += ext[i]
                if (!skip(i) && (nb[i] != "" || bps[i] != "")) present = 1
            }
            if (!present) { print "MISSING"; exit }

            for (i = 1; i <= n; i++) {
                if (skip(i)) continue
                w = "stream " idx[i] " (" typ[i] ")"
                if (nb[i] == "" || bps[i] == "" || dt[i] == "") {
                    R("statistics incomplete for " w); continue
                }
                if (nb[i] !~ /^[0-9]+$/)  { R("NUMBER_OF_BYTES is not a number for " w); continue }
                if (bps[i] !~ /^[0-9]+$/) { R("BPS is not a number for " w); continue }
                d = hms(dt[i])
                if (d <= 0) { R("DURATION tag is not a positive duration for " w); continue }

                x = nb[i] * 8 / d
                if (abs(bps[i] - x) > x * 0.01 + 64)
                    R("BPS does not match NUMBER_OF_BYTES/duration for " w)
                if (D > 0 && d > D * 1.01 + 1)
                    R("DURATION tag is longer than the file for " w)
                if (D > 0 && (typ[i] == "video" || typ[i] == "audio") && d < D * 0.9 - 1)
                    R("DURATION tag is much shorter than the file for " w " (statistics of another file?)")
                if (nb[i] + 0 > fsize + 0)
                    R("NUMBER_OF_BYTES is larger than the file for " w " (stale, copied from another file?)")
                if ((cod[i] == "ac3" || cod[i] == "eac3") && br[i] ~ /^[0-9]+$/ && br[i] + 0 > 0 &&
                    abs(bps[i] - br[i]) > br[i] * 0.03)
                    R("BPS does not match the " cod[i] " bit rate for " w " (statistics of another stream?)")
                if (sd[i] != "" && cdate != "" && when(sd[i]) >= 0 && when(cdate) - when(sd[i]) > 3600)
                    R("statistics are older than the file for " w " (copied from the source?)")
                sum += nb[i]
            }

            if (reason == "" && sum > fsize + 0)
                R("statistics add up to more than the file size (stale, copied from another file?)")
            if (reason == "") {
                slack = fsize * slack_pct / 100
                if (slack < slack_min) slack = slack_min
                if (sum + attach < fsize + 0 - slack)
                    R(sprintf("statistics cover only %.0f%% of the file (stale, copied from another file?)",
                        fsize > 0 ? (sum + attach) / fsize * 100 : 0))
            }

            if (reason != "") { print "REJECT " reason; exit }

            print "OK"
            for (i = 1; i <= n; i++) {
                if (skip(i)) printf "%s %s %d N/A N/A\n", idx[i], typ[i], att[i]
                else         printf "%s %s 0 %s %.0f\n", idx[i], typ[i], nb[i], bps[i] / 1000
            }
        }'  <<< "$1"
}

# _stats_from_bitrates PROBE DURATION  ->  "OK" + stream lines | "MISSING"
# Container / stream bit rates; video and audio must all have one.
_stats_from_bitrates() {
    awk -v D="$2" "$_STATS_AWK_PARSE"'
        END {
            for (i = 1; i <= n; i++)
                if (!skip(i) && (typ[i] == "video" || typ[i] == "audio") && !(br[i] ~ /^[0-9]+$/ && br[i] + 0 > 0)) {
                    print "MISSING"; exit
                }
            print "OK"
            for (i = 1; i <= n; i++) {
                if (skip(i) || !(br[i] ~ /^[0-9]+$/ && br[i] + 0 > 0)) {
                    printf "%s %s %d N/A N/A\n", idx[i], typ[i], att[i]; continue
                }
                d = (sdur[i] ~ /^[0-9.]+$/ && sdur[i] + 0 > 0) ? sdur[i] : D
                printf "%s %s 0 %.0f %.0f\n", idx[i], typ[i], br[i] * d / 8, br[i] / 1000
            }
        }' <<< "$1"
}

# _stats_from_packets PROBE PACKET_BYTES DURATION  ->  stream lines
_stats_from_packets() {
    awk -v packets="$2" -v D="$3" "$_STATS_AWK_PARSE"'
        END {
            m = split(packets, l, "\n")
            for (j = 1; j <= m; j++) {
                split(l[j], q, " ")
                if (q[1] != "") pk[q[1]] = q[2]
            }
            for (i = 1; i <= n; i++) {
                if (idx[i] in pk)
                    printf "%s %s %d %s %s\n", idx[i], typ[i], att[i], pk[idx[i]],
                        (D > 0) ? sprintf("%.0f", pk[idx[i]] * 8 / D / 1000) : "N/A"
                else
                    printf "%s %s %d N/A N/A\n", idx[i], typ[i], att[i]
            }
        }' <<< "$1"
}

stats_load() {
    local file="$1" dur="${2:-}" mode="${3:-exact}"
    local probe fsize res

    STATS_LINES=""
    STATS_SOURCE=""
    STATS_KIND=""
    STATS_REJECTED=""
    STATS_SCANNED=0

    [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]] || dur=$(get_duration "$file" 2>/dev/null || true)
    [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]] || dur=0
    fsize=$(file_bytes "$file" 2>/dev/null || echo 0)
    probe=$(_stats_probe "$file")

    if _stats_is_matroska "$probe"; then
        res=$(_stats_from_tags "$probe" "$fsize" "$dur")
        case "$res" in
            OK*)
                STATS_LINES="${res#OK$'\n'}"
                STATS_SOURCE="stored MKV statistics tags"
                STATS_KIND="tags"
                return 0
                ;;
            REJECT*)
                STATS_REJECTED="${res#REJECT }"
                ;;
        esac
    elif [[ "$mode" == "estimate" ]]; then
        res=$(_stats_from_bitrates "$probe" "$dur")
        if [[ "$res" == OK* ]]; then
            STATS_LINES="${res#OK$'\n'}"
            STATS_SOURCE="ffprobe metadata (stream bit rates; sizes estimated)"
            STATS_KIND="meta"
            return 0
        fi
    fi

    if [[ "${STATS_PROGRESS:-0}" == 1 ]]; then
        [[ -n "$STATS_REJECTED" ]] &&
            echo "${STATS_INDENT:-}Stored statistics rejected: $STATS_REJECTED"
        echo "${STATS_INDENT:-}Scanning packets..."
    fi

    STATS_LINES=$(_stats_from_packets "$probe" "$(stream_packet_bytes "$file")" "$dur")
    STATS_SOURCE="packet scan"
    STATS_KIND="packets"
    STATS_SCANNED=1
}

# stats_totals MAIN_VIDEO_INDEX  ->  "video_bytes audio_bytes audio_count complete"
# From STATS_LINES. Missing values count as 0; complete=0 when the main
# video or an audio stream has no value.
stats_totals() {
    awk -v v="$1" '
        $1 == v { seen = 1; if ($4 == "N/A") miss = 1; else vb = $4 }
        $2 == "audio" { ac++; if ($4 == "N/A") miss = 1; else ab += $4 }
        END { printf "%.0f %.0f %d %d\n", vb, ab, ac, (seen && !miss) }' <<< "$STATS_LINES"
}

# stats_field INDEX bytes|kbps  ->  value from STATS_LINES ("N/A" if unknown)
stats_field() {
    awk -v s="$1" -v c="$([[ "$2" == kbps ]] && echo 5 || echo 4)" '
        $1 == s { v = $c } END { print (v == "" ? "N/A" : v) }' <<< "$STATS_LINES"
}

# stats_audio_kbps  ->  kb/s of every audio stream, space separated
stats_audio_kbps() {
    awk '$2 == "audio" { printf "%s ", $5 }' <<< "$STATS_LINES"
}
