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
# the actual file contents (an MKV, or a job's "<output>.mkv.part").
# Returns non-zero when not possible.
refresh_mkv_stats() {
    local file="$1"

    case "${file,,}" in
        *.mkv|*.mkv.part) ;;
        *) return 2 ;;
    esac

    command -v mkvpropedit >/dev/null 2>&1 || return 3

    mkvpropedit "$file" \
        --delete-track-statistics-tags \
        --add-track-statistics-tags
}

# Global tags of a CRF encode (mkv_set_compression_tags), as extended
# regular expressions over the upper-case tag name: the CRF / tier, and
# the provenance of the encode (which pipeline, which Git version, when).
COMPRESSION_CRF_TAG_NAMES="COMPRESSION_CRF|COMPRESSION_TIER"
COMPRESSION_PROVENANCE_TAG_NAMES="COMPRESSION_TOOL|MOVIE_COMPRESSER_VERSION|COMPRESSION_DATE"
COMPRESSION_ALL_TAG_NAMES="$COMPRESSION_CRF_TAG_NAMES|$COMPRESSION_PROVENANCE_TAG_NAMES"
COMPRESSION_TOOL_NAME="movie-compresser"

# compresser_version  ->  `git describe --tags --always --dirty` of the
# movie-compresser checkout this library belongs to (work/lib/../..,
# symlinks resolved; the caller's working directory does not matter), or
# "unknown" when Git is missing, that directory is not the top of a Git
# work tree (copied without .git, or only inside some other repository)
# or describe fails. Never fails. A job calls it once, when it is
# generated (emit_job_header), and records that value in every output.
compresser_version() {
    local lib root top v

    lib=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) &&
    root=$(cd -P -- "$lib/../.." 2>/dev/null && pwd -P) &&
    command -v git >/dev/null 2>&1 &&
    top=$(GIT_OPTIONAL_LOCKS=0 git -C "$root" rev-parse --show-toplevel 2>/dev/null) &&
    [[ -n "$top" && "$(cd -P -- "$top" 2>/dev/null && pwd -P)" == "$root" ]] &&
    v=$(GIT_OPTIONAL_LOCKS=0 git -C "$root" describe --tags --always --dirty 2>/dev/null) &&
    [[ "$v" =~ ^[[:graph:]]{1,128}$ ]] || v=unknown

    printf '%s\n' "$v"
}

# compression_date_now  ->  today's date, ISO 8601 (YYYY-MM-DD), in UTC
compression_date_now() {
    date -u +%Y-%m-%d
}

# _xml_escape TEXT  ->  TEXT for an XML element value
_xml_escape() {
    local s="$1"
    # quoted replacements: a bare & means "the match" in bash >= 5.2
    s="${s//&/"&amp;"}"
    s="${s//</"&lt;"}"
    s="${s//>/"&gt;"}"
    printf '%s' "$s"
}

# mkv_global_tag_values XML NAME  ->  the value of every top-level simple
# tag NAME (case-insensitive) of the global tags (same rule as
# _compression_tags_strip) in an mkvextract tags XML, one per line, in
# file order, XML entities decoded
mkv_global_tag_values() {
    awk -v want="${2^^}" '
        function unesc(s) {
            gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&quot;/, "\"", s)
            gsub(/&apos;/, "\047", s); gsub(/&amp;/, "\\&", s)
            return s
        }
        { sub(/\r$/, "") }
        /<Tag>/ && !intag { intag = 1; global = 1; sdepth = 0; n = 0; next }
        intag && sdepth == 0 && /<(TrackUID|EditionUID|ChapterUID|AttachmentUID)>/ { global = 0 }
        intag && /<Simple>/ { if (++sdepth == 1) { name = ""; val = ""; hasval = 0 } }
        intag && sdepth == 1 && name == "" && match($0, /<Name>[^<]*<\/Name>/) { name = substr($0, RSTART + 6, RLENGTH - 13) }
        intag && sdepth == 1 && !hasval && match($0, /<String>.*<\/String>/) { val = substr($0, RSTART + 8, RLENGTH - 17); hasval = 1 }
        intag && /<\/Simple>/ { if (sdepth == 1 && toupper(name) == want) vals[n++] = val; sdepth-- }
        intag && /<\/Tag>/ { if (global) for (i = 0; i < n; i++) print unesc(vals[i]); intag = 0 }' "$1"
}

# _compression_tags_strip [NAMES]  (filter)  ->  mkvextract tags XML
# without the simple tags of global tags (Targets without a track /
# edition / chapter / attachment UID) whose upper-case name matches the
# extended regular expression NAMES (default: COMPRESSION_CRF /
# COMPRESSION_TIER); a global Tag left without any simple tag is
# dropped. Everything else is printed unchanged. Expects mkvextract's
# layout (one element per line).
_compression_tags_strip() {
    awk -v names="^(${1:-$COMPRESSION_CRF_TAG_NAMES})$" '
        function flush_simple() {
            if (sbuf != "" && !(global && toupper(sname) ~ names)) { tbuf = tbuf sbuf; kept++ }
            sbuf = ""; sname = ""
        }
        /<Tag>/ && !intag { intag = 1; tbuf = $0 "\n"; global = 1; kept = 0; sdepth = 0; next }
        intag && sdepth == 0 && /<(TrackUID|EditionUID|ChapterUID|AttachmentUID)>/ { global = 0 }
        intag && /<Simple>/ {
            if (sdepth == 0) { sbuf = ""; sname = "" }
            sdepth++
        }
        intag && sdepth > 0 {
            sbuf = sbuf $0 "\n"
            if (sdepth == 1 && sname == "" && match($0, /<Name>[^<]*<\/Name>/))
                sname = substr($0, RSTART + 6, RLENGTH - 13)
            if (/<\/Simple>/ && --sdepth == 0) flush_simple()
            next
        }
        intag && /<\/Tag>/ {
            intag = 0
            if (kept > 0 || !global) printf "%s%s\n", tbuf, $0
            next
        }
        intag { tbuf = tbuf $0 "\n"; next }
        { print }'
}

# _compression_tags_canon [NAMES]  (filter)  ->  the content of a tags
# XML for comparison: Tag / Simple nesting, targets, names and values,
# without the compression tags (_compression_tags_strip NAMES), the XML
# header / indentation and the attributes mkvpropedit normalises on
# writing (TagLanguage / TagLanguageIETF / TagDefault, TargetTypeValue 50)
_compression_tags_canon() {
    _compression_tags_strip "${1:-}" | awk '
        { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        /^<(TagLanguage|TagLanguageIETF|TagDefault)>/ || /^<TargetTypeValue>50<\/TargetTypeValue>$/ { next }
        /^<\/?(Tag|Simple)>$/ || /^<[A-Za-z]+>.*<\/[A-Za-z]+>$/ { print }'
}

# ------------------------------------------------------------
# FFmpeg stream -> Matroska track mapping (MKVToolNix identification)
#
# mkvpropedit addresses tracks by Matroska track number; FFmpeg numbers
# streams its own way (attachments become streams, tracks it cannot read
# are left out). The two are never assumed to line up: every FFmpeg
# stream is matched to the tracks of `mkvmerge -J` by its properties.
# ------------------------------------------------------------

# mkv_identify_tracks FILE  ->  one line per Matroska track:
#   id  type  number  codec_id  channels  sample_rate  WxH  language
#   name  default  forced                    (tab-separated, "-" = none)
# from `mkvmerge -J` (a small JSON reader in awk: no jq / python needed).
# Non-zero when mkvmerge is missing or cannot read FILE.
mkv_identify_tracks() {
    local json

    command -v mkvmerge >/dev/null 2>&1 || return 3
    json=$(mkvmerge -J "$1" 2>/dev/null) || return 4
    [[ "$json" == *'"tracks"'* ]] || return 4

    # C locale: bytes, the same in gawk / mawk / busybox awk; raw UTF-8 in
    # the JSON passes through unchanged
    LC_ALL=C awk '
        BEGIN { RS = "\001" }
        { s = s $0 }
        END {
            n = length(s); nt = 0; i = 1
            while (i <= n) {
                c = substr(s, i, 1)
                if (c ~ /[ \t\r\n]/) { i++; continue }
                if (c ~ /[{}\[\]:,]/) { tok[++nt] = c; i++; continue }
                if (c == "\"") {
                    v = ""; i++
                    while (i <= n) {
                        c = substr(s, i, 1)
                        if (c == "\\") {
                            e = substr(s, i + 1, 1)
                            if (e == "n" || e == "t" || e == "r") v = v " "
                            else if (e == "b") v = v sprintf("%c", 8)
                            else if (e == "f") v = v sprintf("%c", 12)
                            else if (e == "u") {
                                cp = hex(substr(s, i + 2, 4)); i += 4
                                # surrogate pair: one code point
                                if (cp >= 55296 && cp <= 56319 && substr(s, i + 2, 2) == "\\u") {
                                    lo = hex(substr(s, i + 4, 4))
                                    if (lo >= 56320 && lo <= 57343) {
                                        cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); i += 6
                                    }
                                }
                                v = v utf8(cp)
                            }
                            else v = v e
                            i += 2; continue
                        }
                        if (c == "\"") { i++; break }
                        v = v c; i++
                    }
                    gsub(/[\t\r\n]/, " ", v)
                    tok[++nt] = "S"; val[nt] = v; continue
                }
                v = ""
                while (i <= n && substr(s, i, 1) !~ /[ \t\r\n{}\[\]:,]/) { v = v substr(s, i, 1); i++ }
                tok[++nt] = "V"; val[nt] = v
            }
            p = 1
            if (nt) value("")
            for (k = 0; k in T_id; k++)
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                    T_id[k], g(k, "type"), g(k, "number"), g(k, "codec_id"),
                    g(k, "audio_channels"), g(k, "audio_sampling_frequency"),
                    g(k, "pixel_dimensions"), g(k, "language"), g(k, "track_name"),
                    g(k, "default_track"), g(k, "forced_track")
        }
        function g(k, key) { return ((k, key) in F && F[k, key] != "") ? F[k, key] : "-" }
        function hex(h,    i, d, n) {
            n = 0; h = tolower(h)
            for (i = 1; i <= length(h); i++) {
                d = index("0123456789abcdef", substr(h, i, 1))
                if (!d) return 65533
                n = n * 16 + d - 1
            }
            return n
        }
        # code point -> UTF-8 bytes (awk runs with LC_ALL=C: %c is a byte);
        # a lone surrogate becomes U+FFFD
        function utf8(c) {
            if (c >= 55296 && c <= 57343) c = 65533
            if (c < 128)   return sprintf("%c", c)
            if (c < 2048)  return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
            if (c < 65536) return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
            return sprintf("%c%c%c%c", 240 + int(c / 262144), 128 + int(c / 4096) % 64,
                128 + int(c / 64) % 64, 128 + c % 64)
        }
        function value(path,    key, k) {
            if (tok[p] == "{") {
                p++
                if (tok[p] == "}") { p++; return }
                while (p <= nt) {
                    key = val[p]; p += 2            # key, ":"
                    value(path "/" key)
                    if (tok[p] == ",") { p++; continue }
                    p++; return
                }
                return
            }
            if (tok[p] == "[") {
                p++; k = 0
                if (tok[p] == "]") { p++; return }
                while (p <= nt) {
                    value(path "/" k); k++
                    if (tok[p] == ",") { p++; continue }
                    p++; return
                }
                return
            }
            scalar(path, val[p]); p++
        }
        function scalar(path, v,    a, m) {
            m = split(path, a, "/")
            if (a[2] != "tracks") return
            if (m == 4) {
                F[a[3], a[4]] = v
                if (a[4] == "id") T_id[a[3]] = v
            } else if (m == 5 && a[4] == "properties") {
                F[a[3], a[5]] = v
            }
        }' <<< "$json"
}

