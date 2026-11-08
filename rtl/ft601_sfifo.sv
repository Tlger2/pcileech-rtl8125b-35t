// lang: SystemVerilog, file: ft601_sfifo.sv
// target: Xilinx Artix-7 XC7A35T, ft601_clk domain (100 MHz)
// function: FT601 USB3 synchronous slave-FIFO bridge.
//           Presents simple FIFO-style valid/ready interfaces to the rest of the design.
//           OE_N must be asserted (low) one full cycle BEFORE RD_N per FT601 datasheet.
//
// State machine (RX / host→FPGA path):
//   R_IDLE  → R_OE   : oe_n=0, rd_n=1          (pre-assert OE_N)
//   R_OE    → R_STRB : oe_n=0, rd_n=0           (assert RD_N, data valid next cycle)
//   R_STRB  → R_LATCH: oe_n=0, rd_n=0           (sample ft601_data into rx fifo)
//   R_LATCH → R_IDLE : oe_n=1, rd_n=1           (release bus, tristate data)
//
//   De-assert when rxf_n goes high (no more data) during any RX state.
//
// TX (FPGA→host) path uses a straightforward WR_N assertion whenever txe_n is low
// and we have data to send.
//
// All ChatGPT-identified bugs corrected:
//   #1  `assign oe_n = 1'b1` dead override removed — driven from FSM register
//   #2  `assign rd_n = 1'b1` dead override removed — driven from FSM register
//   #3  Duplicate `logic data_oe` declaration removed — single declaration only

