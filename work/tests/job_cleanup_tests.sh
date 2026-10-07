#!/usr/bin/env bash
# Job runtime cleanup tests (no ffmpeg / tmux needed; tmux is stubbed).
#
#   bash ~/compress/work/tests/job_cleanup_tests.sh
#
# Also run by run_tests.sh. Covers:
#   1. a successful job removes its own work/<session>.sh and .state
#   2. a failed job moves them into its log directory (job.sh /
#      job.state) next to the kept item logs; nothing left in work/
#   3. an interrupted job keeps its files; menu-start cleanup never
#      removes files of a live tmux session or of running / failed /
#      interrupted / old-format jobs
#   4. another session's files are untouched (by a finishing job and by
#      the menu-start cleanup)
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SRC_WORK/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

W="$T/work"
mkdir -p "$W/logs" "$T/stub"
cp -r "$SRC_WORK/lib" "$W/"
WORK_DIR="$W"
for l in media_probe media_stats bitrate encode_common hdr_dovi job_runtime; do
    source "$W/lib/$l.sh"
done

# tmux stub: the sessions listed in $T/live exist
cat > "$T/stub/tmux" <<EOF
#!/usr/bin/env bash
[[ "\$1" == has-session ]] && grep -qx -- "\${3#=}" "$T/live" 2>/dev/null
EOF
chmod +x "$T/stub/tmux"
: > "$T/live"
export PATH="$T/stub:$PATH"

# job SESSION BODY  ->  work/<SESSION>.sh: a generated job whose items
# are replaced by BODY (code run between job_init and job_finish)
job() {
    {
        emit_job_header "$1" movie 1
        printf '%s\n' "$2"
        emit_job_footer
    } > "$W/$1.sh"
}
run_job() { bash "$W/$1.sh" < /dev/null > "$T/$1.log" 2>&1; }
# fake_state SESSION STATUS [STARTED]  ->  a state file of another job
fake_state() {
    printf 'version=1\nsession=%s\ntype=movie\nstatus=%s\nitem=1\nitems=1\nstarted=%s\nlog_dir=/x\n' \
        "$1" "$2" "${3:-1000}" > "$W/$1.state"
}
listing() { (cd "$W" && ls -A | grep -v '^lib$' | sort | tr '\n' ' '); }

echo "permanent result" > "$W/logs/crf_estimates.tsv"

echo
echo "== job state while running records mode / CRF"
job c90 'item_expect mode=crf crf=24; job_write_state; cp "$JOB_STATE" "'"$T"'/c90.snapshot"; JOB_OK=1'
run_job c90
check "running state: mode=crf, crf=24"            "grep -qx 'mode=crf' '$T/c90.snapshot' && grep -qx 'crf=24' '$T/c90.snapshot'"

echo
echo "== 1 successful job removes its own runtime files"
job c91 'JOB_OK=1'
mkdir -p "$W/c91_passes"
run_job c91
check "c91: finished normally"                      "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/c91.log'"
check "c91: work/c91.sh removed"                    "[[ ! -e '$W/c91.sh' ]]"
check "c91: work/c91.state (+ .tmp/.progress) removed" "[[ ! -e '$W/c91.state' && ! -e '$W/c91.state.tmp' && ! -e '$W/c91.progress' ]]"
check "c91: empty c91_passes removed"               "[[ ! -e '$W/c91_passes' ]]"
check "permanent logs kept"                         "grep -qx 'permanent result' '$W/logs/crf_estimates.tsv'"

echo
echo "== 2 failed job: files moved into its log directory"
job c92 'ITEM_LOG="$JOB_LOG_DIR/item-1.log"; echo "ffmpeg error" > "$ITEM_LOG"; JOB_FAILED=1; JOB_FAILED_NAMES=(Broken.mkv)'
run_job c92
d=$(ls -d "$W"/logs/c92-* 2>/dev/null | head -1)
check "c92: finished with errors"                   "grep -q 'All encodes finished: 0 ok, 1 failed' '$T/c92.log'"
check "c92: nothing left in work/"                  "[[ ! -e '$W/c92.sh' && ! -e '$W/c92.state' && ! -e '$W/c92.progress' ]]"
check "c92: job.sh kept in the log dir"             "[[ -n '$d' && -f '$d/job.sh' ]] && grep -q 'job_init c92 movie 1' '$d/job.sh'"
check "c92: job.state (status=failed) kept"         "grep -qx 'status=failed' '$d/job.state' && grep -qx 'log_dir=$d' '$d/job.state'"
check "c92: item log kept"                          "grep -qx 'ffmpeg error' '$d/item-1.log'"

echo
echo "== 3 interrupted / active jobs keep their files"
job c93 'sleep 30 & ITEM_CHILD=$!; wait "$ITEM_CHILD"'
bash "$W/c93.sh" < /dev/null > "$T/c93.log" 2>&1 &
pid=$!
for _ in $(seq 50); do [[ -f "$W/c93.state" ]] && break; sleep 0.1; done
check "c93: running job has its files"              "[[ -f '$W/c93.sh' && -f '$W/c93.state' ]]"
kill -TERM "$pid"; wait "$pid" 2>/dev/null
check "c93: interrupted, state says so"             "grep -qx 'status=interrupted' '$W/c93.state'"
check "c93: interrupted job keeps .sh + .state"     "[[ -f '$W/c93.sh' && -f '$W/c93.state' ]]"

