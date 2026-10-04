"""Upload / download / relay transfers through the in-process SSH servers."""
from __future__ import annotations

import asyncio
import os

import pytest

from app.files.transfer import ConflictError, TransferError

pytestmark = pytest.mark.asyncio

IN = "/home/u/compress/in"
OUT = "/home/u/compress/out"


def lp(p) -> str:
    return str(p).replace("\\", "/")


async def wait(t, timeout=60):
    await asyncio.wait_for(asyncio.shield(t.task), timeout)
    return t


async def test_upload_file_verifies_and_keeps_mtime(env):
    src = env.local_root / "movie (1) it's 한글.mkv"
    data = os.urandom(3 * 1024 * 1024 + 7)
    src.write_bytes(data)
    os.utime(src, (1700000000, 1700000000))
    t = await env.transfers.create("Local", lp(src), "srvA", IN)
    await wait(t)
    assert t.state == "done", t.error
    dst = env.servers[0].home / "compress" / "in" / src.name
    assert dst.read_bytes() == data
    assert int(dst.stat().st_mtime) == 1700000000
    assert not (dst.parent / (src.name + ".part")).exists()
    d = t.to_dict()
    assert d["percent"] == 100.0 and d["done"] == d["total"] == len(data)


async def test_download_folder_recursive(env):
    base = env.servers[0].home / "compress" / "out" / "Show S01"
    (base / "Extras" / "empty").mkdir(parents=True)
    (base / "e01.mkv").write_bytes(b"a" * 5000)
    (base / "Extras" / "bts.mkv").write_bytes(b"b" * 3000)
    t = await env.transfers.create("srvA", f"{OUT}/Show S01", "Local", lp(env.local_root))
    await wait(t)
    assert t.state == "done", t.error
    got = env.local_root / "Show S01"
    assert (got / "e01.mkv").read_bytes() == b"a" * 5000
    assert (got / "Extras" / "bts.mkv").read_bytes() == b"b" * 3000
    assert (got / "Extras" / "empty").is_dir()
    assert t.to_dict()["files_total"] == 2


async def test_relay_between_servers_cleans_temp(env):
    src = env.servers[0].home / "compress" / "out" / "relay me.mkv"
    src.write_bytes(os.urandom(2 * 1024 * 1024))
    t = await env.transfers.create("srvA", f"{OUT}/relay me.mkv", "srvB", IN)
    assert t.kind == "relay" and t.total == 2 * t.size
    await wait(t)
    assert t.state == "done", t.error
    assert (env.servers[1].home / "compress" / "in" / "relay me.mkv").read_bytes() == src.read_bytes()
    relay = env.tmp / "relay"
    assert not relay.exists() or not any(relay.iterdir())


async def test_conflict_prompt_skip_rename_overwrite(env):
    src = env.local_root / "dup.mkv"
    src.write_bytes(b"new" * 100)
    existing = env.servers[0].home / "compress" / "in" / "dup.mkv"
    existing.write_bytes(b"old")

    with pytest.raises(ConflictError) as ei:
        await env.transfers.create("Local", lp(src), "srvA", IN)
    assert ei.value.suggested_name == "dup (1).mkv"

    assert await env.transfers.create("Local", lp(src), "srvA", IN, on_conflict="skip") is None
    assert existing.read_bytes() == b"old"

    t = await env.transfers.create("Local", lp(src), "srvA", IN, on_conflict="rename")
    await wait(t)
    assert t.state == "done" and t.dst_path == f"{IN}/dup (1).mkv"
    assert existing.read_bytes() == b"old"

    t = await env.transfers.create("Local", lp(src), "srvA", IN, on_conflict="overwrite")
    await wait(t)
    assert t.state == "done", t.error
    assert existing.read_bytes() == b"new" * 100


async def test_download_conflict_overwrite_local(env):
    (env.servers[0].home / "compress" / "out" / "x.mkv").write_bytes(b"remote")
    (env.local_root / "x.mkv").write_bytes(b"local")
    t = await env.transfers.create("srvA", f"{OUT}/x.mkv", "Local", lp(env.local_root), on_conflict="overwrite")
    await wait(t)
    assert t.state == "done", t.error
    assert (env.local_root / "x.mkv").read_bytes() == b"remote"


async def test_cancel_removes_part(env):
    src = env.local_root / "big.mkv"
    with open(src, "wb") as f:
        f.truncate(400 * 1024 * 1024)  # sparse-ish 400 MiB
    t = await env.transfers.create("Local", lp(src), "srvA", IN)
    for _ in range(200):
        if t.done > 0:
            break
        await asyncio.sleep(0.02)
    env.transfers.cancel(t.id)
    await t.task  # the task records the cancellation instead of propagating it
    assert t.state == "cancelled"
    d = env.servers[0].home / "compress" / "in"
    assert not (d / "big.mkv").exists()
    assert not (d / "big.mkv.part").exists()


async def test_cancel_download_removes_local_part(env):
    src = env.servers[0].home / "compress" / "out" / "bigdl.mkv"
    with open(src, "wb") as f:
        f.truncate(400 * 1024 * 1024)
    t = await env.transfers.create("srvA", f"{OUT}/bigdl.mkv", "Local", lp(env.local_root))
    for _ in range(200):
        if t.done > 0:
            break
        await asyncio.sleep(0.02)
    env.transfers.cancel(t.id)
    await t.task  # the task records the cancellation instead of propagating it
    assert t.state == "cancelled"
    assert not (env.local_root / "bigdl.mkv").exists()
    assert not (env.local_root / "bigdl.mkv.part").exists()


async def test_refuses_insufficient_space(env, monkeypatch):
    src = env.local_root / "a.mkv"
    src.write_bytes(b"x" * 1000)

    async def tiny(path):
        return 10
    monkeypatch.setattr(env.pool.get("srvA"), "disk_free", tiny)
    with pytest.raises(TransferError, match="not enough space"):
        await env.transfers.create("Local", lp(src), "srvA", IN)


async def test_rejects_bad_requests(env):
    src = env.local_root / "a.mkv"
    src.write_bytes(b"x")
    with pytest.raises(TransferError):
        await env.transfers.create("Local", lp(src), "Local", lp(env.local_root))
    with pytest.raises(TransferError):
        await env.transfers.create("srvA", f"{IN}", "srvA", OUT)


async def test_download_rejects_windows_invalid_names(env):
    (env.servers[0].home / "compress" / "out" / "dir").mkdir()
    # a name that is legal on Linux but not on Windows can't be created on this test host,
    # so check the validator directly
    from app.files.transfer import windows_name_problem
    assert windows_name_problem("dir/what?.mkv")
    assert windows_name_problem("CON.txt")
    assert windows_name_problem("trailing.")
    assert windows_name_problem("ok/movie (2019) it's.mkv") is None


async def test_concurrency_limit(env):
    srcs = []
    for i in range(3):
        p = env.local_root / f"c{i}.mkv"
        with open(p, "wb") as f:
            f.truncate(150 * 1024 * 1024)
        srcs.append(p)
    ts = [await env.transfers.create("Local", lp(p), "srvA", IN) for p in srcs]
    seen_running = 0
    for _ in range(300):
        running = sum(t.state == "running" for t in ts)
        seen_running = max(seen_running, running)
        if all(t.state == "done" for t in ts):
            break
        await asyncio.sleep(0.02)
    for t in ts:
        await wait(t, 120)
    assert all(t.state == "done" for t in ts), [t.error for t in ts]
    assert seen_running <= 2
