FROM python:3.12-slim

WORKDIR /app

# libpq-dev is needed at runtime for psycopg2-binary's shared lib.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml .
# Install psycopg2-binary first using the pre-built wheel (avoids needing gcc).
RUN pip install --no-cache-dir --only-binary=:all: psycopg2-binary
RUN pip install --no-cache-dir -e .

COPY . .

# Default: production-style server (no --reload). Overridden by
# docker-compose.yml for local dev (fixed port 8000 there).
#
# Cloud Run injects $PORT (8080 by default) and health-checks that exact
# port; hardcoding --port 8000 here caused the startup TCP probe to always
# fail (app listening on 8000, probe checking 8080), so the container was
# never marked healthy. Use shell form to read $PORT at runtime, falling
# back to 8080 to match Cloud Run's default container port.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"]
