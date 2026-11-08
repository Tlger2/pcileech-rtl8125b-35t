// lang: SystemVerilog, file: pcie_ecap_router.sv, target: Xilinx Artix-7 XC7A35T, Vivado 2026.1
// Extended Configuration Space (ECAP) router.
//
// Routes 10-bit DW addresses covering byte offsets 0x100–0xFFF to the three
// RTL8125B extended capability modules.  Addresses 0x000–0x03F (standard
// config space, byte 0x000–0x0FF) must NOT be driven here — the caller is
// responsible for the split.
//
// ECAP chain (matches real RTL8125B captures):
//   0x100..0x128  AER  (ECAP ID 0x0001, ver 2, 11 DWs)  next → 0x150
//   0x150..0x158  DSN  (ECAP ID 0x0003, ver 1,  3 DWs)  next → 0x160
//   0x160..0x164  LTR  (ECAP ID 0x0018, ver 1,  2 DWs)  next → 0x000 (end)
//
// DW address → byte offset: byte = dw_addr * 4.
//   AER base  DW: 0x040  (0x100 / 4)   range 0x040..0x04A
//   DSN base  DW: 0x054  (0x150 / 4)   range 0x054..0x056
//   LTR base  DW: 0x058  (0x160 / 4)   range 0x058..0x059
//
// All other ECAP addresses return 0x0 (no capability).
//
// INTEGRATION — Xilinx 7-Series pcie_7x_0 (critical):
//
//   The 7-series integrated PCIe block intercepts ALL type-0 config TLPs from
//   the RC and responds directly — this router CANNOT be inserted as a live
//   intercept in the standard endpoint IP flow.  Instead, use it one of two ways:
//
//   WAY 1 (simplest) — feed the constant DW values to the Vivado IP wizard:
//     Open pcie_7x_0 → Advanced → Extended Capabilities.
//     For each cap, enable it and enter the DW contents as a hex string.
//     Extract the right values from the localparam expressions in each cap module
//     (ECAP_HEADER for DW0, then the per-DW reset values for DW1..N).
//     Vivado burns them into the IP; the IP responds automatically to host reads.
//     This is the production path.
//
//   WAY 2 — soft endpoint override:
//     Replace the IP's config-space TLP handling with a custom TLP parser that
//     exposes config reads/writes to user logic (cfg_rd_en / cfg_wr_en /
//     cfg_dwaddr).  Instantiate this router in that path.  The DW address bus
//     for the full config space is 10 bits [9:0] (covering 0x000–0xFFC).
//     Gate this module on dw_addr >= 10'h040.
//
// MODULE PARAMETER AGREEMENT:
//   MAC_ADDR must match what you configured in rtl8125b_bar0_regs so the DSN
//   stays consistent with the MAC the driver reads from BAR0.

module pcie_ecap_router #(
    parameter logic [47:0] MAC_ADDR = 48'h00_E0_4C_12_34_56
) (
    input  logic        clk,
    input  logic        rst_n,

    // 10-bit DW address covering full 4 KiB config space.
    // This module only decodes [9:0] >= 10'h040; caller must gate accordingly.
    input  logic        cfg_rd_en,
    input  logic        cfg_wr_en,
    input  logic [9:0]  cfg_dwaddr,
    input  logic [3:0]  cfg_be,
    input  logic [31:0] cfg_wdata,
    output logic [31:0] cfg_rdata
);

    // ---- Address decode --------------------------------------------------
    // AER:  DW 0x040..0x04A  (11 DWs)
    // DSN:  DW 0x054..0x056  ( 3 DWs)
    // LTR:  DW 0x058..0x059  ( 2 DWs)

    logic aer_sel, dsn_sel, ltr_sel;
    assign aer_sel = (cfg_dwaddr >= 10'h040) && (cfg_dwaddr <= 10'h04A);
    assign dsn_sel = (cfg_dwaddr >= 10'h054) && (cfg_dwaddr <= 10'h056);
    assign ltr_sel = (cfg_dwaddr >= 10'h058) && (cfg_dwaddr <= 10'h059);

    logic [3:0]  aer_dw_idx;
    logic [1:0]  dsn_dw_idx;
    logic        ltr_dw_idx;
    assign aer_dw_idx = cfg_dwaddr[3:0] - 4'h0;  // 0x040 → idx 0
    assign dsn_dw_idx = cfg_dwaddr[1:0];           // 0x054 → idx 0
    assign ltr_dw_idx = cfg_dwaddr[0];             // 0x058 → idx 0

    // ---- Instantiate caps ------------------------------------------------
    logic [31:0] aer_rdata, dsn_rdata, ltr_rdata;

    pcie_ecap_aer #(
        .NEXT_CAP_OFFSET(12'h150)
    ) u_aer (
        .clk         (clk),
        .rst_n       (rst_n),
        .cap_rd_en   (cfg_rd_en & aer_sel),
        .cap_wr_en   (cfg_wr_en & aer_sel),
        .cap_dw_idx  (aer_dw_idx),
        .cap_be      (cfg_be),
        .cap_wdata   (cfg_wdata),
        .cap_rdata   (aer_rdata)
    );

    pcie_ecap_dsn #(
        .NEXT_CAP_OFFSET(12'h160),
        .MAC_ADDR       (MAC_ADDR)
    ) u_dsn (
        .cap_rd_en   (cfg_rd_en & dsn_sel),
        .cap_dw_idx  (dsn_dw_idx),
        .cap_rdata   (dsn_rdata)
    );

    pcie_ecap_ltr #(
        .NEXT_CAP_OFFSET(12'h000)
    ) u_ltr (
        .clk         (clk),
        .rst_n       (rst_n),
        .cap_rd_en   (cfg_rd_en & ltr_sel),
        .cap_wr_en   (cfg_wr_en & ltr_sel),
        .cap_dw_idx  (ltr_dw_idx),
        .cap_be      (cfg_be),
        .cap_wdata   (cfg_wdata),
        .cap_rdata   (ltr_rdata)
    );

    // ---- Output mux ------------------------------------------------------
    always_comb begin
        if      (aer_sel) cfg_rdata = aer_rdata;
        else if (dsn_sel) cfg_rdata = dsn_rdata;
        else if (ltr_sel) cfg_rdata = ltr_rdata;
        else              cfg_rdata = 32'h0;    // unimplemented ECAP address
    end

endmodule
