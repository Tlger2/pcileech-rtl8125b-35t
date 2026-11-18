// Virtual Channel Extended Capability (ECAP ID 0x0002, ver 1).
// Donor places VC at 0x148 (8 DWs) with next → DSN at 0x168.

module pcie_ecap_vc #(
    parameter logic [11:0] NEXT_CAP_OFFSET = 12'h168
) (
    input  logic        cap_rd_en,
    input  logic [2:0]  cap_dw_idx,
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h0002};
    // Port VC Cap: 1 VC (VC0), no extended VC
    localparam logic [31:0] PORT_VC_CAP = 32'h0000_0001;
    localparam logic [31:0] PORT_VC_CTRL = 32'h0000_0000;
    localparam logic [31:0] VC0_RES_CAP  = 32'h0000_0001;
    localparam logic [31:0] VC0_RES_CTRL = 32'h8000_00FF;
    localparam logic [31:0] VC0_RES_STS  = 32'h0002_0000;

    always_comb begin
        unique case (cap_dw_idx)
            3'd0: cap_rdata = ECAP_HEADER;
            3'd1: cap_rdata = PORT_VC_CAP;
            3'd2: cap_rdata = PORT_VC_CTRL;
            3'd3: cap_rdata = 32'h0;
            3'd4: cap_rdata = VC0_RES_CAP;
            3'd5: cap_rdata = VC0_RES_CTRL;
            3'd6: cap_rdata = VC0_RES_STS;
            3'd7: cap_rdata = 32'h0;
            default: cap_rdata = 32'h0;
        endcase
    end
endmodule
