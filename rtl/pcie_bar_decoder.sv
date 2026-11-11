// BAR aperture decoder — I/O space (BAR0) and memory space (BAR2).
// BAR0 hit gated by IOCE  (Command[0], I/O Space Enable).
// BAR2 hit gated by MSE   (Command[1], Memory Space Enable).
// Emit no hit when the matching enable is clear.
//
// BAR map (RTL8125B spoof):
//   BAR0 = 32-bit I/O port, 256 bytes  (IORd/IOWr TLPs, 16-bit address)
//   BAR2 = 32-bit non-prefetchable MMIO, 4 KiB

module pcie_bar_decoder #(
    parameter int BAR0_LOG2_SIZE = 8,   // 2^8  = 256 bytes  I/O aperture
    parameter int BAR2_LOG2_SIZE = 12   // 2^12 = 4 KiB      MMIO aperture
) (
    input  logic        ioce,           // Command[0] I/O Space Enable  (for BAR0)
    input  logic        mse,            // Command[1] Memory Space Enable (for BAR2)
    input  logic [63:0] bar0_base_64,
    input  logic [31:0] bar2_base_32,
    input  logic [63:0] tlp_addr,

    output logic        bar_hit,
    output logic [1:0]  bar_idx,
    output logic [15:0] bar_offset_lo,
    output logic [31:0] bar_offset_32
);
    logic bar0_match_raw, bar2_match_raw;
    assign bar0_match_raw = (tlp_addr[63:BAR0_LOG2_SIZE] ==
                             bar0_base_64[63:BAR0_LOG2_SIZE]);
    assign bar2_match_raw = (tlp_addr[63:32] == 32'h0) &&
                            (tlp_addr[31:BAR2_LOG2_SIZE] ==
                             bar2_base_32[31:BAR2_LOG2_SIZE]);

    logic bar0_base_programmed, bar2_base_programmed;
    assign bar0_base_programmed = (bar0_base_64 != 64'h0);
    assign bar2_base_programmed = (bar2_base_32 != 32'h0);

    logic bar0_hit, bar2_hit;
    assign bar0_hit = ioce && bar0_match_raw && bar0_base_programmed;
    assign bar2_hit = mse  && bar2_match_raw && bar2_base_programmed;

    always_comb begin
        bar_hit       = 1'b0;
        bar_idx       = 2'd0;
        bar_offset_lo = 16'h0;
        bar_offset_32 = 32'h0;

        if (bar0_hit) begin
            bar_hit       = 1'b1;
            bar_idx       = 2'd0;
            bar_offset_lo = tlp_addr[15:0];
            bar_offset_32 = {16'h0, tlp_addr[15:0]};
        end else if (bar2_hit) begin
            bar_hit       = 1'b1;
            bar_idx       = 2'd2;
            bar_offset_lo = {4'h0, tlp_addr[11:0]};
            bar_offset_32 = {20'h0, tlp_addr[11:0]};
        end
    end
endmodule
