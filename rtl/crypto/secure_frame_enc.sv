// Data-plane encryption wrapper.
//
// Plaintext DWs flow in; ciphertext DWs flow out with a ChaCha20
// keystream XOR. Within a frame, block_counter increments every
// 16 DWs (64 bytes). Between frames, the frame sequence number
// advances; the nonce is:
//   nonce[11:0]  = session_id
//   nonce[12]    = direction (0 = host->dev, 1 = dev->host)
//   nonce[95:64] = sequence low
//   nonce[63:16] = sequence high / padding
//
// Pair with a Poly1305 MAC (separate module) for authenticity:
// compute over (AAD || ciphertext), append 16-byte tag at end of frame.

module secure_frame_enc (
    input  logic         clk,
    input  logic         rst_n,

    input  logic [255:0] session_key,
    input  logic [15:0]  session_id,
    input  logic         direction,            // 0 = host->dev, 1 = dev->host

    input  logic [31:0]  pt_dw,
    input  logic         pt_valid,
    output logic         pt_ready,
    input  logic         pt_last,

    output logic [31:0]  ct_dw,
    output logic         ct_valid,
    input  logic         ct_ready,
    output logic         ct_last,

    // ChaCha20 core port
    output logic         cc_start,
    output logic [255:0] cc_key,
    output logic [95:0]  cc_nonce,
    output logic [31:0]  cc_block_counter,
    input  logic [511:0] cc_keystream,
    input  logic         cc_done
);
    logic [63:0]  seq_q;
    logic [31:0]  block_cnt_q;
    logic [511:0] ks_block;
    logic [3:0]   dw_in_block;

    assign cc_key   = session_key;
    assign cc_nonce = {15'h0, direction, session_id, seq_q};

    typedef enum logic [1:0] {E_IDLE, E_KEYSTREAM, E_STREAM} e_t;
    e_t enc_state;

    assign pt_ready = (enc_state == E_STREAM) && ct_ready;
    assign ct_valid = (enc_state == E_STREAM) && pt_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enc_state        <= E_IDLE;
            seq_q            <= 64'h0;
            block_cnt_q      <= 32'h0;
            dw_in_block      <= 4'h0;
            cc_start         <= 1'b0;
            cc_block_counter <= 32'h0;
            ks_block         <= 512'h0;
            ct_dw            <= 32'h0;
            ct_last          <= 1'b0;
        end else begin
            cc_start <= 1'b0;

            unique case (enc_state)
                E_IDLE: if (pt_valid) begin
                    cc_start         <= 1'b1;
                    cc_block_counter <= 32'h0;
                    block_cnt_q      <= 32'h0;
                    dw_in_block      <= 4'h0;
                    enc_state        <= E_KEYSTREAM;
                end

                E_KEYSTREAM: if (cc_done) begin
                    ks_block  <= cc_keystream;
                    enc_state <= E_STREAM;
                end

                E_STREAM: if (pt_valid && ct_ready) begin
                    ct_dw   <= pt_dw ^ ks_block[dw_in_block*32 +: 32];
                    ct_last <= pt_last;
                    if (pt_last) begin
                        seq_q     <= seq_q + 64'h1;
                        enc_state <= E_IDLE;
                    end else if (dw_in_block == 4'd15) begin
                        block_cnt_q      <= block_cnt_q + 32'h1;
                        cc_block_counter <= block_cnt_q + 32'h1;
                        cc_start         <= 1'b1;
                        dw_in_block      <= 4'h0;
                        enc_state        <= E_KEYSTREAM;
                    end else begin
                        dw_in_block <= dw_in_block + 4'h1;
                    end
                end

                default: ;
            endcase
        end
    end
endmodule
