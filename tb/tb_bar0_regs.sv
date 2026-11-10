// r8125 BAR map: ChipCmd 0x37, TxPoll 0x38, IntrStatus 0x3e, PHYAR 0x60.
`timescale 1ns/1ps

module tb_bar0_regs;
    import rtl8125b_identity_pkg::*;

    logic clk = 0;
    always #4 clk = ~clk;
    logic rst_n = 0;
    logic wr = 0, rd = 0, rvalid, irq;
    logic [15:0] addr = 0;
    logic [31:0] wdata = 0, rdata;
    logic [3:0]  be = 4'hF;

    rtl8125b_bar0_regs #(.LINK_UP_DELAY_CYCLES(8), .ENABLE_SHADOW(1'b1)) dut (
        .clk(clk), .rst_n(rst_n),
        .mem_wr_en(wr), .mem_rd_en(rd),
        .mem_byte_addr(addr), .mem_wdata(wdata), .mem_be(be),
        .mem_rdata(rdata), .mem_rvalid(rvalid),
        .tx_desc_ring_level(16'h0), .rx_desc_ring_level(16'h0),
        .irq_pulse(irq)
    );

    integer errors = 0;
    logic [31:0] got;

    task automatic write_be(input logic [15:0] a, input logic [31:0] d, input logic [3:0] b);
        @(negedge clk);
        wr = 1; addr = a; wdata = d; be = b;
        @(negedge clk);
        wr = 0;
    endtask

    task automatic read_dw(input logic [15:0] a, output logic [31:0] d);
        @(negedge clk);
        rd = 1; addr = a;
        @(negedge clk);
        rd = 0;
        wait (rvalid);
        d = rdata;
        @(negedge clk);
    endtask

    initial begin
        $dumpfile("tb_bar0_regs.vcd");
        $dumpvars(0, tb_bar0_regs);
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        read_dw(16'h00, got);
        if (got !== {MAC_ADDR[23:16], MAC_ADDR[31:24], MAC_ADDR[39:32], MAC_ADDR[47:40]}) begin
            $display("FAIL MAC0 %h", got); errors++;
        end
        if (MAC_ADDR[47:24] !== 24'h00E04C) begin
            $display("FAIL MAC OUI"); errors++;
        end
        if (MAC_ADDR === 48'h0012_3456_0000 || MAC_ADDR === 48'h0) begin
            $display("FAIL MAC is placeholder"); errors++;
        end

        read_dw(16'h40, got);
        if ((got & 32'h7CF0_0000) !== 32'h64A0_0000) begin
            $display("FAIL TxConfig chip id %h", got); errors++;
        end

        // ChipCmd at byte 0x37 = DW 0x34 byte 3
        write_be(16'h34, 32'h0C00_0000, 4'b1000);
        read_dw(16'h34, got);
        if (got[31:24] !== 8'h0C) begin
            $display("FAIL ChipCmd 0x37 readback %h", got); errors++;
        end

        // TxPoll 0x38 self-clears after the write cycle
        write_be(16'h38, 32'h0000_0040, 4'b0001);
        @(negedge clk);
        read_dw(16'h38, got);
        if (got[7:0] !== 8'h00) begin
            $display("FAIL TxPoll did not self-clear %h", got); errors++;
        end

        // IntrMask 0x3C / IntrStatus 0x3E
        write_be(16'h3C, 32'h0000_0020, 4'b0011);
        read_dw(16'h3C, got);
        if (got[15:0] !== 16'h0020) begin
            $display("FAIL IntrMask %h", got); errors++;
        end

        // Wait for simulated link-up so IntrStatus.LinkChg sets
        repeat (16) @(negedge clk);
        read_dw(16'h3C, got);
        if (got[31:16] !== 16'h0020) begin
            $display("FAIL IntrStatus LinkChg %h", got); errors++;
        end

        // PHYAR 0x60: write Flag=1, wait for Flag=0
        write_be(16'h60, 32'h8000_0000 | (5'd0 << 16) | 16'h1140, 4'hF);
        repeat (20) @(negedge clk);
        read_dw(16'h60, got);
        if (got[31] !== 1'b0) begin
            $display("FAIL PHYAR write Flag stuck %h", got); errors++;
        end
        write_be(16'h60, (5'd2 << 16), 4'hF);  // read PHYID1
        repeat (20) @(negedge clk);
        read_dw(16'h60, got);
        if (got[31] !== 1'b1 || got[15:0] !== 16'h001C) begin
            $display("FAIL PHYAR read PHYID1 %h", got); errors++;
        end

        // Shadow RAM above the named window
        write_be(16'h100, 32'hDEAD_BEEF, 4'hF);
        read_dw(16'h100, got);
        if (got !== 32'hDEAD_BEEF) begin
            $display("FAIL shadow %h", got); errors++;
        end

        if (errors == 0) $display("PASS: r8125 BAR0 map ChipCmd/TxPoll/IntrStatus/PHYAR");
        else $fatal(1, "%0d BAR0 failures", errors);
        $finish;
    end

    initial #50_000 $fatal(1, "tb_bar0_regs timeout");
endmodule
