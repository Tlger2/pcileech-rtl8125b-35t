`timescale 1ns/1ps
module tb_usb_response;
    import opcode_scramble_pkg::*;
    logic user_clk = 0, ft601_clk = 0;
    always #8 user_clk = ~user_clk;
    always #5 ft601_clk = ~ft601_clk;
    logic user_reset = 1;
    logic [63:0] tx_data, rx_data = '0;
    logic [7:0] tx_keep;
    logic tx_valid, tx_last, tx_ready = 1;
    logic rx_valid = 0, rx_last = 0;
    logic [15:0] completer_id = 16'h0200;

    localparam logic [31:0] MAGIC = 32'h5aa5_c33c;
    logic [31:0] request_words [0:11];
    logic [31:0] expected [0:9];
    int rx_index = 0, tx_index = 0;
    logic txe_n = 1;
    wire rxf_n = rx_index >= 12;
    wire oe_n, rd_n, wr_n;
    tri [31:0] bus_data;
    tri [3:0] bus_be;
    assign bus_data = !oe_n && !rxf_n ? request_words[rx_index] : 32'bz;
    assign bus_be = !oe_n && !rxf_n ? 4'hf : 4'bz;

    logic ft601_sample_clk = 0;
    always @(ft601_clk) ft601_sample_clk <= #5 ft601_clk;
    pcie_custom_endpoint_top dut (
        .user_clk(user_clk), .user_reset(user_reset), .user_lnk_up(1'b1),
        .s_axis_tx_tdata(tx_data), .s_axis_tx_tkeep(tx_keep),
        .s_axis_tx_tvalid(tx_valid), .s_axis_tx_tready(tx_ready),
        .s_axis_tx_tlast(tx_last), .s_axis_tx_tuser(),
        .m_axis_rx_tdata(rx_data), .m_axis_rx_tkeep(8'hff),
        .m_axis_rx_tvalid(rx_valid), .m_axis_rx_tready(),
        .m_axis_rx_tlast(rx_last), .m_axis_rx_tuser(22'b0),
        .cfg_completer_id(completer_id), .cfg_max_payload_size(3'b0),
        .cfg_max_read_req_size(3'b0), .link_speed_live(4'd2),
        .link_width_live(6'd1), .cfg_interrupt(), .cfg_interrupt_rdy(1'b0),
        .cfg_interrupt_assert(), .cfg_interrupt_di(),
        .cfg_interrupt_msienable(1'b0), .cfg_interrupt_mmenable(3'b0),
        .ft601_clk(ft601_clk), .ft601_rst_n(!user_reset), .ft601_rxf_n(rxf_n),
        .ft601_sample_clk(ft601_sample_clk),
        .ft601_oe_n(oe_n), .ft601_rd_n(rd_n), .ft601_wr_n(wr_n), .ft601_txe_n(txe_n),
        .ft601_data(bus_data), .ft601_be(bus_be)
    );

    always @(posedge ft601_clk) begin
        if (!user_reset && !rxf_n && !rd_n) rx_index <= rx_index + 1;
        if (!user_reset && !txe_n && !wr_n) begin
            if (tx_index >= 10 || bus_data !== expected[tx_index] || bus_be !== 4'hf)
                $fatal(1, "USB response word %0d was %h", tx_index, bus_data);
            tx_index <= tx_index + 1;
        end
    end

    initial begin
        request_words[0] = MAGIC;
        request_words[1] = {opc_encode(OPC_WRITE_BURST), 8'h00, 16'd3};
        request_words[2] = 32'h4;
        request_words[3] = 32'h11223344;
        request_words[4] = 32'h55667788;
        request_words[5] = 32'haabbccdd;
        request_words[6] = MAGIC;
        request_words[7] = {opc_encode(OPC_READ_BURST), 8'h00, 16'd3};
        request_words[8] = 32'h4;
        request_words[9] = MAGIC;
        request_words[10] = {opc_encode(OPC_READ), 8'h00, 16'd0};
        request_words[11] = 32'h8;
        expected[0] = MAGIC;
        expected[1] = request_words[7];
        expected[2] = 32'h4;
        expected[3] = request_words[3];
        expected[4] = request_words[4];
        expected[5] = request_words[5];
        expected[6] = MAGIC;
        expected[7] = {opc_encode(OPC_READ), 8'h00, 16'd1};
        expected[8] = 32'h8;
        expected[9] = request_words[4];

        repeat (10) @(negedge ft601_clk);
        user_reset = 0;
        repeat (100) @(negedge ft601_clk);
        txe_n = 0;
        wait (tx_index == 5);
        @(negedge ft601_clk);
        txe_n = 1;
        repeat (40) @(negedge ft601_clk);
        txe_n = 0;
        wait (tx_index == 10);
        repeat (40) @(negedge ft601_clk);
        $display("PASS: USB burst and single read responses survive FT601 backpressure");
        $finish;
    end

    initial #15000 $fatal(1, "USB response timed out after %0d input and %0d output words", rx_index, tx_index);
endmodule
