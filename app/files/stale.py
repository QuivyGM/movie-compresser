"""Find and delete leftover *.part files under the configured roots (never automatically)."""
from __future__ import annotations

import asyncio
import os
import posixpath

from ..config import LOCAL_NAME
from .paths import PathError, fs_path, q
from .remote import RemoteError, RemoteServer
from .service import FileService, NotFound

PART_SUFFIX = ".part"
SERVER_TIMEOUT = 45.0


def part_key(location: str, path: str) -> tuple[str, str]:
    """Comparable key for a .part path (case-insensitive for local Windows paths)."""
    if location == LOCAL_NAME:
        return (location, os.path.normcase(path).replace("\\", "/"))
    return (location, path)


def _walk_local_parts(root: str) -> list[dict]:
    out = []
    base = fs_path(root)
    for dp, _dn, fn in os.walk(base):
        for f in fn:
            if not f.endswith(PART_SUFFIX):
                continue
            full = os.path.join(dp, f)
            try:
                st = os.stat(full)
            except OSError:
                continue
            p = full[4:] if full.startswith("\\\\?\\") else full
            out.append({"path": p.replace("\\", "/"), "size": st.st_size, "mtime": int(st.st_mtime)})
    return out


async def _remote_parts(srv: RemoteServer) -> list[dict]:
    await srv.connect()
    # One SSH command for all roots. Paths are printed relative to each root (%P) after an
    # "R <index>" marker and joined here, so results always carry our normalized root prefix.
    # Missing roots make find fail; that root simply contributes nothing.
    cmd = "; ".join(f"printf 'R {i}\\0'; find {q(r)} -type f -name '*.part' -printf '%s %T@ %P\\0' 2>/dev/null"
                    for i, r in enumerate(srv.roots))
    r = await srv.run(cmd, timeout=300, binary=True)
    out = []
    root = None
    for rec in (r.stdout or b"").split(b"\0"):
        if not rec:
            continue
        if rec.startswith(b"R "):
            root = srv.roots[int(rec[2:])]
            continue
        size, mtime, rel = rec.split(b" ", 2)
        if root is None:
            continue
        out.append({"path": posixpath.join(root, rel.decode("utf-8", "surrogateescape")),
                    "size": int(size), "mtime": int(float(mtime))})
    return out


async def find_stale_parts(files: FileService, active: set[tuple[str, str]]) -> dict:
    """All *.part files under every root, minus those owned by running transfers.

    Unreachable servers are reported in "skipped" instead of failing the whole check.
    """
    items: list[dict] = []
    skipped: list[dict] = []

    async def local_task():
        found = []
        for root in files.cfg.local.roots:
            if os.path.isdir(fs_path(root)):
                found += await asyncio.to_thread(_walk_local_parts, root)
        return "Local", found

    async def remote_task(name: str):
        return name, await asyncio.wait_for(_remote_parts(files.server(name)), SERVER_TIMEOUT)

    names = ["Local"] + [s.name for s in files.cfg.servers]
    tasks = [local_task()] + [remote_task(s.name) for s in files.cfg.servers]
    for name, res in zip(names, await asyncio.gather(*tasks, return_exceptions=True)):
        if isinstance(res, BaseException):
            msg = "timed out" if isinstance(res, asyncio.TimeoutError) else (str(res) or type(res).__name__)
            skipped.append({"location": name, "error": msg})
            continue
        location, found = res
        for f in found:
            if part_key(location, f["path"]) in active:
                continue
            items.append({"location": location, **f})
    items.sort(key=lambda x: (x["location"], x["path"]))
    return {"items": items, "skipped": skipped}


async def delete_stale_parts(files: FileService, active: set[tuple[str, str]], targets: list[dict]) -> list[dict]:
    """Delete the given .part files after re-validating each one. Returns a per-file result list."""
    results = []
    for t in targets:
        location, path = t.get("location", ""), t.get("path", "")
        res = {"location": location, "path": path, "ok": False, "error": None}
        try:
            if not path.endswith(PART_SUFFIX):
                raise PathError("only files ending in .part can be deleted here")
            p = await files.resolve(location, path)  # root restriction + symlink/junction check
            if not p.endswith(PART_SUFFIX):
                raise PathError("only files ending in .part can be deleted here")
            if part_key(location, p) in active:
                raise PathError("in use by a running transfer")
            entry = await files.stat(location, p)
            if entry["type"] != "file":
                raise PathError("not a file")
            if files.is_local(location):
                await asyncio.to_thread(os.remove, fs_path(p))
            else:
                await files.server(location).remove(p)
            res["path"] = p
            res["ok"] = True
        except (PathError, NotFound, RemoteError, OSError) as e:
            res["error"] = str(e) or type(e).__name__
        results.append(res)
    return results
