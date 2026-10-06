#!/usr/bin/env bash
# Runtime for generated job scripts (work/<session>.sh).
#
# Jobs run with `set -uo pipefail` but without -e: each queued item is
# independent. A failed item is reported, its log and x265 pass stats
# are kept under work/logs/, and the queue continues with the next item.
#
# Outputs are written to "<output>.part" and only renamed to the final
# name after ffmpeg succeeded and the result passed a duration check, so
# an interrupted or failed encode is never left under the final name.
#
# State for progress-check.sh is written to work/<session>.state
# (key=value lines) and ffmpeg progress to work/<session>.progress.

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
    job_write_state
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
    echo "PASS $label"

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
        ITEM_FAIL_REASON="pass $label failed (ffmpeg exit $rc)"
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

    final="$ITEM_OUTPUT"

    if [[ -e "$final" ]] && (( ITEM_OVERWRITE != 1 )); then
        final=$(unique_output_path "$final")
        echo "WARNING: $(basename "$ITEM_OUTPUT") already exists."
        echo "         Saved as $(basename "$final") instead."
    fi

    if ! mv -f -- "$ITEM_PART" "$final"; then
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

    # Keep x265 pass stats next to the log for diagnosis.
    if [[ -n "$ITEM_PASSLOG" ]]; then
        for f in "$ITEM_PASSLOG" "$ITEM_PASSLOG".*; do
            [[ -e "$f" ]] && mv -f -- "$f" "$JOB_LOG_DIR/"
        done
    fi

    echo "FAILED: $reason" >> "$ITEM_LOG"
    printf '%s\t%s\n' "$ITEM_NAME" "$reason" >> "$JOB_LOG_DIR/failed.tsv"

    ((JOB_FAILED += 1))
    JOB_FAILED_NAMES+=("$ITEM_NAME")
    job_write_state

    echo
    echo "############################################################"
    echo "FAILED: $ITEM_NAME"
    echo "  Reason: $reason"
    echo "  Log:    $ITEM_LOG"
    echo "  No output was kept for this item. Continuing with the queue."
    echo "############################################################"
}

# report_output_stats FILE  ->  actual bitrates/sizes from a packet scan
report_output_stats() {
    local out="$1"
    local dur bytes totals vbytes abytes

    dur=$(get_duration "$out" 2>/dev/null || true)
    bytes=$(stat -c %s "$out")
    totals=$(media_stream_totals "$out")
    read -r vbytes abytes <<< "$totals"

    echo
    echo "Finished: $(basename "$out")"
    echo "  Actual video bitrate: $(bytes_to_mbps "$vbytes" "$dur") Mb/s"
    echo "  Actual audio bitrate: $(bytes_to_mbps "$abytes" "$dur") Mb/s"
    echo "  Actual video size:    $(bytes_to_gib "$vbytes") GiB"
    echo "  Actual audio size:    $(bytes_to_gib "$abytes") GiB"
    echo "  Actual file size:     $(bytes_to_gib "$bytes") GiB"
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
