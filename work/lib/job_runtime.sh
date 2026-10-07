#!/usr/bin/env bash
# Runtime for generated job scripts (work/<session>.sh).
#
# Jobs run with `set -uo pipefail` but without -e: each queued item is
# independent. A failed item is reported, its log (and, for two-pass
# encodes, the x265 pass stats) are kept under work/logs/, and the queue
# continues with the next item.
#
# Video encode modes (item_expect mode=): crf (single-pass x265 CRF,
# movie / series High, Base, Custom), abr (two-pass bitrate, movie
# Quality), copy (source video kept). After a CRF encode the actual
# video size is reported against the pre-encode estimate and the pair
# is appended to work/logs/crf_estimates.tsv.
#
# Outputs are written to "<output>.part" and only renamed to the final
# name after ffmpeg succeeded and the result passed a duration check, so
# an interrupted or failed encode is never left under the final name.
#
# State for progress-check.sh is written to work/<session>.state
# (key=value lines) and ffmpeg progress to work/<session>.progress.
#
# Each item has a scratch directory ($ITEM_TMP, under the job log dir)
# for Dolby Vision / HDR10+ intermediates and the metadata report. It is
# removed when the item succeeds and kept (RPU, raw HEVC, tool logs) when
# it fails.

job_init() {
    JOB_SESSION="$1"
    JOB_TYPE="$2"
    JOB_ITEMS="$3"
    JOB_WORK="$4"

    JOB_STATE="$JOB_WORK/$JOB_SESSION.state"
    JOB_PROGRESS="$JOB_WORK/$JOB_SESSION.progress"
    JOB_LOG_DIR="$JOB_WORK/logs/$JOB_SESSION-$(date +%Y%m%d-%H%M%S)"
    JOB_STARTED=$(date +%s)
    JOB_STATUS="starting"
    JOB_OK=0
    JOB_FAILED=0
    JOB_DONE=0
    JOB_FAILED_NAMES=()

    ITEM_INDEX=0
    ITEM_INPUT=""
    ITEM_OUTPUT=""
    ITEM_NAME=""
    ITEM_TIER=""
    ITEM_PASS=""
    ITEM_DURATION=""
    ITEM_PART=""
    ITEM_PASSLOG=""
    ITEM_OVERWRITE=0
    ITEM_LOG=""
    ITEM_FAIL_REASON=""
    ITEM_CHILD=""
    ITEM_TMP=""
    declare -gA ITEM_EXP=()

    mkdir -p "$JOB_LOG_DIR"

    trap job_on_exit EXIT
    trap 'job_signal 129' HUP
    trap 'job_signal 130' INT
    trap 'job_signal 143' TERM

    job_write_state
}

job_write_state() {
    local tmp="$JOB_STATE.tmp"

    {
        printf 'version=1\n'
        printf 'session=%s\n' "$JOB_SESSION"
        printf 'type=%s\n' "$JOB_TYPE"
        printf 'status=%s\n' "$JOB_STATUS"
        printf 'item=%s\n' "$ITEM_INDEX"
        printf 'items=%s\n' "$JOB_ITEMS"
        printf 'ok=%s\n' "$JOB_OK"
        printf 'failed=%s\n' "$JOB_FAILED"
        printf 'name=%s\n' "${ITEM_NAME//$'\n'/ }"
        printf 'input=%s\n' "${ITEM_INPUT//$'\n'/ }"
        printf 'output=%s\n' "${ITEM_OUTPUT//$'\n'/ }"
        printf 'tier=%s\n' "$ITEM_TIER"
        printf 'pass=%s\n' "$ITEM_PASS"
        printf 'mode=%s\n' "${ITEM_EXP[mode]:-}"
        printf 'crf=%s\n' "${ITEM_EXP[crf]:-}"
        printf 'duration=%s\n' "$ITEM_DURATION"
        printf 'started=%s\n' "$JOB_STARTED"
        printf 'updated=%s\n' "$(date +%s)"
        printf 'progress=%s\n' "$JOB_PROGRESS"
        printf 'log_dir=%s\n' "$JOB_LOG_DIR"
    } > "$tmp" 2>/dev/null &&
    mv -f "$tmp" "$JOB_STATE" 2>/dev/null

    return 0
}

