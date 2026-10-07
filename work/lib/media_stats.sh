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
#   stats_load FILE [DURATION] [MODE] [refresh]
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
# "refresh" (compression menus): after a fallback packet scan of a
# Matroska file, rewrite its track statistics tags with mkvpropedit so
# the next analysis can skip the scan (_stats_refresh: regular,
# writable, non-symlink files that no running compression job is
# reading, see source_in_active_job; only the statistics tags change).
# The current analysis always keeps the packet-scan values.
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
#   STATS_REFRESH   "" (not attempted) | "refreshed" (tags rewritten and
#                   the metadata-first re-read matches the scan) |
#                   "skipped: why" | "failed: why" | "verify-failed: why"
#
# STATS_PROGRESS=1 prints the rejection reason and "Scanning packets..."
# before a scan (menus); STATS_INDENT is put in front of those lines.
# ------------------------------------------------------------

# mkvpropedit command used by _stats_refresh (tests replace it).
STATS_MKVPROPEDIT="${STATS_MKVPROPEDIT:-mkvpropedit}"

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

# mkvmerge command used by _stats_compressed_tracks (tests replace it).
STATS_MKVMERGE="${STATS_MKVMERGE:-mkvmerge}"

# _stats_compressed_tracks FILE  ->  " 0 2 " : stream indexes of Matroska
# tracks stored with content compression (zlib, header removal, ...;
# mkvmerge compresses PGS / VobSub subtitles with zlib by default).
# Their frames - what packet scans and NUMBER_OF_BYTES count - are
# larger than the bytes stored in the file, so such tracks can make the
# statistics add up to more than the file size. " " when there are none
# or mkvmerge is not available. Track IDs of mkvmerge are the ffprobe
# stream indexes (attachments are listed after the tracks by both).
_stats_compressed_tracks() {
    local out

    command -v "$STATS_MKVMERGE" >/dev/null 2>&1 || { printf ' '; return 0; }
    out=$("$STATS_MKVMERGE" -J "$1" 2>/dev/null) || { printf ' '; return 0; }

    awk '
        /"tracks": *\[/ { t = 1; next }
        t && /^  \]/ { t = 0 }
        t && /"id": *[0-9]+/ { match($0, /[0-9]+/); id = substr($0, RSTART, RLENGTH) }
        t && /"content_encoding_algorithms"/ && id != "" { c[id] = 1 }
        END { printf " "; for (i in c) printf "%s ", i }' <<< "$out"
}

# _stats_from_tags PROBE FILE_BYTES DURATION [COMPRESSED]
#   ->  "OK" + stream lines | "MISSING" | "REJECT reason"
#
# COMPRESSED (_stats_compressed_tracks): content-compressed tracks may
# legitimately count more bytes than the file holds, so they are left
# out of the "larger than the file" checks (every other check applies).
_stats_from_tags() {
    awk -v fsize="$2" -v D="$3" -v comp="${4:- }" \
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
            reason = ""; present = 0; sum = 0; plain = 0; attach = 0
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
                cmp = index(comp, " " idx[i] " ") > 0
                if (!cmp && nb[i] + 0 > fsize + 0)
                    R("NUMBER_OF_BYTES is larger than the file for " w " (stale, copied from another file?)")
                if ((cod[i] == "ac3" || cod[i] == "eac3") && br[i] ~ /^[0-9]+$/ && br[i] + 0 > 0 &&
                    abs(bps[i] - br[i]) > br[i] * 0.03)
                    R("BPS does not match the " cod[i] " bit rate for " w " (statistics of another stream?)")
                if (sd[i] != "" && cdate != "" && when(sd[i]) >= 0 && when(cdate) - when(sd[i]) > 3600)
                    R("statistics are older than the file for " w " (copied from the source?)")
                sum += nb[i]
                if (!cmp) plain += nb[i]
            }

            # Uncompressed tracks are stored byte for byte: together they
            # cannot exceed the file. (Content-compressed tracks count
            # their decompressed frames and are left out of this bound.)
            if (reason == "" && plain > fsize + 0)
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

