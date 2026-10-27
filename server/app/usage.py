"""What a user has spent: free tries on `profiles`, every model call on `usage`.

Both written with the secret key, through PostgREST — no client may write
either table, so there is no policy for one to write through."""

import logging
from datetime import datetime, timezone

import httpx

from app.core.config import settings

# Enough to try writing, adapting and importing, and still feel like a taste.
FREE_TRIES = 5

_rest = httpx.AsyncClient(base_url=f"{settings.SUPABASE_URL}/rest/v1", timeout=10)
log = logging.getLogger(__name__)


def _secret() -> dict:
    # The secret key in `apikey` only, as in auth.py: it is not a JWT.
    return {"apikey": settings.SUPABASE_SECRET_KEY.get_secret_value()}


class UsageError(Exception):
    pass


async def tries_left(user_id: str) -> int | None:
    """Free tries this user has left, or None for a Pro user, who has no limit."""
    response = await _rest.get(
        "/profiles",
        params={"id": f"eq.{user_id}", "select": "pro_until,free_tries_used"},
        headers=_secret(),
    )
    if response.is_error:
        raise UsageError(f"profiles {response.status_code}")
    rows = response.json()
    if not rows:
        # The trigger makes one with the user, so this is a user deleted since
        # their token was issued.
        return 0
    pro_until = rows[0]["pro_until"]
    if pro_until and datetime.fromisoformat(pro_until) > datetime.now(timezone.utc):
        return None
    return max(0, FREE_TRIES - rows[0]["free_tries_used"])


async def spend_try(user_id: str, left: int) -> None:
    """Counts one free try, after a recipe that passed. Logged rather than
    raised: the recipe is already written, and the cook has waited for it."""
    # ponytail: read-then-write, so two requests at once can both spend the
    # same try; an rpc doing `free_tries_used + 1` if anyone ever bothers.
    response = await _rest.patch(
        "/profiles",
        params={"id": f"eq.{user_id}"},
        json={"free_tries_used": FREE_TRIES - left + 1},
        headers=_secret(),
    )
    if response.is_error:
        log.error("Couldn't spend a try for %s: %s", user_id, response.status_code)


async def record(
    user_id: str, kind: str, tokens: tuple[int, int], cost_usd: float, ok: bool
) -> None:
    """One row per call that reached the model, failed or not. Logged rather
    than raised, like [spend_try]."""
    response = await _rest.post(
        "/usage",
        json={
            "user_id": user_id,
            "kind": kind,
            "input_tokens": tokens[0],
            "output_tokens": tokens[1],
            "cost_usd": round(cost_usd, 6),
            "ok": ok,
        },
        headers={**_secret(), "Prefer": "return=minimal"},
    )
    if response.is_error:
        log.error("Couldn't record usage for %s: %s", user_id, response.status_code)
