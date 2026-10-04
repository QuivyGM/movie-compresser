"""Normalize ffprobe output into the common file/media schema, and aggregate packet scans."""
from __future__ import annotations

from fractions import Fraction
from typing import Any


def _num(v: Any, cast=float):
    """Parse a numeric ffprobe value; None for missing/'N/A'/garbage. Never invents values."""
    if v is None:
        return None
    try:
        x = cast(float(v)) if cast is int else cast(v)
    except (TypeError, ValueError):
        return None
    if x != x or x < 0:  # NaN or negative
        return None
    return x


def _tag(stream: dict, *names: str):
    tags = stream.get("tags") or {}
    lower = {k.lower(): v for k, v in tags.items()}
    for n in names:
        if n.lower() in lower:
            return lower[n.lower()]
    return None


def stream_bitrate(stream: dict) -> int | None:
    """Bitrate from metadata: stream bit_rate, else Matroska statistics tag (BPS / BPS-eng)."""
    br = _num(stream.get("bit_rate"), int)
    if br:
        return br
    return _num(_tag(stream, "BPS", "BPS-eng"), int) or None


def is_attached_pic(s: dict) -> bool:
    return bool((s.get("disposition") or {}).get("attached_pic"))


def main_video(streams: list[dict]) -> dict | None:
    return next((s for s in streams if s.get("codec_type") == "video" and not is_attached_pic(s)), None)


def main_audio(streams: list[dict]) -> dict | None:
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    for s in audio:
        if (s.get("disposition") or {}).get("default"):
            return s
    return audio[0] if audio else None


def media_duration(data: dict) -> float | None:
    d = _num((data.get("format") or {}).get("duration"))
    if d:
        return d
    durs = [_num(s.get("duration")) for s in data.get("streams") or []]
    durs = [x for x in durs if x]
    if durs:
        return max(durs)
    # Matroska stores per-stream duration as a tag "HH:MM:SS.nnnnnnnnn"
    for s in data.get("streams") or []:
        t = _tag(s, "DURATION", "DURATION-eng")
        if t:
            try:
                h, m, sec = t.split(":")
                return int(h) * 3600 + int(m) * 60 + float(sec)
            except ValueError:
                pass
    return None


def stream_summary(s: dict) -> dict:
    disp = s.get("disposition") or {}
    w, h = s.get("width"), s.get("height")
    return {
        "index": s.get("index"),
        "type": s.get("codec_type"),
        "codec": s.get("codec_name"),
        "profile": s.get("profile"),
        "language": _tag(s, "language"),
        "title": _tag(s, "title"),
        "channels": s.get("channels"),
        "channel_layout": s.get("channel_layout"),
        "resolution": f"{w}x{h}" if w and h else None,
        "bitrate": stream_bitrate(s),
        "default": bool(disp.get("default")),
        "forced": bool(disp.get("forced")),
        "attached_pic": bool(disp.get("attached_pic")),
        "time_base": s.get("time_base"),
    }


def parse_time_base(tb) -> Fraction | None:
    try:
        f = Fraction(str(tb))
    except (TypeError, ValueError, ZeroDivisionError):
        return None
    return f if f > 0 else None


def time_bases(media: dict) -> dict[int, Fraction]:
    out = {}
    for s in media.get("streams", []):
        tb = parse_time_base(s.get("time_base"))
        if tb is not None and s.get("index") is not None:
            out[s["index"]] = tb
    return out


def normalize_media(data: dict) -> dict:
    streams = data.get("streams") or []
    v = main_video(streams)
    a = main_audio(streams)
    res = None
    if v and v.get("width") and v.get("height"):
        res = f"{v['width']}x{v['height']}"
    return {
        "duration": media_duration(data),
        "resolution": res,
        "video_codec": v.get("codec_name") if v else None,
        "video_profile": v.get("profile") if v else None,
        "video_bitrate": stream_bitrate(v) if v else None,
        "video_size": None,
        "main_audio_codec": a.get("codec_name") if a else None,
        "main_audio_channels": a.get("channels") if a else None,
        "main_audio_bitrate": stream_bitrate(a) if a else None,
        "main_audio_size": None,
        "total_audio_bitrate": None,
        "total_audio_size": None,
        "audio_tracks": sum(1 for s in streams if s.get("codec_type") == "audio"),
        "subtitle_tracks": sum(1 for s in streams if s.get("codec_type") == "subtitle"),
        "format_bitrate": _num((data.get("format") or {}).get("bit_rate"), int),
        "container": (data.get("format") or {}).get("format_name"),
        "main_video_index": v.get("index") if v else None,
        "main_audio_index": a.get("index") if a else None,
        "streams": [stream_summary(s) for s in streams],
        "measured": False,
    }


# ---------- packet scan ----------

PACKET_ENTRIES = "packet=stream_index,pts,duration,size"
MIN_STREAM_DURATION = 1.0  # shorter measured spans fall back to the container duration


def _int(v: str) -> int | None:
    try:
        return int(v)
    except ValueError:  # "N/A"
        return None


