"""Writes small synthetic Matroska files for the viewer tests.

usage: python -I make_test_mkvs.py OUT_DIR   (also imported by the tests)

Hand-built EBML (no ffmpeg / mkvtoolnix needed) so that every layout the
reader must handle is exact: mkvpropedit-style tags (TargetTypeValue 50)
appended after the clusters, track-targeted decoys, no SeekHead, unknown
sizes, truncation, garbage. The Block payloads are dummies: these files
are for the metadata reader, not for playback.
"""
import os
import sys


def vint_size(n, length=None):
    if length is None:
        length = 1
        while n >= (1 << (7 * length)) - 1:
            length += 1
    return ((1 << (7 * length)) | n).to_bytes(length, "big")


UNKNOWN = b"\x01\xff\xff\xff\xff\xff\xff\xff"


def el(id_, payload, size=None):
    id_b = id_.to_bytes((id_.bit_length() + 7) // 8, "big")
    return id_b + (size if size is not None else vint_size(len(payload))) + payload


def uint(id_, v):
    return el(id_, v.to_bytes(max(1, (v.bit_length() + 7) // 8), "big"))


def s(id_, text):
    return el(id_, text.encode("utf-8"))


EBML, SEGMENT, SEEKHEAD, SEEK, INFO, TRACKS, CLUSTER, TAGS = (
    0x1A45DFA3, 0x18538067, 0x114D9B74, 0x4DBB, 0x1549A966, 0x1654AE6B, 0x1F43B675, 0x1254C367)
VIDEO_UID, AUDIO_UID = 0x1234567890AB, 0x42


def ebml_header():
    return el(EBML, uint(0x4286, 1) + uint(0x42F7, 1) + uint(0x42F2, 4) + uint(0x42F3, 8)
              + s(0x4282, "matroska") + uint(0x4287, 4) + uint(0x4285, 2))


def info(writing="mkvmerge v88.0 ('All I Know') 64-bit", muxing="libebml v1.4.5 + libmatroska v1.7.1", date_ns=None):
    date = el(0x4461, date_ns.to_bytes(8, "big", signed=True)) if date_ns is not None else b""
    return el(INFO, uint(0x2AD7B1, 1000000) + s(0x4D80, muxing) + s(0x5741, writing) + date)


def x265_private(options):
    """hvcC-like CodecPrivate holding the x265 info SEI text (as libx265 writes it)."""
    sei = (b"x265 (build 215) - 4.1+1-1d117be:[Linux][GCC 13.3.0][64 bit] 10bit - H.265/HEVC codec - "
           b"Copyright 2013-2018 (c) Multicoreware, Inc - http://x265.org - options: " + options.encode() + b"\x00\x80")
    return b"\x01\x02\x20\x00\x00\x00\x90\x00\x00\x00\x00\x00\x99\xf0\x00\xfc\xfd\xfa\xfa\x00\x0f\x04" + sei


def tracks(x265=None, audio_title=None):
    private = el(0x63A2, x265_private(x265)) if x265 else b""
    video = el(0xAE, uint(0xD7, 1) + uint(0x73C5, VIDEO_UID) + uint(0x83, 1) + s(0x86, "V_MPEGH/ISO/HEVC")
               + private + el(0xE0, uint(0xB0, 320) + uint(0xBA, 240)))
    title = s(0x536E, audio_title) if audio_title else b""
    audio = el(0xAE, uint(0xD7, 2) + uint(0x73C5, AUDIO_UID) + uint(0x83, 2) + s(0x86, "A_AC3") + title)
    return el(TRACKS, video + audio)


def stats(nbytes, date="2026-10-13 12:00:00"):
    return [simple("BPS", "6400000"), simple("DURATION", "00:00:01.000000000"), simple("NUMBER_OF_BYTES", str(nbytes)),
            simple("_STATISTICS_WRITING_APP", "mkvpropedit v88.0"), simple("_STATISTICS_WRITING_DATE_UTC", date),
            simple("_STATISTICS_TAGS", "BPS DURATION NUMBER_OF_BYTES")]


def cluster(payload_len=64):
    block = el(0xA3, b"\x81\x00\x00\x80" + b"\x00" * payload_len)
    return el(CLUSTER, uint(0xE7, 0) + block)


def simple(name, value):
    return el(0x67C8, s(0x45A3, name) + s(0x447A, "und") + s(0x4487, value))


def tag(targets, *simples):
    return el(0x7373, el(0x63C0, targets) + b"".join(simples))


def global_ttv50(*simples):
    return tag(uint(0x68CA, 50), *simples)


def global_empty_targets(*simples):
    return tag(b"", *simples)


def track_tag(uid, *simples):
    return tag(uint(0x68CA, 50) + uint(0x63C5, uid), *simples)


def tags(*tag_elements):
    return el(TAGS, b"".join(tag_elements))


def seekhead(entries):
    """entries: [(element_id, relative_position)]"""
    return el(SEEKHEAD, b"".join(
        el(SEEK, el(0x53AB, i.to_bytes((i.bit_length() + 7) // 8, "big")) + el(0x53AC, p.to_bytes(8, "big")))
        for i, p in entries))


def segment(children_before_clusters, clusters, tail, with_seekhead=True, unknown_size=False):
    """SeekHead (fixed size: positions are 8-byte) + children + clusters + tail
    elements; the SeekHead points at Info, Tracks and every tail element."""
    def build(positions):
        sh = seekhead(positions) if with_seekhead else b""
        return sh + b"".join(children_before_clusters) + clusters + b"".join(t for _, t in tail)

    ids = [INFO, TRACKS] + [i for i, _ in tail]
    body = build([(i, 0) for i in ids])          # sizes only
    sh_len = len(seekhead([(i, 0) for i in ids])) if with_seekhead else 0
    pos, positions = sh_len, []
    for child in children_before_clusters:
        positions.append(pos)
        pos += len(child)
    pos += len(clusters)
    for _, t in tail:
        positions.append(pos)
        pos += len(t)
    body = build(list(zip(ids, positions)))
    return el(SEGMENT, body, size=UNKNOWN if unknown_size else None)


CURRENT_TAGS = tags(
    track_tag(VIDEO_UID, simple("ENCODER", "Lavc61.19.101 libx265"),
              simple("BPS", "6400000"), simple("NUMBER_OF_BYTES", "4523456789")),
    track_tag(AUDIO_UID, simple("ENCODER", "Lavc61.19.101 ac3"), simple("NUMBER_OF_BYTES", "123")),
    # decoys: compression names on a track / a chapter are not global
    track_tag(VIDEO_UID, simple("COMPRESSION_CRF", "99")),
    tag(uint(0x68CA, 30) + uint(0x63C4, 7), simple("COMPRESSION_TIER", "Decoy")),
    global_ttv50(simple("COMPRESSION_CRF", "23.5"), simple("COMPRESSION_TIER", "Compact")),
)


def write(out, name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)


def main(out):
    os.makedirs(out, exist_ok=True)
    head = ebml_header()
    body = [info(), tracks()]

    # current scripts: mkvpropedit appends Tags after the clusters
    write(out, "current_mkvpropedit.mkv",
          head + segment(body, cluster() + cluster(), [(TAGS, CURRENT_TAGS)]))

    # older ffmpeg -metadata style: empty Targets, tags before the clusters
    old = tags(global_empty_targets(simple("ENCODER", "Lavf61.7.100"), simple("COMPRESSION_CRF", "21"),
                                    simple("COMPRESSION_TIER", "High")),
               track_tag(VIDEO_UID, simple("ENCODER", "Lavc61.19.101 libx265")))
    write(out, "old_ffmpeg_tags.mkv",
          head + segment(body + [old], cluster(), [], with_seekhead=True))

    # CRF only (two-pass / Custom without tier name)
    write(out, "crf_only.mkv",
          head + segment(body, cluster(), [(TAGS, tags(global_ttv50(simple("COMPRESSION_CRF", "18"))))]))

    # outputs of the scripts before tagging existed: encoder only
    write(out, "legacy_no_compression_tags.mkv",
          head + segment(body, cluster(), [(TAGS, tags(track_tag(VIDEO_UID, simple("ENCODER", "Lavc60 libx265"))))]))

    # no Tags element at all
    write(out, "no_tags.mkv", head + segment(body, cluster(), []))

    # no SeekHead: Tags only reachable by the bounded tail scan
    write(out, "no_seekhead.mkv",
          head + segment(body, cluster(), [(TAGS, CURRENT_TAGS)], with_seekhead=False))

    # unknown-size Segment (live muxing), Tags still indexed by the SeekHead
    write(out, "unknown_segment_size.mkv",
          head + segment(body, cluster(), [(TAGS, CURRENT_TAGS)], unknown_size=True))

    # non-ASCII tag value
    write(out, "utf8_tier.mkv",
          head + segment(body, cluster(), [(TAGS, tags(global_ttv50(simple("COMPRESSION_TIER", "Qualité ★"),
                                                                    simple("COMPRESSION_CRF", "20"))))]))

    # truncated in the middle of the Tags element
    full = head + segment(body, cluster(), [(TAGS, CURRENT_TAGS)])
    write(out, "truncated.mkv", full[: len(full) - 40])

    # Tags claiming an absurd size
    bogus = el(TAGS, b"", size=vint_size(1 << 40, 8))
    write(out, "huge_tags_size.mkv", head + segment(body, cluster(), [(TAGS, bogus)]))

    write(out, "garbage.mkv", os.urandom(4096))
    write(out, "empty.mkv", b"")

    # validation cases (compression tags vs x265 settings, statistics, titles)
    def ns(text):   # "2026-10-13 12:00:00" -> Matroska DateUTC
        import datetime
        t = datetime.datetime.fromisoformat(text).replace(tzinfo=datetime.timezone.utc)
        return int((t - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()) * 10**9

    def valid_case(name, x265, glob, date_ns=None, stats_date="2026-10-13 12:00:00", title="English | AC-3 | 5.1"):
        body_v = [info(date_ns=date_ns), tracks(x265=x265, audio_title=title)]
        t = tags(track_tag(VIDEO_UID, simple("ENCODER", "Lavc61 libx265"), *stats(100, stats_date)),
                 track_tag(AUDIO_UID, *stats(50, stats_date)), *glob)
        write(out, name, head + segment(body_v, cluster(), [(TAGS, t)]))

    crf_tags = lambda crf, tier: global_ttv50(simple("COMPRESSION_CRF", crf), simple("COMPRESSION_TIER", tier))  # noqa: E731
    valid_case("valid_ok.mkv", "rc=crf crf=22.0 qcomp=0.60", [crf_tags("22", "Base")], date_ns=ns("2026-10-13 11:59:00"))
    valid_case("crf_mismatch.mkv", "rc=crf crf=20.0 qcomp=0.60", [crf_tags("23.5", "Compact")])
    valid_case("x265_untagged.mkv", "rc=crf crf=24.0", [])
    valid_case("twopass_with_crf.mkv", "rc=abr bitrate=4000 stats-read=2", [crf_tags("22", "Base")])
    valid_case("stats_outdated.mkv", "rc=crf crf=22.0", [crf_tags("22", "Base")],
               date_ns=ns("2026-10-15 08:00:00"), stats_date="2026-10-13 12:00:00")
    valid_case("conflicting_tags.mkv", "rc=crf crf=22.0",
               [crf_tags("22", "Base"), global_empty_targets(simple("COMPRESSION_CRF", "26"))])
    valid_case("bad_values.mkv", None, [crf_tags("twenty", "Ultra")], title=None)
    valid_case("tier_without_crf.mkv", None, [global_ttv50(simple("COMPRESSION_TIER", "High"))])

    # provenance tags (COMPRESSION_TOOL / MOVIE_COMPRESSER_VERSION /
    # COMPRESSION_DATE), laid out as mkv_set_compression_tags writes them
    def prov_tags(version="v1.4.2-5-ga3f8c21-dirty", date="2026-10-19", tool="movie-compresser", crf="23", tier="Base"):
        named = (("COMPRESSION_TOOL", tool), ("MOVIE_COMPRESSER_VERSION", version), ("COMPRESSION_DATE", date),
                 ("COMPRESSION_CRF", crf), ("COMPRESSION_TIER", tier))
        return global_ttv50(*(simple(n, v) for n, v in named if v is not None))

    valid_case("provenance_current.mkv", "rc=crf crf=23.0 qcomp=0.60", [prov_tags()], date_ns=ns("2026-10-13 11:59:00"))
    valid_case("provenance_conflict.mkv", "rc=crf crf=23.0",
               [prov_tags(), global_empty_targets(simple("MOVIE_COMPRESSER_VERSION", "v1.3.0"))])
    valid_case("provenance_ffmpeg_version.mkv", "rc=crf crf=23.0", [prov_tags(version="Lavf61.7.100")])
    valid_case("provenance_partial.mkv", "rc=crf crf=23.0", [prov_tags(tool=None, date="19/10/2026")])
    valid_case("provenance_unknown.mkv", "rc=crf crf=23.0", [prov_tags(version="unknown")])
    # a version on a track is not the file's
    valid_case("provenance_on_track.mkv", "rc=crf crf=22.0",
               [crf_tags("22", "Base"), track_tag(VIDEO_UID, simple("MOVIE_COMPRESSER_VERSION", "v9.9.9"))])

    # 256 MiB cluster before the Tags: proves clusters are skipped, not read
    big_len = 256 * 1024 * 1024
    big_cluster_header = el(CLUSTER, b"", size=vint_size(big_len, 8))
    tail_tags = CURRENT_TAGS
    seg_children = body
    sh = seekhead([(INFO, 0), (TRACKS, 0), (TAGS, 0)])
    p_info = len(sh)
    p_tracks = p_info + len(body[0])
    p_tags = p_tracks + len(body[1]) + len(big_cluster_header) + big_len
    sh = seekhead([(INFO, p_info), (TRACKS, p_tracks), (TAGS, p_tags)])
    seg_len = len(sh) + sum(map(len, seg_children)) + len(big_cluster_header) + big_len + len(tail_tags)
    with open(os.path.join(out, "large_cluster.mkv"), "wb") as f:
        f.write(head + el(SEGMENT, b"", size=vint_size(seg_len, 8)) + sh + b"".join(seg_children)
                + big_cluster_header)
        f.seek(big_len, os.SEEK_CUR)   # sparse-style gap, no data written
        f.write(tail_tags)


if __name__ == "__main__":
    main(sys.argv[1])
