"""Read-only viewer for the compression tags movie-compresser writes into MKVs.

usage: viewer.py [--stats] [--pause] FILE...

Prints the fields of each FILE in the terminal ("Not recorded" when a tag is
absent). --stats adds the bytes read; --pause waits for Enter before
exiting (used by the Explorer "Compression info" entry, whose console
window would otherwise close at once).

Exit status: 0 all files read, 1 a file is not (valid) Matroska,
2 usage error, 3 a file could not be opened.

Standard library only; this file is copied on its own by installer.py.

Only the EBML header, SeekHead(s), Info, Tracks and Tags are read; Clusters
(the audio / video data) are skipped by their size, never read. A file
without a SeekHead gets one bounded tail scan. Files are opened read-only.
"""
import datetime
import os
import re
import sys

# Element IDs (with their length marker, as written in the file)
EBML, DOC_TYPE = 0x1A45DFA3, 0x4282
SEGMENT, SEEK_HEAD, SEEK, SEEK_ID, SEEK_POSITION = 0x18538067, 0x114D9B74, 0x4DBB, 0x53AB, 0x53AC
INFO, MUXING_APP, WRITING_APP, DATE_UTC = 0x1549A966, 0x4D80, 0x5741, 0x4461
TRACKS, TRACK_ENTRY, TRACK_UID, TRACK_TYPE = 0x1654AE6B, 0xAE, 0x73C5, 0x83
TRACK_NUMBER, CODEC_ID, CODEC_PRIVATE, TRACK_NAME = 0xD7, 0x86, 0x63A2, 0x536E
LANGUAGE, LANGUAGE_BCP47, FLAG_DEFAULT, FLAG_FORCED = 0x22B59C, 0x22B59D, 0x88, 0x55AA
VIDEO, PIXEL_WIDTH, PIXEL_HEIGHT, AUDIO, CHANNELS = 0xE0, 0xB0, 0xBA, 0xE1, 0x9F
TRACK_TYPES = {1: "video", 2: "audio", 17: "subtitle", 16: "logo", 18: "buttons", 32: "control", 33: "metadata"}
MATROSKA_EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
CLUSTER = 0x1F43B675
TAGS, TAG, TARGETS, SIMPLE_TAG, TAG_NAME, TAG_STRING = 0x1254C367, 0x7373, 0x63C0, 0x67C8, 0x45A3, 0x4487
TAG_TRACK_UID, OTHER_TARGET_UIDS = 0x63C5, (0x63C9, 0x63C4, 0x63C6)   # edition, chapter, attachment
VOID, CRC32 = 0xEC, 0xBF
ELEMENT_NAMES = {SEEK_HEAD: "SeekHead", INFO: "Info", TRACKS: "Tracks", TAGS: "Tags"}

# I/O limits: whatever a file claims, no more than this is ever read
MAX_HEADER, MAX_SEEK_HEAD, MAX_INFO = 64 << 10, 256 << 10, 1 << 20
MAX_TRACKS, MAX_TAGS, MAX_TOTAL_READ = 4 << 20, 8 << 20, 24 << 20
MAX_TOP_LEVEL_WALK, MAX_SEEK_TARGETS, TAIL_SCAN, MAX_VALUE_CHARS = 64, 64, 1 << 20, 256
UNKNOWN = None   # unknown element size (live / streaming muxing)

FIELDS = [   # (CompressionInfo attribute, label)
    ("tool", "Compression tool"),
    ("version", "Compressor version"),
    ("date", "Compression date"),
    ("tier", "Compression tier"),
    ("crf", "Compression CRF"),
    ("video_encoder", "Video encoder"),
    ("video_stream_size", "Video stream size"),
    ("writing_app", "Writing application"),
    ("muxing_app", "Muxing application"),
]
# global tags written by mkv_set_compression_tags -> CompressionInfo attribute
# (the first global value counts, as in the scripts)
GLOBAL_FIELDS = {"COMPRESSION_TOOL": "tool", "MOVIE_COMPRESSER_VERSION": "version", "COMPRESSION_DATE": "date",
                 "COMPRESSION_TIER": "tier", "COMPRESSION_CRF": "crf"}
LABEL_WIDTH = 22
NOT_RECORDED = "Not recorded"
USAGE = "usage: viewer.py [--stats] [--pause] FILE..."
EXIT_OK, EXIT_NOT_MATROSKA, EXIT_USAGE, EXIT_UNREADABLE = 0, 1, 2, 3


