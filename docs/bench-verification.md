# Captain DMA bench verification

Persistent flash is on hold. Scope is the isolated, authorized bench. FPGA SRAM or SPI NOR programming requires approval of the exact image and procedure.

## Verified hardware and image

- A read-only scan of J2 Interface A (0403:6011, MI_00) returned FPGA IDCODE 0x0362D093, consistent with the XC7A35T FGG484 markings. The scan used the installed FTDI D2XX driver. Windows OpenOCD requires a compatible USB binding on J2.
- J3 is the FT601 data interface (0403:601F). Signed Windows D3XX 1.3.0.10 installed and enumerated one device.
- The previously staged .bit file has SHA-256 C0D3426EF19E7A66866D5D3499BE6D91D87A7C2CCB8DE9EF8839B43CE0AAD717. Its payload reproduced from the saved routed, physically optimized checkpoint. That checkpoint reported zero routing and bitstream DRC errors, +0.882 ns setup slack, and +0.034 ns hold slack.
- The Windows bench copy differs from this repository in FT601 placement attributes and timing exceptions. Four XSim tests passed on that copy. A clean build of that copy produced a different payload from its saved checkpoint. Those results do not justify applying the bench copy's blanket FT601 output multicycle exception to this repository.

## Timing review

The board reference clock is declared at the sys_clk_p input. In a scratch checkpoint experiment this removed TIMING-3 with the same clock coverage and setup/hold margins. The reset-synchronizer exception matched no cells in the audited build and has been removed. Two CDC-13 entries in the previous routed report refer to the same select path into the vendor PCIe PIPE BUFGCTRL under two clock contexts. The generated core uses the mux select inputs, with enables tied high and ignore inputs low. Keep these findings visible and verify Gen2 training across cold boots.

