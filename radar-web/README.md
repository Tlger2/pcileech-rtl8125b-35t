# AtomicDMA — Rust radar (web)

Web UI on top of the classic radar: full island map, loot filter, ESP widget, DMA panel, chams, hack functions, and aim assist. Layout matches AtomicDMA.

## Run

```bash
cd radar-web
npm install
npm run dev
```

Open http://127.0.0.1:5173 — starts on a live **SIM** world (seed 1337, size 4000) so the overlay is usable without the card.

## DMA at home

1. Flash the 35T firmware (PR on `cursor/rtl8125b-eac-hide-1fc4`).
2. Run ReaderRadar `rust_snapshot.py` **or** this bridge:

```bash
python radar-web/bridge/dma_bridge.py
```

The UI **Connect DMA** button probes `http://127.0.0.1:1738/state` and `http://127.0.0.1:8080/state` (ReaderRadar). Snapshot schema is the ReaderRadar JSON (`entities[].category/position/meta`).

Aim write: enable **Allow memory features** in the menu. The UI POSTs `{pitch,yaw,bone,targetId}` to `:1738/aim`. The bridge applies it only when `ATOMIC_DMA_WRITE=1` and MemProcFS is present. Offsets: `public/offsets.json` (edit after `rust_probe.py`).

This bitstream speaks MAGIC `0x5AA5C33C`, not stock MemProcFS `fpga://`. Use `host/ft601_client.py --identify` plus the bridge; native `fpga://` will not identify until a TLP-stream shim exists.

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
