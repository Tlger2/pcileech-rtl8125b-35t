// TLP read-completion timing jitter.
//
// EAC (and other PCIe fingerprinting tools) measure the inter-TLP gap
// between a DMA MRd completion and the next outstanding request.
// A fixed gap is a hardware constant that identifies the DMA board.
// This module inserts a pseudorandom delay (4–67 cycles) using a
// maximal-length 32-bit LFSR (Galois form, x^32+x^22+x^2+x+1) seeded
// from a compile-time parameter so each build has a unique sequence.
//
// Usage:
//   - Assert dma_cpl_seen when a DMA read completion TLP has been
//     forwarded to the host.  The FSM immediately arms and counts
//     down a random delay.
//   - Hold the DMA read engine's request-issue gate low while
//     dma_hold_req is asserted.
//   - Connect seed to a unique per-board value (e.g. device serial
//     number, or tie to a 32-bit config register in BAR0).
//
// Delay range: 4..67 cycles (LFSR[5:0] + 4).
//   At 250 MHz user_clk:  16 ns  .. 268 ns  (sub-microsecond, below
//   any OS-visible measurement granularity but above LFSR overhead).
//   At 125 MHz user_clk:  32 ns  .. 536 ns.
//
// Synthesis: single BRAM-less LFSR, ~35 LUTs, zero BRAM.

// lang: SystemVerilog, file: tlp_jitter_fsm.sv
// target: Xilinx Artix-7 (XC7A35T), Vivado 2023.x

module tlp_jitter_fsm #(
    parameter logic [31:0] LFSR_SEED = 32'hDEAD_C0DE
) (
    input  logic clk,
    input  logic rst_n,

    // Pulse: a DMA read completion TLP just left the endpoint
    input  logic dma_cpl_seen,

    // High while the random hold-off is in progress.
    // The DMA engine must gate MRd issuance while this is asserted.
    output logic dma_hold_req
);

    // ------------------------------------------------------------------ //
    //  Galois LFSR — polynomial x^32+x^22+x^2+x+1 (0x00400007 tapped)   //
    //  Maximal-length: period = 2^32 - 1.                                 //
    // ------------------------------------------------------------------ //
    localparam logic [31:0] LFSR_POLY = 32'h0040_0007;

    logic [31:0] lfsr_q;

    function automatic logic [31:0] lfsr_next(input logic [31:0] s);
        logic feedback;
        feedback = s[0];
        lfsr_next = {1'b0, s[31:1]} ^ (feedback ? LFSR_POLY : 32'h0);
    endfunction

    // ------------------------------------------------------------------ //
    //  Delay counter                                                       //
    // ------------------------------------------------------------------ //
    logic [6:0]  cnt_q;        // counts down from (lfsr[5:0] + 4)
    logic        active_q;

    assign dma_hold_req = active_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_q   <= (LFSR_SEED == 32'h0) ? 32'hDEAD_BEEF : LFSR_SEED;
            cnt_q    <= 7'h0;
            active_q <= 1'b0;
        end else begin
            // Advance LFSR every cycle (the delay just picks a snapshot)
            lfsr_q <= lfsr_next(lfsr_q);

            if (!active_q) begin
                if (dma_cpl_seen) begin
                    // Arm: load random delay 4..67 cycles
                    cnt_q    <= {1'b0, lfsr_q[5:0]} + 7'd4;
                    active_q <= 1'b1;
                end
            end else begin
                if (cnt_q == 7'h1) begin
                    cnt_q    <= 7'h0;
                    active_q <= 1'b0;
                end else begin
                    cnt_q <= cnt_q - 7'h1;
                end
            end
        end
    end

endmodule
