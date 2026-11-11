#!/usr/bin/env python3
"""Offline tests for the read-only DMA bridge (no FT601 required)."""

from __future__ import annotations

import json
import os
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path

import dma_bridge as b


class NormalizeTests(unittest.TestCase):
    def test_reader_radar_entities(self) -> None:
        body = b.normalize_snapshot({
            "ts": 1,
            "world_size": 4500,
            "local_player": {"position": {"x": 10, "y": 2, "z": 30}, "health": 80},
            "entities": [
                {"category": "player", "position": {"x": 1, "y": 2, "z": 3}, "meta": {"name": "A"}},
            ],
        })
        self.assertTrue(body["dmaConnected"])
        self.assertEqual(body["provider"], "memprocfs")
        self.assertEqual(body["world_size"], 4500)
        self.assertEqual(body["entities"][0]["meta"]["name"], "A")
        self.assertEqual(body["local_player"]["health"], 80)

    def test_alias_players_and_world_size(self) -> None:
        body = b.normalize_snapshot({
            "world": {"size": 3000},
            "localPlayer": {"position": {"x": 0, "y": 0, "z": 0}, "health": 1},
            "players": [{"type": "ore-sulfur", "x": 4, "y": 5, "z": 6, "name": "Sulfur"}],
        })
        self.assertEqual(body["world_size"], 3000)
        self.assertEqual(body["entities"][0]["category"], "ore-sulfur")
        self.assertEqual(body["entities"][0]["position"]["x"], 4.0)
        self.assertIsNotNone(body["local_player"])


class MapSafetyTests(unittest.TestCase):
    def test_rejects_traversal_and_remote(self) -> None:
        self.assertIsNone(b._safe_map_file("../etc/passwd"))
        self.assertIsNone(b._safe_map_file("http://evil.example/map.png"))
        self.assertIsNone(b._safe_map_file("javascript:alert(1)"))

    def test_allows_image_under_trusted_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            img = root / "island.png"
            img.write_bytes(b"\x89PNG\r\n\x1a\n")
            old = os.environ.get("ATOMIC_MAP_DIR")
            os.environ["ATOMIC_MAP_DIR"] = str(root)
            try:
                self.assertEqual(b._safe_map_file("island.png"), img.resolve())
                self.assertIsNone(b._safe_map_file(str(root / "nope.jpg")))
            finally:
                if old is None:
                    os.environ.pop("ATOMIC_MAP_DIR", None)
                else:
                    os.environ["ATOMIC_MAP_DIR"] = old


class CorsTests(unittest.TestCase):
    def test_loopback_only(self) -> None:
        self.assertEqual(b._allowed_cors_origin("http://127.0.0.1:5173"), "http://127.0.0.1:5173")
        self.assertEqual(b._allowed_cors_origin("http://localhost:4173"), "http://localhost:4173")
        self.assertIsNone(b._allowed_cors_origin("https://evil.example"))
        self.assertIsNone(b._allowed_cors_origin("http://evil.example"))
        self.assertIsNone(b._allowed_cors_origin("*"))


class HttpTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.snap = Path(self.tmp.name) / "ReaderRadar-Rust-live.json"
        self.snap.write_text(json.dumps({
            "world_size": 4000,
            "local_player": {"position": {"x": 100, "y": 1, "z": 200}, "health": 77, "yaw": 10},
            "entities": [
                {"category": "player", "position": {"x": 110, "y": 1, "z": 210}, "meta": {"name": "Wolf"}},
            ],
        }), encoding="utf-8")
        b.SNAPSHOT = self.snap
        b._state = {
            "ts": 0,
            "world_size": 4000,
            "provider": "sim",
            "dmaConnected": False,
            "local_player": None,
            "entities": [],
            "map_image_path": None,
        }
        b._map_path = None
        b._load_snapshot()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), b.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.httpd.server_address[1]

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def _get(self, path: str, origin: str | None = None) -> tuple[int, dict, dict]:
        conn = HTTPConnection("127.0.0.1", self.port, timeout=2)
        headers = {"Origin": origin} if origin else {}
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        headers_out = dict(resp.getheaders())
        conn.close()
        body = json.loads(raw.decode("utf-8"))
        return resp.status, body, headers_out

    def test_state_is_live_snapshot(self) -> None:
        status, body, _ = self._get("/state")
        self.assertEqual(status, 200)
        self.assertTrue(body["dmaConnected"])
        self.assertEqual(body["provider"], "memprocfs")
        self.assertEqual(body["entities"][0]["meta"]["name"], "Wolf")

    def test_health_readonly(self) -> None:
        status, body, _ = self._get("/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertTrue(body["readonly"])
        self.assertTrue(body["snapshot_present"])

    def test_cors_loopback_reflected(self) -> None:
        _, _, headers = self._get("/state", origin="http://127.0.0.1:5173")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "http://127.0.0.1:5173")
        _, _, headers = self._get("/state", origin="http://evil.example")
        self.assertIsNone(headers.get("Access-Control-Allow-Origin"))

    def test_empty_sim_not_forced_live(self) -> None:
        b._state = {
            "ts": 0,
            "world_size": 4000,
            "provider": "sim",
            "dmaConnected": False,
            "local_player": None,
            "entities": [],
            "map_image_path": None,
        }
        status, body, _ = self._get("/state")
        self.assertEqual(status, 200)
        self.assertFalse(body["dmaConnected"])
        self.assertEqual(body["provider"], "sim")
        self.assertEqual(body["entities"], [])


if __name__ == "__main__":
    unittest.main()
