// ChaCha20 block cipher core.
// Generates one 512-bit keystream block per (key, nonce, block_counter)
// over 20 rounds (10 column + 10 diagonal, interleaved).
//
// Usage:
//   Pulse `start` with key/nonce/block_counter driven stable. 10 clocks
//   after start, `done` pulses and keystream_out holds the 64-byte block.
// Multiple blocks: increment block_counter and start again.
//
// ARX-only (add/rotate/XOR), no S-boxes. ~0.5 K LUTs on XC7A35T.

module chacha20_core (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         start,
    input  logic [255:0] key,
    input  logic [95:0]  nonce,
    input  logic [31:0]  block_counter,

    output logic [511:0] keystream_out,
    output logic         done
);
    // Constants: ASCII "expand 32-byte k"
    localparam logic [31:0] C0 = 32'h61707865;
    localparam logic [31:0] C1 = 32'h3320646E;
    localparam logic [31:0] C2 = 32'h79622D32;
    localparam logic [31:0] C3 = 32'h6B206574;

    logic [31:0] st  [0:15];
    logic [31:0] ini [0:15];
    logic [4:0]  round_cnt;

    typedef enum logic [1:0] {S_IDLE, S_ROUND, S_FINAL, S_DONE} st_t;
    st_t fsm;

    task automatic qr(input int ai, bi, ci, di);
        logic [31:0] a, b, c, d;
        a = st[ai]; b = st[bi]; c = st[ci]; d = st[di];
        a = a + b;
        d = d ^ a; d = {d[15:0], d[31:16]};         // rotl 16
        c = c + d;
        b = b ^ c; b = {b[19:0], b[31:20]};         // rotl 12
        a = a + b;
        d = d ^ a; d = {d[23:0], d[31:24]};         // rotl 8
        c = c + d;
        b = b ^ c; b = {b[24:0], b[31:25]};         // rotl 7
        st[ai] = a; st[bi] = b; st[ci] = c; st[di] = d;
    endtask

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm           <= S_IDLE;
            round_cnt     <= 5'd0;
            done          <= 1'b0;
            keystream_out <= '0;
        end else begin
            done <= 1'b0;

            unique case (fsm)
                S_IDLE: if (start) begin
                    st[0]  <= C0;             st[1]  <= C1;
                    st[2]  <= C2;             st[3]  <= C3;
                    st[4]  <= key[31:0];      st[5]  <= key[63:32];
                    st[6]  <= key[95:64];     st[7]  <= key[127:96];
                    st[8]  <= key[159:128];   st[9]  <= key[191:160];
                    st[10] <= key[223:192];   st[11] <= key[255:224];
                    st[12] <= block_counter;
                    st[13] <= nonce[31:0];    st[14] <= nonce[63:32];
                    st[15] <= nonce[95:64];

                    ini[0]  <= C0;             ini[1]  <= C1;
                    ini[2]  <= C2;             ini[3]  <= C3;
                    ini[4]  <= key[31:0];      ini[5]  <= key[63:32];
                    ini[6]  <= key[95:64];     ini[7]  <= key[127:96];
                    ini[8]  <= key[159:128];   ini[9]  <= key[191:160];
                    ini[10] <= key[223:192];   ini[11] <= key[255:224];
                    ini[12] <= block_counter;
                    ini[13] <= nonce[31:0];    ini[14] <= nonce[63:32];
                    ini[15] <= nonce[95:64];

                    round_cnt <= 5'd0;
                    fsm       <= S_ROUND;
                end

                S_ROUND: begin
                    qr(0, 4,  8, 12);
                    qr(1, 5,  9, 13);
                    qr(2, 6, 10, 14);
                    qr(3, 7, 11, 15);
                    qr(0, 5, 10, 15);
                    qr(1, 6, 11, 12);
                    qr(2, 7,  8, 13);
                    qr(3, 4,  9, 14);

                    if (round_cnt == 5'd9) fsm <= S_FINAL;
                    round_cnt <= round_cnt + 5'd1;
                end

                S_FINAL: begin
                    for (i = 0; i < 16; i++) begin
                        keystream_out[i*32 +: 32] <= st[i] + ini[i];
                    end
                    done <= 1'b1;
                    fsm  <= S_DONE;
                end

                S_DONE: fsm <= S_IDLE;
            endcase
        end
    end
endmodule
