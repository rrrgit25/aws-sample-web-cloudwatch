"""Sample Python web application for deployment on AWS EKS.

Endpoints
---------
GET  /                 HTML landing page
GET  /health/live      Liveness probe (process is up)
GET  /health/ready     Readiness probe (app can serve traffic)
GET  /api/info         Build / runtime information
GET  /api/items        List items (in-memory store)
POST /api/items        Create an item  {"name": "...", "description": "..."}
GET  /api/items/<id>   Fetch one item
DELETE /api/items/<id> Delete one item

Chaos endpoints (only when ENABLE_CHAOS_ENDPOINTS=true) - used to verify
that the CloudWatch alarms fire:
POST /chaos/cpu?seconds=N   Burn CPU for N seconds (max 300)
POST /chaos/error           Return HTTP 500 and log an ERROR line
POST /chaos/crash           Terminate the process (container restart)
"""

from __future__ import annotations

import json
import logging
import os
import platform
import signal
import socket
import sys
import threading
import time
import uuid
from datetime import datetime, timezone

from flask import Flask, abort, jsonify, request

APP_NAME = os.getenv("APP_NAME", "sample-web")
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "dev")


class JsonFormatter(logging.Formatter):
    """Emit one JSON object per log line (friendly for CloudWatch Logs Insights)."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "app": APP_NAME,
            "version": APP_VERSION,
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def _configure_logging() -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    return logging.getLogger(APP_NAME)


def _env_flag(name: str, default: bool = False) -> bool:
    return os.getenv(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


def create_app() -> Flask:
    log = _configure_logging()
    app = Flask(__name__)
    app.config["CHAOS_ENABLED"] = _env_flag("ENABLE_CHAOS_ENDPOINTS")
    app.config["STARTED_AT"] = time.time()

    items: dict[str, dict] = {}
    lock = threading.Lock()

    # ------------------------------------------------------------------ pages
    @app.get("/")
    def index():
        return (
            f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{APP_NAME}</title>
<style>body{{font-family:system-ui,sans-serif;max-width:720px;margin:3rem auto;padding:0 1rem}}
code{{background:#f2f2f2;padding:2px 4px;border-radius:4px}}</style></head>
<body>
<h1>{APP_NAME}</h1>
<p>Version <code>{APP_VERSION}</code> &middot; environment <code>{ENVIRONMENT}</code>
&middot; served by pod <code>{socket.gethostname()}</code></p>
<ul>
  <li><a href="/api/info">/api/info</a></li>
  <li><a href="/api/items">/api/items</a></li>
  <li><a href="/health/live">/health/live</a> &middot; <a href="/health/ready">/health/ready</a></li>
</ul>
</body></html>""",
            200,
            {"Content-Type": "text/html; charset=utf-8"},
        )

    # ----------------------------------------------------------------- health
    @app.get("/health/live")
    def live():
        return jsonify(status="ok")

    @app.get("/health/ready")
    def ready():
        return jsonify(status="ready", uptime_seconds=round(time.time() - app.config["STARTED_AT"], 1))

    # -------------------------------------------------------------------- api
    @app.get("/api/info")
    def info():
        return jsonify(
            app=APP_NAME,
            version=APP_VERSION,
            environment=ENVIRONMENT,
            hostname=socket.gethostname(),
            python=platform.python_version(),
            chaos_enabled=app.config["CHAOS_ENABLED"],
        )

    @app.get("/api/items")
    def list_items():
        with lock:
            return jsonify(items=list(items.values()), count=len(items))

    @app.post("/api/items")
    def create_item():
        data = request.get_json(silent=True) or {}
        name = str(data.get("name", "")).strip()
        if not name:
            return jsonify(error="'name' is required"), 400
        item = {
            "id": uuid.uuid4().hex[:12],
            "name": name,
            "description": str(data.get("description", "")),
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        with lock:
            items[item["id"]] = item
        log.info("created item %s", item["id"])
        return jsonify(item), 201

    @app.get("/api/items/<item_id>")
    def get_item(item_id: str):
        with lock:
            item = items.get(item_id)
        if item is None:
            abort(404)
        return jsonify(item)

    @app.delete("/api/items/<item_id>")
    def delete_item(item_id: str):
        with lock:
            item = items.pop(item_id, None)
        if item is None:
            abort(404)
        log.info("deleted item %s", item_id)
        return "", 204

    # ------------------------------------------------------------------ chaos
    def _require_chaos():
        if not app.config["CHAOS_ENABLED"]:
            abort(404)

    @app.post("/chaos/cpu")
    def chaos_cpu():
        _require_chaos()
        seconds = max(1, min(int(request.args.get("seconds", 60)), 300))

        def burn(until: float) -> None:
            while time.time() < until:
                _ = sum(i * i for i in range(10_000))

        until = time.time() + seconds
        threading.Thread(target=burn, args=(until,), daemon=True).start()
        log.warning("chaos: burning CPU for %s seconds", seconds)
        return jsonify(status="burning", seconds=seconds), 202

    @app.post("/chaos/error")
    def chaos_error():
        _require_chaos()
        log.error("chaos: simulated application error")
        return jsonify(error="simulated failure"), 500

    @app.post("/chaos/crash")
    def chaos_crash():
        _require_chaos()
        log.critical("chaos: crashing process on purpose")

        def die() -> None:
            # Under gunicorn the worker's parent is the master (PID 1 in the
            # container). Killing only the worker would just respawn it, so
            # stop the master to force a real container restart.
            if os.getppid() == 1:
                os.kill(1, signal.SIGTERM)
            os._exit(1)

        threading.Timer(0.5, die).start()
        return jsonify(status="crashing"), 202

    # ----------------------------------------------------------------- errors
    @app.errorhandler(404)
    def not_found(_):
        return jsonify(error="not found"), 404

    @app.errorhandler(Exception)
    def unhandled(exc):
        from werkzeug.exceptions import HTTPException

        if isinstance(exc, HTTPException):
            return jsonify(error=exc.description), exc.code
        log.exception("unhandled error")
        return jsonify(error="internal server error"), 500

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
