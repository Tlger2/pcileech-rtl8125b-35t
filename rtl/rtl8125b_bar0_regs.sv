// Minimal RTL8125B BAR0 operational register footprint.
//
// This block models the driver-facing registers needed for deterministic
// initialization. It does not fetch descriptors or perform packet/DMA work.
// MMIO addresses are byte offsets within BAR0; wstrb selects byte lanes of
// the naturally aligned 32-bit word containing addr.

module rtl8125b_bar0_regs #(
    parameter logic [47:0] MAC_ADDR = 48'h02_12_25_35_00_01,
    parameter int unsigned RESET_CLEAR_CYCLES = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mmio_wr_en,
    input  logic        mmio_rd_en,
    input  logic [15:0] mmio_addr,
    input  logic [31:0] mmio_wdata,
    input  logic [3:0]  mmio_wstrb,
    output logic [31:0] mmio_rdata,
    output logic        mmio_rd_valid,

    // Hardware event injection. IntrStatus is sticky and W1C over MMIO.
    input  logic [31:0] intr_set,
    output logic        irq_pending,

    output logic [47:0] mac_address,
    output logic [63:0] tx_desc_base,
    output logic [63:0] tx_high_desc_base,
    output logic [63:0] rx_desc_base,
    output logic [7:0]  chip_cmd
);
    localparam logic [15:0] REG_MAC0        = 16'h0000;
    localparam logic [15:0] REG_MAC4        = 16'h0004;
    localparam logic [15:0] REG_MAR0        = 16'h0008;
    localparam logic [15:0] REG_MAR4        = 16'h000C;
    localparam logic [15:0] REG_TX_DESC_LO  = 16'h0020;
    localparam logic [15:0] REG_TX_DESC_HI  = 16'h0024;
    localparam logic [15:0] REG_TXH_DESC_LO = 16'h0028;
    localparam logic [15:0] REG_TXH_DESC_HI = 16'h002C;
    localparam logic [15:0] REG_CHIP_CMD     = 16'h0034; // byte 0x37, lane 3
    localparam logic [15:0] REG_INTR_MASK    = 16'h0038;
    localparam logic [15:0] REG_INTR_STATUS  = 16'h003C;
    localparam logic [15:0] REG_TX_CONFIG    = 16'h0040;
    localparam logic [15:0] REG_RX_CONFIG    = 16'h0044;
    localparam logic [15:0] REG_RX_DESC_LO   = 16'h00E4;
    localparam logic [15:0] REG_RX_DESC_HI   = 16'h00E8;

    localparam logic [7:0]  CMD_RESET = 8'h10;
    localparam logic [31:0] TXCFG_XID_MASK  = 32'hFCF0_0000;
    localparam logic [31:0] TXCFG_8125B_XID = 32'h6410_0000;
    localparam int unsigned RESET_COUNT_WIDTH =
        (RESET_CLEAR_CYCLES < 2) ? 1 : $clog2(RESET_CLEAR_CYCLES + 1);

    logic [31:0] mac0_reg, mac4_reg;
    logic [31:0] mar0_reg, mar4_reg;
    logic [31:0] intr_mask_reg, intr_status_reg;
    logic [31:0] tx_config_reg, rx_config_reg;
    logic [31:0] tx_desc_lo_reg, tx_desc_hi_reg;
    logic [31:0] txh_desc_lo_reg, txh_desc_hi_reg;
    logic [31:0] rx_desc_lo_reg, rx_desc_hi_reg;
    logic [RESET_COUNT_WIDTH-1:0] reset_count;

    function automatic logic [31:0] strobe_mask(input logic [3:0] strb);
        strobe_mask = {{8{strb[3]}}, {8{strb[2]}},
                       {8{strb[1]}}, {8{strb[0]}}};
    endfunction

    function automatic logic [31:0] merge_wstrb(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strb
    );
        logic [31:0] mask;
        begin
            mask = strobe_mask(strb);
            merge_wstrb = (old_value & ~mask) | (new_value & mask);
        end
    endfunction

    assign mac_address = {mac0_reg[7:0], mac0_reg[15:8],
                          mac0_reg[23:16], mac0_reg[31:24],
                          mac4_reg[7:0], mac4_reg[15:8]};
    assign tx_desc_base      = {tx_desc_hi_reg, tx_desc_lo_reg};
    assign tx_high_desc_base = {txh_desc_hi_reg, txh_desc_lo_reg};
    assign rx_desc_base      = {rx_desc_hi_reg, rx_desc_lo_reg};
    assign irq_pending       = |(intr_mask_reg & intr_status_reg);

    always_comb begin
        mmio_rdata    = 32'h0000_0000;
        mmio_rd_valid = mmio_rd_en;
        unique case ({mmio_addr[15:2], 2'b00})
            REG_MAC0:        mmio_rdata = mac0_reg;
            REG_MAC4:        mmio_rdata = mac4_reg;
            REG_MAR0:        mmio_rdata = mar0_reg;
            REG_MAR4:        mmio_rdata = mar4_reg;
            REG_TX_DESC_LO:  mmio_rdata = tx_desc_lo_reg;
            REG_TX_DESC_HI:  mmio_rdata = tx_desc_hi_reg;
            REG_TXH_DESC_LO: mmio_rdata = txh_desc_lo_reg;
            REG_TXH_DESC_HI: mmio_rdata = txh_desc_hi_reg;
            REG_CHIP_CMD:    mmio_rdata = {chip_cmd, 24'h0};
            REG_INTR_MASK:   mmio_rdata = intr_mask_reg;
            REG_INTR_STATUS: mmio_rdata = intr_status_reg;
            REG_TX_CONFIG:   mmio_rdata = tx_config_reg;
            REG_RX_CONFIG:   mmio_rdata = rx_config_reg;
            REG_RX_DESC_LO:  mmio_rdata = rx_desc_lo_reg;
            REG_RX_DESC_HI:  mmio_rdata = rx_desc_hi_reg;
            default:         mmio_rdata = 32'h0000_0000;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // MAC_ADDR is written in canonical network order.
            mac0_reg          <= {MAC_ADDR[23:16], MAC_ADDR[31:24],
                                  MAC_ADDR[39:32], MAC_ADDR[47:40]};
            mac4_reg          <= {16'h0000, MAC_ADDR[7:0], MAC_ADDR[15:8]};
            mar0_reg          <= 32'h0000_0000;
            mar4_reg          <= 32'h0000_0000;
            intr_mask_reg     <= 32'h0000_0000;
            intr_status_reg   <= 32'h0000_0000;
            tx_config_reg     <= TXCFG_8125B_XID;
            rx_config_reg     <= 32'h0000_0000;
            tx_desc_lo_reg    <= 32'h0000_0000;
            tx_desc_hi_reg    <= 32'h0000_0000;
            txh_desc_lo_reg   <= 32'h0000_0000;
            txh_desc_hi_reg   <= 32'h0000_0000;
            rx_desc_lo_reg    <= 32'h0000_0000;
            rx_desc_hi_reg    <= 32'h0000_0000;
            chip_cmd          <= 8'h00;
            reset_count       <= '0;
        end else begin
            // New hardware events are sticky. A simultaneous W1C leaves a
            // newly asserted event set so it cannot be lost.
            intr_status_reg <= intr_status_reg | intr_set;

            if (reset_count != 0) begin
                reset_count <= reset_count - 1'b1;
                if (reset_count == 1)
                    chip_cmd <= chip_cmd & ~CMD_RESET;
            end

            if (mmio_wr_en) begin
                unique case ({mmio_addr[15:2], 2'b00})
                    REG_MAC0:
                        mac0_reg <= merge_wstrb(mac0_reg, mmio_wdata, mmio_wstrb);
                    REG_MAC4:
                        mac4_reg <= merge_wstrb(mac4_reg, mmio_wdata, mmio_wstrb)
                                    & 32'h0000_FFFF;
                    REG_MAR0:
                        mar0_reg <= merge_wstrb(mar0_reg, mmio_wdata, mmio_wstrb);
                    REG_MAR4:
                        mar4_reg <= merge_wstrb(mar4_reg, mmio_wdata, mmio_wstrb);
                    REG_TX_DESC_LO:
                        tx_desc_lo_reg <= merge_wstrb(tx_desc_lo_reg, mmio_wdata, mmio_wstrb);
                    REG_TX_DESC_HI:
                        tx_desc_hi_reg <= merge_wstrb(tx_desc_hi_reg, mmio_wdata, mmio_wstrb);
                    REG_TXH_DESC_LO:
                        txh_desc_lo_reg <= merge_wstrb(txh_desc_lo_reg, mmio_wdata, mmio_wstrb);
                    REG_TXH_DESC_HI:
                        txh_desc_hi_reg <= merge_wstrb(txh_desc_hi_reg, mmio_wdata, mmio_wstrb);
                    REG_RX_DESC_LO:
                        rx_desc_lo_reg <= merge_wstrb(rx_desc_lo_reg, mmio_wdata, mmio_wstrb);
                    REG_RX_DESC_HI:
                        rx_desc_hi_reg <= merge_wstrb(rx_desc_hi_reg, mmio_wdata, mmio_wstrb);
                    REG_INTR_MASK:
                        intr_mask_reg <= merge_wstrb(intr_mask_reg, mmio_wdata, mmio_wstrb);
                    REG_INTR_STATUS:
                        intr_status_reg <= (intr_status_reg &
                                            ~(mmio_wdata & strobe_mask(mmio_wstrb))) |
                                           intr_set;
                    REG_TX_CONFIG:
                        tx_config_reg <=
                            (merge_wstrb(tx_config_reg, mmio_wdata, mmio_wstrb)
                             & ~TXCFG_XID_MASK) | TXCFG_8125B_XID;
                    REG_RX_CONFIG:
                        rx_config_reg <= merge_wstrb(rx_config_reg, mmio_wdata, mmio_wstrb);
                    REG_CHIP_CMD: begin
                        // ChipCmd occupies byte lane 3 at byte offset 0x37.
                        if (mmio_wstrb[3]) begin
                            chip_cmd <= mmio_wdata[31:24];
                            if (mmio_wdata[28]) begin
                                chip_cmd        <= CMD_RESET;
                                reset_count     <= RESET_CLEAR_CYCLES[RESET_COUNT_WIDTH-1:0];
                                intr_mask_reg   <= 32'h0000_0000;
                                intr_status_reg <= 32'h0000_0000;
                                tx_config_reg   <= TXCFG_8125B_XID;
                                rx_config_reg   <= 32'h0000_0000;
                                tx_desc_lo_reg  <= 32'h0000_0000;
                                tx_desc_hi_reg  <= 32'h0000_0000;
                                txh_desc_lo_reg <= 32'h0000_0000;
                                txh_desc_hi_reg <= 32'h0000_0000;
                                rx_desc_lo_reg  <= 32'h0000_0000;
                                rx_desc_hi_reg  <= 32'h0000_0000;
                            end
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end

endmodule