# _mkv_codec_ok FFMPEG_CODEC MKV_CODEC_ID  ->  0 when they can be the
# same track (an FFmpeg codec not listed here is not compared)
_mkv_codec_ok() {
    local f="$1" m="$2"

    case "$f" in
        ac3)            [[ "$m" == A_AC3* ]] ;;
        eac3)           [[ "$m" == A_EAC3* ]] ;;
        aac)            [[ "$m" == A_AAC* ]] ;;
        dts)            [[ "$m" == A_DTS* ]] ;;
        truehd|mlp)     [[ "$m" == A_TRUEHD* || "$m" == A_MLP* ]] ;;
        flac)           [[ "$m" == A_FLAC* ]] ;;
        opus)           [[ "$m" == A_OPUS* ]] ;;
        vorbis)         [[ "$m" == A_VORBIS* ]] ;;
        mp3)            [[ "$m" == A_MPEG/L3* ]] ;;
        mp2)            [[ "$m" == A_MPEG/L2* ]] ;;
        alac)           [[ "$m" == A_ALAC* ]] ;;
        pcm_*)          [[ "$m" == A_PCM* ]] ;;
        h264)           [[ "$m" == V_MPEG4/ISO/AVC* ]] ;;
        hevc)           [[ "$m" == V_MPEGH/ISO/HEVC* ]] ;;
        av1)            [[ "$m" == V_AV1* ]] ;;
        vp9)            [[ "$m" == V_VP9* ]] ;;
        vp8)            [[ "$m" == V_VP8* ]] ;;
        mpeg4)          [[ "$m" == V_MPEG4/ISO/* || "$m" == V_MS/VFW/FOURCC* ]] ;;
        mpeg2video)     [[ "$m" == V_MPEG2* ]] ;;
        mpeg1video)     [[ "$m" == V_MPEG1* ]] ;;
        subrip)         [[ "$m" == S_TEXT/UTF8* || "$m" == S_TEXT/ASCII* ]] ;;
        ass|ssa)        [[ "$m" == S_TEXT/ASS* || "$m" == S_TEXT/SSA* || "$m" == S_ASS* || "$m" == S_SSA* ]] ;;
        hdmv_pgs_subtitle) [[ "$m" == S_HDMV/PGS* ]] ;;
        dvd_subtitle)   [[ "$m" == S_VOBSUB* ]] ;;
        webvtt)         [[ "$m" == S_TEXT/WEBVTT* || "$m" == D_WEBVTT* ]] ;;
        *)              return 0 ;;
    esac
}

# mkv_track_map FILE  ->  "ffmpeg_index<TAB>number[,number...]" for every
# FFmpeg video (not cover art) / audio / subtitle stream of an MKV: the
# Matroska track number(s) it can be. Several numbers: tracks that are
# identical in every compared property (the caller must treat them
# alike). Prints "ERR<TAB>reason" and returns 1 when the mapping is not
# certain: track counts differ, a stream matches no track, or the
# candidate sets overlap. Compared: type, codec, channels, sample rate
# (or half of it: AAC SBR), dimensions, track name, default / forced
# flags, and the language when both name a real one.
mkv_track_map() {
    local file="$1" t line k w h sr2
    local -a tr f
    local -A dims=() fcount=() tcount=() setof=() setsize=() claim=()

    if ! mapfile -t tr < <(mkv_identify_tracks "$file") || (( ${#tr[@]} == 0 )); then
        printf 'ERR\t%s\n' "MKVToolNix (mkvmerge) cannot identify the tracks"
        return 1
    fi

    # newer ffprobe appends an empty field for streams with side data
    # (HDR10 mastering metadata, ...): the rest goes to _
    while IFS=, read -r k w h _; do
        [[ "$k" =~ ^[0-9]+$ ]] && dims[$k]="${w%$'\r'}x${h%$'\r'}"
    done < <(ffprobe -v error -show_entries stream=index,width,height -of csv=p=0 "$file" 2>/dev/null)

    local -a mt=()
    for line in "${tr[@]}"; do
        IFS=$'\t' read -r -a t <<< "$line"
        case "${t[1]}" in video|audio|subtitles) ;; *) continue ;; esac
        [[ "${t[2]}" =~ ^[0-9]+$ ]] || { printf 'ERR\t%s\n' "a track has no track number"; return 1; }
        [[ -z "${tcount[n${t[2]}]:-}" ]] || { printf 'ERR\t%s\n' "track number ${t[2]} is not unique"; return 1; }
        tcount[n${t[2]}]=1
        tcount[${t[1]}]=$(( ${tcount[${t[1]}]:-0} + 1 ))
        mt+=("$line")
    done

    local out=() idx type nums lang
    while IFS=$'\t' read -r -a f; do
        type="${f[1]}"
        case "$type" in
            video)    [[ "${f[11]}" == 1 ]] && continue ;;    # cover art: an attachment
            audio)    ;;
            subtitle) type=subtitles ;;
            *)        continue ;;
        esac
        idx="${f[0]}"
        fcount[$type]=$(( ${fcount[$type]:-0} + 1 ))
        nums=""
        for line in "${mt[@]}"; do
            IFS=$'\t' read -r -a t <<< "$line"
            [[ "${t[1]}" == "$type" ]] || continue
            _mkv_codec_ok "${f[2]}" "${t[3]}" || continue
            if [[ "$type" == audio ]]; then
                [[ "${t[4]}" == "${f[4]}" ]] || continue
                sr2="-"
                [[ "${t[5]}" =~ ^[0-9]+$ ]] && sr2=$(( t[5] * 2 ))
                [[ "${t[5]}" == "${f[17]}" || "$sr2" == "${f[17]}" ]] || continue
            fi
            [[ "$type" != video || "${t[6]}" == "${dims[$idx]:-}" ]] || continue
            [[ "${t[8]}" == "${f[13]}" ]] || continue
            [[ "${t[9]}" == "$( [[ "${f[6]}" == 1 ]] && echo true || echo false)" ]] || continue
            [[ "${t[10]}" == "$( [[ "${f[7]}" == 1 ]] && echo true || echo false)" ]] || continue
            lang="${f[12]}"
            if [[ "$lang" != - && "$lang" != und && "${t[7]}" != - && "${t[7]}" != und ]]; then
                [[ "${t[7]}" == "$lang" ]] || continue
            fi
            nums+="${nums:+,}${t[2]}"
        done
        if [[ -z "$nums" ]]; then
            printf 'ERR\t%s\n' "FFmpeg stream $idx ($type ${f[2]}) matches no Matroska track"
            return 1
        fi
        claim[$nums]=$(( ${claim[$nums]:-0} + 1 ))
        out+=("$idx"$'\t'"$nums")
    done < <(stream_meta "$file")

    for type in video audio subtitles; do
        if [[ "${fcount[$type]:-0}" != "${tcount[$type]:-0}" ]]; then
            printf 'ERR\t%s\n' "FFmpeg sees ${fcount[$type]:-0} $type stream(s), MKVToolNix ${tcount[$type]:-0}"
            return 1
        fi
    done

    # every candidate set must be claimed by exactly as many streams as
    # it has tracks, and the sets must not overlap
    local -A seen=()
    for nums in "${!claim[@]}"; do
        IFS=, read -ra t <<< "$nums"
        if (( ${#t[@]} != claim[$nums] )); then
            printf 'ERR\t%s\n' "tracks $nums cannot be told apart from the FFmpeg streams"
            return 1
        fi
        for k in "${t[@]}"; do
            [[ -z "${seen[$k]:-}" ]] || { printf 'ERR\t%s\n' "track $k matches several different FFmpeg streams"; return 1; }
            seen[$k]=1
        done
    done

    printf '%s\n' "${out[@]+"${out[@]}"}"
}

# mkv_set_compression_tags FILE CRF TIER WORKDIR [VERSION DATE]
#
# Writes the global Matroska tags COMPRESSION_CRF=CRF and (when TIER is
# not empty) COMPRESSION_TIER=TIER into FILE with mkvpropedit. With
# VERSION (a new encode: the job's compresser_version, "unknown"
# included) also COMPRESSION_TOOL=movie-compresser,
# MOVIE_COMPRESSER_VERSION=VERSION and COMPRESSION_DATE=DATE
# (YYYY-MM-DD, UTC); any earlier values of those (e.g. copied from the
# source by -map_metadata) are replaced. Without VERSION (Validate +
# update backfill) existing provenance tags are left exactly as they are
# and none are added: a historical version is never rewritten or
# invented. Every other existing tag (global, track, edition, chapter,
# attachment) is kept: the file's tags are extracted, earlier global
# values of the written names are removed, the new tag is appended and
# the whole set is written back (--tags all:), so each name is stored
# once. Afterwards the tags are read back; when anything else differs or
# a written value is not there exactly once, the original tag set is
# restored. Only tags change (no remux). Returns non-zero when the tags
# were not written (FILE unchanged); WORKDIR keeps the XML and tool logs.
mkv_set_compression_tags() {
    local file="$1" crf="$2" tier="$3" dir="$4" version="${5:-}" date="${6:-}"
    local orig="$dir/tags_source.xml" new="$dir/tags_compression.xml"
    local back="$dir/tags_written.xml" log="$dir/mkvpropedit_tags.log"
    local rc restore names="$COMPRESSION_CRF_TAG_NAMES" n v

    [[ "$crf" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 2
    if [[ -n "$version" ]]; then
        [[ "$version" =~ ^[[:graph:]]{1,128}$ && "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 2
        names="$COMPRESSION_ALL_TAG_NAMES"
    fi
    command -v mkvextract >/dev/null 2>&1 && command -v mkvpropedit >/dev/null 2>&1 || return 3
    mkdir -p "$dir" || return 4

    rm -f -- "$orig" "$new" "$back"
    mkvextract "$file" tags "$orig" > "$log" 2>&1 || return 5
    # no tags at all: mkvextract writes no (or an empty) file
    if grep -q '<Tags>' "$orig" 2>/dev/null; then
        restore="all:$orig"
    else
        printf '<?xml version="1.0"?>\n<Tags>\n</Tags>\n' > "$orig"
        restore="all:"
    fi

    # NAME=VALUE pairs of the new global tag, in writing order
    local -a want=()
    [[ -n "$version" ]] &&
        want+=("COMPRESSION_TOOL=$COMPRESSION_TOOL_NAME" "MOVIE_COMPRESSER_VERSION=$version" "COMPRESSION_DATE=$date")
    want+=("COMPRESSION_CRF=$crf")
    [[ -n "$tier" ]] && want+=("COMPRESSION_TIER=$tier")

    {
        _compression_tags_strip "$names" < "$orig" | sed '/<\/Tags>/,$d'
        echo '  <Tag>'
        echo '    <Targets>'
        echo '      <TargetTypeValue>50</TargetTypeValue>'
        echo '    </Targets>'
        for n in "${want[@]}"; do
            printf '    <Simple>\n      <Name>%s</Name>\n      <String>%s</String>\n    </Simple>\n' \
                "${n%%=*}" "$(_xml_escape "${n#*=}")"
        done
        echo '  </Tag>'
        echo '</Tags>'
    } > "$new"

    mkvpropedit "$file" --tags "all:$new" >> "$log" 2>&1
    rc=$?
    (( rc <= 1 )) || return 6

    # read back: every written value exactly once, and the other tags
    # exactly the ones extracted before
    if mkvextract "$file" tags "$back" >> "$log" 2>&1 &&
       [[ "$(_compression_tags_canon "$names" < "$back")" == "$(_compression_tags_canon "$names" < "$orig")" ]]; then
        rc=0
        for n in "${want[@]}"; do
            v=$(mkv_global_tag_values "$back" "${n%%=*}")
            [[ "$v" == "${n#*=}" ]] || { rc=1; echo "read back: ${n%%=*} is \"${v//$'\n'/\", \"}\", not \"${n#*=}\"" >> "$log"; }
        done
        (( rc == 0 )) && return 0
    fi

    echo "tags read back differ from the source tags: original tags restored" >> "$log"
    mkvpropedit "$file" --tags "$restore" >> "$log" 2>&1
    return 7
}

# compression_tag_duplicates FILE  ->  one line per compression tag name
# (COMPRESSION_ALL_TAG_NAMES) stored more than once in the global tags:
#   NAME<TAB>conflict|duplicate<TAB>VALUE, VALUE, ...
# "conflict" when the values differ (readers disagree on which one
# counts), "duplicate" when they are all the same. Nothing printed for a
# clean file. Read-only (mkvextract into a temporary directory). Returns
# 3 when MKVToolNix is missing, 5 when the tags cannot be read.
compression_tag_duplicates() {
    local file="$1" tmp n vals

    command -v mkvextract >/dev/null 2>&1 || return 3
    tmp=$(mktemp -d) || return 5
    if ! mkvextract "$file" tags "$tmp/tags.xml" > /dev/null 2>&1; then
        rm -rf -- "$tmp"
        return 5
    fi
    if [[ -s "$tmp/tags.xml" ]]; then
        for n in ${COMPRESSION_ALL_TAG_NAMES//|/ }; do
            vals=$(mkv_global_tag_values "$tmp/tags.xml" "$n")
            (( $(grep -c '' <<< "$vals") > 1 )) || continue
            if (( $(sort -u <<< "$vals" | grep -c '') > 1 )); then
                printf '%s\tconflict\t%s\n' "$n" "$(paste -sd, <<< "$vals" | sed 's/,/, /g')"
            else
                printf '%s\tduplicate\t%s\n' "$n" "$(paste -sd, <<< "$vals" | sed 's/,/, /g')"
            fi
        done
    fi
    rm -rf -- "$tmp"
    return 0
}

# compression_tier_name TIER  ->  TIER when it is a menu CRF tier
# (Quality / High / Base / Compact / Custom), else nothing
compression_tier_name() {
    case "$1" in
        Quality|High|Base|Compact|Custom) printf '%s' "$1" ;;
    esac
}

# work/logs/compression_tags.tsv: one row per finished CRF encode, written
# by the job when the output got its final name (job_runtime.sh
# item_succeeded). The authoritative record for Validate + update.
COMPRESSION_LEDGER_HEADER=$'date\toutput\tcrf\ttier\tvideo_bytes\tsession\tinput'

# compression_ledger_add LOG_DIR OUTPUT CRF TIER VIDEO_BYTES SESSION INPUT
# A failure to write is ignored.
compression_ledger_add() {
    local f="$1/compression_tags.tsv"

    [[ -s "$f" ]] || printf '%s\n' "$COMPRESSION_LEDGER_HEADER" >> "$f" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$2" "$3" "${4:--}" "${5:--}" "$6" "$7" \
        >> "$f" 2>/dev/null || true
}

# compression_record_lookup LOG_DIR OUTPUT VIDEO_BYTES
#   ->  "CRF<TAB>TIER<TAB>RECORD" (TIER "-" when the record has none)
#
# The CRF / tier of the encode that produced OUTPUT, from the job records
# in LOG_DIR only (nothing is derived from bitrate, size, name or encoder
# settings). VIDEO_BYTES (exact main video packet bytes of OUTPUT, packet
# scan) identifies the encode: a record counts only when its measured
# video bytes are exactly these.
#   1. compression_tags.tsv: same output file name
#   2. crf_estimates.tsv (encodes of earlier versions): an attempt that
#      was kept (not REJECTED / FAILED / a replaced candidate) whose
#      input file name is the source of OUTPUT's name
# Returns 1 when no record matches, 2 when matching records disagree.
compression_record_lookup() {
    local logs="$1" out="$2" vb="$3" name stem hits n

    [[ "$vb" =~ ^[1-9][0-9]*$ ]] || return 1
    name="${out##*/}"
    stem=$(output_source_stem "$name" 2>/dev/null)
    stem="${stem,,}"

    hits=$(
        [[ -s "$logs/compression_tags.tsv" ]] &&
            awk -F'\t' -v n="$name" -v vb="$vb" '
                NR > 1 && $5 == vb && $3 ~ /^[0-9]+([.][0-9]+)?$/ {
                    o = $2; sub(/.*\//, "", o)
                    if (o == n) printf "%s\t%s\tcompression_tags.tsv\n", $3, ($4 == "" ? "-" : $4)
                }' "$logs/compression_tags.tsv"
        [[ -s "$logs/crf_estimates.tsv" && -n "$stem" ]] &&
            awk -F'\t' -v s="$stem" -v vb="$vb" '
                NR > 1 && $7 == vb && $3 ~ /^[0-9]+([.][0-9]+)?$/ && $12 !~ /^(REJECTED|FAILED|ACCEPTED-CANDIDATE)$/ {
                    i = $10; sub(/.*\//, "", i); sub(/\.[^.]*$/, "", i)
                    if (tolower(i) == s) printf "%s\t%s\tcrf_estimates.tsv\n", $3, $2
                }' "$logs/crf_estimates.tsv"
    )
    [[ -n "$hits" ]] || return 1

    # tiers that are not menu CRF tiers are not recorded
    hits=$(awk -F'\t' -v OFS='\t' '$2 !~ /^(Quality|High|Base|Compact|Custom)$/ { $2 = "-" } { print }' <<< "$hits")
    n=$(cut -f1,2 <<< "$hits" | sort -u | wc -l)
    (( n == 1 )) || return 2
    head -n 1 <<< "$hits"
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

# x265 tune of the encode ("" = none; movie Custom: "grain" when film
# grain is to be preserved). Set per item like DV_POLICY; the sample
# encodes, their cache keys and the final encode all follow it. Given
# with -tune: x265 ignores a "tune=" inside -x265-params.
X265_TUNE=""

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
    [[ -n "${X265_TUNE:-}" ]] && a+=(-tune:v:0 "$X265_TUNE")

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
    sig="$(readlink -f -- "$file")|$(stat -L -c '%s %Y' -- "$file")|$vidx|$filter|$x265|$X265_PRESET${X265_TUNE:+ tune=$X265_TUNE}|$crf"
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

# ------------------------------------------------------------
# Actual CRF results (movie High / Base)
#
# The measured main video bytes of every completed movie High / Base
# CRF attempt (job_runtime.sh item_crf_encode: fitting or over the
# ceiling) are kept under WORK_DIR/cache/crf_actual, one file per encode
# fingerprint (crf_actual_sig; md5 of it as the name):
#   line 1   "# SIGNATURE"   (checked on every read: a hash collision or
#                             foreign file is never used)
#   then     "CRF<TAB>VIDEO_BYTES<TAB>SAVED_AT" per CRF, one line per
#            CRF (a newer measurement replaces it)
# Written to a temporary file in the same directory and renamed (an
# interrupted write never leaves a broken file). A later search of the
# same movie and settings uses the actual bytes of exactly that CRF
# instead of sampling it (crf_title_estimate_actual); other CRFs are
# sampled as usual. Any cache problem only means "not cached".
# CRF_ACTUAL_CACHE=0 turns it off.
# ------------------------------------------------------------

CRF_ACTUAL_SCHEMA=v1

# _crf_actual_dir  ->  cache directory ("" = off)
_crf_actual_dir() {
    [[ "${CRF_ACTUAL_CACHE:-1}" == "0" ]] && return 0
    printf '%s' "${WORK_DIR:-$HOME/compress/work}/cache/crf_actual"
}

# crf_actual_encoder_id  ->  the ffmpeg build ("ffmpeg version ..."; its
# libx265 decides the size); 1 when unknown
crf_actual_encoder_id() {
    if [[ -z "${CRF_ACTUAL_ENCODER_ID:-}" ]]; then
        CRF_ACTUAL_ENCODER_ID=$(ffmpeg -hide_banner -version 2>/dev/null | head -n 1 | tr -d '\r')
    fi
    [[ -n "$CRF_ACTUAL_ENCODER_ID" ]] && printf '%s' "$CRF_ACTUAL_ENCODER_ID"
}

# crf_actual_sig FILE VIDX FILTER OUT_WIDTH OUT_HEIGHT DURATION DV_POLICY DV_MODE HDR10P_POLICY
#   ->  the encode fingerprint (every CRF-independent setting that
#       decides the video size of the final encode, emit_encode_item);
#       1 (nothing printed) when any part cannot be determined
#
# "v1|stat=SIZE MTIME|dur=..|vidx=..|out=WxH|filter=..|enc=libx265 <ffmpeg>
#  |preset=..|pix=yuv420p10le|range=<HDR kind>|x265=<colour/HDR10 params>
#  |dv=<policy>/<mode>|hdr10p=<policy>|src=<resolved path>"
# (stat first so job_runtime.sh can re-check the source before saving;
# the path last: it may contain "|")
crf_actual_sig() {
    local file="$1" vidx="$2" filter="$3" w="$4" h="$5" dur="$6" dv="$7" dvm="$8" h10p="$9"
    local real st enc hdr sig

    [[ "$vidx" =~ ^[0-9]+$ && "$w" =~ ^[1-9][0-9]*$ && "$h" =~ ^[1-9][0-9]*$ &&
       "$dur" =~ ^[0-9]+([.][0-9]+)?$ && -n "$dv" && -n "$h10p" && -n "${X265_PRESET:-}" ]] || return 1
    real=$(readlink -f -- "$file" 2>/dev/null) && [[ -n "$real" ]] || return 1
    st=$(stat -L -c '%s %Y' -- "$file" 2>/dev/null) && [[ "$st" =~ ^[0-9]+\ [0-9]+$ ]] || return 1
    enc=$(crf_actual_encoder_id) || return 1
    # dynamic range kind + the x265 colour / HDR10 parameters, as the
    # final encode probes them (subshell: the caller's HDR_* stay)
    hdr=$(probe_hdr "$file" "$vidx" > /dev/null 2>&1 && printf '%s|x265=%s' "$HDR_KIND" "$(x265_color_params)") || return 1
    [[ "$hdr" == ?*"|x265="* ]] || return 1

    sig="$CRF_ACTUAL_SCHEMA|stat=$st|dur=$dur|vidx=$vidx|out=${w}x$h|filter=$filter|enc=libx265 $enc"
    sig+="|preset=$X265_PRESET${X265_TUNE:+ tune=$X265_TUNE}|pix=yuv420p10le|range=$hdr|dv=$dv/$dvm|hdr10p=$h10p|src=$real"
    [[ "$sig" == *$'\n'* || "$sig" == *$'\t'* ]] && return 1
    printf '%s' "$sig"
}

# _crf_actual_file SIG  ->  the cache file of SIG ("" / 1 when off)
_crf_actual_file() {
    local dir key

    dir=$(_crf_actual_dir)
    [[ -n "$dir" && -n "$1" ]] || return 1
    key=$(printf '%s' "$1" | md5sum 2>/dev/null | cut -c1-32)
    [[ "$key" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s/%s.tsv' "$dir" "$key"
}

# crf_actual_lookup SIG CRF  ->  actual video bytes of exactly CRF under
# SIG; 1 when none (missing, other signature, unreadable, invalid)
crf_actual_lookup() {
    local sig="$1" crf="$2" f first b

    [[ -n "$sig" && "$crf" =~ ^[0-9]+$ ]] || return 1
    f=$(_crf_actual_file "$sig") || return 1
    [[ -f "$f" && -r "$f" ]] || return 1
    IFS= read -r first < "$f" 2>/dev/null || return 1
    [[ "$first" == "# $sig" ]] || return 1
    b=$(awk -F'\t' -v c="$crf" 'NR > 1 && $1 == c + 0 && $1 ~ /^[0-9]+$/ { b = $2 } END { print b }' "$f" 2>/dev/null)
    [[ "$b" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$b"
}

# crf_actual_save SIG CRF BYTES  ->  stores (replaces) the actual result
# of CRF; 1 when it could not be written (nothing else is affected)
crf_actual_save() {
    local sig="$1" crf="$2" bytes="$3" f dir tmp first=""

    [[ -n "$sig" && "$crf" =~ ^[0-9]+$ && "$bytes" =~ ^[1-9][0-9]*$ ]] || return 1
    f=$(_crf_actual_file "$sig") || return 1
    dir="${f%/*}"
    mkdir -p -- "$dir" 2>/dev/null || return 1
    tmp=$(mktemp "$dir/.save.XXXXXX" 2>/dev/null) || return 1

    [[ -f "$f" ]] && IFS= read -r first < "$f" 2>/dev/null
    if {
        printf '# %s\n' "$sig"
        {
            # other CRFs of the same signature are kept (a file of another
            # signature is replaced as a whole)
            [[ "$first" == "# $sig" ]] &&
                awk -F'\t' -v c="$((10#$crf))" 'NR > 1 && $1 ~ /^[0-9]+$/ && $1 != c && $2 ~ /^[0-9]+$/' "$f"
            printf '%s\t%s\t%s\n' "$((10#$crf))" "$bytes" "$(date '+%F %T')"
        } | sort -t $'\t' -k1,1n
    } > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$f" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# crf_title_estimate_actual CRF  (ESTIMATOR for crf_select_boundary,
# movie High / Base): the cached actual video bytes of exactly CRF
# (CRF_ACTUAL_SIG, crf_actual_lookup) when there are any, else
# crf_title_estimate. CRF_ACTUAL_HIT[CRF]=1 for a cached actual result.
crf_title_estimate_actual() {
    local b

    if b=$(crf_actual_lookup "${CRF_ACTUAL_SIG:-}" "$1"); then
        CRF_ACTUAL_HIT[$1]=1
        CRF_EST_RESULT="$b"
        if ui_verbose; then
            printf '  CRF %s: %s video actual (cached, not sampled)\n' "$1" "$(size_text "$b")"
        else
            printf '  CRF %-4s %s GiB actual (cached)\n' "$1" "$(bytes_to_gib "$b")"
        fi
        return 0
    fi
    crf_title_estimate "$1"
}

# crf_series_estimate CRF  (ESTIMATOR for crf_select / crf_select_exact)
#
# A series batch: samples the episodes in CRF_SERIES_SAMPLED (indexes
# into FILES / EP_VIDX / EP_DUR) with CRF_SERIES_FILTER, spreads the
# result over every episode (series_crf_spread) and leaves the deciding
# estimate in CRF_EST_RESULT (series_batch_stats SB_DECIDE against
# CRF_CEILING_BYTES: with SERIES_CRF_SHARED=1, the series menu, the
# LARGEST episode, outliers included; earlier rules: the largest regular
# one). Per-episode estimates are kept in
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
        below-floor) printf 'fits, %s -> trying CRF %s' "$(ui_warn "below the video floor")" "$3" ;;
        floor-over)  printf '%s' "$(ui_warn "too large")" ;;
        floor-met)   printf 'fits, at or above the video floor' ;;
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
        below-floor|floor-over|floor-met) return 0 ;;
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
        # movie Base: both CRFs with their figures (crf_compare_boundary_lines)
        if [[ "${TIER:-}" == Base && "${DURATION:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
           (( ${CRF_CEILING_BYTES:-0} > 0 )); then
            crf_compare_boundary_lines "$2" "$3"
        else
            crf_boundary_lines "$2" "$3"
        fi
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
# CRF estimate comparison (movie High / Base / Compact; output only)
#
# Every figure comes from the estimates already in CRF_EST (sample
# encodes or cached actual results): nothing here estimates a CRF. Read
# CRF_CEILING_BYTES, CRF_FLOOR_BYTES (movie Base after the source
# exemption; 0 = no floor: High / Compact / exempt) and DURATION.
# ------------------------------------------------------------

CRF_RULE="------------------------------------------------------------"
CRF_RULE2="============================================================"

# crf_limit_text VIDEO_BYTES  ->  "OK" | "OVER ceiling by 0.31 GiB" |
# "BELOW floor by 0.07 GiB" (no floor: never BELOW)
crf_limit_text() {
    crf_limit_check "$1" "$CRF_CEILING_BYTES" "${CRF_FLOOR_BYTES:-0}"
    case "$CRF_LIMIT_KIND" in
        over)  printf 'OVER ceiling by %s GiB' "$CRF_LIMIT_GIB" ;;
        below) printf 'BELOW floor by %s GiB' "$CRF_LIMIT_GIB" ;;
        *)     printf 'OK' ;;
    esac
}

# crf_compare_row CRF  ->  one table row: CRF, video GiB, GiB/h, Mb/s,
# status against the limits
crf_compare_row() {
    local e="${CRF_EST[$1]}"
    printf '%-5s %-10s %-10s %-8s %s\n' "$1" "$(bytes_to_gib "$e") GiB" \
        "$(video_gib_per_hour "$e" "$DURATION")" "$(bytes_to_mbps "$e" "$DURATION")" "$(crf_limit_text "$e")"
}

# crf_estimates_table  ->  every CRF estimated (CRF_TRIED), lowest first
crf_estimates_table() {
    local c

    echo
    echo "CRF estimates"
    echo "$CRF_RULE"
    printf '%-5s %-10s %-10s %-8s %s\n' CRF Video GiB/h Mb/s "vs limits"
    for c in $(printf '%s\n' "${CRF_TRIED[@]}" | sort -n); do
        crf_compare_row "$c"
    done
    echo "$CRF_RULE"
}

# crf_compare_boundary_lines LO HI  ->  the Boundary block with the
# figures of both CRFs (movie Base; other tiers: crf_boundary_lines)
crf_compare_boundary_lines() {
    local c e

    echo "Boundary:"
    for c in "$1" "$2"; do
        e="${CRF_EST[$c]}"
        printf '  CRF %-4s %-10s %-12s %-11s %s\n' "$c" "$(bytes_to_gib "$e") GiB" \
            "$(video_gib_per_hour "$e" "$DURATION") GiB/h" "$(bytes_to_mbps "$e" "$DURATION") Mb/s" "$(crf_limit_text "$e")"
    done
}

# base_limits_lines  ->  the movie Base limits for this movie (before the
# estimates): runtime, rate, ceiling, floor, allowed video range
base_limits_lines() {
    printf '%-17s%s\n' "Runtime:" "$(format_hms "$DURATION")"
    printf '%-17s%s GiB/h (defines the video ceiling)\n' "Base rate:" "$CRF_GIB_PER_HOUR"
    printf '%-17s%s GiB / %s Mb/s\n' "Video ceiling:" "$(bytes_to_gib "$CRF_CEILING_BYTES")" \
        "$(bytes_to_mbps "$CRF_CEILING_BYTES" "$DURATION")"
    if (( ${CRF_FLOOR_BYTES:-0} > 0 )); then
        printf '%-17s%s GiB / %s Mb/s\n' "Video floor:" "$(bytes_to_gib "$CRF_FLOOR_BYTES")" \
            "$(bytes_to_mbps "$CRF_FLOOR_BYTES" "$DURATION")"
        printf '%-17s%s–%s GiB\n' "Allowed video:" "$(bytes_to_gib "$CRF_FLOOR_BYTES")" "$(bytes_to_gib "$CRF_CEILING_BYTES")"
    else
        printf '%-17snot applied (source video %s Mb/s is below %s Mb/s)\n' "Video floor:" \
            "${SOURCE_VIDEO_MBPS:-N/A}" "${CRF_FLOOR_MBPS:-?}"
        printf '%-17sup to %s GiB\n' "Allowed video:" "$(bytes_to_gib "$CRF_CEILING_BYTES")"
    fi
}

# base_range_text VIDEO_BYTES  ->  the second Base range line of the
# queued-item summary: "OK" | "+0.31 GiB over ceiling" | "-0.07 GiB
# below floor"
base_range_text() {
    crf_limit_check "$1" "$CRF_CEILING_BYTES" "${CRF_FLOOR_BYTES:-0}"
    case "$CRF_LIMIT_KIND" in
        over)  printf '+%s GiB over ceiling' "$CRF_LIMIT_GIB" ;;
        below) printf -- '-%s GiB below floor' "$CRF_LIMIT_GIB" ;;
        *)     printf 'OK' ;;
    esac
}

