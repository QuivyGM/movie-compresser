#!/usr/bin/env bash
# Summary of the compressed outputs in ~/compress/out. Read-only, no
# prompts.
#
#   results.sh             outputs of the most recent finished job (job
#                          records in work/, see "Last job" below); all of
#                          out/ when no record names an output that is
#                          still there
#   results.sh PATH        one show folder, season folder or file: relative
#                          to out/ (or to the current folder) or absolute;
#                          must be inside out/
#   results.sh --all       everything in out/
#   COMPRESS_VERBOSE=1     also one row per episode under each season
#
# Per show: one row per season (episodes, CRF or CRF range, tier, output
# size, size of the paired sources, saved %, average GiB per episode,
# track titles, status) and a total row; movies (files directly in out/)
# in one table. Saved % is taken over the outputs with a paired source
# only (verify.sh's pairing: naming.sh find_source_for_output); an
# unpaired output counts for its size, its saved % is "-".
#
# Status "OK" / "N issues", plus "over target (N)" for outputs the job
# kept above their video ceiling at the tier's CRF limit (series High /
# Base over target; provenance flag over_ceiling of the latest job record
# of the output; not an issue). The "Issues:" list names only real problems:
#   - verification mismatch: stored MKV statistics missing or rejected,
#     a compression tag stored with different values, compression tags
#     that differ from the job record of the encode, an encode kept as
#     "<output>.verify-failed" / ".finalize-failed"
#   - no video stream
#   - unpaired output (no source, or several candidates, in in/)
#   - missing compression tags (COMPRESSION_CRF / COMPRESSION_TIER) on an
#     x265 CRF encode
# Missing / non-standard track titles are only counted per season
# ("Titles": episodes whose titles verify.sh Validate + update would
# correct), never listed as issues.
#
# Never modifies a file: the inspection is verify.sh's Verify mode
# (work/lib/inspect.sh inspect_file, VALIDATE=0). Stored statistics are
# read; a file without usable statistics is packet-scanned in memory
# only; no statistics refresh, tag or title write.
#
# Last job: the job records left in work/ by finished jobs:
#   work/logs/provenance/journal.jsonl (python3) and spool/*/event.tsv
#                      one record per verified output, with the job's
#                      session and log folder (unique per job run)
#   work/logs/compression_tags.tsv
#                      one row per finished CRF encode (earlier versions)
#   work/<session>.state, work/logs/<job>/job.state
#                      status / end time of a job that is waiting for
#                      Enter or failed; running and interrupted jobs are
#                      never "finished"
# The job with the latest end time that has at least one recorded output
# still in out/ is shown. All times are compared as epochs: the journal /
# spool times are UTC ("Z"), the ledger rows local time of this machine
# (as the job wrote them: date '+%F %T'), job.state epochs; the log folder
# names are only used as job identities, never as times.
set -u

BASE="$HOME/compress"
IN="$BASE/in"
OUT="$BASE/out"
WORK="$BASE/work"
LIB="$WORK/lib"
LOGS="$WORK/logs"

usage() {
    cat <<'EOF'
usage: results.sh [--all | PATH]

  (no argument)  outputs of the most recent finished job (all of out/
                 when no job record is found)
  PATH           a show folder, season folder or file in out/ (relative
                 to out/ or absolute)
  --all          everything in out/

COMPRESS_VERBOSE=1 adds one row per episode. Read-only: never modifies
a file.
EOF
}

die() {
    echo "results.sh: $*" >&2
    exit 1
}

SCOPE_MODE=job
SCOPE_ARG=""
while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --all)
            [[ "$SCOPE_MODE" == job ]] || die "use either --all or one PATH"
            SCOPE_MODE=all
            ;;
        --) shift; break ;;
        -?*) die "unknown option: $1 (see --help)" ;;
        *)
            [[ "$SCOPE_MODE" == job ]] || die "use either --all or one PATH"
            SCOPE_MODE=path
            SCOPE_ARG="$1"
            ;;
    esac
    shift
