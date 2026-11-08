// Response packager: frames a read result or status reply and hands it
// to an upstream TX FIFO (e.g., the FT601 TX side). Mirrors the frame
// format consumed by ft601_cmd_parser.

module ft601_resp_packager
    import opcode_scramble_pkg::*;
#(
    parameter logic [31:0] FRAME_MAGIC = 32'h5AA5_C33C
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        rsp_start,
    input  logic [7:0]  rsp_opcode_canon,
    input  logic [7:0]  rsp_flags,
    input  logic [31:0] rsp_addr,
    input  logic [15:0] rsp_length_dw,
    output logic        rsp_busy,
    output logic        rsp_done,

    input  logic        pld_valid,
    output logic        pld_ready,
    input  logic [31:0] pld_data,

    output logic        fifo_wr_valid,
    input  logic        fifo_wr_ready,
    output logic [31:0] fifo_wr_data,
    output logic        fifo_wr_last,

    output logic        bad_opcode_err
);
    logic [7:0]  opc_canon_q;
    logic [7:0]  opc_wire_q;
    logic [7:0]  flags_q;
    logic [31:0] addr_q;
    logic [15:0] length_q;
    logic [15:0] length_total;

    typedef enum logic [2:0] {
        S_IDLE  = 3'd0,
        S_MAGIC = 3'd1,
        S_HDR   = 3'd2,
        S_ADDR  = 3'd3,
        S_DATA  = 3'd4,
        S_DONE  = 3'd5
    } st_t;

    st_t state, state_n;

    logic fifo_fire;
    logic pld_fire;
    assign fifo_fire = fifo_wr_valid && fifo_wr_ready;
    assign pld_fire  = (state == S_DATA) && pld_valid && fifo_wr_ready;

    always_comb begin
        fifo_wr_valid = 1'b0;
        fifo_wr_data  = 32'h0;
        fifo_wr_last  = 1'b0;
        pld_ready     = 1'b0;
        rsp_done      = 1'b0;
        state_n       = state;

        unique case (state)
            S_IDLE: begin
                if (rsp_start) state_n = S_MAGIC;
            end

            S_MAGIC: begin
                fifo_wr_valid = 1'b1;
                fifo_wr_data  = FRAME_MAGIC;
                if (fifo_fire) state_n = S_HDR;
            end

            S_HDR: begin
                fifo_wr_valid = 1'b1;
                fifo_wr_data  = {opc_wire_q, flags_q, length_total};
                if (fifo_fire) state_n = S_ADDR;
            end

            S_ADDR: begin
                fifo_wr_valid = 1'b1;
                fifo_wr_data  = addr_q;
                if (fifo_fire) begin
                    if (length_total == 16'd0) begin
                        fifo_wr_last = 1'b1;
                        state_n      = S_DONE;
                    end else begin
                        state_n = S_DATA;
                    end
                end
            end

            S_DATA: begin
                fifo_wr_valid = pld_valid;
                fifo_wr_data  = pld_data;
                pld_ready     = fifo_wr_ready;
                fifo_wr_last  = (length_q == 16'd1);
                if (pld_fire && length_q == 16'd1) state_n = S_DONE;
            end

            S_DONE: begin
                rsp_done = 1'b1;
                state_n  = S_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            opc_canon_q    <= 8'h00;
            opc_wire_q     <= 8'h00;
            flags_q        <= 8'h00;
            addr_q         <= 32'h0;
            length_q       <= 16'h0;
            length_total   <= 16'h0;
            bad_opcode_err <= 1'b0;
        end else begin
            state          <= state_n;
            bad_opcode_err <= 1'b0;

            if (state == S_IDLE && rsp_start) begin
                opc_canon_q  <= rsp_opcode_canon;
                opc_wire_q   <= opc_encode(rsp_opcode_canon);
                flags_q      <= rsp_flags;
                addr_q       <= rsp_addr;
                length_q     <= rsp_length_dw;
                length_total <= rsp_length_dw;
                if (opc_encode(rsp_opcode_canon) == OPC_INVALID)
                    bad_opcode_err <= 1'b1;
            end

            if (pld_fire) length_q <= length_q - 16'd1;
        end
    end

    assign rsp_busy = (state != S_IDLE);
endmodule
