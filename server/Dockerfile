FROM python:3.13-slim
COPY --from=ghcr.io/astral-sh/uv:0.10.2 /uv /bin/uv

WORKDIR /srv
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY app ./app

# Cloud Run sends traffic to 8080 unless told otherwise.
CMD [".venv/bin/uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