done
if (( $# )); then
    [[ "$SCOPE_MODE" == job && $# == 1 ]] || die "use either --all or one PATH"
    SCOPE_MODE=path
    SCOPE_ARG="$1"
fi

[[ "$SCOPE_MODE" == path && -z "$SCOPE_ARG" ]] && die "empty path"
[[ -d "$OUT" ]] || die "output folder not found: $OUT"

source "$LIB/inspect.sh"

command -v ffprobe >/dev/null || die "ffprobe not found"

ROOT="$OUT"

# ------------------------------------------------------------
# Scope: a path in out/
# ------------------------------------------------------------

# resolve_out_path ARG  ->  RESOLVED: the path below OUT (as OUT/...), or
# non-zero with RESOLVE_WHY:
# relative to out/ first, then to the current folder; absolute paths as
# they are. Inside out/ by its name (".." resolved, symlinks kept) or by
# the real path (out/ itself may be a symlink to another disk).
resolve_out_path() {
    local arg="$1" cand out_l out_p p_l p_p

    out_l=$(realpath -s -m -- "$OUT")
    out_p=$(realpath -m -- "$OUT")

    if [[ "$arg" == /* ]]; then
        cand=("$arg")
    else
        cand=("$OUT/$arg" "$PWD/$arg")
    fi

    for p in "${cand[@]}"; do
        [[ -e "$p" || -L "$p" ]] || continue
        p_l=$(realpath -s -m -- "$p")
        if [[ "$p_l" == "$out_l" || "$p_l" == "$out_l"/* ]]; then
            RESOLVED="$OUT${p_l#"$out_l"}"
            return 0
        fi
        p_p=$(realpath -m -- "$p")
        if [[ "$p_p" == "$out_p" || "$p_p" == "$out_p"/* ]]; then
            RESOLVED="$OUT${p_p#"$out_p"}"
            return 0
        fi
        RESOLVE_WHY="not inside $OUT"
        return 1
    done
    RESOLVE_WHY="not found (relative paths are taken from $OUT)"
    return 1
}

# is_media NAME  ->  0 for a media file extension (MEDIA_EXTS)
is_media() {
    local e
    for e in "${MEDIA_EXTS[@]}"; do
        [[ "${1,,}" == *."$e" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------
# Last job (job records in work/; read-only)
# ------------------------------------------------------------

# _job_raw  ->  "TIME<TAB>SOURCE<TAB>SESSION<TAB>LOG_DIR<TAB>OUTPUT" per
# recorded output (SOURCE prov | ledger), TIME as written; "-" for an
# empty field (read splits on tabs, which would merge empty fields)
_job_raw() {
    local pdir="$LOGS/provenance" py ev

    if [[ -s "$pdir/journal.jsonl" ]] && py=$(command -v python3); then
        "$py" -I -c '
import json, sys
def clean(v):
    return v.replace("\t", " ").replace("\n", " ").replace("\r", " ") if isinstance(v, str) else ""
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for line in f:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("entry") != "output":
            continue
        op = e.get("op") if isinstance(e.get("op"), dict) else {}
        job = op.get("job") if isinstance(op.get("job"), dict) else {}
        fi = e.get("file") if isinstance(e.get("file"), dict) else {}
        t = clean(op.get("recorded") or op.get("time"))
        out = clean(fi.get("path"))
        if t and out:
            print("\t".join((t, "prov", clean(job.get("session")) or "-", clean(job.get("log_dir")) or "-", out)))
' "$pdir/journal.jsonl" 2>/dev/null
    fi

    # events not merged into the manifest yet (python3 missing, ...)
    for ev in "$pdir"/spool/*/event.tsv; do
        [[ -f "$ev" ]] || continue
        awk -F'\t' '
            { v[$1] = substr($0, length($1) + 2) }
            END {
                t = (v["recorded"] != "" ? v["recorded"] : v["time"])
                if (t != "" && v["output"] != "")
                    printf "%s\tprov\t%s\t%s\t%s\n", t, (v["job_session"] != "" ? v["job_session"] : "-"),
                        (v["job_log_dir"] != "" ? v["job_log_dir"] : "-"), v["output"]
            }' "$ev" 2>/dev/null
    done

    [[ -s "$LOGS/compression_tags.tsv" ]] &&
        awk -F'\t' 'NR > 1 && $1 != "" && $2 != "" { printf "%s\tledger\t%s\t-\t%s\n", $1, ($6 != "" ? $6 : "-"), $2 }' \
            "$LOGS/compression_tags.tsv" 2>/dev/null
    return 0
}

# _over_records  ->  "OUTPUT<TAB>VIDEO_BYTES<TAB>OVER" per recorded output,
# oldest first (journal, then the spool): OVER 1 when the job kept that
# output above its video ceiling at the tier's CRF limit ("over target",
# provenance flag over_ceiling); VIDEO_BYTES "-" when not recorded
_over_records() {
    local pdir="$LOGS/provenance" py ev

    if [[ -s "$pdir/journal.jsonl" ]] && py=$(command -v python3); then
        "$py" -I -c '
import json, sys
def clean(v):
    return v.replace("\t", " ").replace("\n", " ").replace("\r", " ") if isinstance(v, str) else ""
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for line in f:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("entry") != "output":
            continue
        op = e.get("op") if isinstance(e.get("op"), dict) else {}
        fi = e.get("file") if isinstance(e.get("file"), dict) else {}
        out = clean(fi.get("path"))
        if not out:
            continue
        fl = op.get("flags") if isinstance(op.get("flags"), list) else []
        vb = op.get("output_video_bytes")
        print("\t".join((out, str(vb) if isinstance(vb, int) and vb > 0 else "-",
                         "1" if "over_ceiling" in fl else "0")))
' "$pdir/journal.jsonl" 2>/dev/null
    fi

    for ev in "$pdir"/spool/*/event.tsv; do
        [[ -f "$ev" ]] || continue
        awk -F'\t' '
            { v[$1] = substr($0, length($1) + 2) }
            END {
                if (v["output"] != "")
                    printf "%s\t%s\t%s\n", v["output"], (v["final_video_bytes"] ~ /^[1-9][0-9]*$/ ? v["final_video_bytes"] : "-"),
                        (v["over_ceiling"] == "1" ? 1 : 0)
            }' "$ev" 2>/dev/null
    done
    return 0
}

# _job_states  ->  "SESSION<TAB>STATUS<TAB>STARTED<TAB>UPDATED<TAB>LOG_DIR<TAB>FAILED"
# of every job state file left in work/ (running / waiting / failed jobs)
_job_states() {
    local f
    for f in "$WORK"/*.state "$LOGS"/*/job.state; do
        [[ -f "$f" ]] || continue
        awk -F'=' '
            { k = $1; v[k] = substr($0, length(k) + 2) }
            END {
                if (v["session"] != "")
                    printf "%s\t%s\t%s\t%s\t%s\t%s\n", v["session"], (v["status"] != "" ? v["status"] : "-"),
                        v["started"] + 0, v["updated"] + 0, (v["log_dir"] != "" ? v["log_dir"] : "-"), v["failed"] + 0
            }' "$f" 2>/dev/null
    done
}

# find_last_job  ->  LAST_JOB_FILES (outputs still in out/), LAST_JOB_LABEL,
# LAST_JOB_MISSING (recorded outputs no longer there); non-zero when no
# finished job with an output in out/ is recorded
find_last_job() {
    local -a raw=() times=() epochs=()
    local line t src ses ld out i n key
    local -A st_status=() st_start=() st_end=() st_failed=() st_session=()
    local -A j_end=() j_session=() j_outs=() prov_out=()
    local -A seen=()

    mapfile -t raw < <(_job_raw | awk -F'\t' '
        $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9:]+)?$/ && !seen[$0]++')
    (( ${#raw[@]} )) || return 1

    # all timestamps in one date call (validated above: one line out per line in)
    for line in "${raw[@]}"; do times+=("${line%%$'\t'*}"); done
    mapfile -t epochs < <(printf '%s\n' "${times[@]}" | date -f - +%s 2>/dev/null)
    (( ${#epochs[@]} == ${#raw[@]} )) || return 1

    # job state files: finished / failed jobs and the ones that are not over
    while IFS=$'\t' read -r ses t i n ld out; do
        [[ -n "$ld" && "$ld" != "-" ]] || continue
        st_session[$ld]="$ses"
        st_status[$ld]="$t"
        st_start[$ld]="$i"
        st_end[$ld]="$n"
        st_failed[$ld]="$out"
    done < <(_job_states)

    # provenance records: keyed by the job's log folder (one per job run)
    for i in "${!raw[@]}"; do
        IFS=$'\t' read -r t src ses ld out <<< "${raw[$i]}"
        [[ "$src" == prov ]] || continue
        [[ "$ses" == "-" ]] && ses=""
        key="$ld"
        [[ "$ld" == "-" ]] && key="session:$ses"
        prov_out["$out"]+="${epochs[$i]} "
        _job_add "$key" "$ses" "${epochs[$i]}" "$out"
    done

    # ledger rows: the job of a provenance record of the same output (same
    # hour), else the job state of that session whose run covers the row,
    # else one job per session run (a run ends where an output repeats)
    local -A run_of=() run_outs=()
    local e d ok
    for i in "${!raw[@]}"; do
        IFS=$'\t' read -r t src ses ld out <<< "${raw[$i]}"
        [[ "$src" == ledger ]] || continue
        [[ "$ses" == "-" ]] && ses=""
        ok=0
        for e in ${prov_out["$out"]:-}; do
            d=$(( ${epochs[$i]} - e ))
            (( d < 0 )) && d=$(( -d ))
            (( d <= 3600 )) && { ok=1; break; }
        done
        (( ok )) && continue
        key=""
        for ld in "${!st_session[@]}"; do
            [[ "${st_session[$ld]}" == "$ses" ]] || continue
            (( ${epochs[$i]} >= ${st_start[$ld]} - 60 && ${epochs[$i]} <= ${st_end[$ld]} + 600 )) && { key="$ld"; break; }
        done
        if [[ -z "$key" ]]; then
            if [[ -z "${run_of[$ses]:-}" || "${run_outs[$ses]:-}" == *$'\n'"$out"$'\n'* ]]; then
                run_of[$ses]="ledger:$ses:${epochs[$i]}"
                run_outs[$ses]=$'\n'
            fi
            run_outs[$ses]+="$out"$'\n'
            key="${run_of[$ses]}"
        fi
        _job_add "$key" "$ses" "${epochs[$i]}" "$out"
    done

    # running / interrupted jobs are not finished
    local -a order=()
    for key in "${!j_end[@]}"; do
        if [[ -n "${st_status[$key]+x}" ]]; then
            [[ "${st_status[$key]}" =~ ^(finished|failed)$ ]] || continue
            (( ${st_end[$key]} > ${j_end[$key]} )) && j_end[$key]="${st_end[$key]}"
        fi
        order+=("${j_end[$key]}"$'\t'"$key")
    done
    (( ${#order[@]} )) || return 1

    while IFS=$'\t' read -r e key; do
        LAST_JOB_FILES=()
        LAST_JOB_MISSING=0
        seen=()
        while IFS= read -r out; do
            [[ -n "$out" && -z "${seen[$out]+x}" ]] || continue
            seen[$out]=1
            if [[ "$out" == "$OUT"/* && -f "$out" ]] && is_media "$out"; then
                LAST_JOB_FILES+=("$out")
            else
                ((LAST_JOB_MISSING += 1))
            fi
        done <<< "${j_outs[$key]}"
        (( ${#LAST_JOB_FILES[@]} )) || continue

        LAST_JOB_LABEL="Last job: ${j_session[$key]:-?}, finished $(date -d "@$e" '+%F %H:%M')"
        if [[ "${st_status[$key]:-}" == failed ]]; then
            LAST_JOB_LABEL+=" with $(ui_plural "${st_failed[$key]:-?}" "failed item")"
        fi
        return 0
    done < <(printf '%s\n' "${order[@]}" | sort -t $'\t' -k1,1nr)
    return 1
}

# _job_add KEY SESSION EPOCH OUTPUT  (find_last_job's j_* maps)
_job_add() {
    [[ -n "${j_end[$1]+x}" ]] || { j_end[$1]=0; j_outs[$1]=""; }
    (( $3 > ${j_end[$1]} )) && j_end[$1]="$3"
    [[ -n "$2" ]] && j_session[$1]="$2"
    j_outs[$1]+="$4"$'\n'
}

# ------------------------------------------------------------
# Files in scope
# ------------------------------------------------------------

FILES=()
FAILED_DIRS=()          # folders searched for kept verify-failed encodes
FAILED_DEPTH=""         # "" recursive, 1 that folder only
DISCOVERY_QUIET=1

case "$SCOPE_MODE" in
    path)
        RESOLVE_WHY=""
        RESOLVED=""
        resolve_out_path "$SCOPE_ARG" || die "$SCOPE_ARG: ${RESOLVE_WHY:-invalid path}"
        target="$RESOLVED"
        if [[ -d "$target" ]]; then
            mapfile -d '' -t FILES < <(media_files_recursive "$target")
            FAILED_DIRS=("$target")
        elif [[ -f "$target" ]]; then
            is_media "$target" || die "$SCOPE_ARG: not a media file (${MEDIA_EXTS[*]})"
            FILES=("$target")
        else
            die "$SCOPE_ARG: not a file or folder"
        fi
        rel="${target#"$OUT"}"
        SCOPE_LABEL="out${rel:-/}"
        ;;
    all)
        mapfile -d '' -t FILES < <(media_files_recursive "$OUT")
        FAILED_DIRS=("$OUT")
        SCOPE_LABEL="All of out/"
        ;;
    job)
        LAST_JOB_FILES=()
        LAST_JOB_MISSING=0
        if find_last_job; then
            mapfile -t FILES < <(printf '%s\n' "${LAST_JOB_FILES[@]}" | sort)
            mapfile -t FAILED_DIRS < <(printf '%s\n' "${FILES[@]}" | sed 's|/[^/]*$||' | sort -u)
            FAILED_DEPTH=1
            SCOPE_LABEL="$LAST_JOB_LABEL"
            (( LAST_JOB_MISSING > 0 )) &&
                SCOPE_LABEL+=$'\n'"($(ui_plural "$LAST_JOB_MISSING" "recorded output") of this job no longer in out/)"
        else
            mapfile -d '' -t FILES < <(media_files_recursive "$OUT")
            FAILED_DIRS=("$OUT")
            SCOPE_LABEL="No finished job recorded: all of out/"
        fi
        ;;
esac

# encodes kept after a failed output verification / rename
# (job_runtime.sh item_keep_completed)
KEPT_FAILED=()
if (( ${#FAILED_DIRS[@]} )); then
    mapfile -d '' -t KEPT_FAILED < <(
        find -H "${FAILED_DIRS[@]}" ${FAILED_DEPTH:+-maxdepth "$FAILED_DEPTH"} -type f \
            \( -name '*.verify-failed' -o -name '*.verify-failed.[0-9]*' \
               -o -name '*.finalize-failed' -o -name '*.finalize-failed.[0-9]*' \) -print0 2>/dev/null |
            sort -z)
fi

echo "$SCOPE_LABEL"

if (( ${#FILES[@]} + ${#KEPT_FAILED[@]} == 0 )); then
    echo
    echo "No compressed outputs found."
    exit 0
fi

build_source_index "$IN"
inspect_group_files "$OUT" "${FILES[@]+"${FILES[@]}"}"

# group_of FILE  ->  "SHOW<TAB>SEASON" (inspect_group_files' key)
group_of() {
    local rel="${1#"$OUT"/}" show
    if [[ "$rel" == */* ]]; then
        show="${rel%%/*}"
        printf '%s\t%s' "$show" "$(series_group_name "$OUT/$show" "$(dirname -- "$1")")"
    else
        printf '\t'
    fi
}

# ------------------------------------------------------------
# Per file (read-only inspection)
# ------------------------------------------------------------

declare -A F_SIZE=() F_SRC=() F_CRF=() F_TIER=() F_ISSUES=() F_TITLES=() F_OVER=()

# REC_OVER[OUTPUT] = "VIDEO_BYTES OVER" of the latest job record of that
# output (_over_records)
declare -A REC_OVER=()
while IFS=$'\t' read -r _o _vb _ov; do
    [[ -n "$_o" ]] && REC_OVER[$_o]="$_vb $_ov"
done < <(_over_records)
declare -A G_EXTRA=()       # key -> issues not tied to one output (kept failed encodes)

CRF_TIERS_RE="$COMPRESSION_TIER_RE"   # encode_common.sh: the menu CRF tiers, Custom size included

# crf_text VALUE  ->  "21", "20.5" ("" for none)
crf_text() {
    local c="$1"
    [[ "$c" == "-" ]] && c=""
    c="${c#crf }"
    [[ "$c" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf ''; return; }
    awk -v c="$c" 'BEGIN { s = sprintf("%.2f", c); sub(/0+$/, "", s); sub(/\.$/, "", s); print s }'
}

summarize_file() {
    local file="$1" name_tier crf tier rec rc rcrf rtier issues="" missing=""

    STATS_PROGRESS=0 inspect_file "$file" "$OUT" 0 > /dev/null 2>&1

    name_tier=$(output_tier "$(basename "$file")")
    name_tier="${name_tier%% + *}"
    name_tier="${name_tier% (1080p)}"
    [[ "$name_tier" == Unknown ]] && name_tier=""

    crf=$(crf_text "$FILE_CRF_TAG")
    [[ -z "$crf" && "$FILE_RC" == "crf "* ]] && crf=$(crf_text "$FILE_RC")
    tier="$FILE_TIER_TAG"
    [[ "$tier" == "-" ]] && tier="$name_tier"

    F_SIZE[$file]="${FILE_BYTES:-0}"
    F_CRF[$file]="$crf"
    F_TIER[$file]="$tier"
    F_TITLES[$file]="${FILE_TITLE_FIXES:-0}"
    # over target: the latest job record of this output kept it above its
    # video ceiling (not an issue; shown in the status). A record whose
    # video bytes differ from this file's is of another encode.
    F_OVER[$file]=0
    if [[ -n "${REC_OVER[$file]+x}" ]]; then
        local rvb rov
        read -r rvb rov <<< "${REC_OVER[$file]}"
        if [[ "$rov" == 1 ]] && [[ "$rvb" == "-" || ! "${FILE_VBYTES:-}" =~ ^[1-9][0-9]*$ || "$rvb" == "$FILE_VBYTES" ]]; then
            F_OVER[$file]=1
        fi
    fi
    F_SRC[$file]=""
    [[ "$FILE_SRC_KIND" == OK && "$FILE_SRC_BYTES" =~ ^[0-9]+$ ]] && F_SRC[$file]="$FILE_SRC_BYTES"

    (( FILE_NO_VIDEO == 1 )) && issues+="no video stream"$'\n'
    case "$FILE_SRC_KIND" in
        NONE)      issues+="unpaired output (no source found in in/)"$'\n' ;;
        AMBIGUOUS) issues+="unpaired output ($FILE_SRC_CANDIDATES possible sources in in/, not paired)"$'\n' ;;
    esac
    if (( FILE_STATS_BAD == 1 )); then
        issues+="verification mismatch: stored MKV statistics ${FILE_STATS_WHY:+rejected ($FILE_STATS_WHY)}"
        [[ -n "$FILE_STATS_WHY" ]] || issues+="missing"
        issues+=$'\n'
    fi
    [[ -n "$FILE_TAG_CONFLICTS" ]] &&
        issues+="verification mismatch: compression tag stored with different values: $FILE_TAG_CONFLICTS"$'\n'

    # the job record of this encode (exact video bytes identify it)
    if (( FILE_STATS_EXACT == 1 )) && [[ "$FILE_VBYTES" =~ ^[1-9][0-9]*$ ]]; then
        rec=$(compression_record_lookup "$LOGS" "$file" "$FILE_VBYTES" 2>/dev/null)
        rc=$?
        if (( rc == 0 )); then
            IFS=$'\t' read -r rcrf rtier _ <<< "$rec"
            rcrf=$(crf_text "$rcrf")
            if [[ "$FILE_CRF_TAG" != "-" && -n "$rcrf" && "$(crf_text "$FILE_CRF_TAG")" != "$rcrf" ]]; then
                issues+="verification mismatch: COMPRESSION_CRF $FILE_CRF_TAG, job record CRF $rcrf"$'\n'
            fi
            if [[ "$FILE_TIER_TAG" != "-" && "$rtier" != "-" && -n "$rtier" && "$FILE_TIER_TAG" != "$rtier" ]]; then
                issues+="verification mismatch: COMPRESSION_TIER $FILE_TIER_TAG, job record $rtier"$'\n'
            fi
        fi
    fi

    # compression tags of an x265 CRF encode (stream settings, or a CRF
    # tier in the name when the stream does not say)
    if [[ "$FILE_RC" == "crf "* || ( -z "$FILE_RC" && "$name_tier" =~ $CRF_TIERS_RE ) ]]; then
        [[ "$FILE_CRF_TAG" == "-" ]] && missing+="COMPRESSION_CRF"
        [[ "$FILE_TIER_TAG" == "-" && "$name_tier" =~ $CRF_TIERS_RE ]] && missing+="${missing:+, }COMPRESSION_TIER"
        [[ -n "$missing" ]] && issues+="compression tags missing: $missing"$'\n'
    fi

    F_ISSUES[$file]="$issues"
}

total=${#FILES[@]}
n=0
for file in "${FILES[@]+"${FILES[@]}"}"; do
    ((n += 1))
    ui_progress "Inspecting $n/$total: $(basename "$file")..."
    summarize_file "$file"
done
ui_progress ""

for f in "${KEPT_FAILED[@]+"${KEPT_FAILED[@]}"}"; do
    key=$(group_of "$f")
    G_EXTRA[$key]+="$(basename "$f"): verification mismatch: encode kept after a failed output verification / rename"$'\n'
    show="${key%%$'\t'*}"
    if [[ -z "${SHOW_SEEN["k$show"]+x}" ]]; then
        SHOW_SEEN["k$show"]=1
        SHOW_ORDER+=("$show")
    fi
    [[ -n "${GROUP_FILES[$key]+x}" ]] || GROUP_FILES[$key]=""
done

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b / 1073741824 }'; }

# saved_pct SOURCE OUTPUT  ->  "73.4%" ("-" without a source)
saved_pct() {
    [[ "${1:-0}" =~ ^[1-9][0-9]*$ ]] || { printf -- '-'; return; }
    awk -v s="$1" -v o="$2" 'BEGIN { printf "%.1f%%", (s - o) / s * 100 }'
}

# crf_range CRF...  ->  "21", "20-22", "-"
crf_range() {
    local lo hi
    read -r lo hi < <(printf '%s\n' "$@" | grep -E '^[0-9]' | sort -g | sed -n '1p;$p' | paste -sd' ')
    if [[ -z "$lo" ]]; then
        printf -- '-'
    elif [[ -z "$hi" || "$lo" == "$hi" ]]; then
        printf '%s' "$lo"
    else
        printf '%s-%s' "$lo" "$hi"
    fi
}

# tier_set TIER...  ->  "High", "Base/High", "-"
tier_set() {
    local s
    s=$(printf '%s\n' "$@" | grep -v '^$' | sort -u | paste -sd/)
    printf '%s' "${s:--}"
}

# status_text ISSUES [OVER [ONE]]  ->  "OK" / "2 issues"; with OVER > 0
# outputs kept above their video ceiling: "over target (2)" ("over
# target" for ONE file) after it
status_text() {
    local over="${2:-0}" ot
    if (( over > 0 )); then
        ot="over target"
        [[ -n "${3:-}" ]] || ot+=" ($over)"
        if (( $1 == 0 )); then
            ui_warn "$ot"
        else
            printf '%s, %s' "$(ui_err "$(ui_plural "$1" issue)")" "$(ui_warn "$ot")"
        fi
        return 0
    fi
    if (( $1 == 0 )); then
        ui_ok OK
    else
        ui_err "$(ui_plural "$1" issue)"
    fi
}

# count_lines TEXT  ->  non-empty lines
count_lines() {
    [[ -n "$1" ]] || { echo 0; return; }
    grep -c . <<< "$1"
}

LW=0                 # label column width
NAME_MAX=48
fit() {
    local s="$1"
    (( ${#s} > NAME_MAX )) && s="${s:0:$((NAME_MAX - 1))}~"
    printf '%s' "$s"
}

# AGG_* of a list of files: agg FILE...
agg() {
    local f
    AGG_N=0 AGG_OUT=0 AGG_SRC=0 AGG_POUT=0 AGG_ISSUES=0 AGG_TITLES=0 AGG_OVER=0
    AGG_CRFS=() AGG_TIERS=()
    for f in "$@"; do
        [[ -n "$f" ]] || continue
        ((AGG_N += 1))
        AGG_OUT=$(( AGG_OUT + ${F_SIZE[$f]} ))
        if [[ -n "${F_SRC[$f]}" ]]; then
            AGG_SRC=$(( AGG_SRC + ${F_SRC[$f]} ))
            AGG_POUT=$(( AGG_POUT + ${F_SIZE[$f]} ))
        fi
        AGG_ISSUES=$(( AGG_ISSUES + $(count_lines "${F_ISSUES[$f]}") ))
        (( ${F_TITLES[$f]} > 0 )) && ((AGG_TITLES += 1))
        (( ${F_OVER[$f]:-0} == 1 )) && ((AGG_OVER += 1))
        AGG_CRFS+=("${F_CRF[$f]}")
        AGG_TIERS+=("${F_TIER[$f]}")
    done
}

TW=4                 # tier column width
SEASON_FMT='  %-*s  %4s  %-7s  %-*s  %10s  %10s  %6s  %6s  %-7s  %s\n'

season_row() {   # LABEL EPS CRF TIER OUT SRC SAVED AVG TITLES STATUS
    printf "$SEASON_FMT" "$LW" "$1" "$2" "$3" "$TW" "${@:4}"
}

# tier_width FILE...  ->  TW for a table of these files
tier_width() {
    local f t
    TW=4
    for f in "$@"; do
        [[ -n "$f" ]] || continue
        t="${F_TIER[$f]:--}"
        (( ${#t} > TW )) && TW=${#t}
    done
    t=$(agg_tiers "$@")
    (( ${#t} > TW )) && TW=${#t}
}

agg_tiers() {
    local f
    local -a t=()
    for f in "$@"; do [[ -n "$f" ]] && t+=("${F_TIER[$f]}"); done
    tier_set "${t[@]+"${t[@]}"}"
}

# titles_text FILES_WITH_FIXES EPISODES  ->  "OK" / "3 of 8"
titles_text() {
    if (( $1 == 0 )); then printf 'OK'; else printf '%s of %s' "$1" "$2"; fi
}

file_row() {     # FILE  (season table, verbose)
    local f="$1" ni
    ni=$(count_lines "${F_ISSUES[$f]}")
    season_row "  $(fit "$(basename "$f")")" "" "${F_CRF[$f]:--}" "${F_TIER[$f]:--}" \
        "$(gib "${F_SIZE[$f]}") GiB" \
        "$([[ -n "${F_SRC[$f]}" ]] && echo "$(gib "${F_SRC[$f]}") GiB" || echo -)" \
        "$(saved_pct "${F_SRC[$f]}" "${F_SIZE[$f]}")" "" \
        "$( (( ${F_TITLES[$f]} > 0 )) && echo "$(ui_plural "${F_TITLES[$f]}" fix)" || echo OK)" \
        "$(status_text "$ni" "${F_OVER[$f]:-0}" 1)"
}

ALL_FILES=()
ALL_EXTRA=0

print_issues() {   # KEY...  ->  the "Issues:" list of these groups
    local key f line out="" prefix
    for key in "$@"; do
        prefix="${key#*$'\t'}"
        [[ -z "$prefix" || "$prefix" == "$SERIES_ROOT_GROUP" ]] && prefix="" || prefix+="/"
        while IFS= read -r f; do
            [[ -n "$f" && -n "${F_ISSUES[$f]}" ]] || continue
            while IFS= read -r line; do
                [[ -n "$line" ]] && out+="    $prefix$(basename "$f"): $line"$'\n'
            done <<< "${F_ISSUES[$f]}"
        done <<< "${GROUP_FILES[$key]}"
        while IFS= read -r line; do
            [[ -n "$line" ]] && out+="    $prefix$line"$'\n'
        done <<< "${G_EXTRA[$key]:-}"
    done
    if [[ -n "$out" ]]; then
        echo
        echo "  Issues:"
        printf '%s' "$out"
    fi
}

for show in "${SHOW_ORDER[@]+"${SHOW_ORDER[@]}"}"; do
    [[ -n "$show" ]] || continue
    mapfile -t SEASONS < <(show_seasons "$show")

    LW=7
    for s in "${SEASONS[@]}"; do (( ${#s} > LW )) && LW=${#s}; done
    if ui_verbose; then
        for s in "${SEASONS[@]}"; do
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                b=$(fit "$(basename "$f")")
                (( ${#b} + 2 > LW )) && LW=$(( ${#b} + 2 ))
            done <<< "${GROUP_FILES["$show"$'\t'"$s"]}"
        done
    fi

    mapfile -t SF < <(for s in "${SEASONS[@]}"; do printf '%s' "${GROUP_FILES["$show"$'\t'"$s"]}"; done | grep -v '^$')
    tier_width "${SF[@]+"${SF[@]}"}"

    echo
    echo "$(ui_bold "$show")"
    season_row "Season" "Eps" "CRF" "Tier" "Output" "Source" "Saved" "GiB/ep" "Titles" "Status"

    SHOW_FILES=()
    SHOW_EXTRA=0
    KEYS=()
    for s in "${SEASONS[@]}"; do
        key="$show"$'\t'"$s"
        KEYS+=("$key")
        mapfile -t GF < <(grep -v '^$' <<< "${GROUP_FILES[$key]}")
        agg "${GF[@]+"${GF[@]}"}"
        extra=$(count_lines "${G_EXTRA[$key]:-}")
        SHOW_FILES+=("${GF[@]+"${GF[@]}"}")
        SHOW_EXTRA=$(( SHOW_EXTRA + extra ))
        season_row "$s" "$AGG_N" "$(crf_range "${AGG_CRFS[@]+"${AGG_CRFS[@]}"}")" \
            "$(tier_set "${AGG_TIERS[@]+"${AGG_TIERS[@]}"}")" \
            "$(gib "$AGG_OUT") GiB" \
            "$( (( AGG_SRC > 0 )) && echo "$(gib "$AGG_SRC") GiB" || echo -)" \
            "$(saved_pct "$AGG_SRC" "$AGG_POUT")" \
            "$( (( AGG_N > 0 )) && gib $(( AGG_OUT / AGG_N )) || echo -)" \
            "$(titles_text "$AGG_TITLES" "$AGG_N")" "$(status_text $(( AGG_ISSUES + extra )) "$AGG_OVER")"
        if ui_verbose; then
            for f in "${GF[@]+"${GF[@]}"}"; do file_row "$f"; done
        fi
    done

    agg "${SHOW_FILES[@]+"${SHOW_FILES[@]}"}"
    season_row "Total" "$AGG_N" "$(crf_range "${AGG_CRFS[@]+"${AGG_CRFS[@]}"}")" \
        "$(tier_set "${AGG_TIERS[@]+"${AGG_TIERS[@]}"}")" \
        "$(gib "$AGG_OUT") GiB" \
        "$( (( AGG_SRC > 0 )) && echo "$(gib "$AGG_SRC") GiB" || echo -)" \
        "$(saved_pct "$AGG_SRC" "$AGG_POUT")" \
        "$( (( AGG_N > 0 )) && gib $(( AGG_OUT / AGG_N )) || echo -)" \
        "$(titles_text "$AGG_TITLES" "$AGG_N")" "$(status_text $(( AGG_ISSUES + SHOW_EXTRA )) "$AGG_OVER")"

    print_issues "${KEYS[@]}"
    ALL_FILES+=("${SHOW_FILES[@]+"${SHOW_FILES[@]}"}")
    ALL_EXTRA=$(( ALL_EXTRA + SHOW_EXTRA ))
done

# movies: files directly in out/
MKEY=$'\t'
mapfile -t MOVIES < <(grep -v '^$' <<< "${GROUP_FILES[$MKEY]:-}")
if (( ${#MOVIES[@]} )) || [[ -n "${G_EXTRA[$MKEY]:-}" ]]; then
    LW=5
    for f in "${MOVIES[@]+"${MOVIES[@]}"}"; do
        b=$(fit "$(basename "$f")")
        (( ${#b} > LW )) && LW=${#b}
    done
    tier_width "${MOVIES[@]+"${MOVIES[@]}"}"
    MOVIE_FMT="  %-*s  %-${TW}s  %-7s  %10s  %10s  %6s  %s\n"
    echo
    echo "$(ui_bold "Movies")"
    printf "$MOVIE_FMT" "$LW" "Name" "Tier" "CRF" "Size" "Source" "Saved" "Status"
    for f in "${MOVIES[@]+"${MOVIES[@]}"}"; do
        printf "$MOVIE_FMT" "$LW" "$(fit "$(basename "$f")")" "${F_TIER[$f]:--}" "${F_CRF[$f]:--}" \
            "$(gib "${F_SIZE[$f]}") GiB" \
            "$([[ -n "${F_SRC[$f]}" ]] && echo "$(gib "${F_SRC[$f]}") GiB" || echo -)" \
            "$(saved_pct "${F_SRC[$f]}" "${F_SIZE[$f]}")" "$(status_text "$(count_lines "${F_ISSUES[$f]}")" "${F_OVER[$f]:-0}" 1)"
    done
    extra=$(count_lines "${G_EXTRA[$MKEY]:-}")
    agg "${MOVIES[@]+"${MOVIES[@]}"}"
    if (( ${#MOVIES[@]} > 1 )); then
        printf "$MOVIE_FMT" "$LW" "Total ($AGG_N)" "$(tier_set "${AGG_TIERS[@]+"${AGG_TIERS[@]}"}")" \
            "$(crf_range "${AGG_CRFS[@]+"${AGG_CRFS[@]}"}")" "$(gib "$AGG_OUT") GiB" \
            "$( (( AGG_SRC > 0 )) && echo "$(gib "$AGG_SRC") GiB" || echo -)" \
            "$(saved_pct "$AGG_SRC" "$AGG_POUT")" "$(status_text $(( AGG_ISSUES + extra )) "$AGG_OVER")"
    fi
    (( AGG_TITLES > 0 )) &&
        echo "  Titles: $AGG_TITLES of $AGG_N with missing or non-standard track titles"
    print_issues "$MKEY"
    ALL_FILES+=("${MOVIES[@]+"${MOVIES[@]}"}")
    ALL_EXTRA=$(( ALL_EXTRA + extra ))
fi

# overall
agg "${ALL_FILES[@]+"${ALL_FILES[@]}"}"
echo
echo "------------------------------------------------------------"
printf 'Outputs: %s, %s GiB' "$AGG_N" "$(gib "$AGG_OUT")"
if (( AGG_SRC > 0 )); then
    printf ' (paired sources %s GiB, saved %s)' "$(gib "$AGG_SRC")" "$(saved_pct "$AGG_SRC" "$AGG_POUT")"
fi
printf '; %s\n' "$(status_text $(( AGG_ISSUES + ALL_EXTRA )) "$AGG_OVER")"
(( AGG_OVER > 0 )) &&
    echo "Over target: $AGG_OVER of $AGG_N outputs kept above their video ceiling at the tier's CRF limit (job summary)"
(( AGG_TITLES > 0 )) &&
    echo "Track titles: $AGG_TITLES of $AGG_N outputs with missing or non-standard titles (verify.sh Validate + update corrects them)"
exit 0
