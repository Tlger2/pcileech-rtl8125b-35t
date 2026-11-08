// lang: SystemVerilog, file: pcie_ecap_ltr.sv, target: Xilinx Artix-7 XC7A35T, Vivado 2026.1
// PCI Express Extended Capability — Latency Tolerance Reporting (LTR).
// ECAP ID 0x0018, version 1.  2 DWs (header + LTR register), byte range 0x160..0x164.
// End of the extended cap chain: NEXT_CAP_OFFSET = 0x000.
//
// LTR register layout (PCIe base spec 4.0 §7.8.26):
//   [15:0]  Max Snoop Latency    — { 1'b0, scale[2:0], value[9:0] }
//   [31:16] Max No-Snoop Latency — { 1'b0, scale[2:0], value[9:0] }
//
//   Scale encoding:
//     000 = 1 ns      001 = 32 ns     010 = 1024 ns
//     011 = 32768 ns  100 = 1048576 ns  101 = 33554432 ns
//
// RTL8125B default: scale=001 (32 ns), value=100 → 3200 ns ≈ 3.2 µs (both directions).
//   Encoded: {1'b0, 3'b001, 10'd100} = 16'h0464
//   Register: 32'h0464_0464
//
// The LTR register is host-writable (the RC may update it after BIOS/driver init).
//
// INTEGRATION: same as pcie_ecap_aer.sv.

module pcie_ecap_ltr #(
    parameter logic [11:0] NEXT_CAP_OFFSET = 12'h000,     // end of chain
    // scale=001 (32 ns), value=100 → 3200 ns
    parameter logic [15:0] SNOOP_LAT_RST   = 16'h0464,
    parameter logic [15:0] NOSNOOP_LAT_RST = 16'h0464
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [0:0]  cap_dw_idx,   // 0=header (RO), 1=LTR register (RW)
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h0018};

    logic [15:0] snoop_lat_q;
    logic [15:0] nosnoop_lat_q;

    always_comb begin
        case (cap_dw_idx)
            1'b0: cap_rdata = ECAP_HEADER;
            1'b1: cap_rdata = {nosnoop_lat_q, snoop_lat_q};
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snoop_lat_q   <= SNOOP_LAT_RST;
            nosnoop_lat_q <= NOSNOOP_LAT_RST;
        end else if (cap_wr_en && cap_dw_idx == 1'b1) begin
            if (cap_be[0]) snoop_lat_q[7:0]   <= cap_wdata[7:0];
            if (cap_be[1]) snoop_lat_q[15:8]  <= cap_wdata[15:8];
            if (cap_be[2]) nosnoop_lat_q[7:0]  <= cap_wdata[23:16];
            if (cap_be[3]) nosnoop_lat_q[15:8] <= cap_wdata[31:24];
        end
    end

endmodule