# base_added_lines RES_LABEL CRF MANUAL HDR_TEXT EST_VIDEO_BYTES AUDIO_GIB TOTAL_GIB
#   ->  the queued-item summary of a movie Base CRF encode (compact
#       output; the menu prints the notes and the output name after it):
#       tier / resolution / CRF (MANUAL: a manual CRF) / HDR, video with
#       GiB/h and Mb/s, the Base range and where the estimate is in it,
#       audio, total
base_added_lines() {
    local res="$1" crf="$2" manual="$3" hdr="$4" e="$5" audio="$6" total="$7"

    echo
    printf 'Base %s | %s | %s\n' "$res" "$(ui_bold "CRF $crf$( [[ "$manual" == 1 ]] && echo " MANUAL")")" "$hdr"
    echo
    printf '%-13s~%s GiB   %s GiB/h   %s Mb/s\n' "Video:" "$(bytes_to_gib "$e")" \
        "$(video_gib_per_hour "$e" "$DURATION")" "$(bytes_to_mbps "$e" "$DURATION")"
    if (( ${CRF_FLOOR_BYTES:-0} > 0 )); then
        printf '%-14s%s–%s GiB\n' "Base range:" "$(bytes_to_gib "$CRF_FLOOR_BYTES")" "$(bytes_to_gib "$CRF_CEILING_BYTES")"
    else
        printf '%-14sup to %s GiB (floor not applied: source video %s Mb/s)\n' "Base range:" \
            "$(bytes_to_gib "$CRF_CEILING_BYTES")" "${SOURCE_VIDEO_MBPS:-N/A}"
    fi
    printf '%-14s%s\n' "" "$(base_range_text "$e")"
    echo
    printf '%-14s%s GiB copied\n' "Audio:" "$audio"
    printf '%-13s~%s GiB\n' "Total:" "$(awk -v t="$total" 'BEGIN { printf "%.2f", t }')"
}

# ------------------------------------------------------------
# Movie Base: no CRF inside both limits (prompt)
# ------------------------------------------------------------

# base_crf_prompt ESTIMATOR
#
# Movie Base, when the search found no CRF that fits the ceiling AND
# reaches the video floor: CRF_FLOOR_STATUS gap / limit (policy.sh
# crf_floor_extend) or CRF_OVER_CEILING=1 (even CRF_MAX above the
# ceiling). Shows the closest choices side by side, then asks:
#   1) encode the automatic CRF (CRF) anyway
#   2) encode the adjacent higher-quality CRF (gap: CRF_BOUNDARY_LOW,
#      above the ceiling), only when it already has an estimate in
#      CRF_EST (never estimated for this menu); a Base manual CRF
#   n) choose another CRF: a whole x265 CRF 0-51 (not limited to the
#      Base search range; empty = the automatic CRF), estimated with
#      ESTIMATOR through the search's CRF_EST (a CRF already estimated is
#      shown, not estimated again; sample encodes only, never the final
#      encode), shown against the ceiling and the floor, then: encode at
#      it / choose another CRF / skip
#   n) skip this movie
# Reads CRF CRF_EST CRF_MIN CRF_MAX CRF_OVER_CEILING CRF_FLOOR_STATUS
# CRF_BOUNDARY_LOW CRF_CEILING_BYTES CRF_CEILING_GIB CRF_FLOOR_BYTES
# CRF_FLOOR_MBPS CRF_GIB_PER_HOUR DURATION SOURCE_VIDEO_MBPS. Sets
# BASE_PICK (auto | manual | skip; end of input: skip) and BASE_PICK_CRF
# (the CRF to encode). Always returns 0.
base_crf_prompt() {
    local est="$1" sel adj="" n_other n_skip auto_tag adj_tag

    BASE_PICK=""
    BASE_PICK_CRF="$CRF"
    if [[ "${CRF_FLOOR_STATUS:-}" == gap && -n "${CRF_BOUNDARY_LOW:-}" && -n "${CRF_EST[$CRF_BOUNDARY_LOW]+x}" ]]; then
        adj="$CRF_BOUNDARY_LOW"
    fi

    echo
    if (( ${CRF_OVER_CEILING:-0} == 1 )); then
        echo "Base cannot meet its video ceiling within CRF ${CRF_MIN}-${CRF_MAX}"
    else
        echo "Base cannot satisfy both limits"
    fi
    echo "$CRF_RULE2"
    _base_gap_lines "$adj"
    echo
    _base_compare_grid $adj "$CRF"
    echo "$CRF_RULE"

    crf_limit_check "${CRF_EST[$CRF]}" "$CRF_CEILING_BYTES" "${CRF_FLOOR_BYTES:-0}"
    case "$CRF_LIMIT_KIND" in
        over)  auto_tag="automatic, ${CRF_LIMIT_GIB} GiB over ceiling" ;;
        below) auto_tag="automatic, below floor by ${CRF_LIMIT_GIB} GiB" ;;
        *)     auto_tag="automatic" ;;
    esac
    if [[ -n "$adj" ]]; then
        crf_limit_check "${CRF_EST[$adj]}" "$CRF_CEILING_BYTES" "${CRF_FLOOR_BYTES:-0}"
        adj_tag="higher quality"
        [[ "$CRF_LIMIT_KIND" == over ]] && adj_tag+=", ${CRF_LIMIT_GIB} GiB over ceiling"
        n_other=3
        n_skip=4
    else
        n_other=2
        n_skip=3
    fi

    while true; do
        echo
        echo "1) Encode CRF ${CRF}  [${auto_tag}]"
        [[ -n "$adj" ]] && echo "2) Encode CRF ${adj}  [${adj_tag}]"
        echo "${n_other}) Choose another CRF"
        echo "${n_skip}) Skip"
        if ! read -rp "Select [1-${n_skip}]: " sel; then
            BASE_PICK=skip
            return 0
        fi
        if [[ "$sel" == 1 ]]; then
            BASE_PICK=auto
            return 0
        elif [[ -n "$adj" && "$sel" == 2 ]]; then
            BASE_PICK=manual
            BASE_PICK_CRF="$adj"
            return 0
        elif [[ "$sel" == "$n_other" ]]; then
            _base_crf_manual "$est"
            [[ -n "$BASE_PICK" ]] && return 0
        elif [[ "$sel" == "$n_skip" ]]; then
            BASE_PICK=skip
            return 0
        else
            echo "Invalid selection."
        fi
    done
}

