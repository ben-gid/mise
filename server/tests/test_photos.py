from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from app import main, pexels
from app.main import app

client = TestClient(app)


@pytest.fixture
def upstream(monkeypatch):
    """Stands in for api.pexels.com: answers with `status`, records `requests`."""
    fake = SimpleNamespace(requests=[], status=200)

    def handler(request: httpx.Request) -> httpx.Response:
        fake.requests.append(request)
        body = {
            "photos": [
                {"src": {"large": "https://images.pexels.com/1.jpeg"}},
                {"src": {}},
                {"src": {"large": "https://images.pexels.com/2.jpeg"}},
            ]
        }
        return httpx.Response(fake.status, json=body)

    monkeypatch.setattr(pexels, "_cache", {})
    monkeypatch.setattr(main, "_windows", {})
    monkeypatch.setattr(
        pexels,
        "_client",
        httpx.AsyncClient(
            base_url="https://api.pexels.com/v1", transport=httpx.MockTransport(handler)
        ),
    )
    return fake


def test_returns_urls_and_sends_the_key(upstream):
    response = client.get("/photos", params={"query": "creamy mushroom pasta"})
    assert response.status_code == 200
    assert response.json() == [
        "https://images.pexels.com/1.jpeg",
        "https://images.pexels.com/2.jpeg",
    ]
    assert upstream.requests[0].headers["Authorization"] == "test-key"
    assert upstream.requests[0].url.params["query"] == "creamy mushroom pasta"


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
