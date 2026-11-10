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

Transport: FT601 SuperSpeed FIFO via pyusb/libusb WinUSB bulk transfers
(VID 0x0403, PID 0x601F). After set_configuration the client walks every
interface and altsetting and binds the first bulk IN+OUT pair, preferring
OUT 0x02 + IN 0x82 (PCILeech/CaptainDMA). The FT601 is not an
FT232/FT2232 UART; pyftdi's Ftdi product table has no 0x601F and cannot
open it.
"""

from __future__ import annotations

import struct
import sys
from dataclasses import dataclass
from enum import IntEnum
from typing import Iterable, Optional

try:
    import usb.backend.libusb1
    import usb.core
    import usb.util
    _HAVE_PYUSB = True
except ImportError:  # pragma: no cover
    usb = None  # type: ignore[assignment]
    _HAVE_PYUSB = False


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
    # Reads put the requested DW count in HDR length_dw with an empty
    # payload. Writes use len(payload). Independent so READ_BURST of 32
    # DWs (128 B) is not serialized as length 0.
    req_length_dw: int | None = None

    @property
    def length_dw(self) -> int:
        if self.req_length_dw is not None:
            return self.req_length_dw
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
# FT601 transport (pyusb WinUSB bulk, not pyftdi UART)
# ------------------------------------------------------------------
_LIBUSB_HINT = (
    "On Windows bind WinUSB to 0403:601F (Zadig; the interface with bulk "
    "pipes, often MI_00) and put libusb-1.0.dll on PATH; on Linux install "
    "libusb-1.0."
)

# FT601 EEPROM layouts: 1 / 2 / 4 FIFO channels, usually bConfigurationValue 1.
_FT601_CONFIG_VALUES = (1, 2, 3, 4)
_FT601_INTERFACE = 0  # MI_00 default; open() walks every iface/alt
_PREF_EP_OUT = 0x02
_PREF_EP_IN = 0x82
_EP_TYPE_MASK = 0x03
_EP_DIR_MASK = 0x80
_XFER_NAMES = {0: "ctrl", 1: "iso", 2: "bulk", 3: "int"}


def _is_usb_timeout(exc: BaseException) -> bool:
    if "timeout" in type(exc).__name__.lower():
        return True
    errno = getattr(exc, "errno", None)
    if errno in (-7, 110, 60, 10060):  # LIBUSB_ERROR_TIMEOUT, ETIMEDOUT, WSAETIMEDOUT
        return True
    return "timeout" in str(exc).lower()


def _libusb_backend():
    """Return the libusb-1.0 pyusb backend, or raise a WinUSB/DLL-oriented error."""
    if not _HAVE_PYUSB:
        raise RuntimeError("pyusb is not installed. pip install pyusb. " + _LIBUSB_HINT)
    try:
        backend = usb.backend.libusb1.get_backend()
    except Exception as exc:
        raise RuntimeError(
            f"pyusb could not load the libusb-1.0 backend ({exc}). {_LIBUSB_HINT}"
        ) from exc
    if backend is None:
        raise RuntimeError("pyusb found no libusb-1.0 backend. " + _LIBUSB_HINT)
    return backend


def _find_ft601(vid: int, pid: int, index: int = 0):
    backend = _libusb_backend()
    no_backend = getattr(usb.core, "NoBackendError", RuntimeError)
    try:
        found = list(usb.core.find(
            find_all=True, idVendor=vid, idProduct=pid, backend=backend,
        ))
    except no_backend as exc:
        raise RuntimeError(
            "pyusb found no libusb-1.0 backend. " + _LIBUSB_HINT
        ) from exc
    if not found:
        raise RuntimeError(
            f"FT601 {vid:04x}:{pid:04x} not found on USB. {_LIBUSB_HINT}"
        )
    if index < 0 or index >= len(found):
        raise RuntimeError(
            f"FT601 index {index} out of range ({len(found)} device(s) matched)"
        )
    return found[index]


def _configure_ft601(dev) -> None:
    """set_configuration, then common FT601 config values, then the active one."""
    try:
        dev.set_configuration()
        return
    except usb.core.USBError:
        pass
    values: list[int] = []
    try:
        values = [int(cfg.bConfigurationValue) for cfg in dev]
    except Exception:
        values = []
    for value in list(dict.fromkeys([*values, *_FT601_CONFIG_VALUES])):
        try:
            dev.set_configuration(value)
            return
        except usb.core.USBError:
            continue
    try:
        dev.get_active_configuration()
    except usb.core.USBError as exc:
        raise RuntimeError(
            f"FT601 set_configuration failed ({exc}). {_LIBUSB_HINT}"
        ) from exc


def _usb_error_type():
    if _HAVE_PYUSB:
        return getattr(usb.core, "USBError", Exception)
    return Exception


def _format_descriptor_dump(dev) -> str:
    """Compact cfg/iface/alt/ep dump for pasting when open fails."""
    lines: list[str] = []
    try:
        configs = list(dev)
    except Exception as exc:
        return f"(descriptor walk failed: {exc})"
    if not configs:
        return "(no USB configurations)"
    for cfg in configs:
        try:
            cfg_val = int(cfg.bConfigurationValue)
        except Exception:
            cfg_val = -1
        try:
            intfs = list(cfg)
        except Exception as exc:
            lines.append(f"cfg={cfg_val} (interface walk failed: {exc})")
            continue
        if not intfs:
            lines.append(f"cfg={cfg_val} (no interfaces)")
            continue
        for intf in intfs:
            try:
                iface = int(intf.bInterfaceNumber)
                alt = int(intf.bAlternateSetting)
            except Exception:
                iface, alt = -1, -1
            try:
                eps = list(intf)
            except Exception as exc:
                lines.append(
                    f"cfg={cfg_val} iface={iface} alt={alt} (ep walk failed: {exc})"
                )
                continue
            if not eps:
                lines.append(f"cfg={cfg_val} iface={iface} alt={alt} (no endpoints)")
                continue
            for ep in eps:
                addr = int(getattr(ep, "bEndpointAddress", 0))
                bm = int(getattr(ep, "bmAttributes", 0))
                maxpkt = int(getattr(ep, "wMaxPacketSize", 0))
                typ = _XFER_NAMES.get(bm & _EP_TYPE_MASK, str(bm & _EP_TYPE_MASK))
                lines.append(
                    f"cfg={cfg_val} iface={iface} alt={alt} "
                    f"ep=0x{addr:02x} type={typ} maxpkt={maxpkt}"
                )
    return "\n".join(lines)


def _print_descriptor_dump(dev) -> str:
    dump = _format_descriptor_dump(dev)
    print(dump, file=sys.stderr)
    return dump


def _claim_interface(dev, intf_num: int) -> None:
    try:
        if bool(dev.is_kernel_driver_active(intf_num)):
            dev.detach_kernel_driver(intf_num)
    except (NotImplementedError, ValueError, _usb_error_type()):
        pass
    try:
        usb.util.claim_interface(dev, intf_num)
    except Exception as exc:
        dump = _print_descriptor_dump(dev)
        if intf_num != 0:
            raise RuntimeError(
                f"could not claim FT601 interface {intf_num} "
                f"(Zadig WinUSB on that interface): {exc}. {_LIBUSB_HINT}\n{dump}"
            ) from exc
        raise RuntimeError(
            f"could not claim FT601 interface {intf_num} (MI_00): {exc}. "
            f"{_LIBUSB_HINT}\n{dump}"
        ) from exc


def _bulk_pair(intf):
    """Return (bulk_out, bulk_in) on this iface/alt, preferring 0x02/0x82."""
    outs: list = []
    ins: list = []
    for ep in intf:
        bm = int(getattr(ep, "bmAttributes", 0))
        if (bm & _EP_TYPE_MASK) != 2:
            continue
        addr = int(ep.bEndpointAddress)
        if addr & _EP_DIR_MASK:
            ins.append(ep)
        else:
            outs.append(ep)
    if not outs or not ins:
        return None, None
    ep_out = next(
        (e for e in outs if int(e.bEndpointAddress) == _PREF_EP_OUT), outs[0],
    )
    ep_in = next(
        (e for e in ins if int(e.bEndpointAddress) == _PREF_EP_IN), ins[0],
    )
    return ep_out, ep_in


def _pair_is_preferred(ep_out, ep_in) -> bool:
    return (
        int(ep_out.bEndpointAddress) == _PREF_EP_OUT
        and int(ep_in.bEndpointAddress) == _PREF_EP_IN
    )


def _candidates_from_cfg(cfg):
    found = []
    for intf in cfg:
        ep_out, ep_in = _bulk_pair(intf)
        if ep_out is not None and ep_in is not None:
            found.append((intf, ep_out, ep_in))
    return found


def _pick_candidate(candidates):
    for item in candidates:
        if _pair_is_preferred(item[1], item[2]):
            return item
    return candidates[0]


def _select_from_active(dev):
    try:
        cfg = dev.get_active_configuration()
    except Exception:
        return None
    cands = _candidates_from_cfg(cfg)
    if not cands:
        return None
    return _pick_candidate(cands)


def _select_bulk_interface(dev):
    """Walk every interface/altsetting; first bulk IN+OUT, prefer 0x02/0x82.

    If the active configuration has no pair, try the other
    bConfigurationValue values (FT601 FIFO often lives on cfg 1 vs 0).
    """
    chosen = _select_from_active(dev)
    if chosen is not None:
        return chosen

    values: list[int] = []
    try:
        values = [int(cfg.bConfigurationValue) for cfg in dev]
    except Exception:
        values = []
    active_val = None
    try:
        active_val = int(dev.get_active_configuration().bConfigurationValue)
    except Exception:
        pass
    usb_err = _usb_error_type()
    for value in list(dict.fromkeys([*values, *_FT601_CONFIG_VALUES])):
        if value == active_val:
            continue
        try:
            dev.set_configuration(value)
        except usb_err:
            continue
        except Exception:
            continue
        chosen = _select_from_active(dev)
        if chosen is not None:
            return chosen

    dump = _print_descriptor_dump(dev)
    raise RuntimeError(
        "FT601 has no bulk IN+OUT pair on any interface/altsetting.\n" + dump
    )


def _apply_altsetting(dev, intf) -> None:
    alt = int(intf.bAlternateSetting)
    iface = int(intf.bInterfaceNumber)
    if alt == 0:
        return
    try:
        dev.set_interface_altsetting(interface=iface, alternate_setting=alt)
    except Exception as exc:
        dump = _print_descriptor_dump(dev)
        raise RuntimeError(
            f"FT601 set_interface altsetting {alt} on interface {iface} "
            f"failed ({exc}).\n{dump}"
        ) from exc


class FT601Client:
    """
    WinUSB/libusb bulk FIFO client for FT601 (VID 0x0403, PID 0x601F).

    After set_configuration, walks every interface/altsetting for a bulk
    IN+OUT pair (preferring 0x02/0x82), claims that interface, and uses
    those endpoints for framed MAGIC I/O. Not a UART; do not open via
    pyftdi / ftdi://.

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
    INTERFACE   = _FT601_INTERFACE

    def __init__(self, vid: int = DEFAULT_VID, pid: int = DEFAULT_PID,
                 index: int = 0):
        self._vid    = vid
        self._pid    = pid
        self._index  = index
        self._dev    = None
        self._ep_out: Optional[int] = None
        self._ep_in: Optional[int] = None
        self._intf_num: Optional[int] = None

    @property
    def is_open(self) -> bool:
        return self._dev is not None

    @property
    def _timeout_ms(self) -> int:
        return max(1, int(self.IO_TIMEOUT * 1000))

    # ------------------------- lifecycle --------------------------
    def open(self) -> "FT601Client":
        if self._dev is not None:
            return self
        dev = _find_ft601(self._vid, self._pid, self._index)
        claimed: Optional[int] = None
        try:
            _configure_ft601(dev)
            intf, ep_out, ep_in = _select_bulk_interface(dev)
            intf_num = int(intf.bInterfaceNumber)
            _claim_interface(dev, intf_num)
            claimed = intf_num
            _apply_altsetting(dev, intf)
        except Exception:
            if _HAVE_PYUSB:
                if claimed is not None:
                    try:
                        usb.util.release_interface(dev, claimed)
                    except Exception:
                        pass
                try:
                    usb.util.dispose_resources(dev)
                except Exception:
                    pass
            raise
        self._dev = dev
        self._ep_out = int(ep_out.bEndpointAddress)
        self._ep_in = int(ep_in.bEndpointAddress)
        self._intf_num = int(intf.bInterfaceNumber)
        return self

    def close(self) -> None:
        dev = self._dev
        intf_num = self._intf_num
        self._dev = None
        self._ep_out = None
        self._ep_in = None
        self._intf_num = None
        if dev is None:
            return
        if _HAVE_PYUSB:
            try:
                if intf_num is not None:
                    usb.util.release_interface(dev, intf_num)
            except Exception:
                pass
            try:
                usb.util.dispose_resources(dev)
            except Exception:
                pass

    def __enter__(self) -> "FT601Client":
        if self._dev is None:
            return self.open()
        return self

    def __exit__(self, *_exc_info) -> None:
        self.close()

    # ------------------------- raw I/O ---------------------------
    def _write_raw(self, blob: bytes) -> int:
        if self._dev is None or self._ep_out is None:
            raise IOError("device not open")
        if not blob:
            return 0
        timeout = self._timeout_ms
        written = 0
        view = memoryview(blob)
        while written < len(blob):
            try:
                n = int(self._dev.write(self._ep_out, view[written:], timeout))
            except Exception as exc:
                if _is_usb_timeout(exc):
                    if written:
                        break
                    raise TimeoutError("FT601 bulk OUT timeout") from exc
                raise
            if n <= 0:
                break
            written += n
        return written

    def _read_raw(self, nbytes: int) -> bytes:
        if self._dev is None or self._ep_in is None:
            raise IOError("device not open")
        if nbytes <= 0:
            return b""
        timeout = self._timeout_ms
        buf = bytearray()
        while len(buf) < nbytes:
            want = min(self.READ_CHUNK, nbytes - len(buf))
            try:
                chunk = self._dev.read(self._ep_in, want, timeout)
            except Exception as exc:
                if _is_usb_timeout(exc):
                    break  # short read: return what we have
                raise
            if not chunk:
                break
            buf.extend(bytes(chunk))
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
            chunk = self._read_raw(4)
            buf.extend(chunk)
            if len(chunk) < 4:
                attempts += 1
                continue
            maybe_magic = struct.unpack("<I", bytes(buf[-4:]))[0]
            if maybe_magic == FRAME_MAGIC:
                break
            attempts += 1
        else:
            raise TimeoutError(self._magic_timeout_message(buf, max_wait))

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
            req_length_dw=1,
        ))
        rsp = self.recv_frame(expect_payload_dw=1)
        return rsp.payload[0]

    def read_burst(self, address: int, length_dw: int, flags: int = 0) -> list[int]:
        if length_dw <= 0:
            raise ValueError("length_dw must be >= 1")
        self.send_frame(Frame(
            opcode=Opcode.READ_BURST,
            flags=flags,
            address=address,
            payload=[],
            req_length_dw=length_dw,
        ))
        rsp = self.recv_frame(expect_payload_dw=length_dw)
        return rsp.payload

    def transport_summary(self) -> str:
        iface = self._intf_num
        ep_out = self._ep_out
        ep_in = self._ep_in
        return (
            f"iface={iface} OUT=0x{ep_out:02x} IN=0x{ep_in:02x}"
            if iface is not None and ep_out is not None and ep_in is not None
            else "not open"
        )

    def _magic_timeout_message(self, buf: bytes, max_wait: int) -> str:
        preview = buf[:16].hex() if buf else "(none)"
        hint = (
            "USB bulk write of MAGIC+KEEPALIVE succeeded; the FPGA did not "
            "return MAGIC 0x5AA5C33C. Stock CaptainDMA speaks PCILeech 0x77, "
            "not this bitstream. Flash with J2 + vivado_build.tcl / "
            "vivado_flash.tcl (do not power-cycle after SRAM program)."
        )
        if buf[:1] == b"\x77":
            hint = (
                "RX starts with 0x77 — that is stock PCILeech FPGA USB, not "
                "MAGIC 0x5AA5C33C. Flash this repo's bitstream on J2."
            )
        return (
            f"MAGIC not found within {max_wait} DWs "
            f"({self.transport_summary()}; rx {len(buf)} bytes: {preview}). "
            f"{hint}"
        )

    def ping(self) -> Frame:
        self.send_frame(Frame(
            opcode=Opcode.KEEPALIVE,
            flags=0, address=0, payload=[], req_length_dw=0
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
            "usb_id": "0403:601F",
            "usb": bool(
                (self._client is not None and self._client.is_open)
                or _usb_present()
            ),
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
        if self._client.is_open:
            info["usb_transport"] = self._client.transport_summary()
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


def _usb_present(vid: int = 0x0403, pid: int = 0x601F) -> bool:
    """True if pyusb can enumerate at least one 0403:601F (find_all)."""
    if not _HAVE_PYUSB:
        return False
    try:
        backend = usb.backend.libusb1.get_backend()
        if backend is None:
            return False
        found = list(usb.core.find(
            find_all=True, idVendor=vid, idProduct=pid, backend=backend,
        ))
        return bool(found)
    except Exception:
        return False


def _dsn_from_mac(mac: bytes) -> str:
    dsn_lo = (mac[3] << 24) | (mac[4] << 16) | (mac[5] << 8)
    dsn_hi = (mac[0] << 16) | (mac[1] << 8) | mac[2]
    return f"{dsn_hi:08x}{dsn_lo:08x}"


def _identity_from_rtl() -> dict | None:
    """Parse rtl8125b_identity_pkg.sv so host/RTL IDs cannot silently drift."""
    from pathlib import Path
    import re
    pkg = Path(__file__).resolve().parents[1] / "rtl" / "rtl8125b_identity_pkg.sv"
    if not pkg.is_file():
        return None
    text = pkg.read_text(encoding="utf-8")

    def hex_field(name: str) -> int:
        m = re.search(rf"{name}\s*=\s*16'h([0-9A-Fa-f]+)", text)
        if not m:
            raise AssertionError(f"missing {name} in {pkg}")
        return int(m.group(1), 16)

    rev = re.search(r"REVISION_ID\s*=\s*8'h([0-9A-Fa-f]+)", text)
    mac = re.search(r"MAC_ADDR\s*=\s*48'h([0-9A-Fa-f_]+)", text)
    if not rev or not mac:
        raise AssertionError(f"missing REVISION_ID/MAC_ADDR in {pkg}")
    mac_int = int(mac.group(1).replace("_", ""), 16)
    mac_bytes = mac_int.to_bytes(6, "big")
    return {
        "vid": hex_field("VENDOR_ID"),
        "did": hex_field("DEVICE_ID"),
        "rev": int(rev.group(1), 16),
        "svid": hex_field("SUBSYS_VENDOR_ID"),
        "ssid": hex_field("SUBSYS_ID"),
        "mac": mac_bytes,
    }


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
    assert ident["usb_id"] == "0403:601F"
    assert ident["usb"] is False or ident["usb"] is True
    assert ident["pcileech_fpga_tlp_stream"] is False
    assert ident["mac"] == "00:e0:4c:7a:3b:91"
    assert ident["dsn"] == _dsn_from_mac(DONOR_MAC)
    assert ident["max_read_bytes"] == 128
    assert ident["dsn"] != "0000000000000000"
    assert ident["mac"] != "12:34:56:00:00:00"

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

    rd = Frame(
        opcode=Opcode.READ_BURST,
        flags=0,
        address=DMA_BUF,
        payload=[],
        req_length_dw=DMA_MAX_DW,
    )
    rd_words = _words(rd.to_bytes())
    assert rd.length_dw == DMA_MAX_DW
    assert (rd_words[1] & 0xFFFF) == DMA_MAX_DW
    assert len(rd_words) == 3  # MAGIC + HDR + ADDR, no payload

    ping = Frame(opcode=Opcode.KEEPALIVE, flags=0, address=0, payload=[],
                 req_length_dw=0)
    ping_words = _words(ping.to_bytes())
    assert ping_words[0] == FRAME_MAGIC
    assert ((ping_words[1] >> 24) & 0xFF) == _FORWARD[Opcode.KEEPALIVE]
    assert (ping_words[1] & 0xFFFF) == 0

    # Mock WinUSB bulk: ping must actually write MAGIC+KEEPALIVE (no hardware).
    class _FakeUsbDev:
        def __init__(self, rx: bytes = b""):
            self.tx = bytearray()
            self.rx = bytearray(rx)
            self.timeouts_left = 0

        def write(self, _ep, data, timeout=None):
            blob = bytes(data)
            self.tx.extend(blob)
            return len(blob)

        def read(self, _ep, size, timeout=None):
            if self.timeouts_left > 0:
                self.timeouts_left -= 1
                raise TimeoutError("USB timeout")
            n = min(int(size), len(self.rx))
            chunk = bytes(self.rx[:n])
            del self.rx[:n]
            return chunk

    ack = Frame(opcode=Opcode.KEEPALIVE, flags=0, address=0, payload=[],
                req_length_dw=0)
    fake = _FakeUsbDev(rx=ack.to_bytes())
    loop = FT601Client()
    loop._dev = fake
    loop._ep_out = 0x02
    loop._ep_in = 0x81
    loop._intf_num = 0
    got = loop.ping()
    assert bytes(fake.tx) == ping.to_bytes()
    assert got.opcode == Opcode.KEEPALIVE
    silent = _FakeUsbDev()
    loop._dev = silent
    try:
        loop.ping()
        raise AssertionError("expected MAGIC timeout on empty RX")
    except TimeoutError as exc:
        msg = str(exc)
        assert "0x5AA5C33C" in msg
        assert "rx 0 bytes" in msg
        assert "vivado_flash.tcl" in msg
    loop._dev = fake
    # short-read / timeout handling
    fake.rx.extend(b"\x11\x22")
    assert loop._read_raw(8) == b"\x11\x22"
    fake.timeouts_left = 1
    assert loop._read_raw(4) == b""
    loop.close()
    assert loop._dev is None
    assert "libusb-1.0.dll" in _LIBUSB_HINT
    assert "WinUSB" in _LIBUSB_HINT
    assert "ftdi://" not in _LIBUSB_HINT

    # Descriptor walk: skip iface 0 (no bulk), prefer 0x02/0x82 on iface 1 alt 1.
    class _Ep:
        def __init__(self, addr: int, xfer: int = 2, maxpkt: int = 1024):
            self.bEndpointAddress = addr
            self.bmAttributes = xfer
            self.wMaxPacketSize = maxpkt

    class _Intf:
        def __init__(self, num: int, alt: int, eps: list):
            self.bInterfaceNumber = num
            self.bAlternateSetting = alt
            self.bNumEndpoints = len(eps)
            self._eps = list(eps)

        def __iter__(self):
            return iter(self._eps)

    class _Cfg:
        def __init__(self, value: int, intfs: list):
            self.bConfigurationValue = value
            self._intfs = list(intfs)

        def __iter__(self):
            return iter(self._intfs)

    class _DescDev:
        def __init__(self, cfgs: list, active: int = 0):
            self._cfgs = list(cfgs)
            self._active = active
            self.claimed: list[int] = []
            self.alts: list[tuple[int, int]] = []
            self.set_cfgs: list = []

        def __iter__(self):
            return iter(self._cfgs)

        def set_configuration(self, value=None):
            self.set_cfgs.append(value)
            if value is None:
                self._active = 0
                return
            for i, cfg in enumerate(self._cfgs):
                if int(cfg.bConfigurationValue) == int(value):
                    self._active = i
                    return
            raise RuntimeError(f"no configuration {value}")

        def get_active_configuration(self):
            return self._cfgs[self._active]

        def set_interface_altsetting(self, interface, alternate_setting):
            self.alts.append((int(interface), int(alternate_setting)))

        def is_kernel_driver_active(self, n):
            return False

    dump_dev = _DescDev([_Cfg(1, [
        _Intf(0, 0, [_Ep(0x81, xfer=3, maxpkt=64)]),  # interrupt only
        _Intf(1, 0, [_Ep(0x01), _Ep(0x81)]),
        _Intf(1, 1, [_Ep(0x02), _Ep(0x82), _Ep(0x83, xfer=3)]),
    ])])
    dump = _format_descriptor_dump(dump_dev)
    assert "cfg=1 iface=0 alt=0 ep=0x81 type=int maxpkt=64" in dump
    assert "cfg=1 iface=1 alt=0 ep=0x01 type=bulk maxpkt=1024" in dump
    assert "cfg=1 iface=1 alt=1 ep=0x02 type=bulk maxpkt=1024" in dump
    assert "cfg=1 iface=1 alt=1 ep=0x82 type=bulk maxpkt=1024" in dump

    chosen = _select_bulk_interface(dump_dev)
    assert chosen[0].bInterfaceNumber == 1
    assert chosen[0].bAlternateSetting == 1
    assert int(chosen[1].bEndpointAddress) == 0x02
    assert int(chosen[2].bEndpointAddress) == 0x82

    # First bulk pair when 0x02/0x82 is absent (0x01/0x81).
    only_01 = _DescDev([_Cfg(1, [
        _Intf(0, 0, []),
        _Intf(1, 0, [_Ep(0x01), _Ep(0x81)]),
    ])])
    chosen_01 = _select_bulk_interface(only_01)
    assert chosen_01[0].bInterfaceNumber == 1
    assert int(chosen_01[1].bEndpointAddress) == 0x01
    assert int(chosen_01[2].bEndpointAddress) == 0x81

    # Bulk pair on cfg 2 after active cfg 1 has none.
    cfg_switch = _DescDev([
        _Cfg(1, [_Intf(0, 0, [])]),
        _Cfg(2, [_Intf(0, 0, [_Ep(0x02), _Ep(0x82)])]),
    ])
    chosen_cfg = _select_bulk_interface(cfg_switch)
    assert int(cfg_switch.get_active_configuration().bConfigurationValue) == 2
    assert int(chosen_cfg[1].bEndpointAddress) == 0x02
    assert int(chosen_cfg[2].bEndpointAddress) == 0x82

    empty = _DescDev([_Cfg(1, [_Intf(0, 0, [_Ep(0x81, xfer=3)])])])
    import io
    from contextlib import redirect_stderr, redirect_stdout
    err = io.StringIO()
    try:
        with redirect_stderr(err):
            _select_bulk_interface(empty)
        raise AssertionError("expected no-bulk error")
    except RuntimeError as exc:
        msg = str(exc)
        assert "no bulk IN+OUT pair" in msg
        assert "cfg=1 iface=0 alt=0 ep=0x81 type=int maxpkt=1024" in msg
        assert "cfg=1 iface=0 alt=0 ep=0x81 type=int maxpkt=1024" in err.getvalue()

    if _HAVE_PYUSB:
        class _ClaimDev:
            def is_kernel_driver_active(self, n):
                return False

        orig_claim = usb.util.claim_interface

        def boom(_dev, n):
            raise usb.core.USBError("access denied")

        usb.util.claim_interface = boom
        try:
            try:
                with redirect_stderr(io.StringIO()):
                    _claim_interface(_ClaimDev(), 1)
                raise AssertionError("expected claim failure")
            except RuntimeError as exc:
                assert "Zadig WinUSB on that interface" in str(exc)
                assert "interface 1" in str(exc)
        finally:
            usb.util.claim_interface = orig_claim

    g = globals()
    orig_find = g["_find_ft601"]
    g["_find_ft601"] = lambda *a, **k: dump_dev
    try:
        buf = io.StringIO()
        with redirect_stdout(buf):
            _usb_dump()
        assert "cfg=1 iface=1 alt=1 ep=0x02 type=bulk maxpkt=1024" in buf.getvalue()
    finally:
        g["_find_ft601"] = orig_find

    # open() walks descriptors, claims the chosen iface, sets altsetting.
    if _HAVE_PYUSB:
        sentinel = dump_dev
        orig_find = g["_find_ft601"]
        orig_claim_fn = usb.util.claim_interface

        def fake_find(vid, pid, index=0):
            assert vid == 0x0403 and pid == 0x601F
            return sentinel

        def fake_claim(dev, n):
            dev.claimed.append(int(n))

        try:
            g["_find_ft601"] = fake_find
            usb.util.claim_interface = fake_claim
            opened = FT601Client().open()
            assert opened._dev is sentinel
            assert opened._ep_out == 0x02 and opened._ep_in == 0x82
            assert opened._intf_num == 1
            assert sentinel.claimed == [1]
            assert (1, 1) in sentinel.alts
            opened.close()
            assert opened._dev is None
        finally:
            g["_find_ft601"] = orig_find
            usb.util.claim_interface = orig_claim_fn

    orig_have = g["_HAVE_PYUSB"]
    g["_HAVE_PYUSB"] = False
    try:
        try:
            _libusb_backend()
            raise AssertionError("expected RuntimeError when pyusb is missing")
        except RuntimeError as exc:
            msg = str(exc)
            assert "libusb-1.0.dll" in msg and "WinUSB" in msg
            assert "ftdi://" not in msg
    finally:
        g["_HAVE_PYUSB"] = orig_have

    ident_sv = _identity_from_rtl()
    if ident_sv is not None:
        assert ident_sv["vid"] == DONOR_VID
        assert ident_sv["did"] == DONOR_DID
        assert ident_sv["rev"] == DONOR_REV
        assert ident_sv["ssid"] == DONOR_SSID
        assert ident_sv["mac"] == DONOR_MAC
    print("ft601_client self-test: OK")


def _usb_dump(vid: int = FT601Client.DEFAULT_VID,
              pid: int = FT601Client.DEFAULT_PID,
              index: int = 0) -> None:
    """Print compact USB descriptors and return; exit 0 if the device exists."""
    try:
        dev = _find_ft601(vid, pid, index)
    except Exception as exc:
        raise SystemExit(f"FT601 {vid:04x}:{pid:04x} not found ({exc})") from exc
    print(_format_descriptor_dump(dev))


def _open_or_die() -> FT601Client:
    try:
        return FT601Client().open()
    except Exception as exc:
        raise SystemExit(f"FT601 0403:601f open failed ({exc})") from exc


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true",
                    help="run offline bijection + frame round-trip")
    ap.add_argument("--ping", action="store_true",
                    help="open 0403:601F WinUSB bulk, write KEEPALIVE, print ACK")
    ap.add_argument("--read", type=lambda x: int(x, 0),
                    help="read one DW from the given address and print")
    ap.add_argument("--write", nargs=2, type=lambda x: int(x, 0),
                    metavar=("ADDR", "VALUE"),
                    help="write one DW to the given address")
    ap.add_argument("--read-burst", nargs=2, type=lambda x: int(x, 0),
                    metavar=("ADDR", "LEN_DW"),
                    help="read LEN_DW words starting at ADDR")
    ap.add_argument("--dma-read", nargs=2, type=lambda x: int(x, 0),
                    metavar=("PA", "BYTES"),
                    help="LeechCoreAdapter physical read (MAGIC path, up to 128 B/TLP)")
    ap.add_argument("--identify", action="store_true",
                    help="print LeechCore-shaped identify (offline if no FT601)")
    ap.add_argument("--usb-dump", action="store_true",
                    help="print 0403:601F descriptors (cfg/iface/alt/ep) and exit")
    args = ap.parse_args()

    if args.selftest:
        _selftest()
    if args.usb_dump:
        _usb_dump()
        raise SystemExit(0)
    if args.identify:
        try:
            with FT601Client() as dev:
                info = LeechCoreAdapter(dev).identify()
        except Exception:
            info = LeechCoreAdapter().identify()
        shown = dict(info)
        for key, width in (("vid", 4), ("did", 4), ("svid", 4), ("ssid", 4), ("rev", 2)):
            if isinstance(shown.get(key), int):
                shown[key] = f"0x{shown[key]:0{width}X}"
        print(shown)
    if args.ping:
        with _open_or_die() as dev:
            print(dev.transport_summary())
            try:
                print(dev.ping())
            except TimeoutError as exc:
                raise SystemExit(str(exc)) from exc
    if args.read is not None:
        with _open_or_die() as dev:
            print(f"0x{dev.read_dw(args.read):08X}")
    if args.write is not None:
        with _open_or_die() as dev:
            dev.write_dw(args.write[0], args.write[1])
            print("OK")
    if args.read_burst is not None:
        with _open_or_die() as dev:
            words = dev.read_burst(args.read_burst[0], args.read_burst[1])
            print(" ".join(f"0x{w:08X}" for w in words))
    if args.dma_read is not None:
        with _open_or_die() as dev:
            data = LeechCoreAdapter(dev).read(args.dma_read[0], args.dma_read[1])
            print(data.hex())
