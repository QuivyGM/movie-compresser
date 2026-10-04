"""Path normalization and root restriction for local (Windows) and remote (POSIX) paths."""
from __future__ import annotations

import ntpath
import os
import posixpath
import re
import shlex

MEDIA_EXTS = {".mkv", ".mp4", ".m2ts", ".ts", ".avi", ".mov"}


class PathError(Exception):
    """Path is malformed or outside the configured roots."""


def is_media(name: str) -> bool:
    return os.path.splitext(name)[1].lower() in MEDIA_EXTS


# ---------- local (Windows or POSIX host) ----------

def norm_local(path: str) -> str:
    """Absolute, normalized, forward-slash form used throughout the API."""
    if not path or "\x00" in path:
        raise PathError("empty or invalid path")
    p = path.replace("\\", "/")
    if p.startswith("//?/"):
        p = p[4:]
    return os.path.abspath(p).replace("\\", "/")


def local_within(path: str, root: str) -> bool:
    a = os.path.normcase(norm_local(path)).replace("\\", "/").rstrip("/")
    r = os.path.normcase(norm_local(root)).replace("\\", "/").rstrip("/")
    return a == r or a.startswith(r + "/")


def check_local(path: str, roots: list[str]) -> str:
    """Normalize and verify the path (and its resolved target) is inside a root."""
    p = norm_local(path)
    if not any(local_within(p, r) for r in roots):
        raise PathError(f"path outside configured roots: {p}")
    # Resolve junctions/symlinks to catch escapes via links.
    real = os.path.realpath(fs_path(p))
    if real.startswith("\\\\?\\"):
        real = real[4:]
    real_roots = [os.path.realpath(fs_path(r)) for r in roots]
    real_roots = [r[4:] if r.startswith("\\\\?\\") else r for r in real_roots]
    if not any(local_within(real, r) for r in real_roots):
        raise PathError(f"path resolves outside configured roots: {p}")
    return p


def fs_path(p: str) -> str:
    """OS path for filesystem calls; adds the \\\\?\\ prefix for long Windows paths."""
    if os.name != "nt":
        return p
    w = p.replace("/", "\\")
    if len(w) >= 240 and not w.startswith("\\\\?\\") and re.match(r"^[A-Za-z]:\\", w):
        return "\\\\?\\" + w
    return w


def local_join(d: str, name: str) -> str:
    _check_name(name)
    return norm_local(d.rstrip("/") + "/" + name)


def local_parent(path: str) -> str:
    return norm_local(ntpath.dirname(path) if os.name == "nt" else posixpath.dirname(path))


# ---------- remote (POSIX) ----------

def norm_remote(path: str, home: str | None = None) -> str:
    if not path or "\x00" in path:
        raise PathError("empty or invalid path")
    if path == "~" or path.startswith("~/"):
        if not home:
            raise PathError("cannot expand ~ without home directory")
        path = home.rstrip("/") + path[1:]
    if not path.startswith("/"):
        raise PathError(f"remote path must be absolute: {path}")
    p = posixpath.normpath(path)
    if p.startswith("//"):
        p = "/" + p.lstrip("/")
    return p


def remote_within(path: str, root: str) -> bool:
    r = root.rstrip("/")
    return path == root or path == r or path.startswith(r + "/") or r == ""


def check_remote(path: str, roots: list[str], home: str | None = None) -> str:
    p = norm_remote(path, home)
    if not any(remote_within(p, r) for r in roots):
        raise PathError(f"path outside configured roots: {p}")
    return p


def remote_join(d: str, name: str) -> str:
    _check_name(name)
    return posixpath.join(d, name)


def _check_name(name: str) -> None:
    if not name or name in (".", "..") or "/" in name or "\\" in name or "\x00" in name:
        raise PathError(f"invalid file name: {name!r}")


def q(path: str) -> str:
    """Quote a value for a remote POSIX shell."""
    return shlex.quote(path)


def unique_name(name: str, exists) -> str:
    """'movie.mkv' -> 'movie (1).mkv' ... first name for which exists(name) is False."""
    stem, ext = os.path.splitext(name)
    if name.startswith(".") and stem == name:
        stem, ext = name, ""
    i = 1
    while True:
        cand = f"{stem} ({i}){ext}"
        if not exists(cand):
            return cand
        i += 1
