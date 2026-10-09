#!/usr/bin/env bash
# Completed-encode preservation and chapter verification tests.
#
#   bash ~/compress/work/tests/verify_preserve_tests.sh
#
# Part 1 (no media tools): generated-style jobs with a stand-in encoder
# and a stand-in verification that can be told to fail. A complete
# encode that fails ONLY the output verification is kept as
# "<output>.verify-failed" (movie, CRF retries, series items, season
# batch); a complete, verified encode whose rename to the final name
# fails is kept as "<final>.finalize-failed" (a directory at the final
# name with overwrite on makes the rename fail); an incomplete / failed
# encode is still deleted; JOB_DONE_PARTS and the attempt files stay
# consistent.
# Part 2 (needs mkvtoolnix): the semantic chapter comparison
# (chapter_xml_same) on real mkvextract output: equal structures pass
# whatever the serialisation, real losses / changes fail.
# Part 3 (needs ffmpeg with libx265 + mkvtoolnix): real generated jobs.
# The accepted CRF attempt ("<output>.retry-crf<N>.part") is verified
# with its full chapter structure (the Skyfall failure: 1 edition,
# chapters with eng / en names, accepted at a lower CRF), and a real
# chapter loss keeps a readable "<output>.verify-failed", a failed final
# rename a readable "<output>.finalize-failed".
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
if [[ "${VERIFY_TESTS_KEEP:-0}" == 1 ]]; then echo "Kept: $T"; else trap 'rm -rf -- "$T"' EXIT; fi
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }

unset COMPRESS_VERBOSE
G=1073741824
gib() { awk -v g="$1" -v G=$G 'BEGIN { printf "%.0f", g * G }'; }

W="$T/work"
mkdir -p "$W/logs" "$T/in/Show" "$T/out/Show" "$T/stub"
cp -r "$SRC_WORK/lib" "$W/"
WORK_DIR="$W"
for l in media_probe media_stats bitrate encode_common hdr_dovi job_runtime; do
    source "$W/lib/$l.sh" > /dev/null
done
printf '#!/usr/bin/env bash\n[[ "$1" == has-session ]] && exit 1\nexit 0\n' > "$T/stub/tmux"
chmod +x "$T/stub/tmux"
export PATH="$T/stub:$PATH"

echo movie > "$T/in/M.mkv"
for e in 1 2 3; do echo "episode $e" > "$T/in/Show/E0$e.mkv"; done

# Stand-ins: the "encoder" writes "VIDEO AUDIO CRF DURATION" into
# $ITEM_PART (SIZES[CRF] / SIZES[EPISODE:CRF]: "V A", "fail" = ffmpeg
# fails after writing part of the file, "short" = ffmpeg "succeeds" but
# the file covers only half of the source). The verification fails for
# the episodes / CRFs listed in VFAIL ("INDEX:CRF" or "*"), "sleep"
# hangs it (interruption). Each verified file is recorded.
STUBS='
get_duration() { if [[ "$1" == "$ITEM_INPUT" ]]; then echo 100; else awk "{ print \$4 }" "$1"; fi; }
media_stream_totals() { local v a c; read -r v a c _ < "$1"; echo "$v $a"; }
item_verify_output() {
    echo "$ITEM_INDEX:${ITEM_EXP[crf]}:${ITEM_PART##*/}" >> "'"$T"'/$JOB_SESSION.verified"
    case " $VFAIL " in
        *" sleep "*) sleep 30 & ITEM_CHILD=$!; wait "$ITEM_CHILD"; return 1 ;;
        *" * "*|*" $ITEM_INDEX:${ITEM_EXP[crf]} "*)
            echo "  RESULT: FAILED - edition/chapter structure differs from the source" > "$ITEM_TMP/report.txt"
            echo "edition/chapter structure differs from the source" > "$ITEM_TMP/reason"
            return 1 ;;
    esac
    return 0
}
refresh_mkv_stats() { return 0; }
report_output_stats() { :; }
get_resolution() { echo 1920x1080; }
main_video_index() { echo 0; }
declare -A SIZES=()
VFAIL=""
fake_encode() {
    local c="${ITEM_EXP[crf]}" s
    s="${SIZES[$ITEM_INDEX:$c]:-${SIZES[$c]:-}}"
    echo "$ITEM_INDEX:$c" >> "'"$T"'/$JOB_SESSION.encoded"
    case "$s" in
        fail)  echo "partial $c" > "$ITEM_PART"; return 1 ;;
        short) echo "1 1 $c 50" > "$ITEM_PART"; return 0 ;;
        sleep) sleep 30 & ITEM_CHILD=$!; wait "$ITEM_CHILD"; return 1 ;;
    esac
    echo "$s $c 100" > "$ITEM_PART"
}
'

job() {
    {
        emit_job_header "$1" "${3:-movie}" "${4:-1}"
        printf '%s\n' "$STUBS" "$2"
        emit_job_footer
    } > "$W/$1.sh"
}
run_job() { bash "$W/$1.sh" < /dev/null > "$T/$1.log" 2>&1; }
encoded()  { tr '\n' ' ' < "$T/$1.encoded" 2>/dev/null; }
verified() { tr '\n' ' ' < "$T/$1.verified" 2>/dev/null; }
# every job file left in out/ (attempts, kept encodes, finals)
files() { (cd "$T/out" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' '); }
crf_of() { awk '{ print $3 }' "$1"; }
logdir() { ls -d "$W/logs/$1"-* 2>/dev/null | head -1; }

