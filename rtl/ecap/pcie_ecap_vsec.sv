// Vendor-Specific Extended Capability (ECAP ID 0x000B, ver 1).
// Donor places VSEC at 0x21C, end of chain.

module pcie_ecap_vsec
    import rtl8125b_identity_pkg::*;
#(
    parameter logic [11:0] NEXT_CAP_OFFSET = 12'h000
) (
    input  logic        cap_rd_en,
    input  logic [1:0]  cap_dw_idx,
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h000B};
    // VSEC Header: VID 10EC, rev 1, length 2 DWs of vendor body
    localparam logic [31:0] VSEC_HDR    = {8'h02, 4'h1, VENDOR_ID};
    localparam logic [31:0] VSEC_DW     = 32'h0000_0000;

    always_comb begin
        unique case (cap_dw_idx)
            2'd0: cap_rdata = ECAP_HEADER;
            2'd1: cap_rdata = VSEC_HDR;
            2'd2: cap_rdata = VSEC_DW;
            default: cap_rdata = 32'h0;
        endcase
    end
endmodule