- [AMD TIMING-3 guidance](https://docs.amd.com/r/en-US/ug906-vivado-design-analysis/TIMING-3-Invalid-Primary-Clock-on-Clock-Modifying-Block)
- [AMD 7 Series BUFGCTRL](https://docs.amd.com/r/en-US/ug953-vivado-7series-libraries/BUFGCTRL)

## Independent bench checks

1. **PCIe enumeration.** After an approved flash and a full power-off, use the host PCI inventory to locate 10EC:8125 REV_36. Record slot or bus address, status, and negotiated link speed and width. The onboard Realtek NIC on this bench has REV_04.
2. **PCIe BAR0.** Use a bench PCIe MMIO reader against the confirmed REV_36 endpoint's assigned BAR0. Record aligned DWORD reads at offsets 0x00 and 0x04 and compare with the MAC register in rtl8125b_bar0_regs.sv. Capture the baseline before the network driver changes those registers. Record this separately from USB or PCI configuration-space reads.
3. **FT601 register transport.** Connect J3 and use the Windows D3XX driver and the ftd3xx Python package. From the repository root:

   ~~~powershell
   python -m host.ft601_register_probe --serial <bench-FT601-serial>
   ~~~

   This probe sends a framed read of status register 0x10 in the USB-accessible control block and checks the response header, address, and payload. It does not start DMA. Run it on a card already running the audited firmware. Offline checks exercised exact request bytes, fragmented and truncated responses, malformed headers, and invalid status. The no-match path was checked on Windows. A device response remains pending.
4. **Idle observation.** Record PCIe/WHEA errors and link stability separately from traffic. A claim of zero unsolicited traffic requires a trace or a counter that measures transactions attributable to the endpoint.

## Before programming

Confirm SPI NOR part and geometry, select a compatible method, and review the exact candidate hash and command. The installed PCILeech command reference lacks an FPGA flash command. The documented OpenOCD indirect SPI procedure temporarily loads an FPGA proxy, which also requires approval. Preserve a recovery path and verify the written bytes before cold-boot testing.

- [CaptainDMA hardware notes](https://github.com/ufrisk/pcileech-fpga/blob/master/CaptainDMA/readme.md)
- [OpenOCD update-port workflow](https://docs.lambdaconcept.com/screamer/programming.html)

## Verification of this branch

- The clean Vivado build of the clock and reset constraint corrections synthesized and routed. The timing gate withheld the bitstream at +0.471 ns setup and -2.318 ns hold. The worst hold paths run from the FT601 tristate registers to byte-enable and data outputs. The passing margins from the bench checkpoint are separate evidence.
- All four XSim testbenches passed against the GitHub RTL when run in the previously working scratch directory. The first attempt hit a Windows child-process launch error.

- A separate fabric-placement experiment with the same FT601 constraints routed at -5.313 ns setup and +0.034 ns hold. It traded the hold failure for a setup failure, so those placement attributes were excluded from this branch. Keep the flash on hold until the FT601 output timing closes against an interface model supported by the actual capture edges and board delays.

## FT601 phase experiment

FTDI Table 4.2 specifies 1.0 ns setup and 4.8 ns hold for FPGA-driven signals at the FT601. A scratch variant kept these requirements and retimed the pin outputs using a related 100 MHz clock shifted by 3 ns. Receive sampling and the FIFO handshakes stayed on the original clock. All four existing functional simulations passed on that variant. The routed build had −2.666 ns setup and +0.034 ns hold, with the worst setup path from a tristate register to FT601 data bit 27. The timing gate withheld the image. The experimental RTL remains outside this branch.

The BAR0 endpoint now decodes both three- and four-DWORD PCIe read headers. The regression checks the original four-DWORD read at offset 0x00 and a three-DWORD read at offset 0x04 with the transmit path stalled. All four XSim benches passed with the BAR0 fix isolated from the experimental FT601 clock changes. Physical MMIO verification remains pending. A full NIC driver or memory-write test is outside the scope of this read-only check.

[FTDI FT600Q/FT601Q FIFO AC timing](https://ftdichip.com/wp-content/uploads/2020/07/DS_FT600Q-FT601Q-IC-Datasheet.pdf)

## Follow-up clock experiments

| Scratch configuration | Routed setup slack | Routed hold slack |
| --- | ---: | ---: |
| Direct MMCM input, fast board-profile outputs, 3 ns output phase | −5.298 ns | −1.534 ns |
| Direct MMCM input, fast outputs, 5.5 ns output phase | −2.694 ns | +0.034 ns |
| Shared MMCM, 0 ns input phase and 5.5 ns output phase | −1.661 ns | +0.034 ns |

The shared MMCM case met the output-pin and internal handoff timing, but missed FT601 input setup. The scratch follow-up separates FT601 pin capture from the FIFO logic and models the prior external data launch edge and next-data hold edge. FTDI Table 4.2 gives 3 ns setup and 3.5 ns hold for FT601-driven pins. At 100 MHz, an input sampled at 2.5 ns after CLKOUT must see data launched on the preceding rising edge and retain hold protection against data changes after the current rise. The scratch constraint is scoped to FT601 input ports and the related capture clock. Output timing and internal paths keep their normal checks. Full timing closure is pending.

[AMD phase-shift timing edge selection](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Multicycle-Paths-and-Clock-Phase-Shift)

The input-capture-stage variant with the corrected edge pairing, 1 ns capture, and 5.5 ns output launch reached −0.273 ns setup and +0.034 ns hold after routing. Input-pin setup and hold were +1.390 ns and +3.276 ns. Output-pin setup and hold were +0.493 ns and +0.966 ns. The remaining failing paths were internal, chiefly the sampled RXF_N flag to the tristate-control registers. All four simulations passed. Aggressive post-route optimization left the same worst setup slack. Neither run generated a bitstream. The follow-up uses a 0.5 ns capture point to trade some of the positive input setup margin for additional internal handoff time.

## Bus-ownership timing closure

The revised logic captures the FT601 inputs at 0.5 ns after CLKOUT and runs the FIFO state machine and output registers on the 5.5 ns phase. A transmit claim state registers bus ownership a cycle before driving the bus. This removes the high-fanout tristate registers from the short receive-flag path. All four XSim tests passed, including aborting a claimed transfer, contention checks, and retrying the queued word exactly once.

Vivado 2026.1 completed a clean source-to-bitstream build. Timing was +0.494 ns setup and +0.034 ns hold. The independent checkpoint audit reported 2,977 fully routed nets, zero routing errors, passing bus skew, zero unclocked registers, and zero unconstrained internal endpoints. Bitstream generation reported zero DRC errors. The local scratch image SHA-256 was 0277800DC8A1B8E5804CA01BB93202A16DA9D1E45C41219CE3018D317D9DC45E.

The checkpoint also exposed a CDC-10 warning and LUTAR-1 warning on the combinational FT601 reset qualifier. This scratch image is excluded from the flash plan. The follow-up rebuild uses the MMCM LOCKED output directly for asynchronous assertion and keeps the two-stage synchronized release. The vendor PIPE clock-mux CDC entries are tracked separately.
