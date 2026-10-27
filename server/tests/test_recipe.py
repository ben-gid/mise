import base64
import copy
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from app import main, recipes, usage
from app.core.config import settings
from app.main import app
from tests.test_me import bearer, keys, token  # noqa: F401 — keys: the JWKS stand-in, autouse

client = TestClient(app)
FOCACCIA = json.loads(
    (Path(__file__).resolve().parents[2] / "test/fixtures/valid/focaccia.json").read_text()
)


def answer(recipe) -> SimpleNamespace:
    text = recipe if isinstance(recipe, str) else json.dumps(recipe)
    return SimpleNamespace(
        content=[SimpleNamespace(type="text", text=text)],
        usage=SimpleNamespace(input_tokens=3000, output_tokens=2000),
        stop_reason="end_turn",
    )


@pytest.fixture
def claude(monkeypatch):
    """Stands in for the model: hands out `answers` in turn, records `calls`."""
    fake = SimpleNamespace(calls=[], answers=[FOCACCIA])

    async def create(**kwargs):
        fake.calls.append(copy.deepcopy(kwargs["messages"]))
        return answer(fake.answers[min(len(fake.calls), len(fake.answers)) - 1])

    monkeypatch.setattr(
        recipes, "_claude", SimpleNamespace(messages=SimpleNamespace(create=create))
    )
    monkeypatch.setattr(main, "_recipe_windows", {})
    return fake


@pytest.fixture
def db(monkeypatch):
    """Stands in for PostgREST: one profile, and every write recorded."""
    fake = SimpleNamespace(profile={"pro_until": None, "free_tries_used": 0}, writes=[])

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, json=[fake.profile])
        fake.writes.append((request.method, request.url.path, json.loads(request.content)))
        return httpx.Response(204)

    monkeypatch.setattr(
        usage,
        "_rest",
        httpx.AsyncClient(
            base_url=f"{settings.SUPABASE_URL}/rest/v1",
            transport=httpx.MockTransport(handler),
        ),
    )
    return fake


def post(body: dict, **claims) -> httpx.Response:
    return client.post("/recipe", json=body, headers=bearer(token(**claims)))


def test_a_sentence_comes_back_as_a_recipe_and_spends_a_try(claude, db):
    response = post({"text": "garlic focaccia"})
    assert response.status_code == 200
    assert response.json()["title"] == "Garlic Butter Focaccia"
    assert ("PATCH", "/rest/v1/profiles", {"free_tries_used": 1}) in db.writes
    recorded = next(body for method, path, body in db.writes if path == "/rest/v1/usage")
    assert recorded["kind"] == "write" and recorded["ok"] is True
    assert recorded["cost_usd"] == pytest.approx(0.0013)


def test_the_time_and_photos_are_set_here_not_by_the_model(claude, db):
    claude.answers = [{**FOCACCIA, "image_urls": ["https://made.up/x.jpg"]}]
    written = post({"text": "focaccia"}).json()
    assert written["image_urls"] == []
    assert datetime.fromisoformat(written["created_at"]) > datetime.now(timezone.utc) - timedelta(minutes=1)


def test_an_adapted_recipe_keeps_the_cooks_photo(claude, db):
    base = {**FOCACCIA, "image_urls": ["mise://1.jpg"]}
    written = post({"text": "make it vegan", "base": base}).json()
    assert written["image_urls"] == ["mise://1.jpg"]
    assert "make it vegan" in json.dumps(claude.calls[0])


def test_a_dangling_ref_is_sent_back_and_fixed(claude, db):
    broken = copy.deepcopy(FOCACCIA)
    broken["steps"][0]["content"] = "Whisk {0099}."
    claude.answers = [broken, FOCACCIA]
    assert post({"text": "focaccia"}).status_code == 200
    assert len(claude.calls) == 2
    assert "{0099}" in claude.calls[1][-1]["content"]


def test_three_failures_are_a_422_that_costs_no_try(claude, db):
    claude.answers = [{**FOCACCIA, "ingredients": []}]
    response = post({"text": "focaccia"})
    assert response.status_code == 422
    assert response.json()["errors"]
    assert len(claude.calls) == recipes.ATTEMPTS
    assert not any(path == "/rest/v1/profiles" for _, path, _ in db.writes)
    recorded = next(body for _, path, body in db.writes if path == "/rest/v1/usage")
    assert recorded["ok"] is False


def test_out_of_tries_is_a_402_before_the_model(claude, db):
    db.profile["free_tries_used"] = usage.FREE_TRIES
    assert post({"text": "focaccia"}).status_code == 402
    assert claude.calls == []


