# Build context is the repo root (see .github/workflows/workers.yml —
# `docker build -f workers/Dockerfile .`), not workers/, because this image
# reuses shared service modules owned by backend/app rather than duplicating
# them. If backend/app's package layout changes, update the COPY paths below.

FROM python:3.12-slim

WORKDIR /app

# ffmpeg is required by the merge worker (trims + transitions + concat).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Reuse the backend's dependency manifest — workers need the same AI
# provider, Firestore, and GCS client libraries as the API.
COPY backend/pyproject.toml ./pyproject.toml

# Shared service modules — owned by backend/app, copied here rather than
# duplicated across two independently-built images.
COPY backend/app/services ./app/services
COPY backend/app/config.py ./app/config.py
COPY backend/instructions ./instructions

# Worker-owned code: Cloud Tasks push-target endpoints + job handlers.
COPY workers/app ./app

# Editable install last, after all `app/` source is in place — pip needs the
# package directory to exist to build the .pth redirect (see backend/Dockerfile
# for the same pattern).
RUN pip install --no-cache-dir -e .

# Cloud Run injects $PORT (8080 by default); see backend/Dockerfile for why
# this must not be hardcoded.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"]
