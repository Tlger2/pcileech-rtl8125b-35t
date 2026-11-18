// lang: SystemVerilog, file: pcie_custom_endpoint_top.sv
// target: Xilinx Artix-7 XC7A35T, Vivado 2026.1
// function: PCIe endpoint top — TLP parser/builder, BAR0 CplD, DMA engine,
//           CDC across ft601_clk/user_clk, TX arbitration, EAC-evasion wiring.
//
// TLP beat layout (64-bit AXI-Stream, per dma_engine.sv convention):
//   Beat N: tdata = {DW_(2N+1), DW_(2N)} → DW0 in [31:0], DW1 in [63:32]
//
// DW0[31:24] = {fmt[2:0], type[4:0]}:
//   8'h00  3DW MemRd  (fmt=000, type=00000)
//   8'h40  3DW MemWr  (fmt=010, type=00000)
//   8'h4A  3DW CplD   (fmt=010, type=01010)
//
// 3DW MemRd (12 B = 2 beats):
//   Beat0: {DW1={ReqID,Tag,LastBE,FirstBE}, DW0={fmt/type/len}}  tkeep=FF  tlast=0
//   Beat1: {32'h0, DW2={Addr[31:2],PH}}                          tkeep=0F  tlast=1
//
// 3DW MemWr (16 B = 2 beats, 1-DW payload):
//   Beat0: {DW1, DW0}                                            tkeep=FF  tlast=0
//   Beat1: {DW3=payload, DW2=Addr}                               tkeep=FF  tlast=1
//
// CplD (12 B header + 4 B payload = 2 beats):
//   Beat0: {DW1={CplID,BCM,Status,ByteCount}, DW0}               tkeep=FF  tlast=0
//   Beat1: {data[31:0], DW2={ReqID,Tag,LowerAddr}}               tkeep=FF  tlast=1
//
// CDC protocol over FT601 (MAGIC frames, 32-bit words):
//   DW0 : 32'h5AA5_C33C
//   DW1 : {wire_opcode[7:0], flags[7:0], length_dw[15:0]}
//   DW2 : register-file byte address
//   DW3+: length_dw payload (writes only)
// ACK opcodes (KEEPALIVE/VERSION/...) reply with a 3-DW MAGIC frame, length 0.
// Reads reply with MAGIC + HDR + ADDR + payload DWs from the DMA RF.

