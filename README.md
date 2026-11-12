# pcileech-rtl8125b-35t

SystemVerilog RTL for a PCILeech-style CaptainDMA (XC7A35T, FGG484) endpoint
that enumerates as a Realtek RTL8125B 2.5GbE NIC (rev 05, SVID/SSID 10EC:0123).

> Target: Xilinx Artix-7 XC7A35T, Xilinx 7-Series integrated PCIe block, FT601 USB 3.0
> device side, Vivado 2026.1.

## Status (2026-11-10)

Live in this tree (no card required to review or sim):

- Endpoint top restored to a complete synthesizable module (TLP RX, BAR CplD, DMA, FT601 CDC). MemWr payload is captured into the MAC register file; shadow RAM is on; MSI is 1-vector maskable via `pcie_msi_trigger`; MSI-X 32-vector table/PBA sits in BAR4 and `msix_mwr_tx` emits MemWr TLPs.
- Identity is one package (`rtl/rtl8125b_identity_pkg.sv`): VID/DID 10EC:8125, Rev 05, Class 020000, SVID/SSID 10EC:0123, MAC `00:E0:4C:7A:3B:91`, DSN derived from that MAC. Wrapper `cfg_dsn` is that value, not 0.
- Soft Type-0 header, BAR decoder, and `vivado_build.tcl` pcie_7x CONFIG agree on BAR0 I/O 256 B, BAR2 64-bit npref 64 KB (MAC), BAR4 64-bit npref 16 KB (MSI-X). Cap chain PM@0x40 → MSI@0x50 → PCIe@0x70 → MSI-X@0xB0 → VPD@0xD0. ECAP: AER@0x100 → VC@0x148 → DSN@0x168 → TPH@0x178 → LTR@0x204 → L1PM@0x20C → VSEC@0x21C.
- Live `pcie_7x` `cfg_ext` is wired to `pcie_ecap_router` (`EXT_PCI_CFG_Space` must stay true). Unclaimed ECAPs (TPH/LTR/L1PM/VSEC, and DSN if the core did not keep 0x168) answer on silicon. Type-0 / PM / MSI / PCIe / MSI-X are still the integrated block.
- MAC register file uses r8125/r8169 offsets (ChipCmd 0x37, TxPoll 0x38, IntrStatus 0x3e, PHYAR 0x60, ERIDR/ERIAR 0x70/0x74, EPHYAR 0x80, OCPDR/OCPAR 0xB0/0xB4). TxConfig chip id is `0x64Axxxxx` (RTL8125B). PHY/ERI/EPHY/OCP flags complete so a Windows probe does not Code 10 on those paths.
- DMA engine issues burst MRd/MWr with a real Length field, up to 32 DW (128 B) / MPS. CplD gather accepts continuation beats and split completions. Host `--selftest` covers READ_BURST length-in-HDR and KEEPALIVE. `LeechCoreAdapter` maps identify/read/write onto the existing MAGIC+opcode path. KEEPALIVE/STATUS/INFO/VERSION/RESET return a 0-DW USB ACK so `--ping` does not hang.

Icarus: `bash scripts/sim_iverilog.sh` (dma 128 B, BAR0 map + ERI/OCP/EPHY, ECAP DSN, BAR CplD, USB response). `tb_endpoint` is XSim-first; iverilog compiles it only. `python3 scripts/lspci_check.py --selftest` checks the donor `lspci -xxx` rules.

Still needs the card:

- Vivado bitstream (this environment has no Vivado). Flash with the board's usual flow.
- `lspci -nnvvv` vs a real RTL8125B rev 05 donor (BARs, cap pointers, DSN@0x168, MSI-X 32/BAR4).
- Windows bind of r8125 / rt640x64 (Device Manager, no Code 10).
- MemProcFS: this firmware is MAGIC `0x5AA5C33C` + scrambled opcodes, not the PCILeech-FPGA `fpga://` 0x77 TLP stream. Use `host/leechcore_adapter.py` (or `ft601_client.py --identify`) on the FT601. Native `fpga://` will not identify this bitstream until a TLP-stream shim exists.

## Modules

