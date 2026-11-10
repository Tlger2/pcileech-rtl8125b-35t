// Parser for a 32-bit command stream arriving from an FT601 FIFO.
//
// Frame format:
//   DW0 : 32'h5AA5_C33C                         (MAGIC)
//   DW1 : {opcode[7:0], flags[7:0], length[15:0]}
//   DW2 : 32-bit target register-file address
//   DW3+: length_dw words of payload
//
// Wrap this module with the FT601 slave-FIFO controller: map RXF_N/OE_N/RD_N
// to the fifo_rd_valid/fifo_rd_ready handshake exposed here.

module ft601_cmd_parser
    import opcode_scramble_pkg::*;
#(
    parameter logic [31:0] FRAME_MAGIC = 32'h5AA5_C33C
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        fifo_rd_valid,
    output logic        fifo_rd_ready,
    input  logic [31:0] fifo_rd_data,
    input  logic        accept_frame,
    input  logic        rf_ready,

    output logic        rf_we,
    output logic [31:0] rf_waddr,
    output logic [31:0] rf_wdata,

    output logic        rf_re,
    output logic [31:0] rf_raddr,
    input  logic [31:0] rf_rdata,
    input  logic        rf_rvalid,

    output logic        frame_start,
    output logic        read_start,
    output logic [15:0] read_length,
    output logic        frame_done,
    output logic        bad_opcode_err,
    output logic [7:0]  last_opcode,
    output logic [31:0] last_base_addr
);
    logic word_fire;
    assign word_fire = fifo_rd_valid && fifo_rd_ready;

    typedef enum logic [2:0] {
        S_SYNC  = 3'd0,
        S_HDR   = 3'd1,
        S_ADDR  = 3'd2,
        S_WDATA = 3'd3,
        S_RWAIT = 3'd4,
        S_RISSUE = 3'd5
    } st_t;

    st_t state, state_n;

    logic [7:0]  opc_wire_q;
    logic [7:0]  opc_canon_q;
    logic [7:0]  flags_q;
    logic [15:0] length_q;
    logic [31:0] base_addr_q;
    logic [31:0] cur_addr_q;
    logic        is_burst;
    logic        is_write_cmd;
    logic        is_read_cmd;
    logic        is_ack_cmd;
    logic        opc_known;

    always_comb begin
        is_burst     = (opc_canon_q == OPC_READ_BURST) ||
                       (opc_canon_q == OPC_WRITE_BURST);
        is_write_cmd = (opc_canon_q == OPC_WRITE) ||
                       (opc_canon_q == OPC_WRITE_BURST);
        is_read_cmd  = (opc_canon_q == OPC_READ) ||
                       (opc_canon_q == OPC_READ_BURST);
        // Header-only USB reply so ping/identify/reset do not hang the host.
        is_ack_cmd   = (opc_canon_q == OPC_NOP)       ||
                       (opc_canon_q == OPC_STATUS)    ||
                       (opc_canon_q == OPC_INFO)      ||
                       (opc_canon_q == OPC_KEEPALIVE) ||
                       (opc_canon_q == OPC_VERSION)   ||
                       (opc_canon_q == OPC_RESET)     ||
                       (opc_canon_q == OPC_FLUSH)     ||
                       (opc_canon_q == OPC_HANDSHAKE);
        opc_known    = is_write_cmd || is_read_cmd || is_ack_cmd;
    end

    always_comb begin
        fifo_rd_ready   = 1'b0;
        rf_we           = 1'b0;
        rf_waddr        = cur_addr_q;
        rf_wdata        = fifo_rd_data;
        rf_re           = 1'b0;
        rf_raddr        = cur_addr_q;
        frame_start     = 1'b0;
        read_start      = 1'b0;
        read_length     = is_read_cmd ? (is_burst ? length_q : 16'd1) : 16'd0;
        frame_done      = 1'b0;
        state_n         = state;

        unique case (state)
            S_SYNC: begin
                fifo_rd_ready = accept_frame;
                if (word_fire && fifo_rd_data == FRAME_MAGIC) begin
                    frame_start = 1'b1;
                    state_n     = S_HDR;
                end
            end

            S_HDR: begin
                fifo_rd_ready = 1'b1;
                if (word_fire) state_n = S_ADDR;
            end

            S_ADDR: begin
                fifo_rd_ready = 1'b1;
                if (word_fire) begin
                    if (!opc_known) begin
                        state_n = S_SYNC;
                    end else if (is_write_cmd) begin
                        if (length_q == 16'd0) state_n = S_SYNC;
                        else                   state_n = S_WDATA;
                    end else if (is_read_cmd) begin
                        if (is_burst && length_q == 16'd0) begin
                            state_n = S_SYNC;
                        end else begin
                            read_start = fifo_rd_data != FRAME_MAGIC;
                            state_n = S_RISSUE;
                        end
                    end else if (is_ack_cmd) begin
                        read_start = fifo_rd_data != FRAME_MAGIC;
                        state_n    = S_SYNC;
                    end else begin
                        state_n = S_SYNC;
                    end
                end
            end

            S_WDATA: begin
                fifo_rd_ready = rf_ready;
                if (word_fire) begin
                    rf_we    = 1'b1;
                    rf_waddr = cur_addr_q;
                    rf_wdata = fifo_rd_data;
                    if (length_q == 16'd1) begin
                        frame_done = 1'b1;
                        state_n    = S_SYNC;
                    end
                end
            end

            S_RISSUE: begin
                rf_re = rf_ready;
                if (rf_ready) state_n = S_RWAIT;
            end

            S_RWAIT: begin
                if (rf_rvalid) begin
                    if (!is_burst || length_q == 16'd1) begin
                        frame_done = 1'b1;
                        state_n    = S_SYNC;
                    end else state_n = S_RISSUE;
                end
            end
        endcase

        if (state == S_HDR || state == S_ADDR) begin
            if (word_fire && fifo_rd_data == FRAME_MAGIC) begin
                state_n     = S_HDR;
                frame_start = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_SYNC;
            opc_wire_q     <= 8'h00;
            opc_canon_q    <= OPC_INVALID;
            flags_q        <= 8'h00;
            length_q       <= 16'h0000;
            base_addr_q    <= 32'h0;
            cur_addr_q     <= 32'h0;
            last_opcode    <= 8'h00;
            last_base_addr <= 32'h0;
            bad_opcode_err <= 1'b0;
        end else begin
            state <= state_n;

            unique case (state)
                S_HDR: if (word_fire) begin
                    opc_wire_q  <= fifo_rd_data[31:24];
                    opc_canon_q <= opc_decode(fifo_rd_data[31:24]);
                    flags_q     <= fifo_rd_data[23:16];
                    length_q    <= fifo_rd_data[15:0];
                    last_opcode <= opc_decode(fifo_rd_data[31:24]);
                end

                S_ADDR: if (word_fire) begin
                    base_addr_q    <= fifo_rd_data;
                    cur_addr_q     <= fifo_rd_data;
                    last_base_addr <= fifo_rd_data;
                    if (!opc_known) bad_opcode_err <= 1'b1;
                end

                S_WDATA: if (word_fire) begin
                    length_q   <= length_q - 16'd1;
                    cur_addr_q <= cur_addr_q + 32'd4;
                end

                S_RWAIT: if (rf_rvalid) begin
                    length_q   <= length_q - 16'd1;
                    cur_addr_q <= cur_addr_q + 32'd4;
                end

                default: ;
            endcase

            if (state == S_ADDR && word_fire && opc_known)
                bad_opcode_err <= 1'b0;
            else if (state == S_SYNC)
                bad_opcode_err <= 1'b0;
        end
    end
endmodule