# HUP (tmux session killed), INT (Ctrl-C), TERM: stop the running
# ffmpeg, then exit (job_on_exit cleans up).
job_signal() {
    local code="$1"

    trap '' HUP INT TERM

    if [[ -n "${ITEM_CHILD:-}" ]] && kill -0 "$ITEM_CHILD" 2>/dev/null; then
        # item_step children are subshells running pipelines
        pkill -TERM -P "$ITEM_CHILD" 2>/dev/null
        kill -TERM "$ITEM_CHILD" 2>/dev/null
        wait "$ITEM_CHILD" 2>/dev/null
    fi

    exit "$code"
}

job_on_exit() {
    if (( JOB_DONE == 1 )); then
        return
    fi

    # Killed (tmux kill-session, Ctrl-C, ...) before job_finish.
    if [[ -n "$ITEM_PART" && -e "$ITEM_PART" ]]; then
        rm -f -- "$ITEM_PART"
    fi

    # Large intermediates are not useful after an interruption.
    if [[ -n "${ITEM_TMP:-}" && -d "$ITEM_TMP" ]]; then
        rm -f -- "$ITEM_TMP"/*.hevc "$ITEM_TMP"/video_dv.mkv
    fi

    JOB_STATUS="interrupted"
    job_write_state
    rm -f -- "$JOB_PROGRESS"

    echo
    echo "Job interrupted. Logs: $JOB_LOG_DIR"
}

# item_begin INDEX INPUT OUTPUT TIER OVERWRITE PASSLOG
item_begin() {
    ITEM_INDEX="$1"
    ITEM_INPUT="$2"
    ITEM_OUTPUT="$3"
    ITEM_TIER="$4"
    ITEM_OVERWRITE="${5:-0}"
    ITEM_PASSLOG="${6:-}"
    ITEM_NAME=$(basename "$ITEM_INPUT")
    ITEM_PART="$ITEM_OUTPUT.part"
    ITEM_LOG="$JOB_LOG_DIR/item-$ITEM_INDEX.log"
    ITEM_PASS=""
    ITEM_FAIL_REASON=""
    ITEM_DURATION=""
    ITEM_FINAL=""
    ITEM_TMP="$JOB_LOG_DIR/item-$ITEM_INDEX.tmp"
    ITEM_EXP=()
    JOB_STATUS="running"

    echo
    echo "============================================================"
    printf '%s %s/%s\n' \
        "$( [[ "$JOB_TYPE" == "series" ]] && echo Episode || echo Item )" \
        "$ITEM_INDEX" "$JOB_ITEMS"
    echo "Encoding: $ITEM_INPUT"
    echo "Output:   $(basename "$ITEM_OUTPUT")"
    echo "Tier: $ITEM_TIER"
    echo "============================================================"

    {
        echo "input:  $ITEM_INPUT"
        echo "output: $ITEM_OUTPUT"
        echo "tier:   $ITEM_TIER"
    } >> "$ITEM_LOG"

    if [[ ! -f "$ITEM_INPUT" ]]; then
        ITEM_FAIL_REASON="input file not found"
        if [[ -L "$ITEM_INPUT" ]]; then
            ITEM_FAIL_REASON="input is a broken symlink ($ITEM_INPUT -> $(readlink -- "$ITEM_INPUT"))"
        fi
        job_write_state
        return 1
    fi

    # ffmpeg/mkvpropedit would write THROUGH a symlink at the .part name
    if [[ -L "$ITEM_PART" ]]; then
        ITEM_FAIL_REASON="$(basename "$ITEM_PART") is a symlink; refusing to write through it"
        ITEM_PART=""
        job_write_state
        return 1
    fi

    if [[ -e "$ITEM_PART" ]]; then
        ITEM_FAIL_REASON="$(basename "$ITEM_PART") already exists (another encode writing it?)"
        ITEM_PART=""
        job_write_state
        return 1
    fi

    ITEM_DURATION=$(get_duration "$ITEM_INPUT" 2>/dev/null || true)
    mkdir -p "$ITEM_TMP"
    job_write_state
}

# item_expect KEY=VALUE...
#
# What the generated job intends for this item, used by the output
# verification and the final report: vidx (source main video index),
# video (encode|copy), mode (crf|abr|copy), crf, kbps, est_vbytes
# (pre-encode video estimate of a CRF encode), dv (none|preserve|drop),
# dv_profile, dv_compat, hdr10p (none|preserve|drop), scaled (0|1).
item_expect() {
    local kv

    for kv in "$@"; do
        ITEM_EXP[${kv%%=*}]="${kv#*=}"
    done

    return 0
}

# item_step LABEL FUNCTION ARGS...
#
# Runs a shell function (Dolby Vision / HDR10+ steps, verification) as
# a waited background child like item_run, output to the pane and the
# item log. The function leaves a failure reason in $ITEM_TMP/reason.
item_step() {
    local label="$1"
    local rc

    shift

    ITEM_PASS="$label"
    job_write_state
    : > "$JOB_PROGRESS"
    rm -f -- "$ITEM_TMP/reason"

    echo
    echo "STEP $label"

    {
        echo
        echo "===== $(date '+%F %T')  step $label"
        printf '%q ' "$@"
        echo
    } >> "$ITEM_LOG"

    "$@" 0<&0 > >(tee -a "$ITEM_LOG") 2>&1 &
    ITEM_CHILD=$!
    wait "$ITEM_CHILD"
    rc=$?
    ITEM_CHILD=""

    if (( rc != 0 )); then
        if [[ -s "$ITEM_TMP/reason" ]]; then
            ITEM_FAIL_REASON="$label: $(head -n 1 "$ITEM_TMP/reason")"
        else
            ITEM_FAIL_REASON="step $label failed (exit $rc)"
        fi
    fi

    return "$rc"
}

# item_run PASS_LABEL ffmpeg ARGS...
#
# Runs ffmpeg with -progress pointed at the job progress file. stderr
# still goes to the tmux pane and is also appended to the item log.
item_run() {
    local label="$1"
    local cmd="$2"
    local rc

    shift 2

    ITEM_PASS="$label"
    job_write_state
    : > "$JOB_PROGRESS"

    echo
    if [[ "$label" == "encode" ]]; then
        echo "ENCODING (single pass${ITEM_EXP[crf]:+, CRF ${ITEM_EXP[crf]}})"
    else
        echo "PASS $label"
    fi

    {
        echo
        echo "===== $(date '+%F %T')  pass $label"
        printf '%q ' "$cmd" "$@"
        echo
    } >> "$ITEM_LOG"

    # Run as a waited child (stdin kept, so 'q' still works when
    # attached): bash only runs signal traps between commands, so a
    # foreground ffmpeg would keep encoding headless after the tmux
    # session is killed.
    "$cmd" -progress "$JOB_PROGRESS" "$@" 0<&0 2> >(tee -a "$ITEM_LOG" >&2) &
    ITEM_CHILD=$!
    wait "$ITEM_CHILD"
    rc=$?
    ITEM_CHILD=""

    if (( rc != 0 )); then
        if [[ "$label" == "encode" ]]; then
            ITEM_FAIL_REASON="encode failed (ffmpeg exit $rc)"
        else
            ITEM_FAIL_REASON="pass $label failed (ffmpeg exit $rc)"
        fi
    fi

    return "$rc"
}

# item_add_cover SOURCE STREAM_INDEX FILENAME MIMETYPE
#
# Copies one attached picture from the source into "$ITEM_PART" as a
# real MKV attachment. A failure only loses the cover, so it is a
# warning, not an item failure.
item_add_cover() {
    local src="$1"
    local idx="$2"
    local name="$3"
    local mime="$4"
    local tmp="$JOB_LOG_DIR/cover-$ITEM_INDEX-$idx"

    echo "Adding cover art attachment: $name"

    if ffmpeg -v error -y -i "$src" -map "0:$idx" -c copy -frames:v 1 \
            -update 1 -f image2 "$tmp" >> "$ITEM_LOG" 2>&1 &&
       mkvpropedit "$ITEM_PART" \
            --attachment-name "$name" \
            --attachment-mime-type "$mime" \
            --add-attachment "$tmp" >> "$ITEM_LOG" 2>&1; then
        rm -f -- "$tmp"
        return 0
    fi

    rm -f -- "$tmp"
    echo "WARNING: could not copy cover art \"$name\" (see $ITEM_LOG)."
    return 0
}

# item_restore_mkv_chapters SOURCE  (item step)
#
# FFmpeg keeps only a flat chapter list of one edition (no further
# editions, ordered/hidden flags, nesting, edition UIDs or chapter
# languages). For Matroska sources the complete chapter XML is copied
# from the source into "$ITEM_PART" with mkvpropedit. Chapter times are
# moved by the same offset FFmpeg applied to the media (none with
# -copyts). When ordered chapters reference segment UIDs, or the file is
# part of a linked set, the source segment UIDs are kept as well.
#
# Writes $ITEM_TMP/chapters_state: none | restored | unverified:<why>.
# Fails the item when the restore itself fails.
item_restore_mkv_chapters() {
    local src="$1"
    local xml="$ITEM_TMP/chapters_source.xml"
    local fixed="$ITEM_TMP/chapters_restore.xml"
    local offset=0 uid prev next rc
    local args=()

    if ! is_matroska "$src"; then
        echo none > "$ITEM_TMP/chapters_state"
        return 0
    fi

    if ! command -v mkvextract >/dev/null 2>&1 || ! command -v mkvpropedit >/dev/null 2>&1; then
        echo "mkvtoolnix missing: chapters left as FFmpeg mapped them (flat list)"
        echo "unverified:mkvtoolnix missing" > "$ITEM_TMP/chapters_state"
        return 0
    fi

    if ! mkv_chapters_xml "$src" "$xml"; then
        echo none > "$ITEM_TMP/chapters_state"
        return 0
    fi

    [[ "${ITEM_EXP[copyts]:-0}" == "1" ]] || offset=$(format_start_time "$src")

    # shift ChapterTimeStart/End by -offset seconds (clamped at 0)
    awk -v off="$offset" '
        function ns(t,   a) { split(t, a, ":"); return ((a[1] * 60 + a[2]) * 60 + a[3]) * 1e9 }
        function fmt(n,   h, m, s) {
            if (n < 0) n = 0
            h = int(n / 3.6e12); n -= h * 3.6e12
            m = int(n / 6e10);   n -= m * 6e10
            s = int(n / 1e9);    n -= s * 1e9
            return sprintf("%02d:%02d:%02d.%09d", h, m, s, n)
        }
        off + 0 != 0 && match($0, /<ChapterTime(Start|End)>[0-9:.]+</) {
            pre = substr($0, 1, RSTART - 1); tag = substr($0, RSTART, RLENGTH)
            post = substr($0, RSTART + RLENGTH - 1)
            name = tag; sub(/>.*/, ">", name)
            v = tag; sub(/^[^>]*>/, "", v); sub(/<$/, "", v)
            print pre name fmt(ns(v) - off * 1e9) post
            next
        }
        { print }' "$xml" > "$fixed"

    if awk -v o="$offset" 'BEGIN { exit !(o + 0 != 0) }'; then
        echo "Chapter times moved by -${offset}s (source start offset, same as the media)."
    fi

    args=(--chapters "$fixed")

    read -r uid prev next <<< "$(mkv_segment_uids "$src")"
    if grep -q '<ChapterSegment' "$fixed" || [[ "$prev" != "-" || "$next" != "-" ]]; then
        [[ "$uid" != "-" ]] && args+=(--edit info --set "segment-uid=0x$uid")
        [[ "$prev" != "-" ]] && args+=(--edit info --set "prev-uid=0x$prev")
        [[ "$next" != "-" ]] && args+=(--edit info --set "next-uid=0x$next")
        echo "Keeping source segment UIDs (referenced by ordered chapters / linked files)."
        echo "$uid" > "$ITEM_TMP/segment_uid_kept"
    fi

    echo "Restoring chapters: $(chapter_xml_describe "$fixed")"
    mkvpropedit "$ITEM_PART" "${args[@]}" > "$ITEM_TMP/mkvpropedit_chapters.log" 2>&1
    rc=$?

    if (( rc > 1 )); then
        cat "$ITEM_TMP/mkvpropedit_chapters.log"
        printf '%s\n' "chapter restore failed (mkvpropedit exit $rc)" > "$ITEM_TMP/reason"
        return 1
    fi

    echo restored > "$ITEM_TMP/chapters_state"
}

