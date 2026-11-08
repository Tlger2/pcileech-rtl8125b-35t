// lang: SystemVerilog, file: pcie_ecap_dsn.sv, target: Xilinx Artix-7 XC7A35T, Vivado 2026.1
// PCI Express Extended Capability — Device Serial Number (DSN).
// ECAP ID 0x0003, version 1.  3 DWs (header + 2 data DWs), byte range 0x150..0x158.
//
// The 64-bit serial is derived from the RTL8125B default MAC address (00:E0:4C:12:34:56):
//   DSN_LO = {MAC[23:0],  8'h00}  = 0x1234_5600
//   DSN_HI = {8'h00, OUI[23:0]}   = 0x00E0_4C00
//
// Adjust MAC_ADDR to match whatever MAC you burned into rtl8125b_bar0_regs so the
// DSN stays consistent with what the driver reads from BAR0 offset 0x00.
//
// INTEGRATION: same constraints as pcie_ecap_aer.sv — feed the ECAP_HEADER / DSN
// constants to the Vivado IP wizard under Extended Capabilities > Device Serial Number,
// or use in a soft PCIe endpoint path.

module pcie_ecap_dsn #(
    parameter logic [11:0] NEXT_CAP_OFFSET = 12'h160,          // → LTR at 0x160
    parameter logic [47:0] MAC_ADDR        = 48'h00_E0_4C_12_34_56
) (
    // No clk/rst needed — entirely read-only constants.
    input  logic       cap_rd_en,
    input  logic [1:0] cap_dw_idx,   // 0=header, 1=DSN_LO, 2=DSN_HI
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h0003};

    // Build serial from MAC: upper half carries the OUI, lower half the unique part.
    // Layout mirrors common Realtek DSN captures:
    //   DSN[31: 0]  = { MAC[23:16], MAC[15:8], MAC[7:0], 8'h00 }
    //   DSN[63:32]  = { 8'h00, MAC[47:40], MAC[39:32], MAC[31:24] }
    localparam logic [31:0] DSN_LO = {MAC_ADDR[23:16], MAC_ADDR[15:8],
                                      MAC_ADDR[7:0],   8'h00};
    localparam logic [31:0] DSN_HI = {8'h00, MAC_ADDR[47:40],
                                      MAC_ADDR[39:32], MAC_ADDR[31:24]};

    always_comb begin
        case (cap_dw_idx)
            2'd0:   cap_rdata = ECAP_HEADER;
            2'd1:   cap_rdata = DSN_LO;
            2'd2:   cap_rdata = DSN_HI;
            default: cap_rdata = 32'h0;
        endcase
    end

endmodule
