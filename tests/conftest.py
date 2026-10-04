from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from app.config import AppConfig, LocalConfig, ServerConfig
from app.files.remote import RemotePool
from app.files.service import FileService
from app.files.transfer import TransferManager

from .sshserver import find_bash, start_server

FIXTURES = Path(__file__).parent / "fixtures"
FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")
BASH = find_bash()


def load_fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def make_sample_mkv(path: Path, seconds: int = 3) -> Path:
    """Small MKV: video + 2 audio (second is default) + 1 subtitle."""
    srt = path.with_suffix(".srt")
    srt.write_text("1\n00:00:00,500 --> 00:00:01,500\nHello\n", encoding="utf-8")
    subprocess.run([FFMPEG, "-v", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                    "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000",
                    "-f", "lavfi", "-i", "sine=f=880:sample_rate=48000",
                    "-i", str(srt), "-t", str(seconds),
                    "-map", "0", "-map", "1", "-map", "2", "-map", "3",
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a:0", "ac3", "-c:a:1", "aac", "-c:s", "srt",
                    "-disposition:a:0", "0", "-disposition:a:1", "default", str(path)],
                   check=True, capture_output=True)
    srt.unlink()
    return path


def make_late_audio_mkv(path: Path) -> Path:
    """6 s video; the only audio track starts at 4 s and lasts 2 s (AC-3 192 kb/s)."""
    subprocess.run([FFMPEG, "-v", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                    "-itsoffset", "4", "-f", "lavfi", "-t", "2", "-i", "sine=f=440:sample_rate=48000",
                    "-t", "6", "-map", "0", "-map", "1", "-c:v", "libx264", "-preset", "ultrafast",
                    "-c:a", "ac3", "-b:a", "192k", str(path)], check=True, capture_output=True)
    return path


needs_ffmpeg = pytest.mark.skipif(not (FFMPEG and FFPROBE), reason="ffmpeg/ffprobe not on PATH")
needs_bash = pytest.mark.skipif(not BASH, reason="bash (Git Bash) not found for the test SSH server")


@pytest.fixture
async def env(tmp_path):
    """Two in-process SSH servers (srvA, srvB) + local roots, wired into FileService/TransferManager."""
    if not BASH:
        pytest.skip("bash (Git Bash) not found for the test SSH server")
    local_root = tmp_path / "local"
    (local_root / "movies").mkdir(parents=True)
    servers = []
    cfgs = []
    for name in ("srvA", "srvB"):
        root = tmp_path / name
        root.mkdir()
        ts = await start_server(root, BASH)
        for d in ("in", "out"):
            (ts.home / "compress" / d).mkdir(parents=True)
        servers.append(ts)
        cfgs.append(ServerConfig(name=name, host="127.0.0.1", port=ts.port, user="u",
                                 ffprobe=FFPROBE or "ffprobe", roots=["~/compress/in", "~/compress/out"]))
    cfg = AppConfig(
        local=LocalConfig(ffprobe=FFPROBE or "ffprobe",
                          roots=[str(local_root / "movies").replace("\\", "/")],
                          temp_dir=str(tmp_path / "relay").replace("\\", "/")),
        servers=cfgs, max_transfers=2)
    pool = RemotePool(cfgs)
    for ts, c in zip(servers, cfgs):
        pool.get(c.name).extra_opts = ts.client_opts()
    files = FileService(cfg, pool)
    transfers = TransferManager(cfg, files)

    class Env:
        pass

    e = Env()
    e.cfg, e.pool, e.files, e.transfers, e.servers, e.local_root = cfg, pool, files, transfers, servers, local_root / "movies"
    e.tmp = tmp_path
    yield e
    await transfers.shutdown()
    await files.shutdown()
    await pool.close()
    for ts in servers:
        ts.server.close()
