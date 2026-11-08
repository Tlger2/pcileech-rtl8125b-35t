// MSI-X Table + PBA storage, memory-mapped inside BAR0.
// Table: NUM_VECTORS * 16 bytes starting at TABLE_BAR_BYTE_BASE
// PBA  : NUM_VECTORS bits packed into DWs at PBA_BAR_BYTE_BASE
// At reset all vectors are masked per PCIe spec (Vector Control bit 0 = 1).

module msix_table_pba #(
    parameter int NUM_VECTORS         = 8,
    parameter int TABLE_BAR_BYTE_BASE = 'h0000,
    parameter int PBA_BAR_BYTE_BASE   = 'h1000
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mem_wr_en,
    input  logic        mem_rd_en,
    input  logic [15:0] mem_byte_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_be,
    output logic [31:0] mem_rdata,
    output logic        mem_rvalid,

    input  logic [$clog2(NUM_VECTORS)-1:0] vec_rd_idx,
    output logic [63:0] vec_addr,
    output logic [31:0] vec_data,
    output logic        vec_mask,

    input  logic [NUM_VECTORS-1:0] pba_set,
    input  logic [NUM_VECTORS-1:0] pba_clear,
    output logic [NUM_VECTORS-1:0] pba_bits
);
    localparam int TABLE_DWS   = NUM_VECTORS * 4;
    localparam int TABLE_BYTES = NUM_VECTORS * 16;
    localparam int PBA_DWS     = (NUM_VECTORS + 31) / 32;
    localparam int PBA_BYTES   = PBA_DWS * 4;

    logic [31:0] table_mem [0:TABLE_DWS-1];
    logic [NUM_VECTORS-1:0] pba_q;
    assign pba_bits = pba_q;

    logic [15:0] table_off, pba_off;
    logic        in_table, in_pba;
    assign table_off = mem_byte_addr - TABLE_BAR_BYTE_BASE[15:0];
    assign pba_off   = mem_byte_addr - PBA_BAR_BYTE_BASE[15:0];
    assign in_table  = (mem_byte_addr >= TABLE_BAR_BYTE_BASE) &&
                       (table_off < TABLE_BYTES);
    assign in_pba    = (mem_byte_addr >= PBA_BAR_BYTE_BASE) &&
                       (pba_off < PBA_BYTES);

    logic [$clog2(TABLE_DWS)-1:0] table_dw_idx;
    assign table_dw_idx = table_off[$clog2(TABLE_DWS)+1:2];

    assign vec_addr[31:0]  = table_mem[vec_rd_idx*4 + 0];
    assign vec_addr[63:32] = table_mem[vec_rd_idx*4 + 1];
    assign vec_data        = table_mem[vec_rd_idx*4 + 2];
    assign vec_mask        = table_mem[vec_rd_idx*4 + 3][0];

    logic [31:0] pba_rd_dw;
    always_comb begin
        pba_rd_dw = 32'h0;
        for (int i = 0; i < 32; i++) begin
            if (i < NUM_VECTORS) pba_rd_dw[i] = pba_q[i];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int v = 0; v < NUM_VECTORS; v++) begin
                table_mem[v*4 + 0] <= 32'h0;
                table_mem[v*4 + 1] <= 32'h0;
                table_mem[v*4 + 2] <= 32'h0;
                table_mem[v*4 + 3] <= 32'h0000_0001;
            end
            pba_q      <= '0;
            mem_rdata  <= 32'h0;
            mem_rvalid <= 1'b0;
        end else begin
            mem_rvalid <= 1'b0;

            if (mem_wr_en && in_table) begin
                if (mem_be[0]) table_mem[table_dw_idx][7:0]   <= mem_wdata[7:0];
                if (mem_be[1]) table_mem[table_dw_idx][15:8]  <= mem_wdata[15:8];
                if (mem_be[2]) table_mem[table_dw_idx][23:16] <= mem_wdata[23:16];
                if (mem_be[3]) table_mem[table_dw_idx][31:24] <= mem_wdata[31:24];
            end

            if (mem_rd_en) begin
                mem_rvalid <= 1'b1;
                if (in_table)      mem_rdata <= table_mem[table_dw_idx];
                else if (in_pba)   mem_rdata <= pba_rd_dw;
                else               mem_rdata <= 32'h0;
            end

            for (int v = 0; v < NUM_VECTORS; v++) begin
                if (pba_clear[v])    pba_q[v] <= 1'b0;
                else if (pba_set[v]) pba_q[v] <= 1'b1;
            end
        end
    end
endmodule
