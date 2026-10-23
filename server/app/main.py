import time
from typing import Annotated

import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response

from app import auth, pexels
from app.core.config import settings

app = FastAPI(title="mise api")

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
    if not settings.PEXELS_KEY.get_secret_value():
        raise HTTPException(status_code=503, detail="Photo search isn't set up")
    if (hit := pexels.cached(query)) is not None:
        return hit
    if not _allow(_caller(request)):
        raise HTTPException(status_code=429, detail="Too many photo searches")
    try:
        return await pexels.search(query)
    except (pexels.PexelsError, httpx.HTTPError):
        raise HTTPException(status_code=502, detail="Photo search failed")


User = Annotated[dict, Depends(auth.current_user)]


@app.get("/me", tags=["account"])
def me(user: User) -> dict:
    # Anonymous users are real users with a real id; the flag is what later
    # routes read to tell a free try from a linked account.
    return {"id": user["sub"], "anonymous": bool(user.get("is_anonymous"))}


@app.delete("/me", status_code=204, tags=["account"])
async def delete_me(user: User) -> Response:
    try:
        await auth.delete_user(user["sub"])
    except (auth.AdminError, httpx.HTTPError):
        raise HTTPException(status_code=502, detail="Couldn't delete the account")
    return Response(status_code=204)
