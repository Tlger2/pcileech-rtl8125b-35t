// Decode TLP header DW0 (Fmt/Type/TC/Length).
//
// Bit layout (PCIe Base Spec):
//   [31]    R
//   [30:29] Fmt
//   [28:24] Type
//   [23]    T9/R
//   [22:20] TC
//   [19]    T8/R
//   [18]    Attr[2]
//   [17:16] R
//   [15]    TD
//   [14]    EP
//   [13:12] Attr[1:0]
//   [11:10] AT
//   [9:0]   Length (DWs); 0 == 1024

typedef struct packed {
    logic [1:0] fmt;
    logic [4:0] ttype;
    logic [2:0] tc;
    logic [9:0] length;
} tlp_dw0_t;

function automatic tlp_dw0_t decode_tlp_dw0(input logic [31:0] dw0);
    decode_tlp_dw0.fmt    = dw0[30:29];
    decode_tlp_dw0.ttype  = dw0[28:24];
    decode_tlp_dw0.tc     = dw0[22:20];
    decode_tlp_dw0.length = dw0[9:0];
endfunction

module tlp_dw0_decoder (
    input  logic [31:0] tlp_dw0,
    output logic [1:0]  fmt,
    output logic [4:0]  ttype,
    output logic [2:0]  tc,
    output logic [9:0]  length_dw,
    output logic [10:0] length_dw_eff,
    output logic        is_4dw_header,
    output logic        has_data,
    output logic        is_mem_req
);
    assign fmt           = tlp_dw0[30:29];
    assign ttype         = tlp_dw0[28:24];
    assign tc            = tlp_dw0[22:20];
    assign length_dw     = tlp_dw0[9:0];
    assign length_dw_eff = (length_dw == 10'd0) ? 11'd1024 : {1'b0, length_dw};
    assign is_4dw_header = fmt[0];
    assign has_data      = fmt[1];
    assign is_mem_req    = (ttype == 5'b00000);
endmodule
