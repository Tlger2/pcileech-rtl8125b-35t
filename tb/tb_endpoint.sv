// Self-checking testbench for ft601_cmd_parser and pcie_cpld_axis_tx_mux.
// XSim-compatible; no UVM, no interfaces.

`timescale 1ns / 1ps

import opcode_scramble_pkg::*;

module tb_endpoint;

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #4 clk = ~clk;  // 125 MHz

    int errors = 0;
    int checks = 0;

    // Sticky latches so a one-cycle combinational pulse on frame_done /
    // tx_done is never missed by an @(posedge …) that happens to arm after
    // the pulse has already resolved in the same timestep. Plain `always`
    // (not always_ff) because the initial block also clears these — the
    // multi-driver rule only bites inside always_ff. The driving `always`
    // block lives farther down, after frame_done and tx_done are declared
    // (XSim 2026.1 enforces declare-before-use inside procedural code).
    logic frame_done_sticky = 1'b0;
    logic tx_done_sticky    = 1'b0;

    `define CHECK(cond, msg)                                               \
        begin                                                              \
            checks++;                                                      \
            if (!(cond)) begin                                             \
                errors++;                                                  \
                $display("[%0t] FAIL #%0d: %s", $time, errors, msg);       \
            end else begin                                                 \
                $display("[%0t] PASS: %s", $time, msg);                    \
            end                                                            \
        end

    // ============== Phase A: ft601_cmd_parser =====================
    logic        fifo_rd_valid;
    logic        fifo_rd_ready;
    logic [31:0] fifo_rd_data;

    logic        rf_we, rf_re;
    logic [31:0] rf_waddr, rf_wdata, rf_raddr, rf_rdata;
    logic        rf_rvalid;

    logic        frame_start, frame_done, bad_opcode_err;
    logic [7:0]  last_opcode;
    logic [31:0] last_base_addr;

    ft601_cmd_parser u_parser (
        .clk           (clk),
        .rst_n         (rst_n),
        .fifo_rd_valid (fifo_rd_valid),
        .fifo_rd_ready (fifo_rd_ready),
        .fifo_rd_data  (fifo_rd_data),
        .rf_we         (rf_we),
        .rf_waddr      (rf_waddr),
        .rf_wdata      (rf_wdata),
        .rf_re         (rf_re),
        .rf_raddr      (rf_raddr),
        .rf_rdata      (rf_rdata),
        .rf_rvalid     (rf_rvalid),
        .frame_start   (frame_start),
        .frame_done    (frame_done),
        .bad_opcode_err(bad_opcode_err),
        .last_opcode   (last_opcode),
        .last_base_addr(last_base_addr)
    );

    logic [31:0] rf_mem [logic [31:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_rdata  <= 32'h0;
            rf_rvalid <= 1'b0;
        end else begin
            rf_rvalid <= 1'b0;
            if (rf_we) rf_mem[rf_waddr] = rf_wdata;
            if (rf_re) begin
                rf_rdata  <= rf_mem.exists(rf_raddr) ? rf_mem[rf_raddr] : 32'hBAADF00D;
                rf_rvalid <= 1'b1;
            end
        end
    end

    task automatic push_word(input logic [31:0] w);
        @(posedge clk);
        fifo_rd_valid <= 1'b1;
        fifo_rd_data  <= w;
        do @(posedge clk); while (!fifo_rd_ready);
        fifo_rd_valid <= 1'b0;
        fifo_rd_data  <= 32'h0;
    endtask

    task automatic send_frame(
        input logic [7:0]  canon_opc,
        input logic [7:0]  flags,
        input logic [15:0] length_dw,
        input logic [31:0] base_addr,
        input logic [31:0] payload[$]
    );
        logic [7:0] wire_opc;
        wire_opc = opc_encode(canon_opc);
        push_word(32'h5AA5_C33C);
        push_word({wire_opc, flags, length_dw});
        push_word(base_addr);
        foreach (payload[i]) push_word(payload[i]);
    endtask

    // ============== Phase B: pcie_cpld_axis_tx_mux ================
    logic [63:0] s_axis_rx_tdata;
    logic [7:0]  s_axis_rx_tkeep;
    logic        s_axis_rx_tvalid;
    logic        s_axis_rx_tready;
    logic        s_axis_rx_tlast;
    assign s_axis_rx_tready = 1'b1;

    logic [63:0] s_axis_tx_tdata;
    logic [7:0]  s_axis_tx_tkeep;
    logic        s_axis_tx_tvalid, s_axis_tx_tready, s_axis_tx_tlast;
    logic [3:0]  s_axis_tx_tuser;

    localparam int PAY_DEPTH = 32;
    logic [31:0] payload_mem [0:PAY_DEPTH-1];
    logic [9:0]  payload_len_dw;
    logic [4:0]  payload_rd_addr;
    logic        payload_rd_en;
    logic [31:0] payload_rd_data;

    always_ff @(posedge clk) begin
        if (payload_rd_en) payload_rd_data <= payload_mem[payload_rd_addr];
    end

    logic [31:0] hdr_dw0, hdr_dw1, hdr_dw2;
    logic        tx_start, tx_busy, tx_done;

    // Sticky-flag driver (declarations are at the top of the module).
    // Captures a one-cycle pulse on frame_done / tx_done so the test
    // sequencer can wait on it without racing against the pulse's fall.
    always @(posedge clk) begin
        if (frame_done) frame_done_sticky = 1'b1;
        if (tx_done)    tx_done_sticky    = 1'b1;
    end

    pcie_cpld_axis_tx_mux #(
        .LEN_W (10),
        .ADDR_W(5)
    ) u_tx_mux (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (tx_start),
        .busy            (tx_busy),
        .done            (tx_done),
        .hdr_dw0         (hdr_dw0),
        .hdr_dw1         (hdr_dw1),
        .hdr_dw2         (hdr_dw2),
        .payload_len_dw  (payload_len_dw),
        .payload_rd_addr (payload_rd_addr),
        .payload_rd_en   (payload_rd_en),
        .payload_rd_data (payload_rd_data),
        .s_axis_tx_tdata (s_axis_tx_tdata),
        .s_axis_tx_tkeep (s_axis_tx_tkeep),
        .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .s_axis_tx_tlast (s_axis_tx_tlast),
        .s_axis_tx_tuser (s_axis_tx_tuser),
        .s_axis_tx_tready(s_axis_tx_tready)
    );

    task automatic inject_mrd(
        input logic [15:0] req_id,
        input logic [7:0]  tag,
        input logic [3:0]  first_be,
        input logic [31:0] addr,
        input logic [9:0]  length_dw
    );
        logic [31:0] dw0, dw1, dw2;
        dw0 = {1'b0, 2'b00, 5'b00000, 1'b0, 3'b000,
               1'b0, 1'b0, 2'b00, 1'b0, 1'b0, 2'b00, 2'b00, length_dw};
        dw1 = {req_id, tag, 4'h0, first_be};
        dw2 = {addr[31:2], 2'b00};

        @(posedge clk);
        s_axis_rx_tdata  <= {dw1, dw0};
        s_axis_rx_tkeep  <= 8'hFF;
        s_axis_rx_tvalid <= 1'b1;
        s_axis_rx_tlast  <= 1'b0;

        @(posedge clk);
        s_axis_rx_tdata  <= {32'h0, dw2};
        s_axis_rx_tkeep  <= 8'h0F;
        s_axis_rx_tlast  <= 1'b1;

        @(posedge clk);
        s_axis_rx_tvalid <= 1'b0;
        s_axis_rx_tkeep  <= 8'h00;
        s_axis_rx_tlast  <= 1'b0;
        s_axis_rx_tdata  <= 64'h0;
    endtask

    logic [31:0] exp_tx_beats_lo [$];
    logic [31:0] exp_tx_beats_hi [$];
    logic [7:0]  exp_tx_tkeep    [$];
    logic        exp_tx_tlast    [$];
    int          beat_idx_mon;

    // NOTE: plain `always` (not always_ff) — the CHECK macro expands to
    // blocking `checks++` / `errors++`, and those counters are also written
    // from the initial/task context. Vivado 2026.1 rejects that combination
    // under always_ff's exclusive-driver + nonblocking-only rules.
    always @(posedge clk) begin
        if (s_axis_tx_tvalid && s_axis_tx_tready) begin
            automatic logic [31:0] got_lo = s_axis_tx_tdata[31:0];
            automatic logic [31:0] got_hi = s_axis_tx_tdata[63:32];
            if (beat_idx_mon < exp_tx_beats_lo.size()) begin
                `CHECK(got_lo == exp_tx_beats_lo[beat_idx_mon],
                       $sformatf("TX beat %0d lo DW", beat_idx_mon))
                `CHECK(got_hi == exp_tx_beats_hi[beat_idx_mon],
                       $sformatf("TX beat %0d hi DW", beat_idx_mon))
                `CHECK(s_axis_tx_tkeep == exp_tx_tkeep[beat_idx_mon],
                       $sformatf("TX beat %0d tkeep", beat_idx_mon))
                `CHECK(s_axis_tx_tlast == exp_tx_tlast[beat_idx_mon],
                       $sformatf("TX beat %0d tlast", beat_idx_mon))
            end
            beat_idx_mon++;
        end
    end

    initial begin
        $dumpfile("tb_endpoint.vcd");
        $dumpvars(0, tb_endpoint);

        fifo_rd_valid    = 1'b0;
        fifo_rd_data     = 32'h0;
        s_axis_rx_tdata  = 64'h0;
        s_axis_rx_tkeep  = 8'h00;
        s_axis_rx_tvalid = 1'b0;
        s_axis_rx_tlast  = 1'b0;
        s_axis_tx_tready = 1'b1;
        tx_start         = 1'b0;
        payload_len_dw   = 10'h0;
        hdr_dw0          = 32'h0;
        hdr_dw1          = 32'h0;
        hdr_dw2          = 32'h0;
        beat_idx_mon     = 0;

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("\n==== PHASE A: ft601_cmd_parser ====");
        begin
            logic [31:0] q[$];
            q = '{32'hDEAD_BEEF, 32'hCAFE_F00D, 32'h1234_5678, 32'hA5A5_5A5A};
            send_frame(OPC_WRITE_BURST, 8'h00, 16'd4, 32'h0000_1000, q);
            wait (frame_done_sticky); frame_done_sticky = 1'b0;
            @(posedge clk);
        end
        `CHECK(rf_mem.exists(32'h0000_1000) && rf_mem[32'h0000_1000] == 32'hDEAD_BEEF, "A.1 regfile[0x1000]")
        `CHECK(rf_mem.exists(32'h0000_1004) && rf_mem[32'h0000_1004] == 32'hCAFE_F00D, "A.1 regfile[0x1004]")
        `CHECK(rf_mem.exists(32'h0000_1008) && rf_mem[32'h0000_1008] == 32'h1234_5678, "A.1 regfile[0x1008]")
        `CHECK(rf_mem.exists(32'h0000_100C) && rf_mem[32'h0000_100C] == 32'hA5A5_5A5A, "A.1 regfile[0x100C]")
        `CHECK(last_opcode == OPC_WRITE_BURST, "A.1 last_opcode descrambled")
        `CHECK(last_base_addr == 32'h0000_1000, "A.1 last_base_addr")

        begin
            logic [31:0] q[$];
            send_frame(OPC_READ, 8'h00, 16'd0, 32'h0000_1004, q);
            wait (frame_done_sticky); frame_done_sticky = 1'b0;
            @(posedge clk);
        end
        `CHECK(last_opcode == OPC_READ, "A.2 last_opcode == OPC_READ")

        $display("\n==== PHASE B: pcie_cpld_axis_tx_mux ====");
        for (int i = 0; i < PAY_DEPTH; i++)
            payload_mem[i] = 32'hA000_0000 + i;

        begin
            localparam logic [15:0] REQ_ID   = 16'hABCD;
            localparam logic [7:0]  TAG      = 8'h42;
            localparam logic [3:0]  FIRST_BE = 4'hF;
            localparam logic [31:0] MRD_ADDR = 32'h2000_0040;
            localparam logic [9:0]  LEN      = 10'd4;
            automatic logic [11:0] bc;
            automatic logic [6:0]  la;

            fork
                inject_mrd(REQ_ID, TAG, FIRST_BE, MRD_ADDR, LEN);
            join_none

            bc = LEN * 4;
            la = MRD_ADDR[6:0];
            hdr_dw0 = {1'b0, 2'b10, 5'b01010, 1'b0, 3'b000,
                       1'b0, 1'b0, 2'b00, 1'b0, 1'b0, 2'b00, 2'b00, LEN};
            hdr_dw1 = {16'h0100, 3'b000, 1'b0, bc};
            hdr_dw2 = {REQ_ID, TAG, 1'b0, la};
            payload_len_dw = LEN;

            exp_tx_beats_lo.push_back(hdr_dw0);
            exp_tx_beats_hi.push_back(hdr_dw1);
            exp_tx_tkeep.push_back(8'hFF);
            exp_tx_tlast.push_back(1'b0);
            exp_tx_beats_lo.push_back(hdr_dw2);
            exp_tx_beats_hi.push_back(payload_mem[0]);
            exp_tx_tkeep.push_back(8'hFF);
            exp_tx_tlast.push_back(1'b0);
            exp_tx_beats_lo.push_back(payload_mem[1]);
            exp_tx_beats_hi.push_back(payload_mem[2]);
            exp_tx_tkeep.push_back(8'hFF);
            exp_tx_tlast.push_back(1'b0);
            exp_tx_beats_lo.push_back(payload_mem[3]);
            exp_tx_beats_hi.push_back(32'h0);
            exp_tx_tkeep.push_back(8'h0F);
            exp_tx_tlast.push_back(1'b1);

            beat_idx_mon = 0;
            @(posedge clk);
            tx_start <= 1'b1;
            @(posedge clk);
            tx_start <= 1'b0;

            fork
                begin : watchdog
                    repeat (200) @(posedge clk);
                    `CHECK(tx_done_sticky, "B.1 tx_done fired")
                end
                begin : wait_done
                    wait (tx_done_sticky);
                    tx_done_sticky = 1'b0;
                    disable watchdog;
                end
            join

            `CHECK(beat_idx_mon == 4, "B.1 emitted 4 TX beats")
        end

        $display("\n================================================");
        $display("TB SUMMARY : %0d checks, %0d failures", checks, errors);
        if (errors == 0) $display("RESULT     : ALL PASS");
        else             $display("RESULT     : %0d FAILURES", errors);
        $display("================================================\n");
        $finish;
    end

    initial begin
        #200_000;
        $display("TIMEOUT: TB exceeded 200us");
        $finish;
    end

endmodule
