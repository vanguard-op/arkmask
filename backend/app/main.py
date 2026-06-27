"""FastAPI application entry point for the ArkMask API.

All routes are registered here. The app is a stateless AI proxy and billing
middleware — it validates platform API keys, proxies AI generation requests
to user-supplied providers, and records credit usage events atomically.

Security notes:
  - `X-Provider-Key` never appears in any log statement (not even at DEBUG).
  - `X-Platform-Key` is never logged — only the resolved `user_id` is.
  - Structured JSON logging is used; all log fields are safe for GCP Cloud Logging.
"""

import logging

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.config import get_settings
from app.routers import account, auth, generation

settings = get_settings()

logging.basicConfig(
    level=logging.DEBUG if settings.is_local else logging.INFO,
    format="%(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="ArkMask API",
    version="0.1.0",
    description=(
        "Stateless AI proxy and billing middleware for the ArkMask mobile app. "
        "See docs/ArkMask/architecture.md for the full system design."
    ),
    # Disable the default /docs and /redoc in production.
    docs_url="/docs" if settings.is_local else None,
    redoc_url=None,
)

# CORS — only needed when running against a web client or local Flutter web.
if settings.is_local:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

# ── Routers ───────────────────────────────────────────────────────────────────

app.include_router(auth.router)
app.include_router(account.router)
app.include_router(generation.router)


# ── Global exception handlers ─────────────────────────────────────────────────

@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Catch-all: return a safe 500 without leaking stack traces to clients."""
    logger.exception("Unhandled exception on %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"detail": "An internal server error occurred."},
    )


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health", tags=["infra"])
def health():
    """Liveness probe for Cloud Run / load balancer health checks."""
    return {"status": "ready", "env": settings.app_env}
