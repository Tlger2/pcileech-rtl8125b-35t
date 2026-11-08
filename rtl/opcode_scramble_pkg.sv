// Opcode substitution LUT for a host<->device protocol.
// Forward: canonical opcode (host-side) -> wire opcode (on-link).
// Reverse: wire opcode -> canonical opcode.
//
// The table is a fixed permutation of 16 defined opcodes; all other
// values map to OPC_INVALID in both directions. The two directions are
// strict inverses — opc_decode(opc_encode(X)) == X for every defined X.
//
// SECURITY NOTE: a static byte-level substitution is obfuscation, not
// encryption. Put real AEAD on top if you need confidentiality/integrity.

package opcode_scramble_pkg;

    // Canonical command codes (host-side, human-readable)
    localparam logic [7:0] OPC_NOP         = 8'h00;
    localparam logic [7:0] OPC_READ        = 8'h01;
    localparam logic [7:0] OPC_WRITE       = 8'h02;
    localparam logic [7:0] OPC_READ_BURST  = 8'h03;
    localparam logic [7:0] OPC_WRITE_BURST = 8'h04;
    localparam logic [7:0] OPC_INFO        = 8'h05;
    localparam logic [7:0] OPC_STATUS      = 8'h06;
    localparam logic [7:0] OPC_RESET       = 8'h07;
    localparam logic [7:0] OPC_FLUSH       = 8'h08;
    localparam logic [7:0] OPC_IRQ_ENABLE  = 8'h09;
    localparam logic [7:0] OPC_IRQ_CLEAR   = 8'h0A;
    localparam logic [7:0] OPC_HANDSHAKE   = 8'h0B;
    localparam logic [7:0] OPC_KEEPALIVE   = 8'h0C;
    localparam logic [7:0] OPC_VERSION     = 8'h0D;
    localparam logic [7:0] OPC_ABORT       = 8'h0E;
    localparam logic [7:0] OPC_SHUTDOWN    = 8'h0F;
    localparam logic [7:0] OPC_INVALID     = 8'hFF;

    // Wire-side (scrambled) opcodes
    localparam logic [7:0] WIRE_NOP         = 8'hA3;
    localparam logic [7:0] WIRE_READ        = 8'h5C;
    localparam logic [7:0] WIRE_WRITE       = 8'hE1;
    localparam logic [7:0] WIRE_READ_BURST  = 8'h7F;
    localparam logic [7:0] WIRE_WRITE_BURST = 8'h29;
    localparam logic [7:0] WIRE_INFO        = 8'hB6;
    localparam logic [7:0] WIRE_STATUS      = 8'hD4;
    localparam logic [7:0] WIRE_RESET       = 8'h18;
    localparam logic [7:0] WIRE_FLUSH       = 8'h92;
    localparam logic [7:0] WIRE_IRQ_ENABLE  = 8'h4B;
    localparam logic [7:0] WIRE_IRQ_CLEAR   = 8'hF0;
    localparam logic [7:0] WIRE_HANDSHAKE   = 8'h3D;
    localparam logic [7:0] WIRE_KEEPALIVE   = 8'h87;
    localparam logic [7:0] WIRE_VERSION     = 8'h6A;
    localparam logic [7:0] WIRE_ABORT       = 8'hC5;
    localparam logic [7:0] WIRE_SHUTDOWN    = 8'h2E;

    function automatic logic [7:0] opc_encode(input logic [7:0] canon);
        unique case (canon)
            OPC_NOP        : opc_encode = WIRE_NOP;
            OPC_READ       : opc_encode = WIRE_READ;
            OPC_WRITE      : opc_encode = WIRE_WRITE;
            OPC_READ_BURST : opc_encode = WIRE_READ_BURST;
            OPC_WRITE_BURST: opc_encode = WIRE_WRITE_BURST;
            OPC_INFO       : opc_encode = WIRE_INFO;
            OPC_STATUS     : opc_encode = WIRE_STATUS;
            OPC_RESET      : opc_encode = WIRE_RESET;
            OPC_FLUSH      : opc_encode = WIRE_FLUSH;
            OPC_IRQ_ENABLE : opc_encode = WIRE_IRQ_ENABLE;
            OPC_IRQ_CLEAR  : opc_encode = WIRE_IRQ_CLEAR;
            OPC_HANDSHAKE  : opc_encode = WIRE_HANDSHAKE;
            OPC_KEEPALIVE  : opc_encode = WIRE_KEEPALIVE;
            OPC_VERSION    : opc_encode = WIRE_VERSION;
            OPC_ABORT      : opc_encode = WIRE_ABORT;
            OPC_SHUTDOWN   : opc_encode = WIRE_SHUTDOWN;
            default        : opc_encode = OPC_INVALID;
        endcase
    endfunction

    function automatic logic [7:0] opc_decode(input logic [7:0] wire_op);
        unique case (wire_op)
            WIRE_NOP        : opc_decode = OPC_NOP;
            WIRE_READ       : opc_decode = OPC_READ;
            WIRE_WRITE      : opc_decode = OPC_WRITE;
            WIRE_READ_BURST : opc_decode = OPC_READ_BURST;
            WIRE_WRITE_BURST: opc_decode = OPC_WRITE_BURST;
            WIRE_INFO       : opc_decode = OPC_INFO;
            WIRE_STATUS     : opc_decode = OPC_STATUS;
            WIRE_RESET      : opc_decode = OPC_RESET;
            WIRE_FLUSH      : opc_decode = OPC_FLUSH;
            WIRE_IRQ_ENABLE : opc_decode = OPC_IRQ_ENABLE;
            WIRE_IRQ_CLEAR  : opc_decode = OPC_IRQ_CLEAR;
            WIRE_HANDSHAKE  : opc_decode = OPC_HANDSHAKE;
            WIRE_KEEPALIVE  : opc_decode = OPC_KEEPALIVE;
            WIRE_VERSION    : opc_decode = OPC_VERSION;
            WIRE_ABORT      : opc_decode = OPC_ABORT;
            WIRE_SHUTDOWN   : opc_decode = OPC_SHUTDOWN;
            default         : opc_decode = OPC_INVALID;
        endcase
    endfunction

    function automatic logic opc_is_valid_canon(input logic [7:0] canon);
        opc_is_valid_canon = (opc_encode(canon) != OPC_INVALID);
    endfunction

    function automatic logic opc_is_valid_wire(input logic [7:0] wire_op);
        opc_is_valid_wire = (opc_decode(wire_op) != OPC_INVALID);
    endfunction

endpackage
