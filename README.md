# pcileech-rtl8125b-35t

SystemVerilog RTL building blocks for a PCILeech-style CaptainDMA (XC7A35T, FGG484)
project that enumerates as a Realtek RTL8125B 2.5GbE NIC.

> Target: Xilinx Artix-7 XC7A35T, Xilinx 7-Series integrated PCIe block, FT601 USB 3.0
> device side, Vivado 2026.1.

## Status

Donor identity (single source: [`rtl/rtl8125b_identity_pkg.sv`](rtl/rtl8125b_identity_pkg.sv)):

- VID `10EC`, DID `8125`, Rev `04`, SVID/SSID `1043:87D7`, class `020000`
  (onboard PnP Type-0 DWs: `PCI\VEN_10EC&DEV_8125&SUBSYS_87D71043&REV_04`)
- MAC `00:E0:4C:7A:3B:91` (DSN derived from the same MAC, also `cfg_dsn`;
  not a clone of onboard `7C:10:C9:45:5E:D0`)
- TxConfig chip id `0x64Axxxxx` so r8169/r8125 IDs RTL8125B

Done in RTL (needs a Vivado rebuild + SPI reflash + **cold boot** before silicon matches):

- BAR2 64 KiB MAC register file takes the real MemWr payload (not hard-wired 0)
- 64 KiB BAR2 shadow in BRAM; named r8169/r8125/rt640x64 offsets (MAC, TxConfig,
  PHYAR, CSI, ERI/EPHY/OCP/GPHY_OCP Flag protocol, ChipCmd, TxPoll TOK irq,
  descriptor rings, TimeInt2, MTPS, FuncEvent, …)
- Completer ID is the last non-zero `cfg_completer_id` (debug 0x20=effective,
  0x34=raw). No hardcoded `FALLBACK_BDF=0x0500`.
- MSI handshake via `pcie_msi_trigger` (held until `cfg_interrupt_rdy`)
- MSI-X 32-vector table/PBA in BAR4; irq pulse emits a MemWr TLP when MSI-X is enabled
- Soft config-space chain: PM `0x40` → MSI `0x50` → PCIe `0x70` → MSI-X `0xB0` → VPD `0xD0`
- Soft ECAP chain: AER `0x100` → VC `0x148` → DSN `0x168` → TPH `0x178` → LTR `0x204` → L1PM `0x20C` → VSEC `0x21C`

Still cannot be 1:1 on XC7A35T `pcie_7x`:

- **I/O BAR0 (donor 256 B I/O).** 7-series IP has no I/O BAR. A 256 B *Memory* BAR0
  Code-10s rtcx21, so BAR0 is omitted and the MAC window is BAR2 (same resource
  map Windows assigns the onboard 8125B on this machine). Comment is at the
  constraint site in `pci_type0_cfg_header.sv` and `vivado_build.tcl`.
- **Gen3.** Artix-7 GTP is Gen2 x1 max. Soft PCIe cap advertises Gen2 x1.
  `pcie_7x` 3.3 has no `Target_Link_Speed` / `Link_Cap_Max_Link_Speed` properties
  (both skip); advertised speed is `CONFIG.Link_Speed = 5.0_GT/s`. The wrapper
  keeps Gen2 if the RP trained it, otherwise one `pl_directed_link_change`
  uptrain, CED → Gen1. Live 5 GT/s still needs the RP to allow it.
- **Live `cfg_ext_*`.** Vivado 2026.1 `pcie_7x` 3.3 has no `cfg_ext_*` ports, so
  silicon ECAPs must be baked into the IP (`vivado_build.tcl`). The soft router
  is the TB/source-of-truth copy of those DWs.
- Full GPHY/OCP/ERI/CSI maps beyond the Flag protocol + a small stub array.
- Cap/ECAP DWs beyond Type-0 were not readable from user mode (no admin
  dump tool). Soft/IP ECAPs stay the baked 8125B chain.
- SRAM-only reload zeros the completer-ID latch; CplD/DMA still need cold boot.
- After SSID match Windows inbox `rtcx21` (Microsoft 1.0.0.14) will rank-match
  the same hardware ID as the onboard NIC. Do not force-install `rt640x64`.
  The Null `oem39.inf` only matches `10EC:0123`; keep it if DMA would break.

## Modules

