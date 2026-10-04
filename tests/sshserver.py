"""In-process asyncssh server used by the remote/transfer tests.

SFTP is served from a chroot directory. Exec requests are run through bash (Git Bash on Windows)
with the fake home "/home/u" rewritten to the chroot path, so the app's real remote commands
(du, find, ffprobe | awk) are executed, not mocked.

Exception: the free-space pipeline (`df -B1 --output=avail -- PATH | tail -n 1`) is answered with
shutil.disk_usage. Git Bash's df enumerates every Windows drive mapping and can stall ~21 s on an
unreachable network drive, which made tests slow and flaky; GNU df on Linux has no such issue.
"""
from __future__ import annotations

import asyncio
import os
import re
import shlex
import shutil
from dataclasses import dataclass
from pathlib import Path

import asyncssh

FAKE_HOME = "/home/u"
DF_RE = re.compile(r"^df -B1 --output=avail -- (.+) \| tail -n 1$")


def find_bash() -> str | None:
    for cand in (r"C:\Program Files\Git\bin\bash.exe", shutil.which("bash")):
        if cand and os.path.exists(cand) and "System32" not in cand:  # skip WSL's bash.exe
            return cand
    return None


@dataclass
class TestServer:
    server: asyncssh.SSHAcceptor
    port: int
    root: Path            # chroot directory
    client_key: asyncssh.SSHKey

    @property
    def home(self) -> Path:
        return self.root / "home" / "u"

    def client_opts(self) -> dict:
        return {"known_hosts": None, "client_keys": [self.client_key], "config": [], "agent_path": None,
                "username": "u"}


async def start_server(root: Path, bash: str) -> TestServer:
    host_key = asyncssh.generate_private_key("ssh-ed25519")
    client_key = asyncssh.generate_private_key("ssh-ed25519")
    authorized = asyncssh.import_authorized_keys(client_key.export_public_key().decode())
    (root / "home" / "u").mkdir(parents=True, exist_ok=True)
    prefix = str(root).replace("\\", "/")

    async def handle(process: asyncssh.SSHServerProcess) -> None:
        cmd = process.command or ""
        mapped = cmd.replace(FAKE_HOME, prefix + FAKE_HOME)
        m = DF_RE.match(mapped)
        if m:
            try:
                free = shutil.disk_usage(shlex.split(m.group(1))[0]).free
                process.stdout.write(f"{free}\n".encode())
                process.exit(0)
            except OSError as e:
                process.stderr.write(f"df: {e}\n".encode())
                process.exit(1)
            return
        env = dict(os.environ, HOME=FAKE_HOME, MSYS_NO_PATHCONV="1")
        proc = await asyncio.create_subprocess_exec(bash, "-c", mapped, stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.PIPE, env=env)

        async def pump(src, dst):
            while chunk := await src.read(65536):
                dst.write(chunk)

        try:
            await asyncio.gather(pump(proc.stdout, process.stdout), pump(proc.stderr, process.stderr))
            rc = await proc.wait()
        except Exception:
            if proc.returncode is None:
                proc.kill()
            rc = 1
        try:
            process.exit(rc)
        except Exception:
            pass

    server = await asyncssh.create_server(
        asyncssh.SSHServer, "127.0.0.1", 0,
        server_host_keys=[host_key], authorized_client_keys=authorized,
        sftp_factory=lambda chan: asyncssh.SFTPServer(chan, chroot=str(root).encode()),
        process_factory=handle, encoding=None, allow_scp=False)
    port = server.sockets[0].getsockname()[1]
    return TestServer(server=server, port=port, root=root, client_key=client_key)
