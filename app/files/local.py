"""Local (Windows) filesystem access and local ffprobe."""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import stat
import subprocess
import threading
from typing import Callable

from .paths import fs_path, is_media, local_join, norm_local
from .probe import PACKET_ENTRIES, PacketAggregator

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


class ProbeError(Exception):
    pass


def entry_obj(location: str, path: str, name: str, is_dir: bool, size: int | None, mtime: float | None) -> dict:
    return {
        "location": location,
        "path": path,
        "name": name,
        "type": "folder" if is_dir else "file",
        "size": None if is_dir else size,
        "mtime": int(mtime) if mtime is not None else None,
        "is_media": (not is_dir) and is_media(name),
        "media": None,
        "folder": None,
    }


def _list_dir_sync(location: str, path: str) -> list[dict]:
    out = []
    with os.scandir(fs_path(path)) as it:
        for e in it:
            try:
                st = e.stat()  # follows links
            except OSError:
                continue
            is_dir = stat.S_ISDIR(st.st_mode)
            out.append(entry_obj(location, local_join(path, e.name), e.name, is_dir, st.st_size, st.st_mtime))
    return out


async def list_dir(location: str, path: str) -> list[dict]:
    return await asyncio.to_thread(_list_dir_sync, location, path)


def _stat_sync(location: str, path: str) -> dict:
    st = os.stat(fs_path(path))
    name = os.path.basename(path.rstrip("/")) or path
    return entry_obj(location, path, name, stat.S_ISDIR(st.st_mode), st.st_size, st.st_mtime)


async def stat_path(location: str, path: str) -> dict:
    return await asyncio.to_thread(_stat_sync, location, path)


def _folder_stats_sync(path: str) -> dict:
    total = files = 0
    stack = [fs_path(path)]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        elif e.is_file(follow_symlinks=False):
                            total += e.stat(follow_symlinks=False).st_size
                            files += 1
                    except OSError:
                        continue
        except OSError:
            continue
    return {"size": total, "files": files}


async def folder_stats(path: str) -> dict:
    return await asyncio.to_thread(_folder_stats_sync, path)


def walk_files(root: str) -> tuple[list[tuple[str, int, float]], list[str]]:
    """Recursive listing: ([(relpath, size, mtime)], [rel dirs]) with '/' separators."""
    files, dirs = [], []
    base = fs_path(root)
    for dp, dn, fn in os.walk(base):
        rel_dir = os.path.relpath(dp, base).replace("\\", "/")
        rel_dir = "" if rel_dir == "." else rel_dir
        for d in dn:
            dirs.append(f"{rel_dir}/{d}" if rel_dir else d)
        for f in fn:
            st = os.stat(os.path.join(dp, f))
            files.append((f"{rel_dir}/{f}" if rel_dir else f, st.st_size, st.st_mtime))
    return files, dirs


def disk_free(path: str) -> int:
    return shutil.disk_usage(fs_path(path)).free


def exists(path: str) -> bool:
    return os.path.lexists(fs_path(path))


# ---------- ffprobe ----------

def _check_ffprobe_sync(ffprobe: str) -> dict:
    exe = shutil.which(ffprobe) or (ffprobe if os.path.isfile(ffprobe) else None)
    if not exe:
        return {"ok": False, "path": ffprobe,
                "error": f"ffprobe not found at '{ffprobe}'. Install FFmpeg and set [local] ffprobe in config.toml."}
    try:
        r = subprocess.run([exe, "-version"], capture_output=True, timeout=15, creationflags=CREATE_NO_WINDOW)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"ok": False, "path": exe, "error": f"ffprobe at '{exe}' could not be run: {e}"}
    out = r.stdout.decode("utf-8", "replace").strip()
    if r.returncode != 0 or not out.startswith("ffprobe"):
        err = (r.stderr.decode("utf-8", "replace").strip() or out)[-300:]
        return {"ok": False, "path": exe, "error": f"'{exe} -version' failed (exit {r.returncode}): {err}"}
    return {"ok": True, "path": exe, "version": out.splitlines()[0]}


async def check_ffprobe(ffprobe: str) -> dict:
    """Verify the local ffprobe exists and runs (`ffprobe -version`)."""
    return await asyncio.to_thread(_check_ffprobe_sync, ffprobe)


def _ffprobe_json_sync(ffprobe: str, path: str, timeout: float) -> dict:
    cmd = [ffprobe, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-i", fs_path(path)]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout, creationflags=CREATE_NO_WINDOW)
    except FileNotFoundError:
        raise ProbeError(f"ffprobe not found: {ffprobe}")
    except subprocess.TimeoutExpired:
        raise ProbeError("ffprobe timed out")
    if r.returncode != 0:
        raise ProbeError(r.stderr.decode("utf-8", "replace").strip()[-500:] or f"ffprobe exit {r.returncode}")
    try:
        return json.loads(r.stdout.decode("utf-8", "replace"))
    except json.JSONDecodeError as e:
        raise ProbeError(f"invalid ffprobe output: {e}")


async def ffprobe_json(ffprobe: str, path: str, timeout: float = 60) -> dict:
    # Run in a thread: works regardless of the event loop type uvicorn picks on Windows.
    return await asyncio.to_thread(_ffprobe_json_sync, ffprobe, path, timeout)


def _packet_scan_sync(ffprobe: str, path: str, agg: PacketAggregator,
                      cancel: threading.Event, on_progress: Callable[[float], None]) -> None:
    cmd = [ffprobe, "-v", "error", "-show_entries", PACKET_ENTRIES,
           "-of", "compact=p=0", "-i", fs_path(path)]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                creationflags=CREATE_NO_WINDOW, bufsize=1 << 20)
    except FileNotFoundError:
        raise ProbeError(f"ffprobe not found: {ffprobe}")
    err_buf: list[bytes] = []
    done = threading.Event()

    def watch_cancel():  # kill promptly even if ffprobe is blocked on slow I/O
        while not done.is_set():
            if cancel.wait(0.2):
                if proc.poll() is None:
                    proc.kill()
                return

    t = threading.Thread(target=lambda: err_buf.append(proc.stderr.read()), daemon=True)
    w = threading.Thread(target=watch_cancel, daemon=True)
    t.start()
    w.start()
    try:
        n = 0
        for raw in proc.stdout:
            agg.feed_line(raw.decode("ascii", "replace"))
            n += 1
            if n % 20000 == 0:
                on_progress(agg.position)
    finally:
        done.set()
        if cancel.is_set() and proc.poll() is None:
            proc.kill()
        proc.wait()
        t.join(timeout=5)
    if cancel.is_set():
        return
    if proc.returncode != 0:
        msg = b"".join(err_buf).decode("utf-8", "replace").strip()[-500:]
        raise ProbeError(msg or f"ffprobe exit {proc.returncode}")


async def packet_scan(ffprobe: str, path: str, agg: PacketAggregator,
                      cancel: threading.Event, on_progress: Callable[[float], None]) -> None:
    await asyncio.to_thread(_packet_scan_sync, ffprobe, path, agg, cancel, on_progress)


__all__ = ["list_dir", "stat_path", "folder_stats", "walk_files", "disk_free", "exists",
           "ffprobe_json", "packet_scan", "ProbeError", "entry_obj", "norm_local"]