| File | Purpose |
|---|---|
| [rtl/rtl8125b_identity_pkg.sv](rtl/rtl8125b_identity_pkg.sv) | Donor VID/DID/rev/SSID/MAC/DSN/BAR/cap pointers |
| [rtl/rtl8125b_bar0_regs.sv](rtl/rtl8125b_bar0_regs.sv) | MAC MMIO (BAR2 64 KiB), PHYAR/ERI/OCP, irq pulse |
| [rtl/ecap/pcie_ecap_router.sv](rtl/ecap/pcie_ecap_router.sv) | ECAP chain router (AER/VC/DSN/TPH/LTR/L1PM/VSEC) |
| [rtl/ecap/pcie_ecap_aer.sv](rtl/ecap/pcie_ecap_aer.sv) | AER Extended Capability (ECAP ID 0x0001, ver 2) |
| [rtl/ecap/pcie_ecap_vc.sv](rtl/ecap/pcie_ecap_vc.sv) | Virtual Channel (ECAP ID 0x0002) at 0x148 |
| [rtl/ecap/pcie_ecap_dsn.sv](rtl/ecap/pcie_ecap_dsn.sv) | Device Serial Number (ECAP ID 0x0003), MAC-derived |
| [rtl/ecap/pcie_ecap_tph.sv](rtl/ecap/pcie_ecap_tph.sv) | TPH Requester (ECAP ID 0x0017) at 0x178 |
| [rtl/ecap/pcie_ecap_ltr.sv](rtl/ecap/pcie_ecap_ltr.sv) | LTR (ECAP ID 0x0018) at 0x204 |
| [rtl/ecap/pcie_ecap_l1pm.sv](rtl/ecap/pcie_ecap_l1pm.sv) | L1 PM Substates (ECAP ID 0x001E) at 0x20C |
| [rtl/ecap/pcie_ecap_vsec.sv](rtl/ecap/pcie_ecap_vsec.sv) | Vendor-Specific ECAP (ID 0x000B) at 0x21C |
| [rtl/caps/pci_cap_vpd.sv](rtl/caps/pci_cap_vpd.sv) | VPD capability at 0xD0 |
| [rtl/opcode_scramble_pkg.sv](rtl/opcode_scramble_pkg.sv) | 8-bit opcode substitution LUT (host↔wire, bijective) |
| [rtl/crypto/chacha20_core.sv](rtl/crypto/chacha20_core.sv) | ChaCha20 block cipher, 20 rounds, 64-byte keystream block |
| [rtl/crypto/trng_ring_osc.sv](rtl/crypto/trng_ring_osc.sv) | Ring-oscillator TRNG for ephemeral handshake nonces |
| [rtl/crypto/secure_session_fsm.sv](rtl/crypto/secure_session_fsm.sv) | PSK-rooted mutual-auth handshake |
| [rtl/crypto/secure_frame_enc.sv](rtl/crypto/secure_frame_enc.sv) | Data-plane ChaCha20 wrapper |
| [rtl/tlp_dw0_decoder.sv](rtl/tlp_dw0_decoder.sv) | Parse PCIe TLP header DW0 (Fmt / Type / TC / Length) |
| [rtl/tlp_rid_tag_be_decoder.sv](rtl/tlp_rid_tag_be_decoder.sv) | Parse TLP DW1 (Requester ID / Tag / Byte Enables) |
| [rtl/tlp_addr_decoder.sv](rtl/tlp_addr_decoder.sv) | Extract memory address from DW2/DW3 (3-DW & 4-DW headers) |
| [rtl/tlp_cpld_header_fmt.sv](rtl/tlp_cpld_header_fmt.sv) | Build the three header DWs of a Completion with Data (CplD) |
| [rtl/pcie_cpld_axis_tx_mux.sv](rtl/pcie_cpld_axis_tx_mux.sv) | 64-bit AXI-Stream TX mux that packs CplD header + N-DW payload |
| [rtl/pcie_msi_trigger.sv](rtl/pcie_msi_trigger.sv) | MSI request generator with CDC sync, pulse stretch, vector masking |
| [rtl/msix_table_pba.sv](rtl/msix_table_pba.sv) | MSI-X table + PBA in BAR4 (32 vectors, PBA at 0x800) |
| [rtl/msix_mwr_tx.sv](rtl/msix_mwr_tx.sv) | MSI-X Memory Write TLP generator |
| [rtl/ft601_cmd_parser.sv](rtl/ft601_cmd_parser.sv) | Parse command frames from the FT601 FIFO and drive a register file |
| [rtl/ft601_resp_packager.sv](rtl/ft601_resp_packager.sv) | Frame read results / status into response packets for the FT601 TX FIFO |
| [rtl/pcie_top_wrapper.sv](rtl/pcie_top_wrapper.sv) | Top-level that instantiates `pcie_7x_0` and the custom endpoint |
| [tb/tb_endpoint.sv](tb/tb_endpoint.sv) | Self-checking TB — parser, CplD mux, cap/ECAP walk, BAR2/BAR4, MAC regs |
| [host/ft601_client.py](host/ft601_client.py) | Python host-side driver (pyftdi) for the FT601 framed protocol |
| [rtl/pci_type0_cfg_header.sv](rtl/pci_type0_cfg_header.sv) | PCI Type 0 header (RTL8125B identity, BAR2+BAR4 64-bit) |
| [rtl/pci_cfg_space.sv](rtl/pci_cfg_space.sv) | Config-space router: header + PM/MSI/PCIe/MSI-X/VPD |
| [rtl/caps/pci_cap_pm.sv](rtl/caps/pci_cap_pm.sv) | PCI Power Management Capability (D1+D2, PME, Aux 375 mA) |
| [rtl/caps/pci_cap_msi.sv](rtl/caps/pci_cap_msi.sv) | MSI Capability (64-bit, maskable, 1 vector) |
| [rtl/caps/pci_cap_pcie.sv](rtl/caps/pci_cap_pcie.sv) | PCIe Capability v2 (Endpoint, Gen2 x1, LTR in Dev Cap 2) |
| [rtl/caps/pci_cap_msix.sv](rtl/caps/pci_cap_msix.sv) | MSI-X Capability (32 vec, BAR4, PBA 0x800) |
| [rtl/pcie_bar_decoder.sv](rtl/pcie_bar_decoder.sv) | BAR2/BAR4 aperture match + Memory Space Enable |

