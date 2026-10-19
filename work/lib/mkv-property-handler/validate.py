"""Read-only validation of the metadata the compression scripts leave in an MKV.

Checks (no file is ever written):
  compression tags   COMPRESSION_TIER / COMPRESSION_CRF: format, tier name
                     (compression_tier_name in work/lib/encode_common.sh),
                     duplicates, tags on a track instead of global
  provenance         COMPRESSION_TOOL / MOVIE_COMPRESSER_VERSION /
                     COMPRESSION_DATE: tool name, written together, ISO date,
                     duplicates; a version that is really an FFmpeg / x265 /
                     MKVToolNix version string. Files compressed before these
                     tags existed show "Not recorded" (information, not a
                     problem); no version is ever derived for them
  CRF consistency    the CRF tag against the x265 settings x265 stores in the
                     video track's CodecPrivate (the same "rc=crf crf=..."
                     string verify.sh's x265_rate_control reads, but from the
                     track header instead of the first frame)
  codecs             every track's codec; compression tags on non-HEVC video
  statistics tags    BPS / NUMBER_OF_BYTES present, plausible, newer than
                     the last mux (Segment DateUTC)
  track titles       verify.sh's own check_track_titles in Verify mode, via
                     verify_titles.sh (needs bash + ffprobe); otherwise only
                     missing audio titles are reported
Finding kinds: MISSING, INVALID, OUTDATED, INCONSISTENT (problems) and INFO.
"""
import datetime
import os
import re
import shutil
import subprocess
from pathlib import Path

import viewer

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
TITLES_SCRIPT = HERE / "verify_titles.sh"
CRF_FORMAT = re.compile(r"^[0-9]+([.][0-9]+)?$")   # as mkv_set_compression_tags accepts it
CRF_RANGE = (0.0, 51.0)                             # x265
TOOL_NAME = "movie-compresser"                      # COMPRESSION_TOOL_NAME in encode_common.sh
PROVENANCE_TAGS = ("COMPRESSION_TOOL", "MOVIE_COMPRESSER_VERSION", "COMPRESSION_DATE")
DATE_FORMAT = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
# version strings of the other programs in the pipeline: never a movie-compresser version
OTHER_TOOL_VERSION = re.compile(r"^(Lav[fcu]\d|lib(x265|ebml|matroska|av)|x265\b|ffmpeg|ffprobe|mkv(merge|propedit|extract)"
                                r"|HandBrake|[0-9]+\.[0-9]+(\.[0-9]+)?\+[0-9]+-[0-9a-f]+)", re.I)
PROBLEM_KINDS = ("MISSING", "INVALID", "OUTDATED", "INCONSISTENT")
CODEC_NAMES = {"V_MPEGH/ISO/HEVC": "HEVC", "V_MPEG4/ISO/AVC": "H.264", "V_AV1": "AV1", "V_VP9": "VP9",
               "A_AC3": "AC-3", "A_EAC3": "E-AC-3", "A_DTS": "DTS", "A_TRUEHD": "TrueHD", "A_OPUS": "Opus",
               "A_AAC": "AAC", "A_FLAC": "FLAC", "A_MPEG/L3": "MP3", "S_TEXT/UTF8": "SRT", "S_TEXT/ASS": "ASS",
               "S_HDMV/PGS": "PGS", "S_VOBSUB": "VobSub"}


def tier_names():
    """Tier names compression_tier_name accepts, read from encode_common.sh."""
    try:
        src = (REPO / "work" / "lib" / "encode_common.sh").read_text(encoding="utf-8")
        m = re.search(r"^compression_tier_name\(\) \{.*?case \"\$1\" in\s*\n\s*([A-Za-z|]+)\)", src, re.S | re.M)
        if m:
            return tuple(m.group(1).split("|"))
    except OSError:
        pass
    return ("Quality", "High", "Base", "Compact", "Custom")


class Finding:
    def __init__(self, kind, subject, message):
        self.kind, self.subject, self.message = kind, subject, message

    def __str__(self):
        return f"{self.kind:<12} {self.subject}: {self.message}"


class FileReport:
    def __init__(self, path):
        self.path = path
        self.status = "OK"        # OK | ISSUES | INVALID | UNREADABLE | ERROR
        self.lines = []           # ("label", "text") information rows
        self.findings = []

    def add(self, kind, subject, message):
        self.findings.append(Finding(kind, subject, message))

    @property
    def problems(self):
        return [f for f in self.findings if f.kind in PROBLEM_KINDS]


