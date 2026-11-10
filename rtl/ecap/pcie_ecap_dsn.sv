// PCI Express Extended Capability — Device Serial Number (DSN).
// ECAP ID 0x0003, version 1.  3 DWs at donor offset 0x168.
// Serial is derived from rtl8125b_identity_pkg::MAC_ADDR (Realtek OUI).

module pcie_ecap_dsn
    import rtl8125b_identity_pkg::*;
#(
    parameter logic [11:0] NEXT_CAP_OFFSET = ECAP_TPH_BASE,
    parameter logic [47:0] MAC_ADDR        = rtl8125b_identity_pkg::MAC_ADDR
) (
    input  logic       cap_rd_en,
    input  logic [1:0] cap_dw_idx,
    output logic [31:0] cap_rdata
);
    localparam logic [31:0] ECAP_HEADER = {NEXT_CAP_OFFSET, 4'h1, 16'h0003};
    localparam logic [31:0] DSN_LO_W = {MAC_ADDR[23:16], MAC_ADDR[15:8],
                                        MAC_ADDR[7:0],   8'h00};
    localparam logic [31:0] DSN_HI_W = {8'h00, MAC_ADDR[47:40],
                                        MAC_ADDR[39:32], MAC_ADDR[31:24]};

    always_comb begin
        case (cap_dw_idx)
            2'd0:    cap_rdata = ECAP_HEADER;
            2'd1:    cap_rdata = DSN_LO_W;
            2'd2:    cap_rdata = DSN_HI_W;
            default: cap_rdata = 32'h0;
        endcase
    end
endmodule
