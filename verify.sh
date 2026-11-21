#!/usr/bin/env bash
# Inspect / validate media files under ~/compress/in or ~/compress/out.
#
#   verify.sh [--verify | --update] [--brief] [PATH]
#
#   (no PATH)          every file of the Location chosen in the menu
#   PATH               a show folder, season folder or file under in/ or
#                      out/: relative (to out/ or in/, "in/..." / "out/...",
#                      or the current folder) or absolute. The Location
#                      follows from the path (no Location prompt); a
#                      relative path found in both in/ and out/ is refused.
#   --verify           Verify (no Mode prompt)
#   --update           Validate + update (no Mode prompt, no confirmation)
#   --brief            one line per season
#   COMPRESS_VERBOSE=1 the full detail block of every file
#
#   Verify             fast: stored MKV statistics tags (BPS,
#                      NUMBER_OF_BYTES, DURATION) when they pass the
#                      sanity checks in media_stats.sh, or stream bit
#                      rates for non-MKV. Missing / rejected statistics
#                      are replaced by a packet scan of that file.
#   Validate + update  full packet scan of every file, refreshes MKV
#                      statistics with mkvpropedit, checks the stored
#                      NUMBER_OF_BYTES tags against the scan and that a
#                      normal metadata-first read now returns the same
#                      values without scanning. Outputs (OUT) also get
#                      COMPRESSION_CRF / COMPRESSION_TIER written or
#                      corrected from the job records in work/logs
#                      (never guessed; see backfill_compression_tags).
#                      The provenance tags (COMPRESSION_TOOL /
#                      MOVIE_COMPRESSER_VERSION / COMPRESSION_DATE) are
#                      never written or changed here: only an encode
#                      records them.
#                      Track titles that are not the standard titles of
#                      the actual streams are corrected
#                      (check_track_titles; track names only).
#
# Both modes report the compression tags (compression tool, compressor
# version, compression date, tier, CRF; "Not recorded" when absent, never
# a failure: outputs of earlier versions have none), flag compression
# tags stored more than once with different values (MKVToolNix), and
# check the audio / video track titles against the actual streams
# (check_track_titles). Verify never modifies a file. The inspection
# itself is work/lib/inspect.sh (shared with results.sh).
#
# Recursive, so series folders are included. Non-MKV files are only
# inspected; mkvpropedit is never run on them.
#
# Report, per show and season (media_probe.sh series_season_groups):
#   -- SEASON: N episodes, video size, audio size
#      Common:  values every episode shares (video, dynamic range,
#               encode, resolution, audio tracks)
#      Differs: the values that differ, with the episodes of each value
#      Titles:  missing / non-standard track titles of the season
#               (Validate + update: the titles corrected)
#      Written: (Validate + update) statistics / titles / CRF tags written
#   one line per episode: label (S01E02), duration, video size, video
#   Mb/s, status (OK / UNPAIRED / CHECK REQUIRED; Validate + update: what
#   was written), the values where it differs from the rest. Titles alone
#   never make a file CHECK REQUIRED. The full detail block only for a
#   real problem (no video, missing / rejected statistics, verification
#   mismatch, unpaired output) or for every file with COMPRESS_VERBOSE=1;
#   encodes kept as "<output>.verify-failed" / ".finalize-failed" are
#   listed as CHECK REQUIRED. Summary lines are at most 120 columns.
set -u

BASE="$HOME/compress"
IN="$BASE/in"
OUT="$BASE/out"
LIB="$BASE/work/lib"
WIDTH=120

usage() {
    sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "verify.sh: $*" >&2
    exit 1
}

MODE_ARG=""
BRIEF=0
PATH_ARG=""
NPATH=0
while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --verify|--update)
            [[ -z "$MODE_ARG" || "$MODE_ARG" == "$1" ]] || die "use either --verify or --update"
            MODE_ARG="$1"
            ;;
        --brief) BRIEF=1 ;;
        --) shift; break ;;
        -?*) die "unknown option: $1 (see --help)" ;;
        *) PATH_ARG="$1"; ((NPATH += 1)) ;;
    esac
    shift
