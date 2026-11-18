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
    input  logic [15:0] cfg_command,
    input  logic debug_link_up,
    input  logic [31:0] debug_rx_header,
    // {fc_nph, tx_buf_av[5:0], link_state[2:0], cfg_dstatus[14:0]}
    input  logic [31:0] debug_link_diag,
    input  logic [31:0] debug_aer,
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
    // Every beat the PCIe core presents on m_axis_rx (not just CplD).
    input  logic        rx_any_valid,

    output logic        dma_cpl_seen,
    input  logic        dma_hold_req,
    // Pulse from the PCIe core when it discards a TX TLP (malformed / no credits).
    input  logic        tx_err_drop,
    // High while a non-posted request is outstanding. Drives cfg_trn_pending.
    output logic        np_pending
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
// Completion timeout: 12,500,000 cycles ≈ 100 ms @ 125 MHz, 200 ms @ 62.5 MHz.
localparam logic [23:0] CPL_TIMEOUT_CYCLES = 24'd12_500_000;
logic [23:0] cpl_timeout_q;

logic [31:0] debug_tx_beats, debug_cpl_beats;
logic [15:0] debug_tx_err_cnt;
logic [31:0] debug_rx_any;
logic [31:0] debug_bme_wait;   // counts GO_READ/GO_WRITE rejected because BME=0
always_ff @(posedge user_clk or negedge user_rst_n) begin
    if (!user_rst_n) begin
        debug_tx_beats  <= 0;
        debug_cpl_beats <= 0;
        debug_tx_err_cnt <= '0;
        debug_rx_any    <= '0;
        debug_bme_wait  <= '0;
    end else begin
        if (tx_req_valid && tx_req_ready) debug_tx_beats <= debug_tx_beats + 1;
        if (rx_cpl_valid) debug_cpl_beats <= debug_cpl_beats + 1;
        if (rx_any_valid && debug_rx_any != 32'hffff_ffff)
            debug_rx_any <= debug_rx_any + 32'd1;
        if (tx_err_drop && debug_tx_err_cnt != 16'hffff)
            debug_tx_err_cnt <= debug_tx_err_cnt + 16'd1;
        // Count GO pulses that arrive while BME=0 so we can confirm MGMT fix
        if (rf_we && rf_waddr == CTRL_ADDR && state_q == ST_IDLE &&
                !dma_hold_req && !cfg_command[2] &&
                (rf_wdata[0] || rf_wdata[1]) &&
                debug_bme_wait != 32'hffff_ffff)
            debug_bme_wait <= debug_bme_wait + 32'd1;
    end
end
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
// Keep the core from accepting a D3/L1 entry while a MemRd is in flight.
assign np_pending = (state_q == ST_TX_H0) || (state_q == ST_TX_H1) ||
                    (state_q == ST_TX_PLD) || (state_q == ST_WAIT_CPL);

// Completer/Requester ID: latch the last non-zero cfg_completer_id.
// GSR-zeroed; not cleared by user_reset, so a link retrain that reports 0
// keeps the BDF from the last successful enumeration. A hardcoded
// FALLBACK_BDF=0x0500 was this machine's cold-boot bus and is wrong if
// the device enumerates elsewhere. SRAM-only reload re-GSRs this to 0
// and the RC does not re-enumerate — CplD/DMA then need a cold boot.
logic [15:0] latched_completer_id = 16'h0;
always_ff @(posedge user_clk) begin
    if (cfg_completer_id != 16'h0)
        latched_completer_id <= cfg_completer_id;
end
wire [15:0] eff_completer_id =
    (cfg_completer_id != 16'h0) ? cfg_completer_id : latched_completer_id;

logic        fourdw_q;
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
        cpl_timeout_q  <= 24'h0;
        fourdw_q       <= 1'b0;
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
                    if (state_q == ST_IDLE && !dma_hold_req && cfg_command[2]) begin
                        xfer_len_q <= go_len;
                        if (rf_wdata[0]) begin
                            is_read_q  <= 1'b1;
                            status_q   <= 32'h1;
                            pend_tag_q <= tag_q;
                            tag_q      <= tag_q + 8'd1;
                            // 4DW only when the high address is nonzero. A
                            // 4DW MemRd with Addr[63:32]=0 is legal, but this
                            // root complex accepts the beat and returns no Cpl.
                            fourdw_q <= (addr_hi_q != 32'h0);
                            dw0_q <= (addr_hi_q != 32'h0 ? 32'h2000_0000 : 32'h0)
                                   | {22'h0, go_len};
                            dw1_q <= {eff_completer_id, tag_q,
                                      (go_len == 10'd1) ? 4'h0 : 4'hF, 4'hF};
                            dw2_q <= addr_hi_q;
                            dw3_q <= {addr_lo_q[31:2], 2'b00};
                            state_q <= ST_TX_H0;
                        end else if (rf_wdata[1]) begin
                            is_read_q  <= 1'b0;
                            status_q   <= 32'h1;
                            tag_q      <= tag_q + 8'd1;
                            dw0_q <= 32'h6000_0000 | {22'h0, go_len};
                            dw1_q <= {eff_completer_id, tag_q,
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
                32'h1C: rf_rdata_q <= debug_rx_any;
                32'h20: rf_rdata_q <= {eff_completer_id, cfg_command};
                32'h24: rf_rdata_q <= {26'b0,state_q,tx_req_ready,tx_req_valid,debug_link_up};
                32'h28: rf_rdata_q <= debug_tx_beats;
                32'h2c: rf_rdata_q <= {debug_rx_any[15:0], debug_cpl_beats[15:0]};
                32'h30: rf_rdata_q <= debug_rx_header;
                // {tx_err_drop count, raw cfg completer id (0 until latched)}
                32'h34: rf_rdata_q <= {debug_tx_err_cnt, cfg_completer_id};
                32'h38: rf_rdata_q <= debug_link_diag;
                32'h3C: rf_rdata_q <= debug_bme_wait;
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
                    tx_data_q <= fourdw_q ? {dw3_q, dw2_q} : {32'h0, dw3_q};
                    tx_keep_q <= fourdw_q ? 8'hFF : 8'h0F;
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
                        cpl_timeout_q  <= 24'h0;  // arm completion timeout
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
                tx_valid_q    <= 1'b0;
                cpl_timeout_q <= cpl_timeout_q + 24'd1;
                if (cpl_timeout_q == CPL_TIMEOUT_CYCLES) begin
                    // No completion in ~100-200 ms: flag ERR and unblock host.
                    cpl_hdr0_q     <= 1'b0;
                    cpl_need_dw2_q <= 1'b0;
                    status_q       <= 32'h4;  // bit2=ERR (timeout)
                    state_q        <= ST_DONE;
                end else if (rx_cpl_valid) begin
                    if (!cpl_hdr0_q) begin
                        // Beat 0: {DW1, DW0}. DW1[15:13] is Completer Status.
                        // 000=SC, 001=UR, 010=CRS, 100=CA. Anything but SC is
                        // a failed read — don't wait for a data beat that
                        // a 3DW Cpl (no payload) will never send.
                        if (rx_cpl_data[47:45] != 3'b000) begin
                            status_q <= 32'h4;
                            state_q  <= ST_DONE;
                        end else begin
                            cpl_hdr0_q     <= 1'b1;
                            cpl_need_dw2_q <= 1'b1;
                        end
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
