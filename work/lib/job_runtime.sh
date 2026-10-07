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
# High / Base CRF encodes (item_expect ceiling_vbytes= crf_max=) are
# checked against the tier's VIDEO ceiling after encoding: the actual
# main video bytes (packet scan; audio, subtitles and container are not
# counted) above the ceiling reject the attempt and the encode is
# repeated at CRF + 1, up to crf_max (item_crf_encode). A result that
# fits with at least down_headroom_pct to spare tries CRF - 1 (down to
# crf_min, at most down_max times); a lower attempt above the ceiling is
# discarded and the fitting one kept. Series
# batches (job_crf_batch) keep one CRF for every episode: the MEDIAN
# episode's actual video decides, and the whole season is re-encoded.
# Retries write "<output>.retry-crf<N>.part"; a completed earlier
# attempt is only deleted once a later one has completed, and is kept
# (not deleted) when the job is interrupted. Custom CRF and Quality
# never retry.
#
# Outputs are written to "<output>.part" and only renamed to the final
# name after ffmpeg succeeded and the result passed a duration check, so
# an interrupted or failed encode is never left under the final name.
#
# State for progress-check.sh is written to work/<session>.state
# (key=value lines) and ffmpeg progress to work/<session>.progress.
# When the job ends normally, job_cleanup_runtime removes its own
# work/<session>.sh and .state (failed jobs: moved into the log dir);
# interrupted jobs keep them.
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

    # CRF retry state (item_crf_encode / job_crf_batch)
    ITEM_BEGIN_MODE=""        # "" | retry | resume (see item_begin)
    ITEM_BATCH_CRF=""
    ITEM_CRF_RUN=""           # CRF that replaces the planned -crf:v:0 value
    ITEM_OVER_CEILING=0
    ITEM_ATTEMPT_ROWS=()
    JOB_BATCH=()
    JOB_OVER_NAMES=()
    declare -gA JOB_DONE_PARTS=()   # completed attempt files: never deleted on interruption

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

    # Killed (tmux kill-session, Ctrl-C, ...) before job_finish: the
    # encode in progress is removed, completed CRF attempts are kept.
    if [[ -n "$ITEM_PART" && -e "$ITEM_PART" && -z "${JOB_DONE_PARTS[$ITEM_PART]:-}" ]]; then
        rm -f -- "$ITEM_PART"
    fi

    local p kept=()
    for p in "${!JOB_DONE_PARTS[@]}"; do
        [[ -e "$p" ]] && kept+=("$p")
    done

    # Large intermediates are not useful after an interruption.
    if [[ -n "${ITEM_TMP:-}" && -d "$ITEM_TMP" ]]; then
        rm -f -- "$ITEM_TMP"/*.hevc "$ITEM_TMP"/video_dv.mkv
    fi

    JOB_STATUS="interrupted"
    job_write_state
    rm -f -- "$JOB_PROGRESS"

    echo
    echo "Job interrupted. Logs: $JOB_LOG_DIR"

    if (( ${#kept[@]} )); then
        echo "Completed CRF attempts kept (not final outputs; rename or delete them):"
        printf '  %s\n' "${kept[@]}"
        printf '%s\n' "${kept[@]}" > "$JOB_LOG_DIR/kept_attempts.txt" 2>/dev/null
    fi
}

# item_begin INDEX INPUT OUTPUT TIER OVERWRITE PASSLOG
#
# ITEM_BEGIN_MODE (series CRF batch, job_crf_batch):
#   ""      a new item: banner, "<output>.part" must not exist
#   retry   the item again for a season retry at ITEM_BATCH_CRF (banner;
#           the attempt file is checked by item_attempt_part)
#   resume  context only (finalising an accepted attempt): no banner,
#           no .part checks
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
    ITEM_CRF_RUN=""
    ITEM_OVER_CEILING=0
    ITEM_ATTEMPT_ROWS=()
    JOB_STATUS="running"

    if [[ "${ITEM_BEGIN_MODE:-}" == resume ]]; then
        ITEM_DURATION=$(get_duration "$ITEM_INPUT" 2>/dev/null || true)
        mkdir -p "$ITEM_TMP"
        job_write_state
        return 0
    fi

    echo
    echo "============================================================"
    printf '%s %s/%s%s\n' \
        "$( [[ "$JOB_TYPE" == "series" ]] && echo Episode || echo Item )" \
        "$ITEM_INDEX" "$JOB_ITEMS" \
        "$( [[ "${ITEM_BEGIN_MODE:-}" == retry ]] && echo "  (season retry at CRF $ITEM_BATCH_CRF)")"
    echo "Encoding: $ITEM_INPUT"
    echo "Output:   $(basename "$ITEM_OUTPUT")"
    echo "Tier: $ITEM_TIER"
    echo "============================================================"

    {
        echo "input:  $ITEM_INPUT"
        echo "output: $ITEM_OUTPUT"
        echo "tier:   $ITEM_TIER"
        [[ "${ITEM_BEGIN_MODE:-}" == retry ]] && echo "season retry at CRF $ITEM_BATCH_CRF"
    } >> "$ITEM_LOG"

    if [[ ! -f "$ITEM_INPUT" ]]; then
        ITEM_FAIL_REASON="input file not found"
        if [[ -L "$ITEM_INPUT" ]]; then
            ITEM_FAIL_REASON="input is a broken symlink ($ITEM_INPUT -> $(readlink -- "$ITEM_INPUT"))"
        fi
        job_write_state
        return 1
    fi

    if [[ "${ITEM_BEGIN_MODE:-}" == retry ]]; then
        ITEM_DURATION=$(get_duration "$ITEM_INPUT" 2>/dev/null || true)
        mkdir -p "$ITEM_TMP"
        job_write_state
        return 0
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

    # CRF retry: the generated command carries the planned CRF; a retry
    # attempt replaces the value of -crf:v:0 (nothing else changes)
    if [[ "$label" == "encode" && -n "${ITEM_CRF_RUN:-}" ]]; then
        local -a args=()
        local a prev=""
        for a in "$@"; do
            [[ "$prev" == "-crf:v:0" ]] && a="$ITEM_CRF_RUN"
            args+=("$a")
            prev="$a"
        done
        set -- "${args[@]}"
    fi

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

# item_part_complete  ->  0 when "$ITEM_PART" was written and covers the
# whole source (ffmpeg exits 0 when stopped with 'q'); otherwise 1 with
# ITEM_FAIL_REASON set
item_part_complete() {
    local out_dur short

    if [[ ! -s "$ITEM_PART" ]]; then
        ITEM_FAIL_REASON="ffmpeg reported success but no output was written"
        return 1
    fi

    out_dur=$(get_duration "$ITEM_PART" 2>/dev/null || true)

    short=$(awk -v s="$ITEM_DURATION" -v o="$out_dur" 'BEGIN {
        if (s !~ /^[0-9.]+$/ || o !~ /^[0-9.]+$/) { print 0; exit }
        t = s * 0.005; if (t < 3) t = 3
        print (o < s - t) ? 1 : 0
    }')

    if (( short == 1 )); then
        ITEM_FAIL_REASON="output is incomplete ($(format_hms "$out_dur") of $(format_hms "$ITEM_DURATION"))"
        return 1
    fi
}

item_succeeded() {
    local final

    # the whole source must be covered before it gets the final name
    if ! item_part_complete; then
        item_failed
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

    unset 'JOB_DONE_PARTS[$ITEM_PART]'
    ITEM_PART=""
    ITEM_FINAL="$final"
    (( ITEM_OVER_CEILING == 1 )) && JOB_OVER_NAMES+=("$ITEM_NAME")

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

    [[ -n "$ITEM_PART" ]] && unset 'JOB_DONE_PARTS[$ITEM_PART]'
    ITEM_PART=""

    # CRF attempts of this item (estimate accuracy is still useful)
    item_record_attempts "" "item failed: $reason"

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
# the estimate error, and for High / Base every CRF attempt against the
# video ceiling. The estimate error is information for improving the
# estimator (logged to work/logs/crf_estimates.tsv), never a failure.
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
        if [[ "${ITEM_EXP[crf]:-}" == "${ITEM_EXP[crf_planned]:-${ITEM_EXP[crf]:-}}" ]]; then
            echo "  Estimated video size: $(bytes_to_gib "$est") GiB"
            echo "  Estimate error:       $(estimate_error_pct "$est" "$vbytes")  (actual vs pre-encode estimate; for information)"
        else
            echo "  Estimated video size: $(bytes_to_gib "$est") GiB at the planned CRF ${ITEM_EXP[crf_planned]}"
        fi
    fi

    if (( ${#ITEM_ATTEMPT_ROWS[@]} )); then
        echo "  CRF attempts:"
        item_attempt_lines | sed 's/^/    /'
    fi

    if [[ "${ITEM_EXP[mode]:-}" == "crf" ]]; then
        if (( ${#ITEM_ATTEMPT_ROWS[@]} )); then
            item_record_attempts "$out"
        elif [[ -n "$est" ]]; then
            record_crf_estimate "$out" "${ITEM_EXP[crf]:-}" "$est" "$vbytes" "$dur"
        fi
    fi

    echo "  Actual audio size:    $(bytes_to_gib "$abytes") GiB"
    echo "  Actual file size:     $(bytes_to_gib "$bytes") GiB"

    if [[ -n "${ITEM_EXP[atrans]+x}" && -z "${ITEM_EXP[atrans]}" ]]; then
        echo "  Audio:                copied unchanged"
    fi
}

# Columns of work/logs/crf_estimates.tsv. CRF_LOG_HEADER_V1 is the
# header of logs written before the retry columns existed.
CRF_LOG_HEADER_V1=$'date\ttier\tcrf\tresolution\tduration_s\testimated_video_bytes\tactual_video_bytes\terror_pct\tsession\tinput'
CRF_LOG_HEADER="$CRF_LOG_HEADER_V1"$'\tceiling_video_bytes\tresult\treason'

# crf_log_prepare FILE  ->  FILE exists with the current header
#
# An old log (10-column header) is migrated in place: new header, older
# rows padded with "-" for the new columns (written to a temporary file
# and renamed, so the log is never half-written). A file with any other
# first line is not a log of this format: it is moved aside to
# FILE.unknown-<date> and a new log is started. Never fails the caller.
crf_log_prepare() {
    local f="$1" first tmp

    if [[ ! -s "$f" ]]; then
        printf '%s\n' "$CRF_LOG_HEADER" >> "$f" 2>/dev/null
        return 0
    fi

    IFS= read -r first < "$f" 2>/dev/null || first=""
    [[ "$first" == "$CRF_LOG_HEADER" ]] && return 0

    if [[ "$first" == "$CRF_LOG_HEADER_V1" ]]; then
        tmp="$f.migrate.$$"
        if awk -F'\t' -v OFS='\t' -v h="$CRF_LOG_HEADER" '
                NR == 1 { print h; next }
                { while (NF < 13) $(NF + 1) = "-"; print }' "$f" > "$tmp" 2>/dev/null; then
            mv -f -- "$tmp" "$f" 2>/dev/null || rm -f -- "$tmp"
        else
            rm -f -- "$tmp"
        fi
        return 0
    fi

    mv -f -- "$f" "$f.unknown-$(date +%Y%m%d-%H%M%S)" 2>/dev/null &&
        printf '%s\n' "$CRF_LOG_HEADER" > "$f" 2>/dev/null
    return 0
}

# record_crf_estimate OUTPUT CRF EST_BYTES ACTUAL_BYTES DURATION [CEILING_BYTES RESULT REASON]
#
# Appends one line to work/logs/crf_estimates.tsv (estimate accuracy and
# the CRF retry decision of each attempt). EST_BYTES "" = no estimate at
# that CRF (a retry). A failure to write is ignored.
record_crf_estimate() {
    local out="$1" crf="$2" est="$3" act="$4" dur="$5" ceil="${6:-}" result="${7:-}" reason="${8:-}"
    local f="$JOB_WORK/logs/crf_estimates.tsv" res="" err="-"

    [[ -n "$out" && -e "$out" ]] &&
        res=$(get_resolution "$out" "$(main_video_index "$out")" 2>/dev/null || true)
    [[ -n "$est" ]] && err=$(estimate_error_pct "$est" "$act")

    crf_log_prepare "$f"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%F %T')" "$ITEM_TIER" "$crf" "${res:-?}" \
        "$(awk -v d="$dur" 'BEGIN { printf "%.0f", d }')" "${est:--}" "$act" \
        "$err" "$JOB_SESSION" "$ITEM_INPUT" "${ceil:--}" "${result:--}" "${reason:--}" \
        >> "$f" 2>/dev/null || true
}

# ------------------------------------------------------------
# CRF retry against the tier's video ceiling (High / Base)
#
# Two directional phases, so a CRF is never encoded twice and the
# search always ends:
#   1. up:   while the actual video is above the ceiling, CRF + 1 (up
#            to crf_max) until an attempt fits
#   2. down: from the attempt that fits, while its video is at least
#            down_headroom_pct below the ceiling, try CRF - 1 (not below
#            crf_min, at most down_max times, never a CRF already found
#            above the ceiling). A lower attempt that fits replaces the
#            accepted one; one above the ceiling (or failing) is
#            discarded and the accepted encode is kept. The accepted
#            encode is renamed to "<output>.accepted-crf<N>.part" first
#            and only deleted after a lower attempt has fitted.
# The ceiling is a hard upper bound: an attempt above it is never
# chosen over one that fits.
# ------------------------------------------------------------

# item_retry_enabled  ->  0 for a CRF item with a video ceiling and a
# tier CRF_MAX (Custom / Quality / copy items have none)
item_retry_enabled() {
    [[ "${ITEM_EXP[mode]:-}" == crf &&
       "${ITEM_EXP[ceiling_vbytes]:-}" =~ ^[0-9]+$ && "${ITEM_EXP[crf_max]:-}" =~ ^[0-9]+$ &&
       "${ITEM_EXP[crf]:-}" =~ ^[0-9]+$ ]] && (( ITEM_EXP[ceiling_vbytes] > 0 ))
}

# item_video_bytes FILE  ->  actual main video bytes (packet scan; audio,
# subtitles, attachments and container overhead are not counted)
item_video_bytes() {
    local v a
    read -r v a <<< "$(media_stream_totals "$1")"
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}

# _down_threshold CEILING_BYTES HEADROOM_PCT  ->  bytes at or below which
# a fitting result may try CRF - 1 ("" = downward retry off)
_down_threshold() {
    [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    awk -v c="$1" -v p="$2" 'BEGIN { if (p < 100) printf "%.0f", c * (100 - p) / 100 }'
}

# field separator of attempt rows (not whitespace: empty fields such as
# a missing estimate must not collapse)
_RS=$'\x1f'

# _gib BYTES  ->  "7.40"
_gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b / 1073741824 }'; }

# attempt_line TIER CRF EST ACTUAL CEILING RESULT [REASON]
#   ->  "High | CRF 19 | est 6.80 GiB | actual 7.40 GiB | ceiling 7.00 | REJECTED -> retry CRF 20"
attempt_line() {
    local est="n/a"
    [[ -n "$3" ]] && est="$(_gib "$3") GiB"
    printf '%s | CRF %s | est %s | actual %s GiB | ceiling %s | %s%s' \
        "$1" "$2" "$est" "$(_gib "$4")" "$(_gib "$5")" "$6" "${7:+ -> $7}"
}

# item_attempt_note CRF ACTUAL RESULT [REASON]  ->  one attempt of the
# current item: item log line now, report line and estimate log row when
# the item ends. RESULT ACCEPTED-CANDIDATE: fits; becomes ACCEPTED when
# it is the final CRF (item_rows_final), stays a candidate when a lower
# CRF replaced it.
item_attempt_note() {
    local crf="$1" act="$2" result="$3" reason="${4:-}" est=""

    [[ "$crf" == "${ITEM_EXP[crf_planned]:-}" ]] && est="${ITEM_EXP[est_vbytes]:-}"
    ITEM_ATTEMPT_ROWS+=("$crf$_RS$est$_RS$act$_RS$result$_RS$reason")
    attempt_line "$ITEM_TIER" "$crf" "$est" "$act" "${ITEM_EXP[ceiling_vbytes]}" "$result" "$reason" >> "$ITEM_LOG"
    echo >> "$ITEM_LOG"
}

# item_rows_final CRF  ->  the attempt at CRF (the final one) is ACCEPTED
item_rows_final() {
    local i crf est act result reason

    for i in "${!ITEM_ATTEMPT_ROWS[@]}"; do
        IFS="$_RS" read -r crf est act result reason <<< "${ITEM_ATTEMPT_ROWS[$i]}"
        [[ "$crf" == "$1" && "$result" == ACCEPTED-CANDIDATE ]] &&
            ITEM_ATTEMPT_ROWS[$i]="$crf$_RS$est$_RS$act${_RS}ACCEPTED$_RS$reason"
    done
    return 0
}

# item_attempt_lines  ->  report line per attempt
item_attempt_lines() {
    local r crf est act result reason

    for r in "${ITEM_ATTEMPT_ROWS[@]+"${ITEM_ATTEMPT_ROWS[@]}"}"; do
        IFS="$_RS" read -r crf est act result reason <<< "$r"
        attempt_line "$ITEM_TIER" "$crf" "$est" "$act" "${ITEM_EXP[ceiling_vbytes]:-0}" "$result" "$reason"
        echo
    done
}

# item_record_attempts OUTPUT [NOTE]  ->  crf_estimates.tsv rows of the
# item's attempts (once); NOTE is added to the final attempt's reason
item_record_attempts() {
    local out="$1" note="${2:-}" r crf est act result reason

    for r in "${ITEM_ATTEMPT_ROWS[@]+"${ITEM_ATTEMPT_ROWS[@]}"}"; do
        IFS="$_RS" read -r crf est act result reason <<< "$r"
        [[ -n "$note" && "$result" != REJECTED && "$result" != ACCEPTED-CANDIDATE ]] &&
            reason="${reason:+$reason; }$note"
        record_crf_estimate "$out" "$crf" "$est" "$act" "$ITEM_DURATION" \
            "${ITEM_EXP[ceiling_vbytes]:-}" "$result" "$reason"
    done
    ITEM_ATTEMPT_ROWS=()
}

# item_attempt_part CRF  ->  ITEM_PART = "<output>.retry-crf<CRF>.part"
# (1 with ITEM_FAIL_REASON when that name is taken: never written through)
item_attempt_part() {
    local p="$ITEM_OUTPUT.retry-crf$1.part"

    if [[ -L "$p" || -e "$p" ]]; then
        ITEM_FAIL_REASON="$(basename "$p") already exists"
        return 1
    fi
    ITEM_PART="$p"
}

# _keep_accepted FILE OUTPUT CRF  ->  KEPT_PART = the accepted encode,
# renamed to "OUTPUT.accepted-crfCRF.part" (no-clobber); 1 when it
# cannot be set aside safely (then no lower CRF is tried). Runs in the
# current shell (JOB_DONE_PARTS), not in $(...).
_keep_accepted() {
    local f="$1" acc="$2.accepted-crf$3.part"

    KEPT_PART="$f"
    if [[ "$f" != "$acc" ]]; then
        [[ -e "$acc" || -L "$acc" ]] && return 1
        mv -nT -- "$f" "$acc" 2>/dev/null || return 1
        [[ -e "$acc" && ! -e "$f" ]] || return 1
        unset 'JOB_DONE_PARTS[$f]'
        JOB_DONE_PARTS[$acc]=1
    fi
    KEPT_PART="$acc"
}

# _drop_attempt FILE  ->  delete a completed attempt that a later one
# replaced
_drop_attempt() {
    [[ -n "$1" ]] || return 0
    rm -f -- "$1"
    unset 'JOB_DONE_PARTS[$1]'
}

# item_crf_encode ENCODE_FUNCTION
#
# Runs the item's encode (ENCODE_FUNCTION writes "$ITEM_PART", covers
# and chapters included). Without a ceiling (Custom) that is all. High /
# Base: phase 1 (up) and phase 2 (down) as described above. At crf_max
# still above the ceiling the last attempt is kept with a warning
# (ITEM_OVER_CEILING; the job keeps its session open at the end); when
# an upward retry fails, the completed earlier attempt is kept the same
# way. Leaves the accepted attempt in ITEM_PART and its CRF in
# ITEM_EXP[crf] (what item_verify_output checks).
item_crf_encode() {
    local fn="$1"
    local planned="${ITEM_EXP[crf]:-}" ceil max min c act prev="" prev_crf="" ok
    local thr down_max downs=0 nc a2 acc
    local -A over=()

    ITEM_EXP[crf_planned]="$planned"
    ITEM_CRF_RUN=""

    if ! item_retry_enabled; then
        "$fn"
        return
    fi

    ceil="${ITEM_EXP[ceiling_vbytes]}"
    max="${ITEM_EXP[crf_max]}"
    min="${ITEM_EXP[crf_min]:-}"
    [[ "$min" =~ ^[0-9]+$ ]] || min="$planned"
    down_max="${ITEM_EXP[down_max]:-0}"
    [[ "$down_max" =~ ^[0-9]+$ ]] || down_max=0
    thr=$(_down_threshold "$ceil" "${ITEM_EXP[down_headroom_pct]:-}")
    c="$planned"

    # ---- phase 1: up until an attempt fits
    while true; do
        ok=1
        if (( c != planned )); then
            ITEM_EXP[crf]="$c"
            ITEM_CRF_RUN="$c"
            item_attempt_part "$c" || ok=0
        fi
        (( ok == 1 )) && { "$fn" && item_part_complete || ok=0; }

        if (( ok == 0 )); then
            [[ -z "$prev" ]] && return 1

            # keep the completed earlier attempt (above the ceiling)
            [[ "$ITEM_PART" != "$prev" && "${ITEM_FAIL_REASON:-}" != *"already exists" ]] &&
                rm -f -- "$ITEM_PART"
            item_attempt_note "$c" 0 FAILED "${ITEM_FAIL_REASON:-encode failed}; kept CRF $prev_crf"
            echo
            echo "WARNING: retry at CRF $c failed (${ITEM_FAIL_REASON:-encode failed})."
            echo "         Keeping the completed CRF $prev_crf encode (above the $(_gib "$ceil") GiB video ceiling)."
            ITEM_PART="$prev"
            ITEM_EXP[crf]="$prev_crf"
            ITEM_CRF_RUN=""
            ITEM_FAIL_REASON=""
            ITEM_OVER_CEILING=1
            return 0
        fi

        JOB_DONE_PARTS[$ITEM_PART]=1
        act=$(item_video_bytes "$ITEM_PART")

        echo
        echo "CRF $c actual: $(_gib "$act") GiB / $(_gib "$ceil") GiB ceiling"

        if (( act <= ceil )); then
            echo "Result: accepted"
            item_attempt_note "$c" "$act" ACCEPTED-CANDIDATE
            _drop_attempt "$prev"
            ITEM_CRF_RUN=""
            break
        fi

        over[$c]=1
        if (( c < max )); then
            echo "Result: over ceiling -> retrying CRF $((c + 1))"
            item_attempt_note "$c" "$act" REJECTED "retry CRF $((c + 1))"
            _drop_attempt "$prev"
            prev="$ITEM_PART"
            prev_crf="$c"
            c=$((c + 1))
            continue
        fi

        echo "Result: over ceiling; CRF $max is the $ITEM_TIER limit"
        echo "WARNING: the $(_gib "$ceil") GiB video ceiling cannot be met within the $ITEM_TIER"
        echo "         CRF range ($min-$max); keeping CRF $max ($(_gib "$act") GiB video)."
        item_attempt_note "$c" "$act" "OVER CEILING" "kept: CRF $max is the $ITEM_TIER limit"
        _drop_attempt "$prev"
        ITEM_CRF_RUN=""
        ITEM_OVER_CEILING=1
        return 0
    done

    # ---- phase 2: down while the accepted result has enough headroom
    while [[ -n "$thr" ]] && (( act <= thr )); do
        nc=$((c - 1))
        if (( c <= min )); then
            echo "Headroom large, but CRF $min is the $ITEM_TIER minimum"
            break
        fi
        if (( downs >= down_max )); then
            (( down_max > 0 )) && echo "Headroom large, but the lower-CRF retry limit ($down_max) is reached"
            break
        fi
        [[ -n "${over[$nc]:-}" ]] && break

        if ! _keep_accepted "$ITEM_PART" "$ITEM_OUTPUT" "$c"; then
            ITEM_PART="$KEPT_PART"
            echo "Headroom large, but the CRF $c encode cannot be set aside safely; keeping it"
            break
        fi
        acc="$KEPT_PART"
        ITEM_PART="$acc"

        echo "Headroom large -> trying CRF $nc"
        ((downs += 1))
        ITEM_EXP[crf]="$nc"
        ITEM_CRF_RUN="$nc"

        ok=1
        item_attempt_part "$nc" || ok=0
        (( ok == 1 )) && { "$fn" && item_part_complete || ok=0; }

        if (( ok == 0 )); then
            [[ "$ITEM_PART" != "$acc" ]] && rm -f -- "$ITEM_PART"
            item_attempt_note "$nc" 0 FAILED "${ITEM_FAIL_REASON:-encode failed}; keep CRF $c"
            echo
            echo "Result: CRF $nc failed (${ITEM_FAIL_REASON:-encode failed}) -> keeping CRF $c"
            ITEM_PART="$acc"
            ITEM_FAIL_REASON=""
            break
        fi

        JOB_DONE_PARTS[$ITEM_PART]=1
        a2=$(item_video_bytes "$ITEM_PART")

        echo
        echo "CRF $nc actual: $(_gib "$a2") GiB / $(_gib "$ceil") GiB ceiling"

        if (( a2 <= ceil )); then
            echo "Result: accepted"
            item_attempt_note "$nc" "$a2" ACCEPTED-CANDIDATE
            _drop_attempt "$acc"
            c="$nc"
            act="$a2"
            continue
        fi

        echo "Result: over ceiling -> keeping CRF $c"
        item_attempt_note "$nc" "$a2" REJECTED "over ceiling; keep CRF $c"
        _drop_attempt "$ITEM_PART"
        ITEM_PART="$acc"
        break
    done

    ITEM_EXP[crf]="$c"
    ITEM_CRF_RUN=""
    item_rows_final "$c"
    return 0
}

# job_batch_add INDEX  ->  episode INDEX belongs to the series CRF batch
# (generated functions item_ctx_INDEX, item_prep_INDEX, item_encode_INDEX)
job_batch_add() {
    JOB_BATCH+=("$1")
}

# _median_bytes VALUE...  ->  median (whole number)
_median_bytes() {
    printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print 0; exit }
        if (NR % 2) printf "%.0f", v[(NR + 1) / 2]
        else printf "%.0f", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

# _batch_note ID CRF ACTUAL RESULT [REASON]  ->  attempt of episode ID
# (kept per episode until it is finalised)
_batch_note() {
    local id="$1" crf="$2" act="$3" result="$4" reason="${5:-}" est=""

    [[ "$crf" == "$BATCH_PLANNED" ]] && est="${BATCH_EST[$id]:-}"
    BATCH_ROWS[$id]+="$crf$_RS$est$_RS$act$_RS$result$_RS$reason"$'\n'
    { attempt_line "$BATCH_TIER" "$crf" "$est" "$act" "$BATCH_CEIL" "$result" "$reason"; echo; } \
        >> "$JOB_LOG_DIR/item-$id.log"
}

# _batch_notes_fit CRF VB_ARRAY_NAME  ->  ACCEPTED-CANDIDATE for every
# active episode at CRF (outliers above the nominal ceiling noted)
_batch_notes_fit() {
    local -n _vb="$2"
    local id

    for id in "${active[@]}"; do
        if (( _vb[$id] > BATCH_CEIL )); then
            _batch_note "$id" "$1" "${_vb[$id]}" ACCEPTED-CANDIDATE "above the nominal ceiling; season median fits"
        else
            _batch_note "$id" "$1" "${_vb[$id]}" ACCEPTED-CANDIDATE
        fi
    done
}

# _batch_season CRF  ->  every active episode encoded at CRF into its
# retry file (npart / nvb of job_crf_batch). 1 at the first failure
# (fail_id / why set); nothing of the earlier attempt is touched.
_batch_season() {
    local nc="$1" id

    npart=()
    nvb=()
    fail_id=""
    why=""

    for id in "${active[@]}"; do
        ITEM_BEGIN_MODE=retry
        ITEM_BATCH_CRF="$nc"
        if ! "item_ctx_$id"; then
            fail_id="$id"
            why="${ITEM_FAIL_REASON:-episode not available}"
            break
        fi
        ITEM_EXP[crf_planned]="$BATCH_PLANNED"
        ITEM_EXP[crf]="$nc"
        ITEM_CRF_RUN="$nc"

        if ! item_attempt_part "$nc"; then
            fail_id="$id"
            why="$ITEM_FAIL_REASON"
            break
        fi
        if ! "item_encode_$id" || ! item_part_complete; then
            fail_id="$id"
            why="${ITEM_FAIL_REASON:-encode failed}"
            rm -f -- "$ITEM_PART"
            break
        fi

        JOB_DONE_PARTS[$ITEM_PART]=1
        npart[$id]="$ITEM_PART"
        nvb[$id]=$(item_video_bytes "$ITEM_PART")
        ITEM_PART=""
    done

    ITEM_BEGIN_MODE=""
    ITEM_CRF_RUN=""
    ITEM_PART=""

    if [[ -n "$fail_id" ]]; then
        for id in "${!npart[@]}"; do
            _drop_attempt "${npart[$id]}"
        done
        return 1
    fi
}

# job_crf_batch  ->  encodes the series batch (job_batch_add) with ONE
# CRF for every episode
#
# Every episode is encoded at the planned CRF into its .part file. With
# a ceiling (High / Base) the MEDIAN episode's actual main video bytes
# decide, in the two phases described above, always for the whole
# season (one CRF for every episode; single episodes above the nominal
# ceiling are only listed): up while the median is above the ceiling,
# then down while the median has enough headroom. A season attempt is
# only replaced once the next one has completed for every episode; a
# failing or over-ceiling lower attempt is discarded and the previous
# season kept. Then every episode is verified at the accepted CRF and
# gets its final name (item_succeeded).
job_crf_batch() {
    (( ${#JOB_BATCH[@]} )) || return 0

    local id c="" max="" min="" med m2 fits=0 nc fail_id why n_above
    local thr="" down_max=0 downs=0 acc
    local -a active=()
    local -A part=() vb=() npart=() nvb=() over=() outp=()

    declare -gA BATCH_ROWS=() BATCH_EST=()
    BATCH_PLANNED="" BATCH_CEIL="" BATCH_TIER=""

    # ---- attempt 1: every episode at the planned CRF
    for id in "${JOB_BATCH[@]}"; do
        ITEM_BEGIN_MODE=""
        if ! "item_ctx_$id" || ! "item_prep_$id"; then
            item_failed
            continue
        fi

        if [[ -z "$c" ]]; then
            c="${ITEM_EXP[crf]}"
            BATCH_PLANNED="$c"
            BATCH_TIER="$ITEM_TIER"
            if item_retry_enabled; then
                BATCH_CEIL="${ITEM_EXP[ceiling_vbytes]}"
                max="${ITEM_EXP[crf_max]}"
                min="${ITEM_EXP[crf_min]:-}"
                [[ "$min" =~ ^[0-9]+$ ]] || min="$c"
                down_max="${ITEM_EXP[down_max]:-0}"
                [[ "$down_max" =~ ^[0-9]+$ ]] || down_max=0
                thr=$(_down_threshold "$BATCH_CEIL" "${ITEM_EXP[down_headroom_pct]:-}")
            fi
        fi
        ITEM_EXP[crf_planned]="$BATCH_PLANNED"
        BATCH_EST[$id]="${ITEM_EXP[est_vbytes]:-}"

        if ! "item_encode_$id" || ! item_part_complete; then
            item_failed
            continue
        fi

        JOB_DONE_PARTS[$ITEM_PART]=1
        part[$id]="$ITEM_PART"
        outp[$id]="$ITEM_OUTPUT"
        [[ -n "$BATCH_CEIL" ]] && vb[$id]=$(item_video_bytes "$ITEM_PART")
        active+=("$id")
        ITEM_PART=""
    done

    (( ${#active[@]} )) || return 0

    if [[ -n "$BATCH_CEIL" ]]; then
        echo
        echo "============================================================"
        echo "Season CRF check ($BATCH_TIER, ${#active[@]} episode(s))"
    fi

    # ---- phase 1: up while the median episode is above the ceiling
    while [[ -n "$BATCH_CEIL" ]]; do
        med=$(_median_bytes "${vb[@]}")
        echo
        echo "CRF $c actual median: $(_gib "$med") GiB / $(_gib "$BATCH_CEIL") GiB ceiling"

        if (( med <= BATCH_CEIL )); then
            fits=1
            echo "Result: accepted"
            _batch_notes_fit "$c" vb
            break
        fi

        over[$c]=1
        if (( c >= max )); then
            echo "Result: over ceiling; CRF $max is the $BATCH_TIER limit"
            echo "WARNING: the $(_gib "$BATCH_CEIL") GiB per-episode video ceiling cannot be met within the"
            echo "         $BATCH_TIER CRF range ($min-$max); keeping CRF $max for every episode."
            for id in "${active[@]}"; do
                _batch_note "$id" "$c" "${vb[$id]}" "OVER CEILING" "kept: season median $(_gib "$med") GiB; CRF $max is the $BATCH_TIER limit"
            done
            break
        fi

        nc=$((c + 1))
        echo "Result: over ceiling -> retrying season at CRF $nc"
        for id in "${active[@]}"; do
            _batch_note "$id" "$c" "${vb[$id]}" REJECTED "season median $(_gib "$med") GiB > ceiling; retry CRF $nc"
        done

        # the previous season attempt is kept until every episode completed
        if ! _batch_season "$nc"; then
            _batch_note "$fail_id" "$nc" 0 FAILED "$why; season kept at CRF $c"
            echo
            echo "WARNING: season retry at CRF $nc failed (episode $fail_id: $why)."
            echo "         Keeping the completed CRF $c encodes (above the ceiling) for every episode."
            break
        fi

        for id in "${active[@]}"; do
            _drop_attempt "${part[$id]}"
            part[$id]="${npart[$id]}"
            vb[$id]="${nvb[$id]}"
        done
        c="$nc"
    done

    # ---- phase 2: down while the median episode has enough headroom
    while (( fits == 1 )) && [[ -n "$thr" ]] && (( med <= thr )); do
        nc=$((c - 1))
        if (( c <= min )); then
            echo "Headroom large, but CRF $min is the $BATCH_TIER minimum"
            break
        fi
        if (( downs >= down_max )); then
            (( down_max > 0 )) && echo "Headroom large, but the lower-CRF retry limit ($down_max) is reached"
            break
        fi
        [[ -n "${over[$nc]:-}" ]] && break

        # the accepted season stays under its own names meanwhile
        acc=1
        for id in "${active[@]}"; do
            _keep_accepted "${part[$id]}" "${outp[$id]}" "$c" || acc=0
            part[$id]="$KEPT_PART"
        done
        if (( acc == 0 )); then
            echo "Headroom large, but the CRF $c season cannot be set aside safely; keeping it"
            break
        fi

        echo "Headroom large -> trying season at CRF $nc"
        ((downs += 1))

        if ! _batch_season "$nc"; then
            _batch_note "$fail_id" "$nc" 0 FAILED "$why; keep CRF $c"
            echo
            echo "Result: season at CRF $nc failed (episode $fail_id: $why) -> keeping CRF $c"
            break
        fi

        m2=$(_median_bytes "${nvb[@]}")
        echo
        echo "CRF $nc actual median: $(_gib "$m2") GiB / $(_gib "$BATCH_CEIL") GiB ceiling"

        if (( m2 > BATCH_CEIL )); then
            echo "Result: over ceiling -> keeping CRF $c"
            for id in "${active[@]}"; do
                _batch_note "$id" "$nc" "${nvb[$id]}" REJECTED "season median $(_gib "$m2") GiB > ceiling; keep CRF $c"
                _drop_attempt "${npart[$id]}"
            done
            break
        fi

        echo "Result: accepted"
        _batch_notes_fit "$nc" nvb
        for id in "${active[@]}"; do
            _drop_attempt "${part[$id]}"
            part[$id]="${npart[$id]}"
            vb[$id]="${nvb[$id]}"
        done
        c="$nc"
        med="$m2"
    done

    if [[ -n "$BATCH_CEIL" ]]; then
        if (( fits == 1 )); then
            n_above=0
            for id in "${active[@]}"; do
                (( vb[$id] > BATCH_CEIL )) && ((n_above += 1))
            done
            if (( n_above == 1 )); then
                echo "Warning: 1 episode remains above nominal ceiling"
            elif (( n_above > 1 )); then
                echo "Warning: $n_above episodes remain above nominal ceiling"
            fi
        fi
        echo "Season CRF: $c"
        echo "============================================================"
    fi

    # ---- finalise: verify every episode at the accepted CRF, final name
    for id in "${active[@]}"; do
        ITEM_BEGIN_MODE=resume
        "item_ctx_$id"
        ITEM_BEGIN_MODE=""
        ITEM_EXP[crf_planned]="$BATCH_PLANNED"
        ITEM_EXP[crf]="$c"
        ITEM_PART="${part[$id]}"
        [[ -n "$BATCH_CEIL" ]] && (( fits == 0 )) && ITEM_OVER_CEILING=1

        mapfile -t ITEM_ATTEMPT_ROWS < <(printf '%s' "${BATCH_ROWS[$id]:-}")
        item_rows_final "$c"

        echo
        echo "Finalising episode $id/$JOB_ITEMS: $ITEM_NAME (CRF $c)"
        item_succeeded || true
    done
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

    if (( ${#JOB_OVER_NAMES[@]} )); then
        echo
        echo "Above the video ceiling (kept: the ceiling cannot be met within the tier's CRF range):"
        for n in "${JOB_OVER_NAMES[@]}"; do
            echo "  $n"
        done
        echo "CRF attempts: $JOB_WORK/logs/crf_estimates.tsv"
    fi

    echo "============================================================"

    if (( JOB_FAILED > 0 || ${#JOB_OVER_NAMES[@]} > 0 )); then
        # Keep the tmux session open so a failure or a kept over-ceiling
        # result is noticed.
        echo
        read -rp "Press Enter to close this session... " _ || true
    fi

    job_cleanup_runtime
}

# job_own_state  ->  0 when JOB_STATE is still this job's state file
# (same session and start time), so another job's file is never touched
job_own_state() {
    [[ -f "$JOB_STATE" ]] &&
        [[ "$(sed -n 's/^session=//p' "$JOB_STATE" 2>/dev/null)" == "$JOB_SESSION" ]] &&
        [[ "$(sed -n 's/^started=//p' "$JOB_STATE" 2>/dev/null)" == "$JOB_STARTED" ]]
}

# job_cleanup_runtime  ->  after job_finish: remove this job's own
# runtime files from the work directory. Logs (work/logs/) are kept.
#   all items ok:   work/<session>.sh and .state are deleted
#   some failed:    both are moved into the job's log directory
#                   (job.sh / job.state) next to the item logs
# The script is only touched when it is the file this job runs from
# ($0), the state only when it is still this job's (job_own_state).
# Interrupted jobs never get here (job_on_exit keeps their files).
job_cleanup_runtime() {
    local script="$JOB_WORK/$JOB_SESSION.sh" own_script=0 own_state=0

    [[ -f "$script" && "$(readlink -f -- "$0" 2>/dev/null)" == "$(readlink -f -- "$script" 2>/dev/null)" ]] &&
        own_script=1
    job_own_state && own_state=1

    rm -f -- "$JOB_STATE.tmp" "$JOB_PROGRESS"

    if (( JOB_FAILED > 0 )) && [[ -d "$JOB_LOG_DIR" ]]; then
        (( own_script )) && mv -f -- "$script" "$JOB_LOG_DIR/job.sh" 2>/dev/null
        (( own_state )) && mv -f -- "$JOB_STATE" "$JOB_LOG_DIR/job.state" 2>/dev/null
    else
        (( own_script )) && rm -f -- "$script"
        (( own_state )) && rm -f -- "$JOB_STATE"
    fi
    return 0
}