done
while (( $# )); do PATH_ARG="$1"; ((NPATH += 1)); shift; done
(( NPATH <= 1 )) || die "one PATH at most"
(( NPATH == 0 )) || [[ -n "$PATH_ARG" ]] || die "empty path"

# shared inspection (inspect_file, check_track_titles, show_source,
# update_and_check, backfill_compression_tags, grouping): work/lib/inspect.sh
source "$LIB/inspect.sh"

command -v ffprobe >/dev/null || {
    echo "ffprobe not found"
    exit 1
}

# ------------------------------------------------------------
# Scope from a path: ROOT (IN / OUT) and TARGET (file or folder)
# ------------------------------------------------------------

# _inside ROOT PATH  ->  ROOT/... for PATH inside ROOT (by its name with
# ".." resolved, or by the real path: in/ / out/ may be symlinks)
_inside() {
    local root="$1" p="$2" rl pl
    rl=$(realpath -s -m -- "$root"); pl=$(realpath -s -m -- "$p")
    if [[ "$pl" == "$rl" || "$pl" == "$rl"/* ]]; then
        printf '%s' "$root${pl#"$rl"}"
        return 0
    fi
    rl=$(realpath -m -- "$root"); pl=$(realpath -m -- "$p")
    if [[ "$pl" == "$rl" || "$pl" == "$rl"/* ]]; then
        printf '%s' "$root${pl#"$rl"}"
        return 0
    fi
    return 1
}

# resolve_scope ARG  ->  ROOT, TARGET; dies with a clear message
resolve_scope() {
    local arg="$1" p m r outside=0
    local -a cand=()
    local -A hit=()

    if [[ "$arg" == /* ]]; then
        cand=("$arg")
    else
        case "$arg" in
            in|in/*|out|out/*) cand=("$BASE/$arg") ;;
        esac
        cand+=("$OUT/$arg" "$IN/$arg" "$PWD/$arg")
    fi
    for p in "${cand[@]}"; do
        [[ -e "$p" || -L "$p" ]] || continue
        if m=$(_inside "$OUT" "$p"); then
            hit["$OUT"$'\t'"$m"]=1
        elif m=$(_inside "$IN" "$p"); then
            hit["$IN"$'\t'"$m"]=1
        else
            outside=1
        fi
    done
    if (( ${#hit[@]} == 0 )); then
        (( outside )) && die "$arg: not inside $IN or $OUT"
        die "$arg: not found (relative paths are taken from out/, in/ or the current folder)"
    fi
    if (( ${#hit[@]} > 1 )); then
        die "$arg: found in both in/ and out/; give in/$arg or out/$arg"
    fi
    for r in "${!hit[@]}"; do
        ROOT="${r%%$'\t'*}"
        TARGET="${r#*$'\t'}"
    done
    if [[ -f "$TARGET" ]]; then
        local e ok=0
        for e in "${MEDIA_EXTS[@]}"; do [[ "${TARGET,,}" == *."$e" ]] && ok=1; done
        (( ok )) || die "$arg: not a media file (${MEDIA_EXTS[*]})"
    elif [[ ! -d "$TARGET" ]]; then
        die "$arg: not a file or folder"
    fi
}

ROOT=""
TARGET=""
[[ -n "$PATH_ARG" ]] && resolve_scope "$PATH_ARG"

# ------------------------------------------------------------
# Menu (Location only without PATH, Mode only without --verify / --update)
# ------------------------------------------------------------

if [[ -z "$ROOT" ]]; then
    echo
    echo "Location:"
    echo "1) IN"
    echo "2) OUT"

    while true; do
        read -rp "Select [1-2]: " c || exit 0
        case "$c" in
            1) ROOT="$IN";  break ;;
            2) ROOT="$OUT"; break ;;
            *) echo "Invalid selection." ;;
        esac
    done
fi

case "$MODE_ARG" in
    --verify) VALIDATE=0 ;;
    --update) VALIDATE=1 ;;
    *)
        echo
        echo "Mode:"
        echo "1) Verify"
        echo "2) Validate + update"

        while true; do
            read -rp "Select [1-2]: " c || exit 0
            case "$c" in
                1) VALIDATE=0; break ;;
                2) VALIDATE=1; break ;;
                *) echo "Invalid selection." ;;
            esac
        done

        if (( VALIDATE == 1 )) && [[ "$ROOT" == "$IN" ]]; then
            echo
            echo "Validate + update rewrites the statistics tags and corrects the track"
            echo "titles of source MKV files in IN (metadata only; audio/video data is"
            echo "not touched)."
            read -rp "Continue? [y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] || exit 0
        fi
        ;;
esac

LOC=$(basename "$ROOT")
if [[ -n "$TARGET" ]]; then
    rel="${TARGET#"$ROOT"}"
    SCOPE_LABEL="$LOC${rel:-/}"
else
    SCOPE_LABEL="all of $LOC/"
fi
echo
echo "$( (( VALIDATE == 1 )) && echo "Validate + update" || echo "Verify"): $SCOPE_LABEL"
(( VALIDATE == 1 )) && echo "Full packet scan of every file. This can take a while."

# ------------------------------------------------------------
# Files, grouped by show and season (inspect_group_files)
# ------------------------------------------------------------

if [[ -f "$TARGET" ]]; then
    FILES=("$TARGET")
    KEPT_DIRS=()
else
    mapfile -d '' -t FILES < <(media_files_recursive "${TARGET:-$ROOT}")
    KEPT_DIRS=("${TARGET:-$ROOT}")
fi

# encodes kept after a failed output verification / rename
# (job_runtime.sh item_keep_completed)
KEPT=()
if (( ${#KEPT_DIRS[@]} )); then
    mapfile -d '' -t KEPT < <(
        find -H "${KEPT_DIRS[@]}" -type f \
            \( -name '*.verify-failed' -o -name '*.verify-failed.[0-9]*' \
               -o -name '*.finalize-failed' -o -name '*.finalize-failed.[0-9]*' \) -print0 2>/dev/null |
            sort -z)
fi

[[ "$ROOT" == "$OUT" ]] && build_source_index "$IN"
inspect_group_files "$ROOT" "${FILES[@]+"${FILES[@]}"}"

declare -A G_KEPT=()
for f in "${KEPT[@]+"${KEPT[@]}"}"; do
    rel="${f#"$ROOT"/}"
    if [[ "$rel" == */* ]]; then
        show="${rel%%/*}"
        key="$show"$'\t'"$(series_group_name "$ROOT/$show" "$(dirname -- "$f")")"
    else
        show=""
        key=$'\t'
    fi
    if [[ -z "${SHOW_SEEN["k$show"]+x}" ]]; then
        SHOW_SEEN["k$show"]=1
        SHOW_ORDER+=("$show")
    fi
    [[ -n "${GROUP_FILES[$key]+x}" ]] || GROUP_FILES[$key]=""
    G_KEPT[$key]+="$f"$'\n'
done

if (( ${#FILES[@]} + ${#KEPT[@]} == 0 )); then
    echo
    echo "No media files found."
    exit 0
fi

# ------------------------------------------------------------
# Formatting helpers
# ------------------------------------------------------------

# clip TEXT  ->  TEXT cut to WIDTH columns ("~" marks the cut)
clip() {
    local s="$1"
    (( ${#s} > WIDTH )) && s="${s:0:$((WIDTH - 1))}~"
    printf '%s\n' "$s"
}

# fit_name PREFIX NAME REST  ->  PREFIX NAME REST in WIDTH columns: the
# NAME is shortened ("~") so the REST (counts, sizes) stays whole
fit_name() {
    local prefix="$1" name="$2" rest="$3" room
    room=$(( WIDTH - ${#prefix} - ${#rest} ))
    (( room < 10 )) && room=10
    (( ${#name} > room )) && name="${name:0:$((room - 1))}~"
    clip "$prefix$name$rest"
}

# wrap SEP PREFIX PIECE...  ->  the pieces joined by SEP on lines of at
# most WIDTH columns, continuation lines indented to the end of PREFIX
wrap() {
    local sep="$1" prefix="$2" line="" pad p
    shift 2
    printf -v pad '%*s' "${#prefix}" ''
    line="$prefix"
    local first=1
    for p in "$@"; do
        if (( first )); then
            line+="$p"
            first=0
        elif (( ${#line} + ${#sep} + ${#p} <= WIDTH )); then
            line+="$sep$p"
        else
            clip "$line${sep% }"
            line="$pad$p"
        fi
    done
    clip "$line"
}

# ep_label FILE  ->  "S01E02" from the name, else the name (shortened)
ep_label() {
    local n
    n=$(basename -- "$1")
    if [[ "$n" =~ [Ss]([0-9]{1,3})[\ ._-]?[Ee]([0-9]{1,4}) ]]; then
        printf 'S%02dE%02d' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
        return
    fi
    n=$(output_source_stem "$n")
    (( ${#n} > 40 )) && n="${n:0:39}~"
    printf '%s' "$n"
}

# compress_labels LABEL...  ->  "E01-E07, E09" for episodes of one season,
# else the labels joined by ", "
compress_labels() {
    local l s="" ok=1 lo="" prev="" out=""
    local -a nums=()
    for l in "$@"; do
        if [[ "$l" =~ ^S([0-9]+)E([0-9]+)$ ]] && [[ -z "$s" || "$s" == "${BASH_REMATCH[1]}" ]]; then
            s="${BASH_REMATCH[1]}"
            nums+=("$((10#${BASH_REMATCH[2]}))")
        else
            ok=0
        fi
    done
    if (( ! ok )); then
        local IFS=,
        out="$*"
        printf '%s' "${out//,/, }"
        return
    fi
    local n
    while IFS= read -r n; do
        if [[ -z "$lo" ]]; then
            lo="$n"
        elif (( n != prev + 1 )); then
            out+="${out:+, }$(_erange "$lo" "$prev")"
            lo="$n"
        fi
        prev="$n"
    done < <(printf '%s\n' "${nums[@]}" | sort -n -u)
    out+="${out:+, }$(_erange "$lo" "$prev")"
    printf '%s' "$out"
}
_erange() {
    if (( $1 == $2 )); then printf 'E%02d' "$1"; else printf 'E%02d-E%02d' "$1" "$2"; fi
}

# enc_text RC CODEC_DESC  ->  "x265 CRF 21", "x265 two-pass 1500 kb/s", ...
enc_text() {
    local c
    case "$1" in
        "crf "*)   c="${1#crf }"; printf 'x265 CRF %s' "${c%.0}" ;;
        "2pass "*) printf 'x265 two-pass %s kb/s' "${1#2pass }" ;;
        "abr "*)   printf 'x265 one-pass %s kb/s' "${1#abr }" ;;
        "")        [[ "$2" == hevc* ]] && printf 'HEVC (no x265 settings)' || printf '%s' "${2%% *}" ;;
        *)         printf 'x265 %s' "$1" ;;
    esac
}

gib() { [[ "${1:-}" =~ ^[0-9]+$ ]] && awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }' || printf -- '-'; }

# ------------------------------------------------------------
# Inspection of one group (all its files first: Common / Differs need
# every episode)
# ------------------------------------------------------------

DTMP=$(mktemp -d)
trap 'rm -rf -- "$DTMP"' EXIT
ATTRS=(video range encode resolution audio)
declare -A ATTR_NAME=([video]=video [range]="dynamic range" [encode]=encode [resolution]=resolution [audio]=audio)

NF=0                       # files inspected (index of E_*)
declare -A E_FILE=() E_LABEL=() E_DUR=() E_VB=() E_AB=() E_APPROX=() E_ST=() E_WROTE=()
declare -A E_TITLES=() E_TWRITTEN=() E_STATS=() E_TAGS=() E_UNREC=() E_A=() E_NOVIDEO=()
# totals
T_SEASONS=0 T_FILES=0 T_CHECK=0 T_UNPAIRED=0 T_TITLES=0 T_TFIXED=0 T_TCOUNT=0
T_STATS=0 T_TAGS=0 T_UNREC=0 T_SHOWS=0

inspect_group() {   # FILE...  ->  G_IDX (indexes of E_*)
    local f b_cr b_ns b_fi st a w
    G_IDX=()
    for f in "$@"; do
        [[ -n "$f" ]] || continue
        ((NF += 1))
        ui_progress "$(clip "Checking $(basename "$f")...")"
        b_cr=$CHECK_REQUIRED b_ns=$NO_SOURCE b_fi=$FILE_ISSUES
        inspect_file "$f" "$ROOT" "$VALIDATE" > "$DTMP/$NF" 2>&1
        if (( CHECK_REQUIRED > b_cr || FILE_ISSUES > b_fi )); then
            st="CHECK REQUIRED"
        elif (( NO_SOURCE > b_ns )); then
            st="UNPAIRED"
        else
            st="OK"
        fi
        w=""
        (( FILE_STATS_REFRESHED == 1 )) && w+="${w:+, }stats"
        (( FILE_TITLES_WRITTEN > 0 )) && w+="${w:+, }$(ui_plural "$FILE_TITLES_WRITTEN" title)"
        (( FILE_TAGS_WRITTEN == 1 )) && w+="${w:+, }CRF tags"
        E_FILE[$NF]="$f"
        E_LABEL[$NF]=$(ep_label "$f")
        E_DUR[$NF]="$FILE_DUR"
        E_VB[$NF]="$FILE_VBYTES"
        E_AB[$NF]="$FILE_ABYTES"
        E_APPROX[$NF]="$FILE_APPROX"
        E_ST[$NF]="$st"
        E_WROTE[$NF]="$w"
        E_NOVIDEO[$NF]="$FILE_NO_VIDEO"
        E_TITLES[$NF]="$FILE_TITLE_KINDS"
        E_TWRITTEN[$NF]="$FILE_TITLES_WRITTEN"
        E_STATS[$NF]="$FILE_STATS_REFRESHED"
        E_TAGS[$NF]="$FILE_TAGS_WRITTEN"
        E_UNREC[$NF]="$FILE_TAGS_UNRECOVERED"
        E_A[$NF,video]="${FILE_VDESC:--}"
        E_A[$NF,range]="${FILE_HDR:--}"
        E_A[$NF,encode]="$(enc_text "$FILE_RC" "$FILE_VDESC")"
        E_A[$NF,resolution]="${FILE_RES:--}"
        E_A[$NF,audio]="${FILE_AUDIO:-none}"
        G_IDX+=("$NF")
    done
    ui_progress ""
}

# group_values ATTR IDX...  ->  "VALUE<TAB>COUNT<TAB>LABEL,LABEL" lines, most
# frequent first (files without video are left out)
group_values() {
    local attr="$1" i v
    shift
    local -A cnt=() labs=() first=()
    local -a order=()
    for i in "$@"; do
        (( E_NOVIDEO[$i] == 1 )) && continue
        v="${E_A[$i,$attr]}"
        if [[ -z "${cnt[$v]+x}" ]]; then
            cnt[$v]=0
            labs[$v]=""
            order+=("$v")
        fi
        cnt[$v]=$(( ${cnt[$v]} + 1 ))
        labs[$v]+="${E_LABEL[$i]}"$'\x1f'
    done
    local n=0
    for v in "${order[@]+"${order[@]}"}"; do
        ((n += 1))
        printf '%s\t%s\t%s\t%s\n' "${cnt[$v]}" "$n" "$v" "${labs[$v]}"
    done | sort -t $'\t' -k1,1nr -k2,2n | cut -f1,3,4
}

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

print_group() {   # SHOW SEASON
    local show="$1" season="$2" key="$1"$'\t'"$2"
    local -a files=() idx=() kept=()
    local i a line v c l word n_ok=0 n_un=0 n_cr=0 t_files=0 vb=0 ab=0 approx="" f
    local -a common=() dkeys=()
    local -A dparts=()
    local -A major=()

    mapfile -t files < <(grep -v '^$' <<< "${GROUP_FILES[$key]}")
    mapfile -t kept < <(grep -v '^$' <<< "${G_KEPT[$key]:-}")
    inspect_group "${files[@]+"${files[@]}"}"
    idx=("${G_IDX[@]+"${G_IDX[@]}"}")

    # Common / Differs
    for a in "${ATTRS[@]}"; do
        mapfile -t vals < <(group_values "$a" "${idx[@]+"${idx[@]}"}")
        (( ${#vals[@]} )) || continue
        IFS=$'\t' read -r c v l <<< "${vals[0]}"
        major[$a]="$v"
        if (( ${#vals[@]} == 1 )); then
            case "$a" in
                video|audio) common+=("$a $v") ;;
                *)           common+=("$v") ;;
            esac
        else
            local pfx="${ATTR_NAME[$a]} "
            for line in "${vals[@]}"; do
                IFS=$'\t' read -r c v l <<< "$line"
                IFS=$'\x1f' read -ra ls <<< "$l"
                dparts[$a]+="$pfx$v ($(compress_labels "${ls[@]}"))"$'\x1f'
                pfx=""
            done
            dkeys+=("$a")
        fi
    done

    # counts and sizes
    for i in "${idx[@]+"${idx[@]}"}"; do
        case "${E_ST[$i]}" in
            OK) ((n_ok += 1)) ;;
            UNPAIRED) ((n_un += 1)) ;;
            *) ((n_cr += 1)) ;;
        esac
        [[ "${E_VB[$i]}" =~ ^[0-9]+$ ]] && vb=$(( vb + E_VB[$i] ))
        [[ "${E_AB[$i]}" =~ ^[0-9]+$ ]] && ab=$(( ab + E_AB[$i] ))
        [[ -n "${E_APPROX[$i]}" ]] && approx="~"
    done
    n_cr=$(( n_cr + ${#kept[@]} ))

    # titles
    local -A tk=()
    local t_fix=0 t_written=0 t_wfiles=0 s_stats=0 s_tags=0 s_unrec=0 k
    for i in "${idx[@]+"${idx[@]}"}"; do
        if (( E_TWRITTEN[$i] > 0 )); then
            ((t_wfiles += 1))
            t_written=$(( t_written + E_TWRITTEN[$i] ))
        elif [[ -n "${E_TITLES[$i]}" ]]; then
            ((t_fix += 1))
            while IFS= read -r k; do
                [[ -n "$k" ]] && tk[$k]=$(( ${tk[$k]:-0} + 1 ))
            done < <(sort -u <<< "${E_TITLES[$i]}")
        fi
        (( E_STATS[$i] == 1 )) && ((s_stats += 1))
        (( E_TAGS[$i] == 1 )) && ((s_tags += 1))
        (( E_UNREC[$i] == 1 )) && ((s_unrec += 1))
    done

    local n=${#idx[@]}
    word=episode
    [[ -z "$show" ]] && word=file
    [[ -n "$show" ]] && ((T_SEASONS += 1))
    T_FILES=$(( T_FILES + n ))
    T_CHECK=$(( T_CHECK + n_cr ))
    T_UNPAIRED=$(( T_UNPAIRED + n_un ))
    T_TITLES=$(( T_TITLES + t_fix ))
    T_TFIXED=$(( T_TFIXED + t_wfiles ))
    T_TCOUNT=$(( T_TCOUNT + t_written ))
    T_STATS=$(( T_STATS + s_stats ))
    T_TAGS=$(( T_TAGS + s_tags ))
    T_UNREC=$(( T_UNREC + s_unrec ))

    local tline="" st_counts=""
    if (( ${#tk[@]} )); then
        local tparts=()
        while IFS=$'\t' read -r c k; do
            tparts+=("$k ($c)")
        done < <(for k in "${!tk[@]}"; do printf '%s\t%s\n' "${tk[$k]}" "$k"; done | sort -t $'\t' -k1,1nr -k2,2)
        tline="to correct on $t_fix of $n $word$( ((n == 1)) || echo s): $(IFS='|'; printf '%s' "${tparts[*]}" | sed 's/|/, /g')"
    fi
    if (( t_wfiles > 0 )); then
        tline="corrected on $t_wfiles of $n $word$( ((n == 1)) || echo s) ($(ui_plural "$t_written" title))${tline:+; still $tline}"
    fi

    local wline=""
    if (( VALIDATE == 1 )); then
        wline="statistics $s_stats of $n"
        (( t_wfiles > 0 )) && wline+=", titles $t_wfiles"
        [[ "$ROOT" == "$OUT" ]] && wline+=", CRF tags $s_tags${s_unrec:+$( ((s_unrec > 0)) && echo " (not recovered: $s_unrec)")}"
    fi

    local label="$season"
    [[ -z "$show" ]] && label="(files in $LOC/)"

    if (( BRIEF == 1 )); then
        st_counts="$n_ok OK"
        (( n_un > 0 )) && st_counts+=", $n_un UNPAIRED"
        (( n_cr > 0 )) && st_counts+=", $n_cr CHECK REQUIRED"
        local bl=": $(ui_plural "$n" "$( [[ -n "$show" ]] && echo ep || echo file)"), video $approx$(gib "$vb"), $st_counts"
        (( t_fix > 0 )) && bl+=", titles $t_fix"
        (( VALIDATE == 1 )) && bl+=", wrote: stats $s_stats, titles $t_wfiles, tags $s_tags"
        if (( ${#dkeys[@]} )); then
            local dn=()
            for a in "${dkeys[@]}"; do dn+=("${ATTR_NAME[$a]}"); done
            bl+=", differs: $(IFS=,; printf '%s' "${dn[*]}" | sed 's/,/, /g')"
        fi
        fit_name "  " "${show:+$show / }$label" "$bl"
        return
    fi

    echo
    if [[ -n "$show" ]]; then
        fit_name "-- " "$label" ": $(ui_plural "$n" "$word"), video $approx$(gib "$vb"), audio $approx$(gib "$ab")"
    else
        clip "-- $(ui_plural "$n" "$word"), video $approx$(gib "$vb"), audio $approx$(gib "$ab")"
    fi
    (( ${#common[@]} )) && wrap "; " "   Common:  " "${common[@]}"
    local dpre="   Differs: "
    for a in "${dkeys[@]+"${dkeys[@]}"}"; do
        IFS=$'\x1f' read -ra ls <<< "${dparts[$a]}"
        wrap ", " "$dpre" "${ls[@]}"
        dpre="            "
    done
    [[ -n "$tline" ]] && wrap "; " "   Titles:  " "$tline"
    [[ -n "$wline" ]] && wrap "; " "   Written: " "$wline"

    # one line per episode
    local lw=6 dur mb note st
    for i in "${idx[@]+"${idx[@]}"}"; do (( ${#E_LABEL[$i]} > lw )) && lw=${#E_LABEL[$i]}; done
    for i in "${idx[@]+"${idx[@]}"}"; do
        if [[ "${E_DUR[$i]}" =~ ^[0-9.]+$ ]]; then dur=$(format_hms "${E_DUR[$i]}"); else dur="-"; fi
        if [[ "${E_VB[$i]}" =~ ^[0-9]+$ && "${E_DUR[$i]}" =~ ^[0-9.]+$ ]]; then
            mb="$(bytes_to_mbps "${E_VB[$i]}" "${E_DUR[$i]}") Mb/s"
        else
            mb="-"
        fi
        note=""
        if (( E_NOVIDEO[$i] == 1 )); then
            note="no video stream"
        else
            for a in "${ATTRS[@]}"; do
                [[ -n "${major[$a]+x}" && "${E_A[$i,$a]}" != "${major[$a]}" ]] &&
                    note+="${note:+; }${ATTR_NAME[$a]} ${E_A[$i,$a]}"
            done
        fi
        st="${E_ST[$i]}"
        [[ -n "${E_WROTE[$i]}" ]] && st+=" (wrote: ${E_WROTE[$i]})"
        line=$(printf '  %-*s  %8s  %11s  %11s  %s' "$lw" "${E_LABEL[$i]}" "$dur" \
            "${E_APPROX[$i]}$(gib "${E_VB[$i]}")" "$mb" "$st")
        line=$(clip "$line${note:+  $note}")
        # colour only the status (after clipping: escapes take no columns)
        case "${E_ST[$i]}" in
            OK)       line="${line/  OK/  $(ui_ok OK)}" ;;
            UNPAIRED) line="${line/  UNPAIRED/  $(ui_warn UNPAIRED)}" ;;
            *)        line="${line/  CHECK REQUIRED/  $(ui_err "CHECK REQUIRED")}" ;;
        esac
        printf '%s\n' "$line"
        if [[ "${E_ST[$i]}" != OK ]] || ui_verbose; then
            sed -e '1{/^[[:space:]]*$/d}' -e 's/^./    &/' "$DTMP/$i"
        fi
    done
    for f in "${kept[@]+"${kept[@]}"}"; do
        line=$(clip "  $(basename "$f")  $(ui_err "CHECK REQUIRED")  encode kept after a failed verification / rename")
        printf '%s\n' "$line"
    done
}

for show in "${SHOW_ORDER[@]+"${SHOW_ORDER[@]}"}"; do
    if [[ -n "$show" ]]; then
        ((T_SHOWS += 1))
        (( BRIEF == 1 )) || { echo; clip "== $(ui_bold "$show")"; }
        while IFS= read -r season; do
            print_group "$show" "$season"
        done < <(show_seasons "$show")
    else
        (( BRIEF == 1 )) || { echo; clip "== $(ui_bold "(files in $LOC/)")"; }
        print_group "" ""
    fi
done

# ------------------------------------------------------------
# Totals
# ------------------------------------------------------------

echo
problems=$(( T_CHECK + T_UNPAIRED ))
tl="Total: $(ui_plural "$T_SHOWS" show), $(ui_plural "$T_SEASONS" season), $(ui_plural "$T_FILES" file)"
tl+="; problems: $problems"
(( problems > 0 )) && tl+=" ($T_CHECK CHECK REQUIRED, $T_UNPAIRED UNPAIRED)"
tl+="; titles to correct: $T_TITLES"
clip "$tl"
if (( VALIDATE == 1 )); then
    wl="Written: statistics $T_STATS, titles $(ui_plural "$T_TFIXED" file) ($(ui_plural "$T_TCOUNT" title))"
    [[ "$ROOT" == "$OUT" ]] && wl+=", CRF tags $T_TAGS; CRF tags not recovered: $T_UNREC"
    clip "$wl"
fi
exit 0