# movie_job SESSION TIER CRF EXPECT_EXTRA VFAIL SIZES...
movie_job() {
    local s="$1" tier="$2" crf="$3" extra="$4" vf="$5"
    shift 5
    rm -f "$T"/out/M.mkv* "$T/$s.encoded" "$T/$s.verified"
    job "$s" "SIZES=($*)
VFAIL='$vf'
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' $tier 0 '' &&
   item_expect vidx=0 mode=crf crf=$crf kbps= est_vbytes=$(gib 4) atrans= ahash=1 $extra &&
   item_crf_encode item_encode_1
then
    item_succeeded
else
    item_failed
fi"
    run_job "$s"
}
NORETRY="ceiling_vbytes= crf_min= crf_max="
HIGH="ceiling_vbytes=$(gib 7) crf_min=19 crf_max=23"
DOWN="ceiling_vbytes=$(gib 5) crf_min=15 crf_max=21 down_headroom_pct=20 down_max=2"

# ------------------------------------------------------------
echo "== movie: verification failure keeps the complete encode"

movie_job a1 Custom 20 "$NORETRY" "*" "[20]='$(gib 3) 1'"
eq    "A no retry: only the kept encode is left"   "$(files)" "M.mkv.verify-failed "
check "A kept encode is the complete CRF 20 file"  "[[ \$(crf_of '$T/out/M.mkv.verify-failed') == 20 && \$(awk '{print \$4}' '$T/out/M.mkv.verify-failed') == 100 ]]"
check "A item failed, job counts it"               "grep -q 'All encodes finished: 0 ok, 1 failed' '$T/a1.log'"
check "A reason + kept path reported"              "grep -q 'Reason: verify: edition/chapter structure differs' '$T/a1.log' && grep -q 'only the verification failed' '$T/a1.log' && grep -qF '$T/out/M.mkv.verify-failed' '$T/a1.log' && ! grep -q 'No output was kept' '$T/a1.log'"
check "A failed.tsv / kept_unverified.txt name it" "grep -qF 'encode kept: $T/out/M.mkv.verify-failed' '$(logdir a1)/failed.tsv' && grep -qxF '$T/out/M.mkv.verify-failed' '$(logdir a1)/kept_unverified.txt'"
check "A verification report kept for diagnosis"  "grep -q 'RESULT: FAILED' '$(logdir a1)/item-1.tmp/report.txt'"
check "A not listed as an interrupted attempt"     "! grep -q 'Completed CRF attempts kept' '$T/a1.log' && [[ ! -e '$(logdir a1)/kept_attempts.txt' ]]"

# an earlier kept encode is never overwritten
echo "earlier kept" > "$T/out/M.mkv.verify-failed"
rm -f "$T/a2.encoded" "$T/a2.verified"
job a2 "SIZES=([20]='$(gib 3) 1')
VFAIL='*'
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' Custom 0 '' &&
   item_expect vidx=0 mode=crf crf=20 kbps= est_vbytes=1 atrans= ahash=1 $NORETRY &&
   item_crf_encode item_encode_1
then item_succeeded; else item_failed; fi"
run_job a2
check "A no-clobber: earlier .verify-failed untouched" "[[ \$(cat '$T/out/M.mkv.verify-failed') == 'earlier kept' ]]"
check "A no-clobber: new one is .verify-failed.2"      "[[ \$(crf_of '$T/out/M.mkv.verify-failed.2') == 20 ]] && [[ '$(files)' == 'M.mkv.verify-failed M.mkv.verify-failed.2 ' ]]"
rm -f "$T"/out/M.mkv*

movie_job a3 Custom 20 "$NORETRY" "" "[20]='$(gib 3) 1'"
eq    "success: renamed to the final name, nothing else left" "$(files)" "M.mkv "
check "success: complete CRF 20 output"                       "[[ \$(crf_of '$T/out/M.mkv') == 20 ]] && grep -q 'All encodes finished: 1 ok, 0 failed' '$T/a3.log'"

echo
echo "== movie: incomplete / failed encodes are still deleted"

movie_job b1 Custom 20 "$NORETRY" "*" "[20]=fail"
eq    "B ffmpeg failed: partial .part deleted, nothing kept" "$(files)" ""
check "B not verified, no kept message"                      "[[ ! -s '$T/b1.verified' ]] && grep -q 'No output was kept' '$T/b1.log' && [[ ! -e '$(logdir b1)/kept_unverified.txt' ]]"

movie_job b2 Custom 20 "$NORETRY" "*" "[20]=short"
eq    "B incomplete encode: deleted, not kept"               "$(files)" ""
check "B reason: incomplete"                                 "grep -q 'Reason: output is incomplete' '$T/b2.log' && [[ ! -s '$T/b2.verified' ]]"

movie_job b3 High 19 "$HIGH" "*" "[19]=fail"
eq    "B retry path, first attempt fails: deleted"           "$(files)" ""

echo
echo "== movie: CRF retries"

# up: 19 over the ceiling (rejected), 20 fits -> verify fails
movie_job i1 High 19 "$HIGH" "1:20" "[19]='$(gib 7.4) 1' [20]='$(gib 6.6) 1'"
eq    "I up: verified the accepted CRF 20 attempt"     "$(verified i1)" "1:20:M.mkv.retry-crf20.part "
eq    "I up: rejected CRF 19 removed, only CRF 20 kept" "$(files)" "M.mkv.verify-failed "
check "I up: kept file is CRF 20"                      "[[ \$(crf_of '$T/out/M.mkv.verify-failed') == 20 ]]"

# down: 18 fits with headroom, 17 accepted, 16 over (rejected) -> verify fails on 17
movie_job i2 High 18 "$DOWN" "1:17" "[18]='$(gib 3.0) 1' [17]='$(gib 3.5) 1' [16]='$(gib 5.5) 1'"
eq    "I down: encoded 18, 17, 16"                     "$(encoded i2)" "1:18 1:17 1:16 "
eq    "I down: verified the accepted CRF 17 attempt"   "$(verified i2)" "1:17:M.mkv.accepted-crf17.part "
eq    "I down: only the accepted candidate kept"       "$(files)" "M.mkv.verify-failed "
check "I down: kept file is CRF 17"                    "[[ \$(crf_of '$T/out/M.mkv.verify-failed') == 17 ]]"

