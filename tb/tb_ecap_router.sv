// Donor ECAP chain + cfg_ext 1-cycle valid handshake (wrapper path).
`timescale 1ns/1ps

module tb_ecap_router;
    import rtl8125b_identity_pkg::*;

    logic clk = 0;
    always #4 clk = ~clk;
    logic rst_n = 0;

    logic        rd = 0, wr = 0;
    logic [9:0]  dwaddr = 0;
    logic [3:0]  be = 4'hF;
    logic [31:0] wdata = 0, rdata;

    pcie_ecap_router dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_rd_en(rd), .cfg_wr_en(wr),
        .cfg_dwaddr(dwaddr), .cfg_be(be),
        .cfg_wdata(wdata), .cfg_rdata(rdata)
    );

    logic        ext_read_received = 0;
    logic [31:0] ext_read_data = 0;
    logic        ext_read_data_valid = 0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ext_read_data       <= 32'h0;
            ext_read_data_valid <= 1'b0;
        end else begin
            ext_read_data_valid <= ext_read_received;
            if (ext_read_received)
                ext_read_data <= rdata;
        end
    end

    integer errors = 0;
    logic [31:0] got;

    task automatic peek(input logic [11:0] byte_off, output logic [31:0] d);
        @(negedge clk);
        dwaddr = byte_off[11:2];
        rd = 1;
        #1 d = rdata;
        @(negedge clk);
        rd = 0;
    endtask

    initial begin
        $dumpfile("tb_ecap_router.vcd");
        $dumpvars(0, tb_ecap_router);
        repeat (2) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        peek(12'h168, got);
        if (got[15:0] !== 16'h0003) begin
            $display("FAIL DSN cap id %h", got); errors++;
        end
        if (got[31:20] !== ECAP_TPH_BASE) begin
            $display("FAIL DSN next %h", got); errors++;
        end

        peek(12'h16C, got);
        if (got !== DSN_LO) begin
            $display("FAIL DSN_LO %h want %h", got, DSN_LO); errors++;
        end
        peek(12'h170, got);
        if (got !== DSN_HI) begin
            $display("FAIL DSN_HI %h want %h", got, DSN_HI); errors++;
        end
        if ({DSN_HI, DSN_LO} !== 64'h0000e04c7a3b9100) begin
            $display("FAIL packed DSN"); errors++;
        end

        peek(12'h178, got);
        if (got[15:0] !== 16'h0017) begin
            $display("FAIL TPH cap id %h", got); errors++;
        end
        peek(12'h204, got);
        if (got[15:0] !== 16'h0018) begin
            $display("FAIL LTR cap id %h", got); errors++;
        end
        peek(12'h20C, got);
        if (got[15:0] !== 16'h001E) begin
            $display("FAIL L1PM cap id %h", got); errors++;
        end
        peek(12'h21C, got);
        if (got[15:0] !== 16'h000B) begin
            $display("FAIL VSEC cap id %h", got); errors++;
        end

        peek(12'h100, got);
        if (got[15:0] !== 16'h0001) begin
            $display("FAIL AER cap id %h", got); errors++;
        end
        if (got[31:20] !== ECAP_VC_BASE) begin
            $display("FAIL AER next %h", got); errors++;
        end

        // cfg_ext handshake: pulse received, data valid next cycle.
        @(negedge clk);
        dwaddr = 10'h05A;  // 0x168
        rd = 1;
        ext_read_received = 1;
        @(posedge clk);
        @(negedge clk);
        rd = 0;
        ext_read_received = 0;
        if (!ext_read_data_valid || ext_read_data[15:0] !== 16'h0003) begin
            $display("FAIL cfg_ext handshake %b %h", ext_read_data_valid, ext_read_data);
            errors++;
        end

        if (errors == 0) $display("PASS: ECAP DSN 0000e04c7a3b9100 + cfg_ext valid");
        else $fatal(1, "%0d ecap failures", errors);
        $finish;
    end

    initial #50_000 $fatal(1, "tb_ecap_router timeout");
endmodule
