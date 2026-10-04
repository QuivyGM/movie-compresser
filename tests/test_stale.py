"""Stale .part detection/deletion, against local roots and the in-process SSH servers."""
from __future__ import annotations

import asyncio

import pytest

from app.config import ServerConfig
from app.files.remote import RemoteServer
from app.files.stale import delete_stale_parts, find_stale_parts, part_key

pytestmark = pytest.mark.asyncio

IN = "/home/u/compress/in"


def lp(p) -> str:
    return str(p).replace("\\", "/")


def seed(env):
    """Create .part and look-alike files locally and on srvA; return the expected stale set."""
    lroot = env.local_root
    (lroot / "deep" / "er").mkdir(parents=True)
    (lroot / "movie.mkv.part").write_bytes(b"x" * 10)
    (lroot / "deep" / "er" / "한글 it's.mkv.part").write_bytes(b"y" * 20)
    (lroot / "movie.part.mkv").write_bytes(b"not a part")     # suffix isn't .part
    (lroot / "folder.part").mkdir()                           # a directory, not a file
    rin = env.servers[0].home / "compress" / "in"
    (rin / "sub dir").mkdir()
    (rin / "a b.mkv.part").write_bytes(b"z" * 30)
    (rin / "sub dir" / "c.part").write_bytes(b"w" * 40)
    (rin / "keep.mkv").write_bytes(b"k")
    # outside the configured roots: must never be reported
    (env.servers[0].home / "compress" / "outside.part").write_bytes(b"o")
    return {
        ("Local", lp(lroot / "movie.mkv.part")),
        ("Local", lp(lroot / "deep" / "er" / "한글 it's.mkv.part")),
        ("srvA", f"{IN}/a b.mkv.part"),
        ("srvA", f"{IN}/sub dir/c.part"),
    }


async def test_find_stale_parts_local_and_remote(env):
    expected = seed(env)
    r = await find_stale_parts(env.files, set())
    got = {(i["location"], i["path"]) for i in r["items"]}
    assert got == expected
    assert r["skipped"] == []
    by_path = {i["path"]: i for i in r["items"]}
    assert by_path[f"{IN}/sub dir/c.part"]["size"] == 40
    assert all(i["mtime"] > 0 for i in r["items"])


async def test_unreachable_server_is_skipped(env):
    seed(env)
    dead_cfg = ServerConfig(name="dead", host="127.0.0.1", port=1, user="u", roots=["/srv/x"])
    env.cfg.servers.append(dead_cfg)
    dead = RemoteServer(dead_cfg)
    dead.extra_opts = {"known_hosts": None, "config": [], "agent_path": None, "connect_timeout": 3}
    env.pool.servers["dead"] = dead
    r = await find_stale_parts(env.files, set())
    assert [s["location"] for s in r["skipped"]] == ["dead"]
    assert len(r["items"]) == 4  # the other locations still reported


async def test_excludes_parts_of_running_transfers(env):
    src = env.local_root / "big.mkv"
    with open(src, "wb") as f:
        f.truncate(400 * 1024 * 1024)
    t = await env.transfers.create("Local", lp(src), "srvA", IN)
    for _ in range(300):
        if t.done > 0:
            break
        await asyncio.sleep(0.02)
    assert t.state == "running"
    active = env.transfers.active_parts()
    assert ("srvA", f"{IN}/big.mkv.part") in active
    r = await find_stale_parts(env.files, active)
    assert all(i["path"] != f"{IN}/big.mkv.part" for i in r["items"])
    res = await delete_stale_parts(env.files, active, [{"location": "srvA", "path": f"{IN}/big.mkv.part"}])
    assert not res[0]["ok"] and "running transfer" in res[0]["error"]
    env.transfers.cancel(t.id)
    await t.task
    assert env.transfers.active_parts() == set()


async def test_delete_selected_and_validation(env):
    seed(env)
    lroot = env.local_root
    outside_local = env.tmp / "outside.part"
    outside_local.write_bytes(b"o")
    targets = [
        {"location": "Local", "path": lp(lroot / "movie.mkv.part")},                    # ok
        {"location": "srvA", "path": f"{IN}/sub dir/c.part"},                            # ok
        {"location": "Local", "path": lp(lroot / "movie.part.mkv")},                    # not .part
        {"location": "Local", "path": lp(outside_local)},                                # outside roots
        {"location": "srvA", "path": f"{IN}/../outside.part"},                           # traversal
        {"location": "srvA", "path": f"{IN}/keep.mkv"},                                  # not .part
        {"location": "Local", "path": lp(lroot / "folder.part")},                       # directory
        {"location": "srvA", "path": f"{IN}/gone.part"},                                 # missing
        {"location": "nowhere", "path": "/x.part"},                                      # unknown location
    ]
    res = await delete_stale_parts(env.files, set(), targets)
    ok = [r["ok"] for r in res]
    assert ok == [True, True, False, False, False, False, False, False, False]
    assert all(r["error"] for r in res[2:])
    assert not (lroot / "movie.mkv.part").exists()
    assert not (env.servers[0].home / "compress" / "in" / "sub dir" / "c.part").exists()
    assert (lroot / "movie.part.mkv").exists() and outside_local.exists()
    assert (env.servers[0].home / "compress" / "outside.part").exists()
    assert (env.servers[0].home / "compress" / "in" / "keep.mkv").exists()
    assert (lroot / "folder.part").is_dir()
    left = {(i["location"], i["path"]) for i in (await find_stale_parts(env.files, set()))["items"]}
    assert left == {("Local", lp(lroot / "deep" / "er" / "한글 it's.mkv.part")), ("srvA", f"{IN}/a b.mkv.part")}


async def test_local_part_key_is_case_insensitive_on_windows():
    import os
    a = part_key("Local", "D:/Movies/X.mkv.part")
    b = part_key("Local", "d:\\movies\\x.mkv.part")
    assert (a == b) == (os.name == "nt")
    assert part_key("srv", "/a/X.part") != part_key("srv", "/a/x.part")
