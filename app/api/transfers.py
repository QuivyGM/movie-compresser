"""Transfer endpoints."""
from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Request
from pydantic import BaseModel

from ..files.transfer import TransferManager

router = APIRouter(prefix="/api")


def mgr(request: Request) -> TransferManager:
    return request.app.state.transfers


class TransferRequest(BaseModel):
    src_location: str
    src_path: str
    dst_location: str
    dst_dir: str
    on_conflict: Literal["overwrite", "skip", "rename"] | None = None


@router.post("/transfers")
async def create_transfer(body: TransferRequest, request: Request):
    t = await mgr(request).create(body.src_location, body.src_path, body.dst_location, body.dst_dir,
                                  body.on_conflict)
    if t is None:
        return {"skipped": True}
    return t.to_dict()


@router.get("/transfers")
async def list_transfers(request: Request):
    return mgr(request).list()


@router.delete("/transfers/{tid}")
async def cancel_transfer(tid: str, request: Request):
    return mgr(request).cancel(tid).to_dict()
