// MSI Capability (full) — 64-bit addr, no per-vector masking.
//   DW0: Msg Ctrl | Next Ptr | Cap ID (0x05)
//   DW1: Message Address low
//   DW2: Message Address high
//   DW3: Reserved | Message Data

module pci_cap_msi #(
    parameter logic [7:0] NEXT_PTR          = 8'h70,
    parameter logic [2:0] MULTI_MSG_CAPABLE = 3'd3
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [1:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata,

    output logic        msi_enable,
    output logic [2:0]  multi_msg_enable,
    output logic [63:0] msi_address,
    output logic [15:0] msi_data
);
    localparam logic [7:0] CAP_ID = 8'h05;

    logic        msi_en_q;
    logic [2:0]  mme_q;
    logic [31:0] addr_lo_q, addr_hi_q;
    logic [15:0] data_q;

    assign msi_enable       = msi_en_q;
    assign multi_msg_enable = mme_q;
    assign msi_address      = {addr_hi_q, addr_lo_q};
    assign msi_data         = data_q;

    logic [15:0] msg_ctrl;
    assign msg_ctrl = {7'h00, 1'b0, 1'b1, mme_q, MULTI_MSG_CAPABLE, msi_en_q};

    logic [31:0] dw0, dw1, dw2, dw3;
    assign dw0 = {msg_ctrl, NEXT_PTR, CAP_ID};
    assign dw1 = addr_lo_q;
    assign dw2 = addr_hi_q;
    assign dw3 = {16'h0, data_q};

    always_comb begin
        unique case (cap_dw_idx)
            2'd0: cap_rdata = dw0;
            2'd1: cap_rdata = dw1;
            2'd2: cap_rdata = dw2;
            2'd3: cap_rdata = dw3;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msi_en_q  <= 1'b0;
            mme_q     <= 3'd0;
            addr_lo_q <= 32'h0;
            addr_hi_q <= 32'h0;
            data_q    <= 16'h0;
        end else if (cap_wr_en) begin
            unique case (cap_dw_idx)
                2'd0: if (cap_be[2]) begin
                    msi_en_q <= cap_wdata[16];
                    mme_q    <= cap_wdata[22:20];
                end
                2'd1: begin
                    if (cap_be[0]) addr_lo_q[7:0]   <= {cap_wdata[7:2], 2'b00};
                    if (cap_be[1]) addr_lo_q[15:8]  <= cap_wdata[15:8];
                    if (cap_be[2]) addr_lo_q[23:16] <= cap_wdata[23:16];
                    if (cap_be[3]) addr_lo_q[31:24] <= cap_wdata[31:24];
                end
                2'd2: begin
                    if (cap_be[0]) addr_hi_q[7:0]   <= cap_wdata[7:0];
                    if (cap_be[1]) addr_hi_q[15:8]  <= cap_wdata[15:8];
                    if (cap_be[2]) addr_hi_q[23:16] <= cap_wdata[23:16];
                    if (cap_be[3]) addr_hi_q[31:24] <= cap_wdata[31:24];
                end
                2'd3: begin
                    if (cap_be[0]) data_q[7:0]  <= cap_wdata[7:0];
                    if (cap_be[1]) data_q[15:8] <= cap_wdata[15:8];
                end
            endcase
        end
    end
endmodule