# _base_gap_lines [ADJACENT_CRF]  ->  why no CRF fits both limits, the
# closest choices and the automatic choice (base_crf_prompt)
_base_gap_lines() {
    local adj="${1:-}" e

    if (( ${CRF_OVER_CEILING:-0} == 1 )); then
        echo "No CRF in the Base range (${CRF_MIN}-${CRF_MAX}) fits the video ceiling."
    else
        echo "No tested CRF satisfies both Base limits."
    fi
    echo
    echo "Closest choices:"
    if [[ -n "$adj" ]]; then
        crf_limit_check "${CRF_EST[$adj]}" "$CRF_CEILING_BYTES" "${CRF_FLOOR_BYTES:-0}"
        printf '  CRF %-4s %-26s %s\n' "$adj" "+${CRF_LIMIT_GIB} GiB above ceiling" "higher quality"
    fi
    e="${CRF_EST[$CRF]}"
    crf_limit_check "$e" "$CRF_CEILING_BYTES" "${CRF_FLOOR_BYTES:-0}"
    case "$CRF_LIMIT_KIND" in
        over)  printf '  CRF %-4s %-26s %s\n' "$CRF" "+${CRF_LIMIT_GIB} GiB above ceiling" "lowest quality Base allows" ;;
        below) printf '  CRF %-4s %-26s %s\n' "$CRF" "-${CRF_LIMIT_GIB} GiB below floor" \
                   "$( [[ "${CRF_FLOOR_STATUS:-}" == limit ]] && echo "lowest CRF the floor may use" || echo "smaller file")" ;;
        *)     printf '  CRF %-4s %s\n' "$CRF" "OK" ;;
    esac
    echo
    echo "Automatic choice: CRF ${CRF}"
    echo "(${CRF_GIB_PER_HOUR} GiB/h defines the Base ceiling, an upper limit; no CRF is aimed at that rate."
    echo " Source video: ${SOURCE_VIDEO_MBPS:-N/A} Mb/s.)"
}

# _base_compare_grid CRF...  ->  the CRFs side by side: video, rate,
# bitrate, ceiling, floor (when one applies), quality (two CRFs: the
# lower CRF is the higher quality)
_base_compare_grid() {
    local c e line

    line=$(printf '%-20s' "")
    for c in "$@"; do line+=$(printf '%-19s' "CRF $c"); done
    echo "${line%"${line##*[! ]}"}"

    _base_grid_row "Video"   "$@"
    _base_grid_row "Rate"    "$@"
    _base_grid_row "Bitrate" "$@"
    _base_grid_row "Ceiling" "$@"
    (( ${CRF_FLOOR_BYTES:-0} > 0 )) && _base_grid_row "Floor" "$@"
    if (( $# == 2 )); then
        printf '%-20s%-19s%s\n' "Quality" "higher" "lower"
    fi
    return 0
}

# _base_grid_row LABEL CRF...  ->  one row of _base_compare_grid
_base_grid_row() {
    local label="$1" c e v line
    shift

    line=$(printf '%-20s' "$label")
    for c in "$@"; do
        e="${CRF_EST[$c]}"
        case "$label" in
            Video)   v="$(bytes_to_gib "$e") GiB" ;;
            Rate)    v="$(video_gib_per_hour "$e" "$DURATION") GiB/h" ;;
            Bitrate) v="$(bytes_to_mbps "$e" "$DURATION") Mb/s" ;;
            Ceiling)
                crf_limit_check "$e" "$CRF_CEILING_BYTES" 0
                if [[ "$CRF_LIMIT_KIND" == over ]]; then
                    v="+${CRF_LIMIT_GIB} GiB OVER"
                else
                    v="${CRF_LIMIT_ROOM} GiB under"
                fi
                ;;
            Floor)
                if (( e < CRF_FLOOR_BYTES )); then
                    v="-$(awk -v a="$e" -v b="$CRF_FLOOR_BYTES" 'BEGIN { printf "%.2f", (b - a) / 1073741824 }') GiB BELOW"
                else
                    v="above"
                fi
                ;;
        esac
        line+=$(printf '%-19s' "$v")
    done
    echo "${line%"${line##*[! ]}"}"
}

# _base_crf_manual ESTIMATOR  ->  the manual CRF loop of base_crf_prompt:
# sets BASE_PICK manual (BASE_PICK_CRF) or skip (also at end of input)
_base_crf_manual() {
    local est="$1" cur="$CRF" in m e cached sel over below

    while true; do
        if ! read -rp "Manual Base CRF (0-$CRF_LIMIT) [$cur]: " in; then
            BASE_PICK=skip
            return 0
        fi
        in="${in//[[:space:]]/}"
        [[ -z "$in" ]] && in="$cur"
        if [[ ! "$in" =~ ^[0-9]+$ ]] || (( 10#$in > CRF_LIMIT )); then
            echo "Enter a whole x265 CRF from 0 to $CRF_LIMIT (lower = higher quality), e.g. $CRF"
            continue
        fi
        m=$((10#$in))

        cached=0
        if [[ -n "${CRF_EST[$m]+x}" ]]; then
            cached=1
            e="${CRF_EST[$m]}"
        else
            echo "Estimating CRF $m (sample encodes only)..."
            if ! _CRF_SELECT_EST="$est" _crf_select_probe "$m"; then
                echo "$(ui_warn "Could not estimate CRF $m") (sample encode error above); choose another CRF."
                continue
            fi
            e="$CRF_EST_RESULT"
        fi

        crf_limit_check "$e" "$CRF_CEILING_BYTES" 0
        over=0
        [[ "$CRF_LIMIT_KIND" == over ]] && over=1
        below=0
        crf_below_floor "$e" "$CRF_FLOOR_BYTES" && below=1

        echo
        printf '%-17s%s\n' "Manual Base CRF:" "$m"
        printf '%-17s%s GiB%s\n' "Estimated video:" "$(bytes_to_gib "$e")" "$( (( cached )) && echo " (already estimated)")"
        printf '%-17s%s GiB/h\n' "Rate:" "$(video_gib_per_hour "$e" "$DURATION")"
        printf '%-17s%s Mb/s\n' "Bitrate:" "$(bytes_to_mbps "$e" "$DURATION")"
        echo
        echo "Base limits:"
        printf '  %-15s%s GiB / %s Mb/s\n' "Ceiling:" "$CRF_CEILING_GIB" "$(bytes_to_mbps "$CRF_CEILING_BYTES" "$DURATION")"
        if (( ${CRF_FLOOR_BYTES:-0} > 0 )); then
            printf '  %-15s%s GiB / %s Mb/s\n' "Floor:" "$(bytes_to_gib "$CRF_FLOOR_BYTES")" "$(bytes_to_mbps "$CRF_FLOOR_BYTES" "$DURATION")"
        else
            printf '  %-15snot applied (source video %s Mb/s)\n' "Floor:" "${SOURCE_VIDEO_MBPS:-N/A}"
        fi
        echo
        echo "Result:"
        if (( over )); then
            printf '  %-15s+%s GiB OVER\n' "Ceiling:" "$CRF_LIMIT_GIB"
        else
            printf '  %-15sOK (%s GiB under)\n' "Ceiling:" "$CRF_LIMIT_ROOM"
        fi
        if (( ${CRF_FLOOR_BYTES:-0} > 0 )); then
            if (( below )); then
                printf '  %-15s-%s GiB BELOW\n' "Floor:" \
                    "$(awk -v a="$e" -v b="$CRF_FLOOR_BYTES" 'BEGIN { printf "%.2f", (b - a) / 1073741824 }')"
            else
                printf '  %-15sOK\n' "Floor:"
            fi
        fi
        if (( over )); then
            echo
            echo "$(ui_warn WARNING): estimated video exceeds the Base ceiling by $(crf_oversize_gib "$e" "$CRF_CEILING_BYTES") GiB."
        fi
        if (( below )); then
            echo
            echo "$(ui_warn WARNING): estimated bitrate is below the ${CRF_FLOOR_MBPS} Mb/s Base floor."
        fi

        echo
        if (( over || below )); then
            echo "1) Encode at CRF $m anyway"
        else
            echo "1) Encode at CRF $m"
        fi
        echo "2) Choose another CRF"
        echo "3) Skip this movie"
        while true; do
            if ! read -rp "Select [1-3]: " sel; then
                BASE_PICK=skip
                return 0
            fi
            case "$sel" in
                1) BASE_PICK=manual; BASE_PICK_CRF="$m"; return 0 ;;
                2) cur="$m"; break ;;
                3) BASE_PICK=skip; return 0 ;;
                *) echo "Invalid selection." ;;
            esac
        done
    done
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
# MODE residue: TITLE with every codec / object-audio / bitrate / bit-
#   depth / sample-rate / channel claim (true or false) and the track's
#   own language (LANG: regex of its name and codes) removed: the
#   descriptive rest ("Director's Commentary"), for audio_std_title.
# Case-insensitive; plain POSIX awk (mawk compatible).
_audio_title_awk() {
    # the title is passed in the environment: awk -v would turn its
    # backslashes into escape sequences
    AT_TITLE="$2" awk -v mode="$1" -v codec="$3" -v label="$4" -v ch="$5" -v prof="$6" -v lang="${7:-}" \
        -v nbr="${8:-}" -v bits="${9:-}" -v sr="${10:-}" -v trans="${11:-}" '
        BEGIN {
            t = ENVIRON["AT_TITLE"]
            # residue / check: release-style separators ("TrueHD.Atmos.7.1",
            # "DTS_HD") are spaces; a dot between digits stays ("7.1")
            if (mode != "rewrite") t = undot(t)
            # Dolby Digital EX / Surround EX: the "EX" belongs to the codec
            # claim (matrixed rear surround in an AC-3 stream)
            lt = tolower(t)
            exclaim = (lt ~ /(^|[^a-z])(dolby digital( plus)?|dd\+?|ddp|e?-?ac-?3)[^a-z]*([0-9][.][0-9][^a-z]*)?(surround[ -])?ex([^a-z]|$)/ ||
                       lt ~ /(^|[^a-z])surround[ -]ex([^a-z]|$)/)
            # pattern, class (order matters: longest / most specific first)
            n = 0
            P[++n] = "dolby atmos";                       C[n] = "atmos"
            P[++n] = "atmos";                             C[n] = "atmos"
            P[++n] = "dts[:-]? ?x";                       C[n] = "dtsx"
            P[++n] = "dolby tru(e)?[- ]?hd";              C[n] = "truehd"
            P[++n] = "tru(e)?[- ]?hd";                    C[n] = "truehd"
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
            P[++n] = "hd[- ]?(ma|hra)";                   C[n] = "dts"
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
            # residue only (kept by rewrite / check): any other channel
            # notation, and the track language
            P[++n] = "[0-9]+\\.[0-9](\\.[0-9])?";          C[n] = "chx"
            P[++n] = "[0-9]+ ?(ch|channels?)";            C[n] = "chx"
            if (lang != "") { P[++n] = lang;              C[n] = "lang" }
            if (exclaim)    { P[++n] = "(surround[ -])?ex"; C[n] = "ex" }

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

                    if (!is_false(C[i], substr(lc, s, l)) || mode == "check" || mode == "unknown") {
                        if (mode == "check" && is_false(C[i], substr(lc, s, l)))
                            stale = stale (stale ? ", " : "") substr(t, s, l)
                        else if (mode == "unknown" && is_unknown(C[i]))
                            stale = stale (stale ? ", " : "") substr(t, s, l)
                        lc = substr(lc, 1, s - 1) blank substr(lc, s + l)
                        pos = s + l
                        continue
                    }

                    rep = ""
                    # DTS:X also names the codec (DTS); Atmos alone does not
                    if ((is_codec(C[i]) || C[i] == "dtsx") && first && mode != "residue") { rep = "\001"; first = 0 }
                    lc  = substr(lc, 1, s - 1) rep substr(lc, s + l)
                    out = substr(out, 1, s - 1) rep substr(out, s + l)
                    pos = s + length(rep)
                }
            }

            if (mode == "check" || mode == "unknown") { print stale; exit }

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
        # TXT: the matched (lower-case) claim
        function is_false(c, txt,    v) {
            if (mode == "residue") return 1
            if (c == "chx" || c == "lang") return 0
            if (is_codec(c)) return c != codec
            if (c == "dolby")    return codec !~ /^(ac3|eac3|truehd)$/
            if (c == "lossless") return codec !~ /^(flac|alac|pcm|truehd)$/
            if (c == "ex")       return codec !~ /^(ac3|eac3)$/
            # object audio: FFmpeg does not report every Atmos / DTS:X
            # stream in the profile, so on an unchanged (not transcoded)
            # stream of a codec that can carry it a title claim is not
            # disproved; a transcode always drops it
            if (c == "atmos")    return prof !~ /Atmos/ && (mode == "rewrite" || trans == 1 || codec !~ /^(truehd|eac3)$/)
            if (c == "dtsx")     return prof !~ /DTS:X/ && (mode == "rewrite" || trans == 1 || codec != "dts")
            # EX is matrixed into the surrounds: "6.1" on 6 channels is EX
            if (c == "ch7" && exclaim && ch + 0 == 6) return 0
            if (c ~ /^ch/)       return (ch != "" && substr(c, 3) + 0 != ch + 0)
            # bit rate / bit depth / sample rate: rewrite (the old stream
            # of a transcode) drops them; check only when the stream says
            # otherwise (unknown is never false)
            if (mode == "rewrite") return 1
            if (c == "bitrate") {
                v = claim_bps(txt)
                return nbr ~ /^[0-9]+$/ && nbr + 0 > 0 && v > 0 && (v > nbr * 1.02 || v < nbr * 0.98)
            }
            if (c == "bitdepth") {
                v = txt; sub(/[^0-9].*/, "", v)
                return bits ~ /^[0-9]+$/ && bits + 0 > 0 && v + 0 != bits + 0
            }
            if (c == "samplerate") {
                v = txt; sub(/ ?khz$/, "", v); gsub(/,/, ".", v); v = v * 1000
                return sr ~ /^[0-9]+$/ && sr + 0 > 0 && (v > sr * 1.006 || v < sr * 0.994)
            }
            return 0
        }
        # unknown mode: a technical claim the stream can neither confirm
        # nor contradict (no nominal rate / bit depth / sample rate)
        function is_unknown(c) {
            if (c == "bitrate")    return nbr !~ /^[0-9]+$/
            if (c == "bitdepth")   return bits !~ /^[0-9]+$/
            if (c == "samplerate") return sr !~ /^[0-9]+$/
            return 0
        }
        # "3394 kbps" / "1.5 Mbps" / "1,509 kb/s" / "640k"  ->  bits per second
        function claim_bps(x,    num, unit) {
            num = x; sub(/ ?[a-z\/]+$/, "", num)
            unit = substr(x, length(num) + 1); gsub(/ /, "", unit)
            if (num ~ /^[0-9]+,[0-9][0-9][0-9]$/) gsub(/,/, "", num); else gsub(/,/, ".", num)
            return num * (unit ~ /^m/ ? 1000000 : 1000)
        }
        function undot(x,    o, i, c, n, a, b) {
            o = ""; n = length(x)
            for (i = 1; i <= n; i++) {
                c = substr(x, i, 1)
                if (c == "_") c = " "
                else if (c == ".") {
                    a = substr(x, i - 1, 1); b = substr(x, i + 1, 1)
                    if (!(a ~ /[0-9]/ && b ~ /[0-9]/)) c = " "
                }
                o = o c
            }
            return o
        }'
}

# audio_title_rewrite TITLE CODEC CHANNELS  ->  title for the re-encoded track
audio_title_rewrite() {
    _audio_title_awk rewrite "$1" "$2" "$(codec_title_label "$2")" "$3" ""
}

# audio_title_false_claims TITLE CODEC CHANNELS PROFILE [NOMINAL_BPS BITS
#                          SAMPLE_RATE TRANSCODED]  ->  "" if accurate
# Only what the stream contradicts is listed: a bit rate against the
# nominal (constant) rate, a bit depth / sample rate against the known
# value (audio_title_stream_facts); "" for any of them = unknown, never
# false. TRANSCODED=1: the track was re-encoded (object audio is gone).
audio_title_false_claims() {
    _audio_title_awk check "$1" "$2" "" "$3" "$4" "" "${5:-}" "${6:-}" "${7:-}" "${8:-}"
}

# audio_title_unverified TITLE CODEC CHANNELS PROFILE [NOMINAL_BPS BITS
#                         SAMPLE_RATE]  ->  the bit rate / bit depth /
# sample rate claims the stream can neither confirm nor contradict
# (UNKNOWN, as opposed to the false claims above); "" = none
audio_title_unverified() {
    _audio_title_awk unknown "$1" "$2" "" "$3" "$4" "" "${5:-}" "${6:-}" "${7:-}" ""
}

