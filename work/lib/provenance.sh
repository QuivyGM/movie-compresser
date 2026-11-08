#!/usr/bin/env bash
# Compression provenance: what produced each output, recorded by the job
# that produced it. Sourced by job_runtime.sh (so job scripts of earlier
# versions get it too) and by provenance.sh in the project root. Needs
# encode_common.sh (mkv_set_global_tags, compresser_git_info) and
# media_probe.sh at call time. Documentation: PROVENANCE.md.
#
# For every output that passed the verification (job_runtime.sh
# item_succeeded):
#   1. item_provenance_tag (before the rename, after the verification):
#      a new stable ID and the compact PROVENANCE_* global tags are
#      written into "<output>.part" (mkv_set_global_tags: tags only,
#      every other tag / chapter / attachment kept and read back)
#   2. item_provenance_record (after the rename): an event with the
#      job's Git version and settings, the tool versions, the executed
#      encode options, the verified operations ($ITEM_TMP/ops.tsv,
#      written by hdr_dovi.sh item_verify_output) and ffprobe of source
#      and output is put into work/logs/provenance/spool/ (one atomic
#      directory rename) and merged into the manifest by provenance.py
#      (python3; when missing the event waits in the spool for
#      `provenance.sh ingest`)
# Neither step can fail an item or change the encode: a failure is a
# warning, the output stays exactly as verified.

[[ -n "${PROVENANCE_LOADED:-}" ]] && return 0
PROVENANCE_LOADED=1
PROVENANCE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PROVENANCE_SCHEMA=1

# PROVENANCE_TAG_NAMES is defined in encode_common.sh (mux strip args)
: "${PROVENANCE_TAG_NAMES:=PROVENANCE_TOOL|PROVENANCE_ID|PROVENANCE_STATUS|PROVENANCE_COMMIT|PROVENANCE_TREE|PROVENANCE_TIME|PROVENANCE_PRESET|PROVENANCE_OPS|PROVENANCE_PARENT}"

# prov_dir WORK  ->  the manifest directory (PROVENANCE_DIR overrides)
prov_dir() {
    printf '%s' "${PROVENANCE_DIR:-${1:-${JOB_WORK:-${WORK_DIR:-.}}}/logs/provenance}"
}

