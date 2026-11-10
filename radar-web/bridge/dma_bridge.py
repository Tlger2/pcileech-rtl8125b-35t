#!/usr/bin/env python3
"""Read-only DMA / snapshot bridge for the Never Banned web radar.

Serves:
  GET  /state  — ReaderRadar-compatible snapshot (or last ingest)
  GET  /health — liveness
  GET  /map    — optional basemap image from ReaderRadar world.map_image_path
                 (files under ATOMIC_MAP_DIR, snapshot-adjacent maps/, or radar-web/maps)

Ingest order:
  1. SNAPSHOT_PATH JSON from rust_snapshot.py (ReaderRadar)
  2. Optional FT601 identify / read via host/ft601_client.py
  3. Empty state so the web UI stays on SIM

Run on the reader laptop:
  python radar-web/bridge/dma_bridge.py

This process never writes game memory. DMA is identify + snapshot ingest only.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
HOST_DIR = ROOT / "host"
if str(HOST_DIR) not in sys.path:
    sys.path.insert(0, str(HOST_DIR))

PORT = int(os.environ.get("ATOMIC_DMA_PORT", "1738"))
SNAPSHOT = Path(os.environ.get(
    "SNAPSHOT_PATH",
    Path(os.environ.get("TEMP") or os.environ.get("TMP") or "/tmp") / "ReaderRadar-Rust-live.json",
))
_MAP_EXTS = {".png", ".jpg", ".jpeg", ".webp"}
_LOOPBACK_HOSTS = {"127.0.0.1", "localhost"}

_lock = threading.Lock()
_state: dict = {
    "ts": time.time(),
    "world_size": int(os.environ.get("RUST_WORLD_SIZE", "4000")),
    "provider": "sim",
    "dmaConnected": False,
    "local_player": None,
    "entities": [],
    "map_image_path": None,
}
_map_path: Path | None = None


def _trusted_map_root() -> Path:
    env = os.environ.get("ATOMIC_MAP_DIR", "").strip()
    if env:
        return Path(env).expanduser().resolve()
    snap_maps = SNAPSHOT.parent / "maps"
    if snap_maps.is_dir():
        return snap_maps.resolve()
    return (Path(__file__).resolve().parents[1] / "maps").resolve()


def _safe_map_file(raw: str | None) -> Path | None:
    """Resolve snapshot map_image_path only if it is a real image under the trusted root."""
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if not text or "\x00" in text:
        return None
    lowered = text.lower()
    if lowered.startswith(("http://", "https://", "file:", "javascript:", "data:", "blob:")):
        return None
    parts = text.replace("\\", "/").split("/")
    if any(part == ".." for part in parts):
        return None
    root = _trusted_map_root()
    candidate = Path(text)
    try:
        resolved = candidate.resolve() if candidate.is_absolute() else (root / candidate).resolve()
    except (OSError, RuntimeError):
        return None
    try:
        resolved.relative_to(root)
    except ValueError:
        return None
    if resolved.suffix.lower() not in _MAP_EXTS:
        return None
    if not resolved.is_file():
        return None
    return resolved


def _map_content_type(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".png":
        return "image/png"
    if suffix in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if suffix == ".webp":
        return "image/webp"
    return "application/octet-stream"


def _allowed_cors_origin(origin: str | None) -> str | None:
    """Reflect only http://127.0.0.1:* and http://localhost:* . Never '*'."""
    if not origin:
        return None
    try:
        parsed = urlparse(origin)
    except ValueError:
        return None
    if parsed.scheme != "http":
        return None
    if parsed.username or parsed.password:
        return None
    host = (parsed.hostname or "").lower()
    if host not in _LOOPBACK_HOSTS:
        return None
    if parsed.path not in {"", "/"}:
        return None
    return origin


def _map_image_from(data: dict) -> str | None:
    world = data.get("world") if isinstance(data.get("world"), dict) else {}
    raw = data.get("map_image_path") or world.get("map_image_path")
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    return None


def _load_snapshot() -> None:
    global _state, _map_path
    if not SNAPSHOT.is_file():
        return
    try:
        data = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    safe = _safe_map_file(_map_image_from(data))
    with _lock:
        _state = {
            "ts": data.get("ts", time.time()),
            "world_size": data.get("world_size", data.get("world", {}).get("size", 4000) if isinstance(data.get("world"), dict) else 4000),
            "provider": "memprocfs",
            "dmaConnected": True,
            "local_player": data.get("local_player"),
            "entities": data.get("entities", []),
            "map_image_path": "/map" if safe else None,
            "world": None,
        }
        _map_path = safe


def _try_ft601() -> None:
    try:
        from ft601_client import FT601Client  # type: ignore
    except Exception:
        return
    try:
        with FT601Client() as dev:
            ident = None
            if hasattr(dev, "identify"):
                ident = dev.identify()
            with _lock:
                _state["provider"] = "ft601"
                _state["dmaConnected"] = True
                _state["ft601"] = ident or True
    except Exception:
        return


def _watch() -> None:
    last = 0.0
    while True:
        try:
            m = SNAPSHOT.stat().st_mtime if SNAPSHOT.is_file() else 0.0
        except OSError:
            m = 0.0
        if m > last:
            last = m
            _load_snapshot()
        time.sleep(0.05)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        return

    def _apply_cors(self) -> None:
        origin = _allowed_cors_origin(self.headers.get("Origin"))
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Vary", "Origin")

    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._apply_cors()
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _send_bytes(self, code: int, payload: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self._apply_cors()
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self) -> None:  # noqa: N802
        origin = _allowed_cors_origin(self.headers.get("Origin"))
        self.send_response(204)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET,OPTIONS")
            self.send_header("Vary", "Origin")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/health"):
            self._send(200, {"ok": True, "readonly": True})
            return
        if self.path.startswith("/state"):
            with _lock:
                body = dict(_state)
            self._send(200, body)
            return
        if self.path.startswith("/map"):
            with _lock:
                path = _map_path
            path = _safe_map_file(str(path)) if path else None
            if not path:
                self._send(404, {"error": "no map image"})
                return
            try:
                self._send_bytes(200, path.read_bytes(), _map_content_type(path))
            except OSError:
                self._send(404, {"error": "map image unreadable"})
            return
        self._send(404, {"error": "not found"})


def main() -> None:
    _load_snapshot()
    _try_ft601()
    threading.Thread(target=_watch, daemon=True).start()
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"never-banned bridge http://127.0.0.1:{PORT}/state  snapshot={SNAPSHOT} (read-only)")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
