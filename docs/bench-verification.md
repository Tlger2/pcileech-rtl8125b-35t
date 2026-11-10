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
