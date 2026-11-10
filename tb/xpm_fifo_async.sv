// Sim-only FWFT async FIFO so iverilog can elaborate the endpoint top.
// Not a timing model of XPM; depth and data width match the live instances.
`timescale 1ns/1ps

module xpm_fifo_async #(
    parameter int FIFO_WRITE_DEPTH = 16,
    parameter int WRITE_DATA_WIDTH = 32,
    parameter     FIFO_MEMORY_TYPE = "block",
    parameter int CDC_SYNC_STAGES  = 2,
    parameter     READ_MODE        = "fwft",
    parameter int FIFO_READ_LATENCY = 0,
    parameter     USE_ADV_FEATURES = "0000",
    parameter int READ_DATA_WIDTH  = WRITE_DATA_WIDTH
) (
    input  wire                        wr_clk,
    input  wire                        rd_clk,
    input  wire                        rst,
    input  wire                        wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0] din,
    output wire                        full,
    input  wire                        rd_en,
    output wire [READ_DATA_WIDTH-1:0]  dout,
    output wire                        empty,
    output wire                        wr_rst_busy,
    output wire                        rd_rst_busy,
    output wire                        almost_full,
    output wire                        almost_empty,
    output wire [7:0]                  wr_data_count,
    output wire [7:0]                  rd_data_count,
    output wire                        overflow,
    output wire                        underflow,
    output wire                        prog_full,
    output wire                        prog_empty,
    input  wire                        sleep,
    input  wire                        injectsbiterr,
    input  wire                        injectdbiterr,
    output wire                        sbiterr,
    output wire                        dbiterr
);
    localparam int DEPTH = FIFO_WRITE_DEPTH;
    localparam int AW    = $clog2(DEPTH);

    logic [WRITE_DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW:0] wr_ptr, rd_ptr, wr_ptr_rd, rd_ptr_wr;
    logic wr_rst_q, rd_rst_q;

    assign wr_rst_busy = wr_rst_q;
    assign rd_rst_busy = rd_rst_q;
    assign almost_full = 1'b0;
    assign almost_empty = 1'b0;
    assign wr_data_count = 8'h0;
    assign rd_data_count = 8'h0;
    assign overflow = 1'b0;
    assign underflow = 1'b0;
    assign prog_full = 1'b0;
    assign prog_empty = 1'b0;
    assign sbiterr = 1'b0;
    assign dbiterr = 1'b0;

    wire [AW:0] wr_count = wr_ptr - rd_ptr_wr;
    wire [AW:0] rd_count = wr_ptr_rd - rd_ptr;
    assign full  = wr_count[AW];
    assign empty = (rd_count == 0);
    assign dout  = mem[rd_ptr[AW-1:0]];

    always_ff @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            wr_ptr   <= '0;
            wr_rst_q <= 1'b1;
        end else begin
            wr_rst_q <= 1'b0;
            if (wr_en && !full)
                mem[wr_ptr[AW-1:0]] <= din;
            if (wr_en && !full)
                wr_ptr <= wr_ptr + 1'b1;
        end
    end

    always_ff @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            rd_ptr   <= '0;
            rd_rst_q <= 1'b1;
        end else begin
            rd_rst_q <= 1'b0;
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // Two-flop pointer CDC (functional, not a metastability study).
    logic [AW:0] wr_ptr_rd_meta, rd_ptr_wr_meta;
    always_ff @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            wr_ptr_rd_meta <= '0;
            wr_ptr_rd      <= '0;
        end else begin
            wr_ptr_rd_meta <= wr_ptr;
            wr_ptr_rd      <= wr_ptr_rd_meta;
        end
    end
    always_ff @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            rd_ptr_wr_meta <= '0;
            rd_ptr_wr      <= '0;
        end else begin
            rd_ptr_wr_meta <= rd_ptr;
            rd_ptr_wr      <= rd_ptr_wr_meta;
        end
    end
endmodule
