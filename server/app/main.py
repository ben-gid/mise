import time
from typing import Annotated

import httpx
from fastapi import FastAPI, HTTPException, Query, Request

from app import pexels

app = FastAPI(title="mise photos")

# Pexels searches a single caller may spend per hour. Only cache misses count —
# a hit costs Pexels nothing — so this caps what one IP can take out of the
# shared 200/hour, and a phone loading a library of mostly-cached dishes never
# feels it. A caller over it gets a 429, which the app reads as "no photos".
# ponytail: per-instance fixed window, so --max-instances N lets a caller have
# N times this; Cloud Armor or a shared counter if that ever matters.
LIMIT = 50
_windows: dict[str, tuple[float, int]] = {}


def _caller(request: Request) -> str:
    # Cloud Run appends the address it saw to X-Forwarded-For, after anything
    # the client sent itself — so only the last entry can't be forged. Behind a
    # load balancer that appends its own, this would need to be second-last.
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.rsplit(",", 1)[-1].strip()
    return request.client.host if request.client else ""


def _allow(caller: str) -> bool:
    now = time.monotonic()
    start, count = _windows.get(caller, (now, 0))
    if now - start >= 60 * 60:
        start, count = now, 0
    if count >= LIMIT:
        return False
    if len(_windows) >= 10_000:
        _windows.clear()
    _windows[caller] = (start, count + 1)
    return True


@app.get("/photos", tags=["photos"])
async def photos(
    request: Request, query: Annotated[str, Query(min_length=1, max_length=200)]
) -> list[str]:
    # 200 rather than image_query's 60: the picker falls back to a recipe title.
    if (hit := pexels.cached(query)) is not None:
        return hit
    if not _allow(_caller(request)):
        raise HTTPException(status_code=429, detail="Too many photo searches")
    try:
        return await pexels.search(query)
    except (pexels.PexelsError, httpx.HTTPError):
        raise HTTPException(status_code=502, detail="Photo search failed")
