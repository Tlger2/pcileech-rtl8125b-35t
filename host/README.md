# Host-side client

Python driver that speaks the FT601 framed protocol used by `pcie_custom_endpoint_top`.

## Install

```
pip install pyftdi
```

On Windows you also need a libusb-1.0 backend bound to the FT601:
run [Zadig](https://zadig.akeo.ie/) and bind **WinUSB** to the FT601 interface
(`VID 0x0403`, `PID 0x601F`). The bundled FTDI D3XX driver is a separate
Windows kernel driver and does not work with `pyftdi`; pick one or the other.

On Linux, add a udev rule granting access to `0403:601f` and `plugdev`-group
your user, or run with `sudo`.

## Use

Offline self-test (no hardware needed) — checks the opcode bijection and a
frame round-trip:

```
python ft601_client.py --selftest
```

On hardware:

```
python ft601_client.py --ping
python ft601_client.py --read  0x00001000
python ft601_client.py --write 0x00001000 0xDEADBEEF
```

LeechCore-shaped identify/read/write on the same MAGIC path (does not
speak native MemProcFS `fpga://`, which is the PCILeech 0x77 TLP stream):

```
python ft601_client.py --identify
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