class CompressionInfo:
    """What the compression scripts leave in an output MKV. Empty strings
    mean "not present"; nothing is derived or guessed."""

    def __init__(self):
        self.is_matroska = False
        self.tags_found = False
        self.tool = ""            # global COMPRESSION_TOOL (movie-compresser)
        self.version = ""         # global MOVIE_COMPRESSER_VERSION (Git version of the encode job)
        self.date = ""            # global COMPRESSION_DATE (YYYY-MM-DD, UTC)
        self.crf = ""             # global COMPRESSION_CRF
        self.tier = ""            # global COMPRESSION_TIER
        self.video_encoder = ""   # ENCODER of the first video track
        self.video_bytes = None   # NUMBER_OF_BYTES of the first video track
        self.writing_app = ""
        self.muxing_app = ""
        self.bytes_read = 0
        self.error = ""
        # for validation (same bounded reads)
        self.file_size = 0
        self.date_utc = None      # Segment Info DateUTC (muxing date)
        self.tracks = []          # Track, in file order
        self.global_tags = {}     # upper-case name -> every value of global SimpleTags
        self.misplaced = []       # (name, value) of compression tags with a track / edition / ... target
        self.damaged = []         # structural problems met while reading

    @property
    def video_stream_size(self):
        return format_byte_size(self.video_bytes) if self.video_bytes is not None else ""


class Track:
    """One TrackEntry (only fields the validation looks at)."""

    def __init__(self):
        self.number = self.uid = 0
        self.type = ""            # video / audio / subtitle / ...
        self.codec_id = ""        # e.g. V_MPEGH/ISO/HEVC, A_AC3
        self.name = ""            # track title
        self.language = "eng"     # Matroska default when the element is absent
        self.default = True
        self.forced = False
        self.width = self.height = self.channels = 0
        self.x265 = {}            # encoder settings x265 stores in CodecPrivate (rc, crf, bitrate, ...)
        self.x265_version = ""
        self.tags = {}            # upper-case name -> value of tags targeting this track


X265_SETTINGS = re.compile(rb"x265 \(build \d+\) - ([\x20-\x7e]{1,200}?) - H\.265/HEVC codec[\x20-\x7e]{0,400}?options: "
                           rb"([\x20-\x7e]{1,8000})")


def parse_x265_settings(private):
    """(version, {option: value}) from the x265 info SEI in CodecPrivate."""
    m = X265_SETTINGS.search(private)
    if not m:
        return "", {}
    opts = {}
    for token in m.group(2).decode("ascii", "replace").split():
        key, sep, value = token.partition("=")
        opts[key] = value if sep else "1"
    return m.group(1).decode("ascii", "replace"), opts


def format_byte_size(n):
    """'4.21 GB (4,523,456,789 bytes)', 1024-based like Explorer."""
    v, unit = float(n), 0
    units = ("bytes", "KB", "MB", "GB", "TB")
    while v >= 1024 and unit < 4:
        v /= 1024
        unit += 1
    return f"{n:,} bytes" if unit == 0 else f"{v:.2f} {units[unit]} ({n:,} bytes)"


def parse_id(b, p):
    """(id, next_pos) of the element ID at b[p], or None."""
    if p >= len(b):
        return None
    first = b[p]
    length = 1 if first & 0x80 else 2 if first & 0x40 else 3 if first & 0x20 else 4 if first & 0x10 else 0
    if length == 0 or p + length > len(b):
        return None
    return int.from_bytes(b[p:p + length], "big"), p + length


def parse_size(b, p):
    """(size or UNKNOWN, next_pos) of the size vint at b[p], or None."""
    if p >= len(b):
        return None
    first = b[p]
    length = 1
    while length <= 8 and not first & (0x80 >> (length - 1)):
        length += 1
    if length > 8 or p + length > len(b):
        return None
    v = first & (0xFF >> length)
    all_ones = v == (0xFF >> length) and all(x == 0xFF for x in b[p + 1:p + length])
    for x in b[p + 1:p + length]:
        v = (v << 8) | x
    return (UNKNOWN if all_ones else v), p + length


def children(buf):
    """Yields (id, payload) of the elements in an in-memory master element;
    raises _Malformed at the first malformed one."""
    p = 0
    while p < len(buf):
        r = parse_id(buf, p)
        s = r and parse_size(buf, r[1])
        if not s or s[0] is UNKNOWN or s[0] > len(buf) - s[1]:
            raise _Malformed
        yield r[0], buf[s[1]:s[1] + s[0]]
        p = s[1] + s[0]


