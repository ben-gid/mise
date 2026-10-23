"""Who is calling: a Supabase access token, checked against the project's own
public keys, and the one admin call the app needs."""

from typing import Annotated

import httpx
import jwt
from fastapi import Header, HTTPException

from app.core.config import settings

_issuer = f"{settings.SUPABASE_URL}/auth/v1"

# The project's public signing keys, cached. An unknown key id refetches, so a
# key rotation costs one request rather than an outage — and verifying needs
# no call to Supabase at all otherwise.
_keys = jwt.PyJWKClient(f"{_issuer}/.well-known/jwks.json", cache_keys=True)

_admin = httpx.AsyncClient(base_url=f"{_issuer}/admin", timeout=10)
_storage = httpx.AsyncClient(
    base_url=f"{settings.SUPABASE_URL}/storage/v1", timeout=10
)


class AdminError(Exception):
    pass


def current_user(
    authorization: Annotated[str | None, Header()] = None,
) -> dict:
    """The verified claims of the caller's access token, or a 401.

    A plain `def` so FastAPI runs it in the threadpool: the first call, and any
    after a key rotation, fetches the key set synchronously.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Sign-in required")
    token = authorization.removeprefix("Bearer ")
    try:
        key = _keys.get_signing_key_from_jwt(token).key
        return jwt.decode(
            token,
            key,
            algorithms=["ES256", "RS256"],
            audience="authenticated",
            issuer=_issuer,
        )
    except jwt.PyJWKClientConnectionError:
        # Supabase unreachable is not the caller's fault; a 401 would read as
        # "sign in again" to the app.
        raise HTTPException(status_code=503, detail="Can't check sign-in")
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="Invalid sign-in")


def _secret() -> dict:
    # The secret key in `apikey` only: it is not a JWT, so it doesn't go in
    # Authorization.
    return {"apikey": settings.SUPABASE_SECRET_KEY.get_secret_value()}


async def delete_user(user_id: str) -> None:
    """Deletes the user outright, photos first.

    Their profile and synced rows go with the user by cascade; storage objects
    don't, so the photos folder is emptied before — a failure there keeps the
    account rather than orphaning its photos.
    """
    while True:
        listed = await _storage.post(
            "/object/list/photos",
            headers=_secret(),
            json={"prefix": user_id, "limit": 1000, "offset": 0},
        )
        if listed.is_error:
            raise AdminError(f"storage list {listed.status_code}")
        names = [f"{user_id}/{item['name']}" for item in listed.json()]
        if not names:
            break
        removed = await _storage.request(
            "DELETE", "/object/photos", headers=_secret(), json={"prefixes": names}
        )
        if removed.is_error:
            raise AdminError(f"storage delete {removed.status_code}")
    response = await _admin.delete(f"/users/{user_id}", headers=_secret())
    if response.is_error:
        raise AdminError(f"admin API {response.status_code}")
