// lang: SystemVerilog, file: pcie_custom_endpoint_top.sv
// target: Xilinx Artix-7 XC7A35T, Vivado 2023.x
// function: PCIe endpoint top — TLP parser/builder, BAR0 CplD, DMA engine,
//           CDC across ft601_clk/user_clk, TX arbitration, EAC-evasion wiring.
//
// All ChatGPT-identified bugs corrected:
//   #1  rx_dw2/rx_dw3 undriven    — captured from AXI-Stream beat1
//   #2  rx_active never driven    — assigned from m_axis_rx_tvalid
//   #3  DMA RF CDC disconnected   — xpm_fifo_async cmd+rsp FIFOs added
//   #4  .rsp_start(1'b0) perma-0  — wired from TLP-decode pipeline
//   #5  CplD data mux wrong       — MUX: BAR0 shadow RAM vs cfg_rdata
//   #6  No CDC                    — xpm_fifo_async for cmd and response paths

`timescale 1ns/1ps

module pcie_custom_endpoint_top
    import rtl8125b_identity_pkg::*;
#(
    parameter bit ENABLE_TLP_JITTER = 1'b0,
    parameter bit ENABLE_SHADOW     = 1'b1,
    parameter logic [47:0] MAC_ADDR = rtl8125b_identity_pkg::MAC_ADDR
) (
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
    input  logic  [21:0] m_axis_rx_tuser,

    // PCIe config (user_clk)
    input  logic [15:0] cfg_completer_id,
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

    // ---- FT601 USB3 (ft601_clk domain) ----
    input  logic        ft601_clk,
    input  logic        ft601_rst_n,
    input  logic        ft601_rxf_n,
    output logic        ft601_oe_n,
    output logic        ft601_rd_n,
    output logic        ft601_wr_n,
    input  logic        ft601_txe_n,
    inout  wire  [31:0] ft601_data,
    inout  wire   [3:0] ft601_be
);

// ─── user_rst_n (active-low, synchronized) ───────────────────────────────────
logic user_rst_n;
assign user_rst_n = ~user_reset;

// ─── 7-series: RX cannot be back-pressured ───────────────────────────────────
assign m_axis_rx_tready = 1'b1;

// TX user sideband is unused (no error forward, no streaming ECRC).
assign s_axis_tx_tuser = 4'h0;

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
// SECTION 2 — Command parser (ft601_clk domain)
// =============================================================================
// RF interface signals (ft601_clk side)
logic        rf_we_ft, rf_re_ft;
logic [31:0] rf_waddr_ft, rf_wdata_ft, rf_raddr_ft;
logic [31:0] rf_rdata_ft;
logic        rf_rvalid_ft;
logic        frame_start_ft, frame_done_ft, bad_opcode_err_ft;
logic        read_start_ft, rsp_busy_ft;
logic [15:0] read_length_ft;
logic        cmd_ready_ft;
logic  [7:0] last_opcode_ft;
logic [31:0] last_base_addr_ft;

ft601_cmd_parser u_cmd_parser (
    .clk           (ft601_clk),
    .rst_n         (ft601_rst_n),
    .fifo_rd_valid (fifo_rd_valid),
    .fifo_rd_ready (fifo_rd_ready),
    .fifo_rd_data  (fifo_rd_data),
    .accept_frame  (!rsp_busy_ft),
    .rf_ready      (cmd_ready_ft),
    .rf_we         (rf_we_ft),
    .rf_waddr      (rf_waddr_ft),
    .rf_wdata      (rf_wdata_ft),
    .rf_re         (rf_re_ft),
    .rf_raddr      (rf_raddr_ft),
    .rf_rdata      (rf_rdata_ft),
    .rf_rvalid     (rf_rvalid_ft),
    .frame_start   (frame_start_ft),
    .read_start    (read_start_ft),
    .read_length   (read_length_ft),
    .frame_done    (frame_done_ft),
    .bad_opcode_err(bad_opcode_err_ft),
    .last_opcode   (last_opcode_ft),
    .last_base_addr(last_base_addr_ft)
);

// =============================================================================
// SECTION 3 — CDC: ft601_clk → user_clk  (command FIFO)  (#6 fix)
// =============================================================================
// Command word: {is_write[0], addr[31:0], wdata[31:0]} = 65 bits
// Pack: {rf_we_ft, rf_waddr_ft, rf_wdata_ft}  for writes
//        {1'b0,    rf_raddr_ft, 32'h0}         for reads
logic        cmd_fifo_wr_en;
logic [64:0] cmd_fifo_din;
logic        cmd_fifo_full;
logic        cmd_wr_busy, cmd_rd_busy;
logic        rsp_wr_busy, rsp_rd_busy;
logic        rsp_fifo_full;

logic        cmd_fifo_rd_en;
logic [64:0] cmd_fifo_dout;
logic        cmd_fifo_empty;

assign cmd_ready_ft = !cmd_fifo_full && !cmd_wr_busy;
assign cmd_fifo_wr_en = (rf_we_ft || rf_re_ft) && cmd_ready_ft;
assign cmd_fifo_din   = rf_we_ft
                      ? {1'b1, rf_waddr_ft, rf_wdata_ft}
                      : {1'b0, rf_raddr_ft, 32'h0};

xpm_fifo_async #(
    .FIFO_WRITE_DEPTH(16),
    .WRITE_DATA_WIDTH(65),
    .FIFO_MEMORY_TYPE("block"),      // "block" keeps gray counter as FFs (not RAM32M).
    .CDC_SYNC_STAGES (2),
    .READ_MODE       ("fwft"),
    .FIFO_READ_LATENCY(0),
    .USE_ADV_FEATURES("0000")
) u_cmd_cdc (
    .wr_clk   (ft601_clk),
    .rd_clk   (user_clk),
    .rst      (~ft601_rst_n),
    .wr_en    (cmd_fifo_wr_en),
    .din      (cmd_fifo_din),
    .full     (cmd_fifo_full),
    .rd_en    (cmd_fifo_rd_en),
    .dout     (cmd_fifo_dout),
    .empty    (cmd_fifo_empty),
    // unused
    .wr_rst_busy(cmd_wr_busy), .rd_rst_busy(cmd_rd_busy),
    .almost_full(), .almost_empty(),
    .wr_data_count(), .rd_data_count(),
    .overflow(), .underflow(),
    .prog_full(), .prog_empty(),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .sbiterr(), .dbiterr()
);

// user_clk side: unpack command and drive dma_engine RF
logic        rf_we_uc, rf_re_uc;
logic [31:0] rf_waddr_uc, rf_wdata_uc, rf_raddr_uc;

assign cmd_fifo_rd_en = !cmd_fifo_empty && !cmd_rd_busy && !user_reset &&
    (cmd_fifo_dout[64] || (!rsp_wr_busy && !rsp_fifo_full));
assign rf_we_uc   =  cmd_fifo_dout[64] && cmd_fifo_rd_en;
assign rf_re_uc   = !cmd_fifo_dout[64] && cmd_fifo_rd_en;
assign rf_waddr_uc = cmd_fifo_dout[63:32];
assign rf_wdata_uc = cmd_fifo_dout[31:0];
assign rf_raddr_uc = cmd_fifo_dout[63:32];

// =============================================================================
// SECTION 4 — CDC: user_clk → ft601_clk  (response FIFO)  (#6 fix)
// =============================================================================
logic        rsp_fifo_wr_en;
logic [31:0] rsp_fifo_din;

logic        rsp_fifo_rd_en;
logic [31:0] rsp_fifo_dout;
logic        rsp_fifo_empty;

xpm_fifo_async #(
    .FIFO_WRITE_DEPTH(16),
    .WRITE_DATA_WIDTH(32),
    .FIFO_MEMORY_TYPE("block"),      // "block" keeps gray counter as FFs (not RAM32M).
    .CDC_SYNC_STAGES (2),
    .READ_MODE       ("fwft"),
    .FIFO_READ_LATENCY(0),
    .USE_ADV_FEATURES("0000")
) u_rsp_cdc (
    .wr_clk   (user_clk),
    .rd_clk   (ft601_clk),
    .rst      (~user_rst_n),
    .wr_en    (rsp_fifo_wr_en),
    .din      (rsp_fifo_din),
    .full     (rsp_fifo_full),
    .rd_en    (rsp_fifo_rd_en),
    .dout     (rsp_fifo_dout),
    .empty    (rsp_fifo_empty),
    .wr_rst_busy(rsp_wr_busy), .rd_rst_busy(rsp_rd_busy),
    .almost_full(), .almost_empty(),
    .wr_data_count(), .rd_data_count(),
    .overflow(), .underflow(),
    .prog_full(), .prog_empty(),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .sbiterr(), .dbiterr()
);

// Drive rf_rdata_ft from response FIFO (ft601_clk domain)
assign rf_rdata_ft    = rsp_fifo_empty ? 32'hDEAD_BEEF : rsp_fifo_dout;
assign rf_rvalid_ft   = rsp_fifo_rd_en;

// =============================================================================
// SECTION 5 — DMA engine (user_clk domain)
// =============================================================================
logic [31:0] rf_rdata_uc;
logic        rf_rvalid_uc;

// Push DMA read-back into response FIFO
assign rsp_fifo_wr_en = rf_rvalid_uc && !rsp_fifo_full && !rsp_wr_busy;
assign rsp_fifo_din   = rf_rdata_uc;

// TX from DMA engine
logic [63:0] dma_tx_data;
logic  [7:0] dma_tx_keep;
logic        dma_tx_valid, dma_tx_last;
logic        dma_tx_ready;

// Jitter signals
logic        dma_cpl_seen, dma_hold_req;

logic rx_cpl_valid_w, rx_cpl_ready_w;
logic [63:0] rx_cpl_data_w;
logic  [7:0] rx_cpl_keep_w;
logic        rx_cpl_last_w;

dma_engine u_dma (
    .user_clk        (user_clk),
    .user_rst_n      (user_rst_n),
    .rf_we           (rf_we_uc),
    .rf_waddr        (rf_waddr_uc),
    .rf_wdata        (rf_wdata_uc),
    .rf_re           (rf_re_uc),
    .rf_raddr        (rf_raddr_uc),
    .rf_rdata        (rf_rdata_uc),
    .rf_rvalid       (rf_rvalid_uc),
    .cfg_completer_id(cfg_completer_id),
    .cfg_max_payload_size(cfg_max_payload_size),
    .tx_req_valid    (dma_tx_valid),
    .tx_req_ready    (dma_tx_ready),
    .tx_req_data     (dma_tx_data),
    .tx_req_keep     (dma_tx_keep),
    .tx_req_last     (dma_tx_last),
    .rx_cpl_valid    (rx_cpl_valid_w),
    .rx_cpl_ready    (rx_cpl_ready_w),
    .rx_cpl_data     (rx_cpl_data_w),
    .rx_cpl_keep     (rx_cpl_keep_w),
    .rx_cpl_last     (rx_cpl_last_w),
    .dma_cpl_seen    (dma_cpl_seen),
    .dma_hold_req    (dma_hold_req)
);

// Jitter is off the default NIC/DMA path. Enabling it delays DMA MRd
// issue only; BAR completions still look like a NIC.
logic jitter_hold;
tlp_jitter_fsm u_jitter (
    .clk         (user_clk),
    .rst_n       (user_rst_n),
    .dma_cpl_seen(dma_cpl_seen),
    .dma_hold_req(jitter_hold)
);
assign dma_hold_req = ENABLE_TLP_JITTER ? jitter_hold : 1'b0;

// =============================================================================
// SECTION 6 — TLP RX parser  (#1 fix: capture beat1 → rx_dw2/rx_dw3)
// =============================================================================
// 64-bit AXI-Stream, 4DW header:
//   Beat0: {DW1, DW0}   Beat1: {DW3, DW2}   Beat2+: payload until tlast
// Packet class is taken from the live beat-0 DW0 and held until tlast.
// Classifying from the registered DW0 is one beat late and drops CplD beat 0.
logic [31:0] rx_dw0_q, rx_dw1_q, rx_dw2_q, rx_dw3_q;
logic        rx_hdr_valid_q;    // header fully captured (pulses the next cycle)

typedef enum logic [1:0] { RX_HDR0, RX_HDR1, RX_PAY } rx_phase_e;
rx_phase_e rx_phase_q;
logic      rx_in_pkt_q;
logic      rx_pkt_cpld_q, rx_pkt_memwr_q, rx_pkt_iowr_q;
logic      rx_pay_latched_q;
logic [6:0] rx_bar_hit_q;
logic       rx_hdr_4dw_q;

// (#2 fix: rx_active from AXI-Stream)
logic rx_active;
assign rx_active = m_axis_rx_tvalid;

// Live beat-0 decode (m_axis_rx_tdata[31:0] is DW0 on the first beat).
logic [1:0] live_fmt;
logic [4:0] live_type;
logic       live_is_cpld, live_is_memwr, live_is_iowr;
assign live_fmt      = m_axis_rx_tdata[30:29];
assign live_type     = m_axis_rx_tdata[28:24];
assign live_is_cpld  = (live_fmt == 2'b10) && (live_type == 5'b01010);
assign live_is_memwr = (live_type == 5'b00000) && live_fmt[1];          // 3DW or 4DW MemWr
assign live_is_iowr  = (live_type == 5'b00010) && live_fmt[1];          // IOWr

// Held class. On beat 0 (rx_in_pkt_q == 0) the live DW0 is the class.
logic rx_is_cpld;
assign rx_is_cpld = rx_in_pkt_q ? rx_pkt_cpld_q : live_is_cpld;

// Header fields from the captured beat-0 DW0. These are stable on the
// cycle rx_hdr_valid_q is set, which is one cycle after beat 1.
logic [1:0] rx_fmt;
logic [4:0] rx_type;
logic [9:0] rx_length;
logic       rx_is_memrd, rx_is_iord, rx_is_bar_rd;
assign rx_fmt      = rx_dw0_q[30:29];
assign rx_type     = rx_dw0_q[28:24];
assign rx_length   = rx_dw0_q[9:0];
assign rx_is_memrd = (rx_type == 5'b00000) && !rx_fmt[1];               // 3DW or 4DW MemRd
assign rx_is_iord  = (rx_type == 5'b00010) && !rx_fmt[1];
assign rx_is_bar_rd = rx_is_memrd || rx_is_iord;

// Address: 4DW Mem uses DW3 as low; 3DW Mem/IO uses DW2 as low.
logic [31:0] rx_bar0_addr;
assign rx_bar0_addr = rx_hdr_4dw_q ? rx_dw3_q : rx_dw2_q;

// tuser[8:2] = {EXPROM, BAR5..BAR0}. Empty tuser (TB) falls back to MAC BAR.
logic hit_io, hit_mac, hit_msix;
assign hit_io   = rx_bar_hit_q[0];
assign hit_mac  = rx_bar_hit_q[2] || (rx_bar_hit_q == 7'h0 && !hit_msix);
assign hit_msix = rx_bar_hit_q[4];

// requester ID and tag for BAR0 CplD
logic [15:0] rx_req_id;
logic  [7:0] rx_tag;
assign rx_req_id = rx_dw1_q[31:16];
assign rx_tag    = rx_dw1_q[15:8];

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        rx_dw0_q        <= '0;
        rx_dw1_q        <= '0;
        rx_dw2_q        <= '0;  // (#1 fix)
        rx_dw3_q        <= '0;  // (#1 fix)
        rx_hdr_valid_q  <= 1'b0;
        rx_phase_q      <= RX_HDR0;
        rx_in_pkt_q     <= 1'b0;
        rx_pkt_cpld_q   <= 1'b0;
        rx_pkt_memwr_q  <= 1'b0;
        rx_pkt_iowr_q   <= 1'b0;
        rx_pay_latched_q <= 1'b0;
        rx_bar_hit_q    <= 7'h0;
        rx_hdr_4dw_q    <= 1'b1;
    end else begin
        rx_hdr_valid_q <= 1'b0;
        if (m_axis_rx_tvalid && !rx_in_pkt_q) begin
            // Beat 0 of a new packet. Classify from the DW0 on this beat.
            rx_dw0_q       <= m_axis_rx_tdata[31:0];
            rx_dw1_q       <= m_axis_rx_tdata[63:32];
            rx_pkt_cpld_q  <= live_is_cpld;
            rx_pkt_memwr_q <= live_is_memwr || live_is_iowr;
            rx_pkt_iowr_q  <= live_is_iowr;
            rx_bar_hit_q   <= m_axis_rx_tuser[8:2];
            rx_hdr_4dw_q   <= live_fmt[0];
            rx_pay_latched_q <= 1'b0;
            if (m_axis_rx_tlast) begin
                rx_in_pkt_q <= 1'b0;
                rx_phase_q  <= RX_HDR0;
            end else begin
                rx_in_pkt_q <= 1'b1;
                rx_phase_q  <= RX_HDR1;
            end
        end else if (m_axis_rx_tvalid && rx_phase_q == RX_HDR1) begin
            // Beat 1: 4DW {DW3, DW2}; 3DW write {data, addr}.
            rx_dw2_q       <= m_axis_rx_tdata[31:0];
            rx_dw3_q       <= m_axis_rx_tdata[63:32];
            rx_hdr_valid_q <= 1'b1;
            if (m_axis_rx_tlast) begin
                rx_in_pkt_q <= 1'b0;
                rx_phase_q  <= RX_HDR0;
            end else begin
                rx_phase_q <= RX_PAY;
            end
        end else if (m_axis_rx_tvalid && rx_phase_q == RX_PAY) begin
            // Payload beats are not a new header. Stay here until tlast.
            // Latch-once flag so a multi-DW MemWr commits only its first DW.
            if (rx_pkt_memwr_q && !rx_pay_latched_q)
                rx_pay_latched_q <= 1'b1;
            if (m_axis_rx_tlast) begin
                rx_in_pkt_q <= 1'b0;
                rx_phase_q  <= RX_HDR0;
            end
        end
    end
end

// =============================================================================
// SECTION 7 — CplD routing: separate BAR0 completions from DMA completions
// =============================================================================
// A CplD is for the DMA engine if tag matches pend_tag (tracked in dma_engine).
// Everything else stays with the BAR0 path.
// Simple heuristic: CplD with fmt=10/type=01010 arrives at AXI-Stream RX.
// We tee the stream: dma_engine gets it via rx_cpl_* wires; BAR0 ignores it.



// Route the raw AXI-Stream RX to dma_engine when the packet class,
// sampled on beat 0 and held until tlast, is CplD. Every beat of that
// packet is forwarded, including beat 0.
assign rx_cpl_valid_w = m_axis_rx_tvalid && rx_is_cpld;
assign rx_cpl_data_w  = m_axis_rx_tdata;
assign rx_cpl_keep_w  = m_axis_rx_tkeep;
assign rx_cpl_last_w  = m_axis_rx_tlast;
// rx_cpl_ready_w comes back from dma_engine; we ignore it (RX can't back-pressure)

// =============================================================================
// SECTION 8 — BAR0 shadow RAM read + CplD builder  (#4 fix, #5 fix)
// =============================================================================
// When a 4DW MemRd targeting BAR0 is detected, we build a CplD using data
// from rtl8125b_bar0_regs (shadow RAM). Priority over DMA TLPs.

logic [31:0] bar0_rdata;
logic        bar0_rvalid;
logic        bar0_mem_rd_en, bar0_mem_wr_en;
logic [15:0] bar0_byte_addr;
logic [31:0] bar0_wdata, bar0_wdata_q;
logic  [3:0] bar0_be, bar0_be_q;
logic        bar0_mem_wr_en_q;
logic        bar0_wr_pend_q;
logic        bar0_rd_pending_set;
logic        irq_pulse;

// BAR0 access is from host MemRd/MemWr — decode address from rx_dw3.
// wdata / First BE are latched from the first payload beat; mem_wr_en
// pulses the cycle after that latch so the register bank sees both.
assign bar0_byte_addr = rx_bar0_addr[15:0];
assign bar0_wdata     = bar0_wdata_q;
assign bar0_be        = bar0_be_q;
assign bar0_mem_wr_en = bar0_mem_wr_en_q && (hit_mac || hit_io);

logic        msix_mem_wr_en, msix_mem_rd_en;
logic        msix_rvalid;
logic [31:0] msix_rdata;
assign msix_mem_wr_en = bar0_mem_wr_en_q && hit_msix;

// Trigger MAC/MSI-X read when header is fully captured and it's a read TLP.
logic bar0_rd_pending_q, msix_rd_pending_q;

assign bar0_rd_pending_set = rx_hdr_valid_q && rx_is_bar_rd && (hit_mac || hit_io);
assign bar0_mem_rd_en      = bar0_rd_pending_q;
assign msix_mem_rd_en      = msix_rd_pending_q;

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        bar0_rd_pending_q <= 1'b0;
        msix_rd_pending_q <= 1'b0;
        bar0_wdata_q      <= 32'h0;
        bar0_be_q         <= 4'h0;
        bar0_mem_wr_en_q  <= 1'b0;
        bar0_wr_pend_q    <= 1'b0;
    end else begin
        bar0_mem_wr_en_q <= bar0_wr_pend_q;
        bar0_wr_pend_q   <= 1'b0;

        if (bar0_rd_pending_set)      bar0_rd_pending_q <= 1'b1;
        else if (bar0_rvalid)         bar0_rd_pending_q <= 1'b0;

        if (rx_hdr_valid_q && rx_is_bar_rd && hit_msix)
            msix_rd_pending_q <= 1'b1;
        else if (msix_rvalid)
            msix_rd_pending_q <= 1'b0;

        // 4DW MemWr payload on RX_PAY; 3DW IOWr/MemWr payload on HDR1 high half.
        if (m_axis_rx_tvalid && rx_pkt_memwr_q && !rx_pay_latched_q) begin
            if (rx_phase_q == RX_PAY) begin
                bar0_wdata_q   <= m_axis_rx_tdata[31:0];
                bar0_be_q      <= rx_dw1_q[3:0];
                bar0_wr_pend_q <= 1'b1;
            end else if (rx_phase_q == RX_HDR1 && m_axis_rx_tlast && !rx_hdr_4dw_q) begin
                bar0_wdata_q   <= m_axis_rx_tdata[63:32];
                bar0_be_q      <= rx_dw1_q[3:0];
                bar0_wr_pend_q <= 1'b1;
            end
        end
    end
end

rtl8125b_bar0_regs #(
    .ENABLE_SHADOW(ENABLE_SHADOW),
    .MAC_ADDR     (MAC_ADDR)
) u_bar0 (
    .clk               (user_clk),
    .rst_n             (user_rst_n),
    .mem_wr_en         (bar0_mem_wr_en),
    .mem_rd_en         (bar0_mem_rd_en),
    .mem_byte_addr     (bar0_byte_addr),
    .mem_wdata         (bar0_wdata),
    .mem_be            (bar0_be),
    .mem_rdata         (bar0_rdata),
    .mem_rvalid        (bar0_rvalid),
    .tx_desc_ring_level(16'h0),
    .rx_desc_ring_level(16'h0),
    .irq_pulse         (irq_pulse)
);

logic [$clog2(MSIX_VECTORS)-1:0] msix_vec_idx;
logic [63:0] msix_vec_addr;
logic [31:0] msix_vec_data;
logic        msix_vec_mask;
logic [MSIX_VECTORS-1:0] msix_pba_set, msix_pba_clr, msix_pba_bits;
logic [MSIX_VECTORS-1:0] msix_irq_bus;
assign msix_irq_bus = {{(MSIX_VECTORS-1){1'b0}}, irq_pulse};

msix_table_pba #(
    .NUM_VECTORS         (MSIX_VECTORS),
    .TABLE_BAR_BYTE_BASE (MSIX_TABLE_BYTE_OFF),
    .PBA_BAR_BYTE_BASE   (MSIX_PBA_BYTE_OFF)
) u_msix_tbl (
    .clk           (user_clk),
    .rst_n         (user_rst_n),
    .mem_wr_en     (msix_mem_wr_en),
    .mem_rd_en     (msix_mem_rd_en),
    .mem_byte_addr (bar0_byte_addr),
    .mem_wdata     (bar0_wdata),
    .mem_be        (bar0_be),
    .mem_rdata     (msix_rdata),
    .mem_rvalid    (msix_rvalid),
    .vec_rd_idx    (msix_vec_idx),
    .vec_addr      (msix_vec_addr),
    .vec_data      (msix_vec_data),
    .vec_mask      (msix_vec_mask),
    .pba_set       (msix_pba_set),
    .pba_clear     (msix_pba_clr),
    .pba_bits      (msix_pba_bits)
);

logic [63:0] msix_tx_data;
logic [7:0]  msix_tx_keep;
logic        msix_tx_valid, msix_tx_last, msix_tx_ready;
logic [3:0]  msix_tx_user;
logic        msix_tx_busy;

msix_mwr_tx #(.NUM_VECTORS(MSIX_VECTORS)) u_msix_tx (
    .clk              (user_clk),
    .rst_n            (user_rst_n),
    .irq_req          (msix_irq_bus),
    .msix_enable      (cfg_interrupt_msixenable),
    .function_mask    (cfg_interrupt_msixfm),
    .vec_rd_idx       (msix_vec_idx),
    .vec_addr         (msix_vec_addr),
    .vec_data         (msix_vec_data),
    .vec_mask         (msix_vec_mask),
    .pba_set          (msix_pba_set),
    .pba_clear        (msix_pba_clr),
    .completer_id     (cfg_completer_id),
    .s_axis_tx_tdata  (msix_tx_data),
    .s_axis_tx_tkeep  (msix_tx_keep),
    .s_axis_tx_tvalid (msix_tx_valid),
    .s_axis_tx_tlast  (msix_tx_last),
    .s_axis_tx_tuser  (msix_tx_user),
    .s_axis_tx_tready (msix_tx_ready),
    .busy             (msix_tx_busy)
);

// MSI: 1 vector, maskable. Core handshake is unused while MSI-X is armed.
pcie_msi_trigger #(
    .NUM_VECTORS(1),
    .STRETCH_CYC(4)
) u_msi (
    .pcie_clk               (user_clk),
    .pcie_rst_n             (user_rst_n),
    .src_clk                (user_clk),
    .irq_req                (irq_pulse),
    .vector_mask            (1'b0),
    .cfg_interrupt          (cfg_interrupt),
    .cfg_interrupt_rdy      (cfg_interrupt_rdy),
    .cfg_interrupt_msienable(cfg_interrupt_msienable && !cfg_interrupt_msixenable),
    .cfg_interrupt_mmenable (cfg_interrupt_mmenable),
    .cfg_interrupt_assert   (cfg_interrupt_assert),
    .cfg_interrupt_di       (cfg_interrupt_di),
    .pending                (),
    .busy                   ()
);

// BAR0 completion with one DWORD of data. Snapshot both beats so a stall
// or a change to the receive-side registers cannot alter an offered beat.
localparam logic [31:0] CPLD_DW0 = 32'h4A00_0001;
typedef enum logic [1:0] {BAR_IDLE, BAR_B0, BAR_B1} bar_tx_state_t;
bar_tx_state_t bar_tx_q;
logic [63:0] bar_tx_data_q, bar_tx_payload_q;
wire bar_tx_last = bar_tx_q == BAR_B1;

logic        bar_cpl_fire;
logic [31:0] bar_cpl_data;
assign bar_cpl_fire = bar0_rvalid || msix_rvalid;
assign bar_cpl_data = msix_rvalid ? msix_rdata : bar0_rdata;

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        bar_tx_q         <= BAR_IDLE;
        bar_tx_data_q    <= '0;
        bar_tx_payload_q <= '0;
    end else begin
        case (bar_tx_q)
            BAR_IDLE: if (bar_cpl_fire) begin
                bar_tx_data_q <= {cfg_completer_id, 3'b000, 1'b0, 12'd4, CPLD_DW0};
                // Lower Address is the DWORD-aligned byte offset of the first
                // returned byte (PCIe CplD DW2[6:0]).
                bar_tx_payload_q <= {
                    bar_cpl_data, rx_req_id, rx_tag, 1'b0,
                    rx_bar0_addr[6:2], 2'b00
                };
                bar_tx_q <= BAR_B0;
            end
            BAR_B0: if (s_axis_tx_tready) begin
                bar_tx_data_q <= bar_tx_payload_q;
                bar_tx_q <= BAR_B1;
            end
            BAR_B1: if (s_axis_tx_tready)
                bar_tx_q <= BAR_IDLE;
            default: bar_tx_q <= BAR_IDLE;
        endcase
    end
end

// =============================================================================
// SECTION 9 — TX arbitration: BAR0 CplD (hi) > DMA TLPs (lo)
// =============================================================================
// Prioritize an outstanding BAR0 completion.

logic bar_tx_active;
assign bar_tx_active = (bar_tx_q != BAR_IDLE);

always_comb begin
    msix_tx_ready = 1'b0;
    dma_tx_ready  = 1'b0;
    if (bar_tx_active) begin
        s_axis_tx_tdata  = bar_tx_data_q;
        s_axis_tx_tkeep  = 8'hff;
        s_axis_tx_tvalid = 1'b1;
        s_axis_tx_tlast  = bar_tx_last;
    end else if (msix_tx_valid) begin
        s_axis_tx_tdata  = msix_tx_data;
        s_axis_tx_tkeep  = msix_tx_keep;
        s_axis_tx_tvalid = 1'b1;
        s_axis_tx_tlast  = msix_tx_last;
        msix_tx_ready    = s_axis_tx_tready;
    end else begin
        s_axis_tx_tdata  = dma_tx_data;
        s_axis_tx_tkeep  = dma_tx_keep;
        s_axis_tx_tvalid = dma_tx_valid && !dma_hold_req;
        s_axis_tx_tlast  = dma_tx_last;
        dma_tx_ready     = s_axis_tx_tready && !dma_hold_req;
    end
end

// =============================================================================
// SECTION 10 — Response packager (ft601_clk domain)
// =============================================================================
// Open the response on the read command. Pop each payload word only when
// the packager accepts it, then allow the parser to issue the next read.
logic        rsp_done_ft;
logic        pld_valid_ft, pld_ready_ft;
logic [31:0] pld_data_ft;
logic        rsp_fifo_wr_valid_ft, rsp_fifo_wr_ready_ft;
logic [31:0] rsp_fifo_wr_data_ft;
logic        rsp_fifo_wr_last_ft;

// Payload: data from response FIFO (already in ft601_clk after CDC)
assign pld_valid_ft  = ft601_rst_n && !rsp_fifo_empty && !rsp_rd_busy;
assign rsp_fifo_rd_en = pld_valid_ft && pld_ready_ft;
assign pld_data_ft   = rsp_fifo_dout;

ft601_resp_packager u_resp_packager (
    .clk             (ft601_clk),
    .rst_n           (ft601_rst_n),
    .rsp_start       (read_start_ft),
    .rsp_opcode_canon(last_opcode_ft),
    .rsp_flags       (8'h00),
    .rsp_addr        (fifo_rd_data),
    .rsp_length_dw   (read_length_ft),
    .rsp_busy        (rsp_busy_ft),
    .rsp_done        (rsp_done_ft),
    .pld_valid       (pld_valid_ft),
    .pld_ready       (pld_ready_ft),
    .pld_data        (pld_data_ft),
    .fifo_wr_valid   (fifo_wr_valid),
    .fifo_wr_ready   (fifo_wr_ready),
    .fifo_wr_data    (fifo_wr_data),
    .fifo_wr_last    (rsp_fifo_wr_last_ft),
    .bad_opcode_err  ()
);

// fifo_wr_be: all bytes valid for response frames
assign fifo_wr_be = 4'hF;

endmodule
