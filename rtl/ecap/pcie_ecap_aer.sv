// lang: SystemVerilog, file: pcie_ecap_aer.sv, target: Xilinx Artix-7 XC7A35T, Vivado 2026.1
// PCI Express Extended Capability — Advanced Error Reporting (AER).
// ECAP ID 0x0001, version 2.  11 DWs (header + 10 data DWs), byte range 0x100..0x128.
//
// RTL8125B baseline defaults:
//   UncErrSev  = 32'h0006_2030  (completion timeout, ECRC, poisoned TLP, Unexpected Cpl fatal)
//   CorrErrMsk = 32'h0000_31C1  (advisory non-fatal + receiver errors masked by default)
//   All error status registers reset to 0 and are RW1C.
//   Header log DWs are RW (overwritten by hardware on a detected error).
//
// INTEGRATION — Xilinx 7-Series pcie_7x_0:
//   The 7-series integrated PCIe block owns all config-space TLPs from the RC.
//   This module cannot be wired inline as a live intercept via cfg_mgmt.
//   Two ways to get these values into silicon:
//
//   1. Vivado IP Wizard (recommended):
//      Open pcie_7x_0 -> Advanced tab -> Extended Capabilities.
//      Add "Advanced Error Reporting" and enter each DW value from the
//      read-only constants in this file (ECAP_HEADER through HDRLOG_3_RST).
//
//   2. Soft endpoint path:
//      If your design replaces the IP's config-space handling with a custom
//      TLP parser, instantiate this module in your config-space router and
//      drive cap_rd_en / cap_wr_en from the decoded config address.

module pcie_ecap_aer #(
    parameter logic [11:0] NEXT_CAP_OFFSET  = 12'h148,     // → VC at 0x148
    // RTL8125B-matched severity defaults
    parameter logic [31:0] UNCERRSEV_RST    = 32'h0006_2030,
    parameter logic [31:0] CORRERRMSK_RST   = 32'h0000_31C1
) (
    input  logic        clk,
    input  logic        rst_n,

    // DW-indexed access, cap_dw_idx 0..10 (DW 0 = ECAP header at 0x100)
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [3:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    // ---- ECAP header (read-only) ----------------------------------------
    // [31:20] next cap offset  [19:16] cap version  [15:0] ECAP ID
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h2, 16'h0001};

    // ---- RW1C error status regs -----------------------------------------
    logic [31:0] uncerr_sts_q;   // 0x104  Uncorrectable Error Status
    logic [31:0] correrr_sts_q;  // 0x110  Correctable   Error Status

    // ---- RW mask / severity / control regs ------------------------------
    logic [31:0] uncerr_msk_q;   // 0x108  Uncorrectable Error Mask    (rst=0: none masked)
    logic [31:0] uncerr_sev_q;   // 0x10C  Uncorrectable Error Severity
    logic [31:0] correrr_msk_q;  // 0x114  Correctable   Error Mask
    logic [31:0] aer_cap_ctl_q;  // 0x118  AER Capabilities & Control  (rst=0)

    // ---- Header log (RW, overwritten on error) ---------------------------
    logic [31:0] hdrlog_q [0:3]; // 0x11C..0x128

    // ---- Read mux --------------------------------------------------------
    always_comb begin
        case (cap_dw_idx)
            4'd0:  cap_rdata = ECAP_HEADER;
            4'd1:  cap_rdata = uncerr_sts_q;
            4'd2:  cap_rdata = uncerr_msk_q;
            4'd3:  cap_rdata = uncerr_sev_q;
            4'd4:  cap_rdata = correrr_sts_q;
            4'd5:  cap_rdata = correrr_msk_q;
            4'd6:  cap_rdata = aer_cap_ctl_q;
            4'd7:  cap_rdata = hdrlog_q[0];
            4'd8:  cap_rdata = hdrlog_q[1];
            4'd9:  cap_rdata = hdrlog_q[2];
            4'd10: cap_rdata = hdrlog_q[3];
            default: cap_rdata = 32'h0;
        endcase
    end

    // ---- Write / RW1C logic ---------------------------------------------
    function automatic logic [31:0] apply_be(
        input logic [31:0] cur,
        input logic [31:0] wdata,
        input logic [3:0]  be
    );
        logic [31:0] m;
        m = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
        apply_be = (cur & ~m) | (wdata & m);
    endfunction

    // BE expansion — shared by both RW1C paths
    logic [31:0] be_mask;
    assign be_mask = {{8{cap_be[3]}}, {8{cap_be[2]}},
                      {8{cap_be[1]}}, {8{cap_be[0]}}};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uncerr_sts_q  <= 32'h0;
            uncerr_msk_q  <= 32'h0;
            uncerr_sev_q  <= UNCERRSEV_RST;
            correrr_sts_q <= 32'h0;
            correrr_msk_q <= CORRERRMSK_RST;
            aer_cap_ctl_q <= 32'h0;
            for (int i = 0; i < 4; i++) hdrlog_q[i] <= 32'h0;
        end else if (cap_wr_en) begin
            case (cap_dw_idx)
                // DW0: ECAP header — read-only, writes ignored
                4'd1: uncerr_sts_q  <= uncerr_sts_q  & ~(cap_wdata & be_mask); // RW1C
                4'd2: uncerr_msk_q  <= apply_be(uncerr_msk_q,  cap_wdata, cap_be);
                4'd3: uncerr_sev_q  <= apply_be(uncerr_sev_q,  cap_wdata, cap_be);
                4'd4: correrr_sts_q <= correrr_sts_q & ~(cap_wdata & be_mask); // RW1C
                4'd5: correrr_msk_q <= apply_be(correrr_msk_q, cap_wdata, cap_be);
                4'd6: aer_cap_ctl_q <= apply_be(aer_cap_ctl_q, cap_wdata, cap_be);
                4'd7:  hdrlog_q[0]  <= apply_be(hdrlog_q[0],   cap_wdata, cap_be);
                4'd8:  hdrlog_q[1]  <= apply_be(hdrlog_q[1],   cap_wdata, cap_be);
                4'd9:  hdrlog_q[2]  <= apply_be(hdrlog_q[2],   cap_wdata, cap_be);
                4'd10: hdrlog_q[3]  <= apply_be(hdrlog_q[3],   cap_wdata, cap_be);
                default: ;
            endcase
        end
    end

endmodule
