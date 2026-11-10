#!/usr/bin/env python3
"""Compare an `lspci -xxx -d 10ec:8125` dump to the RTL8125B donor identity.

This cloud VM cannot see L1. Run on the desktop that has the card:

    lspci -xxx -d 10ec:8125 > /tmp/8125.xxx
    python3 scripts/lspci_check.py /tmp/8125.xxx

Offline: python3 scripts/lspci_check.py --selftest
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "host"))
from ft601_client import DONOR_DID, DONOR_MAC, DONOR_REV, DONOR_SSID, DONOR_SVID, DONOR_VID, _dsn_from_mac  # noqa: E402

CAP_PM, CAP_MSI, CAP_PCIE, CAP_MSIX, CAP_VPD = 0x01, 0x05, 0x10, 0x11, 0x03
ECAP_AER, ECAP_DSN, ECAP_TPH, ECAP_LTR, ECAP_L1PM, ECAP_VSEC = (
    0x0001, 0x0003, 0x0017, 0x0018, 0x001E, 0x000B,
)


def parse_lspci_xxx(text: str) -> bytes:
    """Parse `lspci -xxx` hex rows (`00: ec 10 25 81 ...`) into a bytearray."""
    blob = bytearray(4096)
    filled = 0
    for line in text.splitlines():
        m = re.match(r"^\s*([0-9a-fA-F]{2}):\s+((?:[0-9a-fA-F]{2}\s*)+)$", line)
        if not m:
            continue
        off = int(m.group(1), 16)
        vals = [int(x, 16) for x in m.group(2).split()]
        for i, v in enumerate(vals):
            if off + i < len(blob):
                blob[off + i] = v
                filled = max(filled, off + i + 1)
    return bytes(blob[: max(filled, 256)])


def _dw(cfg: bytes, off: int) -> int:
    return int.from_bytes(cfg[off : off + 4], "little")


def _w(cfg: bytes, off: int) -> int:
    return int.from_bytes(cfg[off : off + 2], "little")


def check(cfg: bytes) -> list[str]:
    fail: list[str] = []
    if _w(cfg, 0) != DONOR_VID or _w(cfg, 2) != DONOR_DID:
        fail.append(f"VID:DID {cfg[0]:02x}{cfg[1]:02x}:{cfg[2]:02x}{cfg[3]:02x}")
    if cfg[8] != DONOR_REV:
        fail.append(f"rev {cfg[8]:02x} want {DONOR_REV:02x}")
    if cfg[9:12] != bytes((0x00, 0x00, 0x02)):
        fail.append(f"class {cfg[9]:02x}{cfg[10]:02x}{cfg[11]:02x}")
    if _w(cfg, 0x2C) != DONOR_SVID or _w(cfg, 0x2E) != DONOR_SSID:
        fail.append("SVID/SSID")
    if cfg[0x34] != 0x40:
        fail.append(f"CapPtr {cfg[0x34]:02x} want 40")
    bar0, bar2, bar4 = _dw(cfg, 0x10), _dw(cfg, 0x18), _dw(cfg, 0x20)
    if (bar0 & 1) != 1:
        fail.append("BAR0 is not I/O")
    if (bar2 & 0x7) != 0x4:
        fail.append("BAR2 is not 64-bit non-prefetch MEM")
    if (bar4 & 0x7) != 0x4:
        fail.append("BAR4 is not 64-bit non-prefetch MEM")
    if cfg[0x40] != CAP_PM:
        fail.append(f"PM@40 id {cfg[0x40]:02x}")
    # Walk standard caps; donor is PM@40 → MSI@50 → PCIe@70 → MSI-X@B0.
    ptr = cfg[0x34]
    seen: dict[int, int] = {}
    guard = 0
    while ptr and ptr != 0xFF and guard < 16:
        seen[cfg[ptr]] = ptr
        ptr = cfg[ptr + 1]
        guard += 1
    for cap, off in ((CAP_PM, 0x40), (CAP_MSI, 0x50), (CAP_PCIE, 0x70), (CAP_MSIX, 0xB0)):
        if seen.get(cap) != off:
            fail.append(f"cap {cap:#x} at {seen.get(cap, 0):#x} want {off:#x}")
    if 0xB0 + 2 < len(cfg):
        msix_ctl = _w(cfg, 0xB0 + 2)
        table_size = (msix_ctl & 0x7FF) + 1
        if table_size != 32:
            fail.append(f"MSI-X table size {table_size} want 32")
        table = _dw(cfg, 0xB4)
        pba = _dw(cfg, 0xB8)
        if (table & 7) != 4:
            fail.append("MSI-X table BIR != 4")
        if (pba & 7) != 4 or (pba & ~7) != 0x800:
            fail.append(f"MSI-X PBA {pba:#x} want BIR4 + 0x800")
    if len(cfg) >= 0x174:
        dsn_hdr = _dw(cfg, 0x168)
        if (dsn_hdr & 0xFFFF) == ECAP_DSN:
            dsn = (_dw(cfg, 0x170) << 32) | _dw(cfg, 0x16C)
            want = int(_dsn_from_mac(DONOR_MAC), 16)
            if dsn != want:
                fail.append(f"DSN {dsn:016x} want {want:016x}")
        elif dsn_hdr & 0xFFFF:
            fail.append(f"ECAP@168 id {dsn_hdr & 0xFFFF:#x} want DSN")
    return fail


def _synthetic() -> bytes:
    cfg = bytearray(0x220)
    cfg[0:2] = DONOR_VID.to_bytes(2, "little")
    cfg[2:4] = DONOR_DID.to_bytes(2, "little")
    cfg[8] = DONOR_REV
    cfg[9:12] = bytes((0x00, 0x00, 0x02))
    cfg[0x10:0x14] = (0x0000D001).to_bytes(4, "little")  # I/O
    cfg[0x18:0x1C] = (0xF7000004).to_bytes(4, "little")  # MEM64 npref
    cfg[0x20:0x24] = (0xF7800004).to_bytes(4, "little")
    cfg[0x2C:0x2E] = DONOR_SVID.to_bytes(2, "little")
    cfg[0x2E:0x30] = DONOR_SSID.to_bytes(2, "little")
    cfg[0x34] = 0x40
    cfg[0x40] = CAP_PM
    cfg[0x41] = 0x50
    cfg[0x50] = CAP_MSI
    cfg[0x51] = 0x70
    cfg[0x70] = CAP_PCIE
    cfg[0x71] = 0xB0
    cfg[0xB0] = CAP_MSIX
    cfg[0xB1] = 0xD0
    cfg[0xB2:0xB4] = (31).to_bytes(2, "little")  # N-1 = 31 → 32 vectors
    cfg[0xB4:0xB8] = (4).to_bytes(4, "little")
    cfg[0xB8:0xBC] = (0x800 | 4).to_bytes(4, "little")
    cfg[0xD0] = CAP_VPD
    cfg[0xD1] = 0x00
    cfg[0x168:0x16C] = (0x178 << 20 | 0x1 << 16 | ECAP_DSN).to_bytes(4, "little")
    dsn = int(_dsn_from_mac(DONOR_MAC), 16)
    cfg[0x16C:0x170] = (dsn & 0xFFFFFFFF).to_bytes(4, "little")
    cfg[0x170:0x174] = (dsn >> 32).to_bytes(4, "little")
    return bytes(cfg)


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        fail = check(_synthetic())
        if fail:
            print("selftest FAIL:", "; ".join(fail))
            return 1
        print("lspci_check self-test: OK")
        return 0
    if len(argv) < 2:
        print(__doc__)
        return 2
    text = Path(argv[1]).read_text(encoding="utf-8", errors="replace")
    fail = check(parse_lspci_xxx(text))
    if fail:
        print("MISMATCH vs donor RTL8125B rev 05:")
        for line in fail:
            print(" -", line)
        print("Patch vivado_build.tcl pcie_7x CONFIG (not only the soft header), rebuild, reprogram.")
        return 1
    print("OK: IDs, BARs, cap pointers, MSI-X, DSN match donor")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
