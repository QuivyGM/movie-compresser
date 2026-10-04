"""FastAPI app: routers, static UI, error mapping. Run with `python -m app.main`."""
from __future__ import annotations

import asyncio
import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .api import files as files_api
from .api import transfers as transfers_api
from .config import AppConfig, ConfigError, load_config
from .files.local import ProbeError
from .files.paths import PathError
from .files.remote import RemoteError, RemotePool
from .files.service import FileService, NotFound
from .files.stale import find_stale_parts
from .files.transfer import ConflictError, TransferError, TransferManager

STATIC = Path(__file__).parent / "static"
log = logging.getLogger("app")


def create_app(cfg: AppConfig, pool: RemotePool | None = None, check_stale_on_startup: bool = True) -> FastAPI:
    pool = pool or RemotePool(cfg.servers)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.cfg = cfg
        app.state.pool = pool
        app.state.files = FileService(cfg, pool)
        app.state.transfers = TransferManager(cfg, app.state.files)
        ff = await app.state.files.check_local_ffprobe()
        if ff["ok"]:
            log.info("local ffprobe: %s (%s)", ff["path"], ff["version"])
        else:
            log.error("local ffprobe unavailable: %s", ff["error"])
        stale_task = asyncio.create_task(_log_stale_parts(app)) if check_stale_on_startup else None
        yield
        if stale_task:
            stale_task.cancel()
        await app.state.transfers.shutdown()
        await app.state.files.shutdown()
        await pool.close()

    app = FastAPI(title="Movie Compressor — Files", lifespan=lifespan)
    # Reject requests with foreign Host headers (DNS-rebinding protection for a localhost app).
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "testserver"])

    def err(status: int):
        async def handler(_req: Request, exc: Exception):
            return JSONResponse({"error": str(exc) or type(exc).__name__}, status_code=status)
        return handler

    app.add_exception_handler(PathError, err(403))
    app.add_exception_handler(NotFound, err(404))
    app.add_exception_handler(FileNotFoundError, err(404))
    app.add_exception_handler(NotADirectoryError, err(400))
    app.add_exception_handler(PermissionError, err(403))
    app.add_exception_handler(TransferError, err(400))
    app.add_exception_handler(ProbeError, err(422))
    app.add_exception_handler(RemoteError, err(502))
    app.add_exception_handler(OSError, err(500))

    @app.exception_handler(ConflictError)
    async def conflict(_req: Request, exc: ConflictError):
        return JSONResponse({"error": str(exc), "conflict": True, "dst_path": exc.dst_path,
                             "dst_type": exc.dst_type, "suggested_name": exc.suggested_name}, status_code=409)

    app.include_router(files_api.router)
    app.include_router(transfers_api.router)
    app.mount("/static", StaticFiles(directory=STATIC), name="static")

    @app.get("/", include_in_schema=False)
    async def index():
        return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-cache"})

    return app


async def _log_stale_parts(app: FastAPI) -> None:
    """Startup check: log leftover .part files (the UI shows and deletes them; nothing is auto-deleted)."""
    try:
        r = await find_stale_parts(app.state.files, app.state.transfers.active_parts())
    except Exception as e:  # noqa: BLE001 - informational only
        log.warning("stale .part check failed: %s", e)
        return
    for sk in r["skipped"]:
        log.warning("stale .part check skipped %s: %s", sk["location"], sk["error"])
    if r["items"]:
        log.warning("%d stale .part file(s) found; review them in the UI (Check for stale files)", len(r["items"]))


def main() -> None:
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        cfg = load_config()
    except ConfigError as e:
        print(f"Config error: {e}", file=sys.stderr)
        sys.exit(2)
    print(f"Serving on http://127.0.0.1:{cfg.port}")
    uvicorn.run(create_app(cfg), host="127.0.0.1", port=cfg.port, log_level="info")


if __name__ == "__main__":
    main()
