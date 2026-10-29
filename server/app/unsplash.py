"""Unsplash search, with the key held here rather than compiled into the app."""

import time
from urllib.parse import parse_qs, urlparse

import httpx

from app.core.config import settings

DAY = 24 * 60 * 60

# One entry per distinct query, shared by every phone that hits this instance —
# which is what stretches the hourly quota across a whole user base.
# ponytail: per-instance and cleared wholesale when full; a shared store
# (Memorystore) if instances multiply enough that each warms its own cold.
_cache: dict[str, tuple[float, list[dict]]] = {}
_CACHE_MAX = 10_000

_client = httpx.AsyncClient(base_url="https://api.unsplash.com", timeout=10)

# Unsplash asks for these on every link back to it, so it can see where its
# photographers' traffic comes from.
_REFERRAL = "utm_source=mise&utm_medium=referral"


class UnsplashError(Exception):
    pass


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Client-ID {settings.UNSPLASH_ACCESS_KEY.get_secret_value()}",
        "Accept-Version": "v1",
    }


def _key(query: str) -> str:
    return query.strip().lower()


def cached(query: str) -> list[dict] | None:
    """The day-old-or-younger answer for [query], or None if it would cost a
    call to Unsplash. Separate from [search] so the rate limit can charge a
    caller for misses only."""
    hit = _cache.get(_key(query))
    if hit and time.monotonic() - hit[0] < DAY:
        return hit[1]
    return None


def _photo(result: dict) -> dict | None:
    user = result.get("user") or {}
    url = (result.get("urls") or {}).get("regular")
    if not all(isinstance(v, str) and v for v in (url, result.get("id"), user.get("name"), user.get("username"))):
        return None
    return {
        # 'regular' is 1080px wide, enough for a hero on a phone; the picker's
        # tile and the hero then share one cache entry on the phone. Kept
        # whole: Unsplash wants its ixid query parameter left on.
        "url": url,
        # For [downloaded], which Unsplash asks for when a photo is kept: the
        # id and the ixid off its download_location, which Unsplash wants sent
        # back. Not the location itself, so the phone never names a url the
        # server will call with its key.
        "id": result["id"],
        "ixid": _ixid(result),
        # The credit, as Unsplash wants it: the photographer by name, linking
        # to their profile. The phone shows it and never builds the link.
        "name": user["name"],
        "link": f"https://unsplash.com/@{user['username']}?{_REFERRAL}",
    }


def _ixid(result: dict) -> str:
    location = (result.get("links") or {}).get("download_location") or ""
    return parse_qs(urlparse(location).query).get("ixid", [""])[0]


async def search(query: str) -> list[dict]:
    """Asks Unsplash for photos, best first, and caches them. Check [cached]
    first. Raises on any upstream failure, so a 429 or an outage is never cached
    as "no photos"."""
    response = await _client.get(
        "/search/photos",
        params={
            "query": query,
            # One page serves both the hero and the picker's three-by-three grid.
            "per_page": 9,
            # A hero is a wide band and a list tile is a square; a portrait shot
            # crops to the middle of its subject in both.
            "orientation": "landscape",
            "content_filter": "high",
        },
        headers=_headers(),
    )
    if response.status_code != httpx.codes.OK:
        raise UnsplashError(response.status_code)

    photos = [p for r in response.json().get("results", []) if (p := _photo(r))]
    if len(_cache) >= _CACHE_MAX:
        _cache.clear()
    _cache[_key(query)] = (time.monotonic(), photos)
    return photos


async def downloaded(photo_id: str, ixid: str) -> None:
    """Tells Unsplash a photo was kept — its guidelines' "download", which is
    what credits the photographer. Not called for merely showing one."""
    response = await _client.get(
        f"/photos/{photo_id}/download",
        params={"ixid": ixid} if ixid else None,
        headers=_headers(),
    )
    if response.status_code != httpx.codes.OK:
        raise UnsplashError(response.status_code)
