`timescale 1ns/1ps
module tb_ft601_sfifo;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic ft601_rxf_n = 1, ft601_txe_n = 1;
    wire ft601_oe_n, ft601_rd_n, ft601_wr_n, ft601_siwu_n;
    tri [31:0] ft601_data;
    tri [3:0] ft601_be;
    wire fifo_rd_valid, fifo_wr_ready;
    wire [31:0] fifo_rd_data;
    logic fifo_rd_ready = 0, fifo_wr_valid = 0;
    logic [31:0] fifo_wr_data = 32'hCAFE_BEEF;
    logic [3:0] fifo_wr_be = 4'hB;
    int reads = 0, writes = 0;
    int wr_gap = 0;
    logic prev_oe_n = 1;
    logic prev_wr_n = 1;
    logic [31:0] written [0:7];
    logic burst_on = 0;
    int burst_n = 0;
    logic [31:0] burst_words [0:2] = '{32'hA1, 32'hA2, 32'hA3};

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
            if (!ft601_wr_n) begin
                if (writes == 0 && ft601_be !== 4'hB)
                    $fatal(1, "Queued TX beat lost its byte enables");
                if (writes < 8)
                    written[writes] <= ft601_data;
                writes <= writes + 1;
                if (prev_wr_n)
                    wr_gap <= wr_gap + 1;
            end
            if (ft601_siwu_n !== 1'b1)
                $fatal(1, "SIWU# must stay high; FT601 reserves that pin");
        end
        prev_oe_n <= ft601_oe_n;
        prev_wr_n <= ft601_wr_n;
    end

    // Present the next burst word on the cycle the current one is accepted.
    always @(posedge clk) begin
        if (burst_on && fifo_wr_valid && fifo_wr_ready) begin
            if (burst_n == 2)
                fifo_wr_valid <= 1'b0;
            else
                fifo_wr_data <= burst_words[burst_n + 1];
            burst_n <= burst_n + 1;
        end
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
        if (writes != 0 || reads != 1 || !fifo_rd_valid || fifo_rd_data !== 32'h1234_0000)
            $fatal(1, "Wrote while TXE# was high, or dropped the RX word");
        fifo_rd_ready = 1;
        ft601_txe_n = 0;
        wait (writes == 1 && reads == 2);
        @(negedge clk);
        ft601_rxf_n = 1;
        repeat (4) @(negedge clk);
        if (writes != 1 || reads != 2 || written[0] !== 32'hCAFE_BEEF)
            $fatal(1, "TXE# low did not commit the queued word once");

        // Three producer words must be one WR# burst. A gap is an underrun
        // and the host session returns only the first beat.
        fifo_wr_be = 4'hF;
        fifo_wr_data = 32'hA1;
        burst_on = 1;
        fifo_wr_valid = 1;
        wait (writes == 4);
        burst_on = 0;
        fifo_wr_valid = 0;
        repeat (4) @(negedge clk);
        if (writes != 4 || wr_gap != 2 || written[1] !== 32'hA1
            || written[2] !== 32'hA2 || written[3] !== 32'hA3)
            $fatal(1, "Multi-word frame was not one continuous WR# burst");
        $display("PASS: TXE# gate, RX hold, and back-to-back WR# burst");
        $finish;
    end

    initial #2000 $fatal(1, "FT601 test timed out");
endmodule
