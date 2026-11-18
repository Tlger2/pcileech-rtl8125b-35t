// Self-checking testbench for ft601_cmd_parser and pcie_cpld_axis_tx_mux.
// XSim-compatible; no UVM, no interfaces.

`timescale 1ns / 1ps

import opcode_scramble_pkg::*;
import rtl8125b_identity_pkg::*;

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
        .accept_frame  (1'b1),
        .rf_ready      (1'b1),
        .read_start    (),
        .read_length   (),
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
    logic [63:0] bar0_base_64, bar2_base_64, bar4_base_64;

    pci_cfg_space #(.USE_CAP_STUBS(1'b0)) u_cfg (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .cfg_rd_en             (cfg_rd_en),
        .cfg_wr_en             (cfg_wr_en),
        .cfg_addr              (cfg_addr),
        .cfg_be                (cfg_be),
        .cfg_wdata             (cfg_wdata),
        .cfg_rdata             (cfg_rdata),
        .cmd_io_space_en       (),
        .cmd_mem_space_en      (cmd_mem_space_en),
        .cmd_bus_master_en     (),
        .cmd_intx_disable      (),
        .bar0_base_64          (bar0_base_64),
        .bar2_base_64          (bar2_base_64),
        .bar4_base_64          (bar4_base_64),
        .interrupt_line        (),
        .pm_power_state        (),
        .msi_enable            (),
        .msi_multi_msg_enable  (),
        .msi_address           (),
        .msi_data              (),
        .cfg_max_payload_size  (),
        .cfg_max_read_req_size (),
        .msix_enable           (),
        .msix_function_mask    (),
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
    logic [2:0]  bar_idx;
    logic [15:0] bar_offset_lo;

    pcie_bar_decoder u_bar_dec (
        .mse           (cmd_mem_space_en),
        .bar2_base_64  (bar2_base_64),
        .bar4_base_64  (bar4_base_64),
        .tlp_addr      (bar_tlp_addr),
        .bar_hit       (bar_hit),
        .bar_idx       (bar_idx),
        .bar_offset_lo (bar_offset_lo),
        .bar_offset_32 ()
    );

    logic        ecap_rd_en, ecap_wr_en;
    logic [9:0]  ecap_dwaddr;
    logic [31:0] ecap_rdata;
    pcie_ecap_router u_ecap (
        .clk        (clk),
        .rst_n      (rst_n),
        .cfg_rd_en  (ecap_rd_en),
        .cfg_wr_en  (ecap_wr_en),
        .cfg_dwaddr (ecap_dwaddr),
        .cfg_be     (4'hF),
        .cfg_wdata  (32'h0),
        .cfg_rdata  (ecap_rdata)
    );

    logic        bar_wr, bar_rd, bar_rvalid, bar_irq;
    logic [15:0] bar_addr;
    logic [31:0] bar_wdata, bar_rdata;
    logic [3:0]  bar_be;
    rtl8125b_bar0_regs #(.LINK_UP_DELAY_CYCLES(32'd4)) u_bar0 (
        .clk                (clk),
        .rst_n              (rst_n),
        .mem_wr_en          (bar_wr),
        .mem_rd_en          (bar_rd),
        .mem_byte_addr      (bar_addr),
        .mem_wdata          (bar_wdata),
        .mem_be             (bar_be),
        .mem_rdata          (bar_rdata),
        .mem_rvalid         (bar_rvalid),
        .tx_desc_ring_level (16'h0),
        .rx_desc_ring_level (16'h0),
        .irq_pulse          (bar_irq)
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
    logic [31:0] got_lo_mon, got_hi_mon;
    always @(posedge clk) begin
        if (s_axis_tx_tvalid && s_axis_tx_tready) begin
            got_lo_mon = s_axis_tx_tdata[31:0];
            got_hi_mon = s_axis_tx_tdata[63:32];
            if (beat_idx_mon < exp_tx_beats_lo.size()) begin
                `CHECK(got_lo_mon == exp_tx_beats_lo[beat_idx_mon],
                       $sformatf("TX beat %0d lo DW", beat_idx_mon))
                `CHECK(got_hi_mon == exp_tx_beats_hi[beat_idx_mon],
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
        ecap_rd_en       = 1'b0;
        ecap_wr_en       = 1'b0;
        ecap_dwaddr      = 10'h0;
        bar_wr           = 1'b0;
        bar_rd           = 1'b0;
        bar_addr         = 16'h0;
        bar_wdata        = 32'h0;
        bar_be           = 4'hF;

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
            logic [11:0] bc;
            logic [6:0]  la;

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
                begin
                    wait (tx_done_sticky);
                    tx_done_sticky = 1'b0;
                end
                begin
                    repeat (200) @(posedge clk);
                end
            join_any
            disable fork;
            `CHECK(tx_done_sticky || (beat_idx_mon == 4), "B.1 tx_done fired or beats reached")

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

            // C.1 Check identity DW (from rtl8125b_identity_pkg)
            cfg_read_dw(6'd0, dw);
            `CHECK(dw == {DEVICE_ID, VENDOR_ID}, "C.1 DW0 = DID | VID from identity pkg")

            // C.2 Status bit [4] Capabilities List
            cfg_read_dw(6'd1, dw);
            `CHECK(dw[16+4] == 1'b1, "C.2 Status[4] Capabilities List = 1")

            // C.3 Class Code / Rev ID
            cfg_read_dw(6'd2, dw);
            `CHECK(dw == {CLASS_CODE, REVISION_ID},
                   "C.3 DW2 = Class | Rev from identity pkg")

            // C.4 Subsys ID
            cfg_read_dw(6'd11, dw);
            `CHECK(dw == {SUBSYS_ID, SUBSYS_VENDOR_ID},
                   "C.4 Subsys ID from identity pkg")

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
            `CHECK(dw[16+7] == 1'b1, "C.7 MSI 64-bit capable = 1")
            `CHECK(dw[16+8] == 1'b1, "C.7 MSI per-vector mask = 1")
            `CHECK(dw[16+3:16+1] == 3'd0, "C.7 MSI MMC = 1 vector")

            // C.8 PCIe cap at 0x70 (DW 28)
            cfg_read_dw(6'd28, dw);
            cap_id   = dw[7:0];
            next_ptr = dw[15:8];
            `CHECK(cap_id   == 8'h10, "C.8 PCIe CapID = 0x10")
            `CHECK(next_ptr == 8'hB0, "C.8 PCIe NextPtr = 0xB0 (MSI-X)")
            `CHECK(dw[16+3:16+0] == 4'h2, "C.8 PCIe Cap version = 2")
            `CHECK(dw[16+7:16+4] == 4'h0, "C.8 PCIe Device/Port Type = 0 (EP)")

            // C.9 MSI-X at 0xB0 (DW 44): 32 vec, BAR4, PBA 0x800, next VPD
            cfg_read_dw(6'd44, dw);
            cap_id   = dw[7:0];
            next_ptr = dw[15:8];
            `CHECK(cap_id   == 8'h11, "C.9 MSI-X CapID = 0x11")
            `CHECK(next_ptr == 8'hD0, "C.9 MSI-X NextPtr = 0xD0 (VPD)")
            `CHECK(dw[26:16] == 11'd31, "C.9 MSI-X Table Size = 32")
            cfg_read_dw(6'd45, dw);
            `CHECK(dw[2:0] == 3'd4, "C.9 MSI-X Table BIR = BAR4")
            cfg_read_dw(6'd46, dw);
            `CHECK(dw[2:0] == 3'd4, "C.9 MSI-X PBA BIR = BAR4")
            `CHECK(dw[31:3] == 29'h0000_0100, "C.9 MSI-X PBA offset = 0x800")

            // C.10 VPD at 0xD0 (DW 52)
            cfg_read_dw(6'd52, dw);
            cap_id   = dw[7:0];
            next_ptr = dw[15:8];
            `CHECK(cap_id   == 8'h03, "C.10 VPD CapID = 0x03")
            `CHECK(next_ptr == 8'h00, "C.10 VPD NextPtr = 0x00 (end)")

            // C.11 BAR map: BAR0 unused, BAR2 64-bit npref, BAR4 64-bit npref
            cfg_read_dw(6'd4, dw);
            `CHECK(dw == 32'h0, "C.11 BAR0 unused (no I/O BAR on 7-series)")
            cfg_read_dw(6'd6, dw);
            `CHECK(dw[3:0] == 4'h4, "C.11 BAR2 type = 64-bit npref")
            cfg_read_dw(6'd8, dw);
            `CHECK(dw[3:0] == 4'h4, "C.11 BAR4 type = 64-bit npref")
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
        $display("\n==== PHASE D: MSE enforcement (BAR2 MAC / BAR4 MSI-X) ====");
        begin
            bar_tlp_addr = 64'hF000_0000;
            #1;
            `CHECK(bar_hit == 1'b0, "D.1 reset: MSE=0, BAR=0 -> no hit")

            cfg_write_dw(6'd6, 32'hF000_0004, 4'hF);
            cfg_write_dw(6'd7, 32'h0000_0000, 4'hF);
            bar_tlp_addr = 64'h0000_0000_F000_1234;
            #1;
            `CHECK(bar_hit == 1'b0, "D.2 BAR2 programmed, MSE=0 -> still no hit")

            cfg_write_dw(6'd1, 32'h0000_0002, 4'hF);
            @(posedge clk); @(posedge clk);
            `CHECK(cmd_mem_space_en == 1'b1, "D.3 MSE latched high")
            bar_tlp_addr = 64'h0000_0000_F000_1234;
            #1;
            `CHECK(bar_hit == 1'b1, "D.3 MSE=1 + BAR2 in range -> hit")
            `CHECK(bar_idx == 3'd2, "D.3 hit on BAR2")
            `CHECK(bar_offset_lo == 16'h1234, "D.3 offset = 0x1234")

            bar_tlp_addr = 64'h0000_0000_E000_0000;
            #1;
            `CHECK(bar_hit == 1'b0, "D.4 out-of-range -> no hit")

            cfg_write_dw(6'd1, 32'h0000_0000, 4'hF);
            @(posedge clk); @(posedge clk);
            `CHECK(cmd_mem_space_en == 1'b0, "D.5 MSE cleared")
            bar_tlp_addr = 64'h0000_0000_F000_1234;
            #1;
            `CHECK(bar_hit == 1'b0, "D.5 MSE=0 again -> no hit")

            cfg_write_dw(6'd8, 32'hE000_0004, 4'hF);
            cfg_write_dw(6'd9, 32'h0000_0000, 4'hF);
            cfg_write_dw(6'd1, 32'h0000_0002, 4'hF);
            @(posedge clk); @(posedge clk);
            bar_tlp_addr = 64'h0000_0000_E000_0ABC;
            #1;
            `CHECK(bar_hit == 1'b1, "D.6 BAR4 hit with MSE=1")
            `CHECK(bar_idx == 3'd4, "D.6 hit index = BAR4")
            `CHECK(bar_offset_lo == 16'h0ABC, "D.6 BAR4 offset = 0xABC")
        end

        $display("\n==== PHASE E: ECAP chain ====");
        begin
            logic [31:0] dw;
            ecap_wr_en = 1'b0;
            ecap_rd_en = 1'b1;
            ecap_dwaddr = 10'h040; #1;
            `CHECK(ecap_rdata[15:0] == 16'h0001, "E.1 AER ID")
            `CHECK(ecap_rdata[31:20] == 12'h148, "E.1 AER next = VC 0x148")
            ecap_dwaddr = 10'h052; #1;
            `CHECK(ecap_rdata[15:0] == 16'h0002, "E.2 VC ID")
            `CHECK(ecap_rdata[31:20] == 12'h168, "E.2 VC next = DSN 0x168")
            ecap_dwaddr = 10'h05A; #1;
            `CHECK(ecap_rdata[15:0] == 16'h0003, "E.3 DSN ID")
            `CHECK(ecap_rdata[31:20] == 12'h178, "E.3 DSN next = TPH 0x178")
            ecap_dwaddr = 10'h05B; #1;
            `CHECK(ecap_rdata == rtl8125b_identity_pkg::DSN_LO, "E.3 DSN_LO from MAC")
            ecap_dwaddr = 10'h05C; #1;
            `CHECK(ecap_rdata == rtl8125b_identity_pkg::DSN_HI, "E.3 DSN_HI from MAC")
            ecap_dwaddr = 10'h05E; #1;
            `CHECK(ecap_rdata[15:0] == 16'h0017, "E.4 TPH ID")
            ecap_dwaddr = 10'h081; #1;
            `CHECK(ecap_rdata[15:0] == 16'h0018, "E.5 LTR ID")
            `CHECK(ecap_rdata[31:20] == 12'h20C, "E.5 LTR next = L1PM 0x20C")
            ecap_dwaddr = 10'h083; #1;
            `CHECK(ecap_rdata[15:0] == 16'h001E, "E.6 L1PM ID")
            ecap_dwaddr = 10'h087; #1;
            `CHECK(ecap_rdata[15:0] == 16'h000B, "E.7 VSEC ID")
            `CHECK(ecap_rdata[31:20] == 12'h000, "E.7 VSEC next = end")
            ecap_rd_en = 1'b0;
        end

        $display("\n==== PHASE F: BAR0/BAR2 MAC register file ====");
        begin
            bar_wr = 0; bar_rd = 0; bar_be = 4'hF;
            bar_addr = 16'h0; bar_wdata = 32'h0;
            @(posedge clk);
            bar_rd = 1; bar_addr = 16'h00;
            @(posedge clk);
            bar_rd = 0;
            @(posedge clk);
            `CHECK(bar_rdata == 32'h7A4C_E000, "F.1 MAC0 = 00:E0:4C:7A")
            bar_rd = 1; bar_addr = 16'h40;
            @(posedge clk);
            bar_rd = 0;
            @(posedge clk);
            `CHECK((bar_rdata & 32'h7CF0_0000) == 32'h64A0_0000,
                   "F.2 TxConfig chip id = RTL8125B")
            // Shadow: write/read unnamed offset 0x90
            bar_wr = 1; bar_addr = 16'h90; bar_wdata = 32'hA5A5_5A5A; bar_be = 4'hF;
            @(posedge clk);
            bar_wr = 0;
            bar_rd = 1; bar_addr = 16'h90;
            @(posedge clk);
            bar_rd = 0;
            @(posedge clk);
            `CHECK(bar_rdata == 32'hA5A5_5A5A, "F.3 shadow RAM round-trip at 0x90")
            // PHYAR write Flag=0 (read), wait for complete
            bar_wr = 1; bar_addr = 16'h60; bar_wdata = 32'h0002_0000; bar_be = 4'hF;
            @(posedge clk);
            bar_wr = 0;
            repeat (16) @(posedge clk);
            bar_rd = 1; bar_addr = 16'h60;
            @(posedge clk);
            bar_rd = 0;
            @(posedge clk);
            `CHECK(bar_rdata[31] == 1'b1, "F.4 PHYAR Flag set on read complete")
            `CHECK(bar_rdata[15:0] == 16'h001C, "F.4 PHYID1 = Realtek 0x001C")
            // TxPoll -> TOK irq
            bar_wr = 1; bar_addr = 16'h3C; bar_wdata = 32'h0000_0004; bar_be = 4'h3;
            @(posedge clk);
            bar_wr = 0;
            @(posedge clk);
            bar_wr = 1; bar_addr = 16'h38; bar_wdata = 32'h0000_0040; bar_be = 4'h1;
            @(posedge clk);
            #1;
            `CHECK(bar_irq == 1'b1, "F.5 TxPoll raises irq_pulse when TOK masked")
            bar_wr = 0;
            @(posedge clk);
            // CSIAR Flag protocol (r8169/r8125 CSI)
            bar_wr = 1; bar_addr = 16'h68; bar_wdata = 32'h0000_0000; bar_be = 4'hF;
            @(posedge clk);
            bar_wr = 0;
            repeat (32) @(posedge clk);
            bar_rd = 1; bar_addr = 16'h68;
            @(posedge clk);
            bar_rd = 0;
            @(posedge clk);
            `CHECK(bar_rdata[31] == 1'b1, "F.6 CSIAR Flag set on read complete")
            // GPHY_OCP Flag protocol (stub, not a full GPHY)
            bar_wr = 1; bar_addr = 16'hB8; bar_wdata = 32'h0000_0000; bar_be = 4'hF;
            @(posedge clk);
            bar_wr = 0;
            repeat (32) @(posedge clk);
            bar_rd = 1; bar_addr = 16'hB8;
            @(posedge clk);
            bar_rd = 0;
            @(posedge clk);
            `CHECK(bar_rdata[31] == 1'b1, "F.7 GPHY_OCP Flag set on read complete")
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
