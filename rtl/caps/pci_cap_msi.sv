// MSI Capability (full) — 64-bit addr, 1 vector, per-vector masking.
// 6 DWs when 64-bit + maskable:
//   DW0: Msg Ctrl | Next Ptr | Cap ID (0x05)
//   DW1: Message Address low
//   DW2: Message Address high
//   DW3: Reserved | Message Data
//   DW4: Mask Bits
//   DW5: Pending Bits

module pci_cap_msi #(
    parameter logic [7:0] NEXT_PTR          = 8'h70,
    parameter logic [2:0] MULTI_MSG_CAPABLE = 3'd0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [2:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata,

    output logic        msi_enable,
    output logic [2:0]  multi_msg_enable,
    output logic [63:0] msi_address,
    output logic [15:0] msi_data,
    output logic        msi_mask_bit0
);
    localparam logic [7:0] CAP_ID = 8'h05;

    logic        msi_en_q;
    logic [2:0]  mme_q;
    logic [31:0] addr_lo_q, addr_hi_q;
    logic [15:0] data_q;
    logic [31:0] mask_q, pending_q;

    assign msi_enable       = msi_en_q;
    assign multi_msg_enable = mme_q;
    assign msi_address      = {addr_hi_q, addr_lo_q};
    assign msi_data         = data_q;
    assign msi_mask_bit0    = mask_q[0];

    // [8]=maskable, [7]=64-bit, [6:4]=MME, [3:1]=MMC, [0]=enable
    logic [15:0] msg_ctrl;
    assign msg_ctrl = {7'h00, 1'b1, 1'b1, mme_q, MULTI_MSG_CAPABLE, msi_en_q};

    always_comb begin
        unique case (cap_dw_idx)
            3'd0: cap_rdata = {msg_ctrl, NEXT_PTR, CAP_ID};
            3'd1: cap_rdata = addr_lo_q;
            3'd2: cap_rdata = addr_hi_q;
            3'd3: cap_rdata = {16'h0, data_q};
            3'd4: cap_rdata = mask_q;
            3'd5: cap_rdata = pending_q;
            default: cap_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msi_en_q  <= 1'b0;
            mme_q     <= 3'd0;
            addr_lo_q <= 32'h0;
            addr_hi_q <= 32'h0;
            data_q    <= 16'h0;
            mask_q    <= 32'h0;
            pending_q <= 32'h0;
        end else if (cap_wr_en) begin
            unique case (cap_dw_idx)
                3'd0: if (cap_be[2]) begin
                    msi_en_q <= cap_wdata[16];
                    mme_q    <= cap_wdata[22:20];
                end
                3'd1: begin
                    if (cap_be[0]) addr_lo_q[7:0]   <= {cap_wdata[7:2], 2'b00};
                    if (cap_be[1]) addr_lo_q[15:8]  <= cap_wdata[15:8];
                    if (cap_be[2]) addr_lo_q[23:16] <= cap_wdata[23:16];
                    if (cap_be[3]) addr_lo_q[31:24] <= cap_wdata[31:24];
                end
                3'd2: begin
                    if (cap_be[0]) addr_hi_q[7:0]   <= cap_wdata[7:0];
                    if (cap_be[1]) addr_hi_q[15:8]  <= cap_wdata[15:8];
                    if (cap_be[2]) addr_hi_q[23:16] <= cap_wdata[23:16];
                    if (cap_be[3]) addr_hi_q[31:24] <= cap_wdata[31:24];
                end
                3'd3: begin
                    if (cap_be[0]) data_q[7:0]  <= cap_wdata[7:0];
                    if (cap_be[1]) data_q[15:8] <= cap_wdata[15:8];
                end
                3'd4: begin
                    if (cap_be[0]) mask_q[7:0]   <= cap_wdata[7:0];
                    if (cap_be[1]) mask_q[15:8]  <= cap_wdata[15:8];
                    if (cap_be[2]) mask_q[23:16] <= cap_wdata[23:16];
                    if (cap_be[3]) mask_q[31:24] <= cap_wdata[31:24];
                end
                default: ;
            endcase
        end
    end
endmodule
