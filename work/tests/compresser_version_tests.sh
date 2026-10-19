#!/usr/bin/env bash
# movie-compresser version detection (encode_common.sh compresser_version,
# compression_date_now, emit_job_header).
#
#   bash ~/compress/work/tests/compresser_version_tests.sh
#
# Throwaway Git repositories holding a copy of the library: untagged,
# tagged (lightweight: needs --tags), commits after the tag, dirty
# (tracked change; untracked files do not count), any working
# directory, a repository without commits, a copy without .git, a copy
# inside some other repository, Git missing or broken. The version is
# taken once when a job is generated. No media tools; a few seconds.
set -uo pipefail

SRC_WORK="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
PASS=0
FAIL=0

ok()    { echo "  ok    $1"; ((PASS += 1)); }
bad()   { echo "  FAIL  $1"; ((FAIL += 1)); }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1  (got \"$2\", want \"$3\")"; fi; }
match() { if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1  (got \"$2\", want /$3/)"; fi; }

if ! command -v git >/dev/null 2>&1; then
    echo "skipped: git not found"
    echo "passed: 0  failed: 0"
    exit 0
fi

# no user / global configuration involved
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME="$T/home"
mkdir -p "$HOME"
g() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false \
          -c init.defaultBranch=main -c core.autocrlf=false -c core.abbrev=7 -C "$@"; }

# mkcheckout DIR  ->  DIR/work/lib with the library (not a repository yet)
mkcheckout() {
    mkdir -p "$1/work/lib"
    cp "$SRC_WORK/lib/ui.sh" "$SRC_WORK/lib/encode_common.sh" "$1/work/lib/"
    echo "readme" > "$1/README"
}
# ver DIR [CWD [PRELUDE]]  ->  compresser_version of the library in DIR,
# run from CWD (default /), with PRELUDE evaluated first
ver() {
    (cd "${2:-/}" && bash -c "${3:-}"$'\n''source "$1/work/lib/encode_common.sh" > /dev/null; compresser_version; echo "rc=$?"' _ "$1")
}

R="$T/repo"
mkcheckout "$R"
g "$R" init -q
g "$R" add -A
g "$R" commit -qm one
H1=$(g "$R" rev-parse --short HEAD)

echo "== untagged repository"
eq    "untagged: abbreviated commit"           "$(ver "$R")" "$H1"$'\nrc=0'

echo
echo "== tagged revisions"
g "$R" tag v1.4.2
eq    "lightweight tag on HEAD"                "$(ver "$R" | head -n 1)" v1.4.2
echo two >> "$R/README"
g "$R" commit -qam two
H2=$(g "$R" rev-parse --short HEAD)
eq    "one commit after the tag"               "$(ver "$R" | head -n 1)" "v1.4.2-1-g$H2"
g "$R" tag -a v1.5.0 -m release
eq    "annotated tag"                          "$(ver "$R" | head -n 1)" v1.5.0

echo
echo "== dirty working tree"
echo "untracked" > "$R/notes.txt"
eq    "untracked file: not dirty"              "$(ver "$R" | head -n 1)" v1.5.0
echo "# local change" >> "$R/work/lib/encode_common.sh"
eq    "tracked change: -dirty kept"            "$(ver "$R" | head -n 1)" v1.5.0-dirty
eq    "index not rewritten (no lock left)"     "$(ls "$R/.git/index.lock" 2>/dev/null)" ""

echo
echo "== any working directory"
eq    "from the repository root"               "$(ver "$R" "$R" | head -n 1)" v1.5.0-dirty
eq    "from work/lib"                          "$(ver "$R" "$R/work/lib" | head -n 1)" v1.5.0-dirty
mkdir -p "$T/elsewhere"
g "$T/elsewhere" init -q
eq    "from inside another repository"         "$(ver "$R" "$T/elsewhere" | head -n 1)" v1.5.0-dirty
g "$R" checkout -q -- work/lib/encode_common.sh

echo
echo "== no usable Git metadata: unknown, never a failure"
E="$T/empty"
mkcheckout "$E"
g "$E" init -q
eq    "repository without commits"             "$(ver "$E")" $'unknown\nrc=0'
C="$T/copy"
mkcheckout "$C"
eq    "copy without .git"                      "$(ver "$C")" $'unknown\nrc=0'
O="$T/outer"
mkdir -p "$O"
g "$O" init -q
mkcheckout "$O/deploy"
g "$O" add -A
g "$O" commit -qm outer
g "$O" tag outer-9.9
eq    "copy inside another repository: not its version" "$(ver "$O/deploy")" $'unknown\nrc=0'
eq    "Git not installed"                      "$(ver "$R" / 'command() { [[ "$1 ${2:-}" == "-v git" ]] && return 1; builtin command "$@"; }')" $'unknown\nrc=0'
mkdir -p "$T/badgit"
printf '#!/usr/bin/env bash\necho "fatal: broken" >&2\nexit 128\n' > "$T/badgit/git"
chmod +x "$T/badgit/git"
eq    "Git broken"                             "$(ver "$R" / "PATH=\"$T/badgit:\$PATH\"")" $'unknown\nrc=0'
match "never prints errors"                    "$(ver "$C" 2>&1)" '^unknown'$'\n''rc=0$'

echo
echo "== the version is taken once, when the job is generated"
# emit_job_header writes it into the job as a constant
hdr() { (cd / && bash -c 'source "$1/work/lib/encode_common.sh" > /dev/null; WORK_DIR="$1/work"; emit_job_header s1 movie 1' _ "$1"); }
hdr "$R" > "$T/job1.sh"
eq    "job header records the version"         "$(grep '^JOB_COMPRESSER_VERSION=' "$T/job1.sh")" "JOB_COMPRESSER_VERSION=v1.5.0"
echo "# change while the job runs" >> "$R/work/lib/encode_common.sh"
eq    "the generated job keeps it"             "$(grep '^JOB_COMPRESSER_VERSION=' "$T/job1.sh")" "JOB_COMPRESSER_VERSION=v1.5.0"
hdr "$R" > "$T/job2.sh"
eq    "a new job takes the new state"          "$(grep '^JOB_COMPRESSER_VERSION=' "$T/job2.sh")" "JOB_COMPRESSER_VERSION=v1.5.0-dirty"
check_order=$(grep -n -e '^JOB_COMPRESSER_VERSION=' -e '^job_init ' "$T/job1.sh" | cut -d: -f1 | tr '\n' ' ')
match "set before job_init"                    "$check_order" '^[0-9]+ [0-9]+ $'
bash -n "$T/job1.sh" && ok "job header passes bash -n" || bad "job header passes bash -n"

echo
echo "== compression date: ISO 8601, UTC"
d=$(bash -c 'source "$1/lib/encode_common.sh" > /dev/null; compression_date_now' _ "$SRC_WORK")
match "YYYY-MM-DD"                             "$d" '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
eq    "UTC whatever the local zone"            "$(TZ=UTC-14 bash -c 'source "$1/lib/encode_common.sh" > /dev/null; compression_date_now' _ "$SRC_WORK")" "$(date -u +%Y-%m-%d)"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
