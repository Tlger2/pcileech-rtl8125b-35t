# Firmware contract (DMA bring-up)

Proven path after **cold boot** (not SRAM-only): `10EC:8125` SUBSYS `10EC:0123`
REV `05`, Present, RID `0x0500`, GO_READ PA `0x1000000` STATUS=DONE, 2 CplD.

This file is the DMA contract. Later identity, BAR, USB, or timing edits must
keep these facts. It is not anti-cheat guidance.

## TX arbitration

CplD **>** MSI-X **>** DMA. Site: `rtl/pcie_custom_endpoint_top.sv` section 10.
Do not invert the mux or let DMA hold `s_axis_tx` across a BAR completion.

## Completer ID

Latch the last **non-zero** `cfg_completer_id`. Use the latched value as
Requester ID on DMA MemRd/MemWr DW1 and as Completer ID on BAR CplD.

| Debug RF | Meaning |
|---|---|
| `0x20` | **Effective** RID (live if non-zero, else latch) in `[31:16]` |
| `0x34` | **Raw** `cfg_completer_id` in `[15:0]` (0 until the RC enumerates) |

Do not hardcode `FALLBACK_BDF=0x0500`. JTAG **SRAM-only** (`openFPGALoader -m`)
re-GSRs the latch to 0 and the RC does not re-enumerate — BAR CplD / DMA then
need a cold boot. Do not claim CplD after SRAM-only.

## BAR map

7-series `pcie_7x` cannot emit an I/O BAR. A 256 B *Memory* BAR0 Code-10s
`rtcx21`. Keep:

- **No I/O BAR0**, **no 256 B Memory BAR0**
- **BAR2** 64-bit non-prefetchable **64 KB** (MAC)
- **BAR4** 64-bit non-prefetchable **16 KB** (MSI-X table @ 0, PBA @ `0x800`)

## Identity package is the single source

`rtl/rtl8125b_identity_pkg.sv` feeds:

- soft Type-0 / cap / ECAP copies
- `pcie_7x` CONFIG (`vivado_build.tcl` parses the package)
- DSN / MAC (`cfg_dsn`, BAR2 ID registers)
- host `DONOR_*` in `host/ft601_client.py`

Changing SSID / VID / DID / rev / MAC without **rebuilding the PCIe IP**,
**SPI reflash**, and a **cold boot** desyncs silicon from RTL and TB.

Working DMA identity is `10EC:8125` / `10EC:0123` / rev `05`. Onboard PnP
`1043:87D7` rev `04` is a different function; do not copy it into the package
without that full rebuild path.

## FT601 framing and WinUSB

- Frame MAGIC `0x5AA5_C33C`. Stock CaptainDMA PCILeech `0x77` is a different
  protocol — this bitstream will not answer it.
- Opcode scramble in `rtl/opcode_scramble_pkg.sv` is a **bijection**
  (`opc_decode(opc_encode(X)) == X`). Host LUT in `host/ft601_client.py` must
  stay in lock-step.
- WinUSB on FT601 (`USB\VID_0403&PID_601F`) and FT4232 **MI_00** (OFL / JTAG).
  OFL: `C:\msys64\ucrt64\bin\openFPGALoader.exe -c ft4232 --fpga-part xc7a35tfgg484`
  with **`spiOverJtag_xc7a35tfgg484`**, not `tools/bscan_spi_xc7a35t.bit`.
- SPI is ISSI **IS25LP032** (32 Mbit), not Winbond W25Q64.

## BME / `dma_hold_req`

Do not gate DMA on BME in the top-level hold mux: `dma_hold_req` is tied off
(`1'b0`). Do not wire `tlp_jitter_fsm` or `cfg_command[2]` into that port.
The root complex still enforces BME on the link.

`dma_engine` GO_* still samples `cfg_command[2]` so a BME=0 GO does not enter
`ST_WAIT_CPL`. That is not a second hold mux — do not re-introduce one.

## 7-series PCIe IP

- No Gen3 (Artix-7 GTP max is Gen2 x1). Do not advertise 8.0 GT/s.
- No live `cfg_ext_*` on Vivado 2026.1 `pcie_7x` 3.3. ECAPs are baked into
  the IP in `vivado_build.tcl`; the soft ECAP router is TB / source-of-truth.

## Bring-up smoke

Test PA **`0x1000000`**, LENGTH **1 DW**, GO_READ. Host: `python host/diag.py`,
then a 1-DW read of that PA. Burst `LENGTH>=32` is implemented (`MAX_BURST_DW=32`)
but is not the bring-up smoke — do not brick a working 1-DW path to try it.

## Rebuild / flash

A timing-clean bitstream from `vivado_build.tcl` is required before silicon
matches RTL. Flash SPI, verify, then **cold boot**. SRAM-only is for bring-up
probes only.
