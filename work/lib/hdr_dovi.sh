#!/usr/bin/env bash
# Dolby Vision / HDR10+ preservation and the post-encode metadata
# report. Sourced, not executed. Needs media_probe.sh and
# encode_common.sh; the item_* step functions also need job_runtime.sh.
#
# Dolby Vision (single-layer output, robust path):
#   1. RPU extracted from the source with dovi_tool (profile 7 -> 8.1
#      with mode 2); L5 active-area offsets rescaled when the video is
#      downscaled
#   2. x265 encodes the base layer exactly like a non-DV encode (two
#      pass), pass 2 writes raw HEVC; ffmpeg's own RPU writing is off
#   3. dovi_tool inject-rpu puts the RPU back (frame counts must match)
#   4. mkvmerge wraps the HEVC with the source frame timestamps and
#      writes the DV configuration record; ffmpeg then muxes it with all
#      other streams like the normal path
#   5. the output is verified (configuration record, RPU in every frame,
#      HDR10 fallback signalling) before it gets its final name
#
# HDR10+: metadata extracted with hdr10plus_tool and handed to x265
# (dhdr10-info). ffmpeg does not pass HDR10+ through on its own.
#
# Optional tools are looked up in $WORK_DIR/bin first, then in PATH, so
# static dovi_tool / hdr10plus_tool binaries can simply be dropped into
# ~/compress/work/bin (no sudo needed).

# ------------------------------------------------------------
# Capability detection
# ------------------------------------------------------------

hdr_find_tool() {
    local dir="${WORK_DIR:-$HOME/compress/work}/bin"

    if [[ -x "$dir/$1" ]]; then
        printf '%s\n' "$dir/$1"
        return 0
    fi

    command -v "$1" 2>/dev/null || true
}

HDR_TOOLS_DETECTED=0

# Sets:
#   DOVI_TOOL DOVI_TOOL_VERSION  path / version, "" if missing
#   DOVI_TOOL_OK      1 when dovi_tool is new enough (export level5)
#   HDR10PLUS_TOOL    path or ""
#   MKVMERGE          path or ""
#   FFMPEG_DOVI_BSF   1 if ffmpeg has the dovi_rpu bitstream filter
#   FFMPEG_X265_DV    1 if ffmpeg's libx265 wrapper has -dolbyvision
hdr_tools_detect() {
    (( HDR_TOOLS_DETECTED == 1 )) && return 0

    DOVI_TOOL=$(hdr_find_tool dovi_tool)
    DOVI_TOOL_VERSION=""
    DOVI_TOOL_OK=0

    if [[ -n "$DOVI_TOOL" ]]; then
        DOVI_TOOL_VERSION=$("$DOVI_TOOL" --version 2>/dev/null | awk '{ print $2; exit }')

        if "$DOVI_TOOL" export --help 2>/dev/null | grep -q 'level5'; then
            DOVI_TOOL_OK=1
        fi
    fi

    HDR10PLUS_TOOL=$(hdr_find_tool hdr10plus_tool)
    MKVMERGE=$(hdr_find_tool mkvmerge)

    FFMPEG_DOVI_BSF=0
    if ffmpeg -hide_banner -bsfs 2>/dev/null | grep -qx 'dovi_rpu'; then
        FFMPEG_DOVI_BSF=1
    fi

    FFMPEG_X265_DV=0
    if libx265_has_option dolbyvision; then
        FFMPEG_X265_DV=1
    fi

    X265_HDR10PLUS=""
    HDR_TOOLS_DETECTED=1
}

# x265_hdr10plus_supported  ->  0 when libx265 accepts dhdr10-info
# (x265 must be built with HDR10+ support). One tiny test encode,
# cached.
x265_hdr10plus_supported() {
    local tmp

    if [[ -z "${X265_HDR10PLUS:-}" ]]; then
        X265_HDR10PLUS=0
        tmp=$(mktemp -d 2>/dev/null) || return 1

        cat > "$tmp/t.json" <<'EOF'
{"JSONInfo":{"HDR10plusProfile":"B","Version":"1.0"},"SceneInfo":[{"BezierCurveData":{"Anchors":[100,200,300,400,500,600,700,800,900],"KneePointX":10,"KneePointY":20},"LuminanceParameters":{"AverageRGB":1000,"LuminanceDistributions":{"DistributionIndex":[1,5,10,25,50,75,90,95,99],"DistributionValues":[10,20,30,40,50,60,70,80,90]},"MaxScl":[5000,6000,7000]},"NumberOfWindows":1,"TargetedSystemDisplayMaximumLuminance":400,"SceneFrameIndex":0,"SceneId":0,"SequenceFrameIndex":0}],"SceneInfoSummary":{"SceneFirstFrameIndex":[0],"SceneFrameNumbers":[1]},"ToolInfo":{"Tool":"compress","Version":"1"}}
EOF

        if ffmpeg -v error -nostdin -f lavfi -i 'color=black:s=64x64:r=24' \
                -frames:v 1 -pix_fmt yuv420p10le -c:v libx265 \
                -x265-params "log-level=error:dhdr10-info=$tmp/t.json" \
                -f hevc "$tmp/t.hevc" >/dev/null 2>&1 &&
           ffprobe -v error -show_frames "$tmp/t.hevc" 2>/dev/null |
                grep -q '2094-40'; then
            X265_HDR10PLUS=1
        fi

        rm -rf -- "$tmp"
    fi

    (( X265_HDR10PLUS == 1 ))
}

hdr_tools_report() {
    hdr_tools_detect

    echo "HDR tools:"
    printf '  dovi_tool:       %s\n' "$(
        if [[ -z "$DOVI_TOOL" ]]; then echo "not found (looked in ${WORK_DIR:-~/compress/work}/bin and PATH)"
        elif (( DOVI_TOOL_OK == 0 )); then echo "$DOVI_TOOL_VERSION at $DOVI_TOOL - too old (need >= 2.1: export level5)"
        else echo "$DOVI_TOOL_VERSION ($DOVI_TOOL)"; fi)"
    printf '  mkvmerge:        %s\n' "${MKVMERGE:-not found (mkvtoolnix)}"
    printf '  hdr10plus_tool:  %s\n' "${HDR10PLUS_TOOL:-not found}"
    printf '  ffmpeg:          libx265 -dolbyvision %s, dovi_rpu bsf %s\n' \
        "$( (( FFMPEG_X265_DV == 1 )) && echo yes || echo no)" \
        "$( (( FFMPEG_DOVI_BSF == 1 )) && echo yes || echo no)"
    echo "                   (not used to write DV: RPUs are re-injected by dovi_tool"
    echo "                   and the result is verified; libx265 RPU output is disabled)"
}

# ------------------------------------------------------------
# Policy (menus; after probe_hdr)
# ------------------------------------------------------------

