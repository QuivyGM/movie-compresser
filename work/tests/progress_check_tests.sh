#!/usr/bin/env bash
# progress-check.sh layout tests: CURRENT block, JOB QUEUE (only for a
# job of more than one item), [DONE] / [NOW] / [NEXT] / [WAIT], inline or
# wrapped queue metadata, single-item jobs, finished jobs.
#
#   bash ~/compress/work/tests/progress_check_tests.sh
#
# Stand-ins only: tmux and ffprobe are stubs (a source "file" holds its
# runtime), no ffmpeg, no encodes.
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

H="$T/home"
W="$H/compress/work"
mkdir -p "$W/lib" "$T/stub" "$T/src"
cp "$SRC_WORK/lib/bitrate.sh" "$SRC_WORK/lib/media_probe.sh" "$SRC_WORK/lib/media_stats.sh" "$W/lib/"
cp "$ROOT/progress-check.sh" "$H/compress/"
now=$(date +%s)

# ffprobe stub: the duration stored in the source file
cat > "$T/stub/ffprobe" <<'EOF'
#!/usr/bin/env bash
for a; do f="$a"; done
[[ -f "$f" ]] && sed -n 's/^dur=//p' "$f"
EOF
chmod +x "$T/stub/ffprobe"

src() { printf 'dur=%s\n' "$2" > "$T/src/$1"; printf '%s' "$T/src/$1"; }

# job SESSION ITEM_LINES...  ->  the job script (item_begin / item_expect
# as emit_encode_item writes them, %q in a UTF-8 locale like the menus;
# JOB_LC=C: as a non-UTF-8 locale writes them, $'...');
# ITEM_LINE "IDX|PATH|TIER|CRF|EXTRA"
job() {
    local s="$1" l idx p tier crf extra
    local LC_ALL="${JOB_LC:-C.UTF-8}"
    shift
    for l in "$@"; do
        IFS='|' read -r idx p tier crf extra <<< "$l"
        printf 'if item_begin %q %q %q %q 0 "" &&\n' "$idx" "$p" "/out/$(basename "$p")" "$tier"
        printf '   item_expect vidx=0 mode=crf crf=%s kbps= est_vbytes=1 atrans= ahash=1 ceiling_vbytes=9%s &&\n' "$crf" "${extra:+ $extra}"
        printf '   item_crf_encode item_encode_%s\nthen\n    item_succeeded\nfi\n' "$idx"
    done > "$W/$s.sh"
    touch -d "@$((now - 4000))" "$W/$s.sh"
}

# state SESSION KEY=VALUE...  (and its progress file)
state() {
    local s="$1"
    shift
    {
        printf 'version=1\nsession=%s\ntype=movie\nstatus=running\nok=0\nfailed=0\nmode=crf\npass=encode\n' "$s"
        printf 'progress=%s\nlog_dir=%s\n' "$W/$s.progress" "$W/logs/$s"
        printf '%s\n' "$@"
    } > "$W/$s.state"
}

# itemlog SESSION IDX SECONDS_AGO PATH CRF DONE
itemlog() {
    mkdir -p "$W/logs/$1"
    {
        echo "input:  $4"
        echo
        echo "===== $(date -d "@$((now - $3))" '+%F %T')  pass encode"
        echo "ffmpeg -y -i $4 -crf:v:0 $5 out.mkv"
        [[ "$6" == 1 ]] && echo "[out#0/matroska @ 0x1] video:1KiB audio:0KiB muxing overhead: 1.0%"
    } > "$W/logs/$1/item-$2.log"
}

# ---- c1: two movies, the first encoding (the layout example)
A=$(src "Mission- Impossible (1996).mkv" 6613)
B=$(src "Mission- Impossible – Fallout (2018).mkv" 8845)
job c1 "1|$A|Base|23|down_mode=boundary" "2|$B|Base|21|down_mode=manual"
state c1 item=1 items=2 "name=Mission- Impossible (1996).mkv" "input=$A" tier=Base crf=23 duration=6613 \
    "started=$((now - 103))" "updated=$now"
