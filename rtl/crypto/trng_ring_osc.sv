// Ring-oscillator TRNG for ephemeral handshake nonces.
//
// Eight 7-stage rings jitter against each other; their XOR is sampled
// through a 2-FF sync and Von Neumann debiased to produce ~1 bit of
// entropy every ~16 clocks after sampling stabilizes. A 64-bit pool
// fills from debiased bits and is released on `pop`.
//
// Vivado synthesis attributes:
//   ALLOW_COMBINATORIAL_LOOPS - permit the ring feedback
//   KEEP                      - stop optimizer from collapsing stages
//   ASYNC_REG                 - meta-stability marker on the sampler
//
// Throughput: ~60 kb/s at 62.5 MHz. One 128-bit nonce takes ~2 ms.
// Good enough for a per-boot handshake; do NOT use for bulk keystream.

(* KEEP_HIERARCHY = "TRUE" *)
module trng_ring_osc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pop,
    output logic [63:0] nonce_out,
    output logic        nonce_valid
);
    // -----------------------------------------------------------------
    // Eight ring oscillators, 7 stages each (odd -> oscillates)
    // -----------------------------------------------------------------
    logic [7:0] ro_out;
    genvar g;
    generate
        for (g = 0; g < 8; g++) begin : g_ro
            (* ALLOW_COMBINATORIAL_LOOPS = "TRUE" *)
            (* KEEP = "TRUE" *) wire [6:0] ring;
            assign ring[0] = ~ring[6];
            assign ring[1] = ring[0];
            assign ring[2] = ring[1];
            assign ring[3] = ring[2];
            assign ring[4] = ring[3];
            assign ring[5] = ring[4];
            assign ring[6] = ring[5];
            assign ro_out[g] = ring[6];
        end
    endgenerate

    // -----------------------------------------------------------------
    // Sample XOR of rings through 2-FF sync
    // -----------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic [1:0] sample_sync;
    logic                               sample_bit;
    assign sample_bit = ^ro_out;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_sync <= 2'b00;
        else        sample_sync <= {sample_sync[0], sample_bit};
    end

    // -----------------------------------------------------------------
    // Von Neumann debias: look at pairs of samples.
    // (01) -> emit 1, (10) -> emit 0, (00)/(11) -> discard.
    // -----------------------------------------------------------------
    logic prev_sample_q;
    logic have_prev_q;
    logic vn_bit_q;
    logic vn_valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_sample_q <= 1'b0;
            have_prev_q   <= 1'b0;
            vn_bit_q      <= 1'b0;
            vn_valid_q    <= 1'b0;
        end else begin
            vn_valid_q <= 1'b0;
            if (!have_prev_q) begin
                prev_sample_q <= sample_sync[1];
                have_prev_q   <= 1'b1;
            end else begin
                have_prev_q <= 1'b0;
                if (prev_sample_q != sample_sync[1]) begin
                    vn_bit_q   <= sample_sync[1];
                    vn_valid_q <= 1'b1;
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // 64-bit entropy pool
    // -----------------------------------------------------------------
    logic [63:0] pool_q;
    logic [6:0]  pool_cnt;
    assign nonce_valid = pool_cnt[6];     // >= 64

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pool_q    <= 64'h0;
            pool_cnt  <= 7'd0;
            nonce_out <= 64'h0;
        end else begin
            if (vn_valid_q && !pool_cnt[6]) begin
                pool_q   <= {pool_q[62:0], vn_bit_q};
                pool_cnt <= pool_cnt + 7'd1;
            end
            if (pop && nonce_valid) begin
                nonce_out <= pool_q;
                pool_cnt  <= 7'd0;
            end
        end
    end
endmodule
