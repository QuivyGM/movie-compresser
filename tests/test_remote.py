"""Remote operations against the in-process SSH server (real SFTP + real du/df/find/ffprobe|awk)."""
from __future__ import annotations

import asyncio
import threading

import pytest

from app.files import local as localfs
from app.files.paths import PathError
from app.files.probe import PacketAggregator, time_bases

from .conftest import make_late_audio_mkv, make_sample_mkv, needs_ffmpeg

pytestmark = pytest.mark.asyncio


async def test_connect_and_test(env):
    srv = env.pool.get("srvA")
    r = await srv.test()
    assert r["ok"], r
    assert r["home"] == "/home/u"
    assert r["roots"] == ["/home/u/compress/in", "/home/u/compress/out"]


async def test_list_roots_and_dir_with_awkward_names(env):
    home = env.servers[0].home
    names = ["movie (2019) it's.mkv", "space name.txt", "한글 파일.mkv", "$weird`name;rm -rf.txt"]
    for n in names:
        (home / "compress" / "in" / n).write_bytes(b"x" * 10)
    (home / "compress" / "in" / "sub dir").mkdir()
    (home / "compress" / "in" / "sub dir" / "a.bin").write_bytes(b"y" * 1000)

    roots = await env.files.list("srvA", "")
    assert [e["path"] for e in roots["entries"]] == ["/home/u/compress/in", "/home/u/compress/out"]

    listing = await env.files.list("srvA", "~/compress/in")
    got = {e["name"]: e for e in listing["entries"]}
    assert set(got) == set(names) | {"sub dir"}
    assert got["sub dir"]["type"] == "folder"
    assert got["한글 파일.mkv"]["is_media"] and got["한글 파일.mkv"]["size"] == 10
    assert listing["parent"] == ""

    stats = await env.files.folder_stats("srvA", "/home/u/compress/in/sub dir")
    assert stats == {"size": 1000, "files": 1}
    stats = await env.files.folder_stats("srvA", "/home/u/compress/in")
    assert stats["files"] == 5

    files, dirs = await env.pool.get("srvA").walk_files("/home/u/compress/in")
    assert ("sub dir/a.bin", 1000) in [(f, s) for f, s, _ in files]
    assert dirs == ["sub dir"]
    assert await env.pool.get("srvA").disk_free("/home/u/compress/in") > 0


async def test_remote_traversal_rejected(env):
    for bad in ["/home/u/compress/in/../../.ssh", "~/compress", "/etc", "relative/path", "/home/u/compress/inx"]:
        with pytest.raises(PathError):
            await env.files.list("srvA", bad)


@needs_ffmpeg
async def test_remote_probe_and_scan(env):
    path = env.servers[0].home / "compress" / "in" / "sample (it's).mkv"
    make_sample_mkv(path)
    entry = await env.files.probe("srvA", "/home/u/compress/in/sample (it's).mkv")
    m = entry["media"]
    assert m["resolution"] == "320x180" and m["video_codec"] == "h264"
    assert m["main_audio_codec"] == "aac"  # the default-flagged track, not the first
    assert m["audio_tracks"] == 2 and m["subtitle_tracks"] == 1

    scan = await env.files.start_scan("srvA", entry["path"])
    await asyncio.wait_for(scan.task, 60)
    assert scan.state == "done", scan.error
    r = scan.result
    # compare with a local packet scan of the same bytes (visible locally through the chroot)
    agg = PacketAggregator()
    await localfs.packet_scan(env.cfg.local.ffprobe, str(path).replace("\\", "/"), agg, threading.Event(), lambda p: None)
    assert r["main_video"]["size"] == agg.sizes[0]
    assert r["main_audio"]["size"] == agg.sizes[2]
    assert r["total_audio"]["size"] == agg.sizes[1] + agg.sizes[2]
    assert r["subtitles"]["count"] == 1
    assert scan.to_dict()["progress"] == 1.0
    cached = await env.files.probe("srvA", entry["path"])
    assert cached["media"]["measured"] is True
    assert cached["media"]["video_size"] == agg.sizes[0]


async def test_reconnect_after_drop(env):
    srv = env.pool.get("srvA")
    await srv.connect()
    srv._conn.close()
    await asyncio.sleep(0.1)
    r = await srv.test()
    assert r["ok"], r


@needs_ffmpeg
async def test_remote_scan_late_start_bitrate_matches_local(env):
    """Audio that starts at 4 s of a 6 s file: bitrate must use the track's own 2 s span."""
    path = make_late_audio_mkv(env.servers[0].home / "compress" / "in" / "late start.mkv")
    scan = await env.files.start_scan("srvA", "/home/u/compress/in/late start.mkv")
    await asyncio.wait_for(scan.task, 60)
    assert scan.state == "done", scan.error
    a = scan.result["main_audio"]
    assert a["duration_source"] == "stream"
    assert abs(a["duration"] - 2.0) < 0.05
    assert abs(a["bitrate"] - 192000) / 192000 < 0.03     # container duration would give ~64 kb/s
    assert abs(scan.result["main_video"]["duration"] - 6.0) < 0.1
    # the remote awk aggregation must agree exactly with the local Python aggregation
    media = (await env.files.probe("srvA", "/home/u/compress/in/late start.mkv"))["media"]
    agg = PacketAggregator(time_bases(media))
    await localfs.packet_scan(env.cfg.local.ffprobe, str(path).replace("\\", "/"), agg, threading.Event(), lambda p: None)
    remote_streams = {s["index"]: s for s in scan.result["streams"]}
    for i, d in agg.durations().items():
        assert remote_streams[i]["duration"] == d
        assert remote_streams[i]["size"] == agg.sizes[i]
