// Vital Product Data Capability (cap ID 0x03). 2 DWs, read-mostly.
// Donor places VPD at 0xD0 at the end of the standard cap chain.

module pci_cap_vpd #(
    parameter logic [7:0] NEXT_PTR = 8'h00
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic        cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    localparam logic [7:0] CAP_ID = 8'h03;

    logic [14:0] addr_q;
    logic        flag_q;
    logic [31:0] data_q;

    // DW0: {F, Address[14:0], Next, ID}; flag=1 means data ready on read
    always_comb begin
        if (!cap_dw_idx)
            cap_rdata = {flag_q, addr_q, NEXT_PTR, CAP_ID};
        else
            cap_rdata = data_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_q <= 15'h0;
            flag_q <= 1'b0;
            data_q <= 32'h0;
        end else if (cap_wr_en && !cap_dw_idx) begin
            if (cap_be[2]) addr_q[7:0]  <= cap_wdata[23:16];
            if (cap_be[3]) begin
                addr_q[14:8] <= cap_wdata[30:24];
                // Host sets F=1 to start a VPD read; complete immediately
                // with empty data so a probe does not stall.
                flag_q <= 1'b1;
                data_q <= 32'h0;
            end
        end
    end
endmodule
