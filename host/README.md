# Host-side client

Python driver that speaks the FT601 framed protocol used by `pcie_custom_endpoint_top`.

## Install

```
pip install pyusb
```

The FT601 is a SuperSpeed FIFO (`0403:601F`), not an FT232 UART. After
`set_configuration` the host walks **every interface and altsetting** and
binds the first bulk IN+OUT pair, preferring **OUT 0x02 + IN 0x82**.

On Windows: bind **WinUSB** with [Zadig](https://zadig.akeo.ie/) to
`VID 0x0403`, `PID 0x601F` on the interface that has those bulk pipes
(often MI_00; if open says `Zadig WinUSB on that interface`, bind that
MI_xx instead), and put `libusb-1.0.dll` on PATH (or next to `python.exe`).
On Linux, install `libusb-1.0` and add a udev rule for `0403:601f` (or
run in the `plugdev` group / with `sudo`).

## Use

Offline self-test (no hardware needed) — checks the opcode bijection and a
frame round-trip:

```
python ft601_client.py --selftest
```

On the laptop USB-connected to the 35T (`lsusb` shows `0403:601f`).
`--identify` sets `usb: true` when pyusb finds `0403:601F`. `--usb-dump`
prints cfg/iface/alt/ep descriptors and exits 0 if the device is found.
`--ping` bulk-writes MAGIC+KEEPALIVE on the chosen bulk OUT endpoint and
waits for an ACK — not `ftdi://`. If open fails, the client prints the
descriptor dump (do not fail silently). A MAGIC timeout after a successful
open means USB is up and the FPGA is not running this bitstream (stock
cards speak PCILeech `0x77`). Flash with J2 + `vivado_build.tcl` /
`vivado_flash.tcl`. CaptainDMA FT601 often has bulk `0x02`/`0x82` on
**iface 1** (iface 0 is bulk OUT + interrupt IN).

```
python3 ft601_client.py --selftest
python3 ft601_client.py --usb-dump
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