# audio_title_stream_facts CODEC PROFILE BIT_RATE BITS_PER_RAW_SAMPLE
#                          SAMPLE_RATE CHANNELS
#   ->  "NOMINAL_BPS BITS SAMPLE_RATE" ("-" = unknown) for
#       audio_title_false_claims. A nominal bit rate only for constant
#       rate streams (AC-3, E-AC-3, MP2, DTS core without HD extension,
#       PCM); TrueHD / DTS-HD / FLAC / AAC / Opus / ... are variable, so a
#       title's (average) rate cannot be judged. A bit depth only where
#       it is a property of the stream (PCM, lossless).
audio_title_stream_facts() {
    local codec="$1" profile="${2:-}" br="${3:-}" raw="${4:-}" sr="${5:-}" ch="${6:-}" n="-" b="-" pb=""

    [[ "$br" =~ ^[0-9]+$ ]] || br=""
    [[ "$raw" =~ ^[1-9][0-9]*$ ]] || raw=""
    [[ "$sr" =~ ^[1-9][0-9]*$ ]] || sr=""

    case "$codec" in
        pcm_*)
            [[ "$codec" =~ ^pcm_[a-z]?([0-9]+) ]] && pb="${BASH_REMATCH[1]}"
            b="${pb:--}"
            [[ -n "$pb" && -n "$sr" && "$ch" =~ ^[0-9]+$ ]] && n=$(( pb * sr * ch ))
            ;;
        ac3|eac3|mp2)
            n="${br:--}" ;;
        dts)
            [[ "$profile" == DTS || "$profile" == DTS-ES || "$profile" == "DTS 96/24" ]] && n="${br:--}"
            [[ "$profile" == *MA* ]] && b="${raw:--}"
            ;;
        truehd|mlp|flac|alac|wavpack)
            b="${raw:--}" ;;
    esac
    printf '%s %s %s' "$n" "$b" "${sr:--}"
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

# ------------------------------------------------------------
# Standard audio track titles: "Language | Codec | Channels[ | Type]"
#   "English | AC-3 | 5.1", "English | TrueHD Atmos | 7.1",
#   "English | AC-3 | 2.0 | Commentary"
# Built from the properties of the OUTPUT track (codec, profile,
# channels, layout, language tag, dispositions); the old title only
# contributes its descriptive rest (commentary, mix names, ...), never a
# codec, channel or object-audio claim. Unknown parts are left out
# (language "und"), or say only what is known ("6ch" for 6 channels
# without a speaker layout); nothing is invented.
# ------------------------------------------------------------

# ISO 639-2 (B and T) / 639-1 codes -> English language name
declare -gA AUDIO_LANG_NAMES=(
    [eng]=English [en]=English [jpn]=Japanese [ja]=Japanese
    [fre]=French [fra]=French [fr]=French [ger]=German [deu]=German [de]=German
    [spa]=Spanish [es]=Spanish [ita]=Italian [it]=Italian
    [por]=Portuguese [pt]=Portuguese [rus]=Russian [ru]=Russian
    [chi]=Chinese [zho]=Chinese [zh]=Chinese [cmn]=Mandarin [yue]=Cantonese
    [kor]=Korean [ko]=Korean [hin]=Hindi [hi]=Hindi [ara]=Arabic [ar]=Arabic
    [dut]=Dutch [nld]=Dutch [nl]=Dutch [swe]=Swedish [sv]=Swedish
    [nor]=Norwegian [no]=Norwegian [nob]="Norwegian Bokmal" [nb]="Norwegian Bokmal"
    [nno]="Norwegian Nynorsk" [nn]="Norwegian Nynorsk"
    [dan]=Danish [da]=Danish [fin]=Finnish [fi]=Finnish [pol]=Polish [pl]=Polish
    [cze]=Czech [ces]=Czech [cs]=Czech [slo]=Slovak [slk]=Slovak [sk]=Slovak
    [hun]=Hungarian [hu]=Hungarian [gre]=Greek [ell]=Greek [el]=Greek
    [tur]=Turkish [tr]=Turkish [heb]=Hebrew [he]=Hebrew [tha]=Thai [th]=Thai
    [vie]=Vietnamese [vi]=Vietnamese [ind]=Indonesian [id]=Indonesian
    [may]=Malay [msa]=Malay [ms]=Malay [fil]=Filipino [tgl]=Tagalog [tl]=Tagalog
    [tam]=Tamil [ta]=Tamil [tel]=Telugu [te]=Telugu [ben]=Bengali [bn]=Bengali
    [mar]=Marathi [mr]=Marathi [kan]=Kannada [kn]=Kannada [mal]=Malayalam [ml]=Malayalam
    [pan]=Punjabi [pa]=Punjabi [guj]=Gujarati [gu]=Gujarati [urd]=Urdu [ur]=Urdu
    [per]=Persian [fas]=Persian [fa]=Persian [ukr]=Ukrainian [uk]=Ukrainian
    [rum]=Romanian [ron]=Romanian [ro]=Romanian [bul]=Bulgarian [bg]=Bulgarian
    [hrv]=Croatian [hr]=Croatian [srp]=Serbian [sr]=Serbian [slv]=Slovenian [sl]=Slovenian
    [bos]=Bosnian [bs]=Bosnian [mac]=Macedonian [mkd]=Macedonian [mk]=Macedonian
    [est]=Estonian [et]=Estonian [lav]=Latvian [lv]=Latvian [lit]=Lithuanian [lt]=Lithuanian
    [ice]=Icelandic [isl]=Icelandic [is]=Icelandic [cat]=Catalan [ca]=Catalan
    [baq]=Basque [eus]=Basque [eu]=Basque [glg]=Galician [gl]=Galician
    [gle]=Irish [ga]=Irish [wel]=Welsh [cym]=Welsh [cy]=Welsh
    [afr]=Afrikaans [af]=Afrikaans [swa]=Swahili [sw]=Swahili [zul]=Zulu [zu]=Zulu
    [lat]=Latin [la]=Latin [mul]=Multiple
)

# audio_lang_name CODE  ->  "English"; "" for none / und / zxx / mis;
# an unlisted code is shown as it is (never guessed)
audio_lang_name() {
    local c="${1,,}"

    c="${c%%[-_]*}"                       # en-US -> en
    case "$c" in
        ""|-|und|zxx|mis) return 0 ;;
    esac
    printf '%s' "${AUDIO_LANG_NAMES[$c]:-$1}"
}

# audio_codec_name CODEC PROFILE OBJECT  ->  "AC-3", "TrueHD Atmos",
# "DTS-HD MA", ... OBJECT: audio_object_kind of the track ("" = none)
audio_codec_name() {
    local codec="$1" profile="${2:-}" object="${3:-}" l

    [[ "$profile" == "-" || "$profile" == unknown ]] && profile=""
    case "$codec" in
        ""|-|unknown) return 0 ;;
        dts)
            # FFmpeg's profile names the DTS kind: "DTS-HD MA", "DTS-HD
            # MA + DTS:X", "DTS-ES", "DTS 96/24", "DTS Express"
            if [[ "$profile" == DTS* ]]; then l="$profile"; else l=DTS; fi
            [[ "$object" == DTS:X* && "$l" != *DTS:X* ]] && l+=" + DTS:X"
            ;;
        aac)
            case "$profile" in
                HE-AACv2) l="HE-AAC v2" ;;
                HE-AAC)   l="HE-AAC" ;;
                *)        l="AAC" ;;
            esac
            ;;
        *)  l=$(codec_title_label "$codec") ;;
    esac
    [[ "$object" == "Dolby Atmos"* && "$codec" =~ ^(truehd|eac3)$ ]] && l+=" Atmos"
    printf '%s' "$l"
}

# audio_channel_notation LAYOUT CHANNELS  ->  "5.1", "2.0", "7.1.4";
# "6ch" when the layout is unknown (1 / 2 channels: "1.0" / "2.0") or
# does not have CHANNELS channels
audio_channel_notation() {
    local l="${1:-}" n="${2:-}" r="" c
    local -a list=()
    local main=0 lfe=0 h=0

    case "$l" in
        mono)                                   r=1.0 ;;
        stereo|downmix|binaural)                r=2.0 ;;
        2.1)                                    r=2.1 ;;
        3.0|"3.0(back)")                        r=3.0 ;;
        4.0|quad|"quad(side)")                  r=4.0 ;;
        3.1)                                    r=3.1 ;;
        5.0|"5.0(side)")                        r=5.0 ;;
        4.1)                                    r=4.1 ;;
        5.1|"5.1(side)")                        r=5.1 ;;
        6.0|"6.0(front)"|hexagonal)             r=6.0 ;;
        6.1|"6.1(back)"|"6.1(front)")           r=6.1 ;;
        7.0|"7.0(front)")                       r=7.0 ;;
        7.1|"7.1(wide)"|"7.1(wide-side)")       r=7.1 ;;
        octagonal)                              r=8.0 ;;
        3.1.2|5.1.2|5.1.4|7.1.2|7.1.4|7.2.3|9.1.4|9.1.6|22.2) r="$l" ;;
        "5.1.2(back)"|"5.1.4(back)"|"7.1.2(wide)"|"7.1.4(back)") r="${l%%(*}" ;;
        cube)                                   r=4.0.4 ;;
        hexadecagonal)                          r=16.0 ;;
        *)
            # "6 channels (FL+FR+...)" / "FL+FR+...": count the speakers
            [[ "$l" =~ \(([A-Z0-9+]+)\)$ ]] && l="${BASH_REMATCH[1]}"
            if [[ "$l" =~ ^[A-Z0-9]+(\+[A-Z0-9]+)*$ ]]; then
                IFS=+ read -ra list <<< "$l"
                for c in "${list[@]}"; do
                    case "$c" in
                        LFE|LFE2|LFE3)                      ((lfe += 1)) ;;
                        TFL|TFR|TFC|TC|TBL|TBR|TBC|TSL|TSR) ((h += 1)) ;;
                        *)                                  ((main += 1)) ;;
                    esac
                done
                r="$main.$lfe"
                (( h > 0 )) && r+=".$h"
            fi
            ;;
    esac

    # the notation must add up to the channel count
    if [[ -n "$r" && "$n" =~ ^[0-9]+$ ]]; then
        c=0
        IFS=. read -ra list <<< "$r"
        for main in "${list[@]}"; do ((c += main)); done
        (( c == n )) || r=""
    fi
    # no stored layout (Matroska PCM never has one): 1 and 2 channels have
    # only one standard order (mono / stereo); more are not guessed
    if [[ -z "$r" && ( -z "${1:-}" || "$1" == - || "$1" == unknown ) ]]; then
        case "$n" in 1) r=1.0 ;; 2) r=2.0 ;; esac
    fi
    if [[ -z "$r" && "$n" =~ ^[1-9][0-9]*$ ]]; then
        r="${n}ch"
    fi
    printf '%s' "$r"
}

# Release information in a track title (resolution, source, video codec,
# dynamic range), as one lower-case token: never part of an audio
# description. Only tokens that cannot be ordinary words of a
# description ("Complete", "Hybrid", initials such as "DV" can be part
# of a commentary credit: they are not listed).
AUDIO_DESC_RELEASE_RE='^(4320p|2160p|1440p|1080[pi]|720p|576[pi]|480[pi]|4k|8k|uhd|blu-?ray|bdremux|bdrip|brrip|remux|web-?dl|web-?rip|webrip|hdtv|hdrip|dvdrip|hevc|avc|av1|vp9|[xh]\.?26[45]|hdr10|hdr10\+|hdr10plus|dovi|(8|10)-?bit)$'