printf 'out_time_us=55000000\nspeed=0.736x\nprogress=continue\n' > "$W/c1.progress"
itemlog c1 1 103 "$A" 23 0

# ---- c2: one movie
C=$(src "Solo.mkv" 6613)
job c2 "1|$C|Base|23|"
state c2 item=1 items=1 name=Solo.mkv "input=$C" tier=Base crf=23 duration=6613 \
    "started=$((now - 103))" "updated=$now"
printf 'out_time_us=55000000\nspeed=0.736x\nprogress=continue\n' > "$W/c2.progress"
itemlog c2 1 103 "$C" 23 0

# ---- c3: four movies, the second encoding, the first done at CRF 22
# (planned 24 in the script: the log's final CRF is shown)
D1=$(src "Movie A.mkv" 3600); D2=$(src "Movie B.mkv" 3600); D3=$(src "Movie C.mkv" 3600); D4=$(src "Movie D.mkv" 3600)
job c3 "1|$D1|Base|24|" "2|$D2|Base|21|" "3|$D3|Base|23|down_mode=manual" "4|$D4|High|15|"
state c3 item=2 items=4 "name=Movie B.mkv" "input=$D2" tier=Base crf=21 duration=3600 ok=1 \
    "started=$((now - 7863))" "updated=$now"
printf 'out_time_us=1800000000\nspeed=1.0x\nprogress=continue\n' > "$W/c3.progress"
itemlog c3 1 7863 "$D1" 22 1
itemlog c3 2 600 "$D2" 21 0

# ---- c5: two movies, the job script quoted in the C locale ($'...' names)
E1=$(src "Plain.mkv" 3600); E2=$(src "Dash – Name.mkv" 3600)
JOB_LC=C job c5 "1|$E1|Base|20|" "2|$E2|High|14|"
state c5 item=1 items=2 name=Plain.mkv "input=$E1" tier=Base crf=20 duration=3600 \
    "started=$((now - 60))" "updated=$now"
printf 'out_time_us=60000000\nspeed=1.0x\nprogress=continue\n' > "$W/c5.progress"

# ---- series9: episode 3/4 encoding; episodes 1-2 completed per their item
# logs (60 s of source each, 600 s wall each: 0.1x overall incl. overhead;
# series job scripts: item_begin without item_expect)
sstart=$((now - 1500))
for i in 1 2 3 4; do S[$i]=$(src "E0$i.mkv" 60); done
for i in 1 2 3; do itemlog series9 "$i" $((1500 - (i - 1) * 600)) "${S[$i]}" $((i == 3 ? 19 : 18)) $((i < 3)); done
for i in 1 2 3 4; do
    printf 'item_ctx_%s() {\n   item_begin %s %q %q High 0 "" &&\n}\n' "$i" "$i" "${S[$i]}" "/out/E0$i.mkv"
done > "$W/series9.sh"
touch -d '@1' "$W/series9.sh"
state series9 type=series item=3 items=4 name=E03.mkv "input=${S[3]}" tier=High crf=18 duration=60 \
    "started=$sstart" "updated=$now"
sed -i 's/^type=movie$//' "$W/series9.state"
printf 'out_time_us=30000000\nspeed=0.1x\nprogress=continue\n' > "$W/series9.progress"

# ---- c4: finished, the session waits for Enter
state c4 item=2 items=2 status=finished ok=2 name=X.mkv tier=Base "started=$((now - 600))" "updated=$((now - 60))"
sed -i 's/^status=running$//' "$W/c4.state"

cat > "$T/stub/tmux" <<EOF
#!/usr/bin/env bash
[[ "\$1" == list-sessions ]] && printf 'c1 %s\nc2 %s\nc3 %s\nc4 %s\nc5 %s\nseries9 %s\n' $now $now $now $now $now $sstart
exit 0
EOF
chmod +x "$T/stub/tmux"