`timescale 1ns/1ps

module ft601_sfifo (
    input  logic        clk,     // ft601_clk, 100 MHz
    input  logic        rst_n,

    // ---- FT601 physical pins ----
    input  logic        ft601_rxf_n,    // RX FIFO not-empty (active low)
    input  logic        ft601_txe_n,    // TX FIFO not-full  (active low)
    output logic        ft601_oe_n,     // Output Enable     (active low)
    output logic        ft601_rd_n,     // Read strobe       (active low)
    output logic        ft601_wr_n,     // Write strobe      (active low)
    inout  wire  [31:0] ft601_data,     // Bidirectional 32-bit bus
    inout  wire   [3:0] ft601_be,       // Byte enable (bidirectional)

    // ---- RX path: data from USB host into FPGA ----
    output logic        fifo_rd_valid,  // data word available
    input  logic        fifo_rd_ready,  // consumer accepts data
    output logic [31:0] fifo_rd_data,   // received data word

    // ---- TX path: data from FPGA out to USB host ----
    input  logic        fifo_wr_valid,  // producer has data
    output logic        fifo_wr_ready,  // we accepted it
    input  logic [31:0] fifo_wr_data,   // data to send
    input  logic  [3:0] fifo_wr_be      // byte enables for TX
);

// ─── Internal bus drive control ───────────────────────────────────────────────
// (#3 fix: single declaration only)
logic        data_oe;        // 1 = FPGA drives ft601_data/be (TX), 0 = tristate
logic [31:0] tx_data_drive;
logic  [3:0] tx_be_drive;

assign ft601_data = data_oe ? tx_data_drive : 32'hZZZZ_ZZZZ;
assign ft601_be   = data_oe ? tx_be_drive   :  4'hZ;

// ─── RX state machine ─────────────────────────────────────────────────────────
typedef enum logic [1:0] {
    R_IDLE,
    R_OE,     // OE_N low, RD_N still high — give bus turnaround one cycle
    R_STRB,   // OE_N low, RD_N low — data valid on input bus
    R_LATCH   // sample registered data, deassert both
} rx_state_t;

rx_state_t rx_state_q;

// FSM-driven output regs (#1 & #2 fix: not tied to 1'b1)
logic oe_n_q, rd_n_q;
assign ft601_oe_n = oe_n_q;
assign ft601_rd_n = rd_n_q;

// Registered input (sample ft601_data one cycle after RD_N assertion)
logic [31:0] rx_data_latch;
logic        rx_data_valid_q;

// Output register for fifo_rd interface
logic [31:0] fifo_rd_data_q;
logic        fifo_rd_valid_q;

assign fifo_rd_data  = fifo_rd_data_q;
assign fifo_rd_valid = fifo_rd_valid_q;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_state_q      <= R_IDLE;
        oe_n_q          <= 1'b1;
        rd_n_q          <= 1'b1;
        rx_data_latch   <= 32'h0;
        rx_data_valid_q <= 1'b0;
        fifo_rd_data_q  <= 32'h0;
        fifo_rd_valid_q <= 1'b0;
    end else begin
        // Clear single-cycle valid once consumer accepts
        if (fifo_rd_valid_q && fifo_rd_ready)
            fifo_rd_valid_q <= 1'b0;

        case (rx_state_q)
            R_IDLE: begin
                oe_n_q <= 1'b1;
                rd_n_q <= 1'b1;
                // Start RX when host has data and consumer has drained previous word
                if (!ft601_rxf_n && (!fifo_rd_valid_q || fifo_rd_ready)) begin
                    oe_n_q     <= 1'b0;   // pre-assert OE_N one cycle early
                    rd_n_q     <= 1'b1;
                    rx_state_q <= R_OE;
                end
            end

            R_OE: begin
                // OE_N already low; now assert RD_N
                if (!ft601_rxf_n) begin
                    oe_n_q     <= 1'b0;
                    rd_n_q     <= 1'b0;   // FT601 drives data next clock
                    rx_state_q <= R_STRB;
                end else begin
                    // Host took data away between IDLE and OE — back off
                    oe_n_q     <= 1'b1;
                    rx_state_q <= R_IDLE;
                end
            end

            R_STRB: begin
                // Data is valid on ft601_data now — capture it
                oe_n_q        <= 1'b0;
                rd_n_q        <= 1'b0;
                rx_data_latch <= ft601_data;    // combinational sample from bidir
                rx_state_q    <= R_LATCH;
            end

            R_LATCH: begin
                // Release bus, push word to consumer FIFO interface
                oe_n_q          <= 1'b1;
                rd_n_q          <= 1'b1;
                fifo_rd_data_q  <= rx_data_latch;
                fifo_rd_valid_q <= 1'b1;
                rx_state_q      <= R_IDLE;
            end

            default: rx_state_q <= R_IDLE;
        endcase
    end
end

// ─── TX state machine ─────────────────────────────────────────────────────────
typedef enum logic [1:0] {
    T_IDLE,
    T_DRIVE,   // drive data onto bus, assert WR_N
    T_HOLD     // deassert WR_N, tristate
} tx_state_t;

tx_state_t  tx_state_q;
logic       ft601_wr_n_q;
logic       fifo_wr_ready_q;

assign ft601_wr_n    = ft601_wr_n_q;
assign fifo_wr_ready = fifo_wr_ready_q;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_state_q      <= T_IDLE;
        ft601_wr_n_q    <= 1'b1;
        data_oe         <= 1'b0;
        tx_data_drive   <= 32'h0;
        tx_be_drive     <=  4'h0;
        fifo_wr_ready_q <= 1'b0;
    end else begin
        fifo_wr_ready_q <= 1'b0;  // default: not accepting

        case (tx_state_q)
            T_IDLE: begin
                ft601_wr_n_q <= 1'b1;
                data_oe      <= 1'b0;
                // Only TX when FT601 has room, we have data, and RX bus is released
                if (!ft601_txe_n && fifo_wr_valid && oe_n_q) begin
                    tx_data_drive   <= fifo_wr_data;
                    tx_be_drive     <= fifo_wr_be;
                    data_oe         <= 1'b1;
                    ft601_wr_n_q    <= 1'b0;
                    fifo_wr_ready_q <= 1'b1;   // accept producer word this cycle
                    tx_state_q      <= T_DRIVE;
                end
            end

            T_DRIVE: begin
                // WR_N active, data stable — hold one cycle
                ft601_wr_n_q <= 1'b1;   // deassert
                data_oe      <= 1'b0;   // tristate next cycle
                tx_state_q   <= T_HOLD;
            end

            T_HOLD: begin
                // Bus turnaround — back to idle
                ft601_wr_n_q <= 1'b1;
                data_oe      <= 1'b0;
                tx_state_q   <= T_IDLE;
            end

            default: tx_state_q <= T_IDLE;
        endcase
    end
end

endmodule