# down: the lower trial fails -> the accepted attempt set aside is verified
movie_job i3 High 18 "$DOWN" "1:18" "[18]='$(gib 3.0) 1' [17]=fail"
eq    "I accepted-crf name: verified that file"        "$(verified i3)" "1:18:M.mkv.accepted-crf18.part "
eq    "I accepted-crf name: kept, failed trial gone"   "$(files)" "M.mkv.verify-failed "
check "I accepted-crf name: kept file is CRF 18"       "[[ \$(crf_of '$T/out/M.mkv.verify-failed') == 18 ]]"

movie_job i4 High 18 "$DOWN" "" "[18]='$(gib 3.0) 1' [17]='$(gib 3.5) 1' [16]='$(gib 5.5) 1'"
eq    "I verify passes: final output only"             "$(files)" "M.mkv "
check "I verify passes: CRF 17 final"                  "[[ \$(crf_of '$T/out/M.mkv') == 17 ]]"
rm -f "$T"/out/M.mkv*

echo
echo "== series: same semantics"

# series_compress.sh: one item per episode
rm -f "$T"/out/Show/* "$T/j1.encoded" "$T/j1.verified"
body=""
for n in 1 2 3; do
    body+="item_encode_$n() { fake_encode; }
if item_begin $n '$T/in/Show/E0$n.mkv' '$T/out/Show/E0$n.mkv' High 0 '' &&
   item_expect vidx=0 mode=crf crf=18 kbps= est_vbytes=$(gib 4) atrans= ahash=1 ceiling_vbytes=$(gib 5) crf_min=16 crf_max=21 &&
   item_crf_encode item_encode_$n
then item_succeeded; else item_failed; fi
"
done
job j1 "SIZES=([1:18]='$(gib 4) 1' [2:18]='$(gib 5.5) 1' [2:19]='$(gib 4.5) 1' [3:18]='$(gib 4) 1')
VFAIL='2:19'
$body" series 3
run_job j1
eq    "J episodes: E02 (retried to 19) kept, the others final" "$(files)" "Show/E01.mkv Show/E02.mkv.verify-failed Show/E03.mkv "
check "J episodes: kept E02 is CRF 19, queue continued"        "[[ \$(crf_of '$T/out/Show/E02.mkv.verify-failed') == 19 ]] && grep -q 'All encodes finished: 2 ok, 1 failed' '$T/j1.log'"

# season batch of earlier job scripts (job_crf_batch)
rm -f "$T"/out/Show/* "$T/j2.encoded" "$T/j2.verified"
body=""
for n in 1 2 3; do
    body+="item_encode_$n() { fake_encode; }
item_ctx_$n() {
   item_begin $n '$T/in/Show/E0$n.mkv' '$T/out/Show/E0$n.mkv' High 0 '' &&
   item_expect vidx=0 mode=crf crf=18 kbps= est_vbytes=$(gib 4) atrans= ahash=1 ceiling_vbytes=$(gib 5) crf_min=18 crf_max=21
}
item_prep_$n() { :; }
job_batch_add $n
"
done
job j2 "SIZES=([1:18]='$(gib 5.5) 1' [2:18]='$(gib 5.5) 1' [3:18]='$(gib 5.5) 1' [1:19]='$(gib 4) 1' [2:19]='$(gib 4) 1' [3:19]='$(gib 4) 1')
VFAIL='2:19'
$body" series 3
run_job j2
eq    "J season batch: E02 kept, the others final, CRF 18 season removed" "$(files)" "Show/E01.mkv Show/E02.mkv.verify-failed Show/E03.mkv "
check "J season batch: kept E02 is the CRF 19 retry"                      "[[ \$(crf_of '$T/out/Show/E02.mkv.verify-failed') == 19 ]] && grep -q 'E02.mkv.retry-crf19.part' '$T/j2.verified'"
rm -f "$T"/out/Show/*

echo
echo "== interruption during verification (unchanged)"

rm -f "$T"/out/M.mkv* "$T/x1.encoded"
job x1 "SIZES=([20]='$(gib 3) 1')
VFAIL='sleep'
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' Custom 0 '' &&
   item_expect vidx=0 mode=crf crf=20 kbps= est_vbytes=1 atrans= ahash=1 $NORETRY &&
   item_crf_encode item_encode_1
then item_succeeded; else item_failed; fi"
bash "$W/x1.sh" < /dev/null > "$T/x1.log" 2>&1 &
pid=$!
for _ in $(seq 100); do [[ -s "$T/x1.verified" ]] && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid"; wait "$pid" 2>/dev/null
eq    "interrupted (no retry): .part removed as before, nothing kept" "$(files)" ""
check "interrupted: state says interrupted"                           "grep -qx 'status=interrupted' '$W/x1.state'"

rm -f "$T/x2.encoded" "$T/x2.verified"
job x2 "SIZES=([19]='$(gib 7.4) 1' [20]='$(gib 6) 1')
VFAIL='sleep'
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' High 0 '' &&
   item_expect vidx=0 mode=crf crf=19 kbps= est_vbytes=1 atrans= ahash=1 $HIGH &&
   item_crf_encode item_encode_1
then item_succeeded; else item_failed; fi"
bash "$W/x2.sh" < /dev/null > "$T/x2.log" 2>&1 &
pid=$!
for _ in $(seq 100); do [[ -s "$T/x2.verified" ]] && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid"; wait "$pid" 2>/dev/null
eq    "interrupted (retry): completed CRF attempt kept as before" "$(files)" "M.mkv.retry-crf20.part "
check "interrupted (retry): listed as a kept attempt"             "grep -q 'Completed CRF attempts kept' '$T/x2.log'"
rm -f "$T"/out/M.mkv*

# ------------------------------------------------------------
echo
echo "== final rename fails: the verified encode is kept"

# ow_job SESSION OVERWRITE TIER CRF EXTRA VFAIL SIZES...  (out/M.mkv as the test set it up)
ow_job() {
    local s="$1" ow="$2" tier="$3" crf="$4" extra="$5" vf="$6"
    shift 6
    rm -f "$T/$s.encoded" "$T/$s.verified"
    job "$s" "SIZES=($*)
VFAIL='$vf'
item_encode_1() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' $tier $ow '' &&
   item_expect vidx=0 mode=crf crf=$crf kbps= est_vbytes=$(gib 4) atrans= ahash=1 $extra &&
   item_crf_encode item_encode_1
then
    item_succeeded
else
    item_failed
fi"
    run_job "$s"
}
# a non-empty directory at the final name: with overwrite on, mv -fT fails
blocked() { rm -rf "$T"/out/M.mkv*; mkdir "$T/out/M.mkv"; echo "user data" > "$T/out/M.mkv/keep.txt"; }

blocked
ow_job f1 1 Custom 20 "$NORETRY" "" "[20]='$(gib 3) 1'"
eq    "B rename fails: verified encode kept as .finalize-failed" "$(files)" "M.mkv.finalize-failed M.mkv/keep.txt "
check "B kept file is the complete, verified CRF 20 encode" "[[ \$(crf_of '$T/out/M.mkv.finalize-failed') == 20 && \$(awk '{print \$4}' '$T/out/M.mkv.finalize-failed') == 100 && '$(verified f1)' == '1:20:M.mkv.part ' ]]"
check "B item failed, reason names the final file"  "grep -q 'All encodes finished: 0 ok, 1 failed' '$T/f1.log' && grep -q 'Reason: could not rename the finished .part file to M.mkv' '$T/f1.log'"
check "B banner: passed verification, kept path"    "grep -q 'passed the verification; only the' '$T/f1.log' && grep -qF '    $T/out/M.mkv.finalize-failed' '$T/f1.log' && ! grep -q 'No output was kept' '$T/f1.log' && ! grep -q 'only the verification failed' '$T/f1.log'"
check "B failed.tsv + kept_finalize_failed.txt + item log" "grep -qF 'encode kept: $T/out/M.mkv.finalize-failed' '$(logdir f1)/failed.tsv' && grep -qxF '$T/out/M.mkv.finalize-failed' '$(logdir f1)/kept_finalize_failed.txt' && grep -qF 'Completed encode kept (finalize-failed): $T/out/M.mkv.finalize-failed' '$(logdir f1)/item-1.log' && [[ ! -e '$(logdir f1)/kept_unverified.txt' ]]"
check "B the blocking directory is untouched"       "[[ \$(cat '$T/out/M.mkv/keep.txt') == 'user data' ]]"
check "D after normal job cleanup the file remains" "[[ -s '$T/out/M.mkv.finalize-failed' && -e '$(logdir f1)/job.sh' && ! -e '$W/f1.sh' ]]"

# C: never overwrite an earlier kept file (or a symlink at its name)
blocked
echo "earlier 1" > "$T/out/M.mkv.finalize-failed"
ow_job f2 1 Custom 20 "$NORETRY" "" "[20]='$(gib 3) 1'"
check "C .finalize-failed taken: kept as .finalize-failed.2" "[[ \$(cat '$T/out/M.mkv.finalize-failed') == 'earlier 1' && \$(crf_of '$T/out/M.mkv.finalize-failed.2') == 20 ]]"
ow_job f3 1 Custom 21 "$NORETRY" "" "[21]='$(gib 3) 1'"
check "C .2 taken too: .finalize-failed.3, earlier ones untouched" "[[ \$(cat '$T/out/M.mkv.finalize-failed') == 'earlier 1' && \$(crf_of '$T/out/M.mkv.finalize-failed.2') == 20 && \$(crf_of '$T/out/M.mkv.finalize-failed.3') == 21 ]]"
blocked
ln -s "$T/out/elsewhere" "$T/out/M.mkv.finalize-failed"
ow_job f4 1 Custom 20 "$NORETRY" "" "[20]='$(gib 3) 1'"
check "C a (broken) symlink at the kept name is not replaced" "[[ -L '$T/out/M.mkv.finalize-failed' && ! -e '$T/out/elsewhere' && \$(crf_of '$T/out/M.mkv.finalize-failed.2') == 20 ]]"

# CRF retry path: the accepted attempt is kept, the rejected one removed as before
blocked
ow_job f5 1 High 19 "$HIGH" "" "[19]='$(gib 7.4) 1' [20]='$(gib 6.6) 1'"
eq    "retry: accepted CRF 20 kept, rejected CRF 19 removed" "$(files)" "M.mkv.finalize-failed M.mkv/keep.txt "
check "retry: kept file is CRF 20"                         "[[ \$(crf_of '$T/out/M.mkv.finalize-failed') == 20 ]]"

# G: a verification failure still keeps .verify-failed (no rename attempted)
blocked
ow_job f6 1 Custom 20 "$NORETRY" "*" "[20]='$(gib 3) 1'"
eq    "G verify fails: .verify-failed only"                 "$(files)" "M.mkv.verify-failed M.mkv/keep.txt "
check "G banner says verification"                          "grep -q 'only the verification failed' '$T/f6.log' && [[ ! -e '$(logdir f6)/kept_finalize_failed.txt' ]]"

# F: an encode failure before verification is still deleted
blocked
ow_job f7 1 Custom 20 "$NORETRY" "" "[20]=fail"
eq    "F encode fails: partial .part deleted, nothing kept"  "$(files)" "M.mkv/keep.txt "
rm -rf "$T"/out/M.mkv*

# A / H / I: successful renames unchanged
ow_job h1 0 Custom 20 "$NORETRY" "" "[20]='$(gib 3) 1'"
eq    "A rename succeeds: final output, no kept file"        "$(files)" "M.mkv "
ow_job h2 0 Custom 21 "$NORETRY" "" "[21]='$(gib 3) 1'"
check "H existing output, no overwrite: saved as M (2).mkv"  "[[ '$(files)' == 'M (2).mkv M.mkv ' && \$(crf_of '$T/out/M.mkv') == 20 && \$(crf_of '$T/out/M (2).mkv') == 21 ]] && grep -q 'Saved as M (2).mkv instead' '$T/h2.log'"
echo "earlier kept" > "$T/out/M.mkv.finalize-failed"
echo "earlier unverified" > "$T/out/M.mkv.verify-failed"
ow_job h3 1 Custom 22 "$NORETRY" "" "[22]='$(gib 3) 1'"
check "H overwrite: only the final name replaced, kept files untouched" "[[ \$(crf_of '$T/out/M.mkv') == 22 && \$(cat '$T/out/M.mkv.finalize-failed') == 'earlier kept' && \$(cat '$T/out/M.mkv.verify-failed') == 'earlier unverified' ]]"
rm -rf "$T"/out/M*
echo "link target" > "$T/target.mkv"
ln -s "$T/target.mkv" "$T/out/M.mkv"
ow_job s1 1 Custom 20 "$NORETRY" "" "[20]='$(gib 3) 1'"
check "I symlink + overwrite: link replaced, target untouched" "[[ ! -L '$T/out/M.mkv' && \$(crf_of '$T/out/M.mkv') == 20 && \$(cat '$T/target.mkv') == 'link target' ]] && grep -q 'Replacing the symlink M.mkv' '$T/s1.log'"
rm -f "$T"/out/M*
ln -s "$T/target.mkv" "$T/out/M.mkv"
ow_job s2 0 Custom 20 "$NORETRY" "" "[20]='$(gib 3) 1'"
check "I symlink, no overwrite: saved as M (2).mkv, link kept" "[[ -L '$T/out/M.mkv' && \$(crf_of '$T/out/M (2).mkv') == 20 && \$(cat '$T/target.mkv') == 'link target' ]]"
check "A/H/I: no kept files"                                  "[[ -z \$(find '$T/out' -name '*-failed*') ]]"
rm -rf "$T"/out/M*

# E: rename failure, then the job is interrupted during the next item
blocked
rm -f "$T/e1.encoded"
job e1 "SIZES=([1:20]='$(gib 3) 1' [2:20]=sleep)
VFAIL=''
item_encode_1() { fake_encode; }
item_encode_2() { fake_encode; }
if item_begin 1 '$T/in/M.mkv' '$T/out/M.mkv' Custom 1 '' &&
   item_expect vidx=0 mode=crf crf=20 kbps= est_vbytes=1 atrans= ahash=1 $NORETRY &&
   item_crf_encode item_encode_1
then item_succeeded; else item_failed; fi
if item_begin 2 '$T/in/Show/E01.mkv' '$T/out/N.mkv' Custom 0 '' &&
   item_expect vidx=0 mode=crf crf=20 kbps= est_vbytes=1 atrans= ahash=1 $NORETRY &&
   item_crf_encode item_encode_2
then item_succeeded; else item_failed; fi" movie 2
bash "$W/e1.sh" < /dev/null > "$T/e1.log" 2>&1 &
pid=$!
for _ in $(seq 100); do grep -q '^2:20' "$T/e1.encoded" 2>/dev/null && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid"; wait "$pid" 2>/dev/null
eq    "E interrupted afterwards: kept file remains, unfinished .part removed" "$(files)" "M.mkv.finalize-failed M.mkv/keep.txt "
check "E interrupted: state says interrupted, not listed as an attempt" "grep -qx 'status=interrupted' '$W/e1.state' && ! grep -q 'Completed CRF attempts kept' '$T/e1.log'"
rm -rf "$T"/out/M.mkv* "$T"/out/N.mkv*

# J: series, one item per episode and the season batch
rm -rf "$T"/out/Show/*
mkdir "$T/out/Show/E02.mkv"
body=""
for n in 1 2 3; do
    body+="item_encode_$n() { fake_encode; }
if item_begin $n '$T/in/Show/E0$n.mkv' '$T/out/Show/E0$n.mkv' High 1 '' &&
   item_expect vidx=0 mode=crf crf=18 kbps= est_vbytes=$(gib 4) atrans= ahash=1 ceiling_vbytes=$(gib 5) crf_min=16 crf_max=21 &&
   item_crf_encode item_encode_$n
then item_succeeded; else item_failed; fi
"
done
job jf1 "SIZES=([1:18]='$(gib 4) 1' [2:18]='$(gib 5.5) 1' [2:19]='$(gib 4.5) 1' [3:18]='$(gib 4) 1')
VFAIL=''
$body" series 3
run_job jf1
check "J episodes: E02 (CRF 19) kept as .finalize-failed, others final" "[[ '$(files)' == 'Show/E01.mkv Show/E02.mkv.finalize-failed Show/E03.mkv ' && \$(crf_of '$T/out/Show/E02.mkv.finalize-failed') == 19 && -d '$T/out/Show/E02.mkv' ]] && grep -q 'All encodes finished: 2 ok, 1 failed' '$T/jf1.log'"
rm -rf "$T"/out/Show/*
mkdir "$T/out/Show/E02.mkv"
body=""
for n in 1 2 3; do
    body+="item_encode_$n() { fake_encode; }
item_ctx_$n() {
   item_begin $n '$T/in/Show/E0$n.mkv' '$T/out/Show/E0$n.mkv' High 1 '' &&
   item_expect vidx=0 mode=crf crf=18 kbps= est_vbytes=$(gib 4) atrans= ahash=1 ceiling_vbytes=$(gib 5) crf_min=18 crf_max=21
}
item_prep_$n() { :; }
job_batch_add $n
"
done
job jf2 "SIZES=([1:18]='$(gib 5.5) 1' [2:18]='$(gib 5.5) 1' [3:18]='$(gib 5.5) 1' [1:19]='$(gib 4) 1' [2:19]='$(gib 4) 1' [3:19]='$(gib 4) 1')
VFAIL=''
$body" series 3
run_job jf2
check "J season batch: E02 CRF 19 kept as .finalize-failed, others final" "[[ '$(files)' == 'Show/E01.mkv Show/E02.mkv.finalize-failed Show/E03.mkv ' && \$(crf_of '$T/out/Show/E02.mkv.finalize-failed') == 19 ]]"
rm -rf "$T"/out/Show/*

# ------------------------------------------------------------
echo
echo "== file names: job attempt files of an MKV output are Matroska"

for f in "X.mkv" "X.mkv.part" "Skyfall (2012).mkv.retry-crf13.part" "X.MKV.accepted-crf8.part" "X.mka"; do
    check "is_matroska: $f" "is_matroska '$f'"
done
for f in "X.mp4" "X.mp4.part" "X.mp4.retry-crf13.part" "X.mkv.retry-crf.part" "X.mkv.verify-failed"; do
    check "not is_matroska: $f" "! is_matroska '$f'"
done

# ------------------------------------------------------------
echo
echo "== semantic chapter comparison (mkvextract XML)"

if ! command -v mkvmerge >/dev/null || ! command -v mkvextract >/dev/null ||
   ! command -v mkvpropedit >/dev/null || ! command -v ffmpeg >/dev/null; then
    echo "  (mkvtoolnix / ffmpeg not found: skipped)"
    echo
    echo "passed: $PASS  failed: $FAIL"
    exit $(( FAIL > 0 ))
fi

C="$T/ch"
mkdir -p "$C"
ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x90:r=24:d=4" -c:v libx264 -preset ultrafast "$C/v.mkv"

# chapters_xml FILE NAMES...  ->  1 edition, one chapter per second,
# names in eng + en (as the Skyfall source); NAMES "-" = default
chapters_xml() {
    local out="$1" i=0 n
    shift
    {
        echo '<?xml version="1.0"?>'
        echo '<Chapters>'
        echo '  <EditionEntry>'
        [[ -z "${NO_UIDS:-}" ]] && echo "    <EditionUID>${EUID_V:-9000}</EditionUID>"
        echo '    <EditionFlagHidden>0</EditionFlagHidden>'
        echo '    <EditionFlagDefault>0</EditionFlagDefault>'
        for n in "$@"; do
            echo '    <ChapterAtom>'
            [[ -z "${NO_UIDS:-}" ]] && echo "      <ChapterUID>$(( ${CUID_BASE:-100} + i ))</ChapterUID>"
            printf '      <ChapterTimeStart>00:00:%02d.000000000</ChapterTimeStart>\n' "$i"
            echo '      <ChapterFlagHidden>0</ChapterFlagHidden>'
            echo '      <ChapterFlagEnabled>1</ChapterFlagEnabled>'
            echo '      <ChapterDisplay>'
            echo "        <ChapterString>$n</ChapterString>"
            echo '        <ChapterLanguage>eng</ChapterLanguage>'
            [[ -z "${NO_IETF:-}" ]] && echo '        <ChapLanguageIETF>en</ChapLanguageIETF>'
            echo '      </ChapterDisplay>'
            echo '    </ChapterAtom>'
            ((i++))
        done
        echo '  </EditionEntry>'
        echo '</Chapters>'
    } > "$out"
}
# muxed XML IN  ->  mkvextract XML of a file carrying IN (what the
# verification reads); "$C/<name>.mkv" / "$C/<name>.xml"
muxed() {
    mkvmerge -q -o "$C/$1.mkv" --chapters "$2" --no-chapters "$C/v.mkv" &&
        mkvextract "$C/$1.mkv" chapters "$C/$1.xml" > /dev/null 2>&1
}

chapters_xml "$C/src_in.xml" "Chapter 01" "Chapter 02" "Chapter 03" "Chapter 04"
muxed src "$C/src_in.xml"
REF="$C/src.xml"
check "reference: 1 edition, 4 chapters, eng + en" "[[ '$(chapter_xml_describe "$REF")' == '1 edition, 4 chapters, 4 names [eng,en]' ]]"

# restored exactly as the job does it (ffmpeg -map_chapters 0, then mkvpropedit)
ffmpeg -v error -y -i "$C/src.mkv" -map 0 -c copy -map_chapters 0 -f matroska "$C/rest.mkv.retry-crf13.part"
mkvpropedit -q "$C/rest.mkv.retry-crf13.part" --chapters "$REF"
check "restored attempt: chapters readable under the retry name"  "mkv_chapters_xml '$C/rest.mkv.retry-crf13.part' '$C/rest.xml'"
check "restored attempt: same structure"                          "chapter_xml_same '$REF' '$C/rest.xml'"
check "ffmpeg alone (und names, end times, default flag): differs" "ffmpeg -v error -y -i '$C/src.mkv' -map 0 -c copy -map_chapters 0 '$C/ff.mkv' && mkvextract '$C/ff.mkv' chapters '$C/ff.xml' >/dev/null 2>&1 && ! chapter_xml_same '$REF' '$C/ff.xml'"

# C: equal semantics, different representation
reorder() {   # language before the name, flags before the start time
    awk '/<ChapterTimeStart>/ { t = $0; next } /<ChapterFlagEnabled>/ { print; print t; next }
         /<ChapterString>/ { s = $0; next } /<\/ChapterDisplay>/ { print s } { print }' "$1"
}
reorder "$REF" > "$C/reordered.xml"
check "C serialisation order differs: same structure"       "! diff -q '$REF' '$C/reordered.xml' >/dev/null && chapter_xml_same '$REF' '$C/reordered.xml'"
NO_UIDS=1 NO_IETF=1 chapters_xml "$C/nouid_ref.xml" "Chapter 01" "Chapter 02" "Chapter 03" "Chapter 04"
NO_UIDS=1 NO_IETF=1 chapters_xml "$C/nouid_in.xml" "Chapter 01" "Chapter 02" "Chapter 03" "Chapter 04"
muxed nouid "$C/nouid_in.xml"
check "C source without UIDs / IETF: generated ones accepted" "grep -q '<ChapterUID>' '$C/nouid.xml' && grep -q '<EditionUID>' '$C/nouid.xml' && chapter_xml_same '$C/nouid_ref.xml' '$C/nouid.xml'"
CUID_BASE=500 EUID_V=777 chapters_xml "$C/uid_in.xml" "Chapter 01" "Chapter 02" "Chapter 03" "Chapter 04"
muxed uid "$C/uid_in.xml"
check "C source UIDs replaced: differs (kept exactly by design)" "! chapter_xml_same '$REF' '$C/uid.xml' '$C/uid.diff' && grep -q 'ChapterUID' '$C/uid.diff'"

# D-G: real losses / changes
chapters_xml "$C/d_in.xml" "Chapter 01" "Chapter 02" "Chapter 03"
muxed d "$C/d_in.xml"
check "D missing chapter: differs"      "! chapter_xml_same '$REF' '$C/d.xml'"
sed 's|00:00:02.000000000|00:00:02.001000000|' "$C/src_in.xml" > "$C/e_in.xml"
muxed e "$C/e_in.xml"
check "E start time +1 ms: differs"     "! chapter_xml_same '$REF' '$C/e.xml' '$C/e.diff' && grep -q 'ChapterTimeStart' '$C/e.diff'"
chapters_xml "$C/f_in.xml" "Chapter 01" "Chapter 02" "Chapter Three" "Chapter 04"
muxed f "$C/f_in.xml"
check "F changed title: differs"        "! chapter_xml_same '$REF' '$C/f.xml' '$C/f.diff' && grep -q 'Chapter Three' '$C/f.diff'"
awk '/<\/Chapters>/ { print "  <EditionEntry><EditionUID>9001</EditionUID><ChapterAtom><ChapterUID>999</ChapterUID><ChapterTimeStart>00:00:00.000000000</ChapterTimeStart></ChapterAtom></EditionEntry>" } { print }' \
    "$C/src_in.xml" > "$C/g_in.xml"
muxed g "$C/g_in.xml"
check "G extra edition: differs"        "[[ \$(grep -c '<EditionEntry>' '$C/g.xml') == 2 ]] && ! chapter_xml_same '$REF' '$C/g.xml'"
sed 's|<ChapterLanguage>eng<|<ChapterLanguage>ger<|; s|<ChapLanguageIETF>en<|<ChapLanguageIETF>de<|' "$C/src_in.xml" > "$C/l_in.xml"
muxed l "$C/l_in.xml"
check "language changed: differs"       "! chapter_xml_same '$REF' '$C/l.xml'"
sed '0,/<ChapterFlagHidden>0</s||<ChapterFlagHidden>1<|' "$C/src_in.xml" > "$C/h_in.xml"
muxed h "$C/h_in.xml"
check "hidden flag changed: differs"    "! chapter_xml_same '$REF' '$C/h.xml'"

# two names per chapter: the language must stay with its name
two_names() {
    awk -v a="$2" -v b="$3" '/<ChapterString>Chapter 01</ {
            print "        <ChapterString>Kapitel 1</ChapterString>"
            print "        <ChapterLanguage>" a "</ChapterLanguage>"
            print "      </ChapterDisplay>"
            print "      <ChapterDisplay>"
            print "        <ChapterString>Chapter 01</ChapterString>"
            print "        <ChapterLanguage>" b "</ChapterLanguage>"; getline; getline; next } { print }' "$1"
}
two_names "$C/src_in.xml" ger eng > "$C/m_in.xml";  muxed m "$C/m_in.xml"
two_names "$C/src_in.xml" eng ger > "$C/m2_in.xml"; muxed m2 "$C/m2_in.xml"
check "two names per chapter: same structure"        "chapter_xml_same '$C/m.xml' '$C/m.xml' && [[ \$(grep -c '<ChapterDisplay>' '$C/m.xml') == 5 ]]"
check "two names per chapter: languages swapped differs" "! chapter_xml_same '$C/m.xml' '$C/m2.xml'"

# ------------------------------------------------------------
echo
echo "== generated jobs, real encodes (Skyfall scenario)"

if [[ "$(ffmpeg -hide_banner -encoders 2>/dev/null)" != *libx265* ]]; then
    echo "  (ffmpeg with libx265 not found: skipped)"
else
    source "$W/lib/policy.sh"
    COMPRESS_CONF="$W/lib/compress.conf" load_policy > /dev/null
    R="$T/real"
    mkdir -p "$R/in" "$R/out"
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=24:d=4" -f lavfi -i "sine=f=440:r=48000:d=4" \
        -c:v libx264 -preset ultrafast -qp 0 -c:a aac -b:a 96k "$C/plain.mkv"
    mkvmerge -q -o "$R/in/Skyfall.mkv" --chapters "$C/src_in.xml" "$C/plain.mkv"
    cp "$C/plain.mkv" "$R/in/NoChapters.mkv"
    DV_POLICY=none HDR10P_POLICY=none

    # huge ceiling: planned CRF 21, accepted at the lower CRF 19 (limit 2),
    # verified as "Skyfall.mkv.retry-crf19.part"
    { emit_job_header s1 movie 1
      emit_encode_item 1 "$R/in/Skyfall.mkv" "$R/out/Skyfall.mkv" High crf:21 "" "" 0 1000 "$(gib 100):23:19:20:2"
      emit_job_footer; } > "$W/s1.sh"
    bash -n "$W/s1.sh" && run_job s1
    check "real: accepted at the lower CRF 19 (retry attempt)" "grep -q 'Selected CRF: *19' '$T/s1.log' && grep -q 'ENCODING (single pass, CRF 20)' '$T/s1.log'"
    check "real: editions MATCH on the retry attempt"         "grep -qE 'Editions: +MATCH \\(1 edition, 4 chapters, 4 names \\[eng,en\\]' '$T/s1.log' && grep -q 'Chapters: *MATCH' '$T/s1.log'"
    check "real: job succeeded, final name"                    "grep -q 'All encodes finished: 1 ok, 0 failed' '$T/s1.log' && [[ -f '$R/out/Skyfall.mkv' ]]"
    # the AAC source starts at a negative time: FFmpeg moves the media to
    # 0 and the restore moves the chapters by the same offset
    off=$(format_start_time "$R/in/Skyfall.mkv")
    check "real: UIDs, names, languages, flags identical"     "diff -q <(mkvextract '$R/in/Skyfall.mkv' chapters - 2>/dev/null | grep -v ChapterTimeStart) <(mkvextract '$R/out/Skyfall.mkv' chapters - 2>/dev/null | grep -v ChapterTimeStart)"
    eq    "real: start times moved with the media (${off}s)"  "$(mkvextract "$R/out/Skyfall.mkv" chapters - 2>/dev/null | grep -o '<ChapterTimeStart>[^<]*' | sed 's/.*>//' | tr '
' ' ')"         "$(for i in 0 1 2 3; do awk -v s=$i -v o="$off" 'BEGIN { t = s - o; if (t < 0) t = 0; printf "00:00:%012.9f ", t }'; done)"
    check "real: no attempt / kept files left"                 "[[ -z \$(find '$R/out' -name '*.part' -o -name '*.verify-failed*') ]]"

    # H: source without chapters
    { emit_job_header s2 movie 1
      emit_encode_item 1 "$R/in/NoChapters.mkv" "$R/out/NoChapters.mkv" High crf:21 "" "" 0 1000 "$(gib 100):23:20:20:1"
      emit_job_footer; } > "$W/s2.sh"
    bash -n "$W/s2.sh" && run_job s2
    check "H no chapters: none, job succeeded"  "grep -q 'Chapters: *none' '$T/s2.log' && ! grep -q 'Editions:' '$T/s2.log' && grep -q 'All encodes finished: 1 ok, 0 failed' '$T/s2.log'"

    # A (real): the chapter restore loses the last chapter -> verification
    # fails, the complete encode is kept and stays readable
    mkdir -p "$T/lossy"
    cat > "$T/lossy/mkvpropedit" <<EOF
#!/usr/bin/env bash
a=()
while ((\$#)); do
    if [[ "\$1" == --chapters ]]; then
        awk '/<ChapterAtom>/ { n++ } n == 4 && !done { if (/<\/ChapterAtom>/) done = 1; next } { print }' "\$2" > "$T/lossy/ch.xml"
        a+=(--chapters "$T/lossy/ch.xml"); shift 2; continue
    fi
    a+=("\$1"); shift
done
exec $(command -v mkvpropedit) "\${a[@]}"
EOF
    chmod +x "$T/lossy/mkvpropedit"
    rm -f "$R/out/Skyfall.mkv"
    { emit_job_header s3 movie 1
      emit_encode_item 1 "$R/in/Skyfall.mkv" "$R/out/Skyfall.mkv" High crf:21 "" "" 0 1000 "$(gib 100):23:20:20:1"
      emit_job_footer; } > "$W/s3.sh"
    PATH="$T/lossy:$PATH" bash "$W/s3.sh" < /dev/null > "$T/s3.log" 2>&1
    kept="$R/out/Skyfall.mkv.verify-failed"
    check "A real: verification failed on the chapter loss"  "grep -qE 'Reason: verify: (edition/)?chapter' '$T/s3.log' && grep -qE 'Editions: +CHANGED' '$T/s3.log' && grep -qE 'source: +E1/4' '$T/s3.log'"
    check "A real: complete encode kept as .verify-failed"   "[[ -s '$kept' && ! -e '$R/out/Skyfall.mkv' ]] && [[ -z \$(find '$R/out' -name '*.part') ]]"
    check "A real: kept file readable (HEVC, full duration)" "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 -f matroska '$kept') == hevc ]] && awk -v d=\$(ffprobe -v error -show_entries format=duration -of csv=p=0 -f matroska '$kept') 'BEGIN { exit !(d > 3.9) }' && mkvmerge -J '$kept' > /dev/null"

    # B (real): the verified encode cannot be renamed (a directory holds
    # the final name, overwrite on) -> kept, readable, chapters intact
    mv "$R/out/Skyfall.mkv.verify-failed" "$T/s3-kept.mkv"
    mkdir "$R/out/Skyfall.mkv"
    { emit_job_header s4 movie 1
      emit_encode_item 1 "$R/in/Skyfall.mkv" "$R/out/Skyfall.mkv" High crf:21 "" "" 1 1000 "$(gib 100):23:20:20:1"
      emit_job_footer; } > "$W/s4.sh"
    bash -n "$W/s4.sh" && run_job s4
    kept="$R/out/Skyfall.mkv.finalize-failed"
    check "B real: verified, then the rename failed"           "grep -qE 'Editions: +MATCH' '$T/s4.log' && ! grep -q 'RESULT: FAILED' '$T/s4.log' && grep -q 'Reason: could not rename the finished .part file' '$T/s4.log'"
    check "B real: kept as .finalize-failed, nothing else left" "[[ -s '$kept' && -d '$R/out/Skyfall.mkv' && -z \$(find '$R/out' -name '*.part') ]]"
    check "B real: kept file readable (HEVC, full duration, 4 chapters)" "[[ \$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 -f matroska '$kept') == hevc ]] && awk -v d=\$(ffprobe -v error -show_entries format=duration -of csv=p=0 -f matroska '$kept') 'BEGIN { exit !(d > 3.9) }' && [[ \$(mkvextract '$kept' chapters - 2>/dev/null | grep -c '<ChapterAtom>') == 4 ]]"
fi

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