`timescale 1ns/1ps

module pcie_custom_endpoint_top (
    // ---- PCIe user interface (user_clk domain) ----
    input  logic        user_clk,
    input  logic        user_reset,
    input  logic        user_lnk_up,

    // AXI-Stream TX (user_clk)
    output logic [63:0] s_axis_tx_tdata,
    output logic  [7:0] s_axis_tx_tkeep,
    output logic        s_axis_tx_tvalid,
    input  logic        s_axis_tx_tready,
    output logic        s_axis_tx_tlast,
    output logic  [3:0] s_axis_tx_tuser,

    // AXI-Stream RX (user_clk)
    input  logic [63:0] m_axis_rx_tdata,
    input  logic  [7:0] m_axis_rx_tkeep,
    input  logic        m_axis_rx_tvalid,
    output logic        m_axis_rx_tready,
    input  logic        m_axis_rx_tlast,
    input  logic [21:0] m_axis_rx_tuser,

    // PCIe config (user_clk)
    input  logic [15:0] cfg_completer_id,
    input  logic [15:0] cfg_command,
    input  logic  [2:0] cfg_max_payload_size,
    input  logic  [2:0] cfg_max_read_req_size,
    input  logic  [3:0] link_speed_live,
    input  logic  [5:0] link_width_live,

    // Interrupt (user_clk)
    output logic        cfg_interrupt,
    input  logic        cfg_interrupt_rdy,
    output logic        cfg_interrupt_assert,
    output logic  [7:0] cfg_interrupt_di,
    input  logic        cfg_interrupt_msienable,
    input  logic  [2:0] cfg_interrupt_mmenable,
    input  logic        cfg_interrupt_msixenable,
    input  logic        cfg_interrupt_msixfm,

    // {fc_nph, tx_buf_av, link_state, device status}. DMA reg 0x38.
    input  logic [31:0] debug_link_diag,
    // AER Correctable Error Status (byte 0x110). DMA reg 0x3C.
    input  logic [31:0] debug_aer,
    // Core discarded a TX TLP. Counted in DMA reg 0x34.
    input  logic        tx_err_drop,
    // Asserted while a DMA TLP is in flight (core cfg_trn_pending).
    output logic        cfg_trn_pending,

    // ---- FT601 USB3 (ft601_clk domain) ----
    input  logic        ft601_clk,
    input  logic        ft601_rst_n,
    input  logic        ft601_rxf_n,
    output logic        ft601_oe_n,
    output logic        ft601_rd_n,
    output logic        ft601_wr_n,
    output logic        ft601_siwu_n,
    input  logic        ft601_txe_n,
    inout  wire  [31:0] ft601_data,
    inout  wire   [3:0] ft601_be
);

// =============================================================================
// Resets
// =============================================================================
logic user_rst_n;
assign user_rst_n = ~user_reset;

// XPM wr_clk rst must stay in the ft601_clk domain. OR-ing user_reset
// (userclk1) into this net is an unsynchronized CDC into the FIFO reset
// FSM and is what failed setup by 0.37 ns. PCIe reset still clears the
// user_clk RF adapter; leftover USB words are discarded on FT601 rst.
logic fifo_arst;
assign fifo_arst = ~ft601_rst_n;

// =============================================================================
// Static tie-offs
// =============================================================================
assign m_axis_rx_tready = 1'b1;   // 7-series RX cannot be back-pressured
assign s_axis_tx_tuser  = 4'h0;

// =============================================================================
// SECTION 1 — FT601 SFIFO (ft601_clk domain)
// =============================================================================
logic        fifo_rd_valid, fifo_rd_ready;
logic [31:0] fifo_rd_data;
logic        fifo_wr_valid, fifo_wr_ready;
logic [31:0] fifo_wr_data;
logic  [3:0] fifo_wr_be;

ft601_sfifo u_ft601_sfifo (
    .clk          (ft601_clk),
    .rst_n        (ft601_rst_n),
    .ft601_rxf_n  (ft601_rxf_n),
    .ft601_txe_n  (ft601_txe_n),
    .ft601_oe_n   (ft601_oe_n),
    .ft601_rd_n   (ft601_rd_n),
    .ft601_wr_n   (ft601_wr_n),
    .ft601_siwu_n (ft601_siwu_n),
    .ft601_data   (ft601_data),
    .ft601_be     (ft601_be),
    .fifo_rd_valid(fifo_rd_valid),
    .fifo_rd_ready(fifo_rd_ready),
    .fifo_rd_data (fifo_rd_data),
    .fifo_wr_valid(fifo_wr_valid),
    .fifo_wr_ready(fifo_wr_ready),
    .fifo_wr_data (fifo_wr_data),
    .fifo_wr_be   (fifo_wr_be)
);

// =============================================================================
// SECTION 2 — MAGIC parser + packager (ft601_clk domain)
//
// Keepalive/version/info ACKs are entirely in ft601_clk so --ping works even
// while PCIe user_reset holds the CMD/RSP CDC FIFOs. Register-file reads and
// writes still cross to user_clk through those FIFOs. PCIe BAR CplD stays on
// s_axis_tx (section 9); this mux only feeds the FT601 TX FIFO.
// =============================================================================
logic        cmd_wr_en;
logic [64:0] cmd_wr_data;
logic        cmd_wr_full;
logic        cmd_wr_rst_busy;
logic        rsp_rd_valid;
logic [31:0] rsp_rd_data;
logic        rsp_rd_en;

logic        prs_rf_we, prs_rf_re;
logic [31:0] prs_rf_waddr, prs_rf_wdata, prs_rf_raddr;
logic [31:0] prs_rf_rdata;
logic        prs_rf_rvalid;
logic        prs_rf_ready;
logic        prs_accept_frame;
logic        prs_read_start;
logic [15:0] prs_read_length;
logic [7:0]  prs_last_opcode;
logic [31:0] prs_last_base_addr;

logic        pkg_rsp_start, pkg_rsp_busy;
logic [7:0]  pkg_opcode;
logic [7:0]  pkg_flags;
logic [31:0] pkg_addr;
logic [15:0] pkg_length_dw;
logic        pkg_pld_valid, pkg_pld_ready;
logic [31:0] pkg_pld_data;
logic        pkg_fifo_wr_valid, pkg_fifo_wr_ready;
logic [31:0] pkg_fifo_wr_data;

logic        rd_inflight;
logic        pld_hold_valid;
logic        pld_parser_ack;
logic [31:0] pld_hold;
logic        read_start_d;
logic        ack_pending;
logic [7:0]  ack_opcode;
logic [15:0] ack_length;
logic [31:0] ack_addr;

assign prs_accept_frame = !pkg_rsp_busy && !ack_pending && !read_start_d;
assign prs_rf_ready = !cmd_wr_full && !cmd_wr_rst_busy
                    && !rd_inflight && !pld_hold_valid;

ft601_cmd_parser u_cmd_parser (
    .clk           (ft601_clk),
    .rst_n         (ft601_rst_n),
    .fifo_rd_valid (fifo_rd_valid),
    .fifo_rd_ready (fifo_rd_ready),
    .fifo_rd_data  (fifo_rd_data),
    .accept_frame  (prs_accept_frame),
    .rf_ready      (prs_rf_ready),
    .rf_we         (prs_rf_we),
    .rf_waddr      (prs_rf_waddr),
    .rf_wdata      (prs_rf_wdata),
    .rf_re         (prs_rf_re),
    .rf_raddr      (prs_rf_raddr),
    .rf_rdata      (prs_rf_rdata),
    .rf_rvalid     (prs_rf_rvalid),
    .frame_start   (),
    .read_start    (prs_read_start),
    .read_length   (prs_read_length),
    .frame_done    (),
    .bad_opcode_err(),
    .last_opcode   (prs_last_opcode),
    .last_base_addr(prs_last_base_addr)
);

ft601_resp_packager u_resp_packager (
    .clk             (ft601_clk),
    .rst_n           (ft601_rst_n),
    .rsp_start       (pkg_rsp_start),
    .rsp_opcode_canon(pkg_opcode),
    .rsp_flags       (pkg_flags),
    .rsp_addr        (pkg_addr),
    .rsp_length_dw   (pkg_length_dw),
    .rsp_busy        (pkg_rsp_busy),
    .rsp_done        (),
    .pld_valid       (pkg_pld_valid),
    .pld_ready       (pkg_pld_ready),
    .pld_data        (pkg_pld_data),
    .fifo_wr_valid   (pkg_fifo_wr_valid),
    .fifo_wr_ready   (pkg_fifo_wr_ready),
    .fifo_wr_data    (pkg_fifo_wr_data),
    .fifo_wr_last    (),
    .bad_opcode_err  ()
);

// CMD CDC push: parser RF ops are in ft601_clk; dma_engine is in user_clk.
assign cmd_wr_en = !cmd_wr_full && !cmd_wr_rst_busy && (
    prs_rf_we || (prs_rf_re && !rd_inflight && !pld_hold_valid)
);
assign cmd_wr_data = prs_rf_we
    ? {1'b1, prs_rf_waddr, prs_rf_wdata}
    : {1'b0, prs_rf_raddr, 32'h0};

assign prs_rf_rdata  = pld_hold;
assign prs_rf_rvalid = pld_hold_valid && !pld_parser_ack;
assign pkg_pld_valid = pld_hold_valid;
assign pkg_pld_data  = pld_hold;
assign pkg_flags     = 8'h00;

always_ff @(posedge ft601_clk or negedge ft601_rst_n) begin
    if (!ft601_rst_n) begin
        rd_inflight    <= 1'b0;
        pld_hold_valid <= 1'b0;
        pld_parser_ack <= 1'b0;
        pld_hold       <= '0;
        read_start_d   <= 1'b0;
        ack_pending    <= 1'b0;
        ack_opcode     <= '0;
        ack_length     <= '0;
        ack_addr       <= '0;
        pkg_rsp_start  <= 1'b0;
        pkg_opcode     <= '0;
        pkg_addr       <= '0;
        pkg_length_dw  <= '0;
    end else begin
        pkg_rsp_start <= 1'b0;
        read_start_d  <= prs_read_start;

        if (prs_read_start) begin
            ack_opcode <= prs_last_opcode;
            ack_length <= prs_read_length;
        end

        if (read_start_d) begin
            ack_pending <= 1'b1;
            ack_addr    <= prs_last_base_addr;
        end

        if ((ack_pending || read_start_d) && !pkg_rsp_busy && !pkg_rsp_start) begin
            pkg_rsp_start <= 1'b1;
            pkg_opcode    <= ack_opcode;
            pkg_addr      <= read_start_d ? prs_last_base_addr : ack_addr;
            pkg_length_dw <= ack_length;
            ack_pending   <= 1'b0;
        end

        if (cmd_wr_en && prs_rf_re && !prs_rf_we)
            rd_inflight <= 1'b1;

        if (rd_inflight && rsp_rd_valid && !pld_hold_valid) begin
            pld_hold       <= rsp_rd_data;
            pld_hold_valid <= 1'b1;
            pld_parser_ack <= 1'b0;
            rd_inflight    <= 1'b0;
        end else if (pld_hold_valid && pkg_pld_ready) begin
            pld_hold_valid <= 1'b0;
            pld_parser_ack <= 1'b0;
        end else if (pld_hold_valid && !pld_parser_ack) begin
            pld_parser_ack <= 1'b1;
        end
    end
end

// =============================================================================
// SECTION 3 — CDC FIFOs (ft601_clk ↔ user_clk)
// =============================================================================

// --- CMD FIFO: ft601_clk → user_clk (65 bits: {is_write, addr[31:0], wdata[31:0]}) ---
logic [64:0] cmd_rd_data;
logic        cmd_rd_empty;
logic        cmd_rd_en;
logic        cmd_rd_rst_busy;

xpm_fifo_async #(
    .FIFO_WRITE_DEPTH (16),
    .WRITE_DATA_WIDTH (65),
    .READ_DATA_WIDTH  (65),
    .CDC_SYNC_STAGES  (2),
    .READ_MODE        ("fwft"),
    .ECC_MODE         ("no_ecc"),
    .RELATED_CLOCKS   (0),
    .SIM_ASSERT_CHK   (0),
    .USE_ADV_FEATURES ("0000"),
    .FIFO_MEMORY_TYPE ("distributed")
) u_cmd_cdc (
    .rst          (fifo_arst),
    .wr_clk       (ft601_clk),
    .wr_en        (cmd_wr_en),
    .din          (cmd_wr_data),
    .full         (cmd_wr_full),
    .wr_ack       (),
    .overflow     (),
    .wr_data_count(),
    .prog_full    (),
    .wr_rst_busy  (cmd_wr_rst_busy),
    .rd_clk       (user_clk),
    .rd_en        (cmd_rd_en),
    .dout         (cmd_rd_data),
    .empty        (cmd_rd_empty),
    .data_valid   (),
    .underflow    (),
    .rd_data_count(),
    .prog_empty   (),
    .rd_rst_busy  (cmd_rd_rst_busy),
    .injectsbiterr(1'b0),
    .injectdbiterr(1'b0),
    .sbiterr      (),
    .dbiterr      ()
);

wire cmd_rd_valid = ~cmd_rd_empty & ~cmd_rd_rst_busy;

// --- RSP FIFO: user_clk → ft601_clk (32 bits: read data) ---
logic        rsp_wr_en;
logic [31:0] rsp_wr_data;
logic        rsp_wr_full;
logic        rsp_wr_rst_busy;
logic        rsp_rd_empty;
logic        rsp_rd_rst_busy;

xpm_fifo_async #(
    .FIFO_WRITE_DEPTH (16),
    .WRITE_DATA_WIDTH (32),
    .READ_DATA_WIDTH  (32),
    .CDC_SYNC_STAGES  (2),
    .READ_MODE        ("fwft"),
    .ECC_MODE         ("no_ecc"),
    .RELATED_CLOCKS   (0),
    .SIM_ASSERT_CHK   (0),
    .USE_ADV_FEATURES ("0000"),
    .FIFO_MEMORY_TYPE ("distributed")
) u_rsp_cdc (
    .rst          (fifo_arst),
    .wr_clk       (user_clk),
    .wr_en        (rsp_wr_en),
    .din          (rsp_wr_data),
    .full         (rsp_wr_full),
    .wr_ack       (),
    .overflow     (),
    .wr_data_count(),
    .prog_full    (),
    .wr_rst_busy  (rsp_wr_rst_busy),
    .rd_clk       (ft601_clk),
    .rd_en        (rsp_rd_en),
    .dout         (rsp_rd_data),
    .empty        (rsp_rd_empty),
    .data_valid   (),
    .underflow    (),
    .rd_data_count(),
    .prog_empty   (),
    .rd_rst_busy  (rsp_rd_rst_busy),
    .injectsbiterr(1'b0),
    .injectdbiterr(1'b0),
    .sbiterr      (),
    .dbiterr      ()
);

assign rsp_rd_valid = ~rsp_rd_empty & ~rsp_rd_rst_busy;
assign rsp_rd_en    = rd_inflight & rsp_rd_valid & ~pld_hold_valid;

// Only solicited packager responses may drive USB TX. The old debug
// heartbeat used per-word priority and could splice a KEEPALIVE into a
// response, besides making a ping pass without a command being received.
assign fifo_wr_valid     = pkg_fifo_wr_valid;
assign fifo_wr_data      = pkg_fifo_wr_data;
assign fifo_wr_be        = 4'hF;
assign pkg_fifo_wr_ready = fifo_wr_ready;

// =============================================================================
// SECTION 4 — DMA Engine register file adapter (user_clk domain)
//
// Pops commands from CMD FIFO, drives dma_engine RF, pushes read results to RSP FIFO.
// =============================================================================
logic        rf_we, rf_re;
logic [31:0] rf_waddr, rf_wdata;
logic [31:0] rf_raddr;
logic [31:0] rf_rdata;
logic        rf_rvalid;

typedef enum logic [1:0] {
    RF_IDLE      = 2'd0,
    RF_READ_WAIT = 2'd1
} rf_state_e;

rf_state_e rf_state;

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        rf_state  <= RF_IDLE;
        rf_we     <= 1'b0;
        rf_re     <= 1'b0;
        rf_waddr  <= '0;
        rf_wdata  <= '0;
        rf_raddr  <= '0;
        cmd_rd_en <= 1'b0;
        rsp_wr_en <= 1'b0;
        rsp_wr_data <= '0;
    end else begin
        rf_we       <= 1'b0;
        rf_re       <= 1'b0;
        cmd_rd_en   <= 1'b0;
        rsp_wr_en   <= 1'b0;

        case (rf_state)
            RF_IDLE: begin
                if (cmd_rd_valid) begin
                    cmd_rd_en <= 1'b1;   // pop the command
                    if (cmd_rd_data[64]) begin
                        // Write to DMA register file
                        rf_we    <= 1'b1;
                        rf_waddr <= cmd_rd_data[63:32];
                        rf_wdata <= cmd_rd_data[31:0];
                        rf_state <= RF_IDLE;
                    end else begin
                        // Read from DMA register file
                        rf_re    <= 1'b1;
                        rf_raddr <= cmd_rd_data[63:32];
                        rf_state <= RF_READ_WAIT;
                    end
                end
            end

            RF_READ_WAIT: begin
                if (rf_rvalid && !rsp_wr_full && !rsp_wr_rst_busy) begin
                    rsp_wr_en   <= 1'b1;
                    rsp_wr_data <= rf_rdata;
                    rf_state    <= RF_IDLE;
                end
            end

            default: rf_state <= RF_IDLE;
        endcase
    end
end

// =============================================================================
// SECTION 5 — DMA Engine (user_clk domain)
// =============================================================================
logic        dma_tx_valid, dma_tx_ready;
logic [63:0] dma_tx_data;
logic  [7:0] dma_tx_keep;
logic        dma_tx_last;

logic        dma_rx_valid;
logic [63:0] dma_rx_data;
logic  [7:0] dma_rx_keep;
logic        dma_rx_last;
logic        dma_cpl_seen;
logic [31:0] debug_rx_header;

// BME gate removed: dma_hold_req tied low so DMA fires regardless of
// cfg_command[2]. The 35T target's Realtek driver does not set BME during
// NdisInitialize, causing the FPGA to stall indefinitely in ST_WAIT_CPL.
// The RC still enforces BME at the fabric level for real transactions;
// this change only removes the redundant software-side gate.

dma_engine u_dma_engine (
    .user_clk         (user_clk),
    .user_rst_n       (user_rst_n),
    // Register file (user_clk domain, from cmd FIFO adapter above)
    .rf_we            (rf_we),
    .rf_waddr         (rf_waddr),
    .rf_wdata         (rf_wdata),
    .rf_re            (rf_re),
    .rf_raddr         (rf_raddr),
    .rf_rdata         (rf_rdata),
    .rf_rvalid        (rf_rvalid),
    // PCIe requester ID
    .cfg_completer_id (cfg_completer_id),
    .cfg_command      (cfg_command),
    .debug_link_up    (user_lnk_up),
    .debug_rx_header  (debug_rx_header),
    .debug_link_diag  (debug_link_diag),
    .debug_aer        (debug_aer),
    .cfg_max_payload_size(cfg_max_payload_size),
    // AXI-Stream TX → PCIe core
    .tx_req_valid     (dma_tx_valid),
    .tx_req_ready     (dma_tx_ready),
    .tx_req_data      (dma_tx_data),
    .tx_req_keep      (dma_tx_keep),
    .tx_req_last      (dma_tx_last),
    // AXI-Stream RX ← PCIe core (CplD from host)
    .rx_cpl_valid     (dma_rx_valid),
    .rx_cpl_ready     (/* ignored — 7-series cannot back-pressure RX */),
    .rx_cpl_data      (dma_rx_data),
    .rx_cpl_keep      (dma_rx_keep),
    .rx_cpl_last      (dma_rx_last),
    .rx_any_valid     (m_axis_rx_tvalid),
    // Jitter gate — tied low, BME gate removed
    .dma_cpl_seen     (dma_cpl_seen),
    .dma_hold_req     (1'b0),
    .tx_err_drop      (tx_err_drop),
    .np_pending       (cfg_trn_pending)
);

// =============================================================================
// SECTION 6 — TLP RX Decoder (user_clk domain)
//
// Tracks beat position within each TLP; on beat0 identifies type and latches
// header fields; on beat1 dispatches to BAR0 register bank or routes CplD to
// the DMA engine.
// =============================================================================

// Beat counter — resets on tlast
logic [1:0] rx_beat_cnt;
always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) rx_beat_cnt <= 2'd0;
    else if (m_axis_rx_tvalid) begin
        if (m_axis_rx_tlast) rx_beat_cnt <= 2'd0;
        else if (rx_beat_cnt != 2'd3) rx_beat_cnt <= rx_beat_cnt + 1'b1;
    end
end

// Record all received packet headers for read-only diagnostics.
always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) debug_rx_header <= 0;
    else if (m_axis_rx_tvalid && rx_beat_cnt == 0)
        debug_rx_header <= m_axis_rx_tdata[31:0];
end

// TLP type encoding
localparam logic [2:0] RX_OTHER = 3'd0;
localparam logic [2:0] RX_MRD   = 3'd1;
localparam logic [2:0] RX_MWR   = 3'd2;
localparam logic [2:0] RX_CPLD  = 3'd3;

// Fields latched from beat0
logic [15:0] rx_reqid_q;
logic  [7:0] rx_tag_q;
logic  [3:0] rx_firstbe_q;
logic  [2:0] rx_tlp_kind;
logic        rx_fourdw_q;
logic [6:0]  rx_bar_hit_q; // m_axis_rx_tuser[8:2]

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        rx_reqid_q   <= '0;
        rx_tag_q     <= '0;
        rx_firstbe_q <= '0;
        rx_tlp_kind  <= RX_OTHER;
        rx_fourdw_q  <= 1'b0;
        rx_bar_hit_q <= '0;
    end else if (m_axis_rx_tvalid && rx_beat_cnt == 2'd0) begin
        // Beat0: tdata[31:0]=DW0, tdata[63:32]=DW1
        // DW1: [31:16]=ReqID, [23:16]=Tag, [3:0]=FirstBE
        rx_reqid_q   <= m_axis_rx_tdata[63:48]; // DW1[31:16]
        rx_tag_q     <= m_axis_rx_tdata[47:40]; // DW1[23:16]
        rx_firstbe_q <= m_axis_rx_tdata[35:32]; // DW1[3:0]
        rx_fourdw_q  <= m_axis_rx_tdata[29];    // Fmt[0] = 4DW header
        rx_bar_hit_q <= m_axis_rx_tuser[8:2];
        case (m_axis_rx_tdata[31:24])            // DW0 fmt|type byte
            8'h00, 8'h20: rx_tlp_kind <= RX_MRD;   // 3DW/4DW MemRd
            8'h40, 8'h60: rx_tlp_kind <= RX_MWR;   // 3DW/4DW MemWr
            8'h0A, 8'h4A: rx_tlp_kind <= RX_CPLD;  // Cpl / CplD
            default:      rx_tlp_kind <= RX_OTHER;
        endcase
    end
end

// --- Completion routing to DMA engine (Cpl 8'h0A and CplD 8'h4A) ---
wire rx_is_cpl = (m_axis_rx_tdata[28:24] == 5'b01010);
assign dma_rx_valid = m_axis_rx_tvalid & (
    (rx_beat_cnt == 2'd0 && rx_is_cpl) |
    (rx_beat_cnt != 2'd0 && rx_tlp_kind == RX_CPLD)
);
assign dma_rx_data = m_axis_rx_tdata;
assign dma_rx_keep = m_axis_rx_tkeep;
assign dma_rx_last = m_axis_rx_tlast;

// --- BAR0 access — decoded on beat1 ---
// beat1: tdata[31:0]=DW2(addr), tdata[63:32]=DW3(payload for MemWr)
// BAR0 byte address within 256-B aperture = DW2[7:0] (BAR0 base is 256-B aligned)
// DW2[1:0] = PH bits (processing hints), always 0 from real hosts.

logic        bar0_wr_en_q, bar0_rd_en_q;
logic        bar4_wr_en_q, bar4_rd_en_q;
logic [15:0] bar0_byte_addr_q;  // 16-bit to match rtl8125b_bar0_regs.mem_byte_addr
logic [31:0] bar0_wdata_q;

// Context saved for CplD generation (latched alongside bar0_rd_en_q)
logic [15:0] bar0_pend_reqid;
logic  [7:0] bar0_pend_tag;
logic  [7:0] bar0_pend_laddr; // LowerAddr for CplD DW2

// cpld_state used to gate new MemRd when a CplD is already in-flight
// (declared below; forward reference is fine in SV)
logic cpld_pending;

wire [31:0] rx_addr32 = rx_fourdw_q ? m_axis_rx_tdata[63:32] : m_axis_rx_tdata[31:0];
// BAR2 is the 64 KB MAC window (bar_hit[2]). BAR0 hit is kept as an alias
// because some 7-series configs still report the omitted I/O window as BAR0.
// BAR4 is MSI-X (bar_hit[4]). Ignore MemRd/MemWr with no BAR hit.
wire rx_bar2 = rx_bar_hit_q[2] | rx_bar_hit_q[0];
wire rx_bar4 = rx_bar_hit_q[4];

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        bar0_wr_en_q     <= 1'b0;
        bar0_rd_en_q     <= 1'b0;
        bar4_wr_en_q     <= 1'b0;
        bar4_rd_en_q     <= 1'b0;
        bar0_byte_addr_q <= '0;
        bar0_wdata_q     <= '0;
        bar0_pend_reqid  <= '0;
        bar0_pend_tag    <= '0;
        bar0_pend_laddr  <= '0;
    end else begin
        bar0_wr_en_q <= 1'b0;
        bar0_rd_en_q <= 1'b0;
        bar4_wr_en_q <= 1'b0;
        bar4_rd_en_q <= 1'b0;

        if (m_axis_rx_tvalid && rx_beat_cnt == 2'd1) begin
            bar0_byte_addr_q <= rx_addr32[15:0];
            bar0_pend_laddr  <= rx_addr32[6:0];

            if (rx_tlp_kind == RX_MWR && !rx_fourdw_q) begin
                bar0_wdata_q <= m_axis_rx_tdata[63:32];
                if (rx_bar4)
                    bar4_wr_en_q <= 1'b1;
                else if (rx_bar2)
                    bar0_wr_en_q <= 1'b1;
            end else if (rx_tlp_kind == RX_MRD && !cpld_pending) begin
                bar0_pend_reqid <= rx_reqid_q;
                bar0_pend_tag   <= rx_tag_q;
                if (rx_bar4)
                    bar4_rd_en_q <= 1'b1;
                else if (rx_bar2)
                    bar0_rd_en_q <= 1'b1;
            end
        end else if (m_axis_rx_tvalid && rx_beat_cnt == 2'd2 &&
                     rx_tlp_kind == RX_MWR && rx_fourdw_q) begin
            bar0_wdata_q <= m_axis_rx_tdata[31:0];
            if (rx_bar4)
                bar4_wr_en_q <= 1'b1;
            else if (rx_bar2)
                bar0_wr_en_q <= 1'b1;
        end
    end
end

// =============================================================================
// SECTION 7 — BAR0 Register Bank (user_clk domain)
// =============================================================================
logic [31:0] bar0_rdata;
logic        bar0_rvalid;
logic        irq_pulse;

rtl8125b_bar0_regs #(
    .ENABLE_SHADOW(1'b1)
) u_bar0_regs (
    .clk                (user_clk),
    .rst_n              (user_rst_n),
    .mem_wr_en          (bar0_wr_en_q),
    .mem_rd_en          (bar0_rd_en_q),
    .mem_byte_addr      (bar0_byte_addr_q),
    .mem_wdata          (bar0_wdata_q),
    .mem_be             (rx_firstbe_q),
    .mem_rdata          (bar0_rdata),
    .mem_rvalid         (bar0_rvalid),
    .tx_desc_ring_level (16'h0),
    .rx_desc_ring_level (16'h0),
    .irq_pulse          (irq_pulse)
);

// MSI-X table (32 × 16 B at 0x000) and PBA (at 0x800) in BAR4.
logic [31:0] msix_rdata;
logic        msix_rvalid;
logic [4:0]  msix_vec_idx;
logic [63:0] msix_vec_addr;
logic [31:0] msix_vec_data;
logic        msix_vec_mask;
logic [31:0] msix_pba_set, msix_pba_clear;

msix_table_pba #(
    .NUM_VECTORS         (rtl8125b_identity_pkg::MSIX_VECTORS),
    .TABLE_BAR_BYTE_BASE (rtl8125b_identity_pkg::MSIX_TABLE_BYTE_OFF),
    .PBA_BAR_BYTE_BASE   (rtl8125b_identity_pkg::MSIX_PBA_BYTE_OFF)
) u_msix_table (
    .clk           (user_clk),
    .rst_n         (user_rst_n),
    .mem_wr_en     (bar4_wr_en_q),
    .mem_rd_en     (bar4_rd_en_q),
    .mem_byte_addr (bar0_byte_addr_q),
    .mem_wdata     (bar0_wdata_q),
    .mem_be        (rx_firstbe_q),
    .mem_rdata     (msix_rdata),
    .mem_rvalid    (msix_rvalid),
    .vec_rd_idx    (msix_vec_idx),
    .vec_addr      (msix_vec_addr),
    .vec_data      (msix_vec_data),
    .vec_mask      (msix_vec_mask),
    .pba_set       (msix_pba_set),
    .pba_clear     (msix_pba_clear),
    .pba_bits      ()
);

logic [31:0] cpl_rdata;
logic        cpl_rvalid;
assign cpl_rdata  = msix_rvalid ? msix_rdata : bar0_rdata;
assign cpl_rvalid = msix_rvalid | bar0_rvalid;

// =============================================================================
// SECTION 8 — CplD Builder (user_clk domain)
//
// Triggered by bar0_rvalid. Builds and stores a 2-beat 3DW CplD TLP:
//   Beat0: { DW1={CplID,BCM=0,Status=OK,ByteCount=4}, DW0=0x4A000001 }
//   Beat1: { payload=bar0_rdata, DW2={ReqID,Tag,0,LowerAddr[6:0]} }
//
// cpld_pending is asserted while a CplD is queued or being transmitted.
// =============================================================================
typedef enum logic [1:0] {
    CPLD_IDLE = 2'd0,
    CPLD_B0   = 2'd1,
    CPLD_B1   = 2'd2
} cpld_state_e;

cpld_state_e cpld_state;

logic [63:0] cpld_b0, cpld_b1;
logic        cpld_valid;
logic [63:0] cpld_tdata;
logic  [7:0] cpld_tkeep;
logic        cpld_tlast;
logic        cpld_tx_ready; // from TX arb when CplD source is granted

assign cpld_pending = (cpld_state != CPLD_IDLE);

// CplD state machine
always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        cpld_state <= CPLD_IDLE;
        cpld_b0    <= '0;
        cpld_b1    <= '0;
    end else begin
        case (cpld_state)
            CPLD_IDLE: begin
                if (cpl_rvalid) begin
                    // DW0 = {fmt=010, type=01010, 7'b0, len=1DW} = 32'h4A00_0001
                    // DW1 = {CompleterID[15:0], BCM=0, Status=000(OK), ByteCount=12'd4}
                    cpld_b0 <= {
                        (cfg_completer_id == 16'h0) ? 16'h0500 : cfg_completer_id,
                        1'b0,
                        3'b000,
                        12'd4,
                        32'h4A00_0001
                    };
                    // DW2 = {RequesterID[15:0], Tag[7:0], 1'b0, LowerAddr[6:0]}
                    cpld_b1 <= {
                        cpl_rdata,
                        bar0_pend_reqid,
                        bar0_pend_tag,
                        1'b0,
                        bar0_pend_laddr[6:0]
                    };
                    cpld_state <= CPLD_B0;
                end
            end

            CPLD_B0: begin
                if (cpld_tx_ready) cpld_state <= CPLD_B1;
            end

            CPLD_B1: begin
                if (cpld_tx_ready) cpld_state <= CPLD_IDLE;
            end

            default: cpld_state <= CPLD_IDLE;
        endcase
    end
end

// CplD combinatorial outputs
always_comb begin
    cpld_valid = 1'b0;
    cpld_tdata = '0;
    cpld_tkeep = 8'h00;
    cpld_tlast = 1'b0;
    case (cpld_state)
        CPLD_B0: begin
            cpld_valid = 1'b1;
            cpld_tdata = cpld_b0;
            cpld_tkeep = 8'hFF;
            cpld_tlast = 1'b0;
        end
        CPLD_B1: begin
            cpld_valid = 1'b1;
            cpld_tdata = cpld_b1;
            cpld_tkeep = 8'hFF;
            cpld_tlast = 1'b1;
        end
        default: ;
    endcase
end

// =============================================================================
// SECTION 9 — MSI-X MemWr + MSI handshake (user_clk domain)
//
// MSI-X: host-programmed table in BAR4; emit a 4DW MemWr TLP per irq_pulse.
// MSI:    cfg_interrupt held until cfg_interrupt_rdy (not a 1-cycle pulse).
// INTx is not implemented; Realtek uses MSI/MSI-X.
// =============================================================================
logic [63:0] msix_tx_tdata;
logic [7:0]  msix_tx_tkeep;
logic        msix_tx_tvalid, msix_tx_tlast, msix_tx_tready;

logic [31:0] msix_irq_bus;
assign msix_irq_bus = {31'b0, irq_pulse & cfg_interrupt_msixenable};

msix_mwr_tx #(
    .NUM_VECTORS(rtl8125b_identity_pkg::MSIX_VECTORS)
) u_msix_tx (
    .clk            (user_clk),
    .rst_n          (user_rst_n),
    .irq_req        (msix_irq_bus),
    .msix_enable    (cfg_interrupt_msixenable),
    .function_mask  (cfg_interrupt_msixfm),
    .vec_rd_idx     (msix_vec_idx),
    .vec_addr       (msix_vec_addr),
    .vec_data       (msix_vec_data),
    .vec_mask       (msix_vec_mask),
    .pba_set        (msix_pba_set),
    .pba_clear      (msix_pba_clear),
    .completer_id   (cfg_completer_id),
    .s_axis_tx_tdata(msix_tx_tdata),
    .s_axis_tx_tkeep(msix_tx_tkeep),
    .s_axis_tx_tvalid(msix_tx_tvalid),
    .s_axis_tx_tlast(msix_tx_tlast),
    .s_axis_tx_tuser(),
    .s_axis_tx_tready(msix_tx_tready),
    .busy           ()
);

pcie_msi_trigger #(
    .NUM_VECTORS(8),
    .STRETCH_CYC(4)
) u_msi (
    .pcie_clk               (user_clk),
    .pcie_rst_n             (user_rst_n),
    .src_clk                (user_clk),
    .irq_req                ({7'b0, irq_pulse & ~cfg_interrupt_msixenable}),
    .vector_mask            (8'h0),
    .cfg_interrupt          (cfg_interrupt),
    .cfg_interrupt_rdy      (cfg_interrupt_rdy),
    .cfg_interrupt_msienable(cfg_interrupt_msienable),
    .cfg_interrupt_mmenable (cfg_interrupt_mmenable),
    .cfg_interrupt_assert   (cfg_interrupt_assert),
    .cfg_interrupt_di       (cfg_interrupt_di),
    .pending                (),
    .busy                   ()
);

// =============================================================================
// SECTION 10 — TX Arbitration (user_clk domain)
//
// Priority: CplD (latency-sensitive) > MSI-X MemWr > DMA engine TLPs.
// Source is locked for the duration of a TLP (until tlast + ready).
// =============================================================================
localparam logic [1:0] TXSRC_DMA  = 2'd0;
localparam logic [1:0] TXSRC_CPLD = 2'd1;
localparam logic [1:0] TXSRC_MSIX = 2'd2;

logic [1:0] tx_sel;
logic       tx_in_tlp;

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        tx_sel    <= TXSRC_DMA;
        tx_in_tlp <= 1'b0;
    end else begin
        if (!tx_in_tlp) begin
            if (cpld_valid)
                tx_sel <= TXSRC_CPLD;
            else if (msix_tx_tvalid)
                tx_sel <= TXSRC_MSIX;
            else
                tx_sel <= TXSRC_DMA;
            if (s_axis_tx_tvalid && s_axis_tx_tready && !s_axis_tx_tlast)
                tx_in_tlp <= 1'b1;
        end else begin
            if (s_axis_tx_tvalid && s_axis_tx_tready && s_axis_tx_tlast)
                tx_in_tlp <= 1'b0;
        end
    end
end

always_comb begin
    s_axis_tx_tdata  = dma_tx_data;
    s_axis_tx_tkeep  = dma_tx_keep;
    s_axis_tx_tvalid = dma_tx_valid;
    s_axis_tx_tlast  = dma_tx_last;
    cpld_tx_ready    = 1'b0;
    dma_tx_ready     = 1'b0;
    msix_tx_tready   = 1'b0;

    unique case (tx_sel)
        TXSRC_CPLD: begin
            s_axis_tx_tdata  = cpld_tdata;
            s_axis_tx_tkeep  = cpld_tkeep;
            s_axis_tx_tvalid = cpld_valid;
            s_axis_tx_tlast  = cpld_tlast;
            cpld_tx_ready    = s_axis_tx_tready;
        end
        TXSRC_MSIX: begin
            s_axis_tx_tdata  = msix_tx_tdata;
            s_axis_tx_tkeep  = msix_tx_tkeep;
            s_axis_tx_tvalid = msix_tx_tvalid;
            s_axis_tx_tlast  = msix_tx_tlast;
            msix_tx_tready   = s_axis_tx_tready;
        end
        default: begin
            dma_tx_ready = s_axis_tx_tready;
        end
    endcase
end

endmodule
