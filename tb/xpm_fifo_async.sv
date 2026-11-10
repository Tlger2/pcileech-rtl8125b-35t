// Behavioral stand-in for Xilinx xpm_fifo_async (FWFT, symmetric width).
// Simulation only — not part of the Vivado source list. Models the ports
// the endpoint uses: independent read/write clocks, active-high rst,
// first-word fall-through, and wr_rst_busy / rd_rst_busy.
`timescale 1ns/1ps

module xpm_fifo_async #(
    parameter integer FIFO_WRITE_DEPTH  = 16,
    parameter integer WRITE_DATA_WIDTH  = 32,
    parameter integer READ_DATA_WIDTH   = WRITE_DATA_WIDTH,
    parameter integer CDC_SYNC_STAGES   = 2,
    parameter integer FIFO_READ_LATENCY = 0,
    parameter integer PROG_FULL_THRESH  = 10,
    parameter integer PROG_EMPTY_THRESH = 10,
    parameter         FIFO_MEMORY_TYPE  = "block",
    parameter         READ_MODE         = "fwft",
    parameter         USE_ADV_FEATURES  = "0000"
) (
    input  wire                          wr_clk,
    input  wire                          rd_clk,
    input  wire                          rst,
    input  wire                          wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0]   din,
    output wire                          full,
    input  wire                          rd_en,
    output wire [READ_DATA_WIDTH-1:0]    dout,
    output wire                          empty,
    output wire                          wr_rst_busy,
    output wire                          rd_rst_busy,
    output wire                          almost_full,
    output wire                          almost_empty,
    output wire [31:0]                   wr_data_count,
    output wire [31:0]                   rd_data_count,
    output wire                          overflow,
    output wire                          underflow,
    output wire                          prog_full,
    output wire                          prog_empty,
    input  wire                          sleep,
    input  wire                          injectsbiterr,
    input  wire                          injectdbiterr,
    output wire                          sbiterr,
    output wire                          dbiterr
);
    localparam integer ADDR_W = $clog2(FIFO_WRITE_DEPTH);
    localparam integer PTR_W  = ADDR_W + 1;

    reg [WRITE_DATA_WIDTH-1:0] mem [0:FIFO_WRITE_DEPTH-1];
    reg [PTR_W-1:0] wr_bin, wr_gray;
    reg [PTR_W-1:0] rd_bin, rd_gray;
    reg [PTR_W-1:0] wr_gray_s1, wr_gray_s2;
    reg [PTR_W-1:0] rd_gray_s1, rd_gray_s2;
    reg [WRITE_DATA_WIDTH-1:0] dout_r;
    reg [2:0] wr_busy_cnt, rd_busy_cnt;
    reg wr_busy_r, rd_busy_r;

    function automatic [PTR_W-1:0] bin2gray(input [PTR_W-1:0] b);
        bin2gray = (b >> 1) ^ b;
    endfunction

    initial begin
        wr_bin = '0; wr_gray = '0;
        rd_bin = '0; rd_gray = '0;
        wr_gray_s1 = '0; wr_gray_s2 = '0;
        rd_gray_s1 = '0; rd_gray_s2 = '0;
        dout_r = '0;
        wr_busy_r = 1'b1; rd_busy_r = 1'b1;
        wr_busy_cnt = 3'd3; rd_busy_cnt = 3'd3;
    end

    // Current gray vs the other side's synchronized gray.
    wire empty_w = (rd_gray == wr_gray_s2);
    wire full_w  = (wr_gray == {~rd_gray_s2[PTR_W-1:PTR_W-2],
                                 rd_gray_s2[PTR_W-3:0]});

    assign empty         = empty_w;
    assign full          = full_w;
    assign dout          = dout_r[READ_DATA_WIDTH-1:0];
    assign wr_rst_busy   = wr_busy_r;
    assign rd_rst_busy   = rd_busy_r;
    assign almost_full   = full_w;
    assign almost_empty  = empty_w;
    assign wr_data_count = 32'h0;
    assign rd_data_count = 32'h0;
    assign overflow      = 1'b0;
    assign underflow     = 1'b0;
    assign prog_full     = full_w;
    assign prog_empty    = empty_w;
    assign sbiterr       = 1'b0;
    assign dbiterr       = 1'b0;

    // Touch unused configuration so the elaborator keeps the parameters.
    wire unused_cfg = sleep | injectsbiterr | injectdbiterr |
                      (CDC_SYNC_STAGES == 0) | (FIFO_READ_LATENCY != 0) |
                      (PROG_FULL_THRESH == 0) | (PROG_EMPTY_THRESH == 0) |
                      (READ_MODE == "std") | (FIFO_MEMORY_TYPE == "") |
                      (USE_ADV_FEATURES == "");

    always @(posedge wr_clk) begin
        rd_gray_s1 <= rd_gray;
        rd_gray_s2 <= rd_gray_s1;
        if (rst) begin
            wr_bin      <= '0;
            wr_gray     <= '0;
            wr_busy_r   <= 1'b1;
            wr_busy_cnt <= 3'd3;
        end else if (wr_busy_cnt != 3'd0) begin
            wr_busy_cnt <= wr_busy_cnt - 3'd1;
            wr_busy_r   <= 1'b1;
        end else begin
            wr_busy_r <= 1'b0;
            if (wr_en && !full_w) begin
                mem[wr_bin[ADDR_W-1:0]] <= din;
                wr_bin  <= wr_bin + 1'b1;
                wr_gray <= bin2gray(wr_bin + 1'b1);
            end
        end
    end

    always @(posedge rd_clk) begin
        wr_gray_s1 <= wr_gray;
        wr_gray_s2 <= wr_gray_s1;
        if (rst) begin
            rd_bin      <= '0;
            rd_gray     <= '0;
            dout_r      <= '0;
            rd_busy_r   <= 1'b1;
            rd_busy_cnt <= 3'd3;
        end else if (rd_busy_cnt != 3'd0) begin
            rd_busy_cnt <= rd_busy_cnt - 3'd1;
            rd_busy_r   <= 1'b1;
        end else begin
            rd_busy_r <= 1'b0;
            // Fall-through: dout holds the word at rd_bin. A pop advances
            // the pointer and prefetches the next word on this same edge;
            // the consumer samples the pre-edge dout.
            if (rd_en && !empty_w) begin
                rd_bin  <= rd_bin + 1'b1;
                rd_gray <= bin2gray(rd_bin + 1'b1);
                dout_r  <= mem[rd_bin[ADDR_W-1:0] + {{(ADDR_W-1){1'b0}}, 1'b1}];
            end else begin
                dout_r <= mem[rd_bin[ADDR_W-1:0]];
            end
        end
    end
endmodule
