// lang: SystemVerilog, file: dma_engine.sv
// target: Xilinx Artix-7 XC7A35T, Vivado 2023.x, user_clk domain
// function: Issues 4DW MemRd/MemWr TLPs via AXI-Stream, collects CplD completions.
//           Presents a DWORD-addressed register file to the CDC command FIFO.
//
// Register map (byte addresses, all 32-bit):
//   0x00  CTRL_REG   WO  [0]=GO_READ  [1]=GO_WRITE  (self-clearing after launch)
//   0x04  ADDR_LO    RW  Lower 32 bits of target physical address
//   0x08  ADDR_HI    RW  Upper 32 bits of target physical address
//   0x0C  WDATA      RW  Data to write (MemWr only)
//   0x10  STATUS     RO  [0]=BUSY  [1]=DONE  [2]=ERR  (cleared on next GO)
//   0x14  RDATA      RO  Completion data from last MemRd
//
// TLP encoding (AXI-Stream, 64-bit data, beat = 8 bytes):
//   4DW MemRd  (fmt=01, type=00000, len=1):
//     Beat0: {DW1, DW0}  tkeep=0xFF  tlast=0
//     Beat1: {DW3, DW2}  tkeep=0xFF  tlast=1
//   4DW MemWr  (fmt=11, type=00000, len=1):
//     Beat0: {DW1, DW0}  tkeep=0xFF  tlast=0
//     Beat1: {DW3, DW2}  tkeep=0xFF  tlast=0
//     Beat2: {32'h0, payload}  tkeep=0x0F  tlast=1
//   CplD RX (fmt=10, type=01010):
//     Beat0: {DW1, DW0}  — DW1[31:16]=completer_id, DW1[14:12]=status
//     Beat1: {data, DW2} — DW2[15:8]=tag, data=read result
//
// All ChatGPT-identified bugs corrected:
//   #1  GO_WRITE bit: rf_wdata[1] (not [2])
//   #2  TX per-beat ready handshake: TX_H0 → TX_H1 → TX_PLD, stall on !ready
//   #3  MemWr payload: TX_PLD state emits {32'h0, wdata_q}, tkeep=0x0F
//   #4  STATUS layout: bit0=BUSY bit1=DONE bit2=ERR
//   #5  Tag tracking: pend_tag_q latched per request, compared on CplD
//   #6  Tag generation: 8-bit rotating counter tag_q
//   #7  4DW header: two beats (H0={DW1,DW0}, H1={DW3,DW2})

