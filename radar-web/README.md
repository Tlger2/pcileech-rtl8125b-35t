# Never Banned — Rust radar (web)

> “in the end you are never truly banned” — Hellon Wong

Read-only web radar: Facepunch-style satellite island (teal ocean, canopy, dirt roads, ice-cap snow — not cartoon cloud masses), loot filter, ESP widget, DMA panel. Write-memory cheats are not included. DMA is snapshot ingest / FT601 identify-read only. When the bridge serves `GET /map`, that raster is the basemap; otherwise the SIM paints a procedural G-map.

## Run (SIM)

```bash
cd radar-web
npm install
npm run dev
```

Open http://127.0.0.1:5173 — live **SIM** world until Connect DMA succeeds. Insert opens the menu. Set **DMA source** (default `http://127.0.0.1:1738/state`, saved in localStorage) if the bridge is on another port.

## Two-PC (laptop runbook)

Game PC: card in PCIe, Windows, `RustClient.exe`. Laptop: USB3 to FT601 (`VID 0403 PID 601F`). This cloud VM is not the laptop and has no FT601.

1. On the laptop, pull this radar branch:

```bash
git fetch origin
git checkout cursor/atomic-rust-radar-ui-1fc4
git pull origin cursor/atomic-rust-radar-ui-1fc4
```

2. Windows laptop: Zadig → bind **WinUSB** to FT601 (`VID 0403 PID 601F`).

3. USB attached to the **laptop**:

```bash
pip install pyftdi
python host/ft601_client.py --selftest
python host/ft601_client.py --identify
```

`--identify` must show `"usb": true`. `"magic_ok": true` means this repo’s MAGIC `0x5AA5C33C` bitstream answered. `"magic_ok": false` with USB present is normal on **stock CaptainDMA** firmware.

4. ReaderRadar / MemProcFS on the laptop (stock `fpga` firmware):

```text
MEMPROCFS_DIR=<MemProcFS>
VMM_DEVICE=fpga
```

Run `rust_snapshot.py` against `RustClient.exe` on the game PC. Snapshot path defaults to `%TEMP%/ReaderRadar-Rust-live.json` (override with `SNAPSHOT_PATH`).

5. Bridge + radar on the laptop:

```bash
python radar-web/bridge/dma_bridge.py
cd radar-web && npm install && npm run dev
```

Open http://127.0.0.1:5173 → Insert → DMA source `http://127.0.0.1:1738/state` (or ReaderRadar `http://127.0.0.1:8080/state`) → **Connect DMA**. If the bridge is down, the SIM world stays. Disconnect returns to SIM.

Bridge: `GET /state`, `GET /health`, `GET /identify`, `GET /map`. Read-only. CORS is loopback-only. Map files only from the trusted maps dir (`ATOMIC_MAP_DIR`, snapshot `maps/`, or `radar-web/maps`).

## Firmware fork (identify vs `fpga`)

This cloud environment never built a bitstream (no Vivado).

| Card firmware | Laptop path |
|---|---|
| Stock CaptainDMA | MemProcFS `VMM_DEVICE=fpga` + `rust_snapshot.py` + this bridge/UI |
| This repo MAGIC `0x5AA5C33C` | PR **#5** `cursor/rtl8125b-eac-hide-1fc4`. Needs a **Vivado flash on the 35T**. Then `host/ft601_client.py --identify` (`magic_ok`). Native `fpga://` will not identify this bitstream until a TLP-stream shim exists. |

Offsets in `public/offsets.json` are notes only — the web radar never writes them.

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
