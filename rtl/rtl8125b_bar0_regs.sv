// RTL8125B BAR0 register bank.
//
// 256-byte BAR0 I/O aperture (matching the real RTL8125B BAR0 aperture) with
// the init-time polled registers from the Linux r8169 driver
// (RTL_GIGA_MAC_VER_61). Named registers return realistic defaults;
// everything else lands in a 64-DW shadow RAM so unexpected writes are
// preserved and read back as a real NIC would.
//
// Address bus is 8-bit (byte-addressed, 256 B), DW index is 6-bit.
//
// Link-up appears after a bounded auto-neg delay (default ~400 ms at
// 62.5 MHz) so drivers don't see link-up on cycle 0.

module rtl8125b_bar0_regs #(
    parameter int LINK_UP_DELAY_CYCLES = 32'd25_000_000,
    parameter logic [47:0] MAC_ADDR    = 48'h00_E0_4C_12_34_56,
    parameter bit ENABLE_SHADOW = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mem_wr_en,
    input  logic        mem_rd_en,
    input  logic [7:0]  mem_byte_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_be,
    output logic [31:0] mem_rdata,
    output logic        mem_rvalid,

    input  logic [15:0] tx_desc_ring_level,
    input  logic [15:0] rx_desc_ring_level,

    output logic        irq_pulse
);
    localparam logic [7:0] REG_MAC0       = 8'h00;
    localparam logic [7:0] REG_MAC4       = 8'h04;
    localparam logic [7:0] REG_MAR0       = 8'h08;
    localparam logic [7:0] REG_MAR4       = 8'h0C;
    localparam logic [7:0] REG_CMD        = 8'h34;
    localparam logic [7:0] REG_INTRMASK   = 8'h3C;
    localparam logic [7:0] REG_INTRSTATUS = 8'h38;
    localparam logic [7:0] REG_TXCONFIG   = 8'h40;
    localparam logic [7:0] REG_RXCONFIG   = 8'h44;
    localparam logic [7:0] REG_CFG9346    = 8'h50;
    localparam logic [7:0] REG_CONFIG3    = 8'h54;
    localparam logic [7:0] REG_PHYSTATUS  = 8'h6C;

    localparam logic [31:0] DEF_TXCONFIG = 32'h0700_0700;
    localparam logic [31:0] DEF_RXCONFIG = 32'h0000_0E70;

    logic [47:0] mac_addr_q;
    logic [63:0] mcast_filter_q;
    logic [31:0] txconfig_q;
    logic [31:0] rxconfig_q;
    logic [15:0] intrmask_q;
    logic [15:0] intrstatus_q;
    logic [7:0]  cmd_q;
    logic [7:0]  cfg9346_q;
    logic [7:0]  config2_q, config3_q, config4_q, config5_q;

    logic [31:0] link_timer_q;
    logic        link_up_q;

    // PHYSTATUS bits: [0]FullDup [1]LinkSts [7]EN2000M
    logic [7:0]  phystatus;
    assign phystatus = link_up_q ? 8'b1000_0011 : 8'b0000_0000;

    logic [31:0] shadow_read;

    logic [5:0]  dw_idx;
    logic [7:0]  reg_off;
    assign dw_idx  = mem_byte_addr[7:2];
    assign reg_off = mem_byte_addr;

    // The current endpoint does not deliver Memory Write payloads. It can
    // omit this storage while keeping unmapped offsets at their reset value.
    if (ENABLE_SHADOW) begin : gen_shadow
        logic [31:0] shadow_mem [0:63];
        wire named_write = reg_off == REG_MAC0 || reg_off == REG_MAC4 ||
            reg_off == REG_TXCONFIG || reg_off == REG_RXCONFIG ||
            reg_off == REG_INTRMASK || reg_off == REG_INTRSTATUS ||
            reg_off == REG_CMD || reg_off == REG_CFG9346 || reg_off == REG_CONFIG3;
        assign shadow_read = shadow_mem[dw_idx];
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                for (int i = 0; i < 64; i++) shadow_mem[i] <= '0;
            end else if (mem_wr_en && !named_write) begin
                for (int b = 0; b < 4; b++)
                    if (mem_be[b]) shadow_mem[dw_idx][8*b +: 8] <= mem_wdata[8*b +: 8];
            end
        end
    end else begin : gen_no_shadow
        assign shadow_read = '0;
    end

    // Readback mux
    always_comb begin
        case (reg_off)
            REG_MAC0:        mem_rdata = mac_addr_q[31:0];
            REG_MAC4:        mem_rdata = {16'h0, mac_addr_q[47:32]};
            REG_MAR0:        mem_rdata = mcast_filter_q[31:0];
            REG_MAR4:        mem_rdata = mcast_filter_q[63:32];
            REG_INTRSTATUS:  mem_rdata = {16'h0, intrstatus_q};
            REG_INTRMASK:    mem_rdata = {16'h0, intrmask_q};
            REG_TXCONFIG:    mem_rdata = txconfig_q;
            REG_RXCONFIG:    mem_rdata = rxconfig_q;
            REG_CFG9346:     mem_rdata = {config2_q, 8'h00, 8'h00, cfg9346_q};
            REG_CONFIG3:     mem_rdata = {config5_q, config4_q, config3_q, 8'h00};
            REG_PHYSTATUS:   mem_rdata = {24'h0, phystatus};
            default:         mem_rdata = shadow_read;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_addr_q     <= MAC_ADDR;
            mcast_filter_q <= 64'hFFFF_FFFF_FFFF_FFFF;
            txconfig_q     <= DEF_TXCONFIG;
            rxconfig_q     <= DEF_RXCONFIG;
            intrmask_q     <= 16'h0;
            intrstatus_q   <= 16'h0;
            cmd_q          <= 8'h00;
            cfg9346_q      <= 8'h00;
            config2_q      <= 8'h20;
            config3_q      <= 8'h40;
            config4_q      <= 8'h00;
            config5_q      <= 8'h07;
            link_timer_q   <= 32'h0;
            link_up_q      <= 1'b0;
            mem_rvalid     <= 1'b0;
            irq_pulse      <= 1'b0;
        end else begin
            mem_rvalid <= mem_rd_en;
            irq_pulse  <= 1'b0;

            // Link-up FSM
            if (!link_up_q) begin
                if (link_timer_q >= LINK_UP_DELAY_CYCLES) begin
                    link_up_q       <= 1'b1;
                    intrstatus_q[2] <= 1'b1;
                    if (intrmask_q[2]) irq_pulse <= 1'b1;
                end else begin
                    link_timer_q <= link_timer_q + 1'b1;
                end
            end

            if (mem_wr_en) begin
                unique case (reg_off)
                    REG_MAC0: begin
                        if (mem_be[0]) mac_addr_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) mac_addr_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) mac_addr_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) mac_addr_q[31:24] <= mem_wdata[31:24];
                    end
                    REG_MAC4: begin
                        if (mem_be[0]) mac_addr_q[39:32] <= mem_wdata[7:0];
                        if (mem_be[1]) mac_addr_q[47:40] <= mem_wdata[15:8];
                    end
                    REG_TXCONFIG: begin
                        if (mem_be[0]) txconfig_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) txconfig_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) txconfig_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) txconfig_q[31:24] <= mem_wdata[31:24];
                    end
                    REG_RXCONFIG: begin
                        if (mem_be[0]) rxconfig_q[7:0]   <= mem_wdata[7:0];
                        if (mem_be[1]) rxconfig_q[15:8]  <= mem_wdata[15:8];
                        if (mem_be[2]) rxconfig_q[23:16] <= mem_wdata[23:16];
                        if (mem_be[3]) rxconfig_q[31:24] <= mem_wdata[31:24];
                    end
                    REG_INTRMASK: begin
                        if (mem_be[0]) intrmask_q[7:0]  <= mem_wdata[7:0];
                        if (mem_be[1]) intrmask_q[15:8] <= mem_wdata[15:8];
                    end
                    REG_INTRSTATUS: begin
                        if (mem_be[0]) intrstatus_q[7:0]  <= intrstatus_q[7:0]  & ~mem_wdata[7:0];
                        if (mem_be[1]) intrstatus_q[15:8] <= intrstatus_q[15:8] & ~mem_wdata[15:8];
                    end
                    REG_CMD: begin
                        if (mem_be[0]) begin
                            cmd_q <= mem_wdata[7:0];
                            if (mem_wdata[4]) begin   // software reset
                                link_up_q    <= 1'b0;
                                link_timer_q <= 32'h0;
                            end
                        end
                    end
                    REG_CFG9346: begin
                        if (mem_be[0]) cfg9346_q <= mem_wdata[7:0];
                    end
                    REG_CONFIG3: begin
                        if (cfg9346_q[7:6] == 2'b11) begin
                            if (mem_be[1]) config3_q <= mem_wdata[15:8];
                            if (mem_be[2]) config4_q <= mem_wdata[23:16];
                            if (mem_be[3]) config5_q <= mem_wdata[31:24];
                        end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