class _Malformed(Exception):
    pass


def safe_children(buf):
    """children() that ends quietly at malformed data, keeping what was read."""
    try:
        yield from children(buf)
    except _Malformed:
        return


def uint(b):
    return int.from_bytes(b, "big") if len(b) <= 8 else 0


def text(b):
    """UTF-8 value for a single-line field: control characters dropped,
    spaces trimmed, length capped."""
    s = bytes(b).rstrip(b"\0").decode("utf-8", "replace")
    s = "".join(ch for ch in s if ch >= " " and ch != "\x7f").strip(" ")
    return s[:MAX_VALUE_CHARS]


class _Reader:
    def __init__(self, f, info):
        self.f, self.info = f, info
        f.seek(0, os.SEEK_END)
        self.size = f.tell()

    def read(self, off, n):
        if off >= self.size or self.info.bytes_read + n > MAX_TOTAL_READ:
            return b""
        self.f.seek(off)
        data = self.f.read(n)
        self.info.bytes_read += len(data)
        return data

    def header(self, off, end):
        """(id, data_pos, size or UNKNOWN) of the element at off, or None."""
        b = self.read(off, min(12, max(0, end - off)))
        if len(b) < 2:
            return None
        r = parse_id(b, 0)
        s = r and parse_size(b, r[1])
        return (r[0], off + s[1], s[0]) if s else None

    def payload(self, h, limit):
        id_, pos, size = h
        if size is not UNKNOWN and pos + size > self.size and id_ in ELEMENT_NAMES:
            self.info.damaged.append(f"{ELEMENT_NAMES[id_]} element extends past the end of the file (truncated)")
        if size is UNKNOWN or size > limit or pos + size > self.size:
            return None
        data = self.read(pos, size)
        return data if len(data) == size else None


