#!/usr/bin/env python3
# lang: Python3, file: rust_dma.py, target: Windows 11 / Python 3.12
# DMA tool for Rust (game) — phys read + EPROCESS scan via CaptainDMA 35T / RTL8125B spoof
# usage: python host\rust_dma.py [--ping] [--dma-test] [--find-procs [--quick]]

import argparse
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))

from ft601_client import (
    FT601Client,
    DMA_CTRL, DMA_ADDR_LO, DMA_ADDR_HI,
    DMA_LENGTH, DMA_STATUS, DMA_RDATA, DMA_WDATA,
    DMA_GO_READ, DMA_MAX_DW,
)

# ── DMA read ──────────────────────────────────────────────────────────────────
# FPGA DMA engine: max DMA_MAX_DW (32) DWORDs = 128 bytes per transfer.
# Larger reads are chunked automatically.

_STATUS_POLL_MAX = 2000   # iterations before giving up on a DMA transfer


def read_phys(client: FT601Client, addr: int, length: int) -> bytes:
    """Read `length` bytes from physical address `addr` via DMA register engine."""
    if length <= 0:
        return b''

    result = bytearray()
    offset = 0

    while offset < length:
        chunk_bytes = min(length - offset, DMA_MAX_DW * 4)
        chunk_dw   = (chunk_bytes + 3) // 4
        pa         = addr + offset

        # program address
        client.write_dw(DMA_ADDR_LO, pa & 0xFFFF_FFFF)
        client.write_dw(DMA_ADDR_HI, (pa >> 32) & 0xFFFF_FFFF)
        # program length and fire
        client.write_dw(DMA_LENGTH, chunk_dw)
        client.write_dw(DMA_CTRL,   DMA_GO_READ)

        # poll completion
        for _ in range(_STATUS_POLL_MAX):
            if client.read_dw(DMA_STATUS):
                break
        else:
            raise TimeoutError(f"DMA timeout @ PA {pa:#018x} (offset {offset})")

        # drain RDATA FIFO
        chunk_data = client.read_burst(DMA_RDATA, chunk_dw)
        result.extend(bytes(chunk_data)[:chunk_bytes])
        offset += chunk_bytes

    return bytes(result)


# ── Win11 22H2+ EPROCESS offsets ─────────────────────────────────────────────
# re-derive after major Win updates: dt nt!_EPROCESS in WinDbg
EP_UNIQUE_PID   = 0x440
EP_ACTIVE_LINKS = 0x448   # LIST_ENTRY.Flink → next EPROCESS.ActiveProcessLinks
EP_IMAGE_NAME   = 0x5A8   # UCHAR[15], null-padded
EP_CR3          = 0x028   # DirectoryTableBase inside _KPROCESS (at EPROCESS+0)

SYSTEM_PID   = 4
MAX_PROCS    = 512


# ── helpers ───────────────────────────────────────────────────────────────────

def _u64(client, pa: int) -> int:
    d = read_phys(client, pa, 8)
    return struct.unpack_from('<Q', d)[0] if len(d) >= 8 else 0


def _str(client, pa: int, n: int = 15) -> str:
    return read_phys(client, pa, n).split(b'\x00')[0].decode('ascii', errors='replace')


# ── EPROCESS brute scan ───────────────────────────────────────────────────────
# Scan low RAM for SYSTEM EPROCESS (PID=4, ImageFileName="System").
# Chunked at DMA_MAX_DW*4 per read internally, but we walk in 128-byte strides
# since EPROCESS is at least that big and 0x10-aligned.

SCAN_START = 0x0010_0000     # skip first 1 MB (IVT/BIOS)
SCAN_END   = 0x0800_0000     # 128 MB — SYSTEM always here
SCAN_BUF   = 0x0004_0000     # 256 KB working buffer per outer loop
STEP       = 0x10            # EPROCESS is 0x10-aligned


def find_system_eprocess(client: FT601Client) -> int:
    print(f"  scanning PA {SCAN_START:#010x}–{SCAN_END:#010x} …", flush=True)
    pa = SCAN_START
    while pa < SCAN_END:
        end    = min(pa + SCAN_BUF, SCAN_END)
        length = end - pa
        sys.stdout.write(f"\r  [{pa:#010x}] …")
        sys.stdout.flush()
        try:
            buf = read_phys(client, pa, length)
        except Exception as exc:
            print(f"\n  read error @ {pa:#010x}: {exc}")
            pa += SCAN_BUF
            continue

        for off in range(0, len(buf) - 0x600, STEP):
            pid = struct.unpack_from('<Q', buf, off + EP_UNIQUE_PID)[0]
            if pid != SYSTEM_PID:
                continue
            name = buf[off + EP_IMAGE_NAME: off + EP_IMAGE_NAME + 15].split(b'\x00')[0]
            if name.lower() == b'system':
                ep_pa = pa + off
                print(f"\n  SYSTEM EPROCESS @ PA {ep_pa:#010x}")
                return ep_pa
        pa += SCAN_BUF

    print("\n  not found in scanned range")
    return 0


# ── process walk ──────────────────────────────────────────────────────────────