# prov_now  ->  ISO 8601 UTC timestamp, seconds
prov_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# prov_new_id  ->  a random RFC 4122 version 4 UUID (lower case)
prov_new_id() {
    local h=""

    [[ -r /proc/sys/kernel/random/uuid ]] && read -r h < /proc/sys/kernel/random/uuid 2>/dev/null
    if [[ ! "$h" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
        h=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
        [[ "$h" =~ ^[0-9a-f]{32}$ ]] ||
            h=$(printf '%04x%04x%04x%04x%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)
        h="${h:0:8}-${h:8:4}-4${h:13:3}-$(printf '%x' $(( (16#${h:16:1} & 3) | 8 )))${h:17:3}-${h:20:12}"
    fi
    printf '%s\n' "$h"
}

# prov_python  ->  a python 3.6+ interpreter, or non-zero
prov_python() {
    local p

    for p in "${PROVENANCE_PYTHON:-}" python3 python; do
        [[ -n "$p" ]] || continue
        command -v "$p" >/dev/null 2>&1 || continue
        "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' >/dev/null 2>&1 || continue
        printf '%s\n' "$p"
        return 0
    done
    return 1
}

# prov_file_tag FILE NAME  ->  value of global tag NAME (case-insensitive;
# the first one), empty when not there or unreadable
prov_file_tag() {
    ffprobe -v error -show_entries format_tags -of default=nw=1 "$1" 2>/dev/null |
        awk -v want="$2" '
            { sub(/\r$/, ""); k = toupper($0); v = substr($0, index($0, "=") + 1) }
            index(k, "TAG:" toupper(want) "=") == 1 { print v; exit }'
}

# prov_tool_versions  ->  "NAME<TAB>VERSION" lines of the tools this job
# can run (ffmpeg / ffprobe / mkvtoolnix always; dovi_tool /
# hdr10plus_tool only when found); cached for the job
prov_tool_versions() {
    if [[ -z "${PROV_TOOLS_CACHE+x}" ]]; then
        local v t
        PROV_TOOLS_CACHE=""
        v=$(ffmpeg -hide_banner -version 2>/dev/null | tr -d '\r' | awk 'NR == 1 && $1 == "ffmpeg" && $2 == "version" { print $3 }')
        [[ -n "$v" ]] && PROV_TOOLS_CACHE+="ffmpeg"$'\t'"$v"$'\n'
        v=$(ffprobe -hide_banner -version 2>/dev/null | tr -d '\r' | awk 'NR == 1 && $1 == "ffprobe" && $2 == "version" { print $3 }')
        [[ -n "$v" ]] && PROV_TOOLS_CACHE+="ffprobe"$'\t'"$v"$'\n'
        v=$(mkvmerge --version 2>/dev/null | tr -d '\r' | awk 'NR == 1 && $1 == "mkvmerge" { sub(/^v/, "", $2); print $2 }')
        [[ -n "$v" ]] && PROV_TOOLS_CACHE+="mkvtoolnix"$'\t'"$v"$'\n'
        for t in dovi_tool hdr10plus_tool; do
            local p=""
            declare -F hdr_find_tool > /dev/null && p=$(hdr_find_tool "$t")
            [[ -n "$p" ]] || continue
            v=$("$p" --version 2>/dev/null | tr -d '\r' | awk 'NR == 1 { print $NF }')
            [[ -n "$v" ]] && PROV_TOOLS_CACHE+="$t"$'\t'"$v"$'\n'
        done
    fi
    printf '%s' "$PROV_TOOLS_CACHE"
}

# prov_x265_sei FILE STREAM_INDEX  ->  the x265 settings SEI text of the
# stream ("x265 (build N) - VERSION ... - options: ..."), one line;
# nothing when the stream was not written by x265
prov_x265_sei() {
    [[ -n "$2" ]] || return 0
    ffmpeg -v error -nostdin -i "$1" -map "0:$2" -c copy -frames:v 1 -f hevc - 2>/dev/null |
        head -c 4000000 | tr -c '[:print:]' '\n' | grep -m1 'x265 (build' | cut -c1-8000
    return 0
}

# prov_ops_summary OPS_TSV MODE CRF KBPS  ->  the compact one-line summary
# of the verified operations (PROVENANCE_OPS), e.g.
#   video=reencoded x265 crf 21, 3840x2160->1920x1080; hdr=HDR10 kept;
#   dv=profile 7 -> 8.1, EL (MEL) removed; audio=3 copied, 1 converted;
#   commentary=1 kept; subs=4 kept, 1 converted, 1 removed
# The video part comes from the executed encode (MODE / CRF / KBPS), the
# rest only from rows the verification wrote; nothing when it wrote none.
prov_ops_summary() {
    local ops="$1" mode="$2" crf="$3" kbps="$4" video=""

    case "$mode" in
        crf)   video="reencoded x265 crf $crf" ;;
        abr)   video="reencoded x265 2-pass ${kbps}k" ;;
        copy)  video="copied" ;;
        audio) video="copied" ;;
    esac

    awk -F'\t' -v video="$video" '
        function add(k, v) { part[k] = (k in part && part[k] != "") ? part[k] ", " v : v; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
        function cnt(k, a) { c[k, a]++; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
        $1 == "video" && $2 == "stream" && video == "" {
            video = ($3 == "preserved") ? "copied" : $3
        }
        $1 == "video" && $2 == "resolution" && $3 == "modified" { res = $4; sub(/ \(.*$/, "", res); gsub(/ /, "", res) }
        $1 == "hdr" && $2 == "dynamic range" { add("hdr", $4 ($3 == "preserved" ? " kept" : "")) }
        $1 == "dv" && $2 == "rpu" {
            if ($3 == "preserved") add("dv", "kept")
            else if ($3 == "converted") { d = $4; sub(/ \(.*$/, "", d); add("dv", d) }
            else if ($3 == "removed") add("dv", "removed")
        }
        $1 == "dv" && $2 == "enhancement layer" && $3 == "removed" { d = $4; sub(/ discarded.*$/, "", d); add("dv", "EL (" d ") removed") }
        $1 == "hdr10plus" { add("hdr10+", $3 == "preserved" ? "kept" : $3) }
        $1 == "audio" && $2 ~ /^track [0-9]+$/ { cnt("audio", $3) }
        $1 == "audio" && $2 ~ /object audio$/ && $3 == "removed" { add("audio-objects", $4 " removed") }
        $1 == "commentary" { cnt("commentary", $3) }
        $1 == "subtitle" && ($2 ~ /^track [0-9]+$/ || $2 ~ /^subtitle [0-9]+/) { cnt("subs", $3) }
        $1 == "subtitle" && $2 ~ /^track [0-9]+ / && $3 == "modified" {
            split($2, t, " "); if (!(t[2] in smod)) { smod[t[2]] = 1; cnt("subs", "modified") }
        }
        $1 == "metadata" && $2 ~ /title$/ && $3 == "modified" { cnt("titles", $3) }
        END {
            if (video != "") printf "video=%s%s", video, (res != "" ? ", " res : "")
            sep = (video != "") ? "; " : ""
            split("preserved:kept converted:converted removed:removed modified:modified added:added reencoded:reencoded", al, " ")
            for (i = 1; i <= n; i++) {
                k = order[i]; v = part[k]
                if (k == "audio" || k == "commentary" || k == "subs" || k == "titles") {
                    v = ""
                    for (j = 1; j in al; j++) {
                        split(al[j], ab, ":")
                        if ((k, ab[1]) in c) v = v (v == "" ? "" : ", ") c[k, ab[1]] " " (k == "audio" && ab[2] == "kept" ? "copied" : ab[2])
                    }
                }
                if (v != "") { printf "%s%s=%s", sep, k, v; sep = "; " }
            }
            printf "\n"
        }' "$ops" 2>/dev/null || { [[ -n "$video" ]] && printf 'video=%s\n' "$video"; }
}

# _prov_op_type  ->  the kind of operation the current item performed
_prov_op_type() {
    if [[ "${JOB_TYPE:-}" == audio ]]; then
        [[ -n "${ITEM_EXP[atrans]:-}" ]] && echo audio-compress || echo remux
        return
    fi
    case "${ITEM_EXP[mode]:-}" in
        crf|abr) echo compress ;;
        copy)    echo stream-copy ;;
        *)       [[ "${ITEM_EXP[video]:-}" == copy ]] && echo remux || echo compress ;;
    esac
}

