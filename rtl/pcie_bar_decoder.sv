// BAR aperture decoder with IOSE / MSE enforcement.
//
// BAR map (RTL8125B donor):
//   BAR0 = I/O 256 B
//   BAR2 = 64-bit non-prefetchable MMIO 64 KiB (MAC)
//   BAR4 = 64-bit non-prefetchable MMIO 16 KiB (MSI-X)

module pcie_bar_decoder
    import rtl8125b_identity_pkg::*;
#(
    parameter int BAR0_LOG2_SIZE = BAR0_IO_LOG2,
    parameter int BAR2_LOG2_SIZE = BAR2_MEM_LOG2,
    parameter int BAR4_LOG2_SIZE = BAR4_MEM_LOG2
) (
    input  logic        iose,
    input  logic        mse,
    input  logic [31:0] bar0_base_io,
    input  logic [63:0] bar2_base_64,
    input  logic [63:0] bar4_base_64,
    input  logic [63:0] tlp_addr,
    input  logic        tlp_is_io,

    output logic        bar_hit,
    output logic [2:0]  bar_idx,
    output logic [15:0] bar_offset_lo,
    output logic [31:0] bar_offset_32
);
    logic bar0_match_raw, bar2_match_raw, bar4_match_raw;
    assign bar0_match_raw = (tlp_addr[63:32] == 32'h0) &&
                            (tlp_addr[31:BAR0_LOG2_SIZE] ==
                             bar0_base_io[31:BAR0_LOG2_SIZE]);
    assign bar2_match_raw = (tlp_addr[63:BAR2_LOG2_SIZE] ==
                             bar2_base_64[63:BAR2_LOG2_SIZE]);
    assign bar4_match_raw = (tlp_addr[63:BAR4_LOG2_SIZE] ==
                             bar4_base_64[63:BAR4_LOG2_SIZE]);

    logic bar0_base_programmed, bar2_base_programmed, bar4_base_programmed;
    assign bar0_base_programmed = (bar0_base_io != 32'h0);
    assign bar2_base_programmed = (bar2_base_64 != 64'h0);
    assign bar4_base_programmed = (bar4_base_64 != 64'h0);

    logic bar0_hit, bar2_hit, bar4_hit;
    assign bar0_hit = iose && tlp_is_io && bar0_match_raw && bar0_base_programmed;
    assign bar2_hit = mse && !tlp_is_io && bar2_match_raw && bar2_base_programmed;
    assign bar4_hit = mse && !tlp_is_io && bar4_match_raw && bar4_base_programmed;

    always_comb begin
        bar_hit       = 1'b0;
        bar_idx       = 3'd0;
        bar_offset_lo = 16'h0;
        bar_offset_32 = 32'h0;

        if (bar0_hit) begin
            bar_hit       = 1'b1;
            bar_idx       = 3'd0;
            bar_offset_lo = {8'h0, tlp_addr[7:0]};
            bar_offset_32 = {24'h0, tlp_addr[7:0]};
        end else if (bar2_hit) begin
            bar_hit       = 1'b1;
            bar_idx       = 3'd2;
            bar_offset_lo = tlp_addr[15:0];
            bar_offset_32 = {16'h0, tlp_addr[15:0]};
        end else if (bar4_hit) begin
            bar_hit       = 1'b1;
            bar_idx       = 3'd4;
            bar_offset_lo = {2'h0, tlp_addr[13:0]};
            bar_offset_32 = {18'h0, tlp_addr[13:0]};
        end
    end
endmodule
