// PCI Power Management Capability (full, with host-writable PMCSR).
//   DW0: PMC | Next Ptr | Cap ID (0x01)
//   DW1: Data | BSE | PMCSR

module pci_cap_pm #(
    parameter logic [7:0] NEXT_PTR = 8'h50
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [1:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata,
    output logic [1:0]  current_power_state
);
    localparam logic [7:0]  CAP_ID = 8'h01;
    localparam logic [15:0] PMC    = 16'h0003;

    logic       pme_en_q, pme_status_q;
    logic [1:0] power_state_q;

    assign current_power_state = power_state_q;

    logic [31:0] dw0, dw1;
    assign dw0 = {PMC, NEXT_PTR, CAP_ID};
    assign dw1 = {8'h00, 1'b0, 1'b0, 6'h00,
                  pme_status_q, 2'b00, 4'h0,
                  pme_en_q, 4'h0, 1'b1, 1'b0, power_state_q};

    always_comb begin
        unique case (cap_dw_idx)
            2'd0:    cap_rdata = dw0;
            2'd1:    cap_rdata = dw1;
            default: cap_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pme_en_q      <= 1'b0;
            pme_status_q  <= 1'b0;
            power_state_q <= 2'b00;
        end else if (cap_wr_en && cap_dw_idx == 2'd1) begin
            if (cap_be[0]) begin
                power_state_q <= cap_wdata[1:0];
                pme_en_q      <= cap_wdata[8];
            end
            if (cap_be[1] && cap_wdata[15]) pme_status_q <= 1'b0;
        end
    end
endmodule
