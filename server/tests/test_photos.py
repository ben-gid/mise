from types import SimpleNamespace

import httpx
from pydantic import SecretStr
import pytest
from fastapi.testclient import TestClient

from app import main, unsplash
from app.main import app

client = TestClient(app)


@pytest.fixture
def upstream(monkeypatch):
    """Stands in for api.unsplash.com: answers with `status`, records `requests`."""
    fake = SimpleNamespace(requests=[], status=200)

    def handler(request: httpx.Request) -> httpx.Response:
        fake.requests.append(request)
        user = {"name": "Jane Doe", "username": "janedoe"}
        body = {
            "results": [
                {
                    "id": "a1",
                    "urls": {"regular": "https://images.unsplash.com/1"},
                    "user": user,
                    "links": {"download_location": "https://api.unsplash.com/photos/a1/download?ixid=M3wx"},
                },
                # No credit to give is no photo to show: Unsplash's terms ask for one.
                {"id": "b2", "urls": {"regular": "https://images.unsplash.com/x"}, "user": {}},
                {"id": "c3", "urls": {}, "user": user},
                {"id": "d4", "urls": {"regular": "https://images.unsplash.com/2"}, "user": user},
            ]
        }
        return httpx.Response(fake.status, json=body)

    monkeypatch.setattr(unsplash, "_cache", {})
    monkeypatch.setattr(main, "_windows", {})
    monkeypatch.setattr(
        unsplash,
        "_client",
        httpx.AsyncClient(
            base_url="https://api.unsplash.com", transport=httpx.MockTransport(handler)
        ),
    )
    return fake


def test_returns_credited_photos_and_sends_the_key(upstream):
    response = client.get("/photos", params={"query": "creamy mushroom pasta"})
    assert response.status_code == 200
    link = "https://unsplash.com/@janedoe?utm_source=mise&utm_medium=referral"
    assert response.json() == [
        {"url": "https://images.unsplash.com/1", "id": "a1", "ixid": "M3wx", "name": "Jane Doe", "link": link},
        {"url": "https://images.unsplash.com/2", "id": "d4", "ixid": "", "name": "Jane Doe", "link": link},
    ]
    assert upstream.requests[0].headers["Authorization"] == "Client-ID test-key"
    assert upstream.requests[0].url.params["query"] == "creamy mushroom pasta"


def test_a_kept_photo_is_reported_to_unsplash(upstream):
    response = client.post("/photos/used", json={"id": "a1", "ixid": "M3wx"})
    assert response.status_code == 204
    # The ixid goes back too: Unsplash's guidelines ask for download_location
    # with its query parameters.
    assert upstream.requests[0].url.path == "/photos/a1/download"
    assert upstream.requests[0].url.params["ixid"] == "M3wx"
    assert upstream.requests[0].headers["Authorization"] == "Client-ID test-key"


def test_a_used_photo_id_cannot_steer_the_request(upstream):
    # The key goes on whatever url this builds, so an id can't be a path.
    assert client.post("/photos/used", json={"id": "../me"}).status_code == 422
    assert client.post("/photos/used", json={"id": "a1", "ixid": "x&client_id=y"}).status_code == 422
    assert upstream.requests == []


def test_a_repeat_query_is_served_from_cache(upstream):
    client.get("/photos", params={"query": "Focaccia"})
    client.get("/photos", params={"query": " focaccia "})
    assert len(upstream.requests) == 1


def test_an_upstream_failure_is_a_502_and_not_cached(upstream):
    upstream.status = 429
    assert client.get("/photos", params={"query": "ramen"}).status_code == 502
    upstream.status = 200
    assert client.get("/photos", params={"query": "ramen"}).status_code == 200
    assert len(upstream.requests) == 2


def test_a_caller_over_the_limit_gets_429_but_still_gets_cache_hits(upstream, monkeypatch):
    monkeypatch.setattr(main, "LIMIT", 2)
    assert client.get("/photos", params={"query": "ramen"}).status_code == 200
    assert client.get("/photos", params={"query": "pho"}).status_code == 200
    assert client.get("/photos", params={"query": "udon"}).status_code == 429
    assert client.get("/photos", params={"query": "ramen"}).status_code == 200
    assert len(upstream.requests) == 2


def test_a_forged_forwarded_for_does_not_buy_a_fresh_limit(upstream, monkeypatch):
    monkeypatch.setattr(main, "LIMIT", 1)

    def ask(query: str, forged: str) -> int:
        headers = {"X-Forwarded-For": f"{forged}, 203.0.113.7"}
        return client.get("/photos", params={"query": query}, headers=headers).status_code

    assert ask("ramen", "1.1.1.1") == 200
    assert ask("pho", "2.2.2.2") == 429


def test_no_unsplash_key_is_a_503_without_calling_upstream(upstream, monkeypatch):
    # Without a key the server still deploys and serves accounts, and the app
    # reads the 503 as "no photos" and falls through to Wikipedia.
    monkeypatch.setattr(main.settings, "UNSPLASH_ACCESS_KEY", SecretStr(""))
    assert client.get("/photos", params={"query": "ramen"}).status_code == 503
    assert upstream.requests == []