item_succeeded() {
    local out_dur final short

    if [[ ! -s "$ITEM_PART" ]]; then
        item_failed "ffmpeg reported success but no output was written"
        return 1
    fi

    # ffmpeg exits 0 when stopped with 'q'; make sure the result covers
    # the whole source before it gets the final name.
    out_dur=$(get_duration "$ITEM_PART" 2>/dev/null || true)

    short=$(awk -v s="$ITEM_DURATION" -v o="$out_dur" 'BEGIN {
        if (s !~ /^[0-9.]+$/ || o !~ /^[0-9.]+$/) { print 0; exit }
        t = s * 0.005; if (t < 3) t = 3
        print (o < s - t) ? 1 : 0
    }')

    if (( short == 1 )); then
        item_failed "output is incomplete ($(format_hms "$out_dur") of $(format_hms "$ITEM_DURATION"))"
        return 1
    fi

    # Metadata verification before the output gets its final name: a
    # Dolby Vision / HDR10+ preservation that did not survive, or lost
    # colour signalling, fails the item.
    if ! item_step verify item_verify_output; then
        [[ -s "$ITEM_TMP/report.txt" ]] && cat "$ITEM_TMP/report.txt"
        item_failed
        return 1
    fi

    final="$ITEM_OUTPUT"

    # A symlink (valid or broken) at the output name is "taken" too.
    if path_taken "$final" && (( ITEM_OVERWRITE != 1 )); then
        final=$(unique_output_path "$final")
        echo "WARNING: $(basename "$ITEM_OUTPUT") already exists."
        echo "         Saved as $(basename "$final") instead."
    elif [[ -L "$final" ]]; then
        echo "Replacing the symlink $(basename "$final") (its target is not modified)."
    fi

    # Rename only: an existing entry (also a symlink) is replaced, never
    # written through. -T: a symlink to a directory is replaced too,
    # instead of moving the file into that directory.
    if ! mv -fT -- "$ITEM_PART" "$final"; then
        item_failed "could not rename the finished .part file"
        return 1
    fi

    ITEM_PART=""
    ITEM_FINAL="$final"

    if [[ -n "$ITEM_PASSLOG" ]]; then
        rm -f -- "$ITEM_PASSLOG" "$ITEM_PASSLOG".*
    fi

    echo "Refreshing MKV track statistics metadata..."
    if refresh_mkv_stats "$final" >/dev/null; then
        echo "MKV statistics updated from actual output."
    else
        echo "WARNING: MKV statistics update failed (is mkvtoolnix installed?)."
    fi

    report_output_stats "$final"

    if [[ -s "$ITEM_TMP/report.txt" ]]; then
        echo
        cat "$ITEM_TMP/report.txt"
    fi

    rm -rf -- "$ITEM_TMP"
    rm -f -- "$ITEM_LOG"
    ((JOB_OK += 1))
    job_write_state
}

