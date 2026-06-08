"""System routes — server lifecycle controls (graceful shutdown)."""

import asyncio
import logging
import os
import signal

from fastapi import APIRouter, Request

from core.middleware import require_admin
from src.auth_helpers import get_current_user

logger = logging.getLogger(__name__)


def _trigger_shutdown() -> None:
    """Ask the running server to stop, gracefully where possible.

    Raising SIGINT runs uvicorn's own signal handler, which sets
    ``should_exit`` and lets the app shut down cleanly (the lifespan
    ``_shutdown_event`` runs: MCP subprocesses and webhook tasks are torn
    down). This works on both POSIX and Windows because Python delivers the
    SIGINT handler on the main thread, and this callback is scheduled on the
    event loop (the main thread). If no handler is installed, the default
    handler raises KeyboardInterrupt, which uvicorn also treats as a stop.
    """
    try:
        signal.raise_signal(signal.SIGINT)
    except Exception:
        logger.exception("Graceful shutdown signal failed; forcing exit")
        os._exit(0)


def setup_system_routes() -> APIRouter:
    router = APIRouter(tags=["system"])

    @router.get("/api/system/ping")
    async def ping():
        """Lightweight liveness probe. Used by the shutdown overlay to detect
        when the server has actually stopped (the request stops resolving)."""
        return {"ok": True}

    @router.post("/api/system/shutdown")
    async def shutdown_server(request: Request):
        """Stop the Odysseus server. Admin-only.

        Returns immediately, then stops the server a beat later so this HTTP
        response is flushed to the browser first. Dependency containers
        (ChromaDB, SearXNG, ntfy) are left running.
        """
        require_admin(request)
        user = get_current_user(request)
        logger.warning("Server shutdown requested via UI by user=%s", user or "unknown")

        loop = asyncio.get_running_loop()
        loop.call_later(0.5, _trigger_shutdown)

        return {"ok": True, "message": "Odysseus is shutting down."}

    return router
