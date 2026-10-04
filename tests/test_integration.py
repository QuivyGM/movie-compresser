"""Opt-in tests against a real server from config.toml.

    set MC_INTEGRATION=1   (PowerShell: $env:MC_INTEGRATION=1)
    optional: MC_INTEGRATION_SERVER=milab   (defaults to the first server)

Writes and then removes one small file in the server's first root and the first local root.
"""
import asyncio
import os
import uuid
from pathlib import Path

import pytest

from app.config import load_config
from app.files.remote import RemotePool
from app.files.service import FileService
from app.files.transfer import TransferManager

pytestmark = [
    pytest.mark.integration,
    pytest.mark.asyncio,
    pytest.mark.skipif(os.environ.get("MC_INTEGRATION") != "1", reason="set MC_INTEGRATION=1 to run"),
]


@pytest.fixture
async def real():
    cfg = load_config()
    name = os.environ.get("MC_INTEGRATION_SERVER") or cfg.servers[0].name
    pool = RemotePool(cfg.servers)
    files = FileService(cfg, pool)
    yield cfg, name, files, TransferManager(cfg, files)
    await pool.close()


async def test_connect_list_probe(real):
    cfg, name, files, _ = real
    r = await files.server(name).test()
    assert r["ok"], r
    roots = await files.list(name, "")
    assert roots["entries"]
    listing = await files.list(name, roots["entries"][0]["path"])
    media = [e for e in listing["entries"] if e["is_media"]]
    if media:
        e = await files.probe(name, media[0]["path"])
        assert "duration" in e["media"]


async def test_round_trip(real):
    cfg, name, files, transfers = real
    srv = files.server(name)
    await srv.connect()
    remote_dir = srv.roots[0]
    local_dir = cfg.local.roots[0]
    tag = uuid.uuid4().hex[:8]
    src = Path(local_dir) / f"mc-itest-{tag}.bin"
    data = os.urandom(5 * 1024 * 1024 + 123)
    src.write_bytes(data)
    back_dir = Path(local_dir) / f"mc-itest-back-{tag}"
    back_dir.mkdir()
    remote_file = f"{remote_dir}/{src.name}"
    try:
        t = await transfers.create("Local", str(src).replace("\\", "/"), name, remote_dir)
        await asyncio.wait_for(t.task, 300)
        assert t.state == "done", t.error
        assert (await srv.stat_path(remote_file))["size"] == len(data)
        t = await transfers.create(name, remote_file, "Local", str(back_dir).replace("\\", "/"))
        await asyncio.wait_for(t.task, 300)
        assert t.state == "done", t.error
        assert (back_dir / src.name).read_bytes() == data
    finally:
        try:
            await (await srv.sftp()).remove(remote_file)
        except Exception:
            pass
        src.unlink(missing_ok=True)
        (back_dir / src.name).unlink(missing_ok=True)
        back_dir.rmdir()
