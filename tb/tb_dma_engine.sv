// Self-check: 1-DW and 32-DW (128 B) MemRd/MemWr, including split CplD gather.
`timescale 1ns/1ps

module tb_dma_engine;
    logic clk = 0;
    always #4 clk = ~clk;
    logic rst_n = 0;

    logic        rf_we = 0, rf_re = 0;
    logic [31:0] rf_waddr = 0, rf_wdata = 0, rf_raddr = 0, rf_rdata;
    logic        rf_rvalid;

    logic        tx_valid, tx_ready = 1, tx_last;
    logic [63:0] tx_data;
    logic [7:0]  tx_keep;

    logic        rx_valid = 0, rx_last = 0, rx_ready;
    logic [63:0] rx_data = 0;
    logic [7:0]  rx_keep = 8'hFF;

    dma_engine #(.MAX_BURST_DW(32)) dut (
        .user_clk(clk), .user_rst_n(rst_n),
        .rf_we(rf_we), .rf_waddr(rf_waddr), .rf_wdata(rf_wdata),
        .rf_re(rf_re), .rf_raddr(rf_raddr), .rf_rdata(rf_rdata), .rf_rvalid(rf_rvalid),
        .cfg_completer_id(16'h0100), .cfg_max_payload_size(3'd0),
        .tx_req_valid(tx_valid), .tx_req_ready(tx_ready),
        .tx_req_data(tx_data), .tx_req_keep(tx_keep), .tx_req_last(tx_last),
        .rx_cpl_valid(rx_valid), .rx_cpl_ready(rx_ready),
        .rx_cpl_data(rx_data), .rx_cpl_keep(rx_keep), .rx_cpl_last(rx_last),
        .dma_cpl_seen(), .dma_hold_req(1'b0)
    );

    task automatic poke(input logic [31:0] a, input logic [31:0] d);
        @(negedge clk);
        rf_we = 1; rf_waddr = a; rf_wdata = d;
        @(negedge clk);
        rf_we = 0;
    endtask

    task automatic peek(input logic [31:0] a, output logic [31:0] d);
        @(negedge clk);
        rf_re = 1; rf_raddr = a;
        @(posedge clk);
        @(negedge clk);
        rf_re = 0;
        if (!rf_rvalid)
            $fatal(1, "rf_rvalid not set for peek %h", a);
        d = rf_rdata;
    endtask

    task automatic wait_tx_beat(output logic [63:0] data, output logic last);
        integer guard;
        guard = 0;
        do begin
            @(negedge clk);
            guard++;
            if (guard > 200)
                $fatal(1, "timeout waiting for TX beat (valid=%b state=%0d pld_idx=%0d xfer=%0d)",
                       tx_valid, dut.state_q, dut.pld_idx_q, dut.xfer_len_q);
        end while (!tx_valid);
        data = tx_data;
        last = tx_last;
    endtask

    integer errors = 0;
    integer i;
    logic [63:0] beat;
    logic        last;
    logic [31:0] got, tag;
    logic [31:0] expect_mem [0:31];

    initial begin
        $dumpfile("tb_dma_engine.vcd");
        $dumpvars(0, tb_dma_engine);
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // ---- 32-DW MemWr: Length field must be 32, 16 payload beats ----
        for (i = 0; i < 32; i++)
            poke(32'h40 + (i * 4), 32'hA000_0000 + i);
        poke(32'h18, 32'd32);
        poke(32'h04, 32'h2000_1000);
        poke(32'h08, 32'h0000_0000);
        poke(32'h00, 32'h2);  // GO_WRITE

        wait_tx_beat(beat, last);
        if (beat[9:0] !== 10'd32) begin
            $display("FAIL: MWr Length=%0d want 32", beat[9:0]);
            errors++;
        end
        if (beat[31:29] !== 3'b011) begin
            $display("FAIL: MWr fmt/type high bits %b", beat[31:24]);
            errors++;
        end
        if (last) begin $display("FAIL: MWr H0 tlast"); errors++; end
        wait_tx_beat(beat, last);
        if (last) begin $display("FAIL: MWr H1 tlast"); errors++; end
        for (i = 0; i < 16; i++) begin
            wait_tx_beat(beat, last);
            if (beat[31:0] !== (32'hA000_0000 + 2*i) ||
                beat[63:32] !== (32'hA000_0000 + 2*i + 1)) begin
                $display("FAIL: MWr payload beat %0d = %h", i, beat);
                errors++;
            end
            if (last !== (i == 15)) begin
                $display("FAIL: MWr tlast on payload beat %0d", i);
                errors++;
            end
        end

        // ---- 32-DW MemRd + one CplD with 32 data DWs ----
        poke(32'h18, 32'd32);
        poke(32'h04, 32'h3000_0000);
        poke(32'h00, 32'h1);  // GO_READ
        wait_tx_beat(beat, last);
        if (beat[9:0] !== 10'd32) begin
            $display("FAIL: MRd Length=%0d want 32", beat[9:0]);
            errors++;
        end
        tag = beat[47:40];
        wait_tx_beat(beat, last);
        if (!last) begin $display("FAIL: MRd H1 should tlast"); errors++; end

        for (i = 0; i < 32; i++)
            expect_mem[i] = 32'hB000_0000 + i;

        @(negedge clk);
        // Beat 0 header
        rx_valid = 1; rx_last = 0; rx_keep = 8'hFF;
        rx_data = {16'h0100, tag[7:0], 8'h00, 32'h4A00_0020};
        @(negedge clk);
        // Beat 1 {data0, DW2}
        rx_data = {expect_mem[0], 16'h0100, tag[7:0], 8'h00};
        @(negedge clk);
        for (i = 0; i < 15; i++) begin
            rx_data = {expect_mem[2*i + 2], expect_mem[2*i + 1]};
            rx_last = 0;
            @(negedge clk);
        end
        // Last leftover DW 31 in the low half, keep 0F
        rx_data = {32'h0, expect_mem[31]};
        rx_keep = 8'h0F;
        rx_last = 1;
        @(negedge clk);
        rx_valid = 0; rx_last = 0; rx_keep = 8'hFF;

        repeat (8) @(negedge clk);
        peek(32'h10, got);
        if (got[1] !== 1'b1) begin
            $display("FAIL: STATUS DONE not set after 128 B CplD (status=%h)", got);
            errors++;
        end
        peek(32'h14, got);
        if (got !== expect_mem[0]) begin
            $display("FAIL: RDATA %h want %h", got, expect_mem[0]);
            errors++;
        end
        for (i = 0; i < 32; i++) begin
            peek(32'h40 + (i * 4), got);
            if (got !== expect_mem[i]) begin
                $display("FAIL: buf[%0d]=%h want %h", i, got, expect_mem[i]);
                errors++;
            end
        end

        // ---- Split CplD: 4 DW as 1+3 ----
        poke(32'h18, 32'd4);
        poke(32'h00, 32'h1);
        wait_tx_beat(beat, last);
        tag = beat[47:40];
        wait_tx_beat(beat, last);

        @(negedge clk);
        rx_valid = 1; rx_last = 0; rx_keep = 8'hFF;
        rx_data = {16'h0100, tag[7:0], 8'h00, 32'h4A00_0001};
        @(negedge clk);
        rx_data = {32'h1111_0001, 16'h0100, tag[7:0], 8'h00};
        rx_last = 1;
        @(negedge clk);
        rx_last = 0;
        rx_data = {16'h0100, tag[7:0], 8'h00, 32'h4A00_0003};
        @(negedge clk);
        rx_data = {32'h1111_0002, 16'h0100, tag[7:0], 8'h00};
        @(negedge clk);
        rx_data = {32'h1111_0004, 32'h1111_0003};
        rx_last = 1;
        @(negedge clk);
        rx_valid = 0; rx_last = 0;

        repeat (8) @(negedge clk);
        peek(32'h40, got);
        if (got !== 32'h1111_0001) begin $display("FAIL split[0]"); errors++; end
        peek(32'h44, got);
        if (got !== 32'h1111_0002) begin $display("FAIL split[1] %h", got); errors++; end
        peek(32'h48, got);
        if (got !== 32'h1111_0003) begin $display("FAIL split[2] %h", got); errors++; end
        peek(32'h4C, got);
        if (got !== 32'h1111_0004) begin $display("FAIL split[3] %h", got); errors++; end

        if (errors == 0) $display("PASS: dma_engine 128 B burst MRd/MWr + split CplD");
        else $display("RESULT: %0d FAILURES", errors);
        if (errors) $fatal(1);
        $finish;
    end

    initial #200_000 $fatal(1, "tb_dma_engine timeout");
endmodule
