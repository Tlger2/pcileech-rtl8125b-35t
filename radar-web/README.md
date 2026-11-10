# AtomicDMA — Rust radar (web)

Read-only web radar matching the AtomicDMA overlay: satellite island, loot filter, ESP widget, DMA panel, chams, and visual ESP. Write-memory cheats (aim assist, recoil, eoka, spiderman, jump-shoot, memory features) are not included. DMA is snapshot ingest / FT601 identify-read only.

## Run

```bash
cd radar-web
npm install
npm run dev
```

Open http://127.0.0.1:5173 — starts on a live **SIM** world (seed 1337, size 4000). On join / Reload Map, the view centers on you at in-game map scale. Interactive camera then lets you pan.

## DMA at home

1. Flash the 35T firmware (PR on `cursor/rtl8125b-eac-hide-1fc4`).
2. Run ReaderRadar `rust_snapshot.py` **or** this read-only bridge:

```bash
python radar-web/bridge/dma_bridge.py
```

The UI **Connect DMA** button probes `http://127.0.0.1:1738/state` and `http://127.0.0.1:8080/state` (ReaderRadar). Snapshot schema is the ReaderRadar JSON (`entities[].category/position/meta`, `world_size`, optional `world.map_image_path` basemap).

The bridge serves `GET /state`, `GET /health`, snapshot watch, optional `GET /map`, and optional FT601 identify/read. It does not POST aim angles or write process memory.

This bitstream speaks MAGIC `0x5AA5C33C`, not stock MemProcFS `fpga://`. Use `host/ft601_client.py --identify` plus the bridge; native `fpga://` will not identify until a TLP-stream shim exists.

Offsets in `public/offsets.json` are for ReaderRadar / probe notes only — the web radar never writes them.

## Hotkeys

| Key | Action |
|---|---|
| Insert / F1 | Main menu |
| F2 | Loot filter |
| F3 | ESP widget |
| F4 | Classic radar (web UI off, map + ESP only) |
| F | Follow local player |
| Esc | Close help / menu |
| Drag / wheel | Pan / zoom (with Interactive camera) |
