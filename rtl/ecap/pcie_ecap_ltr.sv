// PCI Express Extended Capability — Latency Tolerance Reporting (LTR).
// ECAP ID 0x0018, version 1.  2 DWs at donor offset 0x204.
// Donor default is 0 ns (scale=0, value=0) in both snoop and no-snoop.

module pcie_ecap_ltr
    import rtl8125b_identity_pkg::*;
#(
    parameter logic [11:0] NEXT_CAP_OFFSET = ECAP_L1PM_BASE,
    parameter logic [15:0] SNOOP_LAT_RST   = 16'h0000,
    parameter logic [15:0] NOSNOOP_LAT_RST = 16'h0000
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [0:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h0018};

    logic [15:0] snoop_lat_q;
    logic [15:0] nosnoop_lat_q;

    always_comb begin
        case (cap_dw_idx)
            1'b0: cap_rdata = ECAP_HEADER;
            1'b1: cap_rdata = {nosnoop_lat_q, snoop_lat_q};
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snoop_lat_q   <= SNOOP_LAT_RST;
            nosnoop_lat_q <= NOSNOOP_LAT_RST;
        end else if (cap_wr_en && cap_dw_idx == 1'b1) begin
            if (cap_be[0]) snoop_lat_q[7:0]    <= cap_wdata[7:0];
            if (cap_be[1]) snoop_lat_q[15:8]   <= cap_wdata[15:8];
            if (cap_be[2]) nosnoop_lat_q[7:0]  <= cap_wdata[23:16];
            if (cap_be[3]) nosnoop_lat_q[15:8] <= cap_wdata[31:24];
        end
    end
endmodule
