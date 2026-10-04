"""Location-agnostic file operations (Local + remote servers), probe cache and detailed scans."""
from __future__ import annotations

import asyncio
import posixpath
import threading
import time
import uuid
from dataclasses import dataclass, field

from ..config import LOCAL_NAME, AppConfig
from . import local
from .paths import PathError, check_local, local_parent
from .probe import PacketAggregator, apply_scan_to_media, build_scan_result, normalize_media, time_bases
from .remote import RemotePool, RemoteServer

FOLDER_STATS_TTL = 60.0


class NotFound(Exception):
    pass


@dataclass
class Scan:
    id: str
    location: str
    path: str
    state: str = "running"          # running | done | failed | cancelled
    duration: float | None = None
    position: float = 0.0
    result: dict | None = None
    error: str | None = None
    started: float = field(default_factory=time.time)
    finished: float | None = None
    cancel_thread: threading.Event = field(default_factory=threading.Event)
    cancel_async: asyncio.Event = field(default_factory=asyncio.Event)
    task: asyncio.Task | None = None

    def to_dict(self) -> dict:
        prog = None
        if self.state == "done":
            prog = 1.0
        elif self.duration:
            prog = min(1.0, max(0.0, self.position / self.duration))
        return {"id": self.id, "location": self.location, "path": self.path, "state": self.state,
                "progress": prog, "position": self.position, "duration": self.duration,
                "result": self.result, "error": self.error,
                "elapsed": round((self.finished or time.time()) - self.started, 1)}