## Configuration space layout

```
0x00 .. 0x3F : Type 0 header   (VID/DID, Command, Status, BAR2+BAR4, Cap Ptr=0x40)
0x40 .. 0x47 : PM Cap          (Cap ID 0x01, Next 0x50)
0x50 .. 0x67 : MSI Cap         (Cap ID 0x05, Next 0x70, 64-bit + mask)
0x70 .. 0xAB : PCIe Cap v2     (Cap ID 0x10, Next 0xB0, Endpoint)
0xB0 .. 0xBB : MSI-X Cap       (Cap ID 0x11, Next 0xD0, 32 vec in BAR4)
0xD0 .. 0xD7 : VPD Cap         (Cap ID 0x03, Next 0x00)
```

BAR0 is unused on this part (see Status). Silicon identity is also programmed
into `pcie_7x_0` by `vivado_build.tcl` — the soft header is for TB and any
soft-endpoint path.

## Command/response frame format

```
DW0  : 32'h5AA5_C33C                              (MAGIC)
DW1  : {opcode[7:0], flags[7:0], length_dw[15:0]}
DW2  : 32-bit target address
DW3+ : length_dw words of payload
```

Opcodes live in `opcode_scramble_pkg` — canonical codes internally, scrambled bytes
on the wire. The two directions are strict inverses (`opc_decode(opc_encode(X)) == X`
for every defined `X`).

## Hardware

- **Board:** CaptainDMA 35T (XC7A35T FGG484 + FTDI FT601 USB 3.0 bridge)
- **SPI flash:** ISSI IS25LP032 (32 Mbit), not Winbond W25Q64
- **Spoof target:** Realtek RTL8125B 2.5GbE NIC, onboard donor `1043:87D7` rev `04`
  - VID `0x10EC`, DID `0x8125`, Class `0x020000`, Rev `0x04`
  - Subsys VID `0x1043`, SSID `0x87D7`
  - PCIe Gen2 x1 advertised; wrapper keeps/uptrains 5 GT/s (CED falls back to Gen1)
  - BAR2 64 KB 64-bit non-prefetchable (MAC), BAR4 16 KB 64-bit npref (MSI-X)
  - Donor I/O 256 B BAR0 is omitted (7-series IP limit)

## Build notes

These modules target the Xilinx 7-Series PCIe integrated block on an XC7A35T. The
AXI-Stream TX mux assumes the 64-bit `s_axis_tx` interface (Gen2 x1 default); port
to 128-bit by packing 4 DWs per beat with the same state-machine shape.

RTL identity/BAR/MSI changes are **not** in the currently flashed bitstream until
`vivado_build.tcl` is re-run, the SPI image is reflashed with OFL's
`spiOverJtag_xc7a35tfgg484` (not `tools/bscan_spi_xc7a35t.bit`), and the host
does a **cold boot**. SRAM-only (`-m`) does not re-enumerate CplD/DMA.

```
C:\msys64\ucrt64\bin\openFPGALoader.exe -c ft4232 --fpga-part xc7a35tfgg484 -f --verify --unprotect-flash pcie_top_wrapper.bit
C:\msys64\ucrt64\bin\openFPGALoader.exe -c ft4232 --fpga-part xc7a35tfgg484 -m pcie_top_wrapper.bit
```

## License

See [LICENSE](LICENSE).

## Security note

The opcode scramble LUT is obfuscation, not encryption. A static byte-level
substitution is trivially broken by a handful of known-plaintext pairs. Layer a real
AEAD (AES-GCM, ChaCha20-Poly1305) on top of the framed payload if the link may be
observed or injected into.
