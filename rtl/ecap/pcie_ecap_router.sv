// Extended Configuration Space (ECAP) router.
//
// Donor RTL8125B chain:
//   0x100 AER  → 0x148 VC → 0x168 DSN → 0x178 TPH
//        → 0x204 LTR → 0x20C L1PM → 0x21C VSEC → 0x000
//
// Live silicon: pcie_top_wrapper wires this to pcie_7x cfg_ext so TPH/LTR/
// L1PM/VSEC (and DSN if the core did not keep it) answer at these offsets.
// Type-0 / PM / MSI / PCIe / MSI-X still belong to the integrated block.

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
    localparam logic [9:0] AER_DW  = ECAP_AER_BASE  >> 2;  // 0x040
    localparam logic [9:0] VC_DW   = ECAP_VC_BASE   >> 2;  // 0x052
    localparam logic [9:0] DSN_DW  = ECAP_DSN_BASE  >> 2;  // 0x05A
    localparam logic [9:0] TPH_DW  = ECAP_TPH_BASE  >> 2;  // 0x05E
    localparam logic [9:0] LTR_DW  = ECAP_LTR_BASE  >> 2;  // 0x081
    localparam logic [9:0] L1PM_DW = ECAP_L1PM_BASE >> 2;  // 0x083
    localparam logic [9:0] VSEC_DW = ECAP_VSEC_BASE >> 2;  // 0x087

    logic aer_sel, vc_sel, dsn_sel, tph_sel, ltr_sel, l1pm_sel, vsec_sel;
    assign aer_sel  = (cfg_dwaddr >= AER_DW)  && (cfg_dwaddr <= AER_DW  + 10'd10);
    assign vc_sel   = (cfg_dwaddr >= VC_DW)   && (cfg_dwaddr <= VC_DW   + 10'd7);
    assign dsn_sel  = (cfg_dwaddr >= DSN_DW)  && (cfg_dwaddr <= DSN_DW  + 10'd2);
    assign tph_sel  = (cfg_dwaddr >= TPH_DW)  && (cfg_dwaddr <= TPH_DW  + 10'd2);
    assign ltr_sel  = (cfg_dwaddr >= LTR_DW)  && (cfg_dwaddr <= LTR_DW  + 10'd1);
    assign l1pm_sel = (cfg_dwaddr >= L1PM_DW) && (cfg_dwaddr <= L1PM_DW + 10'd3);
    assign vsec_sel = (cfg_dwaddr >= VSEC_DW) && (cfg_dwaddr <= VSEC_DW + 10'd2);

    logic [3:0] aer_dw_idx;
    logic [2:0] vc_dw_idx;
    logic [1:0] dsn_dw_idx, tph_dw_idx, l1pm_dw_idx, vsec_dw_idx;
    logic       ltr_dw_idx;
    assign aer_dw_idx  = cfg_dwaddr - AER_DW;
    assign vc_dw_idx   = cfg_dwaddr - VC_DW;
    assign dsn_dw_idx  = cfg_dwaddr - DSN_DW;
    assign tph_dw_idx  = cfg_dwaddr - TPH_DW;
    assign ltr_dw_idx  = (cfg_dwaddr != LTR_DW);     // 0 at LTR base, 1 at base+1
    assign l1pm_dw_idx = cfg_dwaddr - L1PM_DW;
    assign vsec_dw_idx = cfg_dwaddr - VSEC_DW;

    logic [31:0] aer_rdata, vc_rdata, dsn_rdata, tph_rdata;
    logic [31:0] ltr_rdata, l1pm_rdata, vsec_rdata;

    pcie_ecap_aer #(.NEXT_CAP_OFFSET(ECAP_VC_BASE)) u_aer (
        .clk        (clk),
        .rst_n      (rst_n),
        .cap_rd_en  (cfg_rd_en & aer_sel),
        .cap_wr_en  (cfg_wr_en & aer_sel),
        .cap_dw_idx (aer_dw_idx),
        .cap_be     (cfg_be),
        .cap_wdata  (cfg_wdata),
        .cap_rdata  (aer_rdata)
    );

    pcie_ecap_vc #(.NEXT_CAP_OFFSET(ECAP_DSN_BASE)) u_vc (
        .cap_rd_en  (cfg_rd_en & vc_sel),
        .cap_dw_idx (vc_dw_idx),
        .cap_rdata  (vc_rdata)
    );

    pcie_ecap_dsn #(.NEXT_CAP_OFFSET(ECAP_TPH_BASE), .MAC_ADDR(MAC_ADDR)) u_dsn (
        .cap_rd_en  (cfg_rd_en & dsn_sel),
        .cap_dw_idx (dsn_dw_idx),
        .cap_rdata  (dsn_rdata)
    );

    pcie_ecap_tph #(.NEXT_CAP_OFFSET(ECAP_LTR_BASE)) u_tph (
        .cap_rd_en  (cfg_rd_en & tph_sel),
        .cap_dw_idx (tph_dw_idx),
        .cap_rdata  (tph_rdata)
    );

    pcie_ecap_ltr #(.NEXT_CAP_OFFSET(ECAP_L1PM_BASE)) u_ltr (
        .clk        (clk),
        .rst_n      (rst_n),
        .cap_rd_en  (cfg_rd_en & ltr_sel),
        .cap_wr_en  (cfg_wr_en & ltr_sel),
        .cap_dw_idx (ltr_dw_idx),
        .cap_be     (cfg_be),
        .cap_wdata  (cfg_wdata),
        .cap_rdata  (ltr_rdata)
    );

    pcie_ecap_l1pm #(.NEXT_CAP_OFFSET(ECAP_VSEC_BASE)) u_l1pm (
        .clk        (clk),
        .rst_n      (rst_n),
        .cap_rd_en  (cfg_rd_en & l1pm_sel),
        .cap_wr_en  (cfg_wr_en & l1pm_sel),
        .cap_dw_idx (l1pm_dw_idx),
        .cap_be     (cfg_be),
        .cap_wdata  (cfg_wdata),
        .cap_rdata  (l1pm_rdata)
    );

    pcie_ecap_vsec #(.NEXT_CAP_OFFSET(12'h000)) u_vsec (
        .cap_rd_en  (cfg_rd_en & vsec_sel),
        .cap_dw_idx (vsec_dw_idx),
        .cap_rdata  (vsec_rdata)
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
