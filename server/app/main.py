import base64
import binascii
import time
from typing import Annotated, Literal

import anthropic
import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app import auth, recipes, unsplash, usage
from app.core.config import settings

app = FastAPI(title="mise api")

# Unsplash calls a single caller may spend per hour. Only cache misses count —
# a hit costs Unsplash nothing — so this caps what one IP can take out of the
# shared hourly quota, and a phone loading a library of mostly-cached dishes never
# feels it. A caller over it gets a 429, which the app reads as "no photos".
# ponytail: per-instance fixed window, so --max-instances N lets a caller have
# N times this; Cloud Armor or a shared counter if that ever matters.
LIMIT = 50
_windows: dict[str, tuple[float, int]] = {}
# Recipes written per caller per hour, the same way. Free tries are per user,
# and a script can make users; this is what it can't make more of.
RECIPE_LIMIT = 20
_recipe_windows: dict[str, tuple[float, int]] = {}


def _caller(request: Request) -> str:
    # Cloud Run appends the address it saw to X-Forwarded-For, after anything
    # the client sent itself — so only the last entry can't be forged. Behind a
    # load balancer that appends its own, this would need to be second-last.
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.rsplit(",", 1)[-1].strip()
    return request.client.host if request.client else ""


def _allow(windows: dict[str, tuple[float, int]], caller: str, limit: int) -> bool:
    now = time.monotonic()
    start, count = windows.get(caller, (now, 0))
    if now - start >= 60 * 60:
        start, count = now, 0
    if count >= limit:
        return False
    if len(windows) >= 10_000:
        windows.clear()
    windows[caller] = (start, count + 1)
    return True


@app.get("/photos", tags=["photos"])
async def photos(
    request: Request, query: Annotated[str, Query(min_length=1, max_length=200)]
) -> list[dict]:
    # 200 rather than image_query's 60: the picker falls back to a recipe title.
    if not settings.UNSPLASH_ACCESS_KEY.get_secret_value():
        raise HTTPException(status_code=503, detail="Photo search isn't set up")
    if (hit := unsplash.cached(query)) is not None:
        return hit
    if not _allow(_windows, _caller(request), LIMIT):
        raise HTTPException(status_code=429, detail="Too many photo searches")
    try:
        return await unsplash.search(query)
    except (unsplash.UnsplashError, httpx.HTTPError):
        raise HTTPException(status_code=502, detail="Photo search failed")


class PhotoUsed(BaseModel):
    # An Unsplash photo id, never a url: the server builds the one url it calls
    # with its key, so this can't be pointed anywhere else.
    id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")


@app.post("/photos/used", status_code=204, tags=["photos"])
async def photo_used(body: PhotoUsed, request: Request) -> Response:
    """The phone kept a search result. Unsplash's terms ask for this ping, and
    it spends quota, so it shares the search's hourly window."""
    if not settings.UNSPLASH_ACCESS_KEY.get_secret_value():
        raise HTTPException(status_code=503, detail="Photo search isn't set up")
    if not _allow(_windows, _caller(request), LIMIT):
        raise HTTPException(status_code=429, detail="Too many photo searches")
    try:
        await unsplash.downloaded(body.id)
    except (unsplash.UnsplashError, httpx.HTTPError):
        raise HTTPException(status_code=502, detail="Unsplash didn't answer")
    return Response(status_code=204)


User = Annotated[dict, Depends(auth.current_user)]


@app.get("/me", tags=["account"])
def me(user: User) -> dict:
    # Anonymous users are real users with a real id; the flag is what later
    # routes read to tell a free try from a linked account.
    return {"id": user["sub"], "anonymous": bool(user.get("is_anonymous"))}


@app.delete("/me", status_code=204, tags=["account"])
async def delete_me(user: User) -> Response:
    try:
        await auth.delete_user(user["sub"])
    except (auth.AdminError, httpx.HTTPError):
        raise HTTPException(status_code=502, detail="Couldn't delete the account")
    return Response(status_code=204)


class RecipeRequest(BaseModel):
    """One kind of material: [text] alone is a recipe to write; with [base] it
    is the change to make to it; [url] is a page and [image] a photo of one,
    base64."""

    # Room for an idea plus the answers to two rounds of questions.
    text: str | None = Field(None, min_length=1, max_length=6000)
    url: str | None = Field(None, max_length=2000)
    # A phone photo shrunk to 1600px is well under this.
    image: str | None = Field(None, max_length=8_000_000)
    image_type: Literal["image/jpeg", "image/png", "image/webp"] = "image/jpeg"
    base: dict | None = None


