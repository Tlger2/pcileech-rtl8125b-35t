"""
Host-side protocol driver for the CaptainDMA 35T endpoint.

Protocol frame (little-endian 32-bit DWs on the wire):
    DW0 : MAGIC             = 0x5AA5_C33C
    DW1 : {wire_opcode[7:0], flags[7:0], length_dw[15:0]}
    DW2 : 32-bit target base address
    DW3+: length_dw payload words (for writes; absent for reads)

Opcode scrambling mirrors rtl/opcode_scramble_pkg.sv: internal code is
canonical, on-wire byte is the substituted value. The table is bijective
so decode_opcode(encode_opcode(x)) == x for every defined x.

Transport: FT601 USB 3.0 bridge via pyftdi (libusb backend).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum
from typing import Iterable, Optional

try:
    from pyftdi.usbtools import UsbTools
    from pyftdi.ftdi import Ftdi
    _HAVE_PYFTDI = True
except ImportError:  # pragma: no cover
    _HAVE_PYFTDI = False


FRAME_MAGIC = 0x5AA5_C33C


# ------------------------------------------------------------------
# Opcode LUT — must stay in lock-step with rtl/opcode_scramble_pkg.sv
# ------------------------------------------------------------------
class Opcode(IntEnum):
    NOP          = 0x00
    READ         = 0x01
    WRITE        = 0x02
    READ_BURST   = 0x03
    WRITE_BURST  = 0x04
    INFO         = 0x05
    STATUS       = 0x06
    RESET        = 0x07
    FLUSH        = 0x08
    IRQ_ENABLE   = 0x09
    IRQ_CLEAR    = 0x0A
    HANDSHAKE    = 0x0B
    KEEPALIVE    = 0x0C
    VERSION      = 0x0D
    ABORT        = 0x0E
    SHUTDOWN     = 0x0F
    INVALID      = 0xFF


_FORWARD = {
    Opcode.NOP:         0xA3,
    Opcode.READ:        0x5C,
    Opcode.WRITE:       0xE1,
    Opcode.READ_BURST:  0x7F,
    Opcode.WRITE_BURST: 0x29,
    Opcode.INFO:        0xB6,
    Opcode.STATUS:      0xD4,
    Opcode.RESET:       0x18,
    Opcode.FLUSH:       0x92,
    Opcode.IRQ_ENABLE:  0x4B,
    Opcode.IRQ_CLEAR:   0xF0,
    Opcode.HANDSHAKE:   0x3D,
    Opcode.KEEPALIVE:   0x87,
    Opcode.VERSION:     0x6A,
    Opcode.ABORT:       0xC5,
    Opcode.SHUTDOWN:    0x2E,
}
_REVERSE = {wire: canon for canon, wire in _FORWARD.items()}

# Sanity: bijection, no collisions, no wire byte equals INVALID (0xFF)
assert len(_FORWARD) == len(set(_FORWARD.values())), "wire opcodes not unique"
assert Opcode.INVALID not in _FORWARD.values(), "wire byte collides with INVALID"


def encode_opcode(canon: Opcode | int) -> int:
    """Canonical -> wire. Returns 0xFF for unknown canonical codes."""
    try:
        return _FORWARD[Opcode(canon)]
    except (KeyError, ValueError):
        return Opcode.INVALID.value


def decode_opcode(wire: int) -> Opcode:
    """Wire -> canonical. Returns Opcode.INVALID for unknown wire bytes."""
    return _REVERSE.get(wire & 0xFF, Opcode.INVALID)


# ------------------------------------------------------------------
# Frame format
# ------------------------------------------------------------------
@dataclass
class Frame:
    opcode: Opcode
    flags: int
    address: int
    payload: list[int]   # 32-bit DWs

    @property
    def length_dw(self) -> int:
        return len(self.payload)

    def to_bytes(self) -> bytes:
        """Serialize to little-endian wire form."""
        if self.length_dw > 0xFFFF:
            raise ValueError(f"payload too long: {self.length_dw} DWs > 65535")
        wire_opc = encode_opcode(self.opcode)
        if wire_opc == Opcode.INVALID.value:
            raise ValueError(f"unknown canonical opcode {self.opcode!r}")

        hdr = (wire_opc << 24) | ((self.flags & 0xFF) << 16) | (self.length_dw & 0xFFFF)
        words = [FRAME_MAGIC, hdr, self.address & 0xFFFFFFFF, *self.payload]
        return b"".join(struct.pack("<I", w) for w in words)

    @classmethod
    def from_words(cls, words: Iterable[int]) -> "Frame":
        """Decode a frame from an iterable of 32-bit DWs. The caller is
        responsible for having found the MAGIC; `words` starts at HDR."""
        it = iter(words)
        hdr  = next(it)
        addr = next(it)
        wire_opc = (hdr >> 24) & 0xFF
        flags    = (hdr >> 16) & 0xFF
        length   = hdr & 0xFFFF
        canon    = decode_opcode(wire_opc)
        payload  = [next(it) for _ in range(length)]
        return cls(opcode=canon, flags=flags, address=addr, payload=payload)


def _words(blob: bytes) -> list[int]:
    """Unpack a byte blob to little-endian 32-bit DWs."""
    if len(blob) % 4 != 0:
        raise ValueError(f"blob length {len(blob)} not a multiple of 4")
    return list(struct.unpack(f"<{len(blob)//4}I", blob))


# ------------------------------------------------------------------
# FT601 transport
# ------------------------------------------------------------------
class FT601Client:
    """
    Thin wrapper around pyftdi's FT601 (VID 0x0403, PID 0x601F).

    The FT601 is a SuperSpeed FIFO device, not a UART — pyftdi talks to it
    through its libusb backend. Open with .open() / close with .close() /
    or use as a context manager.

    Usage:
        with FT601Client() as dev:
            dev.reset_endpoint()
            dev.write_dw(0x0000_2000, 0xDEADBEEF)
            v = dev.read_dw(0x0000_2000)
    """

    DEFAULT_VID = 0x0403
    DEFAULT_PID = 0x601F
    READ_CHUNK  = 4096      # bytes per bulk-in read
    IO_TIMEOUT  = 1.0       # seconds

    def __init__(self, vid: int = DEFAULT_VID, pid: int = DEFAULT_PID,
                 index: int = 0):
        if not _HAVE_PYFTDI:
            raise RuntimeError(
                "pyftdi is not installed. pip install pyftdi; and install a "
                "libusb-1.0 backend (on Windows, use Zadig to bind WinUSB to "
                "the FT601 device)."
            )
        self._vid    = vid
        self._pid    = pid
        self._index  = index
        self._ftdi: Optional[Ftdi] = None

    # ------------------------- lifecycle --------------------------
    def open(self) -> "FT601Client":
        self._ftdi = Ftdi()
        url = f"ftdi://0x{self._vid:04x}:0x{self._pid:04x}/{self._index + 1}"
        self._ftdi.open_from_url(url)
        # FT601 synchronous FIFO; no UART-style line settings apply.
        return self

    def close(self) -> None:
        if self._ftdi is not None:
            self._ftdi.close()
            self._ftdi = None

    def __enter__(self) -> "FT601Client":
        return self.open()

    def __exit__(self, *_exc_info) -> None:
        self.close()

    # ------------------------- raw I/O ---------------------------
    def _write_raw(self, blob: bytes) -> int:
        assert self._ftdi is not None, "device not open"
        return self._ftdi.write_data(blob)

    def _read_raw(self, nbytes: int) -> bytes:
        assert self._ftdi is not None, "device not open"
        buf = bytearray()
        while len(buf) < nbytes:
            chunk = self._ftdi.read_data(min(self.READ_CHUNK, nbytes - len(buf)))
            if not chunk:
                break
            buf.extend(chunk)
        return bytes(buf)

    # ------------------------- framing ---------------------------
    def send_frame(self, frame: Frame) -> None:
        blob = frame.to_bytes()
        n = self._write_raw(blob)
        if n != len(blob):
            raise IOError(f"short write: wrote {n} / {len(blob)} bytes")

    def recv_frame(self, expect_payload_dw: int = 0, max_wait: int = 32) -> Frame:
        """
        Pull one response frame off the RX FIFO.

        Scans the byte stream for FRAME_MAGIC, then reads the HDR + ADDR + N
        payload DWs. `max_wait` bounds how many extra DWs we'll skip past
        before giving up looking for MAGIC.
        """
        # Hunt for MAGIC (word-aligned; FT601 returns 32-bit-aligned data)
        buf = bytearray()
        attempts = 0
        while attempts < max_wait:
            buf.extend(self._read_raw(4))
            if len(buf) < 4:
                attempts += 1
                continue
            maybe_magic = struct.unpack("<I", bytes(buf[-4:]))[0]
            if maybe_magic == FRAME_MAGIC:
                break
            attempts += 1
        else:
            raise TimeoutError(f"MAGIC not found within {max_wait} DWs")

        # Read HDR + ADDR to learn the payload length
        hdr_addr = self._read_raw(8)
        if len(hdr_addr) != 8:
            raise IOError("short read on HDR/ADDR")
        hdr, addr = struct.unpack("<II", hdr_addr)
        length_dw = hdr & 0xFFFF
        if expect_payload_dw and length_dw != expect_payload_dw:
            raise IOError(
                f"unexpected payload length: got {length_dw}, want {expect_payload_dw}"
            )

        # Pull the payload (if any)
        pld_bytes = self._read_raw(length_dw * 4) if length_dw else b""
        if len(pld_bytes) != length_dw * 4:
            raise IOError("short read on payload")

        words = [hdr, addr, *_words(pld_bytes)]
        return Frame.from_words(words)

    # ------------------------- high-level API --------------------
    def write_dw(self, address: int, value: int, flags: int = 0) -> None:
        self.send_frame(Frame(
            opcode=Opcode.WRITE,
            flags=flags,
            address=address,
            payload=[value & 0xFFFFFFFF],
        ))

    def write_burst(self, address: int, values: list[int], flags: int = 0) -> None:
        self.send_frame(Frame(
            opcode=Opcode.WRITE_BURST,
            flags=flags,
            address=address,
            payload=[v & 0xFFFFFFFF for v in values],
        ))

    def read_dw(self, address: int, flags: int = 0) -> int:
        self.send_frame(Frame(
            opcode=Opcode.READ,
            flags=flags,
            address=address,
            payload=[],
        ))
        rsp = self.recv_frame(expect_payload_dw=1)
        return rsp.payload[0]

    def read_burst(self, address: int, length_dw: int, flags: int = 0) -> list[int]:
        self.send_frame(Frame(
            opcode=Opcode.READ_BURST,
            flags=flags,
            address=address,
            payload=[],
        ))
        rsp = self.recv_frame(expect_payload_dw=length_dw)
        return rsp.payload

    def ping(self) -> Frame:
        self.send_frame(Frame(
            opcode=Opcode.KEEPALIVE,
            flags=0, address=0, payload=[]
        ))
        return self.recv_frame()

    def get_version(self) -> Frame:
        self.send_frame(Frame(
            opcode=Opcode.VERSION,
            flags=0, address=0, payload=[]
        ))
        return self.recv_frame()

    def reset_endpoint(self) -> None:
        self.send_frame(Frame(
            opcode=Opcode.RESET,
            flags=0, address=0, payload=[]
        ))


# DMA engine register file (byte addresses on the MAGIC/opcode path).
DMA_CTRL = 0x00
DMA_ADDR_LO = 0x04
DMA_ADDR_HI = 0x08
DMA_WDATA = 0x0C
DMA_STATUS = 0x10
DMA_RDATA = 0x14
DMA_LENGTH = 0x18
DMA_BUF = 0x40
DMA_MAX_DW = 32  # 128 B; matches dma_engine MAX_BURST_DW
DMA_GO_READ = 0x1
DMA_GO_WRITE = 0x2

# Donor identity (must match rtl/rtl8125b_identity_pkg.sv)
DONOR_VID = 0x10EC
DONOR_DID = 0x8125
DONOR_REV = 0x05
DONOR_SVID = 0x10EC
DONOR_SSID = 0x0123
DONOR_MAC = bytes((0x00, 0xE0, 0x4C, 0x7A, 0x3B, 0x91))


class LeechCoreAdapter:
    """MemProcFS/LeechCore-shaped identify / read / write on this firmware's
    FT601 MAGIC + scrambled-opcode path.

    ReaderRadar and stock MemProcFS `fpga://` speak the PCILeech-FPGA USB
    dialect (0x77 FIFO + raw TLP stream). This bitstream does not. Use this
    adapter (or ft601_client.FT601Client) against the CaptainDMA FT601 once
    the card is up. Opcode bijection with opcode_scramble_pkg is unchanged.
    """

    def __init__(self, client: FT601Client | None = None):
        self._client = client

    def identify(self) -> dict:
        info = {
            "protocol": "magic-5AA5C33C",
            "pcileech_fpga_tlp_stream": False,
            "vid": DONOR_VID,
            "did": DONOR_DID,
            "rev": DONOR_REV,
            "svid": DONOR_SVID,
            "ssid": DONOR_SSID,
            "mac": DONOR_MAC.hex(":"),
            "dsn": _dsn_from_mac(DONOR_MAC),
            "max_read_bytes": DMA_MAX_DW * 4,
            "fpga_id": "rtl8125b-35t",
        }
        if self._client is None:
            return info
        try:
            info["status"] = self._client.read_dw(DMA_STATUS)
        except Exception as exc:  # hardware optional
            info["status_error"] = str(exc)
        return info

    def read(self, pa: int, size: int) -> bytes:
        if self._client is None:
            raise RuntimeError("FT601 client is required for DMA read")
        if size < 0:
            raise ValueError("size must be >= 0")
        out = bytearray()
        while size:
            chunk = min(size, DMA_MAX_DW * 4)
            dws = (chunk + 3) // 4
            self._program_addr(pa)
            self._client.write_dw(DMA_LENGTH, dws)
            self._client.write_dw(DMA_CTRL, DMA_GO_READ)
            words = self._client.read_burst(DMA_BUF, dws)
            raw = b"".join(struct.pack("<I", w) for w in words)
            out.extend(raw[:chunk])
            pa += chunk
            size -= chunk
        return bytes(out)

    def write(self, pa: int, data: bytes) -> None:
        if self._client is None:
            raise RuntimeError("FT601 client is required for DMA write")
        off = 0
        while off < len(data):
            chunk = data[off:off + DMA_MAX_DW * 4]
            padded = chunk + bytes((4 - (len(chunk) % 4)) % 4)
            words = list(struct.unpack(f"<{len(padded)//4}I", padded))
            self._program_addr(pa + off)
            self._client.write_dw(DMA_LENGTH, len(words))
            self._client.write_burst(DMA_BUF, words)
            self._client.write_dw(DMA_CTRL, DMA_GO_WRITE)
            off += len(chunk)

    def _program_addr(self, pa: int) -> None:
        self._client.write_dw(DMA_ADDR_LO, pa & 0xFFFFFFFF)
        self._client.write_dw(DMA_ADDR_HI, (pa >> 32) & 0xFFFFFFFF)


def _dsn_from_mac(mac: bytes) -> str:
    dsn_lo = (mac[3] << 24) | (mac[4] << 16) | (mac[5] << 8)
    dsn_hi = (mac[0] << 16) | (mac[1] << 8) | mac[2]
    return f"{dsn_hi:08x}{dsn_lo:08x}"


# ------------------------------------------------------------------
# Self-test: offline bijection + round-trip framing (no hardware)
# ------------------------------------------------------------------
def _selftest() -> None:
    # Bijection
    for op, wire in _FORWARD.items():
        assert decode_opcode(wire) == op, f"round-trip failed for {op}"
    assert decode_opcode(0x00) == Opcode.INVALID  # 0x00 is NOT a wire opcode
    assert encode_opcode(0xFE) == Opcode.INVALID  # unknown canonical

    # Frame round-trip
    f = Frame(
        opcode=Opcode.WRITE_BURST,
        flags=0x00,
        address=0x0000_1000,
        payload=[0xDEAD_BEEF, 0xCAFE_F00D, 0x1234_5678, 0xA5A5_5A5A],
    )
    blob  = f.to_bytes()
    words = _words(blob)
    assert words[0] == FRAME_MAGIC
    wire_opc = (words[1] >> 24) & 0xFF
    assert wire_opc == _FORWARD[Opcode.WRITE_BURST]
    assert (words[1] & 0xFFFF) == 4
    assert words[2] == 0x0000_1000
    f2 = Frame.from_words(words[1:])
    assert f2.opcode == Opcode.WRITE_BURST
    assert f2.address == 0x0000_1000
    assert f2.payload == f.payload

    ident = LeechCoreAdapter().identify()
    assert ident["vid"] == DONOR_VID and ident["did"] == DONOR_DID
    assert ident["rev"] == DONOR_REV
    assert ident["pcileech_fpga_tlp_stream"] is False
    assert ident["mac"] == "00:e0:4c:7a:3b:91"
    assert ident["dsn"] == _dsn_from_mac(DONOR_MAC)
    assert ident["max_read_bytes"] == 128

    # Adapter read/write require a client; packing of a 128 B burst is
    # still checked through Frame so the DMA LENGTH path stays aligned.
    burst = Frame(
        opcode=Opcode.WRITE_BURST,
        flags=0,
        address=DMA_BUF,
        payload=list(range(DMA_MAX_DW)),
    )
    assert burst.length_dw == DMA_MAX_DW
    assert (burst.to_bytes()[4] & 0xFF) == DMA_MAX_DW  # length_dw low byte
    print("ft601_client self-test: OK")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true",
                    help="run offline bijection + frame round-trip")
    ap.add_argument("--ping", action="store_true",
                    help="open FT601, send KEEPALIVE, print response")
    ap.add_argument("--read", type=lambda x: int(x, 0),
                    help="read one DW from the given address and print")
    ap.add_argument("--write", nargs=2, type=lambda x: int(x, 0),
                    metavar=("ADDR", "VALUE"),
                    help="write one DW to the given address")
    ap.add_argument("--identify", action="store_true",
                    help="print LeechCore-shaped identify (offline if no FT601)")
    args = ap.parse_args()

    if args.selftest:
        _selftest()
    if args.identify:
        try:
            with FT601Client() as dev:
                print(LeechCoreAdapter(dev).identify())
        except Exception:
            print(LeechCoreAdapter().identify())
    if args.ping:
        with FT601Client() as dev:
            print(dev.ping())
    if args.read is not None:
        with FT601Client() as dev:
            print(f"0x{dev.read_dw(args.read):08X}")
    if args.write is not None:
        with FT601Client() as dev:
            dev.write_dw(args.write[0], args.write[1])
            print("OK")
