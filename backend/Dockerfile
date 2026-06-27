FROM python:3.12-slim

WORKDIR /app

# Install build dependencies for psycopg2-binary and other C extensions.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev gcc \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml .
RUN pip install --no-cache-dir -e .

COPY . .

# Default: production-style server (no --reload).
# Override in docker-compose.yml for local dev.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