# dv_plan_source  (after probe_hdr, with HDR_DV == 1)
#
# Sets:
#   DV_SUPPORTED  1 when the RPU can be carried into a single-layer
#                 HEVC encode
#   DV_MODE       dovi_tool mode ("" = untouched, 2 = profile 7 -> 8.1)
#   DV_OUT        output profile label, e.g. 8.1
#   DV_BASE_OK    1 when the base layer is valid on its own (HDR10, SDR,
#                 HLG): dropping DV then still gives correct colours
#   DV_WHY        why DV cannot be carried (when DV_SUPPORTED == 0)
dv_plan_source() {
    DV_SUPPORTED=0
    DV_MODE=""
    DV_OUT=""
    DV_BASE_OK=0
    DV_WHY=""

    case "${HDR_DV_COMPAT:-}" in
        1|2|4|6) DV_BASE_OK=1 ;;
    esac

    case "${HDR_DV_PROFILE:-}" in
        8)
            case "${HDR_DV_COMPAT:-}" in
                1|2|4)
                    DV_SUPPORTED=1
                    DV_OUT="8.$HDR_DV_COMPAT"
                    ;;
                *)
                    DV_WHY="profile 8 with base-layer compatibility id '${HDR_DV_COMPAT:-?}' is not handled"
                    ;;
            esac
            ;;
        7)
            DV_SUPPORTED=1
            DV_MODE=2
            DV_OUT="8.1"
            ;;
        5)
            DV_BASE_OK=0
            DV_WHY="profile 5 has no backward-compatible base layer (IPTPQc2 colour space)"
            ;;
        *)
            DV_WHY="profile '${HDR_DV_PROFILE:-?}' is not handled by this workflow"
            ;;
    esac

    if (( DV_SUPPORTED == 1 )) && [[ "$HDR_CODEC" != "hevc" ]]; then
        DV_SUPPORTED=0
        DV_WHY="Dolby Vision in a ${HDR_CODEC:-unknown} stream is not handled (HEVC only)"
    fi

    # The base layer must actually carry its own signalling.
    if (( DV_BASE_OK == 1 )); then
        case "$HDR_DV_COMPAT" in
            1|6) [[ "$HDR_KIND" == "HDR10" ]] || DV_BASE_OK=0 ;;
            4)   [[ "$HDR_KIND" == "HLG" ]] || DV_BASE_OK=0 ;;
            2)   [[ "$HDR_KIND" == "SDR" ]] || DV_BASE_OK=0 ;;
        esac
    fi

    return 0
}

# confirm_dynamic_range LABEL  (after probe_hdr)
#
# Prints the dynamic range summary, decides what happens to Dolby
# Vision / HDR10+ and asks where a choice is needed. Sets:
#   DV_POLICY      none | preserve | drop
#   DV_MODE        dovi_tool conversion mode ("" or 2)
#   HDR10P_POLICY  none | preserve | drop
# Returns 1 when the source should be skipped.
confirm_dynamic_range() {
    local label="$1"
    local ans

    DV_POLICY="none"
    DV_MODE=""
    HDR10P_POLICY="none"

    echo "Dynamic range:  $(hdr_description)"

    case "$HDR_KIND" in
        HDR10)
            if [[ -n "$HDR_MASTER" || -n "$HDR_CLL" ]]; then
                echo "                HDR10 kept: PQ/BT.2020 signalling + mastering display${HDR_CLL:+ + MaxCLL/MaxFALL ($HDR_CLL)}"
            else
                echo "                HDR10 kept: PQ/BT.2020 signalling (source has no mastering metadata)"
            fi
            ;;
        HLG)
            echo "                HLG kept: BT.2020/HLG signalling"
            ;;
    esac

    (( HDR_DV == 1 || HDR_HDR10PLUS == 1 )) || return 0

    echo
    hdr_tools_report

    # -------- HDR10+
    if (( HDR_HDR10PLUS == 1 )); then
        echo

        local why=""
        if [[ -z "$HDR10PLUS_TOOL" ]]; then
            why="hdr10plus_tool not found"
        elif ! x265_hdr10plus_supported; then
            why="this libx265 build has no HDR10+ support (dhdr10-info)"
        fi

        if [[ -z "$why" ]]; then
            HDR10P_POLICY="preserve"
            echo "HDR10+:         PRESERVED (extracted with hdr10plus_tool, re-encoded by x265)"
        else
            echo "WARNING: $label contains HDR10+ dynamic metadata that cannot be preserved:"
            echo "  $why"
            echo "  The static HDR10 layer is kept; HDR10+ players fall back to static HDR10."
            read -rp "Encode without HDR10+? [y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] || return 1
            HDR10P_POLICY="drop"
        fi
    fi

    (( HDR_DV == 1 )) || return 0

    # -------- Dolby Vision
    dv_plan_source
    echo

    if (( DV_BASE_OK == 0 )); then
        echo "ERROR: $label contains Dolby Vision profile ${HDR_DV_PROFILE:-?}${HDR_DV_COMPAT:+ (compatibility id $HDR_DV_COMPAT)}."
        echo "  ${DV_WHY:-The base layer is not a valid HDR10/SDR/HLG stream on its own.}"
        echo "  Simply removing Dolby Vision would give WRONG colours on every player,"
        echo "  and no valid conversion to a supported output is implemented."
        echo "  Skipped."
        return 1
    fi

    if (( DV_SUPPORTED == 1 )) && (( DOVI_TOOL_OK == 1 )) && [[ -n "$MKVMERGE" ]]; then
        DV_POLICY="preserve"

        echo "Dolby Vision:   PRESERVED as profile $DV_OUT (RPU re-injected with dovi_tool;"
        echo "                $HDR_KIND base layer kept as fallback; verified after encoding)"

        if [[ "$HDR_DV_PROFILE" == "7" ]]; then
            echo
            echo "NOTE: profile 7 is dual-layer. The enhancement layer (FEL or MEL) is NOT"
            echo "  retained: a single-layer x265 encode can only carry the RPU, which is"
            echo "  converted to profile 8.1 (dovi_tool mode 2). For FEL sources the extra"
            echo "  detail of the enhancement layer is lost."
            read -rp "Continue with profile 8.1 conversion? [Y/n]: " ans
            [[ "$ans" =~ ^[Nn]$ ]] && return 1
        fi

        return 0
    fi

    echo "WARNING: Dolby Vision profile ${HDR_DV_PROFILE:-?} cannot be preserved safely:"
    if (( DV_SUPPORTED == 0 )); then
        echo "  $DV_WHY"
    else
        [[ -z "$DOVI_TOOL" ]] && echo "  dovi_tool not found (needed to extract and re-inject the RPU)"
        [[ -n "$DOVI_TOOL" ]] && (( DOVI_TOOL_OK == 0 )) && echo "  dovi_tool $DOVI_TOOL_VERSION is too old (need >= 2.1)"
        [[ -z "$MKVMERGE" ]] && echo "  mkvmerge not found (needed to write the DV configuration record)"
        echo "  Install a static dovi_tool into ${WORK_DIR:-~/compress/work}/bin to preserve it."
    fi
    echo "  The $HDR_KIND base layer is valid on its own; without Dolby Vision the"
    echo "  output is plain $HDR_KIND$( [[ "$HDR_DV_EL" == "1" || "$HDR_DV_PROFILE" == "7" ]] && echo " (the enhancement layer is dropped too)")."
    echo "1) Encode the $HDR_KIND base layer only (Dolby Vision dropped)"
    echo "2) Skip"

    while true; do
        read -rp "Select [1-2]: " ans
        case "$ans" in
            1) DV_POLICY="drop"; return 0 ;;
            2) return 1 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# hdr_policy_summary  ->  one line for the queue summary
