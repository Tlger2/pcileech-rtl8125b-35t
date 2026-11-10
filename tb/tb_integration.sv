// Endpoint-level checks for the integration bugs:
//   * 1-DW and multi-DW CplD reach dma_engine (STATUS / RDATA / tag)
//   * MemRd and MemWr DW1 byte enables are First=F, Last=0
//   * BAR0 MemWr payload updates a register (full and partial First BE)
//   * BAR0 irq_pulse raises cfg_interrupt and drops it on cfg_interrupt_rdy
`timescale 1ns/1ps

module tb_integration;
    import opcode_scramble_pkg::*;

    logic user_clk = 0, ft601_clk = 0;
    always #8 user_clk = ~user_clk;
    always #5 ft601_clk = ~ft601_clk;

    logic user_reset = 1;
    logic [63:0] tx_data, rx_data;
    logic [7:0]  tx_keep, rx_keep;
    logic tx_valid, tx_last, tx_ready;
    logic rx_valid, rx_last;
    logic [15:0] completer_id;

    logic        cfg_interrupt, cfg_interrupt_rdy, cfg_interrupt_assert;
    logic [7:0]  cfg_interrupt_di;
    logic        cfg_msienable;
    logic [2:0]  cfg_mmenable;

    localparam logic [31:0] MAGIC = 32'h5AA5_C33C;
    localparam logic [31:0] ADDR_LO = 32'h4;
    localparam logic [31:0] ADDR_HI = 32'h8;
    localparam logic [31:0] WDATA   = 32'hC;
    localparam logic [31:0] CTRL    = 32'h0;
    localparam logic [31:0] STATUS  = 32'h10;
    localparam logic [31:0] RDATA   = 32'h14;

    logic [31:0] rx_mem [0:511];
    int rx_len, rx_index;
    logic [31:0] tx_mem [0:511];
    int tx_index;
    logic txe_n;
    wire rxf_n = (rx_index >= rx_len);
    wire oe_n, rd_n, wr_n;
    tri [31:0] bus_data;
    tri [3:0]  bus_be;
    wire [31:0] rx_word = (rx_index < 512) ? rx_mem[rx_index] : 32'h0;
    assign bus_data = (!oe_n && !rxf_n) ? rx_word : 32'bz;
    assign bus_be   = (!oe_n && !rxf_n) ? 4'hf : 4'bz;

    logic        tx_cap_en;
    logic [63:0] tx_beat [0:7];
    logic [7:0]  tx_beat_keep [0:7];
    logic        tx_beat_last [0:7];
    int          tx_beat_n;

    pcie_custom_endpoint_top dut (
        .user_clk(user_clk), .user_reset(user_reset), .user_lnk_up(1'b1),
        .s_axis_tx_tdata(tx_data), .s_axis_tx_tkeep(tx_keep),
        .s_axis_tx_tvalid(tx_valid), .s_axis_tx_tready(tx_ready),
        .s_axis_tx_tlast(tx_last), .s_axis_tx_tuser(),
        .m_axis_rx_tdata(rx_data), .m_axis_rx_tkeep(rx_keep),
        .m_axis_rx_tvalid(rx_valid), .m_axis_rx_tready(),
        .m_axis_rx_tlast(rx_last), .m_axis_rx_tuser(22'b0),
        .cfg_completer_id(completer_id), .cfg_max_payload_size(3'b0),
        .cfg_max_read_req_size(3'b0), .link_speed_live(4'd2),
        .link_width_live(6'd1),
        .cfg_interrupt(cfg_interrupt), .cfg_interrupt_rdy(cfg_interrupt_rdy),
        .cfg_interrupt_assert(cfg_interrupt_assert),
        .cfg_interrupt_di(cfg_interrupt_di),
        .cfg_interrupt_msienable(cfg_msienable),
        .cfg_interrupt_mmenable(cfg_mmenable),
        .ft601_clk(ft601_clk), .ft601_rst_n(!user_reset), .ft601_rxf_n(rxf_n),
        .ft601_oe_n(oe_n), .ft601_rd_n(rd_n), .ft601_wr_n(wr_n),
        .ft601_txe_n(txe_n), .ft601_data(bus_data), .ft601_be(bus_be)
    );

    // Shorten link-up so the MSI test does not wait out the 400 ms default.
    defparam dut.u_bar0.LINK_UP_DELAY_CYCLES = 32'd40;

    always @(posedge ft601_clk) begin
        if (!user_reset && !rxf_n && !rd_n)
            rx_index <= rx_index + 1;
        if (!user_reset && !txe_n && !wr_n) begin
            tx_mem[tx_index] <= bus_data;
            tx_index <= tx_index + 1;
        end
    end

    // Sample registered TX beats. Blocking updates are visible by the next negedge.
    always @(posedge user_clk) begin
        if (tx_cap_en && tx_valid && tx_ready && tx_beat_n < 8) begin
            tx_beat[tx_beat_n]      = tx_data;
            tx_beat_keep[tx_beat_n] = tx_keep;
            tx_beat_last[tx_beat_n] = tx_last;
            tx_beat_n               = tx_beat_n + 1;
        end
    end

    task automatic host_memwr(input logic [31:0] addr,
                              input logic [31:0] data,
                              input logic [3:0]  first_be);
        @(negedge user_clk);
        rx_valid <= 1'b1;
        rx_last  <= 1'b0;
        rx_keep  <= 8'hff;
        rx_data  <= {16'h1234, 8'h01, 4'h0, first_be, 32'h6000_0001};
        @(negedge user_clk);
        rx_data  <= {addr, 32'h0};
        @(negedge user_clk);
        rx_data  <= {32'h0, data};
        rx_keep  <= 8'h0f;
        rx_last  <= 1'b1;
        @(negedge user_clk);
        rx_valid <= 1'b0;
        rx_last  <= 1'b0;
        rx_keep  <= 8'h00;
        rx_data  <= 64'h0;
    endtask

    task automatic host_memrd(input logic [7:0] tag, input logic [31:0] addr);
        @(negedge user_clk);
        rx_valid <= 1'b1;
        rx_last  <= 1'b0;
        rx_keep  <= 8'hff;
        rx_data  <= {16'h1234, tag, 8'h0f, 32'h2000_0001};
        @(negedge user_clk);
        rx_data  <= {addr, 32'h0};
        rx_last  <= 1'b1;
        @(negedge user_clk);
        rx_valid <= 1'b0;
        rx_last  <= 1'b0;
        rx_data  <= 64'h0;
    endtask

    task automatic expect_bar_beat(input logic [63:0] data, input logic last);
        int guard;
        guard = 0;
        do begin
            @(negedge user_clk);
            guard++;
            if (guard > 40) $fatal(1, "Timed out waiting for BAR completion");
        end while (!tx_valid);
        if ({tx_valid, tx_data, tx_keep, tx_last} !== {1'b1, data, 8'hff, last})
            $fatal(1, "BAR beat got %h keep %h last %b, expected %h last %b",
                   tx_data, tx_keep, tx_last, data, last);
    endtask

    task automatic send_cpld(input logic [7:0] tag,
                             input logic [31:0] word0,
                             input int ndw);
        logic [31:0] extra1, extra2, extra3;
        int guard;
        extra1 = 32'h2222_0002;
        extra2 = 32'h3333_0003;
        extra3 = 32'h4444_0004;
        @(negedge user_clk);
        rx_valid <= 1'b1;
        rx_last  <= 1'b0;
        rx_keep  <= 8'hff;
        // Beat 0: {DW1, DW0}. Must be forwarded; a stale class drops it.
        rx_data  <= {16'hABCD, 3'b000, 1'b0, (ndw[11:0] * 12'd4),
                     32'h4A00_0000 | ndw[9:0]};
        @(negedge user_clk);
        // Beat 1: {first data DW, DW2}. DW2 carries the tag.
        rx_data  <= {word0, 16'h0200, tag, 8'h00};
        rx_last  <= (ndw <= 1);
        if (ndw > 1) begin
            @(negedge user_clk);
            rx_data <= {extra2, extra1};
            rx_last <= 1'b0;
            @(negedge user_clk);
            rx_data <= {32'h0, extra3};
            rx_keep <= 8'h0f;
            rx_last <= 1'b1;
        end
        @(negedge user_clk);
        rx_valid <= 1'b0;
        rx_last  <= 1'b0;
        rx_keep  <= 8'hff;
        rx_data  <= 64'h0;
        guard = 0;
        while (dut.u_dma.status_q[0] !== 1'b0) begin
            @(posedge user_clk);
            guard++;
            if (guard > 40)
                $fatal(1, "dma_engine stayed BUSY after CplD (tag %h, %0d DW)", tag, ndw);
        end
    endtask

    task automatic queue_word(input logic [31:0] w);
        rx_mem[rx_len] = w;
        rx_len = rx_len + 1;
    endtask

    task automatic usb_write(input logic [31:0] addr, input logic [31:0] data);
        int guard;
        queue_word(MAGIC);
        queue_word({opc_encode(OPC_WRITE), 8'h00, 16'd1});
        queue_word(addr);
        queue_word(data);
        guard = 0;
        while (rx_index < rx_len) begin
            @(posedge ft601_clk);
            guard++;
            if (guard > 400) $fatal(1, "USB write was not consumed");
        end
        repeat (8) @(posedge ft601_clk);
    endtask

    task automatic usb_read(input logic [31:0] addr, output logic [31:0] data);
        int base, guard;
        base = tx_index;
        queue_word(MAGIC);
        queue_word({opc_encode(OPC_READ), 8'h00, 16'd0});
        queue_word(addr);
        guard = 0;
        while (rx_index < rx_len) begin
            @(posedge ft601_clk);
            guard++;
            if (guard > 400) $fatal(1, "USB read command was not consumed");
        end
        txe_n = 1'b0;
        guard = 0;
        while (tx_index < base + 4) begin
            @(posedge ft601_clk);
            guard++;
            if (guard > 800) $fatal(1, "USB read response timed out at %0d", tx_index);
        end
        txe_n = 1'b1;
        if (tx_mem[base] !== MAGIC)
            $fatal(1, "USB response magic %h", tx_mem[base]);
        if (tx_mem[base+2] !== addr)
            $fatal(1, "USB response addr %h expected %h", tx_mem[base+2], addr);
        data = tx_mem[base+3];
    endtask

    task automatic wait_dma_idle;
        int guard;
        guard = 0;
        while (dut.dma_hold_req !== 1'b0 || dut.u_dma.status_q[0] !== 1'b0) begin
            @(posedge user_clk);
            guard++;
            if (guard > 200)
                $fatal(1, "DMA idle timeout status=%h hold=%b",
                       dut.u_dma.status_q, dut.dma_hold_req);
        end
    endtask

    task automatic capture_beats(input int nbeats);
        int guard;
        @(negedge user_clk);
        tx_beat_n = 0;
        tx_cap_en = 1'b1;
        guard = 0;
        while (tx_beat_n < nbeats) begin
            @(negedge user_clk);
            guard++;
            if (guard > 400)
                $fatal(1, "Timed out waiting for %0d TX beats (got %0d)", nbeats, tx_beat_n);
        end
        tx_cap_en = 1'b0;
    endtask

    task automatic check_dw1_be(input logic [63:0] beat);
        if (beat[35:32] !== 4'hF || beat[39:36] !== 4'h0)
            $fatal(1, "DW1 byte enables are %h (First BE [3:0]=%h Last BE [7:4]=%h), expected First=F Last=0",
                   beat[39:32], beat[35:32], beat[39:36]);
    endtask

    task automatic dma_launch(input logic [31:0] ctrl, input int nbeats);
        fork
            capture_beats(nbeats);
            usb_write(CTRL, ctrl);
        join
    endtask

    initial begin
        logic [31:0] rd;
        logic [7:0]  tag;
        int guard;

        rx_data = '0;
        rx_keep = 8'h00;
        rx_valid = 1'b0;
        rx_last = 1'b0;
        tx_ready = 1'b1;
        completer_id = 16'h0200;
        cfg_interrupt_rdy = 1'b0;
        cfg_msienable = 1'b1;
        cfg_mmenable = 3'd0;
        txe_n = 1'b1;
        rx_len = 0;
        rx_index = 0;
        tx_index = 0;
        tx_cap_en = 1'b0;
        tx_beat_n = 0;

        repeat (4) @(negedge user_clk);
        user_reset = 1'b0;

        // ----------------------------------------------------------------
        // MSI: mask link-status, then the BAR0 pulse must assert vector 0.
        // ----------------------------------------------------------------
        repeat (2) @(negedge user_clk);
        if (cfg_interrupt !== 1'b0)
            $fatal(1, "cfg_interrupt high before the link-up event");
        host_memwr(32'h0000_003C, 32'h0000_0004, 4'hF);
        guard = 0;
        while (cfg_interrupt !== 1'b1) begin
            @(posedge user_clk);
            guard++;
            if (guard > 200) $fatal(1, "MSI cfg_interrupt never asserted");
        end
        if (cfg_interrupt_di !== 8'h00)
            $fatal(1, "MSI vector %h, expected 0", cfg_interrupt_di);
        if (cfg_interrupt_assert !== 1'b0)
            $fatal(1, "cfg_interrupt_assert set for MSI");
        @(negedge user_clk);
        cfg_interrupt_rdy = 1'b1;
        @(negedge user_clk);
        cfg_interrupt_rdy = 1'b0;
        repeat (4) @(posedge user_clk);
        if (cfg_interrupt !== 1'b0)
            $fatal(1, "cfg_interrupt stayed high after cfg_interrupt_rdy");
        $display("PASS: MSI vector 0 asserts from BAR0 irq_pulse and clears on rdy");

        // ----------------------------------------------------------------
        // BAR0 MemWr payload + First BE, checked by a MemRd completion.
        // ----------------------------------------------------------------
        host_memwr(32'h0000_0040, 32'hA1B2_C3D4, 4'hF);
        repeat (4) @(negedge user_clk);
        if (tx_valid) $fatal(1, "Posted MemWr produced a completion");
        host_memrd(8'h11, 32'h0000_0040);
        expect_bar_beat(64'h0200_0004_4a00_0001, 1'b0);
        expect_bar_beat(64'hA1B2_C3D4_1234_1140, 1'b1);
        $display("PASS: BAR0 MemWr payload updates TXCONFIG and reads back");

        host_memwr(32'h0000_0040, 32'hFFFF_FF5A, 4'h1);
        repeat (4) @(negedge user_clk);
        host_memrd(8'h12, 32'h0000_0040);
        expect_bar_beat(64'h0200_0004_4a00_0001, 1'b0);
        // Only byte 0 changes: 0xA1B2C3D4 -> 0xA1B2C35A. Lower address is 0x40.
        expect_bar_beat(64'hA1B2_C35A_1234_1240, 1'b1);
        $display("PASS: BAR0 MemWr First BE writes only the enabled byte");

        // ----------------------------------------------------------------
        // DMA MemRd / MemWr byte enables and CplD completion.
        // ----------------------------------------------------------------
        usb_write(ADDR_LO, 32'h0000_1000);
        usb_write(ADDR_HI, 32'h0000_0002);
        usb_write(WDATA,   32'h55AA_33CC);

        dma_launch(32'h1, 2); // GO_READ
        check_dw1_be(tx_beat[0]);
        if (tx_beat[0][31:0] !== 32'h2000_0001 || tx_beat[0][63:48] !== 16'h0200)
            $fatal(1, "MemRd beat0 %h", tx_beat[0]);
        if (tx_beat[1] !== 64'h0000_1000_0000_0002 || tx_beat_last[1] !== 1'b1)
            $fatal(1, "MemRd beat1 %h last %b", tx_beat[1], tx_beat_last[1]);
        tag = tx_beat[0][47:40];
        send_cpld(tag, 32'hCAFE_0001, 1);
        if (dut.u_dma.status_q !== 32'h2 || dut.u_dma.rdata_q !== 32'hCAFE_0001)
            $fatal(1, "1-DW CplD status %h rdata %h", dut.u_dma.status_q, dut.u_dma.rdata_q);
        usb_read(STATUS, rd);
        if (rd !== 32'h2) $fatal(1, "USB STATUS after 1-DW CplD is %h", rd);
        usb_read(RDATA, rd);
        if (rd !== 32'hCAFE_0001) $fatal(1, "USB RDATA after 1-DW CplD is %h", rd);
        $display("PASS: 1-DW CplD tag %h returns STATUS=DONE RDATA=CAFE0001", tag);
        $display("PASS: MemRd DW1 First BE=F Last BE=0");

        wait_dma_idle();
        dma_launch(32'h1, 2);
        check_dw1_be(tx_beat[0]);
        tag = tx_beat[0][47:40];
        send_cpld(tag, 32'h1111_0001, 4);
        if (dut.u_dma.status_q !== 32'h2 || dut.u_dma.rdata_q !== 32'h1111_0001)
            $fatal(1, "multi-DW CplD status %h rdata %h", dut.u_dma.status_q, dut.u_dma.rdata_q);
        usb_read(STATUS, rd);
        if (rd !== 32'h2) $fatal(1, "USB STATUS after multi-DW CplD is %h", rd);
        usb_read(RDATA, rd);
        if (rd !== 32'h1111_0001) $fatal(1, "USB RDATA after multi-DW CplD is %h", rd);
        $display("PASS: multi-DW CplD keeps beat1 tag/data and drains to tlast");

        wait_dma_idle();
        dma_launch(32'h1, 2);
        tag = tx_beat[0][47:40];
        send_cpld(tag ^ 8'hFF, 32'hDEAD_DEAD, 1);
        if (dut.u_dma.status_q !== 32'h4 || dut.u_dma.rdata_q !== 32'h1111_0001)
            $fatal(1, "tag mismatch status %h rdata %h", dut.u_dma.status_q, dut.u_dma.rdata_q);
        usb_read(STATUS, rd);
        if (rd !== 32'h4) $fatal(1, "USB STATUS after tag mismatch is %h", rd);
        $display("PASS: CplD tag mismatch sets STATUS.ERR and keeps RDATA");

        wait_dma_idle();
        dma_launch(32'h2, 3); // GO_WRITE
        check_dw1_be(tx_beat[0]);
        if (tx_beat[0][31:0] !== 32'h6000_0001)
            $fatal(1, "MemWr DW0 %h", tx_beat[0][31:0]);
        if (tx_beat[1] !== 64'h0000_1000_0000_0002 || tx_beat_last[1] !== 1'b0)
            $fatal(1, "MemWr beat1 %h last %b", tx_beat[1], tx_beat_last[1]);
        if (tx_beat[2] !== 64'h0000_0000_55AA_33CC || tx_beat_last[2] !== 1'b1 ||
            tx_beat_keep[2] !== 8'h0F)
            $fatal(1, "MemWr payload %h keep %h last %b",
                   tx_beat[2], tx_beat_keep[2], tx_beat_last[2]);
        guard = 0;
        while (dut.u_dma.status_q !== 32'h2) begin
            @(posedge user_clk);
            guard++;
            if (guard > 20) $fatal(1, "MemWr did not reach DONE (status %h)", dut.u_dma.status_q);
        end
        usb_read(STATUS, rd);
        if (rd !== 32'h2) $fatal(1, "USB STATUS after MemWr is %h", rd);
        $display("PASS: MemWr DW1 First BE=F Last BE=0 and payload beat is wdata");

        $display("PASS: endpoint integration checks");
        $finish;
    end

    initial begin
        #500_000;
        $fatal(1, "integration test timed out");
    end
endmodule
