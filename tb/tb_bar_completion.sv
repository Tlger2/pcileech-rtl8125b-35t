`timescale 1ns/1ps
module tb_bar_completion;
    logic user_clk = 0, ft601_clk = 0;
    always #8 user_clk = ~user_clk;
    always #5 ft601_clk = ~ft601_clk;
    logic user_reset = 1;
    logic [63:0] tx_data, rx_data = '0;
    logic [7:0] tx_keep;
    logic tx_valid, tx_last, tx_ready = 1;
    logic rx_valid = 0, rx_last = 0;
    logic [15:0] completer_id = 16'h0200;

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
        .ft601_clk(ft601_clk), .ft601_rst_n(!user_reset), .ft601_rxf_n(1'b1),
        .ft601_oe_n(), .ft601_rd_n(), .ft601_wr_n(), .ft601_txe_n(1'b1),
        .ft601_data(), .ft601_be()
    );

    task automatic request_read(input logic [7:0] tag);
        @(negedge user_clk);
        rx_valid = 1;
        rx_data = {16'h1234, tag, 8'h0f, 32'h2000_0001};
        @(negedge user_clk);
        rx_data = 64'b0;
        rx_last = 1;
        @(negedge user_clk);
        rx_valid = 0;
        rx_last = 0;
    endtask

    task automatic expect_beat(input logic [63:0] data, input bit last, input bit stall);
        do @(negedge user_clk); while (!tx_valid);
        if (stall) begin
            repeat (3) begin
                if ({tx_valid, tx_data, tx_keep, tx_last} !== {1'b1, data, 8'hff, last})
                    $fatal(1, "BAR beat changed while stalled");
                @(negedge user_clk);
            end
        end
        tx_ready = 1;
        @(posedge user_clk);
        if ({tx_valid, tx_data, tx_keep, tx_last} !== {1'b1, data, 8'hff, last})
            $fatal(1, "Incorrect accepted BAR beat (last=%b, data=%h)", tx_last, tx_data);
    endtask

    initial begin
        repeat (4) @(negedge user_clk);
        user_reset = 0;
        request_read(8'h5a);
        expect_beat(64'h0200_0004_4a00_0001, 0, 0);
        expect_beat(64'h4c12_3456_1234_5a00, 1, 0);
        repeat (4) @(negedge user_clk);
        if (tx_valid) $fatal(1, "Unexpected duplicate completion");

        tx_ready = 0;
        request_read(8'h7b);
        expect_beat(64'h0200_0004_4a00_0001, 0, 1);
        // Deassert ready before the next rising edge. The final beat must
        // retain its data and TLAST even if the live completer ID changes.
        #1;
        tx_ready = 0;
        completer_id = 16'habcd;
        expect_beat(64'h4c12_3456_1234_7b00, 1, 1);
        repeat (4) @(negedge user_clk);
        if (tx_valid) $fatal(1, "Unexpected duplicate completion after a stall");
        $display("PASS: BAR completion delivers both beats with ready high or stalled");
        $finish;
    end

    initial #5000 $fatal(1, "Timed out waiting for the BAR completion");
endmodule