class _Parser:
    def __init__(self, f, info):
        self.r, self.info = _Reader(f, info), info
        info.file_size = self.r.size
        self.seg_data = self.seg_end = 0
        self.seek_head_seen = False
        self.visited, self.pending = set(), set()
        self.video_uid = None
        self.track_tags = []   # (uid, name, value)

    def run(self):
        if not self.ebml_header():
            return
        self.info.is_matroska = True
        self.walk_top_level()
        self.follow_seek_targets()
        if not self.seek_head_seen and not self.info.tags_found:
            self.tail_scan_for_tags()
        self.apply_track_tags()

    def ebml_header(self):
        h = self.r.header(0, self.r.size)
        buf = self.r.payload(h, MAX_HEADER) if h and h[0] == EBML else None
        if buf is None:
            return False
        doc_type = next((bytes(v).rstrip(b"\0") for i, v in safe_children(buf) if i == DOC_TYPE), b"")
        if doc_type not in (b"matroska", b"webm"):
            return False
        pos = h[1] + h[2]
        for _ in range(4):   # the Segment follows (Void elements may sit in between)
            s = self.r.header(pos, self.r.size)
            if not s:
                return False
            if s[0] == SEGMENT:
                self.seg_data = s[1]
                self.seg_end = self.r.size if s[2] is UNKNOWN else min(s[1] + s[2], self.r.size)
                return True
            if s[2] is UNKNOWN:
                return False
            pos = s[1] + s[2]
        return False

    def walk_top_level(self):
        """Top-level elements in file order up to the first Cluster."""
        pos = self.seg_data
        for _ in range(MAX_TOP_LEVEL_WALK):
            if pos >= self.seg_end:
                return
            h = self.r.header(pos, self.seg_end)
            if not h or h[0] == CLUSTER:
                return
            self.visit(h)
            if h[2] is UNKNOWN:
                return
            pos = h[1] + h[2]

    def follow_seek_targets(self):
        for _ in range(MAX_SEEK_TARGETS):
            if not self.pending:
                return
            id_, pos = min(self.pending)
            self.pending.discard((id_, pos))
            h = self.r.header(pos, self.seg_end)
            if h and h[0] == id_:
                self.visit(h)

    def visit(self, h):
        if h[1] in self.visited:
            return
        self.visited.add(h[1])
        handlers = {SEEK_HEAD: (MAX_SEEK_HEAD, self.seek_head), INFO: (MAX_INFO, self.segment_info),
                    TRACKS: (MAX_TRACKS, self.tracks), TAGS: (MAX_TAGS, self.tags)}
        if h[0] in handlers:
            if h[0] == SEEK_HEAD:
                self.seek_head_seen = True
            limit, fn = handlers[h[0]]
            buf = self.r.payload(h, limit)
            if buf is not None:
                fn(buf)

    def seek_head(self, buf):
        for i, seek in safe_children(buf):
            if i != SEEK:
                continue
            id_, rel = 0, None
            for j, v in safe_children(seek):
                if j == SEEK_ID and 1 <= len(v) <= 4:
                    id_ = uint(v)
                elif j == SEEK_POSITION and len(v) <= 8:
                    rel = uint(v)
            if (id_ in (SEEK_HEAD, INFO, TRACKS, TAGS) and rel is not None and rel < self.seg_end - self.seg_data
                    and self.seg_data + rel not in self.visited and len(self.pending) < MAX_SEEK_TARGETS):
                self.pending.add((id_, self.seg_data + rel))

    def segment_info(self, buf):
        for i, v in safe_children(buf):
            if i == MUXING_APP and not self.info.muxing_app:
                self.info.muxing_app = text(v)
            elif i == WRITING_APP and not self.info.writing_app:
                self.info.writing_app = text(v)
            elif i == DATE_UTC and len(v) == 8 and self.info.date_utc is None:
                ns = int.from_bytes(v, "big", signed=True)
                self.info.date_utc = MATROSKA_EPOCH + datetime.timedelta(microseconds=ns // 1000)

    def tracks(self, buf):
        if self.info.tracks:
            return
        for i, entry in safe_children(buf):
            if i != TRACK_ENTRY:
                continue
            t = Track()
            bcp47 = ""   # LanguageBCP47 wins over Language when both are present
            for j, v in safe_children(entry):
                if j == TRACK_NUMBER:
                    t.number = uint(v)
                elif j == TRACK_UID:
                    t.uid = uint(v)
                elif j == TRACK_TYPE:
                    t.type = TRACK_TYPES.get(uint(v), f"type {uint(v)}")
                elif j == CODEC_ID:
                    t.codec_id = text(v)
                elif j == TRACK_NAME:
                    t.name = text(v)
                elif j == LANGUAGE:
                    t.language = text(v) or t.language
                elif j == LANGUAGE_BCP47:
                    bcp47 = text(v)
                elif j == FLAG_DEFAULT:
                    t.default = bool(uint(v))
                elif j == FLAG_FORCED:
                    t.forced = bool(uint(v))
                elif j == CODEC_PRIVATE:
                    t.x265_version, t.x265 = parse_x265_settings(bytes(v))
                elif j in (VIDEO, AUDIO):
                    for k, w in safe_children(v):
                        if k == PIXEL_WIDTH:
                            t.width = uint(w)
                        elif k == PIXEL_HEIGHT:
                            t.height = uint(w)
                        elif k == CHANNELS:
                            t.channels = uint(w)
            t.language = bcp47 or t.language
            self.info.tracks.append(t)
            if t.type == "video" and t.uid and self.video_uid is None:   # first video track
                self.video_uid = t.uid

    def tags(self, buf):
        """A Tag is global when its Targets name no track / edition / chapter /
        attachment (UID 0 means "all": global too). Same rule as the scripts'
        _compression_tags_strip and ffprobe's format tags."""
        self.info.tags_found = True
        for i, tag in safe_children(buf):
            if i != TAG:
                continue
            global_, track_uids, simple = True, [], []
            for j, v in safe_children(tag):
                if j == TARGETS:
                    for k, u in safe_children(v):
                        if k == TAG_TRACK_UID and uint(u):
                            global_ = False
                            track_uids.append(uint(u))
                        elif k in OTHER_TARGET_UIDS and uint(u):
                            global_ = False
                            track_uids.append(0)   # not a track-only tag
                elif j == SIMPLE_TAG:   # top-level SimpleTags only
                    name, value = "", ""
                    for k, s in safe_children(v):
                        if k == TAG_NAME:
                            name = bytes(s).rstrip(b"\0").decode("utf-8", "replace")
                        elif k == TAG_STRING:
                            value = text(s)
                    if name:
                        simple.append((name.upper(), value))
            for name, value in simple:
                if global_:
                    self.info.global_tags.setdefault(name, []).append(value)
                    attr = GLOBAL_FIELDS.get(name)
                    if attr and not getattr(self.info, attr):
                        setattr(self.info, attr, value)
                    continue
                if name.startswith("COMPRESSION_") or name in GLOBAL_FIELDS:
                    self.info.misplaced.append((name, value))
                if len(track_uids) == 1 and track_uids[0]:
                    self.track_tags.append((track_uids[0], name, value))

    def apply_track_tags(self):
        """Tags may come before Tracks: matched to the tracks last."""
        by_uid = {t.uid: t for t in self.info.tracks if t.uid}
        for uid, name, value in self.track_tags:
            if uid in by_uid:
                by_uid[uid].tags.setdefault(name, value)
            if uid != self.video_uid:
                continue
            if name == "ENCODER" and not self.info.video_encoder:
                self.info.video_encoder = value
            elif name == "NUMBER_OF_BYTES" and self.info.video_bytes is None and value.isdigit() and len(value) <= 19:
                self.info.video_bytes = int(value)

    def tail_scan_for_tags(self):
        """No SeekHead at all (rare, hand-made files): a complete Tags element
        in the last TAIL_SCAN bytes, accepted only when its whole payload
        parses as Tag elements."""
        start = max(self.r.size - TAIL_SCAN, self.seg_data)
        tail = self.r.read(start, self.r.size - start)
        p = tail.find(b"\x12\x54\xC3\x67")
        while p >= 0:
            s = parse_size(tail, p + 4)
            if s and s[0] not in (UNKNOWN, 0) and s[0] <= len(tail) - s[1]:
                body = tail[s[1]:s[1] + s[0]]
                try:
                    if all(i in (TAG, VOID, CRC32) for i, _ in children(body)):
                        self.tags(body)
                        return
                except _Malformed:
                    pass
            p = tail.find(b"\x12\x54\xC3\x67", p + 1)


def read_compression_info(path):
    """CompressionInfo of path; never raises for bad content (I/O errors are
    reported in .error). The file is opened read-only."""
    info = CompressionInfo()
    try:
        with open(path, "rb") as f:
            _Parser(f, info).run()
    except OSError as e:
        info.error = e.strerror or str(e)
    except (MemoryError, RecursionError):
        pass
    return info


def describe(path, info, stats=False):
    """Terminal lines for one file."""
    lines = [f"File: {path}"]
    if info.error:
        lines.append(f"  Error: cannot open the file ({info.error})")
    elif not info.is_matroska:
        lines.append("  Error: not a Matroska file (no valid EBML header / Segment)")
    else:
        lines += [f"  {label + ':':<{LABEL_WIDTH}}{getattr(info, attr) or NOT_RECORDED}" for attr, label in FIELDS]
    if stats:
        lines.append(f"  {'Tags element found:':<{LABEL_WIDTH}}{'yes' if info.tags_found else 'no'}")
        lines.append(f"  {'Bytes read:':<{LABEL_WIDTH}}{info.bytes_read}")
    return lines


def exit_code(infos):
    """0 all files read, 1 some file is not (valid) Matroska, 3 some file
    could not be opened (2 is a usage error)."""
    if any(i.error for i in infos):
        return EXIT_UNREADABLE
    return EXIT_OK if all(i.is_matroska for i in infos) else EXIT_NOT_MATROSKA


def pause():
    """Explorer's "Compression info" runs in a console of its own that closes
    when the program ends: wait for Enter there (--pause), never otherwise."""
    try:
        input("\nPress Enter to close...")
    except (EOFError, KeyboardInterrupt):
        pass


def main(argv):
    args = list(argv)
    stats = pause_at_end = False
    while args and args[0].startswith("--"):
        opt = args.pop(0)
        if opt == "--stats":
            stats = True
        elif opt == "--pause":
            pause_at_end = True
        elif opt == "--":
            break
        else:
            print(f"viewer.py: unknown option {opt}", file=sys.stderr)
            return EXIT_USAGE
    if not args:
        print(USAGE, file=sys.stderr)
        return EXIT_USAGE
    try:
        if pause_at_end and sys.platform == "win32":
            try:
                import ctypes
                ctypes.windll.kernel32.SetConsoleTitleW("Compression info")
            except (AttributeError, OSError):
                pass
        infos = []
        for n, path in enumerate(args):
            info = read_compression_info(path)
            infos.append(info)
            print(("\n" if n else "") + "\n".join(describe(path, info, stats)), flush=True)
        return exit_code(infos)
    finally:
        if pause_at_end:
            pause()


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main(sys.argv[1:]))
