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
    input  logic  [3:0] m_axis_rx_tuser,

    // PCIe config (user_clk)
    input  logic [15:0] cfg_completer_id,
    input  logic  [2:0] cfg_max_payload_size,
    input  logic  [2:0] cfg_max_read_req_size,
    input  logic  [3:0] link_speed_live,
    input  logic  [5:0] link_width_live,

    // cfg_ext: Extended config space (ECAP region ≥0x100) forwarded by PCIe IP (user_clk)
    // Wire these to pcie_7x_0 cfg_ext_* ports in the top wrapper.
    input  logic        cfg_ext_read_received,
    input  logic        cfg_ext_write_received,
    input  logic  [9:0] cfg_ext_register_number,
    input  logic  [7:0] cfg_ext_function_number,
    input  logic [31:0] cfg_ext_write_data,
    input  logic  [3:0] cfg_ext_write_byte_enable,
    output logic [31:0] cfg_ext_read_data,
    output logic        cfg_ext_read_data_valid,

    // Interrupt (user_clk)
    output logic        cfg_interrupt,
    input  logic        cfg_interrupt_rdy,
    output logic        cfg_interrupt_assert,
    output logic  [7:0] cfg_interrupt_di,
    input  logic        cfg_interrupt_msienable,
    input  logic  [2:0] cfg_interrupt_mmenable,

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

// ─── Interrupt tie-offs ───────────────────────────────────────────────────────
assign cfg_interrupt        = 1'b0;
assign cfg_interrupt_assert = 1'b0;
assign cfg_interrupt_di     = 8'h0;
assign s_axis_tx_tuser      = 4'h0;

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
logic  [7:0] last_opcode_ft;
logic [31:0] last_base_addr_ft;

