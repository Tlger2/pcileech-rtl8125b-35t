// TPH Requester Extended Capability (ECAP ID 0x0017, ver 1).
// Donor places TPH at 0x178, next → LTR at 0x204.

module pcie_ecap_tph #(
    parameter logic [11:0] NEXT_CAP_OFFSET = 12'h204
) (
    input  logic        cap_rd_en,
    input  logic [1:0]  cap_dw_idx,
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h0017};
    // No ST table, No Interrupt Vector Mode, No Device Specific Mode
    localparam logic [31:0] TPH_REQ_CAP = 32'h0000_0001;
    localparam logic [31:0] TPH_REQ_CTL = 32'h0000_0000;

    always_comb begin
        unique case (cap_dw_idx)
            2'd0: cap_rdata = ECAP_HEADER;
            2'd1: cap_rdata = TPH_REQ_CAP;
            2'd2: cap_rdata = TPH_REQ_CTL;
            default: cap_rdata = 32'h0;
        endcase
    end
endmodule