def test_pro_spends_no_tries(claude, db):
    later = (datetime.now(timezone.utc) + timedelta(days=30)).isoformat()
    db.profile = {"pro_until": later, "free_tries_used": usage.FREE_TRIES}
    assert post({"text": "focaccia"}).status_code == 200
    assert not any(path == "/rest/v1/profiles" for _, path, _ in db.writes)


def test_needs_a_token(claude, db):
    assert client.post("/recipe", json={"text": "x"}).status_code == 401


@pytest.mark.parametrize(
    "body", [{}, {"url": "https://a.com", "text": "x", "image": "eA=="}, {"base": FOCACCIA}]
)
def test_one_kind_of_material(claude, db, body):
    assert post(body).status_code == 400


def test_no_key_is_a_503(claude, db, monkeypatch):
    monkeypatch.setattr(settings, "ANTHROPIC_API_KEY", SecretStr(""))
    assert post({"text": "focaccia"}).status_code == 503


def test_a_photo_goes_to_the_model_as_an_image(claude, db):
    photo = base64.b64encode(b"\xff\xd8 not really a jpeg").decode()
    assert post({"image": photo}).status_code == 200
    block = claude.calls[0][0]["content"][0]
    assert block["type"] == "image" and block["source"]["data"] == photo


@pytest.fixture
def web(monkeypatch):
    """Stands in for the open web: `pages` by url; every host is public unless
    named in `private`."""
    fake = SimpleNamespace(pages={}, private=set(), status=None)

    async def public(host):
        return host not in fake.private

    def handler(request: httpx.Request) -> httpx.Response:
        if fake.status:
            return httpx.Response(fake.status)
        page = fake.pages.get(str(request.url))
        if isinstance(page, tuple):
            return httpx.Response(301, headers={"location": page[1]})
        return httpx.Response(200 if page else 404, text=page or "")

    monkeypatch.setattr(recipes, "_public", public)
    monkeypatch.setattr(recipes, "_page", httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    return fake


LD_PAGE = """<html><head><script type="application/ld+json">
{"@context":"https://schema.org","@graph":[{"@type":"WebPage"},
 {"@type":["Recipe"],"name":"Focaccia","recipeIngredient":["500 g flour"]}]}
</script></head><body><nav>Home</nav><p>Life story…</p></body></html>"""


def test_a_page_with_recipe_data_sends_only_that(claude, db, web):
    web.pages["https://food.site/focaccia"] = LD_PAGE
    written = post({"url": "https://food.site/focaccia"}).json()
    sent = claude.calls[0][0]["content"][0]["text"]
    assert '"recipeIngredient"' in sent and "Life story" not in sent
    assert written["source"] == "https://food.site/focaccia"


def test_a_page_without_it_sends_its_text(claude, db, web):
    web.pages["https://blog.site/p"] = "<p>500 g flour</p><script>track()</script>"
    post({"url": "https://blog.site/p"})
    sent = claude.calls[0][0]["content"][0]["text"]
    assert "500 g flour" in sent and "track()" not in sent


def test_redirects_are_followed_and_each_hop_checked(claude, db, web):
    web.pages["https://short.link/a"] = (301, "https://food.site/focaccia")
    web.pages["https://food.site/focaccia"] = LD_PAGE
    assert post({"url": "https://short.link/a"}).status_code == 200
    web.pages["https://short.link/b"] = (301, "https://metadata.internal/token")
    web.private.add("metadata.internal")
    response = post({"url": "https://short.link/b"})
    assert response.status_code == 422
    assert "public" in response.json()["errors"][0]


@pytest.mark.parametrize("url", ["http://food.site/x", "https://169.254.169.254/"])
def test_only_public_https_pages_are_read(claude, db, url):
    # The real address check, unmocked: a literal link-local IP is never global.
    response = post({"url": url})
    assert response.status_code == 422
    assert claude.calls == []


def test_the_model_must_write_a_headnote_and_a_photo_query():
    # Optional fields get skipped under constrained decoding; a real recipe
    # written from a sentence came back with neither.
    required = recipes._format["schema"]["required"]
    assert "notes" in required and "image_query" in required
    assert "image_urls" not in recipes._format["schema"]["properties"]


def test_a_site_that_blocks_apps_says_what_to_do(claude, db, web):
    web.status = 403
    response = post({"url": "https://blocked.site/r"})
    assert response.status_code == 422
    assert "paste" in response.json()["errors"][0]
    assert claude.calls == []
