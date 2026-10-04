"""Transfer manager: local→remote, remote→local, and remote→local→remote relay over SFTP."""
from __future__ import annotations

import asyncio
import os
import posixpath
import re
import shutil
import time
import uuid
from collections import deque
from dataclasses import dataclass, field

import asyncssh

from ..config import LOCAL_NAME, AppConfig
from . import local
from .paths import PathError, fs_path, local_join, remote_join, unique_name
from .service import FileService, NotFound
from .stale import part_key

ACTIVE = ("queued", "running")
_WIN_BAD = re.compile(r'[<>:"|?*\x00-\x1f]')
_WIN_RESERVED = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$", re.I)


class TransferError(Exception):
    pass


class ConflictError(Exception):
    def __init__(self, dst_path: str, suggested_name: str, dst_type: str):
        super().__init__(f"destination exists: {dst_path}")
        self.dst_path = dst_path
        self.suggested_name = suggested_name
        self.dst_type = dst_type


# ---------- speed / ETA ----------

class RateMeter:
    """Rolling-window throughput from (time, cumulative bytes) samples."""

    def __init__(self, window: float = 5.0):
        self.window = window
        self.samples: deque[tuple[float, int]] = deque()

    def add(self, t: float, total_bytes: int) -> None:
        self.samples.append((t, total_bytes))
        # keep one sample at/before the window start so the span covers the full window
        while len(self.samples) > 2 and self.samples[1][0] <= t - self.window:
            self.samples.popleft()

    def speed(self) -> float | None:
        if len(self.samples) < 2:
            return None
        (t0, b0), (t1, b1) = self.samples[0], self.samples[-1]
        if t1 - t0 <= 0:
            return None
        return max(0.0, (b1 - b0) / (t1 - t0))


def eta_seconds(remaining: int, speed: float | None) -> float | None:
    if remaining <= 0:
        return 0.0
    if not speed or speed <= 0:
        return None
    return remaining / speed


def windows_name_problem(rel: str) -> str | None:
    for part in rel.split("/"):
        if _WIN_BAD.search(part):
            return f"'{part}' contains characters not allowed on Windows"
        if _WIN_RESERVED.match(part):
            return f"'{part}' is a reserved name on Windows"
        if part.endswith((" ", ".")):
            return f"'{part}' ends with a space or dot (not allowed on Windows)"
    return None


# ---------- model ----------

@dataclass
class Transfer:
    id: str
    kind: str                       # upload | download | relay
    src_location: str
    src_path: str
    dst_location: str
    dst_dir: str
    dst_path: str
    name: str
    is_dir: bool
    overwrite: bool
    files: list[tuple[str, int, float]] = field(default_factory=list)   # (rel, size, mtime)
    dirs: list[str] = field(default_factory=list)
    size: int = 0                   # source bytes
    total: int = 0                  # bytes to move (2x size for relay)
    done: int = 0
    state: str = "queued"
    phase: str | None = None
    current_file: str | None = None
    files_done: int = 0
    error: str | None = None
    created: float = field(default_factory=time.time)
    started: float | None = None
    finished: float | None = None
    meter: RateMeter = field(default_factory=RateMeter)
    task: asyncio.Task | None = None

    def to_dict(self) -> dict:
        running = self.state == "running"
        speed = self.meter.speed() if running else None
        elapsed = ((self.finished or time.time()) - self.started) if self.started else None
        return {
            "id": self.id, "kind": self.kind, "name": self.name, "is_dir": self.is_dir,
            "src_location": self.src_location, "src_path": self.src_path,
            "dst_location": self.dst_location, "dst_dir": self.dst_dir, "dst_path": self.dst_path,
            "state": self.state, "phase": self.phase, "current_file": self.current_file,
            "files_total": len(self.files), "files_done": self.files_done,
            "size": self.size, "total": self.total, "done": self.done,
            "percent": round(100 * self.done / self.total, 2) if self.total else (100.0 if self.state == "done" else 0.0),
            "speed": speed, "eta": eta_seconds(self.total - self.done, speed) if running else None,
            "avg_speed": (self.done / elapsed) if elapsed else None,
            "error": self.error, "created": self.created, "started": self.started, "finished": self.finished,
        }


