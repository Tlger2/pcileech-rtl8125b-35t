// MSI-X Capability (3 DWs, cap ID 0x11). Standalone — not yet wired
// into the chain so the existing cap walk (PM -> MSI -> PCIe) stays
// intact. To activate, insert between MSI and PCIe and change MSI's
// NEXT_PTR to 0x60.

module pci_cap_msix #(
    parameter logic [7:0]  NEXT_PTR          = 8'h70,
    parameter int          NUM_VECTORS       = 8,
    parameter logic [2:0]  TABLE_BIR         = 3'd0,
    parameter logic [28:0] TABLE_QW_OFFSET   = 29'h0000_0000,
    parameter logic [2:0]  PBA_BIR           = 3'd0,
    parameter logic [28:0] PBA_QW_OFFSET     = 29'h0000_0200
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [1:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata,

    output logic        msix_enable,
    output logic        function_mask
);
    localparam logic [7:0]  CAP_ID         = 8'h11;
    localparam logic [10:0] TABLE_SIZE_M1  = NUM_VECTORS - 1;

    logic msix_en_q, func_mask_q;
    assign msix_enable   = msix_en_q;
    assign function_mask = func_mask_q;

    logic [15:0] msg_ctrl;
    assign msg_ctrl = {msix_en_q, func_mask_q, 3'b000, TABLE_SIZE_M1};

    logic [31:0] dw0, dw1, dw2;
    assign dw0 = {msg_ctrl, NEXT_PTR, CAP_ID};
    assign dw1 = {TABLE_QW_OFFSET, TABLE_BIR};
    assign dw2 = {PBA_QW_OFFSET,   PBA_BIR};

    always_comb begin
        unique case (cap_dw_idx)
            2'd0: cap_rdata = dw0;
            2'd1: cap_rdata = dw1;
            2'd2: cap_rdata = dw2;
            default: cap_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msix_en_q   <= 1'b0;
            func_mask_q <= 1'b0;
        end else if (cap_wr_en && cap_dw_idx == 2'd0 && cap_be[3]) begin
            msix_en_q   <= cap_wdata[31];
            func_mask_q <= cap_wdata[30];
        end
    end
endmodule
