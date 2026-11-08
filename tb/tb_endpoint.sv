// Self-checking endpoint testbench: parser, CplD mux, config/BAR decode,
// and the RTL8125B operational BAR0 register footprint.
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

    // ============== Phase C: config space + cap chain ============
    logic        cfg_rd_en, cfg_wr_en;
    logic [5:0]  cfg_addr;
    logic [3:0]  cfg_be;
    logic [31:0] cfg_wdata, cfg_rdata;
    logic        cmd_mem_space_en;
    logic [63:0] bar0_base_64;
    logic [31:0] bar2_base_32;

    pci_cfg_space #(.USE_CAP_STUBS(1'b0)) u_cfg (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .cfg_rd_en             (cfg_rd_en),
        .cfg_wr_en             (cfg_wr_en),
        .cfg_addr              (cfg_addr),
        .cfg_be                (cfg_be),
        .cfg_wdata             (cfg_wdata),
        .cfg_rdata             (cfg_rdata),
        .cmd_mem_space_en      (cmd_mem_space_en),
        .cmd_bus_master_en     (),
        .cmd_intx_disable      (),
        .bar0_base_64          (bar0_base_64),
        .bar2_base_32          (bar2_base_32),
        .interrupt_line        (),
        .pm_power_state        (),
        .msi_enable            (),
        .msi_multi_msg_enable  (),
        .msi_address           (),
        .msi_data              (),
        .cfg_max_payload_size  (),
        .cfg_max_read_req_size (),
        .link_speed_live       (4'd2),
        .link_width_live       (6'd1)
    );

    task automatic cfg_write_dw(input logic [5:0] dw_idx,
                                input logic [31:0] data,
                                input logic [3:0] be);
        @(posedge clk);
        cfg_wr_en <= 1'b1;
        cfg_addr  <= dw_idx;
        cfg_wdata <= data;
        cfg_be    <= be;
        @(posedge clk);
        cfg_wr_en <= 1'b0;
        cfg_be    <= 4'h0;
    endtask

    task automatic cfg_read_dw(input logic [5:0] dw_idx,
                               output logic [31:0] data);
        @(posedge clk);
        cfg_rd_en <= 1'b1;
        cfg_addr  <= dw_idx;
        @(posedge clk);
        data = cfg_rdata;
        cfg_rd_en <= 1'b0;
    endtask

    // ============== Phase D: BAR decoder + MSE ==================
    logic [63:0] bar_tlp_addr;
    logic        bar_hit;
    logic [1:0]  bar_idx;
    logic [15:0] bar_offset_lo;

    pcie_bar_decoder u_bar_dec (
        .mse           (cmd_mem_space_en),
        .bar0_base_64  (bar0_base_64),
        .bar2_base_32  (bar2_base_32),
        .tlp_addr      (bar_tlp_addr),
        .bar_hit       (bar_hit),
        .bar_idx       (bar_idx),
        .bar_offset_lo (bar_offset_lo),
        .bar_offset_32 ()
    );

    // ============== Phase E: RTL8125B BAR0 registers ============
    logic        bar0_wr_en, bar0_rd_en;
    logic [15:0] bar0_addr;
    logic [31:0] bar0_wdata, bar0_rdata;
    logic [3:0]  bar0_wstrb;
    logic        bar0_rd_valid;
    logic [31:0] bar0_intr_set;
    logic        bar0_irq_pending;
    logic [47:0] bar0_mac_address;
    logic [63:0] bar0_tx_desc_base, bar0_txh_desc_base, bar0_rx_desc_base;
    logic [7:0]  bar0_chip_cmd;

    rtl8125b_bar0_regs #(
        .MAC_ADDR          (48'h02_12_25_35_00_01),
        .RESET_CLEAR_CYCLES(4)
    ) u_bar0_regs (
        .clk               (clk),
        .rst_n             (rst_n),
        .mmio_wr_en        (bar0_wr_en),
        .mmio_rd_en        (bar0_rd_en),
        .mmio_addr         (bar0_addr),
        .mmio_wdata        (bar0_wdata),
        .mmio_wstrb        (bar0_wstrb),
        .mmio_rdata        (bar0_rdata),
        .mmio_rd_valid     (bar0_rd_valid),
        .intr_set          (bar0_intr_set),
        .irq_pending       (bar0_irq_pending),
        .mac_address       (bar0_mac_address),
        .tx_desc_base      (bar0_tx_desc_base),
        .tx_high_desc_base (bar0_txh_desc_base),
        .rx_desc_base      (bar0_rx_desc_base),
        .chip_cmd          (bar0_chip_cmd)
    );

    task automatic bar0_write_dw(input logic [15:0] addr,
                                 input logic [31:0] data,
                                 input logic [3:0] strb);
        @(posedge clk);
        bar0_wr_en <= 1'b1;
        bar0_addr  <= addr;
        bar0_wdata <= data;
        bar0_wstrb <= strb;
        @(posedge clk);
        bar0_wr_en <= 1'b0;
        bar0_wstrb <= 4'h0;
    endtask

    task automatic bar0_read_dw(input logic [15:0] addr,
                                output logic [31:0] data);
        @(posedge clk);
        bar0_rd_en <= 1'b1;
        bar0_addr  <= addr;
        @(posedge clk);
        data = bar0_rdata;
        bar0_rd_en <= 1'b0;
    endtask

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
        cfg_rd_en        = 1'b0;
        cfg_wr_en        = 1'b0;
        cfg_addr         = 6'h0;
        cfg_be           = 4'h0;
        cfg_wdata        = 32'h0;
        bar_tlp_addr     = 64'h0;
        bar0_wr_en        = 1'b0;
        bar0_rd_en        = 1'b0;
        bar0_addr         = 16'h0;
        bar0_wdata        = 32'h0;
        bar0_wstrb        = 4'h0;
        bar0_intr_set     = 32'h0;

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

        // =============================================================
        // PHASE C — Config space capability chain walk
        //
        // Walks exactly the way an OS driver does:
        //   1. Read DW 0x01 Status[4] -> Capabilities List bit must be 1.
        //   2. Read DW 0x0D (byte 0x34) -> CAP_PTR byte 0 must be 0x40.
        //   3. Read DW 16 (byte 0x40) -> PM cap: CAP_ID=0x01, Next=0x50.
        //   4. Read DW 20 (byte 0x50) -> MSI cap: CAP_ID=0x05, Next=0x70.
        //   5. Read DW 28 (byte 0x70) -> PCIe cap: CAP_ID=0x10, Next=0x00.
        // =============================================================
        $display("\n==== PHASE C: cap chain walk ====");
        begin
            logic [31:0] dw;
            logic [7:0]  cap_ptr, cap_id, next_ptr;

            // C.1 Check identity DW
            cfg_read_dw(6'd0, dw);
            `CHECK(dw == 32'h8125_10EC, "C.1 DW0 = DID_8125 | VID_10EC")

            // C.2 Status bit [4] Capabilities List
            cfg_read_dw(6'd1, dw);
            `CHECK(dw[16+4] == 1'b1, "C.2 Status[4] Capabilities List = 1")

            // C.3 Class Code / Rev ID
            cfg_read_dw(6'd2, dw);
            `CHECK(dw == 32'h0200_0036,
                   "C.3 DW2 = Class 0x020000 | Rev 0x36")

            // C.4 Subsys ID
            cfg_read_dw(6'd11, dw);
            `CHECK(dw == 32'h0123_10EC, "C.4 Subsys ID = 0x0123_10EC")

            // C.5 CapPtr at byte 0x34
            cfg_read_dw(6'd13, dw);
            cap_ptr = dw[7:0];
            `CHECK(cap_ptr == 8'h40, "C.5 CapPtr at 0x34 = 0x40")

            // C.6 PM cap at 0x40 (DW 16)
            cfg_read_dw(6'd16, dw);
            cap_id   = dw[7:0];
            next_ptr = dw[15:8];
            `CHECK(cap_id   == 8'h01, "C.6 PM CapID = 0x01")
            `CHECK(next_ptr == 8'h50, "C.6 PM NextPtr = 0x50")

            // C.7 MSI cap at 0x50 (DW 20)
            cfg_read_dw(6'd20, dw);
            cap_id   = dw[7:0];
            next_ptr = dw[15:8];
            `CHECK(cap_id   == 8'h05, "C.7 MSI CapID = 0x05")
            `CHECK(next_ptr == 8'h70, "C.7 MSI NextPtr = 0x70")
            // MSI 64-bit capable bit
            `CHECK(dw[16+7] == 1'b1, "C.7 MSI 64-bit capable = 1")

            // C.8 PCIe cap at 0x70 (DW 28)
            cfg_read_dw(6'd28, dw);
            cap_id   = dw[7:0];
            next_ptr = dw[15:8];
            `CHECK(cap_id   == 8'h10, "C.8 PCIe CapID = 0x10")
            `CHECK(next_ptr == 8'h00, "C.8 PCIe NextPtr = 0x00 (end)")
            // PCIe Cap Reg: version=2, type=0 (endpoint)
            `CHECK(dw[16+3:16+0] == 4'h2, "C.8 PCIe Cap version = 2")
            `CHECK(dw[16+7:16+4] == 4'h0, "C.8 PCIe Device/Port Type = 0 (EP)")
        end

        // =============================================================
        // PHASE D — MSE enforcement in the BAR decoder
        //
        //   1. After reset, MSE=0 and BARs=0. No in-range address hits.
        //   2. Program BAR0 base (low=0xF000_0000) via config writes.
        //   3. With MSE still 0, address in the BAR0 window -> no hit.
        //   4. Set MSE=1 by writing Command register bit 1 -> hit.
        //   5. Clear MSE back to 0 -> no hit again.
        //   6. BAR2 programmed and in-range only hits when MSE=1.
        // =============================================================
        $display("\n==== PHASE D: MSE enforcement ====");
        begin
            // D.1 Post-reset: no MSE, no BAR hit
            bar_tlp_addr = 64'hF000_0000;
            #1;
            `CHECK(bar_hit == 1'b0, "D.1 reset: MSE=0, BAR=0 -> no hit")

            // D.2 Program BAR0 low to 0xF000_0000 (64-bit pair; keep high = 0)
            cfg_write_dw(6'd4, 32'hF000_000C, 4'hF);  // BAR0 low (attribute bits preserved)
            cfg_write_dw(6'd5, 32'h0000_0000, 4'hF);  // BAR1 upper = 0
            bar_tlp_addr = 64'h0000_0000_F000_1234;
            #1;
            `CHECK(bar_hit == 1'b0, "D.2 BAR0 programmed, MSE=0 -> still no hit")

            // D.3 Set MSE (Command bit 1) and parent Memory Space
            cfg_write_dw(6'd1, 32'h0000_0002, 4'hF);  // Command = MSE only
            @(posedge clk); @(posedge clk);
            `CHECK(cmd_mem_space_en == 1'b1, "D.3 MSE latched high")
            bar_tlp_addr = 64'h0000_0000_F000_1234;
            #1;
            `CHECK(bar_hit == 1'b1, "D.3 MSE=1 + BAR0 in range -> hit")
            `CHECK(bar_idx == 2'd0, "D.3 hit on BAR0")
            `CHECK(bar_offset_lo == 16'h1234, "D.3 offset = 0x1234")

            // D.4 Out-of-range address -> no hit even with MSE=1
            bar_tlp_addr = 64'h0000_0000_E000_0000;
            #1;
            `CHECK(bar_hit == 1'b0, "D.4 out-of-range -> no hit")

            // D.5 Clear MSE -> no hit again
            cfg_write_dw(6'd1, 32'h0000_0000, 4'hF);  // Command = 0
            @(posedge clk); @(posedge clk);
            `CHECK(cmd_mem_space_en == 1'b0, "D.5 MSE cleared")
            bar_tlp_addr = 64'h0000_0000_F000_1234;
            #1;
            `CHECK(bar_hit == 1'b0, "D.5 MSE=0 again -> no hit")

            // D.6 BAR2 path — program BAR2 then re-enable MSE
            cfg_write_dw(6'd6, 32'hE000_0000, 4'hF);
            cfg_write_dw(6'd1, 32'h0000_0002, 4'hF);
            @(posedge clk); @(posedge clk);
            bar_tlp_addr = 64'h0000_0000_E000_0ABC;
            #1;
            `CHECK(bar_hit == 1'b1, "D.6 BAR2 hit with MSE=1")
            `CHECK(bar_idx == 2'd2, "D.6 hit index = BAR2")
            `CHECK(bar_offset_lo == 16'h0ABC, "D.6 BAR2 offset = 0xABC")
        end

        // =============================================================
        // PHASE E — RTL8125B driver-initialization register footprint
        // =============================================================
        $display("\n==== PHASE E: RTL8125B BAR0 registers ====");
        begin
            logic [31:0] dw;

            // E.1 Stable EEPROM-style MAC contents in MMIO byte order.
            bar0_read_dw(16'h0000, dw);
            `CHECK(dw == 32'h3525_1202, "E.1 MAC0 bytes 02:12:25:35")
            bar0_read_dw(16'h0004, dw);
            `CHECK(dw[15:0] == 16'h0100, "E.1 MAC4 bytes 00:01")
            `CHECK(bar0_mac_address == 48'h02_12_25_35_00_01,
                   "E.1 canonical MAC output")

            // E.2 Linux r8169 derives XID=(TxConfig>>20)&0xFCF.
            bar0_read_dw(16'h0040, dw);
            `CHECK(((dw >> 20) & 32'h0000_0FCF) == 32'h0000_0641,
                   "E.2 TxConfig identifies RTL8125B XID 0x641")
            bar0_write_dw(16'h0040, 32'h0300_0700, 4'hF);
            bar0_read_dw(16'h0040, dw);
            `CHECK(((dw >> 20) & 32'h0000_0FCF) == 32'h0000_0641,
                   "E.2 TxConfig write preserves read-only XID")
            `CHECK((dw & ~32'hFCF0_0000) == (32'h0300_0700 & ~32'hFCF0_0000),
                   "E.2 writable TxConfig bits round-trip")
            bar0_write_dw(16'h0044, 32'h0000_E70F, 4'hF);
            bar0_read_dw(16'h0044, dw);
            `CHECK(dw == 32'h0000_E70F, "E.2 RxConfig round-trip")

            // E.3 Program all driver-visible descriptor base pairs.
            bar0_write_dw(16'h0020, 32'h5566_7788, 4'hF);
            bar0_write_dw(16'h0024, 32'h1122_3344, 4'hF);
            bar0_write_dw(16'h0028, 32'hDDEE_FF00, 4'hF);
            bar0_write_dw(16'h002C, 32'h99AA_BBCC, 4'hF);
            bar0_write_dw(16'h00E4, 32'h89AB_CDEF, 4'hF);
            bar0_write_dw(16'h00E8, 32'h0123_4567, 4'hF);
            `CHECK(bar0_tx_desc_base == 64'h1122_3344_5566_7788,
                   "E.3 TX descriptor base")
            `CHECK(bar0_txh_desc_base == 64'h99AA_BBCC_DDEE_FF00,
                   "E.3 high-priority TX descriptor base")
            `CHECK(bar0_rx_desc_base == 64'h0123_4567_89AB_CDEF,
                   "E.3 RX descriptor base")

            // E.4 RTL8125 32-bit IMR/ISR; status is sticky and W1C.
            bar0_write_dw(16'h0038, 32'h0000_0021, 4'hF);
            @(posedge clk);
            bar0_intr_set <= 32'h0000_0021;
            @(posedge clk);
            bar0_intr_set <= 32'h0000_0000;
            @(posedge clk);
            bar0_read_dw(16'h003C, dw);
            `CHECK(dw == 32'h0000_0021, "E.4 IntrStatus captures events")
            `CHECK(bar0_irq_pending == 1'b1, "E.4 masked event raises IRQ")
            bar0_write_dw(16'h003C, 32'h0000_0001, 4'hF);
            bar0_read_dw(16'h003C, dw);
            `CHECK(dw == 32'h0000_0020, "E.4 IntrStatus write-one-to-clear")
            bar0_write_dw(16'h0038, 32'h0000_0000, 4'hF);
            #1;
            `CHECK(bar0_irq_pending == 1'b0, "E.4 zero mask suppresses IRQ")

            // E.5 CmdReset must assert, clear operational state, and then
            // self-clear so the driver's bounded polling loop terminates.
            bar0_write_dw(16'h0034, 32'h1000_0000, 4'b1000);
            #1;
            `CHECK(bar0_chip_cmd[4] == 1'b1, "E.5 CmdReset asserts")
            repeat (5) @(posedge clk);
            bar0_read_dw(16'h0034, dw);
            `CHECK(dw[28] == 1'b0, "E.5 CmdReset self-clears")
            `CHECK(bar0_tx_desc_base == 64'h0 && bar0_rx_desc_base == 64'h0,
                   "E.5 reset clears descriptor bases")
            bar0_read_dw(16'h0038, dw);
            `CHECK(dw == 32'h0, "E.5 reset clears IntrMask")
            bar0_read_dw(16'h0040, dw);
            `CHECK(((dw >> 20) & 32'h0000_0FCF) == 32'h0000_0641,
                   "E.5 reset preserves RTL8125B identity")
            `CHECK(bar0_mac_address == 48'h02_12_25_35_00_01,
                   "E.5 reset preserves MAC address")

            // E.6 Driver can enable RX/TX with an 8-bit write at 0x37.
            bar0_write_dw(16'h0034, 32'h0C00_0000, 4'b1000);
            bar0_read_dw(16'h0034, dw);
            `CHECK(dw[31:24] == 8'h0C, "E.6 ChipCmd RX/TX enable latches")
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