# menu-start cleanup: only finished + no live session + script not newer
# than the state (the menu writes the script first, the job its state)
: > "$W/c94.sh"; fake_state c94 finished; echo c94 >> "$T/live"     # live tmux session
: > "$W/c95.sh"; fake_state c95 running                             # running, session gone
: > "$W/c96.sh"; fake_state c96 failed                              # failed
: > "$W/c97.sh"; fake_state c97 finished; mkdir -p "$W/c97_passes"  # done -> removed
: > "$W/a4.sh";  fake_state a4 finished                             # done -> removed
fake_state series3 finished; touch -d '-1 hour' "$W/series3.state"
: > "$W/series3.sh"                                                 # newer script: name reused
: > "$W/c1.sh"                                                      # old job format, no state
fake_state foo finished                                             # not a job session name
ln -s "$T/elsewhere.sh" "$W/c98.sh"; fake_state c98 finished        # script is a symlink
fake_state c99 finished; sed -i 's/^session=.*/session=c42/' "$W/c99.state"  # names another session
cleanup_finished_jobs "$W" > "$T/startup.out"
eq    "startup: removed exactly c97 and a4"         "$(listing)" \
    "c1.sh c93.sh c93.state c94.sh c94.state c95.sh c95.state c96.sh c96.state c98.sh c98.state c99.state foo.state logs series3.sh series3.state "
check "startup: empty c97_passes removed"           "[[ ! -e '$W/c97_passes' ]]"
check "startup: reports what it removed"            "grep -q 'Removed the runtime files of 2 finished job(s)' '$T/startup.out'"
check "startup: live session c94 kept"              "[[ -f '$W/c94.sh' && -f '$W/c94.state' ]]"
check "startup: running / failed / interrupted kept" "[[ -f '$W/c95.state' && -f '$W/c96.state' && -f '$W/c93.state' ]]"
check "startup: script newer than its state kept"   "[[ -f '$W/series3.sh' && -f '$W/series3.state' ]]"
check "startup: old-format c1.sh (no state) kept"   "[[ -f '$W/c1.sh' ]]"
check "startup: symlinked script left alone"        "[[ -L '$W/c98.sh' && -f '$W/c98.state' ]]"
check "startup: other session's / non-job state kept" "[[ -f '$W/c99.state' && -f '$W/foo.state' ]]"
: > "$W/c97.sh"; fake_state c97 finished
mkdir -p "$T/notmux"; ln -sf "$(command -v sed)" "$T/notmux/sed"; ln -sf "$(command -v basename)" "$T/notmux/basename"
( PATH="$T/notmux"; cleanup_finished_jobs "$W" > /dev/null )
check "startup: no tmux -> nothing removed"         "[[ -f '$W/c97.sh' && -f '$W/c97.state' ]]"
rm -f "$W/c97.sh" "$W/c97.state"

echo
echo "== 4 a finishing job never touches another session's files"
echo "other job" > "$W/c80.sh"; fake_state c80 finished 1234
job c81 'JOB_OK=1'
run_job c81
check "c81: own files removed"                      "[[ ! -e '$W/c81.sh' && ! -e '$W/c81.state' ]]"
check "c80: other session untouched"                "[[ \$(cat '$W/c80.sh') == 'other job' ]] && grep -qx 'started=1234' '$W/c80.state'"
# files at the job's own names that belong to another job (different
# start time; not the script this job runs from) are kept
: > "$W/c82.sh"; fake_state c82 starting 99
( JOB_WORK="$W" JOB_SESSION=c82 JOB_STARTED=5 JOB_STATE="$W/c82.state" \
  JOB_PROGRESS="$W/c82.progress" JOB_FAILED=0 JOB_LOG_DIR="$T/nolog"; job_cleanup_runtime )
check "c82: another job's state + script kept"      "grep -qx 'started=99' '$W/c82.state' && [[ -f '$W/c82.sh' ]]"
rm -f "$W/c82.state" "$W/c82.sh"
# a copy of a job script run from elsewhere: work/c83.sh is not its script
job c83 'JOB_OK=1'
cp "$W/c83.sh" "$T/copy.sh"
bash "$T/copy.sh" < /dev/null > "$T/c83.log" 2>&1
check "c83: work/c83.sh kept (job ran from a copy)" "[[ -f '$W/c83.sh' && ! -e '$W/c83.state' ]]"

echo
echo "== menus call the startup cleanup"
for m in "$SRC_WORK/movie_compress.sh" "$SRC_WORK/series_compress.sh" "$ROOT/audio_compress_menu.sh"; do
    check "$(basename "$m"): cleanup_finished_jobs at start" "grep -q '^cleanup_finished_jobs \"\$WORK_DIR\"' '$m'"
done

echo
echo "============================================================"
echo "passed: $PASS   failed: $FAIL"
echo "============================================================"
(( FAIL == 0 ))