class FileService:
    def __init__(self, cfg: AppConfig, pool: RemotePool):
        self.cfg = cfg
        self.pool = pool
        self.probe_cache: dict[tuple, dict] = {}
        self.folder_cache: dict[tuple, tuple[float, dict]] = {}
        self._sems: dict[str, asyncio.Semaphore] = {}
        self.scans: dict[str, Scan] = {}
        self.local_ffprobe: dict | None = None   # result of local.check_ffprobe(); None = not checked

    async def check_local_ffprobe(self) -> dict:
        self.local_ffprobe = await local.check_ffprobe(self.cfg.local.ffprobe)
        return self.local_ffprobe

    def _require_local_ffprobe(self) -> None:
        if self.local_ffprobe is not None and not self.local_ffprobe["ok"]:
            raise local.ProbeError(f"local ffprobe unavailable: {self.local_ffprobe['error']}")

    # ---------- locations ----------

    def locations(self) -> list[dict]:
        out = [{"name": LOCAL_NAME, "kind": "local", "roots": self.cfg.local.roots}]
        for s in self.cfg.servers:
            srv = self.pool.get(s.name)
            out.append({"name": s.name, "kind": "remote", "roots": (srv.roots if srv and srv.roots else s.roots)})
        return out

    def is_local(self, location: str) -> bool:
        return location == LOCAL_NAME

    def server(self, location: str) -> RemoteServer:
        srv = self.pool.get(location)
        if srv is None:
            raise NotFound(f"unknown location: {location}")
        return srv

    def _sem(self, location: str) -> asyncio.Semaphore:
        if location not in self._sems:
            self._sems[location] = asyncio.Semaphore(self.cfg.probe_concurrency)
        return self._sems[location]

    async def resolve(self, location: str, path: str) -> str:
        if self.is_local(location):
            return check_local(path, self.cfg.local.roots)
        return await self.server(location).check(path)

    async def roots(self, location: str) -> list[str]:
        if self.is_local(location):
            return self.cfg.local.roots
        srv = self.server(location)
        await srv.connect()
        return srv.roots

    async def parent_of(self, location: str, path: str) -> str:
        """Parent path, or '' (the roots view) when already at a root."""
        roots = await self.roots(location)
        if self.is_local(location):
            norm = lambda p: p.rstrip("/").lower()
            if norm(path) in {norm(r) for r in roots}:
                return ""
            return local_parent(path)
        if path in roots:
            return ""
        return posixpath.dirname(path)

    # ---------- listing ----------

    async def stat(self, location: str, path: str) -> dict:
        try:
            if self.is_local(location):
                return await local.stat_path(location, path)
            return await self.server(location).stat_path(path)
        except FileNotFoundError:
            raise NotFound(f"not found: {path}")

    async def list(self, location: str, path: str) -> dict:
        if not path:
            roots = await self.roots(location)
            entries = []
            for r in roots:
                try:
                    e = await self.stat(location, r)
                    e["name"] = r
                    entries.append(e)
                except (NotFound, OSError):
                    entries.append(local.entry_obj(location, r, r, True, None, None) | {"missing": True})
            return {"location": location, "path": "", "parent": None, "entries": entries}
        p = await self.resolve(location, path)
        try:
            if self.is_local(location):
                entries = await local.list_dir(location, p)
            else:
                entries = await self.server(location).list_dir(p)
        except FileNotFoundError:
            raise NotFound(f"not found: {p}")
        except NotADirectoryError:
            raise PathError(f"not a folder: {p}")
        now = time.time()
        for e in entries:
            if e["type"] == "file" and e["is_media"]:
                e["media"] = self.probe_cache.get((location, e["path"], e["size"], e["mtime"]))
            elif e["type"] == "folder":
                hit = self.folder_cache.get((location, e["path"]))
                if hit and now - hit[0] < FOLDER_STATS_TTL:
                    e["folder"] = hit[1]
        return {"location": location, "path": p, "parent": await self.parent_of(location, p), "entries": entries}

    async def folder_stats(self, location: str, path: str) -> dict:
        p = await self.resolve(location, path)
        async with self._sem(location):
            if self.is_local(location):
                st = await local.folder_stats(p)
            else:
                st = await self.server(location).folder_stats(p)
        self.folder_cache[(location, p)] = (time.time(), st)
        return st

    # ---------- probing ----------

    async def _ffprobe(self, location: str, path: str) -> dict:
        if self.is_local(location):
            self._require_local_ffprobe()
            return await local.ffprobe_json(self.cfg.local.ffprobe, path)
        return await self.server(location).ffprobe_json(path)

    async def probe(self, location: str, path: str) -> dict:
        p = await self.resolve(location, path)
        entry = await self.stat(location, p)
        if entry["type"] != "file":
            raise PathError(f"not a file: {p}")
        key = (location, p, entry["size"], entry["mtime"])
        if key in self.probe_cache:
            entry["media"] = self.probe_cache[key]
            return entry
        async with self._sem(location):
            if key not in self.probe_cache:  # another request may have filled it while we waited
                self.probe_cache[key] = normalize_media(await self._ffprobe(location, p))
        entry["media"] = self.probe_cache[key]
        return entry

    # ---------- detailed scan ----------

    async def start_scan(self, location: str, path: str) -> Scan:
        entry = await self.probe(location, path)  # also validates the path
        scan = Scan(id=uuid.uuid4().hex[:12], location=location, path=entry["path"],
                    duration=entry["media"].get("duration"))
        self.scans[scan.id] = scan
        scan.task = asyncio.create_task(self._run_scan(scan, entry))
        self._prune_scans()
        return scan

    async def _run_scan(self, scan: Scan, entry: dict) -> None:
        agg = PacketAggregator(time_bases(entry["media"]))

        def on_progress(pos: float) -> None:
            scan.position = pos

        try:
            if self.is_local(scan.location):
                await local.packet_scan(self.cfg.local.ffprobe, scan.path, agg, scan.cancel_thread, on_progress)
            else:
                await self.server(scan.location).packet_scan(scan.path, agg, scan.cancel_async, on_progress)
            if scan.cancel_thread.is_set():
                scan.state = "cancelled"
                return
            if not agg.sizes:
                raise local.ProbeError("ffprobe returned no packets")
            media = entry["media"]
            scan.result = build_scan_result(media, agg.totals(), agg.durations())
            key = (scan.location, entry["path"], entry["size"], entry["mtime"])
            measured = apply_scan_to_media(media, scan.result)
            self.probe_cache[key] = measured
            scan.result = {**scan.result, "media": {k: v for k, v in measured.items() if k != "scan"}}
            scan.state = "done"
        except asyncio.CancelledError:
            scan.state = "cancelled"
        except Exception as e:  # noqa: BLE001 - surfaced to the UI
            scan.state = "failed"
            scan.error = str(e) or type(e).__name__
        finally:
            scan.finished = time.time()

    def get_scan(self, scan_id: str) -> Scan:
        s = self.scans.get(scan_id)
        if not s:
            raise NotFound(f"unknown scan: {scan_id}")
        return s

    def cancel_scan(self, scan_id: str) -> Scan:
        s = self.get_scan(scan_id)
        if s.state == "running":
            s.cancel_thread.set()
            s.cancel_async.set()
        return s

    def _prune_scans(self, keep: int = 50) -> None:
        finished = sorted((s for s in self.scans.values() if s.state != "running"), key=lambda s: s.started)
        for s in finished[:max(0, len(finished) - keep)]:
            self.scans.pop(s.id, None)

    async def shutdown(self) -> None:
        for s in self.scans.values():
            s.cancel_thread.set()
            s.cancel_async.set()
