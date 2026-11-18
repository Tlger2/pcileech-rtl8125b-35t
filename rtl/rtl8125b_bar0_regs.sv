// RTL8125B MAC register file (I/O BAR0 256 B window + MMIO BAR2 64 KiB).
// Offsets match Linux r8169 / r8125 and Windows rt640x64:
//   MAC0=0x00, ChipCmd=0x37, TxPoll=0x38, IntrMask=0x3C, IntrStatus=0x3E,
//   TxConfig=0x40, RxConfig=0x44, Cfg9346=0x50, PHYAR=0x60, PHYstatus=0x6C,
//   ERIDR=0x70, ERIAR=0x74, EPHYAR=0x80, OCPDR=0xB0, OCPAR=0xB4.
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
    localparam int OFF_TALLY_LO   = 8'h10;
    localparam int OFF_TALLY_HI   = 8'h14;
    localparam int OFF_TNPDS_LO   = 8'h20;
    localparam int OFF_TNPDS_HI   = 8'h24;
    localparam int OFF_THPDS_LO   = 8'h28;
    localparam int OFF_THPDS_HI   = 8'h2C;
    localparam int OFF_FLASH      = 8'h30;
    localparam int OFF_CHIPCMD    = 8'h37;
    localparam int OFF_TXPOLL     = 8'h38;
    localparam int OFF_INTRMASK   = 8'h3C;
    localparam int OFF_INTRSTATUS = 8'h3E;
    localparam int OFF_TXCONFIG   = 8'h40;
    localparam int OFF_RXCONFIG   = 8'h44;
    localparam int OFF_TIMERINT   = 8'h48;
    localparam int OFF_RXMISSED   = 8'h4C;
    localparam int OFF_TIMEINT2   = 8'h58;
    localparam int OFF_CFG9346    = 8'h50;
    localparam int OFF_CONFIG0    = 8'h51;
    localparam int OFF_CONFIG1    = 8'h52;
    localparam int OFF_CONFIG2    = 8'h53;
    localparam int OFF_CONFIG3    = 8'h54;
    localparam int OFF_CONFIG4    = 8'h55;
    localparam int OFF_CONFIG5    = 8'h56;
    localparam int OFF_PHYAR      = 8'h60;
    localparam int OFF_CSIDR      = 8'h64;
    localparam int OFF_CSIAR      = 8'h68;
    localparam int OFF_PHYSTATUS  = 8'h6C;
    localparam int OFF_GPIO       = 8'h6E;
    localparam int OFF_PMCH       = 8'h6F;
    localparam int OFF_ERIDR      = 8'h70;
    localparam int OFF_ERIAR      = 8'h74;
    localparam int OFF_EPHYAR     = 8'h80;
    localparam int OFF_OCPDR      = 8'hB0;
    localparam int OFF_OCPAR      = 8'hB4;
    localparam int OFF_GPHY_OCP   = 8'hB8;
    localparam int OFF_CPLUSCMD   = 8'hE0;
    localparam int OFF_RXMAXSIZE  = 8'hDA;
    localparam int OFF_RDSAR_LO   = 8'hE4;
    localparam int OFF_RDSAR_HI   = 8'hE8;
    localparam int OFF_MTPS       = 8'hEC;
    localparam int OFF_FUNCEVENT  = 8'hF0;

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
    logic [31:0] eridr_q, eriar_q, ephyar_q, ocpdr_q, ocpar_q;
    logic [31:0] csidr_q, csiar_q, gphy_ocp_q, timeint2_q, mtps_q;
    logic [7:0]  macdbg_q, gpio_q, pmch_q;
    // Flag-protocol stubs — not a full GPHY/ERI/OCP map.
    logic [31:0] eri_mem [0:63];
    logic [31:0] csi_mem [0:63];
    logic [15:0] ocp_mem [0:63];
    logic [15:0] ephy_mem [0:31];
    logic [15:0] gphy_ocp_mem [0:31];
    logic [4:0]  eri_timer_q, ephy_timer_q, ocp_timer_q;
    logic [4:0]  csi_timer_q, gphy_ocp_timer_q;
    logic        eri_pending_q, ephy_pending_q, ocp_pending_q;
    logic        csi_pending_q, gphy_ocp_pending_q;
    logic        eri_is_write_q, ephy_is_write_q, ocp_is_write_q;
    logic        csi_is_write_q, gphy_ocp_is_write_q;
    logic [5:0]  eri_idx_q, ocp_idx_q, csi_idx_q;
    logic [4:0]  ephy_reg_q, gphy_ocp_reg_q;
    logic [15:0] rxmaxsize_q;
    logic [31:0] tnpds_lo_q, tnpds_hi_q, rdsar_lo_q, rdsar_hi_q;
    logic [31:0] tally_lo_q, tally_hi_q, thpds_lo_q, thpds_hi_q;
    logic [31:0] flash_q, timerint_q, rxmissed_q;
    logic [31:0] funcevent_q, funceventmask_q, funcpreset_q, funcforce_q;
    logic [15:0] int_cfg1_q;
    logic [15:0] ocp_addr_q;
    logic [11:0] eri_addr_q;
    logic [11:0] gphy_addr_q;

    logic [31:0] link_timer_q;
    logic        link_up_q;

    logic [7:0]  phystatus;
    // r8169 PHYstatus: bit0 FullDup, bit1 LinkSts, bit3 100M, bit4 1000M,
    // bit5 RxFlow, bit6 TxFlow. RTL8125 also uses bit4 plus OCP for 2.5G.
    // Stay link-up so rtcx21 does not D3/Code-10 a "no media" NIC.
    assign phystatus = link_up_q ? 8'b0101_0011 : 8'b0000_0000;

    // 64 KiB BAR2 window. Named MAC registers in 0x00-0xFF override a BRAM
    // shadow of the rest of the aperture. The BRAM has no async reset so it
    // infers block RAM (a 16K-DW FF array will not fit XC7A35T).
    logic [13:0] ram_idx;
    logic [7:0]  byte_off;
    assign ram_idx  = mem_byte_addr[15:2];
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
        (byte_off >= 8'h10 && byte_off <= 8'h17) ||
        (byte_off >= 8'h20 && byte_off <= 8'h33) ||
        (byte_off == OFF_CHIPCMD) || (byte_off == OFF_TXPOLL) ||
        (byte_off[7:1] == OFF_INTRMASK[7:1]) ||  // 0x3C/0x3D
        (byte_off[7:1] == OFF_INTRSTATUS[7:1]) ||
        (byte_off >= OFF_TXCONFIG && byte_off <= OFF_RXMISSED+3) ||
        (byte_off >= OFF_CFG9346 && byte_off <= OFF_CONFIG5) ||
        (byte_off >= OFF_TIMEINT2 && byte_off <= OFF_TIMEINT2+3) ||
        (byte_off >= OFF_PHYAR && byte_off <= OFF_PHYAR+3) ||
        (byte_off >= OFF_CSIDR && byte_off <= OFF_CSIAR+3) ||
        (byte_off >= OFF_PHYSTATUS && byte_off <= OFF_PMCH) ||
        (byte_off >= OFF_ERIDR && byte_off <= OFF_ERIAR+3) ||
        (byte_off >= 8'h78 && byte_off <= 8'h7B) ||
        (byte_off >= OFF_EPHYAR && byte_off <= OFF_EPHYAR+3) ||
        (byte_off >= OFF_OCPDR && byte_off <= OFF_OCPAR+3) ||
        (byte_off >= OFF_GPHY_OCP && byte_off <= OFF_GPHY_OCP+3) ||
        (byte_off >= OFF_CPLUSCMD && byte_off <= OFF_CPLUSCMD+3) ||
        (byte_off >= OFF_RXMAXSIZE && byte_off <= OFF_RXMAXSIZE+1) ||
        (byte_off >= OFF_RDSAR_LO && byte_off <= OFF_RDSAR_HI+3) ||
        (byte_off >= OFF_MTPS && byte_off <= OFF_MTPS+3) ||
        (byte_off >= OFF_FUNCEVENT && byte_off <= OFF_FUNCEVENT+15)
    );

    if (ENABLE_SHADOW) begin : gen_shadow
        (* ram_style = "block" *) logic [31:0] bar2_ram [0:16383];
        logic [31:0] ram_q;
        assign shadow_read = ram_q;
        always_ff @(posedge clk) begin
            ram_q <= bar2_ram[ram_idx];
            if (mem_wr_en && !named_low) begin
                for (int b = 0; b < 4; b++)
                    if (mem_be[b]) bar2_ram[ram_idx][8*b +: 8] <= mem_wdata[8*b +: 8];
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

    // CSI is a MMIO window into PCI config. Seed Type-0 header DWs so a
    // r8169/r8125/rtcx21 CSI probe of VID/DID/rev/SSID is not 0.
    function automatic logic [31:0] csi_cfg_dw(input logic [5:0] idx);
        unique case (idx)
            6'd0:  csi_cfg_dw = {DEVICE_ID, VENDOR_ID};
            6'd1:  csi_cfg_dw = 32'h0010_0000;  // Status CapsList, Command 0
            6'd2:  csi_cfg_dw = {CLASS_CODE, REVISION_ID};
            6'd11: csi_cfg_dw = {SUBSYS_ID, SUBSYS_VENDOR_ID};
            6'd13: csi_cfg_dw = {24'h0, CAP_PTR};
            default: csi_cfg_dw = 32'h0;
        endcase
    endfunction

    function automatic logic [15:0] ocp_rom(input logic [15:0] addr);
        unique case (addr)
            16'hC0B4: ocp_rom = 16'h0000;
            16'hC0B8: ocp_rom = 16'h0000;
            16'hE860: ocp_rom = 16'h0040;  // EEE
            16'hE8DE: ocp_rom = 16'h20E6;
            16'hE0D4: ocp_rom = 16'h0000;
            16'hC0A0: ocp_rom = 16'h0000;
            16'hE614: ocp_rom = 16'h0400;
            default:  ocp_rom = 16'h0;
        endcase
    endfunction

    function automatic logic [31:0] eri_rom(input logic [11:0] addr);
        unique case (addr[11:2])
            10'h032: eri_rom = 32'h0008_0002;  // 0xC8 EXGMAC
            10'h035: eri_rom = 32'h0000_0000;  // 0xD4
            10'h074: eri_rom = 32'h0000_0000;  // 0x1D0
            default: eri_rom = 32'h0;
        endcase
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
            14'h004: begin
                named_hit   = 1'b1;
                named_rdata = tally_lo_q;
            end
            14'h005: begin
                named_hit   = 1'b1;
                named_rdata = tally_hi_q;
            end
            14'h008: begin
                named_hit   = 1'b1;
                named_rdata = tnpds_lo_q;
            end
            14'h009: begin
                named_hit   = 1'b1;
                named_rdata = tnpds_hi_q;
            end
            14'h00A: begin
                named_hit   = 1'b1;
                named_rdata = thpds_lo_q;
            end
            14'h00B: begin
                named_hit   = 1'b1;
                named_rdata = thpds_hi_q;
            end
            14'h00C: begin
                named_hit   = 1'b1;
                named_rdata = flash_q;
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
            14'h012: begin
                named_hit   = 1'b1;
                named_rdata = timerint_q;
            end
            14'h013: begin
                named_hit   = 1'b1;
                named_rdata = rxmissed_q;
            end
            14'h016: begin  // 0x58 TimeInt2
                named_hit   = 1'b1;
                named_rdata = timeint2_q;
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
            14'h019: begin  // 0x64 CSIDR
                named_hit   = 1'b1;
                named_rdata = csidr_q;
            end
            14'h01A: begin  // 0x68 CSIAR
                named_hit   = 1'b1;
                named_rdata = csiar_q;
            end
            14'h01B: begin  // 0x6C PHYstatus, 0x6D MACDBG, 0x6E GPIO, 0x6F PMCH
                named_hit   = 1'b1;
                named_rdata = {pmch_q, gpio_q, macdbg_q, phystatus};
            end
            14'h01C: begin  // 0x70 ERIDR
                named_hit   = 1'b1;
                named_rdata = eridr_q;
            end
            14'h01D: begin  // 0x74 ERIAR
                named_hit   = 1'b1;
                named_rdata = eriar_q;
            end
            14'h01E: begin  // 0x78: INT_CFG1_8125 at 0x7A
                named_hit   = 1'b1;
                named_rdata = {int_cfg1_q, 16'h0};
            end
            14'h020: begin  // 0x80 EPHYAR
                named_hit   = 1'b1;
                named_rdata = ephyar_q;
            end
            14'h02C: begin  // 0xB0 OCPDR
                named_hit   = 1'b1;
                named_rdata = ocpdr_q;
            end
            14'h02D: begin  // 0xB4 OCPAR
                named_hit   = 1'b1;
                named_rdata = ocpar_q;
            end
            14'h02E: begin  // 0xB8 GPHY_OCP (flag protocol, not a full GPHY)
                named_hit   = 1'b1;
                named_rdata = gphy_ocp_q;
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
            14'h03B: begin  // 0xEC MTPS
                named_hit   = 1'b1;
                named_rdata = mtps_q;
            end
            14'h03C: begin
                named_hit   = 1'b1;
                named_rdata = funcevent_q;
            end
            14'h03D: begin
                named_hit   = 1'b1;
                named_rdata = funceventmask_q;
            end
            14'h03E: begin
                named_hit   = 1'b1;
                named_rdata = funcpreset_q;
            end
            14'h03F: begin
                named_hit   = 1'b1;
                named_rdata = funcforce_q;
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
            thpds_lo_q     <= 32'h0;
            thpds_hi_q     <= 32'h0;
            tally_lo_q     <= 32'h0;
            tally_hi_q     <= 32'h0;
            flash_q        <= 32'h0;
            timerint_q     <= 32'h0;
            rxmissed_q     <= 32'h0;
            funcevent_q    <= 32'h0;
            funceventmask_q<= 32'h0;
            funcpreset_q   <= 32'h0;
            funcforce_q    <= 32'h0;
            rdsar_lo_q     <= 32'h0;
            rdsar_hi_q     <= 32'h0;
            link_timer_q   <= LINK_UP_DELAY_CYCLES;
            link_up_q      <= 1'b1;
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
            phy_regs[1]    <= 16'h796D;  // BMSR: link + AN complete
            phy_regs[2]    <= 16'h001C;  // PHYID1 Realtek
            phy_regs[3]    <= 16'hC916;  // PHYID2
            phy_regs[4]    <= 16'h0DE1;
            phy_regs[5]    <= 16'hCDE1;
            phy_regs[9]    <= 16'h0200;
            phy_regs[10]   <= 16'h3C00;
            eridr_q        <= 32'h0;
            eriar_q        <= 32'h0;
            ephyar_q       <= 32'h0;
            ocpdr_q        <= 32'h0;
            ocpar_q        <= 32'h0;
            csidr_q        <= 32'h0;
            csiar_q        <= 32'h0;
            gphy_ocp_q     <= 32'h0;
            timeint2_q     <= 32'h0;
            mtps_q         <= 32'h0000_000C;
            macdbg_q       <= 8'h00;
            gpio_q         <= 8'h00;
            pmch_q         <= 8'hC0;  // donor-plausible PMCH (PME/D3cold)
            int_cfg1_q     <= 16'h0;
            ocp_addr_q     <= 16'h0;
            eri_addr_q     <= 12'h0;
            gphy_addr_q    <= 12'h0;
            eri_timer_q    <= '0;
            ephy_timer_q   <= '0;
            ocp_timer_q    <= '0;
            csi_timer_q    <= '0;
            gphy_ocp_timer_q <= '0;
            eri_pending_q  <= 1'b0;
            ephy_pending_q <= 1'b0;
            ocp_pending_q  <= 1'b0;
            csi_pending_q  <= 1'b0;
            gphy_ocp_pending_q <= 1'b0;
            eri_is_write_q <= 1'b0;
            ephy_is_write_q<= 1'b0;
            ocp_is_write_q <= 1'b0;
            csi_is_write_q <= 1'b0;
            gphy_ocp_is_write_q <= 1'b0;
            eri_idx_q      <= '0;
            ocp_idx_q      <= '0;
            csi_idx_q      <= '0;
            ephy_reg_q     <= '0;
            gphy_ocp_reg_q <= '0;
            for (int e = 0; e < 64; e++) begin
                eri_mem[e] <= 32'h0;
                csi_mem[e] <= csi_cfg_dw(e[5:0]);
                ocp_mem[e] <= 16'h0;
            end
            for (int ep = 0; ep < 32; ep++) begin
                ephy_mem[ep]      <= 16'h0;
                gphy_ocp_mem[ep]  <= 16'h0;
            end
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

            // PHYAR / CSI / ERI / EPHY / OCP / GPHY_OCP: Flag clears on write, sets on read
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
            if (eri_pending_q) begin
                if (eri_timer_q != 0)
                    eri_timer_q <= eri_timer_q - 1'b1;
                else begin
                    eri_pending_q <= 1'b0;
                    if (eri_is_write_q) begin
                        eri_mem[eri_idx_q] <= eridr_q;
                        eriar_q[31]        <= 1'b0;
                    end else begin
                        eridr_q            <= (eri_mem[eri_idx_q] != 32'h0)
                                            ? eri_mem[eri_idx_q]
                                            : eri_rom(eri_addr_q);
                        eriar_q[31]        <= 1'b1;
                    end
                end
            end
            if (ephy_pending_q) begin
                if (ephy_timer_q != 0)
                    ephy_timer_q <= ephy_timer_q - 1'b1;
                else begin
                    ephy_pending_q <= 1'b0;
                    if (ephy_is_write_q) begin
                        ephy_mem[ephy_reg_q] <= ephyar_q[15:0];
                        ephyar_q[31]         <= 1'b0;
                    end else begin
                        ephyar_q[15:0]       <= ephy_mem[ephy_reg_q];
                        ephyar_q[31]         <= 1'b1;
                    end
                end
            end
            if (ocp_pending_q) begin
                if (ocp_timer_q != 0)
                    ocp_timer_q <= ocp_timer_q - 1'b1;
                else begin
                    ocp_pending_q <= 1'b0;
                    if (ocp_is_write_q) begin
                        ocp_mem[ocp_idx_q] <= ocpdr_q[15:0];
                        ocpar_q[31]        <= 1'b0;
                    end else begin
                        ocpdr_q[15:0]      <= (ocp_mem[ocp_idx_q] != 16'h0)
                                            ? ocp_mem[ocp_idx_q]
                                            : ocp_rom(ocp_addr_q);
                        ocpar_q[31]        <= 1'b1;
                    end
                end
            end
            if (csi_pending_q) begin
                if (csi_timer_q != 0)
                    csi_timer_q <= csi_timer_q - 1'b1;
                else begin
                    csi_pending_q <= 1'b0;
                    if (csi_is_write_q) begin
                        csi_mem[csi_idx_q] <= csidr_q;
                        csiar_q[31]        <= 1'b0;
                    end else begin
                        csidr_q            <= csi_mem[csi_idx_q];
                        csiar_q[31]        <= 1'b1;
                    end
                end
            end
            if (gphy_ocp_pending_q) begin
                if (gphy_ocp_timer_q != 0)
                    gphy_ocp_timer_q <= gphy_ocp_timer_q - 1'b1;
                else begin
                    gphy_ocp_pending_q <= 1'b0;
                    if (gphy_ocp_is_write_q) begin
                        gphy_ocp_mem[gphy_ocp_reg_q] <= gphy_ocp_q[15:0];
                        if (gphy_addr_q == 12'hA40) phy_regs[0] <= gphy_ocp_q[15:0];
                        if (gphy_addr_q == 12'hA42) phy_regs[1] <= gphy_ocp_q[15:0];
                        gphy_ocp_q[31]               <= 1'b0;
                    end else begin
                        unique case (gphy_addr_q)
                            12'hA40: gphy_ocp_q[15:0] <= phy_regs[0];
                            12'hA42: gphy_ocp_q[15:0] <= phy_regs[1];
                            12'hA44: gphy_ocp_q[15:0] <= phy_regs[2];
                            12'hA46: gphy_ocp_q[15:0] <= phy_regs[3];
                            default: gphy_ocp_q[15:0] <= gphy_ocp_mem[gphy_ocp_reg_q];
                        endcase
                        gphy_ocp_q[31] <= 1'b1;
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
                    14'h004: begin
                        if (mem_be[0]) tally_lo_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) tally_lo_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) tally_lo_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) tally_lo_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h005: begin
                        if (mem_be[0]) tally_hi_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) tally_hi_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) tally_hi_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) tally_hi_q[31:24] <= mem_wdata[31:24];
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
                    14'h00A: begin
                        if (mem_be[0]) thpds_lo_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) thpds_lo_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) thpds_lo_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) thpds_lo_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h00B: begin
                        if (mem_be[0]) thpds_hi_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) thpds_hi_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) thpds_hi_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) thpds_hi_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h00C: begin
                        if (mem_be[0]) flash_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) flash_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) flash_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) flash_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h00D: begin
                        if (mem_be[3]) begin
                            chipcmd_q <= mem_wdata[31:24] & (CMD_RESET|CMD_RX_ENB|CMD_TX_ENB);
                            if (mem_wdata[28]) begin  // CmdReset at bit 4 of byte 0x37
                                // Self-clear immediately. Keep link so a PnP
                                // restart does not Code-10 waiting for media.
                                chipcmd_q    <= 8'h00;
                                link_up_q    <= 1'b1;
                                link_timer_q <= LINK_UP_DELAY_CYCLES;
                                phy_regs[1]  <= 16'h796D;
                                phy_regs[5]  <= 16'hCDE1;
                                phy_regs[10] <= 16'h3C00;
                            end
                        end
                    end
                    14'h00E: if (mem_be[0]) begin
                        txpoll_q <= mem_wdata[7:0];
                        // NPQ/HPQ kick: a real MAC would DMA a descriptor and
                        // raise TOK. Pulse so the driver sees interrupt life.
                        if (mem_wdata[7:0] != 8'h00) begin
                            intrstatus_q <= intrstatus_q | INTR_TOK;
                            if (intrmask_q & INTR_TOK)
                                irq_pulse <= 1'b1;
                        end
                    end
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
                    14'h012: begin
                        if (mem_be[0]) timerint_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) timerint_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) timerint_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) timerint_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h013: begin
                        if (mem_be[0]) rxmissed_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) rxmissed_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) rxmissed_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) rxmissed_q[31:24] <= mem_wdata[31:24];
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
                    14'h016: begin  // 0x58 TimeInt2
                        if (mem_be[0]) timeint2_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) timeint2_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) timeint2_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) timeint2_q[31:24] <= mem_wdata[31:24];
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
                    14'h019: begin  // CSIDR
                        if (mem_be[0]) csidr_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) csidr_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) csidr_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) csidr_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h01A: begin  // CSIAR Flag=bit31, 64-entry stub
                        if (mem_be[0]) csiar_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) csiar_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) csiar_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) csiar_q[31:24] <= mem_wdata[31:24];
                        if (mem_be[3] || mem_be[2]) begin
                            csi_pending_q  <= 1'b1;
                            csi_timer_q    <= 5'd12;
                            csi_is_write_q <= mem_wdata[31];
                            csi_idx_q      <= mem_wdata[7:2];
                            csiar_q[31]    <= mem_wdata[31];
                        end
                    end
                    14'h01B: begin  // PHYstatus RO; MACDBG/GPIO/PMCH RW
                        if (mem_be[1]) macdbg_q <= mem_wdata[15:8];
                        if (mem_be[2]) gpio_q   <= mem_wdata[23:16];
                        if (mem_be[3]) pmch_q   <= mem_wdata[31:24];
                    end
                    14'h01C: begin  // ERIDR
                        if (mem_be[0]) eridr_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) eridr_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) eridr_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) eridr_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h01D: begin  // ERIAR Flag=bit31, 64-entry stub
                        if (mem_be[0]) eriar_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) eriar_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) eriar_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) eriar_q[31:24] <= mem_wdata[31:24];
                        if (mem_be[3] || mem_be[2]) begin
                            eri_pending_q  <= 1'b1;
                            eri_timer_q    <= 5'd12;
                            eri_is_write_q <= mem_wdata[31];
                            eri_idx_q      <= mem_wdata[9:4];
                            eri_addr_q     <= mem_wdata[11:0];
                            eriar_q[31]    <= mem_wdata[31];
                        end
                    end
                    14'h01E: begin  // INT_CFG1_8125 at 0x7A
                        if (mem_be[2]) int_cfg1_q[7:0]  <= mem_wdata[23:16];
                        if (mem_be[3]) int_cfg1_q[15:8] <= mem_wdata[31:24];
                    end
                    14'h020: begin  // EPHYAR
                        if (mem_be[0]) ephyar_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) ephyar_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) ephyar_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) ephyar_q[31:24] <= mem_wdata[31:24];
                        if (mem_be[3] || mem_be[2]) begin
                            ephy_pending_q  <= 1'b1;
                            ephy_timer_q    <= 5'd12;
                            ephy_is_write_q <= mem_wdata[31];
                            ephy_reg_q      <= mem_wdata[20:16];
                            ephyar_q[31]    <= mem_wdata[31];
                        end
                    end
                    14'h02C: begin  // OCPDR
                        if (mem_be[0]) ocpdr_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) ocpdr_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) ocpdr_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) ocpdr_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h02D: begin  // OCPAR
                        if (mem_be[0]) ocpar_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) ocpar_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) ocpar_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) ocpar_q[31:24] <= mem_wdata[31:24];
                        if (mem_be[3] || mem_be[2]) begin
                            ocp_pending_q  <= 1'b1;
                            ocp_timer_q    <= 5'd12;
                            ocp_is_write_q <= mem_wdata[31];
                            ocp_idx_q      <= mem_wdata[7:2];
                            ocp_addr_q     <= mem_wdata[15:0];
                            ocpar_q[31]    <= mem_wdata[31];
                        end
                    end
                    14'h02E: begin  // GPHY_OCP Flag=bit31, 32-entry stub (not a full GPHY)
                        if (mem_be[0]) gphy_ocp_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) gphy_ocp_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) gphy_ocp_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) gphy_ocp_q[31:24] <= mem_wdata[31:24];
                        if (mem_be[3] || mem_be[2]) begin
                            gphy_ocp_pending_q  <= 1'b1;
                            gphy_ocp_timer_q    <= 5'd12;
                            gphy_ocp_is_write_q <= mem_wdata[31];
                            gphy_ocp_reg_q      <= mem_wdata[20:16];
                            gphy_addr_q         <= mem_wdata[27:16];
                            gphy_ocp_q[31]      <= mem_wdata[31];
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
                    14'h03B: begin  // 0xEC MTPS
                        if (mem_be[0]) mtps_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) mtps_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) mtps_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) mtps_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h03C: begin
                        if (mem_be[0]) funcevent_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) funcevent_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) funcevent_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) funcevent_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h03D: begin
                        if (mem_be[0]) funceventmask_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) funceventmask_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) funceventmask_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) funceventmask_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h03E: begin
                        if (mem_be[0]) funcpreset_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) funcpreset_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) funcpreset_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) funcpreset_q[31:24] <= mem_wdata[31:24];
                    end
                    14'h03F: begin
                        if (mem_be[0]) funcforce_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) funcforce_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) funcforce_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) funcforce_q[31:24] <= mem_wdata[31:24];
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
