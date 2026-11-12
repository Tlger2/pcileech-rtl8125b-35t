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
// CDC protocol over FT601 (2-word frames, 32-bit words):
//   Write: Word0={1'b1, 15'h0, byte_addr[15:0]}  Word1=wdata[31:0]
//   Read:  Word0={1'b0, 15'h0, byte_addr[15:0]}  → response pushed to RSP FIFO

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

// =============================================================================
// Resets
// =============================================================================
logic user_rst_n;
assign user_rst_n = ~user_reset;

// Combined async reset for xpm FIFOs (level, needs 2+ cycles of slower clk)
logic fifo_arst;
assign fifo_arst = ~ft601_rst_n | user_reset;

// =============================================================================
// Static tie-offs
// =============================================================================
assign m_axis_rx_tready    = 1'b1;   // 7-series RX cannot be back-pressured
assign cfg_interrupt_assert = 1'b0;
assign cfg_interrupt_di     = 8'h01;
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

// FT601 always ready to receive host commands
assign fifo_rd_ready = 1'b1;

// =============================================================================
// SECTION 2 — FT601 Command Decoder (ft601_clk domain)
//
// 2-word framing:
//   Word0: [31]=is_write, [15:0]=byte_addr within DMA register file
//   Word1 (writes only): wdata[31:0]
//
// Output to CMD FIFO: 65-bit word = {is_write, addr[31:0], wdata[31:0]}
// =============================================================================
logic        cmd_wr_en;
logic [64:0] cmd_wr_data;
logic        cmd_wr_full;
logic        cmd_wr_rst_busy;

typedef enum logic {FT_IDLE = 1'b0, FT_WAIT_DATA = 1'b1} ft_state_e;
ft_state_e ft_state;

logic        ft_is_write_q;
logic [31:0] ft_addr_q;

