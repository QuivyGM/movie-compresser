from fractions import Fraction

from app.files.probe import PacketAggregator, apply_scan_to_media, build_scan_result, normalize_media

from .conftest import load_fixture


def test_hevc_4k_dtshd_subs():
    m = normalize_media(load_fixture("hevc4k_dtshd_subs.json"))
    assert m["duration"] == 8673.302
    assert m["resolution"] == "3840x2160"
    assert m["video_codec"] == "hevc" and m["video_profile"] == "Main 10"
    assert m["video_bitrate"] == 58123456          # from mkvmerge BPS tag
    assert m["main_audio_codec"] == "dts" and m["main_audio_channels"] == 8
    assert m["main_audio_bitrate"] == 4523000
    assert m["audio_tracks"] == 2 and m["subtitle_tracks"] == 3
    assert m["video_size"] is None and m["main_audio_size"] is None
    assert m["total_audio_bitrate"] is None and m["total_audio_size"] is None
    assert m["measured"] is False
    assert [s["type"] for s in m["streams"]][-1] == "attachment"
    assert m["streams"][1]["language"] == "eng" and m["streams"][1]["default"]


def test_avc_1080p_ac3_ignores_cover_art():
    m = normalize_media(load_fixture("avc1080_ac3.json"))
    assert m["resolution"] == "1920x1080"        # not the 600x900 attached picture
    assert m["video_codec"] == "h264" and m["video_bitrate"] == 9010000
    assert m["main_audio_codec"] == "ac3" and m["main_audio_bitrate"] == 448000
    assert m["duration"] == 6512.48
    assert m["main_video_index"] == 0


def test_missing_bitrate_metadata_stays_null():
    m = normalize_media(load_fixture("missing_bitrate.json"))
    assert m["video_bitrate"] is None
    assert m["main_audio_bitrate"] is None
    assert m["duration"] is None                  # no format/stream duration -> never invented
    assert m["format_bitrate"] is None            # "N/A"
    assert m["main_audio_codec"] == "truehd"


def test_no_default_audio_falls_back_to_first():
    m = normalize_media(load_fixture("no_default_audio.json"))
    assert m["main_audio_index"] == 1
    assert m["main_audio_codec"] == "ac3" and m["main_audio_channels"] == 2
    assert m["audio_tracks"] == 2 and m["subtitle_tracks"] == 0


def test_empty_probe():
    m = normalize_media({})
    assert m["resolution"] is None and m["video_codec"] is None and m["audio_tracks"] == 0


def test_packet_aggregation_and_scan_result():
    agg = PacketAggregator()
    lines = [
        "stream_index=0|pts=0|duration=40|size=1000",
        "stream_index=1|pts=0|duration=1024|size=200|",
        "stream_index=2|pts=N/A|duration=N/A|size=100|",
        "stream_index=3|pts=1000|duration=1000|size=10",
        "stream_index=0|pts=99500|duration=40|size=3000",
        "garbage line",
    ]
    for line in lines:
        agg.feed_line(line)
    assert agg.totals() == {0: (4000, 2), 1: (200, 1), 2: (100, 1), 3: (10, 1)}
    assert agg.position == 0.0  # no time bases given

    media = normalize_media(load_fixture("hevc4k_dtshd_subs.json"))
    media["duration"] = 100.0
    r = build_scan_result(media, agg.totals())
    assert r["main_video"]["size"] == 4000 and r["main_video"]["bitrate"] == 320
    assert r["main_audio"]["index"] == 1 and r["main_audio"]["size"] == 200
    assert r["total_audio"]["size"] == 300 and r["total_audio"]["bitrate"] == 24
    assert r["subtitles"]["count"] == 3
    assert [s["type"] for s in r["other_streams"]] == ["attachment"]
    m2 = apply_scan_to_media(media, r)
    assert m2["measured"] and m2["video_size"] == 4000 and m2["total_audio_size"] == 300
    assert media["measured"] is False  # original untouched


def test_scan_total_audio_null_if_any_stream_unmeasured():
    media = normalize_media(load_fixture("hevc4k_dtshd_subs.json"))
    r = build_scan_result(media, {0: (1000, 1), 1: (500, 1)})  # stream 2 (audio) missing
    assert r["total_audio"]["size"] is None and r["total_audio"]["bitrate"] is None


# ---------- per-stream durations ----------


def _media_two_streams(container=10.0):
    return {
        "duration": container, "main_video_index": 0, "main_audio_index": 1,
        "streams": [
            {"index": 0, "type": "video", "codec": "h264", "time_base": "1/1000"},
            {"index": 1, "type": "audio", "codec": "ac3", "time_base": "1/48000"},
        ],
    }


def test_late_starting_stream_uses_its_own_duration():
    agg = PacketAggregator({0: Fraction(1, 1000), 1: Fraction(1, 48000)})
    for k in range(10):  # video 0..10 s, 1 packet/s of 1000 B
        agg.feed_line(f"stream_index=0|pts={k * 1000}|duration=1000|size=1000")
    for k in range(4):   # audio starts at 6 s: 4 packets of 1 s each, 2000 B
        agg.feed_line(f"stream_index=1|pts={(6 + k) * 48000}|duration=48000|size=2000|")
    d = agg.durations()
    assert d == {0: 10.0, 1: 4.0}
    assert agg.position == 10.0
    r = build_scan_result(_media_two_streams(), agg.totals(), d)
    a = r["main_audio"]
    assert a["duration"] == 4.0 and a["duration_source"] == "stream"
    assert a["bitrate"] == 8000 * 8 // 4          # not / 10 (container)
    assert r["main_video"]["bitrate"] == 10000 * 8 // 10
    assert r["total_audio"]["bitrate"] == a["bitrate"]


def test_pts_reordering_uses_min_first_and_max_end():
    agg = PacketAggregator({0: Fraction(1, 1000)})
    for pts in (0, 3000, 1000, 2000):  # decode order != presentation order (B-frames)
        agg.feed_line(f"stream_index=0|pts={pts}|duration=1000|size=10")
    assert agg.durations() == {0: 4.0}


def test_short_or_unknown_stream_duration_falls_back_to_container():
    agg = PacketAggregator({0: Fraction(1, 1000)})   # stream 1 has no time base
    agg.feed_line("stream_index=0|pts=0|duration=500|size=100")   # 0.5 s < 1 s
    agg.feed_line("stream_index=1|pts=N/A|duration=N/A|size=50")
    d = agg.durations()
    assert d == {0: 0.5, 1: None}
    r = build_scan_result(_media_two_streams(container=20.0), agg.totals(), d)
    for s in r["streams"]:
        assert s["duration"] == 20.0 and s["duration_source"] == "container"
    assert r["main_video"]["bitrate"] == 100 * 8 // 20


def test_no_container_duration_and_no_stream_duration_gives_null():
    r = build_scan_result(_media_two_streams(container=None), {0: (100, 1)}, {0: None})
    assert r["main_video"]["bitrate"] is None and r["main_video"]["duration_source"] is None


def test_stream_summary_keeps_time_base():
    m = normalize_media({"streams": [{"index": 0, "codec_type": "video", "time_base": "1/1000"}]})
    assert m["streams"][0]["time_base"] == "1/1000"
