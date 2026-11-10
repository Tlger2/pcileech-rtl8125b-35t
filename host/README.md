# Host-side client

Python driver that speaks the FT601 framed protocol used by `pcie_custom_endpoint_top`.

## Install

```
pip install pyusb
```

The FT601 is a SuperSpeed FIFO (`0403:601F`), not an FT232 UART. The host
opens it with pyusb bulk transfers on **interface 0 (MI_00)**.

On Windows: bind **WinUSB** to `VID 0x0403`, `PID 0x601F`, **MI_00** with
[Zadig](https://zadig.akeo.ie/), and put `libusb-1.0.dll` on PATH (or next
to `python.exe`). On Linux, install `libusb-1.0` and add a udev rule for
`0403:601f` (or run in the `plugdev` group / with `sudo`).

## Use

Offline self-test (no hardware needed) — checks the opcode bijection and a
frame round-trip:

```
python ft601_client.py --selftest
```

On the laptop USB-connected to the 35T (`lsusb` shows `0403:601f`).
`--identify` sets `usb: true` when pyusb finds `0403:601F` (and tries to
open MI_00). `--ping` bulk-writes MAGIC+KEEPALIVE on the WinUSB bulk OUT
endpoint and waits for an ACK — not `ftdi://`.

```
python3 ft601_client.py --selftest
python3 ft601_client.py --identify
python3 ft601_client.py --ping
python3 ft601_client.py --write 0x04 0x00001000
python3 ft601_client.py --read  0x04
python3 ft601_client.py --read-burst 0x40 32
python3 ft601_client.py --dma-read 0x1000 128
```

LeechCore-shaped identify/read/write on the same MAGIC path. Native
MemProcFS `fpga://` is the PCILeech 0x77 TLP stream and will not identify
this bitstream:

```
python3 ft601_client.py --identify
```

```python
from ft601_client import FT601Client, Opcode, LeechCoreAdapter

with FT601Client() as dev:
    dev.write_dw(0x0000_1000, 0xDEAD_BEEF)
    print(hex(dev.read_dw(0x0000_1000)))
    block = dev.read_burst(0x0000_2000, 16)
    lc = LeechCoreAdapter(dev)
    print(lc.identify())
    phys = lc.read(0x1000, 128)
```

## Protocol

Frame layout (little-endian 32-bit DWs on the wire):

| DW | Field |
|---|---|
| 0 | MAGIC `0x5AA5_C33C` |
| 1 | `{wire_opcode[7:0], flags[7:0], length_dw[15:0]}` |
| 2 | Target base address |
| 3… | `length_dw` payload words |

The wire opcode is produced by `encode_opcode(canonical)` from the
substitution table in `opcode_scramble_pkg.sv`. The table is bijective —
`decode_opcode(encode_opcode(x)) == x` for every defined canonical value —
so this host script and the FPGA parser stay in step without further state.

The scramble is obfuscation, not encryption; layer AEAD on top if the link
can be observed or injected into.