def codec_name(codec_id):
    return CODEC_NAMES.get(codec_id, codec_id or "?")


def track_line(t):
    parts = [codec_name(t.codec_id)]
    if t.type == "video" and t.width:
        parts.append(f"{t.width}x{t.height}")
    if t.type == "audio" and t.channels:
        parts.append(f"{t.channels} ch")
    parts.append(t.language)
    flags = [f for f, on in (("default", t.default), ("forced", t.forced)) if on]
    text = ", ".join(parts + flags)
    return text + (f' | "{t.name}"' if t.name else " | no title")


def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def check_compression(info, r, tiers):
    crfs = info.global_tags.get("COMPRESSION_CRF", [])
    tiers_found = info.global_tags.get("COMPRESSION_TIER", [])
    video = next((t for t in info.tracks if t.type == "video"), None)
    x = video.x265 if video else {}
    rc = x.get("rc", "")
    stream = ("x265 " + (f"CRF {x.get('crf')}" if rc == "crf" else
                         f"two-pass {x.get('bitrate')} kb/s" if rc == "abr" and (_num(x.get("stats-read")) or 0) >= 2
                         else f"rc={rc}")) if rc else ""

    r.lines.append(("Compression tool", info.tool or viewer.NOT_RECORDED))
    r.lines.append(("Compressor version", info.version or viewer.NOT_RECORDED))
    r.lines.append(("Compression date", info.date or viewer.NOT_RECORDED))
    r.lines.append(("Compression tier", info.tier or viewer.NOT_RECORDED))
    r.lines.append(("Compression CRF", info.crf or viewer.NOT_RECORDED))
    if stream:
        r.lines.append(("Video encode", f"{stream} (x265 {video.x265_version.split(':')[0]})"))

    for name, values in [("COMPRESSION_CRF", crfs), ("COMPRESSION_TIER", tiers_found)] + [
            (n, info.global_tags.get(n, [])) for n in PROVENANCE_TAGS]:
        if len(set(values)) > 1:
            r.add("INCONSISTENT", name, f"{len(values)} global values ({', '.join(values)}); tools use the first")
        elif len(values) > 1:
            r.add("INFO", name, f"stored {len(values)} times with the same value")
    for name, value in info.misplaced:
        r.add("INVALID", name, f"'{value}' targets a track / chapter, not the file: ignored by the scripts")

    if info.crf:
        if not CRF_FORMAT.match(info.crf):
            r.add("INVALID", "Compression CRF", f"'{info.crf}' is not a number")
        elif not CRF_RANGE[0] <= float(info.crf) <= CRF_RANGE[1]:
            r.add("INVALID", "Compression CRF", f"{info.crf} is outside the x265 range 0-51")
        elif rc == "crf" and _num(x.get("crf")) is not None and abs(float(info.crf) - float(x["crf"])) > 0.05:
            r.add("INCONSISTENT", "Compression CRF", f"tag {info.crf} but the stream was encoded with x265 crf={x['crf']}")
        elif rc and rc != "crf":
            r.add("INCONSISTENT", "Compression CRF", f"tag {info.crf} but the stream is not a CRF encode ({stream})")
        if video and video.codec_id != "V_MPEGH/ISO/HEVC":
            r.add("INCONSISTENT", "Video codec", f"compression tags present but the video is {codec_name(video.codec_id)}, not HEVC")
    elif rc == "crf":
        r.add("OUTDATED", "Compression CRF", f"not recorded although the stream is an x265 CRF {x.get('crf')} encode "
              "(probably written before tagging existed; verify.sh Validate + update backfills it from the job records)")
    else:
        r.add("INFO", "Compression CRF", "not recorded (stream copy, two-pass or not from these scripts)")

    if info.tier:
        if info.tier not in tiers:
            r.add("INVALID", "Compression tier", f"'{info.tier}' is not a tier name ({', '.join(tiers)})")
        if not info.crf:
            r.add("INCONSISTENT", "Compression tier", "present without COMPRESSION_CRF (the scripts always write both)")
    elif info.crf:
        r.add("INFO", "Compression tier", "not recorded (CRF only: no menu tier)")

    check_provenance(info, r)