| File | Purpose |
|---|---|
| [rtl/rtl8125b_identity_pkg.sv](rtl/rtl8125b_identity_pkg.sv) | Single source of VID/DID/Rev/MAC/DSN/BAR/cap offsets |
| [rtl/ecap/pcie_ecap_router.sv](rtl/ecap/pcie_ecap_router.sv) | ECAP chain router (AER/VC/DSN/TPH/LTR/L1PM/VSEC) |
| [rtl/opcode_scramble_pkg.sv](rtl/opcode_scramble_pkg.sv) | 8-bit opcode substitution LUT (host↔wire, bijective) |
| [rtl/dma_engine.sv](rtl/dma_engine.sv) | 4DW MemRd/MemWr issuer, burst up to 128 B, CplD gather |
| [rtl/pcie_msi_trigger.sv](rtl/pcie_msi_trigger.sv) | MSI request generator (1 vector) |
| [rtl/msix_table_pba.sv](rtl/msix_table_pba.sv) | MSI-X table + PBA in BAR4 |
| [rtl/msix_mwr_tx.sv](rtl/msix_mwr_tx.sv) | MSI-X MemWr TLP issuer |
| [rtl/pcie_top_wrapper.sv](rtl/pcie_top_wrapper.sv) | Instantiates `pcie_7x_0` + custom endpoint, MAC-derived `cfg_dsn` |
| [rtl/pci_type0_cfg_header.sv](rtl/pci_type0_cfg_header.sv) | Type 0 header, donor BAR map, Rev 05 |
| [rtl/pcie_bar_decoder.sv](rtl/pcie_bar_decoder.sv) | I/O BAR0 + MEM BAR2 + MEM BAR4 decode, IOSE/MSE |
| [rtl/rtl8125b_bar0_regs.sv](rtl/rtl8125b_bar0_regs.sv) | r8125 MAC register file (I/O window + 64 KB MMIO) |
| [host/ft601_client.py](host/ft601_client.py) | FT601 MAGIC client + LeechCore-shaped adapter |

## Configuration space layout

```
0x00 .. 0x3F : Type 0 header   (VID/DID, Command, Status, BARs, Cap Ptr=0x40)
0x40 .. 0x47 : PM Cap          (Cap ID 0x01, Next 0x50, PMC=0xFFC3)
0x50 .. 0x67 : MSI Cap         (Cap ID 0x05, Next 0x70, 64-bit, maskable, 1 vec)
0x70 .. 0xAB : PCIe Cap v2     (Cap ID 0x10, Next 0xB0, Gen2 x1, ASPM L0s+L1)
0xB0 .. 0xBB : MSI-X Cap       (Cap ID 0x11, Next 0xD0, 32 vec, BIR=4, PBA 0x800)
0xD0 .. 0xD7 : VPD Cap         (Cap ID 0x03, Next 0x00)

ECAP:
0x100 AER → 0x148 VC → 0x168 DSN → 0x178 TPH → 0x204 LTR → 0x20C L1PM → 0x21C VSEC
```

## Command/response frame format

```
DW0  : 32'h5AA5_C33C                              (MAGIC)
DW1  : {opcode[7:0], flags[7:0], length_dw[15:0]}
DW2  : 32-bit target address
DW3+ : length_dw words of payload
```

Opcodes live in `opcode_scramble_pkg` — canonical codes internally, scrambled bytes
on the wire. The two directions are strict inverses (`opc_decode(opc_encode(X)) == X`
for every defined `X`). ChaCha stays off this path; the PCIe function the host
sees is the NIC.

MemProcFS `fpga://` / PCILeech FPGA USB is a different framing (0x77 FIFO + raw
TLPs). `LeechCoreAdapter` in `host/ft601_client.py` exposes identify/read/write
on the MAGIC path without changing the opcode LUT.

## Hardware

- **Board:** CaptainDMA 35T (XC7A35T FGG484 + FTDI FT601 USB 3.0 bridge)
- **Spoof target:** Realtek RTL8125B 2.5GbE NIC
  - VID `0x10EC`, DID `0x8125`, Class `0x020000`, Rev `0x05`
  - Subsys VID `0x10EC`, SSID `0x0123`
  - MAC `00:E0:4C:7A:3B:91` (DSN `0000e04c7a3b9100`)
  - PCIe Gen2 x1, BAR0 I/O 256 B, BAR2 MEM64 64 KB npref, BAR4 MEM64 16 KB npref
  - MSI 1-vector maskable 64-bit; MSI-X 32 vectors in BAR4

## Read-only radar UI

Atomic-style 2D radar lives in [`radar-web/`](radar-web/). No aimbot, RCS, chams, or other memory writes.

```bash
cd radar-web && python3 -m http.server 8765
```

## Tonight: laptop USB + Vivado machine