# _prov_preset  ->  the menu preset of the item: Quality / High / Base /
# Compact / Custom, "Audio <tiers>" for the audio menu, else the tier
# label as the job recorded it
_prov_preset() {
    local t="${ITEM_TIER:-}"

    t="${t//$'\t'/ }"
    t="${t//$'\n'/ }"
    printf '%s' "${t:-unknown}"
}

# _prov_git  ->  "COMMIT<TAB>BRANCH<TAB>TREE<TAB>CAPTURED" of the job:
# taken when the job was generated (emit_job_header), else (job scripts
# of earlier versions) the commit the job's recorded describe string names
# when this checkout knows it, never the checkout's current HEAD
_prov_git() {
    local c="${JOB_GIT_COMMIT:-}" b="${JOB_GIT_BRANCH:-}" t="${JOB_GIT_TREE:-}" how=job-generated
    local d="${JOB_COMPRESSER_VERSION:-unknown}" root r

    if [[ -z "$c" ]]; then
        how=unknown c=unknown b=unknown t=unknown
        if [[ "$d" != unknown ]]; then
            [[ "$d" == *-dirty ]] && t=dirty || t=clean
            while IFS= read -r root; do
                r=$(GIT_OPTIONAL_LOCKS=0 git -C "$root" rev-parse --verify -q "${d%-dirty}^{commit}" 2>/dev/null) &&
                [[ "$r" =~ ^[0-9a-f]{40}$ ]] && { c="$r"; how=resolved-from-describe; break; }
            done < <(declare -F _compresser_git_roots > /dev/null && _compresser_git_roots)
            [[ "$c" == unknown ]] && t=unknown
        fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$c" "${b:-unknown}" "${t:-unknown}" "$how"
}