# item_failed [REASON]
item_failed() {
    local reason="${1:-${ITEM_FAIL_REASON:-encode failed}}"
    local f

    if [[ -n "$ITEM_PART" && -e "$ITEM_PART" ]]; then
        rm -f -- "$ITEM_PART"
    fi

    ITEM_PART=""

    # Keep x265 pass stats (two-pass encodes) next to the log for diagnosis.
    if [[ -n "$ITEM_PASSLOG" ]]; then
        for f in "$ITEM_PASSLOG" "$ITEM_PASSLOG".*; do
            [[ -e "$f" ]] && mv -f -- "$f" "$JOB_LOG_DIR/"
        done
    fi

    echo "FAILED: $reason" >> "$ITEM_LOG"

    # Keep DV / HDR10+ intermediates (RPU, raw HEVC, tool logs) for
    # diagnosis; drop the directory if nothing was written.
    if [[ -n "${ITEM_TMP:-}" ]]; then
        rmdir -- "$ITEM_TMP" 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$ITEM_NAME" "$reason" >> "$JOB_LOG_DIR/failed.tsv"

    ((JOB_FAILED += 1))
    JOB_FAILED_NAMES+=("$ITEM_NAME")
    job_write_state

    echo
    echo "############################################################"
    echo "FAILED: $ITEM_NAME"
    echo "  Reason: $reason"
    echo "  Log:    $ITEM_LOG"
    if [[ -n "${ITEM_TMP:-}" && -d "$ITEM_TMP" ]]; then
        echo "  Files:  $ITEM_TMP"
    fi
    echo "  No output was kept for this item. Continuing with the queue."
    echo "############################################################"
}