def check_provenance(info, r):
    """COMPRESSION_TOOL / MOVIE_COMPRESSER_VERSION / COMPRESSION_DATE as
    mkv_set_compression_tags writes them (all three with the CRF). Their
    absence is history (outputs of earlier versions), never corruption."""
    present = [n for n, v in (("COMPRESSION_TOOL", info.tool), ("MOVIE_COMPRESSER_VERSION", info.version),
                              ("COMPRESSION_DATE", info.date)) if v]
    if not present:
        if info.crf:
            r.add("INFO", "Compressor version", f"{viewer.NOT_RECORDED} (compressed before version tagging existed)")
        return
    if len(present) < len(PROVENANCE_TAGS):
        missing = [n for n in PROVENANCE_TAGS if n not in present]
        r.add("INCONSISTENT", "Compressor version", f"{', '.join(missing)} missing although {', '.join(present)} "
              "present (the scripts write all three together)")
    if info.tool and info.tool != TOOL_NAME:
        r.add("INVALID", "Compression tool", f"'{info.tool}' is not {TOOL_NAME}")
    if info.version:
        if OTHER_TOOL_VERSION.match(info.version):
            r.add("INVALID", "Compressor version", f"'{info.version}' looks like an FFmpeg / x265 / MKVToolNix version, "
                  "not a movie-compresser Git version")
        elif info.version == "unknown":
            r.add("INFO", "Compressor version", "recorded as 'unknown' (Git or the repository was not available "
                  "when it was encoded)")
        elif info.version.endswith("-dirty"):
            r.add("INFO", "Compressor version", "encoded from a working tree with uncommitted changes (-dirty)")
    if info.date:
        try:
            ok = bool(DATE_FORMAT.match(info.date)) and bool(datetime.date.fromisoformat(info.date))
        except ValueError:
            ok = False
        if not ok:
            r.add("INVALID", "Compression date", f"'{info.date}' is not an ISO 8601 date (YYYY-MM-DD)")
    if not info.crf:
        r.add("INCONSISTENT", "Compressor version", "present without COMPRESSION_CRF (the scripts write them together)")


