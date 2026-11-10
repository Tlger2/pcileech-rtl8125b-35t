// L1 PM Substates Extended Capability (ECAP ID 0x001E, ver 1).
// Donor places L1PM at 0x20C (4 DWs), next → VSEC at 0x21C.

module pcie_ecap_l1pm #(
    parameter logic [11:0] NEXT_CAP_OFFSET = 12'h21C
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [1:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h001E};
    // L1.1 + L1.2 supported on both ASPM and PCI-PM
    localparam logic [31:0] L1PM_CAP    = 32'h0000_001F;

    logic [31:0] ctrl1_q, ctrl2_q;

    always_comb begin
        unique case (cap_dw_idx)
            2'd0: cap_rdata = ECAP_HEADER;
            2'd1: cap_rdata = L1PM_CAP;
            2'd2: cap_rdata = ctrl1_q;
            2'd3: cap_rdata = ctrl2_q;
            default: cap_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl1_q <= 32'h0;
            ctrl2_q <= 32'h0000_0040;
        end else if (cap_wr_en) begin
            if (cap_dw_idx == 2'd2) begin
                if (cap_be[0]) ctrl1_q[7:0]   <= cap_wdata[7:0];
                if (cap_be[1]) ctrl1_q[15:8]  <= cap_wdata[15:8];
                if (cap_be[2]) ctrl1_q[23:16] <= cap_wdata[23:16];
                if (cap_be[3]) ctrl1_q[31:24] <= cap_wdata[31:24];
            end else if (cap_dw_idx == 2'd3) begin
                if (cap_be[0]) ctrl2_q[7:0]   <= cap_wdata[7:0];
                if (cap_be[1]) ctrl2_q[15:8]  <= cap_wdata[15:8];
                if (cap_be[2]) ctrl2_q[23:16] <= cap_wdata[23:16];
                if (cap_be[3]) ctrl2_q[31:24] <= cap_wdata[31:24];
            end
        end
    end
endmodule
