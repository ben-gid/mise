# Built from the repo root, not server/: the server reads the live recipe schema
# and the shared prompt from assets/, the same files the app bundles, so there
# is no copy of either to drift. The layout below mirrors the repo's, which is
# what lets app/recipes.py find them by the same relative path in both places.
FROM python:3.13-slim
COPY --from=ghcr.io/astral-sh/uv:0.10.2 /uv /bin/uv

WORKDIR /srv/server
COPY server/pyproject.toml server/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY server/app ./app
COPY assets/schemas /srv/assets/schemas
COPY assets/prompts /srv/assets/prompts

# Cloud Run sends traffic to 8080 unless told otherwise.
CMD [".venv/bin/uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
