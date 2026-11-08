# pcileech-rtl8125b-35t

SystemVerilog RTL building blocks for a PCILeech-style CaptainDMA (XC7A35T, FGG484)
project that enumerates as a Realtek RTL8125B 2.5GbE NIC.

> Target: Xilinx Artix-7 XC7A35T, Xilinx 7-Series integrated PCIe block, FT601 USB 3.0
> device side, Vivado 2026.1.

## Modules

| File | Purpose |
|---|---|
| [rtl/ecap/pcie_ecap_router.sv](rtl/ecap/pcie_ecap_router.sv) | ECAP chain router — decodes 10-bit DW addresses ≥ 0x040 and dispatches to AER / DSN / LTR caps |
| [rtl/ecap/pcie_ecap_aer.sv](rtl/ecap/pcie_ecap_aer.sv) | AER Extended Capability (ECAP ID 0x0001, ver 2) — 11 DWs at 0x100, RTL8125B severity defaults |
| [rtl/ecap/pcie_ecap_dsn.sv](rtl/ecap/pcie_ecap_dsn.sv) | Device Serial Number (ECAP ID 0x0003, ver 1) — 3 DWs at 0x150, serial derived from MAC_ADDR |
| [rtl/ecap/pcie_ecap_ltr.sv](rtl/ecap/pcie_ecap_ltr.sv) | Latency Tolerance Reporting (ECAP ID 0x0018, ver 1) — 2 DWs at 0x160, 3.2 µs default, end of chain |
| [rtl/opcode_scramble_pkg.sv](rtl/opcode_scramble_pkg.sv) | 8-bit opcode substitution LUT (host↔wire, bijective) — legacy, superseded by the crypto path when `secure_session_fsm` is wired in |
| [rtl/crypto/chacha20_core.sv](rtl/crypto/chacha20_core.sv) | ChaCha20 block cipher, 20 rounds, 64-byte keystream block |
| [rtl/crypto/trng_ring_osc.sv](rtl/crypto/trng_ring_osc.sv) | Ring-oscillator TRNG for ephemeral handshake nonces |
| [rtl/crypto/secure_session_fsm.sv](rtl/crypto/secure_session_fsm.sv) | PSK-rooted mutual-auth handshake (CLIENT_HELLO → SERVER_CHALLENGE → CLIENT_RESPONSE → SERVER_ACK) with session-key derivation |
| [rtl/crypto/secure_frame_enc.sv](rtl/crypto/secure_frame_enc.sv) | Data-plane ChaCha20 wrapper — encrypts outbound command/response frames per session |
| [rtl/tlp_dw0_decoder.sv](rtl/tlp_dw0_decoder.sv) | Parse PCIe TLP header DW0 (Fmt / Type / TC / Length) |
| [rtl/tlp_rid_tag_be_decoder.sv](rtl/tlp_rid_tag_be_decoder.sv) | Parse TLP DW1 (Requester ID / Tag / Byte Enables) |
| [rtl/tlp_addr_decoder.sv](rtl/tlp_addr_decoder.sv) | Extract memory address from DW2/DW3 (3-DW & 4-DW headers) |
| [rtl/tlp_cpld_header_fmt.sv](rtl/tlp_cpld_header_fmt.sv) | Build the three header DWs of a Completion with Data (CplD) |
| [rtl/pcie_cpld_axis_tx_mux.sv](rtl/pcie_cpld_axis_tx_mux.sv) | 64-bit AXI-Stream TX mux that packs CplD header + N-DW payload |
| [rtl/pcie_msi_trigger.sv](rtl/pcie_msi_trigger.sv) | MSI request generator with CDC sync, pulse stretch, vector masking |
| [rtl/ft601_cmd_parser.sv](rtl/ft601_cmd_parser.sv) | Parse command frames from the FT601 FIFO and drive a register file |
| [rtl/ft601_resp_packager.sv](rtl/ft601_resp_packager.sv) | Frame read results / status into response packets for the FT601 TX FIFO |
| [rtl/pcie_top_wrapper.sv](rtl/pcie_top_wrapper.sv) | Top-level that instantiates `pcie_7x_0` and the custom endpoint, with GT REFCLK + PERST# routing |
| [tb/tb_endpoint.sv](tb/tb_endpoint.sv) | Self-checking XSim testbench — parser frames + CplD TX mux beat stream |
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