# _audio_desc_strip_release TEXT  ->  TEXT without release information:
# AUDIO_DESC_RELEASE_RE tokens and a release group tag: "-FGT" as the
# last word, "[FGT]" / "{FGT}" as the first or last word (upper-case
# letters / digits, 2-8 characters: a credit such as "[John Smith]" or
# "-nolan" is not one)
_audio_desc_strip_release() {
    local t="${1:-}" w lw out=() n i

    [[ -n "$t" ]] || return 0
    read -ra w <<< "$t"
    n=${#w[@]}
    for ((i = 0; i < n; i++)); do
        lw="${w[$i],,}"
        lw="${lw#[\[\(\{]}"; lw="${lw%[\]\)\},;:]}"
        [[ "$lw" =~ $AUDIO_DESC_RELEASE_RE ]] && continue
        (( i == n - 1 )) && [[ "${w[$i]}" =~ ^-[A-Z0-9]{2,8}$ ]] && continue
        (( i == 0 || i == n - 1 )) && [[ "${w[$i]}" =~ ^[\[\{][A-Z0-9]{2,8}[\]\}]$ ]] && continue
        out+=("${w[$i]}")
    done
    printf '%s' "${out[*]-}"
}

# audio_desc_meaningful TEXT  ->  0 when the (lower-case) rest of a title
# names a distinction worth keeping: commentary, audio description /
# narration, SDH, a mix / version / cut, an isolated score, a dub, or a
# regional language variant (Latin American Spanish, Castilian, ...)
audio_desc_meaningful() {
    local t="${1,,}"

    [[ "$t" =~ comment|kommentar|descri|narrat|(^|[^a-z])(ad|sdh|alt|m\&e|cut|ost)($|[^a-z])|hearing|dialog|mix|theatrical|theat(er|re)|original|home\ ?video|remaster|restor|alternat|isolated|score|music|effects|dub|karaoke|instrumental|cast|director|crew|writer|producer|bonus|extended|edition|version|imax|latin|castilian|european|brazil|canad|quebec|parisian|flemish|swiss|simplified|traditional|mandarin|cantonese ]] ||
    [[ "$1" == *副音声* || "$1" == *解説* || "$1" == *コメンタリー* || "$1" == *吹替* || "$1" == *オリジナル* ]]
}

# _audio_title_rest TITLE LANG_CODE  ->  the descriptive rest of TITLE,
# exactly as written: every codec / object-audio / channel / rate /
# bit-depth / sample-rate claim, the track's own language and release
# information removed, connectors left at either end dropped; "" when
# only filler remains ("Audio", "Surround", "Track 2", ...)
_audio_title_rest() {
    local t="${1:-}" code="${2:-}" name re="" r

    [[ "$t" == "-" ]] && t=""
    [[ -n "$t" ]] || return 0
    name=$(audio_lang_name "$code")
    code="${code,,}"; code="${code%%[-_]*}"
    for r in "${name,,}" "$code"; do
        [[ -n "$r" && "$r" != - && "$r" =~ ^[a-z\ ]+$ ]] && re+="${re:+|}$r"
    done

    # release text: in the title as written (a group tag is a word of its
    # own there) and in what is left once the claims are removed
    r=$(_audio_title_awk residue "$(_audio_desc_strip_release "$t")" "" "" "" "" "$re")
    r=$(_audio_desc_strip_release "$r")
    # connectors left over from removed claims ("TrueHD with Atmos" ->
    # "with"): dropped at either end; inside the text they stay
    local conn='(with|and|plus|in|on|feat\.?|featuring|w/|&|\+)' sep='[][[:space:]|/,;:@()-]'
    while [[ "${r,,}" =~ ^${conn}(${sep}+|$) ]]; do
        r="${r:${#BASH_REMATCH[0]}}"
    done
    while [[ "${r,,}" =~ (^|${sep}+)${conn}$ ]]; do
        r="${r:0:$(( ${#r} - ${#BASH_REMATCH[0]} ))}"
    done
    # separators at either end; a bracket that closes / opens one inside
    # the text stays ("Commentary (Complete)", "[John Smith] Commentary")
    while [[ "$r" =~ ^${sep} ]]; do
        [[ ( "${r:0:1}" == "(" && "$r" == *")"* ) || ( "${r:0:1}" == "[" && "$r" == *"]"* ) ]] && break
        r="${r:1}"
    done
    while [[ "$r" =~ ${sep}$ ]]; do
        [[ ( "${r: -1}" == ")" && "$r" == *"("* ) || ( "${r: -1}" == "]" && "$r" == *"["* ) ]] && break
        r="${r:0:$(( ${#r} - 1 ))}"
    done
    [[ "${r,,}" =~ ^((main|original)\ )?(audio|sound|track|surround|audio\ track)(\ #?[0-9]+)?$ ]] && r=""
    printf '%s' "$r"
}

# audio_title_unparsed TITLE LANG_CODE  ->  the rest of TITLE that was
# not understood with confidence: a rest that is no recognised
# description (a name, a credit without "commentary", ...), or one that
# is not found verbatim in TITLE (removing claims from the middle of it,
# or a dotted name such as "D.V.", would change the wording); "" when
# the whole title was understood. A title with such a rest is never
# rewritten (audio_std_title keeps it) and is reported for a check.
audio_title_unparsed() {
    local r

    r=$(_audio_title_rest "$1" "${2:-}")
    [[ -n "$r" ]] || return 0
    if ! audio_desc_meaningful "$r" || [[ "$1" != *"$r"* ]]; then
        printf '%s' "$r"
    fi
    return 0
}

# audio_title_warning TITLE LANG_CODE  ->  the warning for a title whose
# description is not understood ("" = none): the same text everywhere
# (compression jobs, verify.sh, audio_titles.sh)
audio_title_warning() {
    local u

    u=$(audio_title_unparsed "$1" "${2:-}")
    [[ -n "$u" ]] && printf 'description "%s" not recognised: kept as written, check manually' "$u"
    return 0
}

# audio_title_description TITLE LANG_CODE COMMENT HI VI  ->  the Type
# part(s): the descriptive rest of TITLE, kept exactly as written
# (commentary credits included), plus what the dispositions say when the
# rest does not already say it. " | "-separated; "" = none.
audio_title_description() {
    local r lc
    local -a parts=()

    r=$(_audio_title_rest "${1:-}" "${2:-}")
    lc="${r,,}"
    [[ -n "$r" ]] && parts+=("$r")

    [[ "${3:-0}" == 1 && "$lc" != *comment* ]] && parts+=("Commentary")
    [[ "${5:-0}" == 1 && ! "$lc" =~ descri|narrat|(^|[^a-z])ad($|[^a-z]) ]] && parts+=("Descriptive Audio")
    [[ "${4:-0}" == 1 && ! "$lc" =~ hearing|sdh|(^|[^a-z])hi($|[^a-z])|dialog ]] && parts+=("Hearing Impaired")

    _title_join "${parts[@]+"${parts[@]}"}"
}

# audio_title_ex TITLE  ->  0 when TITLE claims Dolby Digital EX ("Dolby
# Digital EX", "DD EX", "DD5.1 EX", "AC-3 EX", "Surround EX"): the same
# rule as the "ex" claim of _audio_title_awk
audio_title_ex() {
    local t="${1,,}"

    [[ "$t" =~ (^|[^a-z])(dolby\ digital(\ plus)?|dd\+?|ddp|e?-?ac-?3)[^a-z]*([0-9][.][0-9][^a-z]*)?(surround[\ -])?ex([^a-z]|$) ||
       "$t" =~ (^|[^a-z])surround[\ -]ex([^a-z]|$) ]]
}

# _title_join PART...  ->  "PART | PART | ..."
_title_join() {
    local o="" p

    for p in "$@"; do
        o+="${o:+ | }$p"
    done
    printf '%s' "$o"
}

# audio_std_title LANG CODEC PROFILE CHANNELS LAYOUT OLD_TITLE COMMENT
#                 HI VI COPIED [KBPS]
#   ->  "English | AC-3 | 5.1 | 640 kbps | Commentary"
# COPIED=1: the stream is copied, so object audio named only in the old
# title (older FFmpeg, see audio_object_kind) still describes it; a
# transcoded track never has object audio. KBPS: the bit rate of the
# track (audio_title_kbps; "" = unknown: left out).
# An old title whose description cannot be parsed with confidence
# (audio_title_unparsed) is kept: a copied track keeps it unchanged; a
# transcoded one (whose old codec / channel claims would be untrue) gets
# the standard title with that text kept verbatim as its description.
audio_std_title() {
    local old="${6:-}" object="" out=() p cname kbps="${11:-}"

    [[ "$old" == "-" ]] && old=""
    if [[ -n "$old" && "${10:-0}" == 1 && -n "$(audio_title_unparsed "$old" "$1")" ]]; then
        printf '%s' "$old"
        return 0
    fi
    cname=$(audio_codec_name "$2" "$3")
    if [[ "${10:-0}" == 1 ]]; then
        object=$(audio_object_kind "$2" "$3" "$old")
        cname=$(audio_codec_name "$2" "$3" "$object")
        # Dolby Digital EX is a flag in the AC-3 stream FFmpeg does not
        # report: kept from the old title of an unchanged (copied) AC-3 /
        # E-AC-3 track, never invented, dropped by a transcode
        [[ "$2" =~ ^(ac3|eac3)$ ]] && audio_title_ex "$old" && cname+=" EX"
    fi

    [[ "$kbps" =~ ^[1-9][0-9]*$ ]] && kbps+=" kbps" || kbps=""
    for p in "$(audio_lang_name "$1")" "$cname" \
             "$(audio_channel_notation "$5" "$4")" "$kbps" \
             "$(audio_title_description "$old" "$1" "${7:-0}" "${8:-0}" "${9:-0}")"; do
        [[ -n "$p" ]] && out+=("$p")
    done

    _title_join "${out[@]+"${out[@]}"}"
}

# audio_title_kbps CODEC PROFILE BIT_RATE BITS_PER_RAW_SAMPLE SAMPLE_RATE
#                  CHANNELS [MEASURED_KBPS]  ->  whole kb/s for the title
# The constant rate the stream itself states (AC-3 / E-AC-3 / DTS core /
# PCM, audio_title_stream_facts), else MEASURED_KBPS (the average of the
# actual packets: statistics tags / packet scan, audio_measured_kbps);
# "" when neither is known. A variable-rate stream's bit_rate field (the
# DTS core rate of DTS-HD MA, ...) is never used.
audio_title_kbps() {
    local n

    read -r n _ <<< "$(audio_title_stream_facts "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}")"
    if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        printf '%d' $(( (n + 500) / 1000 ))
    elif [[ "${7:-}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%d' "$7"
    fi
    return 0
}

# audio_title_facts FILE  ->  "index<TAB>bit_rate<TAB>bits_per_raw_sample
# <TAB>sample_rate" per audio stream ("" = not reported)
audio_title_facts() {
    # key=value: ffprobe prints csv fields in its own order
    ffprobe -v error -select_streams a \
        -show_entries stream=index,bit_rate,bits_per_raw_sample,sample_rate \
        -of default=nw=1 "$1" 2>/dev/null |
    awk -F= '
        function flush() { if (i != "") printf "%s\t%s\t%s\t%s\n", i, v["bit_rate"], v["bits_per_raw_sample"], v["sample_rate"] }
        { sub(/\r$/, "") }
        $1 == "index" { flush(); i = $2; split("", v); next }
        { v[$1] = ($2 ~ /^[0-9]+$/) ? $2 : "" }
        END { flush() }'
}

# audio_measured_kbps STATS_LINES  ->  "index<TAB>kbps" per audio stream
# of stats_load's STATS_LINES (statistics tags or packet scan of the
# actual file; kbps whole kb/s)
audio_measured_kbps() {
    awk '$2 == "audio" && $5 ~ /^[0-9]+$/ && $5 > 0 { printf "%s\t%s\n", $1, $5 }' <<< "${1:-}"
}

# audio_std_title_plan FILE [OVERRIDES]
#   ->  "src_index<TAB>old title<TAB>new title" for every audio track of
#       FILE (source order; old "-" = none). OVERRIDES: lines
#       "src_index<TAB>codec<TAB>profile<TAB>channels<TAB>layout[<TAB>kbps]"
#       with the output properties of transcoded tracks (kbps: the
#       encoder's rate; only titled for a constant rate codec); every
#       other track is copied (its own properties and its stated constant
#       rate). The rate of a variable-rate track is only known after the
#       mux: item_finalize_titles adds it.
audio_std_title_plan() {
    local file="$1" i=0 oc op och ol ok copied kbps br raw sr
    local -a f o
    local -A ov=() fact=()

    while IFS=$'\t' read -r -a o; do
        [[ "${o[0]:-}" =~ ^[0-9]+$ ]] && ov[${o[0]}]="${o[1]:--}"$'\t'"${o[2]:--}"$'\t'"${o[3]:--}"$'\t'"${o[4]:--}"$'\t'"${o[5]:--}"
    done <<< "${2:-}"

    while IFS=$'\t' read -r -a o; do
        [[ "${o[0]:-}" =~ ^[0-9]+$ ]] && fact[${o[0]}]="${o[1]:-}|${o[2]:-}|${o[3]:-}"
    done < <(audio_title_facts "$file")

    while IFS=$'\t' read -r -a f; do
        oc="${f[2]}" op="${f[3]}" och="${f[4]}" ol="${f[5]}" copied=1
        IFS='|' read -r br raw sr <<< "${fact[${f[0]}]:-||}"
        if [[ -n "${ov[$i]:-}" ]]; then
            IFS=$'\t' read -r oc op och ol ok <<< "${ov[$i]}"
            copied=0
            # the encoder's rate is the stream's rate for CBR codecs only
            br="" raw=""
            [[ "$oc" =~ ^(ac3|eac3|mp2)$ && "$ok" =~ ^[0-9]+$ ]] && br=$(( ok * 1000 ))
        fi
        kbps=$(audio_title_kbps "$oc" "$op" "$br" "$raw" "$sr" "$och")
        printf '%s\t%s\t%s\n' "$i" "${f[13]}" \
            "$(audio_std_title "${f[12]}" "$oc" "$op" "$och" "$ol" "${f[13]}" "${f[8]}" "${f[9]}" "${f[10]}" "$copied" "$kbps")"
        ((i += 1))
    done < <(_audio_rows "$file")
}

# audio_std_title_args FILE [OVERRIDES]  ->  shell-quoted
# -metadata:s:a:N title=... for EVERY audio track (N: the output audio
# index, MAP_AUDIO_OUT of build_stream_map; the same index without it).
# Always set, so MP4 track names (handler_name) become MKV titles too.
# Metadata only: no stream is re-encoded for it.
audio_std_title_args() {
    local i old new a=()

    while IFS=$'\t' read -r i old new; do
        [[ -n "$new" ]] && a+=("-metadata:s:a:${MAP_AUDIO_OUT[$i]:-$i}" "title=$new")
    done < <(audio_std_title_plan "$1" "${2:-}")

    (( ${#a[@]} )) && printf '%q ' "${a[@]}"
    return 0
}

# ------------------------------------------------------------
# Standard titles of an existing file (finalization / verification)
# ------------------------------------------------------------

# mkv_std_track_titles FILE [CRF [TRANSCODED [MEASURED [audio]]]]
#   ->  "ffmpeg_index<TAB>video|audio<TAB>current title<TAB>standard
#       title" for the main video and every audio track of FILE, built
#       from the streams of FILE itself (current "-" = none; an empty
#       standard title: nothing known to build one from).
# CRF: of the main video (video_std_title_of: a value, "auto", "").
# TRANSCODED: FFmpeg stream indexes (comma / space list) of audio tracks
# that were re-encoded (object audio named only in a title is not kept
# for them). MEASURED: "index<TAB>kbps" lines (audio_measured_kbps) for
# tracks without a stated constant rate. The current title only lends
# an audio track its description (audio_title_description). "audio":
# the audio tracks only (no video probe at all: stream headers only).
mkv_std_track_titles() {
    local file="$1" crf="${2:-}" vidx t idx kbps br raw sr copied
    local -a f
    local -A trans=() meas=() fact=()

    for idx in ${3:+${3//,/ }}; do trans[$idx]=1; done
    while IFS=$'\t' read -r idx kbps; do
        [[ "$idx" =~ ^[0-9]+$ ]] && meas[$idx]="$kbps"
    done <<< "${4:-}"

    vidx=""
    [[ "${5:-}" == audio ]] || vidx=$(main_video_index "$file")
    if [[ -n "$vidx" ]]; then
        t="-"
        while IFS=$'\t' read -r -a f; do
            [[ "${f[0]}" == "$vidx" ]] && { t="${f[13]}"; break; }
        done < <(stream_meta "$file")
        printf '%s\tvideo\t%s\t%s\n' "$vidx" "$t" "$(video_std_title_of "$file" "$vidx" "$crf")"
    fi

    while IFS=$'\t' read -r -a f; do
        [[ "${f[0]:-}" =~ ^[0-9]+$ ]] && fact[${f[0]}]="${f[1]:-}|${f[2]:-}|${f[3]:-}"
    done < <(audio_title_facts "$file")

    while IFS=$'\t' read -r -a f; do
        IFS='|' read -r br raw sr <<< "${fact[${f[0]}]:-||}"
        copied=1
        [[ -n "${trans[${f[0]}]:-}" ]] && copied=0
        kbps=$(audio_title_kbps "${f[2]}" "${f[3]}" "$br" "$raw" "$sr" "${f[4]}" "${meas[${f[0]}]:-}")
        printf '%s\taudio\t%s\t%s\n' "${f[0]}" "${f[13]}" \
            "$(audio_std_title "${f[12]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "${f[13]}" \
                "${f[8]}" "${f[9]}" "${f[10]}" "$copied" "$kbps")"
    done < <(_audio_rows "$file")
}

# mkv_write_track_titles FILE WANT_ARRAY_NAME
#
# Writes track names into the MKV FILE with mkvpropedit: WANT is an
# associative array FFmpeg stream index -> title ("-" removes it).
# Track names only: no remux, no stream data, no other metadata touched.
# FFmpeg streams are matched to Matroska track numbers by MKVToolNix
# identification first (mkv_track_map; the numberings are never assumed
# to line up); tracks the two cannot tell apart must all get the same
# title. Nothing is written unless the mapping is certain. The titles are
# read back through MKVToolNix and FFmpeg.
# Returns 0 (written and read back; nothing to write is success too),
# 3 MKVToolNix missing, 4 mapping not certain, 5 identical tracks need
# different titles, 6 a stream has no Matroska track, 7 mkvpropedit
# failed, 8 the read-back differs; MKV_TITLES_MSG says why.
mkv_write_track_titles() {
    local file="$1" map ffi nums x
    local -n W="$2"
    local -a edits=() f
    local -A gwant=() byno=()

    MKV_TITLES_MSG=""
    (( ${#W[@]} )) || return 0
    if ! command -v mkvpropedit >/dev/null 2>&1 || ! command -v mkvmerge >/dev/null 2>&1; then
        MKV_TITLES_MSG="MKVToolNix (mkvpropedit / mkvmerge) not found"
        return 3
    fi
    if ! map=$(mkv_track_map "$file"); then
        MKV_TITLES_MSG="track mapping not certain (${map#ERR$'\t'})"
        return 4
    fi
    while IFS=$'\t' read -r ffi nums; do
        [[ -n "$ffi" ]] || continue
        x="${W[$ffi]-$'\001'}"
        if [[ -n "${gwant[$nums]+x}" && "${gwant[$nums]}" != "$x" ]]; then
            MKV_TITLES_MSG="tracks $nums look identical but need different titles"
            return 5
        fi
        gwant[$nums]="$x"
    done <<< "$map"
    for ffi in "${!W[@]}"; do
        grep -q "^$ffi"$'\t' <<< "$map" || {
            MKV_TITLES_MSG="FFmpeg stream $ffi has no Matroska track"
            return 6
        }
    done
    for nums in "${!gwant[@]}"; do
        [[ "${gwant[$nums]}" != $'\001' ]] || continue
        IFS=, read -ra f <<< "$nums"
        for x in "${f[@]}"; do
            byno[$x]="${gwant[$nums]}"
            if [[ "${gwant[$nums]}" == "-" ]]; then
                edits+=(--edit "track:@$x" --delete name)
            else
                edits+=(--edit "track:@$x" --set "name=${gwant[$nums]}")
            fi
        done
    done

    if ! mkvpropedit "$file" "${edits[@]}" > /dev/null 2>&1; then
        MKV_TITLES_MSG="mkvpropedit failed"
        return 7
    fi

    # read back, by Matroska track number (MKVToolNix) and by FFmpeg stream
    local bad=0
    while IFS=$'\t' read -r -a f; do
        [[ -n "${byno[${f[2]}]+x}" && "${f[8]}" != "${byno[${f[2]}]}" ]] && bad=1
    done < <(mkv_identify_tracks "$file")
    while IFS=$'\t' read -r -a f; do
        [[ -n "${W[${f[0]}]+x}" && "${f[13]}" != "${W[${f[0]}]}" ]] && bad=1
    done < <(stream_meta "$file")
    if (( bad == 1 )); then
        MKV_TITLES_MSG="written, but the read-back differs"
        return 8
    fi
    return 0
}

# ------------------------------------------------------------
# Standard video track titles:
#   "Codec | Resolution | Bit Depth | HDR Format | CRF Value"
#   "HEVC | 2160p | 10-bit | Dolby Vision + HDR10 | CRF 18",
#   "HEVC | 1080p | 10-bit | HDR10 | CRF 22", "AVC | 720p | 8-bit"
# Built from the properties of the OUTPUT stream only; the old title
# (usually a movie or release name) contributes nothing. Unknown or
# inapplicable parts are left out: no HDR format for SDR, no CRF unless
# the encode is known (the job's CRF, or the x265 settings stored in the
# stream). The compression tier is never part of it.
# ------------------------------------------------------------

# video_codec_label CODEC  ->  "HEVC", "AVC", "AV1", ... ("" unknown)
video_codec_label() {
    case "${1:-}" in
        ""|-|unknown) ;;
        hevc)       echo HEVC ;;
        h264)       echo AVC ;;
        av1)        echo AV1 ;;
        vp9)        echo VP9 ;;
        vp8)        echo VP8 ;;
        mpeg2video) echo MPEG-2 ;;
        mpeg1video) echo MPEG-1 ;;
        mpeg4)      echo MPEG-4 ;;
        vc1)        echo VC-1 ;;
        *)          echo "${1^^}" ;;
    esac
}

# video_resolution_label WIDTHxHEIGHT [FIELD_ORDER]  ->  "2160p", "1080p",
# "1080i", "576p", ... ("" unknown). Named by the frame size the way
# release names do: a letterboxed / cropped 1920x800 frame is 1080p, a
# 3840x1600 frame 2160p (the same classes _video_title_awk accepts).
# Interlaced only when the stream says so (tt / bb / tb / bt).
video_resolution_label() {
    local w h s="p"

    [[ "${1:-}" =~ ^([0-9]+)x([0-9]+)$ ]] || return 0
    w="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}"
    (( w > 0 && h > 0 )) || return 0
    [[ "${2:-}" =~ ^(tt|bb|tb|bt)$ ]] && s="i"

    if   (( w >= 6000 || h >= 3400 )); then echo 4320p
    elif (( w >= 3000 || h >= 1500 )); then echo 2160p
    elif (( w >= 2200 || h >= 1250 )); then echo 1440p
    elif (( w >= 1500 || h >= 900 ));  then echo "1080$s"
    elif (( w >= 1000 || h >= 600 ));  then echo 720p
    else echo "$h$s"
    fi
}

# video_hdr_label HDR_KIND DV DV_PROFILE HDR10PLUS  ->  "HDR10",
# "HDR10+", "HLG", "Dolby Vision + HDR10", "Dolby Vision" (profile 5:
# no HDR10 base layer); "" for SDR. HDR10PLUS: 1 = present.
video_hdr_label() {
    local kind="${1:-}" dv="${2:-0}" prof="${3:-}" base=""

    case "$kind" in
        HDR10) base=HDR10; [[ "${4:-0}" == 1 ]] && base="HDR10+" ;;
        HLG)   base=HLG ;;
    esac
    if [[ "$dv" == 1 ]]; then
        [[ "$prof" == 5 ]] && base=""
        printf 'Dolby Vision%s' "${base:+ + $base}"
    else
        printf '%s' "$base"
    fi
}

