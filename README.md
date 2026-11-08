# pcileech-rtl8125b-35t

SystemVerilog RTL building blocks for a PCILeech-style CaptainDMA (XC7A35T, FGG484)
project that enumerates as a Realtek RTL8125B 2.5GbE NIC.

> Target: Xilinx Artix-7 XC7A35T, Xilinx 7-Series integrated PCIe block, FT601 USB 3.0
> device side, Vivado 2026.1.

## Modules

| File | Purpose |
|---|---|
| [rtl/opcode_scramble_pkg.sv](rtl/opcode_scramble_pkg.sv) | 8-bit opcode substitution LUT (host↔wire, bijective) |
| [rtl/tlp_dw0_decoder.sv](rtl/tlp_dw0_decoder.sv) | Parse PCIe TLP header DW0 (Fmt / Type / TC / Length) |
| [rtl/tlp_rid_tag_be_decoder.sv](rtl/tlp_rid_tag_be_decoder.sv) | Parse TLP DW1 (Requester ID / Tag / Byte Enables) |
| [rtl/tlp_addr_decoder.sv](rtl/tlp_addr_decoder.sv) | Extract memory address from DW2/DW3 (3-DW & 4-DW headers) |
| [rtl/tlp_cpld_header_fmt.sv](rtl/tlp_cpld_header_fmt.sv) | Build the three header DWs of a Completion with Data (CplD) |
| [rtl/pcie_cpld_axis_tx_mux.sv](rtl/pcie_cpld_axis_tx_mux.sv) | 64-bit AXI-Stream TX mux that packs CplD header + N-DW payload |
| [rtl/pcie_msi_trigger.sv](rtl/pcie_msi_trigger.sv) | MSI request generator with CDC sync, pulse stretch, vector masking |
| [rtl/ft601_cmd_parser.sv](rtl/ft601_cmd_parser.sv) | Parse command frames from the FT601 FIFO and drive a register file |
| [rtl/ft601_resp_packager.sv](rtl/ft601_resp_packager.sv) | Frame read results / status into response packets for the FT601 TX FIFO |
| [rtl/pcie_top_wrapper.sv](rtl/pcie_top_wrapper.sv) | Top-level that instantiates `pcie_7x_0` and the custom endpoint, with GT REFCLK + PERST# routing |
| [tb/tb_endpoint.sv](tb/tb_endpoint.sv) | Self-checking XSim testbench — parser, CplD mux, config/BAR decode, and BAR0 register behavior |
| [host/ft601_client.py](host/ft601_client.py) | Python host-side driver (pyftdi) for the FT601 framed protocol |
| [rtl/pci_type0_cfg_header.sv](rtl/pci_type0_cfg_header.sv) | PCI Type 0 configuration space header (RTL8125B identity, BARs, Command/Status) |
| [rtl/pci_cfg_space.sv](rtl/pci_cfg_space.sv) | Config-space router: header + PM/MSI/PCIe cap chain, with stub/full selector |
| [rtl/caps/pci_cap_pm.sv](rtl/caps/pci_cap_pm.sv) | PCI Power Management Capability (full, host-writable PMCSR) |
| [rtl/caps/pci_cap_msi.sv](rtl/caps/pci_cap_msi.sv) | MSI Capability (full, 64-bit addr, 8 vectors) |
| [rtl/caps/pci_cap_pcie.sv](rtl/caps/pci_cap_pcie.sv) | PCIe Capability v2 (full, Endpoint, MPS/MRRS host-writable) |
| [rtl/caps/pci_cap_pm_stub.sv](rtl/caps/pci_cap_pm_stub.sv) | PM Cap enumeration stub (read-only) |
| [rtl/caps/pci_cap_msi_stub.sv](rtl/caps/pci_cap_msi_stub.sv) | MSI Cap enumeration stub (read-only) |
| [rtl/caps/pci_cap_pcie_stub.sv](rtl/caps/pci_cap_pcie_stub.sv) | PCIe Cap enumeration stub (read-only) |
| [rtl/pcie_bar_decoder.sv](rtl/pcie_bar_decoder.sv) | BAR aperture match + Memory Space Enable (MSE) enforcement |
| [rtl/rtl8125b_bar0_regs.sv](rtl/rtl8125b_bar0_regs.sv) | RTL8125B operational BAR0 footprint: MAC, interrupt, reset/config, and descriptor-base registers |

## Configuration space layout

```
0x00 .. 0x3F : Type 0 header   (VID/DID, Command, Status, BARs, Cap Ptr=0x40)
0x40 .. 0x47 : PM Cap          (Cap ID 0x01, Next 0x50)
0x50 .. 0x5F : MSI Cap         (Cap ID 0x05, Next 0x70, 64-bit addr)
0x70 .. 0xAB : PCIe Cap v2     (Cap ID 0x10, Next 0x00, Endpoint)
```

Capability chain walks cleanly through Windows and Linux PCI enumeration.
Use the full caps when the host needs to configure MSI vectors / MPS / power
state; use the stubs for bring-up or testbench runs where only the chain
topology matters. Swap via `pci_cfg_space #(.USE_CAP_STUBS(1))`.

## BAR0 operational footprint

`rtl8125b_bar0_regs` implements the initialization-critical MMIO subset. It
models the RTL8125 32-bit interrupt mask/status pair at `0x38`/`0x3C`, the
MAC and multicast-filter words, `ChipCmd` reset self-clear, writable RX/TX
configuration, and the normal/high-priority TX plus RX descriptor bases.
`TxConfig` keeps the read-only RTL8125B XID (`0x641`) across driver writes.
Interrupt status is sticky/W1C and `irq_pending` is the masked-status OR.
The block deliberately contains no descriptor fetcher or packet/DMA engine.

| Offset | Width | Register behavior |
|---:|---:|---|
| `0x00`–`0x05` | 48 | MAC address, byte-addressable |
| `0x08`–`0x0F` | 64 | Multicast address filter |
| `0x20`/`0x24` | 64 | Normal-priority TX descriptor base |
| `0x28`/`0x2C` | 64 | High-priority TX descriptor base |
| `0x37` | 8 | `ChipCmd`; reset bit self-clears after a bounded delay |
| `0x38` | 32 | RTL8125 interrupt mask |
| `0x3C` | 32 | RTL8125 sticky/W1C interrupt status |
| `0x40` | 32 | TX configuration with read-only RTL8125B XID fields |
| `0x44` | 32 | RX configuration |
| `0xE4`/`0xE8` | 64 | RX descriptor base |

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
- **Spoof target:** Realtek RTL8125B 2.5GbE NIC
  - VID `0x10EC`, DID `0x8125`, Class `0x020000`, Rev `0x36`
  - Subsys VID `0x10EC`, SSID `0x0123`
  - PCIe Gen2 x1, BAR0 64 KB 64-bit prefetchable, BAR1 4 KB

## Build notes

These modules target the Xilinx 7-Series PCIe integrated block on an XC7A35T. The
AXI-Stream TX mux assumes the 64-bit `s_axis_tx` interface (Gen2 x1 default); port
to 128-bit by packing 4 DWs per beat with the same state-machine shape.

## License

See [LICENSE](LICENSE).

## Security note

The opcode scramble LUT is obfuscation, not encryption. A static byte-level
substitution is trivially broken by a handful of known-plaintext pairs. Layer a real
AEAD (AES-GCM, ChaCha20-Poly1305) on top of the framed payload if the link may be
observed or injected into.

