// Decode TLP header DW1: Requester ID / Tag / Byte Enables.
//
// Bit layout (memory request DW1):
//   [31:16] Requester ID
//   [15:8]  Tag (legacy 8-bit)
//   [7:4]   Last DW Byte Enables
//   [3:0]   First DW Byte Enables ("lower" BEs)

typedef struct packed {
    logic [15:0] requester_id;
    logic [7:0]  tag;
    logic [3:0]  last_be;
    logic [3:0]  first_be;
} tlp_rid_tag_be_t;

function automatic tlp_rid_tag_be_t decode_tlp_rid_tag_be(input logic [31:0] dw1);
    decode_tlp_rid_tag_be.requester_id = dw1[31:16];
    decode_tlp_rid_tag_be.tag          = dw1[15:8];
    decode_tlp_rid_tag_be.last_be      = dw1[7:4];
    decode_tlp_rid_tag_be.first_be     = dw1[3:0];
endfunction

module tlp_rid_tag_be_decoder (
    input  logic [31:0] tlp_dw1,
    output logic [15:0] requester_id,
    output logic [7:0]  tag,
    output logic [3:0]  first_be,
    output logic [3:0]  last_be
);
    assign requester_id = tlp_dw1[31:16];
    assign tag          = tlp_dw1[15:8];
    assign last_be      = tlp_dw1[7:4];
    assign first_be     = tlp_dw1[3:0];
endmodule
