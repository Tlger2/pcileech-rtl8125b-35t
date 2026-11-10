// RTL8125B MAC register file (I/O BAR0 256 B window + MMIO BAR2 64 KiB).
// Offsets match Linux r8169 / r8125 and Windows rt640x64:
//   MAC0=0x00, ChipCmd=0x37, TxPoll=0x38, IntrMask=0x3C, IntrStatus=0x3E,
//   TxConfig=0x40, RxConfig=0x44, Cfg9346=0x50, PHYAR=0x60, PHYstatus=0x6C.
//
// TxConfig reset has chip id 0x64Axxxxx so (val & 0x7CF00000) == 0x64A00000
// (RTL_GIGA_MAC_VER_63 / RTL8125B). PHYAR completes so a PHY probe does not
// Code 10. MAC bytes are Realtek OUI 00:E0:4C, unique, not 12:34:56.

module rtl8125b_bar0_regs
    import rtl8125b_identity_pkg::*;
#(
    parameter int LINK_UP_DELAY_CYCLES = 32'd25_000_000,
    parameter logic [47:0] MAC_ADDR    = rtl8125b_identity_pkg::MAC_ADDR,
    parameter bit ENABLE_SHADOW        = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mem_wr_en,
    input  logic        mem_rd_en,
    input  logic [15:0] mem_byte_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_be,
    output logic [31:0] mem_rdata,
    output logic        mem_rvalid,

    input  logic [15:0] tx_desc_ring_level,
    input  logic [15:0] rx_desc_ring_level,

    output logic        irq_pulse
);
    // r8169 / r8125 byte offsets
    localparam int OFF_MAC0       = 8'h00;
    localparam int OFF_MAR0       = 8'h08;
    localparam int OFF_TNPDS_LO   = 8'h20;
    localparam int OFF_TNPDS_HI   = 8'h24;
    localparam int OFF_CHIPCMD    = 8'h37;
    localparam int OFF_TXPOLL     = 8'h38;
    localparam int OFF_INTRMASK   = 8'h3C;
    localparam int OFF_INTRSTATUS = 8'h3E;
    localparam int OFF_TXCONFIG   = 8'h40;
    localparam int OFF_RXCONFIG   = 8'h44;
    localparam int OFF_CFG9346    = 8'h50;
    localparam int OFF_CONFIG0    = 8'h51;
    localparam int OFF_CONFIG1    = 8'h52;
    localparam int OFF_CONFIG2    = 8'h53;
    localparam int OFF_CONFIG3    = 8'h54;
    localparam int OFF_CONFIG4    = 8'h55;
    localparam int OFF_CONFIG5    = 8'h56;
    localparam int OFF_PHYAR      = 8'h60;
    localparam int OFF_PHYSTATUS  = 8'h6C;
    localparam int OFF_CPLUSCMD   = 8'hE0;
    localparam int OFF_RXMAXSIZE  = 8'hDA;
    localparam int OFF_RDSAR_LO   = 8'hE4;
    localparam int OFF_RDSAR_HI   = 8'hE8;

    localparam logic [7:0] CMD_RESET  = 8'h10;
    localparam logic [7:0] CMD_RX_ENB = 8'h08;
    localparam logic [7:0] CMD_TX_ENB = 8'h04;

    localparam logic [15:0] INTR_LINKCHG = 16'h0020;
    localparam logic [15:0] INTR_ROK     = 16'h0001;
    localparam logic [15:0] INTR_TOK     = 16'h0004;

    localparam logic [31:0] DEF_TXCONFIG = TXCONFIG_RST;
    localparam logic [31:0] DEF_RXCONFIG = 32'h0000_0E00;

    logic [7:0]  mac_q [0:5];
    logic [63:0] mar_q;
    logic [7:0]  chipcmd_q, txpoll_q, cfg9346_q;
    logic [7:0]  config0_q, config1_q, config2_q, config3_q, config4_q, config5_q;
    logic [15:0] intrmask_q, intrstatus_q;
    logic [31:0] txconfig_q, rxconfig_q, phyar_q, cpluscmd_q;
    logic [15:0] rxmaxsize_q;
    logic [31:0] tnpds_lo_q, tnpds_hi_q, rdsar_lo_q, rdsar_hi_q;

    logic [31:0] link_timer_q;
    logic        link_up_q;

    logic [7:0]  phystatus;
    // bit0 FullDup, bit1 LinkSts, bit4 1000, bit5 rx-flow, bit6 tx-flow
    assign phystatus = link_up_q ? 8'b0101_0011 : 8'b0000_0000;

    logic [13:0] dw_idx;
    logic [7:0]  byte_off;
    assign dw_idx   = mem_byte_addr[15:2];
    assign byte_off = mem_byte_addr[7:0];
    wire         in_low256 = (mem_byte_addr[15:8] == 8'h00);

    // ---- Internal GPHY (clause 22) via PHYAR at 0x60 ----
    logic [15:0] phy_regs [0:31];
    logic [4:0]  phy_timer_q;
    logic        phy_pending_q;
    logic        phy_is_write_q;
    logic [4:0]  phy_reg_q;
    logic [15:0] phy_wdata_q;

    logic [31:0] shadow_read;
    wire named_low = in_low256 && (
        (byte_off <= 8'h07) ||
        (byte_off >= 8'h08 && byte_off <= 8'h0F) ||
        (byte_off >= 8'h20 && byte_off <= 8'h27) ||
        (byte_off == OFF_CHIPCMD) || (byte_off == OFF_TXPOLL) ||
        (byte_off[7:1] == OFF_INTRMASK[7:1]) ||  // 0x3C/0x3D
        (byte_off[7:1] == OFF_INTRSTATUS[7:1]) ||
        (byte_off >= OFF_TXCONFIG && byte_off <= OFF_TXCONFIG+3) ||
        (byte_off >= OFF_RXCONFIG && byte_off <= OFF_RXCONFIG+3) ||
        (byte_off >= OFF_CFG9346 && byte_off <= OFF_CONFIG5) ||
        (byte_off >= OFF_PHYAR && byte_off <= OFF_PHYAR+3) ||
        (byte_off == OFF_PHYSTATUS) ||
        (byte_off >= OFF_CPLUSCMD && byte_off <= OFF_CPLUSCMD+3) ||
        (byte_off >= OFF_RXMAXSIZE && byte_off <= OFF_RXMAXSIZE+1) ||
        (byte_off >= OFF_RDSAR_LO && byte_off <= OFF_RDSAR_HI+3)
    );

    if (ENABLE_SHADOW) begin : gen_shadow
        logic [31:0] shadow_mem [0:16383];
        assign shadow_read = shadow_mem[dw_idx];
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                for (int i = 0; i < 16384; i++) shadow_mem[i] <= '0;
            end else if (mem_wr_en && !named_low) begin
                for (int b = 0; b < 4; b++)
                    if (mem_be[b]) shadow_mem[dw_idx][8*b +: 8] <= mem_wdata[8*b +: 8];
            end
        end
    end else begin : gen_no_shadow
        assign shadow_read = '0;
    end

    function automatic logic [31:0] pack4(
        input logic [7:0] b0, b1, b2, b3
    );
        pack4 = {b3, b2, b1, b0};
    endfunction

    logic [31:0] named_rdata;
    logic        named_hit;

    always_comb begin
        named_rdata = 32'h0;
        named_hit   = 1'b0;
        unique case (mem_byte_addr[15:2])
            14'h000: begin
                named_hit   = 1'b1;
                named_rdata = pack4(mac_q[0], mac_q[1], mac_q[2], mac_q[3]);
            end
            14'h001: begin
                named_hit   = 1'b1;
                named_rdata = pack4(mac_q[4], mac_q[5], 8'h00, 8'h00);
            end
            14'h002: begin
                named_hit   = 1'b1;
                named_rdata = mar_q[31:0];
            end
            14'h003: begin
                named_hit   = 1'b1;
                named_rdata = mar_q[63:32];
            end
            14'h008: begin
                named_hit   = 1'b1;
                named_rdata = tnpds_lo_q;
            end
            14'h009: begin
                named_hit   = 1'b1;
                named_rdata = tnpds_hi_q;
            end
            14'h00D: begin  // 0x34: [31:24]=ChipCmd @0x37
                named_hit   = 1'b1;
                named_rdata = {chipcmd_q, 8'h00, 8'h00, 8'h00};
            end
            14'h00E: begin  // 0x38 TxPoll in byte 0
                named_hit   = 1'b1;
                named_rdata = {8'h00, 8'h00, 8'h00, txpoll_q};
            end
            14'h00F: begin  // 0x3C IntrMask, 0x3E IntrStatus
                named_hit   = 1'b1;
                named_rdata = {intrstatus_q, intrmask_q};
            end
            14'h010: begin
                named_hit   = 1'b1;
                named_rdata = txconfig_q;
            end
            14'h011: begin
                named_hit   = 1'b1;
                named_rdata = rxconfig_q;
            end
            14'h014: begin  // 0x50 Cfg9346 + Config0..2
                named_hit   = 1'b1;
                named_rdata = {config2_q, config1_q, config0_q, cfg9346_q};
            end
            14'h015: begin  // 0x54 Config3..5
                named_hit   = 1'b1;
                named_rdata = {8'h00, config5_q, config4_q, config3_q};
            end
            14'h018: begin  // 0x60 PHYAR
                named_hit   = 1'b1;
                named_rdata = phyar_q;
            end
            14'h01B: begin  // 0x6C PHYstatus
                named_hit   = 1'b1;
                named_rdata = {24'h0, phystatus};
            end
            14'h036: begin  // 0xD8: RxMaxSize at 0xDA
                named_hit   = 1'b1;
                named_rdata = {rxmaxsize_q, 16'h0};
            end
            14'h038: begin  // 0xE0 CPlusCmd
                named_hit   = 1'b1;
                named_rdata = cpluscmd_q;
            end
            14'h039: begin
                named_hit   = 1'b1;
                named_rdata = rdsar_lo_q;
            end
            14'h03A: begin
                named_hit   = 1'b1;
                named_rdata = rdsar_hi_q;
            end
            default: ;
        endcase
    end

    assign mem_rdata = named_hit ? named_rdata : shadow_read;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_q[0]       <= MAC_ADDR[47:40];
            mac_q[1]       <= MAC_ADDR[39:32];
            mac_q[2]       <= MAC_ADDR[31:24];
            mac_q[3]       <= MAC_ADDR[23:16];
            mac_q[4]       <= MAC_ADDR[15:8];
            mac_q[5]       <= MAC_ADDR[7:0];
            mar_q          <= 64'hFFFF_FFFF_FFFF_FFFF;
            chipcmd_q      <= 8'h00;
            txpoll_q       <= 8'h00;
            cfg9346_q      <= 8'h00;
            config0_q      <= 8'h00;
            config1_q      <= 8'h0C;
            config2_q      <= 8'h00;
            config3_q      <= 8'h00;
            config4_q      <= 8'h00;
            config5_q      <= 8'h00;
            intrmask_q     <= 16'h0;
            intrstatus_q   <= 16'h0;
            txconfig_q     <= DEF_TXCONFIG;
            rxconfig_q     <= DEF_RXCONFIG;
            phyar_q        <= 32'h0;
            cpluscmd_q     <= 32'h0000_2000;
            rxmaxsize_q    <= 16'h0600;
            tnpds_lo_q     <= 32'h0;
            tnpds_hi_q     <= 32'h0;
            rdsar_lo_q     <= 32'h0;
            rdsar_hi_q     <= 32'h0;
            link_timer_q   <= 32'h0;
            link_up_q      <= 1'b0;
            mem_rvalid     <= 1'b0;
            irq_pulse      <= 1'b0;
            phy_timer_q    <= '0;
            phy_pending_q  <= 1'b0;
            phy_is_write_q <= 1'b0;
            phy_reg_q      <= '0;
            phy_wdata_q    <= '0;
            for (int p = 0; p < 32; p++)
                phy_regs[p] <= 16'h0;
            phy_regs[0]    <= 16'h1140;  // BMCR: AN enable
            phy_regs[1]    <= 16'h7949;  // BMSR: capabilities, no link yet
            phy_regs[2]    <= 16'h001C;  // PHYID1 Realtek
            phy_regs[3]    <= 16'hC916;  // PHYID2
            phy_regs[4]    <= 16'h0DE1;
            phy_regs[9]    <= 16'h0200;
        end else begin
            mem_rvalid <= mem_rd_en;
            irq_pulse  <= 1'b0;
            txpoll_q   <= 8'h00;  // self-clearing

            if (!link_up_q) begin
                if (link_timer_q >= LINK_UP_DELAY_CYCLES) begin
                    link_up_q        <= 1'b1;
                    phy_regs[1]      <= 16'h796D;  // link + AN complete
                    phy_regs[5]      <= 16'hCDE1;
                    phy_regs[10]     <= 16'h3C00;
                    intrstatus_q     <= intrstatus_q | INTR_LINKCHG;
                    if (intrmask_q & INTR_LINKCHG)
                        irq_pulse    <= 1'b1;
                end else begin
                    link_timer_q <= link_timer_q + 1'b1;
                end
            end

            // PHYAR completion: Flag clears on write, sets on read
            if (phy_pending_q) begin
                if (phy_timer_q != 0)
                    phy_timer_q <= phy_timer_q - 1'b1;
                else begin
                    phy_pending_q <= 1'b0;
                    if (phy_is_write_q) begin
                        phy_regs[phy_reg_q] <= phy_wdata_q;
                        phyar_q[31]         <= 1'b0;
                    end else begin
                        phyar_q[15:0]       <= phy_regs[phy_reg_q];
                        phyar_q[31]         <= 1'b1;
                    end
                end
            end

            if (mem_wr_en) begin
                unique case (mem_byte_addr[15:2])
                    14'h000: begin
                        if (mem_be[0]) mac_q[0] <= mem_wdata[7:0];
                        if (mem_be[1]) mac_q[1] <= mem_wdata[15:8];
                        if (mem_be[2]) mac_q[2] <= mem_wdata[23:16];
                        if (mem_be[3]) mac_q[3] <= mem_wdata[31:24];
                    end
                    14'h001: begin
                        if (mem_be[0]) mac_q[4] <= mem_wdata[7:0];
                        if (mem_be[1]) mac_q[5] <= mem_wdata[15:8];
                    end
                    14'h002: begin
                        if (mem_be[0]) mar_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) mar_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) mar_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) mar_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h003: begin
                        if (mem_be[0]) mar_q[39:32] <= mem_wdata[7:0];
                        if (mem_be[1]) mar_q[47:40] <= mem_wdata[15:8];
                        if (mem_be[2]) mar_q[55:48] <= mem_wdata[23:16];
                        if (mem_be[3]) mar_q[63:56] <= mem_wdata[31:24];
                    end
                    14'h008: if (mem_be != 4'h0) begin
                        if (mem_be[0]) tnpds_lo_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) tnpds_lo_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) tnpds_lo_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) tnpds_lo_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h009: begin
                        if (mem_be[0]) tnpds_hi_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) tnpds_hi_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) tnpds_hi_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) tnpds_hi_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h00D: begin
                        if (mem_be[3]) begin
                            chipcmd_q <= mem_wdata[31:24] & (CMD_RESET|CMD_RX_ENB|CMD_TX_ENB);
                            if (mem_wdata[28]) begin  // CmdReset at bit 4 of byte 0x37
                                link_up_q    <= 1'b0;
                                link_timer_q <= 32'h0;
                                chipcmd_q    <= 8'h00;
                                phy_regs[1]  <= 16'h7949;
                            end
                        end
                    end
                    14'h00E: if (mem_be[0]) txpoll_q <= mem_wdata[7:0];
                    14'h00F: begin
                        if (mem_be[0]) intrmask_q[7:0]  <= mem_wdata[7:0];
                        if (mem_be[1]) intrmask_q[15:8] <= mem_wdata[15:8];
                        // IntrStatus is RC/W1C
                        if (mem_be[2]) intrstatus_q[7:0]  <= intrstatus_q[7:0]  & ~mem_wdata[23:16];
                        if (mem_be[3]) intrstatus_q[15:8] <= intrstatus_q[15:8] & ~mem_wdata[31:24];
                    end
                    14'h010: begin
                        // Chip version bits [30:20] stay 0x64A so r8125 IDs RTL8125B
                        if (mem_be[0]) txconfig_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) txconfig_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) txconfig_q[19:16] <= mem_wdata[19:16];
                    end
                    14'h011: begin
                        if (mem_be[0]) rxconfig_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) rxconfig_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) rxconfig_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) rxconfig_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h014: begin
                        if (mem_be[0]) cfg9346_q <= mem_wdata[7:0];
                        if (cfg9346_q[7:6] == 2'b11 || mem_wdata[7:6] == 2'b11) begin
                            if (mem_be[1]) config0_q <= mem_wdata[15:8];
                            if (mem_be[2]) config1_q <= mem_wdata[23:16];
                            if (mem_be[3]) config2_q <= mem_wdata[31:24];
                        end
                    end
                    14'h015: begin
                        if (cfg9346_q[7:6] == 2'b11) begin
                            if (mem_be[0]) config3_q <= mem_wdata[7:0];
                            if (mem_be[1]) config4_q <= mem_wdata[15:8];
                            if (mem_be[2]) config5_q <= mem_wdata[23:16];
                        end
                    end
                    14'h018: begin
                        if (mem_be[0]) phyar_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) phyar_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) phyar_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) phyar_q[31:24] <= mem_wdata[31:24];
                        if (mem_be[3] || mem_be[2]) begin
                            phy_pending_q  <= 1'b1;
                            phy_timer_q    <= 5'd12;
                            phy_is_write_q <= mem_wdata[31];
                            phy_reg_q      <= mem_wdata[20:16];
                            phy_wdata_q    <= mem_wdata[15:0];
                            // Flag behaviour: writes start with Flag=1; we keep
                            // it set until the timer expires, then clear/set.
                            phyar_q[31]    <= mem_wdata[31];
                        end
                    end
                    14'h036: begin
                        if (mem_be[2]) rxmaxsize_q[7:0]  <= mem_wdata[23:16];
                        if (mem_be[3]) rxmaxsize_q[15:8] <= mem_wdata[31:24];
                    end
                    14'h038: begin
                        if (mem_be[0]) cpluscmd_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) cpluscmd_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) cpluscmd_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) cpluscmd_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h039: begin
                        if (mem_be[0]) rdsar_lo_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) rdsar_lo_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) rdsar_lo_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) rdsar_lo_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h03A: begin
                        if (mem_be[0]) rdsar_hi_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) rdsar_hi_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) rdsar_hi_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) rdsar_hi_q[31:24] <= mem_wdata[31:24];
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