def walk_procs(client: FT601Client, system_ep_pa: int):
    """Yield (ep_pa, pid, name, cr3) for every process."""
    seen = set()
    head = _u64(client, system_ep_pa + EP_ACTIVE_LINKS)
    if not head:
        return
    cur = head
    for _ in range(MAX_PROCS):
        if cur in seen:
            break
        seen.add(cur)
        ep   = cur - EP_ACTIVE_LINKS
        pid  = _u64(client, ep + EP_UNIQUE_PID)
        name = _str(client, ep + EP_IMAGE_NAME)
        cr3  = _u64(client, ep + EP_CR3)
        yield (ep, pid, name, cr3)
        nxt = _u64(client, cur)
        if not nxt or nxt == head:
            break
        cur = nxt


# ── VA → PA page-table walk ───────────────────────────────────────────────────

def va_to_pa(client: FT601Client, cr3: int, va: int) -> int:
    """4-level page-table walk (4 KB pages). Returns PA or 0 if not present."""
    base = cr3 & ~0xFFF
    for level in range(4):
        idx      = (va >> (39 - level * 9)) & 0x1FF
        entry_pa = base + idx * 8
        entry    = _u64(client, entry_pa)
        if not (entry & 1):
            return 0
        if level == 3:
            return (entry & 0x000F_FFFF_FFFF_F000) | (va & 0xFFF)
        if entry & (1 << 7):   # large page
            if level == 1:     # 1 GB
                return (entry & 0x000F_FFFF_C000_0000) | (va & 0x3FFF_FFFF)
            if level == 2:     # 2 MB
                return (entry & 0x000F_FFFF_FFE0_0000) | (va & 0x1F_FFFF)
        base = entry & 0x000F_FFFF_FFFF_F000
    return 0


# ── IN-endpoint drain ─────────────────────────────────────────────────────────
# After USB idle the FPGA queues KEEPALIVE frames in its FT601 output FIFO.
# If that FIFO is full the FPGA state machine won't service the TX (OUT) side,
# causing bulk-OUT timeout on the very first write.  Draining IN first breaks
# the deadlock.  Uses raw libusb reads so it works even before any OUT succeeds.

EP_IN_ADDR = 0x82      # matches iface=1 IN endpoint printed by ft601_client
_DRAIN_N   = 32        # max frames to discard
_DRAIN_TO  = 150       # ms per read attempt


def _drain_in(client: FT601Client):
    try:
        dev = client._dev          # usb.core.Device (confirmed by traceback)
        for _ in range(_DRAIN_N):
            try:
                dev.read(EP_IN_ADDR, 512, timeout=_DRAIN_TO)
            except Exception:
                break              # timeout = no more data queued, done
    except Exception:
        pass                       # best-effort; proceed regardless


# ── commands ──────────────────────────────────────────────────────────────────

def cmd_ping(client: FT601Client):
    frame = client.ping()
    print(f"OK: {frame!r}")


def cmd_dma_test(client: FT601Client):
    print("reading 128 bytes from PA=0x0 …")
    data = read_phys(client, 0x0, 128)
    print(f"got {len(data)} bytes")
    for row in range(0, min(len(data), 128), 16):
        chunk    = data[row:row+16]
        hex_part = ' '.join(f'{b:02x}' for b in chunk)
        asc_part = ''.join(chr(b) if 0x20 <= b < 0x7f else '.' for b in chunk)
        print(f"  {row:04x}:  {hex_part:<47}  {asc_part}")


def cmd_find_procs(client: FT601Client, quick: bool):
    ep_pa = find_system_eprocess(client)
    if not ep_pa:
        print("failed to locate SYSTEM EPROCESS")
        return

    print(f"\n{'PA':>18}  {'PID':>6}  {'CR3':>18}  NAME")
    print('-' * 70)
    rust_hits = []
    for ep, pid, name, cr3 in walk_procs(client, ep_pa):
        print(f"  {ep:#018x}  {pid:>6}  {cr3:#018x}  {name}")
        if 'rust' in name.lower():
            rust_hits.append((ep, pid, name, cr3))
            if quick:
                break

    if rust_hits:
        print('\n── rust.exe found ──')
        for ep, pid, name, cr3 in rust_hits:
            print(f"  ep={ep:#018x}  pid={pid}  cr3={cr3:#018x}  name={name!r}")
    else:
        print('\nrust.exe not found (game running?)')


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description='CaptainDMA 35T / Rust DMA tool')
    ap.add_argument('--ping',       action='store_true')
    ap.add_argument('--dma-test',   action='store_true')
    ap.add_argument('--find-procs', action='store_true')
    ap.add_argument('--quick',      action='store_true', help='stop walk at first rust.exe')
    args = ap.parse_args()

    if not any([args.ping, args.dma_test, args.find_procs]):
        ap.print_help()
        sys.exit(0)

    client = FT601Client()
    client.open()
    # _drain_in removed: raw libusb read bypasses pyftdi state machine and
    # causes EP OUT timeout.  recv_frame's MAGIC scanner handles stale RX data.
    try:
        if args.ping:
            cmd_ping(client)
        if args.dma_test:
            cmd_dma_test(client)
        if args.find_procs:
            cmd_find_procs(client, quick=args.quick)
    finally:
        client.close()


if __name__ == '__main__':
    main()
