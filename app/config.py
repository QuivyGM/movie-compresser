"""Load and validate config.toml."""
from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

LOCAL_NAME = "Local"


class ConfigError(Exception):
    pass


@dataclass
class LocalConfig:
    ffprobe: str
    roots: list[str]
    temp_dir: str


@dataclass
class ServerConfig:
    name: str
    host: str
    port: int | None = None        # None -> ~/.ssh/config or 22
    user: str | None = None        # None -> ~/.ssh/config or local user
    key_file: str | None = None    # None -> ssh-agent / default keys
    ffprobe: str = "ffprobe"
    roots: list[str] = field(default_factory=list)


@dataclass
class AppConfig:
    local: LocalConfig
    servers: list[ServerConfig]
    host: str = "127.0.0.1"
    port: int = 5000
    max_transfers: int = 2
    probe_concurrency: int = 4

    def server(self, name: str) -> ServerConfig | None:
        return next((s for s in self.servers if s.name == name), None)


def _norm_local(p: str) -> str:
    return os.path.abspath(os.path.expanduser(p)).replace("\\", "/")


def _require(d: dict, key: str, where: str):
    if key not in d or d[key] in (None, ""):
        raise ConfigError(f"{where}: missing '{key}'")
    return d[key]


def parse_config(data: dict) -> AppConfig:
    loc = data.get("local")
    if not isinstance(loc, dict):
        raise ConfigError("missing [local] section")
    roots = _require(loc, "roots", "[local]")
    if not isinstance(roots, list) or not roots:
        raise ConfigError("[local]: 'roots' must be a non-empty list")
    local = LocalConfig(
        ffprobe=loc.get("ffprobe", "ffprobe"),
        roots=[_norm_local(r) for r in roots],
        temp_dir=_norm_local(_require(loc, "temp_dir", "[local]")),
    )

    servers: list[ServerConfig] = []
    seen = {LOCAL_NAME.lower()}
    for i, s in enumerate(data.get("servers", [])):
        where = f"[[servers]] #{i + 1}"
        name = str(_require(s, "name", where))
        if name.lower() in seen:
            raise ConfigError(f"{where}: duplicate or reserved name '{name}'")
        seen.add(name.lower())
        sroots = _require(s, "roots", f"server '{name}'")
        if not isinstance(sroots, list) or not sroots:
            raise ConfigError(f"server '{name}': 'roots' must be a non-empty list")
        for r in sroots:
            if not (r.startswith("/") or r == "~" or r.startswith("~/")):
                raise ConfigError(f"server '{name}': root '{r}' must be absolute or start with ~/")
        port = s.get("port")
        servers.append(ServerConfig(
            name=name,
            host=str(_require(s, "host", f"server '{name}'")),
            port=int(port) if port else None,
            user=s.get("user") or None,
            key_file=os.path.expanduser(s["key_file"]) if s.get("key_file") else None,
            ffprobe=s.get("ffprobe", "ffprobe"),
            roots=[r.rstrip("/") or "/" for r in sroots],
        ))

    app = data.get("app", {})
    return AppConfig(
        local=local,
        servers=servers,
        host="127.0.0.1",  # never bind elsewhere
        port=int(app.get("port", 5000)),
        max_transfers=max(1, int(app.get("max_transfers", 2))),
        probe_concurrency=max(1, int(app.get("probe_concurrency", 4))),
    )


def load_config(path: str | os.PathLike | None = None) -> AppConfig:
    path = Path(path or os.environ.get("MC_CONFIG", "config.toml"))
    if not path.exists():
        raise ConfigError(f"config file not found: {path.resolve()} (copy config.example.toml)")
    with open(path, "rb") as f:
        try:
            data = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            raise ConfigError(f"{path}: {e}") from e
    return parse_config(data)
