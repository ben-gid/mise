"""How well the model writes mise recipes from real material — run by hand,
never by pytest, because every case is a real call that costs a fraction of a
cent. This is the gate on shipping /import, and the way to check a prompt
change or a cheaper model later.

    cd server && ANTHROPIC_API_KEY=sk-ant-... uv run python -m eval.run

cases.json is a list; each case is one of
    {"text": "a dish to write"}
    {"url": "https://a recipe page"}
    {"photo": "eval/photos/page.jpg"}   (relative to server/)
It goes through the same reading, prompt, retries and checks as /recipe, but
spends no free tries and writes no usage rows."""

import asyncio
import json
import os
import sys
from pathlib import Path

# Before app.core.config, which wants the Supabase settings the eval never uses.
os.environ.setdefault("SUPABASE_URL", "https://unused.supabase.co")
os.environ.setdefault("SUPABASE_SECRET_KEY", "unused")

from app import recipes  # noqa: E402

HERE = Path(__file__).parent


async def one(case: dict) -> tuple[bool, str, tuple[int, int]]:
    page = image = None
    if "url" in case:
        try:
            page = await recipes.read_page(case["url"])
        except recipes.PageError as e:
            return False, str(e), (0, 0)
    if "photo" in case:
        path = HERE.parent / case["photo"]
        kind = "image/png" if path.suffix == ".png" else "image/jpeg"
        image = (kind, path.read_bytes())
    messages = recipes.ask(text=case.get("text"), page=page, image=image, base=None)
    try:
        recipe, tokens = await recipes.write(messages, base=None, source=case.get("url"))
    except recipes.RecipeFailed as e:
        return False, "; ".join(e.errors[:3]), e.usage
    return True, f"{recipe['title']} — {len(recipe['ingredients'])} ingredients", tokens


async def main() -> int:
    cases = json.loads((HERE / "cases.json").read_text())
    passed, spent = 0, 0.0
    for case in cases:
        ok, what, tokens = await one(case)
        passed += ok
        spent += recipes.cost(tokens)
        label = case.get("url") or case.get("photo") or case["text"]
        print(f"{'pass' if ok else 'FAIL'}  {label}\n      {what}  ({tokens[0]}+{tokens[1]} tokens)")
    print(f"\n{passed}/{len(cases)} passed, ${spent:.4f}")
    return 0 if passed == len(cases) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