hdr_policy_summary() {
    local s=""

    case "${DV_POLICY:-none}" in
        preserve) s="Dolby Vision preserved as profile ${DV_OUT:-8.1}" ;;
        drop)     s="Dolby Vision DROPPED (base layer only, by choice)" ;;
    esac

    case "${HDR10P_POLICY:-none}" in
        preserve) s+="${s:+; }HDR10+ preserved" ;;
        drop)     s+="${s:+; }HDR10+ DROPPED (by choice)" ;;
    esac

    printf '%s' "$s"
}

# ------------------------------------------------------------
# Generation helpers (emit_encode_item)
# ------------------------------------------------------------

# mkvmerge track options carrying the HDR10 static metadata (from the
# probe_hdr globals) into the container, shell-quoted.
dv_mkvmerge_hdr_args() {
    local a=()
    local v

    if [[ -n "$HDR_CLL" ]]; then
        a+=(--max-content-light "0:${HDR_CLL%%,*}" --max-frame-light "0:${HDR_CLL##*,}")
    fi

    if [[ -n "$HDR_MASTER" ]]; then
        # G(gx,gy)B(bx,by)R(rx,ry)WP(wx,wy)L(max,min)
        v=$(awk -v m="$HDR_MASTER" 'BEGIN {
            gsub(/[GBRWPL()]/, " ", m); gsub(/,/, " ", m)
            n = split(m, x, " ")
            if (n != 10) exit 1
            printf "%.5f,%.5f,%.5f,%.5f,%.5f,%.5f %.5f,%.5f %.4f %.4f\n",
                x[5]/50000, x[6]/50000, x[1]/50000, x[2]/50000, x[3]/50000, x[4]/50000,
                x[7]/50000, x[8]/50000, x[9]/10000, x[10]/10000
        }') || v=""

        if [[ -n "$v" ]]; then
            read -r rgb wp lmax lmin <<< "$v"
            a+=(--chromaticity-coordinates "0:$rgb"
                --white-colour-coordinates "0:$wp"
                --max-luminance "0:$lmax"
                --min-luminance "0:$lmin")
        fi
    fi

    (( ${#a[@]} )) && printf '%q ' "${a[@]}"
    return 0
}

# ------------------------------------------------------------
# Job steps (run through item_step; output goes to the item log)
# ------------------------------------------------------------

_dv_fail() {
    echo "ERROR: $1"
    printf '%s\n' "$1" > "$ITEM_TMP/reason"
    return 1
}

# item_dv_extract SOURCE VIDX MODE
#
# Writes to $ITEM_TMP:
#   source.rpu      RPU as extracted (mode applied)
#   inject.rpu      copy of it (item_dv_inject rescales L5 when needed)
#   timestamps.txt  source frame timestamps (mkvmerge v2 format)
#   rpu_frames      number of RPUs
item_dv_extract() {
    local src="$1" vidx="$2" mode="$3"
    local log="$ITEM_TMP/dovi_tool.log"
    local frames n margs=()

    hdr_tools_detect
    [[ -n "$DOVI_TOOL" ]] || { _dv_fail "dovi_tool not found"; return 1; }
    [[ -n "$mode" ]] && margs=(-m "$mode")

    echo "Extracting Dolby Vision RPU${mode:+ (dovi_tool mode $mode)}..."

    if ! ffmpeg -v error -nostdin -i "$src" -map "0:$vidx" -c:v copy \
            -bsf:v hevc_mp4toannexb -f hevc - |
         "$DOVI_TOOL" ${margs[@]+"${margs[@]}"} extract-rpu - -o "$ITEM_TMP/source.rpu" >> "$log" 2>&1; then
        _dv_fail "RPU extraction failed (see $log)"
        return 1
    fi

    "$DOVI_TOOL" info -s -i "$ITEM_TMP/source.rpu" > "$ITEM_TMP/source_rpu_summary.txt" 2>> "$log"
    cat "$ITEM_TMP/source_rpu_summary.txt"

    frames=$(awk '/Frames:/ { print $2; exit }' "$ITEM_TMP/source_rpu_summary.txt")
    [[ "$frames" =~ ^[0-9]+$ ]] && (( frames > 0 )) ||
        { _dv_fail "no RPU frames found in the source"; return 1; }
    echo "$frames" > "$ITEM_TMP/rpu_frames"

    # Frame timestamps in display order. The encoded stream has the same
    # frames (fps_mode passthrough), so they are reused 1:1 when the HEVC
    # is wrapped; this keeps A/V sync including any start offset.
    echo "Reading source frame timestamps..."
    ffprobe -v error -select_streams "$vidx" -show_entries packet=pts_time \
        -of csv=p=0 "$src" |
        awk -F, '$1 ~ /^-?[0-9.]+$/ { print $1 }' |
        sort -g > "$ITEM_TMP/pts.txt"

    n=$(wc -l < "$ITEM_TMP/pts.txt")

    if (( n != frames )); then
        _dv_fail "source has $n video frames with timestamps but $frames RPUs"
        return 1
    fi

    {
        echo "# timestamp format v2"
        awk '{ printf "%.6f\n", $1 * 1000 }' "$ITEM_TMP/pts.txt"
    } > "$ITEM_TMP/timestamps.txt"

    cp -f -- "$ITEM_TMP/source.rpu" "$ITEM_TMP/inject.rpu"
    return 0
}

# item_dv_inject SRC_W SRC_H
# ($ITEM_TMP/video.hevc + inject.rpu -> video_dv.hevc)
item_dv_inject() {
    local sw="$1" sh="$2"
    local log="$ITEM_TMP/dovi_tool.log"
    local ow oh

    hdr_tools_detect

    IFS=x read -r ow oh <<< "$(get_resolution "$ITEM_TMP/video.hevc" v:0)"

    # Downscaling: L5 active-area offsets are in pixels of the coded
    # frame, so they are scaled with the picture. Other RPU levels do
    # not depend on the resolution.
    if [[ -n "$ow" && ( "$sw" != "$ow" || "$sh" != "$oh" ) ]] &&
       grep -q 'L5 offsets' "$ITEM_TMP/source_rpu_summary.txt"; then

        echo "Rescaling L5 active-area offsets ${sw}x${sh} -> ${ow}x${oh}..."

        if ! "$DOVI_TOOL" export -i "$ITEM_TMP/source.rpu" \
                -d "level5=$ITEM_TMP/l5_source.json" >> "$log" 2>&1; then
            _dv_fail "L5 export failed (see $log)"
            return 1
        fi

        awk -v sx="$(awk -v a="$ow" -v b="$sw" 'BEGIN { printf "%.10f", a / b }')" \
            -v sy="$(awk -v a="$oh" -v b="$sh" 'BEGIN { printf "%.10f", a / b }')" '
            {
                line = $0; out = ""
                while (match(line, /"(left|right|top|bottom)"[ \t]*:[ \t]*[0-9]+/)) {
                    seg = substr(line, RSTART, RLENGTH)
                    k = seg; sub(/^"/, "", k); sub(/".*/, "", k)
                    v = seg; sub(/.*:[ \t]*/, "", v)
                    s = (k == "left" || k == "right") ? sx : sy
                    out = out substr(line, 1, RSTART - 1) "\"" k "\": " int(v * s + 0.5)
                    line = substr(line, RSTART + RLENGTH)
                }
                print out line
            }' "$ITEM_TMP/l5_source.json" > "$ITEM_TMP/l5_scaled.json"

        if ! "$DOVI_TOOL" editor -i "$ITEM_TMP/source.rpu" -j "$ITEM_TMP/l5_scaled.json" \
                -o "$ITEM_TMP/inject.rpu" >> "$log" 2>&1; then
            _dv_fail "L5 rescale (dovi_tool editor) failed (see $log)"
            return 1
        fi

        "$DOVI_TOOL" info -s -i "$ITEM_TMP/inject.rpu" 2>> "$log" | grep -E 'Frames|L5'
    fi


    echo "Injecting RPU..."

    if ! "$DOVI_TOOL" inject-rpu -i "$ITEM_TMP/video.hevc" \
            --rpu-in "$ITEM_TMP/inject.rpu" \
            -o "$ITEM_TMP/video_dv.hevc" > "$ITEM_TMP/inject.log" 2>&1; then
        cat "$ITEM_TMP/inject.log" >> "$log"
        _dv_fail "RPU injection failed (see $log)"
        return 1
    fi

    cat "$ITEM_TMP/inject.log" >> "$log"

    # dovi_tool only warns (and duplicates metadata) on a length mismatch.
    if grep -qi 'mismatch' "$ITEM_TMP/inject.log"; then
        _dv_fail "encoded frame count does not match the RPU count (see $log)"
        return 1
    fi

    rm -f -- "$ITEM_TMP/video.hevc"
}

# item_dv_wrap [MKVMERGE TRACK OPTIONS...]  (video_dv.hevc -> video_dv.mkv)
item_dv_wrap() {
    local log="$ITEM_TMP/mkvmerge.log"
    local rc

    hdr_tools_detect
    echo "Wrapping HEVC with mkvmerge (DV configuration record, source timestamps)..."

    "$MKVMERGE" -o "$ITEM_TMP/video_dv.mkv" \
        --timestamps "0:$ITEM_TMP/timestamps.txt" \
        "$@" "$ITEM_TMP/video_dv.hevc" > "$log" 2>&1
    rc=$?

    # 0 = ok, 1 = warnings, 2 = error
    if (( rc > 1 )); then
        tail -n 5 "$log"
        _dv_fail "mkvmerge failed (exit $rc, see $log)"
        return 1
    fi

    if ! ffprobe -v error -show_streams "$ITEM_TMP/video_dv.mkv" 2>/dev/null |
            grep -q '^dv_profile='; then
        _dv_fail "mkvmerge did not write a Dolby Vision configuration record"
        return 1
    fi

    rm -f -- "$ITEM_TMP/video_dv.hevc"
}

# item_hdr10plus_extract SOURCE VIDX  ->  $ITEM_TMP/hdr10plus.json
item_hdr10plus_extract() {
    local src="$1" vidx="$2"
    local log="$ITEM_TMP/hdr10plus_tool.log"

    hdr_tools_detect
    [[ -n "$HDR10PLUS_TOOL" ]] || { _dv_fail "hdr10plus_tool not found"; return 1; }

    echo "Extracting HDR10+ metadata..."

    if ! ffmpeg -v error -nostdin -i "$src" -map "0:$vidx" -c:v copy \
            -bsf:v hevc_mp4toannexb -f hevc - |
         "$HDR10PLUS_TOOL" extract - -o "$ITEM_TMP/hdr10plus.json" >> "$log" 2>&1; then
        _dv_fail "HDR10+ extraction failed (see $log)"
        return 1
    fi

    [[ -s "$ITEM_TMP/hdr10plus.json" ]] ||
        { _dv_fail "HDR10+ extraction produced no metadata"; return 1; }
}

# ------------------------------------------------------------
# Verification + preservation report
# ------------------------------------------------------------

# _hdr_save PREFIX  ->  copies the probe_hdr globals to PREFIX_*
_hdr_save() {
    local v n

    for v in CODEC PRIMARIES TRANSFER MATRIX RANGE CHROMALOC KIND MASTER CLL \
             HDR10PLUS DV DV_PROFILE DV_COMPAT DV_LEVEL DV_RPU DV_EL DV_BL; do
        n="HDR_$v"
        printf -v "${1}_$v" '%s' "${!n}"
    done
}

# Field separator of the _meta_load rows (titles may contain "|").
MS=$'\x1f'

# _cover_default CODEC  ->  "name<MS>mime" given to cover art without a
# file name (same defaults as build_stream_map)
_cover_default() {
    case "$1" in
        mjpeg) printf 'cover.jpg%simage/jpeg' "$MS" ;;
        png)   printf 'cover.png%simage/png' "$MS" ;;
        bmp)   printf 'cover.bmp%simage/bmp' "$MS" ;;
        gif)   printf 'cover.gif%simage/gif' "$MS" ;;
        webp)  printf 'cover.webp%simage/webp' "$MS" ;;
        *)     printf -- '-%s-' "$MS" ;;
    esac
}