`timescale 1ns/1ps

module dma_engine (
    input  logic        user_clk,
    input  logic        user_rst_n,

    // ---- Register file (user_clk domain, from cmd_fifo CDC) ----
    input  logic        rf_we,
    input  logic [31:0] rf_waddr,
    input  logic [31:0] rf_wdata,
    input  logic        rf_re,
    input  logic [31:0] rf_raddr,
    output logic [31:0] rf_rdata,
    output logic        rf_rvalid,

    // ---- PCIe requester ID ----
    input  logic [15:0] cfg_completer_id,

    // ---- AXI-Stream TX → PCIe core ----
    output logic        tx_req_valid,
    input  logic        tx_req_ready,
    output logic [63:0] tx_req_data,
    output logic  [7:0] tx_req_keep,
    output logic        tx_req_last,

    // ---- AXI-Stream RX ← PCIe core (CplD from host) ----
    input  logic        rx_cpl_valid,
    output logic        rx_cpl_ready,
    input  logic [63:0] rx_cpl_data,
    input  logic  [7:0] rx_cpl_keep,
    input  logic        rx_cpl_last,

    // ---- Jitter gate ----
    output logic        dma_cpl_seen,   // one-cycle pulse when CplD received
    input  logic        dma_hold_req    // jitter FSM: suppress new TLPs
);

// ─── Register addresses ───────────────────────────────────────────────────────
localparam logic [31:0] CTRL_ADDR   = 32'h0000_0000;
localparam logic [31:0] ADDRLO_ADDR = 32'h0000_0004;
localparam logic [31:0] ADDRHI_ADDR = 32'h0000_0008;
localparam logic [31:0] WDATA_ADDR  = 32'h0000_000C;
localparam logic [31:0] STATUS_ADDR = 32'h0000_0010;
localparam logic [31:0] RDATA_ADDR  = 32'h0000_0014;

// ─── TLP DW0 constants ────────────────────────────────────────────────────────
// Fmt[1:0]=01 (4DW no-data) Type[4:0]=00000 Length=1  → 0x2000_0001
localparam logic [31:0] MEMRD_DW0 = 32'h2000_0001;
// Fmt[1:0]=11 (4DW w-data)  Type[4:0]=00000 Length=1  → 0x6000_0001
localparam logic [31:0] MEMWR_DW0 = 32'h6000_0001;

// ─── State machine ───────────────────────────────────────────────────────────
typedef enum logic [2:0] {
    ST_IDLE,
    ST_TX_H0,     // emit beat0  {DW1,DW0}            tkeep=0xFF tlast=0
    ST_TX_H1,     // emit beat1  {DW3,DW2}            tkeep=0xFF tlast=is_read
    ST_TX_PLD,    // emit beat2  {32'h0, wdata_q}     tkeep=0x0F tlast=1 (MemWr only)
    ST_WAIT_CPL,  // poll incoming CplD for matching tag
    ST_DONE       // latch result, pulse dma_cpl_seen, back to IDLE
} tx_state_t;

tx_state_t state_q;
logic       is_read_q;        // current op is MemRd (1) or MemWr (0)

// ─── Stored register values ───────────────────────────────────────────────────
logic [31:0] addr_lo_q, addr_hi_q, wdata_q;
logic [31:0] status_q;        // bit0=BUSY bit1=DONE bit2=ERR
logic [31:0] rdata_q;
logic  [7:0] tag_q;           // rotating tag counter
logic  [7:0] pend_tag_q;      // tag in flight

// ─── Latched TLP header DWs ───────────────────────────────────────────────────
logic [31:0] dw0_q, dw1_q, dw2_q, dw3_q;

// ─── CplD beat tracking ───────────────────────────────────────────────────────
logic        cpl_b0_seen_q;   // beat0 of a CplD was captured
logic        cpl_b1_seen_q;   // beat1 (DW2 + first data DW) was captured
logic [63:0] cpl_b0_q;        // beat0 data
logic  [7:0] cpl_tag_q;       // tag from DW2, held while extra payload drains
logic [31:0] cpl_data_q;      // first payload DW, held while extra payload drains

// ─── RF read output ───────────────────────────────────────────────────────────
logic [31:0] rf_rdata_q;
logic        rf_rvalid_q;

assign rf_rdata  = rf_rdata_q;
assign rf_rvalid = rf_rvalid_q;

// ─── TX drive ─────────────────────────────────────────────────────────────────
logic [63:0] tx_data_q;
logic  [7:0] tx_keep_q;
logic        tx_last_q;
logic        tx_valid_q;

assign tx_req_valid = tx_valid_q;
assign tx_req_data  = tx_data_q;
assign tx_req_keep  = tx_keep_q;
assign tx_req_last  = tx_last_q;

// Accept CplD only when waiting for one
assign rx_cpl_ready = (state_q == ST_WAIT_CPL);

// Pulse when a read completion has been captured (drives jitter FSM)
assign dma_cpl_seen = (state_q == ST_DONE) && is_read_q;

// ─── Main FSM ─────────────────────────────────────────────────────────────────
always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        state_q        <= ST_IDLE;
        is_read_q      <= 1'b0;
        addr_lo_q      <= 32'h0;
        addr_hi_q      <= 32'h0;
        wdata_q        <= 32'h0;
        status_q       <= 32'h0;
        rdata_q        <= 32'h0;
        tag_q          <= 8'h00;
        pend_tag_q     <= 8'h00;
        dw0_q <= '0; dw1_q <= '0; dw2_q <= '0; dw3_q <= '0;
        tx_valid_q     <= 1'b0;
        tx_data_q      <= 64'h0;
        tx_keep_q      <= 8'h0;
        tx_last_q      <= 1'b0;
        cpl_b0_seen_q  <= 1'b0;
        cpl_b1_seen_q  <= 1'b0;
        cpl_b0_q       <= 64'h0;
        cpl_tag_q      <= 8'h0;
        cpl_data_q     <= 32'h0;
        rf_rdata_q     <= 32'h0;
        rf_rvalid_q    <= 1'b0;
    end else begin
        rf_rvalid_q <= 1'b0;  // default: pulse only when handled

        // ── Register file write handler ──────────────────────────────────────
        if (rf_we) begin
            case (rf_waddr)
                ADDRLO_ADDR: addr_lo_q <= rf_wdata;
                ADDRHI_ADDR: addr_hi_q <= rf_wdata;
                WDATA_ADDR:  wdata_q   <= rf_wdata;
                CTRL_ADDR: begin
                    if (state_q == ST_IDLE && !dma_hold_req) begin
                        if (rf_wdata[0]) begin  // bit0 = GO_READ
                            is_read_q  <= 1'b1;
                            status_q   <= 32'h1;        // BUSY
                            pend_tag_q <= tag_q;
                            tag_q      <= tag_q + 8'd1;
                            // Build 4DW MemRd header
                            dw0_q <= MEMRD_DW0;
                            // DW1[7:4] = Last BE, DW1[3:0] = First BE.
                            // Length 1: First BE = F, Last BE = 0.
                            dw1_q <= {cfg_completer_id, tag_q, 4'h0, 4'hF};
                            dw2_q <= addr_hi_q;                  // upper 32-bit addr
                            dw3_q <= {addr_lo_q[31:2], 2'b00};  // lower 32-bit addr
                            state_q <= ST_TX_H0;
                        end else if (rf_wdata[1]) begin  // bit1 = GO_WRITE  (#1 fix)
                            is_read_q  <= 1'b0;
                            status_q   <= 32'h1;        // BUSY
                            tag_q      <= tag_q + 8'd1;
                            // Build 4DW MemWr header
                            dw0_q <= MEMWR_DW0;
                            // Same Length-1 byte enables as MemRd: First BE = F, Last BE = 0.
                            dw1_q <= {cfg_completer_id, tag_q, 4'h0, 4'hF};
                            dw2_q <= addr_hi_q;
                            dw3_q <= {addr_lo_q[31:2], 2'b00};
                            state_q <= ST_TX_H0;
                        end
                    end
                end
                default: ;
            endcase
        end

        // ── Register file read handler ───────────────────────────────────────
        if (rf_re) begin
            rf_rvalid_q <= 1'b1;
            case (rf_raddr)
                ADDRLO_ADDR:  rf_rdata_q <= addr_lo_q;
                ADDRHI_ADDR:  rf_rdata_q <= addr_hi_q;
                WDATA_ADDR:   rf_rdata_q <= wdata_q;
                STATUS_ADDR:  rf_rdata_q <= status_q;  // (#4 fix: bit0=BUSY bit1=DONE bit2=ERR)
                RDATA_ADDR:   rf_rdata_q <= rdata_q;
                default:      rf_rdata_q <= 32'hDEAD_BEEF;
            endcase
        end

        // ── TX / completion state machine ────────────────────────────────────
        case (state_q)
            ST_IDLE: begin
                tx_valid_q <= 1'b0;
                // Kick happens in CTRL_ADDR write handler above
            end

            // Registered TX: a beat is accepted only once tx_data_q already
            // holds it and tx_req_ready is high. Accepting in the same cycle
            // the beat is loaded drops it, because tready is usually already 1.
            // On accept, preload the next beat so it is what the core samples
            // on the following clock.
            ST_TX_H0: begin
                if (tx_valid_q && tx_req_ready && tx_data_q == {dw1_q, dw0_q}) begin
                    state_q    <= ST_TX_H1;
                    tx_valid_q <= 1'b1;
                    tx_data_q  <= {dw3_q, dw2_q};
                    tx_keep_q  <= 8'hFF;
                    tx_last_q  <= is_read_q;
                end else begin
                    tx_valid_q <= 1'b1;
                    tx_data_q  <= {dw1_q, dw0_q};
                    tx_keep_q  <= 8'hFF;
                    tx_last_q  <= 1'b0;
                end
            end

            ST_TX_H1: begin
                if (tx_valid_q && tx_req_ready && tx_data_q == {dw3_q, dw2_q}) begin
                    if (is_read_q) begin
                        tx_valid_q    <= 1'b0;
                        cpl_b0_seen_q <= 1'b0;
                        cpl_b1_seen_q <= 1'b0;
                        state_q       <= ST_WAIT_CPL;
                    end else begin
                        state_q    <= ST_TX_PLD;
                        tx_valid_q <= 1'b1;
                        tx_data_q  <= {32'h0000_0000, wdata_q};
                        tx_keep_q  <= 8'h0F;
                        tx_last_q  <= 1'b1;
                    end
                end else begin
                    tx_valid_q <= 1'b1;
                    tx_data_q  <= {dw3_q, dw2_q};
                    tx_keep_q  <= 8'hFF;
                    tx_last_q  <= is_read_q;
                end
            end

            ST_TX_PLD: begin
                if (tx_valid_q && tx_req_ready &&
                    tx_data_q == {32'h0000_0000, wdata_q}) begin
                    tx_valid_q <= 1'b0;
                    status_q   <= 32'h2;  // bit1=DONE
                    state_q    <= ST_DONE;
                end else begin
                    tx_valid_q <= 1'b1;
                    tx_data_q  <= {32'h0000_0000, wdata_q};
                    tx_keep_q  <= 8'h0F;
                    tx_last_q  <= 1'b1;
                end
            end

            ST_WAIT_CPL: begin
                tx_valid_q <= 1'b0;
                if (rx_cpl_valid) begin
                    if (!cpl_b0_seen_q) begin
                        // Beat0: {DW1, DW0} — header only. Tag and data are on beat1.
                        cpl_b0_q      <= rx_cpl_data;
                        cpl_b0_seen_q <= 1'b1;
                    end else if (!cpl_b1_seen_q) begin
                        // Beat1: {first_data, DW2}. DW2[15:8] is the tag.
                        // A 1-DW CplD ends here (tlast). A longer CplD keeps the
                        // tag and the first data DW, then drains until tlast.
                        if (rx_cpl_last) begin
                            cpl_b0_seen_q <= 1'b0;
                            if (rx_cpl_data[15:8] == pend_tag_q) begin
                                rdata_q  <= rx_cpl_data[63:32];
                                status_q <= 32'h2;      // bit1=DONE
                            end else begin
                                status_q <= 32'h4;      // bit2=ERR (tag mismatch)
                            end
                            state_q <= ST_DONE;
                        end else begin
                            cpl_tag_q     <= rx_cpl_data[15:8];
                            cpl_data_q    <= rx_cpl_data[63:32];
                            cpl_b1_seen_q <= 1'b1;
                        end
                    end else if (rx_cpl_last) begin
                        cpl_b0_seen_q <= 1'b0;
                        cpl_b1_seen_q <= 1'b0;
                        if (cpl_tag_q == pend_tag_q) begin
                            rdata_q  <= cpl_data_q;
                            status_q <= 32'h2;
                        end else begin
                            status_q <= 32'h4;
                        end
                        state_q <= ST_DONE;
                    end
                end
            end

            ST_DONE: begin
                // dma_cpl_seen pulses for one cycle here (combinational assign above)
                // STATUS retains DONE/ERR until next GO_* clears it
                state_q <= ST_IDLE;
            end

            default: state_q <= ST_IDLE;
        endcase
    end
end

endmodule
