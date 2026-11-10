// MSI Capability — enumeration stub (read-only).
// 64-bit addr, per-vector masking, 1 vector advertised. 6 DWs.

module pci_cap_msi_stub #(
    parameter logic [7:0] NEXT_PTR          = 8'h70,
    parameter logic [2:0] MULTI_MSG_CAPABLE = 3'd0
) (
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [2:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    localparam logic [7:0] CAP_ID = 8'h05;

    // [8]=maskable, [7]=64-bit, MMC=0 (1 vector), enable=0
    logic [15:0] msg_ctrl;
    assign msg_ctrl = {7'h0, 1'b1, 1'b1, 3'b000, MULTI_MSG_CAPABLE, 1'b0};

    always_comb begin
        unique case (cap_dw_idx)
            3'd0: cap_rdata = {msg_ctrl, NEXT_PTR, CAP_ID};
            3'd1: cap_rdata = 32'h0;
            3'd2: cap_rdata = 32'h0;
            3'd3: cap_rdata = 32'h0;
            3'd4: cap_rdata = 32'h0;
            3'd5: cap_rdata = 32'h0;
            default: cap_rdata = 32'h0;
        endcase
    end
endmodule