# _stats_say TEXT  ->  progress line (only with STATS_PROGRESS=1)
_stats_say() {
    if [[ "${STATS_PROGRESS:-0}" == 1 ]]; then
        echo "${*:+${STATS_INDENT:-}$*}"
    fi
    return 0
}

# source_in_active_job FILE
#
# 0 when FILE (its resolved real path, so symlink aliases count too) may
# be read by a running compression job right now, or when that cannot be
# determined safely; 1 when it is not in use. ACTIVE_JOB_WHY says why.
#
# Primary test: the job state files written by job_runtime.sh
# (WORK_DIR/<session>.state). A job is active while its status is
# "running" and its tmux session exists; only its current item's input
# can be in use (the job's later items are queued, not open yet; jobs
# still "starting" have no current item). Secondary test: an open file
# descriptor on the same file in /proc (exact path, no command lines).
source_in_active_job() {
    local file="$1" real st status session input ireal pat
    local work="${WORK_DIR:-$HOME/compress/work}"

    ACTIVE_JOB_WHY=""

    if ! real=$(readlink -f -- "$file" 2>/dev/null) || [[ -z "$real" ]]; then
        ACTIVE_JOB_WHY="cannot resolve the source path"
        return 0
    fi

    for st in "$work"/*.state; do
        [[ -e "$st" ]] || continue

        if [[ ! -r "$st" ]] || ! status=$(sed -n 's/^status=//p' "$st" 2>/dev/null); then
            ACTIVE_JOB_WHY="cannot read job state $(basename "$st")"
            return 0
        fi
        [[ "$status" == "running" ]] || continue

        session=$(sed -n 's/^session=//p' "$st")
        input=$(sed -n 's/^input=//p' "$st")

        # a "running" state whose tmux session is gone is left over from
        # a job that was killed without cleaning up
        if command -v tmux >/dev/null 2>&1 && [[ -n "$session" ]] &&
           ! tmux has-session -t "=$session" 2>/dev/null; then
            continue
        fi

        [[ -n "$input" ]] || continue
        ireal=$(readlink -f -- "$input" 2>/dev/null) || continue

        if [[ "$ireal" == "$real" ]]; then
            ACTIVE_JOB_WHY="source is in use by an active compression job${session:+ ($session)}"
            return 0
        fi
    done

    if [[ -d /proc/self/fd ]]; then
        # exact match on the fd target (glob characters escaped)
        pat=$(printf '%s' "$real" | sed 's/[][*?\\]/\\&/g')
        # (no pipe into grep -q: under pipefail find's SIGPIPE would hide the match)
        if [[ -n "$(find /proc/[0-9]*/fd -lname "$pat" -print -quit 2>/dev/null)" ]]; then
            ACTIVE_JOB_WHY="source is open in another process"
            return 0
        fi
    fi

    return 1
}