# video_crf_label CRF  ->  "CRF 22" / "CRF 21.5" ("" when not a CRF)
video_crf_label() {
    local c="${1:-}"

    [[ "$c" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    if [[ "$c" == *.* ]]; then
        while [[ "$c" == *0 ]]; do c="${c%0}"; done
        c="${c%.}"
    fi
    printf 'CRF %s' "$c"
}

# video_std_title CODEC RES BITS HDR_KIND DV DV_PROFILE HDR10PLUS CRF
#                 [FIELD_ORDER]
#   ->  "HEVC | 1080p | 10-bit | HDR10 | CRF 22"
# RES: "WIDTHxHEIGHT"; BITS: video_pix_bits; CRF: "" = not known.
video_std_title() {
    local out=() p bits=""

    [[ "${3:-}" =~ ^[0-9]+$ ]] && bits="${3}-bit"
    for p in "$(video_codec_label "$1")" "$(video_resolution_label "${2:-}" "${9:-}")" "$bits" \
             "$(video_hdr_label "${4:-}" "${5:-0}" "${6:-}" "${7:-0}")" "$(video_crf_label "${8:-}")"; do
        [[ -n "$p" ]] && out+=("$p")
    done
    _title_join "${out[@]+"${out[@]}"}"
}

# video_stream_crf FILE VIDX  ->  the CRF the video stream was encoded
# with, from reliable records only: the x265 settings the encoder wrote
# into the stream (rate control "crf"), else, when the stream carries no
# x265 settings at all, the COMPRESSION_CRF tag a movie-compresser encode
# recorded for it. "" otherwise (two-pass / ABR, another encoder,
# nothing recorded): a CRF is never guessed.
video_stream_crf() {
    local rc crf tool

    rc=$(x265_rate_control "$1" "$2")
    case "$rc" in
        "crf "*) printf '%s' "${rc#crf }"; return 0 ;;
        ?*)      return 0 ;;
    esac
    [[ "$(ffprobe -v error -select_streams "$2" -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$1" 2>/dev/null | tr -d '\r')" == hevc ]] || return 0
    IFS=$'\t' read -r crf _ <<< "$(compression_tags "$1")"
    IFS=$'\t' read -r tool _ <<< "$(compression_provenance "$1")"
    [[ "$tool" == "$COMPRESSION_TOOL_NAME" && "$crf" =~ ^[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$crf"
    return 0
}

# video_std_title_of FILE VIDX [CRF]  ->  the standard title of video
# stream VIDX of FILE, from the stream itself (codec, frame size, bit
# depth, field order, HDR / Dolby Vision / HDR10+ via probe_hdr). CRF:
# a value (the job's final CRF), "auto" (video_stream_crf) or "" (none).
# Runs probe_hdr in a subshell: the caller's HDR_* globals are kept.
video_std_title_of() {
    local file="$1" vidx="$2" crf="${3:-}" k v codec="" pix="" w="" h="" fo=""

    while IFS='=' read -r k v; do
        v="${v%$'\r'}"
        case "$k" in
            codec_name)  codec="$v" ;;
            pix_fmt)     pix="$v" ;;
            width)       w="$v" ;;
            height)      h="$v" ;;
            field_order) fo="$v" ;;
        esac
    done < <(ffprobe -v error -select_streams "$vidx" \
        -show_entries stream=codec_name,pix_fmt,width,height,field_order -of default=nw=1 "$file" 2>/dev/null)
    [[ -n "$codec" ]] || return 0
    [[ "$crf" == auto ]] && crf=$(video_stream_crf "$file" "$vidx")

    (
        probe_hdr "$file" "$vidx"
        video_std_title "$codec" "${w}x${h}" "$(video_pix_bits "$pix")" "$HDR_KIND" \
            "$HDR_DV" "$HDR_DV_PROFILE" "$HDR_HDR10PLUS" "$crf" "$fo"
    )
}

# _video_title_arg TITLE  ->  shell-quoted -metadata:s:v:0 title=TITLE
# ("-" or "": no standard title can be built; the source title stays)
_video_title_arg() {
    [[ -n "$1" && "$1" != "-" ]] || return 0
    printf '%q ' -metadata:s:v:0 "title=$1"
}

# ------------------------------------------------------------
# Claims in an existing video title the stream disproves (codec,
# resolution, HDR / Dolby Vision / HDR10+, bit depth): verify.sh and the
# job verification report them as STALE.
# ------------------------------------------------------------

# video_pix_bits PIX_FMT  ->  8 / 10 / 12 ("" unknown)
video_pix_bits() {
    case "${1:-}" in
        ""|-|unknown)                    ;;
        *p10|*p10le|*p10be|p010*)        echo 10 ;;
        *p12|*p12le|*p12be|p012*)        echo 12 ;;
        yuv*|yuvj*|nv12|nv21|gray|rgb24|bgr24) echo 8 ;;
    esac
}

# _video_title_awk MODE TITLE CODEC RES HDR DV HDR10P BITS
#   MODE check: the claims in TITLE the stream disproves ("" = none)
#   MODE rewrite: TITLE without them ("" when nothing is left)
# CODEC: ffprobe codec_name; RES: "WIDTHxHEIGHT"; HDR: HDR_KIND (SDR /
# HDR10 / HLG); DV: 1 / 0; HDR10P: 1 / 0 / ? (not seen in the probed frames:
# proves nothing); BITS: video_pix_bits. An unknown property ("")
# disproves nothing.
_video_title_awk() {
    # the title in the environment (awk -v would interpret backslashes)
    VT_TITLE="$2" awk -v mode="$1" -v codec="$3" -v res="$4" -v hdr="$5" -v dv="$6" -v h10p="$7" -v bits="$8" '
        BEGIN {
            t = ENVIRON["VT_TITLE"]
            n = 0
            P[++n] = "dolby ?vision|dovi";        C[n] = "dv"
            P[++n] = "dv";                        C[n] = "dv"
            P[++n] = "hdr10 ?(\\+|plus)";         C[n] = "h10p"
            P[++n] = "hdr10";                     C[n] = "hdr10"
            P[++n] = "hlg";                       C[n] = "hlg"
            P[++n] = "hdr";                       C[n] = "hdr"
            P[++n] = "sdr";                       C[n] = "sdr"
            P[++n] = "[xh]\\.?264|avc";           C[n] = "h264"
            P[++n] = "[xh]\\.?265|hevc";          C[n] = "hevc"
            P[++n] = "av1";                       C[n] = "av1"
            P[++n] = "vp9";                       C[n] = "vp9"
            P[++n] = "mpeg-?2";                   C[n] = "mpeg2video"
            P[++n] = "vc-?1";                     C[n] = "vc1"
            P[++n] = "xvid|divx";                 C[n] = "mpeg4"
            P[++n] = "4320p|8k";                  C[n] = "r4320"
            P[++n] = "2160p|4k|uhd";              C[n] = "r2160"
            P[++n] = "1440p|qhd";                 C[n] = "r1440"
            P[++n] = "1080[pi]|fhd";              C[n] = "r1080"
            P[++n] = "720p";                      C[n] = "r720"
            P[++n] = "576[pi]|480[pi]";           C[n] = "rsd"
            # frame size; a resolution claim is false only when the frame
            # clearly cannot be it (letterboxed / cropped / anamorphic /
            # ultrawide frames keep their claim)
            w = h = ""
            if (match(res, /^[0-9]+x[0-9]+$/)) { split(res, wh, "x"); w = wh[1] + 0; h = wh[2] + 0 }
            P[++n] = "(8|10|12)[- ]?bits?";       C[n] = "bits"

            lc = tolower(t); out = t; stale = ""
            for (i = 1; i <= n; i++) {
                re = "(^|[^a-z0-9])(" P[i] ")($|[^a-z0-9])"
                pos = 1
                while (pos <= length(lc) && match(substr(lc, pos), re)) {
                    s = pos + RSTART - 1
                    if (substr(lc, s, 1) ~ /[^a-z0-9]/) s++
                    match(substr(lc, s), "^(" P[i] ")")
                    l = RLENGTH
                    blank = sprintf("%" l "s", ""); gsub(/./, "\002", blank)
                    if (is_false(C[i], substr(lc, s, l))) {
                        stale = stale (stale ? ", " : "") substr(out, s, l)
                        lc  = substr(lc, 1, s - 1) substr(lc, s + l)
                        out = substr(out, 1, s - 1) substr(out, s + l)
                        pos = s
                    } else {
                        lc = substr(lc, 1, s - 1) blank substr(lc, s + l)
                        pos = s + l
                    }
                }
            }
            if (mode == "check") { print stale; exit }

            gsub(/[ \t]+/, " ", out)
            gsub(/\( *[-|\/,;:+@. ]*\)|\[ *[-|\/,;:+@. ]*\]|\{ *[-|\/,;:+@. ]*\}/, "", out)
            while (match(out, /[-|\/,;:+@] *[-|\/,;:+@]/))
                out = substr(out, 1, RSTART) substr(out, RSTART + RLENGTH)
            gsub(/\.\.+/, ".", out)
            gsub(/\( +/, "(", out); gsub(/ +\)/, ")", out)
            gsub(/\[ +/, "[", out); gsub(/ +\]/, "]", out)
            gsub(/ +/, " ", out)
            sub(/^[ .|\/,;:+@-]+/, "", out); sub(/[ .|\/,;:+@-]+$/, "", out)
            print out
        }
        function res_false(c) {
            if (c == "r4320") return w < 6000 && h < 3400
            if (c == "r2160") return (w < 3000 && h < 1500) || w >= 6000 || h >= 3400
            if (c == "r1440") return (w < 2200 && h < 1250) || w >= 3000 || h >= 1500
            if (c == "r1080") return (w < 1500 && h < 900) || w >= 3000 || h >= 1500
            if (c == "r720")  return (w < 1000 && h < 600) || w >= 1700 || h >= 1000
            return w >= 1100 || h >= 650                       # rsd
        }
        function is_false(c, txt,    b) {
            if (c == "dv")    return dv != "" && dv != 1
            # HDR10+ needs an HDR10 stream; "?" (not seen in the frames
            # probed, which does not prove it absent) disproves nothing else
            if (c == "h10p")  return (hdr != "" && hdr != "HDR10") || (h10p != "" && h10p != "?" && h10p != 1)
            if (c == "hdr10") return hdr != "" && hdr != "HDR10"
            if (c == "hlg")   return hdr != "" && hdr != "HLG"
            if (c == "hdr")   return hdr != "" && hdr != "HDR10" && hdr != "HLG" && dv != 1
            if (c == "sdr")   return hdr != "" && (hdr != "SDR" || dv == 1)
            if (c ~ /^r/)     return w != "" && res_false(c)
            if (c == "bits")  { b = txt; sub(/[^0-9].*/, "", b); return bits != "" && b != bits }
            return codec != "" && c != codec
        }'
}

# video_title_false_claims TITLE CODEC RES HDR DV HDR10P BITS  ->  "" if
# nothing in TITLE is disproved by the stream
video_title_false_claims() {
    _video_title_awk check "$@"
}

# video_title_rewrite TITLE CODEC RES HDR DV HDR10P BITS  ->  TITLE with
# the disproved claims removed ("" = nothing left)
video_title_rewrite() {
    _video_title_awk rewrite "$@"
}

