// Format the three header DWs of a Completion with Data (CplD) TLP.
//
// DW0: R | Fmt=10 | Type=01010 | R | TC | R | Attr[2] | R | R | TD | EP |
//      Attr[1:0] | AT | Length
// DW1: Completer ID [31:16] | Status [15:13] | BCM [12] | Byte Count [11:0]
// DW2: Requester ID [31:16] | Tag [15:8] | R [7] | Lower Address [6:0]

module tlp_cpld_header_fmt (
    input  logic [15:0] completer_id,
    input  logic [15:0] requester_id,
    input  logic [7:0]  tag,
    input  logic [11:0] byte_count,
    input  logic [6:0]  lower_address,
    input  logic [9:0]  length_dw,
    input  logic [2:0]  tc,
    input  logic        td,
    input  logic        ep,
    input  logic [2:0]  attr,
    output logic [31:0] hdr_dw0,
    output logic [31:0] hdr_dw1,
    output logic [31:0] hdr_dw2
);
    localparam logic [1:0] FMT_CPLD  = 2'b10;
    localparam logic [4:0] TYPE_CPL  = 5'b01010;
    localparam logic [2:0] STATUS_SC = 3'b000;
    localparam logic       BCM       = 1'b0;

    assign hdr_dw0 = {
        1'b0,
        FMT_CPLD,
        TYPE_CPL,
        1'b0,
        tc,
        1'b0,
        attr[2],
        2'b00,
        td,
        ep,
        attr[1:0],
        2'b00,
        length_dw
    };

    assign hdr_dw1 = {
        completer_id,
        STATUS_SC,
        BCM,
        byte_count
    };

    assign hdr_dw2 = {
        requester_id,
        tag,
        1'b0,
        lower_address
    };
endmodule