# _meta_load FILE PREFIX MAIN_VIDX
#
# Loads stream_meta into PREFIX_A (audio rows), PREFIX_S (subtitle
# rows), PREFIX_ATT (attachments + attached pictures, "name<MS>mime"),
# PREFIX_ORDER (type sequence) and PREFIX_DROPPED (notes). Rows are
# <MS>-separated:
#   1 codec  2 profile  3 layout  4 default  5 forced  6 comment  7 hi
#   8 vi  9 language  10 title  11 channels  12 source index
#   13 original codec
# For the source (PREFIX == S), only streams the encode keeps are
# listed (mov_text already as subrip), so the lists line up with the
# output.
_meta_load() {
    local file="$1" pre="$2" vidx="$3"
    local idx type codec profile ch layout def forced comment hi vi att lang title fname handler mime srate
    local -n A="${pre}_A" Sb="${pre}_S" ORD="${pre}_ORDER" DROP="${pre}_DROPPED"
    local -n ATT="${pre}_ATT"
    local covers=() row act oc

    A=(); Sb=(); ORD=(); DROP=(); ATT=()

    while IFS=$'\t' read -r idx type codec profile ch layout def forced comment hi vi att lang title fname handler mime srate; do
        [[ -n "$idx" ]] || continue

        # mp4 track names live in handler_name (the encode copies them
        # into the title, see build_stream_map)
        if [[ "$pre" == "S" && "$title" == "-" ]] && mp4_handler_is_name "$handler"; then
            title="$handler"
        fi

        oc="$codec"
        if [[ "$pre" == "S" && "$type" == "subtitle" ]]; then
            act=$(mkv_subtitle_action "$codec")
            if [[ "$act" == "drop" ]]; then
                DROP+=("subtitle $idx ($codec): not supported in MKV")
                continue
            fi
            [[ "$act" == "srt" ]] && codec="subrip"
        fi

        row="$codec$MS$profile$MS$layout$MS$def$MS$forced$MS$comment$MS$hi$MS$vi$MS$lang$MS$title$MS$ch$MS$idx$MS$oc"

        case "$type" in
            video)
                if [[ "$idx" == "$vidx" ]]; then
                    ORD=(video "${ORD[@]+"${ORD[@]}"}")
                elif (( att == 1 )); then
                    if [[ "$fname" != "-" ]]; then
                        ATT+=("$fname$MS$mime")
                    else
                        ATT+=("$(_cover_default "$codec")")
                    fi
                    covers+=(attachment)
                else
                    ORD+=(video)
                fi
                ;;
            audio)
                A+=("$row")
                ORD+=(audio)
                ;;
            subtitle)
                Sb+=("$row")
                ORD+=(subtitle)
                ;;
            attachment)
                ATT+=("$fname$MS$mime")
                ORD+=(attachment)
                ;;
            *)
                [[ "$pre" == "S" ]] && DROP+=("$type $idx ($codec): cannot be stored in MKV")
                [[ "$pre" == "S" ]] || ORD+=("$type")
                ;;
        esac
    done < <(stream_meta "$file")

    # Cover art is re-added as an attachment after the mux.
    ORD+=("${covers[@]+"${covers[@]}"}")
}

