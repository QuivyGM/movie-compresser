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


def info(writing="mkvmerge v88.0 ('All I Know') 64-bit", muxing="libebml v1.4.5 + libmatroska v1.7.1"):
    return el(INFO, uint(0x2AD7B1, 1000000) + s(0x4D80, muxing) + s(0x5741, writing))


def tracks():
    video = el(0xAE, uint(0xD7, 1) + uint(0x73C5, VIDEO_UID) + uint(0x83, 1) + s(0x86, "V_MPEGH/ISO/HEVC")
               + el(0xE0, uint(0xB0, 320) + uint(0xBA, 240)))
    audio = el(0xAE, uint(0xD7, 2) + uint(0x73C5, AUDIO_UID) + uint(0x83, 2) + s(0x86, "A_AC3"))
    return el(TRACKS, video + audio)


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
