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
- MAC register file uses r8125/r8169 offsets (ChipCmd 0x37, TxPoll 0x38, IntrStatus 0x3e, PHYAR 0x60). TxConfig chip id is `0x64Axxxxx` (RTL8125B). PHYAR completes so a Windows PHY probe does not Code 10.
- DMA engine issues burst MRd/MWr with a real Length field, up to 32 DW (128 B) / MPS. Host `--selftest` still passes. `LeechCoreAdapter` maps identify/read/write onto the existing MAGIC+opcode path.

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

## Bring-up on the card

1. Build in Vivado 2026.1 (`vivado -mode batch -source vivado_build.tcl`) and flash.
2. `lspci -nnvvv` against a donor RTL8125B rev 05: IDs, rev, BAR types/sizes, cap next-ptrs, DSN at 0x168, MSI-X Table BIR=4 / PBA 0x800.
3. Windows Device Manager: r8125 / rt640x64 bind, PHYAR probe, no Code 10.
4. FT601: `python host/ft601_client.py --selftest` (offline) then `--identify` / adapter `read`/`write` with the card attached.

## Build notes

These modules target the Xilinx 7-Series PCIe integrated block on an XC7A35T. The
AXI-Stream TX mux assumes the 64-bit `s_axis_tx` interface (Gen2 x1 default).
Optional `pcie_7x` properties (PM_BASE_PTR, MSI-X BIR spellings, Aux_Current)
are applied with `ip_try_set` so a missing 2026.1 name does not abort the rest
of the donor CONFIG.

## License

See [LICENSE](LICENSE).
