// lang: SystemVerilog, file: pcie_ecap_router.sv, target: Xilinx Artix-7 XC7A35T, Vivado 2026.1
// Extended Configuration Space (ECAP) router.
//
// Donor RTL8125B rev 04 / 1043:87D7 chain (byte offsets):
//   0x100 AER  (ID 0x0001 ver 2, 11 DWs) → 0x148
//   0x148 VC   (ID 0x0002 ver 1,  8 DWs) → 0x168
//   0x168 DSN  (ID 0x0003 ver 1,  3 DWs) → 0x178
//   0x178 TPH  (ID 0x0017 ver 1,  3 DWs) → 0x204
//   0x204 LTR  (ID 0x0018 ver 1,  2 DWs) → 0x20C
//   0x20C L1PM (ID 0x001E ver 1,  4 DWs) → 0x21C
//   0x21C VSEC (ID 0x000B ver 1,  3 DWs) → 0x000 (end)
//
// INTEGRATION — Xilinx 7-Series pcie_7x_0:
//   The 7-series block intercepts type-0 config TLPs. Vivado 2026.1 pcie_7x 3.3
//   has no cfg_ext_* ports even with EXT_PCI_CFG_Space, so silicon ECAPs must
//   be baked into the IP via vivado_build.tcl (AER/DSN/VC/TPH/LTR/L1PM/VSEC
//   pointers). This router is the soft/TB source of truth for the same DW
//   contents. pcie_top_wrapper keeps it instantiated and idle.

module pcie_ecap_router
    import rtl8125b_identity_pkg::*;
#(
    parameter logic [47:0] MAC_ADDR = rtl8125b_identity_pkg::MAC_ADDR
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        cfg_rd_en,
    input  logic        cfg_wr_en,
    input  logic [9:0]  cfg_dwaddr,
    input  logic [3:0]  cfg_be,
    input  logic [31:0] cfg_wdata,
    output logic [31:0] cfg_rdata
);
    localparam logic [9:0] DW_AER  = ECAP_AER_BASE[11:2];
    localparam logic [9:0] DW_VC   = ECAP_VC_BASE[11:2];
    localparam logic [9:0] DW_DSN  = ECAP_DSN_BASE[11:2];
    localparam logic [9:0] DW_TPH  = ECAP_TPH_BASE[11:2];
    localparam logic [9:0] DW_LTR  = ECAP_LTR_BASE[11:2];
    localparam logic [9:0] DW_L1PM = ECAP_L1PM_BASE[11:2];
    localparam logic [9:0] DW_VSEC = ECAP_VSEC_BASE[11:2];

    logic aer_sel, vc_sel, dsn_sel, tph_sel, ltr_sel, l1pm_sel, vsec_sel;
    assign aer_sel  = (cfg_dwaddr >= DW_AER)  && (cfg_dwaddr < DW_AER  + 10'd11);
    assign vc_sel   = (cfg_dwaddr >= DW_VC)   && (cfg_dwaddr < DW_VC   + 10'd8);
    assign dsn_sel  = (cfg_dwaddr >= DW_DSN)  && (cfg_dwaddr < DW_DSN  + 10'd3);
    assign tph_sel  = (cfg_dwaddr >= DW_TPH)  && (cfg_dwaddr < DW_TPH  + 10'd3);
    assign ltr_sel  = (cfg_dwaddr >= DW_LTR)  && (cfg_dwaddr < DW_LTR  + 10'd2);
    assign l1pm_sel = (cfg_dwaddr >= DW_L1PM) && (cfg_dwaddr < DW_L1PM + 10'd4);
    assign vsec_sel = (cfg_dwaddr >= DW_VSEC) && (cfg_dwaddr < DW_VSEC + 10'd3);

    logic [3:0] aer_dw_idx;
    logic [2:0] vc_dw_idx;
    logic [1:0] dsn_dw_idx, tph_dw_idx, l1pm_dw_idx, vsec_dw_idx;
    logic       ltr_dw_idx;
    assign aer_dw_idx  = 4'(cfg_dwaddr - DW_AER);
    assign vc_dw_idx   = 3'(cfg_dwaddr - DW_VC);
    assign dsn_dw_idx  = 2'(cfg_dwaddr - DW_DSN);
    assign tph_dw_idx  = 2'(cfg_dwaddr - DW_TPH);
    assign ltr_dw_idx  = 1'(cfg_dwaddr - DW_LTR);
    assign l1pm_dw_idx = 2'(cfg_dwaddr - DW_L1PM);
    assign vsec_dw_idx = 2'(cfg_dwaddr - DW_VSEC);

    logic [31:0] aer_rdata, vc_rdata, dsn_rdata, tph_rdata;
    logic [31:0] ltr_rdata, l1pm_rdata, vsec_rdata;

    pcie_ecap_aer #(
        .NEXT_CAP_OFFSET(ECAP_VC_BASE)
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

    pcie_ecap_vc #(
        .NEXT_CAP_OFFSET(ECAP_DSN_BASE)
    ) u_vc (
        .cap_rd_en   (cfg_rd_en & vc_sel),
        .cap_dw_idx  (vc_dw_idx),
        .cap_rdata   (vc_rdata)
    );

    pcie_ecap_dsn #(
        .NEXT_CAP_OFFSET(ECAP_TPH_BASE),
        .MAC_ADDR       (MAC_ADDR)
    ) u_dsn (
        .cap_rd_en   (cfg_rd_en & dsn_sel),
        .cap_dw_idx  (dsn_dw_idx),
        .cap_rdata   (dsn_rdata)
    );

    pcie_ecap_tph #(
        .NEXT_CAP_OFFSET(ECAP_LTR_BASE)
    ) u_tph (
        .cap_rd_en   (cfg_rd_en & tph_sel),
        .cap_dw_idx  (tph_dw_idx),
        .cap_rdata   (tph_rdata)
    );

    pcie_ecap_ltr #(
        .NEXT_CAP_OFFSET(ECAP_L1PM_BASE)
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

    pcie_ecap_l1pm #(
        .NEXT_CAP_OFFSET(ECAP_VSEC_BASE)
    ) u_l1pm (
        .clk         (clk),
        .rst_n       (rst_n),
        .cap_rd_en   (cfg_rd_en & l1pm_sel),
        .cap_wr_en   (cfg_wr_en & l1pm_sel),
        .cap_dw_idx  (l1pm_dw_idx),
        .cap_be      (cfg_be),
        .cap_wdata   (cfg_wdata),
        .cap_rdata   (l1pm_rdata)
    );

    pcie_ecap_vsec #(
        .NEXT_CAP_OFFSET(12'h000)
    ) u_vsec (
        .cap_rd_en   (cfg_rd_en & vsec_sel),
        .cap_dw_idx  (vsec_dw_idx),
        .cap_rdata   (vsec_rdata)
    );

    always_comb begin
        if      (aer_sel)  cfg_rdata = aer_rdata;
        else if (vc_sel)   cfg_rdata = vc_rdata;
        else if (dsn_sel)  cfg_rdata = dsn_rdata;
        else if (tph_sel)  cfg_rdata = tph_rdata;
        else if (ltr_sel)  cfg_rdata = ltr_rdata;
        else if (l1pm_sel) cfg_rdata = l1pm_rdata;
        else if (vsec_sel) cfg_rdata = vsec_rdata;
        else               cfg_rdata = 32'h0;
    end

endmodule
