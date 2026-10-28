"""What a user has spent: free tries on `profiles`, every model call on `usage`.

Both written with the secret key, through PostgREST — no client may write
either table, so there is no policy for one to write through.

Whether a user is Pro is RevenueCat's to say, and it is asked, not told: only
once the free tries are gone, and then only when the `pro_until` it last
answered has passed. There is no webhook, so there is no event to miss — a
purchase, a Restore or a renewal is seen the next time a recipe is asked for.
The cost is that a refund keeps working until that expiry, one period at most."""

import logging
from datetime import datetime, timezone

import httpx

from app.core.config import settings

# Enough to try writing, adapting and importing, and still feel like a taste.
FREE_TRIES = 5

# Recipes a Pro user may have written per calendar month (UTC). At what a
# recipe costs on Haiku that is about a dollar, so it stops a script, not a cook.
PRO_MONTHLY = 201  # "200+ a month" on the paywall, and true
# The entitlement both subscriptions unlock, as set up in RevenueCat.
ENTITLEMENT = "pro"

_rest = httpx.AsyncClient(base_url=f"{settings.SUPABASE_URL}/rest/v1", timeout=10)
_revenuecat = httpx.AsyncClient(base_url="https://api.revenuecat.com/v1", timeout=10)
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
    left = max(0, FREE_TRIES - rows[0]["free_tries_used"])
    if left == 0 and await _pro_from_revenuecat(user_id):
        return None
    return left


async def _pro_from_revenuecat(user_id: str) -> bool:
    """Asks RevenueCat, and keeps an active entitlement's expiry in
    `pro_until` so the next request doesn't ask again. The phone logs in to
    RevenueCat with the Supabase user id, so the two ids are the same."""
    key = settings.REVENUECAT_SECRET_KEY.get_secret_value()
    if not key:
        return False
    response = await _revenuecat.get(
        f"/subscribers/{user_id}", headers={"Authorization": f"Bearer {key}"}
    )
    if response.is_error:
        # Raised, not False: a paying cook shown the paywall because RevenueCat
        # hiccuped is worse than a "try again".
        raise UsageError(f"revenuecat {response.status_code}")
    entitlement = response.json()["subscriber"]["entitlements"].get(ENTITLEMENT)
    expires = entitlement and entitlement.get("expires_date")
    # A null expiry is a lifetime grant; nothing sells one, so it isn't Pro here.
    if not expires or datetime.fromisoformat(expires) <= datetime.now(timezone.utc):
        return False
    response = await _rest.patch(
        "/profiles",
        params={"id": f"eq.{user_id}"},
        json={"pro_until": expires},
        headers=_secret(),
    )
    if response.is_error:
        log.error("Couldn't keep pro_until for %s: %s", user_id, response.status_code)
    return True


async def made_this_month(user_id: str) -> int:
    """Recipes this user has been given since the 1st (UTC), for [PRO_MONTHLY]."""
    start = datetime.now(timezone.utc).replace(
        day=1, hour=0, minute=0, second=0, microsecond=0
    )
    response = await _rest.head(
        "/usage",
        params={
            "user_id": f"eq.{user_id}",
            "ok": "is.true",
            "created_at": f"gte.{start.isoformat()}",
        },
        headers={**_secret(), "Prefer": "count=exact"},
    )
    if response.is_error:
        raise UsageError(f"usage {response.status_code}")
    # "0-24/57", or "*/0" when there are none.
    return int(response.headers["content-range"].rsplit("/", 1)[-1])


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
