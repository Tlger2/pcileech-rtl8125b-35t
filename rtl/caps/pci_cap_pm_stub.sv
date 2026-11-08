// PCI Power Management Capability — enumeration stub (read-only).
// Satisfies capability-walking OS drivers during enumeration.

module pci_cap_pm_stub #(
    parameter logic [7:0] NEXT_PTR = 8'h50
) (
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [1:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata
);
    localparam logic [7:0]  CAP_ID = 8'h01;
    localparam logic [15:0] PMC    = 16'h0003;
    localparam logic [15:0] PMCSR  = 16'h0008;
    localparam logic [7:0]  BSE    = 8'h00;
    localparam logic [7:0]  DATA   = 8'h00;

    logic [31:0] dw0, dw1;
    assign dw0 = {PMC,  NEXT_PTR, CAP_ID};
    assign dw1 = {DATA, BSE,      PMCSR};

    always_comb begin
        unique case (cap_dw_idx)
            2'd0:    cap_rdata = dw0;
            2'd1:    cap_rdata = dw1;
            default: cap_rdata = 32'h0;
        endcase
    end
endmodule