# item_provenance_tag  (job_runtime.sh item_succeeded, after the
# verification passed, before the rename)
#
# Gives the item its provenance ID (ITEM_PROV_ID) and writes the compact
# PROVENANCE_* global tags into "$ITEM_PART": tool, ID, status, commit,
# tree state, time, preset, operations summary and the parent ID (the
# source's own PROVENANCE_ID, when it has one). Tags only (no remux):
# every other tag, the chapters and attachments stay; the write is read
# back and undone on any difference. A failure is a warning only (the
# manifest still gets the record, with tags_embedded false).
item_provenance_tag() {
    local dir="$ITEM_TMP/prov" rc commit tree how ops summary
    local -a want=()

    ITEM_PROV_ID=$(prov_new_id)
    ITEM_PROV_TIME=$(prov_now)
    ITEM_PROV_PARENT=$(prov_file_tag "$ITEM_INPUT" PROVENANCE_ID)
    [[ "$ITEM_PROV_PARENT" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || ITEM_PROV_PARENT=""
    ITEM_PROV_TAGS="skipped:not an MKV output"
    mkdir -p "$dir" 2>/dev/null || { ITEM_PROV_TAGS="failed:no work directory"; return 0; }

    IFS=$'\t' read -r commit _ tree how <<< "$(_prov_git)"
    ops="$ITEM_TMP/ops.tsv"
    summary=$(prov_ops_summary "$ops" "$( [[ "${JOB_TYPE:-}" == audio ]] && echo audio || echo "${ITEM_EXP[mode]:-}")" \
        "${ITEM_EXP[crf]:-}" "${ITEM_EXP[kbps]:-}")
    ITEM_PROV_SUMMARY="$summary"

    [[ "${ITEM_OUTPUT,,}" == *.mkv ]] || return 0

    want=("PROVENANCE_TOOL=$COMPRESSION_TOOL_NAME" "PROVENANCE_ID=$ITEM_PROV_ID" "PROVENANCE_STATUS=recorded"
          "PROVENANCE_COMMIT=$commit" "PROVENANCE_TREE=$tree" "PROVENANCE_TIME=$ITEM_PROV_TIME"
          "PROVENANCE_PRESET=$(_prov_preset)")
    [[ -n "$summary" ]] && want+=("PROVENANCE_OPS=$summary")
    [[ -n "$ITEM_PROV_PARENT" ]] && want+=("PROVENANCE_PARENT=$ITEM_PROV_PARENT")

    echo "Recording provenance tags: PROVENANCE_ID=$ITEM_PROV_ID PROVENANCE_COMMIT=$commit"
    mkv_set_global_tags "$ITEM_PART" "$dir" "$PROVENANCE_TAG_NAMES" "${want[@]}" >> "$ITEM_LOG" 2>&1
    rc=$?
    if (( rc == 0 )); then
        ITEM_PROV_TAGS=written
    else
        cat -- "$dir/mkvpropedit_global_tags.log" >> "$ITEM_LOG" 2>/dev/null
        ITEM_PROV_TAGS="failed:exit $rc"
        (( rc == 3 )) && ITEM_PROV_TAGS="failed:mkvtoolnix missing"
        echo "WARNING: provenance tags not written (${ITEM_PROV_TAGS#failed:}); the manifest record is still kept."
    fi
    return 0
}

# _prov_kv KEY VALUE  ->  one "KEY<TAB>VALUE" line of event.tsv (tabs and
# line breaks inside VALUE become spaces)
_prov_kv() {
    local v="$2"
    v="${v//$'\t'/ }"
    v="${v//$'\r'/ }"
    v="${v//$'\n'/ }"
    printf '%s\t%s\n' "$1" "$v"
}

# _prov_hdr_kv PREFIX FILE  ->  event lines with the dynamic range of the
# main video stream of FILE (probe_hdr), nothing without a video stream
_prov_hdr_kv() {
    local pre="$1" file="$2" idx

    declare -F probe_hdr > /dev/null || return 0
    idx=$(main_video_index "$file" 2>/dev/null)
    [[ -n "$idx" ]] || return 0
    probe_hdr "$file" "$idx" 2>/dev/null || return 0
    _prov_kv "${pre}_vidx" "$idx"
    _prov_kv "${pre}_hdr_kind" "${HDR_KIND:-}"
    _prov_kv "${pre}_hdr10plus" "${HDR_HDR10PLUS:-}"
    _prov_kv "${pre}_dv" "${HDR_DV:-}"
    _prov_kv "${pre}_dv_profile" "${HDR_DV_PROFILE:-}"
    _prov_kv "${pre}_dv_compat" "${HDR_DV_COMPAT:-}"
    _prov_kv "${pre}_dv_level" "${HDR_DV_LEVEL:-}"
    _prov_kv "${pre}_dv_el" "${HDR_DV_EL:-}"
    _prov_kv "${pre}_master_display" "${HDR_MASTER:-}"
    _prov_kv "${pre}_max_cll" "${HDR_CLL:-}"
    _prov_kv "${pre}_primaries" "${HDR_PRIMARIES:-}"
    _prov_kv "${pre}_transfer" "${HDR_TRANSFER:-}"
    _prov_kv "${pre}_matrix" "${HDR_MATRIX:-}"
}

# item_provenance_record FINAL  (job_runtime.sh item_succeeded, after the
# rename and the statistics refresh)
#
# Spools the provenance event of the finished output FINAL (one atomic
# directory rename into work/logs/provenance/spool) and merges it into
# the manifest (provenance.py ingest). Never fails the item.
item_provenance_record() {
    local final="$1" pdir spool opid tmp k v a commit branch tree how py rc
    local -a rows=()

    [[ -n "${ITEM_PROV_ID:-}" ]] || return 0
    pdir=$(prov_dir "$JOB_WORK")
    spool="$pdir/spool"
    if ! mkdir -p "$spool" 2>/dev/null; then
        echo "WARNING: provenance not recorded (cannot create $spool)."
        return 0
    fi
    opid="${JOB_SESSION}-$(date -u +%Y%m%dT%H%M%SZ)-${ITEM_INDEX}-${ITEM_PROV_ID:0:8}"
    tmp="$spool/.tmp-$opid"
    rm -rf -- "$tmp"
    mkdir -p "$tmp" 2>/dev/null || { echo "WARNING: provenance not recorded (cannot write $spool)."; return 0; }

    IFS=$'\t' read -r commit branch tree how <<< "$(_prov_git)"
    for a in "${ITEM_ATTEMPT_ROWS[@]+"${ITEM_ATTEMPT_ROWS[@]}"}"; do
        rows+=("${a//$'\x1f'/|}")
    done

    {
        _prov_kv schema "$PROVENANCE_SCHEMA"
        _prov_kv op_id "$opid"
        _prov_kv id "$ITEM_PROV_ID"
        _prov_kv time "$ITEM_PROV_TIME"
        _prov_kv recorded "$(prov_now)"
        _prov_kv op_type "$(_prov_op_type)"
        _prov_kv job_session "${JOB_SESSION:-}"
        _prov_kv job_type "${JOB_TYPE:-}"
        _prov_kv job_item "${ITEM_INDEX:-}"
        _prov_kv job_log_dir "${JOB_LOG_DIR:-}"
        _prov_kv tier "${ITEM_TIER:-}"
        _prov_kv preset "$(_prov_preset)"
        _prov_kv input "$ITEM_INPUT"
        _prov_kv output "$final"
        _prov_kv output_planned "$ITEM_OUTPUT"
        _prov_kv overwrite "${ITEM_OVERWRITE:-0}"
        _prov_kv parent_id "${ITEM_PROV_PARENT:-}"
        _prov_kv git_commit "$commit"
        _prov_kv git_branch "$branch"
        _prov_kv git_tree "$tree"
        _prov_kv git_captured "$how"
        _prov_kv git_describe "${JOB_COMPRESSER_VERSION:-unknown}"
        while IFS=$'\t' read -r k v; do
            [[ -n "$k" ]] && _prov_kv "tool_$k" "$v"
        done < <(prov_tool_versions)
        _prov_kv tags "${ITEM_PROV_TAGS:-}"
        _prov_kv ops_summary "${ITEM_PROV_SUMMARY:-}"
        _prov_kv verification passed
        _prov_kv ops_recorded "$( [[ -f "$ITEM_TMP/ops.tsv" ]] && echo 1 || echo 0)"
        for k in "${!ITEM_EXP[@]}"; do
            _prov_kv "exp_$k" "${ITEM_EXP[$k]}"
        done
        _prov_kv attempts "$(IFS=';'; printf '%s' "${rows[*]-}")"
        _prov_kv over_ceiling "${ITEM_OVER_CEILING:-0}"
        _prov_kv below_floor "${ITEM_BELOW_FLOOR:-0}"
        _prov_kv titles_state "${ITEM_TITLES_STATE:-}"
        _prov_kv chapters_state "$(head -n 1 "$ITEM_TMP/chapters_state" 2>/dev/null)"
        _prov_kv dv_el "$(head -n 1 "$ITEM_TMP/dv_el" 2>/dev/null)"
        _prov_kv final_video_bytes "${ITEM_FINAL_VBYTES:-}"
        _prov_kv output_bytes "$(file_bytes "$final" 2>/dev/null)"
        _prov_kv source_bytes "$(file_bytes "$ITEM_INPUT" 2>/dev/null)"
        read -r v _ <<< "$(mkv_segment_uids "$final" 2>/dev/null)"
        _prov_kv segment_uid "${v:--}"
        _prov_hdr_kv src "$ITEM_INPUT"
        _prov_hdr_kv out "$final"
        v=$(main_video_index "$final" 2>/dev/null)
        [[ "$(_prov_op_type)" == compress ]] && _prov_kv x265_sei "$(prov_x265_sei "$final" "$v")"
    } > "$tmp/event.tsv" 2>/dev/null

    [[ -f "$ITEM_TMP/ops.tsv" ]] && cp -- "$ITEM_TMP/ops.tsv" "$tmp/ops.tsv" 2>/dev/null
    for k in "$ITEM_TMP/prov"/cmd_*; do
        [[ -f "$k" ]] && cp -- "$k" "$tmp/" 2>/dev/null
    done
    ffprobe -v error -show_format -show_streams -show_chapters -of json "$ITEM_INPUT" > "$tmp/source.json" 2>/dev/null ||
        rm -f -- "$tmp/source.json"
    ffprobe -v error -show_format -show_streams -show_chapters -of json "$final" > "$tmp/output.json" 2>/dev/null ||
        rm -f -- "$tmp/output.json"

    # complete: one rename makes it visible to the manifest
    if ! mv -T -- "$tmp" "$spool/$opid" 2>/dev/null; then
        rm -rf -- "$tmp"
        echo "WARNING: provenance not recorded (spool rename failed)."
        return 0
    fi

    if py=$(prov_python); then
        PROV_BASH="${BASH:-bash}" "$py" "$PROVENANCE_LIB_DIR/provenance.py" --work "$JOB_WORK" \
            ${PROVENANCE_DIR:+--manifest-dir "$PROVENANCE_DIR"} ingest --quiet >> "$ITEM_LOG" 2>&1
        rc=$?
        if (( rc == 0 )); then
            echo "Provenance recorded: $ITEM_PROV_ID"
        else
            echo "WARNING: provenance manifest not updated (exit $rc); the event waits in $spool (provenance.sh ingest)."
        fi
    else
        echo "Provenance event spooled ($ITEM_PROV_ID); python3 not found: run provenance.sh ingest to update the manifest."
    fi
    return 0
}
