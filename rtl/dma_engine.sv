// DMA engine: issues 4DW MemRd/MemWr TLPs via AXI-Stream and collects CplDs.
// Register file (byte addresses, 32-bit):
//   0x00  CTRL     WO  [0]=GO_READ  [1]=GO_WRITE
//   0x04  ADDR_LO  RW
//   0x08  ADDR_HI  RW
//   0x0C  WDATA    RW  first payload DW (aliases buf[0])
//   0x10  STATUS   RO  [0]=BUSY  [1]=DONE  [2]=ERR
//   0x14  RDATA    RO  first completion DW
//   0x18  LENGTH   RW  DW count, 1..MAX_BURST_DW, default 1
//   0x40..         RW  burst buffer, MAX_BURST_DW DWs
//
// Default LENGTH=1 is a 1-DW TLP (existing host/TB path). GO_READ with
// LENGTH>=32 issues a 128 B MemRd; the length field and Last/First BE are
// set per PCIe spec. Completions may split; tags and remaining DW count
// are tracked until the request is filled.

`timescale 1ns/1ps

module dma_engine #(
    parameter int MAX_BURST_DW = 32   // 128 B at 4 B/DW; MPS 256 allows 64
) (
    input  logic        user_clk,
    input  logic        user_rst_n,

    input  logic        rf_we,
    input  logic [31:0] rf_waddr,
    input  logic [31:0] rf_wdata,
    input  logic        rf_re,
    input  logic [31:0] rf_raddr,
    output logic [31:0] rf_rdata,
    output logic        rf_rvalid,

    input  logic [15:0] cfg_completer_id,
    input  logic [2:0]  cfg_max_payload_size,

    output logic        tx_req_valid,
    input  logic        tx_req_ready,
    output logic [63:0] tx_req_data,
    output logic  [7:0] tx_req_keep,
    output logic        tx_req_last,

    input  logic        rx_cpl_valid,
    output logic        rx_cpl_ready,
    input  logic [63:0] rx_cpl_data,
    input  logic [7:0]  rx_cpl_keep,
    input  logic        rx_cpl_last,

    output logic        dma_cpl_seen,
    input  logic        dma_hold_req
);

localparam logic [31:0] CTRL_ADDR   = 32'h0000_0000;
localparam logic [31:0] ADDRLO_ADDR = 32'h0000_0004;
localparam logic [31:0] ADDRHI_ADDR = 32'h0000_0008;
localparam logic [31:0] WDATA_ADDR  = 32'h0000_000C;
localparam logic [31:0] STATUS_ADDR = 32'h0000_0010;
localparam logic [31:0] RDATA_ADDR  = 32'h0000_0014;
localparam logic [31:0] LENGTH_ADDR = 32'h0000_0018;
localparam logic [31:0] BUF_BASE    = 32'h0000_0040;

typedef enum logic [2:0] {
    ST_IDLE,
    ST_TX_H0,
    ST_TX_H1,
    ST_TX_PLD,
    ST_WAIT_CPL,
    ST_DONE
} tx_state_t;

tx_state_t state_q;
logic       is_read_q;

logic [31:0] addr_lo_q, addr_hi_q, wdata_q;
logic [31:0] status_q;
logic [31:0] rdata_q;
logic  [7:0] tag_q, pend_tag_q;
logic  [9:0] length_q;          // requested DWs
logic  [9:0] xfer_len_q;        // DWs in this TLP
logic [31:0] buf_q [0:MAX_BURST_DW-1];

logic [31:0] dw0_q, dw1_q, dw2_q, dw3_q;

logic        cpl_hdr0_q;
logic        cpl_need_dw2_q;    // next beat is {data0, DW2} of this CplD
logic  [9:0] cpl_got_q;
logic  [9:0] cpl_need_q;

logic [31:0] rf_rdata_q;
logic        rf_rvalid_q;
assign rf_rdata  = rf_rdata_q;
assign rf_rvalid = rf_rvalid_q;

logic [63:0] tx_data_q;
logic  [7:0] tx_keep_q;
logic        tx_last_q, tx_valid_q;
assign tx_req_valid = tx_valid_q;
assign tx_req_data  = tx_data_q;
assign tx_req_keep  = tx_keep_q;
assign tx_req_last  = tx_last_q;

assign rx_cpl_ready = (state_q == ST_WAIT_CPL);
assign dma_cpl_seen = (state_q == ST_DONE) && is_read_q;

logic [9:0] pld_idx_q;          // DWs already emitted on TX_PLD
logic [9:0] pld_remain;
assign pld_remain = (xfer_len_q > pld_idx_q) ? (xfer_len_q - pld_idx_q) : 10'd0;
wire [9:0] cpl_cont_add =
    ((cpl_got_q + 10'd1) < MAX_BURST_DW[9:0] && rx_cpl_keep[7:4] == 4'hF)
        ? 10'd2 : 10'd1;

// MPS in DWs: encoding 000=32 (128B), 001=64 (256B), ...
function automatic logic [9:0] mps_limit_dw(input logic [2:0] mps);
    case (mps)
        3'd0:    mps_limit_dw = 10'd32;
        3'd1:    mps_limit_dw = 10'd64;
        3'd2:    mps_limit_dw = 10'd128;
        default: mps_limit_dw = 10'd32;
    endcase
endfunction

function automatic logic [9:0] clamp_len(input logic [31:0] w, input logic [9:0] mps_dw);
    logic [9:0] n;
    n = (w == 0) ? 10'd1 : w[9:0];
    if (n > MAX_BURST_DW[9:0]) n = MAX_BURST_DW[9:0];
    if (n > mps_dw)            n = mps_dw;
    clamp_len = n;
endfunction

logic [9:0] mps_dw;
assign mps_dw = mps_limit_dw(cfg_max_payload_size);
wire [9:0] go_len = (length_q == 10'd0) ? 10'd1 : length_q;

logic in_buf_w, in_buf_r;
logic [$clog2(MAX_BURST_DW)-1:0] buf_idx_w, buf_idx_r;
assign in_buf_w = (rf_waddr >= BUF_BASE) &&
                  (rf_waddr < (BUF_BASE + MAX_BURST_DW*4)) &&
                  (rf_waddr[1:0] == 2'b00);
assign in_buf_r = (rf_raddr >= BUF_BASE) &&
                  (rf_raddr < (BUF_BASE + MAX_BURST_DW*4)) &&
                  (rf_raddr[1:0] == 2'b00);
assign buf_idx_w = (rf_waddr - BUF_BASE) >> 2;
assign buf_idx_r = (rf_raddr - BUF_BASE) >> 2;

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
        length_q       <= 10'd1;
        xfer_len_q     <= 10'd1;
        dw0_q <= '0; dw1_q <= '0; dw2_q <= '0; dw3_q <= '0;
        tx_valid_q     <= 1'b0;
        tx_data_q      <= 64'h0;
        tx_keep_q      <= 8'h0;
        tx_last_q      <= 1'b0;
        cpl_hdr0_q     <= 1'b0;
        cpl_need_dw2_q <= 1'b0;
        cpl_got_q      <= '0;
        cpl_need_q     <= '0;
        pld_idx_q      <= '0;
        rf_rdata_q     <= 32'h0;
        rf_rvalid_q    <= 1'b0;
        for (int i = 0; i < MAX_BURST_DW; i++)
            buf_q[i] <= 32'h0;
    end else begin
        rf_rvalid_q <= 1'b0;

        if (rf_we) begin
            if (in_buf_w) begin
                buf_q[buf_idx_w] <= rf_wdata;
                if (buf_idx_w == 0) wdata_q <= rf_wdata;
            end else case (rf_waddr)
                ADDRLO_ADDR: addr_lo_q <= rf_wdata;
                ADDRHI_ADDR: addr_hi_q <= rf_wdata;
                WDATA_ADDR: begin
                    wdata_q  <= rf_wdata;
                    buf_q[0] <= rf_wdata;
                end
                LENGTH_ADDR: begin
                    length_q <= clamp_len(rf_wdata, mps_dw);
                end
                CTRL_ADDR: begin
                    if (state_q == ST_IDLE && !dma_hold_req) begin
                        xfer_len_q <= go_len;
                        if (rf_wdata[0]) begin
                            is_read_q  <= 1'b1;
                            status_q   <= 32'h1;
                            pend_tag_q <= tag_q;
                            tag_q      <= tag_q + 8'd1;
                            dw0_q <= 32'h2000_0000 | {22'h0, go_len};
                            dw1_q <= {cfg_completer_id, tag_q,
                                      (go_len == 10'd1) ? 4'h0 : 4'hF, 4'hF};
                            dw2_q <= addr_hi_q;
                            dw3_q <= {addr_lo_q[31:2], 2'b00};
                            state_q <= ST_TX_H0;
                        end else if (rf_wdata[1]) begin
                            is_read_q  <= 1'b0;
                            status_q   <= 32'h1;
                            tag_q      <= tag_q + 8'd1;
                            dw0_q <= 32'h6000_0000 | {22'h0, go_len};
                            dw1_q <= {cfg_completer_id, tag_q,
                                      (go_len == 10'd1) ? 4'h0 : 4'hF, 4'hF};
                            dw2_q <= addr_hi_q;
                            dw3_q <= {addr_lo_q[31:2], 2'b00};
                            state_q <= ST_TX_H0;
                        end
                    end
                end
                default: ;
            endcase
        end

        if (rf_re) begin
            rf_rvalid_q <= 1'b1;
            if (in_buf_r)        rf_rdata_q <= buf_q[buf_idx_r];
            else case (rf_raddr)
                ADDRLO_ADDR:  rf_rdata_q <= addr_lo_q;
                ADDRHI_ADDR:  rf_rdata_q <= addr_hi_q;
                WDATA_ADDR:   rf_rdata_q <= wdata_q;
                STATUS_ADDR:  rf_rdata_q <= status_q;
                RDATA_ADDR:   rf_rdata_q <= rdata_q;
                LENGTH_ADDR:  rf_rdata_q <= {22'h0, length_q};
                default:      rf_rdata_q <= 32'hDEAD_BEEF;
            endcase
        end

        case (state_q)
            ST_IDLE: tx_valid_q <= 1'b0;

            ST_TX_H0: begin
                if (!tx_valid_q) begin
                    tx_valid_q <= 1'b1;
                    tx_data_q  <= {dw1_q, dw0_q};
                    tx_keep_q  <= 8'hFF;
                    tx_last_q  <= 1'b0;
                    pld_idx_q  <= 10'd0;
                end else if (tx_req_ready) begin
                    tx_data_q <= {dw3_q, dw2_q};
                    tx_last_q <= is_read_q;
                    state_q   <= ST_TX_H1;
                end
            end

            ST_TX_H1: begin
                if (tx_req_ready) begin
                    if (is_read_q) begin
                        tx_valid_q     <= 1'b0;
                        cpl_hdr0_q     <= 1'b0;
                        cpl_need_dw2_q <= 1'b0;
                        cpl_got_q      <= 10'd0;
                        cpl_need_q     <= xfer_len_q;
                        state_q        <= ST_WAIT_CPL;
                    end else begin
                        if (xfer_len_q <= 10'd1) begin
                            tx_data_q <= {32'h0, buf_q[0]};
                            tx_keep_q <= 8'h0F;
                            tx_last_q <= 1'b1;
                            pld_idx_q <= 10'd1;
                        end else begin
                            tx_data_q <= {buf_q[1], buf_q[0]};
                            tx_keep_q <= 8'hFF;
                            tx_last_q <= (xfer_len_q <= 10'd2);
                            pld_idx_q <= 10'd2;
                        end
                        state_q <= ST_TX_PLD;
                    end
                end
            end

            ST_TX_PLD: begin
                if (tx_req_ready) begin
                    if (tx_last_q) begin
                        tx_valid_q <= 1'b0;
                        status_q   <= 32'h2;
                        state_q    <= ST_DONE;
                    end else if (pld_remain <= 10'd1) begin
                        tx_data_q <= {32'h0, buf_q[pld_idx_q[$clog2(MAX_BURST_DW)-1:0]]};
                        tx_keep_q <= 8'h0F;
                        tx_last_q <= 1'b1;
                        pld_idx_q <= pld_idx_q + 10'd1;
                    end else begin
                        tx_data_q <= {
                            buf_q[pld_idx_q[$clog2(MAX_BURST_DW)-1:0] + 1],
                            buf_q[pld_idx_q[$clog2(MAX_BURST_DW)-1:0]]
                        };
                        tx_keep_q <= 8'hFF;
                        tx_last_q <= (pld_remain <= 10'd2);
                        pld_idx_q <= pld_idx_q + 10'd2;
                    end
                end
            end

            ST_WAIT_CPL: begin
                tx_valid_q <= 1'b0;
                if (rx_cpl_valid) begin
                    if (!cpl_hdr0_q) begin
                        // Beat 0 of each CplD: {DW1, DW0}. Completions may split.
                        cpl_hdr0_q     <= 1'b1;
                        cpl_need_dw2_q <= 1'b1;
                    end else if (cpl_need_dw2_q) begin
                        // Beat 1: {data0, DW2}. Tag lives in DW2[15:8].
                        cpl_need_dw2_q <= 1'b0;
                        if (rx_cpl_data[15:8] != pend_tag_q) begin
                            status_q <= 32'h4;
                            state_q  <= ST_DONE;
                        end else begin
                            if (cpl_got_q < MAX_BURST_DW[9:0])
                                buf_q[cpl_got_q[$clog2(MAX_BURST_DW)-1:0]] <=
                                    rx_cpl_data[63:32];
                            if (cpl_got_q == 10'd0)
                                rdata_q <= rx_cpl_data[63:32];
                            cpl_got_q <= cpl_got_q + 10'd1;
                            if (rx_cpl_last) begin
                                cpl_hdr0_q <= 1'b0;
                                if ((cpl_got_q + 10'd1) >= cpl_need_q) begin
                                    status_q <= 32'h2;
                                    state_q  <= ST_DONE;
                                end
                            end
                        end
                    end else begin
                        // Continuation beats: {data_{n+1}, data_n} (7-series 64-bit).
                        if (cpl_got_q < MAX_BURST_DW[9:0])
                            buf_q[cpl_got_q[$clog2(MAX_BURST_DW)-1:0]] <=
                                rx_cpl_data[31:0];
                        if (cpl_cont_add == 10'd2)
                            buf_q[cpl_got_q[$clog2(MAX_BURST_DW)-1:0] + 1] <=
                                rx_cpl_data[63:32];
                        cpl_got_q <= cpl_got_q + cpl_cont_add;
                        if (rx_cpl_last) begin
                            cpl_hdr0_q     <= 1'b0;
                            cpl_need_dw2_q <= 1'b0;
                            if ((cpl_got_q + cpl_cont_add) >= cpl_need_q) begin
                                status_q <= 32'h2;
                                state_q  <= ST_DONE;
                            end
                        end
                    end
                end
            end

            ST_DONE: state_q <= ST_IDLE;

            default: state_q <= ST_IDLE;
        endcase
    end
end

endmodule
