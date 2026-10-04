"""Location, listing, probe and detailed-scan endpoints."""
from __future__ import annotations

from fastapi import APIRouter, Request
from pydantic import BaseModel

from ..files.service import FileService
from ..files.stale import delete_stale_parts, find_stale_parts

router = APIRouter(prefix="/api")


def svc(request: Request) -> FileService:
    return request.app.state.files


class ScanRequest(BaseModel):
    location: str
    path: str


class PathRef(BaseModel):
    location: str
    path: str


@router.get("/status")
async def status(request: Request):
    return {"local_ffprobe": svc(request).local_ffprobe}


@router.post("/status/ffprobe")
async def recheck_ffprobe(request: Request):
    return {"local_ffprobe": await svc(request).check_local_ffprobe()}


@router.get("/stale-parts")
async def stale_parts(request: Request):
    return await find_stale_parts(svc(request), request.app.state.transfers.active_parts())


@router.delete("/stale-parts")
async def delete_stale(items: list[PathRef], request: Request):
    results = await delete_stale_parts(svc(request), request.app.state.transfers.active_parts(),
                                       [i.model_dump() for i in items])
    return {"results": results, "deleted": sum(r["ok"] for r in results)}


@router.get("/locations")
async def locations(request: Request):
    return svc(request).locations()


@router.post("/locations/{name}/test")
async def test_location(name: str, request: Request):
    files = svc(request)
    if files.is_local(name):
        return {"ok": True, "latency_ms": 0, "local": True}
    return await files.server(name).test()


@router.get("/list")
async def list_dir(location: str, request: Request, path: str = ""):
    return await svc(request).list(location, path)


@router.get("/probe")
async def probe(location: str, path: str, request: Request):
    return await svc(request).probe(location, path)


@router.get("/folderstats")
async def folder_stats(location: str, path: str, request: Request):
    return await svc(request).folder_stats(location, path)


@router.post("/scan")
async def start_scan(body: ScanRequest, request: Request):
    scan = await svc(request).start_scan(body.location, body.path)
    return {"scan_id": scan.id, **scan.to_dict()}


@router.get("/scan/{scan_id}")
async def get_scan(scan_id: str, request: Request):
    return svc(request).get_scan(scan_id).to_dict()


@router.delete("/scan/{scan_id}")
async def cancel_scan(scan_id: str, request: Request):
    return svc(request).cancel_scan(scan_id).to_dict()