def _stats_date(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def check_statistics(info, r):
    with_stats = [t for t in info.tracks if "NUMBER_OF_BYTES" in t.tags]
    video = next((t for t in info.tracks if t.type == "video"), None)
    if not with_stats:
        r.lines.append(("Statistics tags", "none"))
        r.add("MISSING", "Statistics tags", "no BPS / NUMBER_OF_BYTES tags (verify.sh Verify falls back to a "
              "packet scan; Validate + update stores them)")
        return
    missing = [t for t in info.tracks if t.type in ("video", "audio") and "NUMBER_OF_BYTES" not in t.tags]
    if missing:
        r.add("MISSING", "Statistics tags", "none for track(s) " + ", ".join(str(t.number) for t in missing))
    total = 0
    for t in with_stats:
        n = t.tags["NUMBER_OF_BYTES"]
        if not n.isdigit():
            r.add("INVALID", "Statistics tags", f"track {t.number} NUMBER_OF_BYTES '{n}' is not a number")
            continue
        total += int(n)
    if total > info.file_size:
        r.add("INVALID", "Statistics tags", f"tracks claim {total:,} bytes, more than the file's {info.file_size:,} "
              "(stale: the file was rewritten after they were stored)")
    dates = [d for d in (_stats_date(t.tags.get("_STATISTICS_WRITING_DATE_UTC")) for t in with_stats) if d]
    written = min(dates) if dates else None
    if written and info.date_utc and written + datetime.timedelta(seconds=2) < info.date_utc:
        r.add("OUTDATED", "Statistics tags", f"written {written:%Y-%m-%d %H:%M} UTC, before the file was last "
              f"muxed ({info.date_utc:%Y-%m-%d %H:%M} UTC)")
    size = viewer.format_byte_size(int(video.tags["NUMBER_OF_BYTES"])) if video and video.tags.get(
        "NUMBER_OF_BYTES", "").isdigit() else viewer.NOT_RECORDED
    r.lines.append(("Statistics tags", f"video stream {size}" + (f"; written {written:%Y-%m-%d} UTC" if written else "")))


def find_bash():
    """bash able to run verify_titles.sh: Git for Windows' bash on Windows
    (never WSL's System32 bash, which cannot see Windows ffprobe)."""
    if os.name != "nt":
        return shutil.which("bash")
    cands = []
    git = shutil.which("git")
    if git:
        root = Path(git).resolve().parent.parent
        cands += [root / "bin" / "bash.exe", root / "usr" / "bin" / "bash.exe"]
    for pf in (os.environ.get("ProgramW6432"), os.environ.get("ProgramFiles")):
        if pf:
            cands.append(Path(pf) / "Git" / "bin" / "bash.exe")
    return next((str(c) for c in cands if c.is_file()), None)


def title_checker():
    """(bash, None) when verify.sh's title rules can run, else (None, reason)."""
    if not TITLES_SCRIPT.is_file() or not (REPO / "verify.sh").is_file():
        return None, "verify.sh / verify_titles.sh not found"
    bash = find_bash()
    if not bash:
        return None, "bash not found (Git for Windows provides it)"
    if not shutil.which("ffprobe"):
        return None, "ffprobe not found"
    return bash, None


def check_titles(info, r, path, bash, why_not):
    if bash:
        try:
            p = subprocess.run([bash, str(TITLES_SCRIPT), str(path)], capture_output=True, timeout=180,
                               encoding="utf-8", errors="replace", stdin=subprocess.DEVNULL)
            rows = [line.rstrip("\r").split("\t", 1) for line in p.stdout.splitlines() if "\t" in line]
        except (OSError, subprocess.TimeoutExpired) as e:
            rows = [["ERROR", str(e)]]
        errors = [text for label, text in rows if label == "ERROR"]
        if errors or not rows:
            r.add("INFO", "Track titles", "verify.sh title check unavailable: " + ("; ".join(errors) or "no output"))
        else:
            last = None
            for label, text in rows:
                if label == "Track titles":
                    r.lines.append(("Track titles", text + " [verify.sh rules]"))
                    continue
                r.lines.append((label, text))
                subject = label or last
                if label:
                    last = label
                if not label and text.startswith("->") and r.findings and r.findings[-1].subject == subject:
                    r.findings[-1].message += f" {text}"
                elif " - STALE" in text:
                    r.add("INCONSISTENT", subject, "STALE title: " + text.split(" - STALE", 1)[1].strip(" ()"))
                elif " - NOT STANDARD" in text:
                    r.add("OUTDATED", subject, "title not in the standard form")
                elif " - MISSING" in text:
                    r.add("MISSING", subject, "no title")
            return
    else:
        r.add("INFO", "Track titles", f"only missing titles checked: {why_not}")
    for n, t in enumerate((t for t in info.tracks if t.type == "audio"), 1):
        if not t.name:
            r.add("MISSING", f"Audio {n}", "no title")


def validate_file(path, bash=None, why_not=None, tiers=None):
    """FileReport for one file; never raises."""
    r = FileReport(path)
    try:
        info = viewer.read_compression_info(path)
        if info.error:
            r.status = "UNREADABLE"
            r.add("INVALID", "File", f"cannot open: {info.error}")
            return r
        if not info.is_matroska:
            r.status = "INVALID"
            r.add("INVALID", "File", "not a Matroska file (no valid EBML header / Segment)")
            return r
        for d in info.damaged:
            r.add("INVALID", "Structure", d)
        for n, t in enumerate(info.tracks):
            same = sum(1 for u in info.tracks[:n] if u.type == t.type) + 1
            r.lines.append((f"{t.type.capitalize()} {same}" if t.type in ("audio", "subtitle") else t.type.capitalize(),
                            track_line(t)))
        if not any(t.type == "video" for t in info.tracks):
            r.add("INVALID", "Tracks", "no video track" if info.tracks else "no track list could be read")
        check_compression(info, r, tiers or tier_names())
        check_statistics(info, r)
        if any(t.type == "video" for t in info.tracks):
            check_titles(info, r, path, bash, why_not)
        r.status = "ISSUES" if r.problems else "OK"
    except Exception as e:   # one bad file must not stop a batch
        r.status = "ERROR"
        r.add("INVALID", "Validation", f"{type(e).__name__}: {e}")
    return r


def format_report(r, label=None):
    out = [label or str(r.path)]
    w = viewer.LABEL_WIDTH
    for k, v in r.lines:
        out.append(f"  {k + ':' if k else '':<{w}}{v}")
    out += [f"  ! {f}" for f in r.findings if f.kind in PROBLEM_KINDS]
    out += [f"  i {f}" for f in r.findings if f.kind not in PROBLEM_KINDS]
    out.append(f"  {'Result:':<{w}}{r.status}" +(f" ({len(r.problems)} issue{'s' * (len(r.problems) != 1)})"
                                                    if r.problems and r.status == 'ISSUES' else ""))
    return out
