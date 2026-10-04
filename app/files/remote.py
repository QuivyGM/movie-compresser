"""asyncssh connection pool and remote (Linux) operations: listing, du/df, ffprobe."""
from __future__ import annotations

import asyncio
import json
import posixpath
import stat
import time
from typing import Callable

import asyncssh

from ..config import ServerConfig
from .local import ProbeError, entry_obj
from .paths import PathError, check_remote, norm_remote, q, remote_join, remote_within
from .probe import PACKET_ENTRIES, PacketAggregator

SFTP_OPTS = {"path_encoding": "utf-8", "path_errors": "surrogateescape"}
RETRYABLE = (asyncssh.ConnectionLost, asyncssh.DisconnectError, asyncssh.ChannelOpenError,
             BrokenPipeError, ConnectionResetError, EOFError)


class RemoteError(Exception):
    pass


class RemoteServer:
    """One persistent SSH connection (plus a shared SFTP session) per server; auto-reconnects."""

    def __init__(self, cfg: ServerConfig):
        self.cfg = cfg
        self.name = cfg.name
        self._conn: asyncssh.SSHClientConnection | None = None
        self._sftp: asyncssh.SFTPClient | None = None
        self._lock = asyncio.Lock()
        self.home: str | None = None
        self.roots: list[str] = []      # absolute, symlink-resolved
        self.last_error: str | None = None
        self.extra_opts: dict = {}      # extra asyncssh.connect() options (used by tests)

    # ---------- connection ----------

    def _connected(self) -> bool:
        return self._conn is not None and not self._conn.is_closed()

    async def connect(self) -> asyncssh.SSHClientConnection:
        if self._connected():
            return self._conn  # type: ignore[return-value]
        async with self._lock:
            if self._connected():
                return self._conn  # type: ignore[return-value]
            await self._drop()
            opts: dict = {"keepalive_interval": 30, "connect_timeout": 15, "login_timeout": 30}
            if self.cfg.port:
                opts["port"] = self.cfg.port
            if self.cfg.user:
                opts["username"] = self.cfg.user
            if self.cfg.key_file:
                opts["client_keys"] = [self.cfg.key_file]
            opts.update(self.extra_opts)
            try:
                conn = await asyncssh.connect(self.cfg.host, **opts)
            except asyncssh.HostKeyNotVerifiable as e:
                self.last_error = f"host key not verifiable (add it with a manual `ssh` first): {e}"
                raise RemoteError(self.last_error) from e
            except asyncssh.PermissionDenied as e:
                self.last_error = f"authentication failed: {e}"
                raise RemoteError(self.last_error) from e
            except (OSError, asyncssh.Error, asyncio.TimeoutError) as e:
                self.last_error = f"connect failed: {e or type(e).__name__}"
                raise RemoteError(self.last_error) from e
            self._conn = conn
            try:
                r = await conn.run("printf %s \"$HOME\"", check=False, timeout=15)
                self.home = (r.stdout or "").strip() or None
                self._sftp = await conn.start_sftp_client(**SFTP_OPTS)
                self.roots = []
                for root in self.cfg.roots:
                    p = norm_remote(root, self.home)
                    try:
                        p = await self._sftp.realpath(p)
                    except (asyncssh.SFTPError, OSError):
                        pass  # root may not exist yet; keep the normalized path
                    self.roots.append(p)
            except Exception as e:
                await self._drop()
                self.last_error = f"session setup failed: {e}"
                raise RemoteError(self.last_error) from e
            self.last_error = None
            return conn

    async def _drop(self) -> None:
        if self._sftp is not None:
            try:
                self._sftp.exit()
            except Exception:
                pass
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass
        self._sftp = None
        self._conn = None

    async def close(self) -> None:
        async with self._lock:
            await self._drop()

    async def _retry(self, fn):
        """Run fn() once; on a dropped connection reconnect and retry once."""
        for attempt in (0, 1):
            await self.connect()
            try:
                return await fn()
            except RETRYABLE as e:
                async with self._lock:
                    await self._drop()
                if attempt:
                    raise RemoteError(f"connection lost: {e or type(e).__name__}") from e

    async def sftp(self) -> asyncssh.SFTPClient:
        await self.connect()
        return self._sftp  # type: ignore[return-value]

    async def new_sftp(self) -> asyncssh.SFTPClient:
        """Dedicated SFTP session (used per transfer so long copies don't block listings)."""
        async def go():
            return await self._conn.start_sftp_client(**SFTP_OPTS)  # type: ignore[union-attr]
        return await self._retry(go)

    async def run(self, cmd: str, timeout: float | None = 60, binary: bool = False) -> asyncssh.SSHCompletedProcess:
        async def go():
            kw = {"encoding": None} if binary else {"encoding": "utf-8", "errors": "replace"}
            return await self._conn.run(cmd, check=False, timeout=timeout, **kw)  # type: ignore[union-attr]
        try:
            return await self._retry(go)
        except asyncssh.TimeoutError as e:
            raise RemoteError(f"remote command timed out after {timeout}s") from e

    async def test(self) -> dict:
        t0 = time.perf_counter()
        try:
            await self.connect()
            t1 = time.perf_counter()
            r = await self.run("echo ok", timeout=15)
            t2 = time.perf_counter()
        except RemoteError as e:
            return {"ok": False, "error": str(e)}
        if r.exit_status != 0 or (r.stdout or "").strip() != "ok":
            return {"ok": False, "error": f"unexpected reply: {(r.stdout or '')[:100]!r} {(r.stderr or '')[:200]}"}
        return {"ok": True, "connect_ms": round((t1 - t0) * 1000, 1), "latency_ms": round((t2 - t1) * 1000, 1),
                "home": self.home, "roots": self.roots}

    # ---------- paths ----------

    async def check(self, path: str, resolve: bool = True) -> str:
        """Normalize, enforce roots, and (if it exists) verify the symlink-resolved target too."""
        await self.connect()
        p = check_remote(path, self.roots, self.home)
        if resolve:
            sftp = await self.sftp()
            try:
                real = await sftp.realpath(p)
            except (asyncssh.SFTPError, OSError):
                return p
            if not any(remote_within(real, r) for r in self.roots):
                raise PathError(f"path resolves outside configured roots: {p}")
        return p

    # ---------- listing ----------

    async def list_dir(self, path: str) -> list[dict]:
        async def go():
            sftp = self._sftp
            names = await sftp.readdir(path)
            out = []
            for n in names:
                if n.filename in (".", ".."):
                    continue
                a = n.attrs
                if a.permissions is not None and stat.S_ISLNK(a.permissions):
                    try:
                        a = await sftp.stat(remote_join(path, n.filename))
                    except (asyncssh.SFTPError, OSError):
                        continue  # dangling link
                is_dir = a.type == asyncssh.FILEXFER_TYPE_DIRECTORY or (
                    a.permissions is not None and stat.S_ISDIR(a.permissions))
                out.append(entry_obj(self.name, remote_join(path, n.filename), n.filename,
                                     is_dir, a.size, a.mtime))
            return out
        try:
            return await self._retry(go)
        except asyncssh.SFTPError as e:
            raise RemoteError(f"{path}: {e.reason}") from e

    async def stat_path(self, path: str) -> dict:
        async def go():
            return await self._sftp.stat(path)
        try:
            a = await self._retry(go)
        except asyncssh.SFTPNoSuchFile as e:
            raise FileNotFoundError(path) from e
        except asyncssh.SFTPError as e:
            raise RemoteError(f"{path}: {e.reason}") from e
        is_dir = a.type == asyncssh.FILEXFER_TYPE_DIRECTORY or (a.permissions is not None and stat.S_ISDIR(a.permissions))
        return entry_obj(self.name, path, posixpath.basename(path) or path, is_dir, a.size, a.mtime)

    async def exists(self, path: str) -> bool:
        async def go():
            return await self._sftp.exists(path)
        return await self._retry(go)

    async def remove(self, path: str) -> None:
        async def go():
            await self._sftp.remove(path)
        try:
            await self._retry(go)
        except asyncssh.SFTPNoSuchFile as e:
            raise FileNotFoundError(path) from e
        except asyncssh.SFTPError as e:
            raise RemoteError(f"{path}: {e.reason}") from e

    async def folder_stats(self, path: str) -> dict:
        p = q(path)
        r = await self.run(f"du -sb -- {p} 2>/dev/null | cut -f1; find {p} -type f 2>/dev/null | wc -l", timeout=600)
        lines = (r.stdout or "").split()
        try:
            return {"size": int(lines[0]), "files": int(lines[1])}
        except (IndexError, ValueError):
            raise RemoteError(f"du/find failed: {(r.stderr or r.stdout or '').strip()[:300]}")

    async def disk_free(self, path: str) -> int:
        r = await self.run(f"df -B1 --output=avail -- {q(path)} | tail -n 1", timeout=30)
        try:
            return int((r.stdout or "").strip())
        except ValueError:
            raise RemoteError(f"df failed: {(r.stderr or r.stdout or '').strip()[:300]}")

    async def walk_files(self, root: str) -> tuple[list[tuple[str, int, float]], list[str]]:
        """Recursive listing via one `find` call: ([(rel, size, mtime)], [rel dirs])."""
        cmd = (f"find {q(root)} -mindepth 1 \\( -type f -printf 'f %s %T@ %P\\0' \\) "
               f"-o \\( -type d -printf 'd 0 0 %P\\0' \\)")
        r = await self.run(cmd, timeout=600, binary=True)
        if r.exit_status != 0:
            raise RemoteError(f"find failed: {(r.stderr or b'').decode('utf-8', 'replace')[:300]}")
        files, dirs = [], []
        for rec in (r.stdout or b"").split(b"\0"):
            if not rec:
                continue
            kind, size, mtime, rel = rec.split(b" ", 3)
            rel_s = rel.decode("utf-8", "surrogateescape")
            if kind == b"f":
                files.append((rel_s, int(size), float(mtime)))
            else:
                dirs.append(rel_s)
        return files, dirs

    # ---------- ffprobe ----------

    def _ffprobe(self) -> str:
        fp = self.cfg.ffprobe
        if (fp == "~" or fp.startswith("~/")) and self.home:
            fp = self.home + fp[1:]
        return q(fp)

    async def ffprobe_json(self, path: str, timeout: float = 90) -> dict:
        r = await self.run(f"{self._ffprobe()} -v error -print_format json -show_format -show_streams -i {q(path)}",
                           timeout=timeout)
        if r.exit_status != 0:
            err = (r.stderr or "").strip()[-500:]
            if r.exit_status == 127:
                err = f"ffprobe not found on {self.name} ({self.cfg.ffprobe}): {err}"
            raise ProbeError(err or f"ffprobe exit {r.exit_status}")
        try:
            return json.loads(r.stdout or "")
        except json.JSONDecodeError as e:
            raise ProbeError(f"invalid ffprobe output: {e}")

    # Aggregates per stream: bytes, packets, first pts, max(pts + duration); progress in seconds via time bases.
    _SCAN_AWK = r"""'
BEGIN {
  nt = split(tbs, arr, ";");
  for (j = 1; j <= nt; j++) { split(arr[j], kv, "="); split(kv[2], fr, "/"); if (fr[2] + 0 > 0) tb[kv[1]] = fr[1] / fr[2] }
}
{ idx = ""; sz = ""; pts = ""; du = "";
  for (i = 1; i <= NF; i++) {
    eq = index($i, "="); if (!eq) continue;
    k = substr($i, 1, eq - 1); v = substr($i, eq + 1);
    if (k == "stream_index") idx = v;
    else if (k == "size") sz = v;
    else if (k == "pts") pts = v;
    else if (k == "duration") du = v;
  }
  if (idx != "" && sz != "") {
    b[idx] += sz; n[idx]++;
    if (pts != "" && pts != "N/A") {
      p = pts + 0; e = p;
      if (du != "" && du != "N/A" && du + 0 > 0) e = p + du;
      if (!(idx in f) || p < f[idx]) f[idx] = p;
      if (!(idx in en) || e > en[idx]) en[idx] = e;
      if ((idx in tb) && e * tb[idx] > mx) mx = e * tb[idx];
    }
  }
  if (NR % 50000 == 0) { printf "P %.3f\n", mx; fflush() }
}
END {
  for (i in b) {
    fs = (i in f) ? sprintf("%.0f", f[i]) : "NA"; es = (i in en) ? sprintf("%.0f", en[i]) : "NA";
    printf "S %s %.0f %d %s %s\n", i, b[i], n[i], fs, es;
  }
  print "E"
}'"""

    def _scan_script(self, path: str, time_bases: dict) -> str:
        tbs = ";".join(f"{i}={tb.numerator}/{tb.denominator}" for i, tb in sorted(time_bases.items()))
        script = (f"echo \"PID $$\"; {self._ffprobe()} -v error -show_entries {PACKET_ENTRIES} "
                  f"-of compact=p=0 -i {q(path)} | awk -F'|' -v tbs={q(tbs or 'none')} {self._SCAN_AWK}; "
                  f"echo \"RC ${{PIPESTATUS[0]}}\"")
        return "bash -c " + q(script)

    async def packet_scan(self, path: str, agg: PacketAggregator, cancel: asyncio.Event,
                          on_progress: Callable[[float], None]) -> None:
        """Remote packet scan; aggregation happens remotely in awk so only totals cross the wire."""
        await self.connect()
        proc = await self._conn.create_process(self._scan_script(path, agg.time_bases), encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        pid = None
        rc = None
        stderr_task = asyncio.create_task(proc.stderr.read())

        async def read_stdout():
            nonlocal pid, rc
            async for line in proc.stdout:
                parts = line.split()
                if not parts:
                    continue
                if parts[0] == "PID":
                    pid = parts[1]
                elif parts[0] == "P":
                    agg.position = float(parts[1])
                    on_progress(agg.position)
                elif parts[0] == "S" and len(parts) == 6:
                    i = int(parts[1])
                    agg.sizes[i] = int(parts[2])
                    agg.counts[i] = int(parts[3])
                    if parts[4] != "NA" and parts[5] != "NA":
                        agg.first_pts[i] = int(parts[4])
                        agg.end_pts[i] = int(parts[5])
                elif parts[0] == "RC":
                    rc = int(parts[1])

        reader = asyncio.create_task(read_stdout())
        canceller = asyncio.create_task(cancel.wait())
        try:
            done, _ = await asyncio.wait({reader, canceller}, return_when=asyncio.FIRST_COMPLETED)
            if canceller in done:
                # No pty, so closing the channel alone won't stop ffprobe: kill the shell's children.
                if pid and pid.isdigit():
                    try:
                        await self.run(f"pkill -TERM -P {pid}", timeout=15)
                    except RemoteError:
                        pass
                reader.cancel()
                stderr_task.cancel()
                proc.close()
                return
            try:
                await reader
            except RETRYABLE as e:
                raise RemoteError(f"connection lost during scan: {e or type(e).__name__}") from e
        except BaseException:
            stderr_task.cancel()
            proc.close()
            raise
        finally:
            canceller.cancel()
        try:
            err = await asyncio.wait_for(stderr_task, 5)
        except (asyncio.TimeoutError, asyncio.CancelledError, *RETRYABLE):
            err = ""
        proc.close()
        if rc != 0:
            raise ProbeError((err or "").strip()[-500:] or f"remote ffprobe exit {rc}")


class RemotePool:
    def __init__(self, servers: list[ServerConfig]):
        self.servers = {s.name: RemoteServer(s) for s in servers}

    def get(self, name: str) -> RemoteServer | None:
        return self.servers.get(name)

    async def close(self) -> None:
        await asyncio.gather(*(s.close() for s in self.servers.values()), return_exceptions=True)