# report_output_stats FILE  ->  actual bitrates/sizes from a packet scan
#
# CRF encodes also report the tier, the CRF, the pre-encode estimate and
# the estimate error. The error is information for improving the
# estimator (logged to work/logs/crf_estimates.tsv), never a failure:
# the size ceiling is a selection goal, not a byte guarantee.
report_output_stats() {
    local out="$1"
    local dur bytes totals vbytes abytes est

    dur=$(get_duration "$out" 2>/dev/null || true)
    bytes=$(file_bytes "$out")
    totals=$(media_stream_totals "$out")
    read -r vbytes abytes <<< "$totals"
    est="${ITEM_EXP[est_vbytes]:-}"

    echo
    echo "Finished: $(basename "$out")"

    case "${ITEM_EXP[mode]:-}" in
        crf)
            echo "  Tier:                 $ITEM_TIER"
            echo "  Selected CRF:         ${ITEM_EXP[crf]:-?}"
            echo "  Video encode mode:    CRF (single pass)"
            ;;
        abr)
            echo "  Video encode mode:    two-pass bitrate (${ITEM_EXP[kbps]:-?} kb/s)"
            ;;
        copy)
            echo "  Video encode mode:    source video copied (not re-encoded)"
            ;;
    esac

    echo "  Actual video bitrate: $(bytes_to_mbps "$vbytes" "$dur") Mb/s"
    echo "  Actual audio bitrate: $(bytes_to_mbps "$abytes" "$dur") Mb/s"
    echo "  Actual video size:    $(bytes_to_gib "$vbytes") GiB"

    if [[ "${ITEM_EXP[mode]:-}" == "crf" && -n "$est" ]]; then
        echo "  Estimated video size: $(bytes_to_gib "$est") GiB"
        echo "  Estimate error:       $(estimate_error_pct "$est" "$vbytes")  (actual vs pre-encode estimate; for information)"
        record_crf_estimate "$out" "$est" "$vbytes" "$dur"
    fi

    echo "  Actual audio size:    $(bytes_to_gib "$abytes") GiB"
    echo "  Actual file size:     $(bytes_to_gib "$bytes") GiB"

    if [[ -n "${ITEM_EXP[atrans]+x}" && -z "${ITEM_EXP[atrans]}" ]]; then
        echo "  Audio:                copied unchanged"
    fi
}

