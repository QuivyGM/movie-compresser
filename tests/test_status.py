"""Local ffprobe startup check, the /api/status endpoints and stale-parts API."""
import os

import pytest
from fastapi.testclient import TestClient

from app.config import parse_config
from app.files.local import ProbeError, check_ffprobe
from app.main import create_app

from .conftest import FFPROBE, needs_ffmpeg

pytestmark = pytest.mark.asyncio


def p(path) -> str:
    return str(path).replace("\\", "/")


def make_client(tmp_path, ffprobe):
    movies = tmp_path / "Movies"
    movies.mkdir(exist_ok=True)
    cfg = parse_config({"local": {"ffprobe": ffprobe, "roots": [str(movies)], "temp_dir": str(tmp_path / "relay")}})
    c = TestClient(create_app(cfg))
    c.movies = movies
    return c


async def test_check_ffprobe_missing(tmp_path):
    r = await check_ffprobe(str(tmp_path / "nope" / "ffprobe.exe"))
    assert r["ok"] is False and "not found" in r["error"] and "config.toml" in r["error"]


async def test_check_ffprobe_not_runnable(tmp_path):
    fake = tmp_path / ("ffprobe.exe" if os.name == "nt" else "ffprobe")
    fake.write_bytes(b"this is not an executable")
    if os.name != "nt":
        fake.chmod(0o755)
    r = await check_ffprobe(str(fake))
    assert r["ok"] is False and r["error"]


@needs_ffmpeg
async def test_check_ffprobe_ok():
    r = await check_ffprobe(FFPROBE)
    assert r["ok"] is True and r["version"].startswith("ffprobe version")


def test_status_reports_bad_ffprobe_and_blocks_local_probes(tmp_path):
    with make_client(tmp_path, str(tmp_path / "missing-ffprobe.exe")) as c:
        (c.movies / "film.mkv").write_bytes(b"\x1a\x45\xdf\xa3")
        st = c.get("/api/status").json()["local_ffprobe"]
        assert st["ok"] is False and "not found" in st["error"]
        # listing still works; probing fails fast with one clear message instead of running per file
        assert c.get("/api/list", params={"location": "Local", "path": p(c.movies)}).status_code == 200
        r = c.get("/api/probe", params={"location": "Local", "path": p(c.movies / "film.mkv")})
        assert r.status_code == 422 and "local ffprobe unavailable" in r.json()["error"]
        r = c.post("/api/scan", json={"location": "Local", "path": p(c.movies / "film.mkv")})
        assert r.status_code == 422
        assert c.post("/api/status/ffprobe").json()["local_ffprobe"]["ok"] is False


@needs_ffmpeg
def test_status_ok(tmp_path):
    with make_client(tmp_path, FFPROBE) as c:
        st = c.get("/api/status").json()["local_ffprobe"]
        assert st["ok"] is True


def test_stale_parts_api(tmp_path):
    with make_client(tmp_path, FFPROBE or "ffprobe") as c:
        (c.movies / "sub").mkdir()
        (c.movies / "sub" / "x.mkv.part").write_bytes(b"abc")
        (c.movies / "y.part").write_bytes(b"de")
        (c.movies / "z.mkv").write_bytes(b"f")
        r = c.get("/api/stale-parts").json()
        assert {i["path"] for i in r["items"]} == {p(c.movies / "sub" / "x.mkv.part"), p(c.movies / "y.part")}
        assert r["skipped"] == []
        r = c.request("DELETE", "/api/stale-parts", json=[
            {"location": "Local", "path": p(c.movies / "y.part")},
            {"location": "Local", "path": p(c.movies / "z.mkv")},
        ]).json()
        assert r["deleted"] == 1
        assert [x["ok"] for x in r["results"]] == [True, False]
        assert not (c.movies / "y.part").exists() and (c.movies / "z.mkv").exists()
        assert len(c.get("/api/stale-parts").json()["items"]) == 1
        assert c.request("DELETE", "/api/stale-parts", json={"bad": 1}).status_code == 422