# _field ROW N  ->  field N of a _meta_load row
_field() {
    cut -d"$MS" -f"$2" <<< "$1"
}

# _flag_seq ROWS_ARRAY_NAME FIELD  ->  "1,0,0" (FIELD: 4 default, 5 forced, ...)
_flag_seq() {
    local -n R="$1"
    local r out=()

    for r in "${R[@]+"${R[@]}"}"; do
        out+=("$(cut -d"$MS" -f"$2" <<< "$r" | tr "$MS" '/')")
    done

    local IFS=','
    printf '%s' "${out[*]-}"
}

_codec_label() {
    local codec="$1" profile="$2"

    case "$codec" in
        truehd) codec="TrueHD" ;;
        eac3)   codec="E-AC-3" ;;
        ac3)    codec="AC-3" ;;
        dts)    codec="DTS" ;;
        aac)    codec="AAC" ;;
        opus)   codec="Opus" ;;
        flac)   codec="FLAC" ;;
    esac

    [[ "$profile" != "-" && "$profile" != "unknown" && -n "$profile" ]] && codec+=" ($profile)"
    printf '%s' "$codec"
}

# _rep LABEL VALUE
_rep() {
    printf '  %-19s %s\n' "$1:" "$2"
}

# item_verify_output  (item step)
#
# Compares the source with "$ITEM_PART" and writes the preservation
# report to $ITEM_TMP/report.txt. Fails (reason in $ITEM_TMP/reason)
# when a preservation that was asked for is not in the output, or when
# the colour signalling changed unexpectedly.
item_verify_output() {
    local src="$ITEM_INPUT" out="$ITEM_PART"
    local vidx="${ITEM_EXP[vidx]:-}"
    local dv="${ITEM_EXP[dv]:-none}" h10p="${ITEM_EXP[hdr10p]:-none}"
    local video="${ITEM_EXP[video]:-encode}" scaled="${ITEM_EXP[scaled]:-0}"
    local ovidx fails=() warns=() line v s o i n

    local S_CODEC S_PRIMARIES S_TRANSFER S_MATRIX S_RANGE S_CHROMALOC S_KIND S_MASTER S_CLL
    local S_HDR10PLUS S_DV S_DV_PROFILE S_DV_COMPAT S_DV_LEVEL S_DV_RPU S_DV_EL S_DV_BL
    local O_CODEC O_PRIMARIES O_TRANSFER O_MATRIX O_RANGE O_CHROMALOC O_KIND O_MASTER O_CLL
    local O_HDR10PLUS O_DV O_DV_PROFILE O_DV_COMPAT O_DV_LEVEL O_DV_RPU O_DV_EL O_DV_BL
    local S_A=() S_S=() S_ORDER=() S_DROPPED=() S_ATT=()
    local O_A=() O_S=() O_ORDER=() O_DROPPED=() O_ATT=()

    exec 3> "$ITEM_TMP/report.txt"

    echo "Verifying output metadata..."
    echo "Metadata preservation:" >&3

    if [[ -n "$vidx" ]]; then
        ovidx=$(main_video_index "$out")
        probe_hdr "$src" "$vidx";   _hdr_save S
        probe_hdr "$out" "${ovidx:-0}"; _hdr_save O

        # ---- HDR type
        HDR_KIND="$S_KIND"; HDR_HDR10PLUS="$S_HDR10PLUS"; HDR_DV="$S_DV"
        HDR_DV_PROFILE="$S_DV_PROFILE"; HDR_DV_COMPAT="$S_DV_COMPAT"
        s=$(hdr_type_label)
        HDR_KIND="$O_KIND"; HDR_HDR10PLUS="$O_HDR10PLUS"; HDR_DV="$O_DV"
        HDR_DV_PROFILE="$O_DV_PROFILE"; HDR_DV_COMPAT="$O_DV_COMPAT"
        o=$(hdr_type_label)

        if [[ "$s" == "$o" ]]; then
            _rep "HDR type" "$o" >&3
        else
            line="$s -> $o"
            [[ "$dv" == "drop" ]] && line+="  (Dolby Vision dropped by choice)"
            [[ "$h10p" == "drop" ]] && line+="  (HDR10+ dropped by choice)"
            [[ "$dv" == "preserve" && "$S_DV_PROFILE" == "7" ]] && line+="  (profile 7 converted to 8.1)"
            _rep "HDR type" "$line" >&3
        fi

        # ---- Dolby Vision
        if (( S_DV == 1 )); then
            case "$dv" in
                preserve)
                    v=$(dv_verify_rpu "$out" "${ovidx:-0}" \
                        "${ITEM_EXP[dv_profile]:-8}" "${ITEM_EXP[dv_compat]:-}" \
                        "$(cat "$ITEM_TMP/rpu_frames" 2>/dev/null)")
                    if [[ "$v" == VERIFIED* ]]; then
                        _rep "Dolby Vision RPU" "$v" >&3
                        if [[ "$O_DV_COMPAT" == "1" ]]; then
                            if [[ "$O_KIND" == "HDR10" && "$O_PRIMARIES" == "bt2020" && "$O_MASTER" == "$S_MASTER" ]]; then
                                _rep "HDR10 fallback" "VERIFIED (PQ/BT.2020 base layer${O_MASTER:+ + mastering display}${O_CLL:+ + MaxCLL/MaxFALL})" >&3
                            else
                                _rep "HDR10 fallback" "FAILED (base layer is $O_KIND/${O_PRIMARIES:-?})" >&3
                                fails+=("HDR10 fallback not valid")
                            fi
                        fi
                    else
                        _rep "Dolby Vision RPU" "FAILED: $v" >&3
                        fails+=("Dolby Vision not verified: $v")
                    fi
                    if [[ "$S_DV_PROFILE" == "7" ]]; then
                        _rep "DV enhancement" "DROPPED (FEL/MEL video cannot be carried by a single-layer encode)" >&3
                    fi
                    ;;
                drop)
                    if (( O_DV == 1 )); then
                        _rep "Dolby Vision RPU" "UNEXPECTED: output still claims Dolby Vision" >&3
                        fails+=("output has a Dolby Vision record although DV was dropped")
                    else
                        _rep "Dolby Vision RPU" "DROPPED (base layer only, chosen before encoding)" >&3
                    fi
                    ;;
                *)
                    if [[ "$video" == "copy" ]] && (( O_DV == 1 )) && [[ "$O_DV_PROFILE" == "$S_DV_PROFILE" ]]; then
                        _rep "Dolby Vision" "COPIED (video stream copy, profile $O_DV_PROFILE)" >&3
                    else
                        _rep "Dolby Vision" "MISSING" >&3
                        fails+=("Dolby Vision lost without a policy")
                    fi
                    ;;
            esac
        fi

        # ---- HDR10+
        if (( S_HDR10PLUS == 1 )); then
            if [[ "$h10p" == "drop" ]]; then
                _rep "HDR10+" "DROPPED (chosen before encoding)" >&3
            elif (( O_HDR10PLUS == 1 )); then
                _rep "HDR10+" "VERIFIED" >&3
            else
                _rep "HDR10+" "MISSING" >&3
                fails+=("HDR10+ metadata missing in the output")
            fi
        fi

        # ---- colour signalling
        line=""
        for v in PRIMARIES TRANSFER MATRIX RANGE; do
            local -n sv="S_$v" ov="O_$v"
            if [[ -n "$sv" && "$sv" != "$ov" ]]; then
                line+="${line:+, }${v,,} $sv -> ${ov:-unset}"
            fi
            unset -n sv ov
        done

        if [[ -z "$S_PRIMARIES$S_TRANSFER$S_MATRIX$S_RANGE" ]]; then
            _rep "Colour signalling" "n/a (source untagged)" >&3
        elif [[ -z "$line" ]]; then
            _rep "Colour signalling" "MATCH (${S_PRIMARIES:-?}/${S_TRANSFER:-?}/${S_MATRIX:-?}/${S_RANGE:-?})" >&3
        else
            _rep "Colour signalling" "CHANGED: $line" >&3
            fails+=("colour signalling changed: $line")
        fi

        if [[ -n "$S_CHROMALOC" ]]; then
            if [[ "$S_CHROMALOC" == "$O_CHROMALOC" ]]; then
                _rep "Chroma location" "MATCH ($S_CHROMALOC)" >&3
            elif (( scaled == 1 )); then
                _rep "Chroma location" "$S_CHROMALOC -> ${O_CHROMALOC:-unset} (resampled by scaling)" >&3
            else
                _rep "Chroma location" "CHANGED: $S_CHROMALOC -> ${O_CHROMALOC:-unset}" >&3
                warns+=("chroma location changed")
            fi
        fi

        # ---- HDR10 static metadata
        if [[ "$S_KIND" != "SDR" || -n "$S_MASTER$S_CLL" ]]; then
            for v in MASTER CLL; do
                local -n sv="S_$v" ov="O_$v"
                local lbl="HDR10 mastering"
                [[ "$v" == "CLL" ]] && lbl="MaxCLL/MaxFALL"

                if [[ -z "$sv" ]]; then
                    _rep "$lbl" "n/a (source has none)" >&3
                elif [[ "$sv" == "$ov" ]]; then
                    _rep "$lbl" "VERIFIED" >&3
                elif [[ -z "$ov" ]]; then
                    _rep "$lbl" "MISSING" >&3
                    fails+=("$lbl missing in the output")
                else
                    _rep "$lbl" "CHANGED ($sv -> $ov)" >&3
                    fails+=("$lbl changed")
                fi
                unset -n sv ov
            done
        fi
    fi

    # ---- streams
    _meta_load "$src" S "$vidx"
    _meta_load "$out" O "$ovidx"

    local -A trans=()
    local exp_titles=() updated=0
    if [[ -n "${ITEM_EXP[atrans]+x}" ]]; then
        for v in ${ITEM_EXP[atrans]//,/ }; do trans[$v]=1; done
    fi

    line="${#S_A[@]} -> ${#O_A[@]}"
    _rep "Audio tracks" "$line" >&3
    (( ${#S_A[@]} == ${#O_A[@]} )) || fails+=("audio track count changed ($line)")

    for ((i = 0; i < ${#S_A[@]}; i++)); do
        local sc sp sl sch st oc="" op="" ol="" och="" ot="" et claims

        sc=$(_field "${S_A[$i]}" 1); sp=$(_field "${S_A[$i]}" 2)
        sl=$(_field "${S_A[$i]}" 3); sch=$(_field "${S_A[$i]}" 11)
        st=$(_field "${S_A[$i]}" 10)

        if (( i < ${#O_A[@]} )); then
            oc=$(_field "${O_A[$i]}" 1); op=$(_field "${O_A[$i]}" 2)
            ol=$(_field "${O_A[$i]}" 3); och=$(_field "${O_A[$i]}" 11)
            ot=$(_field "${O_A[$i]}" 10)
        fi

        # jobs from before atrans existed: a codec change is a transcode
        if [[ -z "${ITEM_EXP[atrans]+x}" && -n "$oc" && "$sc" != "$oc" ]]; then
            trans[$i]=1
        fi

        if [[ -z "${trans[$i]:-}" ]]; then
            exp_titles+=("$st")
            continue
        fi

        _rep "Audio track $((i + 1))" \
            "$(_codec_label "$sc" "$sp") ${sl/#-/${sch}ch} -> $(_codec_label "$oc" "$op") $( [[ "$ol" == "-" || "$ol" == "unknown" ]] && echo "${och}ch" || echo "$ol") (transcoded)" >&3

        if [[ "$sp" == *Atmos* ]]; then
            if [[ "$op" == *Atmos* ]]; then
                _rep "Atmos metadata" "KEPT" >&3
            else
                _rep "Atmos metadata" "DROPPED (audio transcoded; channel-based ${och}ch kept)" >&3
            fi
        fi
        if [[ "$sp" == *DTS:X* ]]; then
            _rep "DTS:X metadata" "DROPPED (audio transcoded; channel-based ${och}ch kept)" >&3
        fi

        if [[ "$sl" != "$ol" && "$sl" != "-" ]]; then
            if [[ "$oc" == "aac" && ( "$ol" == "unknown" || "$ol" == "-" ) ]]; then
                _rep "Audio $((i + 1)) layout" "$sl -> stored in an AAC PCE (ffprobe cannot name it; ${och} channels kept)" >&3
            else
                _rep "Audio $((i + 1)) layout" "CHANGED: $sl -> $ol" >&3
                warns+=("audio $((i + 1)) channel layout changed")
            fi
        fi

        # title: must describe the new track, neutral text kept
        if [[ "$st" == "-" ]]; then
            et="-"
        else
            et=$(audio_title_rewrite "$st" "$oc" "$sch")
        fi
        exp_titles+=("$et")

        claims=""
        [[ "$ot" != "-" ]] && claims=$(audio_title_false_claims "$ot" "$oc" "$och" "$op")

        if [[ -n "$claims" ]]; then
            _rep "Audio $((i + 1)) title" "STALE: \"$ot\" claims $claims" >&3
            fails+=("audio $((i + 1)) title is no longer true (\"$ot\": $claims)")
        elif [[ "$ot" != "$et" ]]; then
            _rep "Audio $((i + 1)) title" "UNEXPECTED: \"$ot\" (expected \"$et\")" >&3
            warns+=("audio $((i + 1)) title differs from the planned title")
        elif [[ "$st" == "-" ]]; then
            _rep "Audio $((i + 1)) title" "none (source had none; nothing invented)" >&3
        elif [[ "$st" != "$ot" ]]; then
            _rep "Audio $((i + 1)) title" "UPDATED \"$st\" -> \"$ot\"" >&3
            ((updated += 1))
        else
            _rep "Audio $((i + 1)) title" "KEPT \"$ot\" (still accurate)" >&3
        fi
    done

    n=0
    for v in "${S_DROPPED[@]+"${S_DROPPED[@]}"}"; do
        [[ "$v" == subtitle* ]] && ((n += 1))
    done
    line="$(( ${#S_S[@]} + n )) -> ${#O_S[@]}"
    (( n > 0 )) && line+="  ($n not supported in MKV, DROPPED)"
    _rep "Subtitle tracks" "$line" >&3
    (( ${#S_S[@]} == ${#O_S[@]} )) || fails+=("subtitle track count changed")

    for ((i = 0; i < ${#S_S[@]}; i++)); do
        local soc sidx
        soc=$(_field "${S_S[$i]}" 13)
        sidx=$(_field "${S_S[$i]}" 12)
        if [[ "$soc" == "mov_text" ]]; then
            _rep "Subtitle $((i + 1))" "mov_text -> SRT (format conversion; language/title/flags kept)" >&3
            _rep "Subtitle $((i + 1)) styling" "$(movtext_note "$src" "$sidx")" >&3
        fi
    done

    for v in "${S_DROPPED[@]+"${S_DROPPED[@]}"}"; do
        printf '    dropped: %s\n' "$v" >&3
    done

    # ---- attachments: names + MIME types, not just the count
    s=$(printf '%s\n' "${S_ATT[@]+"${S_ATT[@]}"}" | sort | tr "$MS" '|')
    o=$(printf '%s\n' "${O_ATT[@]+"${O_ATT[@]}"}" | sort | tr "$MS" '|')
    if (( ${#S_ATT[@]} == 0 && ${#O_ATT[@]} == 0 )); then
        _rep "Attachments" "none" >&3
    elif [[ "$s" == "$o" ]]; then
        _rep "Attachments" "MATCH (${#S_ATT[@]} -> ${#O_ATT[@]}: file names + MIME types)" >&3
    else
        _rep "Attachments" "CHANGED (${#S_ATT[@]} -> ${#O_ATT[@]}): $(tr '\n' ' ' <<< "$s")-> $(tr '\n' ' ' <<< "$o")" >&3
        warns+=("attachments differ")
    fi

    # ---- chapters (flat view as FFmpeg/players list them) ...
    local sch och offset=0 state
    state=$(cat "$ITEM_TMP/chapters_state" 2>/dev/null || echo none)
    [[ "${ITEM_EXP[copyts]:-0}" == "1" ]] || offset=$(format_start_time "$src")

    # Start times + titles only: when a chapter has no stored end time,
    # ffprobe derives one from the file duration, which legitimately
    # differs after re-encoding. Stored end times are compared exactly
    # in the Editions check below.
    sch=$(chapter_meta "$src" | awk -F'\t' -v o="$offset" '{
        s = $1 - o * 1000; if (s < 0) s = 0
        printf "%.0f\t%s\n", s, $3 }')
    och=$(chapter_meta "$out" | awk -F'\t' '{ printf "%.0f\t%s\n", $1, $3 }')
    s=$(grep -c . <<< "$sch" || true)
    o=$(grep -c . <<< "$och" || true)

    if (( s == 0 && o == 0 )); then
        _rep "Chapters" "none" >&3
    elif [[ "$sch" == "$och" ]]; then
        _rep "Chapters" "MATCH ($s: start times + titles)" >&3
    else
        _rep "Chapters" "CHANGED ($s -> $o: start times/titles differ)" >&3
        fails+=("chapters differ from the source")
    fi

    # ... and the full Matroska structure (editions, flags, nesting,
    # UIDs, names + languages)
    case "$state" in
        restored)
            local oxml="$ITEM_TMP/chapters_output.xml"
            if mkv_chapters_xml "$out" "$oxml" &&
               diff -q <(chapter_xml_canon "$ITEM_TMP/chapters_restore.xml" "$ITEM_TMP/chapters_restore.xml") \
                       <(chapter_xml_canon "$oxml" "$ITEM_TMP/chapters_restore.xml") >/dev/null; then
                _rep "Editions" "MATCH ($(chapter_xml_describe "$oxml"); UIDs + flags identical)" >&3
            else
                _rep "Editions" "CHANGED: $(chapter_xml_describe "$ITEM_TMP/chapters_restore.xml") -> $( [[ -s "$oxml" ]] && chapter_xml_describe "$oxml" || echo none)" >&3
                fails+=("edition/chapter structure differs from the source")
            fi
            ;;
        unverified:*)
            _rep "Editions" "NOT VERIFIED (${state#unverified:}; only FFmpeg's flat chapter list was kept)" >&3
            warns+=("chapter structure not verified")
            ;;
        *)
            if (( s > 0 )) && ! is_matroska "$src"; then
                _rep "Editions" "n/a (source container has a flat chapter list)" >&3
            fi
            ;;
    esac

    if [[ -s "$ITEM_TMP/segment_uid_kept" ]]; then
        local suid ouid
        suid=$(cat "$ITEM_TMP/segment_uid_kept")
        read -r ouid _ <<< "$(mkv_segment_uids "$out")"
        if [[ "${ouid,,}" == "${suid,,}" ]]; then
            _rep "Segment UID" "KEPT (referenced by ordered chapters / linked files)" >&3
        else
            _rep "Segment UID" "CHANGED: ordered-chapter references may break" >&3
            fails+=("segment UID not kept")
        fi
    fi

    # ---- flags / tags
    _flags_line() {
        local label="$1" field="$2" sa oa ss os
        sa=$(_flag_seq S_A "$field"); oa=$(_flag_seq O_A "$field")
        ss=$(_flag_seq S_S "$field"); os=$(_flag_seq O_S "$field")

        if (( ${#S_A[@]} != ${#O_A[@]} || ${#S_S[@]} != ${#O_S[@]} )); then
            _rep "$label" "n/a (track count changed)" >&3
        elif [[ "$sa" == "$oa" && "$ss" == "$os" ]]; then
            _rep "$label" "MATCH" >&3
        else
            local d=""
            [[ "$sa" != "$oa" ]] && d+="audio [$sa] -> [$oa] "
            [[ "$ss" != "$os" ]] && d+="subtitles [$ss] -> [$os]"
            _rep "$label" "CHANGED: $d" >&3
            warns+=("$label changed")
        fi
    }

    _flags_line "Default flags" 4
    _flags_line "Forced flags" 5
    _flags_line "Commentary/HI/VI" 6-8
    _flags_line "Languages" 9

    # titles: audio against the planned titles, subtitles unchanged
    local ota=() t
    for ((i = 0; i < ${#O_A[@]}; i++)); do ota+=("$(_field "${O_A[$i]}" 10)"); done
    s=$(printf '%s\n' "${exp_titles[@]+"${exp_titles[@]}"}"; _flag_seq S_S 10)
    o=$(printf '%s\n' "${ota[@]+"${ota[@]}"}"; _flag_seq O_S 10)
    if (( ${#S_A[@]} != ${#O_A[@]} || ${#S_S[@]} != ${#O_S[@]} )); then
        _rep "Track titles" "n/a (track count changed)" >&3
    elif [[ "$s" != "$o" ]]; then
        _rep "Track titles" "CHANGED unexpectedly" >&3
        warns+=("track titles changed")
    elif (( updated > 0 )); then
        _rep "Track titles" "AS PLANNED ($updated audio title(s) updated above; all others unchanged)" >&3
    else
        _rep "Track titles" "MATCH" >&3
    fi

    s=$(format_title "$src")
    o=$(format_title "$out")
    if [[ -n "$s" ]]; then
        [[ "$s" == "$o" ]] && _rep "Global title" "MATCH" >&3 ||
            { _rep "Global title" "CHANGED" >&3; warns+=("global title changed"); }
    fi

    s="${S_ORDER[*]-}"
    o="${O_ORDER[*]-}"
    if [[ "$s" == "$o" ]]; then
        _rep "Stream order" "MATCH" >&3
    else
        _rep "Stream order" "CHANGED ($s -> $o)" >&3
        warns+=("stream order changed")
    fi

    if (( ${#fails[@]} )); then
        echo "  RESULT: FAILED - ${fails[0]}" >&3
        printf '%s\n' "${fails[0]}" > "$ITEM_TMP/reason"
    elif (( ${#warns[@]} )); then
        echo "  RESULT: check warnings above" >&3
    fi

    exec 3>&-
    unset -f _flags_line

    (( ${#fails[@]} == 0 ))
}

# dv_verify_rpu FILE VIDX EXPECTED_PROFILE EXPECTED_COMPAT EXPECTED_FRAMES
# Prints "VERIFIED (...)" or the reason it is not.
dv_verify_rpu() {
    local file="$1" vidx="$2" prof="$3" compat="$4" frames="$5"
    local tmp summary n p

    hdr_tools_detect

    (( O_DV == 1 )) || { echo "no Dolby Vision configuration record in the output"; return; }
    [[ "$O_DV_PROFILE" == "$prof" ]] || { echo "configuration record profile $O_DV_PROFILE, expected $prof"; return; }
    [[ -z "$compat" || "$O_DV_COMPAT" == "$compat" ]] ||
        { echo "compatibility id $O_DV_COMPAT, expected $compat"; return; }
    [[ "$O_DV_RPU" != "0" ]] || { echo "configuration record says no RPU"; return; }
    [[ "$O_DV_EL" != "1" ]] || { echo "configuration record claims an enhancement layer"; return; }
    [[ -n "$DOVI_TOOL" ]] || { echo "dovi_tool not available to check the RPU"; return; }

    tmp="$ITEM_TMP/output.rpu"

    if ! ffmpeg -v error -nostdin -i "$file" -map "0:$vidx" -c:v copy \
            -bsf:v hevc_mp4toannexb -f hevc - 2>/dev/null |
         "$DOVI_TOOL" extract-rpu - -o "$tmp" >> "$ITEM_TMP/dovi_tool.log" 2>&1; then
        echo "no RPU found in the output stream"
        return
    fi

    summary=$("$DOVI_TOOL" info -s -i "$tmp" 2>/dev/null)
    printf '%s\n' "$summary" > "$ITEM_TMP/output_rpu_summary.txt"
    n=$(awk '/Frames:/ { print $2; exit }' <<< "$summary")
    p=$(awk '/Profile:/ { print $2; exit }' <<< "$summary")

    [[ "$p" == "$prof" ]] || { echo "RPU profile $p, expected $prof"; return; }

    if [[ "$frames" =~ ^[0-9]+$ ]] && [[ "$n" != "$frames" ]]; then
        echo "output has $n RPUs, source had $frames"
        return
    fi

    rm -f -- "$tmp"
    echo "VERIFIED (profile $prof${compat:+.$compat}, RPU in all ${n} frames)"
}
