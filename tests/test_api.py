"""HTTP API tests (local location only; remote paths are covered in test_remote/test_transfers)."""
import time

import pytest
from fastapi.testclient import TestClient

from app.config import parse_config
from app.main import create_app

from .conftest import FFPROBE, make_late_audio_mkv, make_sample_mkv, needs_ffmpeg


@pytest.fixture
def client(tmp_path):
    movies = tmp_path / "Movies"
    (movies / "sub dir").mkdir(parents=True)
    (movies / "notes.txt").write_text("hi")
    cfg = parse_config({
        "local": {"ffprobe": FFPROBE or "ffprobe", "roots": [str(movies)], "temp_dir": str(tmp_path / "relay")},
        "servers": [{"name": "srv", "host": "127.0.0.1", "port": 1, "roots": ["~/compress/in"]}],
    })
    with TestClient(create_app(cfg)) as c:
        c.movies = movies
        yield c


def p(path) -> str:
    return str(path).replace("\\", "/")


def test_locations_and_roots(client):
    locs = client.get("/api/locations").json()
    assert [l["name"] for l in locs] == ["Local", "srv"]
    r = client.get("/api/list", params={"location": "Local", "path": ""}).json()
    assert r["parent"] is None and r["entries"][0]["path"] == p(client.movies)


def test_list_dir(client):
    r = client.get("/api/list", params={"location": "Local", "path": p(client.movies)})
    assert r.status_code == 200
    data = r.json()
    names = {e["name"]: e for e in data["entries"]}
    assert names["sub dir"]["type"] == "folder" and names["notes.txt"]["size"] == 2
    assert data["parent"] == ""
    fs = client.get("/api/folderstats", params={"location": "Local", "path": p(client.movies)}).json()
    assert fs == {"size": 2, "files": 1}


def test_traversal_and_unknown_location(client):
    r = client.get("/api/list", params={"location": "Local", "path": p(client.movies) + "/../"})
    assert r.status_code == 403
    r = client.get("/api/list", params={"location": "Local", "path": "C:/Windows"})
    assert r.status_code == 403
    r = client.get("/api/list", params={"location": "nope", "path": "/x"})
    assert r.status_code == 404


def test_rejects_foreign_host_header(client):
    r = client.get("/api/locations", headers={"Host": "evil.example.com"})
    assert r.status_code == 400


def test_unreachable_server_reports_error(client):
    r = client.post("/api/locations/srv/test").json()
    assert r["ok"] is False and r["error"]


@needs_ffmpeg
def test_probe_and_scan_local(client):
    f = make_sample_mkv(client.movies / "sub dir" / "film (it's).mkv")
    r = client.get("/api/probe", params={"location": "Local", "path": p(f)}).json()
    assert r["media"]["resolution"] == "320x180" and r["media"]["measured"] is False
    sid = client.post("/api/scan", json={"location": "Local", "path": p(f)}).json()["scan_id"]
    for _ in range(100):
        s = client.get(f"/api/scan/{sid}").json()
        if s["state"] != "running":
            break
        time.sleep(0.1)
    assert s["state"] == "done", s["error"]
    assert s["result"]["main_video"]["size"] > 0
    assert s["result"]["total_audio"]["tracks"] == 2
    listed = client.get("/api/list", params={"location": "Local", "path": p(f.parent)}).json()
    assert listed["entries"][0]["media"]["measured"] is True


def _scan(client, path):
    sid = client.post("/api/scan", json={"location": "Local", "path": path}).json()["scan_id"]
    for _ in range(100):
        s = client.get(f"/api/scan/{sid}").json()
        if s["state"] != "running":
            return s
        time.sleep(0.1)
    return s


@needs_ffmpeg
def test_scan_late_start_stream_bitrate_local(client):
    f = make_late_audio_mkv(client.movies / "late.mkv")
    s = _scan(client, p(f))
    assert s["state"] == "done", s["error"]
    audio = next(x for x in s["result"]["streams"] if x["type"] == "audio")
    assert audio["duration_source"] == "stream" and abs(audio["duration"] - 2.0) < 0.05
    assert abs(audio["measured_bitrate"] - 192000) / 192000 < 0.03
    assert audio["measured_bitrate"] == s["result"]["main_audio"]["bitrate"]


def test_probe_non_media_error(client):
    r = client.get("/api/probe", params={"location": "Local", "path": p(client.movies / "notes.txt")})
    assert r.status_code == 422


def test_transfer_validation(client):
    r = client.post("/api/transfers", json={"src_location": "Local", "src_path": p(client.movies / "notes.txt"),
                                            "dst_location": "Local", "dst_dir": p(client.movies)})
    assert r.status_code == 400
    r = client.post("/api/transfers", json={"src_location": "Local", "src_path": p(client.movies / "notes.txt"),
                                            "dst_location": "srv", "dst_dir": "/x", "on_conflict": "bogus"})
    assert r.status_code == 422
    assert client.get("/api/transfers").json() == []