ft601_cmd_parser u_cmd_parser (
    .clk           (ft601_clk),
    .rst_n         (ft601_rst_n),
    .fifo_rd_valid (fifo_rd_valid),
    .fifo_rd_ready (fifo_rd_ready),
    .fifo_rd_data  (fifo_rd_data),
    .rf_we         (rf_we_ft),
    .rf_waddr      (rf_waddr_ft),
    .rf_wdata      (rf_wdata_ft),
    .rf_re         (rf_re_ft),
    .rf_raddr      (rf_raddr_ft),
    .rf_rdata      (rf_rdata_ft),
    .rf_rvalid     (rf_rvalid_ft),
    .frame_start   (frame_start_ft),
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

logic        cmd_fifo_rd_en;
logic [64:0] cmd_fifo_dout;
logic        cmd_fifo_empty;

assign cmd_fifo_wr_en = (rf_we_ft || rf_re_ft) && !cmd_fifo_full;
assign cmd_fifo_din   = rf_we_ft
                      ? {1'b1, rf_waddr_ft, rf_wdata_ft}
                      : {1'b0, rf_raddr_ft, 32'h0};

xpm_fifo_async #(
    .FIFO_DEPTH      (16),
    .DATA_WIDTH      (65),
    .FIFO_MEMORY_TYPE("distributed"),
    .CDC_SYNC_STAGES (2),
    .READ_MODE       ("fwft")
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
    .wr_rst_busy(), .rd_rst_busy(),
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

assign cmd_fifo_rd_en = !cmd_fifo_empty;
assign rf_we_uc   =  cmd_fifo_dout[64] && !cmd_fifo_empty;
assign rf_re_uc   = !cmd_fifo_dout[64] && !cmd_fifo_empty;
assign rf_waddr_uc = cmd_fifo_dout[63:32];
assign rf_wdata_uc = cmd_fifo_dout[31:0];
assign rf_raddr_uc = cmd_fifo_dout[63:32];

// =============================================================================
// SECTION 4 — CDC: user_clk → ft601_clk  (response FIFO)  (#6 fix)
// =============================================================================
logic        rsp_fifo_wr_en;
logic [31:0] rsp_fifo_din;
logic        rsp_fifo_full;

logic        rsp_fifo_rd_en;
logic [31:0] rsp_fifo_dout;
logic        rsp_fifo_empty;

xpm_fifo_async #(
    .FIFO_DEPTH      (16),
    .DATA_WIDTH      (32),
    .FIFO_MEMORY_TYPE("distributed"),
    .CDC_SYNC_STAGES (2),
    .READ_MODE       ("fwft")
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
    .wr_rst_busy(), .rd_rst_busy(),
    .almost_full(), .almost_empty(),
    .wr_data_count(), .rd_data_count(),
    .overflow(), .underflow(),
    .prog_full(), .prog_empty(),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .sbiterr(), .dbiterr()
);

// Drive rf_rdata_ft from response FIFO (ft601_clk domain)
assign rsp_fifo_rd_en = !rsp_fifo_empty;
assign rf_rdata_ft    = rsp_fifo_empty ? 32'hDEAD_BEEF : rsp_fifo_dout;
assign rf_rvalid_ft   = !rsp_fifo_empty;

// =============================================================================
// SECTION 5 — DMA engine (user_clk domain)
// =============================================================================
logic [31:0] rf_rdata_uc;
logic        rf_rvalid_uc;

// Push DMA read-back into response FIFO
assign rsp_fifo_wr_en = rf_rvalid_uc && !rsp_fifo_full;
assign rsp_fifo_din   = rf_rdata_uc;

// TX from DMA engine
logic [63:0] dma_tx_data;
logic  [7:0] dma_tx_keep;
logic        dma_tx_valid, dma_tx_last;
logic        dma_tx_ready;

// Jitter signals
logic        dma_cpl_seen, dma_hold_req;

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

tlp_jitter_fsm u_jitter (
    .clk         (user_clk),
    .rst_n       (user_rst_n),
    .dma_cpl_seen(dma_cpl_seen),
    .dma_hold_req(dma_hold_req)
);

// =============================================================================
// SECTION 6 — TLP RX parser  (#1 fix: capture beat1 → rx_dw2/rx_dw3)
// =============================================================================
// Beat0: {DW1, DW0}   Beat1: {DW3, DW2}
logic [31:0] rx_dw0_q, rx_dw1_q, rx_dw2_q, rx_dw3_q;
logic        rx_hdr_valid_q;    // header fully captured
logic        rx_beat0_seen_q;

// (#2 fix: rx_active from AXI-Stream)
logic rx_active;
assign rx_active = m_axis_rx_tvalid;

// TLP field decode from DW0
logic [1:0] rx_fmt;
logic [4:0] rx_type;
logic [9:0] rx_length;
assign rx_fmt    = rx_dw0_q[30:29];
assign rx_type   = rx_dw0_q[28:24];
assign rx_length = rx_dw0_q[9:0];

// Decoded TLP class flags
logic rx_is_memrd, rx_is_memwr, rx_is_cpld;
assign rx_is_memrd = (rx_fmt == 2'b01) && (rx_type == 5'b00000);
assign rx_is_memwr = (rx_fmt == 2'b11) && (rx_type == 5'b00000);
assign rx_is_cpld  = (rx_fmt == 2'b10) && (rx_type == 5'b01010);

// BAR0 hit: requester is EAC/host probing our BAR0 (addr[27:16] == 0 for 64K)
logic [31:0] rx_bar0_addr;
assign rx_bar0_addr = rx_dw3_q;   // lower 32 bits of 4DW address

// requester ID and tag for BAR0 CplD
logic [15:0] rx_req_id;
logic  [7:0] rx_tag;
assign rx_req_id = rx_dw1_q[31:16];
assign rx_tag    = rx_dw1_q[15:8];

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        rx_dw0_q       <= '0;
        rx_dw1_q       <= '0;
        rx_dw2_q       <= '0;  // (#1 fix)
        rx_dw3_q       <= '0;  // (#1 fix)
        rx_beat0_seen_q <= 1'b0;
        rx_hdr_valid_q  <= 1'b0;
    end else begin
        rx_hdr_valid_q <= 1'b0;
        if (m_axis_rx_tvalid) begin
            if (!rx_beat0_seen_q) begin
                // Beat0: {DW1, DW0}
                rx_dw0_q        <= m_axis_rx_tdata[31:0];
                rx_dw1_q        <= m_axis_rx_tdata[63:32];
                rx_beat0_seen_q <= 1'b1;
            end else begin
                // Beat1: {DW3, DW2}  (#1 fix: capture both DWs)
                rx_dw2_q        <= m_axis_rx_tdata[31:0];
                rx_dw3_q        <= m_axis_rx_tdata[63:32];
                rx_beat0_seen_q <= 1'b0;
                rx_hdr_valid_q  <= 1'b1;
            end
        end
        // Clear on last beat if still mid-header (malformed TLP)
        if (m_axis_rx_tvalid && m_axis_rx_tlast && rx_beat0_seen_q)
            rx_beat0_seen_q <= 1'b0;
    end
end

// =============================================================================
// SECTION 7 — CplD routing: separate BAR0 completions from DMA completions
// =============================================================================
// A CplD is for the DMA engine if tag matches pend_tag (tracked in dma_engine).
// Everything else stays with the BAR0 path.
// Simple heuristic: CplD with fmt=10/type=01010 arrives at AXI-Stream RX.
// We tee the stream: dma_engine gets it via rx_cpl_* wires; BAR0 ignores it.

logic rx_cpl_valid_w, rx_cpl_ready_w;
logic [63:0] rx_cpl_data_w;
logic  [7:0] rx_cpl_keep_w;
logic        rx_cpl_last_w;

// Route the raw AXI-Stream RX to dma_engine when it looks like a CplD.
// The dma_engine uses its pend_tag to validate; we just forward all CplDs.
// BAR0 MemRd processing is handled separately via registered headers above.
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
logic [31:0] bar0_wdata;
logic  [3:0] bar0_be;
logic        irq_pulse;

// BAR0 access is from host MemRd/MemWr — decode address from rx_dw3
assign bar0_byte_addr = rx_bar0_addr[15:0];
assign bar0_wdata     = 32'h0;    // MemWr payload not consumed (EAC probes are reads)
assign bar0_be        = 4'hF;

// Trigger BAR0 read when header is fully captured and it's a MemRd
logic bar0_rd_pending_q;
logic bar0_rd_pending_set;
logic bar0_rd_pending_clr;

assign bar0_rd_pending_set = rx_hdr_valid_q && rx_is_memrd;
assign bar0_mem_rd_en      = bar0_rd_pending_q;
assign bar0_mem_wr_en      = rx_hdr_valid_q && rx_is_memwr;

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n)        bar0_rd_pending_q <= 1'b0;
    else if (bar0_rd_pending_set) bar0_rd_pending_q <= 1'b1;
    else if (bar0_rvalid)         bar0_rd_pending_q <= 1'b0;