always_ff @(posedge ft601_clk or negedge ft601_rst_n) begin
    if (!ft601_rst_n) begin
        ft_state     <= FT_IDLE;
        ft_is_write_q <= 1'b0;
        ft_addr_q    <= '0;
        cmd_wr_en    <= 1'b0;
        cmd_wr_data  <= '0;
    end else begin
        cmd_wr_en <= 1'b0;

        case (ft_state)
            FT_IDLE: begin
                if (fifo_rd_valid && !cmd_wr_full && !cmd_wr_rst_busy) begin
                    ft_is_write_q <= fifo_rd_data[31];
                    ft_addr_q     <= {16'h0, fifo_rd_data[15:0]};
                    if (fifo_rd_data[31]) begin
                        // Write: need data word next
                        ft_state  <= FT_WAIT_DATA;
                    end else begin
                        // Read: push immediately (wdata unused)
                        cmd_wr_en   <= 1'b1;
                        cmd_wr_data <= {1'b0, {16'h0, fifo_rd_data[15:0]}, 32'h0};
                        ft_state    <= FT_IDLE;
                    end
                end
            end

            FT_WAIT_DATA: begin
                if (fifo_rd_valid && !cmd_wr_full && !cmd_wr_rst_busy) begin
                    cmd_wr_en   <= 1'b1;
                    cmd_wr_data <= {1'b1, ft_addr_q, fifo_rd_data};
                    ft_state    <= FT_IDLE;
                end
            end

            default: ft_state <= FT_IDLE;
        endcase
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
logic [31:0] rsp_rd_data;
logic        rsp_rd_empty;
logic        rsp_rd_en;
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

wire rsp_rd_valid = ~rsp_rd_empty & ~rsp_rd_rst_busy;

// RSP FIFO consumer (ft601_clk): push read responses back to host
assign rsp_rd_en    = rsp_rd_valid & fifo_wr_ready;
assign fifo_wr_valid = rsp_rd_valid;
assign fifo_wr_data  = rsp_rd_data;
assign fifo_wr_be    = 4'hF;

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
    // Jitter gate
    .dma_cpl_seen     (dma_cpl_seen),
    .dma_hold_req     (1'b0)
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
        else                 rx_beat_cnt <= rx_beat_cnt + 1'b1;
    end
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

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        rx_reqid_q   <= '0;
        rx_tag_q     <= '0;
        rx_firstbe_q <= '0;
        rx_tlp_kind  <= RX_OTHER;
    end else if (m_axis_rx_tvalid && rx_beat_cnt == 2'd0) begin
        // Beat0: tdata[31:0]=DW0, tdata[63:32]=DW1
        // DW1: [31:16]=ReqID, [23:16]=Tag, [3:0]=FirstBE
        rx_reqid_q   <= m_axis_rx_tdata[63:48]; // DW1[31:16]
        rx_tag_q     <= m_axis_rx_tdata[47:40]; // DW1[23:16]
        rx_firstbe_q <= m_axis_rx_tdata[35:32]; // DW1[3:0]
        case (m_axis_rx_tdata[31:24])            // DW0 fmt|type byte
            8'h00:   rx_tlp_kind <= RX_MRD;
            8'h40:   rx_tlp_kind <= RX_MWR;
            8'h4A:   rx_tlp_kind <= RX_CPLD;
            default: rx_tlp_kind <= RX_OTHER;
        endcase
    end
end

// --- CplD routing to DMA engine ---
// beat0: combinatorial detection; beat1+: use registered rx_tlp_kind
assign dma_rx_valid = m_axis_rx_tvalid & (
    (rx_beat_cnt == 2'd0 && m_axis_rx_tdata[31:24] == 8'h4A) |
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
logic  [7:0] bar0_byte_addr_q;
logic [31:0] bar0_wdata_q;

// Context saved for CplD generation (latched alongside bar0_rd_en_q)
logic [15:0] bar0_pend_reqid;
logic  [7:0] bar0_pend_tag;
logic  [7:0] bar0_pend_laddr; // LowerAddr for CplD DW2

// cpld_state used to gate new MemRd when a CplD is already in-flight
// (declared below; forward reference is fine in SV)
logic cpld_pending;

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        bar0_wr_en_q    <= 1'b0;
        bar0_rd_en_q    <= 1'b0;
        bar0_byte_addr_q <= '0;
        bar0_wdata_q    <= '0;
        bar0_pend_reqid <= '0;
        bar0_pend_tag   <= '0;
        bar0_pend_laddr <= '0;
    end else begin
        bar0_wr_en_q <= 1'b0;
        bar0_rd_en_q <= 1'b0;

        if (m_axis_rx_tvalid && rx_beat_cnt == 2'd1) begin
            bar0_byte_addr_q <= m_axis_rx_tdata[7:0]; // DW2[7:0]

            if (rx_tlp_kind == RX_MWR) begin
                bar0_wr_en_q <= 1'b1;
                bar0_wdata_q <= m_axis_rx_tdata[63:32]; // DW3 = payload
            end else if (rx_tlp_kind == RX_MRD && !cpld_pending) begin
                // Only issue read when no CplD is already in-flight
                bar0_rd_en_q    <= 1'b1;
                bar0_pend_reqid <= rx_reqid_q;
                bar0_pend_tag   <= rx_tag_q;
                bar0_pend_laddr <= m_axis_rx_tdata[7:0]; // LowerAddr = byte offset
            end
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
                if (bar0_rvalid) begin
                    // DW0 = {fmt=010, type=01010, 7'b0, len=1DW} = 32'h4A00_0001
                    // DW1 = {CompleterID[15:0], BCM=0, Status=000(OK), ByteCount=12'd4}
                    cpld_b0 <= {
                        cfg_completer_id,
                        1'b0,
                        3'b000,
                        12'd4,
                        32'h4A00_0001
                    };
                    // DW2 = {RequesterID[15:0], Tag[7:0], 1'b0, LowerAddr[6:0]}
                    cpld_b1 <= {
                        bar0_rdata,
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
// SECTION 9 — TX Arbitration (user_clk domain)
//
// Priority: CplD (latency-sensitive) > DMA engine TLPs.
// Source is locked for the duration of a TLP (until tlast + ready).
// =============================================================================
logic tx_sel;     // 1 = CplD, 0 = DMA
logic tx_in_tlp;  // 1 = mid-TLP, source locked

always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        tx_sel    <= 1'b0;
        tx_in_tlp <= 1'b0;
    end else begin
        if (!tx_in_tlp) begin
            // Idle — select source (CplD takes priority)
            tx_sel <= cpld_valid ? 1'b1 : 1'b0;
            // Track TLP start
            if (s_axis_tx_tvalid && s_axis_tx_tready && !s_axis_tx_tlast)
                tx_in_tlp <= 1'b1;
        end else begin
            // Mid-TLP — locked to current source until tlast
            if (s_axis_tx_tvalid && s_axis_tx_tready && s_axis_tx_tlast)
                tx_in_tlp <= 1'b0;
        end
    end
end

// TX output mux
always_comb begin
    if (tx_sel) begin
        // CplD source
        s_axis_tx_tdata  = cpld_tdata;
        s_axis_tx_tkeep  = cpld_tkeep;
        s_axis_tx_tvalid = cpld_valid;
        s_axis_tx_tlast  = cpld_tlast;
        cpld_tx_ready    = s_axis_tx_tready;
        dma_tx_ready     = 1'b0;
    end else begin
        // DMA engine source
        s_axis_tx_tdata  = dma_tx_data;
        s_axis_tx_tkeep  = dma_tx_keep;
        s_axis_tx_tvalid = dma_tx_valid;
        s_axis_tx_tlast  = dma_tx_last;
        cpld_tx_ready    = 1'b0;
        dma_tx_ready     = s_axis_tx_tready;
    end
end

// =============================================================================
// SECTION 10 — Interrupt (user_clk domain)
// =============================================================================
assign cfg_interrupt = irq_pulse;

endmodule
