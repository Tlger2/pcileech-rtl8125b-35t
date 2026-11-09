`timescale 1ns/1ps
module tb_ft601_sfifo;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic ft601_rxf_n = 1, ft601_txe_n = 1;
    wire ft601_oe_n, ft601_rd_n, ft601_wr_n;
    tri [31:0] ft601_data;
    tri [3:0] ft601_be;
    wire fifo_rd_valid, fifo_wr_ready;
    wire [31:0] fifo_rd_data;
    logic fifo_rd_ready = 0, fifo_wr_valid = 0;
    logic [31:0] fifo_wr_data = 32'hCAFE_BEEF;
    logic [3:0] fifo_wr_be = 4'hB;
    int reads = 0, writes = 0;
    logic prev_oe_n = 1;

    ft601_sfifo dut (.*);
    assign ft601_data = !ft601_oe_n ? (32'h1234_0000 + reads) : 32'bz;
    assign ft601_be = !ft601_oe_n ? 4'hF : 4'bz;

    always @(posedge clk) begin
        if (rst_n) begin
            if (!ft601_oe_n && !ft601_wr_n)
                $fatal(1, "Read and write overlap");
            if (!ft601_rd_n) begin
                if (prev_oe_n || ft601_oe_n || ft601_rxf_n)
                    $fatal(1, "Invalid FT601 read sequence");
                reads <= reads + 1;
            end
            if (!ft601_wr_n && !ft601_txe_n) begin
                if (ft601_data !== 32'hCAFE_BEEF || ft601_be !== 4'hB)
                    $fatal(1, "TX buffer did not preserve data and byte enables");
                writes <= writes + 1;
            end
        end
        prev_oe_n <= ft601_oe_n;
    end

    initial begin
        repeat (2) @(negedge clk);
        if ({ft601_oe_n, ft601_rd_n, ft601_wr_n} !== 3'b111 || fifo_rd_valid !== 1'b0)
            $fatal(1, "Reset did not idle the interface");
        rst_n = 1;
        ft601_rxf_n = 0;
        fifo_wr_valid = 1;
        @(posedge clk);
        if (!fifo_wr_ready) $fatal(1, "TX buffer unavailable after reset");
        @(negedge clk);
        fifo_wr_valid = 0;
        fifo_wr_data = '0;
        repeat (8) @(negedge clk);
        if (reads != 1 || writes != 0 || !fifo_rd_valid || fifo_rd_data !== 32'h1234_0000)
            $fatal(1, "Backpressure lost or duplicated a word");
        fifo_rd_ready = 1;
        ft601_txe_n = 0;
        wait (writes == 1 && reads == 2);
        @(negedge clk);
        ft601_rxf_n = 1;
        repeat (8) @(negedge clk);
        if (writes != 1 || reads != 2) $fatal(1, "Extra transfer");
        $display("PASS: reset, shared bus arbitration, RX hold, TX backpressure and byte enables");
        $finish;
    end

    initial #2000 $fatal(1, "FT601 test timed out");
endmodule