run() {   # COLUMNS  ->  $T/out
    ( cd "$H" && HOME="$H" COLUMNS="$1" LC_ALL=C.UTF-8 PATH="$T/stub:$PATH" bash "$H/compress/progress-check.sh" ) > "$T/out" 2>&1
}
block() { sed -n "/^$1 — /,/^=\{70\}\$/{//!p;}" "$T/out" | sed -n "1,/^=\{70\}\$/p"; }
job_block() { awk -v s="$1 — " 'index($0, s) == 1 { on = 1 } on { print } on && /^={70}$/ && ++r == 2 { exit }' "$T/out"; }
hasx() { grep -qxF -- "$2" <<< "$1"; }
hasre() { grep -qxE -- "$2" <<< "$1"; }
# the runs come seconds after the states were written (103 s ago), and a
# run takes a few seconds on slow-fork systems
EL1='Elapsed: 00:0[1-5]:[0-5][0-9]'

echo "== multi-item job (inline queue, wide terminal)"
run 120
B1=$(job_block c1)
check "header and rules" "hasx \"\$B1\" 'c1 — Movie' && [[ \$(grep -cx '=\\{70\\}' <<< \"\$B1\") == 2 ]]"
check "CURRENT block" \
    "hasx \"\$B1\" 'CURRENT: Mission- Impossible (1996).mkv' && hasx \"\$B1\" '  Base | CRF 23 | Encoding' && hasx \"\$B1\" '  Progress:  0.8%   00:00:55 / 01:50:13   0.736x' && hasre \"\$B1\" '  ETA:       02:28:30    $EL1'"
check "JOB QUEUE with the job ETA / elapsed (ETA math unchanged)" \
    "hasx \"\$B1\" 'JOB QUEUE' && hasx \"\$B1\" '----------------------------------------------------------------------' && hasre \"\$B1\" '  ETA:       05:48:48    $EL1'"
check "queue rows inline: [NOW] current with status, [NEXT] manual CRF" \
    "grep -qE '^  \\[NOW\\]  1\\. Mission- Impossible \\(1996\\)\\.mkv +Base \\| CRF 23 \\| Encoding\$' <<< \"\$B1\" && grep -qE '^  \\[NEXT\\] 2\\. Mission- Impossible – Fallout \\(2018\\)\\.mkv +Base \\| CRF 21 \\(manual\\)\$' <<< \"\$B1\""
check "totals and CRF note" \
    "hasx \"\$B1\" '  Completed: 0' && hasx \"\$B1\" '  Remaining: 1 queued' && hasx \"\$B1\" '  Note: CRF retries/tests not yet started are excluded'"
check "no old fields / JOB TOTAL" "! grep -qE '^(File|Tier|Status|Total ETA|Item ETA):|JOB TOTAL' <<< \"\$B1\""

echo "== multi-item job (narrow terminal: metadata wrapped)"
run 60
B1=$(job_block c1)
check "wrapped rows" \
    "hasx \"\$B1\" '  [NOW]  1. Mission- Impossible (1996).mkv' && hasx \"\$B1\" '            Base | CRF 23 | Encoding' && hasx \"\$B1\" '  [NEXT] 2. Mission- Impossible – Fallout (2018).mkv' && hasx \"\$B1\" '            Base | CRF 21 (manual)'"

echo "== single-item job"
run 120
B2=$(job_block c2)
check "CURRENT only, no JOB QUEUE" "hasx \"\$B2\" 'CURRENT: Solo.mkv' && ! grep -q 'JOB QUEUE' <<< \"\$B2\" && ! grep -q '\\[NOW\\]' <<< \"\$B2\""
eq    "one ETA / elapsed line" "$(grep -c '^  ETA:' <<< "$B2")" "1"
check "single item: ETA line and note" \
    "hasre \"\$B2\" '  ETA:       02:28:30    $EL1' && hasx \"\$B2\" '  Note: CRF retries/tests not yet started are excluded'"