# _stats_refresh FILE DURATION PROBE
#
# After a packet scan (STATS_LINES): rewrite the track statistics tags,
# then re-read them metadata-only (no second scan). Success only when
# every scanned stream's stored statistics equal the scan
# (_stats_match_scan) and the next run's metadata check
# (_stats_from_tags) accepts them, so a refresh is never repeated on
# every run. Sets STATS_REFRESH; never fails the caller.
_stats_refresh() {
    local file="$1" dur="$2" probe="$3"
    local res bad why=""

    STATS_REFRESH=""

    # Matroska only (MP4 / MOV / ... are never modified)
    _stats_is_matroska "$probe" || return 0

    if [[ -L "$file" ]]; then
        why="source is a symlink"
    elif [[ ! -f "$file" ]]; then
        why="not a regular file"
    elif [[ ! -w "$file" ]]; then
        why="source is not writable"
    elif ! command -v "$STATS_MKVPROPEDIT" >/dev/null 2>&1; then
        why="mkvpropedit not found"
    elif source_in_active_job "$file"; then
        # checked last, immediately before mkvpropedit
        why="$ACTIVE_JOB_WHY"
    fi

    if [[ -n "$why" ]]; then
        STATS_REFRESH="skipped: $why"
        _stats_say "MKV statistics not refreshed: $why"
        return 0
    fi

    _stats_say ""
    _stats_say "Refreshing MKV statistics..."

    if ! "$STATS_MKVPROPEDIT" "$file" \
            --delete-track-statistics-tags \
            --add-track-statistics-tags >/dev/null 2>&1; then
        STATS_REFRESH="failed: mkvpropedit failed"
        _stats_say "WARNING: MKV statistics refresh failed (mkvpropedit); using the packet scan."
        return 0
    fi

    _stats_say "MKV statistics updated."

    # Metadata-only re-read, checked stream by stream against the scan
    # (the authority) rather than with file-size heuristics.
    probe=$(_stats_probe "$file")
    bad=$(_stats_match_scan "$probe" "$dur")

    # ... and the next run must be able to use them (otherwise it would
    # scan and refresh again on every run)
    if [[ -z "$bad" ]]; then
        res=$(_stats_from_tags "$probe" "$(file_bytes "$file" 2>/dev/null || echo 0)" "$dur" \
            "$(_stats_compressed_tracks "$file")")
        [[ "$res" == OK* ]] ||
            bad="statistics match the scan, but the metadata check rejects them: ${res#REJECT }"
    fi

    if [[ -z "$bad" ]]; then
        STATS_REFRESH="refreshed"
        _stats_say "Metadata-first re-read: MATCH"
    else
        STATS_REFRESH="verify-failed: $bad"
        _stats_say "WARNING: Metadata-first re-read: DIFFERENT ($bad); using the packet scan."
        _stats_diag "$file" "$probe" "$bad"
    fi
}

# _stats_match_scan PROBE DURATION  ->  "" when the stored statistics of
# every stream the packet scan measured (STATS_LINES) are present,
# numeric, self-consistent (BPS = NUMBER_OF_BYTES / DURATION, DURATION
# not longer than the file) and NUMBER_OF_BYTES equals the scanned bytes
# exactly; otherwise the first problem
_stats_match_scan() {
    awk -v scan="$STATS_LINES" -v D="$2" "$_STATS_AWK_PARSE"'
        function abs(x) { return x < 0 ? -x : x }
        function hms(s,   a) {
            if (split(s, a, ":") != 3) return -1
            if (a[1] !~ /^[0-9]+$/ || a[2] !~ /^[0-9]+$/ || a[3] !~ /^[0-9]+([.][0-9]+)?$/) return -1
            return a[1] * 3600 + a[2] * 60 + a[3]
        }
        END {
            m = split(scan, l, "\n")
            for (j = 1; j <= m; j++) {
                split(l[j], q, " ")
                if (q[1] != "" && q[4] ~ /^[0-9]+$/) sb[q[1]] = q[4]
            }
            for (i = 1; i <= n; i++) {
                if (skip(i) || !(idx[i] in sb)) continue
                w = "stream " idx[i] " (" typ[i] ")"
                if (nb[i] !~ /^[0-9]+$/ || bps[i] !~ /^[0-9]+$/ || (d = hms(dt[i])) <= 0) {
                    print "statistics missing or not numeric for " w; exit
                }
                if (nb[i] != sb[idx[i]]) {
                    printf "%s: NUMBER_OF_BYTES %s, scan %s bytes\n", w, nb[i], sb[idx[i]]; exit
                }
                x = nb[i] * 8 / d
                if (abs(bps[i] - x) > x * 0.01 + 64) { print "BPS does not match NUMBER_OF_BYTES/duration for " w; exit }
                if (D > 0 && d > D * 1.01 + 1) { print "DURATION tag is longer than the file for " w; exit }
            }
        }' <<< "$1"
}

