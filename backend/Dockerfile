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

# Default: production-style server (no --reload).
# Override in docker-compose.yml for local dev.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
