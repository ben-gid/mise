"""Pexels search, with the key held here rather than compiled into the app."""

import time

import httpx

from app.core.config import settings

DAY = 24 * 60 * 60

# One entry per distinct query, shared by every phone that hits this instance —
# which is what stretches the 200/hour free tier across a whole user base.
# ponytail: per-instance and cleared wholesale when full; a shared store
# (Memorystore) if instances multiply enough that each warms its own cold.
_cache: dict[str, tuple[float, list[str]]] = {}
_CACHE_MAX = 10_000

_client = httpx.AsyncClient(base_url="https://api.pexels.com/v1", timeout=10)


class PexelsError(Exception):
    pass


def _key(query: str) -> str:
    return query.strip().lower()


def cached(query: str) -> list[str] | None:
    """The day-old-or-younger answer for [query], or None if it would cost a
    call to Pexels. Separate from [search] so the rate limit can charge a caller
    for misses only."""
    hit = _cache.get(_key(query))
    if hit and time.monotonic() - hit[0] < DAY:
        return hit[1]
    return None


async def search(query: str) -> list[str]:
    """Asks Pexels for image urls, best first, and caches them. Check [cached]
    first. Raises on any upstream failure, so a 429 or an outage is never cached
    as "no photos"."""
    response = await _client.get(
        "/search",
        params={
            "query": query,
            # One page serves both the hero and the picker's three-by-three grid.
            "per_page": 9,
            # A hero is a wide band and a list tile is a square; a portrait shot
            # crops to the middle of its subject in both.
            "orientation": "landscape",
        },
        # Pexels takes the bare key — no 'Bearer'.
        headers={"Authorization": settings.PEXELS_KEY.get_secret_value()},
    )
    if response.status_code != httpx.codes.OK:
        raise PexelsError(response.status_code)

    photos = [
        # 'large' is 940px. Not the larger rendition: the picker's tile and the
        # hero then share one cache entry on the phone.
        url
        for photo in response.json().get("photos", [])
        if isinstance(url := photo.get("src", {}).get("large"), str)
    ]
    if len(_cache) >= _CACHE_MAX:
        _cache.clear()
    _cache[_key(query)] = (time.monotonic(), photos)
    return photos
