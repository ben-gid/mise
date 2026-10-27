"""The server's verdict on a recipe has to be the phone's: these are the
fixtures test/shared_fixtures_test.dart walks, judged by the server's rules."""

import json
from pathlib import Path

import pytest

from app import recipes

FIXTURES = Path(__file__).resolve().parents[2] / "test" / "fixtures"


def _load(path: Path):
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None  # malformed.json: refused before validation, as on the phone


@pytest.mark.parametrize("path", sorted(FIXTURES.glob("valid/*.json")), ids=lambda p: p.name)
def test_accepts(path):
    assert recipes.problems(_load(path)) == []


@pytest.mark.parametrize("path", sorted(FIXTURES.glob("invalid/*.json")), ids=lambda p: p.name)
def test_rejects(path):
    recipe = _load(path)
    assert recipe is None or recipes.problems(recipe) != []