# _encoded_size FILE VIDX FILTER  ->  "WIDTHxHEIGHT" of the encoded
# video: the source size, or what DOWNSCALE_1080P_FILTER makes of it;
# "" (unknown: no resolution claim is judged) for any other filter
_encoded_size() {
    local res w h

    res=$(get_resolution "$1" "$2" 2>/dev/null) || return 0
    w="${res%x*}" h="${res#*x}"
    [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || return 0
    if [[ -n "${3:-}" ]]; then
        [[ "$3" == "$DOWNSCALE_1080P_FILTER" ]] || return 0
        read -r w h < <(awk -v w="$w" -v h="$h" 'BEGIN {
            f = 1; if (1920 / w < f) f = 1920 / w; if (1080 / h < f) f = 1080 / h
            printf "%d %d\n", w * f, h * f }')
    fi
    printf '%sx%s' "$w" "$h"
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
# MKV track title. MAIN_VIDEO_INDEX "" (no video): nothing is output
# video #0; other video streams are copied from output video #0 on.
#
# Codec options: every output stream must match exactly one -c option
# (ffmpeg warns "Multiple -codec/-c/... options specified for stream N"
# and silently takes the last one otherwise). So there is no blanket
# "-c copy": MAP_CODEC_ARGS holds one option per extra video, subtitle
# and attachment stream; the caller adds the main video (-c:v:0 ...)
# and the audio (-c:a copy, or one -c:a:N per output audio stream).
#
# Sets:
#   MAP_ARGS        shell-quoted "-map ..." tokens
#   MAP_OTHER_ARGS  the same without the main video map
#   MAP_CODEC_ARGS  shell-quoted codec options of every mapped stream
#                   except the main video and the audio
#   MAP_META_ARGS   shell-quoted per-stream metadata (titles, not audio)
#   MAP_ATITLE_ARGS shell-quoted standard titles of every audio track,
#                   all copied (audio_std_title_args)
#   MAP_COVERS      array of "index<TAB>filename<TAB>mimetype"
#   MAP_NOTES       array of human-readable notes
#   MAP_AUDIO_COUNT number of mapped audio streams
#   MAP_AUDIO_OUT   source audio index (a:N of the source) -> output
#                   audio index (a:N of the output): the index every
#                   -c:a:N / -b:a:N / -filter:a:N / -metadata:s:a:N for
#                   that track must use
#   MAP_AMAP        the same as "src:out,src:out,..." (item_expect amap=)
build_stream_map() {
    local file="$1"
    local vidx="$2"
    local idx type codec att rest name mime
    local sub_n=0 vid_n=0 att_n=0 aud_src=0
    local out_n=0
    local maps=()
    local codecs=()
    local metas=()
    local amap=()
    local -A handler=()
    local h_idx h_type h_title h_handler

    MAP_NOTES=()
    MAP_COVERS=()
    MAP_AUDIO_COUNT=0
    MAP_AUDIO_OUT=()

    if [[ -n "$vidx" ]]; then
        maps=(-map "0:$vidx")
        out_n=1
        vid_n=1
    fi

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
        [[ -n "$vidx" && "$idx" == "$vidx" ]] && continue

        # audio: the name goes into the standard title (MAP_ATITLE_ARGS)
        if [[ -n "${handler[$idx]:-}" && "$type" == "subtitle" ]] &&
           [[ "$(mkv_subtitle_action "$codec")" != "drop" ]]; then
            metas+=("-metadata:s:$out_n" "title=${handler[$idx]}")
            MAP_NOTES+=("stream $idx: MP4 track name \"${handler[$idx]}\" kept as MKV title")
        elif [[ -n "${handler[$idx]:-}" && "$type" == "audio" ]]; then
            MAP_NOTES+=("stream $idx: MP4 track name \"${handler[$idx]}\" used for the MKV audio title")
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
                    codecs+=("-c:v:$vid_n" copy)
                    ((vid_n += 1))
                    MAP_NOTES+=("stream $idx: extra video ($codec) copied, not re-encoded")
                fi
                ;;
            audio)
                maps+=(-map "0:$idx")
                ((out_n += 1))
                MAP_AUDIO_OUT[$aud_src]=$MAP_AUDIO_COUNT
                amap+=("$aud_src:$MAP_AUDIO_COUNT")
                ((MAP_AUDIO_COUNT += 1))
                ;;
            subtitle)
                case "$(mkv_subtitle_action "$codec")" in
                    copy)
                        maps+=(-map "0:$idx")
                        ((out_n += 1))
                        codecs+=("-c:s:$sub_n" copy)
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
                codecs+=("-c:t:$att_n" copy)
                ((att_n += 1))
                ;;
            data)
                MAP_NOTES+=("stream $idx: data stream ($codec) cannot be stored in MKV, DROPPED")
                ;;
            *)
                MAP_NOTES+=("stream $idx: $type ($codec) skipped")
                ;;
        esac
        [[ "$type" == "audio" ]] && ((aud_src += 1))
    done < <(stream_info "$file")

    MAP_ARGS=""
    (( ${#maps[@]} )) && MAP_ARGS=$(printf '%q ' "${maps[@]}")
    MAP_OTHER_ARGS=""
    [[ -n "$vidx" ]] && (( ${#maps[@]} > 2 )) && MAP_OTHER_ARGS=$(printf '%q ' "${maps[@]:2}")
    MAP_CODEC_ARGS=""
    (( ${#codecs[@]} )) && MAP_CODEC_ARGS=$(printf '%q ' "${codecs[@]}")
    MAP_META_ARGS=""
    (( ${#metas[@]} )) && MAP_META_ARGS=$(printf '%q ' "${metas[@]}")
    MAP_AMAP=$(IFS=,; printf '%s' "${amap[*]-}")
    # standard titles of the copied audio tracks (the audio menu makes
    # its own, with the transcoded tracks' output properties)
    MAP_ATITLE_ARGS=""
    (( MAP_AUDIO_COUNT > 0 )) && MAP_ATITLE_ARGS=$(audio_std_title_args "$file")
    local -a ar
    local an=0 w
    while IFS=$'\t' read -r -a ar; do
        ((an += 1))
        w=$(audio_title_warning "${ar[13]}" "${ar[12]}")
        [[ -n "$w" ]] && MAP_NOTES+=("WARNING: audio $an \"${ar[13]}\": $w")
    done < <(_audio_rows "$file")
    return 0
}

# ------------------------------------------------------------
# Job script generation
# ------------------------------------------------------------

# emit_job_header SESSION TYPE ITEM_COUNT
#
# The movie-compresser version (compresser_version) is taken here, once,
# when the job is created, and written into the job as a constant: every
# output of the job records this value, even if the checkout changes
# while it runs.
emit_job_header() {
    echo '#!/usr/bin/env bash'
    echo '# Generated by the compress menus. Runs inside tmux.'
    echo 'set -uo pipefail'
    echo
    printf 'JOB_COMPRESSER_VERSION=%q\n' "$(compresser_version)"
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
    local file="$1" vidx="$2" fix="${3:-}"
    local idx type def forced comment hi vi lang title a=() d=()

    while IFS=$'\t' read -r idx type _ _ _ _ def forced comment hi vi _ lang title _ _; do
        [[ "$idx" == "$vidx" ]] || continue
        # FIX: the standard title of the encoded video (video_std_title)
        [[ -n "$fix" && "$fix" != "-" ]] && title="$fix"
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

# crf_attempt_leftovers OUTPUT  ->  CRF attempt files an earlier
# (interrupted) job left for OUTPUT, one path per line:
# "<OUTPUT>.retry-crf<N>.part" and "<OUTPUT>.accepted-crf<N>.part"
# (job_runtime.sh item_attempt_part / _keep_accepted), symlinks included.
# Only lists them: one may be the only copy of a completed encode.
crf_attempt_leftovers() {
    local out="$1" dir base f b

    dir=$(dirname -- "$out")
    base="${out##*/}"
    for f in "$dir"/*; do
        [[ -e "$f" || -L "$f" ]] || continue
        b="${f##*/}"
        case "$b" in
            "$base".retry-crf*.part|"$base".accepted-crf*.part) printf '%s\n' "$f" ;;
        esac
    done
    return 0
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

# emit_encode_item INDEX IN OUT TIER VIDEO FILTER PASSLOG OVERWRITE [EST_VIDEO_BYTES [RETRY [QUALITY [CRF_EST [ACTUAL_SIG]]]]]
#
# VIDEO selects the video encode of the main video stream:
#   crf:N   single-pass libx265 CRF encode (movie Quality, High, Base, Custom;
#           series High, Base, Custom). No -b:v, no pass logs (PASSLOG is ignored).
#           EST_VIDEO_BYTES, the pre-encode estimate, is reported against
#           the actual size afterwards (never a failure).
#           RETRY "CEILING_BYTES:CRF_MAX:CRF_MIN:HEADROOM_PCT:DOWN_MAX[:batch|season[:FIT_PCT[:DOWN_MODE[:FLOOR_BYTES:FLOOR_CRF_MIN]]]]"
#           (High / Base / Quality): an attempt whose actual VIDEO bytes are above
#           the ceiling is re-encoded at CRF + 1 up to CRF_MAX; one that
#           fits at least HEADROOM_PCT below the ceiling tries CRF - 1
#           (not below CRF_MIN, at most DOWN_MAX times; job_runtime.sh
#           item_crf_encode). FIT_PCT (High / Base): CRF - 1 only when
#           its predicted size (actual x CRF_EST ratio) stays FIT_PCT
#           below the ceiling. ":season" (series High / Base): the
#           episode joins the shared-CRF season batch (job_crf_batch,
#           batch_mode=season: every episode must fit, the whole season
#           moves up together, one whole-season CRF - 1 test;
#           HEADROOM_PCT / DOWN_MAX / FIT_PCT unused). ":batch" (job
#           scripts of earlier versions): the median-decided season
#           batch. DOWN_MODE "boundary" (movie High / Base):
#           the first attempt that fits tests lower CRFs with no headroom /
#           FIT_PCT gate, up to DOWN_MAX of them (High: 1, CRF - 1 exactly
#           once; Base: CRF_LIMIT, i.e. until one is above the ceiling or
#           CRF_MIN is reached; job_runtime.sh). FLOOR_BYTES /
#           FLOOR_CRF_MIN (movie Base): the video floor (0 = none) and the
#           lowest CRF a result below it may go to. DOWN_MODE "manual"
#           (movie Base manual CRF, base_crf_prompt): one encode at
#           exactly the planned CRF, no CRF retry; its actual video is
#           checked against the ceiling / floor and a violation flagged.
#           "" = no retry (Custom).
#           CRF_EST "CRF=BYTES:..." the pre-encode estimates per CRF (for
#           the FIT_PCT prediction).
#           ACTUAL_SIG (movie High / Base): the encode fingerprint
#           (crf_actual_sig); every completed attempt's actual video
#           bytes are saved under it (job_runtime.sh item_actual_save).
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
    local actual_sig="${13:-}"

    local mode kbps="" crf="" rceil="" rmax="" rmin="" rdpct="" rdmax="" rbatch="" rfit="" rdmode="" rfloor="" rfloormin=""
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
        IFS=: read -r rceil rmax rmin rdpct rdmax rbatch rfit rdmode rfloor rfloormin <<< "$retry"
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

        # profile 7 -> 8.1 discards the enhancement layer: only with the
        # menu's decision on it (dv_el_policy), checked again by the job
        if [[ "$dv_policy" == "preserve" && "$DV_MODE" == 2 && -z "${DV_EL_DISCARD:-}" ]]; then
            emit_failed_item "$index" "$in" "$out" "$tier" "$overwrite" \
                "Dolby Vision profile 7 found but discarding its enhancement layer was not decided"
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
    # audio payload is hash-compared with the source; amap: source ->
    # output audio index (build_stream_map). ceiling_vbytes / crf_min /
    # crf_max: the CRF retry (High / Base; empty = none).
    expect=$(printf 'item_expect vidx=%q mode=%q crf=%q kbps=%q est_vbytes=%q dv=%q dv_profile=%q dv_compat=%q hdr10p=%q scaled=%q copyts=%q atrans= ahash=1 amap=%q atitle=std' \
        "$vidx" "$mode" "$crf" "$kbps" "$est" \
        "$( (( HDR_DV == 1 )) && echo "$dv_policy" || echo none)" \
        "$dv_out_profile" "$dv_out_compat" "$h10p_policy" "$scaled" \
        "$( [[ "$dv_policy" == "preserve" ]] && echo 1 || echo 0)" "${MAP_AMAP:-}")
    # x265 tune (movie Custom film grain): checked in the output's x265
    # settings SEI (item_verify_output)
    [[ -n "${X265_TUNE:-}" ]] && expect+=$(printf ' tune=%q' "$X265_TUNE")
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
    # movie Base manual CRF (base_crf_prompt): encoded once at exactly that
    # CRF, only checked and reported (job_runtime.sh)
    [[ "$mode" == "crf" && "$rdmode" == manual ]] &&
        expect+=' down_mode=manual'
    # movie Base: the video floor (bytes; 0 = none / source exempt) and the
    # lowest CRF the post-encode retry may use to reach it (job_runtime.sh)
    [[ "$mode" == "crf" && ( "$rdmode" == boundary || "$rdmode" == manual ) && "$rfloor" =~ ^[0-9]+$ ]] &&
        expect+=$(printf ' floor_vbytes=%q floor_crf_min=%q' "$rfloor" "$rfloormin")
    # series High / Base: strict shared season CRF (job_runtime.sh job_crf_batch)
    if [[ "$mode" == "crf" && "$rbatch" == season ]]; then
        expect+=' batch_mode=season'
        declare -F episode_label > /dev/null &&
            expect+=$(printf ' ep_label=%q' "$(episode_label "$in")")
    fi
    [[ "$mode" == "crf" && -n "$actual_sig" ]] &&
        expect+=$(printf ' actual_sig=%q' "$actual_sig")
    [[ "$mode" == "crf" && "$crf_est" =~ ^[0-9.]+=[0-9]+(:[0-9.]+=[0-9]+)*$ ]] &&
        expect+=$(printf ' crf_est=%q' "$crf_est")

    # CRF-independent preparation (run once, not per CRF attempt)
    if [[ "$dv_policy" == "preserve" && "$DV_MODE" == 2 ]]; then
        steps+=("$(printf 'item_step rpu item_dv_extract %q %q %q %q' "$in" "$vidx" "$DV_MODE" "$DV_EL_DISCARD")")
    elif [[ "$dv_policy" == "preserve" ]]; then
        steps+=("$(printf 'item_step rpu item_dv_extract %q %q %q' "$in" "$vidx" "$DV_MODE")")
    fi
    [[ "$h10p_policy" == "preserve" ]] &&
        steps+=("$(printf 'item_step hdr10+ item_hdr10plus_extract %q %q' "$in" "$vidx")")

    printf '# ---- item %s%s\n' "$index" \
        "$( [[ "$dv_policy" == "preserve" && "$DV_MODE" == 2 ]] && echo "  (Dolby Vision profile 7 -> $DV_OUT: RPU kept, enhancement layer discarded)")$( [[ "$dv_policy" == "preserve" && "$DV_MODE" != 2 ]] && echo "  (Dolby Vision profile ${HDR_DV_PROFILE} -> $DV_OUT preserved)")$( [[ "$rbatch" == batch || "$rbatch" == season ]] && echo "  (season CRF batch: job_crf_batch)")"

    if [[ "$mode" == "crf" ]]; then
        # the final encode as a function: a CRF retry runs it again
        printf 'item_encode_%s() {\n' "$index"
        _emit_final_encode
        printf '}\n'
    fi

    if [[ "$rbatch" == batch || "$rbatch" == season ]]; then
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
    # standard title of the encoded video (the source title is replaced);
    # without the CRF, which a CRF retry / season decision can still
    # change: item_finalize_titles adds the final one after the encode
    local vfix
    vfix=$(video_std_title hevc "$(_encoded_size "$in" "$vidx" "$filter")" 10 "$HDR_KIND" \
        "$( [[ "$dv_policy" == "preserve" ]] && echo 1 || echo 0)" "$dv_out_profile" \
        "$( [[ "$h10p_policy" == "preserve" ]] && echo 1 || echo 0)" "")

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
        printf '      -c:v:0 copy -c:a copy %s\\\n' "$MAP_CODEC_ARGS"
        printf '      %s\\\n' "$(source_video_tag_args "$in" "$vidx" "$vfix")"
    else
        # one codec option per output stream: -c:v:0 libx265 (below),
        # all audio copied, MAP_CODEC_ARGS for the rest
        printf '   item_run %s ffmpeg -y -i %q \\\n' "$label" "$in"
        printf '      %s\\\n' "$MAP_ARGS"
        printf '      -c:a copy %s\\\n' "$MAP_CODEC_ARGS"
        [[ -n "$vf" ]] && printf '      %s\\\n' "$vf"
        _emit_x265_lines "$rate" "$dv" "$pq" "$color"
        [[ -n "$vfix" ]] && printf '      %s\\\n' "$(_video_title_arg "$vfix")"
    fi

    [[ -n "$MAP_META_ARGS" ]] && printf '      %s\\\n' "$MAP_META_ARGS"
    [[ -n "${MAP_ATITLE_ARGS:-}" ]] && printf '      %s\\\n' "$MAP_ATITLE_ARGS"
    printf '      %s\\\n' "$stale"
    # a source compressed earlier must not lend its provenance to this
    # encode (item_tag_compression writes the job's own)
    printf '      -metadata COMPRESSION_TOOL= -metadata MOVIE_COMPRESSER_VERSION= -metadata COMPRESSION_DATE= \\\n'
    printf '      -map_metadata 0 -map_chapters 0 -max_muxing_queue_size 4096 %s\\\n' "$(matroska_mux_args)"
    emit_part_and_covers "$in"
}

# _emit_x265_lines RATE DV X265_PARAMS_QUOTED COLOR  ->  the libx265
# option lines of a generated ffmpeg command
_emit_x265_lines() {
    printf '      -c:v:0 libx265 -preset %s %s%s -pix_fmt:v:0 yuv420p10le %s\\\n' "$X265_PRESET" \
        "${X265_TUNE:+-tune:v:0 $(printf '%q' "$X265_TUNE") }" "$1" "$2"
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
    local vfix

    # the copied video is the source video: its standard title, with the
    # CRF only when the stream records it (x265 settings)
    vfix=$(video_std_title_of "$in" "$vidx" auto)

    printf '# ---- item %s  (source video kept: stream copy)\n' "$index"
    printf 'if item_begin %q %q %q %q %q "" &&\n' "$index" "$in" "$out" "$tier" "$overwrite"
    printf '   item_expect vidx=%q video=copy mode=copy dv=none hdr10p=none scaled=0 copyts=0 atrans= ahash=1 amap=%q atitle=std &&\n' "$vidx" "${MAP_AMAP:-}"
    printf '   item_run mux ffmpeg -y -i %q \\\n' "$in"
    printf '      %s\\\n' "$MAP_ARGS"
    printf '      -c:v:0 copy -c:a copy %s\\\n' "$MAP_CODEC_ARGS"
    [[ -n "$vfix" ]] && printf '      %s\\\n' "$(_video_title_arg "$vfix")"
    [[ -n "$MAP_META_ARGS" ]] && printf '      %s\\\n' "$MAP_META_ARGS"
    [[ -n "${MAP_ATITLE_ARGS:-}" ]] && printf '      %s\\\n' "$MAP_ATITLE_ARGS"
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
