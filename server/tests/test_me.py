import json
import time
from types import SimpleNamespace

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import auth
from app.core.config import settings
from app.main import app

client = TestClient(app)
ISSUER = f"{settings.SUPABASE_URL}/auth/v1"

# Stands in for the project's ES256 signing key; the public half is what the
# JWKS endpoint would serve.
_signing = ec.generate_private_key(ec.SECP256R1())
_stranger = ec.generate_private_key(ec.SECP256R1())


def token(*, key=_signing, **claims) -> str:
    body = {
        "sub": "user-1",
        "aud": "authenticated",
        "iss": ISSUER,
        "exp": int(time.time()) + 3600,
        "is_anonymous": True,
        **claims,
    }
    return jwt.encode(body, key, algorithm="ES256")


def bearer(value: str) -> dict:
    return {"Authorization": f"Bearer {value}"}


@pytest.fixture(autouse=True)
def keys(monkeypatch):
    """The JWKS lookup, answered locally with the test key's public half."""
    fake = SimpleNamespace(
        get_signing_key_from_jwt=lambda _: SimpleNamespace(key=_signing.public_key())
    )
    monkeypatch.setattr(auth, "_keys", fake)


@pytest.fixture
def admin(monkeypatch):
    """Stands in for Supabase's admin API: answers with `status`, records `requests`."""
    fake = SimpleNamespace(requests=[], status=200)

    def handler(request: httpx.Request) -> httpx.Response:
        fake.requests.append(request)
        return httpx.Response(fake.status, json={})

    monkeypatch.setattr(
        auth,
        "_admin",
        httpx.AsyncClient(
            base_url=f"{ISSUER}/admin", transport=httpx.MockTransport(handler)
        ),
    )
    return fake


@pytest.fixture
def storage(monkeypatch):
    """Stands in for Supabase Storage: `photos` are listed once, then the folder
    reads empty; `status` fails every call."""
    fake = SimpleNamespace(requests=[], photos=["1.jpg", "2.png"], status=200)

    def handler(request: httpx.Request) -> httpx.Response:
        fake.requests.append(request)
        if fake.status != 200:
            return httpx.Response(fake.status, json={})
        if request.url.path.endswith("/object/list/photos"):
            listed, fake.photos = fake.photos, []
            return httpx.Response(200, json=[{"name": n} for n in listed])
        return httpx.Response(200, json=[])

    monkeypatch.setattr(
        auth,
        "_storage",
        httpx.AsyncClient(
            base_url=f"{settings.SUPABASE_URL}/storage/v1",
            transport=httpx.MockTransport(handler),
        ),
    )
    return fake


def test_a_valid_token_names_its_user():
    response = client.get("/me", headers=bearer(token()))
    assert response.status_code == 200
    assert response.json() == {"id": "user-1", "anonymous": True}


def test_a_linked_user_is_not_anonymous():
    response = client.get("/me", headers=bearer(token(is_anonymous=False)))
    assert response.json()["anonymous"] is False


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Basic abc"},
        bearer("not-a-jwt"),
        bearer(token(exp=int(time.time()) - 10)),
        bearer(token(aud="anon")),
        bearer(token(iss="https://someone-else.supabase.co/auth/v1")),
        bearer(token(key=_stranger)),
    ],
    ids=["missing", "not bearer", "garbage", "expired", "audience", "issuer", "signature"],
)
def test_anything_but_a_valid_token_is_401(headers):
    assert client.get("/me", headers=headers).status_code == 401


def test_deleting_the_account_deletes_that_user_with_the_secret_key(admin, storage):
    response = client.delete("/me", headers=bearer(token()))
    assert response.status_code == 204
    request = admin.requests[0]
    assert request.method == "DELETE"
    assert request.url.path == "/auth/v1/admin/users/user-1"
    assert request.headers["apikey"] == settings.SUPABASE_SECRET_KEY.get_secret_value()


def test_deleting_needs_a_valid_token(admin):
    assert client.delete("/me", headers=bearer(token(key=_stranger))).status_code == 401
    assert admin.requests == []


def test_deleting_the_account_empties_its_photo_folder_first(admin, storage):
    assert client.delete("/me", headers=bearer(token())).status_code == 204
    removed = [r for r in storage.requests if r.method == "DELETE"]
    assert len(removed) == 1
    assert json.loads(removed[0].content) == {"prefixes": ["user-1/1.jpg", "user-1/2.png"]}
    assert json.loads(storage.requests[0].content)["prefix"] == "user-1"
    assert removed[0].headers["apikey"] == settings.SUPABASE_SECRET_KEY.get_secret_value()
    assert len(admin.requests) == 1


def test_a_storage_failure_keeps_the_account(admin, storage):
    storage.status = 500
    assert client.delete("/me", headers=bearer(token())).status_code == 502
    assert admin.requests == []


def test_an_admin_api_failure_is_a_502(admin, storage):
    admin.status = 500
    assert client.delete("/me", headers=bearer(token())).status_code == 502


def test_photos_still_need_no_token():
    # The query is answered from cache or upstream; either way it isn't a 401.
    assert client.get("/photos", params={"query": "x"}).status_code != 401
