// PCI Power Management Capability (full, with host-writable PMCSR).
//   DW0: PMC | Next Ptr | Cap ID (0x01)
//   DW1: Data | BSE | PMCSR
//
// PMC matches the donor / vivado_build.tcl: PM 1.2, D1+D2, PME in D0–D3cold,
// Aux 375 mA. PMCSR[3] No_Soft_Reset is sticky-1.

module pci_cap_pm #(
    parameter logic [7:0] NEXT_PTR = 8'h50
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic        cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata,
    output logic [1:0]  current_power_state
);
    localparam logic [7:0]  CAP_ID = 8'h01;
    // [2:0] Version=3, [8:6] Aux=111 (375 mA), [9] D1, [10] D2,
    // [15:11] PME D0/D1/D2/D3hot/D3cold.
    localparam logic [15:0] PMC    = 16'hFEC3;

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
            1'b0:    cap_rdata = dw0;
            1'b1:    cap_rdata = dw1;
            default: cap_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pme_en_q      <= 1'b0;
            pme_status_q  <= 1'b0;
            power_state_q <= 2'b00;
        end else if (cap_wr_en && cap_dw_idx == 1'b1) begin
            if (cap_be[0]) begin
                power_state_q <= cap_wdata[1:0];
                pme_en_q      <= cap_wdata[8];
            end
            if (cap_be[1] && cap_wdata[15]) pme_status_q <= 1'b0;
        end
    end
endmodule