# _stats_diag FILE PROBE REASON  ->  per-stream comparison (verbose
# menus only: COMPRESS_VERBOSE=1 with STATS_PROGRESS=1): file size,
# packet-scan bytes (when scanned), stored NUMBER_OF_BYTES, content
# compression, the stored sum against the file size, and the reason
_stats_diag() {
    [[ "${STATS_PROGRESS:-0}" == 1 && "${COMPRESS_VERBOSE:-0}" == 1 ]] || return 0

    local fsize comp
    fsize=$(file_bytes "$1" 2>/dev/null || echo 0)
    comp=$(_stats_compressed_tracks "$1")

    awk -v fsize="$fsize" -v comp="$comp" -v scan="$STATS_LINES" -v why="$3" \
        -v ind="${STATS_INDENT:-}" "$_STATS_AWK_PARSE"'
        END {
            m = split(scan, l, "\n")
            for (j = 1; j <= m; j++) { split(l[j], q, " "); if (q[1] != "") sb[q[1]] = q[4] }
            printf "%sMKV statistics check: %s\n", ind, why
            printf "%s  file size:  %.0f bytes\n", ind, fsize
            printf "%s  %-6s %-10s %14s %24s  %s\n", ind, "stream", "type", "scan bytes", "stored NUMBER_OF_BYTES", "compressed"
            for (i = 1; i <= n; i++) {
                if (skip(i)) continue
                c = index(comp, " " idx[i] " ") ? "yes" : ""
                printf "%s  %-6s %-10s %14s %24s  %s\n", ind, idx[i], typ[i],
                    (idx[i] in sb && sb[idx[i]] != "") ? sb[idx[i]] : "-", nb[i] != "" ? nb[i] : "-", c
                if (nb[i] ~ /^[0-9]+$/) { sum += nb[i]; if (!c) plain += nb[i] }
            }
            printf "%s  stored sum: %.0f bytes (%+.0f vs the file size); uncompressed tracks: %.0f bytes (%+.0f)\n",
                ind, sum, sum - fsize, plain, plain - fsize
        }' <<< "$2"
}

stats_load() {
    local file="$1" dur="${2:-}" mode="${3:-exact}" refresh="${4:-}"
    local probe fsize res

    STATS_LINES=""
    STATS_SOURCE=""
    STATS_KIND=""
    STATS_REJECTED=""
    STATS_SCANNED=0
    STATS_REFRESH=""

    [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]] || dur=$(get_duration "$file" 2>/dev/null || true)
    [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]] || dur=0
    fsize=$(file_bytes "$file" 2>/dev/null || echo 0)
    probe=$(_stats_probe "$file")

    if _stats_is_matroska "$probe"; then
        res=$(_stats_from_tags "$probe" "$fsize" "$dur" "$(_stats_compressed_tracks "$file")")
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
        if [[ -n "$STATS_REJECTED" ]]; then
            echo "${STATS_INDENT:-}Stored statistics rejected: $STATS_REJECTED"
        fi
        echo "${STATS_INDENT:-}Scanning packets..."
    fi

    STATS_LINES=$(_stats_from_packets "$probe" "$(stream_packet_bytes "$file")" "$dur")
    STATS_SOURCE="packet scan"
    STATS_KIND="packets"
    STATS_SCANNED=1
    _stats_say "Packet scan complete."
    [[ -n "$STATS_REJECTED" ]] && _stats_diag "$file" "$probe" "stored statistics rejected: $STATS_REJECTED"

    # For the next run only: this run keeps the scanned values.
    if [[ "$refresh" == "refresh" ]]; then
        _stats_refresh "$file" "$dur" "$probe"
    fi
    return 0
}

# stats_refresh_note  ->  short note on STATS_REFRESH for "Values from"
# lines ("" when nothing was attempted)
stats_refresh_note() {
    case "$STATS_REFRESH" in
        refreshed)       echo "MKV statistics refreshed; next run reads them without a scan" ;;
        skipped:*)       echo "MKV statistics not refreshed: ${STATS_REFRESH#skipped: }" ;;
        failed:*)        echo "MKV statistics refresh failed: ${STATS_REFRESH#failed: }" ;;
        verify-failed:*) echo "MKV statistics refreshed but the re-read did not match: ${STATS_REFRESH#verify-failed: }" ;;
    esac
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