class QuestionsRequest(BaseModel):
    """The cook's idea, and [brief] — the first round's answers as the phone
    words them — when this is the second round. There is no third: the phone
    never asks for one, and the server has nothing to ask it with."""

    idea: str = Field(min_length=1, max_length=2000)
    brief: str | None = Field(None, max_length=4000)


@app.post("/questions", tags=["recipes"])
async def ask_questions(body: QuestionsRequest, request: Request, user: User) -> dict:
    """Forks to put to the cook before a recipe is written; an empty list means
    there is nothing worth asking. Free: only the recipe at the end spends a
    try, so a cook out of them can still think it through and meet the paywall
    at Create. The hourly limit is shared with /recipe, which is what keeps a
    script from looping this."""
    if not settings.ANTHROPIC_API_KEY.get_secret_value():
        raise HTTPException(status_code=503, detail="Recipe writing isn't set up")
    if not _allow(_recipe_windows, _caller(request), RECIPE_LIMIT):
        raise HTTPException(
            status_code=429,
            detail="That is a lot of recipes for one hour. Try again later.",
        )
    try:
        forks, tokens = await recipes.questions(body.idea, body.brief)
    except anthropic.APIError:
        raise HTTPException(status_code=502, detail="Couldn't think of questions")
    await usage.record(user["sub"], "questions", tokens, recipes.cost(tokens), ok=True)
    return {"questions": forks}


def _refused(*errors: str) -> JSONResponse:
    # The shape of the phone's RecipeValidationException, so it lands in the
    # same error list a bad paste does.
    return JSONResponse(
        status_code=422, content={"detail": "No recipe", "errors": list(errors)}
    )


@app.post("/recipe", tags=["recipes"])
async def recipe(body: RecipeRequest, request: Request, user: User):
    """A validated recipe, or a 422 listing why there isn't one.

    Only a recipe that passes spends a free try; one that fails every attempt
    costs the cook nothing and is still recorded in `usage`, because it cost
    us something."""
    if not settings.ANTHROPIC_API_KEY.get_secret_value():
        raise HTTPException(status_code=503, detail="Recipe writing isn't set up")
    given = [x for x in (body.url, body.image, body.base) if x is not None]
    if len(given) > 1 or (body.base is not None and not body.text) or (
        not given and not body.text
    ):
        raise HTTPException(
            status_code=400,
            detail="Send text, a url, a photo, or a recipe with text",
        )
    # Both 429s are worded for the cook: the phone shows the detail as it is,
    # and only it knows which limit this was.
    if not _allow(_recipe_windows, _caller(request), RECIPE_LIMIT):
        raise HTTPException(
            status_code=429,
            detail="That is a lot of recipes for one hour. Try again later.",
        )
    user_id = user["sub"]
    try:
        left = await usage.tries_left(user_id)
        capped = left is None and (
            await usage.made_this_month(user_id) >= usage.PRO_MONTHLY
        )
    except (usage.UsageError, httpx.HTTPError):
        raise HTTPException(status_code=503, detail="Can't check free tries")
    if left == 0:
        raise HTTPException(status_code=402, detail="No free tries left")
    if capped:
        raise HTTPException(
            status_code=429,
            detail=f"That's {usage.PRO_MONTHLY} recipes this month, Pro's limit. "
            "It starts again on the 1st.",
        )

    kind, page, image = "write", None, None
    if body.base is not None:
        kind = "adapt"
    elif body.url is not None:
        kind = "url"
        try:
            page = await recipes.read_page(body.url)
        except recipes.PageError as e:
            return _refused(str(e))
    elif body.image is not None:
        kind = "photo"
        try:
            image = (body.image_type, base64.b64decode(body.image, validate=True))
        except binascii.Error:
            raise HTTPException(status_code=400, detail="The photo isn't base64")

    messages = recipes.ask(text=body.text, page=page, image=image, base=body.base)
    try:
        written, tokens = await recipes.write(
            messages, base=body.base, source=body.url
        )
    except recipes.RecipeFailed as e:
        await usage.record(user_id, kind, e.usage, recipes.cost(e.usage), ok=False)
        return _refused(*e.errors)
    except anthropic.APIError:
        raise HTTPException(status_code=502, detail="Couldn't write a recipe")
    if left is not None:
        await usage.spend_try(user_id, left)
    await usage.record(user_id, kind, tokens, recipes.cost(tokens), ok=True)
    return written