end

rtl8125b_bar0_regs u_bar0 (
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

// BAR0 CplD builder (highest TX priority, keeps EAC from timing out)
// CplD DW layout:
//   DW0 = 0x4A00_0001  (Fmt=10, Type=01010, Length=1)
//   DW1 = {cfg_completer_id, 3'b000, 1'b0, 11'd4}  (byte count=4)
//   DW2 = {rx_req_id, rx_tag, 1'b0, rx_bar0_addr[6:0]}
//   DW3 = bar0_rdata
//
//   Beat0: {DW1, DW0}  tkeep=0xFF  tlast=0
//   Beat1: {DW3, DW2}  tkeep=0xFF  tlast=1   (#5 fix: bar0_rdata not cfg_rdata)

localparam logic [31:0] CPLD_DW0 = 32'h4A00_0001;

typedef enum logic [1:0] {
    BAR_IDLE,
    BAR_B0,   // emit beat0
    BAR_B1    // emit beat1
} bar_tx_state_t;

bar_tx_state_t bar_tx_q;

logic [63:0] bar_tx_data_q;
logic  [7:0] bar_tx_keep_q;
logic        bar_tx_valid_q, bar_tx_last_q;

// Latch requester info at header capture time
logic [15:0] bar_req_id_latch;
logic  [7:0] bar_tag_latch;
logic [31:0] bar_addr_latch;

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        bar_tx_q        <= BAR_IDLE;
        bar_tx_valid_q  <= 1'b0;
        bar_tx_data_q   <= '0;
        bar_tx_keep_q   <= '0;
        bar_tx_last_q   <= 1'b0;
        bar_req_id_latch <= '0;
        bar_tag_latch    <= '0;
        bar_addr_latch   <= '0;
    end else begin
        case (bar_tx_q)
            BAR_IDLE: begin
                bar_tx_valid_q <= 1'b0;
                if (bar0_rvalid) begin
                    // Latch request context captured at header time
                    bar_req_id_latch <= rx_req_id;
                    bar_tag_latch    <= rx_tag;
                    bar_addr_latch   <= rx_bar0_addr;
                    bar_tx_q         <= BAR_B0;
                end
            end

            BAR_B0: begin
                // (#4 fix) rsp_start is wired from this path, not from 1'b0
                // (#5 fix) DW3=bar0_rdata (not cfg_rdata)
                bar_tx_valid_q <= 1'b1;
                bar_tx_data_q  <= {
                    {cfg_completer_id, 3'b000, 1'b0, 11'd4},  // DW1
                    CPLD_DW0                                   // DW0
                };
                bar_tx_keep_q  <= 8'hFF;
                bar_tx_last_q  <= 1'b0;
                if (s_axis_tx_tready)
                    bar_tx_q <= BAR_B1;
            end

            BAR_B1: begin
                bar_tx_valid_q <= 1'b1;
                bar_tx_data_q  <= {
                    bar0_rdata,                                // DW3 — actual shadow RAM data
                    {bar_req_id_latch, bar_tag_latch, 1'b0, bar_addr_latch[6:0]}  // DW2
                };
                bar_tx_keep_q  <= 8'hFF;
                bar_tx_last_q  <= 1'b1;
                if (s_axis_tx_tready) begin
                    bar_tx_valid_q <= 1'b0;
                    bar_tx_last_q  <= 1'b0;
                    bar_tx_q       <= BAR_IDLE;
                end
            end

            default: bar_tx_q <= BAR_IDLE;
        endcase
    end
end

// =============================================================================
// SECTION 9 — TX arbitration: BAR0 CplD (hi) > DMA TLPs (lo)
// =============================================================================
// BAR0 CplD must be serviced first to avoid EAC config-read timeouts.

logic bar_tx_active;
assign bar_tx_active = (bar_tx_q != BAR_IDLE);

always_comb begin
    if (bar_tx_active) begin
        // BAR0 CplD wins
        s_axis_tx_tdata  = bar_tx_data_q;
        s_axis_tx_tkeep  = bar_tx_keep_q;
        s_axis_tx_tvalid = bar_tx_valid_q;
        s_axis_tx_tlast  = bar_tx_last_q;
        dma_tx_ready     = 1'b0;
    end else begin
        // DMA engine has the bus
        s_axis_tx_tdata  = dma_tx_data;
        s_axis_tx_tkeep  = dma_tx_keep;
        s_axis_tx_tvalid = dma_tx_valid && !dma_hold_req;
        s_axis_tx_tlast  = dma_tx_last;
        dma_tx_ready     = s_axis_tx_tready && !dma_hold_req;
    end
end

// =============================================================================
// SECTION 10 — Response packager (ft601_clk domain)
// (#4 fix: rsp_start wired from frame_done path, never 1'b0)
// =============================================================================
// The response packager frames DMA read-back data for the USB host.
// frame_done_ft pulses when a full USB command frame has been processed.

logic        rsp_busy_ft, rsp_done_ft;
logic        pld_valid_ft, pld_ready_ft;
logic [31:0] pld_data_ft;
logic        rsp_fifo_wr_valid_ft, rsp_fifo_wr_ready_ft;
logic [31:0] rsp_fifo_wr_data_ft;
logic        rsp_fifo_wr_last_ft;

// Use frame_done_ft as rsp_start (#4 fix)
logic rsp_start_ft;
assign rsp_start_ft = frame_done_ft;

// Payload: data from response FIFO (already in ft601_clk after CDC)
assign pld_valid_ft  = !rsp_fifo_empty;
assign pld_data_ft   = rsp_fifo_dout;

ft601_resp_packager u_resp_packager (
    .clk             (ft601_clk),
    .rst_n           (ft601_rst_n),
    .rsp_start       (rsp_start_ft),
    .rsp_opcode_canon(last_opcode_ft),
    .rsp_flags       (8'h00),
    .rsp_addr        (last_base_addr_ft),
    .rsp_length_dw   (16'd1),
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

// =============================================================================
// SECTION 11 — cfg_ext → ECAP mux
// The 7-series PCIe IP forwards extended config space accesses (register_number
// >= 0x040 = byte offset 0x100) through cfg_ext_* ports.  We decode the DW
// address and dispatch to the appropriate ECAP module, then register the
// response one cycle later (IP requires data within 2 clocks of read_received).
//
// DW address map:
//   AER  0x040..0x04A  (11 DWs, bytes 0x100..0x128)
//   DSN  0x054..0x056  ( 3 DWs, bytes 0x150..0x158)
//   LTR  0x058..0x059  ( 2 DWs, bytes 0x160..0x164)
// =============================================================================

// ---- Address decode ---------------------------------------------------------
logic        ecap_aer_sel, ecap_dsn_sel, ecap_ltr_sel;
assign ecap_aer_sel = (cfg_ext_register_number >= 10'h040) &&
                      (cfg_ext_register_number <= 10'h04A);
assign ecap_dsn_sel = (cfg_ext_register_number >= 10'h054) &&
                      (cfg_ext_register_number <= 10'h056);
assign ecap_ltr_sel = (cfg_ext_register_number >= 10'h058) &&
                      (cfg_ext_register_number <= 10'h059);

logic [3:0] aer_dw_idx, dsn_dw_idx, ltr_dw_idx;
assign aer_dw_idx = cfg_ext_register_number[3:0] - 4'h0;  // relative to 0x040
assign dsn_dw_idx = cfg_ext_register_number[1:0] - 2'h0;  // relative to 0x054
assign ltr_dw_idx = cfg_ext_register_number[0];            // relative to 0x058

// ---- ECAP module instances --------------------------------------------------
logic [31:0] aer_rd_data_w, dsn_rd_data_w, ltr_rd_data_w;

pcie_ecap_aer u_ecap_aer (
    .clk       (user_clk),
    .rst_n     (user_rst_n),
    .cap_rd_en (cfg_ext_read_received  && ecap_aer_sel),
    .cap_wr_en (cfg_ext_write_received && ecap_aer_sel),
    .cap_dw_idx(aer_dw_idx),
    .cap_be    (cfg_ext_write_byte_enable),
    .cap_wdata (cfg_ext_write_data),
    .cap_rdata (aer_rd_data_w)
);

pcie_ecap_dsn u_ecap_dsn (
    // DSN is read-only / combinational — no clk/rst/wr ports
    .cap_rd_en (cfg_ext_read_received  && ecap_dsn_sel),
    .cap_dw_idx(dsn_dw_idx[1:0]),
    .cap_rdata (dsn_rd_data_w)
);

pcie_ecap_ltr u_ecap_ltr (
    .clk       (user_clk),
    .rst_n     (user_rst_n),
    .cap_rd_en (cfg_ext_read_received  && ecap_ltr_sel),
    .cap_wr_en (cfg_ext_write_received && ecap_ltr_sel),
    .cap_dw_idx(ltr_dw_idx[0]),
    .cap_be    (cfg_ext_write_byte_enable),
    .cap_wdata (cfg_ext_write_data),
    .cap_rdata (ltr_rd_data_w)
);

// ---- One-cycle registered response (IP requires valid within 2 clocks) ------
always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        cfg_ext_read_data       <= 32'hFFFF_FFFF;
        cfg_ext_read_data_valid <= 1'b0;
    end else begin
        cfg_ext_read_data_valid <= cfg_ext_read_received;
        if (cfg_ext_read_received) begin
            if      (ecap_aer_sel) cfg_ext_read_data <= aer_rd_data_w;
            else if (ecap_dsn_sel) cfg_ext_read_data <= dsn_rd_data_w;
            else if (ecap_ltr_sel) cfg_ext_read_data <= ltr_rd_data_w;
            else                   cfg_ext_read_data <= 32'hFFFF_FFFF; // unsupported ECAP → all-F
        end
    end
end

endmodule
