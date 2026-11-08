// Extract the memory address from TLP DW2 (+ DW3 for 4-DW headers).
//
// 3-DW header (Fmt[0]=0):
//   addr[31:2] = DW2[31:2], addr[1:0] implied 0 (DW2[1:0] = Processing Hints)
// 4-DW header (Fmt[0]=1):
//   addr[63:32] = DW2, addr[31:2] = DW3[31:2], addr[1:0] implied 0

module tlp_addr_decoder (
    input  logic [31:0] tlp_dw0,
    input  logic [31:0] tlp_dw2,
    input  logic [31:0] tlp_dw3,
    output logic [63:0] addr,
    output logic [1:0]  ph,
    output logic        is_64bit
);
    assign is_64bit = tlp_dw0[29];

    always_comb begin
        if (is_64bit) begin
            addr = {tlp_dw2, tlp_dw3[31:2], 2'b00};
            ph   = tlp_dw3[1:0];
        end else begin
            addr = {32'h0, tlp_dw2[31:2], 2'b00};
            ph   = tlp_dw2[1:0];
        end
    end
endmodule

function automatic logic [63:0] tlp_extract_addr(
    input logic [31:0] dw0,
    input logic [31:0] dw2,
    input logic [31:0] dw3
);
    if (dw0[29])
        tlp_extract_addr = {dw2, dw3[31:2], 2'b00};
    else
        tlp_extract_addr = {32'h0, dw2[31:2], 2'b00};
endfunction
