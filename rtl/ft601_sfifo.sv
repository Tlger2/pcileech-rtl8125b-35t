// FT601 synchronous 32-bit slave FIFO bridge (one buffered word per direction).
`timescale 1ns/1ps

module ft601_sfifo (
    input  logic        clk,     // ft601_clk, 100 MHz
    input  logic        rst_n,

    // ---- FT601 physical pins ----
    input  logic        ft601_rxf_n,    // RX FIFO not-empty (active low)
    input  logic        ft601_txe_n,    // TX FIFO not-full  (active low)
    (* IOB = "TRUE" *) output logic ft601_oe_n, // Output Enable (active low)
    (* IOB = "TRUE" *) output logic ft601_rd_n, // Read strobe (active low)
    (* IOB = "TRUE" *) output logic ft601_wr_n, // Write strobe (active low)
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

    typedef enum logic [2:0] {IDLE, RX_OE, RX_READ, TX_SETUP, TX_WRITE, TURN} state_t;
    state_t state, next_state;
    logic tx_pending, prefer_tx;
    (* IOB = "TRUE" *) logic [31:0] tx_data;
    (* IOB = "TRUE" *) logic [3:0] tx_be;
    wire rx_request = !ft601_rxf_n && (!fifo_rd_valid || fifo_rd_ready);
    wire tx_request = tx_pending && !ft601_txe_n;

    wire tristate_next = !(next_state == TX_SETUP || next_state == TX_WRITE);
    wire [35:0] tx_bus = {tx_be, tx_data};
    wire [35:0] pin_bus;
    assign {ft601_be, ft601_data} = pin_bus;
    for (genvar bit_index = 0; bit_index < 36; bit_index++) begin : gen_pin
        // Preserve a tristate register per pin so placement can pack it into
        // that pin's I/O block instead of routing a shared control net.
        (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) logic tristate_pin;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                tristate_pin <= 1'b1;
            else
                tristate_pin <= tristate_next;
        end
        assign pin_bus[bit_index] = tristate_pin ? 1'bz : tx_bus[bit_index];
    end
    assign fifo_wr_ready = rst_n && !tx_pending;

    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (tx_request && (prefer_tx || !rx_request))
                    next_state = TX_SETUP;
                else if (rx_request)
                    next_state = RX_OE;
            end
            RX_OE: next_state = ft601_rxf_n ? TURN : RX_READ;
            TX_SETUP: next_state = ft601_txe_n ? TURN : TX_WRITE;
            RX_READ, TX_WRITE: next_state = TURN;
            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            fifo_rd_data <= '0;
            fifo_rd_valid <= 1'b0;
            tx_pending <= 1'b0;
            tx_data <= '0;
            tx_be <= '0;
            prefer_tx <= 1'b0;
            ft601_oe_n <= 1'b1;
            ft601_rd_n <= 1'b1;
            ft601_wr_n <= 1'b1;
        end else begin
            state <= next_state;
            ft601_oe_n <= !(next_state == RX_OE || next_state == RX_READ);
            ft601_rd_n <= next_state != RX_READ;
            ft601_wr_n <= next_state != TX_WRITE;
            if (fifo_rd_valid && fifo_rd_ready)
                fifo_rd_valid <= 1'b0;
            if (fifo_wr_valid && fifo_wr_ready) begin
                tx_pending <= 1'b1;
                tx_data <= fifo_wr_data;
                tx_be <= fifo_wr_be;
            end

            case (state)
                RX_READ: begin
                    if (!ft601_rxf_n) begin
                        fifo_rd_data <= ft601_data;
                        fifo_rd_valid <= 1'b1;
                        prefer_tx <= 1'b1;
                    end
                end
                TX_WRITE: begin
                    if (!ft601_txe_n) begin
                        tx_pending <= 1'b0;
                        prefer_tx <= 1'b0;
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