echo "== four items: DONE / NOW / NEXT / WAIT"
B3=$(job_block c3)
check "statuses and metadata" \
    "grep -qE '^  \\[DONE\\] 1\\. Movie A\\.mkv +Base \\| CRF 22\$' <<< \"\$B3\" && grep -qE '^  \\[NOW\\]  2\\. Movie B\\.mkv +Base \\| CRF 21 \\| Encoding\$' <<< \"\$B3\" && grep -qE '^  \\[NEXT\\] 3\\. Movie C\\.mkv +Base \\| CRF 23 \\(manual\\)\$' <<< \"\$B3\" && grep -qE '^  \\[WAIT\\] 4\\. Movie D\\.mkv +High \\| CRF 15\$' <<< \"\$B3\""
eq    "exactly one [NOW]" "$(grep -c '\[NOW\]' <<< "$B3")" "1"
check "Completed / Remaining (after the current item)" "hasx \"\$B3\" '  Completed: 1' && hasx \"\$B3\" '  Remaining: 2 queued'"
check "inline columns aligned" \
    "[[ \$(grep -E '^  \\[(DONE|NOW|NEXT|WAIT)' <<< \"\$B3\" | LC_ALL=C.UTF-8 awk '{ print index(\$0, \"Base\") + index(\$0, \"High\") }' | sort -u | wc -l) == 1 ]]"
B1=$(job_block c1)
check "inline columns aligned with a multibyte (en dash) name" \
    "[[ \$(grep -E '^  \\[(NOW|NEXT)' <<< \"\$B1\" | LC_ALL=C.UTF-8 awk '{ print index(\$0, \"Base |\") }' | sort -u | wc -l) == 1 ]]"

echo "== \$'...'-quoted name in the job script"
B5=$(job_block c5)
check "octal escapes decoded for display" "grep -qE '^  \\[NEXT\\] 2\\. Dash – Name\\.mkv +High \\| CRF 14\$' <<< \"\$B5\""

echo "== series: ETA from completed episodes (calculation unchanged)"
B9=$(job_block series9)
check "series queue and CURRENT" \
    "hasx \"\$B9\" 'series9 — Series' && hasx \"\$B9\" '  High | CRF 19 | Encoding' && grep -qE '^  \\[DONE\\] 1\\. E01\\.mkv +High \\| CRF 18\$' <<< \"\$B9\" && grep -qE '^  \\[NOW\\]  3\\. E03\\.mkv +High \\| CRF 19 \\| Encoding\$' <<< \"\$B9\" && grep -qE '^  \\[NEXT\\] 4\\. E04\\.mkv +High\$' <<< \"\$B9\" && hasx \"\$B9\" '  Completed: 2' && hasx \"\$B9\" '  Remaining: 1 queued'"
# item: 30 s left at 0.1x = 300 s; episode 4: 60 s at 0.1x = 600 s
check "item ETA / elapsed, job ETA / elapsed" \
    "hasre \"\$B9\" '  ETA:       00:05:00    Elapsed: 00:0[5-9]:[0-5][0-9]' && hasre \"\$B9\" '  ETA:       00:15:00    Elapsed: 00:2[5-9]:[0-5][0-9]'"

echo "== finished job (session waiting)"
B4=$(job_block c4)
check "finished: status and elapsed, no CURRENT / queue" \
    "hasx \"\$B4\" 'Finished: 2 ok' && hasx \"\$B4\" '  Elapsed:   00:09:00' && ! grep -q 'CURRENT\\|JOB QUEUE' <<< \"\$B4\""

echo "== read-only"
check "nothing written to the work dir" "[[ -z \$(find '$W' -maxdepth 1 -newer '$W/c4.state' -type f) ]]"

echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ))
