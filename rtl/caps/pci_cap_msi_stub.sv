// MSI Capability — enumeration stub (read-only).
// 64-bit addr, no per-vector masking, 8 vectors advertised. 4 DWs.

module pci_cap_msi_stub #(
    parameter logic [7:0] NEXT_PTR          = 8'h70,
    parameter logic [2:0] MULTI_MSG_CAPABLE = 3'd3
) (
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [1:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    localparam logic [7:0] CAP_ID = 8'h05;

    logic [15:0] msg_ctrl;
    assign msg_ctrl = {7'h0, 1'b0, 1'b1, 3'b000, MULTI_MSG_CAPABLE, 1'b0};

    logic [31:0] dw0, dw1, dw2, dw3;
    assign dw0 = {msg_ctrl, NEXT_PTR, CAP_ID};
    assign dw1 = 32'h0;
    assign dw2 = 32'h0;
    assign dw3 = 32'h0;

    always_comb begin
        unique case (cap_dw_idx)
            2'd0: cap_rdata = dw0;
            2'd1: cap_rdata = dw1;
            2'd2: cap_rdata = dw2;
            2'd3: cap_rdata = dw3;
        endcase
    end
endmodule
