// BAR aperture decoder for the XC7A35T presentation of RTL8125B.
//
// 7-series pcie_7x cannot emit the donor I/O 256 B BAR0, so BAR0 is omitted
// (same choice as vivado_build.tcl / pci_type0_cfg_header). Hits:
//   BAR2 = 64-bit non-prefetchable MMIO, 64 KiB  (MAC)
//   BAR4 = 64-bit non-prefetchable MMIO, 16 KiB  (MSI-X)
// Both gated by MSE (Command[1]).

module pcie_bar_decoder
    import rtl8125b_identity_pkg::*;
#(
    parameter int BAR2_LOG2_SIZE = rtl8125b_identity_pkg::BAR2_MEM_LOG2,
    parameter int BAR4_LOG2_SIZE = rtl8125b_identity_pkg::BAR4_MEM_LOG2
) (
    input  logic        mse,
    input  logic [63:0] bar2_base_64,
    input  logic [63:0] bar4_base_64,
    input  logic [63:0] tlp_addr,

    output logic        bar_hit,
    output logic [2:0]  bar_idx,
    output logic [15:0] bar_offset_lo,
    output logic [31:0] bar_offset_32
);
    logic bar2_match_raw, bar4_match_raw;
    assign bar2_match_raw = (tlp_addr[63:BAR2_LOG2_SIZE] ==
                             bar2_base_64[63:BAR2_LOG2_SIZE]);
    assign bar4_match_raw = (tlp_addr[63:BAR4_LOG2_SIZE] ==
                             bar4_base_64[63:BAR4_LOG2_SIZE]);

    logic bar2_base_programmed, bar4_base_programmed;
    assign bar2_base_programmed = (bar2_base_64 != 64'h0);
    assign bar4_base_programmed = (bar4_base_64 != 64'h0);

    logic bar2_hit, bar4_hit;
    assign bar2_hit = mse && bar2_match_raw && bar2_base_programmed;
    assign bar4_hit = mse && bar4_match_raw && bar4_base_programmed;

    always_comb begin
        bar_hit       = 1'b0;
        bar_idx       = 3'd0;
        bar_offset_lo = 16'h0;
        bar_offset_32 = 32'h0;

        if (bar2_hit) begin
            bar_hit       = 1'b1;
            bar_idx       = 3'd2;
            bar_offset_lo = tlp_addr[15:0];
            bar_offset_32 = {16'h0, tlp_addr[15:0]};
        end else if (bar4_hit) begin
            bar_hit       = 1'b1;
            bar_idx       = 3'd4;
            bar_offset_lo = tlp_addr[15:0];
            bar_offset_32 = {16'h0, tlp_addr[15:0]};
        end
    end
endmodule