class PacketAggregator:
    """Accumulates `ffprobe -show_entries packet=stream_index,pts,duration,size -of compact=p=0` lines.

    Per stream it tracks total bytes, packet count, the first pts and the end of the last packet
    (max of pts + duration), all in that stream's time_base ticks.
    """

    def __init__(self, time_bases: dict[int, Fraction] | None = None) -> None:
        self.time_bases = time_bases or {}
        self.sizes: dict[int, int] = {}
        self.counts: dict[int, int] = {}
        self.first_pts: dict[int, int] = {}
        self.end_pts: dict[int, int] = {}
        self.position = 0.0  # furthest presentation time seen, seconds (for progress)

    def feed_line(self, line: str) -> None:
        idx = size = pts = dur = None
        for part in line.strip().split("|"):
            k, _, val = part.partition("=")
            if k == "stream_index":
                idx = _int(val)
            elif k == "size":
                size = _int(val)
            elif k == "pts":
                pts = _int(val)
            elif k == "duration":
                dur = _int(val)
        if idx is None or size is None:
            return
        self.sizes[idx] = self.sizes.get(idx, 0) + size
        self.counts[idx] = self.counts.get(idx, 0) + 1
        if pts is not None:
            self.add_span(idx, pts, pts + max(dur or 0, 0))

    def add_span(self, idx: int, first: int, end: int) -> None:
        if idx not in self.first_pts or first < self.first_pts[idx]:
            self.first_pts[idx] = first
        if idx not in self.end_pts or end > self.end_pts[idx]:
            self.end_pts[idx] = end
        tb = self.time_bases.get(idx)
        if tb is not None:
            t = float(end * tb)
            if t > self.position:
                self.position = t

    def totals(self) -> dict[int, tuple[int, int]]:
        return {i: (self.sizes[i], self.counts[i]) for i in self.sizes}

    def durations(self) -> dict[int, float | None]:
        """Per-stream duration in seconds: (last pts + its duration - first pts) * time_base."""
        out: dict[int, float | None] = {}
        for i in self.sizes:
            tb = self.time_bases.get(i)
            if tb is None or i not in self.first_pts:
                out[i] = None
            else:
                out[i] = float((self.end_pts[i] - self.first_pts[i]) * tb)
        return out


def build_scan_result(media: dict, totals: dict[int, tuple[int, int]],
                      durations: dict[int, float | None] | None = None) -> dict:
    """Combine fast-probe media info with measured per-stream packet totals and durations.

    Each stream's bitrate uses its own measured duration; if that is missing or under
    MIN_STREAM_DURATION, the container duration is used and duration_source says "container".
    """
    container = media.get("duration")
    durations = durations or {}

    streams = []
    for s in media.get("streams", []):
        size, packets = totals.get(s["index"], (None, None))
        dur, source = durations.get(s["index"]), "stream"
        if dur is None or dur < MIN_STREAM_DURATION:
            dur, source = (container, "container") if container else (None, None)
        bitrate = int(size * 8 / dur) if size is not None and dur else None
        streams.append({**s, "size": size, "packets": packets, "duration": dur,
                        "duration_source": source, "measured_bitrate": bitrate})

    def find(idx):
        return next((s for s in streams if s["index"] == idx), None) if idx is not None else None

    def summary(s):
        return {"index": s["index"], "codec": s["codec"], "size": s["size"], "bitrate": s["measured_bitrate"],
                "duration": s["duration"], "duration_source": s["duration_source"]} if s else None

    mv = find(media.get("main_video_index"))
    ma = find(media.get("main_audio_index"))
    audio = [s for s in streams if s["type"] == "audio"]
    complete = bool(audio) and all(s["size"] is not None for s in audio)
    total_audio = sum(s["size"] for s in audio) if complete else None
    # each track has its own duration, so the combined rate is the sum of per-track rates
    rates = [s["measured_bitrate"] for s in audio]
    total_audio_rate = sum(rates) if complete and all(r is not None for r in rates) else None
    other = [s for s in streams if s["type"] not in ("video", "audio", "subtitle") or
             (s["type"] == "video" and s is not mv)]
    return {
        "duration": container,
        "streams": streams,
        "main_video": summary(mv),
        "main_audio": summary(ma),
        "total_audio": {"tracks": len(audio), "size": total_audio, "bitrate": total_audio_rate},
        "subtitles": {"count": sum(1 for s in streams if s["type"] == "subtitle"),
                      "size": sum(s["size"] or 0 for s in streams if s["type"] == "subtitle")},
        "other_streams": [{"index": s["index"], "type": s["type"], "codec": s["codec"],
                           "size": s["size"]} for s in other],
        "total_measured_size": sum(s for s, _ in totals.values()),
    }


def apply_scan_to_media(media: dict, result: dict) -> dict:
    m = dict(media)
    if result.get("main_video"):
        m["video_size"] = result["main_video"]["size"]
    if result.get("main_audio"):
        m["main_audio_size"] = result["main_audio"]["size"]
    m["total_audio_size"] = result["total_audio"]["size"]
    m["total_audio_bitrate"] = result["total_audio"]["bitrate"]
    m["measured"] = True
    m["scan"] = result
    return m