The FT601 is the USB3 connector on the CaptainDMA 35T. Stock MemProcFS `fpga://` speaks PCILeech's 0x77 TLP stream; this bitstream speaks MAGIC `0x5AA5C33C` + scrambled opcodes. Use `host/ft601_client.py` (or `host/leechcore_adapter.py`). Do not point MemProcFS `fpga://` at this image.

### 1. Bitstream (machine with Vivado 2026.1)

```bash
cd /path/to/pcileech-rtl8125b-35t
git checkout cursor/rtl8125b-eac-hide-1fc4
vivado -mode batch -source vivado_build.tcl
# bitstream:
#   vivado_project/rtl8125b_dma.runs/impl_1/pcie_top_wrapper.bit
vivado -mode batch -source vivado_flash.tcl
```

`wait_on_run` has no 20-second cap (that aborted synth). Do not power-cycle L1 after SRAM program.

Vivado 2026.1 on Windows lives under `C:\AMDDesignTools\2026.1\Vivado\settings64.bat` (not `C:\Xilinx`). `Bar0_Type IO` can abort an already-customized `pcie_7x_0`; `vivado_build.tcl` catches that, recreates the IP if needed, and falls back to Memory 256 B only if the core has no I/O BAR enum.

`vivado_flash.tcl` JTAG-loads FPGA SRAM (gone on power cycle). For SPI that survives reboot: Hardware Manager → Add Configuration Memory Device → program the `.bit` / generated `.mcs`. There is no `.bit` in this repo; this environment has no Vivado.

### 2. Laptop USB-connected to the 35T (after the card is up)

Windows: Zadig → WinUSB on `VID 0403 PID 601F` (the interface with bulk pipes; often MI_00), plus `libusb-1.0.dll` on PATH. Linux: `libusb-1.0`, user in `plugdev` or a udev rule for `0403:601f`.

```bash
cd /path/to/pcileech-rtl8125b-35t
python3 -m pip install pyusb
python3 host/ft601_client.py --selftest
lsusb | grep -i 0403
# expect: 0403:601f  Future Technology Devices International, Ltd FT601

python3 host/ft601_client.py --usb-dump
python3 host/ft601_client.py --identify
python3 host/ft601_client.py --ping
python3 host/ft601_client.py --write 0x04 0x00001000
python3 host/ft601_client.py --read  0x04
python3 host/ft601_client.py --read-burst 0x40 32
python3 host/ft601_client.py --dma-read 0x1000 128
```

`--selftest` is offline (no FT601). `--usb-dump` prints cfg/iface/alt/ep descriptors and exits 0 if `0403:601F` is found. `--identify` prints donor 10EC:8125 rev 05 even if the USB device is missing (`usb` is true only if pyusb finds `0403:601F`, and `--identify` also tries to open it). `--ping` walks every interface/altsetting for a bulk IN+OUT pair (preferring 0x02/0x82) and bulk-writes MAGIC+KEEPALIVE (wire `0x87`), then waits for the FPGA ACK — it does not use `ftdi://`. If open fails, the client prints a compact descriptor dump. `--read` / `--write` / `--dma-read` also require `0403:601f`.

### 3. PCIe host that has the card in a slot

```bash
lspci -nnvvv -d 10ec:8125
lspci -xxx -d 10ec:8125 > /tmp/8125.xxx
python3 scripts/lspci_check.py /tmp/8125.xxx
# IDs 10ec:8125 rev 05, SVID/SSID 10ec:0123
# BAR0 I/O 256, BAR2 MEM64 64K npref, BAR4 MEM64 16K npref
# Capabilities: PM@40 → MSI@50 → PCIe@70 → MSI-X@b0 (32 vec, BIR=4, PBA 0x800)
# ECAP DSN at 0x168 = 0000e04c7a3b9100
```

If `lspci_check.py` reports a cap-pointer mismatch, change **`vivado_build.tcl` pcie_7x CONFIG** (not only the soft header), rebuild, reprogram, re-diff. Standard-cap layout is still owned by the Xilinx core; `ip_try_set` skips names 2026.1 does not expose.

## Build notes

These modules target the Xilinx 7-Series PCIe integrated block on an XC7A35T. The
AXI-Stream TX mux assumes the 64-bit `s_axis_tx` interface (Gen2 x1 default).
Optional `pcie_7x` properties (PM_BASE_PTR, MSI-X BIR spellings, Aux_Current)
are applied with `ip_try_set` so a missing 2026.1 name does not abort the rest
of the donor CONFIG.

## License

See [LICENSE](LICENSE).