# record_crf_estimate OUTPUT EST_BYTES ACTUAL_BYTES DURATION
#
# Appends one line to work/logs/crf_estimates.tsv (estimate accuracy,
# for tuning the sampling later). A failure to write is ignored.
record_crf_estimate() {
    local out="$1" est="$2" act="$3" dur="$4"
    local f="$JOB_WORK/logs/crf_estimates.tsv" res

    res=$(get_resolution "$out" "$(main_video_index "$out")" 2>/dev/null || true)

    {
        [[ -s "$f" ]] ||
            printf 'date\ttier\tcrf\tresolution\tduration_s\testimated_video_bytes\tactual_video_bytes\terror_pct\tsession\tinput\n'
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date '+%F %T')" "$ITEM_TIER" "${ITEM_EXP[crf]:-}" "${res:-?}" \
            "$(awk -v d="$dur" 'BEGIN { printf "%.0f", d }')" "$est" "$act" \
            "$(estimate_error_pct "$est" "$act")" "$JOB_SESSION" "$ITEM_INPUT"
    } >> "$f" 2>/dev/null || true
}

job_finish() {
    local n

    ITEM_PASS=""
    rm -f -- "$JOB_PROGRESS"

    if (( JOB_FAILED > 0 )); then
        JOB_STATUS="failed"
    else
        JOB_STATUS="finished"
    fi

    job_write_state
    JOB_DONE=1

    # Nothing worth keeping when everything succeeded.
    if (( JOB_FAILED == 0 )); then
        rm -f -- "$JOB_LOG_DIR"/item-*.log
        rmdir -- "$JOB_LOG_DIR" 2>/dev/null || true
    fi

    rmdir -- "$JOB_WORK/${JOB_SESSION}_passes" 2>/dev/null || true

    echo
    echo "============================================================"
    echo "All encodes finished: $JOB_OK ok, $JOB_FAILED failed (of $JOB_ITEMS)"

    if (( JOB_FAILED > 0 )); then
        echo
        echo "Failed:"
        for n in "${JOB_FAILED_NAMES[@]}"; do
            echo "  $n"
        done
        echo
        echo "Logs and pass stats: $JOB_LOG_DIR"
    fi

    echo "============================================================"

    if (( JOB_FAILED > 0 )); then
        # Keep the tmux session open so the failure is noticed.
        echo
        read -rp "Press Enter to close this session... " _ || true
    fi
}