class TransferManager:
    def __init__(self, cfg: AppConfig, files: FileService):
        self.cfg = cfg
        self.files = files
        self.transfers: dict[str, Transfer] = {}
        self._sem = asyncio.Semaphore(cfg.max_transfers)
        self._active_parts: set[tuple[str, str]] = set()   # .part files currently being written

    def active_parts(self) -> set[tuple[str, str]]:
        return set(self._active_parts)

    def _track_part(self, location: str, path: str) -> tuple[str, str]:
        key = part_key(location, path)
        self._active_parts.add(key)
        return key

    # ---------- helpers ----------

    async def _exists(self, location: str, path: str) -> bool:
        if self.files.is_local(location):
            return local.exists(path)
        return await self.files.server(location).exists(path)

    async def _free(self, location: str, path: str) -> int:
        if self.files.is_local(location):
            return await asyncio.to_thread(local.disk_free, path)
        return await self.files.server(location).disk_free(path)

    def _join(self, location: str, d: str, name: str) -> str:
        return local_join(d, name) if self.files.is_local(location) else remote_join(d, name)

    async def _names_in(self, location: str, d: str) -> set[str]:
        listing = await self.files.list(location, d)
        return {e["name"] for e in listing["entries"]}

    async def _check_space(self, t: Transfer) -> None:
        free = await self._free(t.dst_location, t.dst_dir)
        if t.size > free:
            raise TransferError(f"not enough space on {t.dst_location}: need {t.size:,} B, {free:,} B free")
        if t.kind == "relay":
            tmp = self.cfg.local.temp_dir
            await asyncio.to_thread(os.makedirs, fs_path(tmp), exist_ok=True)
            free = await asyncio.to_thread(local.disk_free, tmp)
            if t.size > free:
                raise TransferError(f"not enough space in relay temp dir {tmp}: need {t.size:,} B, {free:,} B free")

    # ---------- API ----------

    async def create(self, src_location: str, src_path: str, dst_location: str, dst_dir: str,
                     on_conflict: str | None = None) -> Transfer | None:
        """Validate and queue a transfer. Returns None when skipped; raises ConflictError if a prompt is needed."""
        src_local, dst_local = self.files.is_local(src_location), self.files.is_local(dst_location)
        if src_location == dst_location:
            raise TransferError("source and destination are the same location (not supported in this version)")
        if src_local and dst_local:
            raise TransferError("local → local copies are not supported")
        if on_conflict not in (None, "overwrite", "skip", "rename"):
            raise TransferError(f"invalid on_conflict: {on_conflict}")
        if not src_local:
            self.files.server(src_location)
        if not dst_local:
            self.files.server(dst_location)
        kind = "upload" if src_local else ("download" if dst_local else "relay")

        src = await self.files.resolve(src_location, src_path)
        src_entry = await self.files.stat(src_location, src)
        dst_dir = await self.files.resolve(dst_location, dst_dir)
        dst_entry = await self.files.stat(dst_location, dst_dir)
        if dst_entry["type"] != "folder":
            raise PathError(f"destination is not a folder: {dst_dir}")

        is_dir = src_entry["type"] == "folder"
        name = src_entry["name"]
        dst_path = self._join(dst_location, dst_dir, name)
        overwrite = False
        if await self._exists(dst_location, dst_path):
            dst_existing = await self.files.stat(dst_location, dst_path)
            names = await self._names_in(dst_location, dst_dir)
            suggestion = unique_name(name, lambda n: n in names or f"{n}.part" in names)
            if on_conflict is None:
                raise ConflictError(dst_path, suggestion, dst_existing["type"])
            if on_conflict == "skip":
                return None
            if on_conflict == "rename":
                name = suggestion
                dst_path = self._join(dst_location, dst_dir, name)
            else:
                if dst_existing["type"] != src_entry["type"]:
                    raise TransferError("cannot overwrite a file with a folder (or vice versa)")
                overwrite = True

        if is_dir:
            if src_local:
                files, dirs = await asyncio.to_thread(local.walk_files, src)
            else:
                files, dirs = await self.files.server(src_location).walk_files(src)
        else:
            files, dirs = [("", src_entry["size"] or 0, src_entry["mtime"] or 0)], []
        if dst_local or kind == "relay":
            for rel in [name] + [f for f, _, _ in files if f] + dirs:
                problem = windows_name_problem(rel)
                if problem:
                    raise TransferError(f"cannot store on Windows: {problem}")

        size = sum(s for _, s, _ in files)
        t = Transfer(id=uuid.uuid4().hex[:12], kind=kind, src_location=src_location, src_path=src,
                     dst_location=dst_location, dst_dir=dst_dir, dst_path=dst_path, name=name, is_dir=is_dir,
                     overwrite=overwrite, files=files, dirs=dirs, size=size,
                     total=size * 2 if kind == "relay" else size)
        await self._check_space(t)
        self.transfers[t.id] = t
        t.task = asyncio.create_task(self._run(t))
        self._prune()
        return t

    def list(self) -> list[dict]:
        return [t.to_dict() for t in sorted(self.transfers.values(), key=lambda t: t.created, reverse=True)]

    def get(self, tid: str) -> Transfer:
        t = self.transfers.get(tid)
        if not t:
            raise NotFound(f"unknown transfer: {tid}")
        return t

    def cancel(self, tid: str) -> Transfer:
        t = self.get(tid)
        if t.state in ACTIVE and t.task:
            t.task.cancel()
        return t

    def _prune(self, keep: int = 100) -> None:
        old = sorted((t for t in self.transfers.values() if t.state not in ACTIVE), key=lambda t: t.created)
        for t in old[:max(0, len(old) - keep)]:
            self.transfers.pop(t.id, None)

    async def shutdown(self) -> None:
        tasks = [t.task for t in self.transfers.values() if t.task and not t.task.done()]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    # ---------- execution ----------

    def _progress(self, t: Transfer, base: int):
        def handler(_src, _dst, copied: int, _total: int) -> None:
            t.done = base + copied
            t.meter.add(time.monotonic(), t.done)
        return handler

    async def _run(self, t: Transfer) -> None:
        tmp_root = None
        try:
            async with self._sem:
                t.state, t.started = "running", time.time()
                t.meter.add(time.monotonic(), 0)
                await self._check_space(t)  # re-check: space may have changed while queued
                if t.kind == "upload":
                    t.phase = "upload"
                    await self._upload_tree(t, t.src_path, t.files, t.dirs, base=0)
                elif t.kind == "download":
                    t.phase = "download"
                    await self._download_tree(t, t.dst_path, base=0, final=True)
                else:
                    tmp_root = local_join(self.cfg.local.temp_dir, f"relay-{t.id}")
                    tmp_path = local_join(tmp_root, t.name)
                    t.phase = "download"
                    await self._download_tree(t, tmp_path, base=0, final=False)
                    t.phase, t.files_done = "upload", 0
                    await self._upload_tree(t, tmp_path, t.files, t.dirs, base=t.size)
                t.done = t.total
                t.state, t.phase, t.current_file = "done", None, None
        except asyncio.CancelledError:
            t.state = "cancelled"
        except Exception as e:  # noqa: BLE001 - surfaced to the UI
            t.state = "failed"
            t.error = _describe(e)
        finally:
            t.finished = time.time()
            if tmp_root:
                await asyncio.to_thread(shutil.rmtree, fs_path(tmp_root), True)

    async def _download_tree(self, t: Transfer, dst_root: str, base: int, final: bool) -> None:
        srv = self.files.server(t.src_location)
        sftp = await srv.new_sftp()
        try:
            await asyncio.to_thread(os.makedirs, fs_path(dst_root if t.is_dir else _parent(dst_root)), exist_ok=True)
            for rel in t.dirs:
                await asyncio.to_thread(os.makedirs, fs_path(local_join_rel(dst_root, rel)), exist_ok=True)
            done = base
            for rel, size, mtime in t.files:
                src = posixpath.join(t.src_path, rel) if rel else t.src_path
                dst = local_join_rel(dst_root, rel) if rel else dst_root
                t.current_file = rel or t.name
                await self._get_file(t, sftp, src, dst, size, mtime, done, overwrite=t.overwrite or not final)
                done += size
                t.files_done += 1
        finally:
            sftp.exit()

    async def _get_file(self, t, sftp, src: str, dst: str, size: int, mtime: float, base: int, overwrite: bool):
        part = dst + ".part"
        await asyncio.to_thread(os.makedirs, fs_path(_parent(dst)), exist_ok=True)
        key = self._track_part(LOCAL_NAME, part)
        try:
            await sftp.get(src, fs_path(part), progress_handler=self._progress(t, base))
            got = await asyncio.to_thread(os.path.getsize, fs_path(part))
            if got != size:
                raise TransferError(f"size mismatch for {t.current_file}: expected {size:,} B, got {got:,} B")
            if overwrite:
                await asyncio.to_thread(os.replace, fs_path(part), fs_path(dst))
            else:
                await asyncio.to_thread(_rename_no_clobber, fs_path(part), fs_path(dst))
            if mtime:
                await asyncio.to_thread(os.utime, fs_path(dst), (mtime, mtime))
            t.done = base + size
        except BaseException:
            await asyncio.to_thread(_remove_quiet, fs_path(part))
            raise
        finally:
            self._active_parts.discard(key)

    async def _upload_tree(self, t: Transfer, src_root: str, files, dirs, base: int) -> None:
        srv = self.files.server(t.dst_location)
        sftp = await srv.new_sftp()
        try:
            if t.is_dir:
                await sftp.makedirs(t.dst_path, exist_ok=True)
            for rel in dirs:
                await sftp.makedirs(posixpath.join(t.dst_path, rel), exist_ok=True)
            done = base
            for rel, size, mtime in files:
                src = local_join_rel(src_root, rel) if rel else src_root
                dst = posixpath.join(t.dst_path, rel) if rel else t.dst_path
                t.current_file = rel or t.name
                await self._put_file(t, srv, sftp, src, dst, size, mtime, done)
                done += size
                t.files_done += 1
        finally:
            sftp.exit()

    async def _put_file(self, t, srv, sftp, src: str, dst: str, size: int, mtime: float, base: int):
        part = dst + ".part"
        await sftp.makedirs(posixpath.dirname(dst), exist_ok=True)
        key = self._track_part(t.dst_location, part)
        try:
            await sftp.put(fs_path(src), part, progress_handler=self._progress(t, base))
            got = (await sftp.stat(part)).size
            if got != size:
                raise TransferError(f"size mismatch for {t.current_file}: expected {size:,} B, got {got:,} B")
            if t.overwrite and await sftp.exists(dst):
                try:
                    await sftp.posix_rename(part, dst)   # atomic replace (OpenSSH extension)
                except asyncssh.SFTPOpUnsupported:
                    await sftp.remove(dst)
                    await sftp.rename(part, dst)
            else:
                await sftp.rename(part, dst)             # SFTPv3 rename refuses to clobber
            if mtime:
                await sftp.utime(dst, (mtime, mtime))
            t.done = base + size
        except BaseException:
            await _remote_remove_quiet(srv, part)
            raise
        finally:
            self._active_parts.discard(key)


def local_join_rel(root: str, rel: str) -> str:
    p = root
    for part in rel.split("/"):
        p = local_join(p, part)
    return p


def _parent(p: str) -> str:
    return p.rsplit("/", 1)[0] if "/" in p.rstrip("/") else p


def _rename_no_clobber(src: str, dst: str) -> None:
    if os.path.lexists(dst):
        raise TransferError(f"destination appeared during transfer: {dst}")
    os.rename(src, dst)  # on Windows this also fails if dst exists


def _remove_quiet(p: str) -> None:
    try:
        os.remove(p)
    except OSError:
        pass


async def _remote_remove_quiet(srv, path: str) -> None:
    # The per-transfer SFTP session may be broken (e.g. after cancel); use the shared one.
    try:
        sftp = await srv.sftp()
        await asyncio.wait_for(sftp.remove(path), 15)
    except Exception:  # noqa: BLE001
        pass


def _describe(e: Exception) -> str:
    if isinstance(e, asyncssh.SFTPError):
        return f"SFTP error: {e.reason}"
    return str(e) or type(e).__name__
