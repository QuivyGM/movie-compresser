#!/usr/bin/env bash
# verify_titles.sh FILE  ->  verify.sh's track-title check for one file, in
# Verify mode (report only), as "LABEL<TAB>TEXT" lines.
#
# Used by window_tagger.py "Validate MKV metadata" so the audio / video
# title rules stay in one place: check_track_titles is taken from verify.sh
# itself and the libraries it needs are sourced from work/lib. Called with
# VALIDATE=0, where check_track_titles returns before any write; mkvpropedit
# is additionally shadowed by a function that refuses, so this script can
# never modify FILE. Needs bash and ffprobe.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
LIB="$REPO/work/lib"

command -v ffprobe >/dev/null 2>&1 || { printf 'ERROR\tffprobe not found\n'; exit 3; }
[[ -r "$1" ]] || { printf 'ERROR\tcannot read %s\n' "$1"; exit 3; }

source "$LIB/media_probe.sh"
source "$LIB/media_stats.sh"
source "$LIB/bitrate.sh"
source "$LIB/encode_common.sh"
source "$LIB/naming.sh"

# read-only guarantee, whatever check_track_titles does
mkvpropedit() { printf 'ERROR\tmkvpropedit refused (read-only)\n'; return 1; }
mkvmerge() { return 1; }

row() { printf '%s\t%s\n' "$1" "$2"; }
is_mkv() { [[ "${1,,}" == *.mkv ]]; }
TITLES_OK=0 TITLES_FIX=0 TITLES_UPDATED=0 CHECK_REQUIRED=0

eval "$(sed -n '/^check_track_titles() {$/,/^}$/p' "$REPO/verify.sh")"
declare -F check_track_titles >/dev/null || { printf 'ERROR\tcheck_track_titles not found in verify.sh\n'; exit 3; }

file="$1"
vidx=$(main_video_index "$file")
vidx="${vidx%$'\r'}"
[[ -n "$vidx" ]] || { printf 'ERROR\tno video stream\n'; exit 4; }
probe_hdr "$file" "$vidx"
# measured audio rates for the titles: stored statistics only (no packet
# scan, which could outlast the caller's timeout on a large file)
stats_load "$file" "" tags || STATS_LINES=""
check_track_titles "$file" "$vidx" 0 "$STATS_LINES"
exit 0   # the report is in the lines; check_track_titles' status is not meaningful
