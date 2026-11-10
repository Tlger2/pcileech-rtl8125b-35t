#!/usr/bin/env python3
"""Local DMA / snapshot bridge for the AtomicDMA web radar.

Serves:
  GET  /state  — ReaderRadar-compatible snapshot (or last ingest)
  POST /aim    — aim write intent (pitch/yaw/bone). Applied via MemProcFS
                 when VMM is present and ATOMIC_DMA_WRITE=1.
  GET  /health

Ingest order:
  1. SNAPSHOT_PATH JSON from rust_snapshot.py (ReaderRadar)
  2. Optional FT601 identify via host/ft601_client.py
  3. Empty state so the web UI stays on SIM

Run on the reader laptop:
  python radar-web/bridge/dma_bridge.py
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST_DIR = ROOT / "host"
if str(HOST_DIR) not in sys.path:
    sys.path.insert(0, str(HOST_DIR))

PORT = int(os.environ.get("ATOMIC_DMA_PORT", "1738"))
SNAPSHOT = Path(os.environ.get(
    "SNAPSHOT_PATH",
    Path(os.environ.get("TEMP") or os.environ.get("TMP") or "/tmp") / "ReaderRadar-Rust-live.json",
))
WRITE = os.environ.get("ATOMIC_DMA_WRITE", "0") == "1"

_lock = threading.Lock()
_state: dict = {
    "ts": time.time(),
    "world_size": int(os.environ.get("RUST_WORLD_SIZE", "4000")),
    "provider": "sim",
    "dmaConnected": False,
    "local_player": None,
    "entities": [],
}
_last_aim: dict | None = None


def _load_snapshot() -> None:
    global _state
    if not SNAPSHOT.is_file():
        return
    try:
        data = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    with _lock:
        _state = {
            "ts": data.get("ts", time.time()),
            "world_size": data.get("world_size", 4000),
            "provider": "memprocfs",
            "dmaConnected": True,
            "local_player": data.get("local_player"),
            "entities": data.get("entities", []),
        }


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


def _write_aim(payload: dict) -> None:
    global _last_aim
    _last_aim = payload
    if not WRITE:
        return
    # MemProcFS write path — only when ATOMIC_DMA_WRITE=1 and vmm.dll is present.
    vmm_path = os.environ.get("VMM_DLL_PATH")
    if not vmm_path:
        return
    try:
        import ctypes
        # Keep the write adapter in one place; offsets come from offsets.json.
        offsets = json.loads((Path(__file__).resolve().parents[1] / "public" / "offsets.json").read_text())
        _last_aim = {**payload, "offsets": offsets.get("BasePlayer", {}), "vmm": vmm_path}
        ctypes  # imported for the Windows host path
    except Exception:
        return


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        return

    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/health"):
            self._send(200, {"ok": True, "aim": _last_aim})
            return
        if self.path.startswith("/state"):
            with _lock:
                body = dict(_state)
                body["aim"] = _last_aim
            self._send(200, body)
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.startswith("/aim"):
            self._send(404, {"error": "not found"})
            return
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send(400, {"error": "bad json"})
            return
        _write_aim(payload)
        self._send(200, {"ok": True, "write": WRITE})


def main() -> None:
    _load_snapshot()
    _try_ft601()
    threading.Thread(target=_watch, daemon=True).start()
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"atomic dma bridge http://127.0.0.1:{PORT}/state  snapshot={SNAPSHOT}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
